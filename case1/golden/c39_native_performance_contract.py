"""Require both 15 fps and no worst-interval regression against actual C37 evidence."""
from functools import lru_cache
import json
from pathlib import Path
from c37_native_performance_contract import require_native_target as require_15fps

ROOT = Path(__file__).resolve().parents[1]
BASELINE_RUN = 'c37_stable_native_20260915a'


@lru_cache(maxsize=1)
def baseline_worst_interval():
    from check_c37_trained_pipeline import xsim, load
    from c37_trained_contract import bound_candidate, source_gate
    folder = ROOT / 'logs/c37_trained_host_runs' / BASELINE_RUN
    status = load(folder / 'status.json')
    if (status['state'] != 'complete' or status['exit_code'] != 0 or
            status['worker_in_windows_job'] is not False or status['simulator_directory_present'] is not False or
            Path(status['run_directory']).exists() or status.get('camera_profile') != 'camera30' or
            status.get('candidate') != 'C37' or status.get('skip_native') is not False):
        raise ValueError('retained C37 native baseline is not complete/clean/camera30')
    source_gate()
    _, config, provenance = bound_candidate(status['qat_run'])
    result = xsim(folder, status, 'native', config, provenance)
    return result['worst_interval_cycles']


def assess_no_regression(intervals, baseline_cycles):
    if type(baseline_cycles) is not int or baseline_cycles <= 0:
        raise ValueError('invalid baseline interval')
    result = require_15fps(intervals)
    if result['worst_interval_cycles'] > baseline_cycles:
        raise ValueError('C39 meets 15 fps but regresses against retained C37 worst interval')
    result.update(reference_worst_interval_cycles=baseline_cycles,
                  no_worst_interval_regression=True)
    return result


def require_native_target(intervals):
    result = assess_no_regression(intervals, baseline_worst_interval())
    result['reference_run'] = BASELINE_RUN
    return result


def self_test():
    reference = 6433652
    for good in ([reference]*5, [reference-1]*5):
        assert assess_no_regression(good, reference)['no_worst_interval_regression']
    rejected = 0
    for bad in ([reference+1]+[reference-1]*4, [10000000]*5, [10000001]*5,
                [reference]*4, [reference]*6, [reference]*4+[True], [reference]*4+[0]):
        try:
            assess_no_regression(bad, reference)
        except (ValueError, AssertionError):
            rejected += 1
        else:
            raise AssertionError('invalid/regressing synthetic intervals accepted')
    print('C39_NATIVE_PERFORMANCE_SELFTEST_PASS ' + json.dumps(dict(
        positive=2, rejected=rejected, synthetic_only=True, RTL_simulated=False)))


if __name__ == '__main__':
    self_test()
