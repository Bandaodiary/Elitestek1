"""C24 feature-resize generated plan through real RGBX/AXI/video/host RTL, not CPU IP."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from r2_resize_plan_vectors import ROOT, vectors, compile_package, profile_nodes
from r2_plan_package import verify

PROJECT = ROOT/'efinity/c1_ti60_r2_resize_host96.xml'
PLAN_SOURCE = 'model/r2_microstyle24_bound_plan/execution_plan.sv'
SOURCES = [(PROJECT.parent/e.attrib['name']).resolve().relative_to(ROOT).as_posix()
           for e in ET.parse(PROJECT).getroot().iter()
           if e.tag.rsplit('}', 1)[-1] == 'design_file' and e.attrib['name'] != 'c1_ti60_r2_resize_host96.sv']
SIM = ['sim/c1_r2_axi_memory_bfm.sv', 'sim/c1_r2_axi_traffic_agent.sv']
TOP = 'tb_c1_r2_resize_host_system'
PREFIX = 'C1_R2_RESIZE_HOST_SYSTEM_'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--compile-only', action='store_true')
    p.add_argument('--profile', choices=('microstyle24', 'drop_res1'), default='microstyle24')
    p.add_argument('--shapes', default='8x8,32x32')
    p.add_argument('--stalls', default='0,1')
    p.add_argument('--negative-only', action='store_true')
    p.add_argument('--aw-wait-w', type=int, choices=(0, 1, 2), default=0)
    p.add_argument('--nn-target', type=int, choices=range(2, 7), default=6)
    a = p.parse_args()
    if not set(a.stalls.split(',')) <= {'0', '1'}:
        p.error('stalls must be 0 or 1')
    package = compile_package(profile_nodes(a.profile))
    if SOURCES.count(PLAN_SOURCE) != 1 or any('microstyle_pingpong_graph.sv' in s for s in SOURCES):
        raise ValueError('source closure must contain one generated plan and no old graph')
    with tempfile.TemporaryDirectory(prefix='c1_r2_resize_host_', dir=ROOT/'sim') as td:
        root = Path(td)
        if a.compile_only:
            if a.profile != 'microstyle24':
                p.error('production compile-only uses the default 22-node package')
            verify(package, ROOT/'model/r2_microstyle24_bound_plan')
            c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'c1_r2_resize_host_system',
                                '-o', str(root/'host.vvp'), *[str(ROOT/s) for s in SOURCES]],
                               capture_output=True, text=True, timeout=90)
            if c.returncode:
                raise RuntimeError(c.stderr[-4000:])
            print(PREFIX+f'COMPILE_PASS sources={len(SOURCES)} actual_host_shell=1 generated_plan=1')
        else:
            for shape in a.shapes.split(','):
                w, h = map(int, shape.split('x'))
                folder = root/shape
                folder.mkdir()
                m = vectors(folder, w, h, a.profile, package)
                print(PREFIX+'VECTORS '+json.dumps(m), flush=True)
                sources = [str(ROOT/s) for s in SOURCES if s != PLAN_SOURCE]+[str(folder/'package/execution_plan.sv')]
                for stalls in map(int, a.stalls.split(',')):
                    for negative in ((1, 2) if a.negative_only else (0,)):
                        exe = folder/f'host_{stalls}_{negative}.vvp'
                        opts = dict(WIDTH=w, HEIGHT=h, STALLS=stalls, AW_WAIT_W=a.aw_wait_w,
                                    NN_TARGET=a.nn_target, NEGATIVE_CONTROL=negative,
                                    STAGE_COUNT=m['stage_count'], RGB_STAGE=m['rgb_stage'])
                        c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', TOP,
                                            *[f'-P{TOP}.{k}={v}' for k, v in opts.items()], '-o', str(exe),
                                            *sources, *[str(ROOT/s) for s in SIM], str(ROOT/f'sim/{TOP}.sv')],
                                           capture_output=True, text=True, timeout=90)
                        if c.returncode:
                            raise RuntimeError(c.stderr[-4000:])
                        r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe), f'+DIR={folder.as_posix()}',
                                            f'+P={m["parameter_words"]}', f'+I={m["input_words"]}', f'+E={m["expected_words"]}',
                                            *[f'+{tag}{i}={source[key]}' for i,source in enumerate(m['sources']) for tag,key in [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]],
                                           capture_output=True, text=True, timeout=900)
                        if negative:
                            marker = {1: 'CNN golden mismatch stage=0', 2: 'display pair not actually produced'}[negative]
                            if r.returncode == 0 or marker not in r.stdout or PREFIX+'PASS ' in r.stdout:
                                raise RuntimeError('negative control failed: '+r.stdout[-2200:])
                            print(PREFIX+f'NEGATIVE_PASS width={w} height={h} stalls={stalls} corruption={negative} actual_ram_mutation=1', flush=True)
                        else:
                            for line in r.stdout.splitlines():
                                if line.startswith(PREFIX):
                                    print(line, flush=True)
                            if r.returncode or r.stdout.count(PREFIX+'PASS ') != 1 or 'FATAL' in r.stdout or 'ERROR' in r.stdout:
                                raise RuntimeError((r.stdout+r.stderr)[-4000:])
    print(PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__':
    main()
