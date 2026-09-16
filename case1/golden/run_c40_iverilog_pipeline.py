"""C39-equivalent three-model matrix and native six frames, using Icarus at 100MHz."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from c40_100mhz_contract import ROOT, TOP, fixture, replace_once, throughput
from c39_onehot_trained_contract import bound_candidate, build_vectors, source_gate
from c39_onehot_sources import sources
from check_r2_trained_host_evidence import check_text
from run_c37_leaf_probe import budget
from c39_seam_admission import check
from c40_four_row_candidate import render as four_row_source

MODELS=('c36_qat_b_starry_equalized_20260915a','c36_qat_b_mosaic_equalized_20260915a',
        'c36_qat_b_mosaic_stable_20260915a')


def write_json(path,data):
    pending=path.with_suffix(path.suffix+'.pending')
    pending.write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    pending.replace(path)


def process_identity(p):
    api=ctypes.WinDLL('kernel32',use_last_error=True)
    stamp=[ctypes.c_uint64() for _ in range(4)]
    api.GetProcessTimes.argtypes=[ctypes.c_void_p]+[ctypes.POINTER(ctypes.c_uint64)]*4
    if not api.GetProcessTimes(int(p._handle),*[ctypes.byref(x) for x in stamp]):raise ctypes.WinError()
    flag=ctypes.c_int()
    api.IsProcessInJob.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_int)]
    if not api.IsProcessInJob(int(p._handle),None,ctypes.byref(flag)):raise ctypes.WinError()
    if flag.value:raise RuntimeError('simulator inherited Windows Job')
    return dict(pid=p.pid,start_filetime=stamp[0].value,in_windows_job=False)


def verify_output(text,config,native):
    if 'C40_CLOCK_PASS core_hz=100000000 ' not in text:raise AssertionError('actual 100MHz clock marker missing')
    result=check_text(text,config,nn=6 if native else 2,clock_native_override=None if native else 1,
                      camera_profile='camera30' if native else 'legacy',core_period_ps=10000)
    # Retain source, layer, frame, display, CPU, ID, APB and ownership gates above.
    rejected=[]
    for old,new in [('stage_count=18','stage_count=22'),('fresh_leases=1','fresh_leases=0'),
                    ('apb_checks=9','apb_checks=8'),('SYSTEM_PASS ','SYSTEM_OMITTED ')]:
        altered=text.replace(old,new,1)
        if altered==text:raise AssertionError('negative evidence did not change')
        try:check_text(altered,config,nn=6 if native else 2,clock_native_override=None if native else 1,
                       camera_profile='camera30' if native else 'legacy',core_period_ps=10000)
        except (ValueError,AssertionError):rejected.append(old)
        else:raise AssertionError('invalid evidence accepted')
    result.update(evidence_negatives_rejected=rejected,actual_CPU_IP=False,actual_AXI=True)
    if native:result['performance']=throughput(result['completion_intervals'])
    return result


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--log-dir',type=Path,required=True)
    ap.add_argument('--scope',choices=('full','matrix','native'),default='full')
    ap.add_argument('--four-rows',action='store_true')
    ap.add_argument('--capture-evidence')
    args=ap.parse_args()
    log=args.log_dir.resolve()
    if not log.is_relative_to(ROOT/'logs/c40_100mhz_runs') or not log.is_dir():raise ValueError('private run log required')
    if args.four_rows:
        if not args.capture_evidence or Path(args.capture_evidence).name!=args.capture_evidence:
            raise ValueError('four-row full capture prerequisite required')
        prior=ROOT/'logs/c40_100mhz_runs'/args.capture_evidence
        prior_state=json.loads((prior/'status.json').read_text(encoding='utf-8-sig'))
        prior_exit=json.loads((prior/'100_four.simulate.exit.json').read_text())
        prior_text=(prior/'100_four.simulate.stdout.log').read_text()
        if prior_state['state']!='complete' or prior_state['phase']!='capture_full' or prior_exit['exit_code']!=0:
            raise ValueError('capture prerequisite not complete')
        if (prior/'candidate.sv').read_text(encoding='utf-8')!=four_row_source():raise ValueError('capture candidate differs')
        if 'results=2 good=2 bad=0' not in prior_text or prior_text.count('C1_R2_DEMO_RGB2_CAPTURE_PASS ')!=1:
            raise ValueError('two full golden capture frames unproven')
        write_json(log/'capture_prerequisite.json',dict(run=args.capture_evidence,full_frames=2,candidate_equal=True))
    budget();check();source_gate()
    import torch
    torch.set_num_threads(1)
    base=fixture((ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig'))
    # A bounded heartbeat makes a multi-hour native vvp observable without waves.
    base=replace_once(base,'c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;',
        '''c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;
        if(c40_core_edges%1000000==0)$display("C40_PROGRESS core_cycles=%0d simulation_ns=%0t",c40_core_edges,$time);''')
    cases=[]
    if args.scope!='native':
        for index,model in enumerate(MODELS):
            cases += [dict(id=f'm{index}_{side}_{stalls}',model=model,width=side,height=side,stalls=stalls,negative=0)
                      for side,stalls in ((8,0),(8,1),(32,0),(32,1))]
            cases += [dict(id=f'm{index}_negative_{n}',model=model,width=8,height=8,stalls=1,negative=n) for n in (1,2)]
    if args.scope!='matrix':
        cases += [dict(id='native',model=MODELS[2],width=640,height=480,stalls=0,negative=0)]
    results=[]
    write_json(log/'pipeline.json',dict(state='starting',scope=args.scope,cases=cases,completed=results))
    for case in cases:
        entry=log/case['id'];entry.mkdir()
        native=case['id']=='native'
        package,config,provenance=bound_candidate(ROOT/'outputs'/case['model'])
        started=time.monotonic()
        with tempfile.TemporaryDirectory(prefix='c40_pipeline_',dir=ROOT/'sim') as temp:
            work=Path(temp)
            write_json(log/'pipeline.json',dict(state='running',case=case,step='vectors',private_directory=str(work),completed=results))
            meta=build_vectors(work/'vectors',case['width'],case['height'],package,config,provenance)
            write_json(entry/'metadata.json',meta)
            testbench=work/f'{TOP}.sv';testbench.write_text(base,encoding='utf-8')
            (entry/'testbench.sv').write_text(base,encoding='utf-8')
            selected=[p for p in sources() if p.name not in ('execution_plan.sv','row_fusion_plan.sv')]
            if args.four_rows:
                candidate=work/'c40_four_row_sampler.sv'
                candidate.write_text(four_row_source(),encoding='utf-8')
                (entry/'candidate.sv').write_text(four_row_source(),encoding='utf-8')
                original=ROOT/'rtl/r2/c1_r2_resize_line_sampler.sv'
                if selected.count(original)!=1:raise ValueError('sampler substitution must be unique')
                selected=[candidate if p==original else p for p in selected]
            selected += [work/'vectors/package/execution_plan.sv',work/'vectors/fusion_plan.sv']
            if len(selected)!=49:raise ValueError('actual source count differs')
            for p,name in [(selected[-2],'execution_plan.sv'),(selected[-1],'fusion_plan.sv')]:
                (entry/name).write_text(p.read_text(encoding='utf-8'),encoding='utf-8')
            opts=dict(WIDTH=case['width'],HEIGHT=case['height'],STALLS=case['stalls'],BANK_WORDS=524288 if native else 16384,
                MAX_CYCLES=120000000,MEMORY_DIV=2,COMMAND_LATENCY=20,AW_WAIT_W=2,NN_TARGET=6 if native else 2,
                FRAME_DIVISOR=1 if native else 2,CLOCKS_NATIVE=1,CPU_START_NEGATIVE=0,NEGATIVE_CONTROL=case['negative'],
                STAGE_COUNT=meta['stage_count'],RGB_STAGE=meta['rgb_stage'],FUSED_DW_STAGE=meta['dw_stage'],FUSED_PW_STAGE=meta['pw_stage'])
            camera=meta['sources'][0]
            for k,f in [('SW','width'),('SH','height'),('RX','roi_x'),('RY','roi_y'),('RW','roi_width'),('RH','roi_height')]:opts['CAMERA_'+k]=camera[f]
            exe=work/'host.vvp'
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,*[f'-P{TOP}.{k}={v}' for k,v in opts.items()],'-o',str(exe),
                      *map(str,selected),str(ROOT/'sim/c1_r2_axi_memory_bfm.sv'),str(ROOT/'sim/c1_r2_axi_traffic_agent.sv'),str(testbench)]]
            plus=[f'+DIR={(work/"vectors").as_posix()}',f'+P={meta["parameter_words"]}',f'+I={meta["input_words"]}',
                  f'+E={meta["expected_words"]}',f'+DW={meta["dw_packets"]}']
            for i,source in enumerate(meta['sources']):plus += [f'+{tag}{i}={source[key]}' for tag,key in [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]
            commands.append(['D:/iverilog/bin/vvp.exe','-i',str(exe),*plus])
            write_json(entry/'compile.json',dict(options=opts,sources=list(map(str,selected)),commands=commands,four_rows=args.four_rows))
            for step,command in zip(('compile','simulate'),commands):
                with (entry/(step+'.stdout.log')).open('w',encoding='utf-8') as out,(entry/(step+'.stderr.log')).open('w',encoding='utf-8') as err:
                    child=subprocess.Popen(command,cwd=work,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
                    identity=process_identity(child)
                    write_json(entry/(step+'.process.json'),identity)
                    while True:
                        write_json(log/'pipeline.json',dict(state='running',scope=args.scope,case=case,step=step,process=identity,
                            private_directory=str(work),elapsed_seconds=round(time.monotonic()-started,1),completed=results))
                        try:code=child.wait(timeout=10);break
                        except subprocess.TimeoutExpired:continue
                write_json(entry/(step+'.exit.json'),dict(exit_code=code,process=identity))
                if step=='compile' and code:raise RuntimeError('Icarus compile failed: '+str(entry))
            text=(entry/'simulate.stdout.log').read_text(encoding='utf-8')
            if case['negative']:
                expected={1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[case['negative']]
                if not code or expected not in text or 'SYSTEM_PASS ' in text:raise AssertionError('RAM negative not rejected')
                result=dict(actual_fault_rejected=True,expected=expected)
            else:
                if code:raise RuntimeError('Icarus simulation failed: '+text[-2200:])
                if (entry/'simulate.stderr.log').stat().st_size:raise RuntimeError('unexpected simulator stderr')
                result=verify_output(text,config,native)
        result.update(case=case,temporary_removed=not work.exists(),wall_seconds=round(time.monotonic()-started,1))
        write_json(entry/'result.json',result);results.append(result)
        print('C40_PIPELINE_CASE_PASS '+case['id'],flush=True)
    write_json(log/'pipeline.json',dict(state='complete',scope=args.scope,completed=results,actual_CPU_IP=False,core_hz=100000000))
    print('C40_ICARUS_PIPELINE_PASS scope='+args.scope+' temporary_removed=1 actual_CPU_IP=0',flush=True)


if __name__=='__main__':main()
