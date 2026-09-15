"""Generate the standalone 640x480 R0 CNN full-frame regression vectors.

The source image is the scikit-image ``astronaut`` sample already recorded in
``assets/SOURCES.md``.  This script deliberately writes to a separate vector
directory so the fast, small default RTL regression remains unchanged.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from style_pipeline import load_rgb, resize_nearest_u8, tiny_style_infer, write_hex_rgb24


FRAME_WIDTH = 640
FRAME_HEIGHT = 480
OUTPUT_WIDTH = FRAME_WIDTH - 4
OUTPUT_HEIGHT = FRAME_HEIGHT - 4

CASE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_IMAGE = CASE_ROOT / "assets" / "images" / "astronaut.png"
DEFAULT_OUTPUT = CASE_ROOT / "sim" / "vectors_fullframe"


def generate(image_path: Path, output_dir: Path) -> dict[str, object]:
    started = time.perf_counter()
    source = load_rgb(image_path)
    resized = resize_nearest_u8(source, FRAME_WIDTH, FRAME_HEIGHT)
    expected, _ = tiny_style_infer(resized)

    if resized.shape != (FRAME_HEIGHT, FRAME_WIDTH, 3):
        raise AssertionError(f"unexpected input tensor shape: {resized.shape}")
    if expected.shape != (OUTPUT_HEIGHT, OUTPUT_WIDTH, 3):
        raise AssertionError(f"unexpected output tensor shape: {expected.shape}")

    output_dir.mkdir(parents=True, exist_ok=True)
    input_name = "cnn_input_rgb24.hex"
    expected_name = "cnn_expected_rgb24.hex"
    write_hex_rgb24(output_dir / input_name, resized)
    write_hex_rgb24(output_dir / expected_name, expected)

    try:
        source_name = image_path.resolve().relative_to(CASE_ROOT).as_posix()
    except ValueError:
        source_name = str(image_path.resolve())

    manifest: dict[str, object] = {
        "model": "R0 diagnostic CNN / vivid_paint",
        "source": source_name,
        "source_size": [int(source.shape[1]), int(source.shape[0])],
        "resize": "integer pixel-centre nearest-neighbour",
        "input_width": FRAME_WIDTH,
        "input_height": FRAME_HEIGHT,
        "input_pixels": FRAME_WIDTH * FRAME_HEIGHT,
        "output_width": OUTPUT_WIDTH,
        "output_height": OUTPUT_HEIGHT,
        "output_pixels": OUTPUT_WIDTH * OUTPUT_HEIGHT,
        "output_coordinate_bounds": {
            "x_min": 2,
            "x_max": FRAME_WIDTH - 3,
            "y_min": 2,
            "y_max": FRAME_HEIGHT - 3,
        },
        "data_format": "RGB24 RRGGBB, one raster-order pixel per ASCII-hex line",
        "files": {
            "input": input_name,
            "expected": expected_name,
        },
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    elapsed = time.perf_counter() - started
    print(
        "FULLFRAME_VECTORS_OK "
        f"input={FRAME_WIDTH * FRAME_HEIGHT} "
        f"output={OUTPUT_WIDTH * OUTPUT_HEIGHT} "
        f"elapsed_seconds={elapsed:.3f} directory={output_dir}"
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    if not args.image.is_file():
        raise SystemExit(f"source image does not exist: {args.image}")
    generate(args.image, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
