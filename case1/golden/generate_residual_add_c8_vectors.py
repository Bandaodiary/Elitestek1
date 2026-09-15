"""Generate deterministic C8 saturated residual-add vectors."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random


FRAME_CONFIGS = (
    (1, 1, 0),
    (5, 3, 0),
    (4, 4, 1),
    (7, 5, 0),
    (3, 6, 1),
    (8, 8, 1),
)

DIRECTED_LANES = (
    (127, 127),
    (-128, -128),
    (127, -128),
    (-128, 127),
    (127, 1),
    (-128, -1),
    (0, -128),
    (0, 127),
)


def saturate_relu(main: int, skip: int, relu: int) -> int:
    value = main + skip
    value = max(-128, min(127, value))
    if relu and value < 0:
        value = 0
    return value


def pack_s8(values: list[int]) -> int:
    packed = 0
    for lane, value in enumerate(values):
        packed |= (value & 0xFF) << (8 * lane)
    return packed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    main_pixels: list[int] = []
    skip_pixels: list[int] = []
    expected_pixels: list[int] = []
    frame_records: list[int] = []

    for frame_index, (width, height, relu) in enumerate(FRAME_CONFIGS):
        pixel_offset = len(main_pixels)
        pixel_count = width * height
        for pixel_index in range(pixel_count):
            main_lanes: list[int] = []
            skip_lanes: list[int] = []
            expected_lanes: list[int] = []
            for lane in range(8):
                if pixel_index == 0:
                    main_value, skip_value = DIRECTED_LANES[lane]
                elif pixel_index == 1:
                    main_value, skip_value = DIRECTED_LANES[7 - lane]
                else:
                    main_value = rng.randint(-128, 127)
                    skip_value = rng.randint(-128, 127)
                main_lanes.append(main_value)
                skip_lanes.append(skip_value)
                expected_lanes.append(
                    saturate_relu(main_value, skip_value, relu)
                )
            main_pixels.append(pack_s8(main_lanes))
            skip_pixels.append(pack_s8(skip_lanes))
            expected_pixels.append(pack_s8(expected_lanes))

        record = (
            (frame_index << 104)
            | (relu << 96)
            | (height << 80)
            | (width << 64)
            | (pixel_count << 32)
            | pixel_offset
        )
        frame_records.append(record)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with (args.output_dir / "residual_add_c8_frames.mem").open(
        "w", encoding="ascii", newline="\n"
    ) as stream:
        for record in frame_records:
            stream.write(f"{record:032x}\n")
    for filename, values in (
        ("residual_add_c8_main.mem", main_pixels),
        ("residual_add_c8_skip.mem", skip_pixels),
        ("residual_add_c8_expected.mem", expected_pixels),
    ):
        with (args.output_dir / filename).open(
            "w", encoding="ascii", newline="\n"
        ) as stream:
            for value in values:
                stream.write(f"{value:016x}\n")

    manifest = {
        "schema_version": 1,
        "seed": args.seed,
        "frames": len(FRAME_CONFIGS),
        "frame_configs": [list(config) for config in FRAME_CONFIGS],
        "pixels": len(main_pixels),
        "directed_lane_pairs": [list(pair) for pair in DIRECTED_LANES],
        "arithmetic": "signed9 add, signed8 saturation, optional ReLU after saturation",
    }
    (args.output_dir / "residual_add_c8_vectors.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "C1_RESIDUAL_ADD_C8_VECTOR_GEN_PASS "
        f"frames={len(FRAME_CONFIGS)} pixels={len(main_pixels)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

