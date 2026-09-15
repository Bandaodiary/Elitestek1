"""Small cycle model for the optional write-response FIFO pop/refill path.

The burst writer retires one descriptor response when an AXI ``B`` handshake
occurs.  With a shallow response FIFO, the conservative implementation waits
for a free slot before asserting ``BREADY``.  The optional mode allows a new
retirement in the same cycle that the public response consumer pops the queue
head.  This model isolates that scheduling effect; it does not model DDR
latency or payload bandwidth.
"""

from __future__ import annotations

from typing import Callable


def simulate(
    *,
    allow_pop_refill: bool,
    depth: int,
    responses: int,
    consumer_ready: Callable[[int], bool],
) -> dict[str, int]:
    """Return FIFO cycles/stalls for an always-valid descriptor producer."""

    if depth < 2:
        raise ValueError("depth must be at least two")
    if responses < 1:
        raise ValueError("responses must be positive")

    cycle = 0
    produced = 0
    consumed = 0
    occupancy = 0
    producer_stalls = 0
    full_pop_push = 0

    while consumed < responses or produced < responses:
        producer_valid = produced < responses
        pop = occupancy > 0 and consumer_ready(cycle)
        capacity = occupancy < depth or (allow_pop_refill and pop)
        push = producer_valid and capacity

        if producer_valid and not push:
            producer_stalls += 1
        if push and pop and occupancy == depth:
            full_pop_push += 1

        produced += int(push)
        consumed += int(pop)
        occupancy += int(push) - int(pop)
        if not 0 <= occupancy <= depth:
            raise AssertionError(f"FIFO bounds violation at cycle {cycle}")
        cycle += 1
        if cycle > 10000:
            raise AssertionError("model did not make forward progress")

    return {
        "cycles": cycle,
        "producer_stalls": producer_stalls,
        "full_pop_push": full_pop_push,
        "responses": responses,
    }


def main() -> int:
    # The consumer starts after the FIFO has filled and then has a repeatable
    # backpressure pattern.  This is intentionally harsher than a normally
    # sized board FIFO so the optional corner is observable in a small model.
    ready = lambda cycle: cycle >= 4 and (cycle % 4) != 1
    baseline = simulate(
        allow_pop_refill=False,
        depth=2,
        responses=12,
        consumer_ready=ready,
    )
    refill = simulate(
        allow_pop_refill=True,
        depth=2,
        responses=12,
        consumer_ready=ready,
    )
    assert baseline["full_pop_push"] == 0
    assert refill["full_pop_push"] > 0
    # The public consumer pattern is the long pole in this focused model, so
    # total drain cycles can remain equal even though the AXI producer spends
    # fewer cycles stalled.  The RTL counter of interest is the BREADY stall.
    assert refill["producer_stalls"] < baseline["producer_stalls"]
    print(
        "WRITE_RSP_POP_REFILL_MODEL_PASS "
        f"depth=2 responses=12 "
        f"baseline_cycles={baseline['cycles']} "
        f"refill_cycles={refill['cycles']} "
        f"saved_stalls={baseline['producer_stalls'] - refill['producer_stalls']} "
        f"baseline_stalls={baseline['producer_stalls']} "
        f"refill_stalls={refill['producer_stalls']} "
        f"full_pop_push={refill['full_pop_push']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
