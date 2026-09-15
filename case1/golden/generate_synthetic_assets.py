#!/usr/bin/env python3
"""Generate deterministic RGB test images for Golden/RTL regression.

The output is deliberately composed only of synthetic arrays. It can therefore
be regenerated offline without relying on a third-party image or network source.
All images are lossless RGB PNG files, including nominally grayscale patterns,
so that image readers exercise the same three-channel input path.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image


DEFAULT_SIZES = (
    (1, 1),
    (2, 2),
    (3, 3),
    (7, 5),
    (8, 6),
    (16, 16),
    (17, 13),
    (64, 48),
    (65, 49),
)
DEFAULT_SEED = 0xC12026


def _solid(width: int, height: int, value: int) -> np.ndarray:
    return np.full((height, width, 3), value, dtype=np.uint8)


def _rgb_bars(width: int, height: int) -> np.ndarray:
    # Full-amplitude bars. Integer mapping is deterministic even when the image
    # is narrower than the number of bars.
    colors = np.asarray(
        [
            (255, 255, 255),
            (255, 255, 0),
            (0, 255, 255),
            (0, 255, 0),
            (255, 0, 255),
            (255, 0, 0),
            (0, 0, 255),
            (0, 0, 0),
        ],
        dtype=np.uint8,
    )
    indices = np.minimum(
        (np.arange(width, dtype=np.uint32) * len(colors)) // width,
        len(colors) - 1,
    )
    row = colors[indices]
    return np.broadcast_to(row, (height, width, 3)).copy()


def _ramp_axis(length: int) -> np.ndarray:
    if length == 1:
        return np.zeros(1, dtype=np.uint8)
    positions = np.arange(length, dtype=np.uint32)
    return ((positions * 255 + (length - 1) // 2) // (length - 1)).astype(np.uint8)


def _ramp_horizontal(width: int, height: int) -> np.ndarray:
    values = _ramp_axis(width)
    row = np.repeat(values[:, None], 3, axis=1)
    return np.broadcast_to(row, (height, width, 3)).copy()


def _ramp_vertical(width: int, height: int) -> np.ndarray:
    values = _ramp_axis(height)
    plane = np.broadcast_to(values[:, None], (height, width))
    return np.repeat(plane[:, :, None], 3, axis=2).copy()


def _checkerboard(width: int, height: int, tile: int) -> np.ndarray:
    yy, xx = np.indices((height, width), dtype=np.uint32)
    values = ((((xx // tile) + (yy // tile)) & 1) * 255).astype(np.uint8)
    return np.repeat(values[:, :, None], 3, axis=2)


def _impulse_center(width: int, height: int) -> np.ndarray:
    image = np.zeros((height, width, 3), dtype=np.uint8)
    # For even dimensions, choose the lower/right member of the two central
    # pixels. This convention is explicit so RTL tests can match it.
    image[height // 2, width // 2] = 255
    return image


def _random_rgb(width: int, height: int, base_seed: int) -> np.ndarray:
    # Give every dimension its own deterministic PCG64 stream. Adding another
    # size later therefore cannot alter existing random images.
    image_seed = (base_seed + width * 1009 + height * 9176) & ((1 << 64) - 1)
    rng = np.random.Generator(np.random.PCG64(image_seed))
    return rng.integers(0, 256, size=(height, width, 3), dtype=np.uint8)


def _parse_size(value: str) -> tuple[int, int]:
    try:
        width_text, height_text = value.lower().split("x", maxsplit=1)
        width, height = int(width_text), int(height_text)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError(
            f"invalid size {value!r}; expected WIDTHxHEIGHT"
        ) from exc
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("image dimensions must be positive")
    return width, height


def _patterns(
    seed: int,
) -> dict[str, tuple[str, Callable[[int, int], np.ndarray]]]:
    return {
        "black": ("all channels are 0", lambda w, h: _solid(w, h, 0)),
        "white": ("all channels are 255", lambda w, h: _solid(w, h, 255)),
        "midgray": ("all channels are 128", lambda w, h: _solid(w, h, 128)),
        "rgb_bars": ("eight full-amplitude vertical RGB color bars", _rgb_bars),
        "ramp_horizontal": (
            "integer 0..255 horizontal grayscale ramp",
            _ramp_horizontal,
        ),
        "ramp_vertical": (
            "integer 0..255 vertical grayscale ramp",
            _ramp_vertical,
        ),
        "checkerboard_px1": (
            "one-pixel black/white checkerboard",
            lambda w, h: _checkerboard(w, h, 1),
        ),
        "checkerboard_tile8": (
            "eight-pixel black/white checkerboard",
            lambda w, h: _checkerboard(w, h, 8),
        ),
        "impulse_center": ("white center pixel on black", _impulse_center),
        "random_rgb": (
            f"PCG64 random RGB, base seed {seed}",
            lambda w, h: _random_rgb(w, h, seed),
        ),
    }


def generate(
    output_dir: Path,
    sizes: tuple[tuple[int, int], ...],
    seed: int,
) -> dict[str, object]:
    output_dir.mkdir(parents=True, exist_ok=True)
    patterns = _patterns(seed)
    files: list[dict[str, object]] = []

    for width, height in sizes:
        for pattern_name, (_, builder) in patterns.items():
            array = builder(width, height)
            expected_shape = (height, width, 3)
            if array.dtype != np.uint8 or array.shape != expected_shape:
                raise RuntimeError(
                    f"{pattern_name} returned dtype={array.dtype}, shape={array.shape}; "
                    f"expected uint8 {expected_shape}"
                )

            filename = f"{pattern_name}_{width}x{height}.png"
            Image.fromarray(array, mode="RGB").save(
                output_dir / filename,
                format="PNG",
                optimize=False,
            )
            files.append(
                {
                    "file": filename,
                    "pattern": pattern_name,
                    "width": width,
                    "height": height,
                    "mode": "RGB",
                }
            )

    manifest: dict[str, object] = {
        "schema_version": 1,
        "generator": "case1/golden/generate_synthetic_assets.py",
        "seed": seed,
        "random_generator": "NumPy PCG64",
        "sizes": [
            {"width": width, "height": height} for width, height in sizes
        ],
        "patterns": {
            name: description for name, (description, _) in patterns.items()
        },
        "file_count": len(files),
        "files": files,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> int:
    default_output = Path(__file__).resolve().parents[1] / "assets" / "generated"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=default_output,
        help=f"output directory (default: {default_output})",
    )
    parser.add_argument(
        "--sizes",
        type=_parse_size,
        nargs="+",
        default=list(DEFAULT_SIZES),
        metavar="WIDTHxHEIGHT",
        help="one or more output sizes",
    )
    parser.add_argument(
        "--seed",
        type=lambda text: int(text, 0),
        default=DEFAULT_SEED,
        help=f"base seed for random_rgb (default: {DEFAULT_SEED}, accepts 0x...)",
    )
    args = parser.parse_args()

    sizes = tuple(args.sizes)
    if len(set(sizes)) != len(sizes):
        parser.error("--sizes contains duplicates")
    if args.seed < 0 or args.seed >= 1 << 64:
        parser.error("--seed must be in the unsigned 64-bit range")

    manifest = generate(args.output.resolve(), sizes, args.seed)
    print(f"GENERATED {manifest['file_count']} PNG files in {args.output.resolve()}")
    print(f"MANIFEST {args.output.resolve() / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
