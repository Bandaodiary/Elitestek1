"""C31 actual RGB2/decimation host evidence; no inherited C26/C29 FPS."""
import argparse
import json
import re
from pathlib import Path
import check_r2_demo_rgb2_evidence as c30
import check_r2_camera_host_evidence as c26
from run_r2_rgb2_host_probe import ROOT,SOURCES,PLAN_SOURCE
from run_r2_camera_capacity_host_probe import SOURCES as OLD_SOURCES
from r2_camera_plan_vectors import camera_geometry
from r2_native_performance_contract import assess_intervals,elaborated_configuration
from r2_camera_cadence_contract import profile as camera_config
c24=c26.c24
need=c30.need
read=c30.read
norm=c30.norm
P='C1_R2_RGB2_HOST_SYSTEM_'
F='C1_R2_RGB2_HOST_FAULT_'
rows=c26.rows
one=c26.one


def source_gate():
    c30.source_gate()
    rename={
        'rtl/r2/c1_r2_camera_capacity_host_system.sv':'rtl/r2/c1_r2_rgb2_host_system.sv',
        'rtl/r2/c1_r2_video_camera_capacity_system.sv':'rtl/r2/c1_r2_video_rgb2_system.sv',
        'rtl/r2/c1_r2_camera_ingress_guarded.sv':'rtl/r2/c1_r2_camera_decimated_ingress.sv',
        'rtl/video/c1_r1_resize_system.sv':'rtl/r2/c1_r2_resize_overlap_system.sv',
        'rtl/r2/c1_r2_resize_pipeline.sv':'rtl/r2/c1_r2_resize_overlap_pipeline.sv',
        'rtl/r2/c1_r2_resize_capture_rgbx32.sv':'rtl/r2/c1_r2_resize_overlap_capture.sv'}
    need(SOURCES==[rename.get(s,s) for s in OLD_SOURCES]+['rtl/r2/c1_r2_rgb2_raster_source.sv'] and len(set(SOURCES))==45,'unexpected production closure')
    a=read(ROOT/'rtl/r2/c1_r2_camera_pair_ingress.sv').replace('c1_r2_camera_pair_ingress','c1_r2_camera_decimated_ingress')
    a=a.replace('FRAME_TIMEOUT=5000000,AW=','FRAME_TIMEOUT=5000000,FRAME_DIVISOR=2,AW=')
    a=a.replace('localparam TW=', 'localparam integer DW=FRAME_DIVISOR<=1 ? 1 : $clog2(FRAME_DIVISOR); logic [DW-1:0] frame_phase; localparam TW=')
    a=a.replace('FRAME_TIMEOUT>=2;','FRAME_TIMEOUT>=2 && FRAME_DIVISOR>=1 && FRAME_DIVISOR<=256;')
    a=a.replace('!cancel_sync2 && GEOMETRY_OK;','!cancel_sync2 && GEOMETRY_OK && frame_phase==0;')
    a=a.replace('request_q<=0;ack_sync1','frame_phase<=0;request_q<=0;ack_sync1')
    a=a.replace('if(cam_valid && cam_sof)begin',"if(cam_valid && cam_sof)begin frame_phase<=frame_phase==FRAME_DIVISOR-1 ? 0 : frame_phase+1'b1;")
    need(norm(a)==norm(read(ROOT/'rtl/r2/c1_r2_camera_decimated_ingress.sv')),'unplanned pair ingress change')
    for old,new in (('c1_r2_camera_capacity_host_system','c1_r2_rgb2_host_system'),('c1_r2_video_camera_capacity_system','c1_r2_video_rgb2_system')):
        a=read(ROOT/f'rtl/r2/{old}.sv').replace(old,new)
        a=a.replace('CAMERA_FIFO=512,FRAME_TIMEOUT=5000000,','CAMERA_FIFO=512,FRAME_TIMEOUT=5000000,FRAME_DIVISOR=2,')
        a=a.replace('input wire cam_clk,cam_rst,cam_valid,cam_sof,cam_eol,cam_eof,cam_error,\n    input wire [23:0] cam_rgb,',
                    'input wire cam_clk,cam_rst,cam_valid,cam_vs,cam_de,cam_error,\n    input wire [47:0] cam_rgb,')
        if old=='c1_r2_camera_capacity_host_system':
            a=a.replace('c1_r2_video_camera_capacity_system','c1_r2_video_rgb2_system')
            a=a.replace('.CAMERA_FIFO(CAMERA_FIFO),.FRAME_TIMEOUT(FRAME_TIMEOUT)', '.CAMERA_FIFO(CAMERA_FIFO),.FRAME_TIMEOUT(FRAME_TIMEOUT),.FRAME_DIVISOR(FRAME_DIVISOR)')
            a=a.replace('.cam_sof(cam_sof),.cam_eol(cam_eol),.cam_eof(cam_eof)','.cam_vs(cam_vs),.cam_de(cam_de)')
        else:
            a=a.replace('c1_r2_camera_ingress_guarded #(','''wire pair_valid,pair_sof,pair_eol,pair_eof,raster_error;
    wire [47:0] pair_rgb;
    c1_r2_rgb2_raster_source #(.SOURCE_WIDTH(SOURCE_WIDTH),.SOURCE_HEIGHT(SOURCE_HEIGHT)) u_raster (
        .clk(cam_clk),.rst(cam_rst),.in_vs(cam_vs),.in_de(cam_de),.in_valid(cam_valid),.in_rgb(cam_rgb),
        .pair_valid(pair_valid),.pair_sof(pair_sof),.pair_eol(pair_eol),.pair_eof(pair_eof),
        .pair_error(raster_error),.pair_rgb(pair_rgb));
    c1_r2_camera_decimated_ingress #(''')
            a=a.replace('.FIFO_DEPTH(CAMERA_FIFO),.FRAME_TIMEOUT(FRAME_TIMEOUT))','.FIFO_DEPTH(CAMERA_FIFO),.FRAME_TIMEOUT(FRAME_TIMEOUT),.FRAME_DIVISOR(FRAME_DIVISOR))')
            a=a.replace('.cam_valid(cam_valid),.cam_sof(cam_sof),.cam_eol(cam_eol),.cam_eof(cam_eof)', '.cam_valid(pair_valid),.cam_sof(pair_sof),.cam_eol(pair_eol),.cam_eof(pair_eof)')
            a=a.replace('.cam_error(cam_error),.cam_rgb(cam_rgb)','.cam_error(cam_error || raster_error),.cam_rgb(pair_rgb)')
            a=a.replace('c1_r2_resize_capture_rgbx32','c1_r2_resize_overlap_capture')
            a=a.replace("32'h52324331","32'h52324332")
            a=a.replace("8'hb4:camera_prdata=CAMERA_FIFO;", "8'hb4:camera_prdata=CAMERA_FIFO; 8'hb8:camera_prdata=32'h01310201; 8'hbc:camera_prdata=FRAME_DIVISOR;")
        need(norm(a)==norm(read(ROOT/f'rtl/r2/{new}.sv')),'unplanned host/control/fabric change '+new)
    a=read(ROOT/'efinity/c1_ti60_r2_camera_capacity96.sdc').replace('13.468','14.286')
    need(a.strip()==read(ROOT/'efinity/c1_ti60_r2_rgb2_host96.sdc').strip(),'unexpected clock/CDC exception change')
    print('C31_SOURCE_PASS retained_c29_c30=1 production_sources=45 new_modules=3 old_compute_and_fabric=1')


def run(text, profile='microstyle24', prefix=P, expected_nn=6, clock_native_override=None, model_budget=None,
        camera_profile='legacy'):
    c24.clean(text)
    p=one(text,'PASS',prefix);plan=one(text,'PLAN',prefix);cam=one(text,'CAMERA',prefix);csr=one(text,'CAMERA_CSR',prefix)
    rgb2=one(text,'RGB2',prefix);div=rgb2['frame_divisor']
    need(div in (1,2,3) and all(rgb2[k]==v for k,v in dict(source_pixels_per_word=2,fifo_record_bits=49,fifo_unit=1,actual_vs_de=1).items()),'wrong RGB2 ABI/selection')
    w,h=p['width'],p['height'];native=(w,h)==(640,480)
    cadence=camera_config(camera_profile)
    if camera_profile!='legacy':
        need(native and prefix=='C1_R2_FUSED_RGB2_HOST_SYSTEM_' and profile=='c36_trained_student',
             'new camera profile is restricted to explicit native trained-host runs')
        need(div==cadence['frame_divisor'],'wrong new-profile frame admission')
    clock_native=native if clock_native_override is None else clock_native_override
    if clock_native_override is not None:
        need(not native and clock_native_override in (0,1),'clock override is only for explicit small startup diagnostics')
        startup=one(text,'CPU_START',prefix)
        need(startup['native_clocks']==int(clock_native) and startup['active']==startup['full_core_pulse']==1,'startup clock/pulse evidence missing')
    fs=rows(text,'FRAME',prefix);starts=rows(text,'NN_START',prefix);caps=rows(text,'CAPTURE',prefix)
    results=rows(text,'CAMERA_RESULT',prefix);sofs=rows(text,'SOURCE_SOF',prefix);req=rows(text,'REQUEST',prefix)
    failed=rows(text,'FAILED',prefix);fault=prefix==F
    need(len(failed)==int(fault), 'wrong failed frame count')
    # The explicit model-budget hook extends only graph counts, not any of the
    # camera/CPU/AXI/display/ownership checks. Legacy calls keep their old path.
    b=c24.c18.budget(profile,w,h) if model_budget is None else model_budget(profile,w,h)
    stage_count=(22 if profile=='microstyle24' else 18) if model_budget is None else b['stages']
    need(tuple(plan[k] for k in ('stage_count','rgb_stage','actual_generated_plan')) == (stage_count,stage_count-2,1), 'wrong actual plan')
    need(len(fs)==len(starts)==p['cnn_frames']==expected_nn, 'missing required real CNN completions')
    for f in fs:
        need((f['width'],f['height'],f['stalls'])==(w,h,p['stalls']), 'mixed frame shape')
        need(tuple(f[k] for k in ('read_beats','write_beats','producers','commits')) ==
             (b['reads'],b['writes'],b['features'],stage_count), 'wrong actual CNN traffic/commits')
        need(f['cycles']>max(b['reads'],b['writes'],(b['macs']+95)//96), 'impossible compute cycles')
    need([s['job'] for s in starts]==list(range(1,expected_nn+1)), 'missing/duplicate starts')
    tags=[f['tag'] for f in fs]
    need(tags[0]==0 and all(b>a for a,b in zip(tags,tags[1:])), 'non-fresh CNN tags')
    need(p['native_timing']==int(native) and all(p[k]==1 for k in
         ('actual_capture_only','rgbx32','cpu_adapter','fresh_leases','host_shell','planned_graph')), 'wrong implementation scope')
    need(p['underflow']==p['display_misses']==0 and p['good_pixels']==2*w*h*p['displays'] and p['displays']>=expected_nn, 'display failure/accounting')
    need(p['cpu_r']>0 and p['cpu_w']>0 and 1<p['peak_r']<=8 and 0<p['peak_w']<=8 and p['apb_checks']==9, 'missing CPU/credits')
    host=one(text,'HOST',prefix);ids=one(text,'IDS',prefix)
    need(host['apb_bits']==16 and host['checks']==13 and host['irq_level_verified']==host['high_alias_rejected']==1, 'host ABI check missing')
    need(ids['reads']>1 and ids['writes']>1 and ids['restored_bits']==8, 'missing actual CPU IDs')
    n=len(sofs);expected_tags=list(range(n));bad_tags={div} if fault else set()
    need(n==cam['frames']==rgb2['source_frames'] and len(results)==p['captures']+int(fault) and n>=expected_nn, 'missing source/final-result accounting')
    need(n-len(results)==rgb2['skipped'],'skipped source frame accounting')
    eligible=[i for i in expected_tags if i%div==0]
    need([s['tag'] for s in sofs]==expected_tags and [r['tag'] for r in results]==eligible, 'source/result/decimation provenance changed')
    need(len(caps)==p['captures'] and [c['tag'] for c in caps]==[i for i in eligible if i not in bad_tags], 'bad capture published')
    source_period=cadence['source_period_camera_cycles'] if native else (w*h*25+4000)//4
    need(p['camera_period']==(cadence['camera_period_summary'] if native else 4*source_period), 'wrong nominal camera period summary')
    need(rgb2['source_period_camera_cycles']==source_period,'RGB2 source period disagrees with requested cadence')
    need(cam['source_sof_cycles']==source_period and all(b['camera_cycle']-a['camera_cycle']==source_period for a,b in zip(sofs,sofs[1:])), 'source waited for downstream/cadence changed')
    for sof in sofs:
        if clock_native:
            # Real independent clocks rounded to 1ps; do not inherit C18's 5M cycle fiction.
            delta=(sof['camera_cycle']-sofs[0]['camera_cycle'])*14.286/6.666
            need(abs(sof['core_cycle']-sofs[0]['core_cycle']-delta)<=1, 'source/core clock mapping wrong')
        else:
            need(sof['core_cycle']-sofs[0]['core_cycle']==2*(sof['camera_cycle']-sofs[0]['camera_cycle']), 'small async clock mapping wrong')
    unadmitted=1 if fault and failed[0]['mode']==1 else 0
    need([r['tag'] for r in req]==[i for i in eligible if not (i==div and unadmitted)] and all(r['ready']==1 for r in req), 'unmatched actual admission')
    req_by_tag={r['tag']:r for r in req};cap_by_tag={c['tag']:c for c in caps}
    for r in results:
        sof=sofs[r['tag']]
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
    line_blank=106 if native else w+4
    # VS after front porch is the final-source fence; measure from first DE.
    vs_delta=source_period-(2+20)*(sw//2+106)-46 if native else source_period-4-line_blank//2
    last_pixel=(vs_delta-1)*(14.286/6.666 if clock_native else 2)
    for r in results:
        sof=sofs[r['tag']]
        if not r['failed']:
            need(r['cycle']-sof['core_cycle']>last_pixel, 'good frame published before full source EOF')
    extra=failed[0]['roi_pixels'] if fault else 0
    need(cam['source_pixels']==n*sw*sh and cam['roi_pixels']==p['captures']*rw*rh+extra and cam['destination_pixels']==p['captures']*w*h,
         'source/ROI/Resize pixel counts disagree')
    need(0<cam['peak']<=512 and cam['source_backpressure_allowed']==0 and cam['actual_roi']==1, 'wrong actual camera capacity/scope')
    need(csr['checks']==48 and csr['readonly']==csr['upper_alias_rejected']==csr['coherent_snapshot']==1 and csr['results']==len(results) and csr['rejected_before_lease']==unadmitted, 'camera APB/telemetry mismatch')
    ends=[]
    for s,f in zip(starts,fs):
        need(s['tag']==f['tag'] and s['tag'] not in bad_tags and s['cycle']>cap_by_tag[s['tag']]['cycle'], 'CNN consumed unfinished/failed capture')
        if ends:need(s['cycle']>=ends[-1], 'overlapping CNN jobs')
        ends.append(s['cycle']+f['cycles']+1)
    intervals=[b-a for a,b in zip(ends,ends[1:])]
    need(intervals[-1]==p['nn_interval'], 'summary interval not actual completions')
    if native:
        commits=rows(text,'STAGE',prefix)
        need(len(commits)==expected_nn*stage_count, 'native stage trace incomplete')
        for f in fs:
            rr=[r for r in commits if r['tag']==f['tag']]
            need([r['stage'] for r in rr]==list(range(stage_count)) and rr[-1]['words']==f['write_beats'] and rr[-1]['cycles']==f['cycles'], 'native actual layer commit mismatch')
    if fault:
        f=failed[0];rec=one(text,'RECOVERY',prefix)
        need(f['tag']==div and f['mode'] in (1,2,3,4) and f['admitted']==1-unadmitted and f['code']==(5 if f['mode'] in (1,2) else 4) and f['capture_debt']==0, 'wrong source fault/drain')
        need(f['held_cycles']==(64 if f['mode'] in (2,3) else 0), 'fault lacks real B hold')
        need(rec['mode']==f['mode'] and rec['failed_captures']==rec['error_irq']==rec['failed_front_forbidden']==1 and rec['reset_used']==0, 'missing error/recovery')
        need(rec['held_cycles']==f['held_cycles'], 'recovery summary differs from actual held B fault')
        need(rec['post_fault_nn']==sum(e>f['cycle'] for e in ends) and rec['post_fault_starts']==sum(s['cycle']>f['cycle'] for s in starts) and rec['post_fault_starts']>=2, 'no new good jobs after fault')
        fronts=rows(text,'FRONT',prefix)
        need(fronts and all(x['tag'] in cap_by_tag and x['tag']!=div for x in fronts), 'failed capture reached actual FRONT')
        if f['mode'] in (1,4):need(f['writes']==f['roi_pixels']==0, 'pre-stream rejection consumed data')
    return dict(width=w,height=h,stalls=p['stalls'],captures=p['captures'],cnn_frames=expected_nn,display_pixels=p['good_pixels'],
                source_frames=n,source_pixels=cam['source_pixels'],roi_pixels=cam['roi_pixels'],peak=cam['peak'],
                completion_cycles=ends,completion_intervals=intervals,fault_mode=failed[0]['mode'] if fault else 0)


def finished(folder):
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0,'run not complete '+folder.name)
    need(s.get('worker_in_windows_job') is False,'Job isolation not proven')
    need(s['simulator_directory_present'] is False and not Path(s['run_directory']).exists(),'private simulator directory still present')
    need(not (folder/'interruption.json').exists(),'interrupted run cannot be accepted')
    return s,read(folder/'result.log')


def xsim_gate(name,native=False):
    folder=ROOT/'logs/r2_rgb2_host_xsim_runs'/name
    status,text=finished(folder)
    meta=json.loads(read(folder/'metadata.json'))
    need(meta['source_pixels_per_word']==2 and meta['actual_vs_de'] is True,'actual source metadata')
    override=status.get('clocks_native',-1)
    result=run(text,meta['profile'],clock_native_override=(override if not native and override!=-1 else None))
    rgb2=one(text,'RGB2',P)
    need(rgb2['frame_divisor']==status['frame_divisor']==meta['frame_divisor'],'frame admission configuration differs')
    need(((result['width'],result['height'])==(640,480))==native,'wrong native/small run selection')
    if native:
        need(status['native_timing'] is True and status['nn_target']==6,'native configuration incomplete')
        need(status.get('clocks_native',-1) in (-1,1) and status.get('cpu_start_negative',0)==0,'native clock/start configuration invalid')
        startup=one(text,'CPU_START',P);early=one(text,'CPU_EARLY',P)
        need(startup['native_clocks']==startup['active']==startup['full_core_pulse']==1 and early['reads']>=2 and early['writes']>=2,'native CPU startup/early traffic missing')
        result.update(assess_intervals(result['completion_intervals']))
        result['ddr_model']=elaborated_configuration(read(folder/'xelab.tail.log'),status,meta)
    result.update(run=name,seconds=status['elapsed_seconds'],native=native,board=False,physical_cdc_signoff=False)
    print('C31_'+('NATIVE' if native else 'XSIM')+'_PASS '+json.dumps(result,separators=(',',':')))


def regression_gate(name,kind):
    folder=ROOT/'logs/r2_rgb2_regression_runs'/name
    status,text=finished(folder)
    need(status['test_kind']==kind,'wrong regression kind')
    prefix=F if kind=='faults' else P
    need(text.count(prefix+'CLEAN temporary_vectors_and_simulator_removed=1')==1,'temporary vectors not cleaned')
    if kind=='negative':
        rr=rows(text,'NEGATIVE_PASS',P)
        need(len(rr)==8 and {(r['width'],r['height'],r['stalls'],r['corruption']) for r in rr}=={(w,w,s,c) for w in (8,32) for s in (0,1) for c in (1,2)},'RAM negative matrix incomplete')
        need(all(r['actual_ram_mutation']==1 for r in rr),'not actual RAM corruption')
        print('C31_RAM_NEGATIVE_PASS actual_ram_corruptions=8');return
    groups=c24.groups(text,prefix)
    rr=[run(t,'drop_res1' if kind=='variant' else 'microstyle24',prefix,2 if kind=='smoke' else 6) for t in groups]
    if kind=='faults':
        need(len(rr)==8 and {(r['fault_mode'],r['stalls']) for r in rr}=={(f,s) for f in (1,2,3,4) for s in (0,1)},'fault matrix missing')
    elif kind=='smoke':need(len(rr)==1 and rr[0]['width']==8 and rr[0]['stalls']==1,'smoke scope')
    else:need(len(rr)==4 and {(r['width'],r['height'],r['stalls']) for r in rr}=={(w,w,s) for w in (8,32) for s in (0,1)},'matrix scope')
    need(all(one(t,'RGB2',prefix)['frame_divisor']==status['frame_divisor'] for t in groups),'declared/actual frame divisor mismatch')
    print('C31_REGRESSION_PASS '+json.dumps(dict(kind=kind,run=name,configurations=len(rr),cnn_frames=sum(r['cnn_frames'] for r in rr),display_pixels=sum(r['display_pixels'] for r in rr),source_pixels=sum(r['source_pixels'] for r in rr)),separators=(',',':')))


def negative_evidence():
    _,text=finished(ROOT/'logs/r2_rgb2_host_xsim_runs/c31_rgb2_xsim_12x12_20260914_b')
    changes=(('frame_divisor=2','frame_divisor=1'),('source_pixels_per_word=2','source_pixels_per_word=1'),
             ('checks=48','checks=44'),('skipped=20','skipped=0'),('commits=22','commits=21'),
             ('fifo_unit=1','fifo_unit=0'))
    for old,new in changes:
        need(old in text,'ineffective evidence mutation')
        try:run(text.replace(old,new,1))
        except (AssertionError,ValueError,KeyError):pass
        else:raise AssertionError('corrupt evidence accepted '+old)
    print('C31_EVIDENCE_NEGATIVE_PASS mutations=6 actual_source_and_CNN_accounting=1')


def physical_gate(run_id):
    folder,s=c30.c29.c27.run(run_id)
    mapped=c30.c29.map_gate(run_id)
    sta=read(folder/'cdc_sta.stdout.log')
    need(len(re.findall(r'^C27_MATCH .* expected=',sta,re.M))==16 and '\nC27_AUDIT_PASS\n' in sta, 'post-route pin checks incomplete')
    timing={}
    prefix='u_host/u_system/'
    camera_ends={f'{prefix}u_ingress/u_fifo/wr_sync1[{i}]~FF|D' for i in range(10)}
    camera_ends|={prefix+'u_ingress/'+x+'~FF|D' for x in ('req_sync1','done_sync1','bad_sync1')}
    camera_ends|={prefix+'u_camera_snapshot/req_sync1_q~FF|D'}
    dest_rx=r'^(?:u_host/u_system/capture_tag|u_host/u_system/u_ingress/failed_code|camera_result_code|camera_seen|camera_skipped|camera_fifo_peak|u_host/u_system/camera_snapshot)\[\d+\]~FF$'
    camera_ends|={n+'|D' for n in mapped if re.match(dest_rx,n)}
    core_ends={f'{prefix}u_ingress/u_fifo/rd_sync1[{i}]~FF|D' for i in range(10)}
    core_ends|={prefix+'u_ingress/'+x+'~FF|D' for x in ('ack_sync1','enable_sync1','cancel_sync1')}
    core_ends|={prefix+'u_camera_snapshot/ack_sync1_q~FF|D'}
    for stem in ('u_host/u_system/u_ingress/source_tag','u_host/u_system/capture_tag'):
        bits={int(re.search(r'\[(\d+)\]',n)[1]) for n in mapped if n.startswith(stem+'[')}
        need(bits==set(range(1,32)),'divisor-2 tag CDC must retain exact bits 1..31')
    need(len(camera_ends)==126 and len(core_ends)==14,'expected endpoint inventory wrong')
    for name in ('core_setup','core_hold','camera_setup','camera_hold','camera_to_core','core_to_camera'):
        report=read(folder/('c27_'+name+'.rpt'))
        slacks=list(map(float,re.findall(r'^Slack\s*:\s*([-+\d.]+) ns',report,re.M)))
        delays=list(map(float,re.findall(r'^Data Path Delay\s*:\s*([-+\d.]+) ns',report,re.M)))
        need(slacks and len(slacks)==len(delays) and min(slacks)>=0, 'timing violation/missing report '+name)
        if name in ('camera_to_core','core_to_camera'):
            count=126 if name=='camera_to_core' else 14
            need(len(slacks)==count and max(delays)<5 and report.count('Timing Exception : Max Delay Path 5.000 ns')==count, 'missing/masked crossing')
            endpoints=re.findall(r'^Path End\s*:\s*(\S+)\s*$',report,re.M)
            need(len(endpoints)==count and set(endpoints)==(camera_ends if name=='camera_to_core' else core_ends), 'crossing endpoint identities changed')
            if name=='core_to_camera':
                need(set(re.findall(r'^Logic Levels\s*:\s*(\d+)',report,re.M))=={'0'}, 'combinational logic still before CDC first stage')
        timing[name]={'min_slack_ns':min(slacks),'max_data_delay_ns':max(delays),'paths':len(slacks)}
    bus=read(folder/'c27_bus_setup.rpt')
    skew=[tuple(map(float,r)) for r in re.findall(r'^\[get_pins .*\|\s*Slow\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([-+\d.]+)\s*$',bus,re.M)]
    need(len(skew)==2 and all(req==1 and actual<1 and slack>0 for req,actual,slack in skew), 'Gray skew not proven')
    bits={(direction,int(bit)) for direction,bit in re.findall(r'u_ingress/u_fifo/(wr|rd)_sync1\[(\d+)\]~FF\|D',bus)}
    need(bits=={(d,i) for d in ('wr','rd') for i in range(10)},'Gray skew omitted bits')
    resources=s['metrics']['pnr_resources']
    need(resources['memory_blocks_used']==145 and resources['dsp_blocks_used']==130, 'unexpected RAM/DSP footprint')
    classification=json.loads(read(folder/'cdc_classification_status.json'))
    print('C31_PNR_PASS '+json.dumps({'resources':resources,'timing':timing,'gray_setup_skew_ns':[v[1] for v in skew],
          'cdc_classification':classification,'physical_cdc_signoff':False},separators=(',',':')))



def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source-only',action='store_true')
    for name in ('xsim','matrix','variant','faults','negative','native','pnr'):
        p.add_argument('--'+name+'-run')
    a=p.parse_args();source_gate()
    if a.source_only:return
    software=read(ROOT/'logs/r2_c31_camera_software_20260914_b.log')
    for expected in (
        'C31_RGB2_CAMERA_SOFTWARE_PASS divisors=256 failures=9 output_unchanged_on_error=1 legacy_abi_rejected=1 records_not_pixels=1',
        'C31_RGB2_CAMERA_RISCV_COMPILE_PASS efinity_toolchain=1 isa=rv32imc abi=ilp32 elf32=1 mmio_fence=1 cpu_execution_claim=0',
        'C31_RGB2_CAMERA_SOFTWARE_CLEAN temporary_executable_removed=1'):
        need(software.splitlines().count(expected)==1,'software capability verification missing')
    print('C31_SOFTWARE_PASS host_unit_tests=1 efinity_rv32imc_compile=1 cpu_execution_claim=0')
    negative_evidence()
    if a.xsim_run:xsim_gate(a.xsim_run)
    for kind in ('matrix','variant','faults','negative'):
        name=getattr(a,kind+'_run')
        if name:regression_gate(name,kind)
    if a.native_run:xsim_gate(a.native_run,True)
    if a.pnr_run:physical_gate(a.pnr_run)
    print('C31_SELECTED_EVIDENCE_PASS completion_claim=0 board_claim=0')


if __name__=='__main__':main()
