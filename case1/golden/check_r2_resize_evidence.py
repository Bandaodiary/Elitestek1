"""C23 evidence gate: Resize only, never a complete camera/host FPS claim."""
from __future__ import annotations
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET
from run_r2_resize_probe import ROOT,SOURCES,OLD
from check_r2_overlay_host_evidence import need,tokens,source_gate as retained_c22
from check_r2_planned_host_evidence import c12

def read(path):return (ROOT/path).read_text(encoding='utf-8-sig')
def rows(text,prefix):return [c12.fields(line) for line in text.splitlines() if line.startswith(prefix+' ')]
def clean(text):need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError',text),'failed test log')

def source_gate():
    preserved=retained_c22()
    for old,new in [('rtl/video/c1_r1_resize_pipeline.sv','rtl/r2/c1_r2_resize_pipeline.sv'),
                    ('sim/tb_c1_r1_resize_pipeline.sv','sim/tb_c1_r2_resize_pipeline.sv')]:
        expected=read(old).replace('c1_r1_resize_pipeline','c1_r2_resize_pipeline').replace('c1_r1_resize_line_sampler','c1_r2_resize_line_sampler').replace('C1_R1_RESIZE_PIPELINE_','C1_R2_RESIZE_PIPELINE_')
        need(tokens(expected)==tokens(read(new)),'unexpected wrapper/testbench behavior change')
    old=read('rtl/video/c1_r1_resize_line_sampler.sv')
    new=read('rtl/r2/c1_r2_resize_line_sampler.sv').replace('c1_r2_resize_line_sampler','c1_r1_resize_line_sampler')
    # Exact changes are removal of four original RAM instances, insertion of
    # the checked pair-RAM port wiring, and a hardware adjacent-X pair guard.
    lo=old.index('    c1_ram_sdp_read_first #(');hi=old.index('    logic job_active;')
    expected=old[:lo]+old[hi:]
    expected=expected.replace("(sample_req_y1 > sample_req_y0 + 16'd1);",
        "(sample_req_y1 > sample_req_y0 + 16'd1) || (sample_req_x1 < sample_req_x0) || ({1'b0,sample_req_x1} > {1'b0,sample_req_x0} + 17'd1);")
    block='''c1_r2_resize_pair_ram #(.MAX_WIDTH(MAX_WIDTH)) u_pair_ram (
        .clk(clk),.rst(rst),.rd_en(ram_rd_en),.rd_x0(sample_req_x0),.rd_x1(sample_req_x1),
        .row0_x0(ram_line0_x0_rd_data),.row0_x1(ram_line0_x1_rd_data),
        .row1_x0(ram_line1_x0_rd_data),.row1_x1(ram_line1_x1_rd_data),
        .wr_row0(ram_line0_wr_en),.wr_row1(ram_line1_wr_en),.wr_x(expected_src_x),.wr_rgb(ram_wr_data));'''
    nt=tokens(new);bt=tokens(block)
    need(nt.count(bt)==1 and nt.replace(bt,'')==tokens(expected),'unexpected sampler change')
    for variant in ('reference','banked','640'):
        name='c1_ti60_r2_resize_'+variant
        project=ET.fromstring(read('efinity/'+name+'.xml'))
        sources=[x.attrib['name'] for x in project.iter() if x.tag.rsplit('}',1)[-1]=='design_file']
        expected_sources=(SOURCES[:4]+OLD) if variant=='reference' else SOURCES
        need(set(sources)==set(['../'+s for s in expected_sources]+[name+'.sv']) and len(sources)==len(set(sources)), 'wrong Resize source closure')
    reference=read('efinity/c1_ti60_r2_resize_reference.sv').replace('c1_ti60_r2_resize_reference','c1_ti60_r2_resize_banked').replace('c1_r1_resize_pipeline','c1_r2_resize_pipeline')
    need(tokens(reference)==tokens(read('efinity/c1_ti60_r2_resize_banked.sv')),'unequal reference resource probe')
    fixed=read('efinity/c1_ti60_r2_resize_640.sv').replace('c1_ti60_r2_resize_640','c1_ti60_r2_resize_banked').replace(".cfg_wout(16'd640),.cfg_hout(16'd480)",'.cfg_wout(wout),.cfg_hout(hout)')
    need(tokens(fixed)==tokens(read('efinity/c1_ti60_r2_resize_banked.sv')),'fixed probe differs beyond output constants')
    return dict(c22_preserved=preserved['source_files']==34,pipeline_control_and_interpolation_unchanged=True,
                new_sampler_contract='x1=x0 or x0+1; monotonic adjacent/clamped y',pair_guard_in_synthesizable_logic=True,
                dynamic_and_fixed_output_probes=True)

def small_gate(text):
    clean(text)
    ps=rows(text,'C1_R2_RESIZE_PIPELINE_PASS')
    need(len(ps)==2 and [p['registered_abort_reset'] for p in ps]==[0,1],'missing reset configurations')
    for p in ps:need((p['configs'],p['outputs'],p['cfg_errors'],p['aborts'])==(11,207,3,4),'wrong retained pipeline coverage')
    need(len(rows(text,'C1_RESIZE_TAIL_RECOVERY_PASS'))==len(rows(text,'C1_RESIZE_SOURCE_TAIL_DRAIN_PASS'))==2,'missing tail checks')
    need(text.count('C1_R2_RESIZE_CLEAN temporary_vectors_and_simulator_removed=1')==1,'small cleanup missing')
    return dict(configurations_per_reset=11,reset_modes=2,golden_outputs=414,tail_cancel_and_malformed_recovery=True)

def ram_gate(text):
    clean(text);ps=rows(text,'C1_R2_RESIZE_RAM_PASS')
    need([p['width'] for p in ps]==[1,1025,2047,2048],'missing full/odd/one-width RAM tests')
    for p in ps:
        w=p['width'];need((p['reads'],p['writes'],p['holds'],p['resets'],p['read_latency'])==(2*w+136,2*w+128,2*w+136,8,1),'RAM counters changed')
    need([p['case'] for p in rows(text,'C1_R2_RESIZE_RAM_NEGATIVE_PASS')]==[1,2,3,4],'missing RAM negatives')
    need(rows(text,'C1_R2_RESIZE_SAMPLER_REJECT_PASS')==[dict(hardware_pair_errors=2,reset_recoveries=2,adjacent_and_clamped=1)],'missing actual sampler rejection/recovery')
    need(text.count('C1_R2_RESIZE_RAM_CLEAN temporary_simulator_removed=1')==1,'RAM cleanup missing')
    return dict(widths=[1,1025,2047,2048],reads=sum(p['reads'] for p in ps),writes=sum(p['writes'] for p in ps),
                holds=sum(p['holds'] for p in ps),resets=32,helper_negatives=4,synthesizable_pair_errors=2)

def miter_gate(text,keys):
    clean(text);ps=rows(text,'C1_R2_RESIZE_EQUIVALENCE_PASS')
    found={(p['width'],p['height'],p['out_width'],p['out_height'],p['stalls']) for p in ps}
    need(found==keys and len(ps)==len(keys),'missing/duplicate actual old/new miter runs')
    for p in ps:
        need(p['inputs']==p['width']*p['height'] and p['outputs']==p['out_width']*p['out_height'] and
             p['cycle_exact']==p['independent_golden']==p['camera_backpressure_allowed']==1,'miter/golden contract missing')
        need(p['cycles']>p['inputs'] and p['source_stalls']>=p['max_source_pause']>0,'missing real source backpressure')
    need(text.count('C1_R2_RESIZE_EQUIVALENCE_CLEAN temporary_vectors_and_simulator_removed=1')==1,'miter cleanup missing')
    return dict(runs=ps,outputs_checked=sum(p['outputs'] for p in ps),camera_unstoppable=False,cnn_fps_claimed=False)

def physical(variant,expected_ram):
    run=f'c23_resize_{variant}_i3_20260913_a';folder=Path('logs/efinity_resource_runs')/run
    s=json.loads(read(folder/'status.json'));m=json.loads(read(folder/'summary.json'))
    name='c1_ti60_r2_resize_'+variant
    need(s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0 and m['marker']==name.upper()+'_MAP_PNR_PASS','wrong/incomplete physical run')
    need(m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr' and '--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'),'wrong physical part/flow')
    r,t=m['pnr_resources'],m['timing']
    need(r['memory_blocks_used']==expected_ram and r['dsp_blocks_used']==18 and r['xlr_cells_used']>1000,'unexpected/pruned Resize resources')
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_period_ns']+t['final_slack_ns']-6.666)<.002,'150MHz timing failure')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_'+name+'_'+run)
    need(not private.exists(),'physical private directory remains')
    need(any('+u_resize:c1_r'+('1' if variant=='reference' else '2')+'_resize_pipeline' in x for x in m['metrics']['module_rows']),'missing actual Resize hierarchy')
    return dict(run=run,resources=r,timing=t,scope='standalone Resize; not joint host/camera/CPU/PHY/CDC')

def xsim_gate():
    folder=Path('logs/r2_resize_xsim_runs/c23_resize_xsim_20260913_a')
    s=json.loads(read(folder/'status.json'));text=read(folder/'result.log');clean(text)
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         s['registered_abort_reset']==1 and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'xsim incomplete/in job/unclean')
    need(rows(text,'C1_R2_RESIZE_PIPELINE_PASS')==[dict(configs=11,outputs=207,cfg_errors=3,aborts=4)],'xsim missing pipeline regression')
    need(len(rows(text,'C1_RESIZE_TAIL_RECOVERY_PASS'))==1 and len(rows(text,'C1_RESIZE_SOURCE_TAIL_DRAIN_PASS'))==1,'xsim tail checks missing')
    return dict(run=s['run_id'],seconds=s['elapsed_seconds'],worker_in_windows_job=False,private_removed=True)

def main():
    emit=lambda name,value:print('C1_R2_C23_'+name+' '+json.dumps(value,separators=(',',':')),flush=True)
    emit('SOURCE_GATE_PASS',source_gate())
    small=read('logs/r2_resize_small_20260913_b.log');emit('SMALL_GATE_PASS',small_gate(small))
    ram=read('logs/r2_resize_ram_20260913_b.log');emit('RAM_GATE_PASS',ram_gate(ram))
    keys={(w,h,ow,oh,s) for w,h,ow,oh in [(1,7,4,3),(2047,5,641,3),(2048,5,640,4)] for s in (0,1)}
    miter=read('logs/r2_resize_miter_20260913_a.log');emit('MITER_GATE_PASS',miter_gate(miter,keys))
    negative=read('logs/r2_resize_miter_negative_20260913_a.log');clean(negative)
    # Do not parse the colon/x shape as an integer prefix with the shared
    # numeric field reader. Check the complete fixture identity literally.
    np=[line.strip() for line in negative.splitlines() if line.startswith('C1_R2_RESIZE_EQUIVALENCE_NEGATIVE_PASS ')]
    need(np==[f'C1_R2_RESIZE_EQUIVALENCE_NEGATIVE_PASS shape=8x8:4x4 stalls={s}' for s in (0,1)] and
         negative.count('C1_R2_RESIZE_EQUIVALENCE_CLEAN temporary_vectors_and_simulator_removed=1')==1,
         'missing/duplicate/wrong pixel-corruption negative')
    emit('NEGATIVE_GATE_PASS',dict(corrupted_golden_runs=2))
    emit('LARGE_GATE_PASS',miter_gate(read('logs/r2_resize_1080_20260913_a.log'),{(1440,1080,640,480,0)}))
    emit('XSIM_GATE_PASS',xsim_gate())
    ref=physical('reference',20);bank=physical('banked',12);fixed=physical('640',12)
    emit('REFERENCE_PHYSICAL_PASS',ref);emit('BANKED_PHYSICAL_PASS',bank);emit('FIXED_PHYSICAL_PASS',fixed)
    need(bank['resources']['memory_blocks_used']<ref['resources']['memory_blocks_used'],'no RAM saving')
    emit('BUDGET',dict(dynamic=dict(ram=239+bank['resources']['memory_blocks_used'],xlr=58613+bank['resources']['xlr_cells_used']),
                       fixed_output=dict(ram=239+fixed['resources']['memory_blocks_used'],xlr=58613+fixed['resources']['xlr_cells_used']),
                       includes='C22 + official CPU/DDR/CSI/Debayer + standalone Resize rough sum',cdc_and_joint_place_route=False))
    for f,text,old,new in [(ram_gate,ram,'read_latency=1','read_latency=2'),
                           (small_gate,small,'aborts=4','aborts=0'),
                           (lambda t:miter_gate(t,keys),miter,'cycle_exact=1','cycle_exact=0')]:
        need(old in text,'missing mutation target')
        try:f(text.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('bad evidence accepted')
    emit('AUDIT_NEGATIVE_PASS',dict(evidence_mutations_rejected=3))

if __name__=='__main__':main()
