"""Run the complete integer R1 ISP on redistributable natural images.

The source RGB image is mosaiced into exact RAW10 for each Bayer pattern,
then reconstructed with identity BLC/AWB/CCM/Gamma.  PSNR measures the valid
crop against the corresponding RGB source interior.  One RGGB 640x480 result
per image is also written to exercise the normative center-aligned Resize.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, UnidentifiedImageError

from r1_isp import BAYER_PATTERNS, R1ISPConfig, rgb8_to_bayer10, run_r1_isp


def psnr_u8(actual: np.ndarray, expected: np.ndarray) -> float:
    difference = actual.astype(np.float64) - expected.astype(np.float64)
    mse = float(np.mean(difference * difference))
    return float("inf") if mse == 0.0 else 10.0 * math.log10((255.0**2) / mse)


def validate(
    images_dir: Path, output_dir: Path, skip_unreadable: bool = False
) -> dict:
    image_paths = sorted(
        path
        for path in images_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
    )
    if not image_paths:
        raise ValueError(f"no supported images found in {images_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, object]] = []
    skipped: list[dict[str, str]] = []
    for path in image_paths:
        try:
            with Image.open(path) as source:
                rgb = np.asarray(source.convert("RGB"), dtype=np.uint8)
        except (OSError, UnidentifiedImageError) as error:
            if not skip_unreadable:
                raise
            skipped.append({"image": path.name, "reason": type(error).__name__})
            continue
        if rgb.shape[0] < 3 or rgb.shape[1] < 3:
            raise ValueError(f"image is too small for valid Debayer: {path}")
        reference = rgb[1:-1, 1:-1]
        pattern_rows: list[dict[str, object]] = []
        for pattern in BAYER_PATTERNS:
            raw10 = rgb8_to_bayer10(rgb, pattern)
            reconstructed, stages = run_r1_isp(
                raw10,
                reference.shape[1],
                reference.shape[0],
                R1ISPConfig(bayer_pattern=pattern),
            )
            if reconstructed.shape != reference.shape:
                raise AssertionError("identity Resize changed the valid-crop shape")
            pattern_rows.append(
                {
                    "pattern": pattern,
                    "effective_bayer": stages["effective_bayer"],
                    "psnr_db": psnr_u8(reconstructed, reference),
                    "max_abs_error": int(
                        np.max(
                            np.abs(
                                reconstructed.astype(np.int16)
                                - reference.astype(np.int16)
                            )
                        )
                    ),
                }
            )
            if pattern == "RGGB":
                resized, _ = run_r1_isp(
                    raw10, 640, 480, R1ISPConfig(bayer_pattern=pattern)
                )
                Image.fromarray(reconstructed, mode="RGB").save(
                    output_dir / f"{path.stem}_rggb_valid.png"
                )
                Image.fromarray(resized, mode="RGB").save(
                    output_dir / f"{path.stem}_rggb_640x480.png"
                )
        rows.append(
            {
                "image": path.name,
                "source_width": int(rgb.shape[1]),
                "source_height": int(rgb.shape[0]),
                "patterns": pattern_rows,
            }
        )

    if not rows:
        raise ValueError("no readable images were validated")
    finite_psnr = [
        float(pattern["psnr_db"])
        for row in rows
        for pattern in row["patterns"]
        if math.isfinite(float(pattern["psnr_db"]))
    ]
    report = {
        "schema_version": 1,
        "algorithm": "R1 RAW10 identity ISP plus center-aligned Q16.16 Resize",
        "image_scope": "redistributable assets/images only unless explicitly overridden",
        "image_count": len(rows),
        "pattern_cases": sum(len(row["patterns"]) for row in rows),
        "skipped_images": skipped,
        "minimum_finite_psnr_db": min(finite_psnr) if finite_psnr else None,
        "mean_finite_psnr_db": (
            sum(finite_psnr) / len(finite_psnr) if finite_psnr else None
        ),
        "images": rows,
    }
    (output_dir / "metrics.json").write_text(
        json.dumps(report, indent=2, allow_nan=True) + "\n", encoding="utf-8"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", type=Path, default=Path("assets/images"))
    parser.add_argument("--output", type=Path, default=Path("outputs/r1_validation"))
    parser.add_argument(
        "--skip-unreadable",
        action="store_true",
        help="record and skip files unsupported by the local image decoder",
    )
    args = parser.parse_args()
    report = validate(args.images, args.output, args.skip_unreadable)
    print(
        "C1_R1_NATURAL_IMAGE_VALIDATION_PASS",
        f"images={report['image_count']}",
        f"patterns={report['pattern_cases']}",
        f"skipped={len(report['skipped_images'])}",
        f"min_psnr={report['minimum_finite_psnr_db']:.4f}",
        f"mean_psnr={report['mean_finite_psnr_db']:.4f}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
