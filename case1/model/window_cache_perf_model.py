"""Boardless 3x3 SAME line/window-cache traffic model for case 1.

The existing :mod:`tensor_perf_model` intentionally models the current
correctness-first adapter: every 3x3 tap is one logical 64-bit request.  This
module keeps that traffic contract as its baseline and models the first
performance seam proposed in ``PERFORMANCE_NEXT_PHASE.md``: a full-width
three-row line buffer with a three-column sliding window.

This is a *traffic* model, not an RTL or DDR timing claim.  It follows the
real adapter order: output pixels are visited in raster order and C8 input
groups are interleaved inside each pixel.  A line miss fetches one complete
input row for *all* groups (``input_width * input_groups`` 64-bit words,
x-major/group-minor) into the line buffer; the three-column window then
consumes taps from resident rows.  SAME_REPLICATE coordinates are clamped,
so a replicated border tap is an in-cache hit once the source row has been
filled.  The default cache has three resident rows, which is the minimum
needed for a 3x3 window without re-reading a row while advancing one output
row at a time.

The report deliberately exposes two different ratios:

``tap_hit_rate``
    Fraction of logical 3x3 tap accesses whose source row was already
    resident.  This is the conventional cache hit statistic for the chosen
    row-cache abstraction.

``external_request_reduction``
    Reduction in external 64-bit words relative to the existing
    ``TrafficRow.tap_reads`` count.  A row fill may prefetch columns that are
    not needed by a particular output, so this bandwidth-oriented number is
    the one to use when sizing the AXI/DDR seam.  For the requested even
    dimensions and a three-row cache, stride-1 stages approach 8/9 reduction
    and stride-2 stages approach 5/9 reduction.
"""

from __future__ import annotations

import argparse
from collections import OrderedDict
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import sys
from typing import Iterator

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from microstyle_layout import LayerSpec, layer_specs  # noqa: E402
from tensor_perf_model import TrafficRow, traffic_rows  # noqa: E402


@dataclass(frozen=True)
class WindowCacheStage:
    """Traffic and hit statistics for one 3x3 stage."""

    name: str
    opcode: int
    input_width: int
    input_height: int
    output_width: int
    output_height: int
    stride: int
    input_groups: int
    line_rows: int
    logical_tap_requests: int
    tap_hits: int
    tap_misses: int
    line_fill_rows: int
    external_requests: int
    tap_hit_rate: float
    external_request_reduction: float


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def _same3x3_rows(
    width: int, height: int
) -> Iterator[tuple[TrafficRow, LayerSpec]]:
    """Yield 3x3 Conv/DW rows paired with their geometry.

    ``traffic_rows`` is the source of truth for the baseline request count;
    the paired ``LayerSpec`` supplies input geometry and stride for the cache
    traversal.  Keeping the pair explicit prevents this model from silently
    drifting from the descriptor graph.
    """

    rows = traffic_rows(width, height)
    specs = layer_specs(width, height)
    if len(rows) != len(specs):
        raise AssertionError("traffic_rows and layer_specs length mismatch")
    for row, spec in zip(rows, specs):
        if spec.kernel == 3 and spec.opcode in (1, 3):
            expected = spec.output_width * spec.output_height * row.input_groups * 9
            if row.tap_reads != expected:
                raise AssertionError(
                    f"{row.name}: traffic_rows tap count drifted "
                    f"({row.tap_reads} != {expected})"
                )
            yield row, spec


def simulate_window_cache_stage(
    row: TrafficRow,
    spec: LayerSpec,
    *,
    line_rows: int = 3,
) -> WindowCacheStage:
    """Simulate a full-width line buffer for one 3x3 SAME stage.

    One resident row contains every C8 group in the tensor's native
    x-major/group-minor order.  ``line_fill_rows`` therefore counts physical
    input rows, including a possible refill after eviction; each fill costs
    ``input_width * input_groups`` external 64-bit requests.  Taps are still
    enumerated individually so border replication, group interleaving and a
    deliberately undersized cache remain observable.
    """

    if line_rows <= 0:
        raise ValueError("line_rows must be positive")
    if spec.kernel != 3 or spec.opcode not in (1, 3):
        raise ValueError(f"{spec.name} is not a 3x3 Conv/DW stage")

    tap_accesses = 0
    tap_hits = 0
    tap_misses = 0
    line_fill_rows = 0

    # OrderedDict is an LRU set of resident complete multi-group rows.  Values
    # are intentionally empty: a line fill accounts for all x/group words.
    resident: OrderedDict[int, None] = OrderedDict()

    def touch_line(input_y: int) -> None:
        nonlocal tap_hits, tap_misses, line_fill_rows
        if input_y in resident:
            tap_hits += 1
            resident.move_to_end(input_y)
            return
        tap_misses += 1
        line_fill_rows += 1
        resident[input_y] = None
        resident.move_to_end(input_y)
        while len(resident) > line_rows:
            resident.popitem(last=False)

    for output_y in range(spec.output_height):
        center_y = output_y * spec.stride
        for output_x in range(spec.output_width):
            center_x = output_x * spec.stride
            for _group in range(row.input_groups):
                # Tap order matches the RTL adapter: group is inside the
                # output pixel, then ky-major/kx-minor taps.
                for kernel_y in (-1, 0, 1):
                    input_y = _clamp(
                        center_y + kernel_y, 0, spec.input_height - 1
                    )
                    for kernel_x in (-1, 0, 1):
                        _ = _clamp(
                            center_x + kernel_x, 0, spec.input_width - 1
                        )
                        touch_line(input_y)
                        tap_accesses += 1

    if tap_accesses != row.tap_reads:
        raise AssertionError(
            f"{row.name}: simulated taps {tap_accesses} != traffic_rows "
            f"{row.tap_reads}"
        )

    external_requests = line_fill_rows * spec.input_width * row.input_groups
    return WindowCacheStage(
        name=spec.name,
        opcode=spec.opcode,
        input_width=spec.input_width,
        input_height=spec.input_height,
        output_width=spec.output_width,
        output_height=spec.output_height,
        stride=spec.stride,
        input_groups=row.input_groups,
        line_rows=line_rows,
        logical_tap_requests=tap_accesses,
        tap_hits=tap_hits,
        tap_misses=tap_misses,
        line_fill_rows=line_fill_rows,
        external_requests=external_requests,
        tap_hit_rate=tap_hits / tap_accesses if tap_accesses else 0.0,
        external_request_reduction=(
            1.0 - external_requests / tap_accesses if tap_accesses else 0.0
        ),
    )


def estimate_window_cache(
    width: int,
    height: int,
    *,
    line_rows: int = 3,
) -> dict:
    """Aggregate 3x3 SAME cache statistics for the frozen descriptor graph."""

    if width <= 0 or height <= 0:
        raise ValueError("width and height must be positive")
    if line_rows <= 0:
        raise ValueError("line_rows must be positive")

    stages = [
        simulate_window_cache_stage(row, spec, line_rows=line_rows)
        for row, spec in _same3x3_rows(width, height)
    ]
    logical = sum(stage.logical_tap_requests for stage in stages)
    hits = sum(stage.tap_hits for stage in stages)
    misses = sum(stage.tap_misses for stage in stages)
    fills = sum(stage.line_fill_rows for stage in stages)
    external = sum(stage.external_requests for stage in stages)
    return {
        "model": "three_row_line_window_cache_traffic",
        "width": width,
        "height": height,
        "line_rows": line_rows,
        "window": "3x3",
        "padding": "SAME_REPLICATE",
        "stage_count": len(stages),
        "logical_tap_requests": logical,
        "tap_hits": hits,
        "tap_misses": misses,
        "line_fill_rows": fills,
        "external_requests": external,
        "tap_hit_rate": hits / logical if logical else 0.0,
        "external_request_reduction": (
            1.0 - external / logical if logical else 0.0
        ),
        "stages": [asdict(stage) for stage in stages],
        "assumptions": [
            "baseline tap requests are traffic_rows.tap_reads",
            "C8 groups are interleaved inside each output pixel",
            "a line miss fetches every C8 group in one complete input row",
            "three resident rows and raster output traversal",
            "no AXI burst, arbitration, DDR refresh, or compute overlap modeled",
        ],
    }


def _format_percent(value: float) -> str:
    return f"{value * 100.0:.4f}%"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=8)
    parser.add_argument("--height", type=int, default=8)
    parser.add_argument("--line-rows", type=int, default=3)
    parser.add_argument("--all-requested-sizes", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    sizes = [(8, 8), (16, 16), (64, 48)] if args.all_requested_sizes else [(args.width, args.height)]
    reports = [
        estimate_window_cache(width, height, line_rows=args.line_rows)
        for width, height in sizes
    ]
    if args.json:
        print(json.dumps(reports if len(reports) > 1 else reports[0], indent=2))
    else:
        for report in reports:
            print(
                "C1_WINDOW_CACHE_MODEL_PASS",
                f"size={report['width']}x{report['height']}",
                f"stages={report['stage_count']}",
                f"tap_requests={report['logical_tap_requests']}",
                f"external_requests={report['external_requests']}",
                f"tap_hit_rate={_format_percent(report['tap_hit_rate'])}",
                f"request_reduction={_format_percent(report['external_request_reduction'])}",
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
