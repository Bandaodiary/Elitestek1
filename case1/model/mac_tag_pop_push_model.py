"""Event-level model for the ping-pong MAC tag FIFO admission option.

The MAC banks already overlap transactions, but the ordered bank-id FIFO can
become the next admission bottleneck when its depth is exactly the number of
banks.  ``ALLOW_TAG_POP_PUSH`` permits one new START on the same edge that the
oldest result retires, provided the selected bank is also in
``ALLOW_OUTPUT_RESTART`` mode.  This model intentionally abstracts arithmetic
and models only ownership, output backpressure, and FIFO accounting.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TagPopPushResult:
    banks: int
    transactions: int
    tag_depth: int
    start_gap: int
    compute_latency: int
    allow_restart: bool
    allow_tag_pop_push: bool
    starts: tuple[int, ...]
    retires: tuple[int, ...]
    bank_ids: tuple[int, ...]
    same_edge_restarts: int
    full_pop_push: int
    max_tag_count: int
    cycles: int


def simulate(
    *,
    banks: int = 2,
    transactions: int = 8,
    tag_depth: int | None = None,
    start_gap: int = 2,
    compute_latency: int = 7,
    ready_period: int = 7,
    ready_stall_phase: int = 3,
    allow_restart: bool = False,
    allow_tag_pop_push: bool = False,
) -> TagPopPushResult:
    """Simulate ordered ownership and full-FIFO replacement.

    ``start_gap`` is the minimum number of cycles between START handshakes
    (the default-two value reflects the legacy START then one-group IN
    sequence in the boardless smoke).  ``compute_latency`` is measured from
    START to a result becoming eligible.  The model is deliberately
    conservative: one START and one retirement are possible per cycle, and a
    bank cannot be reused before its own ordered result retires.
    """

    if banks < 2 or transactions <= 0:
        raise ValueError("invalid bank/transaction configuration")
    if tag_depth is None:
        tag_depth = banks
    if tag_depth < banks or start_gap < 1 or compute_latency < 1:
        raise ValueError("invalid depth/gap/latency configuration")
    if ready_period < 1:
        raise ValueError("ready_period must be positive")

    # ``free_at`` is the first cycle at which each physical bank can accept a
    # new START.  A large sentinel denotes an outstanding result.
    free_at = [0] * banks
    bank_ids: list[int] = []
    ready_at: list[int] = []
    starts: list[int] = []
    retires: list[int] = []
    next_bank = 0
    next_id = 0
    tag_count = 0
    max_tag_count = 0
    same_edge = 0
    full_pop_push = 0
    next_start_cycle = 0
    cycle = 0

    while len(retires) < transactions:
        retired_bank: int | None = None
        tag_was_full = tag_count == tag_depth

        # The tag FIFO is ordered by transaction ID, so only its head may
        # retire.  A deterministic ready pattern mirrors the RTL smoke TB.
        if (
            len(retires) < len(ready_at)
            and ready_at[len(retires)] <= cycle
            and (cycle % ready_period) != ready_stall_phase
        ):
            retired_bank = bank_ids[len(retires)]
            retires.append(cycle)
            tag_count -= 1
            free_at[retired_bank] = cycle if allow_restart else cycle + 1

        # Select the first free bank from the round-robin cursor.  At a full
        # FIFO, only the explicit pop+push option may use the retiring slot.
        tag_space = (tag_count < tag_depth) or (
            allow_tag_pop_push and tag_was_full and retired_bank is not None
        )
        chosen: int | None = None
        if next_id < transactions and cycle >= next_start_cycle and tag_space:
            for offset in range(banks):
                candidate = (next_bank + offset) % banks
                if free_at[candidate] <= cycle:
                    chosen = candidate
                    break

        if chosen is not None:
            if retired_bank == chosen:
                same_edge += 1
            if tag_was_full and retired_bank is not None:
                full_pop_push += 1
            starts.append(cycle)
            bank_ids.append(chosen)
            ready_at.append(cycle + compute_latency)
            free_at[chosen] = 10**9
            tag_count += 1
            max_tag_count = max(max_tag_count, tag_count)
            next_bank = (chosen + 1) % banks
            next_id += 1
            next_start_cycle = cycle + start_gap

        cycle += 1
        if cycle > 1_000_000:
            raise RuntimeError("tag pop+push model did not converge")

    return TagPopPushResult(
        banks=banks,
        transactions=transactions,
        tag_depth=tag_depth,
        start_gap=start_gap,
        compute_latency=compute_latency,
        allow_restart=allow_restart,
        allow_tag_pop_push=allow_tag_pop_push,
        starts=tuple(starts),
        retires=tuple(retires),
        bank_ids=tuple(bank_ids),
        same_edge_restarts=same_edge,
        full_pop_push=full_pop_push,
        max_tag_count=max_tag_count,
        cycles=cycle,
    )


def compare_full_fifo(
    **kwargs: int,
) -> tuple[TagPopPushResult, TagPopPushResult]:
    """Compare conservative and same-edge replacement schedules."""

    baseline = simulate(allow_restart=False, allow_tag_pop_push=False, **kwargs)
    optional = simulate(allow_restart=True, allow_tag_pop_push=True, **kwargs)
    return baseline, optional


if __name__ == "__main__":
    baseline, optional = compare_full_fifo()
    if optional.cycles > baseline.cycles:
        raise SystemExit("tag pop+push unexpectedly increased cycles")
    if optional.full_pop_push <= 0:
        raise SystemExit("tag pop+push did not exercise a full-FIFO event")
    if optional.max_tag_count > optional.tag_depth:
        raise SystemExit("tag FIFO count exceeded configured depth")
    print(
        "MAC_TAG_POP_PUSH_MODEL_PASS "
        f"baseline_cycles={baseline.cycles} optional_cycles={optional.cycles} "
        f"saved_cycles={baseline.cycles - optional.cycles} "
        f"full_pop_push={optional.full_pop_push} "
        f"max_tag={optional.max_tag_count}"
    )
