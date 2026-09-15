"""C13 CPU ID seam + actual C12 CNN/video/fabric, unchanged numeric golden."""
from __future__ import annotations
import argparse,json,subprocess,tempfile
from pathlib import Path
from run_r2_rgbx_system_probe import SOURCES as C12
from run_r2_graph_probe import vectors
ROOT=Path(__file__).resolve().parents[1]
SOURCES=C12+['rtl/r2/c1_r2_cpu_axi_adapter.sv']
SIM=['sim/c1_r2_axi_memory_bfm.sv','sim/c1_r2_axi_traffic_agent.sv']
def main():
    p=argparse.ArgumentParser();p.add_argument('--compile-only',action='store_true');p.add_argument('--shapes',default='8x8,32x32');p.add_argument('--stalls',default='0,1')
    p.add_argument('--negative-only',action='store_true');p.add_argument('--aw-wait-w',type=int,choices=(0,1,2),default=0)
    p.add_argument('--nn-target',type=int,choices=range(2,7));a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='c1_r2_cpu_video_',dir=ROOT/'sim') as td:
        root=Path(td)
        if a.compile_only:
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','c1_r2_video_rgbx_system','-o',str(root/'system.vvp'),*[str(ROOT/s) for s in SOURCES]],capture_output=True,text=True,timeout=90)
            if c.returncode:raise RuntimeError(c.stderr[-4000:])
            print(f'C1_R2_CPU_VIDEO_SYSTEM_COMPILE_PASS sources={len(SOURCES)} scope=retained_core_plus_adapter_sources')
        else:
            for shape in a.shapes.split(','):
                w,h=map(int,shape.split('x'));folder=root/shape;folder.mkdir();m=vectors(folder,w,h)
                print('C1_R2_CPU_VIDEO_SYSTEM_VECTORS '+json.dumps(m),flush=True)
                for stalls in map(int,a.stalls.split(',')):
                    exe=folder/'system.vvp';top='tb_c1_r2_cpu_video_system'
                    for negative in ((1,2) if a.negative_only else (0,)):
                        c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.WIDTH={w}',f'-P{top}.HEIGHT={h}',f'-P{top}.STALLS={stalls}',
                            f'-P{top}.AW_WAIT_W={a.aw_wait_w}',f'-P{top}.NEGATIVE_CONTROL={negative}',
                            *([f'-P{top}.NN_TARGET={a.nn_target}'] if a.nn_target is not None else []),
                            '-o',str(exe),*[str(ROOT/s) for s in SOURCES+SIM],str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
                        if c.returncode:raise RuntimeError(c.stderr[-4000:])
                        r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}'],capture_output=True,text=True,timeout=900)
                        if negative:
                            marker={1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[negative]
                            if r.returncode==0 or marker not in r.stdout or 'C1_R2_CPU_VIDEO_SYSTEM_PASS ' in r.stdout:raise RuntimeError('negative control did not trip: '+r.stdout[-2000:])
                            print(f'C1_R2_CPU_VIDEO_SYSTEM_NEGATIVE_PASS width={w} height={h} stalls={stalls} corruption={negative} actual_ram_mutation=1',flush=True)
                        else:
                            for line in r.stdout.splitlines():
                                if line.startswith('C1_R2_CPU_VIDEO_SYSTEM_'):print(line,flush=True)
                            if r.returncode or r.stdout.count('C1_R2_CPU_VIDEO_SYSTEM_PASS ')!=1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:raise RuntimeError((r.stdout+r.stderr)[-4000:])
    print('C1_R2_CPU_VIDEO_SYSTEM_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)
if __name__=='__main__':main()
