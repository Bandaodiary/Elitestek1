from mac_tag_pop_push_model import compare_full_fifo, simulate


def test_full_fifo_replacement_preserves_order_and_depth():
    baseline, optional = compare_full_fifo()
    assert optional.cycles <= baseline.cycles
    assert optional.full_pop_push > 0
    assert optional.max_tag_count <= optional.tag_depth
    assert list(optional.retires) == sorted(optional.retires)
    assert len(optional.starts) == len(optional.retires) == 8
    assert all(0 <= bank < optional.banks for bank in optional.bank_ids)


def test_tag_option_is_inert_without_a_full_fifo_event():
    # With an over-provisioned tag FIFO the new admission condition is never
    # needed; enabling it must not change ownership or retirement order.
    baseline = simulate(tag_depth=8, allow_restart=False, allow_tag_pop_push=False)
    optional = simulate(tag_depth=8, allow_restart=False, allow_tag_pop_push=True)
    assert optional.starts == baseline.starts
    assert optional.retires == baseline.retires
    assert optional.bank_ids == baseline.bank_ids
    assert optional.full_pop_push == 0


if __name__ == "__main__":
    test_full_fifo_replacement_preserves_order_and_depth()
    test_tag_option_is_inert_without_a_full_fifo_event()
    print("MAC_TAG_POP_PUSH_TEST_PASS")
