"""C7 evidence gate: exact traffic, lifecycle, ablations and native core timing.

The optional native run proves a cycle count under a declared memory SERVICE
PROFILE, not AXI/DDR PHY, camera/display integration or a measured board fps.
"""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def records(text,kind):
    return [fields(s) for s in text.splitlines() if s.startswith('C1_R2_STREAM_'+kind+' ')]


def simulation(text,cleanup_count=2):
    if re.search(r'FATAL|RuntimeError|TimeoutExpired|Traceback',text):raise ValueError('failed simulation')
    metas=[json.loads(s.split(' ',1)[1]) for s in text.splitlines() if s.startswith('C1_R2_STREAM_VECTORS ')]
    frames=records(text,'FRAME');passes=records(text,'PASS');faults=records(text,'FAULT')
    if len(metas)!=4 or {(m['width'],m['height']) for m in metas}!={(4,4),(12,12),(32,32),(640,12)}:raise ValueError('missing shapes')
    if len(passes)!=8 or len(frames)!=18 or len(faults)!=20:raise ValueError('incomplete matrix')
    scalars=words=0
    for m in metas:
        w,h=m['width'],m['height'];b=budget(w,h)
        if (m['cache'],m['overlap'],m['memdiv'],m['latency'])!=(1,1,0,0):raise ValueError('wrong test profile')
        if (m['parameter_words'],m['input_words'],m['expected_words'])!=(b['parameter_beats'],w*h//2,b['write_beats']*2):raise ValueError('wrong transfer plan')
        for f in m['frames']:
            if len(f['stages'])!=19 or {s['stage'] for s in f['stages']}!=set(range(22))-{14,17,21}:raise ValueError('missing stages')
            if sum(s['words'] for s in f['stages'])!=b['write_beats'] or f['output_words']!=b['write_beats']:raise ValueError('wrong output plan')
            if sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in f['stages'])!=f['scalars']:raise ValueError('wrong scalar coverage')
        for stalls in (0,1):
            fs=[f for f in frames if (f['width'],f['height'],f['stalls'])==(w,h,stalls)]
            ps=[p for p in passes if (p['width'],p['height'],p['stalls'])==(w,h,stalls)]
            n=3 if (w,h)==(12,12) else 2
            if len(ps)!=1 or len(fs)!=n or [f['frame'] for f in fs]!=([0,1,1] if n==3 else [0,1]):raise ValueError('missing/duplicate frames')
            p=ps[0]
            if (p['normal_frames'],p['faults'],p['invalid_shapes'],p['expected_input_only'])!=(n,10 if n==3 else 0,10,1):raise ValueError('missing lifecycle coverage')
            if (p['cache'],p['overlap'],p['memdiv'],p['latency'])!=(1,1,0,0):raise ValueError('pass profile mismatch')
            if (stalls and p['blocked_writes']<=0) or (not stalls and p['blocked_writes']!=0):raise ValueError('backpressure mismatch')
            if p['overlap_cycles']<=0 or p['max_read_run']<2:raise ValueError('no actual overlap/consecutive refill')
            if p['bulk_beats']!=p['reads']-p['normal_frames']*b['parameter_beats'] and n==2:raise ValueError('bulk beats mismatch')
            for f in fs:
                if (f['cache'],f['overlap'],f['memdiv'],f['latency'])!=(1,1,0,0):raise ValueError('frame profile mismatch')
                if (f['commits'],f['read_beats'],f['write_beats'],f['producer_reads'])!=(22,b['read_beats'],b['write_beats'],b['feature_read_beats']):raise ValueError('wrong actual traffic')
                if f['cycles']<=b['optimistic_overlap_lower_bound']:raise ValueError('impossible cycles')
                scalars+=m['frames'][f['frame']]['scalars'];words+=f['write_beats']
            if not stalls and len({f['cycles'] for f in fs})!=1:raise ValueError('nondeterministic continuous schedule')
    for stalls in (0,1):
        fs=[f for f in faults if f['stalls']==stalls]
        if len(fs)!=10 or [f['fault'] for f in fs]!=list(range(1,11)):raise ValueError('missing error cases')
        for f in fs:
            if f['drained']!=1 or f['commits']!=(20 if f['fault']==7 else 0):raise ValueError('unsafe error commit')
            if f['overlapped_error']!=int(f['fault']>=9):raise ValueError('missing two-direction drain')
    if text.splitlines().count('C1_R2_STREAM_CLEAN temporary_vectors_and_simulator_removed=1')!=cleanup_count:raise ValueError('missing cleanup')
    return dict(shapes=4,configs=8,normal_frames=18,error_frames=20,valid_scalars=scalars,normal_write_words=words)


def native_run(run):
    path=Path('logs/r2_stream_xsim_runs')/run
    status=json.loads(read(path/'status.json'));meta=json.loads(read(path/'metadata.json'));text=read(path/'result.log')
    if status['state']!='complete' or status['exit_code']!=0 or status['worker_in_windows_job'] is not False:raise ValueError('incomplete/non-detached xsim')
    if status['simulator_directory_present'] or Path(status['run_directory']).exists():raise ValueError('xsim temporary files retained')
    if (status['width'],status['height'],status['memory_div'],status['command_latency'])!=(640,480,2,20):raise ValueError('wrong native profile')
    fs=records(text,'FRAME');ps=records(text,'PASS');stages=records(text,'STAGE_COMMIT');b=budget()
    if len(fs)!=1 or len(ps)!=1 or len(stages)!=22 or [s['stage'] for s in stages]!=list(range(22)):raise ValueError('missing full native graph')
    f,p=fs[0],ps[0]
    if (f['width'],f['height'],f['frame'],f['commits'],f['read_beats'],f['write_beats'],f['producer_reads'])!=(640,480,0,22,b['read_beats'],b['write_beats'],b['feature_read_beats']):raise ValueError('native traffic mismatch')
    if (f['cache'],f['overlap'],f['memdiv'],f['latency'],f['stalls'])!=(1,1,2,20,0):raise ValueError('native frame profile mismatch')
    if (p['normal_frames'],p['faults'],p['invalid_shapes'],p['expected_input_only'],p['bulk_beats'])!=(1,0,10,1,b['feature_read_beats']):raise ValueError('native lifecycle mismatch')
    if p['reads']!=b['read_beats'] or p['writes']!=b['write_beats'] or p['blocked_writes']<=0 or p['overlap_cycles']<=0:raise ValueError('native memory service coverage')
    if f['cycles']<=b['optimistic_overlap_lower_bound'] or f['cycles']<2*(f['read_beats']+f['write_beats']):raise ValueError('impossible native cycles')
    if stages[-1]['words']!=b['write_beats'] or stages[-1]['cycles']!=f['cycles']:raise ValueError('native premature completion')
    if (meta['width'],meta['height'],meta['parameter_words'],meta['expected_words'])!=(640,480,2333,b['write_beats']*2):raise ValueError('wrong native vectors')
    return dict(run=run,cycles=f['cycles'],fps_at_150mhz=150000000/f['cycles'],meets_15fps_under_profile=f['cycles']<=10000000,
                valid_scalars=meta['frames'][0]['scalars'],external_bytes=b['external_bytes'],
                scope='one actual RTL 640x480 graph; 1.2GB/s shared row-memory service and 20-cycle logical command latency, NOT physical AXI/DDR/board fps')


def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');args=p.parse_args()
    text=read('logs/r2_stream_probe_20260913_c.log')+'\n'+read('logs/r2_stream_probe_20260913_d.log')
    print('C1_R2_STREAM_SIM_GATE_PASS '+json.dumps(simulation(text)))
    first=records(text,'FRAME')[0]
    mutations=[('commits=22','commits=21'),('producer_reads=112','producer_reads=111'),('read_beats=2445','read_beats=2444'),
               ('invalid_shapes=10','invalid_shapes=9'),('drained=1','drained=0'),('overlapped_error=1','overlapped_error=0'),
               ('bulk_beats=224','bulk_beats=223'),('expected_input_only=1','expected_input_only=0'),
               ('C1_R2_STREAM_CLEAN temporary_vectors_and_simulator_removed=1',''),('cycles='+str(first['cycles']),'cycles=1')]
    for old,new in mutations:
        if old not in text:raise ValueError('missing mutation marker '+old)
        try:simulation(text.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('accepted corrupted evidence '+old)
    print('C1_R2_STREAM_NEGATIVE_GATE_PASS rejected='+str(len(mutations)))
    poison=records(read('logs/r2_stream_handoff_negative_20260913.log'),'HANDOFF_NEGATIVE_PASS')
    if poison!=[dict(corruption=i,detected_at_stage=1) for i in (1,2)]:raise ValueError('missing actual RAM poison tests')
    print('C1_R2_STREAM_HANDOFF_GATE_PASS real_memory_corruptions_detected=2')
    results={}
    for cache,overlap,cycles in ((0,0,51401),(1,0,45763),(0,1,45051)):
        t=read(f'logs/r2_stream_ablation_c{cache}_o{overlap}_20260913_b.log');fs=records(t,'FRAME');ps=records(t,'PASS');b=budget(32,32,bool(cache))
        if len(fs)!=2 or len(ps)!=1 or 'C1_R2_STREAM_CLEAN' not in t:raise ValueError('missing ablation')
        for f in fs:
            if (f['cache'],f['overlap'],f['width'],f['height'],f['cycles'],f['read_beats'],f['write_beats'])!=(cache,overlap,32,32,cycles,b['read_beats'],b['write_beats']):raise ValueError('ablation mismatch')
        if (ps[0]['overlap_cycles']>0)!=bool(overlap):raise ValueError('ablation overlap coverage')
        results[f'cache{cache}_overlap{overlap}']=cycles
    results['cache1_overlap1']=next(f['cycles'] for f in records(text,'FRAME') if f['width']==32 and f['stalls']==0)
    if results['cache1_overlap1']!=40915:raise ValueError('wrong full configuration')
    print('C1_R2_STREAM_ABLATION_GATE_PASS '+json.dumps(results))
    shared=read('logs/r2_stream_shared_memory_small_20260913_d.log')
    if len(records(shared,'FRAME'))!=3 or len(records(shared,'FAULT'))!=10 or len(records(shared,'PASS'))!=1 or 'C1_R2_STREAM_CLEAN' not in shared:raise ValueError('missing shared memory tests')
    for f in records(shared,'FRAME'):
        if (f['memdiv'],f['latency'],f['cycles'],f['commits'],f['read_beats'],f['write_beats'])!=(2,20,18056,22,3143,756):raise ValueError('wrong shared memory result')
    if any(f['drained']!=1 or f['overlapped_error']!=int(f['fault']>=9) for f in records(shared,'FAULT')):raise ValueError('shared error drain missing')
    print('C1_R2_STREAM_SHARED_SERVICE_GATE_PASS small_normal_frames=3 errors=10')
    from export_r2_graph_parameters import build
    image,info=build(ROOT/'model/microstyle24_starry_functional');artifact=ROOT/'model/r2_microstyle24_starry_functional'
    if (artifact/'parameters.bin').read_bytes()!=image or json.loads((artifact/'manifest.json').read_text())!=info:raise ValueError('parameters not current')
    print('C1_R2_STREAM_PARAMETER_GATE_PASS image_bytes=180224 active_bytes=37328 commands=4666')
    run='c1_ti60_r2_stream96_i3_20260913_b';path=Path('logs/efinity_resource_runs')/run
    s=json.loads(read(path/'summary.json'));status=json.loads(read(path/'status.json'));r=s['pnr_resources'];t=s['timing']
    if status['state']!='complete' or status['exit_code']!=0 or s['flow']!='map+pnr' or s['pnr_exit_code']!=0:raise ValueError('incomplete physical run')
    if (r['xlr_cells_used'],r['memory_blocks_used'],r['dsp_blocks_used'])!=(38932,144,112):raise ValueError('wrong resource snapshot')
    if t['final_slack_ns']<0 or t['final_hold_slack_ns']<0 or t['final_period_ns']>6.666:raise ValueError('150MHz not closed')
    for name,ram,dsp in (('u_operator:c1_r2_cnn_bulk_engine',128,108),('u_writer:c1_r2_tensor_row_writer',16,0)):
        row=next((row for row in s['metrics']['module_rows'] if name in row),None)
        if row is None or [int(v) for v in re.findall(r'(\d+)\(',row)][-2:]!=[ram,dsp]:raise ValueError('resource ownership '+name)
    print('C1_R2_STREAM_PHYSICAL_GATE_PASS '+json.dumps(dict(run=run,xlr=38932,ram=144,dsp=112,setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],scope='core only')))
    b=budget()
    if (b['external_bytes'],b['feature_reads_saved'])!=(47192528,1296000):raise ValueError('native traffic plan mismatch')
    print('C1_R2_STREAM_TRAFFIC_GATE_PASS external_bytes=47192528 c6_external_bytes=67928528')
    if args.native_run:print('C1_R2_STREAM_NATIVE_CORE_GATE_PASS '+json.dumps(native_run(args.native_run)))
    else:print('C1_R2_STREAM_NATIVE_CORE_GATE_NOT_REQUESTED no_native_fps_claim=1')
    smoke=Path('logs/r2_stream_xsim_runs/c7_xsim_smoke_20260913_e')
    ss=json.loads(read(smoke/'status.json'));sf=records(read(smoke/'result.log'),'FRAME');sp=records(read(smoke/'result.log'),'PASS')
    if ss['state']!='complete' or ss['worker_in_windows_job'] is not False or ss['simulator_directory_present'] or Path(ss['run_directory']).exists():raise ValueError('latest testbench xsim smoke incomplete')
    if len(sf)!=1 or len(sp)!=1 or (sf[0]['width'],sf[0]['height'],sf[0]['cycles'],sf[0]['read_beats'],sf[0]['write_beats'],sf[0]['commits'])!=(12,12,18056,3143,756,22):raise ValueError('cross-simulator mismatch')
    print('C1_R2_STREAM_XSIM_COMPAT_GATE_PASS latest_testbench_12x12_cycles=18056 matches_icarus=1')


if __name__=='__main__':main()
