"""Generate bit-exact C8 3x3 replicate-SAME window vectors."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random


MAX_WIDTH = 640
FRAME_CONFIGS = (
    (1, 1, 1),
    (1, 5, 1),       # 1xN
    (5, 1, 1),       # Nx1
    (3, 3, 1),       # odd W/H
    (4, 2, 1),       # even W/H
    (5, 4, 2),       # odd W, even H, stride 2
    (4, 5, 2),       # even W, odd H, stride 2
    (MAX_WIDTH, 2, 2),
    (7, 6, 1),       # additional random-stall coverage
    (1, 1, 2),       # degenerate stride-2 replay/flush boundaries
    (1, 5, 2),
    (5, 1, 2),
    (2, 2, 2),
    (MAX_WIDTH, 3, 1),  # full-width right/bottom edge and bank rotation
)


def clamp(value: int, low: int, high: int) -> int:
    return min(max(value, low), high)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    input_pixels: list[int] = []
    expected_windows: list[int] = []
    frame_records: list[int] = []

    for frame_index, (width, height, stride) in enumerate(FRAME_CONFIGS):
        input_offset = len(input_pixels)
        output_offset = len(expected_windows)
        frame: list[list[int]] = []
        for y in range(height):
            row: list[int] = []
            for x in range(width):
                pixel = rng.getrandbits(64)
                pixel ^= (frame_index & 0xFF) << 56
                pixel ^= (y & 0xFF) << 40
                pixel ^= (x & 0xFFFF) << 8
                pixel &= (1 << 64) - 1
                row.append(pixel)
                input_pixels.append(pixel)
            frame.append(row)

        for center_y in range(0, height, stride):
            for center_x in range(0, width, stride):
                packed_window = 0
                tap_index = 0
                for delta_y in (-1, 0, 1):
                    sample_y = clamp(center_y + delta_y, 0, height - 1)
                    for delta_x in (-1, 0, 1):
                        sample_x = clamp(center_x + delta_x, 0, width - 1)
                        packed_window |= (
                            frame[sample_y][sample_x] << (64 * tap_index)
                        )
                        tap_index += 1
                expected_windows.append(packed_window)

        record = (
            (frame_index << 104)
            | (stride << 96)
            | (height << 80)
            | (width << 64)
            | (output_offset << 32)
            | input_offset
        )
        frame_records.append(record)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with (args.output_dir / "window3x3_same_c8_frames.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for record in frame_records:
            stream.write(f"{record:032x}\n")
    with (args.output_dir / "window3x3_same_c8_input.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for pixel in input_pixels:
            stream.write(f"{pixel:016x}\n")
    with (args.output_dir / "window3x3_same_c8_expected.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for window in expected_windows:
            stream.write(f"{window:0144x}\n")

    manifest = {
        "schema_version": 1,
        "seed": args.seed,
        "max_width": MAX_WIDTH,
        "frames": len(FRAME_CONFIGS),
        "frame_configs": [list(config) for config in FRAME_CONFIGS],
        "input_pixels": len(input_pixels),
        "output_windows": len(expected_windows),
        "line_buffer_bytes": 2 * MAX_WIDTH * 8,
    }
    (args.output_dir / "window3x3_same_c8_vectors.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "C1_WINDOW3X3_SAME_C8_VECTOR_GEN_PASS "
        f"frames={len(FRAME_CONFIGS)} input={len(input_pixels)} "
        f"output={len(expected_windows)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
