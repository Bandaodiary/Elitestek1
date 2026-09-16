"""Fresh xsim regression of the promoted Resize and complete C39 host closure."""
import argparse
import ctypes
import json
import re
import subprocess
import tempfile
from pathlib import Path

from c40_four_row_candidate import SOURCE, render
from c39_onehot_sources import sources
from c39_onehot_trained_contract import ROOT, bound_candidate, build_vectors, source_gate
from generate_r1_resize_line_sampler_vectors import generate
from run_r2_resize_probe import SOURCES as SERIAL
from run_r2_resize_overlap_probe import SOURCES as OVERLAP
from run_r2_demo_rgb2_capture_probe import EXTRA, vectors
from run_c39_onehot_trained_host_probe import CASES, SIM, TOP, camera_geometry
from check_r2_trained_host_evidence import check_text, corruption_checks
from c40_100mhz_contract import fixture
from run_c40_iverilog_pipeline import MODELS, verify_output

VIVADO = Path('D:/vivado/vivado/Vivado/2023.1/bin')
MODEL = ROOT / 'outputs/c36_qat_b_mosaic_stable_20260915a'


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def isolated():
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    kernel.IsProcessInJob.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    value = ctypes.c_int()
    if not kernel.IsProcessInJob(kernel.GetCurrentProcess(), None, ctypes.byref(value)) or value.value:
        raise RuntimeError('regression must run outside Windows Job')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--matrix100-only', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id):
        raise ValueError('invalid run id')
    isolated()
    log = ROOT / 'logs/c40_production_runs' / args.run_id
    log.mkdir(parents=True, exist_ok=False)
    results = []
    initial = {p: p.read_text(encoding='utf-8-sig') for p in sources()}
    source_gate()
    (log / 'production_sampler.sv').write_text(render(), encoding='utf-8')
    import torch
    torch.set_num_threads(2)
    package, config, provenance = bound_candidate(MODEL)

    def run(label, folder, top, files, opts=None, plus=None, defines=(), expected_failure=None):
        opts, plus = opts or {}, plus or {}
        folder.mkdir(parents=True, exist_ok=True)
        case_log = log / label
        case_log.mkdir()
        commands = [
            [str(VIVADO / 'xvlog.bat'), '-sv', *[v for d in defines for v in ('-d', d)], *map(str, files)],
            [str(VIVADO / 'xelab.bat'), top, '-s', 'regression', '-mt', '2',
             *[v for k, n in opts.items() for v in ('-generic_top', f'{k}={n}')]],
            [str(VIVADO / 'xsim.bat'), 'regression', '-runall',
             *[v for k, n in plus.items() for v in ('-testplusarg', f'{k}={n}')]]]
        write_json(case_log / 'manifest.json', dict(top=top, sources=list(map(str, files)), options=opts,
                   plusargs=plus, defines=defines, commands=commands, private_sampler_substitution=False))
        for stage, command in zip(('compile', 'elaborate', 'simulate'), commands):
            write_json(log / 'status.json', dict(state='running', case=label, step=stage, completed=results))
            # cmd treats an unquoted '=' as a batch argument separator. Quote
            # every token, including NAME=value generics and test plusargs.
            if any(any(c in arg for c in '\"\r\n%') for arg in command):
                raise ValueError('unsupported Windows batch argument')
            launch = 'cmd.exe /d /s /c "' + ' '.join('"' + arg + '"' for arg in command) + '"'
            with (case_log / f'{stage}.log').open('w', encoding='utf-8') as out:
                child = subprocess.Popen(launch, cwd=folder, stdout=out, stderr=subprocess.STDOUT,
                                         creationflags=subprocess.CREATE_NO_WINDOW)
                write_json(case_log / f'{stage}.process.json', dict(pid=child.pid, in_windows_job=False))
                try:
                    code = child.wait(timeout=3600)
                except subprocess.TimeoutExpired:
                    subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                    child.wait(timeout=30)
                    raise
            raw = (case_log / f'{stage}.log').read_bytes()
            text = raw.decode('utf-8', errors='replace')
            if stage != 'simulate' or expected_failure is None:
                if code or re.search(r'(?im)\bFATAL\b|^ERROR:', text):
                    raise RuntimeError(f'{label}/{stage} failed; see {case_log}')
            write_json(case_log / f'{stage}.exit.json', dict(exit_code=code))
        if expected_failure is not None:
            if expected_failure not in text or 'C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS ' in text:
                raise RuntimeError('negative control failed to reject corruption: ' + label)
        return text

    try:
        with tempfile.TemporaryDirectory(prefix='c40_production_', dir=ROOT / 'sim') as td:
            work = Path(td)
            pipeline_cases = () if args.matrix100_only else ((False, SERIAL, 'C1_R2_RESIZE_PIPELINE_PASS '),
                                                            (True, OVERLAP, 'C30_RESIZE_OVERLAP_PIPELINE_PASS '))
            for overlap, file_list, prefix in pipeline_cases:
                top = 'tb_c1_r2_resize_' + ('overlap_pipeline' if overlap else 'pipeline')
                for registered in (0, 1):
                    label = f'resize_{int(overlap)}_reset_{registered}'
                    folder = work / label
                    folder.mkdir()
                    generate(folder, 20260913)
                    text = run(label, folder, top, [ROOT / p for p in file_list] + [ROOT / f'sim/{top}.sv'],
                               defines=['C1_REGISTER_ABORT_RESET'] if registered else [])
                    if text.count(prefix) != 1:
                        raise RuntimeError('missing pipeline PASS: ' + label)
                    results.append(dict(case=label, passed=True, evidence=[l for l in text.splitlines() if 'PASS ' in l]))

            swaps = {'rtl/video/c1_r1_resize_system.sv': 'rtl/r2/c1_r2_resize_overlap_system.sv',
                     'rtl/r2/c1_r2_resize_pipeline.sv': 'rtl/r2/c1_r2_resize_overlap_pipeline.sv',
                     'rtl/r2/c1_r2_resize_capture_rgbx32.sv': 'rtl/r2/c1_r2_resize_overlap_capture.sv',
                     'rtl/video/r1_bilinear_interp_rgb888.sv': 'rtl/c37/r1_bilinear_interp_rgb888.sv'}
            capture_top = 'tb_c1_r2_demo_rgb2_capture'
            capture_files = [ROOT / swaps.get(p, p) for p in SERIAL + EXTRA +
                             ['sim/c1_r2_axi_memory_bfm.sv', f'sim/{capture_top}.sv']]
            capture_cases = () if args.matrix100_only else ((0, 0, False), (0, 1, False), (1, 0, False),
                                                           (1, 1, False), (0, 0, True))
            for odd, stalls, native in capture_cases:
                label = 'capture_native100' if native else f'capture_odd{odd}_stall{stalls}'
                folder = work / label
                folder.mkdir()
                geometry = ((1920, 1080, 240, 0, 1440, 1080, 640, 480) if native else
                            (20, 20, 3, 2, 15, 15, 8, 8) if odd else (20, 20, 2, 2, 16, 16, 8, 8))
                plus = vectors(folder, *geometry)
                plus['DIR'] = folder.as_posix()
                opts = dict(zip(('SW', 'SH', 'RX', 'RY', 'RW', 'RH', 'OW', 'OH'), geometry))
                opts.update(FD=512 if native else 64, FAULTS=0 if native else 1, STALLS=stalls, CORE_HALF=5.0)
                if native:
                    opts.update(CAM_HALF=7.143, HBLANK=106, VBLANK=42)
                text = run(label, folder, capture_top, capture_files, opts, plus, ['C30_RESIZE_OVERLAP'])
                if text.count('C1_R2_DEMO_RGB2_CAPTURE_PASS ') != 1 or (native and 'results=2 good=2 bad=0' not in text):
                    raise RuntimeError('capture golden check incomplete: ' + label)
                results.append(dict(case=label, passed=True, evidence=[l for l in text.splitlines() if 'PASS ' in l]))

            host_cases = ([dict(case, id=f'm{index}_' + case['id'], model=model)
                           for index, model in enumerate(MODELS) for case in CASES]
                          if args.matrix100_only else [dict(case, model=MODEL.name) for case in CASES])
            for case in host_cases:
                label = 'host_' + case['id']
                folder = work / label
                package, config, provenance = bound_candidate(ROOT / 'outputs' / case['model'])
                meta = build_vectors(folder, case['width'], case['height'], package, config, provenance)
                selected = [p for p in sources() if p.name not in ('execution_plan.sv', 'row_fusion_plan.sv')]
                selected += [folder / 'package/execution_plan.sv', folder / 'fusion_plan.sv']
                sw, sh, rx, ry, rw, rh = camera_geometry(case['width'], case['height'])
                opts = dict(WIDTH=case['width'], HEIGHT=case['height'], STALLS=case['stalls'], AW_WAIT_W=2,
                            MEMORY_DIV=2, COMMAND_LATENCY=20, FRAME_DIVISOR=2, CAMERA_SW=sw, CAMERA_SH=sh,
                            CAMERA_RX=rx, CAMERA_RY=ry, CAMERA_RW=rw, CAMERA_RH=rh, NN_TARGET=2,
                            NEGATIVE_CONTROL=case['negative'], STAGE_COUNT=meta['stage_count'], RGB_STAGE=meta['rgb_stage'],
                            FUSED_DW_STAGE=meta['dw_stage'], FUSED_PW_STAGE=meta['pw_stage'])
                plus = dict(DIR=folder.as_posix(), P=meta['parameter_words'], I=meta['input_words'],
                            E=meta['expected_words'], DW=meta['dw_packets'])
                for index, src in enumerate(meta['sources']):
                    plus.update({f'{tag}{index}': src[key] for tag, key in
                                 [('SW','width'), ('SH','height'), ('XS','xs'), ('YS','ys'), ('XP','xp'), ('YP','yp')]})
                failure = {1: 'CNN golden mismatch stage=0', 2: 'display pair not actually produced'}.get(case['negative'])
                testbench = ROOT / f'sim/{TOP}.sv'
                if args.matrix100_only:
                    testbench = folder / (TOP + '.sv')
                    testbench.write_text(fixture((ROOT / f'sim/{TOP}.sv').read_text(encoding='utf-8-sig')), encoding='utf-8')
                    opts.update(CLOCKS_NATIVE=1, CPU_START_NEGATIVE=0)
                text = run(label, folder, TOP, selected + [ROOT / p for p in SIM] + [testbench],
                           opts, plus, expected_failure=failure)
                if failure:
                    record = dict(expected_failure=failure, actual_RAM_corruption=True)
                else:
                    if args.matrix100_only:
                        record = verify_output(text, config, native=False)
                    else:
                        record = check_text(text, config, nn=2)
                        record['evidence_corruption_rejections'] = corruption_checks(text, config, 2)
                results.append(dict(case=label, model=case['model'], passed=True, **record))

            if any(p.read_text(encoding='utf-8-sig') != content for p, content in initial.items()):
                raise RuntimeError('source changed during regression')
        summary = dict(state='complete', tests=len(results), cases=results, source_files=list(map(str, initial)),
                       private_sampler_substitution=False, native_capture_frames=0 if args.matrix100_only else 2,
                       trained_host_positive_cases=12 if args.matrix100_only else 4,
                       actual_RAM_corruption_controls=6 if args.matrix100_only else 2,
                       matrix100_only=args.matrix100_only, model_count=3 if args.matrix100_only else 1,
                       core_native_capture_hz=100000000, actual_CPU_IP=False, temporary_removed=True)
        write_json(log / 'summary.json', summary)
        write_json(log / 'status.json', dict(state='complete', tests=len(results)))
        print('C40_PRODUCTION_REGRESSION_PASS tests=' + str(len(results)), flush=True)
    except Exception as exc:
        write_json(log / 'status.json', dict(state='failed', error=str(exc), completed=results))
        raise


if __name__ == '__main__':
    main()
