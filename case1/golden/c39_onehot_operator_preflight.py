"""Terminal gate for the actual one-hot full-operator run; never borrow native PASS."""
import json
from pathlib import Path
import re
from c39_onehot_sources import ROOT, OLD, NEW, verify
from c39_fallback_compile_audit import EXPECTED

RUN = 'c39_onehot_fallback_20260915a'
WORKER = 37320
START = '2026-09-15T19:58:38.0939319+08:00'


def check():
    verify()
    folder = ROOT / 'logs/c39_datapath_runs' / RUN
    status = json.loads((folder / 'status.json').read_text(encoding='utf-8-sig'))
    if (status['run_id'] != RUN or status['state'] != 'complete' or status['exit_code'] != 0 or
            status['variant'] != 'onehot' or status['phase'] != 'fallback' or
            status['worker_pid'] != WORKER or status['worker_start'] != START or
            status['worker_in_windows_job'] is not False or status['child_in_windows_job'] is not False):
        raise ValueError('original onehot full-operator run is not complete/isolated')
    path = folder / 'stdout.log'
    if path.stat().st_size > 262144 or (folder / 'stderr.log').stat().st_size:
        raise ValueError('unexpected operator log size or stderr')
    text = path.read_text(encoding='utf-8-sig')
    if not text.startswith('C39_ONEHOT_VARIANT_BEGIN actual_shared_decode_unpack=1\n'):
        raise ValueError('wrong actual variant entry')
    snapshots = [json.loads(item) for item in re.findall(r'^C39_ONEHOT_COMPILED_SNAPSHOT (.+)$', text, re.M)]
    expected = [NEW if source == OLD else source for source in EXPECTED]
    if len(snapshots) != 2 or [item['stalls'] for item in snapshots] != [0, 1]:
        raise ValueError('both actual compiled snapshots missing')
    private_dirs = set()
    for item in snapshots:
        if item['variant'] != 'onehot' or item['required_candidate_sources_verified'] != expected:
            raise ValueError('snapshot required source binding differs')
        actual = [Path(path).resolve() for path in item['active_sv_sources']]
        for relative in expected:
            required = (ROOT / relative).resolve()
            if [path for path in actual if path.name == required.name] != [required]:
                raise ValueError('actual source table differs from onehot implementation')
        if any(path.name == 'c1_requant_bank8_compact.sv' for path in actual):
            raise ValueError('old quantizer in actual source table')
        snapshot = Path(item['snapshot']).resolve()
        if (not snapshot.parent.is_relative_to((ROOT / 'sim').resolve()) or
                not snapshot.parent.name.startswith('c39_datapath_') or
                snapshot.name != f'tb_c37_operator_fallback_{item["stalls"]}.vvp'):
            raise ValueError('wrong actual snapshot path')
        private_dirs.add(snapshot.parent)
        if snapshot.exists() or snapshot.parent.exists():
            raise ValueError('private operator files still exist')
    if len(private_dirs) != 1:
        raise ValueError('snapshots came from different invocations')
    starts = re.findall(r'^C39_VVP_BEGIN pid=(\d+) wall_timeout_seconds=(\d+)$', text, re.M)
    ends = re.findall(r'^C39_VVP_EXIT pid=(\d+) exit_code=(\d+) elapsed_seconds=([0-9.]+)$', text, re.M)
    if len(starts) != 2 or len(ends) != 2 or any(
            a[0] != b[0] or b[1] != '0' or int(a[1]) != status['fallback_wall_timeout_seconds']
            for a, b in zip(starts, ends)):
        raise ValueError('actual vvp begin/exit pairs incomplete')
    lines = re.findall(r'^C37_ACTUAL_RTL C37_OPERATOR_PASS (.+)$', text, re.M)
    if len(lines) != 2:
        raise ValueError('both actual full-operator PASS records missing')
    common = dict(jobs=187, vectors=167635, bulk_writes=115822, parameter_reads=225634,
                  reset_modes=6, packed_weights=1, lanes=6)
    records = []
    for stalls, line in enumerate(lines):
        fields = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
        if any(fields.get(key) != value for key, value in dict(common, stalls=stalls).items()):
            raise ValueError('actual operator coverage incomplete')
        if fields.get('busy_rejections', 0) < 20 or (stalls and fields.get('held_cycles', 0) < 20):
            raise ValueError('active mutation or backpressure coverage missing')
        records.append(fields)
    marker = 'C39_DATAPATH_PHASE_PASS phase=fallback actual_candidate_sources=1 temporary_removed=1 waves=0'
    if text.count(marker) != 1 or not text.rstrip().endswith(marker):
        raise ValueError('unique terminal cleanup marker missing')
    return dict(run=RUN, candidate='C39_ONEHOT', full_operator_pass=True,
        stalls_profiles=2, actual_compiled_sources_verified=True, temporary_removed=True,
        records=records, actual_AXI_host_verified=False, native_frame_rate_verified=False)


if __name__ == '__main__':
    print('C39_ONEHOT_OPERATOR_PREFLIGHT_PASS ' + json.dumps(check(), separators=(',', ':')), flush=True)
