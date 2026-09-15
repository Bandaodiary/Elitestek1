"""C37 acceptance: retain the 15 fps goal, not merely functional completion.

Pure interval arithmetic. No synthetic result is an RTL/board performance claim.
"""
from r2_native_performance_contract import assess_intervals


def require_native_target(intervals):
    result = assess_intervals(intervals)
    if not result['target_15fps_met_for_observed_intervals']:
        raise ValueError('C37 functional run missed the observed 15 fps target')
    return result


def self_test():
    for good in ([10000000]*5, [6432428]*5, [1,2,3,4,5]):
        assert require_native_target(good)['target_15fps_met_for_observed_intervals']
    rejected = 0
    for bad in ([10000001]+[9999999]*4, [10000000]*4+[10000001],
                [10000000]*4, [10000000]*6, [10000000]*4+[0],
                [10000000]*4+[True], [10000000]*4+[10000000.0]):
        try:
            require_native_target(bad)
        except (ValueError,AssertionError):
            rejected += 1
        else:
            raise AssertionError('invalid/missed-target interval set accepted')
    print(f'C37_NATIVE_TARGET_SELFTEST_PASS positive=3 rejected={rejected} '
          'synthetic_only=1 RTL_simulated=0 native_fps_claim=0')


if __name__ == '__main__':
    self_test()
