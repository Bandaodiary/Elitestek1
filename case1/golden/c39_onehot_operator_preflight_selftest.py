"""Gate unit tests using in-memory synthetic terminal evidence, never a RTL PASS."""
import copy
import json
from pathlib import Path
import re
from unittest.mock import patch
from c39_onehot_operator_preflight import ROOT, RUN, check


def main():
    folder = ROOT / 'logs/c39_datapath_runs' / RUN
    status_path, output_path = folder / 'status.json', folder / 'stdout.log'
    actual_status = json.loads(status_path.read_text(encoding='utf-8-sig'))
    actual_text = output_path.read_text(encoding='utf-8-sig')
    actual_terminal_verified = False
    if actual_status['state'] == 'running':
        try:
            check()
        except ValueError as exc:
            if 'not complete/isolated' not in str(exc):
                raise
        else:
            raise AssertionError('actual live run incorrectly accepted as complete')
    elif actual_status['state'] == 'complete':
        actual_terminal_verified = check()['full_operator_pass']
    else:
        raise ValueError('original run is neither live nor successfully complete')
    observed = re.findall(r'^C39_ONEHOT_COMPILED_SNAPSHOT (.+)$', actual_text, re.M)
    if not observed:
        raise ValueError('actual first compiled snapshot not ready')
    first = json.loads(observed[0])
    second = copy.deepcopy(first)
    second['stalls'] = 1
    second['snapshot'] = str(Path(first['snapshot']).with_name('tb_c37_operator_fallback_1.vvp'))
    records = [first, second]
    # Only a unit-test fixture: old numeric records are not attributed to onehot.
    retained = (ROOT / 'logs/c39_datapath_runs/c39_native_fallback_20260915b/stdout.log').read_text(encoding='utf-8-sig')
    retained = retained.replace('C39_NATIVE_VARIANT_BEGIN actual_compact_RGB_DW_construction=1',
                                'C39_ONEHOT_VARIANT_BEGIN actual_shared_decode_unpack=1')
    terminal = dict(actual_status, state='complete', exit_code=0)
    removed = {Path(row['snapshot']).resolve() for row in records}
    removed |= {path.parent for path in removed}
    original_read, original_exists = Path.read_text, Path.exists

    def evaluate(status, snapshots, output):
        position = 0
        def add_snapshot(match):
            nonlocal position
            payload = json.dumps(snapshots[position], separators=(',', ':'))
            position += 1
            return 'C39_ONEHOT_COMPILED_SNAPSHOT ' + payload + '\n' + match[0]
        injected = re.sub(r'^C39_VVP_BEGIN .+$', add_snapshot, output, flags=re.M)
        def read(path, *args, **kwargs):
            if path == status_path:
                return json.dumps(status)
            if path == output_path:
                return injected
            return original_read(path, *args, **kwargs)
        def exists(path):
            return False if path.resolve() in removed else original_exists(path)
        with patch.object(Path, 'read_text', read), patch.object(Path, 'exists', exists):
            return check()

    assert evaluate(terminal, records, retained)['full_operator_pass']  # synthetic only
    cases = []
    for field, value in (('state', 'running'), ('variant', 'native'), ('worker_pid', 1), ('child_in_windows_job', True)):
        cases.append((field, dict(terminal, **{field: value}), records, retained))
    changed = copy.deepcopy(records)
    changed[1]['stalls'] = 0
    cases.append(('duplicate_snapshot', terminal, changed, retained))
    changed = copy.deepcopy(records)
    changed[0]['active_sv_sources'] = [str(ROOT / 'rtl/c39/c39_operand_codec.sv') if Path(p).name == 'c39_operand_codec.sv' else p
                                      for p in changed[0]['active_sv_sources']]
    cases.append(('false_active_codec', terminal, changed, retained))
    for name, old, new in (
        ('missing_jobs', 'jobs=187', 'jobs=186'),
        ('missing_backpressure', 'held_cycles=192713', 'held_cycles=0'),
        ('missing_exit', 'C39_VVP_EXIT', 'REMOVED_EXIT'),
        ('missing_cleanup', 'C39_DATAPATH_PHASE_PASS', 'REMOVED_CLEANUP'),
    ):
        if old not in retained:
            raise ValueError('retained fixture anchor differs: ' + name)
        cases.append((name, terminal, records, retained.replace(old, new, 1)))
    rejected = []
    for name, state, snapshots, output in cases:
        try:
            evaluate(state, snapshots, output)
        except ValueError:
            rejected.append(name)
        else:
            raise AssertionError('corrupted fixture accepted: ' + name)
    print('C39_ONEHOT_OPERATOR_GATE_SELFTEST_PASS ' + json.dumps(dict(
        actual_running_state_rejected=actual_status['state']=='running', synthetic_terminal_positive=True,
        rejected=rejected, source_files_modified=False,
        actual_onehot_full_operator_complete=actual_terminal_verified), separators=(',', ':')))


if __name__ == '__main__':
    main()
