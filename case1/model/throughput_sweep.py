"""Small, board-independent throughput sweep for case 1.

The existing :mod:`tensor_perf_model` gives a deliberately simple traffic
lower bound.  This module keeps that baseline, but makes the assumptions that
matter for the next RTL step explicit:

* a three-row cache replaces only 3x3 Conv/DW tap reads with complete-row
  refills; writes are never silently reduced by the cache;
* AXI128 packing is represented by a pair fraction (two 64-bit logical words
  per beat), and a burst length is charged separately from payload beats;
* ``requested_outstanding`` is ignored unless the fabric has a real AR/R
  descriptor queue.  This prevents the leaf prototype's queue from being
  mistaken for bus-level memory-level parallelism;
* the shared RTL engine is modelled from its visible FSM contracts: one
  collect phase per pixel, a dot prefetch/feed pair, and nine DW weight
  prefetch cycles.  Output-group parallelism is therefore not conflated with
  a fully pipelined graph.

Numbers are structural estimates, not an FPGA timing or DDR measurement.
The code intentionally uses only the frozen Python descriptor graph and small
integer arithmetic, so it is safe to run as part of the normal regression.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from math import ceil
from pathlib import Path
import sys
from typing import Iterable

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from microstyle_layout import LayerSpec, layer_specs  # noqa: E402
from microstyle_schedule import estimate_schedule  # noqa: E402
from tensor_perf_model import TrafficRow, traffic_rows  # noqa: E402


AXI_BEAT_BYTES = 16
LOGICAL_WORD_BYTES = 8


@dataclass(frozen=True)
class EngineConfig:
    """Control assumptions for the *shared* engine model.

    ``output_group_parallelism`` is the number of independent dot/DW output
    groups launched as one batch.  It does not imply a wider adapter output;
    ``egress_groups_per_cycle`` describes that separately.
    """

    name: str
    output_group_parallelism: int = 1
    dot_tile_ii: int = 2
    dw_weight_prefetch_cycles: int = 9
    core_start_cycles: int = 1
    core_result_cycles: int = 1
    egress_groups_per_cycle: int = 1
    overlap_batch_egress: bool = False
    scalar_mac_lanes: int = 64
    # When true, a DW weight tile is fetched from the bank once per output
    # group and reused on later pixels of the same stage.  The RTL equivalent
    # is the optional CACHE_DW_WEIGHT_TILES tile RAM; the first pixel still
    # pays the configured prefetch latency and a cached tile costs one load
    # cycle in the current FSM model.
    dw_weight_cache_reuse: bool = False


@dataclass(frozen=True)
class TrafficBudget:
    source_write_requests: int
    # Uncached tap+residual reads are retained as a reference so a cache
    # scenario does not make the logical graph appear to have fewer ops.
    uncached_stage_read_requests: int
    stage_read_requests: int
    stage_write_requests: int
    logical_64bit_requests: int
    read_pair_fraction: float
    write_pair_fraction: float
    read_axi_beats: int
    write_axi_beats: int
    read_bursts: int
    write_bursts: int
    bus_axi_beats: int
    bus_bytes_per_frame: int
    write_beat_share: float
    cache_enabled: bool
    line_rows: int


def _ceil_div(value: int, divisor: int) -> int:
    if divisor <= 0:
        raise ValueError("divisor must be positive")
    return (value + divisor - 1) // divisor


def _validate_pair_fraction(value: float, name: str) -> float:
    if not 0.0 <= value <= 1.0:
        raise ValueError(f"{name} must be in [0, 1]")
    return float(value)


def _three_row_external_words(row: TrafficRow, spec: LayerSpec, line_rows: int) -> int:
    """Return external 64-bit words for the supported full-row cache.

    For the frozen graph and even dimensions, a three-row raster cache touches
    every physical input row exactly once for a 3x3 stage.  Keeping this as an
    integer formula avoids iterating over the 17M native tap accesses in every
    sweep.  ``window_cache_perf_model`` independently checks the same relation
    on 8x8, 16x16 and 64x48 shapes.
    """

    if line_rows != 3:
        # The sweep deliberately does not invent an eviction model for a
        # shallow cache.  Returning the uncached count is conservative and
        # keeps the distinction visible in the report.
        return row.tap_reads
    if spec.kernel == 3 and spec.opcode in (1, 3):
        groups = _ceil_div(spec.input_channels, 8)
        return spec.input_width * spec.input_height * groups
    return row.tap_reads


def _pair_beats(requests: int, pair_fraction: float) -> int:
    """Count AXI beats when a fraction of logical requests forms pairs.

    ``pair_fraction=1`` means every request has a partner and gives the ideal
    2:1 AXI128 packing.  A pair saves exactly one beat, hence the ``/2`` term.
    """

    pair_fraction = _validate_pair_fraction(pair_fraction, "pair_fraction")
    saved = int(requests * pair_fraction / 2.0)
    return requests - saved


def _burst_count(beats: int, burst_beats: int) -> int:
    if beats == 0:
        return 0
    return _ceil_div(beats, burst_beats)


def traffic_budget(
    width: int = 640,
    height: int = 480,
    *,
    cache_enabled: bool = False,
    line_rows: int = 3,
    pack_factor: int = 1,
    burst_beats: int = 1,
    read_pair_fraction: float | None = None,
    write_pair_fraction: float | None = None,
) -> TrafficBudget:
    """Build a traffic budget from the frozen 22-stage descriptor graph."""

    if width <= 0 or height <= 0:
        raise ValueError("width and height must be positive")
    if pack_factor not in (1, 2):
        raise ValueError("pack_factor must be 1 or 2 for the AXI128 seam")
    if burst_beats <= 0 or burst_beats > 256:
        raise ValueError("burst_beats must be in 1..256")
    if line_rows <= 0:
        raise ValueError("line_rows must be positive")

    if read_pair_fraction is None:
        read_pair_fraction = 1.0 if pack_factor == 2 else 0.0
    if write_pair_fraction is None:
        write_pair_fraction = 1.0 if pack_factor == 2 else 0.0
    read_pair_fraction = _validate_pair_fraction(read_pair_fraction, "read_pair_fraction")
    write_pair_fraction = _validate_pair_fraction(write_pair_fraction, "write_pair_fraction")

    rows = traffic_rows(width, height)
    specs = layer_specs(width, height)
    source_writes = width * height
    uncached_stage_reads = sum(row.tap_reads + row.residual_reads for row in rows)
    stage_reads = 0
    for row, spec in zip(rows, specs):
        if cache_enabled:
            tap_reads = _three_row_external_words(row, spec, line_rows)
        else:
            tap_reads = row.tap_reads
        # Residual reads are intentionally not claimed as line-cache hits: the
        # current cache sideband is a 3x3 source-row contract.
        stage_reads += tap_reads + row.residual_reads
    stage_writes = sum(row.tensor_writes for row in rows)

    read_beats = _pair_beats(stage_reads, read_pair_fraction)
    write_beats = _pair_beats(source_writes + stage_writes, write_pair_fraction)
    read_bursts = _burst_count(read_beats, burst_beats)
    write_bursts = _burst_count(write_beats, burst_beats)
    total_beats = read_beats + write_beats
    return TrafficBudget(
        source_write_requests=source_writes,
        uncached_stage_read_requests=uncached_stage_reads,
        stage_read_requests=stage_reads,
        stage_write_requests=stage_writes,
        logical_64bit_requests=source_writes + uncached_stage_reads + stage_writes,
        read_pair_fraction=read_pair_fraction,
        write_pair_fraction=write_pair_fraction,
        read_axi_beats=read_beats,
        write_axi_beats=write_beats,
        read_bursts=read_bursts,
        write_bursts=write_bursts,
        bus_axi_beats=total_beats,
        bus_bytes_per_frame=total_beats * AXI_BEAT_BYTES,
        write_beat_share=write_beats / total_beats if total_beats else 0.0,
        cache_enabled=cache_enabled,
        line_rows=line_rows,
    )


def _memory_cycles(
    traffic: TrafficBudget,
    *,
    response_latency: int,
    requested_outstanding: int,
    fabric_supports_outstanding: bool,
    burst_address_cycles: int,
    overlap_read_write: bool,
) -> dict[str, int | bool]:
    if response_latency <= 0 or requested_outstanding <= 0:
        raise ValueError("response_latency and requested_outstanding must be positive")
    effective_outstanding = (
        requested_outstanding if fabric_supports_outstanding else 1
    )

    def channel(beats: int, bursts: int) -> tuple[int, int, int]:
        issue = beats + bursts * burst_address_cycles
        latency = _ceil_div(beats * response_latency, effective_outstanding)
        return issue, latency, max(issue, latency)

    read_issue, read_latency, read_cycles = channel(
        traffic.read_axi_beats, traffic.read_bursts
    )
    write_issue, write_latency, write_cycles = channel(
        traffic.write_axi_beats, traffic.write_bursts
    )
    total_beats = traffic.bus_axi_beats
    total_bursts = traffic.read_bursts + traffic.write_bursts
    serialized_issue = total_beats + total_bursts * burst_address_cycles
    serialized_latency = _ceil_div(total_beats * response_latency, effective_outstanding)
    serialized = max(serialized_issue, serialized_latency)
    channel_overlap = max(read_cycles, write_cycles) if overlap_read_write else serialized
    return {
        "effective_outstanding": effective_outstanding,
        "outstanding_honored": fabric_supports_outstanding,
        "read_issue_cycles": read_issue,
        "write_issue_cycles": write_issue,
        "read_latency_cycles": read_latency,
        "write_latency_cycles": write_latency,
        "serialized_memory_cycles": serialized,
        "channel_overlap_memory_cycles": channel_overlap,
    }


def _batch_cycles(
    groups: int,
    *,
    compute_cycles: int,
    egress_groups_per_cycle: int,
    overlap_egress: bool,
) -> int:
    egress = _ceil_div(groups, egress_groups_per_cycle)
    if overlap_egress:
        return max(compute_cycles, egress)
    # ``compute_cycles`` already includes one result/retirement cycle.  Only
    # the cycles beyond that first result need to be added for a narrow output
    # bus.  This keeps P=1 exactly equal to the current engine contract.
    return compute_cycles + max(0, egress - 1)


def shared_engine_cycles(
    width: int,
    height: int,
    config: EngineConfig,
) -> dict:
    """Estimate cycles of the current sequential engine under a config."""

    if config.output_group_parallelism <= 0:
        raise ValueError("output_group_parallelism must be positive")
    if config.dot_tile_ii <= 0 or config.dw_weight_prefetch_cycles < 0:
        raise ValueError("invalid engine initiation/prefetch cycles")
    if config.core_start_cycles < 0 or config.core_result_cycles <= 0:
        raise ValueError("invalid core latency assumptions")
    if config.egress_groups_per_cycle <= 0 or config.scalar_mac_lanes <= 0:
        raise ValueError("invalid egress or MAC lane count")

    specs = layer_specs(width, height)
    stage_rows: list[dict[str, int | str]] = []
    total_cycles = 0
    total_macs = 0
    for spec in specs:
        groups_in = _ceil_div(spec.input_channels, 8)
        groups_out = _ceil_div(spec.output_channels, 8)
        pixels = spec.output_width * spec.output_height
        taps = spec.kernel * spec.kernel if spec.opcode != 2 else 1
        macs = pixels * spec.weight_count
        total_macs += macs
        collect = groups_in
        if spec.opcode in (1, 2):  # Conv3x3 / pointwise
            batches = _ceil_div(groups_out, config.output_group_parallelism)
            tiles = groups_in * taps
            one_batch_compute = (
                config.core_start_cycles
                + tiles * config.dot_tile_ii
                + config.core_result_cycles
            )
            batch_cycles = 0
            remaining = groups_out
            for _ in range(batches):
                this_batch = min(remaining, config.output_group_parallelism)
                batch_cycles += _batch_cycles(
                    this_batch,
                    compute_cycles=one_batch_compute,
                    egress_groups_per_cycle=config.egress_groups_per_cycle,
                    overlap_egress=config.overlap_batch_egress,
                )
                remaining -= this_batch
            per_pixel = collect + batch_cycles
            kind = "conv"
        elif spec.opcode == 3:  # DW3x3
            batches = _ceil_div(groups_out, config.output_group_parallelism)
            def dw_batch_cycles(prefetch_cycles: int) -> int:
                one_batch_compute = (
                    config.core_start_cycles
                    + prefetch_cycles
                    + 1  # one window feed
                    + config.core_result_cycles
                )
                total = 0
                remaining = groups_out
                for _ in range(batches):
                    this_batch = min(remaining, config.output_group_parallelism)
                    total += _batch_cycles(
                        this_batch,
                        compute_cycles=one_batch_compute,
                        egress_groups_per_cycle=config.egress_groups_per_cycle,
                        overlap_egress=config.overlap_batch_egress,
                    )
                    remaining -= this_batch
                return total

            first_batch_cycles = dw_batch_cycles(config.dw_weight_prefetch_cycles)
            # Keep the per-pixel diagnostic field tied to the uncached first
            # pixel even when the stage total uses the cached steady state.
            batch_cycles = first_batch_cycles
            if config.dw_weight_cache_reuse and pixels > 1:
                # The optional RTL cache adds one registered tile load for a
                # group hit; the first pixel of each stage still fills all
                # group tiles from the linear bank.
                cached_batch_cycles = dw_batch_cycles(1)
                per_pixel = collect + cached_batch_cycles
                stage_cycles = (
                    collect + first_batch_cycles
                    + (pixels - 1) * per_pixel
                )
            else:
                batch_cycles = first_batch_cycles
                per_pixel = collect + batch_cycles
                stage_cycles = pixels * per_pixel
            kind = "dw"
        else:
            # Residual/upsample/output stages are still serialized by the
            # adapter contract; they have no dot tile to parallelize here.
            per_pixel = collect + groups_out
            batch_cycles = groups_out
            batches = groups_out
            kind = "bypass"
        if spec.opcode != 3 or not config.dw_weight_cache_reuse:
            stage_cycles = pixels * per_pixel
        total_cycles += stage_cycles
        stage_rows.append(
            {
                "name": spec.name,
                "kind": kind,
                "pixels": pixels,
                "input_groups": groups_in,
                "output_groups": groups_out,
                "batches_per_pixel": batches,
                "macs": macs,
                "cycles": stage_cycles,
            }
        )

    arithmetic_lower_bound = _ceil_div(total_macs, config.scalar_mac_lanes)
    return {
        "model": "shared_sequential_engine_fsm",
        "config": asdict(config),
        "total_macs": total_macs,
        "engine_cycles": total_cycles,
        "arithmetic_lower_bound_cycles": arithmetic_lower_bound,
        "effective_scalar_mac_rate": (
            total_macs / total_cycles if total_cycles else 0.0
        ),
        "stages": stage_rows,
        "limitations": [
            "one collect phase per output pixel",
            "no inter-stage or inter-pixel overlap",
            "weight/cache refill latency represented by fixed cycle parameters",
            "parameter load/repack and descriptor setup overhead omitted",
            "does not model AXI stalls or output FIFO depth",
        ],
    }


def parallel_mac_sweep(
    width: int = 640,
    height: int = 480,
    clock_hz: int = 100_000_000,
) -> list[dict[str, int | float | str]]:
    """Sweep output-group lanes and expose the residual FSM bubble.

    ``output_group_parallelism`` replicates complete dot/DW output groups;
    it does *not* add pixel or stage overlap.  The final P=8 row is therefore
    a useful saturation check rather than a proposed implementation size.
    """

    if width <= 0 or height <= 0 or clock_hz <= 0:
        raise ValueError("width, height and clock_hz must be positive")

    configs = [
        EngineConfig(
            name="P1_II2_DW9", output_group_parallelism=1,
            dot_tile_ii=2, dw_weight_prefetch_cycles=9,
            scalar_mac_lanes=64,
        ),
        EngineConfig(
            name="P1_II1_DW1", output_group_parallelism=1,
            dot_tile_ii=1, dw_weight_prefetch_cycles=1,
            scalar_mac_lanes=64,
        ),
        EngineConfig(
            name="P2_II1_DW1", output_group_parallelism=2,
            dot_tile_ii=1, dw_weight_prefetch_cycles=1,
            egress_groups_per_cycle=2, scalar_mac_lanes=128,
        ),
        EngineConfig(
            name="P4_II1_DW1", output_group_parallelism=4,
            dot_tile_ii=1, dw_weight_prefetch_cycles=1,
            egress_groups_per_cycle=4, scalar_mac_lanes=256,
        ),
        EngineConfig(
            name="P8_II1_DW1", output_group_parallelism=8,
            dot_tile_ii=1, dw_weight_prefetch_cycles=1,
            egress_groups_per_cycle=8, scalar_mac_lanes=512,
        ),
    ]
    rows: list[dict[str, int | float | str]] = []
    for config in configs:
        compute = shared_engine_cycles(width, height, config)
        cycles = int(compute["engine_cycles"])
        arithmetic = int(compute["arithmetic_lower_bound_cycles"])
        rows.append(
            {
                "name": config.name,
                "output_group_parallelism": config.output_group_parallelism,
                "scalar_mac_lanes": config.scalar_mac_lanes,
                "dot_tile_ii": config.dot_tile_ii,
                "dw_weight_prefetch_cycles": config.dw_weight_prefetch_cycles,
                "engine_cycles": cycles,
                "arithmetic_lower_bound_cycles": arithmetic,
                "fsm_bubble_cycles": cycles - arithmetic,
                "compute_fps_bound": round(clock_hz / cycles, 4),
            }
        )
    return rows


def dw_weight_cache_sweep(
    width: int = 640,
    height: int = 480,
    clock_hz: int = 100_000_000,
) -> list[dict[str, int | float | str]]:
    """Quantify the optional depthwise tile-cache savings.

    The comparison keeps the serialized engine and MAC initiation interval
    unchanged.  Only the repeated nine-cycle DW bank prefetch is replaced by
    a one-cycle registered tile load after the first pixel of each stage.  It
    is therefore a conservative boardless estimate for
    ``CACHE_DW_WEIGHT_TILES=1`` rather than a claim about DDR or stage overlap.
    """

    if width <= 0 or height <= 0 or clock_hz <= 0:
        raise ValueError("width, height and clock_hz must be positive")
    configs = (
        EngineConfig(
            name="P1_II2_DW9", dot_tile_ii=2,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
        ),
        EngineConfig(
            name="P1_II2_DW9_TILE_CACHE", dot_tile_ii=2,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
            dw_weight_cache_reuse=True,
        ),
        EngineConfig(
            name="P1_II1_DW9_TILE_CACHE", dot_tile_ii=1,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
            dw_weight_cache_reuse=True,
        ),
    )
    rows: list[dict[str, int | float | str]] = []
    for config in configs:
        compute = shared_engine_cycles(width, height, config)
        cycles = int(compute["engine_cycles"])
        rows.append(
            {
                "name": config.name,
                "dw_weight_cache_reuse": config.dw_weight_cache_reuse,
                "engine_cycles": cycles,
                "arithmetic_lower_bound_cycles": int(
                    compute["arithmetic_lower_bound_cycles"]
                ),
                "compute_fps_bound": round(clock_hz / cycles, 4),
            }
        )
    baseline = rows[0]["engine_cycles"]
    for row in rows:
        row["cycles_saved_vs_baseline"] = int(baseline - row["engine_cycles"])
        row["percent_saved_vs_baseline"] = round(
            100.0 * (baseline - row["engine_cycles"]) / baseline, 4
        )
    return rows


def mac_prefetch_overlap_sweep(
    width: int = 640,
    height: int = 480,
    clock_hz: int = 100_000_000,
) -> list[dict[str, int | float | str | bool]]:
    """Quantify the optional steady-state MAC tile overlap.

    The RTL seam keeps the first tile's registered prefetch, then captures the
    next activation/weight tile on each accepted input beat.  This model maps
    that contract to ``dot_tile_ii=1`` without assuming inter-stage overlap or
    extra output groups.  The cache-combined row is included because it is the
    most useful boardless upper bound for the two optional engine switches.
    """

    if width <= 0 or height <= 0 or clock_hz <= 0:
        raise ValueError("width, height and clock_hz must be positive")
    configs = (
        EngineConfig(
            name="P1_II2_DW9", dot_tile_ii=2,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
        ),
        EngineConfig(
            name="P1_MAC_OVERLAP_DW9", dot_tile_ii=1,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
        ),
        EngineConfig(
            name="P1_MAC_OVERLAP_DW9_TILE_CACHE", dot_tile_ii=1,
            dw_weight_prefetch_cycles=9, scalar_mac_lanes=64,
            dw_weight_cache_reuse=True,
        ),
    )
    rows: list[dict[str, int | float | str | bool]] = []
    for config in configs:
        compute = shared_engine_cycles(width, height, config)
        cycles = int(compute["engine_cycles"])
        rows.append(
            {
                "name": config.name,
                "dot_tile_ii": config.dot_tile_ii,
                "dw_weight_cache_reuse": config.dw_weight_cache_reuse,
                "engine_cycles": cycles,
                "compute_fps_bound": round(clock_hz / cycles, 4),
            }
        )
    baseline = rows[0]["engine_cycles"]
    for row in rows:
        row["cycles_saved_vs_baseline"] = int(baseline - row["engine_cycles"])
        row["percent_saved_vs_baseline"] = round(
            100.0 * (baseline - row["engine_cycles"]) / baseline, 4
        )
    return rows


def traffic_pair_sweep(
    width: int = 640,
    height: int = 480,
) -> list[dict[str, int | float | str]]:
    """Compare no packing, a measured small-trace pair rate and ideal pack2.

    The 0.182593 point comes from the existing 4x4 adapter adjacency trace
    (407 pairable gaps out of 2,229).  It is intentionally labelled
    directional evidence, not a native-frame measurement.
    """

    pair_points = (
        ("single_beat", 1, 0.0),
        ("pack2_trace_pair18pct", 2, 0.182593),
        ("pack2_ideal_pair100pct", 2, 1.0),
    )
    rows: list[dict[str, int | float | str]] = []
    for name, pack_factor, pair_fraction in pair_points:
        traffic = traffic_budget(
            width,
            height,
            cache_enabled=True,
            pack_factor=pack_factor,
            burst_beats=16,
            read_pair_fraction=pair_fraction,
            write_pair_fraction=pair_fraction,
        )
        memory = _memory_cycles(
            traffic,
            response_latency=4,
            requested_outstanding=16,
            fabric_supports_outstanding=True,
            burst_address_cycles=1,
            overlap_read_write=True,
        )
        rows.append(
            {
                "name": name,
                "pair_fraction": pair_fraction,
                "read_beats": traffic.read_axi_beats,
                "write_beats": traffic.write_axi_beats,
                "bus_bytes_per_frame": traffic.bus_bytes_per_frame,
                "write_beat_share": round(traffic.write_beat_share, 6),
                "read_bursts": traffic.read_bursts,
                "write_bursts": traffic.write_bursts,
                "memory_cycles_out16": int(
                    memory["channel_overlap_memory_cycles"]
                ),
            }
        )
    return rows


def fabric_outstanding_sweep(
    width: int = 640,
    height: int = 480,
    *,
    response_latency: int = 4,
    burst_beats: int = 16,
    read_pair_fraction: float = 1.0,
    write_pair_fraction: float = 1.0,
) -> list[dict[str, int | float | bool]]:
    """Quantify the bus-level MLP needed after cache/pack/burst.

    This is intentionally separate from :func:`default_sweep`: the latter
    compares architectural candidates, while this table is a fabric sizing
    aid.  ``requested_outstanding`` is honored here because the function
    explicitly selects ``fabric_supports_outstanding=True``.  The output is a
    channel-overlap memory bound only; it does not claim that the shared CNN
    FSM reaches the same frame rate.
    """

    if response_latency <= 0:
        raise ValueError("response_latency must be positive")
    traffic = traffic_budget(
        width,
        height,
        cache_enabled=True,
        line_rows=3,
        pack_factor=2,
        burst_beats=burst_beats,
        read_pair_fraction=read_pair_fraction,
        write_pair_fraction=write_pair_fraction,
    )
    rows: list[dict[str, int | float | bool]] = []
    for outstanding in (1, 2, 4, 8, 16, 32):
        memory = _memory_cycles(
            traffic,
            response_latency=response_latency,
            requested_outstanding=outstanding,
            fabric_supports_outstanding=True,
            burst_address_cycles=1,
            overlap_read_write=True,
        )
        cycles = int(memory["channel_overlap_memory_cycles"])
        rows.append(
            {
                "requested_outstanding": outstanding,
                "effective_outstanding": int(memory["effective_outstanding"]),
                "memory_cycles": cycles,
                "memory_fps_bound": 100_000_000 / cycles if cycles else 0.0,
                "beats_per_frame": traffic.bus_axi_beats,
                "read_beats": traffic.read_axi_beats,
                "write_beats": traffic.write_axi_beats,
                "meets_15fps_memory_only": cycles <= (100_000_000 // 15),
            }
        )
    return rows


def _scenario(
    name: str,
    *,
    width: int,
    height: int,
    fps: int,
    clock_hz: int,
    cache_enabled: bool,
    pack_factor: int,
    burst_beats: int,
    requested_outstanding: int,
    fabric_supports_outstanding: bool,
    response_latency: int,
    burst_address_cycles: int,
    overlap_read_write: bool,
    engine: EngineConfig | None,
    dedicated_graph: bool = False,
    read_pair_fraction: float | None = None,
    write_pair_fraction: float | None = None,
) -> dict:
    traffic = traffic_budget(
        width,
        height,
        cache_enabled=cache_enabled,
        pack_factor=pack_factor,
        burst_beats=burst_beats,
        read_pair_fraction=read_pair_fraction,
        write_pair_fraction=write_pair_fraction,
    )
    memory = _memory_cycles(
        traffic,
        response_latency=response_latency,
        requested_outstanding=requested_outstanding,
        fabric_supports_outstanding=fabric_supports_outstanding,
        burst_address_cycles=burst_address_cycles,
        overlap_read_write=overlap_read_write,
    )
    if dedicated_graph:
        schedule = estimate_schedule(width, height, clock_hz, fps)
        compute = {
            "model": schedule["execution_model"],
            "engine_cycles": schedule["bottleneck_lower_bound_cycles"],
            "arithmetic_lower_bound_cycles": _ceil_div(
                schedule["total_macs"], schedule["multiplier_lanes"]
            ),
            "total_macs": schedule["total_macs"],
            "bottleneck_stage": schedule["bottleneck_stage"],
            "multiplier_lanes": schedule["multiplier_lanes"],
        }
    else:
        if engine is None:
            raise ValueError("engine config required for shared scenario")
        compute = shared_engine_cycles(width, height, engine)

    frame_budget = clock_hz // fps
    reserved_frame_budget = (clock_hz * 9) // (fps * 10)
    # ``overlap_read_write`` is a memory-channel assumption, not a claim that
    # compute and memory overlap.  The candidate frame bound below is the
    # optimistic max() used by the existing model; the report labels it.
    frame_cycles = max(int(memory["channel_overlap_memory_cycles"]), int(compute["engine_cycles"]))
    serialized_frame_cycles = max(
        int(memory["serialized_memory_cycles"]), int(compute["engine_cycles"])
    )
    return {
        "name": name,
        "traffic": asdict(traffic),
        "memory": memory,
        "compute": compute,
        "frame_budget_cycles": frame_budget,
        "reserved_budget_cycles": reserved_frame_budget,
        "optimistic_frame_cycles": frame_cycles,
        "optimistic_fps_bound": clock_hz / frame_cycles if frame_cycles else 0.0,
        "serialized_channel_frame_cycles": serialized_frame_cycles,
        "serialized_channel_fps_bound": (
            clock_hz / serialized_frame_cycles if serialized_frame_cycles else 0.0
        ),
        "meets_15fps_optimistic": frame_cycles <= frame_budget,
        "meets_reserved_budget": frame_cycles <= reserved_frame_budget,
        "assumptions": [
            "AXI payload beats issue at one beat/cycle",
            "burst boundary/DDR refresh penalties are not measured",
            "frame max(memory, compute) assumes overlap between the two",
            "cache replaces only 3x3 tap reads; all writes remain external",
            "parameter load/repack and descriptor setup are omitted",
        ],
    }


def default_sweep(width: int = 640, height: int = 480) -> list[dict]:
    """Return a compact set of decisions needed for the next RTL phase."""

    legacy = EngineConfig(name="legacy_P1_II2_DW9", scalar_mac_lanes=64)
    tile_ii1 = EngineConfig(
        name="prefetch_overlap_P1_II1_DW1", dot_tile_ii=1,
        dw_weight_prefetch_cycles=1, scalar_mac_lanes=64,
    )
    dual_narrow = EngineConfig(
        name="dual_group_P2_II1_narrow_egress", output_group_parallelism=2,
        dot_tile_ii=1, dw_weight_prefetch_cycles=1,
        egress_groups_per_cycle=1, scalar_mac_lanes=128,
    )
    dual_wide = EngineConfig(
        name="dual_group_P2_II1_wide_egress", output_group_parallelism=2,
        dot_tile_ii=1, dw_weight_prefetch_cycles=1,
        egress_groups_per_cycle=2, scalar_mac_lanes=128,
    )
    common = dict(
        width=width, height=height, fps=15, clock_hz=100_000_000,
        cache_enabled=False, pack_factor=1, burst_beats=1,
        requested_outstanding=1, fabric_supports_outstanding=False,
        response_latency=4, burst_address_cycles=0,
        overlap_read_write=False,
    )
    scenarios = [
        _scenario("baseline_single_beat_shared", engine=legacy, **common),
        _scenario(
            "cache3_pack2_burst16_serial_fabric", engine=legacy,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16},
        ),
        _scenario(
            "cache3_pack2_burst16_real_out16", engine=legacy,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16, "requested_outstanding": 16,
               "fabric_supports_outstanding": True,
               "burst_address_cycles": 1, "overlap_read_write": True},
        ),
        _scenario(
            "cache3_pack2_burst16_ii1", engine=tile_ii1,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16, "requested_outstanding": 16,
               "fabric_supports_outstanding": True,
               "burst_address_cycles": 1, "overlap_read_write": True},
        ),
        _scenario(
            "cache3_pack2_burst16_dual_narrow", engine=dual_narrow,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16, "requested_outstanding": 16,
               "fabric_supports_outstanding": True,
               "burst_address_cycles": 1, "overlap_read_write": True},
        ),
        _scenario(
            "cache3_pack2_burst16_dual_wide", engine=dual_wide,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16, "requested_outstanding": 16,
               "fabric_supports_outstanding": True,
               "burst_address_cycles": 1, "overlap_read_write": True},
        ),
        _scenario(
            "cache3_pack2_burst16_dedicated_80_lane", engine=None,
            dedicated_graph=True,
            **{**common, "cache_enabled": True, "pack_factor": 2,
               "burst_beats": 16, "requested_outstanding": 16,
               "fabric_supports_outstanding": True,
               "burst_address_cycles": 1, "overlap_read_write": True},
        ),
    ]
    return scenarios


def compact_rows(scenarios: Iterable[dict]) -> list[dict[str, int | float | str | bool]]:
    """Select report fields that remain useful in a small checked-in JSON."""

    rows = []
    for item in scenarios:
        traffic = item["traffic"]
        memory = item["memory"]
        compute = item["compute"]
        rows.append(
            {
                "name": item["name"],
                "uncached_read_req": traffic["uncached_stage_read_requests"],
                "read_req": traffic["stage_read_requests"],
                "write_req": traffic["source_write_requests"]
                + traffic["stage_write_requests"],
                "read_beats": traffic["read_axi_beats"],
                "write_beats": traffic["write_axi_beats"],
                "read_bursts": traffic["read_bursts"],
                "write_bursts": traffic["write_bursts"],
                "bus_bytes_per_frame": traffic["bus_bytes_per_frame"],
                "write_beat_share": round(traffic["write_beat_share"], 6),
                "effective_outstanding": memory["effective_outstanding"],
                "channel_memory_cycles": memory[
                    "channel_overlap_memory_cycles"
                ],
                "serialized_memory_cycles": memory[
                    "serialized_memory_cycles"
                ],
                "engine_cycles": compute["engine_cycles"],
                "arithmetic_lower_bound_cycles": compute[
                    "arithmetic_lower_bound_cycles"
                ],
                "optimistic_frame_cycles": item["optimistic_frame_cycles"],
                "optimistic_fps_bound": round(item["optimistic_fps_bound"], 4),
                "meets_15fps_optimistic": item["meets_15fps_optimistic"],
                "meets_reserved_budget": item["meets_reserved_budget"],
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    scenarios = default_sweep(args.width, args.height)
    result = {
        "model": "case1_throughput_sweep",
        "width": args.width,
        "height": args.height,
        "clock_hz": 100_000_000,
        "fps_target": 15,
        "scenarios": compact_rows(scenarios),
        "parallel_mac_sweep": parallel_mac_sweep(args.width, args.height),
        "dw_weight_cache_sweep": dw_weight_cache_sweep(args.width, args.height),
        "mac_prefetch_overlap_sweep": mac_prefetch_overlap_sweep(
            args.width, args.height
        ),
        "traffic_pair_sweep": traffic_pair_sweep(args.width, args.height),
        "fabric_outstanding_sweep": fabric_outstanding_sweep(
            args.width, args.height
        ),
        "detail": scenarios,
    }
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for row in result["scenarios"]:
            print(
                "C1_THROUGHPUT_SWEEP_RESULT",
                row["name"],
                f"read_beats={row['read_beats']}",
                f"write_beats={row['write_beats']}",
                f"out={row['effective_outstanding']}",
                f"engine_cycles={row['engine_cycles']}",
                f"frame_cycles={row['optimistic_frame_cycles']}",
                f"fps={row['optimistic_fps_bound']:.4f}",
                f"meets={int(row['meets_15fps_optimistic'])}",
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
