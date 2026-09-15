"""Generate bit-exact coordinate and arithmetic vectors for the R1 resize cores."""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


def round_div_away(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    magnitude = abs(numerator)
    quotient = (magnitude + denominator // 2) // denominator
    return -quotient if numerator < 0 else quotient


def pack_fields(fields: Iterable[tuple[int, int]]) -> int:
    packed = 0
    for value, width in fields:
        packed = (packed << width) | (value & ((1 << width) - 1))
    return packed


@dataclass(frozen=True)
class ResizeConfig:
    win: int
    hin: int
    wout: int
    hout: int
    x_step: int
    y_step: int
    x_phase0: int
    y_phase0: int


def center_config(win: int, hin: int, wout: int, hout: int) -> ResizeConfig:
    return ResizeConfig(
        win=win,
        hin=hin,
        wout=wout,
        hout=hout,
        x_step=round_div_away(win << 16, wout),
        y_step=round_div_away(hin << 16, hout),
        x_phase0=round_div_away((win - wout) << 15, wout),
        y_phase0=round_div_away((hin - hout) << 15, hout),
    )


def q16_axis(phase: int, limit: int) -> tuple[int, int, int, int]:
    floor_index = phase // 65536
    fraction = phase - floor_index * 65536
    weight1 = min(4096, (fraction + 8) >> 4)
    weight0 = 4096 - weight1
    index0 = max(0, min(limit - 1, floor_index))
    index1 = max(0, min(limit - 1, floor_index + 1))
    return index0, index1, weight0, weight1


def generate_requests(config: ResizeConfig) -> list[int]:
    requests: list[int] = []
    for out_y in range(config.hout):
        phase_y = config.y_phase0 + out_y * config.y_step
        y0, y1, wy0, wy1 = q16_axis(phase_y, config.hin)
        for out_x in range(config.wout):
            phase_x = config.x_phase0 + out_x * config.x_step
            x0, x1, wx0, wx1 = q16_axis(phase_x, config.win)
            last = int(out_x == config.wout - 1 and out_y == config.hout - 1)
            requests.append(pack_fields([
                (out_x, 16), (out_y, 16),
                (x0, 16), (x1, 16), (y0, 16), (y1, 16),
                (wx0, 13), (wx1, 13), (wy0, 13), (wy1, 13),
                (last, 1),
            ]))
    return requests


def channel_pair(a: int, b: int, weight0: int, weight1: int) -> int:
    return (weight0 * a + weight1 * b + 2048) >> 12


def unpack_rgb(rgb: int) -> tuple[int, int, int]:
    return (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF


def interpolate_rgb(
    p00: int,
    p01: int,
    p10: int,
    p11: int,
    wx0: int,
    wx1: int,
    wy0: int,
    wy1: int,
) -> int:
    result = []
    for c00, c01, c10, c11 in zip(
        unpack_rgb(p00), unpack_rgb(p01), unpack_rgb(p10), unpack_rgb(p11)
    ):
        horizontal0 = channel_pair(c00, c01, wx0, wx1)
        horizontal1 = channel_pair(c10, c11, wx0, wx1)
        result.append(channel_pair(horizontal0, horizontal1, wy0, wy1))
    return (result[0] << 16) | (result[1] << 8) | result[2]


def pack_interp_vector(
    p00: int,
    p01: int,
    p10: int,
    p11: int,
    wx1: int,
    wy1: int,
) -> int:
    wx0 = 4096 - wx1
    wy0 = 4096 - wy1
    expected = interpolate_rgb(p00, p01, p10, p11, wx0, wx1, wy0, wy1)
    return pack_fields([
        (p00, 24), (p01, 24), (p10, 24), (p11, 24),
        (wx0, 13), (wx1, 13), (wy0, 13), (wy1, 13),
        (expected, 24),
    ])


def build_configs(rng: random.Random) -> list[ResizeConfig]:
    # Explicit ratio/shape coverage: 1:1, 2:1, 3:2, non-integer,
    # upsampling with negative center phase, and odd/even edge cases.
    dimensions = [
        (1, 1, 1, 1),
        (4, 3, 4, 3),             # 1:1
        (8, 6, 4, 3),             # 2:1
        (9, 6, 6, 4),             # 3:2
        (7, 5, 4, 3),             # non-integer
        (13, 9, 8, 5),            # non-integer odd/even
        (3, 2, 6, 4),             # negative phase, 2x upsample
        (5, 3, 8, 7),             # negative phase, non-integer upsample
        (2, 3, 5, 4),
        (5, 4, 2, 3),
        (17, 13, 11, 7),
        (16, 15, 7, 12),
    ]
    configs = [center_config(*values) for values in dimensions]

    # Deliberately more negative phase origins exercise multi-pixel clamping.
    configs.extend([
        ResizeConfig(5, 4, 7, 6, 49152, 43691, -98304, -81920),
        ResizeConfig(9, 7, 5, 4, 117965, 114688, -32769, -65537),
    ])

    for _ in range(36):
        win = rng.randint(1, 31)
        hin = rng.randint(1, 23)
        wout = rng.randint(1, 20)
        hout = rng.randint(1, 16)
        configs.append(center_config(win, hin, wout, hout))
    return configs


def directed_interp_vectors() -> list[int]:
    pixels = [
        (0x000000, 0x000000, 0x000000, 0x000000),
        (0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF),
        (0x000000, 0xFFFFFF, 0xFFFFFF, 0x000000),
        (0x010203, 0xFEFDFC, 0x804020, 0x7FBFDF),
        (0x000001, 0x000000, 0x000000, 0x000000),
        (0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF),
    ]
    weights = [0, 1, 8, 16, 2047, 2048, 2049, 4080, 4088, 4095, 4096]
    return [pack_interp_vector(*sample_set, wx1, wy1)
            for sample_set in pixels for wx1 in weights for wy1 in weights]


def generate(output_dir: Path, random_count: int, seed: int) -> dict[str, int]:
    if random_count < 10_000:
        raise ValueError("resize arithmetic regression requires at least 10000 random vectors")
    assert round_div_away(3, 2) == 2
    assert round_div_away(-3, 2) == -2
    assert q16_axis(-16384, 3) == (0, 0, 1024, 3072)
    assert channel_pair(0, 1, 2048, 2048) == 1

    rng = random.Random(seed)
    configs = build_configs(rng)
    requests: list[int] = []
    config_rows: list[tuple[ResizeConfig, int, int]] = []
    for config in configs:
        start = len(requests)
        generated = generate_requests(config)
        requests.extend(generated)
        config_rows.append((config, start, len(generated)))

    interp_vectors = directed_interp_vectors()
    for _ in range(random_count):
        samples = [rng.randrange(1 << 24) for _ in range(4)]
        wx1 = rng.randrange(4097)
        wy1 = rng.randrange(4097)
        interp_vectors.append(pack_interp_vector(*samples, wx1, wy1))

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "c1_r1_resize_configs.txt").write_text(
        str(len(config_rows)) + "\n" +
        "\n".join(
            f"{config.win:04x} {config.hin:04x} "
            f"{config.wout:04x} {config.hout:04x} "
            f"{config.x_step & 0xFFFFFFFF:08x} "
            f"{config.y_step & 0xFFFFFFFF:08x} "
            f"{config.x_phase0 & 0xFFFFFFFF:08x} "
            f"{config.y_phase0 & 0xFFFFFFFF:08x} {start:d} {count:d}"
            for config, start, count in config_rows
        ) + "\n",
        encoding="ascii",
    )
    (output_dir / "c1_r1_resize_requests.txt").write_text(
        str(len(requests)) + "\n" +
        "\n".join(f"{request:038x}" for request in requests) + "\n",
        encoding="ascii",
    )
    (output_dir / "c1_r1_resize_interp_vectors.txt").write_text(
        str(len(interp_vectors)) + "\n" +
        "\n".join(f"{vector:043x}" for vector in interp_vectors) + "\n",
        encoding="ascii",
    )

    summary = {
        "seed": seed,
        "configs": len(config_rows),
        "requests": len(requests),
        "interpolation_vectors": len(interp_vectors),
        "random_interpolation_vectors": random_count,
    }
    (output_dir / "c1_r1_resize_primitive_vectors.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="ascii"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--random-count", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()
    print(json.dumps(generate(args.output_dir, args.random_count, args.seed),
                     sort_keys=True))


if __name__ == "__main__":
    main()
