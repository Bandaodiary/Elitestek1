"""Cycle model for the optional read-response FIFO pop/refill bypass.

This is intentionally not a performance claim for a particular DDR controller.
It proves the FIFO accounting corner used by the small RTL testbench: a shallow
logical-response FIFO can accept the next packed (two-lane) R beat in the same
cycle that one previously queued logical response is consumed.  The default
mode intentionally leaves that cycle as an AXI R-channel bubble for timing.
"""

from __future__ import annotations


def simulate(*, allow_pop_refill: bool, depth: int, lane_counts: list[int]) -> dict:
    """Return a compact trace for an always-valid, always-ready local sink."""
    if depth < 2:
        raise ValueError("depth must hold at least one packed two-lane beat")
    if any(lanes not in (1, 2) for lanes in lane_counts):
        raise ValueError("each AXI beat must carry one or two logical lanes")

    occupancy = 0
    source_index = 0
    logical_out = 0
    cycles = 0
    packed_pop_refills = 0
    max_occupancy = 0

    while source_index < len(lane_counts) or occupancy:
        cycles += 1
        pop = occupancy != 0  # local rsp_ready is high in this focused model
        lanes = lane_counts[source_index] if source_index < len(lane_counts) else 0

        if lanes == 0:
            capacity = False
        elif lanes == 1:
            capacity = occupancy < depth or (allow_pop_refill and pop)
        else:
            capacity = (occupancy < depth - 1) or (
                allow_pop_refill and pop and occupancy < depth
            )
        r_fire = lanes != 0 and capacity

        if r_fire and pop and occupancy == depth - 1 and lanes == 2:
            packed_pop_refills += 1

        occupancy += (lanes if r_fire else 0) - int(pop)
        if not 0 <= occupancy <= depth:
            raise AssertionError(f"FIFO bounds violation at cycle {cycles}: {occupancy}")
        max_occupancy = max(max_occupancy, occupancy)
        logical_out += int(pop)
        if r_fire:
            source_index += 1
        if cycles > 1000:
            raise AssertionError("model did not make forward progress")

    return {
        "cycles": cycles,
        "logical_outputs": logical_out,
        "max_occupancy": max_occupancy,
        "packed_pop_refills": packed_pop_refills,
    }


def main() -> None:
    # Eight adjacent packed AXI beats are sufficient to reach steady state;
    # the final one-lane beat also checks that neither mode overflows at tail.
    lane_counts = [2] * 8 + [1]
    baseline = simulate(allow_pop_refill=False, depth=2, lane_counts=lane_counts)
    refill = simulate(allow_pop_refill=True, depth=2, lane_counts=lane_counts)

    expected_logical = sum(lane_counts)
    assert baseline["logical_outputs"] == expected_logical
    assert refill["logical_outputs"] == expected_logical
    assert refill["packed_pop_refills"] >= 1
    assert refill["cycles"] < baseline["cycles"]

    print(
        "READ_RSP_POP_REFILL_MODEL_PASS "
        f"depth=2 beats={len(lane_counts)} logical={expected_logical} "
        f"baseline_cycles={baseline['cycles']} refill_cycles={refill['cycles']} "
        f"saved={baseline['cycles'] - refill['cycles']} "
        f"same_cycle_packed={refill['packed_pop_refills']}"
    )


if __name__ == "__main__":
    main()
