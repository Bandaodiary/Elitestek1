from write_rsp_pop_refill_model import simulate


def test_optional_mode_reuses_popped_slot():
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
    assert refill["producer_stalls"] < baseline["producer_stalls"]
    assert refill["responses"] == baseline["responses"] == 12


if __name__ == "__main__":
    test_optional_mode_reuses_popped_slot()
    print("WRITE_RSP_POP_REFILL_TEST_PASS")
