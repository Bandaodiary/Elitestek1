"""C10 fail-closed text audit. Separate from the retained C2 engine gate."""
from __future__ import annotations
import argparse,json,re
from pathlib import Path
from check_r2_graph_evidence import fields
from r2_stream_traffic_budget import budget
ROOT=Path(__file__).resolve().parents[1]
def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def need(ok,msg):
    if not ok:raise ValueError(msg)
def rows(t,k):return [fields(s) for s in t.splitlines() if s.startswith('C1_R2_SHARED_'+k+' ')]
def clean(t):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired',t),'failed run')
    need(t.splitlines().count('C1_R2_SHARED_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing/duplicate cleanup')
def frame(f):
    b=budget(f['width'],f['height'])
    need((f['read_beats'],f['write_beats'],f['producer_reads'],f['commits'])==
         (b['read_beats'],b['write_beats'],b['feature_read_beats'],22),'incorrect real tensor traffic/commits')
    need(0<f['ar']<=f['read_beats'] and 0<f['aw']<=f['write_beats'],'invalid burst counts')
    need(f['cycles']>b['compute_cycles']+b['feature_read_beats'],'impossible cycle count')
    need(0<f['peak_read']<=8 and 0<f['peak_write']<=8,'invalid physical queue peaks')
    need((f['bg_reads']>0 and f['bg_writes']>0) if f['background'] else (f['bg_reads']==f['bg_writes']==0),'background traffic missing/unexpected')

def matrix(t,shapes,stalls=(0,1),background=1):
    clean(t);metas=[json.loads(s.split(' ',1)[1]) for s in t.splitlines() if s.startswith('C1_R2_SHARED_VECTORS ')]
    need(len(metas)==len(shapes) and {(m['width'],m['height']) for m in metas}==set(shapes),'missing/extra vector shapes')
    runs=[];ff=[];ee=[]
    for line in t.splitlines():
        if line.startswith('C1_R2_SHARED_FRAME '):ff.append(fields(line))
        if line.startswith('C1_R2_SHARED_FAULT '):ee.append(fields(line))
        if line.startswith('C1_R2_SHARED_PASS '):runs.append((fields(line),ff,ee));ff=[];ee=[]
    need(not ff and not ee,'unterminated configuration')
    keys={(w,h,s) for w,h in shapes for s in stalls}
    need(len(runs)==len(keys) and {(p['width'],p['height'],p['stalls']) for p,_,_ in runs}==keys,'missing/duplicate profiles')
    normals=faults=scalars=0
    for p,fs,es in runs:
        w,h=p['width'],p['height'];m=next(m for m in metas if (m['width'],m['height'])==(w,h));b=budget(w,h)
        need((m['parameter_words'],m['input_words'],m['expected_words'])==(2333,w*h//2,b['write_beats']*2),'wrong golden metadata')
        need(len(m['frames'])==2,'two independent frame golden sets required')
        for mf in m['frames']:
            need(len(mf['stages'])==19 and {s['stage'] for s in mf['stages']}==set(range(22))-{14,17,21},'missing golden layer')
            need(sum(s['words'] for s in mf['stages'])==b['write_beats'],'wrong golden write budget')
            need(sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in mf['stages'])==mf['scalars'],'wrong scalar budget')
        n=7 if (w,h)==(12,12) else 2;nf=5 if n==7 else 0
        need((p['normal_frames'],p['faults'],p['background'],p['actual_capture_handoff'])==(n,nf,background,background),'incomplete lifecycle/handoff')
        need(p['apb_checks']==(207 if nf else 40),'APB lifecycle coverage missing')
        need((p['concurrent_cycles']>0) if background else p['concurrent_cycles']==0,'concurrency coverage missing')
        need(len(fs)==n and [f['frame'] for f in fs]==[0,1]+[0]*(n-2),'wrong frame/recovery sequence')
        for f in fs:
            need((f['width'],f['height'],f['stalls'],f['background'])==(w,h,p['stalls'],background),'mixed frame identity')
            frame(f);scalars+=m['frames'][f['frame']]['scalars']
        need([e['fault'] for e in es]==list(range(1,nf+1)),'missing fault/recovery')
        for e in es:
            k=e['fault']
            need((e['commits'],e['discarded'],e['error'],e['published'],e['drained'])==
                 (0 if k in (1,5) else 20 if k==2 else 22,int(k in (3,4)),int(k in (1,2,5)),0,1),'unsafe fault completion')
        normals+=len(fs);faults+=len(es)
    return dict(configs=len(runs),normal_frames=normals,fault_frames=faults,valid_scalars=scalars,background=background)

def native(run):
    f=Path('logs/r2_shared_xsim_runs')/run;s=json.loads(read(f/'status.json'));m=json.loads(read(f/'metadata.json'));t=read(f/'result.log')
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'native unfinished/nonisolated/unclean')
    need((s['width'],s['height'],s['memory_div'],s['command_latency'])==(640,480,2,20),'wrong native memory profile')
    fs=rows(t,'FRAME');ps=rows(t,'PASS');stages=rows(t,'STAGE_COMMIT')
    need(len(fs)==len(ps)==1 and [r['stage'] for r in stages]==list(range(22)),'incomplete native graph')
    r=fs[0];p=ps[0];frame(r)
    need((r['width'],r['height'],r['frame'],r['stalls'],r['background'])==(640,480,0,0,1),'wrong native frame')
    need((p['normal_frames'],p['faults'],p['actual_capture_handoff'],p['apb_checks'])==(1,0,0,20),'native is one frame, not demonstrated two-frame handoff')
    need(p['peak_read']==p['peak_write']==6 and p['concurrent_cycles']>0,'native concurrent debt coverage')
    need(stages[-1]['cycles']==r['cycles'] and stages[-1]['words']==r['write_beats'],'commit/host cycle mismatch')
    need((m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])==(2333,153600,2860800,21043200),'native golden mismatch')
    return dict(run=run,cycles=r['cycles'],fps_at_150mhz=150000000/r['cycles'],margin_to_15fps_cycles=10000000-r['cycles'],
        cnn_ar=r['ar'],cnn_aw=r['aw'],cnn_r=r['read_beats'],cnn_w=r['write_beats'],background_r=r['bg_reads'],background_w=r['bg_writes'],
        valid_scalars=21043200,scope='shared-bus simulation, paced 640x480 P2C8 capture/display/CPU agents; not CPU IP/video PHY/board or display-deadline proof')

def physical(run):
    f=Path('logs/efinity_resource_runs')/run;s=json.loads(read(f/'status.json'));m=json.loads(read(f/'summary.json'))
    need(s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0 and s['run_id']==m['run_id']==run,'incomplete/mixed physical evidence')
    need(m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr','wrong target/flow')
    need('--timing_model I3 ' in read(f/'efinity.pnr.stdout.tail.log'),'wrong speed grade')
    r=m['pnr_resources'];t=m['timing'];mm=m['metrics'];hier=list(set(mm['module_rows']+mm.get('module_focus_rows',[])))
    need(r['dsp_blocks_used']==112 and r['memory_blocks_used']==162 and 0<r['xlr_cells_used']<=60800,'unexpected/pruned footprint')
    need(mm['primitive_counts'].get('EFX_DSP24')==96 and mm['primitive_counts'].get('EFX_DSP48')==16,'not one shared compute')
    for name in ('+u_control:c1_r2_apb_job_control','+u_cnn:c1_r2_microstyle_axi_graph','+u_fabric:c1_r2_axi_fabric'):
        need(sum(name in row for row in hier)==1,'missing/duplicate system hierarchy: '+name)
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002,'150MHz setup/hold failed')
    return dict(run=run,resources=r,timing=t,scope='C10 shared_system96 pin-reduced system probe, core-only, no board IO constraints')

def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');p.add_argument('--pnr-run');a=p.parse_args()
    t=read('logs/r2_shared_matrix_20260913_b.log');shapes=((4,4),(12,12),(32,32))
    print('C1_R2_C10_MATRIX_GATE_PASS '+json.dumps(matrix(t,shapes)))
    print('C1_R2_C10_NO_BACKGROUND_GATE_PASS '+json.dumps(matrix(read('logs/r2_shared_no_background_20260913_b.log'),((32,32),),(0,),0)))
    apb=read('logs/r2_shared_apb_20260913_b.log');clean(apb);pp=rows(apb,'APB_PASS')
    need(len(pp)==1 and pp[0]==dict(checks=47,starts=4,snapshot=1,lease_reject=1,publication_hold=1,deferred_discard=1,irq_set_wins=1),'incomplete APB coverage')
    print('C1_R2_C10_APB_GATE_PASS checks=47')
    print('C1_R2_C10_WBEFOREAW_GATE_PASS '+json.dumps(matrix(read('logs/r2_c10_wbeforeaw_20260913_b.log'),((12,12),))))
    neg=read('logs/r2_c10_capture_negative_20260913_a.log');clean(neg);ns=rows(neg,'HANDOFF_NEGATIVE_PASS')
    need(len(ns)==4 and {(r['mode'],r['stalls'],r['actual_capture']) for r in ns}=={(m,s,1) for m in (1,2) for s in (0,1)},'missing actual capture RAM negative tests')
    print('C1_R2_C10_CAPTURE_NEGATIVE_GATE_PASS cases=4')
    for old,new in [('commits=22','commits=21'),('drained=1','drained=0'),('actual_capture_handoff=1','actual_capture_handoff=0'),
                    ('apb_checks=207','apb_checks=206'),('read_beats=2445','read_beats=2444'),('discarded=1','discarded=0'),
                    ('C1_R2_SHARED_CLEAN temporary_vectors_and_simulator_removed=1','')]:
        need(old in t,'mutation absent')
        try:matrix(t.replace(old,new,1),shapes)
        except ValueError:pass
        else:raise ValueError('corrupt evidence accepted '+old)
    print('C1_R2_C10_AUDIT_NEGATIVE_PASS rejected=7')
    if a.native_run:print('C1_R2_C10_NATIVE_GATE_PASS '+json.dumps(native(a.native_run)))
    if a.pnr_run:print('C1_R2_C10_PHYSICAL_GATE_PASS '+json.dumps(physical(a.pnr_run)))

if __name__=='__main__':main()
