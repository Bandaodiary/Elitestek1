"""C30 frontend evidence gate. No CNN-FPS, joint-fit or physical CDC claim.

Read bounded retained text, inspect actual source deltas, and check independent
golden/AXI traces. Negative controls operate on strings, never production files.
"""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
import check_r2_camera_capacity_host_evidence as c29
from run_r2_official_debayer_contract import ROOT,VENDOR,SOURCES as VENDOR_SOURCES

need,read,norm=c29.need,c29.read,c29.normalize_rtl
P='C1_R2_DEMO_RGB2_CAPTURE_'
RUNS=ROOT/'logs/r2_demo_rgb2_regression_runs'


def source_gate():
    c29.source_gate()
    a=read(ROOT/'rtl/video/c1_r1_resize_system.sv')
    b=read(ROOT/'rtl/r2/c1_r2_resize_overlap_system.sv')
    a=a.replace('c1_r1_resize_system','c1_r2_resize_overlap_system').replace(
        'sample_req_valid = request_buf_valid && !sample_pending;',
        'sample_req_valid = request_buf_valid && (!sample_pending || (sample_rsp_valid && sample_rsp_ready));')
    a=a.replace("if (sample_rsp_valid && sample_rsp_ready) begin\n                sample_pending <= 1'b0;",
                'if (sample_rsp_valid && sample_rsp_ready) begin\n                sample_pending <= sample_req_valid && sample_req_ready;')
    need(norm(a)==norm(b),'unplanned Resize arithmetic/control delta')
    for old,new,inner_old,inner_new in (
        ('c1_r2_resize_pipeline','c1_r2_resize_overlap_pipeline','c1_r1_resize_system','c1_r2_resize_overlap_system'),
        ('c1_r2_resize_capture_rgbx32','c1_r2_resize_overlap_capture','c1_r2_resize_pipeline','c1_r2_resize_overlap_pipeline')):
        expected=read(ROOT/f'rtl/r2/{old}.sv').replace(old,new).replace(inner_old,inner_new)
        need(norm(expected)==norm(read(ROOT/f'rtl/r2/{new}.sv')),'wrapper behavior changed '+new)
    # Review boundary: registered CDC controls + complete core ownership/result
    # machine remain identical. Pair packing/ROI/phase logic is new and tested.
    a=read(ROOT/'rtl/r2/c1_r2_camera_ingress_guarded.sv')
    b=read(ROOT/'rtl/r2/c1_r2_camera_pair_ingress.sv')
    for start,end in (
        ('logic request_q,ack_q;','wire last_source='),
        ('always_ff @(posedge clk)begin\n        if(rst)begin\n            req_sync1',None)):
        x=a[a.index(start):];y=b[b.index(start):]
        if end:x=x[:x.index(end)];y=y[:y.index(end)]
        need(norm(x)==norm(y),'CDC control/owner/result machine changed')
    need('.DATA_WIDTH(49)' in b, 'pair record width')
    need('fifo_rgb[48] || high_pixel' in b and 'state==DRAIN)high_pixel<=0' in b,'pair drain/phase contract')
    listed=[n.attrib['name'] for n in ET.parse(VENDOR/'ti60f225_oob.xml').getroot().iter()
            if n.tag.rsplit('}',1)[-1]=='design_file']
    need(all(listed.count(s)==1 and (VENDOR/s).is_file() for s in VENDOR_SOURCES),'active official XML mismatch')
    probe=ET.parse(ROOT/'efinity/c1_ti60_r2_rgb2_capture512.xml').getroot()
    files=[(ROOT/'efinity'/n.attrib['name']).resolve() for n in probe.iter()
           if n.tag.rsplit('}',1)[-1]=='design_file']
    need(len(files)==len(set(files))==15 and all(f.is_file() for f in files),'new MAP closure')
    tb=read(ROOT/'sim/tb_c1_r2_demo_rgb2_capture.sv')
    for token in ('reg [4095:0] dir;',"if(^image[i]===1'bx)","if(^expected[i]===1'bx)",
                  'm_axi_wdata!==expected[service_write_address>>4]',
                  's_rgb!==image[(s_y+RY)*SW+s_x+RX]',
                  'if(job_done || results!=before_results || cap_outstanding==0)',
                  'if(stream_words>=RW*RH)', 'debayer_top_2to1 u_official'):
        need(token in tb,'missing independent data/lifecycle monitor '+token)
    print('C30_SOURCE_PASS retained_c29=1 new_frontend_sources=14 resize_control_changes=2 actual_vendor_sources=5')


def fields(line):
    return {k:int(v) for k,v in re.findall(r'\b(\w+)=(-?\d+)\b',line)}


def capture_log(text,vendor=False,native=False,stalls=(0,1),odd=False):
    need(not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text),'fatal/error in successful capture log')
    parts=text.split('C30_RESIZE_SELECTION overlap=1\n')[1:]
    need(len(parts)==len(stalls),'actual overlap implementation count')
    allrows=[]
    codes={1:5,2:5,3:5,4:2,5:4,6:3,7:5,8:6,9:2,10:4,11:4,12:5,13:5,14:5}
    sequence=[0,0] if vendor or native else [0]+[j for i in range(1,15) for j in (i,0)]
    rw,rh=(1440,1080) if native else (12,12) if vendor else (15,15) if odd else (16,16)
    ow,oh=(640,480) if native else (8,8)
    for body,stall in zip(parts,stalls):
        passes=[fields(x) for x in body.splitlines() if x.startswith(P+'PASS ')]
        rows=[fields(x) for x in body.splitlines() if x.startswith(P+'RESULT ')]
        need(len(passes)==1 and len(rows)==len(sequence),'capture result count')
        p=passes[0]
        need((p['rw'],p['rh'],p['ow'],p['oh'],p['stalls'])==(rw,rh,ow,oh,stall),'capture geometry/stalls')
        need(p['sw']==(1920 if native else 20) and p['sh']==(1080 if native else 20),'source shape')
        need(p['fifo']==(512 if native else 64),'source FIFO units/capacity')
        need(p['results']==len(sequence) and p['good']==sequence.count(0) and p['bad']==len(sequence)-sequence.count(0),'summary counts')
        need(p['aw']==p['b'] and p['aw']>0 and p['no_reset_recovery']==p['unstoppable_source']==1,'B debt/producer contract')
        need(p['roi_pixels']==sum(r['roi_pixels'] for r in rows) and p['checked_words']==sum(r['words'] for r in rows),'actual aggregate counts')
        need(0<p['peak']<=p['fifo'],'FIFO capacity')
        for i,(mode,r) in enumerate(zip(sequence,rows)):
            need(r['mode']==mode and r['tag']==i and r['code']==codes.get(mode,0) and r['failed']==int(mode!=0),'fault mode/tag/code')
            need(r['admitted']==int(mode not in (7,9)),'admission/lease')
            if i:need(r['cycle']>rows[i-1]['cycle'],'nonmonotonic completion')
            if mode==0:need(r['roi_pixels']==rw*rh and r['words']==ow*oh//4,'good frame actual data count')
            if mode in (7,9):need(r['words']==r['roi_pixels']==0,'unadmitted frame wrote data')
            if mode in (2,13,14):need(r['roi_pixels']<rw*rh,'bad source committed final ROI')
        producer=f'C30_RASTER_PRODUCER vendor_rtl={int(vendor)} final_pair_waits_for_vs=1 no_ready=1'
        need(body.splitlines().count(producer)==1,'wrong actual source producer')
        if not vendor and not native:
            need(p['held_b']==64 and p['tail_errors']==3,'fault lifecycle coverage')
            need(body.count('C1_R2_DEMO_RGB2_PHASE_PASS held_high_cycles=4 canceled_with_half_word=1 no_reset=1')==1,'half-record cancellation missing')
        if native:
            need('core_half_ns=3.333 camera_half_ns=7.143 hblank=106 vblank=42 sof_interval_camera_cycles=1196052 faults=0' in body,'not official native raster cadence')
            need(p['checked_words']==153600 and p['aw']==9600,'native actual AXI work')
        allrows.append(p)
    return allrows


def completed(folder):
    s=json.loads(read(folder/'status.json'))
    need(s['state']=='complete' and s['exit_code']==0,'run not complete '+folder.name)
    need(s.get('worker_in_windows_job') is False,'Windows Job isolation not proven')
    need(s['simulator_directory_present'] is False and not Path(s['run_directory']).exists(),'live/private simulator directory')
    return s,read(folder/'result.log')


def regressions():
    summary={};matrix=None
    for kind in ('matrix','odd','vendor','native512'):
        name=f'c30_demo_rgb2_{kind}_20260914_'+('a' if kind=='native512' else 'final_a')
        s,t=completed(RUNS/name)
        need(s['overlap_resize'] is True and s['actual_vendor_rtl']==(kind=='vendor'),'worker source selection')
        need(t.count(P+'CLEAN temporary_vectors_and_simulator_removed=1')==1,'temporary vector cleanup')
        rows=capture_log(t,vendor=kind=='vendor',native=kind=='native512',stalls=(0,) if kind=='native512' else (0,1),odd=kind=='odd')
        summary[kind]=dict(configurations=len(rows),good=sum(r['good'] for r in rows),bad=sum(r['bad'] for r in rows),peak=max(r['peak'] for r in rows))
        if kind=='matrix':matrix=t
        if kind=='native512':summary[kind].update(words=rows[0]['checked_words'],roi_pixels=rows[0]['roi_pixels'])
    for kind in ('vendor','fault'):
        folder=ROOT/'logs/r2_demo_rgb2_capture_xsim_runs'/f'c30_demo_rgb2_{kind}_xsim_20260914_c'
        s,t=completed(folder)
        need(s['overlap_resize'] is True and s['actual_vendor_rtl']==(kind=='vendor'),'xsim metadata mismatch')
        capture_log(t,vendor=kind=='vendor',stalls=(1,))
        peer=read(RUNS/f'c30_demo_rgb2_{"vendor" if kind=="vendor" else "matrix"}_20260914_final_a'/'result.log')
        expected=peer.split('C30_RESIZE_SELECTION overlap=1\n')[2]
        prefix=lambda x:[r for r in x.splitlines() if r.startswith((P,'C30_RASTER_PRODUCER','C1_R2_DEMO_RGB2_SOURCE_PROFILE')) and not r.startswith(P+'CLEAN')]
        need(prefix(t)==prefix(expected),'Icarus/xsim actual result timeline differs')
    mutations=(
        matrix.replace('overlap=1','overlap=0',1),
        matrix.replace('failed=1 code=5','failed=1 code=4',1),
        matrix.replace('words=16','words=15',1),
        matrix.replace('vendor_rtl=0','vendor_rtl=1',1),
        matrix.replace('held_high_cycles=4','held_high_cycles=0',1),
        matrix.replace('admitted=0','admitted=1',1),
    )
    for m in mutations:
        need(m!=matrix,'ineffective negative control')
        try:capture_log(m)
        except (AssertionError,ValueError,RuntimeError,KeyError):pass
        else:raise AssertionError('mutated evidence accepted')
    print('C30_CAPTURE_PASS '+json.dumps(summary,separators=(',',':')))
    print('C30_XSIM_PASS configurations=2 actual_vendor=1 fault_modes=14 cycle_trace_equal=1 job_isolated=1')
    print('C30_EVIDENCE_NEGATIVE_PASS mutations=6')


def leaves_and_map():
    t=read(ROOT/'logs/r2_official_debayer_contract_20260914_c.log')
    for line in (
        'C30_OFFICIAL_INTERIOR_GOLDEN_PASS pairs=120 scalar_pixels=240 low_first=1 horizontal_pair_delay=1 flat_r=160 flat_g=96 flat_b=32',
        'C30_OFFICIAL_CONTROL_PASS frames=4 source_pairs=256 output_pairs=256 checks=810 delay_registers=5',
        'C30_OFFICIAL_RAW_PACKING_NEGATIVE_PASS actual_rtl_mutation=1',
        'C30_OFFICIAL_CLEAN private_simulator_removed=1 vendor_sources_edited=0'):
        need(t.splitlines().count(line)==1,'official direct RTL evidence missing')
    t=read(ROOT/'logs/r2_resize_overlap_20260914_b.log')
    for reset in (0,1):
        need(t.count(f'C30_RESIZE_OVERLAP_PIPELINE_PASS configs=11 outputs=207 cfg_errors=3 aborts=4 registered_abort_reset={reset}')==1,'Resize independent golden')
        need(t.count(f'C30_RESIZE_OVERLAP_HANDSHAKE_PASS replacements=124 old_metadata_retired=1 registered_abort_reset={reset}')==1,'actual overlap not exercised')
    need('C30_RESIZE_OVERLAP_CLEAN temporary_vectors_and_simulator_removed=1' in t,'Resize cleanup')
    t=read(ROOT/'logs/r2_rgb2_raster_edges_20260914_a.log')
    rows=[fields(l) for l in t.splitlines() if l.startswith('C30_RASTER_EDGES_PASS ')]
    need({(r['sw'],r['sh'],r['polarity']) for r in rows}=={(w,h,p) for w,h in ((2,1),(2,3),(6,1),(6,3)) for p in (0,1)} and len(rows)==8,'raster edge matrix')
    need(all(r['frames']==6 and r['errors']==3 and r['coincident_close']==r['startup_partial']==r['reset_pending']==1 for r in rows),'raster edge coverage')
    need('C30_RASTER_EDGES_CLEAN configurations=8 temporary_simulator_removed=1' in t,'raster cleanup')
    metrics={}
    for kind,expected in (('capture_safe512',(1887,1642,19,18)),('rgb2_capture512',(2067,1772,20,18))):
        name=f'c30_{kind}_map_20260914_a'
        s=json.loads(read(ROOT/'logs/efinity_resource_runs'/name/'status.json'))
        need(s['state']=='complete' and s['exit_code']==0,'MAP incomplete')
        actual=tuple(s['metrics'][k] for k in ('le','registers','ebr','dsp'))
        need(actual==expected,'MAP resource mismatch')
        private=Path('C:/Users/30982/AppData/Local/Temp')/f'c1_efinity_resource_c1_ti60_r2_{kind}_{name}'
        need(not private.exists(),'MAP private directory remains')
        metrics[kind]=dict(zip(('lut4','ff','ram','dsp'),actual))
    print('C30_LEAF_PASS official_interior_pixels=240 wrong_raw_packing_rejected=1 resize_configurations=22 raster_edge_configurations=8')
    print('C30_MAP_PASS '+json.dumps(metrics,separators=(',',':'))+' pnr_claim=0 joint_fit_claim=0')


def capacity_boundaries():
    # These runs really failed; never turn their status into success. Early
    # missing-vector experiments are intentionally NOT performance evidence.
    for name,expected in (
        ('c30_camera_pair_native512_20260914_c',(6499,512,614,614,611,1099)),
        ('c30_camera_pair_native1024_20260914_a',(280710,1024,34560,34560,34560,96687)),
        ('c30_pair_overlap_native256_20260914_a',(5694,256,518,517,514,550))):
        folder=ROOT/'logs/r2_camera_pair_regression_runs'/name
        s=json.loads(read(folder/'status.json'))
        need(s['state']=='failed' and s['exit_code']!=0,'boundary failure was overwritten')
        t=read(folder/'stderr.log')
        lines=[r[r.index('C30_PAIR_NATIVE_FAILURE '):] for r in t.splitlines() if 'C30_PAIR_NATIVE_FAILURE ' in r]
        need(len(lines)==1,'no unique early overflow diagnostic')
        r=fields(lines[0])
        need(r['code']==2 and tuple(r[k] for k in ('cycle','peak_pairs','sample_requests','sample_responses','resize_pixels','input_waits'))==expected,'capacity boundary changed')
    folder=ROOT/'logs/r2_camera_pair_regression_runs/c30_pair_overlap_native512_20260914_a'
    _,t=completed(folder)
    need('C30_RESIZE_SELECTION overlap=1' in t,'successful paired run not using new Resize')
    need('checked_words=153600 peak=404' in t and 'aw=9600 b=9600' in t,'paired native actual work')
    print('C30_CAPACITY_BOUNDARY_PASS old_fifo512_overflow=1 old_fifo1024_overflow=1 new_fifo256_overflow=1 new_fifo512_native_pass=1')


def cleanup():
    # Read only this task's bounded run roots; no recursive scan of simulator
    # trees, no deletion, and no broad Temp search.
    count=files=size=0
    for root in ('r2_demo_rgb2_regression_runs','r2_camera_pair_regression_runs','r2_demo_rgb2_capture_xsim_runs','efinity_resource_runs'):
        for f in (ROOT/'logs'/root).glob('c30_*/status.json'):
            s=json.loads(read(f));need(s['state'] in ('complete','failed'),'C30 work still running '+f.parent.name)
            if 'run_directory' in s:need(not Path(s['run_directory']).exists(),'private sim remains')
            count+=1
            for item in f.parent.rglob('*'):
                if item.is_file():
                    need(item.suffix.lower() not in ('.wdb','.vcd','.vvp','.mem','.dcp'),'temporary binary/vector retained')
                    files+=1;size+=item.stat().st_size
    for prefix in ('c30_raster_edges_','c30_official_debayer_','c1_r2_demo_rgb2_capture_','c1_r2_camera_pair_capture_','c1_r2_resize_overlap_'):
        need(not any(p.is_dir() for p in (ROOT/'sim').glob(prefix+'*')),'temporary leaf simulation remains '+prefix)
    print(f'C30_CLEANUP_PASS terminal_runs={count} retained_files={files} retained_bytes={size} waves=0')


def main():
    source_gate();leaves_and_map();capacity_boundaries();regressions();cleanup()
    print('C30_GATE_PASS frontend_only=1 cnn_fps_claim=0 physical_cdc_signoff=0 board_claim=0')


if __name__=='__main__':main()
