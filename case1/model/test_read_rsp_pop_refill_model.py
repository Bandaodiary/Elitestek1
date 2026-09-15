"""Direct regression hook for read_rsp_pop_refill_model.py."""

from read_rsp_pop_refill_model import simulate


def main() -> None:
    beats = [2, 2, 2, 2, 1]
    default = simulate(allow_pop_refill=False, depth=2, lane_counts=beats)
    optional = simulate(allow_pop_refill=True, depth=2, lane_counts=beats)
    assert default["logical_outputs"] == sum(beats)
    assert optional["logical_outputs"] == sum(beats)
    assert optional["max_occupancy"] <= 2
    assert optional["packed_pop_refills"] > 0
    assert optional["cycles"] < default["cycles"]
    print(
        "READ_RSP_POP_REFILL_TEST_PASS "
        f"default={default['cycles']} optional={optional['cycles']}"
    )


if __name__ == "__main__":
    main()
