"""Generate deterministic bit-exact vectors for the independent R1 ISP primitives."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Iterable


# Project-wide public encoding: 00 RGGB, 01 BGGR, 10 GRBG, 11 GBRG.
# Each tuple is the (row, column) position of R in the original 2x2 tile.
R_POSITION_BY_PATTERN = ((0, 0), (1, 1), (0, 1), (1, 0))


def round_shift_away(value: int, shift: int) -> int:
    if shift == 0:
        return value
    magnitude = abs(value)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return -rounded if value < 0 else rounded


def clamp(value: int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, value))


def bayer_phase(x: int, y: int, pattern: int,
                roi_x_parity: int, roi_y_parity: int) -> int:
    """Return canonical 0=R,1=Gr,2=Gb,3=B phase."""
    if pattern < 0 or pattern >= len(R_POSITION_BY_PATTERN):
        raise ValueError("Bayer pattern code must be in 0..3")
    r_row, r_column = R_POSITION_BY_PATTERN[pattern]
    row = (y & 1) ^ roi_y_parity ^ r_row
    column = (x & 1) ^ roi_x_parity ^ r_column
    return (row << 1) | column


def blc_u10(raw: int, x: int, y: int, pattern: int,
            roi_x_parity: int, roi_y_parity: int,
            black_levels: tuple[int, int, int, int]) -> tuple[int, int]:
    phase = bayer_phase(x, y, pattern, roi_x_parity, roi_y_parity)
    return clamp(raw - black_levels[phase], 0, 1023), phase


def awb_u12(pixel: int, gain_q14: int) -> int:
    return clamp(round_shift_away(pixel * gain_q14, 14), 0, 4095)


def color_pipeline(
    rgb10: tuple[int, int, int],
    gains: tuple[int, int, int],
    ccm: tuple[tuple[int, int, int],
               tuple[int, int, int],
               tuple[int, int, int]],
    offsets: tuple[int, int, int],
    gamma: list[int],
) -> tuple[int, int, int]:
    awb = [awb_u12(pixel, gain) for pixel, gain in zip(rgb10, gains)]
    linear: list[int] = []
    for row, offset in zip(ccm, offsets):
        accumulator = offset + sum(pixel * coefficient
                                   for pixel, coefficient in zip(awb, row))
        linear.append(clamp(round_shift_away(accumulator, 13), 0, 1023))
    return tuple(gamma[value] for value in linear)  # type: ignore[return-value]


def pack_fields(fields: Iterable[tuple[int, int]]) -> int:
    packed = 0
    for value, width in fields:
        packed = (packed << width) | (value & ((1 << width) - 1))
    return packed


def pack_blc_vector(
    raw: int,
    x: int,
    y: int,
    pattern: int,
    roi_x: int,
    roi_y: int,
    black: tuple[int, int, int, int],
) -> int:
    expected, phase = blc_u10(raw, x, y, pattern, roi_x, roi_y, black)
    return pack_fields(
        [(raw, 10), (x, 10), (y, 9), (pattern, 2),
         (roi_x, 1), (roi_y, 1),
         *((level, 10) for level in black),
         (expected, 10), (phase, 2)]
    )


def pack_color_config(
    gains: tuple[int, int, int],
    ccm: tuple[tuple[int, int, int],
               tuple[int, int, int],
               tuple[int, int, int]],
    offsets: tuple[int, int, int],
) -> int:
    fields: list[tuple[int, int]] = [(value, 16) for value in gains]
    fields.extend((value, 16) for row in ccm for value in row)
    fields.extend((value, 32) for value in offsets)
    return pack_fields(fields)


def directed_blc_vectors() -> list[int]:
    vectors: list[int] = []
    phase_distinct_black = (0, 1, 512, 1023)
    for pattern in range(4):
        for roi_x in range(2):
            for roi_y in range(2):
                for x_parity in range(2):
                    for y_parity in range(2):
                        for raw in (0, 1, 511, 512, 1022, 1023):
                            vectors.append(pack_blc_vector(
                                raw, x_parity, y_parity, pattern,
                                roi_x, roi_y, phase_distinct_black))

    boundary_cases = [
        (0, (0, 0, 0, 0)),
        (0, (1, 1, 1, 1)),
        (1, (0, 1, 2, 3)),
        (1022, (1023, 1022, 1021, 1020)),
        (1023, (0, 1, 1022, 1023)),
    ]
    for raw, black in boundary_cases:
        for phase_coordinate in ((0, 0), (1, 0), (0, 1), (1, 1)):
            vectors.append(pack_blc_vector(
                raw, phase_coordinate[0], phase_coordinate[1],
                0, 0, 0, black))
    return vectors


def directed_color_cases() -> list[
    tuple[
        tuple[int, int, int],
        tuple[int, int, int],
        tuple[tuple[int, int, int], tuple[int, int, int], tuple[int, int, int]],
        tuple[int, int, int],
    ]
]:
    identity = ((8192, 0, 0), (0, 8192, 0), (0, 0, 8192))
    zero = ((0, 0, 0), (0, 0, 0), (0, 0, 0))
    extreme = (
        (-32768, 32767, -1),
        (32767, -32768, 1),
        (-1, 1, 32767),
    )
    cases = []

    for rgb in (
        (0, 0, 0), (1, 1, 1), (511, 512, 513),
        (1022, 1023, 1022), (1023, 1023, 1023),
        (0, 512, 1023), (1023, 512, 0),
    ):
        for gains in (
            (0, 0, 0), (8192, 8192, 8192),
            (16384, 16384, 16384),
            (32768, 16384, 8192), (65535, 65535, 65535),
        ):
            cases.append((rgb, gains, identity, (0, 0, 0)))

    # Explicit signed Q13 midpoint, saturation, coefficient and offset limits.
    for offsets in (
        (-8193, -4096, -4095),
        (-1, 0, 1),
        (4095, 4096, 4097),
        (8191, 8192, 8193),
        (1023 << 13, 1024 << 13, 2048 << 13),
        (-(1 << 31), 0, (1 << 31) - 1),
    ):
        cases.append(((0, 0, 0), (16384, 16384, 16384), zero, offsets))
    cases.append(((1023, 1023, 1023), (65535, 65535, 65535),
                  extreme, (-(1 << 31), 0, (1 << 31) - 1)))
    cases.append(((1, 1, 1), (8192, 8192, 8192), identity,
                  (-4096, 4096, 0)))
    return cases


def generate(output_dir: Path, random_count: int, seed: int) -> dict[str, int]:
    if random_count < 10_000:
        raise ValueError("R1 ISP arithmetic regression requires at least 10000 random vectors")

    assert bayer_phase(0, 0, 0, 0, 0) == 0
    assert bayer_phase(1, 0, 0, 0, 0) == 1
    assert bayer_phase(0, 1, 0, 0, 0) == 2
    assert bayer_phase(1, 1, 0, 0, 0) == 3
    assert [bayer_phase(0, 0, code, 0, 0) for code in range(4)] == [0, 3, 1, 2]
    assert awb_u12(1, 8192) == 1
    assert round_shift_away(-4096, 13) == -1

    rng = random.Random(seed)
    gamma_rng = random.Random(seed ^ 0x47414D4D)
    gamma = [gamma_rng.randrange(256) for _ in range(1024)]
    # Pin endpoints and several recognizable addresses while retaining a
    # non-monotonic LUT that catches channel/address mix-ups.
    gamma[0] = 0x03
    gamma[1] = 0x81
    gamma[511] = 0x5A
    gamma[512] = 0xA5
    gamma[1022] = 0x7E
    gamma[1023] = 0xFC

    blc_vectors = directed_blc_vectors()
    for _ in range(random_count):
        raw = rng.randrange(1024)
        x = rng.randrange(1024)
        y = rng.randrange(512)
        pattern = rng.randrange(4)
        roi_x = rng.randrange(2)
        roi_y = rng.randrange(2)
        black = tuple(rng.randrange(1024) for _ in range(4))
        blc_vectors.append(pack_blc_vector(
            raw, x, y, pattern, roi_x, roi_y, black))

    color_vectors: list[tuple[int, int, int]] = []
    for rgb, gains, ccm, offsets in directed_color_cases():
        rgb_packed = (rgb[0] << 20) | (rgb[1] << 10) | rgb[2]
        config_packed = pack_color_config(gains, ccm, offsets)
        expected = color_pipeline(rgb, gains, ccm, offsets, gamma)
        expected_packed = (expected[0] << 16) | (expected[1] << 8) | expected[2]
        color_vectors.append((rgb_packed, config_packed, expected_packed))

    for index in range(random_count):
        rgb = tuple(rng.randrange(1024) for _ in range(3))
        gains = tuple(rng.randrange(1 << 16) for _ in range(3))
        ccm = tuple(
            tuple(rng.randint(-(1 << 15), (1 << 15) - 1) for _ in range(3))
            for _ in range(3)
        )
        offsets = tuple(rng.randint(-(1 << 31), (1 << 31) - 1)
                        for _ in range(3))

        # Every other constrained case produces more non-saturated values;
        # full-range cases continue to stress signed extrema and saturation.
        if index & 1:
            ccm = tuple(
                tuple(rng.randint(-4096, 4096) for _ in range(3))
                for _ in range(3)
            )
            offsets = tuple(rng.randint(-(1024 << 13), 1024 << 13)
                            for _ in range(3))

        rgb_packed = (rgb[0] << 20) | (rgb[1] << 10) | rgb[2]
        config_packed = pack_color_config(gains, ccm, offsets)
        expected = color_pipeline(rgb, gains, ccm, offsets, gamma)
        expected_packed = (expected[0] << 16) | (expected[1] << 8) | expected[2]
        color_vectors.append((rgb_packed, config_packed, expected_packed))

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "c1_r1_gamma_lut.txt").write_text(
        "1024\n" + "\n".join(f"{value:02x}" for value in gamma) + "\n",
        encoding="ascii",
    )
    (output_dir / "c1_r1_blc_vectors.txt").write_text(
        str(len(blc_vectors)) + "\n" +
        "\n".join(f"{value:022x}" for value in blc_vectors) + "\n",
        encoding="ascii",
    )
    (output_dir / "c1_r1_color_vectors.txt").write_text(
        str(len(color_vectors)) + "\n" +
        "\n".join(
            f"{rgb:08x} {config:072x} {expected:06x}"
            for rgb, config, expected in color_vectors
        ) + "\n",
        encoding="ascii",
    )

    summary = {
        "seed": seed,
        "random_count_per_primitive": random_count,
        "blc_vectors": len(blc_vectors),
        "color_vectors": len(color_vectors),
        "gamma_entries": len(gamma),
    }
    (output_dir / "c1_r1_isp_primitive_vectors.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="ascii"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--random-count", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()
    summary = generate(args.output_dir, args.random_count, args.seed)
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
