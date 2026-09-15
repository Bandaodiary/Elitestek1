"""Reuse full camera/CPU/display checks with explicit fused traffic accounting."""
import json
from pathlib import Path
import re
from unittest.mock import patch

import check_r2_rgb2_host_evidence as baseline
from check_r2_fused_host_source import ROOT,source_gate

PREFIX='C1_R2_FUSED_RGB2_HOST_SYSTEM_'


def check_text(text,profile='microstyle24',nn=2,clock_native_override=None):
    original_budget=baseline.c24.c18.budget
    def fused_budget(profile,width,height):
        b=dict(original_budget(profile,width,height))
        removed=width*height;extra=72*(height-1)
        b['reads']+=extra-removed;b['writes']-=removed;b['features']-=removed
        return b
    # Only expected transfer counts change. Preserve EVERY existing actual
    # source/ROI/Resize/tag/CPU/APB/IRQ/AXI/display/pause accounting check.
    with patch.object(baseline.c24.c18,'budget',fused_budget):
        result=baseline.run(text,profile=profile,prefix=PREFIX,expected_nn=nn,clock_native_override=clock_native_override)
    if baseline.c24.c18.budget is not original_budget:raise ValueError('baseline checker override leaked')
    return result


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid host run')
    folder=ROOT/'logs/r2_fused_rgb2_host_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=ROOT/'sim'/f'c1_r2_fused_host_{run}'
    if (status.get('state')!='complete' or status.get('exit_code')!=0 or status.get('run_id')!=run or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private.resolve() or private.exists()):raise ValueError('host not complete/clean/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong host budget')
    if (folder/'result.log').stat().st_size>131072 or (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('oversized/failed host text')
    text=(folder/'result.log').read_text(encoding='utf-8-sig')
    if re.search('FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed host log')
    source_gate();result=check_text(text)
    if text.splitlines().count('C35_FUSED_HOST_SMOKE_PASS correct_CNN_frames=2 actual_AXI=1 actual_CPU_IP=0 native_fps_claim=0')!=1:raise ValueError('missing smoke gate')
    print('C35_FUSED_HOST_GATE_PASS '+json.dumps(dict(run=run,actual_AXI=True,actual_CPU_IP=False,
        native_fps_claim=False,physical_RAM_measured=False,host_result=result,
        temporary_removed=True,seconds=status['elapsed_seconds'],process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
