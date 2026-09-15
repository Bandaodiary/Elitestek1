"""Regression checks for the compact case-1 throughput sweep.

The checks intentionally exercise only small arithmetic summaries and do not
instantiate Vivado or create a simulation work tree.  Full-frame constants
are useful here because they lock the frozen 640x480 descriptor graph to the
same traffic numbers used by ``tensor_perf_model.py``.
"""

from __future__ import annotations

from throughput_sweep import (
    EngineConfig,
    _three_row_external_words,
    compact_rows,
    default_sweep,
    parallel_mac_sweep,
    dw_weight_cache_sweep,
    mac_prefetch_overlap_sweep,
    shared_engine_cycles,
    traffic_pair_sweep,
    fabric_outstanding_sweep,
    traffic_budget,
)
from microstyle_layout import layer_specs
from tensor_perf_model import traffic_rows


def main() -> int:
    baseline = traffic_budget()
    assert baseline.source_write_requests == 307_200
    assert baseline.uncached_stage_read_requests == 17_376_000
    assert baseline.stage_read_requests == 17_376_000
    assert baseline.stage_write_requests == 3_705_600
    assert baseline.logical_64bit_requests == 21_388_800
    assert baseline.read_axi_beats == 17_376_000
    assert baseline.write_axi_beats == 4_012_800
    assert baseline.bus_bytes_per_frame == 342_220_800

    cached = traffic_budget(
        cache_enabled=True, line_rows=3, pack_factor=2, burst_beats=16
    )
    assert cached.uncached_stage_read_requests == baseline.stage_read_requests
    assert cached.stage_read_requests < baseline.stage_read_requests
    assert cached.read_axi_beats == 2_409_600
    assert cached.write_axi_beats == 2_006_400
    assert cached.read_bursts == 150_600
    assert cached.write_bursts == 125_400
    # Writes are not line-cache hits and remain a substantial fraction after
    # ideal read/write packing.
    assert 0.45 < cached.write_beat_share < 0.46

    # The full-row formula must agree with the independent 3-row cache model's
    # per-stage external tap count for every 3x3 descriptor.
    for row, spec in zip(traffic_rows(64, 48), layer_specs(64, 48)):
        if spec.kernel == 3 and spec.opcode in (1, 3):
            expected = spec.input_width * spec.input_height * (
                (spec.input_channels + 7) // 8
            )
            assert _three_row_external_words(row, spec, 3) == expected

    scenarios = default_sweep()
    rows = {row["name"]: row for row in compact_rows(scenarios)}
    assert rows["cache3_pack2_burst16_serial_fabric"][
        "effective_outstanding"
    ] == 1
    assert rows["cache3_pack2_burst16_real_out16"][
        "effective_outstanding"
    ] == 16
    assert not rows["cache3_pack2_burst16_dual_wide"][
        "meets_15fps_optimistic"
    ]
    assert rows["cache3_pack2_burst16_dedicated_80_lane"][
        "meets_15fps_optimistic"
    ]
    assert rows["cache3_pack2_burst16_dedicated_80_lane"][
        "meets_reserved_budget"
    ]
    assert not rows["cache3_pack2_burst16_dual_wide"][
        "meets_reserved_budget"
    ]
    assert rows["cache3_pack2_burst16_dedicated_80_lane"][
        "optimistic_fps_bound"
    ] > 15.0

    # A two-group shared engine removes some dot/DW bubbles, but the graph is
    # still sequential at the stage boundary; the arithmetic lane count alone
    # cannot turn it into a one-pixel-per-cycle pipeline.
    p1 = shared_engine_cycles(
        64,
        48,
        EngineConfig(
            name="p1", dot_tile_ii=1, dw_weight_prefetch_cycles=1,
            scalar_mac_lanes=64,
        ),
    )
    p2 = shared_engine_cycles(
        64,
        48,
        EngineConfig(
            name="p2", output_group_parallelism=2, dot_tile_ii=1,
            dw_weight_prefetch_cycles=1, scalar_mac_lanes=128,
            egress_groups_per_cycle=2,
        ),
    )
    assert p2["engine_cycles"] < p1["engine_cycles"]
    assert p2["engine_cycles"] > 0
    assert p2["engine_cycles"] > p2["arithmetic_lower_bound_cycles"]

    lane_sweep = parallel_mac_sweep()
    assert [row["name"] for row in lane_sweep] == [
        "P1_II2_DW9", "P1_II1_DW1", "P2_II1_DW1", "P4_II1_DW1",
        "P8_II1_DW1",
    ]
    # Once all output groups fit in one batch, replication saturates at the
    # serialized collect/bypass schedule instead of reaching the arithmetic
    # lower bound.
    assert lane_sweep[-1]["engine_cycles"] == 14_361_600
    assert lane_sweep[-1]["fsm_bubble_cycles"] > 0
    assert all(
        lane_sweep[i]["engine_cycles"] >= lane_sweep[i + 1]["engine_cycles"]
        for i in range(len(lane_sweep) - 1)
    )
    dw_cache = dw_weight_cache_sweep()
    assert [row["name"] for row in dw_cache] == [
        "P1_II2_DW9", "P1_II2_DW9_TILE_CACHE", "P1_II1_DW9_TILE_CACHE",
    ]
    assert dw_cache[0]["engine_cycles"] == 39_571_200
    assert dw_cache[1]["engine_cycles"] == 30_048_184
    assert dw_cache[1]["cycles_saved_vs_baseline"] == 9_523_016
    assert dw_cache[1]["compute_fps_bound"] > 3.3
    assert dw_cache[2]["engine_cycles"] < dw_cache[1]["engine_cycles"]
    mac_overlap = mac_prefetch_overlap_sweep()
    assert [row["name"] for row in mac_overlap] == [
        "P1_II2_DW9", "P1_MAC_OVERLAP_DW9",
        "P1_MAC_OVERLAP_DW9_TILE_CACHE",
    ]
    assert mac_overlap[1]["engine_cycles"] == 31_238_400
    assert mac_overlap[1]["cycles_saved_vs_baseline"] == 8_332_800
    assert mac_overlap[2]["engine_cycles"] == 21_715_384
    assert mac_overlap[2]["compute_fps_bound"] > 4.6
    try:
        parallel_mac_sweep(clock_hz=0)
    except ValueError:
        pass
    else:
        raise AssertionError("zero clock_hz accepted")

    pair_sweep = traffic_pair_sweep()
    assert [row["name"] for row in pair_sweep] == [
        "single_beat", "pack2_trace_pair18pct", "pack2_ideal_pair100pct",
    ]
    assert pair_sweep[0]["read_beats"] == 4_819_200
    assert pair_sweep[1]["read_beats"] == 4_379_224
    assert pair_sweep[2]["read_beats"] == 2_409_600
    assert pair_sweep[1]["memory_cycles_out16"] > pair_sweep[2][
        "memory_cycles_out16"
    ]

    # A fabric-level descriptor queue, unlike a leaf FIFO, must reduce the
    # latency term monotonically.  This table is deliberately memory-only:
    # compute/FSM cycles remain the separate bottleneck in the report.
    out_sweep = fabric_outstanding_sweep()
    assert [row["requested_outstanding"] for row in out_sweep] == [1, 2, 4, 8, 16, 32]
    assert all(
        out_sweep[i]["memory_cycles"] >= out_sweep[i + 1]["memory_cycles"]
        for i in range(len(out_sweep) - 1)
    )
    assert out_sweep[-1]["memory_cycles"] <= out_sweep[0]["memory_cycles"]
    assert out_sweep[-1]["meets_15fps_memory_only"]

    for bad in (
        {"pack_factor": 0},
        {"pack_factor": 3},
        {"burst_beats": 0},
        {"read_pair_fraction": 1.1},
        {"write_pair_fraction": -0.1},
    ):
        try:
            traffic_budget(**bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid input accepted: {bad}")

    print(
        "C1_THROUGHPUT_SWEEP_TEST_PASS",
        f"baseline_bytes={baseline.bus_bytes_per_frame}",
        f"cached_bytes={cached.bus_bytes_per_frame}",
        f"cached_write_share={cached.write_beat_share:.6f}",
        f"dedicated_fps={rows['cache3_pack2_burst16_dedicated_80_lane']['optimistic_fps_bound']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
