"""C19 recoverable response errors in the unchanged C18 production host."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from run_r2_planned_host_probe import ROOT, SOURCES, PLAN_SOURCE, SIM
from r2_plan_vectors import vectors, compile_package, profile_nodes

TOP = 'tb_c1_r2_host_recovery_system'
PREFIX = 'C1_R2_HOST_RECOVERY_'


def choices(value, allowed):
    result = [int(x) for x in value.split(',')]
    if len(set(result)) != len(result) or not set(result) <= set(allowed):
        raise ValueError('invalid/duplicate test configuration')
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--shapes', default='8x8')
    p.add_argument('--stalls', default='0,1')
    p.add_argument('--modes', default='1,2,3,4')
    p.add_argument('--aw-wait-w', default='0')
    p.add_argument('--negative-only', action='store_true')
    p.add_argument('--hold-cycles', type=int, default=64)
    p.add_argument('--min-held-cnn-debt', type=int, choices=range(1, 5), default=1)
    args = p.parse_args()
    stalls = choices(args.stalls, (0, 1))
    modes = choices(args.modes, range(1, 5))
    aw_modes = choices(args.aw_wait_w, (0, 2))
    if not 32 <= args.hold_cycles <= 4096:
        p.error('hold-cycles must be 32..4096')
    package = compile_package(profile_nodes('microstyle24'))
    with tempfile.TemporaryDirectory(prefix='c1_r2_host_recovery_', dir=ROOT/'sim') as td:
        root = Path(td)
        for shape in args.shapes.split(','):
            w, h = map(int, shape.split('x'))
            if w*h > 4096:
                raise ValueError('bounded fault test only, not native FPS')
            folder = root/shape
            folder.mkdir()
            meta = vectors(folder, w, h, 'microstyle24', package)
            print(PREFIX+'FIXTURE '+json.dumps(dict(width=w, height=h, stage_count=meta['stage_count'],
                  parameter_words=meta['parameter_words'], expected_words=meta['expected_words'],
                  frame_scalars=meta['frames'][0]['scalars'], actual_c18_host=True)), flush=True)
            sources = [str(ROOT/s) for s in SOURCES if s != PLAN_SOURCE]+[str(folder/'package/execution_plan.sv')]
            for stall in stalls:
                for aw in aw_modes:
                    for mode in modes:
                        exe = folder/'recovery.vvp'
                        opts = dict(WIDTH=w, HEIGHT=h, STALLS=stall, AW_WAIT_W=aw, FAULT_MODE=mode,
                                    STAGE_COUNT=meta['stage_count'], RGB_STAGE=meta['rgb_stage'],
                                    FAULT_HOLD=args.hold_cycles, MIN_HELD_CNN_DEBT=args.min_held_cnn_debt)
                        if args.negative_only:
                            # Modes 1/3 suppress the physical error itself;
                            # modes 2/4 leave the error but mask its IRQ.
                            opts['FAULT_DISABLE' if mode in (1, 3) else 'ERROR_IRQ_MASK'] = 1 if mode in (1, 3) else 0
                        c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', TOP,
                                            *[f'-P{TOP}.{k}={v}' for k, v in opts.items()], '-o', str(exe),
                                            *sources, *[str(ROOT/s) for s in SIM], str(ROOT/f'sim/{TOP}.sv')],
                                           capture_output=True, text=True, timeout=90)
                        if c.returncode:
                            raise RuntimeError(c.stderr[-3000:])
                        r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe), f'+DIR={folder.as_posix()}',
                                            f'+P={meta["parameter_words"]}', f'+I={meta["input_words"]}',
                                            f'+E={meta["expected_words"]}'], capture_output=True, text=True, timeout=900)
                        if args.negative_only:
                            reason = 'faulted frame reported success' if mode in (1, 3) else 'failed completion did not raise masked error IRQ'
                            if r.returncode == 0 or reason not in r.stdout or PREFIX+'PASS ' in r.stdout:
                                raise RuntimeError('negative control failed: '+(r.stdout+r.stderr)[-2200:])
                            print(PREFIX+f'NEGATIVE_PASS width={w} height={h} stalls={stall} mode={mode} aw_wait_w={aw} '+
                                  ('physical_error_disabled=1' if mode in (1, 3) else 'error_irq_masked=1'), flush=True)
                            continue
                        for line in r.stdout.splitlines():
                            if line.startswith(PREFIX):
                                print(line, flush=True)
                        if r.returncode or r.stdout.count(PREFIX+'PASS ') != 1 or r.stdout.count(PREFIX+'RESULT ') != 1 or 'FATAL' in r.stdout:
                            raise RuntimeError((r.stdout+r.stderr)[-3500:])
    print(PREFIX+'CLEAN temporary_packages_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__':
    main()
