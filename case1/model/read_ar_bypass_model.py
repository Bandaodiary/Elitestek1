"""Handshake-level model for the optional empty-queue AR bypass.

The model is intentionally tiny: it records the only promised gain (one
startup bubble when the downstream is ready on the first cycle) and makes the
stalled-downstream case explicit.  It does not model DDR bandwidth or R data.
"""

from __future__ import annotations


def first_ar_latency(*, empty_ar_bypass: bool, downstream_ready_first: bool) -> int:
    """Return the number of startup bubbles before the first AR handshake."""

    if empty_ar_bypass and downstream_ready_first:
        return 0
    return 1


def compare_startup(*, downstream_ready_first: bool = True) -> dict[str, int]:
    baseline = first_ar_latency(
        empty_ar_bypass=False, downstream_ready_first=downstream_ready_first
    )
    optional = first_ar_latency(
        empty_ar_bypass=True, downstream_ready_first=downstream_ready_first
    )
    return {
        "baseline_first_ar_latency": baseline,
        "optional_first_ar_latency": optional,
        "saved_cycles": baseline - optional,
    }


if __name__ == "__main__":
    ready = compare_startup(downstream_ready_first=True)
    stalled = compare_startup(downstream_ready_first=False)
    assert ready == {
        "baseline_first_ar_latency": 1,
        "optional_first_ar_latency": 0,
        "saved_cycles": 1,
    }
    assert stalled["optional_first_ar_latency"] == 1
    print(
        "READ_AR_BYPASS_MODEL_PASS "
        f"ready={ready['baseline_first_ar_latency']}->"
        f"{ready['optional_first_ar_latency']} "
        f"stalled={stalled['optional_first_ar_latency']}"
    )
