"""Generate deterministic bit-exact vectors for the R1 CNN arithmetic primitives."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path


ACT_NONE = 0
ACT_RELU = 1


def round_shift_away(value: int, shift: int) -> int:
    if not 0 <= shift <= 47:
        raise ValueError(f"R1 requant shift must be 0..47, got {shift}")
    if shift == 0:
        return value
    magnitude = abs(value)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return -rounded if value < 0 else rounded


def sat_s8(value: int) -> int:
    return max(-128, min(127, value))


def requant_s8(acc: int, mult: int, shift: int, activation: int) -> int:
    if not -(1 << 31) <= acc < (1 << 31):
        raise ValueError("acc is outside signed32")
    if not -(1 << 17) <= mult < (1 << 17):
        raise ValueError("mult is outside signed18")
    product = acc * mult
    quantized = sat_s8(round_shift_away(product, shift))
    if activation == ACT_RELU:
        return max(quantized, 0)
    if activation != ACT_NONE:
        raise ValueError(f"unsupported activation {activation}")
    return quantized


def residual_add_s8(main: int, skip: int, relu: int) -> int:
    if not -128 <= main <= 127 or not -128 <= skip <= 127:
        raise ValueError("residual inputs must be signed8")
    result = sat_s8(main + skip)
    return max(result, 0) if relu else result


def directed_requant_vectors() -> list[tuple[int, int, int, int, int]]:
    cases: list[tuple[int, int, int, int]] = []

    # Zero, sign, exact integer and positive/negative midpoint behavior.
    for value in (0, 1, -1, 2, -2, 3, -3, 7, -7, 15, -15):
        for shift in (0, 1, 2, 3):
            for activation in (ACT_NONE, ACT_RELU):
                cases.append((value, 1, shift, activation))

    # Saturation boundaries and their immediate neighbors.
    for value in (-260, -130, -129, -128, -127, -126,
                  -1, 0, 1, 125, 126, 127, 128, 129, 255):
        for activation in (ACT_NONE, ACT_RELU):
            cases.append((value, 1, 0, activation))

    # Full signed32/signed18 extrema, sign combinations and shift endpoints.
    for acc in (-(1 << 31), -(1 << 31) + 1, -1, 0, 1,
                (1 << 31) - 2, (1 << 31) - 1):
        for mult in (-(1 << 17), -(1 << 17) + 1, -1, 0, 1,
                     (1 << 17) - 2, (1 << 17) - 1):
            for shift in (0, 1, 31, 46, 47):
                cases.append((acc, mult, shift, ACT_NONE))
                cases.append((acc, mult, shift, ACT_RELU))

    # Exact +/- half cases at the maximum legal shift: +/-2^46 / 2^47.
    cases.extend(
        [
            (1 << 30, 1 << 16, 47, ACT_NONE),
            (-(1 << 30), 1 << 16, 47, ACT_NONE),
            (1 << 30, -(1 << 16), 47, ACT_NONE),
            (-(1 << 30), -(1 << 16), 47, ACT_NONE),
        ]
    )

    return [
        (acc, mult, shift, activation,
         requant_s8(acc, mult, shift, activation))
        for acc, mult, shift, activation in cases
    ]


def directed_residual_vectors() -> list[tuple[int, int, int, int]]:
    cases: list[tuple[int, int, int]] = []
    interesting = (-128, -127, -2, -1, 0, 1, 2, 126, 127)
    for main in interesting:
        for skip in interesting:
            for relu in (0, 1):
                cases.append((main, skip, relu))

    # Explicit sums around both signed8 saturation limits.
    cases.extend(
        [
            (-128, -128, 0), (-128, -1, 0), (-127, -1, 0),
            (-126, -1, 0), (63, 63, 0), (64, 63, 0),
            (64, 64, 0), (127, 127, 0),
            (-128, -128, 1), (-128, -1, 1), (-127, -1, 1),
            (-126, -1, 1), (63, 63, 1), (64, 63, 1),
            (64, 64, 1), (127, 127, 1),
        ]
    )
    return [
        (main, skip, relu, residual_add_s8(main, skip, relu))
        for main, skip, relu in cases
    ]


def write_requant(path: Path, vectors: list[tuple[int, int, int, int, int]]) -> None:
    lines = [str(len(vectors))]
    lines.extend(
        f"{acc & 0xFFFFFFFF:08x} {mult & 0x3FFFF:05x} "
        f"{shift:02x} {activation:x} {expected & 0xFF:02x}"
        for acc, mult, shift, activation, expected in vectors
    )
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_residual(path: Path, vectors: list[tuple[int, int, int, int]]) -> None:
    lines = [str(len(vectors))]
    lines.extend(
        f"{main & 0xFF:02x} {skip & 0xFF:02x} {relu:x} {expected & 0xFF:02x}"
        for main, skip, relu, expected in vectors
    )
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def generate(output_dir: Path, random_count: int, seed: int) -> dict[str, int]:
    if random_count < 1000:
        raise ValueError("at least 1000 random vectors are required")

    # Small self-checks pin the most error-prone signed midpoint cases.
    assert round_shift_away(1, 1) == 1
    assert round_shift_away(-1, 1) == -1
    assert round_shift_away(3, 1) == 2
    assert round_shift_away(-3, 1) == -2
    assert requant_s8(1 << 30, 1 << 16, 47, ACT_NONE) == 1
    assert requant_s8(-(1 << 30), 1 << 16, 47, ACT_NONE) == -1
    assert residual_add_s8(127, 127, 0) == 127
    assert residual_add_s8(-128, -128, 1) == 0

    rng = random.Random(seed)
    requant = directed_requant_vectors()
    residual = directed_residual_vectors()

    for _ in range(random_count):
        acc = rng.randint(-(1 << 31), (1 << 31) - 1)
        mult = rng.randint(-(1 << 17), (1 << 17) - 1)
        shift = rng.randint(0, 47)
        activation = rng.randint(ACT_NONE, ACT_RELU)
        requant.append(
            (acc, mult, shift, activation,
             requant_s8(acc, mult, shift, activation))
        )

    for _ in range(random_count):
        main = rng.randint(-128, 127)
        skip = rng.randint(-128, 127)
        relu = rng.randint(0, 1)
        residual.append((main, skip, relu,
                         residual_add_s8(main, skip, relu)))

    output_dir.mkdir(parents=True, exist_ok=True)
    write_requant(output_dir / "c1_requant_s8_vectors.txt", requant)
    write_residual(output_dir / "c1_residual_add_s8_vectors.txt", residual)
    summary = {
        "seed": seed,
        "random_count_per_primitive": random_count,
        "requant_vectors": len(requant),
        "residual_vectors": len(residual),
    }
    (output_dir / "c1_r1_cnn_primitive_vectors.json").write_text(
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
