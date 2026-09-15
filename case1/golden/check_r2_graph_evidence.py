"""Evidence audit for complete graph handoff, never a native 15fps gate."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from r2_graph_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]


def fields(line):
    return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}


def simulation(text,cleanup_count=2):
    if re.search(r'FATAL|RuntimeError|TimeoutExpired',text):raise ValueError('failed simulation')
    lines=text.splitlines();metas=[json.loads(s.split(' ',1)[1]) for s in lines if s.startswith('C1_R2_GRAPH_VECTORS ')]
    frames=[fields(s) for s in lines if s.startswith('C1_R2_GRAPH_FRAME ')]
    passes=[fields(s) for s in lines if s.startswith('C1_R2_GRAPH_PASS ')]
    faults=[fields(s) for s in lines if s.startswith('C1_R2_GRAPH_FAULT ')]
    shapes={(4,4),(12,12),(32,32),(640,12)}
    if len(metas)!=4 or {(m['width'],m['height']) for m in metas}!=shapes:raise ValueError('missing shapes')
    if len(passes)!=8 or len(frames)!=18 or len(faults)!=16:raise ValueError('incomplete graph matrix')
    scalars=words=0
    for m in metas:
        w,h=m['width'],m['height'];b=budget(w,h)
        if m['parameter_words']!=b['parameter_beats'] or m['input_words']!=w*h//2 or m['expected_words']!=b['write_beats']*2:raise ValueError('wrong transfer plan')
        for f in m['frames']:
            if len(f['stages'])!=19 or {s['stage'] for s in f['stages']}!=set(range(22))-{14,17,21}:raise ValueError('missing compute stages')
            if sum(s['words'] for s in f['stages'])!=b['write_beats'] or f['output_words']!=b['write_beats']:raise ValueError('wrong frame output plan')
            if sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in f['stages'])!=f['scalars']:raise ValueError('wrong scalar coverage')
        for stalls in (0,1):
            ps=[p for p in passes if (p['width'],p['height'],p['stalls'])==(w,h,stalls)]
            fs=[f for f in frames if (f['width'],f['height'],f['stalls'])==(w,h,stalls)]
            n=3 if w==12 else 2
            if len(ps)!=1 or len(fs)!=n or [f['frame'] for f in fs]!=([0,1,1] if n==3 else [0,1]):raise ValueError('missing/duplicate frames')
            p=ps[0]
            if p['normal_frames']!=n or p['faults']!=(8 if w==12 else 0) or p['invalid_shapes']!=10 or p['expected_input_only']!=1:raise ValueError('missing lifecycle coverage')
            if stalls and p['blocked_writes']<=0:raise ValueError('no output backpressure')
            if not stalls and p['blocked_writes']!=0:raise ValueError('unexpected continuous stalls')
            for f in fs:
                if f['commits']!=22 or f['read_beats']!=b['read_beats'] or f['write_beats']!=b['write_beats'] or f['producer_reads']!=b['feature_read_beats']:raise ValueError('wrong actual graph traffic')
                if f['cycles']<=b['nonoverlap_lower_bound_cycles']:raise ValueError('impossible graph cycles')
                scalars+=m['frames'][f['frame']]['scalars'];words+=f['write_beats']
            if not stalls and len({f['cycles'] for f in fs})!=1:raise ValueError('nondeterministic unstalled schedule')
    for stalls in (0,1):
        fs=[f for f in faults if f['stalls']==stalls]
        if len(fs)!=8 or [f['fault'] for f in fs]!=list(range(1,9)) or any(f['drained']!=1 for f in fs):raise ValueError('missing error drain')
        if any(f['commits']!=(20 if f['fault']==7 else 0) for f in fs):raise ValueError('wrong error commit boundary')
    if sum(s=='C1_R2_GRAPH_CLEAN temporary_vectors_and_simulator_removed=1' for s in lines)!=cleanup_count:raise ValueError('missing cleanup')
    return dict(shapes=4,configs=8,normal_frames=18,error_frames=16,valid_scalars=scalars,normal_write_words=words,
                scope='full graph with actual RAM handoff at bounded dimensions, not native 640x480/DDR/CPU proof')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--simulation',nargs='+',default=['logs/r2_graph_probe_20260913_d.log','logs/r2_graph_probe_20260913_e.log']);args=parser.parse_args()
    text='\n'.join((ROOT/p).read_text(encoding='utf-8-sig') for p in args.simulation);result=simulation(text,len(args.simulation))
    print('C1_R2_GRAPH_SIM_GATE_PASS '+json.dumps(result))
    mutations=[('commits=22','commits=21'),('producer_reads=205','producer_reads=204'),('read_beats=2538','read_beats=2537'),
               ('invalid_shapes=10','invalid_shapes=9'),('drained=1','drained=0'),('expected_input_only=1','expected_input_only=0'),
               ('C1_R2_GRAPH_CLEAN temporary_vectors_and_simulator_removed=1',''),
               ('cycles='+str(fields(next(s for s in text.splitlines() if s.startswith('C1_R2_GRAPH_FRAME ')))['cycles']),'cycles=1')]
    for old,new in mutations:
        if old not in text:raise ValueError('negative marker absent '+old)
        try:simulation(text.replace(old,new,1),len(args.simulation))
        except ValueError:pass
        else:raise ValueError('accepted corrupted evidence '+old)
    print(f'C1_R2_GRAPH_NEGATIVE_GATE_PASS rejected={len(mutations)}')
    negative=(ROOT/'logs/r2_graph_handoff_negative_20260913_c.log').read_text(encoding='utf-8-sig')
    poison=[fields(s) for s in negative.splitlines() if s.startswith('C1_R2_GRAPH_HANDOFF_NEGATIVE_PASS ')]
    if poison!=[dict(stalls=1,corruption=i,detected_at_stage=1) for i in (1,2)]:raise ValueError('missing actual handoff poison tests')
    print('C1_R2_GRAPH_HANDOFF_GATE_PASS real_memory_corruptions_detected=2')
    from export_r2_graph_parameters import build
    image,info=build(ROOT/'model/microstyle24_starry_functional');artifact=ROOT/'model/r2_microstyle24_starry_functional'
    if (artifact/'parameters.bin').read_bytes()!=image or json.loads((artifact/'manifest.json').read_text())!=info:raise ValueError('exported upload image not current')
    print('C1_R2_GRAPH_PARAMETER_GATE_PASS image_bytes=180224 active_bytes=37328 commands=4666')
    b=budget();assert b['nonoverlap_lower_bound_cycles']==18802426 and not b['meets_15fps_even_under_ideal_transfers']
    print('C1_R2_GRAPH_BUDGET_GATE_PASS native_measured_fps=unknown current_32bit_serial_15fps=impossible floor_cycles=18802426')
    run='c1_ti60_r2_graph96_i3_20260913_c';folder=ROOT/'logs/efinity_resource_runs'/run
    s=json.loads((folder/'summary.json').read_text(encoding='utf-8-sig'));status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    r=s['pnr_resources'];t=s['timing'];m=s['metrics']
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0:raise ValueError('incomplete native physical run')
    if (r['xlr_cells_used'],r['memory_blocks_used'],r['dsp_blocks_used'])!=(37570,144,113):raise ValueError('wrong physical snapshot')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or t['final_period_ns']>6.666:raise ValueError('150MHz final timing NOT closed')
    rows=m['module_rows']
    for name,ram,dsp in (('u_operator:c1_r2_cnn_operator_engine',128,108),('u_writer:c1_r2_tensor_row_writer',16,0)):
        row=next((row for row in rows if name in row),None)
        if row is None or [int(v) for v in re.findall(r'(\d+)\(',row)][-2:]!=[ram,dsp]:raise ValueError('wrong shared resource ownership '+name)
    print('C1_R2_GRAPH_PHYSICAL_GATE_PASS '+json.dumps(dict(run=run,xlr=37570,ram=144,dsp=113,setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],scope='graph core with row memory ports, no CPU/DDR PHY/video')))


if __name__=='__main__':main()
