"""C36 trained-model regression on the unchanged real AXI/video/host RTL."""
import argparse
import json
from pathlib import Path
import subprocess

from r2_trained_style_vectors import ROOT,bound_candidate,build_vectors,camera_geometry
from run_r2_fused_rgb2_host_probe import SOURCES,PLAN_SOURCE,FUSION_SOURCE,SIM,TOP,PREFIX
from check_r2_fused_host_source import source_gate
from check_r2_trained_host_evidence import check_text,corruption_checks

CASES=[dict(id=f'{side}_{stalls}',width=side,height=side,stalls=stalls,negative=0)
       for side,stalls in ((8,0),(8,1),(32,0),(32,1))]
CASES += [dict(id=f'negative_{negative}',width=8,height=8,stalls=1,negative=negative) for negative in (1,2)]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--qat-run',type=Path,required=True)
    parser.add_argument('--run-directory',type=Path,required=True)
    args=parser.parse_args()
    root=args.run_directory.resolve()
    if not root.is_relative_to(ROOT/'sim') or not root.is_dir():
        raise ValueError('existing private simulator directory required')
    import torch
    torch.set_num_threads(1)
    source_gate()
    package,config,provenance=bound_candidate(args.qat_run)
    if config!=dict(blocks=2,expansion=24,preproject=True):
        raise ValueError('this first trained-model regression is for candidate B')
    results=[]
    for case in CASES:
        folder=root/case['id']
        meta=build_vectors(folder,case['width'],case['height'],package,config,provenance)
        print('C36_TRAINED_HOST_CASE_BEGIN '+json.dumps(case,separators=(',',':')),flush=True)
        sources=[str(ROOT/s) for s in SOURCES if s not in (PLAN_SOURCE,FUSION_SOURCE)]
        sources += [str(folder/'package/execution_plan.sv'),str(folder/'fusion_plan.sv')]
        sw,sh,rx,ry,rw,rh=camera_geometry(case['width'],case['height'])
        opts=dict(WIDTH=case['width'],HEIGHT=case['height'],STALLS=case['stalls'],AW_WAIT_W=2,
                  MEMORY_DIV=2,COMMAND_LATENCY=20,FRAME_DIVISOR=2,CAMERA_SW=sw,CAMERA_SH=sh,
                  CAMERA_RX=rx,CAMERA_RY=ry,CAMERA_RW=rw,CAMERA_RH=rh,NN_TARGET=2,
                  NEGATIVE_CONTROL=case['negative'],STAGE_COUNT=meta['stage_count'],RGB_STAGE=meta['rgb_stage'],
                  FUSED_DW_STAGE=meta['dw_stage'],FUSED_PW_STAGE=meta['pw_stage'])
        executable=folder/'host.vvp'
        command=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
                 *[f'-P{TOP}.{k}={v}' for k,v in opts.items()],'-o',str(executable),
                 *sources,*[str(ROOT/s) for s in SIM],str(ROOT/f'sim/{TOP}.sv')]
        print('C36_ACTUAL_COMPILE '+json.dumps(command),flush=True)
        compiled=subprocess.run(command,capture_output=True,text=True,timeout=90)
        if compiled.returncode:
            raise RuntimeError(compiled.stderr[-4000:])
        command=['D:/iverilog/bin/vvp.exe',str(executable),f'+DIR={folder.as_posix()}',
                 f'+P={meta["parameter_words"]}',f'+I={meta["input_words"]}',f'+E={meta["expected_words"]}',
                 f'+DW={meta["dw_packets"]}',
                 *[f'+{tag}{i}={source[key]}' for i,source in enumerate(meta['sources'])
                   for tag,key in [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]]
        print('C36_ACTUAL_RUN '+json.dumps(command),flush=True)
        result=subprocess.run(command,capture_output=True,text=True,timeout=900)
        if case['negative']:
            expected={1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[case['negative']]
            if result.returncode==0 or expected not in result.stdout or PREFIX+'PASS ' in result.stdout:
                raise RuntimeError('RAM corruption control did not fail as expected: '+(result.stdout+result.stderr)[-2000:])
            record=dict(case=case['id'],actual_RAM_mutation=True,expected_failure=expected,exit_code=result.returncode)
            # Preserve the actual fatal line, not only a manually produced PASS.
            actual=[line for line in result.stdout.splitlines() if expected in line]
            print('C36_NEGATIVE_OBSERVED '+json.dumps(dict(record,fatal_lines=actual)),flush=True)
        else:
            for line in result.stdout.splitlines():
                if line.startswith(PREFIX):
                    print(line,flush=True)
            if result.returncode or result.stderr.strip():
                raise RuntimeError('trained model RTL failed: '+(result.stdout+result.stderr)[-3000:])
            record=check_text(result.stdout,config,nn=2)
            record.update(case=case['id'],evidence_corruption_rejections=corruption_checks(result.stdout,config,2))
            print('C36_POSITIVE_CHECK '+json.dumps(record,separators=(',',':')),flush=True)
        results.append(record)
        print('C36_TRAINED_HOST_CASE_END '+case['id'],flush=True)
    print('C36_TRAINED_HOST_MATRIX_PASS '+json.dumps(dict(model_binding=provenance,
        positive_configurations=4,correct_CNN_frames=8,actual_RAM_corruption_controls=2,
        actual_AXI=True,actual_CPU_IP=False,new_model_RTL_simulated=True,native_fps_claim=False,
        cases=results),separators=(',',':')),flush=True)


if __name__=='__main__':
    main()
