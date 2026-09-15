"""Prepare only size-matched descriptors and the real trained arena for a SoC run.

No synthetic weights, expected pixel files, hashes or simulator databases are
created. The runner places these compact inputs in its disposable directory.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from microstyle_layout import build_layout


def build_fixture(artifact: Path, width: int, height: int, *, elide_views: bool = False, fuse_final: bool = False) -> tuple[str, str, dict]:
    if (width, height) not in ((8, 8), (16, 8), (16, 16), (64, 48)):
        raise ValueError("trained SoC fixtures currently support 8x8, 16x8, 16x16 and 64x48")
    descriptors, layout = build_layout(width, height)
    manifest = json.loads((artifact / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("trained") is not True or manifest.get("model") != "MicroStyle-24":
        raise ValueError("a real trained MicroStyle-24 artifact is required")
    if manifest.get("descriptor_count") != 22 or len(descriptors) != 22:
        raise ValueError("the trained graph must contain exactly 22 stages")
    # Spatial sizes change, but parameter ABI and every non-spatial operator
    # property must remain the same as the trained checkpoint.
    if manifest.get("parameter_layout") != layout["parameter_layout"]:
        raise ValueError("trained parameter offsets do not match the current layout")
    keys = ("name", "opcode", "activation", "input_channels", "output_channels",
            "kernel", "stride", "mac_lanes", "weight_count", "flags")
    actual_layers = manifest.get("layers", [])
    if len(actual_layers) != 22 or any(
            any(actual.get(key) != expected[key] for key in keys)
            for actual, expected in zip(actual_layers, layout["layers"])):
        raise ValueError("trained operator graph does not match the current layout")
    arena = (artifact / manifest["parameter_file"]).read_bytes()
    if len(arena) != manifest.get("parameter_arena_bytes") or len(arena) != layout["parameter_arena_bytes"]:
        raise ValueError("trained parameter arena length mismatch")
    logical_results=sum(d.output_width*d.output_height*((d.output_channels+7)//8) for d in descriptors)
    physical_results=sum(d.output_width*d.output_height*((d.output_channels+7)//8)
                         for i,d in enumerate(descriptors) if not((elide_views and i in (14,17)) or (fuse_final and i==21)))
    summary = {"width": width, "height": height, "descriptor_count": len(descriptors),
               "parameter_arena_bytes": len(arena),
               "C8_results": physical_results, "logical_C8_results": logical_results,
               "elide_views": elide_views,
               "fuse_final": fuse_final,
               "artifact": str(artifact.resolve()), "trained": True,
               "scope": "functional checkpoint; not final style quality or native fps"}
    return ("\n".join(d.pack()[::-1].hex() for d in descriptors) + "\n",
            "\n".join(arena[i:i+16][::-1].hex() for i in range(0, len(arena), 16)) + "\n",
            summary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--elide-views", action="store_true")
    parser.add_argument("--fuse-final", action="store_true")
    args = parser.parse_args()
    descriptor_text, arena_text, summary = build_fixture(args.artifact, args.width, args.height,elide_views=args.elide_views,fuse_final=args.fuse_final)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "trained_descriptors.mem").write_text(descriptor_text, encoding="ascii")
    (args.output_dir / "trained_parameter_arena.mem").write_text(arena_text, encoding="ascii")
    (args.output_dir / "trained_fixture.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"C1_SOC_TRAINED_FIXTURE_PASS shape={args.width}x{args.height} descriptors=22 C8_results={summary['C8_results']} parameter_bytes={summary['parameter_arena_bytes']}")
