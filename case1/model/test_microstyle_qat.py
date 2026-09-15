"""Artifact-level regression for the trained MicroStyle-24 INT8 export."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import numpy as np
import torch


THIS_DIR = Path(__file__).resolve().parent
GOLDEN_DIR = THIS_DIR.parent / "golden"
sys.path.insert(0, str(GOLDEN_DIR))

from descriptor_format import BYTES as DESCRIPTOR_BYTES, unpack_words  # noqa: E402
from microstyle_quant import (  # noqa: E402
    CONV_NAMES,
    integer_infer_rgb,
    load_qat_checkpoint,
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-dir",
        type=Path,
        default=THIS_DIR / "microstyle24_starry_functional",
    )
    args = parser.parse_args()
    manifest = json.loads(
        (args.artifact_dir / "manifest.json").read_text(encoding="utf-8")
    )
    if manifest["trained"] is not True:
        raise AssertionError("QAT artifact must be marked trained=true")
    if manifest["artifact_role"] != "functional_qat_checkpoint_not_final_quality":
        raise AssertionError("quality boundary role is missing")
    if manifest["descriptor_count"] != 22 or manifest["descriptor_bytes"] != 1408:
        raise AssertionError("frozen 22-stage descriptor ABI changed")
    if manifest["parameter_arena_bytes"] != 16_896:
        raise AssertionError("frozen parameter arena ABI changed")
    if manifest["convolution_weights"] != 12_212:
        raise AssertionError("frozen convolution weight budget changed")

    descriptors = (args.artifact_dir / manifest["descriptor_file"]).read_bytes()
    if len(descriptors) != 22 * DESCRIPTOR_BYTES:
        raise AssertionError("descriptor file has the wrong length")
    for offset in range(0, len(descriptors), DESCRIPTOR_BYTES):
        unpack_words(descriptors[offset : offset + DESCRIPTOR_BYTES])
    arena = (args.artifact_dir / manifest["parameter_file"]).read_bytes()
    if len(arena) != 16_896 or not any(arena):
        raise AssertionError("parameter arena is empty or has the wrong length")

    quantized_layers = manifest["quantized_layers"]
    if tuple(row["name"] for row in quantized_layers) != CONV_NAMES:
        raise AssertionError("quantized layer order changed")
    for row in quantized_layers:
        if not 1 <= row["multiplier_min"] <= row["multiplier_max"] < (1 << 17):
            raise AssertionError(f"{row['name']} multiplier exceeds signed18")
        if not 0 <= row["shift_min"] <= row["shift_max"] <= 47:
            raise AssertionError(f"{row['name']} shift exceeds RTL contract")

    training = manifest["training"]
    if training["float_steps"] <= 0 or training["qat_steps"] <= 0:
        raise AssertionError("artifact does not record both training phases")
    if training["weight_delta_l2_from_seeded_initialization"] <= 1e-6:
        raise AssertionError("exported weights did not move from initialization")
    if len(training["content_files"]) != 6:
        raise AssertionError("training must use the six licensed public content images")
    if "public" not in training["style_license"].lower():
        raise AssertionError("style asset license boundary is missing")
    if not 0.5 <= training["preview_output_change_mae_u8"] <= 180.0:
        raise AssertionError("functional style output is unchanged or degenerate")
    if training["preview_output_saturation_fraction"] >= 0.75:
        raise AssertionError("functional style output is dominated by saturation")

    regression = np.load(args.artifact_dir / "integer_regression.npz")
    observed, layers = integer_infer_rgb(
        regression["input_rgb_u8"], args.artifact_dir, collect=True
    )
    if not np.array_equal(observed, regression["expected_rgb_u8"]):
        raise AssertionError("stored 22-stage integer regression vector changed")
    if len(layers) != 22:
        raise AssertionError(f"expected 22 collected stages, got {len(layers)}")

    qat = load_qat_checkpoint(args.artifact_dir / "checkpoint_qat.pt")
    qat_input = torch.from_numpy(
        regression["input_rgb_u8"].transpose(2, 0, 1).copy()
    ).unsqueeze(0).float() / 255.0
    with torch.no_grad():
        qat_output = torch.round(qat(qat_input)[0] * 255.0).byte()
    qat_output_u8 = qat_output.permute(1, 2, 0).numpy()
    if not np.array_equal(qat_output_u8, observed):
        raise AssertionError("reloaded QAT checkpoint disagrees with integer artifact")

    rng = np.random.default_rng(20260824)
    directed = rng.integers(0, 256, size=(16, 20, 3), dtype=np.uint8)
    second, second_layers = integer_infer_rgb(directed, args.artifact_dir, collect=True)
    if second.shape != directed.shape or second.dtype != np.uint8:
        raise AssertionError("integer inference geometry/type contract failed")
    if any(not np.isfinite(value.astype(np.float64)).all() for value in second_layers.values()):
        raise AssertionError("integer layer output contains a non-finite value")

    print(
        "C1_MICROSTYLE_QAT_ARTIFACT_TEST_PASS",
        f"descriptors={manifest['descriptor_count']}",
        f"arena={manifest['parameter_arena_bytes']}",
        f"weights={manifest['convolution_weights']}",
        f"float_steps={training['float_steps']}",
        f"qat_steps={training['qat_steps']}",
        f"regression_pixels={observed.shape[0] * observed.shape[1]}",
        f"stages={len(layers)}",
        f"change_mae={training['preview_output_change_mae_u8']:.4f}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
