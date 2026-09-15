"""Read-only arithmetic exploration; does not replace RTL or prove its timing."""
import json
import random


def old_record(magnitude, shift, negative):
    # Reachable signed32 * signed18 product: abs(product) <= 2**48.
    assert 0 <= magnitude <= 1 << 48 and 0 <= shift <= 47
    biased = magnitude + ((1 << (shift - 1)) if shift else 0)
    assert biased < 1 << 52
    rounded = biased >> shift
    return negative, bool(rounded >> 8), rounded & 255


def candidate_record(magnitude, shift, negative, mutation=None):
    quotient = magnitude >> shift
    guard = ((magnitude >> (shift - 1)) & 1) if shift else 0
    if mutation == 'drop_guard':
        guard = 0
    low_sum = (quotient & 255) + guard
    carry = bool(low_sum >> 8)
    if mutation == 'drop_carry':
        carry = False
    return negative, bool(quotient >> 8) or carry, low_sum & 255


def output(record, relu):
    negative, overflow, low = record
    if negative and relu:
        return 0
    if overflow or low > (128 if negative else 127):
        return -128 if negative else 127
    return -low if negative else low


def main():
    rng = random.Random(3901)
    records = 0
    outputs = 0
    shift_counts = [0] * 48
    negative_detected = {'drop_guard': 0, 'drop_carry': 0}

    def check(magnitude, shift, negative):
        nonlocal records, outputs
        reference = old_record(magnitude, shift, negative)
        candidate = candidate_record(magnitude, shift, negative)
        assert reference == candidate, (magnitude, shift, negative)
        records += 1
        shift_counts[shift] += 1
        for relu in (False, True):
            assert output(reference, relu) == output(candidate, relu)
            outputs += 1
        for mutation in negative_detected:
            bad = candidate_record(magnitude, shift, negative, mutation)
            if any(output(reference, relu) != output(bad, relu)
                   for relu in (False, True)):
                negative_detected[mutation] += 1

    for shift in range(48):
        values = {0, 1, 2, (1 << 48) - 1, 1 << 48}
        # Both sides of integer, half-way, signed saturation and carry edges.
        for quotient in (0, 1, 126, 127, 128, 129, 254, 255, 256, 257):
            for fraction in (0, (1 << (shift - 1)) if shift else 0):
                for delta in (-1, 0, 1):
                    value = (quotient << shift) + fraction + delta
                    if 0 <= value <= 1 << 48:
                        values.add(value)
        for value in values:
            for negative in (False, True):
                check(value, shift, negative)
    # Actual input extrema and random signed32/signed18 products.
    accumulators = [-(1 << 31), -(1 << 31) + 1, -1, 0, 1, (1 << 31) - 1]
    multipliers = [-(1 << 17), -(1 << 17) + 1, -1, 0, 1, (1 << 17) - 1]
    for acc in accumulators:
        for mult in multipliers:
            for shift in range(48):
                product = acc * mult
                check(abs(product), shift, product < 0)
    for _ in range(100000):
        product = rng.randrange(-(1 << 31), 1 << 31) * rng.randrange(-(1 << 17), 1 << 17)
        check(abs(product), rng.randrange(48), product < 0)
    assert min(shift_counts) > 0 and all(negative_detected.values())
    print(json.dumps({
        'marker': 'C39_REQUANT_ARITHMETIC_IDENTITY_PASS',
        'record_comparisons': records, 'output_comparisons': outputs,
        'all_48_shifts': True, 'signed32_signed18_extrema': True,
        'negative_tests_output_mismatches': negative_detected,
        'proposed_register_bits_saved_six_lanes': 288,
        'rtl_simulated': False, 'synthesis_measured': False,
        'production_rtl_modified': False,
    }, sort_keys=True))


if __name__ == '__main__':
    main()
