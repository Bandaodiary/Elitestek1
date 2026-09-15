"""C34 independent retained-event audit. Selftests are synthetic, not RTL evidence."""
from __future__ import annotations
import argparse
import contextlib
import copy
import io
import json
from pathlib import Path
import re

import run_r2_ring_write_contention as probe
import check_r2_credit_write_evidence as predecessor

ROOT=probe.ROOT
KEYS=('mode','channels','width','candidate','aw_wait_w','inject_b','force_refill','input_gap')
REASONS={'BREAK_CREDIT':'C33 grant exceeds published logical words',
         'BREAK_DRAIN':'C33 authorized burst failed to drain during refill'}


def expected_keys():
    base={(m,c,w,v,aw,e,0,g) for m,c,w in probe.retained.SHAPES
          for v in (2,3) for aw in (0,2) for e in (0,1) for g in (0,8)}
    boundary={(m,c,w,v,aw,0,0,0) for m,c,w in probe.retained.BOUNDARIES for v in (2,3) for aw in (0,2)}
    refill={(m,c,w,v,aw,0,1,8) for m,c,w in probe.retained.REFILL_SHAPES for v in (2,3) for aw in (0,2)}
    assert len(base)==48 and len(boundary)==32 and len(refill)==12
    assert not (base&boundary or base&refill or boundary&refill)
    return base|boundary|refill


def comparisons_for(rows):
    result={}
    for m,c,w in probe.retained.SHAPES:
        for aw in (0,2):
            for error in (0,1):
                for gap in (0,8):
                    pair=[rows[m,c,w,v,aw,error,0,gap] for v in (2,3)]
                    result[m,aw,error,gap]=dict(mode=m,aw_wait_w=aw,inject_b=error,input_gap=gap,
                        capture_wait=[r['capture_command_wait_max'] for r in pair],
                        empty_head=[r['blocked_empty_head'] for r in pair],
                        producer_span=[r['nn_span_cycles'] for r in pair],full_host_fps_claim=False)
    return result


def summary_for(rows):
    ring=[r for r in rows.values() if r['candidate']==3]
    return dict(configurations=len(rows),comparisons=24,
        peak_reserved_words=max(r['peak_used'] for r in ring),wrap_events=sum(r['wraps'] for r in ring),
        space_stall_cycles=sum(r['space_waits'] for r in ring),actual_negative_controls=2,
        physical_words=sum(r['nn_words']+r['capture_words'] for r in rows.values()),
        physical_bursts=sum(r['aw'] for r in rows.values()),full_host_fps_claim=False)


def analyze(text):
    assert not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text)
    expected=expected_keys();rows={};comparisons={};negatives={};summaries=[];clean=0
    for line in text.splitlines():
        if not line.strip():continue
        if line.startswith('C34_WRITE_AXI_PASS '):
            fields=dict(token.split('=') for token in line.split()[1:])
            key=tuple(int(fields[n]) for n in KEYS)
            assert key in expected and key not in rows,'unexpected/duplicate configuration'
            m,c,w,v,aw,e,f,g=key
            physical=(w+3)//4 if m==1 else ((w+1)//2)*((c+7)//8)
            params=dict(zip((n.upper() for n in KEYS),key),PHYSICAL_WORDS=physical)
            r=probe.parse_result(line,params)
            if v==3:
                logical=((w+1)//2)*((c+7)//8)
                assert logical<=r['peak_used']<=1024
                assert 0<=r['wraps']<=r['nn_rows'] and 0<=r['simultaneous_reserve_read']<=r['nn_rows']
                assert 0<=r['space_waits']<=r['nn_span_cycles']
            rows[key]=r
        elif line.startswith('C34_WRITE_AXI_COMPARE '):
            r=json.loads(line.split(' ',1)[1]);key=r['mode'],r['aw_wait_w'],r['inject_b'],r['input_gap']
            assert key not in comparisons;comparisons[key]=r
        elif line.startswith('C34_WRITE_AXI_NEGATIVE_PASS '):
            r=json.loads(line.split(' ',1)[1]);assert r['control'] not in negatives;negatives[r['control']]=r
        elif line.startswith('C34_WRITE_AXI_SUMMARY '):summaries.append(json.loads(line.split(' ',1)[1]))
        elif line=='C34_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1':clean+=1
        else:raise AssertionError('unexpected retained event: '+line[:100])
    assert set(rows)==expected and len(rows)==92 and clean==1,'matrix/cleanup incomplete'
    assert comparisons==comparisons_for(rows),'comparison differs from actual events'
    assert negatives=={c:dict(control=c,actual_RTL_rejected=True,reason=r) for c,r in REASONS.items()}
    summary=summary_for(rows);assert summaries==[summary],'summary differs from events'
    assert summary['peak_reserved_words']==1024 and summary['wrap_events']>0 and summary['space_stall_cycles']>0
    return rows,comparisons,summary


def gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name)
    folder=ROOT/'logs/r2_ring_write_axi_runs'/name
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    assert status['run_id']==name and status['state']=='complete' and status['exit_code']==0
    assert status['worker_in_windows_job'] is False and status['worker_start']
    private=(ROOT/'sim'/f'c1_r2_ring_write_axi_{name}').resolve()
    assert Path(status['run_directory']).resolve()==private and not private.exists()
    assert status['simulator_directory_present'] is False
    budget=status['workload_budget']
    assert budget['policy']=='single-heavy-worker' and 1<=budget['logical_processors']<=2 and budget['priority']=='BelowNormal'
    assert status['actual_AXI'] is True and status['actual_camera'] is False and status['whole_CNN_fps_claim'] is False
    for stem in ('writer_gate','word_model','result'):
        assert not (folder/(stem+'.stderr.log')).read_text(encoding='utf-8-sig').strip()
    # Recheck predecessor, not merely a copied PASS marker in the successor.
    buf=io.StringIO()
    with contextlib.redirect_stdout(buf):predecessor.gate(status['predecessor_writer_run'])
    assert buf.getvalue().strip()==(folder/'writer_gate.log').read_text(encoding='utf-8-sig').strip()
    model_text=(folder/'word_model.log').read_text(encoding='utf-8-sig').strip()
    assert model_text.startswith('C34_RING_MODEL_PASS ') and '\n' not in model_text
    model=json.loads(model_text.split(' ',1)[1])
    assert model['trials']==16 and model['rows']==768 and model['source_default_bytes']==16384 and model['baseline_bytes']==32768
    assert all(model[k]>0 for k in ('wraps','space_stalls','simultaneous_events','reuse_before_row_B'))
    assert all(model[k] is False for k in ('RTL_compiled','RTL_simulated','FPGA_resource_measured'))
    rows,comparisons,summary=analyze((folder/'result.log').read_text(encoding='utf-8-sig'))
    # Signed deltas are observations, never silently turned into an improvement gate.
    for key in sorted(comparisons):
        if key[2]==0:print('C34_RING_OBSERVATION '+json.dumps(comparisons[key],separators=(',',':')))
    print('C34_RING_EVIDENCE_PASS '+json.dumps(dict(run=name,seconds=status['elapsed_seconds'],
        FPGA_resource_measured=False,simultaneous_reserve_reads=sum(r['simultaneous_reserve_read'] for r in rows.values()),
        **summary),separators=(',',':')))


def synthetic_fixture():
    # Reuse field schemas from real C33 records, but synthesize C34 metrics solely
    # in memory. These records must never be saved as an actual simulator run.
    path=ROOT/'logs/r2_credit_write_axi_runs/c33_write_axi_contention_20260914_c/result.log'
    old={}
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('C33_WRITE_AXI_PASS '):
            r={k:int(v) for k,v in (t.split('=') for t in line.split()[1:])}
            if r['candidate']==2:old[tuple(r[k] for k in KEYS[:3]+KEYS[4:7])]=r
    rows={}
    for key in expected_keys():
        m,c,w,v,aw,e,f,g=key;r=copy.deepcopy(old[m,c,w,aw,e,f]);r['candidate']=v
        r.update(input_gap=g,space_waits=2 if v==3 else 0,wraps=1 if v==3 else 0,
                 peak_used=1024 if v==3 else 0,simultaneous_reserve_read=1 if v==3 else 0)
        rows[key]=r
    lines=['C34_WRITE_AXI_PASS '+' '.join(f'{k}={v}' for k,v in rows[key].items()) for key in sorted(rows)]
    lines+=['C34_WRITE_AXI_COMPARE '+json.dumps(r) for r in comparisons_for(rows).values()]
    lines+=['C34_WRITE_AXI_NEGATIVE_PASS '+json.dumps(dict(control=c,actual_RTL_rejected=True,reason=r)) for c,r in REASONS.items()]
    lines+=['C34_WRITE_AXI_SUMMARY '+json.dumps(summary_for(rows)),
            'C34_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1']
    return lines


def selftest():
    lines=synthetic_fixture();analyze('\n'.join(lines))
    cases=[]
    cases.append(lines[1:]);cases.append(lines+[lines[0]]);cases.append(lines[:-1])
    cases.append(lines+[lines[-1]]);cases.append(lines+['FATAL: synthetic corruption'])
    def changed_row(field,value):
        result=lines.copy();i=next(i for i,l in enumerate(result) if l.startswith('C34_WRITE_AXI_PASS ') and 'candidate=3 ' in l)
        result[i]=re.sub(r'\b'+field+r'=-?\d+',field+'='+str(value),result[i]);return result
    for field,value in (('peak_used',1025),('wraps',-1),('input_gap',7),('nn_errors',5),
                        ('nn_words',1),('force_refill',7),('actual_AXI',0),('simultaneous_reserve_read',4)):
        cases.append(changed_row(field,value))
    changed=lines.copy();i=next(i for i,l in enumerate(changed) if l.startswith('C34_WRITE_AXI_COMPARE '))
    obj=json.loads(changed[i].split(' ',1)[1]);obj['producer_span'][1]+=1
    changed[i]='C34_WRITE_AXI_COMPARE '+json.dumps(obj);cases.append(changed)
    changed=lines.copy();obj=json.loads(changed[-2].split(' ',1)[1]);obj['physical_words']+=1
    changed[-2]='C34_WRITE_AXI_SUMMARY '+json.dumps(obj);cases.append(changed)
    cases.append([s for s in lines if '"control": "BREAK_DRAIN"' not in s])
    rejected=0
    for case in cases:
        try:analyze('\n'.join(case))
        except (AssertionError,KeyError,ValueError):rejected+=1
        else:raise AssertionError('synthetic bad evidence accepted')
    print('C34_RING_EVIDENCE_SELFTEST_PASS '+json.dumps(dict(synthetic_only=True,positive_matrices=1,
        rejected=rejected,RTL_executed=False,FPGA_resource_measured=False),separators=(',',':')))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run');parser.add_argument('--selftest',action='store_true')
    args=parser.parse_args()
    if args.selftest:selftest()
    if args.run:gate(args.run)
    if not (args.run or args.selftest):parser.error('select --run or --selftest')
