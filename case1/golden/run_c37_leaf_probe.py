"""C37 actual Icarus tests, compact evidence and automatic private-dir cleanup.

No Vivado/Efinity processes are launched by this runner. Long/native/PNR tests
must use a separate detached, Job-independent serial worker.
"""
import argparse
import atexit
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
from c37_sources import ROOT, REPLACEMENTS, sources


def budget():
    if os.name == 'nt':
        api = ctypes.WinDLL('kernel32', use_last_error=True)
        api.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        api.CreateMutexW.restype = ctypes.c_void_p
        api.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        api.ReleaseMutex.argtypes = [ctypes.c_void_p]
        api.CloseHandle.argtypes = [ctypes.c_void_p]
        lease = api.CreateMutexW(None, False, 'Local\\Case1FpgaHeavyWorker')
        if not lease:
            raise ctypes.WinError(ctypes.get_last_error())
        acquired = api.WaitForSingleObject(lease, 0)
        if acquired not in (0, 128):
            api.CloseHandle(lease)
            raise RuntimeError('Another budgeted FPGA worker is active; no overlapping simulation launched')
        def release():
            api.ReleaseMutex(lease)
            api.CloseHandle(lease)
        atexit.register(release)
        api.GetCurrentProcess.restype = ctypes.c_void_p
        handle = api.GetCurrentProcess()
        api.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        api.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        if not api.SetPriorityClass(handle, 0x4000) or not api.SetProcessAffinityMask(handle, 3):
            raise ctypes.WinError(ctypes.get_last_error())


def execute(command, folder, timeout=90):
    result = subprocess.run(list(map(str, command)), cwd=folder, capture_output=True,
                            text=True, errors='replace', timeout=timeout)
    return result.returncode, result.stdout + result.stderr


def compile_test(folder, top, source_list, options=()):
    exe = folder / (top + '_' + str(len(list(folder.glob('*.vvp')))) + '.vvp')
    command = ['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', top,
               *options, '-o', exe, *source_list]
    code, output = execute(command, folder)
    if code or 'error:' in output.lower():
        diagnostic = [line for line in output.splitlines()
                      if any(word in line.lower() for word in ('error:', 'syntax', 'unable', 'not found'))]
        raise RuntimeError('compile: ' + ('\n'.join(diagnostic) if diagnostic else output)[-6000:])
    # Keep warning types/counts, not repeated thousands-line elaboration output.
    warnings = sorted(set(line for line in output.splitlines()
                          if 'warning:' in line.lower()))
    ordinary = [w for w in warnings if 'cannot be synthesized in an always_ff' in w]
    for warning in [w for w in warnings if w not in ordinary][:8]:
        print('C37_COMPILE_WARNING ' + warning, flush=True)
    if ordinary:
        print(f'C37_ASSERTION_ELAB_NOTICES unique={len(ordinary)} synthesis_guarded=1', flush=True)
    return exe


def run_test(folder, exe, args, marker, negative=None, timeout=120):
    code, output = execute(['D:/iverilog/bin/vvp.exe', exe, *args], folder, timeout)
    if negative:
        if not code or negative not in output or marker in output:
            raise RuntimeError('wrong negative result: ' + output[-4000:])
        print('C37_NEGATIVE_PASS reason=' + negative, flush=True)
    else:
        if code or output.count(marker) != 1 or 'FATAL' in output or 'ERROR' in output:
            raise RuntimeError('simulation: ' + output[-4000:])
        for line in output.splitlines():
            if line.startswith(marker):
                print('C37_ACTUAL_RTL ' + line, flush=True)


def resize(folder):
    # Mechanically rename only the baseline module in a disposable miter fixture.
    original = (ROOT / 'rtl/video/r1_bilinear_interp_rgb888.sv').read_text(encoding='utf-8-sig')
    anchor = 'module r1_bilinear_interp_rgb888 #('
    assert original.count(anchor) == 1
    retained = folder / 'retained_interp.sv'
    retained.write_text(original.replace(anchor, 'module c37_retained_interp #('), encoding='utf-8')
    top = 'tb_c37_resize_difference'
    for bad_weight, bad_golden in ((0, 0), (1, 0), (0, 1)):
        exe = compile_test(folder, top, [ROOT / 'rtl/c37/r1_bilinear_interp_rgb888.sv',
                           retained, ROOT / f'sim/{top}.sv'],
                           [f'-P{top}.BAD_WEIGHT={bad_weight}', f'-P{top}.BAD_GOLDEN={bad_golden}'])
        reason = 'bilinear X weights must sum to 4096' if bad_weight else (
            'C37 resize independent golden mismatch' if bad_golden else None)
        run_test(folder, exe, [], 'C37_RESIZE_DIFFERENCE_PASS ', reason)


def shadow(folder):
    from r2_row_shadow_engine_vectors import vectors
    top = 'tb_c1_r2_cnn_row_shadow_engine'
    executables = {}
    for width, height, stalls, reset_phase, negative in (
        (6, 3, 0, 0, 0), (6, 3, 1, 0, 0), (320, 2, 1, 0, 0),
        (6, 3, 1, 1, 0), (6, 3, 1, 2, 0),
        (6, 3, 1, 0, 1), (6, 3, 1, 0, 2), (6, 3, 1, 0, 3)):
        fixture = folder / f'shadow_{width}_{stalls}_{reset_phase}_{negative}'
        fixture.mkdir()
        meta = vectors(fixture, width, height)
        key = stalls, reset_phase, negative
        if key not in executables:
            executables[key] = compile_test(folder, top, sources() + [ROOT / f'sim/{top}.sv'],
                [f'-P{top}.STALLS={stalls}', f'-P{top}.RESET_PHASE={reset_phase}', f'-P{top}.NEGATIVE={negative}'])
        args = [f'+INPUTS={fixture.as_posix()}/commands.mem', f'+OUTPUTS={fixture.as_posix()}/expected.mem',
                f'+SHADOW={fixture.as_posix()}/shadow.mem']
        args += [f'+{arg}={meta[key]}' for arg, key in (
            ('N','commands'), ('M','packets'), ('S','shadow_words'), ('J','operations'),
            ('BULK','bulk_writes'), ('PARAMS','parameter_writes'), ('BAD_BIAS','bad_bias_channel'))]
        reason = {0: None, 1: 'shadow memory golden mismatch',
                  2: 'shadow engine DW/PW numeric mismatch',
                  3: 'partition window linear reader before spatial drain'}[negative]
        print('C37_SHADOW_CASE ' + json.dumps(dict(width=width*2, height=height*2,
              stalls=stalls, reset_phase=reset_phase, negative=negative)), flush=True)
        run_test(folder, executables[key], args, 'C35_SHADOW_ENGINE_PASS ', reason)


def capacity(folder):
    top = 'tb_c37_capacity'
    exe = compile_test(folder, top, sources() + [ROOT / f'sim/{top}.sv'])
    run_test(folder, exe, [], 'C37_CAPACITY_PASS ')


def window(folder):
    top = 'tb_c37_window_capacity'
    names = ['rtl/common/c1_ram_sdp_read_first.sv', 'rtl/r2/c1_r2_feature_overlay_ram.sv',
             'rtl/r2/c1_r2_overlay_window_store.sv', 'rtl/r2/c1_r2_partitioned_feature_ram.sv',
             'rtl/c37/c1_r2_partitioned_window_store.sv', f'sim/{top}.sv']
    for rows in (512, 1024):
        print(f'C37_WINDOW_CASE row_words={rows}', flush=True)
        exe = compile_test(folder, top, [ROOT / name for name in names], [f'-P{top}.ROW_WORDS={rows}'])
        run_test(folder, exe, [], 'C37_WINDOW_CAPACITY_PASS ')


def compute(folder):
    top = 'tb_c37_indexed_compute'
    names = ['rtl/r2/c1_r2_dot16_array.sv', 'rtl/cnn/c1_requant_bank8_compact.sv',
             'rtl/c37/c37_compute6_indexed.sv', f'sim/{top}.sv']
    original = (ROOT / 'rtl/c37/reference/c37_compute6_indexed_v1.sv').read_text(encoding='utf-8-sig')
    anchor = 'module c37_compute6_indexed #('
    if original.count(anchor)!=1:
        raise ValueError('unexpected retained indexed-compute declaration')
    retained = folder / 'retained_indexed_compute.sv'
    retained.write_text(original.replace(anchor,'module c37_compute6_indexed_v1 #('),encoding='utf-8')
    for channels, negative in ((24,0),(48,0),(24,1),(24,2),(24,3)):
        exe = compile_test(folder, top, [ROOT/name for name in names]+[retained],
                          [f'-P{top}.MAX_CHANNELS={channels}',f'-P{top}.NEGATIVE={negative}'])
        reason = {0:None,1:'C37 live parameter table changed during transaction lease',
                  2:'R2 compute interleaved reduction metadata',3:'C37 compute channel out of capacity'}[negative]
        run_test(folder, exe, [], 'C37_INDEXED_COMPUTE_PASS ', reason)


def fallback(folder):
    from run_r2_overlay_operator_probe import vectors
    fixture = folder / 'fallback'
    fixture.mkdir()
    meta = vectors(fixture)
    print('C37_FALLBACK_VECTORS ' + json.dumps(meta, separators=(',', ':')), flush=True)
    top = 'tb_c37_operator_fallback'
    for stalls in (0, 1):
        exe = compile_test(folder, top, sources() + [ROOT / f'sim/{top}.sv'],
                          ['-DC37_MAX_CHANNELS=48', '-DC37_ROW_WORDS=1024', f'-P{top}.STALLS={stalls}'])
        run_test(folder, exe, [f'+INPUTS={fixture.as_posix()}/bulk.mem',
            f'+OUTPUTS={fixture.as_posix()}/reference/output.mem', f'+N={meta["commands"]}',
            f'+M={meta["vectors"]}', f'+J={meta["jobs"]}'], 'C37_OPERATOR_PASS ', timeout=900)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=('compile', 'resize', 'shadow', 'capacity', 'window', 'compute', 'fallback', 'all'), default='all')
    args = parser.parse_args()
    budget()
    with tempfile.TemporaryDirectory(prefix='c37_leaf_', dir=ROOT/'sim') as temporary:
        folder = Path(temporary)
        if args.phase in ('compile', 'all'):
            for channels, rows in ((24,512), (48,1024)):
                compile_test(folder, 'c1_r2_fused_rgb2_host_system', sources(),
                             [f'-DC37_MAX_CHANNELS={channels}', f'-DC37_ROW_WORDS={rows}'])
                print(f'C37_HOST_COMPILE_PASS channels={channels} row_words={rows} '
                      f'sources={len(sources())} replacements={len(REPLACEMENTS)}', flush=True)
        if args.phase in ('resize', 'all'):
            resize(folder)
        if args.phase in ('shadow', 'all'):
            shadow(folder)
        if args.phase in ('capacity', 'all'):
            capacity(folder)
        if args.phase in ('window', 'all'):
            window(folder)
        if args.phase in ('compute', 'all'):
            compute(folder)
        if args.phase in ('fallback', 'all'):
            fallback(folder)
    print('C37_LEAF_CLEAN phase=' + args.phase + ' temporary_directory_removed=1', flush=True)


if __name__ == '__main__':
    main()
