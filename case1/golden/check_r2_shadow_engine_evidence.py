"""C35 actual shared-MAC row arithmetic gate. Not full-graph/PNR/fps signoff."""
import argparse
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
EXPECTED={(w,h,s,0) for w,h in ((4,4),(12,6),(32,6),(640,4)) for s in (0,1)}|{(12,6,1,1),(12,6,1,2)}
SUMMARY=dict(configurations=10,operations=104,packets=25252,shadow_words=23296,
             fallback_configurations=2,negative_controls=3,full_graph=False,actual_AXI=False,
             native_fps_claim=False,physical_RAM_measured=False)


def records(text,prefix):
    return [json.loads(line[len(prefix):]) for line in text.splitlines() if line.startswith(prefix)]


def check_text(text):
    if re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed result text')
    cases=records(text,'C35_SHADOW_ENGINE_CASE ')
    keys={(c['width'],c['height'],c['stalls'],c['reset_phase']) for c in cases}
    if len(cases)!=10 or keys!=EXPECTED:raise ValueError('arithmetic matrix differs')
    for c in cases:
        w,h,stalls,reset=c['width'],c['height'],c['stalls'],c['reset_phase']
        packets=h*(w*3+(w*8+5)//6)
        exact=dict(operations=h*2,DW_rows=h,PW_rows=h,packets=packets,mac_beats=packets,
            shadow_words=w*h*4,bulk_writes=(w//2)*(h//2)*3,parameter_writes=h*144,
            resets=int(reset!=0),real_DW_PW_arithmetic=1,checker_only_intermediates=1,actual_AXI=0,full_graph=0)
        if any(c.get(k)!=v for k,v in exact.items()):raise ValueError('wrong arithmetic coverage')
        if stalls and c.get('held_cycles',0)<8:raise ValueError('no actual output backpressure')
        if not stalls and c.get('held_cycles')!=0:raise ValueError('unexpected nominal output stall')
        if reset and c.get('discarded_packets',0)<3:raise ValueError('reset not inside arithmetic')
        if w>=12 and c.get('overlap_cycles',0)==0:raise ValueError('partition write overlap not exercised')
    negatives=[line for line in text.splitlines() if line.startswith('C35_SHADOW_ENGINE_NEGATIVE_PASS ')]
    if negatives!=[f'C35_SHADOW_ENGINE_NEGATIVE_PASS case={i} actual_DUT_corruption=1' for i in (1,2,3)]:
        raise ValueError('actual negative matrix differs')
    vector_meta=records(text,'C35_SHADOW_ENGINE_FALLBACK_VECTORS ')
    fallback=records(text,'C35_SHADOW_ENGINE_FALLBACK_PASS ')
    if len(vector_meta)!=1 or len(fallback)!=2 or {c['stalls'] for c in fallback}!={0,1}:raise ValueError('fallback matrix differs')
    meta=vector_meta[0]
    if set(meta.get('mode_jobs',{}))!={str(i) for i in range(6)} or any(meta['mode_jobs'][str(i)]<1 for i in range(6)):
        raise ValueError('not all six fallback modes')
    if sum(meta['mode_jobs'].values())!=meta['jobs']:raise ValueError('fallback mode count mismatch')
    for c in fallback:
        exact=dict(jobs=meta['jobs'],vectors=meta['vectors'],bulk_writes=meta['bulk'],reset_modes=6,packed_weights=1,lanes=6)
        if any(c.get(k)!=v for k,v in exact.items()):raise ValueError('fallback coverage differs')
        if c['stalls'] and c.get('held_cycles',0)<20:raise ValueError('fallback backpressure missing')
    summaries=records(text,'C35_SHADOW_ENGINE_SUMMARY ')
    if summaries!=[SUMMARY]:raise ValueError('wrong summary or overstated scope')
    for key in ('operations','packets','shadow_words'):
        if sum(c[key] for c in cases)!=SUMMARY[key]:raise ValueError('aggregate mismatch')
    if text.splitlines().count('C35_SHADOW_ENGINE_CLEAN temporary_vectors_and_simulator_removed=1')!=1:
        raise ValueError('cleanup record missing')
    return dict(**SUMMARY,fallback_jobs_per_configuration=meta['jobs'],fallback_vectors_per_configuration=meta['vectors'],
        DW_window_shadow_overlap_cycles=sum(c.get('overlap_cycles',0) for c in cases),
        reset_discarded_packets=[c['discarded_packets'] for c in cases if c['reset_phase']])


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid RunId')
    folder=ROOT/'logs/r2_shadow_engine_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=(ROOT/'sim'/f'c1_r2_shadow_engine_{run}').resolve()
    if (status.get('run_id')!=run or status.get('state')!='complete' or status.get('exit_code')!=0 or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private or private.exists()):raise ValueError('run not clean/complete/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong worker budget')
    log=folder/'result.log'
    if log.stat().st_size>131072:raise ValueError('oversized arithmetic log')
    if (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('arithmetic stderr not empty')
    counts=check_text(log.read_text(encoding='utf-8-sig'))
    print('C35_SHADOW_ENGINE_EVIDENCE_PASS '+json.dumps(dict(run=run,**counts,temporary_removed=True,
        elapsed_seconds_including_queue=status['elapsed_seconds'],process_liveness_not_inferred=True),separators=(',',':')))


def selftest():
    lines=[]
    for w,h,s,r in sorted(EXPECTED):
        packets=h*(w*3+(w*8+5)//6)
        c=dict(width=w,height=h,stalls=s,reset_phase=r,operations=h*2,DW_rows=h,PW_rows=h,packets=packets,
            mac_beats=packets,shadow_words=w*h*4,bulk_writes=(w//2)*(h//2)*3,parameter_writes=h*144,
            resets=int(r!=0),real_DW_PW_arithmetic=1,checker_only_intermediates=1,actual_AXI=0,full_graph=0,
            held_cycles=8*s,discarded_packets=3 if r else 0,overlap_cycles=1)
        lines.append('C35_SHADOW_ENGINE_CASE '+json.dumps(c))
    lines.extend(f'C35_SHADOW_ENGINE_NEGATIVE_PASS case={i} actual_DUT_corruption=1' for i in (1,2,3))
    lines.append('C35_SHADOW_ENGINE_FALLBACK_VECTORS '+json.dumps(dict(jobs=6,vectors=60,bulk=12,mode_jobs={str(i):1 for i in range(6)})))
    for s in (0,1):lines.append('C35_SHADOW_ENGINE_FALLBACK_PASS '+json.dumps(dict(stalls=s,jobs=6,vectors=60,bulk_writes=12,reset_modes=6,packed_weights=1,lanes=6,held_cycles=20*s)))
    lines.append('C35_SHADOW_ENGINE_SUMMARY '+json.dumps(SUMMARY))
    lines.append('C35_SHADOW_ENGINE_CLEAN temporary_vectors_and_simulator_removed=1')
    good='\n'.join(lines);check_text(good)
    bad=[good.replace('"operations": 8','"operations": 7',1),good.replace('"mac_beats": 72','"mac_beats": 71',1),
         good.replace('"checker_only_intermediates": 1','"checker_only_intermediates": 0',1),
         good.replace('"full_graph": false','"full_graph": true'),good.replace('case=3','case=2'),
         good.replace('"reset_modes": 6','"reset_modes": 5',1),good.replace('"overlap_cycles": 1','"overlap_cycles": 0'),
         good.replace('C35_SHADOW_ENGINE_CLEAN','NO_CLEAN'),good+'\n'+lines[0],good+'\nFATAL no']
    for text in bad:
        try:check_text(text)
        except ValueError:pass
        else:raise AssertionError('corrupted arithmetic evidence accepted')
    print('C35_SHADOW_ENGINE_GATE_SELFTEST_PASS '+json.dumps(dict(synthetic_matrix=1,rejected=len(bad),RTL_executed=False,actual_run_claim=False),separators=(',',':')))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run');parser.add_argument('--selftest',action='store_true');args=parser.parse_args()
    if args.selftest:selftest()
    elif args.run:run_gate(args.run)
    else:parser.error('choose --selftest or --run')
