"""C29 source faults in the actual CPU/video/CNN shell; no direct RAM seeding."""
import argparse
import subprocess
import tempfile
from pathlib import Path
from run_r2_camera_capacity_host_probe import ROOT, SOURCES, PLAN_SOURCE, SIM
from r2_camera_plan_vectors import vectors, compile_package, profile_nodes, camera_geometry

TOP = 'tb_c1_r2_camera_capacity_host_faults'
PREFIX = 'C1_R2_CAMERA_CAPACITY_HOST_FAULT_'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--faults', default='1,2,3,4')
    p.add_argument('--stalls', default='0,1')
    p.add_argument('--temporary-parent', type=Path)
    a = p.parse_args()
    temp_parent = (a.temporary_parent or ROOT/'sim').resolve()
    if not temp_parent.is_relative_to((ROOT/'sim').resolve()) or not temp_parent.is_dir():
        p.error('temporary parent must be an existing directory within case1/sim')
    faults = list(map(int, a.faults.split(',')))
    stalls = list(map(int, a.stalls.split(',')))
    if not set(faults) <= {1, 2, 3, 4} or not set(stalls) <= {0, 1}:
        p.error('invalid fault or stall mode')
    with tempfile.TemporaryDirectory(prefix='c1_r2_camera_capacity_host_fault_', dir=temp_parent) as td:
        root = Path(td)
        m = vectors(root, 8, 8, 'microstyle24', compile_package(profile_nodes('microstyle24')))
        sw, sh, rx, ry, rw, rh = camera_geometry(8, 8)
        sources = [str(ROOT/s) for s in SOURCES if s != PLAN_SOURCE]+[str(root/'package/execution_plan.sv')]
        for fault in faults:
            for stall in stalls:
                exe = root/f'fault{fault}_{stall}.vvp'
                opts = dict(WIDTH=8, HEIGHT=8, STALLS=stall, FAULT_MODE=fault, NN_TARGET=6,
                            CAMERA_SW=sw, CAMERA_SH=sh, CAMERA_RX=rx, CAMERA_RY=ry, CAMERA_RW=rw, CAMERA_RH=rh)
                c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', TOP,
                                    *[f'-P{TOP}.{k}={v}' for k, v in opts.items()], '-o', str(exe),
                                    *sources, *[str(ROOT/s) for s in SIM], str(ROOT/f'sim/{TOP}.sv')],
                                   capture_output=True, text=True, timeout=90)
                if c.returncode:
                    raise RuntimeError(c.stderr[-4000:])
                r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe), f'+DIR={root.as_posix()}',
                                    f'+P={m["parameter_words"]}', f'+I={m["input_words"]}', f'+E={m["expected_words"]}',
                                    *[f'+{tag}{i}={source[key]}' for i, source in enumerate(m['sources'])
                                      for tag, key in [('SW','width'), ('SH','height'), ('XS','xs'), ('YS','ys'), ('XP','xp'), ('YP','yp')]]],
                                   capture_output=True, text=True, timeout=300)
                for line in r.stdout.splitlines():
                    if line.startswith(PREFIX):
                        print(line, flush=True)
                if r.returncode or r.stdout.count(PREFIX+'PASS ') != 1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:
                    raise RuntimeError((r.stdout+r.stderr)[-4000:])
    print(PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__':
    main()
