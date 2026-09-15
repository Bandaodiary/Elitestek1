"""Independent C35 small full-DAG evidence gate, not AXI/PNR/native FPS."""
import argparse
import copy
import json
from pathlib import Path
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from r2_plan_package import profile_nodes
from r2_execution_plan import OP_UPSAMPLE2,OP_OUTPUT_RGB

PREFIX='C35_ROW_FUSED_GRAPH_'
KEYS={('microstyle24',4,4,0,True),('microstyle24',12,12,0,True),
      ('microstyle24',12,12,1,True),('drop_res1',12,12,1,True),('microstyle24',12,12,1,False)}


def records(text,name):return [json.loads(x[len(PREFIX+name+' '):]) for x in text.splitlines() if x.startswith(PREFIX+name+' ')]


def check_text(text):
    if re.search('FATAL|ERROR:|Traceback|RuntimeError',text):raise ValueError('failed evidence text')
    cases=records(text,'CASE')
    if len(cases)!=5 or {(c['profile'],c['width'],c['height'],c['stalls'],c['fused']) for c in cases}!=KEYS:raise ValueError('wrong case matrix')
    for c in cases:
        w,h,enabled=c['width'],c['height'],c['fused']
        nodes=profile_nodes(c['profile'],w,h)
        # Count logical output tensors directly, not from the new allocator,
        # generated transfer table or its fixture metadata.
        words=sum(((n.spec.output_width+1)//2)*((n.spec.output_channels+7)//8)*n.spec.output_height
            for n in nodes if n.spec.opcode not in (OP_UPSAMPLE2,OP_OUTPUT_RGB))
        removed=w*h if enabled else 0
        if c.get('removed_DDR_write_words_per_frame')!=removed or c.get('extra_parameter_beats_per_frame')!=(72*(h-1) if enabled else 0):raise ValueError('wrong traffic derivation')
        if any(c.get(k) is not False for k in ('actual_AXI','native_fps_claim','physical_RAM_measured')):raise ValueError('scope escalation')
        if len(c['frames'])!=2 or len(c['shadow'])!=2:raise ValueError('wrong frame count')
        for fid,(f,s) in enumerate(zip(c['frames'],c['shadow'])):
            expected=dict(frame=fid,width=w,height=h,stalls=c['stalls'],commits=len(nodes),
                write_beats=words-removed,memdiv=2,latency=20,cache=1,overlap=1,compute_overlap=1,refill_priority=1,write_throttle=0)
            if any(f.get(k)!=v for k,v in expected.items()) or f.get('cycles',0)<1:raise ValueError('wrong frame execution coverage')
            sexpected=dict(frame=fid,enabled=int(enabled),packets=3*w*h if enabled else 0,
                DW_rows=h if enabled else 0,PW_rows=h if enabled else 0,checker_only=1)
            if s!=sexpected:raise ValueError('missing real internal arithmetic')
    fused=next(c for c in cases if (c['profile'],c['width'],c['stalls'],c['fused'])==('microstyle24',12,1,True))
    plain=next(c for c in cases if not c['fused'])
    for f,b in zip(fused['frames'],plain['frames']):
        if b['write_beats']-f['write_beats']!=144 or b['producer_reads']-f['producer_reads']!=144 or f['read_beats']-b['read_beats']!=648:raise ValueError('actual paired traffic does not eliminate DW spill')
    pair=records(text,'PAIRED')
    if pair!=[dict(fused_cycles=[f['cycles'] for f in fused['frames']],unfused_cycles=[f['cycles'] for f in plain['frames']],actual_AXI=False,native_fps_claim=False)]:raise ValueError('wrong paired cycles')
    for suffix in ('NEGATIVE_PASS actual_shadow_RAM_corruption=1',
        'SUMMARY configurations=5 correct_frames=10 actual_negative_controls=1 full_DAG=1 actual_AXI=0 native_fps_claim=0',
        'CLEAN temporary_vectors_and_simulator_removed=1'):
        if text.splitlines().count(PREFIX+suffix)!=1:raise ValueError('missing/duplicate '+suffix)
    return dict(configurations=5,correct_frames=10,actual_shadow_corruption_controls=1,
        original_22_and_variant_18=True,paired_removed_DDR_read_words=144,paired_removed_DDR_write_words=144,
        fused_cycles=pair[0]['fused_cycles'],unfused_cycles=pair[0]['unfused_cycles'],
        full_DAG_small_shapes=True,actual_AXI=False,native_fps_claim=False,physical_RAM_measured=False)


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid run')
    folder=ROOT/'logs/r2_row_fused_graph_runs'/run
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    private=(ROOT/'sim'/f'c1_r2_row_fused_graph_{run}').resolve()
    if (status.get('run_id')!=run or status.get('state')!='complete' or status.get('exit_code')!=0 or
        status.get('worker_in_windows_job') is not False or status.get('simulator_directory_present') is not False or
        Path(status['run_directory']).resolve()!=private or private.exists()):raise ValueError('not complete/clean/isolated')
    budget=status.get('workload_budget') or {}
    if budget.get('logical_processors') not in (1,2) or budget.get('priority')!='BelowNormal':raise ValueError('wrong workload budget')
    if (folder/'result.log').stat().st_size>131072 or (folder/'result.stderr.log').read_text(encoding='utf-8-sig').strip():raise ValueError('oversized/failed log')
    text=(folder/'result.log').read_text(encoding='utf-8-sig');result=check_text(text)
    # Evidence-negative controls; NOT additional RTL tests. Base input must
    # already pass; every deliberately damaged copy must fail closed.
    cases=records(text,'CASE');line=next(x for x in text.splitlines() if x.startswith(PREFIX+'CASE '))
    mutations=[]
    for key,value in [('actual_AXI',True),('removed_DDR_write_words_per_frame',0)]:
        c=copy.deepcopy(cases[0]);c[key]=value
        mutations.append(text.replace(line,PREFIX+'CASE '+json.dumps(c),1))
    c=copy.deepcopy(cases[0]);c['shadow'][0]['packets']-=1
    mutations.append(text.replace(line,PREFIX+'CASE '+json.dumps(c),1))
    c=copy.deepcopy(cases[0]);c['frames'][0]['write_beats']+=1
    mutations.append(text.replace(line,PREFIX+'CASE '+json.dumps(c),1))
    mutations += [text.replace(line,'',1),text+'\n'+line,text+'\nFATAL deliberate damage',
        text.replace('NEGATIVE_PASS actual_shadow_RAM_corruption=1','NEGATIVE_PASS actual_shadow_RAM_corruption=0')]
    for bad in mutations:
        try:check_text(bad)
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('damaged evidence accepted')
    print(PREFIX+'EVIDENCE_PASS '+json.dumps(dict(run=run,**result,evidence_corruption_rejections=len(mutations),
        temporary_removed=True,seconds=status['elapsed_seconds'],process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
