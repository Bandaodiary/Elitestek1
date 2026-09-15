"""C12 fail-closed RGBX32 evidence audit. Functional success is not a 15fps claim."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget as p2c8_budget
ROOT=Path(__file__).resolve().parents[1]
def budget(w,h):
    b=dict(p2c8_budget(w,h));saving=w*h//4
    for k in ('read_beats','write_beats','feature_read_beats'):b[k]-=saving
    return b

def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def need(ok,msg):
    if not ok:raise ValueError(msg)
def rows(t,key):return [fields(s) for s in t.splitlines() if s.startswith('C1_R2_RGBX_SYSTEM_'+key+' ')]
def clean(t):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired',t),'failed local run')
    need(t.splitlines().count('C1_R2_RGBX_SYSTEM_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing/duplicate local cleanup')
def frame(f):
    b=budget(f['width'],f['height'])
    need((f['read_beats'],f['write_beats'],f['producers'],f['commits'])==
         (b['read_beats'],b['write_beats'],b['feature_read_beats'],22),'wrong CNN real traffic/layers')
    need(f['cycles']>b['compute_cycles']+b['feature_read_beats'],'impossible CNN cycle count')
def timeline(t,p,fs):
    starts=rows(t,'NN_START');captures=rows(t,'CAPTURE');requests=rows(t,'REQUEST')
    need(len(starts)==len(fs) and [s['job'] for s in starts]==list(range(1,len(fs)+1)),'missing/duplicate CNN start timeline')
    need(len(captures)==p['captures'] and [c['tag'] for c in captures]==list(range(p['captures'])),'capture timeline/count mismatch')
    need(len(requests)==len(captures) and [r['tag'] for r in requests]==[c['tag'] for c in captures],'unmatched capture request/completion')
    ends=[];gaps=[];done_by_tag={c['tag']:c for c in captures}
    for i,(r,c) in enumerate(zip(requests,captures)):
        need(r['ready']==1 and r['cycle']<c['cycle'] and c['words']==p['width']*p['height']//4,'bad physical capture/cadence evidence')
        if i:need(r['cycle']-requests[i-1]['cycle']==p['camera_period'],'actual request cadence differs from summary')
    for i,(s,f) in enumerate(zip(starts,fs)):
        need(s['tag']==f['tag'] and s['tag'] in done_by_tag,'CNN start/result tag mismatch')
        need(s['cycle']>done_by_tag[s['tag']]['cycle'],'CNN started before actual capture completion')
        if i:
            gaps.append(s['cycle']-ends[-1]);need(gaps[-1]>=0,'overlapping jobs on single CNN array')
        # The graph resets frame_cycles on its START edge and increments only
        # in busy non-RESULT states. This system's owning lease keeps DONE
        # ready asserted: the first RESULT handshake is one clock later than
        # START + frame_cycles. C19 records that physical handshake directly.
        # The +1 cancels in completion intervals but not absolute times/gaps.
        ends.append(s['cycle']+f['cycles']+1)
    intervals=[b-a for a,b in zip(ends,ends[1:])]
    need(intervals[-1]==p['nn_interval'],'summary interval differs from independently reconstructed timeline')
    need(p['good_pixels']==2*p['width']*p['height']*p['displays'],'display frame/pixel counts disagree')
    return dict(completion_cycles=ends,completion_intervals=intervals,start_wait_cycles=gaps)

def run(p,fs,t,native=False,expected_frames=None):
    w,h=p['width'],p['height'];n=expected_frames if expected_frames is not None else (3 if native else 2)
    need(2<=n<=6 and (not native or n>=3),'invalid requested CNN count')
    need(len(fs)==p['cnn_frames']==n,'wrong completed CNN count')
    need(fs[0]['tag']==0 and all(f['tag']>0 for f in fs[1:]) and len({f['tag'] for f in fs})==n,'missing distinct capture tags')
    for f in fs:
        need((f['width'],f['height'],f['stalls'])==(w,h,p['stalls']),'mixed CNN profiles');frame(f)
    need(p['actual_capture_only']==1 and p['rgbx32']==1 and p['native_timing']==int(native),'wrong input source/timing mode')
    need(p['captures']>=n and p['displays']>=n and p['good_pixels']>=2*n*w*h,'missing capture/dual-image lifecycle')
    need(p['underflow']==p['display_misses']==0,'missed display deadline')
    need(p['camera_period']==(5000000 if native else w*h*25+4000),'wrong camera cadence')
    need(p['cpu_r']>0 and p['cpu_w']>0 and p['apb_checks']==9,'missing CPU/APB activity')
    need(1<p['peak_r']<=8 and 0<p['peak_w']<=8,'invalid physical credit coverage')
    need(p['nn_interval']>=fs[-1]['cycles'],'completion interval shorter than frame execution')
    return timeline(t,p,fs)
def matrix(t,shapes,expected_frames=2):
    clean(t);profiles=[];ff=[];trace=[]
    for line in t.splitlines():
        trace.append(line)
        if line.startswith('C1_R2_RGBX_SYSTEM_FRAME '):ff.append(fields(line))
        if line.startswith('C1_R2_RGBX_SYSTEM_PASS '):profiles.append((fields(line),ff,'\n'.join(trace)));ff=[];trace=[]
    need(not ff,'unterminated configuration')
    keys={(w,h,s) for w,h in shapes for s in (0,1)}
    need(len(profiles)==len(keys) and {(p['width'],p['height'],p['stalls']) for p,_,_ in profiles}==keys,'missing/duplicate matrix profiles')
    for p,fs,trace_text in profiles:run(p,fs,trace_text,expected_frames=expected_frames)
    return dict(configs=len(profiles),cnn_frames=expected_frames*len(profiles),good_display_pixels=sum(p['good_pixels'] for p,_,_ in profiles))
def throughput(tm,native):
    # Job 1 is warm-up; job 2 starts before continuous scanout in this test.
    # Audit EVERY interval ending at jobs 3..N, never only the fastest/last one.
    intervals=tm['completion_intervals'];full=intervals[1:] if native else []
    need(bool(intervals) and all(c>0 for c in intervals),'invalid completion intervals')
    need(not native or bool(full),'no fully loaded completion interval')
    return dict(last_interval_fps_at_150mhz=150000000/intervals[-1] if native else None,
                full_load_completion_intervals=full,full_load_interval_samples=len(full),
                worst_full_load_interval_fps_at_150mhz=150000000/max(full) if native else None,
                meets_15fps=all(c<=10000000 for c in full) if native else None)

def require_throughput(result,minimum_samples):
    need(result['full_load_interval_samples']>=minimum_samples,'insufficient consecutive full-load intervals')
    need(result['meets_15fps'],'native functional pass but at least one full-load interval is less than 15fps')

def xsim(run_id,native):
    folder=Path('logs/r2_video_rgbx_xsim_runs')/run_id;s=json.loads(read(folder/'status.json'))
    need(s['run_id']==run_id and s['state']=='complete' and s['exit_code']==0,'xsim not successfully complete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'xsim nonisolated/unclean')
    need((s['memory_div'],s['command_latency'])==(2,20),'wrong shared bandwidth model')
    t=read(folder/'result.log');ps=rows(t,'PASS');fs=rows(t,'FRAME')
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired',t),'failed xsim evidence')
    n=s.get('nn_target',3 if native else 2)
    need(len(ps)==1,'missing/duplicate xsim pass');p=ps[0];tm=run(p,fs,t,native,n)
    need((s['width'],s['height'])==(p['width'],p['height']),'mixed xsim geometry')
    need(s.get('stalls',p['stalls'])==p['stalls'],'mixed xsim wait profile')
    if native:
        need((p['width'],p['height'],p['stalls'])==(640,480,0),'wrong native profile')
        commits=rows(t,'STAGE');need(len(commits)==22*n,'missing native stage records')
        for f in fs:
            cc=[c for c in commits if c['tag']==f['tag']]
            need([c['stage'] for c in cc]==list(range(22)) and cc[-1]['words']==f['write_beats'] and cc[-1]['cycles']==f['cycles'],'native commit/count mismatch')
        m=json.loads(read(folder/'metadata.json'))
        need((m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])==(2333,153600,2860800,21043200),'wrong native golden')
    return dict(run_id=run_id,native=native,cnn_frames=n,frame_cycles=[f['cycles'] for f in fs],last_completion_interval_cycles=p['nn_interval'],
                timeline=tm,**throughput(tm,native),
                scope='finite-run last completion interval; core-domain RGB/ROI + normalized CPU AXI; no actual CPU IP/PHY/CDC/board')
def physical(run_id):
    folder=Path('logs/efinity_resource_runs')/run_id;s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'summary.json'))
    need(s['run_id']==m['run_id']==run_id and s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0,'incomplete/mixed Efinity run')
    need(m['marker']=='C1_TI60_R2_VIDEO_RGBX96_MAP_PNR_PASS' and m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr','wrong Efinity target/probe')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_video_rgbx96_'+run_id)
    need(not private.exists(),'Efinity private database retained')
    need('--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'),'wrong speed grade')
    r=m['pnr_resources'];t=m['timing'];mm=m['metrics'];hier=set(mm['module_rows']+mm.get('module_focus_rows',[]))
    need(r['dsp_blocks_used']==112 and r['memory_blocks_used']==172 and 0<r['xlr_cells_used']<=60800,'unexpected/pruned footprint')
    need(mm['primitive_counts'].get('EFX_DSP24')==96 and mm['primitive_counts'].get('EFX_DSP48')==16,'not one retained compute array')
    for name in ('+u_control:c1_r2_video_rgbx_csr','+u_leases:c1_r2_video_rgbx_leases','+u_capture:c1_r2_video_capture_rgbx32',
                 '+u_scanout:c1_r2_video_scanout_rgbx32','+u_cnn:c1_r2_microstyle_rgbx_axi_graph','+u_fabric:c1_r2_axi_fabric'):
        need(sum(name in row for row in hier)==1,'missing/duplicate hierarchy '+name)
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002,'150MHz setup/hold failed')
    return dict(run_id=run_id,resources=r,timing=t,scope='pin-reduced fixed 640x480 RGBX32/4raw/3styled core, no actual CPU/DDR PHY/ISP/HDMI/CDC or IO constraints')

def row_units(t):
    need('C1_R2_RGBX_ROW_CLEAN temporary_simulator_removed=1' in t and not re.search('FATAL|ERROR|Traceback',t),'packed row run failed/unclean')
    rs=[fields(x) for x in t.splitlines() if x.startswith('C1_R2_RGBX_ROW_PASS ')]
    need(len(rs)==8 and {(r['stalls'],r['aw_wait_w'],r['outstanding']) for r in rs}=={(s,a,n) for s in (0,1) for a in (0,2) for n in (1,4)},'missing row configurations')
    for r in rs:
        need((r['normal'],r['faults'],r['rejects'],r['physical_ratio'],r['snapshot'],r['held_response'],r['drain'])==(15,16,4,2,1,1,1),'row conversion/fault coverage missing')
    return dict(configs=8,normal=120,faults=128,rejected_commands=32)
def video_units(t,shapes,aw):
    need('C1_R2_RGBX_VIDEO_DMA_CLEAN temporary_simulator_removed=1' in t and not re.search('FATAL|ERROR|Traceback',t),'video DMA failed/unclean')
    rr=[];cc=[];ss=[]
    for x in t.splitlines():
        if x.startswith('C1_R2_RGBX_VIDEO_CAPTURE_PASS '):cc.append(fields(x))
        if x.startswith('C1_R2_RGBX_VIDEO_SCAN_PASS '):ss.append(fields(x))
        if x.startswith('C1_R2_RGBX_VIDEO_DMA_PASS '):rr.append((fields(x),cc,ss));cc=[];ss=[]
    need(not cc and not ss,'unterminated video unit')
    need(len(rr)==2*len(shapes) and {(r['width'],r['height'],r['stalls'],r['aw_wait_w']) for r,_,_ in rr}=={(w,h,s,aw) for w,h in shapes for s in (0,1)},'missing video profiles')
    for r,cs,sc in rr:
        w,h=r['width'],r['height']
        need((r['captures'],r['scans'],r['overflow'],r['underflow'])==(10,7,1,1) and r['aw']==r['b'],'video fault/recovery missing')
        need([c['fault'] for c in cs]==[0,0,1,0,2,0,3,0,4,0] and [q['fault'] for q in sc]==[0,1,0,2,0,3,0],'wrong video fault sequence')
        for c in cs:
            if c['fault']==0:need(c['words']==w*h//4,'capture is not four RGB pixels/physical beat')
        for q in sc:
            if q['fault']==0:need(q['reads']==w*h//2 and q['underruns']==0,'dual scanout traffic/deadline mismatch')
    return dict(configs=len(rr),capture_frames=10*len(rr),display_frames=7*len(rr))

def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');p.add_argument('--pnr-run');p.add_argument('--require-15fps',action='store_true')
    p.add_argument('--minimum-full-load-intervals',type=int,choices=range(1,5),default=1);a=p.parse_args()
    print('C1_R2_C12_ROW_GATE_PASS '+json.dumps(row_units(read('logs/r2_rgbx_row_matrix_20260913_a.log'))))
    print('C1_R2_C12_VIDEO_DMA_GATE_PASS '+json.dumps(video_units(read('logs/r2_rgbx_video_dma_matrix_20260913_a.log'),((8,12),(32,12),(640,4)),0)))
    print('C1_R2_C12_VIDEO_WBEFOREAW_GATE_PASS '+json.dumps(video_units(read('logs/r2_rgbx_video_dma_wbeforeaw_20260913_a.log'),((8,12),(640,4)),2)))
    t=read('logs/r2_rgbx_system_matrix_20260913_b.log');shapes=((4,4),(8,8),(12,12),(32,32))
    print('C1_R2_C12_MATRIX_GATE_PASS '+json.dumps(matrix(t,shapes)))
    print('C1_R2_C12_WBEFOREAW_GATE_PASS '+json.dumps(matrix(read('logs/r2_rgbx_system_wbeforeaw_20260913_a.log'),((12,12),))))
    neg=read('logs/r2_rgbx_system_negative_20260913_a.log');clean(neg);nn=rows(neg,'NEGATIVE_PASS')
    need(len(nn)==4 and {(r['width'],r['height'],r['stalls'],r['corruption'],r['actual_ram_mutation']) for r in nn}=={(8,8,s,n,1) for s in (0,1) for n in (1,2)},'missing actual RAM negative controls')
    print('C1_R2_C12_NEGATIVE_GATE_PASS cases=4')
    lease=read('logs/r2_rgbx_leases_20260913_b.log')
    need('C1_R2_RGBX_LEASE_PASS checks=132 captures=7 nn=4 displays=3 raw_slots=4 output_slots=3 concurrent_front_pending_nn_capture=1 no_swap_wait=1 reset=1' in lease and
         'C1_R2_RGBX_ROW_CLEAN temporary_simulator_removed=1' in lease and not re.search('FATAL|ERROR|Traceback',lease),'lease regression missing')
    print('C1_R2_C12_LEASE_GATE_PASS checks=132')
    csr=read('logs/r2_rgbx_csr_20260913_a.log')
    need('C1_R2_RGBX_CSR_PASS checks=102 masked_writes=1 reserved_reject=1 irq_set_wins=1 disabled_completion=1 reset=1' in csr and
         'C1_R2_RGBX_ROW_CLEAN temporary_simulator_removed=1' in csr and not re.search('FATAL|ERROR|Traceback',csr),'new R2V2 CSR regression missing')
    print('C1_R2_C12_CSR_GATE_PASS checks=102')
    print('C1_R2_C12_XSIM_SMALL_GATE_PASS '+json.dumps(xsim('c12_rgbx_xsim_8x8_20260913_a',False)))
    xs=json.loads(read('logs/r2_video_rgbx_xsim_runs/c12_rgbx_xsim_12x12_20260913_a/status.json'))
    need((xs['width'],xs['height'],xs['stalls'],xs['aw_wait_w'])==(12,12,1,2),'wrong xsim stress configuration')
    print('C1_R2_C12_XSIM_STRESS_GATE_PASS '+json.dumps(xsim('c12_rgbx_xsim_12x12_20260913_a',False)))
    print('C1_R2_C12_SIXFRAME_MATRIX_GATE_PASS '+json.dumps(matrix(read('logs/r2_rgbx_system_sixframe_20260913_a.log'),((8,8),(12,12)),6)))
    six=xsim('c12_rgbx_xsim_sixframe_8x8_20260913_a',False)
    need(six['cnn_frames']==6 and len(six['timeline']['start_wait_cycles'])==5,'missing six-frame xsim lifecycle')
    ss=json.loads(read('logs/r2_video_rgbx_xsim_runs/c12_rgbx_xsim_sixframe_8x8_20260913_a/status.json'))
    need((ss['stalls'],ss['aw_wait_w'],ss['nn_target'])==(1,2,6),'wrong six-frame stress profile')
    print('C1_R2_C12_XSIM_SIXFRAME_GATE_PASS '+json.dumps(six))
    driver=read('logs/r2_rgbx_driver_compile_20260913_a.log')
    need('C1_R2_RGBX_DRIVER_COMPILE_PASS rv32imac=1 ilp32=1 functions=3 fences=5 hardware_execution=0' in driver and
         'C1_R2_RGBX_DRIVER_CLEAN temporary_object_removed=1' in driver and not re.search('error:|Traceback|RuntimeError',driver),'driver compile check missing')
    print('C1_R2_C12_DRIVER_GATE_PASS functions=3 hardware_execution=0')
    for old,new in [('commits=22','commits=21'),('actual_capture_only=1','actual_capture_only=0'),('rgbx32=1','rgbx32=0'),('underflow=0','underflow=1'),
                    ('camera_period=5600','camera_period=5601'),('C1_R2_RGBX_SYSTEM_CLEAN temporary_vectors_and_simulator_removed=1','')]:
        need(old in t,'audit mutation absent')
        try:matrix(t.replace(old,new,1),shapes)
        except ValueError:pass
        else:raise ValueError('corrupt evidence accepted '+old)
    for bad in (
        re.sub(r'(?m)^C1_R2_RGBX_SYSTEM_NN_START .*\n','',t,count=1),
        re.sub(r'nn_interval=(\d+)',lambda m:'nn_interval='+str(int(m[1])+1),t,count=1),
        re.sub(r'(?m)^(C1_R2_RGBX_SYSTEM_CAPTURE tag=0 words=)\d+',r'\g<1>0',t,count=1),
        re.sub(r'(?m)^(C1_R2_RGBX_SYSTEM_NN_START job=1 tag=0 cycle=)\d+',r'\g<1>0',t,count=1),
        re.sub(r'(?m)^(C1_R2_RGBX_SYSTEM_REQUEST cycle=)\d+',r'\g<1>0',t,count=1),
        re.sub(r'good_pixels=(\d+)',lambda m:'good_pixels='+str(int(m[1])+1),t,count=1),
    ):
        need(bad!=t,'timeline audit mutation absent')
        try:matrix(bad,shapes)
        except ValueError:pass
        else:raise ValueError('corrupt timeline evidence accepted')
    print('C1_R2_C12_AUDIT_NEGATIVE_PASS rejected=12')
    if a.native_run:
        result=xsim(a.native_run,True);print('C1_R2_C12_NATIVE_FUNCTIONAL_GATE_PASS '+json.dumps(result))
        if a.require_15fps:require_throughput(result,a.minimum_full_load_intervals)
    else:need(not a.require_15fps,'native run required for 15fps claim')
    if a.pnr_run:print('C1_R2_C12_PHYSICAL_GATE_PASS '+json.dumps(physical(a.pnr_run)))
if __name__=='__main__':main()
