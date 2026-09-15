"""Lower-bound schedule check for the dedicated MicroStyle-24 graph.

The estimate assumes every descriptor with MACs has its own multiplier bank,
so all graph stages overlap at steady state.  It verifies architectural
feasibility; weight-memory conflicts, FIFO stalls, pipeline fill/drain and
requant latency must still be measured in RTL and Efinity timing closure.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json

from microstyle_layout import layer_specs


@dataclass(frozen=True)
class ScheduleRow:
    name: str
    macs: int
    parallel_lanes: int
    lower_bound_cycles: int


def estimate_schedule(
    width: int = 640,
    height: int = 480,
    clock_hz: int = 100_000_000,
    frames_per_second: int = 15,
    non_mac_element_lanes: int = 8,
) -> dict:
    if clock_hz <= 0 or frames_per_second <= 0:
        raise ValueError("clock_hz and frames_per_second must be positive")
    if non_mac_element_lanes <= 0:
        raise ValueError("non_mac_element_lanes must be positive")

    rows: list[ScheduleRow] = []
    total_macs = 0
    multiplier_lanes = 0
    for spec in layer_specs(width, height):
        spatial_outputs = spec.output_width * spec.output_height
        macs = spatial_outputs * spec.weight_count
        if macs:
            lanes = spec.mac_lanes
            cycles = (macs + lanes - 1) // lanes
            multiplier_lanes += lanes
            total_macs += macs
        else:
            lanes = non_mac_element_lanes
            channel_groups = (
                spec.output_channels + non_mac_element_lanes - 1
            ) // non_mac_element_lanes
            cycles = spatial_outputs * channel_groups
        rows.append(ScheduleRow(spec.name, macs, lanes, cycles))

    bottleneck = max(rows, key=lambda row: row.lower_bound_cycles)
    frame_budget_cycles = clock_hz // frames_per_second
    reserved_budget_cycles = (clock_hz * 9) // (frames_per_second * 10)
    return {
        "execution_model": "dedicated_multirate_streaming_graph",
        "clock_hz": clock_hz,
        "frames_per_second": frames_per_second,
        "frame_budget_cycles": frame_budget_cycles,
        "reserved_10pct_budget_cycles": reserved_budget_cycles,
        "total_macs": total_macs,
        "multiplier_lanes": multiplier_lanes,
        "bottleneck_stage": bottleneck.name,
        "bottleneck_lower_bound_cycles": bottleneck.lower_bound_cycles,
        "reserved_budget_headroom_cycles": (
            reserved_budget_cycles - bottleneck.lower_bound_cycles
        ),
        "nominal_utilization": (
            bottleneck.lower_bound_cycles * frames_per_second / clock_hz
        ),
        "rows": [asdict(row) for row in rows],
        "limitations": (
            "lower bound only: excludes FIFO stalls, memory banking, "
            "pipeline fill/drain, control and clock-domain effects"
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--clock-hz", type=int, default=100_000_000)
    parser.add_argument("--fps", type=int, default=15)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = estimate_schedule(
        args.width, args.height, args.clock_hz, args.fps
    )
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(
            "C1_MICROSTYLE_SCHEDULE_PASS",
            f"macs={report['total_macs']}",
            f"lanes={report['multiplier_lanes']}",
            f"bottleneck={report['bottleneck_stage']}",
            f"cycles={report['bottleneck_lower_bound_cycles']}",
            f"reserved_headroom={report['reserved_budget_headroom_cycles']}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
