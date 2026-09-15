"""Generate the frozen 22-descriptor MicroStyle-24 streaming layout.

This module plans descriptor and parameter offsets only.  It never invents
trained weights: exported artifacts are explicitly marked ``trained=false``.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import sys


THIS_DIR = Path(__file__).resolve().parent
GOLDEN_DIR = THIS_DIR.parent / "golden"
sys.path.insert(0, str(GOLDEN_DIR))

from descriptor_format import (  # noqa: E402
    ACT_NONE,
    ACT_RELU,
    OP_CONV1X1,
    OP_CONV3X3,
    OP_DWCONV3X3,
    OP_OUTPUT_RGB,
    OP_RESIDUAL_ADD,
    OP_UPSAMPLE2,
    LayerDescriptor,
)


FLAG_SAME_REPLICATE = 1 << 0
FLAG_RESIDUAL_VALID = 1 << 1
FLAG_INPUT_FRAME = 1 << 2
FLAG_OUTPUT_FRAME = 1 << 3


@dataclass(frozen=True)
class LayerSpec:
    name: str
    opcode: int
    activation: int
    input_width: int
    input_height: int
    output_width: int
    output_height: int
    input_channels: int
    output_channels: int
    kernel: int
    stride: int
    mac_lanes: int
    weight_count: int
    flags: int = 0


def _conv(
    name: str,
    opcode: int,
    activation: int,
    width: int,
    height: int,
    in_channels: int,
    out_channels: int,
    kernel: int,
    stride: int,
    mac_lanes: int,
    flags: int = FLAG_SAME_REPLICATE,
) -> LayerSpec:
    output_width = width // stride
    output_height = height // stride
    if opcode == OP_DWCONV3X3:
        weights = in_channels * kernel * kernel
    else:
        weights = in_channels * out_channels * kernel * kernel
    return LayerSpec(
        name,
        opcode,
        activation,
        width,
        height,
        output_width,
        output_height,
        in_channels,
        out_channels,
        kernel,
        stride,
        mac_lanes,
        weights,
        flags,
    )


def layer_specs(width: int = 640, height: int = 480) -> list[LayerSpec]:
    if width % 4 or height % 4:
        raise ValueError("MicroStyle-24 dimensions must be multiples of four")
    w4, h4 = width // 4, height // 4
    rows = [
        _conv(
            "encoder1.conv3x3_s2", OP_CONV3X3, ACT_RELU,
            width, height, 3, 12, 3, 2, 5,
            FLAG_SAME_REPLICATE | FLAG_INPUT_FRAME,
        ),
        _conv(
            "encoder2.conv3x3_s2", OP_CONV3X3, ACT_RELU,
            width // 2, height // 2, 12, 24, 3, 2, 9,
        ),
    ]
    for block in range(3):
        rows.extend(
            (
                _conv(
                    f"res{block}.expand1x1", OP_CONV1X1, ACT_RELU,
                    w4, h4, 24, 48, 1, 1, 4,
                ),
                _conv(
                    f"res{block}.depthwise3x3", OP_DWCONV3X3, ACT_RELU,
                    w4, h4, 48, 48, 3, 1, 2,
                ),
                _conv(
                    f"res{block}.project1x1", OP_CONV1X1, ACT_NONE,
                    w4, h4, 48, 24, 1, 1, 4,
                ),
                LayerSpec(
                    f"res{block}.add_relu",
                    OP_RESIDUAL_ADD,
                    ACT_RELU,
                    w4,
                    h4,
                    w4,
                    h4,
                    24,
                    24,
                    1,
                    1,
                    1,
                    0,
                    FLAG_RESIDUAL_VALID,
                ),
            )
        )
    rows.extend(
        (
            LayerSpec(
                "decoder1.upsample2", OP_UPSAMPLE2, ACT_NONE,
                w4, h4, width // 2, height // 2, 24, 24, 1, 2, 1, 0,
            ),
            _conv(
                "decoder1.depthwise3x3", OP_DWCONV3X3, ACT_RELU,
                width // 2, height // 2, 24, 24, 3, 1, 3,
            ),
            _conv(
                "decoder1.pointwise1x1", OP_CONV1X1, ACT_RELU,
                width // 2, height // 2, 24, 16, 1, 1, 5,
            ),
            LayerSpec(
                "decoder2.upsample2", OP_UPSAMPLE2, ACT_NONE,
                width // 2, height // 2, width, height, 16, 16, 1, 2, 1, 0,
            ),
            _conv(
                "decoder2.depthwise3x3", OP_DWCONV3X3, ACT_RELU,
                width, height, 16, 16, 3, 1, 8,
            ),
            _conv(
                "decoder2.pointwise1x1", OP_CONV1X1, ACT_RELU,
                width, height, 16, 8, 1, 1, 8,
            ),
            _conv(
                "output.conv3x3", OP_CONV3X3, ACT_NONE,
                width, height, 8, 3, 3, 1, 12,
            ),
            LayerSpec(
                "output.s8_to_rgb", OP_OUTPUT_RGB, ACT_NONE,
                width, height, width, height, 3, 3, 1, 1, 1, 0,
                FLAG_OUTPUT_FRAME,
            ),
        )
    )
    return rows


def _align(value: int, alignment: int = 16) -> int:
    return (value + alignment - 1) & -alignment


def build_layout(width: int = 640, height: int = 480) -> tuple[list[LayerDescriptor], dict]:
    specs = layer_specs(width, height)
    parameter_cursor = 0
    descriptors: list[LayerDescriptor] = []
    parameter_rows: list[dict[str, int | str]] = []
    total_macs = 0

    for spec in specs:
        weight_offset = bias_offset = multiplier_offset = shift_offset = 0
        if spec.weight_count:
            parameter_cursor = _align(parameter_cursor, 64)
            weight_offset = parameter_cursor
            parameter_cursor += spec.weight_count
            parameter_cursor = _align(parameter_cursor)
            bias_offset = parameter_cursor
            parameter_cursor += spec.output_channels * 4
            parameter_cursor = _align(parameter_cursor)
            multiplier_offset = parameter_cursor
            parameter_cursor += spec.output_channels * 4  # signed18 stored in LE int32
            parameter_cursor = _align(parameter_cursor)
            shift_offset = parameter_cursor
            parameter_cursor += spec.output_channels
            parameter_cursor = _align(parameter_cursor)
            parameter_rows.append(
                {
                    "name": spec.name,
                    "weight_offset": weight_offset,
                    "weight_bytes": spec.weight_count,
                    "bias_offset": bias_offset,
                    "bias_bytes": spec.output_channels * 4,
                    "multiplier_offset": multiplier_offset,
                    "multiplier_bytes": spec.output_channels * 4,
                    "shift_offset": shift_offset,
                    "shift_bytes": spec.output_channels,
                }
            )

        kernel_width = spec.kernel
        kernel_height = spec.kernel
        geometry_stride = spec.stride
        descriptor = LayerDescriptor(
            opcode=spec.opcode,
            activation=spec.activation,
            flags=spec.flags,
            input_width=spec.input_width,
            input_height=spec.input_height,
            output_width=spec.output_width,
            output_height=spec.output_height,
            input_channels=spec.input_channels,
            output_channels=spec.output_channels,
            input_offset=0,
            output_offset=0,
            residual_offset=0,
            weight_offset=weight_offset,
            bias_offset=bias_offset,
            multiplier_offset=multiplier_offset,
            shift_offset=shift_offset,
            input_row_stride=0,
            output_row_stride=0,
            kernel_width=kernel_width,
            kernel_height=kernel_height,
            stride_x=geometry_stride,
            stride_y=geometry_stride,
            channel_block=8,
            mac_lanes=spec.mac_lanes,
            tile_width=1,
            tile_height=1,
            cycle_budget=0,
        )
        descriptor.validate()
        descriptors.append(descriptor)
        if spec.weight_count:
            total_macs += (
                spec.output_width * spec.output_height * spec.weight_count
            )

    manifest = {
        "schema_version": 1,
        "artifact_role": "streaming_layout_only_untrained",
        "execution_model": "dedicated_multirate_streaming_graph",
        "descriptor_role": (
            "pre-frame stage configuration; descriptors are not a sequential "
            "DDR tensor execution schedule"
        ),
        "model": "MicroStyle-24",
        "trained": False,
        "warning": "Descriptor/parameter layout only; no artistic weights are included.",
        "width": width,
        "height": height,
        "descriptor_count": len(descriptors),
        "descriptor_bytes": len(descriptors) * 64,
        "convolution_weights": sum(spec.weight_count for spec in specs),
        "macs_per_frame": total_macs,
        "parameter_arena_bytes": _align(parameter_cursor, 64),
        "tensor_offsets": "zero means direct streaming between dedicated stages",
        "layers": [asdict(spec) for spec in specs],
        "parameter_layout": parameter_rows,
    }
    return descriptors, manifest


def export_layout(output_dir: Path, width: int = 640, height: int = 480) -> dict:
    descriptors, manifest = build_layout(width, height)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "descriptors_untrained.bin").write_bytes(
        b"".join(descriptor.pack() for descriptor in descriptors)
    )
    (output_dir / "layout_untrained.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    args = parser.parse_args()
    manifest = export_layout(args.output_dir, args.width, args.height)
    print(
        "C1_MICROSTYLE_LAYOUT_PASS",
        f"descriptors={manifest['descriptor_count']}",
        f"weights={manifest['convolution_weights']}",
        f"macs={manifest['macs_per_frame']}",
        f"parameter_bytes={manifest['parameter_arena_bytes']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
