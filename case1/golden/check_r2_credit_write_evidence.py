"""Reconstruct the C33 matrix/comparisons from retained actual simulator events."""
import argparse
import json
from pathlib import Path
import re

import run_r2_credit_write_contention as probe


def gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name),'invalid run identifier'
    root=probe.ROOT;folder=root/'logs/r2_credit_write_axi_runs'/name
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    assert status['run_id']==name and status['state']=='complete' and status['exit_code']==0
    assert status['worker_in_windows_job'] is False and status['worker_start']
    private=(root/'sim'/f'c1_r2_credit_write_axi_{name}').resolve()
    assert Path(status['run_directory']).resolve()==private and not private.exists()
    assert status['simulator_directory_present'] is False
    budget=status['workload_budget']
    assert budget['policy']=='single-heavy-worker' and 1<=budget['logical_processors']<=2
    assert budget['priority']=='BelowNormal'
    assert status['actual_AXI'] is True and status['actual_camera'] is False and status['whole_CNN_fps_claim'] is False
    for filename in ('writer_gate.stderr.log','result.stderr.log'):
        assert not (folder/filename).read_text(encoding='utf-8-sig').strip()
    text=(folder/'result.log').read_text(encoding='utf-8-sig')
    assert not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text)
    assert text.splitlines().count('C33_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1')==1
    expected={(m,c,w,v,aw,e,0) for m,c,w in probe.SHAPES for v in (0,1,2) for aw in (0,2) for e in (0,1)}
    expected|={(m,c,w,2,aw,0,1) for m,c,w in probe.REFILL_SHAPES for aw in (0,2)}
    expected|={(m,c,w,2,aw,0,0) for m,c,w in probe.BOUNDARIES for aw in (0,2)}
    rows={};comparisons={};negatives={};summaries=[]
    for line in text.splitlines():
        if line.startswith('C33_WRITE_AXI_PASS '):
            fields=dict(token.split('=') for token in line.split()[1:])
            key=tuple(int(fields[n]) for n in ('mode','channels','width','candidate','aw_wait_w','inject_b','force_refill'))
            assert key in expected and key not in rows,'unexpected/duplicate configuration'
            m,c,w,v,aw,e,f=key
            physical=(w+3)//4 if m==1 else ((w+1)//2)*((c+7)//8)
            params=dict(MODE=m,CHANNELS=c,WIDTH=w,CANDIDATE=v,AW_WAIT_W=aw,INJECT_B=e,FORCE_REFILL=f,PHYSICAL_WORDS=physical)
            rows[key]=probe.parse_result(line,params)
        elif line.startswith('C33_WRITE_AXI_COMPARE '):
            r=json.loads(line.split(' ',1)[1]);key=r['mode'],r['aw_wait_w'],r['inject_b']
            assert key not in comparisons;comparisons[key]=r
        elif line.startswith('C33_WRITE_AXI_NEGATIVE_PASS '):
            r=json.loads(line.split(' ',1)[1]);assert r['control'] not in negatives
            negatives[r['control']]=r
        elif line.startswith('C33_WRITE_AXI_SUMMARY '):summaries.append(json.loads(line.split(' ',1)[1]))
    assert set(rows)==expected and len(rows)==58 and len(comparisons)==12
    reasons={'BREAK_CREDIT':'C33 grant exceeds published logical words',
             'BREAK_DRAIN':'C33 authorized burst failed to drain during refill'}
    assert set(negatives)==set(reasons)
    for name_,reason in reasons.items():
        assert negatives[name_]==dict(control=name_,actual_RTL_rejected=True,reason=reason)
    for m,c,w in probe.SHAPES:
        for aw in (0,2):
            for error in (0,1):
                triplet=[rows[m,c,w,v,aw,error,0] for v in (0,1,2)]
                wanted=dict(mode=m,aw_wait_w=aw,inject_b=error,
                    capture_wait=[r['capture_command_wait_max'] for r in triplet],
                    empty_head=[r['blocked_empty_head'] for r in triplet],
                    w_occupancy=[r['max_nn_w_occupancy'] for r in triplet],
                    producer_span=[r['nn_span_cycles'] for r in triplet],full_host_fps_claim=False)
                assert comparisons[m,aw,error]==wanted,'comparison differs from events'
    assert len(summaries)==1
    summary=dict(configurations=58,comparisons=12,forced_refill_configurations=6,
        boundary_configurations=16,actual_negative_controls=2,
        physical_words=sum(r['nn_words']+r['capture_words'] for r in rows.values()),
        physical_bursts=sum(r['aw'] for r in rows.values()),
        c33_less_empty_head_than_c32=all(r['empty_head'][2]<r['empty_head'][1] for r in comparisons.values()),
        c33_capture_no_worse_than_c31=all(r['capture_wait'][2]<=r['capture_wait'][0] for r in comparisons.values()),
        full_host_fps_claim=False)
    assert summaries[0]==summary
    for key in sorted(comparisons):
        if key[2]==0:print('C33_CREDIT_OBSERVATION '+json.dumps(comparisons[key],separators=(',',':')))
    print('C33_CREDIT_EVIDENCE_PASS '+json.dumps(dict(run=name,seconds=status['elapsed_seconds'],**summary),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);gate(p.parse_args().run)
