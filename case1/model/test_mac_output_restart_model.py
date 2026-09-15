from mac_output_restart_model import compare_default_optional, simulate


def test_same_edge_restart_preserves_order_and_reduces_or_matches_cycles():
    baseline, optional = compare_default_optional()
    assert optional.cycles <= baseline.cycles
    assert optional.same_edge_restarts > 0
    assert optional.bank_ids  # every transaction has one owner
    assert len(optional.starts) == len(optional.retires) == 6
    assert list(optional.retires) == sorted(optional.retires)


def test_more_banks_do_not_create_invalid_owner_ids():
    result = simulate(banks=4, transactions=12, allow_restart=True)
    assert all(0 <= bank < 4 for bank in result.bank_ids)
    assert len(result.bank_ids) == 12


if __name__ == "__main__":
    test_same_edge_restart_preserves_order_and_reduces_or_matches_cycles()
    test_more_banks_do_not_create_invalid_owner_ids()
    print("MAC_OUTPUT_RESTART_TEST_PASS")
