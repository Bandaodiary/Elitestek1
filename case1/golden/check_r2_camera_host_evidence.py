"""C26 source-to-CNN evidence: real source SOFs, final ingress fence, no inherited FPS."""
from __future__ import annotations
import argparse
import ast
import json
import re
from pathlib import Path
import check_r2_resize_host_evidence as c24
import check_r2_camera_ingress_evidence as c25
from run_r2_camera_host_probe import ROOT, SOURCES, PLAN_SOURCE
from run_r2_resize_host_probe import SOURCES as OLD_SOURCES
from r2_camera_plan_vectors import camera_geometry

need, tokens, read = c24.need, c24.tokens, c24.read
P = 'C1_R2_CAMERA_HOST_SYSTEM_'
F = 'C1_R2_CAMERA_HOST_FAULT_'


def rows(text, key, prefix=P):
    return c24.rows(text, key, prefix)


def one(text, key, prefix=P):
    rr = rows(text, key, prefix)
    need(len(rr) == 1, 'missing/duplicate '+key)
    return rr[0]


def source_gate():
    c25.source_gate()
    removed = {'rtl/r2/c1_r2_resize_host_system.sv', 'rtl/r2/c1_r2_video_resize_system.sv'}
    added = {'rtl/r2/c1_r2_camera_host_system.sv', 'rtl/r2/c1_r2_video_camera_system.sv',
             'rtl/r2/c1_r2_camera_ingress.sv', 'rtl/r2/c1_r2_async_pixel_fifo.sv',
             'rtl/common/c1_cdc_latest_snapshot.sv'}
    need(len(SOURCES) == len(set(SOURCES)) == 44 and set(SOURCES) == set(OLD_SOURCES)-removed | added,
         'wrong actual camera-host closure')
    need(all((ROOT/s).is_file() for s in SOURCES) and SOURCES.count(PLAN_SOURCE) == 1, 'missing source/plan')
    video = tokens(read('rtl/r2/c1_r2_video_camera_system.sv'))
    for fragment in ('assign cap_done_valid=camera_result_valid && camera_result_admitted;',
                     'wire cap_event=camera_result_valid,cap_bad=camera_result_failed;',
                     '.job_done(writer_done)', '.job_failed(writer_error || writer_drop)',
                     '.done_valid(writer_done),.done_ready(1\'b1)', '.cancel(source_cancel)',
                     '.cap_done_valid(cap_done_valid),.cap_done_bad(cap_bad)',
                     'c1_cdc_latest_snapshot #(.WIDTH(81))', '.dst_data(camera_snapshot)',
                     '.psel(psel && !camera_page)', '(!camera_legal || pwrite)',
                     'if(!camera_result_admitted)camera_unadmitted<=camera_unadmitted+1;'):
        need(tokens(fragment) in video, 'missing final ownership/snapshot/CSR fence')
    for name in ('u_cpu_adapter', 'u_control_bridge'):
        def instance(s):
            return re.search(r'\b'+name+r'\s*\(.*?\);', s, re.S).group()
        need(tokens(instance(read('rtl/r2/c1_r2_camera_host_system.sv'))) ==
             tokens(instance(read('rtl/r2/c1_r2_resize_host_system.sv'))), 'changed retained host adapter '+name)
    def infer(path):
        tree=ast.parse(read(path))
        return ast.dump(next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'infer'))
    need(infer('golden/r2_camera_plan_vectors.py') == infer('golden/r2_resize_plan_vectors.py'), 'changed independent CNN oracle')
    need('resize_bilinear_q16_u8(source[ry:ry+rh,rx:rx+rw],width,height)' in read('golden/r2_camera_plan_vectors.py'), 'missing crop/Resize golden')
    return dict(production_sources=44,retained_c24=True,actual_camera_host=True,physical_cdc_verified=False)


def run(text, profile='microstyle24', prefix=P):
    c24.clean(text)
    p=one(text,'PASS',prefix);plan=one(text,'PLAN',prefix);cam=one(text,'CAMERA',prefix);csr=one(text,'CAMERA_CSR',prefix)
    w,h=p['width'],p['height'];native=(w,h)==(640,480)
    fs=rows(text,'FRAME',prefix);starts=rows(text,'NN_START',prefix);caps=rows(text,'CAPTURE',prefix)
    results=rows(text,'CAMERA_RESULT',prefix);sofs=rows(text,'SOURCE_SOF',prefix);req=rows(text,'REQUEST',prefix)
    failed=rows(text,'FAILED',prefix);fault=prefix==F
    need(len(failed)==int(fault), 'wrong failed frame count')
    stage_count=22 if profile=='microstyle24' else 18
    need(tuple(plan[k] for k in ('stage_count','rgb_stage','actual_generated_plan')) == (stage_count,stage_count-2,1), 'wrong actual plan')
    need(len(fs)==len(starts)==p['cnn_frames']==6, 'missing six real CNN completions')
    b=c24.c18.budget(profile,w,h)
    for f in fs:
        need((f['width'],f['height'],f['stalls'])==(w,h,p['stalls']), 'mixed frame shape')
        need(tuple(f[k] for k in ('read_beats','write_beats','producers','commits')) ==
             (b['reads'],b['writes'],b['features'],stage_count), 'wrong actual CNN traffic/commits')
        need(f['cycles']>max(b['reads'],b['writes'],(b['macs']+95)//96), 'impossible compute cycles')
    need([s['job'] for s in starts]==list(range(1,7)), 'missing/duplicate starts')
    tags=[f['tag'] for f in fs]
    need(tags[0]==0 and all(b>a for a,b in zip(tags,tags[1:])), 'non-fresh CNN tags')
    need(p['native_timing']==int(native) and all(p[k]==1 for k in
         ('actual_capture_only','rgbx32','cpu_adapter','fresh_leases','host_shell','planned_graph')), 'wrong implementation scope')
    need(p['underflow']==p['display_misses']==0 and p['good_pixels']==2*w*h*p['displays'] and p['displays']>=6, 'display failure/accounting')
    need(p['cpu_r']>0 and p['cpu_w']>0 and 1<p['peak_r']<=8 and 0<p['peak_w']<=8 and p['apb_checks']==9, 'missing CPU/credits')
    host=one(text,'HOST',prefix);ids=one(text,'IDS',prefix)
    need(host['apb_bits']==16 and host['checks']==13 and host['irq_level_verified']==host['high_alias_rejected']==1, 'host ABI check missing')
    need(ids['reads']>1 and ids['writes']>1 and ids['restored_bits']==8, 'missing actual CPU IDs')
    n=len(sofs);expected_tags=list(range(n));bad_tags={1} if fault else set()
    need(n==cam['frames']==len(results)==p['captures']+int(fault) and n>=6, 'missing source/final-result accounting')
    need([s['tag'] for s in sofs]==[r['tag'] for r in results]==expected_tags, 'source/result provenance changed')
    need(len(caps)==p['captures'] and [c['tag'] for c in caps]==[i for i in expected_tags if i not in bad_tags], 'bad capture published')
    source_period=2475000 if native else (w*h*25+4000)//2
    need(p['camera_period']==(5000495 if native else 2*source_period), 'wrong nominal camera period summary')
    need(cam['source_sof_cycles']==source_period and all(b['camera_cycle']-a['camera_cycle']==source_period for a,b in zip(sofs,sofs[1:])), 'source waited for downstream/cadence changed')
    for sof in sofs:
        if native:
            # Real independent clocks rounded to 1ps; do not inherit C18's 5M cycle fiction.
            delta=(sof['camera_cycle']-sofs[0]['camera_cycle'])*13.468/6.666
            need(abs(sof['core_cycle']-sofs[0]['core_cycle']-delta)<=1, 'source/core clock mapping wrong')
        else:
            need(sof['core_cycle']-sofs[0]['core_cycle']==2*(sof['camera_cycle']-sofs[0]['camera_cycle']), 'small async clock mapping wrong')
    unadmitted=1 if fault and failed[0]['mode']==1 else 0
    need([r['tag'] for r in req]==[i for i in expected_tags if not (i==1 and unadmitted)] and all(r['ready']==1 for r in req), 'unmatched actual admission')
    req_by_tag={r['tag']:r for r in req};cap_by_tag={c['tag']:c for c in caps}
    for r,sof in zip(results,sofs):
        bad=r['tag'] in bad_tags
        need(r['failed']==int(bad) and r['admitted']==int(not (bad and unadmitted)), 'wrong result admission/failure')
        if not bad:
            c=cap_by_tag[r['tag']]
            need(r['code']==0 and r['cycle']==c['cycle'] and sof['core_cycle']<req_by_tag[r['tag']]['cycle']<r['cycle'] and c['words']==w*h//4,
                 'capture published before final ingress fence')
        else:
            f=failed[0]
            need(tuple(r[k] for k in ('tag','admitted','code','cycle'))==tuple(f[k] for k in ('tag','admitted','code','cycle')),
                 'final camera error and lease-failure observation disagree')
    sw,sh,rx,ry,rw,rh=camera_geometry(w,h)
    last_pixel=((sw+(280 if native else 4))*(sh-1)+sw-1)*(13.468/6.666 if native else 2)
    for r,sof in zip(results,sofs):
        if not r['failed']:
            need(r['cycle']-sof['core_cycle']>last_pixel, 'good frame published before full source EOF')
    extra=failed[0]['roi_pixels'] if fault else 0
    need(cam['source_pixels']==n*sw*sh and cam['roi_pixels']==p['captures']*rw*rh+extra and cam['destination_pixels']==p['captures']*w*h,
         'source/ROI/Resize pixel counts disagree')
    need(0<cam['peak']<=512 and cam['source_backpressure_allowed']==0 and cam['actual_roi']==1, 'wrong actual camera capacity/scope')
    need(csr['checks']==44 and csr['readonly']==csr['upper_alias_rejected']==csr['coherent_snapshot']==1 and csr['results']==n and csr['rejected_before_lease']==unadmitted, 'camera APB/telemetry mismatch')
    ends=[]
    for s,f in zip(starts,fs):
        need(s['tag']==f['tag'] and s['tag'] not in bad_tags and s['cycle']>cap_by_tag[s['tag']]['cycle'], 'CNN consumed unfinished/failed capture')
        if ends:need(s['cycle']>=ends[-1], 'overlapping CNN jobs')
        ends.append(s['cycle']+f['cycles']+1)
    intervals=[b-a for a,b in zip(ends,ends[1:])]
    need(intervals[-1]==p['nn_interval'], 'summary interval not actual completions')
    if native:
        commits=rows(text,'STAGE',prefix)
        need(len(commits)==6*stage_count, 'native stage trace incomplete')
        for f in fs:
            rr=[r for r in commits if r['tag']==f['tag']]
            need([r['stage'] for r in rr]==list(range(stage_count)) and rr[-1]['words']==f['write_beats'] and rr[-1]['cycles']==f['cycles'], 'native actual layer commit mismatch')
    if fault:
        f=failed[0];rec=one(text,'RECOVERY',prefix)
        need(f['tag']==1 and f['mode'] in (1,2,3,4) and f['admitted']==1-unadmitted and f['code']==(5 if f['mode'] in (1,2) else 4) and f['capture_debt']==0, 'wrong source fault/drain')
        need(f['held_cycles']==(64 if f['mode'] in (2,3) else 0), 'fault lacks real B hold')
        need(rec['mode']==f['mode'] and rec['failed_captures']==rec['error_irq']==rec['failed_front_forbidden']==1 and rec['reset_used']==0, 'missing error/recovery')
        need(rec['held_cycles']==f['held_cycles'], 'recovery summary differs from actual held B fault')
        need(rec['post_fault_nn']==sum(e>f['cycle'] for e in ends) and rec['post_fault_starts']==sum(s['cycle']>f['cycle'] for s in starts) and rec['post_fault_starts']>=2, 'no new good jobs after fault')
        fronts=rows(text,'FRONT',prefix)
        need(fronts and all(x['tag'] in cap_by_tag and x['tag']!=1 for x in fronts), 'failed capture reached actual FRONT')
        if f['mode'] in (1,4):need(f['writes']==f['roi_pixels']==0, 'pre-stream rejection consumed data')
    return dict(width=w,height=h,stalls=p['stalls'],captures=p['captures'],cnn_frames=6,display_pixels=p['good_pixels'],
                source_frames=n,source_pixels=cam['source_pixels'],roi_pixels=cam['roi_pixels'],peak=cam['peak'],
                completion_cycles=ends,completion_intervals=intervals,fault_mode=failed[0]['mode'] if fault else 0)


def matrix(text, profile):
    need(text.count(P+'CLEAN temporary_vectors_and_simulator_removed=1')==1, 'matrix private cleanup missing')
    rr=[run(t,profile) for t in c24.groups(text,P)]
    need(len(rr)==4 and {(r['width'],r['height'],r['stalls']) for r in rr}=={(w,w,s) for w in (8,32) for s in (0,1)}, 'missing matrix profile')
    return dict(profile=profile,configs=4,cnn_frames=24,good_display_pixels=sum(r['display_pixels'] for r in rr),source_pixels=sum(r['source_pixels'] for r in rr))


def faults(text):
    need(text.count(F+'CLEAN temporary_vectors_and_simulator_removed=1')==1, 'fault cleanup missing')
    rr=[run(t,prefix=F) for t in c24.groups(text,F)]
    need(len(rr)==8 and {(r['fault_mode'],r['stalls']) for r in rr}=={(f,s) for f in (1,2,3,4) for s in (0,1)}, 'missing full-host fault profile')
    return dict(configs=8,failed_source_frames=8,correct_cnn_frames=48,post_fault_new_jobs=40,reset_used=False)


def xsim(run_id, native=False):
    folder=Path('logs/r2_camera_host_xsim_runs')/run_id
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False, 'xsim unfinished/failed/not isolated')
    need(not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim private files remain')
    expected=(640,480,0,0,6,2,20) if native else (12,12,1,2,6,2,20)
    need(tuple(s[k] for k in ('width','height','stalls','aw_wait_w','nn_target','memory_div','command_latency'))==expected and s['camera_backpressure_allowed'] is False and s['actual_roi'] is True, 'wrong xsim camera/load profile')
    text=read(folder/'result.log');result=run(text)
    meta=json.loads(read(folder/'metadata.json'))
    need(meta['actual_roi'] is True and meta['unstoppable_source'] is True and meta['actual_resize_golden'] is True, 'missing actual camera fixtures')
    package=c24.c18.compile_package(c24.c18.profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv')==package.plan_sv and json.loads(read(folder/'plan_manifest.json'))==json.loads(json.dumps(package.manifest)), 'wrong actual xsim plan')
    return dict(run=run_id,seconds=s['elapsed_seconds'],**result,native_timing=native,board=False,physical_cdc_verified=False)


def physical():
    run_id='c26_camera_host96_map_20260913_a';folder=Path('logs/efinity_resource_runs')/run_id
    s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'summary.json'));x=m['metrics']
    need(s['state']==m['state']=='complete' and s['exit_code']==0 and m['flow']=='map', 'MAP failed/unfinished')
    need((x['le'],x['registers'],x['ebr'],x['dsp'])==(29285,20639,148,130), 'wrong measured full host resources')
    for name in ('u_ingress:c1_r2_camera_ingress','u_fifo:c1_r2_async_pixel_fifo','u_camera_snapshot:c1_cdc_latest_snapshot','u_capture:c1_r2_resize_capture_rgbx32','u_cnn:c1_r2_overlay_rgbx_axi_graph'):
        need(sum(name in r for r in x['module_rows'])==1, 'missing actual mapped child '+name)
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_camera_host96_'+run_id)
    need(not private.exists(), 'MAP private directory remains')
    return dict(lut4=x['le'],registers=x['registers'],ram=x['ebr'],dsp=x['dsp'],route_timing_verified=False,rough_platform_ram=253)


def detached_result(run_id, kind):
    folder=Path('logs/r2_camera_regression_runs')/run_id
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         s['test_kind']==kind and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),
         'detached regression incomplete/not isolated/unclean')
    need(not read(folder/'stderr.log').strip(), 'unexpected regression stderr')
    return read(folder/'result.log')


def runner_filter_gate(text):
    script=read('scripts/run_r2_camera_regression_detached.ps1')
    need("-cnotmatch '^C1_R2_CAMERA_HOST_SYSTEM_VECTORS '" in script and
         "-cmatch 'FATAL|ERROR:|Traceback|RuntimeError'" in script, 'runner lost exact/case-sensitive filtering')
    original=text.splitlines()
    old=[x for x in original if not re.search('_VECTORS',x,re.I)]
    fixed=[x for x in original if not re.search('^'+P+'VECTORS ',x)]
    is_clean=lambda x:x==F+'CLEAN temporary_vectors_and_simulator_removed=1'
    need(sum(map(is_clean,original))==sum(map(is_clean,fixed))==1 and sum(map(is_clean,old))==0,
         'runner CLEAN regression not reproduced/guarded')
    need(len(rows('\n'.join(old),'PASS',F))==len(rows('\n'.join(fixed),'PASS',F))==8, 'filter changed real RTL pass count')
    need(not re.search(r'FATAL|ERROR:|Traceback|RuntimeError', F+'RECOVERY error_irq=1'), 'normal IRQ record classified as failure')
    return dict(old_cleanup_lines=0,fixed_cleanup_lines=1,actual_rtl_passes=8,irq_marker_not_an_error=True)


def main():
    p=argparse.ArgumentParser();p.add_argument('--native-run');a=p.parse_args()
    emit=lambda n,v:print('C1_R2_C26_'+n+' '+json.dumps(v,separators=(',',':')),flush=True)
    emit('SOURCE_GATE_PASS',source_gate())
    normal=read('logs/r2_camera_host_matrix_20260913_a.log');variant=detached_result('c26_camera_variant_20260913_e','variant')
    emit('MATRIX_GATE_PASS',matrix(normal,'microstyle24'));emit('VARIANT_GATE_PASS',matrix(variant,'drop_res1'))
    bad=detached_result('c26_camera_faults_20260913_g','faults');emit('FAULT_GATE_PASS',faults(bad))
    emit('RUNNER_FILTER_GATE_PASS',runner_filter_gate(bad))
    emit('RAM_NEGATIVE_GATE_PASS',c24.c18.negative(read('logs/r2_camera_host_negative_20260913_a.log').replace(P,c24.c18.PREFIX)))
    emit('XSIM_GATE_PASS',xsim('c26_camera_host_xsim_12x12_20260913_a'));emit('MAP_GATE_PASS',physical())
    mutations=[('admitted=0','admitted=1'),('code=5','code=0'),('held_cycles=64','held_cycles=0'),('reset_used=0','reset_used=1'),
               ('readonly=1','readonly=0'),('post_fault_starts=5','post_fault_starts=1')]
    for old,new in mutations:
        need(old in bad,'missing fault mutation fixture')
        try:faults(bad.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('corrupt camera-host evidence accepted: '+old)
    emit('AUDIT_NEGATIVE_PASS',dict(rejected=len(mutations)))
    if a.native_run:emit('NATIVE_GATE_PASS',xsim(a.native_run,True))
    emit('PASS',dict(camera_host_integrated=True,native_cnn_fps_claimed=False,board=False,physical_cdc_verified=False))


if __name__=='__main__':main()
