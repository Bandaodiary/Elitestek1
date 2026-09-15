"""Exact C8 scheduling work, not a fitted fps estimate or synthesis result.

The current engine serializes stages, has one 8x8 dot input port, one C8 DW
window input port and one C8 result port. A beat has at most one handshake per
clock. Per-stage minima deliberately omit start/finish, requantization, memory
and control bubbles; different stages cannot overlap in this engine.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from microstyle_layout import build_layout


def workload(width: int, height: int, *, virtual_upsample: bool = False,
             pack_rgb_reduction: bool = False, elide_views: bool = False, fuse_final: bool = False) -> dict:
    if elide_views and not virtual_upsample:
        raise ValueError("view elision requires virtual tensor ownership")
    descriptors, layout = build_layout(width, height)
    stages = []
    for stage, (descriptor, layer) in enumerate(zip(descriptors, layout["layers"])):
        pixels = descriptor.output_width * descriptor.output_height
        input_groups = (descriptor.input_channels + 7) // 8
        output_groups = (descriptor.output_channels + 7) // 8
        logical_results = pixels * output_groups
        elided_view = elide_views and stage in (14,17)
        results = 0 if elided_view or (fuse_final and stage==21) else logical_results
        rgb_conv = descriptor.opcode == 1 and descriptor.input_channels == 3
        reduction_beats = (4 if pack_rgb_reduction and rgb_conv else
                           input_groups * descriptor.kernel_width * descriptor.kernel_height)
        dot = (results * reduction_beats
               if descriptor.opcode in (1, 2) else 0)
        dw = results if descriptor.opcode == 3 else 0
        linear = results if descriptor.opcode in (4, 5, 6) else 0
        # The adapter first copies the incoming RGB frame into its C8 input
        # bank while stage_index is 0. Stage 21 instead sends RGB to the
        # separate output-frame writer, not to the scalar tensor write port.
        scalar_writes = (0 if descriptor.opcode == 6 else results) + (width*height if stage == 0 else 0)
        elided_writes = results if virtual_upsample and stage in (14, 17) else 0
        scalar_writes -= elided_writes
        if fuse_final and stage==20:scalar_writes=0
        stages.append({"stage": stage, "name": layer["name"], "opcode": descriptor.opcode,
                       "C8_results": results, "dot_beats": dot, "dw_beats": dw,
                       "logical_C8_results": logical_results, "view_commit": elided_view,
                       "scalar_writes": scalar_writes,
                       # Independent logical input budgets for the column
                       # endpoint. Pointwise mode transfers these 1x1 reads
                       # from scalar to column; arithmetic work is unchanged.
                       "scalar_reads_with_columns": 0 if elided_view or (fuse_final and stage==21) or descriptor.opcode in (1,3) else
                           pixels*input_groups*(2 if descriptor.opcode==5 else 1),
                       "pointwise_reads": pixels*input_groups if descriptor.opcode==2 else 0,
                       "pointwise_stream_beats": pixels*input_groups if descriptor.opcode==2 and input_groups>1 else 0,
                       "pointwise_early_beats": pixels*(input_groups-1) if descriptor.opcode==2 and input_groups>1 else 0,
                       "dot_transactions": results if descriptor.opcode in (1,2) else 0,
                       "dot_requant_restarts": pixels*(output_groups-1) if descriptor.opcode in (1,2) else 0,
                       "next_pixel_columns": max(0,pixels-1) if descriptor.opcode in (1,2,3) else 0,
                       "input_row_words": descriptor.input_width*input_groups,
                       "input_groups": input_groups,
                       "rgb_conv": rgb_conv,
                       "output_width": descriptor.output_width, "output_height": descriptor.output_height,
                       "elided_writes": elided_writes,
                       "dw_warm_beats": max(0,pixels-1)*output_groups if descriptor.opcode==3 else 0,
                       "linear_beats": linear, "minimum_cycles": dot+dw+linear,
                       "useful_macs": pixels*layer["weight_count"]})
    return {"width": width, "height": height, "stages": stages,
            "minimum_cycles": sum(s["minimum_cycles"] for s in stages),
            "useful_macs": sum(s["useful_macs"] for s in stages)}
