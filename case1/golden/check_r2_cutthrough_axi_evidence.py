"""Audit real C32 competing-writer results; correctness is not a speedup gate."""
import argparse
import json
from pathlib import Path
import re

import run_r2_cutthrough_write_contention as probe
import check_r2_cutthrough_writer_evidence as unit

ROOT=probe.ROOT


def need(condition,message):
    if not condition:raise AssertionError(message)


def read(path):return path.read_text(encoding='utf-8-sig')


def gate(name):
    need(re.fullmatch(r'[A-Za-z0-9_-]+',name) is not None,'unsafe RunId')
    folder=ROOT/'logs/r2_cutthrough_write_axi_runs'/name
    status=json.loads(read(folder/'status.json'))
    need(status['run_id']==name and status['state']=='complete' and status['exit_code']==0,'AXI run not complete')
    need(status['worker_in_windows_job'] is False and status['worker_start'],'worker identity/Job isolation missing')
    private=(ROOT/'sim'/f'c1_r2_cutthrough_write_axi_{name}').resolve()
    need(Path(status['run_directory']).resolve()==private and not private.exists() and status['simulator_directory_present'] is False,'AXI private cleanup incomplete')
    need(not (folder/'interruption.json').exists(),'interrupted AXI run')
    budget=status['workload_budget']
    need(budget['policy']=='single-heavy-worker' and 1<=budget['logical_processors']<=2 and budget['priority']=='BelowNormal','missing low-load policy')
    need(status['actual_AXI'] is True and status['actual_camera'] is False and status['whole_CNN_fps_claim'] is False,'AXI diagnostic scope changed')
    for stderr_name in ('writer_gate.stderr.log','result.stderr.log'):
        need(not read(folder/stderr_name).strip(),'unexpected probe stderr')
    writer_gate=read(folder/'writer_gate.log')
    records=[json.loads(line.split(' ',1)[1]) for line in writer_gate.splitlines() if line.startswith('C32_WRITER_UNIT_GATE_PASS ')]
    need(len(records)==1 and records[0]['run']==status['predecessor_writer_run'],'missing actual predecessor gate')
    unit.gate(status['predecessor_writer_run'])
    text=read(folder/'result.log')
    need(not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text),'AXI failure in results')
    need(text.splitlines().count('C32_WRITE_AXI_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing clean marker')
    expected={(m,c,w,candidate,aw,error) for m,c,w in probe.SHAPES
              for candidate in (0,1) for aw in (0,2) for error in (0,1)}
    rows={};comparisons={}
    for line in text.splitlines():
        if line.startswith('C32_WRITE_AXI_PASS '):
            fields=dict(token.split('=') for token in line.split()[1:])
            key=tuple(int(fields[k]) for k in ('mode','channels','width','candidate','aw_wait_w','inject_b'))
            need(key in expected and key not in rows,'unexpected/duplicate AXI configuration')
            m,c,w,candidate,aw,error=key
            physical_words=w//4 if m==1 else ((w+1)//2)*((c+7)//8)
            rows[key]=probe.parse_result(line,m,c,w,candidate,aw,error,physical_words)
        elif line.startswith('C32_WRITE_AXI_COMPARE '):
            record=json.loads(line.split(' ',1)[1]);key=record['mode'],record['aw_wait_w'],record['inject_b']
            need(key not in comparisons,'duplicate paired comparison');comparisons[key]=record
    need(set(rows)==expected and len(comparisons)==12,'incomplete real AXI matrix')
    table=[]
    for m,c,w in probe.SHAPES:
        for aw in (0,2):
            for error in (0,1):
                before=rows[m,c,w,0,aw,error];after=rows[m,c,w,1,aw,error]
                expected_comparison=dict(mode=m,aw_wait_w=aw,inject_b=error,
                    capture_wait_delta=after['capture_command_wait_max']-before['capture_command_wait_max'],
                    empty_head_delta=after['blocked_empty_head']-before['blocked_empty_head'],
                    producer_row_span_delta=after['nn_span_cycles']-before['nn_span_cycles'],full_host_fps_claim=False)
                need(comparisons[m,aw,error]==expected_comparison,'paired deltas do not match actual events')
                if not error:
                    table.append(dict(mode=m,aw_wait_w=aw,
                        capture_command_wait_old=before['capture_command_wait_max'],
                        capture_command_wait_candidate=after['capture_command_wait_max'],
                        empty_head_old=before['blocked_empty_head'],empty_head_candidate=after['blocked_empty_head'],
                        max_w_occupancy_old=before['max_nn_w_occupancy'],max_w_occupancy_candidate=after['max_nn_w_occupancy'],
                        producer_row_span_delta=expected_comparison['producer_row_span_delta']))
    need(any(row['capture_command_wait_candidate']>row['capture_command_wait_old'] and row['empty_head_candidate']>row['empty_head_old'] for row in table),
         'claimed head-of-line risk not demonstrated by actual paired observations')
    for row in table:print('C32_AXI_CONTENTION_OBSERVATION '+json.dumps(row,separators=(',',':')))
    result=dict(run=status['run_id'],seconds=status['elapsed_seconds'],configurations=24,paired_comparisons=12,
        physical_words_checked=sum(r['nn_words']+r['capture_words'] for r in rows.values()),
        physical_bursts_checked=sum(r['aw'] for r in rows.values()),
        CNN_error_rows_checked=sum(r['nn_errors'] for r in rows.values()),
        capture_error_rows=sum(r['capture_errors'] for r in rows.values()),
        actual_AXI=True,actual_camera=False,whole_CNN_fps_claim=False,
        candidate_promoted_to_host=False,shared_write_head_of_line_observed=True)
    print('C32_WRITE_AXI_EVIDENCE_PASS '+json.dumps(result,separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);gate(p.parse_args().run)
