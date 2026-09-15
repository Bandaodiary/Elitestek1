"""Generate deterministic bit-exact vectors for the R1 dot8 and requant-bank cores."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Iterable


ACT_NONE = 0
ACT_RELU = 1
S32_MIN = -(1 << 31)
S32_MAX = (1 << 31) - 1


def pack_fields(fields: Iterable[tuple[int, int]]) -> int:
    value = 0
    for field, width in fields:
        value = (value << width) | (field & ((1 << width) - 1))
    return value


def pack_lanes(values: Iterable[int], width: int) -> int:
    packed = 0
    for lane, value in enumerate(values):
        packed |= (value & ((1 << width) - 1)) << (lane * width)
    return packed


def dot8(activations: list[int], weights: list[int], mask: int) -> int:
    return sum(a * w for lane, (a, w) in enumerate(zip(activations, weights))
               if (mask >> lane) & 1)


def round_shift_away(value: int, shift: int) -> int:
    if shift == 0:
        return value
    magnitude = abs(value)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return -rounded if value < 0 else rounded


def requant(acc: int, mult: int, shift: int, activation: int) -> int:
    value = round_shift_away(acc * mult, shift)
    value = max(-128, min(127, value))
    return max(value, 0) if activation == ACT_RELU else value


def append_dot_sequence(
    output: list[int],
    beats: list[tuple[list[int], list[int], int]],
    bias: int,
) -> None:
    accumulator = bias
    for index, (activations, weights, mask) in enumerate(beats):
        accumulator += dot8(activations, weights, mask)
        if not S32_MIN <= accumulator <= S32_MAX:
            raise ValueError("generated dot sequence overflows signed32")
        output.append(pack_fields([
            (pack_lanes(activations, 8), 64),
            (pack_lanes(weights, 8), 64),
            (mask, 8),
            (int(index == 0), 1),
            (int(index == len(beats) - 1), 1),
            (bias, 32),
            (accumulator, 32),
        ]))


def directed_dot_vectors() -> tuple[list[int], int]:
    vectors: list[int] = []
    sequences = 0
    masks = [0x00, 0x01, 0x03, 0x07, 0x0F, 0x1F,
             0x3F, 0x7F, 0xFF, 0x55, 0xAA, 0x80]
    patterns = [
        ([127] * 8, [127] * 8),
        ([-128] * 8, [127] * 8),
        ([127, -128] * 4, [-127, 127] * 4),
        ([-1, 0, 1, 2, -2, 126, -127, 127],
         [1, -1, 2, -2, 127, -127, 3, -3]),
    ]
    for mask in masks:
        for activations, weights in patterns:
            append_dot_sequence(vectors, [(activations, weights, mask)], 0)
            sequences += 1

    positive_dot = dot8([127] * 8, [127] * 8, 0xFF)
    negative_dot = dot8([-128] * 8, [127] * 8, 0xFF)
    append_dot_sequence(vectors, [([127] * 8, [127] * 8, 0xFF)],
                        S32_MAX - positive_dot)
    append_dot_sequence(vectors, [([-128] * 8, [127] * 8, 0xFF)],
                        S32_MIN - negative_dot)
    sequences += 2

    append_dot_sequence(
        vectors,
        [
            ([127] * 8, [-127] * 8, 0xFF),
            ([-128] * 8, [-127] * 8, 0x07),
            ([1, 2, 3, 4, 5, 6, 7, 8], [8, 7, 6, 5, 4, 3, 2, 1], 0x1F),
        ],
        123456,
    )
    sequences += 1
    return vectors, sequences


def directed_bank_vectors() -> list[int]:
    vectors: list[int] = []
    acc_patterns = [
        [S32_MIN, S32_MIN + 1, -129, -128, -1, 0, 127, S32_MAX],
        [-7, -3, -1, 1, 3, 7, 127, 128],
        [1 << 30, -(1 << 30), 4096, -4096, 8192, -8192, 0, 1],
    ]
    mult_patterns = [
        [1] * 8,
        [-(1 << 17), -(1 << 17) + 1, -1, 0, 1,
         (1 << 17) - 2, (1 << 17) - 1, 1 << 16],
        [1 << 16] * 8,
    ]
    shift_patterns = [
        [0] * 8,
        [0, 1, 2, 3, 31, 46, 47, 47],
        [47] * 8,
    ]
    for accs in acc_patterns:
        for mults in mult_patterns:
            for shifts in shift_patterns:
                for activation_base in (ACT_NONE, ACT_RELU):
                    activations = [(activation_base + lane) & 1 for lane in range(8)]
                    expected = [requant(a, m, s, act)
                                for a, m, s, act in zip(accs, mults, shifts, activations)]
                    vectors.append(pack_fields([
                        (pack_lanes(accs, 32), 256),
                        (pack_lanes(mults, 18), 144),
                        (pack_lanes(shifts, 6), 48),
                        (pack_lanes(activations, 2), 16),
                        (pack_lanes(expected, 8), 64),
                    ]))
    return vectors


def generate(output_dir: Path, random_count: int, seed: int) -> dict[str, int]:
    if random_count < 10_000:
        raise ValueError("at least 10000 random dot beats/bank vectors are required")
    assert dot8([127] * 8, [127] * 8, 0x01) == 16129
    assert round_shift_away(1, 1) == 1
    assert round_shift_away(-1, 1) == -1
    assert requant(-(1 << 30), 1 << 16, 47, ACT_NONE) == -1

    rng = random.Random(seed)
    dot_vectors, dot_sequences = directed_dot_vectors()
    random_dot_beats = 0
    while random_dot_beats < random_count:
        length = min(rng.randint(1, 6), random_count - random_dot_beats)
        beats: list[tuple[list[int], list[int], int]] = []
        for beat_index in range(length):
            activations = [rng.randint(-128, 127) for _ in range(8)]
            weights = [rng.randint(-127, 127) for _ in range(8)]
            if beat_index == length - 1 and rng.random() < 0.65:
                tail = rng.randint(0, 8)
                mask = (1 << tail) - 1
            else:
                mask = rng.randrange(256)
            beats.append((activations, weights, mask))
        append_dot_sequence(dot_vectors, beats, rng.randint(-1_000_000_000, 1_000_000_000))
        random_dot_beats += length
        dot_sequences += 1

    bank_vectors = directed_bank_vectors()
    for _ in range(random_count):
        accs = [rng.randint(S32_MIN, S32_MAX) for _ in range(8)]
        mults = [rng.randint(-(1 << 17), (1 << 17) - 1) for _ in range(8)]
        shifts = [rng.randint(0, 47) for _ in range(8)]
        activations = [rng.randint(ACT_NONE, ACT_RELU) for _ in range(8)]
        expected = [requant(a, m, s, act)
                    for a, m, s, act in zip(accs, mults, shifts, activations)]
        bank_vectors.append(pack_fields([
            (pack_lanes(accs, 32), 256),
            (pack_lanes(mults, 18), 144),
            (pack_lanes(shifts, 6), 48),
            (pack_lanes(activations, 2), 16),
            (pack_lanes(expected, 8), 64),
        ]))

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "c1_r1_dot8_vectors.txt").write_text(
        str(len(dot_vectors)) + "\n" +
        "\n".join(f"{vector:051x}" for vector in dot_vectors) + "\n",
        encoding="ascii",
    )
    (output_dir / "c1_r1_requant_bank8_vectors.txt").write_text(
        str(len(bank_vectors)) + "\n" +
        "\n".join(f"{vector:0132x}" for vector in bank_vectors) + "\n",
        encoding="ascii",
    )
    summary = {
        "seed": seed,
        "dot_beats": len(dot_vectors),
        "dot_sequences": dot_sequences,
        "random_dot_beats": random_dot_beats,
        "bank_vectors": len(bank_vectors),
        "random_bank_vectors": random_count,
    }
    (output_dir / "c1_r1_cnn_bank_vectors.json").write_text(
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
