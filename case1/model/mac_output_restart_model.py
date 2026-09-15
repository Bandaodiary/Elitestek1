"""Small board-independent model for ping-pong MAC bank reuse.

The RTL option ``ALLOW_OUTPUT_RESTART`` changes only the ownership boundary:
the bank that retires the ordered result may accept the next START on the same
edge.  This model deliberately does not model DSP arithmetic.  It checks the
event-level contract (ordered retirement, bank ownership, and the one-cycle
reuse gap) under a deterministic output-ready pattern used by the smoke TB.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class RestartResult:
    banks: int
    transactions: int
    allow_restart: bool
    starts: tuple[int, ...]
    retires: tuple[int, ...]
    bank_ids: tuple[int, ...]
    same_edge_restarts: int
    cycles: int


def simulate(
    *,
    banks: int = 2,
    transactions: int = 6,
    compute_latency: int = 6,
    ready_period: int = 7,
    ready_stall_phase: int = 3,
    allow_restart: bool = False,
) -> RestartResult:
    """Simulate transaction ownership, not arithmetic.

    ``compute_latency`` is the number of cycles from START acceptance to a
    result becoming eligible.  The result stream is ordered by transaction
    ID, just like the RTL tag FIFO.  A bank is reusable on the retirement edge
    only in the optional mode; in the baseline it becomes reusable next cycle.
    """

    if banks < 2 or transactions <= 0 or compute_latency < 1:
        raise ValueError("invalid bank/transaction/latency configuration")
    if ready_period <= 0:
        raise ValueError("ready_period must be positive")

    # ``free_at`` is the first cycle on which a bank can accept START.  A
    # large sentinel represents a bank whose result has not retired yet.
    free_at = [0] * banks
    bank_ids: list[int] = []
    starts: list[int] = []
    ready_at: list[int] = []
    retires: list[int] = []
    next_id = 0
    next_bank = 0
    cycle = 0
    same_edge = 0

    # At most one transaction is started per cycle, matching the ping-pong
    # wrapper's single START channel.  Retirement can happen on the same edge.
    while len(retires) < transactions:
        retiring_id = len(retires)
        retired_bank = None
        if (
            retiring_id < len(ready_at)
            and ready_at[retiring_id] <= cycle
            and (cycle % ready_period) != ready_stall_phase
        ):
            retired_bank = bank_ids[retiring_id]
            retires.append(cycle)
            free_at[retired_bank] = cycle if allow_restart else cycle + 1

        # Pick the first free bank from the round-robin cursor.  A bank freed
        # by the retirement above is intentionally visible in optional mode.
        if next_id < transactions:
            chosen = None
            for offset in range(banks):
                candidate = (next_bank + offset) % banks
                if free_at[candidate] <= cycle:
                    chosen = candidate
                    break
            if chosen is not None:
                if retired_bank == chosen:
                    same_edge += 1
                starts.append(cycle)
                bank_ids.append(chosen)
                ready_at.append(cycle + compute_latency)
                free_at[chosen] = 10**9
                next_bank = (chosen + 1) % banks
                next_id += 1
        cycle += 1
        if cycle > 1_000_000:
            raise RuntimeError("restart model did not converge")

    return RestartResult(
        banks=banks,
        transactions=transactions,
        allow_restart=allow_restart,
        starts=tuple(starts),
        retires=tuple(retires),
        bank_ids=tuple(bank_ids),
        same_edge_restarts=same_edge,
        cycles=cycle,
    )


def compare_default_optional(**kwargs: int) -> tuple[RestartResult, RestartResult]:
    """Return baseline and same-edge-restart schedules for one configuration."""

    return (
        simulate(allow_restart=False, **kwargs),
        simulate(allow_restart=True, **kwargs),
    )


if __name__ == "__main__":
    baseline, optional = compare_default_optional()
    if optional.cycles > baseline.cycles:
        raise SystemExit("optional restart unexpectedly increased cycles")
    if optional.same_edge_restarts <= 0:
        raise SystemExit("optional restart did not exercise a same-edge event")
    print(
        "MAC_OUTPUT_RESTART_MODEL_PASS "
        f"baseline_cycles={baseline.cycles} optional_cycles={optional.cycles} "
        f"saved_cycles={baseline.cycles - optional.cycles} "
        f"same_edge_restarts={optional.same_edge_restarts}"
    )
