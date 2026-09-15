"""Validate the trained QAT artifact on all six licensed content images."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
import torch

from microstyle_quant import integer_infer_rgb, load_qat_checkpoint


def load_resized(path: Path, size: int) -> np.ndarray:
    with Image.open(path) as image:
        rgb = image.convert("RGB").resize((size, size), Image.Resampling.BILINEAR)
        return np.asarray(rgb, dtype=np.uint8).copy()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content-dir", type=Path, default=Path("assets/images"))
    parser.add_argument(
        "--artifact-dir", type=Path, default=Path("model/microstyle24_starry_functional")
    )
    parser.add_argument(
        "--output-dir", type=Path, default=Path("outputs/microstyle_qat/validation")
    )
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cpu")
    args = parser.parse_args()
    if args.size < 16 or args.size % 4:
        raise ValueError("validation size must be >=16 and divisible by four")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA requested but unavailable")
    paths = sorted(
        path for path in args.content_dir.iterdir()
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg"}
    )
    if len(paths) != 6:
        raise AssertionError(f"expected six licensed content images, found {len(paths)}")

    qat = load_qat_checkpoint(args.artifact_dir / "checkpoint_qat.pt", args.device)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    maximum_error = 0
    for path in paths:
        input_u8 = load_resized(path, args.size)
        integer_output, _ = integer_infer_rgb(input_u8, args.artifact_dir)
        tensor = torch.from_numpy(input_u8.transpose(2, 0, 1).copy()).unsqueeze(0)
        tensor = tensor.to(args.device).float() / 255.0
        with torch.no_grad():
            qat_output = torch.round(qat(tensor)[0] * 255.0).byte()
        qat_u8 = qat_output.permute(1, 2, 0).cpu().numpy()
        error = int(
            np.max(np.abs(qat_u8.astype(np.int16) - integer_output.astype(np.int16)))
        )
        maximum_error = max(maximum_error, error)
        change = float(
            np.mean(np.abs(integer_output.astype(np.int16) - input_u8.astype(np.int16)))
        )
        saturation = float(
            np.mean((integer_output == 0) | (integer_output == 255))
        )
        luminance = (
            integer_output[..., 0].astype(np.float64) * 0.299
            + integer_output[..., 1].astype(np.float64) * 0.587
            + integer_output[..., 2].astype(np.float64) * 0.114
        )
        luma_std = float(np.std(luminance))
        if change < 0.5 or saturation >= 0.75 or luma_std < 3.0:
            raise AssertionError(
                f"{path.name} functional output is degenerate: "
                f"change={change}, saturation={saturation}, luma_std={luma_std}"
            )
        Image.fromarray(
            np.concatenate((input_u8, integer_output), axis=1), mode="RGB"
        ).save(args.output_dir / f"{path.stem}_pair.png")
        rows.append(
            {
                "image": path.name,
                "size": args.size,
                "integer_qat_max_abs_error": error,
                "output_change_mae_u8": change,
                "output_saturation_fraction": saturation,
                "output_luma_std": luma_std,
            }
        )
    if maximum_error != 0:
        raise AssertionError(f"integer/QAT maximum error is {maximum_error}")
    report = {
        "artifact_role": "functional_checkpoint_not_final_visual_convergence",
        "images": rows,
        "image_count": len(rows),
        "integer_qat_max_abs_error": maximum_error,
        "mean_output_change_mae_u8": float(
            np.mean([row["output_change_mae_u8"] for row in rows])
        ),
        "mean_output_saturation_fraction": float(
            np.mean([row["output_saturation_fraction"] for row in rows])
        ),
        "quality_boundary": (
            "Degeneracy and bit-exactness check only; no claim of final artistic quality."
        ),
    }
    (args.output_dir / "validation_metrics.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        "C1_MICROSTYLE_QAT_IMAGE_VALIDATION_PASS",
        f"images={len(rows)}",
        f"size={args.size}",
        f"integer_error={maximum_error}",
        f"mean_change={report['mean_output_change_mae_u8']:.4f}",
        f"mean_saturation={report['mean_output_saturation_fraction']:.6f}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

