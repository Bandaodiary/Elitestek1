"""C9 bounded text evidence audit, not a substitute for simulations/board tests."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]


def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def rec(t,kind):return [fields(s) for s in t.splitlines() if s.startswith('C1_R2_AXI_'+kind+' ')]
def require(ok,message):
    if not ok:raise ValueError(message)
def clean(t):
    require(not re.search(r'FATAL|RuntimeError|TimeoutExpired|Traceback',t),'failed run')
    require(t.splitlines().count('C1_R2_AXI_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing cleanup')


def unit(t,mode):
    clean(t);ps=rec(t,'DMA_PASS');rows=rec(t,'DMA_ROW')
    keys={(b,s,k) for b,s in ((16,1),(16,3),(16,4),(1,4),(256,4)) for k in (0,1)}
    require(len(ps)==10 and {(p['burst'],p['slots'],p['stalls']) for p in ps}==keys,'missing DMA configurations')
    for p in ps:
        rs=[r for r in rows if (r['burst'],r['slots'],r['stalls'])==(p['burst'],p['slots'],p['stalls'])]
        n=26 if p['burst']==1 else 28
        require(p['aw_wait_w']==mode and p['rows']==n and len(rs)==n,'incorrect DMA row count/mode')
        require({r['fault'] for r in rs}==set(range(9))-({2} if p['burst']==1 else set()),'missing fault type')
        require(sum(r['invalid'] for r in rs)==3 and any(r['words']==640 and r['bursts']>1 for r in rs),'missing boundary cases')
    return dict(configs=10,rows=len(rows),aw_wait_w=mode)


def frame(f):
    b=budget(f['width'],f['height'])
    require((f['burst'],f['slots'],f['memdiv'],f['latency'])==(16,4,2,20),'wrong frame profile')
    require((f['read_beats'],f['write_beats'],f['producer_reads'],f['commits'])==(b['read_beats'],b['write_beats'],b['feature_read_beats'],22),'wrong tensor traffic/commits')
    require(f['aw']==f['b'] and 0<f['aw']<=f['write_beats'] and 0<f['ar']<=f['read_beats'],'wrong burst accounting')
    require(f['cycles']>b['compute_cycles']+b['feature_read_beats'] and 0<f['compute_write_beats']<=f['write_beats'],'impossible cycles/overlap')
    require(f['final_b_hold']==37,'missing final B publication barrier')


def graph(t,shapes):
    clean(t);ps=rec(t,'PASS');fs=rec(t,'FRAME');errors=rec(t,'FAULT')
    require(len(ps)==len(shapes)*2,'missing graph profiles')
    metas=[json.loads(s.split(' ',1)[1]) for s in t.splitlines() if s.startswith('C1_R2_AXI_VECTORS ')]
    require(len(metas)==len(shapes) and {(m['width'],m['height']) for m in metas}==set(shapes),'wrong golden coverage')
    scalars=words=0
    for w,h in shapes:
        m=next(m for m in metas if (m['width'],m['height'])==(w,h));b=budget(w,h)
        require((m['parameter_words'],m['input_words'],m['expected_words'])==(2333,w*h//2,2*b['write_beats']),'wrong vector metadata')
        for mf in m['frames']:
            require({s['stage'] for s in mf['stages']}==set(range(22))-{14,17,21} and len(mf['stages'])==19,'missing tensor stages')
            require(sum(s['words'] for s in mf['stages'])==b['write_beats'] and sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in mf['stages'])==mf['scalars'],'bad scalar/word coverage')
        for stalls in (0,1):
            sel=lambda r:(r['width'],r['height'],r['stalls'])==(w,h,stalls)
            pp=[p for p in ps if sel(p)];ff=[f for f in fs if sel(f)];n=11 if (w,h)==(12,12) else 2
            require(len(pp)==1 and len(ff)==n and [f['frame'] for f in ff]==[0]+[1]*(n-1),'missing normal/recovery frame')
            p=pp[0]
            require((p['normal_frames'],p['faults'],p['expected_input_only'],p['max_pages'])==(n,9 if n==11 else 0,1,2),'wrong lifecycle/page coverage')
            require(p['peak_read']==4 and p['peak_write']==(4 if w==640 else 2 if w==32 else 1),'missing actual outstanding coverage')
            require(p['blocked_writes']>0,'missing shared-bus backpressure')
            for f in ff:frame(f);words+=f['write_beats'];scalars+=m['frames'][f['frame']]['scalars']
    require(len(fs)==sum(22 if s==(12,12) else 4 for s in shapes),'extra frames')
    require(len(errors)==(18 if (12,12) in shapes else 0),'missing fault suite')
    for stalls in (0,1):
        ee=[e for e in errors if e['stalls']==stalls]
        require([e['fault'] for e in ee]==(list(range(1,10)) if (12,12) in shapes else []),'missing/duplicate fault')
        for e in ee:
            require(e['drained']==1 and e['protocol_lock']==int(e['fault']>=6) and e['commits']==(20 if e['fault'] in (3,5) else 0),'unsafe fault completion')
            require(e['fault']!=9 or e['rejected_pages']>0,'queued page deadlock not covered')
    return dict(configs=len(ps),normal_frames=len(fs),error_frames=len(errors),valid_scalars=scalars,write_words=words)


def native(run):
    folder=Path('logs/r2_axi_xsim_runs')/run;s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'metadata.json'));t=read(folder/'result.log')
    require(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'native incomplete/non-detached/unclean')
    require((s['width'],s['height'],s['memory_div'],s['command_latency'])==(640,480,2,20),'wrong native profile')
    fs=rec(t,'FRAME');ps=rec(t,'PASS');stages=rec(t,'STAGE_COMMIT')
    require(len(fs)==1 and len(ps)==1 and [s['stage'] for s in stages]==list(range(22)),'incomplete native frame')
    f=fs[0];p=ps[0];frame(f)
    require((f['width'],f['height'],f['frame'],f['stalls'])==(640,480,0,0),'wrong native identity')
    require((p['normal_frames'],p['faults'],p['peak_read'],p['peak_write'],p['expected_input_only'])==(1,0,4,4,1),'native credits/coverage')
    require(stages[-1]['cycles']==f['cycles'] and stages[-1]['words']==f['write_beats'],'native commit mismatch')
    require((m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])==(2333,153600,2860800,21043200),'native vector mismatch')
    return dict(run=run,cycles=f['cycles'],fps_at_150mhz=150000000/f['cycles'],meets_15fps_under_profile=f['cycles']<=10000000,
                ar=f['ar'],aw=f['aw'],b=f['b'],read_beats=f['read_beats'],write_beats=f['write_beats'],valid_scalars=21043200,
                scope='actual AXI RTL graph, shared 1.2GB/s model and 20-cycle per-burst latency; NOT CPU/video/DDR PHY/board fps')


def physical(run):
    s=json.loads(read(Path('logs/efinity_resource_runs')/run/'status.json'));m=s['metrics'];r=m['pnr_resources'];t=m['timing']
    require(s['state']=='complete' and s['exit_code']==0,'unfinished Efinity')
    require(r['memory_blocks_used']==160 and r['dsp_blocks_used']==112 and r['xlr_cells_used']<=60800,'unexpected/pruned resources')
    require(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0,'timing not met')
    return dict(run=run,resources=r,timing=t,scope='core-only 6.666 ns, no constrained physical AXI ports or board integration')


def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');p.add_argument('--pnr-run');p.add_argument('--unit-only',action='store_true');a=p.parse_args()
    for name,mode in (('matrix',0),('awwait',1),('wbeforeaw',2)):
        print('C1_R2_AXI_UNIT_GATE_PASS '+json.dumps(unit(read(f'logs/r2_axi_dma_{name}_20260913_b.log'),mode)))
    if a.unit_only:return
    t=read('logs/r2_axi_graph_matrix_20260913_b.log');shapes=((4,4),(12,12),(32,32),(640,12))
    print('C1_R2_AXI_GRAPH_GATE_PASS '+json.dumps(graph(t,shapes)))
    print('C1_R2_AXI_WBEFOREAW_GATE_PASS '+json.dumps(graph(read('logs/r2_axi_graph_wbeforeaw_20260913_b.log'),((12,12),))))
    negatives=read('logs/r2_axi_handoff_negative_20260913_b.log');clean(negatives);ns=rec(negatives,'HANDOFF_NEGATIVE_PASS')
    require(len(ns)==4 and [n['corruption'] for n in ns]==[1,2,1,2] and all(n['detected_at_stage']==1 for n in ns),'missing real RAM handoff negative controls')
    print('C1_R2_AXI_HANDOFF_GATE_PASS cases=4')
    mutations=[('commits=22','commits=21'),('final_b_hold=37','final_b_hold=0'),('protocol_lock=1','protocol_lock=0'),
               ('rejected_pages=1','rejected_pages=0'),('expected_input_only=1','expected_input_only=0'),('peak_write=4','peak_write=1'),
               ('C1_R2_AXI_CLEAN temporary_vectors_and_simulator_removed=1',''),('drained=1','drained=0')]
    for old,new in mutations:
        require(old in t,'mutation anchor missing')
        try:graph(t.replace(old,new,1),shapes)
        except ValueError:pass
        else:raise ValueError('checker accepted corrupted evidence: '+old)
    print(f'C1_R2_AXI_AUDIT_NEGATIVE_PASS mutations={len(mutations)}')
    if a.native_run:print('C1_R2_AXI_NATIVE_GATE_PASS '+json.dumps(native(a.native_run)))
    if a.pnr_run:print('C1_R2_AXI_PHYSICAL_GATE_PASS '+json.dumps(physical(a.pnr_run)))


if __name__=='__main__':main()
