"""C11 fail-closed evidence audit. Functional success is not a 15fps claim."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]

def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def need(ok,msg):
    if not ok:raise ValueError(msg)
def rows(t,key):return [fields(s) for s in t.splitlines() if s.startswith('C1_R2_VIDEO_SYSTEM_'+key+' ')]
def clean(t):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired',t),'failed local run')
    need(t.splitlines().count('C1_R2_VIDEO_SYSTEM_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing/duplicate local cleanup')
def frame(f):
    b=budget(f['width'],f['height'])
    need((f['read_beats'],f['write_beats'],f['producers'],f['commits'])==
         (b['read_beats'],b['write_beats'],b['feature_read_beats'],22),'wrong CNN real traffic/layers')
    need(f['cycles']>b['compute_cycles']+b['feature_read_beats'],'impossible CNN cycle count')
def run(p,fs,native=False):
    w,h=p['width'],p['height'];n=3 if native else 2
    need(len(fs)==p['cnn_frames']==n,'wrong completed CNN count')
    need(fs[0]['tag']==0 and all(f['tag']>0 for f in fs[1:]) and len({f['tag'] for f in fs})==n,'missing distinct capture tags')
    for f in fs:
        need((f['width'],f['height'],f['stalls'])==(w,h,p['stalls']),'mixed CNN profiles');frame(f)
    need(p['actual_capture_only']==1 and p['native_timing']==int(native),'wrong input source/timing mode')
    need(p['captures']>=n and p['displays']>=n and p['good_pixels']>=2*n*w*h,'missing capture/dual-image lifecycle')
    need(p['underflow']==p['display_misses']==0,'missed display deadline')
    need(p['camera_period']==(5000000 if native else w*h*25+4000),'wrong camera cadence')
    need(p['cpu_r']>0 and p['cpu_w']>0 and p['apb_checks']==9,'missing CPU/APB activity')
    need(1<p['peak_r']<=8 and 0<p['peak_w']<=8,'invalid physical credit coverage')
    need(p['nn_interval']>=fs[-1]['cycles'],'completion interval shorter than frame execution')
def matrix(t,shapes):
    clean(t);profiles=[];ff=[]
    for line in t.splitlines():
        if line.startswith('C1_R2_VIDEO_SYSTEM_FRAME '):ff.append(fields(line))
        if line.startswith('C1_R2_VIDEO_SYSTEM_PASS '):profiles.append((fields(line),ff));ff=[]
    need(not ff,'unterminated configuration')
    keys={(w,h,s) for w,h in shapes for s in (0,1)}
    need(len(profiles)==len(keys) and {(p['width'],p['height'],p['stalls']) for p,_ in profiles}==keys,'missing/duplicate matrix profiles')
    for p,fs in profiles:run(p,fs)
    return dict(configs=len(profiles),cnn_frames=2*len(profiles),good_display_pixels=sum(p['good_pixels'] for p,_ in profiles))
def xsim(run_id,native):
    folder=Path('logs/r2_video_system_xsim_runs')/run_id;s=json.loads(read(folder/'status.json'))
    need(s['run_id']==run_id and s['state']=='complete' and s['exit_code']==0,'xsim not successfully complete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'xsim nonisolated/unclean')
    need((s['memory_div'],s['command_latency'])==(2,20),'wrong shared bandwidth model')
    t=read(folder/'result.log');ps=rows(t,'PASS');fs=rows(t,'FRAME')
    need(len(ps)==1,'missing/duplicate xsim pass');p=ps[0];run(p,fs,native)
    need((s['width'],s['height'])==(p['width'],p['height']),'mixed xsim geometry')
    need(s.get('stalls',p['stalls'])==p['stalls'],'mixed xsim wait profile')
    if native:
        need((p['width'],p['height'],p['stalls'])==(640,480,0),'wrong native profile')
        commits=rows(t,'STAGE');need(len(commits)==66,'missing native stage records')
        for f in fs:
            cc=[c for c in commits if c['tag']==f['tag']]
            need([c['stage'] for c in cc]==list(range(22)) and cc[-1]['words']==f['write_beats'] and cc[-1]['cycles']==f['cycles'],'native commit/count mismatch')
        m=json.loads(read(folder/'metadata.json'))
        need((m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])==(2333,153600,2860800,21043200),'wrong native golden')
    return dict(run_id=run_id,native=native,frame_cycles=[f['cycles'] for f in fs],last_completion_interval_cycles=p['nn_interval'],
                steady_fps_at_150mhz=150000000/p['nn_interval'] if native else None,
                meets_15fps=(p['nn_interval']<=10000000) if native else None,
                scope='core-domain RGB/ROI + normalized CPU AXI simulation; no actual CPU IP/PHY/CDC/board')
def physical(run_id):
    folder=Path('logs/efinity_resource_runs')/run_id;s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'summary.json'))
    need(s['run_id']==m['run_id']==run_id and s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0,'incomplete/mixed Efinity run')
    need(m['marker']=='C1_TI60_R2_VIDEO_SYSTEM96_MAP_PNR_PASS' and m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr','wrong Efinity target/probe')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_video_system96_'+run_id)
    need(not private.exists(),'Efinity private database retained')
    need('--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'),'wrong speed grade')
    r=m['pnr_resources'];t=m['timing'];mm=m['metrics'];hier=set(mm['module_rows']+mm.get('module_focus_rows',[]))
    need(r['dsp_blocks_used']==112 and 162<r['memory_blocks_used']<=256 and 0<r['xlr_cells_used']<=60800,'unexpected/pruned footprint')
    need(mm['primitive_counts'].get('EFX_DSP24')==96 and mm['primitive_counts'].get('EFX_DSP48')==16,'not one retained compute array')
    for name in ('+u_control:c1_r2_video_csr','+u_leases:c1_r2_video_frame_leases','+u_capture:c1_r2_video_capture_p2c8',
                 '+u_scanout:c1_r2_video_scanout_p2c8','+u_cnn:c1_r2_microstyle_axi_graph','+u_fabric:c1_r2_axi_fabric'):
        need(sum(name in row for row in hier)==1,'missing/duplicate hierarchy '+name)
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002,'150MHz setup/hold failed')
    return dict(run_id=run_id,resources=r,timing=t,scope='pin-reduced fixed 640x480 core, no actual CPU/DDR PHY/ISP/HDMI/CDC or IO constraints')
def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');p.add_argument('--pnr-run');p.add_argument('--require-15fps',action='store_true');a=p.parse_args()
    t=read('logs/r2_video_system_matrix_20260913_b.log');shapes=((8,8),(32,32))
    print('C1_R2_C11_MATRIX_GATE_PASS '+json.dumps(matrix(t,shapes)))
    print('C1_R2_C11_WBEFOREAW_GATE_PASS '+json.dumps(matrix(read('logs/r2_video_system_wbeforeaw_20260913_a.log'),((8,8),))))
    neg=read('logs/r2_video_system_negative_20260913_a.log');clean(neg);nn=rows(neg,'NEGATIVE_PASS')
    need(len(nn)==4 and {(r['width'],r['height'],r['stalls'],r['corruption'],r['actual_ram_mutation']) for r in nn}=={(8,8,s,n,1) for s in (0,1) for n in (1,2)},'missing actual RAM negative controls')
    print('C1_R2_C11_NEGATIVE_GATE_PASS cases=4')
    lease=read('logs/r2_video_leases_20260913_c.log')
    need('C1_R2_VIDEO_LEASE_PASS checks=148 captures=8 nn=4 displays=4 pending_hold=1 paired_swaps=2 orphan_lock=1 reset=1' in lease and
         'C1_R2_VIDEO_CLEAN temporary_simulator_removed=1' in lease and not re.search('FATAL|ERROR|Traceback',lease),'lease regression missing')
    print('C1_R2_C11_LEASE_GATE_PASS checks=148')
    csr=read('logs/r2_video_csr_20260913_a.log')
    need('C1_R2_VIDEO_CSR_PASS checks=102 masked_writes=1 reserved_reject=1 irq_set_wins=1 disabled_completion=1 reset=1' in csr and
         'C1_R2_VIDEO_CLEAN temporary_simulator_removed=1' in csr and not re.search('FATAL|ERROR|Traceback',csr),'new R2V1 CSR regression missing')
    print('C1_R2_C11_CSR_GATE_PASS checks=102')
    print('C1_R2_C11_XSIM_SMALL_GATE_PASS '+json.dumps(xsim('c11_video_xsim_8x8_20260913_e',False)))
    xs=json.loads(read('logs/r2_video_system_xsim_runs/c11_video_xsim_32x32_20260913_a/status.json'))
    need((xs['width'],xs['height'],xs['stalls'],xs['aw_wait_w'])==(32,32,1,2),'wrong xsim stress configuration')
    print('C1_R2_C11_XSIM_STRESS_GATE_PASS '+json.dumps(xsim('c11_video_xsim_32x32_20260913_a',False)))
    driver=read('logs/r2_video_driver_compile_20260913_a.log')
    need('C1_R2_VIDEO_DRIVER_COMPILE_PASS rv32imac=1 ilp32=1 functions=3 fences=5 hardware_execution=0' in driver and
         'C1_R2_VIDEO_DRIVER_CLEAN temporary_object_removed=1' in driver and not re.search('error:|Traceback|RuntimeError',driver),'driver compile check missing')
    print('C1_R2_C11_DRIVER_GATE_PASS functions=3 hardware_execution=0')
    for old,new in [('commits=22','commits=21'),('actual_capture_only=1','actual_capture_only=0'),('underflow=0','underflow=1'),
                    ('camera_period=5600','camera_period=5601'),('C1_R2_VIDEO_SYSTEM_CLEAN temporary_vectors_and_simulator_removed=1','')]:
        need(old in t,'audit mutation absent')
        try:matrix(t.replace(old,new,1),shapes)
        except ValueError:pass
        else:raise ValueError('corrupt evidence accepted '+old)
    print('C1_R2_C11_AUDIT_NEGATIVE_PASS rejected=5')
    if a.native_run:
        result=xsim(a.native_run,True);print('C1_R2_C11_NATIVE_FUNCTIONAL_GATE_PASS '+json.dumps(result))
        if a.require_15fps:need(result['meets_15fps'],'native functional pass but less than 15fps')
    else:need(not a.require_15fps,'native run required for 15fps claim')
    if a.pnr_run:print('C1_R2_C11_PHYSICAL_GATE_PASS '+json.dumps(physical(a.pnr_run)))
if __name__=='__main__':main()
