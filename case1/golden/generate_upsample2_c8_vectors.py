"""Generate deterministic C8 nearest-neighbour x2 upsample vectors."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random


MAX_WIDTH = 640
FRAME_SHAPES = (
    (1, 1),       # single-pixel read/write-address corner case
    (5, 3),       # odd width and height
    (8, 2),       # even width
    (MAX_WIDTH, 2),
    (3, 2),       # back-to-back short frames
    (4, 1),
    (17, 4),      # additional random-stall payload coverage
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    input_pixels: list[int] = []
    expected_pixels: list[int] = []
    frame_records: list[int] = []

    for frame_index, (width, height) in enumerate(FRAME_SHAPES):
        input_offset = len(input_pixels)
        output_offset = len(expected_pixels)
        frame: list[list[int]] = []
        for y in range(height):
            row: list[int] = []
            for x in range(width):
                # Exercise all signed-int8 bit patterns without imposing a
                # numerical interpretation on this pure nearest-neighbour op.
                pixel = rng.getrandbits(64)
                pixel ^= (frame_index & 0xFF) << 56
                pixel ^= (y & 0xFF) << 40
                pixel ^= (x & 0xFF) << 8
                pixel &= (1 << 64) - 1
                row.append(pixel)
                input_pixels.append(pixel)
            frame.append(row)

        for row in frame:
            doubled_row = [pixel for pixel in row for _ in range(2)]
            expected_pixels.extend(doubled_row)
            expected_pixels.extend(doubled_row)

        record = (
            (frame_index << 96)
            | (height << 80)
            | (width << 64)
            | (output_offset << 32)
            | input_offset
        )
        frame_records.append(record)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with (args.output_dir / "upsample2_c8_frames.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for record in frame_records:
            stream.write(f"{record:032x}\n")
    with (args.output_dir / "upsample2_c8_input.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for pixel in input_pixels:
            stream.write(f"{pixel:016x}\n")
    with (args.output_dir / "upsample2_c8_expected.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for pixel in expected_pixels:
            stream.write(f"{pixel:016x}\n")

    manifest = {
        "schema_version": 1,
        "seed": args.seed,
        "max_width": MAX_WIDTH,
        "frames": len(FRAME_SHAPES),
        "frame_shapes": [list(shape) for shape in FRAME_SHAPES],
        "input_pixels": len(input_pixels),
        "output_pixels": len(expected_pixels),
        "line_buffer_bytes": MAX_WIDTH * 8,
    }
    (args.output_dir / "upsample2_c8_vectors.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "C1_UPSAMPLE2_C8_VECTOR_GEN_PASS "
        f"frames={len(FRAME_SHAPES)} input={len(input_pixels)} "
        f"output={len(expected_pixels)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

