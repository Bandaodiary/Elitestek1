"""Boardless performance model for the case-1 tensor data plane.

The default RTL exposes a scalar tensor port. The optional column port has a
separate request budget; it must not be mistaken for wider DDR transactions.
This model turns the descriptor graph into a reproducible traffic budget and
lets the next performance implementation be compared against the same
assumptions.  It is a lower-bound model, not a promise about DDR efficiency:
``read_reuse`` represents an ideal line/tile-cache hit factor, ``pack_factor``
represents contiguous 64-bit beats packed into one AXI beat, and
``outstanding``/``response_latency`` model memory-level parallelism.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
import sys

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

from microstyle_layout import layer_specs  # noqa: E402


@dataclass(frozen=True)
class TrafficRow:
    name: str
    opcode: int
    output_pixels: int
    input_groups: int
    output_groups: int
    tap_reads: int
    residual_reads: int
    tensor_writes: int


def _ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def traffic_rows(width: int = 640, height: int = 480) -> list[TrafficRow]:
    """Derive request counts from the sequential adapter's state machine.

    A convolution/DW/1x1 output group consumes one request per input group
    and per tap.  Residual add consumes one primary and one residual request;
    upsample consumes one source group.  The final RGB stage streams its
    result and therefore does not write a tensor bank.
    """

    rows: list[TrafficRow] = []
    for spec in layer_specs(width, height):
        output_pixels = spec.output_width * spec.output_height
        input_groups = _ceil_div(spec.input_channels, 8)
        output_groups = _ceil_div(spec.output_channels, 8)
        if spec.opcode in (1, 2, 3):  # conv3x3, pointwise, depthwise
            taps = spec.kernel * spec.kernel if spec.opcode != 2 else 1
            # The adapter emits output groups after the engine consumes all
            # input groups; the memory window is therefore fetched once per
            # input group, not once per output group.
            tap_reads = output_pixels * input_groups * taps
            residual_reads = 0
        elif spec.opcode == 5:  # residual add
            tap_reads = output_pixels * input_groups
            residual_reads = output_pixels * input_groups
        elif spec.opcode == 4:  # nearest-neighbour upsample
            tap_reads = output_pixels * input_groups
            residual_reads = 0
        elif spec.opcode == 6:  # output stream
            tap_reads = output_pixels * input_groups
            residual_reads = 0
        else:
            raise ValueError(f"unsupported opcode {spec.opcode} in {spec.name}")

        tensor_writes = (
            0 if spec.opcode == 6 else output_pixels * output_groups
        )
        rows.append(
            TrafficRow(
                name=spec.name,
                opcode=spec.opcode,
                output_pixels=output_pixels,
                input_groups=input_groups,
                output_groups=output_groups,
                tap_reads=tap_reads,
                residual_reads=residual_reads,
                tensor_writes=tensor_writes,
            )
        )
    return rows


def horizontal_window_read_budget(width: int = 640, height: int = 480) -> dict:
    """Count adapter-side reads for the fixed graph with horizontal reuse.

    This is not an AXI/DDR byte or cycle estimate. Do not multiply its saving
    by an ideal line-cache reuse factor: both remove overlapping logical work.
    The graph uses distinct input/output tensor banks for its windowed stages.
    """
    if any(not isinstance(v, int) or isinstance(v, bool) or v < 4 or v % 4
           for v in (width, height)):
        raise ValueError("dimensions must be integer multiples of four >= 4")
    specs = layer_specs(width, height)
    dense = sum(row.tap_reads + row.residual_reads for row in traffic_rows(width, height))
    saved = 0
    for spec in specs:
        if spec.opcode in (1, 3) and spec.kernel == 3 and spec.stride in (1, 2):
            overlaps = (spec.output_width - 1) * spec.output_height
            saved += overlaps * _ceil_div(spec.input_channels, 8) * 3 * (3-spec.stride)
    return {
        "width": width, "height": height,
        "dense_stage_read_requests": dense,
        "reused_stage_read_requests": dense - saved,
        "saved_stage_read_requests": saved,
        # Current adapter has distinct request and response states and forbids
        # a same-cycle response. This bound excludes all other work/stalls.
        "current_serial_read_cycle_floor": 2 * (dense - saved),
        # Even an ideal pipelined interface returning one C8 word per clock
        # cannot serve more than this count within fewer clocks.
        "single_c8_port_read_cycle_floor": dense - saved,
        "scope": "adapter_logical_reads_not_ddr_bytes_or_cycles",
    }


def column_window_read_budget(
    width: int = 640, height: int = 480, *, horizontal_reuse: bool = True
) -> dict:
    """Count the adapter's column and remaining scalar reads, not AXI traffic.

    Window columns carry three C8 lanes even when boundary rows coincide.
    Request packing changes transaction count, not the logical C8 payload.
    No hit-rate, miss latency, clock, or external-memory bandwidth is assumed.
    """
    if not isinstance(horizontal_reuse, bool):
        raise ValueError("horizontal_reuse must be a bool")
    reference = horizontal_window_read_budget(width, height)
    window_dense = sum(
        spec.output_width * spec.output_height * _ceil_div(spec.input_channels, 8) * 9
        for spec in layer_specs(width, height)
        if spec.opcode in (1, 3) and spec.kernel == 3
    )
    saved = reference["saved_stage_read_requests"] if horizontal_reuse else 0
    columns = (window_dense - saved) // 3
    scalar = reference["dense_stage_read_requests"] - window_dense
    return {
        "width": width, "height": height, "horizontal_reuse": horizontal_reuse,
        "column_read_requests": columns,
        "scalar_read_requests": scalar,
        "total_read_transactions": columns + scalar,
        "payload_c8_words": 3 * columns + scalar,
        "scope": "adapter_read_transactions_not_axi_or_cycles",
    }


def estimate_tensor_perf(
    width: int = 640,
    height: int = 480,
    clock_hz: int = 100_000_000,
    frames_per_second: int = 15,
    bus_bytes: int = 16,
    pack_factor: int = 1,
    read_reuse: int = 1,
    outstanding: int = 1,
    response_latency: int = 4,
    mac_lanes: int = 64,
) -> dict:
    """Return traffic and optimistic frame-cycle bounds.

    ``read_reuse=1`` and ``pack_factor=1`` reproduce the current sequential
    adapter/bridge contract.  The model intentionally reports assumptions in
    the result so candidate numbers cannot be mistaken for measurements.
    """

    positive = {
        "width": width,
        "height": height,
        "clock_hz": clock_hz,
        "frames_per_second": frames_per_second,
        "bus_bytes": bus_bytes,
        "pack_factor": pack_factor,
        "read_reuse": read_reuse,
        "outstanding": outstanding,
        "response_latency": response_latency,
        "mac_lanes": mac_lanes,
    }
    if any(value <= 0 for value in positive.values()):
        raise ValueError("all dimensions, rates and factors must be positive")
    if bus_bytes < 8 or bus_bytes % 8:
        raise ValueError("bus_bytes must be an integer number of 64-bit beats")
    if pack_factor > bus_bytes // 8:
        raise ValueError("pack_factor exceeds 64-bit words per bus beat")

    rows = traffic_rows(width, height)
    source_writes = width * height
    stage_reads = sum(row.tap_reads + row.residual_reads for row in rows)
    stage_writes = sum(row.tensor_writes for row in rows)
    logical_requests = source_writes + stage_reads + stage_writes

    # Reads and writes are packed independently; a cache cannot combine a
    # read and a write into one bus beat.  Source ingress is a write stream,
    # just like intermediate/final tensor stores.
    effective_read_requests = _ceil_div(stage_reads, read_reuse)
    read_bus_beats = _ceil_div(effective_read_requests, pack_factor)
    write_bus_beats = _ceil_div(source_writes + stage_writes, pack_factor)
    bus_beats = read_bus_beats + write_bus_beats
    bus_bytes_per_frame = bus_beats * bus_bytes

    # A one-beat-per-cycle datapath and a latency/outstanding lower bound are
    # both necessary.  This remains optimistic: arbitration, refresh, burst
    # boundaries and compute/memory overlap are not modeled.
    issue_bound = bus_beats
    latency_bound = _ceil_div(bus_beats * response_latency, outstanding)
    memory_cycles = max(issue_bound, latency_bound)

    total_macs = sum(
        row.output_pixels * spec.weight_count
        for row, spec in zip(rows, layer_specs(width, height))
    )
    compute_cycles = _ceil_div(total_macs, mac_lanes)
    frame_budget_cycles = clock_hz // frames_per_second
    frame_cycles = max(memory_cycles, compute_cycles)

    return {
        "model": "sequential_tensor_traffic_lower_bound",
        "width": width,
        "height": height,
        "clock_hz": clock_hz,
        "frames_per_second": frames_per_second,
        "source_write_requests": source_writes,
        "stage_read_requests": stage_reads,
        "stage_write_requests": stage_writes,
        "logical_64bit_requests": logical_requests,
        "read_reuse": read_reuse,
        "pack_factor": pack_factor,
        "outstanding": outstanding,
        "response_latency": response_latency,
        "bus_bytes": bus_bytes,
        "bus_beats_per_frame": bus_beats,
        "bus_bytes_per_frame": bus_bytes_per_frame,
        "bus_gib_per_second": (
            bus_bytes_per_frame * frames_per_second / (1024**3)
        ),
        "total_macs": total_macs,
        "mac_lanes": mac_lanes,
        "memory_cycle_lower_bound": memory_cycles,
        "compute_cycle_lower_bound": compute_cycles,
        "frame_cycle_lower_bound": frame_cycles,
        "frame_budget_cycles": frame_budget_cycles,
        "optimistic_fps_bound": clock_hz / frame_cycles,
        "meets_frame_budget": frame_cycles <= frame_budget_cycles,
        "rows": [asdict(row) for row in rows],
        "limitations": [
            "ideal cache reuse; no cache miss distribution",
            "ideal AXI packing and one beat per issue cycle",
            "no arbitration, refresh, CDC, or descriptor overhead",
            "does not prove trained-model RTL bit-exactness",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--clock-hz", type=int, default=100_000_000)
    parser.add_argument("--fps", type=int, default=15)
    parser.add_argument("--pack-factor", type=int, default=1)
    parser.add_argument("--read-reuse", type=int, default=1)
    parser.add_argument("--outstanding", type=int, default=1)
    parser.add_argument("--response-latency", type=int, default=4)
    parser.add_argument("--mac-lanes", type=int, default=64)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = estimate_tensor_perf(
        width=args.width,
        height=args.height,
        clock_hz=args.clock_hz,
        frames_per_second=args.fps,
        pack_factor=args.pack_factor,
        read_reuse=args.read_reuse,
        outstanding=args.outstanding,
        response_latency=args.response_latency,
        mac_lanes=args.mac_lanes,
    )
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            "C1_TENSOR_PERF_MODEL_PASS",
            f"requests={report['logical_64bit_requests']}",
            f"beats={report['bus_beats_per_frame']}",
            f"memory_cycles={report['memory_cycle_lower_bound']}",
            f"compute_cycles={report['compute_cycle_lower_bound']}",
            f"fps_bound={report['optimistic_fps_bound']:.3f}",
            f"meets={int(report['meets_frame_budget'])}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
