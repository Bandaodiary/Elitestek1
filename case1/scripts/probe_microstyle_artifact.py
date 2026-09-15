"""Run a bounded integer probe of the exported MicroStyle-24 artifact.

This is deliberately a software-side bit-exact reference probe.  It validates
the frozen descriptor/arena ABI at native size and runs the same exported
integer weights at a small divisible-by-four size, without creating a large
simulation worktree or changing the RTL.  The small-size run is useful for
RTL probes because it exposes every stage tensor and keeps the reference
result cheap to inspect; native RTL ABI and small-frame RTL arithmetic are
reported by their separate detached runners.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
sys.path.insert(0, str(ROOT / "golden"))

from microstyle_layout import build_layout  # noqa: E402
from microstyle_quant import integer_infer_rgb  # noqa: E402


def _pattern(height: int, width: int) -> np.ndarray:
    yy, xx = np.indices((height, width), dtype=np.int32)
    return np.stack(
        ((xx * 17 + yy * 3) & 0xFF,
         (xx * 5 + yy * 29 + 41) & 0xFF,
         (xx * 11 + yy * 7 + 97) & 0xFF), axis=-1
    ).astype(np.uint8)


def probe(artifact: Path, width: int, height: int) -> dict[str, object]:
    manifest = json.loads((artifact / "manifest.json").read_text(encoding="utf-8"))
    descriptors = (artifact / str(manifest["descriptor_file"])).read_bytes()
    arena = (artifact / str(manifest["parameter_file"])).read_bytes()
    expected_desc, layout = build_layout()
    expected_desc_bytes = b"".join(item.pack() for item in expected_desc)
    if descriptors != expected_desc_bytes:
        raise RuntimeError("artifact descriptors do not match frozen native layout")
    if len(arena) != int(manifest["parameter_arena_bytes"]):
        raise RuntimeError("artifact parameter arena length disagrees with manifest")

    image = _pattern(height, width)
    output, layers = integer_infer_rgb(image, artifact, collect=True)
    if output.shape != image.shape or output.dtype != np.uint8:
        raise RuntimeError(f"unexpected output shape/dtype: {output.shape}/{output.dtype}")
    if len(layers) != 22:
        raise RuntimeError(f"expected 22 exposed stages, got {len(layers)}")
    if not np.isfinite(output.astype(np.float32)).all():
        raise RuntimeError("non-finite output")

    return {
        "artifact": str(artifact),
        "trained": bool(manifest.get("trained", False)),
        "native_descriptor_geometry": [int(manifest["width"]), int(manifest["height"])],
        "descriptor_count": len(expected_desc),
        "parameter_arena_bytes": len(arena),
        "small_probe_geometry": [width, height],
        "stage_count": len(layers),
        "stage_shapes": {name: list(value.shape) for name, value in layers.items()},
        "output_sample_rgb": output.reshape(-1, 3)[:4].tolist(),
        "status": "PASS",
        "boundary": (
            "Python integer reference; native descriptor/arena ABI preflight and "
            "8x8 RTL engine/adapter/portable-SoC probes are separate evidence"
        ),
        "layout_parameter_arena_bytes": int(layout["parameter_arena_bytes"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--width", type=int, default=8)
    parser.add_argument("--height", type=int, default=8)
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0 or args.width % 4 or args.height % 4:
        parser.error("width and height must be positive multiples of four")
    print(json.dumps(probe(args.artifact, args.width, args.height), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
