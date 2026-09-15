"""Independent C35 AXI host matrix checks; no full-frame performance claim."""
import argparse
import json
from pathlib import Path
import re

from check_r2_fused_host_evidence import ROOT,PREFIX,check_text as host_check

CASES=[dict(id=f'original_{w}_{s}',profile='microstyle24',shape=f'{w}x{w}',stalls=s,negative=False)
       for w in (8,32) for s in (0,1)]
CASES += [dict(id='variant_32_1',profile='drop_res1',shape='32x32',stalls=1,negative=False)]
CASES += [dict(id=f'negative_8_{s}',profile='microstyle24',shape='8x8',stalls=s,negative=True) for s in (0,1)]


def check_case(case,text):
    if re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed case')
    if text.splitlines().count(PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1')!=1:
        raise ValueError('missing private cleanup')
    if case['negative']:
        entries=re.findall(r'^'+PREFIX+r'NEGATIVE_PASS width=(\d+) height=(\d+) stalls=(\d+) corruption=(\d+) actual_ram_mutation=1$',text,re.M)
        if len(entries)!=2 or {tuple(map(int,e)) for e in entries}!={(8,8,case['stalls'],1),(8,8,case['stalls'],2)}:
            raise ValueError('negative configurations incomplete')
        if PREFIX+'PASS ' in text:raise ValueError('corrupted execution passed')
        return None
    result=host_check(text,profile=case['profile'],nn=2)
    w,h=map(int,case['shape'].split('x'))
    if (result['width'],result['height'],result['stalls'])!=(w,h,case['stalls']):raise ValueError('wrong host configuration')
    return result


def check_text(text):
    matches=list(re.finditer(r'^C35_HOST_CASE_BEGIN ([^\r\n]+)\r?\n(.*?)^C35_HOST_CASE_END (\S+)[^\S\r\n]*$',text,re.M|re.S))
    if len(matches)!=len(CASES):raise ValueError('incomplete matrix')
    results=[]
    for expected,m in zip(CASES,matches):
        if json.loads(m[1])!=expected or m[3]!=expected['id']:raise ValueError('case identity/order mismatch')
        result=check_case(expected,m[2])
        if result:results.append(dict(case=expected['id'],completion_intervals=result['completion_intervals']))
    return dict(positive_configurations=5,correct_CNN_frames=10,actual_RAM_corruption_controls=4,
                actual_AXI=True,actual_CPU_IP=False,native_fps_claim=False,cases=results)


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid run')
    folder=ROOT/'logs/r2_fused_rgb2_regression_runs'/run
    s=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=ROOT/'sim'/f'c1_r2_fused_regression_{run}'
    if (s['state']!='complete' or s['exit_code']!=0 or s['run_id']!=run or
        s['worker_in_windows_job'] is not False or s['simulator_directory_present'] is not False or
        private.exists() or Path(s['run_directory']).resolve()!=private.resolve()):raise ValueError('not complete/clean/detached')
    b=s['workload_budget']
    if b['policy']!='single-heavy-worker' or b['logical_processors'] not in (1,2) or b['priority']!='BelowNormal':raise ValueError('wrong workload budget')
    if (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip() or (folder/'result.log').stat().st_size>262144:
        raise ValueError('failed/oversized output')
    text=(folder/'result.log').read_text(encoding='utf-8-sig')
    result=check_text(text)
    markers=[json.loads(line.split(' ',1)[1]) for line in text.splitlines() if line.startswith('C35_FUSED_HOST_REGRESSION_PASS ')]
    if markers!=[result]:raise ValueError('summary differs from independent matrix check')
    rejected=0
    for damaged in (text.replace('C35_HOST_CASE_END original_8_0','C35_HOST_CASE_END wrong',1),
                    text.replace('corruption=2','corruption=3',1),
                    text.replace('actual_ram_mutation=1','actual_ram_mutation=0',1),
                    text.replace(PREFIX+'PASS ',PREFIX+'OMITTED ',1)):
        try:check_text(damaged)
        except (ValueError,AssertionError):rejected+=1
        else:raise ValueError('damaged evidence accepted')
    print('C35_FUSED_HOST_REGRESSION_GATE_PASS '+json.dumps(dict(run=run,**result,
        evidence_corruption_rejections=rejected,temporary_removed=True,seconds=s['elapsed_seconds'],
        process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
