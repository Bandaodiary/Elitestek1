"""Regression checks for the boardless refill-tail optimization."""

from read_tail_flush_model import simulate


def test_tail_flush_preserves_geometry_and_reduces_tail():
    slow = simulate(5, 8, burst_beats=4, build_timeout=3)
    fast = simulate(5, 8, burst_beats=4, build_timeout=3, tail_flush=True)
    assert (slow.axi_beats, slow.axi_bursts, slow.packed_requests) == (
        fast.axi_beats,
        fast.axi_bursts,
        fast.packed_requests,
    )
    assert fast.total_cycles < slow.total_cycles
    assert slow.total_cycles - fast.total_cycles == 10


def test_tail_flush_handles_odd_row_without_lane_loss():
    slow = simulate(3, 7, burst_beats=4, build_timeout=5)
    fast = simulate(3, 7, burst_beats=4, build_timeout=5, tail_flush=True)
    assert fast.axi_beats == slow.axi_beats == 12
    assert fast.packed_requests == slow.packed_requests == 9
    assert slow.total_cycles - fast.total_cycles == 12
