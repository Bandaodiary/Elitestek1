"""Cycle model for the optional write request-FIFO pop/refill boundary.

The write burst leaf consumes a request when a descriptor starts or when a
contiguous request is appended.  At a full logical FIFO the conservative
interface waits for the registered count to fall below DEPTH; the optional
mode admits a producer handshake on the same edge as that ``req_pop``.  This
small model isolates that handshake contract and deliberately does not claim
anything about DDR bandwidth or end-to-end frame rate.
"""

from __future__ import annotations

from collections.abc import Callable


def simulate(
    *,
    allow_pop_refill: bool,
    depth: int,
    requests: int,
    builder_pop: Callable[[int, int], bool],
) -> dict[str, int]:
    """Simulate an always-valid producer and a deterministic builder pop.

    ``builder_pop(cycle, occupancy)`` is sampled from pre-edge state, matching
    the RTL's registered FIFO/builder decision.  The return values expose the
    first full-queue replacement and producer stalls, which are the only
    promised benefit of this optional seam.
    """

    if depth < 2:
        raise ValueError("depth must be at least two")
    if requests < 1:
        raise ValueError("requests must be positive")

    cycle = 0
    produced = 0
    consumed = 0
    occupancy = 0
    full_cycle = -1
    first_post_full_cycle = -1
    producer_stalls = 0
    full_pop_push = 0

    while produced < requests or occupancy:
        pop = bool(occupancy and builder_pop(cycle, occupancy))
        if occupancy == depth and full_cycle < 0:
            full_cycle = cycle

        producer_valid = produced < requests
        ready = occupancy < depth or (allow_pop_refill and pop)
        push = producer_valid and ready

        if producer_valid and not push:
            producer_stalls += 1
        if full_cycle >= 0 and first_post_full_cycle < 0 and push:
            first_post_full_cycle = cycle
        if push and pop and occupancy == depth:
            full_pop_push += 1

        produced += int(push)
        consumed += int(pop)
        occupancy += int(push) - int(pop)
        if not 0 <= occupancy <= depth:
            raise AssertionError(f"FIFO bounds violation at cycle {cycle}")

        cycle += 1
        if cycle > 100000:
            raise AssertionError("model did not make forward progress")

    return {
        "cycles": cycle,
        "requests": requests,
        "producer_stalls": producer_stalls,
        "full_pop_push": full_pop_push,
        "full_cycle": full_cycle,
        "first_post_full_cycle": first_post_full_cycle,
        "full_to_accept": first_post_full_cycle - full_cycle,
    }


def main() -> int:
    # Hold the builder off while the four-entry FIFO fills, then consume one
    # request every other cycle.  This is a compact abstraction of the xsim
    # test's AXI-release point; it intentionally makes the full boundary easy
    # to inspect without modeling payload or B-channel details.
    def pop_schedule(cycle: int, _occupancy: int) -> bool:
        return cycle >= 6 and ((cycle - 6) % 2 == 0)

    baseline = simulate(
        allow_pop_refill=False,
        depth=4,
        requests=12,
        builder_pop=pop_schedule,
    )
    refill = simulate(
        allow_pop_refill=True,
        depth=4,
        requests=12,
        builder_pop=pop_schedule,
    )
    assert baseline["full_pop_push"] == 0
    assert refill["full_pop_push"] > 0
    assert refill["producer_stalls"] < baseline["producer_stalls"]
    assert refill["full_to_accept"] < baseline["full_to_accept"]
    print(
        "WRITE_REQ_POP_REFILL_MODEL_PASS "
        f"depth=4 requests=12 "
        f"baseline_stalls={baseline['producer_stalls']} "
        f"refill_stalls={refill['producer_stalls']} "
        f"baseline_full_to_accept={baseline['full_to_accept']} "
        f"refill_full_to_accept={refill['full_to_accept']} "
        f"full_pop_push={refill['full_pop_push']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
