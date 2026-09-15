from read_ar_bypass_model import compare_startup, first_ar_latency


def test_ready_startup_saves_one_bubble():
    assert compare_startup(downstream_ready_first=True) == {
        "baseline_first_ar_latency": 1,
        "optional_first_ar_latency": 0,
        "saved_cycles": 1,
    }


def test_stalled_startup_does_not_claim_a_gain():
    assert first_ar_latency(
        empty_ar_bypass=True, downstream_ready_first=False
    ) == 1


if __name__ == "__main__":
    test_ready_startup_saves_one_bubble()
    test_stalled_startup_does_not_claim_a_gain()
    print("READ_AR_BYPASS_TEST_PASS")
