"""Corrupt evidence in memory, not files, to test rejection by the final gate."""
import json
from pathlib import Path
from unittest.mock import patch
from c39_operator_preflight import ROOT, RUN, check


def main():
    baseline = check()
    folder = ROOT / 'logs/c39_datapath_runs' / RUN
    status_path = folder / 'status.json'
    audit_path = folder / 'actual_compiled_sources.json'
    output_path = folder / 'stdout.log'
    status = json.loads(status_path.read_text(encoding='utf-8-sig'))
    audit = json.loads(audit_path.read_text(encoding='utf-8-sig'))
    output = output_path.read_text(encoding='utf-8-sig')
    changes = []
    for field, value in (('state', 'running'), ('variant', 'combined'), ('child_in_windows_job', True)):
        changed = dict(status)
        changed[field] = value
        changes.append((field, status_path, json.dumps(changed)))
    changed = json.loads(json.dumps(audit))
    changed['worker_pid'] += 1
    changes.append(('wrong_process', audit_path, json.dumps(changed)))
    changed = json.loads(json.dumps(audit))
    changed['snapshots'][1]['stalls'] = 0
    changes.append(('duplicate_stalls', audit_path, json.dumps(changed)))
    changed = json.loads(json.dumps(audit))
    snapshot = changed['snapshots'][0]
    original = str(ROOT / 'rtl/c39_native/c1_r2_spatial_partitioned_feeder.sv')
    replacement = str(ROOT / 'rtl/c37/c1_r2_spatial_partitioned_feeder.sv')
    assert original in snapshot['active_sv_sources']
    snapshot['active_sv_sources'] = [replacement if path == original else path for path in snapshot['active_sv_sources']]
    changes.append(('false_source_claim', audit_path, json.dumps(changed)))
    changes.extend((
        ('missing_job', output_path, output.replace('jobs=187', 'jobs=186', 1)),
        ('missing_backpressure', output_path, output.replace('held_cycles=192713', 'held_cycles=0', 1)),
        ('missing_cleanup', output_path, output.replace('C39_DATAPATH_PHASE_PASS', 'REMOVED_FINAL_MARKER')),
    ))
    original_read = Path.read_text
    rejected = []
    for name, target, payload in changes:
        def altered(path, *args, **kwargs):
            return payload if path == target else original_read(path, *args, **kwargs)
        with patch.object(Path, 'read_text', altered):
            try:
                check()
            except ValueError:
                rejected.append(name)
            else:
                raise AssertionError('corrupted evidence accepted: ' + name)
    assert len(rejected) == 9 and baseline['full_operator_pass']
    print('C39_OPERATOR_PREFLIGHT_SELFTEST_PASS ' + json.dumps(dict(
        actual_positive_evidence=True, rejected=rejected, evidence_only_controls=True,
        source_files_modified=False, new_RTL_simulation=False), separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
