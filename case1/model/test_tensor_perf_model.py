"""Regression checks for the boardless tensor performance model."""

from __future__ import annotations

from tensor_perf_model import (
    estimate_tensor_perf, horizontal_window_read_budget, column_window_read_budget,
)


def main() -> int:
    # Observed adapter + production column-cache handshakes; the TB also
    # independently checks every operand in all 22 stages and configuration.
    column_measured = [
        (8,4,False,504,298,1810), (8,4,True,256,298,1066),
        (4,4,False,252,149,905), (4,4,True,166,149,647),
        (12,8,False,1512,894,5430), (12,8,True,692,894,2970),
        (20,12,True,1578,2235,6969), (8,8,True,512,596,2132),
    ]
    for width, height, reuse, columns, scalar, payload in column_measured:
        budget = column_window_read_budget(width, height, horizontal_reuse=reuse)
        assert budget["column_read_requests"] == columns
        assert budget["scalar_read_requests"] == scalar
        assert budget["total_read_transactions"] == columns + scalar
        assert budget["payload_c8_words"] == payload
    for args in [dict(width=6), dict(height=0), dict(width=True),
                 dict(horizontal_reuse=1), dict(horizontal_reuse="true")]:
        try:
            column_window_read_budget(**args)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid column budget input accepted: {args}")
    native_column = column_window_read_budget()
    assert native_column["column_read_requests"] == 1_737_120
    assert native_column["scalar_read_requests"] == 2_860_800
    assert native_column["total_read_transactions"] == 4_597_920
    assert native_column["payload_c8_words"] == 8_072_160
    print("C1_COLUMN_READ_MODEL_TEST_PASS", f"measured_shapes={len(column_measured)}",
          f"native_transactions={native_column['total_read_transactions']}",
          f"native_payload_c8={native_column['payload_c8_words']}")
    # Independent RTL counters/operand scoreboards for these geometries.
    measured = [(4,4,905,647), (8,4,1810,1066), (8,8,3620,2132),
                (12,8,5430,2970), (20,12,13575,6969), (32,16,28960,14320)]
    for width, height, dense, reused in measured:
        budget = horizontal_window_read_budget(width, height)
        assert budget["dense_stage_read_requests"] == dense
        assert budget["reused_stage_read_requests"] == reused
        assert budget["saved_stage_read_requests"] == dense-reused
        assert budget["current_serial_read_cycle_floor"] == 2*reused
        assert budget["single_c8_port_read_cycle_floor"] == reused
    for shape in [(0,4),(4,0),(-4,4),(6,4),(4,6),(8.0,4),(True,4)]:
        try:
            horizontal_window_read_budget(*shape)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid reuse geometry accepted: {shape}")
    native = horizontal_window_read_budget()
    assert native["dense_stage_read_requests"] == 17_376_000
    assert native["current_serial_read_cycle_floor"] == 16_144_320
    assert 0 < native["reused_stage_read_requests"] < native["dense_stage_read_requests"]
    print("C1_HORIZONTAL_READ_MODEL_TEST_PASS", f"measured_shapes={len(measured)}",
          f"native_dense={native['dense_stage_read_requests']}",
          f"native_reused={native['reused_stage_read_requests']}")
    baseline = estimate_tensor_perf()
    assert baseline["stage_read_requests"] == 17_376_000
    assert baseline["stage_write_requests"] == 3_705_600
    assert baseline["logical_64bit_requests"] == 21_388_800
    assert baseline["bus_bytes_per_frame"] == 342_220_800
    assert baseline["memory_cycle_lower_bound"] == 85_555_200
    assert baseline["compute_cycle_lower_bound"] == 6_691_200
    assert not baseline["meets_frame_budget"]

    packed = estimate_tensor_perf(pack_factor=2, read_reuse=9,
                                  outstanding=16)
    assert packed["bus_beats_per_frame"] < baseline["bus_beats_per_frame"]
    assert packed["memory_cycle_lower_bound"] < baseline[
        "memory_cycle_lower_bound"
    ]
    assert packed["bus_bytes_per_frame"] < baseline["bus_bytes_per_frame"]

    # Packing capacity follows bus width, not a fixed AXI128-only rule.
    wide = estimate_tensor_perf(bus_bytes=32, pack_factor=4)
    assert wide["bus_beats_per_frame"] == baseline["bus_beats_per_frame"] // 4
    assert wide["bus_bytes_per_frame"] == baseline["logical_64bit_requests"] * 8

    for bad in (
        {"pack_factor": 0},
        {"read_reuse": 0},
        {"outstanding": 0},
        {"bus_bytes": 10},
        {"bus_bytes": 16, "pack_factor": 3},
        {"bus_bytes": 8, "pack_factor": 2},
    ):
        try:
            estimate_tensor_perf(**bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid input accepted: {bad}")

    print(
        "C1_TENSOR_PERF_MODEL_TEST_PASS",
        "baseline_requests=21388800",
        "baseline_bytes=342220800",
        f"candidate_bytes={packed['bus_bytes_per_frame']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
