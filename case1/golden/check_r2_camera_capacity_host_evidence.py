"""C29 evidence: bit/cycle-exact requant + row RAM capacity, retained CDC protection.

No inherited C26 performance, no board sign-off, no hashes. Reuses the retained
numerical/timeline checker only after proving the C29 producer/source identity.
"""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
import check_r2_camera_host_evidence as c26
import check_r2_camera_physical_cdc as c27
from run_r2_camera_capacity_host_probe import ROOT, SOURCES, PLAN_SOURCE
from run_r2_camera_safe_host_probe import SOURCES as ORIGINAL_SOURCES
import check_r2_camera_safe_host_evidence as c28

need, read = c27.need, c27.read
P = 'C1_R2_CAMERA_CAPACITY_HOST_SYSTEM_'
F = 'C1_R2_CAMERA_CAPACITY_HOST_FAULT_'
RENAMES = {
    'c1_requant_bank8': 'c1_requant_bank8_compact',
    'c1_r2_compute6': 'c1_r2_compute6_compact',
    'c1_r2_overlay_window_store': 'c1_r2_overlay_window_store_packed',
    'c1_r2_spatial_overlay_feeder': 'c1_r2_spatial_packed_feeder',
    'c1_r2_cnn_overlay_engine': 'c1_r2_cnn_capacity_engine',
    'c1_r2_overlay_pingpong_graph': 'c1_r2_capacity_pingpong_graph',
    'c1_r2_overlay_rgbx_axi_graph': 'c1_r2_capacity_rgbx_axi_graph',
    'c1_r2_video_camera_safe_system': 'c1_r2_video_camera_capacity_system',
    'c1_r2_camera_safe_host_system': 'c1_r2_camera_capacity_host_system',
}
normalize_rtl = c28.normalize_rtl


def leaf_delta(old, new, stem):
    if stem == 'c1_requant_bank8':
        need('logic[9:0]rounded_record[0:7];' in normalize_rtl(new), 'wrong compact record width')
        need('shifted_record={negative,|shifted_magnitude[51:8],shifted_magnitude[7:0]};' in normalize_rtl(new),
             'discarded saturation information')
        need("elseif(overflow||(negative?magnitude>8'd128:magnitude>8'd127))" in normalize_rtl(new),
             'wrong signed saturation boundaries')
        # Only the two named arithmetic functions and the stage-4 representation
        # may differ; separate retained-cycle + independent golden tests exercise them.
        for label in ('restore_shifted_sign', 'saturate_activate_s8'):
            # Anchor each function start without spanning previous functions.
            pattern = r'function automatic [^\n]*\b'+label+r'\(.*?endfunction'
            old, n = re.subn(pattern, 'FUNCTION_'+label, old, flags=re.S)
            need(n == 1, 'old arithmetic region not unique '+label)
        new = new.replace('shifted_record','restore_shifted_sign').replace('rounded_record','rounded_pipe')
        new = new.replace('logic [9:0] rounded_pipe [0:7];','logic signed [51:0] rounded_pipe [0:7];')
        for label in ('restore_shifted_sign', 'saturate_activate_s8'):
            new, n = re.subn(r'function automatic [^\n]*\b'+label+r'\(.*?endfunction',
                             'FUNCTION_'+label, new, flags=re.S)
            need(n == 1, 'new arithmetic region not unique '+label)
    elif stem == 'c1_r2_overlay_window_store':
        pattern=r'for\(genvar (?:slice_id|bank_id)=.*?(?=    logic pending_valid)'
        old_block=re.search(pattern,old,re.S); new_block=re.search(pattern,new,re.S)
        need(old_block and new_block,'window bank delta not located')
        expected = old_block[0].replace(
            'slice_id=4;slice_id<12;slice_id=slice_id+1','bank_id=2;bank_id<6;bank_id=bank_id+1'
        ).replace('ROW=slice_id/4','ROW=bank_id/2').replace(
            'BANK=(slice_id/2)%2','BANK=bank_id%2'
        ).replace('localparam integer WORD=slice_id%2;','').replace(
            '.DATA_WIDTH(32)', '.DATA_WIDTH(64)'
        ).replace('bank_data[slice_id*32+:32]','bank_data[bank_id*64+:64]').replace(
            'bulk_data[BANK*64+WORD*32+:32]','bulk_data[BANK*64+:64]')
        need(normalize_rtl(expected)==normalize_rtl(new_block[0]),'unexpected RAM bank rewrite')
        old=re.sub(pattern,'RAM_BANKS\n',old,flags=re.S)
        new=re.sub(pattern,'RAM_BANKS\n',new,flags=re.S)
    return old,new


def source_gate():
    c28.source_gate()
    transformed = [next((s.replace(a,b) for a,b in RENAMES.items() if a+'.sv' in s), s)
                   for s in ORIGINAL_SOURCES]
    need(len(SOURCES)==44 and SOURCES==transformed and len(set(SOURCES))==44,
         'unexpected C29 production closure')
    replacements=0
    for original,replacement in zip(ORIGINAL_SOURCES,SOURCES):
        if original==replacement:
            continue
        replacements+=1
        old,new=read(ROOT/original),read(ROOT/replacement)
        for a,b in sorted(RENAMES.items(),key=lambda kv: -len(kv[1])):
            new=new.replace(b,a)
        old,new=leaf_delta(old,new,Path(original).stem)
        need(normalize_rtl(old)==normalize_rtl(new),'unplanned behavior change '+replacement)
    need(replacements==9,'unexpected replacement count')
    for suffix in ('system','faults'):
        old=read(ROOT/f'sim/tb_c1_r2_camera_safe_host_{suffix}.sv')
        new=read(ROOT/f'sim/tb_c1_r2_camera_capacity_host_{suffix}.sv')
        new=new.replace('camera_capacity','camera_safe').replace('CAMERA_CAPACITY','CAMERA_SAFE')
        need(normalize_rtl(old)==normalize_rtl(new),'host monitor differs '+suffix)
    for extension in ('sdc','audit.tcl','cdc.tcl','sv'):
        old=read(ROOT/f'efinity/c1_ti60_r2_camera_safe96.{extension}')
        new=read(ROOT/f'efinity/c1_ti60_r2_camera_capacity96.{extension}')
        new=new.replace('camera_capacity','camera_safe')
        need(normalize_rtl(old)==normalize_rtl(new),'probe/constraints changed '+extension)
    script=read(ROOT/'scripts/run_r2_camera_capacity_regression_detached.ps1')
    need("-cnotmatch '^"+P+"VECTORS '" in script and "-cmatch 'FATAL|ERROR:|Traceback|RuntimeError'" in script,
         'runner filter changed')
    print('C29_SOURCE_PASS retained_c28=1 production_sources=44 new_modules=9 implementation_leaves=2')


def leaves():
    log=read(ROOT/'logs/r2_capacity_leaf_20260914_b.log')
    expected=[
        'C29_REQUANT_CYCLE_EQUIVALENCE_PASS cycles=13630 elastic_latency_unchanged=1',
        'C29_REQUANT_COMPACT_PASS vectors=7168 lanes=57344 shifts=48 stalls=6447',
        'C29_WINDOW_PACKED_PASS configurations=36 requests=3960 bulk_writes=30348 held=3665 cycle_equivalent=1 independent_golden=1',
        'C29_CAPACITY_LEAF_CLEAN temporary_simulator_removed=1',
    ]
    need(log.strip().splitlines()==expected,'leaf coverage/result changed')
    rows={}
    for design,expected in {
        'requant_reference':(5964,1671,0,16),
        'requant_compact':(3737,1399,0,16),
        'window_reference':(2904,1608,48,0),
        'window_packed':(2909,1608,44,0),
    }.items():
        name=f'c29_{design}_map_20260913_a'
        folder=ROOT/'logs/efinity_resource_runs'/name
        s=json.loads(read(folder/'status.json'))
        need(s['state']=='complete' and s['exit_code']==0,'leaf MAP not complete')
        # Exact known task-private directory, not any broad Temp wildcard.
        private=Path('C:/Users/30982/AppData/Local/Temp')/f'c1_efinity_resource_c1_ti60_{design}_map_{name}'
        need(not private.exists(),'leaf MAP not cleaned')
        metrics=s['metrics']
        actual=tuple(metrics[k] for k in ('le','registers','ebr','dsp'))
        need(actual==expected,'unexpected leaf mapping '+design)
        rows[design]=dict(zip(('lut4','ff','ram','dsp'),actual))
    print('C29_LEAF_PASS '+json.dumps(rows,separators=(',',':')))


def cycle_lines(text, current):
    prefix=P if current else c28.P
    fault=F if current else c28.F
    return [line.replace(prefix,c26.P).replace(fault,c26.F)
            for line in text.splitlines() if line.startswith((prefix,fault))]


def cycle_equivalence():
    comparisons={}
    for kind in ('matrix','faults','variant','negative'):
        old=read(ROOT/'logs/r2_camera_safe_regression_runs'/f'c28_camera_safe_{kind}_20260913_a'/'result.log')
        new=read(ROOT/'logs/r2_camera_capacity_regression_runs'/f'c29_camera_capacity_{kind}_20260914_b'/'result.log')
        a,b=cycle_lines(old,False),cycle_lines(new,True)
        need(a and a==b,'cycle/data trace changed '+kind)
        comparisons[kind]=len(a)
    old=read(ROOT/'logs/r2_camera_safe_host_xsim_runs/c28_camera_safe_xsim_12x12_20260913_a/result.log')
    new=read(ROOT/'logs/r2_camera_capacity_host_xsim_runs/c29_camera_capacity_xsim_12x12_20260914_b/result.log')
    a,b=cycle_lines(old,False),cycle_lines(new,True)
    need(a and a==b,'xsim cycle/data trace changed')
    comparisons['xsim']=len(a)
    print('C29_WHOLE_HOST_CYCLE_EQUIVALENCE_PASS '+json.dumps(comparisons,separators=(',',':')))


def negative_controls():
    text=read(ROOT/'logs/r2_camera_capacity_host_xsim_runs/c29_camera_capacity_xsim_12x12_20260914_b/result.log')
    mutations=[
        ('old producer',text.replace(P,c28.P)),
        ('missing SOF','\n'.join(line for line in text.splitlines() if not line.startswith(P+'SOURCE_SOF '))),
        ('backpressurable camera',text.replace('source_backpressure_allowed=0','source_backpressure_allowed=1')),
        ('writable camera page',text.replace('readonly=1','readonly=0')),
        ('missing graph node',text.replace('commits=22','commits=21')),
        ('display deadline',text.replace('display_misses=0','display_misses=1')),
    ]
    for name,changed in mutations:
        need(changed!=text,'negative control did not change fixture '+name)
        try:c26.run(canonical(changed))
        except (AssertionError,ValueError,KeyError):pass
        else:raise AssertionError('corrupt host evidence accepted '+name)
    print('C29_HOST_EVIDENCE_NEGATIVE_PASS rejected='+str(len(mutations)))


def cleanup():
    records=[]
    for version in ('a','b'):
        for kind in ('matrix','faults','variant','negative'):
            name=f'c29_camera_capacity_{kind}_20260914_{version}'
            folder=ROOT/'logs/r2_camera_capacity_regression_runs'/name
            s=json.loads(read(folder/'status.json'))
            records.append((folder,s,Path(s['run_directory'])))
        name=f'c29_camera_capacity_xsim_12x12_20260914_{version}'
        folder=ROOT/'logs/r2_camera_capacity_host_xsim_runs'/name
        s=json.loads(read(folder/'status.json'))
        records.append((folder,s,Path(s['run_directory'])))
    maps=[(f'c29_{leaf}_map_20260913_a',f'c1_ti60_{leaf}_map') for leaf in
          ('requant_reference','requant_compact','window_reference','window_packed')]
    maps += [(f'c29_camera_capacity96_pnr_20260914_{v}','c1_ti60_r2_camera_capacity96') for v in ('a','b')]
    for name,design in maps:
        folder=ROOT/'logs/efinity_resource_runs'/name
        s=json.loads(read(folder/'status.json'))
        private=Path('C:/Users/30982/AppData/Local/Temp')/f'c1_efinity_resource_{design}_{name}'
        records.append((folder,s,private))
    for folder,s,private in records:
        need(s['state']=='complete' and s['exit_code']==0 and not private.exists(),
             'C29 run not terminal/clean '+folder.name)
        if 'worker_in_windows_job' in s:
            need(s['worker_in_windows_job'] is False,'simulator worker in Windows Job')
    files=[p for folder,_,_ in records for p in folder.rglob('*') if p.is_file()]
    need(not any(p.suffix.lower() in ('.wdb','.vcd','.vvp','.bit','.map','.db') for p in files),
         'unexpected bulky simulation/implementation payload retained')
    total=sum(p.stat().st_size for p in files)
    result={'terminal_runs':len(records),'removed_private_directories':len(records),
            'retained_files':len(files),'retained_bytes':total,'retained_mib':round(total/1048576,3),
            'includes_prerename_runs':True,'deleted_by_this_checker':False,
            'native_c26_not_modified':True}
    print('C29_CLEANUP_PASS '+json.dumps(result,separators=(',',':')))
    return result


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
    print('C29_MAPPED_CDC_STRUCTURE_PASS protected_sync_ff=56 retimed_sync_ff=0 registered_control_crossings=8')
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
    print('C29_MAPPED_CDC_NEGATIVE_CONTROLS_PASS rejected=4')
    return mapped


def canonical(text):
    need(P in text or F in text, 'not C29 evidence')
    need(all(x not in text for x in (c26.P,c26.F,c28.P,c28.F)), 'mixed retained/C29 provenance')
    return text.replace(P,c26.P).replace(F,c26.F)


def regression(run_id,kind):
    folder=ROOT/'logs/r2_camera_capacity_regression_runs'/run_id
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
    print('C29_REGRESSION_PASS '+json.dumps({'kind':kind,'seconds':s['elapsed_seconds'],**result},separators=(',',':')))
    return result


def xsim(run_id):
    folder=ROOT/'logs/r2_camera_capacity_host_xsim_runs'/run_id
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim incomplete/unisolated/unclean')
    need(tuple(s[k] for k in ('width','height','stalls','aw_wait_w','nn_target','memory_div','command_latency'))==(12,12,1,2,6,2,20), 'wrong xsim profile')
    result=c26.run(canonical(read(folder/'result.log')))
    meta=json.loads(read(folder/'metadata.json'))
    need(all(meta[k] is True for k in ('actual_roi','unstoppable_source','actual_resize_golden')), 'wrong camera fixture')
    package=c26.c24.c18.compile_package(c26.c24.c18.profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv')==package.plan_sv and json.loads(read(folder/'plan_manifest.json'))==json.loads(json.dumps(package.manifest)), 'xsim wrong plan')
    print('C29_XSIM_PASS '+json.dumps({'seconds':s['elapsed_seconds'],**result},separators=(',',':')))


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
    need(resources['memory_blocks_used']==144 and resources['dsp_blocks_used']==130, 'unexpected RAM/DSP footprint')
    classification=json.loads(read(folder/'cdc_classification_status.json'))
    print('C29_PNR_PASS '+json.dumps({'resources':resources,'timing':timing,'gray_setup_skew_ns':[v[1] for v in skew],
          'cdc_classification':classification,'physical_cdc_signoff':False},separators=(',',':')))


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source-only',action='store_true')
    p.add_argument('--functional-only',action='store_true')
    a=p.parse_args()
    source_gate();leaves()
    if a.source_only:
        return
    for kind in ('matrix','faults','variant','negative'):
        regression(f'c29_camera_capacity_{kind}_20260914_b',kind)
    xsim('c29_camera_capacity_xsim_12x12_20260914_b')
    cycle_equivalence();negative_controls()
    if a.functional_only:
        return
    physical('c29_camera_capacity96_pnr_20260914_b');cleanup()
    print('C29_EVIDENCE_PASS capacity_rtl_integrated=1 same_model_and_cycles=1 native_fps_claim=0 board_verified=0 physical_cdc_signoff=0')


if __name__=='__main__':main()
