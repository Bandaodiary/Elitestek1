"""Small, board-independent model for row-refill tail flushing.

The burst reader accepts one 64-bit logical request per cycle and packs two
adjacent requests into an AXI-128 beat.  A generic reader waits
``build_timeout`` cycles after the request FIFO becomes empty before closing a
descriptor.  The burst shell can instead pulse ``req_flush`` once that FIFO is
empty; this model captures the resulting tail-only latency change and checks
that packing/burst counts are invariant.

This is intentionally not a DDR timing model.  It is a compact arithmetic
contract used by the RTL A/B smoke and does not create a simulation tree.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TailFlushResult:
    rows: int
    row_words: int
    burst_beats: int
    axi_beats: int
    axi_bursts: int
    packed_requests: int
    request_cycles: int
    tail_cycles: int
    total_cycles: int


def simulate(
    rows: int,
    row_words: int,
    *,
    burst_beats: int = 16,
    build_timeout: int = 4,
    tail_flush: bool = False,
) -> TailFlushResult:
    """Return the deterministic request/descriptor summary for ``rows``.

    The shell feeds complete rows serially, so each row contributes
    ``row_words`` request cycles.  A normal reader contributes
    ``build_timeout`` close cycles after the FIFO drains; a proven tail flush
    contributes one cycle (the cycle in which the empty-FIFO pulse is sampled).
    AXI beat/burst counts are purely geometric and therefore must not change
    between the two modes.
    """

    if rows < 1 or row_words < 1:
        raise ValueError("rows and row_words must be positive")
    if burst_beats < 1:
        raise ValueError("burst_beats must be positive")
    if build_timeout < 1:
        raise ValueError("build_timeout must be positive")

    axi_beats_per_row = (row_words + 1) // 2
    # Each row starts a fresh contiguous descriptor in the shell contract.
    axi_bursts_per_row = (axi_beats_per_row + burst_beats - 1) // burst_beats
    packed_per_row = row_words - axi_beats_per_row
    request_cycles = rows * row_words
    tail_cycles = rows * (1 if tail_flush else build_timeout)
    return TailFlushResult(
        rows=rows,
        row_words=row_words,
        burst_beats=burst_beats,
        axi_beats=rows * axi_beats_per_row,
        axi_bursts=rows * axi_bursts_per_row,
        packed_requests=rows * packed_per_row,
        request_cycles=request_cycles,
        tail_cycles=tail_cycles,
        total_cycles=request_cycles + tail_cycles,
    )


def main() -> int:
    baseline = simulate(5, 8, burst_beats=4, build_timeout=3)
    fast = simulate(5, 8, burst_beats=4, build_timeout=3, tail_flush=True)
    assert baseline.axi_beats == fast.axi_beats == 20
    assert baseline.axi_bursts == fast.axi_bursts == 5
    assert baseline.packed_requests == fast.packed_requests == 20
    assert baseline.total_cycles - fast.total_cycles == 10
    # Odd row lengths retain the same pack2 geometry and still save only the
    # descriptor-tail term; this guards against accidentally dropping a lane.
    odd_base = simulate(3, 7, burst_beats=4, build_timeout=5)
    odd_fast = simulate(3, 7, burst_beats=4, build_timeout=5, tail_flush=True)
    assert odd_base.axi_beats == odd_fast.axi_beats == 12
    assert odd_base.axi_bursts == odd_fast.axi_bursts == 3
    assert odd_base.packed_requests == odd_fast.packed_requests == 9
    assert odd_base.total_cycles - odd_fast.total_cycles == 12
    print(
        "READ_TAIL_FLUSH_MODEL_PASS "
        f"rows={baseline.rows} words={baseline.row_words} "
        f"beats={baseline.axi_beats} bursts={baseline.axi_bursts} "
        f"packed={baseline.packed_requests} "
        f"baseline_cycles={baseline.total_cycles} "
        f"fast_cycles={fast.total_cycles} saved={baseline.total_cycles-fast.total_cycles}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
