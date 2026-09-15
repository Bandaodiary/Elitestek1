"""C17 actual generated-ROM + bound-parameter RTL numerical regression."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import threading
from collections import deque

from r2_plan_vectors import ROOT, vectors, compile_package, profile_nodes
from run_r2_plan_graph_probe import SOURCES as C16_SOURCES

SOURCES = [s for s in C16_SOURCES if not s.endswith('/c1_r2_microstyle_plan.sv')]
PREFIX = 'C1_R2_BOUND_GRAPH_'
TOP = 'tb_c1_r2_bound_plan_graph'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--profiles', default='microstyle24,drop_res1')
    p.add_argument('--shapes', default='4x4,12x12,32x32,640x12')
    p.add_argument('--stalls', default='0,1')
    p.add_argument('--memory-div', type=int, default=0)
    p.add_argument('--latency', type=int, default=0)
    p.add_argument('--write-throttle', type=int, choices=(0, 1), default=0)
    p.add_argument('--reset-only', action='store_true')
    p.add_argument('--negative-only', action='store_true')
    p.add_argument('--package-negative', action='store_true')
    p.add_argument('--timeout-seconds', type=int, default=900)
    a = p.parse_args()
    profiles = a.profiles.split(',')
    if a.timeout_seconds < 1 or a.memory_div < 0 or a.latency < 0 or sum((a.reset_only, a.negative_only, a.package_negative)) > 1:
        p.error('invalid configuration or multiple negative/reset modes')
    if not set(profiles) <= {'microstyle24', 'drop_res1'} or a.package_negative and profiles != ['drop_res1']:
        p.error('unsupported profile; package-negative requires drop_res1 only')
    if not set(a.stalls.split(',')) <= {'0', '1'}:
        p.error('stalls must be 0 or 1')
    with tempfile.TemporaryDirectory(prefix='c1_r2_bound_graph_', dir=ROOT/'sim') as td:
        for profile in profiles:
            package = compile_package(profile_nodes(profile))
            for shape in a.shapes.split(','):
                w, h = map(int, shape.split('x'))
                folder = Path(td)/profile/shape
                folder.mkdir(parents=True)
                m = vectors(folder, w, h, profile, package)
                print(PREFIX+'VECTORS '+json.dumps(m | dict(memdiv=a.memory_div, latency=a.latency)), flush=True)
                stale_folder, stale_meta = None, None
                if a.package_negative:
                    stale_folder = folder/'stale_parameters'
                    stale_folder.mkdir()
                    stale_meta = vectors(stale_folder, w, h, profile, package,
                                         parameter_override=compile_package(profile_nodes('microstyle24')))
                for stalls in map(int, a.stalls.split(',')):
                    cases = [('normal', None)]
                    if a.negative_only:
                        cases = [('handoff1', 'PINGPONG_MISMATCH stage=1'), ('handoff2', 'unwritten/wrong producer stage=1')]
                    if a.package_negative:
                        cases = [('stale_plan', 'parameter uninitialized'), ('stale_parameters', 'PINGPONG_MISMATCH stage=6')]
                    for case, expected_failure in cases:
                        exe = folder/f'{case}_{stalls}.vvp'
                        plan = ROOT/'rtl/r2/c1_r2_microstyle_plan.sv' if case == 'stale_plan' else folder/'package/execution_plan.sv'
                        data_dir, meta = (stale_folder, stale_meta) if case == 'stale_parameters' else (folder, m)
                        opts = dict(STALLS=stalls, STAGE_COUNT=m['stage_count'], RGB_STAGE=m['rgb_stage'],
                                    MEMORY_DIV=a.memory_div, COMMAND_LATENCY=a.latency,
                                    WRITE_THROTTLE=a.write_throttle, RESET_PROBE=int(a.reset_only),
                                    CORRUPT_HANDOFF=int(case[-1]) if case.startswith('handoff') else 0)
                        cmd = ['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', TOP,
                               *[f'-P{TOP}.{k}={v}' for k, v in opts.items()], '-o', str(exe),
                               *[str(ROOT/s) for s in SOURCES], str(plan), str(ROOT/f'sim/{TOP}.sv')]
                        c = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                        if c.returncode:
                            raise RuntimeError(c.stderr[-3000:])
                        cmd = ['D:/iverilog/bin/vvp.exe', str(exe), f'+DIR={data_dir.as_posix()}', f'+W={w}', f'+H={h}',
                               f'+P={meta["parameter_words"]}', f'+I={meta["input_words"]}', f'+E={meta["expected_words"]}']
                        if expected_failure:
                            r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
                            if r.returncode == 0 or expected_failure not in r.stdout:
                                raise RuntimeError('negative did not fail as intended: '+case+'\n'+r.stdout[-2200:])
                            print(PREFIX+f'NEGATIVE_PASS profile={profile} stalls={stalls} case={case} actual_ram_or_plan=1', flush=True)
                            continue
                        tail = deque(maxlen=25)
                        pass_marker = PREFIX+('RESET_SUITE_PASS ' if a.reset_only else 'PASS ')
                        passes, bad = 0, False
                        with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as child:
                            timer = threading.Timer(a.timeout_seconds, child.kill)
                            timer.daemon = True
                            timer.start()
                            try:
                                for line in child.stdout:
                                    line = line.rstrip()
                                    tail.append(line)
                                    if line.startswith(PREFIX):
                                        print(line, flush=True)
                                    passes += line.startswith(pass_marker)
                                    bad |= 'FATAL' in line or 'ERROR' in line
                                code = child.wait()
                            finally:
                                timer.cancel()
                        if code or bad or passes != 1:
                            raise RuntimeError('\n'.join(tail))
    print(PREFIX+'CLEAN temporary_packages_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__':
    main()
