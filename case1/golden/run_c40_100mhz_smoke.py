"""Actual 100 MHz C39 host smoke, with behavioral CPU/DDR and explicit limits."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
from c40_100mhz_contract import ROOT, TOP, fixture
from c39_onehot_trained_contract import bound_candidate, build_vectors, source_gate
from c39_onehot_sources import sources
from run_c37_leaf_probe import budget
from c39_seam_admission import check


def rows(text, suffix):
    return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)', line))
            for line in re.findall(r'^C1_R2_FUSED_RGB2_HOST_SYSTEM_'+suffix+r' ([^\r\n]*)',text,re.M)]


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--log-dir',type=Path,required=True)
    args=ap.parse_args()
    log=args.log_dir.resolve()
    if not log.is_relative_to(ROOT/'logs/c40_100mhz_runs') or not log.is_dir():
        raise ValueError('private retained log directory required')
    budget();check();source_gate()
    import torch
    torch.set_num_threads(1)
    model=ROOT/'outputs/c36_qat_b_mosaic_stable_20260915a'
    package,config,provenance=bound_candidate(model)
    records=[]
    with tempfile.TemporaryDirectory(prefix='c40_100mhz_',dir=ROOT/'sim') as temp:
        work=Path(temp)
        vectors=work/'vectors'
        meta=build_vectors(vectors,8,8,package,config,provenance)
        original=(ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig')
        transformed=fixture(original)
        chosen=[p for p in sources() if p.name not in ('execution_plan.sv','row_fusion_plan.sv')]
        chosen += [vectors/'package/execution_plan.sv',vectors/'fusion_plan.sv']
        if len(chosen)!=49: raise ValueError('wrong actual source closure')
        for name,stalls,negative,bad_clock in [('clean',0,0,False),('stalled',1,0,False),
                                              ('clock_negative',0,0,True),('RAM_negative',1,1,False)]:
            tb=work/f'{name}.sv'
            tb.write_text(transformed.replace('always #(5.0)clk=~clk;',
                'always #(3.333)clk=~clk;') if bad_clock else transformed,encoding='utf-8')
            # Save only the small actual fixture; never retain compiled simulation files.
            (log/f'{name}.testbench.sv').write_text(tb.read_text(),encoding='utf-8')
            opts=dict(WIDTH=8,HEIGHT=8,STALLS=stalls,MEMORY_DIV=1,COMMAND_LATENCY=20,
                AW_WAIT_W=2,NN_TARGET=2,FRAME_DIVISOR=1,CLOCKS_NATIVE=1,
                NEGATIVE_CONTROL=negative,STAGE_COUNT=meta['stage_count'],RGB_STAGE=meta['rgb_stage'],
                FUSED_DW_STAGE=meta['dw_stage'],FUSED_PW_STAGE=meta['pw_stage'])
            camera=meta['sources'][0]
            for key,field in [('SW','width'),('SH','height'),('RX','roi_x'),('RY','roi_y'),('RW','roi_width'),('RH','roi_height')]:
                opts['CAMERA_'+key]=camera[field]
            exe=work/f'{name}.vvp'
            command=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,
                *[f'-P{TOP}.{k}={v}' for k,v in opts.items()],'-o',str(exe),
                *map(str,chosen),str(ROOT/'sim/c1_r2_axi_memory_bfm.sv'),
                str(ROOT/'sim/c1_r2_axi_traffic_agent.sv'),str(tb)]
            (log/f'{name}.compile.json').write_text(json.dumps(command,indent=2),encoding='utf-8')
            build=subprocess.run(command,capture_output=True,text=True,timeout=90)
            (log/f'{name}.compile.stderr.log').write_text(build.stderr,encoding='utf-8')
            if build.returncode:
                errors=[line for line in build.stderr.splitlines() if 'error' in line.lower()]
                raise RuntimeError('\n'.join(errors[:20]) or build.stderr[:2000])
            plus=[f'+DIR={vectors.as_posix()}',f'+P={meta["parameter_words"]}',
                f'+I={meta["input_words"]}',f'+E={meta["expected_words"]}',f'+DW={meta["dw_packets"]}']
            for i,source in enumerate(meta['sources']):
                plus += [f'+{tag}{i}={source[key]}' for tag,key in [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]
            run=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),*plus],capture_output=True,text=True,timeout=900)
            (log/f'{name}.stdout.log').write_text(run.stdout,encoding='utf-8')
            (log/f'{name}.stderr.log').write_text(run.stderr,encoding='utf-8')
            if bad_clock or negative:
                expected='C40 core clock is not 100MHz' if bad_clock else 'CNN golden mismatch stage=0'
                if not run.returncode or expected not in run.stdout or rows(run.stdout,'PASS'):
                    raise AssertionError('actual fault was not rejected: '+name)
                record=dict(case=name,actual_fault_rejected=True,expected=expected)
            else:
                passed=rows(run.stdout,'PASS');frames=rows(run.stdout,'FRAME')
                if run.returncode or run.stderr.strip() or len(passed)!=1 or len(frames)!=2 or 'C40_CLOCK_PASS ' not in run.stdout:
                    raise AssertionError('100MHz smoke failed: '+run.stdout[-3000:])
                p=passed[0]
                if p['cnn_frames']!=2 or p['underflow'] or p['display_misses'] or p['good_pixels']<=0 or p['cpu_r']<=0 or p['cpu_w']<=0:
                    raise AssertionError('missing actual frame/display/CPU traffic coverage')
                if any(f['commits']!=18 for f in frames): raise AssertionError('incomplete graph')
                record=dict(case=name,frames=frames,summary=p,actual_CPU_IP=False)
            records.append(record)
            print('C40_CASE_PASS '+json.dumps(record,separators=(',',':')),flush=True)
    result=dict(cases=records,core_hz=100000000,actual_C39_RTL=True,actual_CPU_IP=False,
        official_DDR=False,native_fps_measured=False,temporary_removed=not work.exists())
    (log/'summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('C40_100MHZ_SMOKE_PASS temporary_removed=1 actual_CPU_IP=0',flush=True)


if __name__=='__main__':main()
