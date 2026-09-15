"""Independent C39 phase checks: actual commands, graph math, full host contract.

--allow-running verifies ONLY an already exited phase inside a live pipeline.
It never asserts the entire run finished, cleaned up, or met a frame-rate goal.
"""
import argparse
import json
from pathlib import Path
import re

from c39_onehot_trained_contract import ROOT,bound_candidate,candidate_nodes,camera_geometry
from r2_row_fused_plan import fused_steps,fusion_sv
from r2_execution_plan import render_sv
from check_r2_trained_host_evidence import check_text,corruption_checks,PREFIX,traffic
from check_r2_fused_xsim_evidence import configuration
from c39_native_performance_contract import require_native_target
from c39_onehot_trained_contract import SOURCES,PLAN_SOURCE,FUSION_SOURCE,TOP,SIM,source_gate
from run_c39_onehot_trained_host_probe import CASES
from r2_camera_cadence_contract import profile as camera_config,render_testbench,assess as assess_camera


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def one_json(text,prefix):
    rows=[json.loads(line[len(prefix):]) for line in text.splitlines() if line.startswith(prefix)]
    if len(rows)!=1:
        raise ValueError('missing/duplicate JSON evidence: '+prefix)
    return rows[0]


def verify_history(status,names):
    for name in names:
        rows=[row for row in status['completed_steps'] if row['name']==name]
        if len(rows)!=1 or rows[0]['exit_code']!=0 or rows[0]['in_windows_job'] is not False:
            raise ValueError('phase exit/Job evidence absent: '+name)
        if rows[0]['free_memory_kib_at_phase_admission']<8388608:
            raise ValueError('phase has no 8 GiB memory admission')


def predecessor_contract(status,prior):
    """A short predecessor proves only small; never reinterpret it as native."""
    pred=status.get('predecessor') or {}
    if type(prior.get('skip_native')) is not bool:
        raise ValueError('predecessor terminal phase is not explicit')
    phase='small' if prior['skip_native'] else 'native'
    if (pred.get('run')!=status['after_run'] or prior.get('run_id')!=status['after_run'] or
        pred.get('worker_pid')!=prior.get('worker_pid') or pred.get('worker_start')!=prior.get('worker_start') or
        pred.get('strict_preflight_phase','native')!=phase or
        pred.get('strict_native_preflight_required') is not (phase=='native')):
        raise ValueError('missing explicit predecessor identity/phase binding')
    if (prior.get('state')!='complete' or prior.get('exit_code')!=0 or
        prior.get('simulator_directory_present') is not False or prior.get('worker_in_windows_job') is not False):
        raise ValueError('predecessor not terminal and clean')
    verify_history(status,['predecessor_'+phase+'_preflight'])
    return phase


def matrix(folder,status,config,provenance):
    verify_history(status,['host_matrix'])
    text=(folder/'host_matrix.result.log').read_text(encoding='utf-8-sig')
    if (folder/'host_matrix.stderr.log').read_text(encoding='utf-8-sig').strip():
        raise ValueError('matrix stderr not empty')
    entries=list(re.finditer(r'^C39_ONEHOT_TRAINED_HOST_CASE_BEGIN ([^\r\n]+)\r?\n(.*?)^C39_ONEHOT_TRAINED_HOST_CASE_END (\S+)\s*$',text,re.M|re.S))
    if len(entries)!=6 or len(CASES)!=6:
        raise ValueError('missing matrix cases')
    results=[]
    for expected,entry in zip(CASES,entries):
        if json.loads(entry[1])!=expected or entry[3]!=expected['id']:
            raise ValueError('case identity/order mismatch')
        body=entry[2]
        command=one_json(body,'C39_ONEHOT_ACTUAL_COMPILE ')
        parameters={}
        for word in command:
            if word.startswith('-P'+TOP+'.'):
                key,value=word.split('=',1)
                key=key.split('.',1)[1]
                if key in parameters:
                    raise ValueError('duplicate Icarus parameter')
                parameters[key]=int(value)
        sw,sh,rx,ry,rw,rh=camera_geometry(expected['width'],expected['height'])
        desired=dict(WIDTH=expected['width'],HEIGHT=expected['height'],STALLS=expected['stalls'],AW_WAIT_W=2,
                     MEMORY_DIV=2,COMMAND_LATENCY=20,FRAME_DIVISOR=2,CAMERA_SW=sw,CAMERA_SH=sh,
                     CAMERA_RX=rx,CAMERA_RY=ry,CAMERA_RW=rw,CAMERA_RH=rh,NN_TARGET=2,
                     NEGATIVE_CONTROL=expected['negative'],STAGE_COUNT=18,RGB_STAGE=16,FUSED_DW_STAGE=14,FUSED_PW_STAGE=15)
        if parameters!=desired or command[:4]!=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP]:
            raise ValueError('actual Icarus elaboration differs from matrix')
        private=Path(status['run_directory'])/'matrix'/expected['id']
        source_paths=[(ROOT/s).resolve() for s in SOURCES if s not in (PLAN_SOURCE,FUSION_SOURCE)]
        source_paths += [(private/'package/execution_plan.sv').resolve(),(private/'fusion_plan.sv').resolve()]
        source_paths += [(ROOT/s).resolve() for s in SIM]+[(ROOT/f'sim/{TOP}.sv').resolve()]
        if [Path(word).resolve() for word in command if word.endswith('.sv')]!=source_paths:
            raise ValueError('actual Icarus sources differ from explicit C39 native closure plus two trained plans')
        run_command=one_json(body,'C39_ONEHOT_ACTUAL_RUN ')
        if run_command[:2]!=['D:/iverilog/bin/vvp.exe',str(private/'host.vvp')]:
            raise ValueError('executed a different compiled snapshot')
        plusargs={}
        for argument in run_command[2:]:
            key,value=argument.removeprefix('+').split('=',1)
            if key in plusargs:
                raise ValueError('duplicate fixture argument')
            plusargs[key]=value
        b=traffic(config,expected['width'],expected['height'])
        parameter_words=bound_candidate(status['qat_run'])[0].manifest['transfer_beats128']
        for key,value in dict(P=parameter_words,I=expected['width']*expected['height']//2,
                              E=2*(b['writes']+expected['width']*expected['height']//4),
                              DW=6*expected['width']*expected['height']).items():
            if plusargs.get(key)!=str(value):
                raise ValueError('wrong actual matrix fixture size: '+key)
        if Path(plusargs['DIR']).resolve()!=private.resolve():
            raise ValueError('wrong actual matrix fixture directory')
        if expected['negative']:
            observed=one_json(body,'C39_ONEHOT_NEGATIVE_OBSERVED ')
            fatal={1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[expected['negative']]
            if (observed['exit_code']==0 or observed['actual_RAM_mutation'] is not True or observed['expected_failure']!=fatal or
                not observed['fatal_lines'] or not all(fatal in line and 'FATAL' in line for line in observed['fatal_lines'])):
                raise ValueError('no actual expected RAM corruption failure')
            if PREFIX+'PASS ' in body:
                raise ValueError('negative execution passed')
        else:
            actual=check_text(body,config,2)
            printed=one_json(body,'C39_ONEHOT_POSITIVE_CHECK ')
            if any(printed[k]!=v for k,v in actual.items()):
                raise ValueError('printed result differs from actual checkpoints')
            rejected=corruption_checks(body,config,2)
            if rejected!=printed['evidence_corruption_rejections']:
                raise ValueError('corruption checker result mismatch')
            results.append(dict(case=expected['id'],**actual))
    summary=one_json(text,'C39_ONEHOT_TRAINED_HOST_MATRIX_PASS ')
    if summary['model_binding']!=provenance or (summary['positive_configurations'],summary['correct_CNN_frames'],summary['actual_RAM_corruption_controls'])!=(4,8,2):
        raise ValueError('incorrect matrix summary')
    return dict(positive_configurations=4,correct_CNN_frames=8,actual_RAM_corruption_controls=2,
                evidence_corruption_rejections=16,actual_AXI=True,native_fps_claim=False,results=results)


def xsim(folder,status,phase,config,provenance):
    verify_history(status,[phase+'_'+step for step in ('vectors','xvlog','xelab','xsim')])
    meta=load(folder/(phase+'.metadata.json'))
    native=phase=='native'
    camera_profile=status.get('camera_profile','legacy') if native else 'legacy'
    cadence=camera_config(camera_profile)
    width,height=(640,480) if native else (8,8)
    nn=6 if native else 2
    if (meta['width'],meta['height'])!=(width,height) or meta['model_binding']!=provenance:
        raise ValueError('wrong model/source/geometry metadata')
    package,_,_=bound_candidate(status['qat_run'])
    steps,pairs=fused_steps(candidate_nodes(**config))
    if meta['stage_count']!=len(steps) or pairs!=[(meta['dw_stage'],meta['pw_stage'])]:
        raise ValueError('wrong generated fusion pair')
    for file,expected in ((phase+'.execution_plan.sv',render_sv(steps)),(phase+'.fusion_plan.sv',fusion_sv(steps,pairs))):
        if (folder/file).read_text(encoding='utf-8-sig').strip()!=expected.strip():
            raise ValueError('actual retained plan differs from trained graph')
    if meta['dw_packets']!=6*width*height or meta['parameter_words']!=package.manifest['transfer_beats128']:
        raise ValueError('incomplete internal DW or trained parameter vectors')
    directory=Path(status['run_directory'])/phase
    expected_sources=[(ROOT/s).resolve() for s in SOURCES if s not in (PLAN_SOURCE,FUSION_SOURCE)]
    expected_sources += [(directory/'package/execution_plan.sv').resolve(),(directory/'fusion_plan.sv').resolve()]
    if [Path(s).resolve() for s in load(folder/(phase+'.sources.json'))]!=expected_sources or len(expected_sources)!=49:
        raise ValueError('wrong production source closure')
    invocation=(folder/(phase+'_xvlog.sources.log')).read_text(encoding='utf-8-sig')
    actual_sources=[Path(word).resolve() for word in re.findall(
        r'^INFO: \[VRFC 10-2263\] Analyzing SystemVerilog file "([^"]+\.sv)" into library work\s*$',invocation,re.M)]
    testbench=(ROOT/f'sim/{TOP}.sv').resolve()
    if camera_profile!='legacy':
        verify_history(status,[phase+'_camera_fixture'])
        generated,metadata=render_testbench(testbench.read_text(encoding='utf-8-sig'),camera_profile)
        if (folder/(phase+'.testbench.sv')).read_text(encoding='utf-8-sig')!=generated:
            raise ValueError('retained camera testbench differs from explicit two-constant variant')
        if load(folder/(phase+'.cadence.json'))!=metadata:
            raise ValueError('retained camera timing fixture metadata differs')
        fixture_line=one_json((folder/(phase+'_camera_fixture.tail.log')).read_text(encoding='utf-8-sig'),
                              'C36_CAMERA_CADENCE_FIXTURE_PREPARED ')
        if fixture_line!=metadata:
            raise ValueError('actual preparer did not emit the requested camera fixture')
        testbench=(directory/'camera_fixture'/f'{TOP}.sv').resolve()
    required=expected_sources+[(ROOT/s).resolve() for s in SIM]+[testbench]
    if actual_sources!=required:
        raise ValueError('actual compiled sources differ from declared closure')
    conditions=dict(width=width,height=height,memory_div=2,command_latency=20,stalls=0 if native else 1,
                    aw_wait_w=2,nn_target=nn,frame_divisor=cadence['frame_divisor'],clocks_native=1,cpu_start_negative=0)
    elaboration=(folder/(phase+'_xelab.tail.log')).read_text(encoding='utf-8-sig')
    ddr=configuration(elaboration,conditions,meta)
    launch=(folder/(phase+'_xsim.invocation.log')).read_text(encoding='utf-8-sig')
    if len(re.findall(r'^# xsim \{c39_onehot_trained_'+phase+r'\}',launch,re.M))!=1:
        raise ValueError('missing/duplicate actual xsim Tcl launch record')
    for name,value in (('P',meta['parameter_words']),('I',meta['input_words']),('E',meta['expected_words']),('DW',meta['dw_packets'])):
        if re.findall(r'-testplusarg\s+'+name+r'=(\d+)(?=\s|$)',launch)!=[str(value)]:
            raise ValueError('actual xsim fixture size not proven: '+name)
    text=(folder/(phase+'_xsim.result.log')).read_text(encoding='utf-8-sig')
    result=check_text(text,config,nn,clock_native_override=None if native else 1,camera_profile=camera_profile)
    if (result['width'],result['height'],result['stalls'])!=(width,height,conditions['stalls']):
        raise ValueError('actual result configuration mismatch')
    rejected=corruption_checks(text,config,nn,None if native else 1,camera_profile)
    if native:
        startup=baseline_start(text,'CPU_START')
        early=baseline_start(text,'CPU_EARLY')
        if startup['native_clocks']!=1 or startup['active']!=1 or startup['full_core_pulse']!=1 or min(early['reads'],early['writes'])<2:
            raise ValueError('native CPU startup/early traffic missing')
        performance=require_native_target(result['completion_intervals'])
        performance['camera_preprocessing']=assess_camera(text,camera_profile)
        if cadence['require_capture_30fps'] and not performance['camera_preprocessing']['capture_30fps_met_for_observed_intervals']:
            raise ValueError('actual completed-capture intervals did not meet 30 fps')
    else:
        performance=dict(native_fps_claim=False)
    return dict(result,**performance,ddr_model=ddr,evidence_corruption_rejections=len(rejected),
                trained_parameter_words=meta['parameter_words'],new_model_RTL_simulated=True)


def baseline_start(text,kind):
    from check_r2_rgb2_host_evidence import one
    return one(text,kind,PREFIX)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',required=True)
    parser.add_argument('--phase',choices=('matrix','small','native'),required=True)
    parser.add_argument('--allow-running',action='store_true')
    args=parser.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+',args.run):
        raise ValueError('invalid run')
    folder=ROOT/'logs/c39_onehot_trained_host_runs'/args.run
    status=load(folder/'status.json')
    private=ROOT/'sim'/('c1_c39_onehot_trained_host_'+args.run)
    if status['run_id']!=args.run or Path(status['run_directory']).resolve()!=private.resolve() or status['worker_in_windows_job'] is not False:
        raise ValueError('wrong run identity/Job')
    if status.get('production_RTL_changed') is not True or status.get('candidate')!='C39_ONEHOT':
        raise ValueError('C39 candidate provenance missing')
    workload=status['workload_budget']
    if workload['policy']!='single-heavy-worker' or workload['logical_processors'] not in (1,2) or workload['priority']!='BelowNormal':
        raise ValueError('wrong workload budget')
    if status.get('after_run'):
        if not re.fullmatch('[A-Za-z0-9_-]+',status['after_run']) or status['after_run']==args.run:
            raise ValueError('invalid predecessor run')
        prior=load(folder.parent/status['after_run']/'status.json')
        prior_phase=predecessor_contract(status,prior)
        prior_private=ROOT/'sim'/('c1_c39_onehot_trained_host_'+status['after_run'])
        if Path(prior['run_directory']).resolve()!=prior_private.resolve() or prior_private.exists():
            raise ValueError('predecessor private directory not proven clean')
        prior_payload=one_json((folder/('predecessor_'+prior_phase+'_preflight.tail.log')).read_text(encoding='utf-8-sig'),
                               'C39_ONEHOT_TRAINED_PIPELINE_PHASE_PASS ')
        if (prior_payload['run']!=status['after_run'] or prior_payload['phase']!=prior_phase or
            prior_payload['phase_only'] is not False or prior_payload['entire_pipeline_complete'] is not True or
            prior_payload['temporary_removed'] is not True):
            raise ValueError('actual predecessor preflight did not prove the expected terminal phase')
    verify_history(status,['c39_onehot_operator_preflight','c39_onehot_source_preflight'])
    from c39_onehot_operator_preflight import check as operator_check
    observed=one_json((folder/'c39_onehot_operator_preflight.tail.log').read_text(encoding='utf-8-sig'),
                      'C39_ONEHOT_OPERATOR_PREFLIGHT_PASS ')
    if observed!=operator_check():
        raise ValueError('operator preflight differs from actual full-run evidence')
    from c39_joint_cdc_evidence import check as check_joint
    observed_joint=one_json((folder/'c39_onehot_source_preflight.tail.log').read_text(encoding='utf-8-sig'),
                            'C39_JOINT_CDC_EVIDENCE_PASS ')
    if observed_joint!=check_joint('c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc'):
        raise ValueError('joint mapped CDC/timing preflight differs from actual evidence')
    camera_config(status.get('camera_profile','legacy'))
    if status.get('skip_native') and status.get('camera_profile','legacy')!='legacy':
        raise ValueError('new camera profile requires a native phase')
    if args.allow_running:
        if status['state']!='running':
            raise ValueError('phase-local mode requires a running pipeline')
    elif status['state']!='complete' or status['exit_code']!=0 or private.exists() or status['simulator_directory_present']:
        raise ValueError('whole pipeline not complete and clean')
    _,config,provenance=bound_candidate(status['qat_run'])
    result=matrix(folder,status,config,provenance) if args.phase=='matrix' else xsim(folder,status,args.phase,config,provenance)
    source_gate()
    payload=dict(result)
    payload.update(run=args.run,phase=args.phase,phase_only=args.allow_running,entire_pipeline_complete=not args.allow_running,
                   temporary_removed=not private.exists(),physical_CDC_signoff=False,board_frequency_measured=False)
    print('C39_ONEHOT_TRAINED_PIPELINE_PHASE_PASS '+json.dumps(payload,separators=(',',':')))


if __name__=='__main__':
    main()
