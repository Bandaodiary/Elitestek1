"""Require real native full-operator terminal evidence before host regressions."""
import json
from pathlib import Path
import re
from c39_native_sources import ROOT, verify
from c39_fallback_compile_audit import EXPECTED

RUN = 'c39_native_fallback_20260915b'


def check():
    folder = ROOT / 'logs/c39_datapath_runs' / RUN
    status = json.loads((folder / 'status.json').read_text(encoding='utf-8-sig'))
    if (status['run_id'] != RUN or status['state'] != 'complete' or status['exit_code'] != 0 or
            status['variant'] != 'native' or status['phase'] != 'fallback' or
            status['worker_in_windows_job'] is not False or status['child_in_windows_job'] is not False):
        raise ValueError('native full-operator run is not complete/isolated')
    verify()
    audit = json.loads((folder / 'actual_compiled_sources.json').read_text(encoding='utf-8'))
    if (audit['marker'] != 'C39_NATIVE_ACTUAL_VVP_SOURCE_AUDIT_PASS' or audit['run'] != RUN or
            audit['worker_pid'] != status['worker_pid'] or audit['worker_start'] != status['worker_start'] or
            audit['python_pid'] != status['child_pid'] or audit['python_start'] != status['child_start']):
        raise ValueError('actual compiled-source audit is for a different run')
    snapshots = audit['snapshots']
    if len(snapshots) != 2 or {item['stalls'] for item in snapshots} != {0, 1}:
        raise ValueError('both actual compiled snapshots are required')
    for item in snapshots:
        if item['required_native_sources_verified'] != list(EXPECTED):
            raise ValueError('snapshot did not prove every native replacement')
        actual = [Path(path).resolve() for path in item['active_sv_sources']]
        for relative in EXPECTED:
            expected = (ROOT / relative).resolve()
            if [path for path in actual if path.name == expected.name] != [expected]:
                raise ValueError('actual source table differs from claimed native replacement')
        if any(path.name == 'c1_requant_bank8_compact.sv' for path in actual):
            raise ValueError('old quantizer in actual source table')
        if Path(item['snapshot']).exists() or Path(item['snapshot']).parent.exists():
            raise ValueError('private simulation artifacts were not removed')
    path = folder / 'stdout.log'
    if path.stat().st_size > 262144 or (folder / 'stderr.log').stat().st_size:
        raise ValueError('unexpected operator log size or stderr')
    text = path.read_text(encoding='utf-8-sig')
    if not text.startswith('C39_NATIVE_VARIANT_BEGIN actual_compact_RGB_DW_construction=1\n'):
        raise ValueError('wrong actual variant entry')
    lines = re.findall(r'^C37_ACTUAL_RTL C37_OPERATOR_PASS (.+)$', text, re.M)
    if len(lines) != 2 or len(re.findall(r'^C39_VVP_EXIT pid=\d+ exit_code=0 ', text, re.M)) != 2:
        raise ValueError('two actual vvp PASS/exit records missing')
    common = dict(jobs=187, vectors=167635, bulk_writes=115822, parameter_reads=225634,
                  reset_modes=6, packed_weights=1, lanes=6)
    records = []
    for stalls, line in enumerate(lines):
        fields = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
        if any(fields.get(key) != value for key, value in dict(common, stalls=stalls).items()):
            raise ValueError('incomplete actual operator coverage')
        if fields['busy_rejections'] < 20 or (stalls == 1 and fields['held_cycles'] < 20):
            raise ValueError('missing active-mutation/backpressure checks')
        records.append(fields)
    if text.count('C39_DATAPATH_PHASE_PASS phase=fallback actual_candidate_sources=1 temporary_removed=1 waves=0') != 1:
        raise ValueError('missing unique final cleanup marker')
    return dict(run=RUN, candidate='C39_NATIVE', full_operator_pass=True, stalls_profiles=2,
                actual_compiled_sources_verified=True, temporary_removed=True, records=records,
                actual_AXI_host_verified=False, native_frame_rate_verified=False)


if __name__ == '__main__':
    print('C39_OPERATOR_PREFLIGHT_PASS ' + json.dumps(check(), separators=(',', ':')), flush=True)
