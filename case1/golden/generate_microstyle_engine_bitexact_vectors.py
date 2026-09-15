"""Generate a bounded trained-artifact vector set for the RTL stage engine.

The shipped QAT artifact is described at 640x480, which is too large for a
fast pre-board engine regression.  Spatial dimensions do not change the
weights or the descriptor/arena offsets, so this generator reuses the
trained parameter arena with the same 22-stage topology at a legal small
shape (8x8 by default).  It emits the exact C8 windows, residual payloads and
expected signed-int8 outputs consumed by ``c1_r1_microstyle_engine``.

This is deliberately an engine-level test, not a claim that the complete
portable SoC or tensor adapter has been proven at native resolution.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Iterable

import numpy as np

# The script is normally invoked by path from the repository root.  Keep the
# imports independent of the caller's current directory.
THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR.parent / "model"))
sys.path.insert(0, str(THIS_DIR))

from microstyle_layout import build_layout
from microstyle_quant import integer_infer_rgb


STAGE_NAMES = (
    "encoder1.conv3x3_s2",
    "encoder2.conv3x3_s2",
    "res0.expand1x1",
    "res0.depthwise3x3",
    "res0.project1x1",
    "res0.add_relu",
    "res1.expand1x1",
    "res1.depthwise3x3",
    "res1.project1x1",
    "res1.add_relu",
    "res2.expand1x1",
    "res2.depthwise3x3",
    "res2.project1x1",
    "res2.add_relu",
    "decoder1.upsample2",
    "decoder1.depthwise3x3",
    "decoder1.pointwise1x1",
    "decoder2.upsample2",
    "decoder2.depthwise3x3",
    "decoder2.pointwise1x1",
    "output.conv3x3",
    "output.s8_to_rgb",
)

OP_CONV3X3 = 1
OP_CONV1X1 = 2
OP_DWCONV3X3 = 3
OP_UPSAMPLE2 = 4
OP_RESIDUAL_ADD = 5
OP_OUTPUT_RGB = 6

VECTOR_BITS = 1024


def _pack_bytes(values: Iterable[int]) -> int:
    result = 0
    for index, value in enumerate(values):
        result |= (int(value) & 0xFF) << (8 * index)
    return result


def _image(width: int, height: int) -> np.ndarray:
    """A deterministic nontrivial RGB pattern in the model's uint8 domain."""
    result = np.empty((height, width, 3), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            for channel in range(3):
                result[y, x, channel] = (
                    17 * x + 31 * y + 53 * channel + 11
                ) & 0xFF
    return result


def _edge_index(index: int, limit: int) -> int:
    return min(max(index, 0), limit - 1)


def _window(
    source: np.ndarray,
    x: int,
    y: int,
    channels: int,
    opcode: int,
    stride: int,
) -> int:
    """Pack one tap-major 3x3 C8 window in the RTL bit order."""
    height, width, source_channels = source.shape
    if opcode == OP_CONV3X3:
        center_x = x * stride
        center_y = y * stride
    else:
        # The adapter presents an already-expanded plane to UPSAMPLE2; all
        # other supported operations use a unit-stride center coordinate.
        center_x = x
        center_y = y
    lanes: list[int] = []
    for tap in range(9):
        dy, dx = divmod(tap, 3)
        sx = _edge_index(center_x + dx - 1, width)
        sy = _edge_index(center_y + dy - 1, height)
        for lane in range(8):
            channel = lane
            # The caller slices a group from the source before invoking this
            # helper; this branch is retained for a clear channel contract.
            if channel < channels and channel < source_channels:
                lanes.append(int(source[sy, sx, channel]))
            else:
                lanes.append(0)
    return _pack_bytes(lanes)


def _window_group(
    source: np.ndarray,
    x: int,
    y: int,
    group: int,
    channels: int,
    opcode: int,
    stride: int,
) -> int:
    """Pack a selected global C8 channel group, including tap-major bytes."""
    height, width, source_channels = source.shape
    if opcode == OP_CONV3X3:
        center_x = x * stride
        center_y = y * stride
    else:
        center_x = x
        center_y = y
    values: list[int] = []
    for tap in range(9):
        dy, dx = divmod(tap, 3)
        sx = _edge_index(center_x + dx - 1, width)
        sy = _edge_index(center_y + dy - 1, height)
        for lane in range(8):
            channel = group * 8 + lane
            values.append(
                int(source[sy, sx, channel])
                if channel < channels and channel < source_channels
                else 0
            )
    return _pack_bytes(values)


def _center_group(
    source: np.ndarray, x: int, y: int, group: int, channels: int
) -> int:
    values = []
    for lane in range(8):
        channel = group * 8 + lane
        values.append(
            int(source[y, x, channel])
            if channel < channels and channel < source.shape[2]
            else 0
        )
    return _pack_bytes(values)


def _stage_sources(
    image: np.ndarray, layers: dict[str, np.ndarray], stage_index: int
) -> tuple[np.ndarray, np.ndarray | None]:
    """Return the input plane and optional residual plane for one stage."""
    if stage_index == 0:
        return (image.astype(np.int16) - 128).astype(np.int8), None

    name = STAGE_NAMES[stage_index]
    if name == "res0.add_relu":
        return layers["res0.project1x1"], layers["encoder2.conv3x3_s2"]
    if name == "res1.add_relu":
        return layers["res1.project1x1"], layers["res0.add_relu"]
    if name == "res2.add_relu":
        return layers["res2.project1x1"], layers["res1.add_relu"]
    if name == "decoder1.upsample2":
        return layers[name], None
    if name == "decoder2.upsample2":
        return layers[name], None
    # OUTPUT_RGB is a signed-code bypass.  Its layer dictionary additionally
    # contains a uint8 display conversion, so use the preceding signed plane.
    if name == "output.s8_to_rgb":
        return layers["output.conv3x3"], None
    return layers[STAGE_NAMES[stage_index - 1]], None


def _pack_record(
    window: int,
    residual: int,
    expected: int,
    x: int,
    y: int,
    group: int,
    stage: int,
) -> int:
    value = window
    value |= residual << 576
    value |= expected << 640
    value |= (x & 0xFFFF) << 704
    value |= (y & 0xFFFF) << 720
    value |= (group & 0xFF) << 736
    value |= (stage & 0xFF) << 744
    if value.bit_length() > VECTOR_BITS:
        raise ValueError("vector record exceeded fixed width")
    return value


def generate(artifact: Path, output_dir: Path, width: int, height: int) -> dict:
    if width <= 0 or height <= 0 or width % 4 or height % 4:
        raise ValueError("small MicroStyle dimensions must be positive multiples of four")

    descriptors, small_layout = build_layout(width, height)
    if len(descriptors) != len(STAGE_NAMES):
        raise RuntimeError("frozen stage count changed")

    manifest_path = artifact / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    arena = (artifact / str(manifest["parameter_file"])).read_bytes()
    if len(arena) != int(manifest["parameter_arena_bytes"]):
        raise ValueError("artifact parameter arena length disagrees with manifest")

    image = _image(width, height)
    _, layers = integer_infer_rgb(image, artifact, collect=True)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "descriptors.mem").write_text(
        "\n".join(descriptor.pack()[::-1].hex() for descriptor in descriptors) + "\n",
        encoding="ascii",
    )
    (output_dir / "parameter_arena.mem").write_text(
        "\n".join(arena[offset : offset + 16][::-1].hex()
                 for offset in range(0, len(arena), 16)) + "\n",
        encoding="ascii",
    )

    records: list[int] = []
    expected_records: list[int] = []
    stage_rows: list[dict[str, int | str]] = []
    for stage_index, name in enumerate(STAGE_NAMES):
        spec = small_layout["layers"][stage_index]
        source, residual_source = _stage_sources(image, layers, stage_index)
        expected_plane = (
            layers["output.conv3x3"]
            if name == "output.s8_to_rgb"
            else layers[name]
        )
        input_channels = int(spec["input_channels"])
        output_channels = int(spec["output_channels"])
        input_groups = (input_channels + 7) // 8
        output_groups = (output_channels + 7) // 8
        stride = int(spec["stride"])
        first_offset = len(records)
        expected_offset = len(expected_records)
        # Keep expected output groups in the engine's raster order.  This is
        # separate from input-group records because Cin and Cout often have
        # different C8 group counts.
        for y in range(int(spec["output_height"])):
            for x in range(int(spec["output_width"])):
                for output_group in range(output_groups):
                    expected_records.append(
                        _center_group(
                            expected_plane, x, y, output_group, output_channels
                        )
                    )
        for y in range(int(spec["output_height"])):
            for x in range(int(spec["output_width"])):
                for group in range(input_groups):
                    if int(spec["opcode"]) in (OP_CONV3X3, OP_DWCONV3X3):
                        window = _window_group(
                            source, x, y, group, input_channels,
                            int(spec["opcode"]), stride
                        )
                    else:
                        # 1x1/bypass stages only consume tap 4.  Filling the
                        # complete window keeps the record self-describing.
                        window = _window_group(
                            source, x, y, group, input_channels,
                            OP_UPSAMPLE2, 1
                        )
                    residual = 0
                    if residual_source is not None:
                        residual = _center_group(
                            residual_source, x, y, group, input_channels
                        )
                    records.append(
                        _pack_record(window, residual, 0, x, y, group, stage_index)
                    )
        stage_rows.append(
            {
                "stage": stage_index,
                "name": name,
                "opcode": int(spec["opcode"]),
                "input_width": int(spec["input_width"]),
                "input_height": int(spec["input_height"]),
                "output_width": int(spec["output_width"]),
                "output_height": int(spec["output_height"]),
                "input_channels": input_channels,
                "output_channels": output_channels,
                "input_groups": input_groups,
                "output_groups": output_groups,
                "record_offset": first_offset,
                "record_count": len(records) - first_offset,
                "expected_offset": expected_offset,
                "expected_count": len(expected_records) - expected_offset,
            }
        )

    (output_dir / "engine_vectors.mem").write_text(
        "\n".join(f"{record:0{VECTOR_BITS // 4}x}" for record in records) + "\n",
        encoding="ascii",
    )
    (output_dir / "expected_outputs.mem").write_text(
        "\n".join(f"{record:016x}" for record in expected_records) + "\n",
        encoding="ascii",
    )
    # A compact fixed-width metadata image keeps the SystemVerilog TB free of
    # hand-copied offsets.  Fields are little-endian bit slices:
    # record/expected offset+count (16 bits each), output W/H, C8 group
    # counts, and opcode.
    meta_words: list[int] = []
    for row in stage_rows:
        meta = int(row["record_offset"])
        meta |= int(row["record_count"]) << 16
        meta |= int(row["expected_offset"]) << 32
        meta |= int(row["expected_count"]) << 48
        meta |= int(row["output_width"]) << 64
        meta |= int(row["output_height"]) << 80
        meta |= int(row["input_groups"]) << 96
        meta |= int(row["output_groups"]) << 104
        meta |= int(row["opcode"]) << 112
        meta_words.append(meta)
    (output_dir / "stage_meta.mem").write_text(
        "\n".join(f"{word:032x}" for word in meta_words) + "\n",
        encoding="ascii",
    )
    summary = {
        "artifact": str(artifact),
        "width": width,
        "height": height,
        "descriptor_count": len(descriptors),
        "parameter_arena_bytes": len(arena),
        "record_bits": VECTOR_BITS,
        "record_count": len(records),
        "expected_count": len(expected_records),
        "input_pattern": "(17*x + 31*y + 53*c + 11) mod 256",
        "stage_rows": stage_rows,
        "evidence_boundary": (
            "trained parameter arena + integer golden + RTL engine stage stream "
            "at a scaled shape; tensor adapter/portable SoC/native frame not covered"
        ),
    }
    (output_dir / "engine_vector_manifest.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, default=8)
    parser.add_argument("--height", type=int, default=8)
    args = parser.parse_args()
    summary = generate(args.artifact, args.output_dir, args.width, args.height)
    print(
        "C1_MICROSTYLE_ENGINE_VECTOR_GEN_PASS",
        f"stages={summary['descriptor_count']}",
        f"records={summary['record_count']}",
        f"shape={summary['width']}x{summary['height']}",
    )


if __name__ == "__main__":
    main()
