"""C28 evidence: protected mapped synchronizers + real camera/host regressions.

No inherited C26 performance, no board sign-off, no hashes. Reuses the retained
numerical/timeline checker only after proving the C28 producer/source identity.
"""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
import check_r2_camera_host_evidence as c26
import check_r2_camera_physical_cdc as c27
from run_r2_camera_safe_host_probe import ROOT, SOURCES, PLAN_SOURCE
from run_r2_camera_host_probe import SOURCES as ORIGINAL_SOURCES

need, read = c27.need, c27.read
P = 'C1_R2_CAMERA_SAFE_HOST_SYSTEM_'
F = 'C1_R2_CAMERA_SAFE_HOST_FAULT_'
RENAMES = {
    'c1_r2_async_pixel_fifo': 'c1_r2_async_pixel_fifo_guarded',
    'c1_r2_camera_ingress': 'c1_r2_camera_ingress_guarded',
    'c1_cdc_latest_snapshot': 'c1_cdc_latest_snapshot_guarded',
    'c1_r2_video_camera_system': 'c1_r2_video_camera_safe_system',
    'c1_r2_camera_host_system': 'c1_r2_camera_safe_host_system',
}


def normalize_rtl(text):
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'\(\*.*?\*\)', '', text, flags=re.S)
    return re.sub(r'\s+', '', text)


def source_gate():
    c26.source_gate()
    transformed = [next((s.replace(a,b) for a,b in RENAMES.items() if a+'.sv' in s), s)
                   for s in ORIGINAL_SOURCES]
    need(len(SOURCES) == 44 and SOURCES == transformed and len(set(SOURCES)) == 44,
         'unexpected production closure delta')
    for original in ORIGINAL_SOURCES:
        replacement = next((s for s in SOURCES if Path(s).stem == RENAMES.get(Path(original).stem)), None)
        if replacement is None:
            continue
        old = read(ROOT/original)
        new = read(ROOT/replacement)
        for a,b in RENAMES.items():
            new = new.replace(b,a)
        actual = normalize_rtl(new)
        if original.endswith('c1_r2_camera_ingress.sv'):
            for contract in ('logicenable_source_q,cancel_source_q;',
                             'always_ff@(posedgeclk)beginif(rst)beginenable_source_q<=0;cancel_source_q<=0;endelsebeginenable_source_q<=enable;cancel_source_q<=source_cancel;endend',
                             'enable_sync1<=enable_source_q;', 'cancel_sync1<=cancel_source_q;'):
                need(actual.count(contract) == 1, 'source launch contract missing')
            actual = actual.replace('logicenable_source_q,cancel_source_q;', '').replace(
                'always_ff@(posedgeclk)beginif(rst)beginenable_source_q<=0;cancel_source_q<=0;endelsebeginenable_source_q<=enable;cancel_source_q<=source_cancel;endend','')
            actual = actual.replace('enable_sync1<=enable_source_q;', 'enable_sync1<=enable;').replace(
                'cancel_sync1<=cancel_source_q;', 'cancel_sync1<=source_cancel;')
            need('(* syn_keep="true" *) logic enable_source_q,cancel_source_q;' in new, 'unprotected source flops')
        need(actual == normalize_rtl(old), 'unexpected functional RTL change '+replacement)
        if any(x in original for x in ('async_pixel_fifo', 'camera_ingress', 'cdc_latest_snapshot')):
            expected_attrs = 1 if 'fifo' in original else 3 if 'ingress' in original else 2
            need(new.count('(* async_reg="true", syn_keep="true" *)') == expected_attrs, 'missing synchronizer protection')
    script = read(ROOT/'scripts/run_r2_camera_safe_regression_detached.ps1')
    need("-cnotmatch '^"+P+"VECTORS '" in script and "-cmatch 'FATAL|ERROR:|Traceback|RuntimeError'" in script,
         'case-sensitive result filtering regressed')
    print('C28_SOURCE_PASS retained_c26=1 production_sources=44 new_modules=5 added_source_flops=2')


def check_mapped_text(text):
    mapped = c27.ff_blocks(text)
    prefix = 'u_host/u_system/'
    inventory = c27.fifo_inventory(text, prefix+'u_ingress/u_fifo')
    need(inventory['retimed_sync_ff'] == 0, 'FIFO CDC retiming persists')
    annotated = {n for n,v in mapped.items() if re.search('async_reg="true"',v['attrs'], re.I)}
    need(len(annotated) == 56 and all('~FF_rt_' not in n for n in annotated), 'wrong protected synchronizer inventory')
    controls = [
        ('u_ingress/', 'ack_sync1','ack_sync2','ack_q','cam_clk','clk'),
        ('u_ingress/', 'req_sync1','req_sync2','request_q','clk','cam_clk'),
        ('u_ingress/', 'enable_sync1','enable_sync2','enable_source_q','cam_clk','clk'),
        ('u_ingress/', 'cancel_sync1','cancel_sync2','cancel_source_q','cam_clk','clk'),
        ('u_ingress/', 'done_sync1','done_sync2','source_done','clk','cam_clk'),
        ('u_ingress/', 'bad_sync1','bad_sync2','source_bad','clk','cam_clk'),
        ('u_camera_snapshot/', 'req_sync1_q','req_sync2_q','request_q','clk','cam_clk'),
        ('u_camera_snapshot/', 'ack_sync1_q','ack_sync2_q','acknowledge_q','cam_clk','clk'),
    ]
    for stem,first,second,launch,dest_clock,source_clock in controls:
        a,b,s = [mapped[prefix+stem+n+'~FF']['pins'] for n in (first,second,launch)]
        need(a['D'] == s['Q'] and b['D'] == a['Q'] and
             a['CLK'] == b['CLK'] == dest_clock and s['CLK'] == source_clock,
             'non-register/incorrect control CDC connection '+first)
    return mapped


def map_gate(run_id):
    folder = ROOT/'logs/efinity_resource_runs'/run_id
    text=read(folder/'cdc_mapped_registers.txt')
    mapped=check_mapped_text(text)
    print('C28_MAPPED_CDC_STRUCTURE_PASS protected_sync_ff=56 retimed_sync_ff=0 registered_control_crossings=8')
    mutations=[
        text.replace('.D(\\u_host/u_system/u_ingress/cancel_source_q )', '.D(\\u_host/u_system/u_ingress/source_cancel )'),
        text.replace('.D(\\u_host/u_system/u_ingress/enable_source_q )', '.D(\\u_host/u_system/COMBINATIONAL_ENABLE )'),
        text.replace('u_fifo/wr_sync1[9]~FF','u_fifo/MISSING_MSB~FF'),
        text.replace('.D(\\u_host/u_system/u_ingress/u_fifo/rd_sync1 [0])', '.D(\\u_host/u_system/u_ingress/u_fifo/COMBINATIONAL [0])'),
    ]
    for changed in mutations:
        need(changed!=text, 'negative control did not mutate evidence')
        try:check_mapped_text(changed)
        except (AssertionError,KeyError):pass
        else:raise AssertionError('unsafe mapped CDC mutation accepted')
    print('C28_MAPPED_CDC_NEGATIVE_CONTROLS_PASS rejected=4')
    return mapped


def canonical(text):
    need(P in text or F in text, 'not C28 evidence')
    need(c26.P not in text and c26.F not in text, 'mixed C26/C28 provenance')
    return text.replace(P,c26.P).replace(F,c26.F)


def regression(run_id,kind):
    folder=ROOT/'logs/r2_camera_safe_regression_runs'/run_id
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0 and s['test_kind']==kind and
         s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and
         not Path(s['run_directory']).exists(), 'regression unfinished/not isolated/not clean '+run_id)
    need(not read(folder/'stderr.log').strip(), 'regression stderr')
    text=canonical(read(folder/'result.log'))
    if kind=='faults':
        result=c26.faults(text)
    elif kind=='negative':
        rr=c26.rows(text,'NEGATIVE_PASS')
        need(len(rr)==8 and {(r['width'],r['height'],r['stalls'],r['corruption']) for r in rr} ==
             {(w,w,s,c) for w in (8,32) for s in (0,1) for c in (1,2)} and
             all(r['actual_ram_mutation']==1 for r in rr), 'negative controls incomplete')
        result={'actual_ram_negative_controls':8}
    else:
        result=c26.matrix(text,'drop_res1' if kind=='variant' else 'microstyle24')
    print('C28_REGRESSION_PASS '+json.dumps({'kind':kind,'seconds':s['elapsed_seconds'],**result},separators=(',',':')))
    return result


def frontend():
    text=read(ROOT/'logs/r2_camera_safe_lifecycle_20260913_a.log')
    control=c26.rows(text,'PASS',prefix='C1_R2_CAMERA_SAFE_CONTROL_')
    need(len(control)==2 and {r['stalls'] for r in control}=={0,1} and
         all(r['checks']>=100 and r['edges']>=4 and r['off_clock_updates']==0 for r in control), 'source register timing not tested')
    normalized=text.replace('C1_R2_CAMERA_SAFE_LIFECYCLE_','C1_R2_CAMERA_LIFECYCLE_')
    # Retained C25 checks have explicit counts for busy/disabled/new-SOF behavior.
    rows=c26.rows(normalized,'PASS',prefix='C1_R2_CAMERA_LIFECYCLE_')
    need(len(rows)==2 and all(tuple(r[k] for k in ('good','bad','source_frames','skipped'))==(4,1,8,3) and
         r['aw']==r['b'] and all(r[k]==1 for k in ('held_completion_frame_skip','disable_owned_continues','unexpected_sof_recovery','no_reset')) for r in rows), 'lifecycle coverage missing')
    faults=read(ROOT/'logs/r2_camera_safe_capture_20260913_a.log')
    rows=c26.rows(faults,'PASS',prefix='C1_R2_CAMERA_SAFE_CAPTURE_')
    results=c26.rows(faults,'RESULT',prefix='C1_R2_CAMERA_SAFE_CAPTURE_')
    need(len(rows)==2 and len(results)==42 and all(tuple(r[k] for k in ('results','good','bad','held_b','tail_errors','aw','b'))==(21,11,10,64,2,113,113) for r in rows), 'front-end fault matrix incomplete')
    for i in range(2):
        rr=results[21*i:21*(i+1)]
        need([r['mode'] for r in rr]==[0]+[x for mode in range(1,11) for x in (mode,0)], 'missing post-fault recovery')
    need(text.count('C1_R2_CAMERA_SAFE_LIFECYCLE_CLEAN temporary_vectors_and_simulator_removed=1')==1 and
         faults.count('C1_R2_CAMERA_SAFE_CAPTURE_CLEAN temporary_vectors_and_simulator_removed=1')==1, 'frontend cleanup missing')
    print('C28_FRONTEND_PASS results=42 expected_faults=20 lifecycle_results=10 source_register_checks='+str(sum(r['checks'] for r in control)))


def xsim(run_id):
    folder=ROOT/'logs/r2_camera_safe_host_xsim_runs'/run_id
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim incomplete/unisolated/unclean')
    need(tuple(s[k] for k in ('width','height','stalls','aw_wait_w','nn_target','memory_div','command_latency'))==(12,12,1,2,6,2,20), 'wrong xsim profile')
    result=c26.run(canonical(read(folder/'result.log')))
    meta=json.loads(read(folder/'metadata.json'))
    need(all(meta[k] is True for k in ('actual_roi','unstoppable_source','actual_resize_golden')), 'wrong camera fixture')
    package=c26.c24.c18.compile_package(c26.c24.c18.profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv')==package.plan_sv and json.loads(read(folder/'plan_manifest.json'))==json.loads(json.dumps(package.manifest)), 'xsim wrong plan')
    print('C28_XSIM_PASS '+json.dumps({'seconds':s['elapsed_seconds'],**result},separators=(',',':')))


def physical(run_id):
    folder,s=c27.run(run_id)
    mapped=map_gate(run_id)
    sta=read(folder/'cdc_sta.stdout.log')
    need(len(re.findall(r'^C27_MATCH .* expected=',sta,re.M))==15 and '\nC27_AUDIT_PASS\n' in sta, 'post-route pin checks incomplete')
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
    need(len(camera_ends)==127 and len(core_ends)==14,'expected endpoint inventory wrong')
    for name in ('core_setup','core_hold','camera_setup','camera_hold','camera_to_core','core_to_camera'):
        report=read(folder/('c27_'+name+'.rpt'))
        slacks=list(map(float,re.findall(r'^Slack\s*:\s*([-+\d.]+) ns',report,re.M)))
        delays=list(map(float,re.findall(r'^Data Path Delay\s*:\s*([-+\d.]+) ns',report,re.M)))
        need(slacks and len(slacks)==len(delays) and min(slacks)>=0, 'timing violation/missing report '+name)
        if name in ('camera_to_core','core_to_camera'):
            count=127 if name=='camera_to_core' else 14
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
    need(resources['memory_blocks_used']==148 and resources['dsp_blocks_used']==130, 'unexpected RAM/DSP footprint')
    classification=json.loads(read(folder/'cdc_classification_status.json'))
    print('C28_PNR_PASS '+json.dumps({'resources':resources,'timing':timing,'gray_setup_skew_ns':[v[1] for v in skew],
          'cdc_classification':classification,'physical_cdc_signoff':False},separators=(',',':')))


def main():
    p=argparse.ArgumentParser();p.add_argument('--source-only',action='store_true');a=p.parse_args()
    source_gate();frontend()
    if a.source_only:
        return
    for kind in ('matrix','faults','variant','negative'):
        regression(f'c28_camera_safe_{kind}_20260913_a',kind)
    xsim('c28_camera_safe_xsim_12x12_20260913_a')
    physical('c28_camera_safe96_pnr_20260913_a')
    print('C28_EVIDENCE_PASS new_cdc_rtl_integrated=1 native_fps_claim=0 board_verified=0 physical_cdc_signoff=0')


if __name__=='__main__':main()
