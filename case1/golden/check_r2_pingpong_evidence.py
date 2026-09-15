"""C8 graph evidence; native service-profile fps is not board/AXI signoff."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]


def read(path):return (ROOT/path).read_text(encoding='utf-8-sig')
def rec(text,kind):return [fields(s) for s in text.splitlines() if s.startswith('C1_R2_PINGPONG_'+kind+' ')]
def clean(text,count=1):
    if re.search(r'FATAL|RuntimeError|TimeoutExpired|Traceback',text):raise ValueError('failed simulation')
    if text.splitlines().count('C1_R2_PINGPONG_CLEAN temporary_vectors_and_simulator_removed=1')!=count:raise ValueError('missing cleanup')


def check_frame(f,memdiv=0,throttle=0):
    b=budget(f['width'],f['height'])
    if (f['cache'],f['overlap'],f['compute_overlap'],f['refill_priority'],f['write_throttle'],f['memdiv'],f['latency'])!=(1,1,1,1,throttle,memdiv,20 if memdiv else 0):raise ValueError('wrong frame configuration')
    if (f['commits'],f['read_beats'],f['write_beats'],f['producer_reads'])!=(22,b['read_beats'],b['write_beats'],b['feature_read_beats']):raise ValueError('wrong actual traffic')
    if f['cycles']<=b['compute_cycles']+b['feature_read_beats'] or not 0<=f['compute_write_beats']<=f['write_beats']:raise ValueError('impossible frame counts')
    if f['width']>=12 and f['compute_write_beats']==0:raise ValueError('no actual compute/write transfer overlap')


def check_faults(fs,stalls):
    fs=[f for f in fs if f['stalls']==stalls]
    if len(fs)!=12 or [f['fault'] for f in fs]!=list(range(1,13)):raise ValueError('missing faults')
    for f in fs:
        if f['drained']!=1 or f['commits']!=(20 if f['fault']==7 else 0):raise ValueError('unsafe error commit')
        if f['overlapped_error']!=int(f['fault'] in (9,10,12)) or f['compute_error']!=int(f['fault']==11) or f['two_pages_error']!=int(f['fault']>=11):raise ValueError('missing multi-page fault coverage')


def matrix(text):
    clean(text,2);metas=[json.loads(s.split(' ',1)[1]) for s in text.splitlines() if s.startswith('C1_R2_PINGPONG_VECTORS ')]
    fs=rec(text,'FRAME');ps=rec(text,'PASS');faults=rec(text,'FAULT')
    if len(metas)!=4 or {(m['width'],m['height']) for m in metas}!={(4,4),(12,12),(32,32),(640,12)}:raise ValueError('missing shapes')
    if len(fs)!=18 or len(ps)!=8 or len(faults)!=24:raise ValueError('missing matrix cases')
    scalars=words=0
    for m in metas:
        w,h=m['width'],m['height'];b=budget(w,h)
        if (m['parameter_words'],m['input_words'],m['expected_words'])!=(2333,w*h//2,b['write_beats']*2):raise ValueError('wrong vector plan')
        for mf in m['frames']:
            if len(mf['stages'])!=19 or {s['stage'] for s in mf['stages']}!=set(range(22))-{14,17,21}:raise ValueError('missing compute nodes')
            if sum(s['words'] for s in mf['stages'])!=b['write_beats'] or sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in mf['stages'])!=mf['scalars']:raise ValueError('vector coverage mismatch')
        for stalls in (0,1):
            frames=[f for f in fs if (f['width'],f['height'],f['stalls'])==(w,h,stalls)]
            passes=[p for p in ps if (p['width'],p['height'],p['stalls'])==(w,h,stalls)];n=3 if w==12 else 2
            if len(passes)!=1 or len(frames)!=n or [f['frame'] for f in frames]!=([0,1,1] if n==3 else [0,1]):raise ValueError('missing/duplicate frames')
            p=passes[0]
            if (p['normal_frames'],p['faults'],p['invalid_shapes'],p['expected_input_only'])!=(n,12 if n==3 else 0,10,1):raise ValueError('missing lifecycle coverage')
            if (p['compute_overlap'],p['refill_priority'],p['write_throttle'],p['memdiv'],p['latency'])!=(1,1,0,0,0):raise ValueError('pass profile mismatch')
            if p['max_pages']>2 or (w>=12 and (p['max_pages']!=2 or p['full_pages_cycles']<=0 or p['compute_write_cycles']<=0)):raise ValueError('missing page/overlap coverage')
            if stalls and p['blocked_writes']<=0 or not stalls and p['blocked_writes']!=0:raise ValueError('backpressure mismatch')
            if p['max_read_run']<2:raise ValueError('missing consecutive refill')
            if n==2 and (p['bulk_beats'],p['reads'],p['writes'])!=(2*b['feature_read_beats'],2*b['read_beats'],2*b['write_beats']):raise ValueError('total traffic mismatch')
            for f in frames:
                check_frame(f);scalars+=m['frames'][f['frame']]['scalars'];words+=f['write_beats']
            if not stalls and len({f['cycles'] for f in frames})!=1:raise ValueError('unstable continuous schedule')
    for stalls in (0,1):check_faults(faults,stalls)
    return dict(shapes=4,configs=8,normal_frames=18,error_frames=24,valid_scalars=scalars,normal_write_words=words)


def shared(text,throttle=0):
    clean(text);ss=(1,) if throttle else (0,1);frames=rec(text,'FRAME');passes=rec(text,'PASS');faults=rec(text,'FAULT')
    if len(frames)!=3*len(ss) or len(passes)!=len(ss) or len(faults)!=12*len(ss):raise ValueError('incomplete shared-service matrix')
    for stalls in ss:
        check_faults(faults,stalls)
        ps=[p for p in passes if p['stalls']==stalls]
        fs=[f for f in frames if f['stalls']==stalls]
        if len(ps)!=1 or [f['frame'] for f in fs]!=[0,1,1]:raise ValueError('missing shared restart')
        p=ps[0]
        if p['max_pages']!=2 or p['full_pages_cycles']<=0 or p['expected_input_only']!=1 or p['normal_frames']!=3 or p['faults']!=12:raise ValueError('missing shared page coverage')
        if throttle and p['paused_held_cycles']<=0:raise ValueError('no held transfer at priority change')
        for f in fs:check_frame(f,2,throttle)
    return dict(normal_frames=len(frames),errors=len(faults),write_throttle=throttle,paused_held_cycles=sum(p['paused_held_cycles'] for p in passes))


def native(run):
    folder=Path('logs/r2_pingpong_xsim_runs')/run;s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'metadata.json'));t=read(folder/'result.log')
    if s['state']!='complete' or s['exit_code']!=0 or s['worker_in_windows_job'] is not False or s['simulator_directory_present'] or Path(s['run_directory']).exists():raise ValueError('incomplete/non-detached/unclean native run')
    if (s['width'],s['height'],s['memory_div'],s['command_latency'])!=(640,480,2,20):raise ValueError('native profile changed')
    fs=rec(t,'FRAME');ps=rec(t,'PASS');stages=rec(t,'STAGE_COMMIT')
    if len(fs)!=1 or len(ps)!=1 or [r['stage'] for r in stages]!=list(range(22)):raise ValueError('incomplete native graph')
    f,p=fs[0],ps[0];check_frame(f,2)
    if (f['width'],f['height'],f['stalls'],f['frame'])!=(640,480,0,0):raise ValueError('wrong native frame')
    if (p['normal_frames'],p['faults'],p['invalid_shapes'],p['expected_input_only'],p['max_pages'])!=(1,0,10,1,2):raise ValueError('native lifecycle mismatch')
    b=budget()
    if (p['reads'],p['writes'],p['bulk_beats'])!=(b['read_beats'],b['write_beats'],b['feature_read_beats']):raise ValueError('native traffic mismatch')
    if stages[-1]['cycles']!=f['cycles'] or stages[-1]['words']!=b['write_beats']:raise ValueError('native commit mismatch')
    if (m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])!=(2333,153600,2860800,21043200):raise ValueError('native vector coverage mismatch')
    return dict(run=run,cycles=f['cycles'],fps_at_150mhz=150000000/f['cycles'],meets_15fps_under_profile=f['cycles']<=10000000,
                valid_scalars=21043200,external_bytes=b['external_bytes'],compute_write_beats=f['compute_write_beats'],
                scope='one actual RTL 640x480 frame, shared 1.2GB/s row-memory service plus 20-cycle logical command latency, NOT AXI/DDR/board fps')


def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');a=p.parse_args()
    text=read('logs/r2_pingpong_probe_20260913_b.log')+'\n'+read('logs/r2_pingpong_probe_20260913_c.log')
    print('C1_R2_PINGPONG_SIM_GATE_PASS '+json.dumps(matrix(text)))
    first=rec(text,'FRAME')[0];nonzero=next(f['compute_write_beats'] for f in rec(text,'FRAME') if f['width']==32)
    mutations=[('commits=22','commits=21'),('invalid_shapes=10','invalid_shapes=9'),('drained=1','drained=0'),('compute_error=1','compute_error=0'),
               ('two_pages_error=1','two_pages_error=0'),('expected_input_only=1','expected_input_only=0'),('max_pages=2','max_pages=3'),
               ('compute_write_beats='+str(nonzero),'compute_write_beats=0'),('cycles='+str(first['cycles']),'cycles=1'),
               ('C1_R2_PINGPONG_CLEAN temporary_vectors_and_simulator_removed=1','')]
    for old,new in mutations:
        if old not in text:raise ValueError('missing mutation anchor')
        try:matrix(text.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('accepted bad evidence '+old)
    print('C1_R2_PINGPONG_NEGATIVE_GATE_PASS rejected='+str(len(mutations)))
    for path,throttle in (('logs/r2_pingpong_shared_small_20260913_c.log',0),('logs/r2_pingpong_throttle_20260913_c.log',1)):
        print('C1_R2_PINGPONG_SHARED_GATE_PASS '+json.dumps(shared(read(path),throttle)))
    t=read('logs/r2_pingpong_reset_20260913_a.log');clean(t);resets=rec(t,'RESET_PASS');frames=rec(t,'FRAME')
    if resets!=[dict(phase=i,restart_golden=1,cleared_pages=1) for i in range(6)] or len(frames)!=6 or rec(t,'RESET_SUITE_PASS')!=[dict(phases=6,normal_restarts=6,system_reset_only=1)]:raise ValueError('missing system reset coverage')
    for f in frames:check_frame(f,2,1)
    print('C1_R2_PINGPONG_RESET_GATE_PASS phases=6 full_golden_restarts=6 system_reset_only=1')
    t=read('logs/r2_pingpong_handoff_negative_20260913.log');clean(t)
    if rec(t,'HANDOFF_NEGATIVE_PASS')!=[dict(corruption=i,detected_at_stage=1) for i in (1,2)]:raise ValueError('missing real RAM poison tests')
    print('C1_R2_PINGPONG_HANDOFF_GATE_PASS real_memory_corruptions_detected=2')
    ablations={}
    for compute,priority,cycles,beats in ((0,0,56848,0),(1,0,52900,851),(1,1,50562,4420)):
        t=read(f'logs/r2_pingpong_ablation_c{compute}_p{priority}_20260913.log');clean(t);fs=rec(t,'FRAME');ps=rec(t,'PASS')
        if len(fs)!=2 or len(ps)!=1:raise ValueError('missing ablation')
        for f in fs:
            if (f['compute_overlap'],f['refill_priority'],f['memdiv'],f['latency'],f['cycles'],f['read_beats'],f['write_beats'],f['compute_write_beats'])!=(compute,priority,2,20,cycles,7389,4768,beats):raise ValueError('ablation mismatch')
        if ps[0]['max_pages']!=(2 if compute else 1):raise ValueError('ablation page mismatch')
        ablations[f'compute{compute}_priority{priority}']=cycles
    print('C1_R2_PINGPONG_ABLATION_GATE_PASS '+json.dumps(ablations))
    from export_r2_graph_parameters import build
    image,info=build(ROOT/'model/microstyle24_starry_functional');artifact=ROOT/'model/r2_microstyle24_starry_functional'
    if (artifact/'parameters.bin').read_bytes()!=image or json.loads((artifact/'manifest.json').read_text())!=info:raise ValueError('parameters not current')
    print('C1_R2_PINGPONG_PARAMETER_GATE_PASS image_bytes=180224 active_bytes=37328 commands=4666')
    smoke=Path('logs/r2_pingpong_xsim_runs/c8_xsim_smoke_20260913_b')
    ss=json.loads(read(smoke/'status.json'));smoke_text=read(smoke/'result.log');sf=rec(smoke_text,'FRAME');sp=rec(smoke_text,'PASS')
    if ss['state']!='complete' or ss['exit_code']!=0 or ss['worker_in_windows_job'] is not False or ss['simulator_directory_present'] or Path(ss['run_directory']).exists():raise ValueError('latest xsim smoke incomplete')
    if len(sf)!=1 or len(sp)!=1 or (sf[0]['width'],sf[0]['height'],sf[0]['cycles'])!=(12,12,17232):raise ValueError('cross-simulator mismatch')
    check_frame(sf[0],2)
    print('C1_R2_PINGPONG_XSIM_COMPAT_GATE_PASS latest_testbench_12x12_cycles=17232 matches_icarus=1')
    run='c1_ti60_r2_pingpong96_i3_20260913_b';folder=Path('logs/efinity_resource_runs')/run
    s=json.loads(read(folder/'summary.json'));st=json.loads(read(folder/'status.json'));r=s['pnr_resources'];t=s['timing']
    if st['state']!='complete' or st['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0:raise ValueError('incomplete physical run')
    if (r['xlr_cells_used'],r['memory_blocks_used'],r['dsp_blocks_used'])!=(38819,160,112):raise ValueError('wrong resource snapshot')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or t['final_period_ns']>6.666:raise ValueError('150MHz not closed')
    for name,ram,dsp in (('u_operator:c1_r2_cnn_bulk_engine',128,108),('u_writer:c1_r2_tensor_pingpong_writer',32,0)):
        row=next((row for row in s['metrics']['module_rows'] if name in row),None)
        if row is None or [int(v) for v in re.findall(r'(\d+)\(',row)][-2:]!=[ram,dsp]:raise ValueError('wrong shared resource ownership')
    print('C1_R2_PINGPONG_PHYSICAL_GATE_PASS '+json.dumps(dict(run=run,xlr=38819,ram=160,dsp=112,setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],scope='core only')))
    if a.native_run:print('C1_R2_PINGPONG_NATIVE_CORE_GATE_PASS '+json.dumps(native(a.native_run)))
    else:print('C1_R2_PINGPONG_NATIVE_CORE_GATE_NOT_REQUESTED')


if __name__=='__main__':main()
