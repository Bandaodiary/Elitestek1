"""Cheap actual-host reproduction of the native-clock CPU start race.

The negative runs the former pulse unchanged, not a forced DUT fault.
All three configurations use the same real host, RAM/AXI and generated graph.
"""
import subprocess
import tempfile
from pathlib import Path
import argparse
import run_r2_rgb2_host_probe as host
from r2_camera_plan_vectors import vectors, compile_package, profile_nodes, camera_geometry
from check_r2_rgb2_host_evidence import run as check_host


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--temporary-parent',type=Path,required=True)
    a=p.parse_args()
    parent=a.temporary_parent.resolve()
    if not parent.is_relative_to((host.ROOT/'sim').resolve()) or not parent.is_dir():
        p.error('temporary parent must be an existing case1/sim directory')
    with tempfile.TemporaryDirectory(prefix='c31_startup_',dir=parent) as td:
        folder=Path(td)
        package=compile_package(profile_nodes('microstyle24'))
        m=vectors(folder,8,8,'microstyle24',package)
        source=[str(host.ROOT/s) for s in host.SOURCES if s!=host.PLAN_SOURCE]
        source += [str(folder/'package/execution_plan.sv')]
        sw,sh,rx,ry,rw,rh=camera_geometry(8,8)
        for native,negative in ((1,1),(0,0),(1,0)):
            opts=dict(WIDTH=8,HEIGHT=8,STALLS=0,AW_WAIT_W=2,NN_TARGET=2,
                      FRAME_DIVISOR=2,CAMERA_SW=sw,CAMERA_SH=sh,CAMERA_RX=rx,
                      CAMERA_RY=ry,CAMERA_RW=rw,CAMERA_RH=rh,
                      CLOCKS_NATIVE=native,CPU_START_NEGATIVE=negative)
            exe=folder/f'host_{native}_{negative}.vvp'
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',host.TOP,
                              *[f'-P{host.TOP}.{k}={v}' for k,v in opts.items()],'-o',str(exe),
                              *source,*[str(host.ROOT/s) for s in host.SIM],
                              str(host.ROOT/f'sim/{host.TOP}.sv')],capture_output=True,text=True,timeout=90)
            if c.returncode:
                errors=[line for line in c.stderr.splitlines() if 'warning:' not in line.lower() and 'sorry:' not in line.lower()]
                raise RuntimeError('\n'.join(errors)[-4000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',
                              f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}',
                              *[f'+{tag}{i}={s[key]}' for i,s in enumerate(m['sources'])
                                for tag,key in [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]],
                             capture_output=True,text=True,timeout=120)
            if negative:
                if r.returncode==0 or 'CPU source did not start: no sampled core-clock pulse' not in r.stdout or host.PREFIX+'PASS ' in r.stdout:
                    raise RuntimeError('legacy startup was not rejected: '+r.stdout[-2000:])
                print('C31_STARTUP_NEGATIVE_PASS native_clocks=1 legacy_pulse=1 missing_start_detected=1',flush=True)
            else:
                if r.returncode or 'FATAL' in r.stdout:raise RuntimeError(r.stdout[-2000:])
                checked=check_host(r.stdout,expected_nn=2,clock_native_override=native)
                for line in r.stdout.splitlines():
                    if line.startswith(host.PREFIX):print(line,flush=True)
                print(f'C31_STARTUP_POSITIVE_PASS native_clocks={native} cnn_frames=2 full_host_checked=1',flush=True)
    print('C31_STARTUP_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
