"""Regression checks for the independent 3x3 line/window-cache model."""

from __future__ import annotations

from window_cache_perf_model import estimate_window_cache


def main() -> int:
    reports = {
        (width, height): estimate_window_cache(width, height)
        for width, height in ((8, 8), (16, 16), (64, 48))
    }

    expected_totals = {
        (8, 8): (3024, 408),
        (16, 16): (12096, 1632),
        (64, 48): (145152, 19584),
    }
    for size, (expected_taps, expected_external) in expected_totals.items():
        report = reports[size]
        assert report["logical_tap_requests"] == expected_taps, report
        assert report["external_requests"] == expected_external, report

    # The frozen graph has 8 3x3 stages (2 encoder Conv, 3 DW residual
    # blocks, 2 decoder DW and the final Conv) for every supported size.
    assert all(report["stage_count"] == 8 for report in reports.values())
    assert all(
        report["logical_tap_requests"] > report["external_requests"]
        for report in reports.values()
    )
    assert all(
        0.0 < report["tap_hit_rate"] < 1.0
        and 0.0 < report["external_request_reduction"] < 1.0
        for report in reports.values()
    )

    # A full three-row line buffer should not refill an input row for these
    # even dimensions.  Each physical row is filled once and contains every
    # C8 group, so external words remain width * height * groups.
    for report in reports.values():
        for stage in report["stages"]:
            expected = (
                stage["input_width"]
                * stage["input_height"]
                * stage["input_groups"]
            )
            assert stage["external_requests"] == expected, stage
            assert stage["line_fill_rows"] == stage["input_height"], stage
            assert stage["tap_hits"] + stage["tap_misses"] == stage[
                "logical_tap_requests"
            ]

    # Stride-1 3x3 windows have a 1/9 external-word ratio (8/9 request
    # reduction), while the even stride-2 encoder stages have a 4/9 ratio.
    # Check representative rows rather than hard-coding the aggregate mix.
    for report in reports.values():
        first = report["stages"][0]
        assert first["stride"] == 2
        assert first["external_requests"] * 9 == (
            first["logical_tap_requests"] * 4
        ), first
        stride1 = next(stage for stage in report["stages"] if stage["stride"] == 1)
        assert stride1["external_requests"] * 9 == stride1[
            "logical_tap_requests"
        ], stride1

    # A deliberately undersized two-row cache must expose refills; this keeps
    # the model sensitive to the line-buffer depth instead of being a formula
    # that always reports ideal reuse.
    ideal = reports[(8, 8)]
    shallow = estimate_window_cache(8, 8, line_rows=2)
    assert shallow["external_requests"] > ideal["external_requests"]
    assert shallow["external_request_reduction"] < ideal[
        "external_request_reduction"
    ]

    print(
        "C1_WINDOW_CACHE_MODEL_TEST_PASS",
        "sizes=8x8,16x16,64x48",
        "line_rows=3",
        "8x8_external=",
        ideal["external_requests"],
        "64x48_external=",
        reports[(64, 48)]["external_requests"],
    )
    for (width, height), report in reports.items():
        print(
            f"C1_WINDOW_CACHE_MODEL_RESULT size={width}x{height}",
            f"tap_requests={report['logical_tap_requests']}",
            f"external_requests={report['external_requests']}",
            f"tap_hit_rate={report['tap_hit_rate']:.6f}",
            f"request_reduction={report['external_request_reduction']:.6f}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
