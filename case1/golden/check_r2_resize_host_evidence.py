"""C24 actual Resize/host evidence; deliberately no board or native-FPS gate."""
from __future__ import annotations
import json
import re
from pathlib import Path
import check_r2_planned_host_evidence as c18
import check_r2_overlay_host_evidence as c22
import check_r2_resize_evidence as c23
from run_r2_resize_host_probe import ROOT, SOURCES, PLAN_SOURCE
from run_r2_overlay_host_probe import SOURCES as C22_SOURCES

need, tokens = c18.need, c22.tokens
PREFIX = 'C1_R2_RESIZE_HOST_SYSTEM_'
FAULT = 'C1_R2_RESIZE_HOST_FAULT_'


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def rows(text, key, prefix=PREFIX):
    return [c18.c12.fields(x) for x in text.splitlines() if x.startswith(prefix+key+' ')]


def clean(text):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired', text), 'failed C24 evidence')


def translated(text, prefix=PREFIX):
    # Rejections are checked separately below, then excluded ONLY from the
    # inherited successful-admission timeline. Never invent a completion.
    return '\n'.join(x.replace(prefix, c18.PREFIX) for x in text.splitlines()
                     if not (x.startswith(prefix+'REQUEST ') and c18.c12.fields(x)['ready']==0))


def groups(text, prefix=PREFIX):
    part=[]
    for line in text.splitlines():
        part.append(line)
        if line.startswith(prefix+'PLAN '):
            yield '\n'.join(part)
            part=[]
    need(not any(x.startswith(prefix+'PASS ') for x in part), 'unterminated C24 profile')


def source_gate():
    retained=c23.source_gate()
    removed={'rtl/r2/c1_r2_overlay_host_system.sv','rtl/r2/c1_r2_video_overlay_system.sv'}
    added={'rtl/r2/c1_r2_resize_host_system.sv','rtl/r2/c1_r2_video_resize_system.sv',
           'rtl/r2/c1_r2_resize_capture_rgbx32.sv',*c23.SOURCES[1:]}
    need(len(SOURCES)==len(set(SOURCES))==41 and set(SOURCES)==set(C22_SOURCES)-removed|added,
         'wrong C24 source closure')
    need(SOURCES.count(PLAN_SOURCE)==1 and all((ROOT/s).is_file() for s in SOURCES), 'missing C24 source/plan')
    ports='''input wire [15:0] source_width,source_height,s_x,s_y,
        input wire signed [31:0] source_x_step_q16,source_y_step_q16,source_x_phase0_q16,source_y_phase0_q16,
        input wire source_cancel,
        output wire s_ready,source_config_error,source_error,
        output wire [3:0] source_error_code,'''
    binding='''.source_width(source_width),.source_height(source_height),.s_x(s_x),.s_y(s_y),
        .source_x_step_q16(source_x_step_q16),.source_y_step_q16(source_y_step_q16),
        .source_x_phase0_q16(source_x_phase0_q16),.source_y_phase0_q16(source_y_phase0_q16),
        .source_cancel(source_cancel),.s_ready(s_ready),.source_config_error(source_config_error),
        .source_error(source_error),.source_error_code(source_error_code),'''
    host=read('rtl/r2/c1_r2_resize_host_system.sv').replace('c1_r2_resize_host_system','c1_r2_overlay_host_system').replace('c1_r2_video_resize_system','c1_r2_video_overlay_system')
    need(tokens(host).replace(tokens(ports),'').replace(tokens(binding),'')==tokens(read('rtl/r2/c1_r2_overlay_host_system.sv')),
         'host changed beyond new source ports/forwarding')
    video=read('rtl/r2/c1_r2_video_resize_system.sv')
    wrapper=read('rtl/r2/c1_r2_resize_capture_rgbx32.sv')
    for fragment in ('.cap_request(cap_admission)', 'if(cap_admission)begin',
                     'source_width_q<=source_width;source_height_q<=source_height;',
                     'if(source_cancel && cap_active && !cap_event)source_cancel_q<=1;',
                     '.cancel(source_cancel_q || source_cancel)', '.cfg_source_width(source_width_q)',
                     'source_config_error=capture_request && !source_legal'):
        need(tokens(fragment) in tokens(video), 'missing source admission/cancel contract')
    for fragment in ('wire terminal=cap_done && !resize_busy;', 'wire mutable_job=owned && !terminal;',
                     'wire stop=owned && (failed_q || stop_trigger);', '.REGISTER_ABORT_RESET(1)',
                     'c1_r2_video_capture_rgbx32', '.cancel(stop && !cap_done)',
                     'assign cap_done_ready=done_valid && done_ready;', 'failed_q<=cancel;'):
        need(tokens(fragment) in tokens(wrapper), 'missing child ownership/drain fence')
    # DAG execution and parameter construction stay independent of RTL slot
    # execution. Only the fixture's input image is preprocessed differently.
    old=read('golden/r2_plan_vectors.py');new=read('golden/r2_resize_plan_vectors.py')
    need(old[old.index('def infer('):old.index('def vectors(')]==new[new.index('def infer('):new.index('def vectors(')], 'changed CNN oracle')
    need('rgb = resize_bilinear_q16_u8(source,width,height)' in new and
         'source = source_image(sw,sh,30+frame)' in new, 'missing independent source/Resize oracle')
    return dict(source_files=41,retained_c22=retained['c22_preserved'],new_production_modules=3,
                actual_resize_capture=True,host_abi_preserved=True,cpu_source_config_registers=False)


def source_run(text, prefix=PREFIX, bad=None):
    p=rows(text,'PASS',prefix)[0];rr=rows(text,'RESIZE',prefix)
    need(len(rr)==1,'missing/duplicate Resize accounting')
    r=rr[0];w,h=p['width'],p['height'];n=p['captures']
    src=[dict(width=2*w,height=2*h),dict(width=w*3//2+1,height=h*3//2+3)]
    extra=0 if bad is None else bad['source_pixels']
    need((r['frames'],r['destination_pixels'],r['source_pixels'])==
         (n,n*w*h,src[0]['width']*src[0]['height']+(n-1)*src[1]['width']*src[1]['height']+extra), 'wrong Resize pixel/frame accounting')
    need(r['config_rejections']==3 and r['actual_preprocessor']==r['source_backpressure_allowed']==1,
         'missing actual Resize/source scope')
    req=rows(text,'REQUEST',prefix);rejected=[x for x in req if x['ready']==0];accepted=[x for x in req if x['ready']==1]
    need(len(rejected)==3 and req[:3]==rejected and all(x['tag']==0 and x['lease_owned']==x['pending']==0 for x in rejected),
         'unexpected or unowned configuration rejection')
    need(all(x['cycle']<accepted[0]['cycle'] for x in rejected), 'rejection overlap with live frame')
    configs=rows(text,'SOURCE_CONFIG',prefix)
    need(len(configs)==len(accepted)==n+int(bad is not None) and [x['tag'] for x in configs]==[x['tag'] for x in accepted],
         'source configuration/admission mismatch')
    from r1_isp import resize_axis_q16
    for c in configs:
        s=src[int(c['tag']!=0)];xs,xp=resize_axis_q16(s['width'],w);ys,yp=resize_axis_q16(s['height'],h)
        need(tuple(c[k] for k in ('width','height','xs','ys','xp','yp'))==(s['width'],s['height'],xs,ys,xp,yp), 'wrong actual Resize configuration')
    return r


def matrix(text, profile):
    clean(text);parts=list(groups(text));need(len(parts)==4,'wrong matrix count')
    accounted=[source_run(t) for t in parts]
    result=c18.matrix(translated(text),profile)
    return dict(**result,source_pixels=sum(r['source_pixels'] for r in accounted),
                resized_pixels=sum(r['destination_pixels'] for r in accounted),config_rejections=12,
                native_fps_claimed=False)


def capture_gate(text):
    clean(text);prefix='C1_R2_RESIZE_VIDEO_'
    ps=rows(text,'DMA_PASS',prefix);front=rows(text,'FRONTEND_PASS',prefix)
    need(len(ps)==len(front)==4 and {(p['stalls'],p['aw_wait_w']) for p in ps}=={(s,a) for s in (0,1) for a in (0,2)}, 'missing capture wait profiles')
    for p,f in zip(ps,front):
        need(tuple(p[k] for k in ('width','height','captures','scans','pixels','overflow','underflow','aw','b'))==(8,12,12,7,1152,1,1,87,87), 'wrong capture/drain counts')
        need(f['held_late_cancel']==12 and f['cancel_on_command']==f['actual_resize']==1 and f['source_accepted']>2900, 'missing completion/cancel checks')
    cap=rows(text,'CAPTURE_PASS',prefix)
    need(len(cap)==48 and all(sum(r['fault']==mode for r in cap)==4 for mode in range(1,6)), 'missing actual capture faults')
    need(text.count('C1_R2_RESIZE_CAPTURE_CLEAN temporary_simulator_removed=1')==1,'capture cleanup missing')
    return dict(captures=48,scans=28,pixels=4608,fault_cases=20,held_late_cancels=48,cancel_on_command=4)


def fault_gate(text,mode):
    clean(text);parts=list(groups(text,FAULT));need(len(parts)==2,'wrong fault profile count')
    c18.planned_profiles(translated(text,FAULT),'microstyle24',2)
    ps=[];later_starts=0
    for t in parts:
        p=rows(t,'PASS',FAULT)[0];ps.append(p)
        failed=rows(t,'FAILED',FAULT);recovered=rows(t,'RECOVERY',FAULT)
        need(len(failed)==len(recovered)==1,'missing failed capture/recovery')
        f,r=failed[0],recovered[0];hold=0 if mode==1 else 64
        need(f['mode']==r['mode']==mode and f['tag']==1 and f['capture_debt']==0 and f['held_cycles']==r['held_cycles']==hold, 'wrong failed owner/B drain')
        need((f['writes']==f['source_pixels']==0) if mode==1 else (f['writes']>0 and f['source_pixels']>0), 'fault not at claimed transaction phase')
        need(r['failed_captures']==1 and r['post_fault_nn']==3 and r['error_irq']==r['failed_front_forbidden']==1 and r['reset_used']==0, 'fault recovery incomplete')
        source_run(t,FAULT,f)
        starts=rows(t,'NN_START',FAULT);frames=rows(t,'FRAME',FAULT);captures=rows(t,'CAPTURE',FAULT)
        need(len(starts)==len(frames)==p['cnn_frames']==3 and len(captures)==p['captures'], 'fault success counts wrong')
        need([c['tag'] for c in captures]==[i for i in range(p['captures']+1) if i!=1], 'failed capture became ready/missing successful capture')
        done={c['tag']:c['cycle'] for c in captures}
        ends=[]
        for s,x in zip(starts,frames):
            c18.c12.frame(x)
            need(s['tag']==x['tag'] and s['tag'] in done and s['cycle']>done[s['tag']], 'CNN used failed/premature raw frame')
            if ends:need(s['cycle']>=ends[-1],'overlapping fault CNN jobs')
            ends.append(s['cycle']+x['cycles']+1)
        fresh=[s for s in starts if s['cycle']>f['cycle'] and s['tag']>1]
        need(len(fresh)>=1,'no newly started post-fault inference')
        later_starts+=len(fresh)
        fronts=rows(t,'FRONT',FAULT)
        need(len(fronts)==p['displays'] and all(x['tag']!=1 and x['tag'] in done for x in fronts), 'failed frame displayed/missing display trace')
        need(p['native_timing']==p['underflow']==p['display_misses']==0 and
             p['good_pixels']==p['displays']*2*p['width']*p['height'] and p['good_pixels']>0 and
             p['cpu_r']>0 and p['cpu_w']>0 and p['nn_interval']==ends[-1]-ends[-2], 'wrong fault host/display result')
    need({p['stalls'] for p in ps}=={0,1} and all(p['width']==p['height']==8 for p in ps), 'wrong fault matrix')
    need(text.count(FAULT+'CLEAN temporary_vectors_and_simulator_removed=1')==1,'fault cleanup missing')
    return dict(mode=mode,configs=2,failed_captures=2,successful_inferences=6,
                newly_started_after_failure=later_starts,real_b_hold_cycles=hold,no_reset=True)


def physical():
    run='c24_resize_host96_i3_20260913_a';folder=Path('logs/efinity_resource_runs')/run
    s,m=(json.loads(read(folder/n)) for n in ('status.json','summary.json'))
    need(s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0 and
         m['marker']=='C1_TI60_R2_RESIZE_HOST96_MAP_PNR_PASS' and
         m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr','wrong physical result')
    need('--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'),'wrong speed grade')
    r,t=m['pnr_resources'],m['timing']
    need((r['xlr_cells_used'],r['memory_blocks_used'],r['dsp_blocks_used'])==(43665,146,130),'unexpected/pruned physical resources')
    need(m['metrics']['primitive_counts']['EFX_DSP24']==96 and m['metrics']['primitive_counts']['EFX_DSP48']==34,'wrong arithmetic footprint')
    hierarchy=set(m['metrics']['module_rows']+m['metrics'].get('module_focus_rows',[]))
    for name in ('+u_host:c1_r2_resize_host_system','+u_system:c1_r2_video_resize_system',
                 '+u_capture:c1_r2_resize_capture_rgbx32','+u_resize:c1_r2_resize_pipeline',
                 '+u_capture:c1_r2_video_capture_rgbx32','+u_cnn:c1_r2_overlay_rgbx_axi_graph'):
        need(sum(name in row for row in hierarchy)==1,'missing actual joined hierarchy: '+name)
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_period_ns']+t['final_slack_ns']-6.666)<.002,'150MHz timing failure')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_resize_host96_'+run)
    need(not private.exists(),'PNR private directory remains')
    return dict(run=run,xlr=43665,ram=146,dsp=130,setup_ns=t['final_slack_ns'],hold_ns=t['final_hold_slack_ns'],
                actual_resize_host=True,cpu_ip_isp_phy_cdc=False,board_resources_closed=False)


def xsim():
    run='c24_resize_host_xsim_12x12_20260913_a';folder=Path('logs/r2_resize_host_xsim_runs')/run
    s=json.loads(read(folder/'status.json'));text=read(folder/'result.log');clean(text)
    need(s['state']=='complete' and s['exit_code']==0 and s['worker_in_windows_job'] is False and
         not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim incomplete/in job/unclean')
    need(tuple(s[k] for k in ('width','height','stalls','aw_wait_w','nn_target','memory_div','command_latency'))==(12,12,1,2,6,2,20), 'wrong xsim profile')
    need(s['camera_backpressure_allowed'] is True and s['performance_claim'] is False,'wrong xsim claim')
    source_run(text);nt=translated(text);c18.planned_profiles(nt,'microstyle24',1);nt=c18.normalized(nt)
    p=c18.c12.rows(nt,'PASS')[0];fs=c18.c12.rows(nt,'FRAME');c18.run(p,fs,nt,'microstyle24')
    meta=json.loads(read(folder/'metadata.json'))
    need(meta['actual_resize_golden'] is True and len(meta['sources'])==2,'wrong xsim golden')
    package=c18.compile_package(c18.profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv')==package.plan_sv and json.loads(read(folder/'plan_manifest.json'))==json.loads(json.dumps(package.manifest)),'wrong xsim plan package')
    return dict(run=run,seconds=s['elapsed_seconds'],cnn_frames=6,frame_cycles=[f['cycles'] for f in fs],
                good_display_pixels=p['good_pixels'],worker_in_windows_job=False,private_removed=True,native_fps_claimed=False)


def main():
    emit=lambda name,value:print('C1_R2_C24_'+name+' '+json.dumps(value,separators=(',',':')),flush=True)
    emit('SOURCE_GATE_PASS',source_gate())
    main=read('logs/r2_resize_host_matrix_20260913_a.log');variant=read('logs/r2_resize_host_variant_20260913_a.log')
    emit('SYSTEM_GATE_PASS',matrix(main,'microstyle24'));emit('VARIANT_GATE_PASS',matrix(variant,'drop_res1'))
    emit('CAPTURE_GATE_PASS',capture_gate(read('logs/r2_resize_capture_20260913_a.log')))
    emit('RAM_NEGATIVE_PASS',c18.negative(translated(read('logs/r2_resize_host_negative_20260913_a.log'))))
    for mode,suffix in [(1,'d'),(2,'b'),(3,'b')]:
        emit('FAULT_GATE_PASS',fault_gate(read(f'logs/r2_resize_host_fault{mode}_20260913_{suffix}.log'),mode))
    emit('PHYSICAL_GATE_PASS',physical());emit('XSIM_GATE_PASS',xsim())
    changes=[('actual_preprocessor=1','actual_preprocessor=0'),('config_rejections=3','config_rejections=2'),
             ('source_pixels=3181','source_pixels=3180'),('ready=0','ready=1'),('underflow=0','underflow=1')]
    for old,new in changes:
        need(old in main,'missing evidence mutation')
        try:matrix(main.replace(old,new,1),'microstyle24')
        except ValueError:pass
        else:raise ValueError('corrupt C24 evidence accepted: '+old)
    faults=read('logs/r2_resize_host_fault2_20260913_b.log')
    for old,new in [('capture_debt=0','capture_debt=1'),('held_cycles=64','held_cycles=0'),('error_irq=1','error_irq=0'),('reset_used=0','reset_used=1'),('FRONT tag=0','FRONT tag=1')]:
        need(old in faults,'missing fault mutation')
        try:fault_gate(faults.replace(old,new,1),2)
        except ValueError:pass
        else:raise ValueError('corrupt C24 fault evidence accepted: '+old)
    emit('AUDIT_NEGATIVE_PASS',dict(rejected=10,actual_rtl_faults_separately_tested=True))
    emit('PASS',dict(local_resize_host_stage=True,board_validation=False,model_quality_validated=False,native_fps_claimed=False))


if __name__=='__main__':
    main()
