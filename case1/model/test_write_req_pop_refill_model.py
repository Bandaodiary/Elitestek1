"""Smoke test for :mod:`write_req_pop_refill_model`."""

from write_req_pop_refill_model import main


def test_write_req_pop_refill_model() -> None:
    assert main() == 0
