"""Regression checks for the MicroStyle-24 steady-state schedule budget."""

from __future__ import annotations

from microstyle_schedule import estimate_schedule


def main() -> int:
    report = estimate_schedule()
    assert report["total_macs"] == 428_236_800
    assert report["multiplier_lanes"] == 80
    assert report["bottleneck_stage"] == "decoder1.pointwise1x1"
    assert report["bottleneck_lower_bound_cycles"] == 5_898_240
    assert report["frame_budget_cycles"] == 6_666_666
    assert report["reserved_10pct_budget_cycles"] == 6_000_000
    assert report["reserved_budget_headroom_cycles"] == 101_760
    assert abs(report["nominal_utilization"] - 0.884736) < 1e-12
    print(
        "C1_MICROSTYLE_SCHEDULE_TEST_PASS",
        "lanes=80",
        "bottleneck_cycles=5898240",
        "reserved_headroom=101760",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
