"""C35 directed fused-stage row-transfer recovery gate. Not local CPU cancel."""
import argparse
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid run')
    folder=ROOT/'logs/r2_row_fused_fault_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=ROOT/'sim'/f'c1_r2_row_fused_fault_{run}'
    if (status.get('state')!='complete' or status.get('run_id')!=run or status.get('exit_code')!=0 or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private.resolve() or private.exists()):raise ValueError('not complete/clean/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong budget')
    if (folder/'result.log').stat().st_size>131072 or (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('oversized/failed log')
    text=(folder/'result.log').read_text(encoding='utf-8-sig')
    if re.search('FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed evidence')
    prefix='C35_ROW_FUSED_FAULTS_EVIDENCE '
    records=[json.loads(x[len(prefix):]) for x in text.splitlines() if x.startswith(prefix)]
    if len(records)!=1:raise ValueError('wrong evidence count')
    r=records[0]
    if r['correct_frames']!=8 or r['full_DAG'] is not True or any(r.get(k) is not False for k in ('actual_AXI','native_fps_claim','local_CPU_cancel_claim')):raise ValueError('wrong scope')
    if len(r['faults'])!=4 or [f['fault'] for f in r['faults']]!=[13,14,15,16] or any(f['commits']!=18 or f['drained']!=1 for f in r['faults']):raise ValueError('missing read/write error drain')
    if len(r['resets'])!=3 or [f['phase'] for f in r['resets']]!=[6,7,8] or any(f['restart_golden']!=1 or f['cleared_pages']!=1 for f in r['resets']):raise ValueError('missing fused resets')
    if text.splitlines().count('C35_ROW_FUSED_FAULTS_CLEAN temporary_vectors_and_simulator_removed=1')!=1:raise ValueError('cleanup marker')
    print('C35_FUSED_FAULT_GATE_PASS '+json.dumps(dict(run=run,**r,temporary_removed=True,
        seconds=status['elapsed_seconds'],process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
