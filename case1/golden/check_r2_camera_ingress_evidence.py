"""C25 camera/ROI/CDC protocol simulation + MAP evidence; not CNN/board signoff."""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from run_r2_camera_capture_probe import ROOT,SOURCES,EXTRA
from check_r2_resize_host_evidence import need,tokens,source_gate as retained_c24
from check_r2_graph_evidence import fields


def read(path):return (ROOT/path).read_text(encoding='utf-8-sig')
def rows(text,prefix):return [fields(s) for s in text.splitlines() if s.startswith(prefix+' ')]
def clean(text):need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired',text),'failed camera evidence')


def source_gate():
    old=retained_c24();need(old['source_files']==41,'retained C24 missing')
    for suffix,depth in [('',1024),('256',256),('512',512)]:
        name='c1_ti60_r2_camera_capture'+suffix
        p=ET.fromstring(read('efinity/'+name+'.xml'))
        sources=[x.attrib['name'] for x in p.iter() if x.tag.rsplit('}',1)[-1]=='design_file']
        need(len(sources)==14 and len(set(sources))==14 and set(sources)==set(['../'+s for s in SOURCES+EXTRA]+[name+'.sv']), 'wrong camera probe closure')
        probe=read('efinity/'+name+'.sv')
        need('input wire clk,rst,cam_clk,cam_rst,enable,cancel' in probe and 'c1_r2_resize_capture_rgbx32 u_capture' in probe, 'not actual two-clock Resize/Capture probe')
        if suffix:
            original=read('efinity/c1_ti60_r2_camera_capture.sv')
            expected=original.replace('c1_ti60_r2_camera_capture',name).replace('wire [10:0] cam_peak;',f'wire [{depth.bit_length()-1}:0] cam_peak;')
            expected=expected.replace('c1_r2_camera_ingress u_ingress',f'c1_r2_camera_ingress #(.FIFO_DEPTH({depth})) u_ingress')
            expected=expected.replace("16'd0,cam_peak",f"{27-depth.bit_length()}'d0,cam_peak")
            need(tokens(expected)==tokens(probe),'unequal FIFO capacity probe')
    front=tokens(read('rtl/r2/c1_r2_camera_ingress.sv'))
    for s in ('tail_write=cam_busy && source_end && tail_valid && !source_done && !source_bad && !abort_source;',
              'pixel_write=taking && !raster_bad && !cam_error && inside_roi && !last_roi && !abort_source;',
              'state==DRAIN && done_sync2 && done_settled && fifo_empty && (!owned || done_seen)',
              'result_admitted<=owned;', 'source_start=cam_valid && cam_sof && !cam_busy && enable_sync2 && !cancel_sync2 && GEOMETRY_OK;',
              '.wr_rst(cam_rst)', '.rd_rst(rst)'):
        need(tokens(s) in front,'missing tail/ownership/reset contract')
    fifo=tokens(read('rtl/r2/c1_r2_async_pixel_fifo.sv'))
    need(tokens('always_ff @(posedge rd_clk)if(load)out_data<=memory[rd_bin[AW-1:0]];') in fifo and
         tokens('rd_empty=!out_valid && ram_empty;') in fifo,'not synchronous RAM/prefetch drain')
    return dict(retained_c24=True,production_sources=13,new_production_modules=2,
                capture_included=True,cnn_host_connected=False,physical_cdc_verified=False)


def fifo_gate(text):
    clean(text);ps=rows(text,'C1_R2_ASYNC_PIXEL_FIFO_PASS')
    need(len(ps)==8 and {(p['depth'],p['wh'],p['rh']) for p in ps}=={(d,w,r) for d in (2,4,32,1024) for w,r in ((7,5),(5,11))},'missing FIFO clocks/capacities')
    for p in ps:
        need(p['epochs']==3 and p['words']==3*(p['depth']*3+137) and p['capacity']==p['depth']+1 and p['held']>0 and p['full_cycles']>0, 'FIFO storage/hold coverage wrong')
    need(text.count('C1_R2_ASYNC_PIXEL_FIFO_CLEAN temporary_simulator_removed=1')==1,'FIFO cleanup missing')
    return dict(configs=8,words=sum(p['words'] for p in ps),coordinated_reset_epochs=24,independent_clocks=True,metastability_simulated=False)


def capture_gate(text,expected_count=2):
    clean(text);ps=rows(text,'C1_R2_CAMERA_CAPTURE_PASS');rr=rows(text,'C1_R2_CAMERA_CAPTURE_RESULT')
    need(len(ps)==expected_count and len(rr)==21*expected_count,'missing capture recovery runs')
    codes={1:1,2:1,3:5,4:2,5:4,6:3,7:5,8:6,9:2,10:4}
    if expected_count==2:need({p['stalls'] for p in ps}=={0,1},'missing capture stall profile')
    for i,p in enumerate(ps):
        need(tuple(p[k] for k in ('sw','sh','rw','rh','ow','oh','fifo','results','good','bad','held_b','tail_errors','aw','b'))==
             (20,20,16,16,8,8,64,21,11,10,64,2,113,113), 'wrong capture/AXI/error totals')
        need(p['checked_words']==226 and p['peak']==64 and p['unstoppable_source']==p['no_reset_recovery']==1,'missing actual source or write check')
        batch=rr[i*21:(i+1)*21]
        need([r['tag'] for r in batch]==list(range(21)),'tag ownership discontinuity')
        need([r['mode'] for r in batch]==[0]+[x for f in range(1,11) for x in (f,0)],'missing per-error no-reset recovery')
        for r in batch:
            mode=r['mode'];need(r['code']==codes.get(mode,0) and r['failed']==int(mode!=0) and r['admitted']==int(mode not in (7,9)), 'wrong fault/admission provenance')
            if mode==0:need(r['roi_pixels']==256 and r['words']==16,'incomplete actual golden frame')
            if mode in (2,3):need(r['roi_pixels']==255 and r['words']==14,'tail failure escaped final-pixel fence')
            if mode==10:need(r['roi_pixels']==256 and r['words']==16,'last-cycle cancel was not at completion boundary')
            if mode in (7,9):need(r['roi_pixels']==r['words']==0,'pre-admission rejection wrote data')
    return dict(configs=expected_count,good=11*expected_count,expected_failures=10*expected_count,
                resize_words_checked=226*expected_count,source_tail_errors=2*expected_count,real_b_held_cycles=64)


def lifecycle_gate(text):
    clean(text);ps=rows(text,'C1_R2_CAMERA_LIFECYCLE_PASS');rr=rows(text,'C1_R2_CAMERA_LIFECYCLE_RESULT')
    need(len(ps)==2 and {p['stalls'] for p in ps}=={0,1} and len(rr)==10,'wrong lifecycle coverage')
    for i,p in enumerate(ps):
        need(tuple(p[k] for k in ('good','bad','source_frames','skipped','aw','b'))==(4,1,8,3,32,32), 'wrong whole-frame skip/lease accounting')
        need(all(p[k]==1 for k in ('held_completion_frame_skip','disable_owned_continues','unexpected_sof_recovery','no_reset')),'missing lifecycle invariant')
        need([r['tag'] for r in rr[i*5:(i+1)*5]]==[0,2,4,5,7],'skipped frame was spliced')
    need(text.count('C1_R2_CAMERA_LIFECYCLE_CLEAN temporary_vectors_and_simulator_removed=1')==1,'lifecycle cleanup missing')
    return dict(source_frames=16,skipped=6,good=8,unexpected_sof_errors=2,reset_used=False)


def xsim(run,depth,stalls,native=False,overflow=False):
    folder=Path('logs/r2_camera_capture_xsim_runs')/run
    s=json.loads(read(folder/'status.json'));t=read(folder/'result.log');meta=json.loads(read(folder/'metadata.json'));clean(t)
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim live/failed/in job/unclean')
    need(s['fifo_depth']==depth and s['stalls']==stalls and s['native_shape']==native and
         s.get('expected_overflow',False)==overflow and s['source_backpressure_allowed'] is False and
         s['cnn_performance_claim'] is False and meta['cnn_included'] is False,'wrong source/claim configuration')
    if not native:
        need(rows(t,'C1_R2_CAMERA_CAPTURE_PASS')[0]['stalls']==stalls,'wrong xsim result stall profile')
        return dict(run=run,seconds=s['elapsed_seconds'],**capture_gate(t,1),worker_in_windows_job=False)
    p=rows(t,'C1_R2_CAMERA_CAPTURE_PASS');results=rows(t,'C1_R2_CAMERA_CAPTURE_RESULT')
    need(len(p)==1 and len(results)==2 and [r['tag'] for r in results]==[0,1],'missing continuous native source frames')
    p=p[0];need(tuple(p[k] for k in ('sw','sh','rw','rh','ow','oh','fifo','stalls','results'))==
        (1920,1080,1440,1080,640,480,depth,stalls,2),'wrong native dimensions/clock profile')
    need(meta['parameters']['CORE_HALF']==3.333 and meta['parameters']['CAM_HALF']==6.734 and meta['parameters']['HBLANK']==280 and meta['parameters']['VBLANK']==45,
         'wrong source clock/raster timing')
    need(meta['plusargs']==dict(XS=147456,YS=147456,XP=40960,YP=40960),'wrong independent Q16 golden')
    # Older completed run retained the source profile in its bounded tail.
    profile=rows(t,'C1_R2_CAMERA_SOURCE_PROFILE') or rows(read(folder/'xsim.tail.log'),'C1_R2_CAMERA_SOURCE_PROFILE')
    need(len(profile)==1 and profile[0]['sof_interval_camera_cycles']==2475000 and profile[0]['faults']==0,'source cadence missing/modified')
    need(p['unstoppable_source']==1 and p['aw']==p['b'],'source backpressured or AXI not drained')
    if overflow:
        need(p['good']==0 and p['bad']==2 and p['peak']==128 and p['checked_words']==0 and
             all(r['failed']==1 and r['code']==2 and r['admitted']==1 for r in results), 'underprovisioned FIFO silently succeeded')
        need(rows(t,'C1_R2_CAMERA_CAPTURE_EXPECTED_OVERFLOW')==[dict(frames=2,whole_frame_drop=1,no_reset=1,fifo=128)],'missing deliberate negative-capacity marker')
    else:
        need((p['good'],p['bad'],p['roi_pixels'],p['checked_words'],p['aw'],p['peak'])==(2,0,3110400,153600,9600,193),'native pixels/transactions/watermark changed')
        need(all(r['failed']==r['code']==0 and r['admitted']==1 and r['roi_pixels']==1555200 and r['words']==76800 for r in results), 'native frame incomplete')
    return dict(run=run,seconds=s['elapsed_seconds'],fifo=depth,source_frames=2,good=p['good'],expected_overflows=p['bad'],
                roi_pixels=p['roi_pixels'],resize_words=p['checked_words'],peak_ram_level=p['peak'],
                source_sof_period_ns=2475000*13.468,worker_in_windows_job=False,private_removed=True,cnn_fps_claimed=False)


def physical(suffix,total_ram,ingress_ram):
    name='c1_ti60_r2_camera_capture'+suffix;run='c25_camera_capture'+suffix+'_map_20260913_a'
    folder=Path('logs/efinity_resource_runs')/run;s,m=(json.loads(read(folder/f)) for f in ('status.json','summary.json'))
    need(s['state']==m['state']=='complete' and s['exit_code']==0 and m['flow']=='map' and
         m['marker']==name.upper()+'_MAP_PASS' and m['device']=='Ti60F225' and m['family']=='Titanium','wrong physical MAP scope')
    metrics=m['metrics'];need(metrics['ebr']==total_ram and metrics['dsp']==18 and metrics['primitive_counts']['EFX_DSP48']==18,'unexpected camera RAM/arithmetic footprint')
    hierarchy=metrics['module_rows']
    fifo=[r for r in hierarchy if '+u_fifo:c1_r2_async_pixel_fifo' in r];front=[r for r in hierarchy if '+u_ingress:c1_r2_camera_ingress' in r]
    need(len(fifo)==len(front)==1 and re.search(r'\s'+str(ingress_ram)+r'\('+str(ingress_ram)+r'\)\s+0\(0\)\s*$',fifo[0]),'deep FIFO not mapped to expected native RAM')
    need(any('+u_capture:c1_r2_resize_capture_rgbx32' in r for r in hierarchy),'missing actual Capture connection')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_'+name+'_'+run)
    need(not private.exists(),'MAP private directory remains')
    return dict(run=run,lut4=metrics['le'],registers=metrics['registers'],ram=metrics['ebr'],dsp=18,
                fifo_ram=ingress_ram,route_timing_verified=False,physical_cdc_verified=False)


def main():
    emit=lambda name,value:print('C1_R2_C25_'+name+' '+json.dumps(value,separators=(',',':')),flush=True)
    emit('SOURCE_GATE_PASS',source_gate());emit('FIFO_GATE_PASS',fifo_gate(read('logs/r2_camera_fifo_20260913_a.log')))
    small=read('logs/r2_camera_capture_matrix_20260913_b.log')
    need(small.count('C1_R2_CAMERA_CAPTURE_CLEAN temporary_vectors_and_simulator_removed=1')==1,'capture cleanup missing')
    emit('CAPTURE_GATE_PASS',capture_gate(small))
    emit('LIFECYCLE_GATE_PASS',lifecycle_gate(read('logs/r2_camera_lifecycle_20260913_a.log')))
    emit('XSIM_SMALL_GATE_PASS',xsim('c25_camera_capture_xsim_small_20260913_b',64,1))
    for run,depth,stalls,bad in [('c25_camera_capture_xsim_1080_20260913_b',1024,0,False),
                               ('c25_camera_capture_xsim_1080_fifo256_20260913_a',256,1,False),
                               ('c25_camera_capture_xsim_1080_fifo512_20260913_a',512,1,False),
                               ('c25_camera_capture_xsim_1080_fifo128_20260913_a',128,0,True)]:
        emit('NATIVE_SOURCE_GATE_PASS',xsim(run,depth,stalls,True,bad))
    for suffix,total,ram in [('',20,3),('256',19,2),('512',19,2)]:emit('MAP_GATE_PASS',physical(suffix,total,ram))
    mutations=[('held_b=64','held_b=0'),('admitted=0','admitted=1'),('roi_pixels=255','roi_pixels=256'),
               ('code=4','code=0'),('aw=113 b=113','aw=113 b=112'),('unstoppable_source=1','unstoppable_source=0')]
    for old,new in mutations:
        need(old in small,'missing source evidence mutation')
        try:capture_gate(small.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('corrupt camera evidence accepted: '+old)
    emit('AUDIT_NEGATIVE_PASS',dict(rejected=6,undersized_fifo_actual_rtl_control=True))
    emit('PASS',dict(camera_frontend_stage=True,c24_main_host_retained=True,cnn_join_pending=True,
                     cdc_protocol_simulated=True,physical_cdc_verified=False,board_validation=False,cnn_fps_claimed=False))


if __name__=='__main__':main()
