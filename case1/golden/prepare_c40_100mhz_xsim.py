"""Prepare the native 640x480 C40 design for an xsim-only six-frame run."""
import argparse
import json
from pathlib import Path

from c40_100mhz_contract import ROOT, TOP, fixture, replace_once
from c39_onehot_trained_contract import bound_candidate, build_vectors, source_gate
from c39_onehot_sources import sources
from c39_seam_admission import check
from c40_four_row_candidate import render as four_row_source


MODEL = 'c36_qat_b_mosaic_stable_20260915a'


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--regression-run', default='c40_production_20260916a')
    args = parser.parse_args()
    work = args.work_dir.resolve()
    log = args.log_dir.resolve()
    if not work.is_relative_to(ROOT / 'sim') or not log.is_relative_to(ROOT / 'logs/c40_100mhz_xsim_runs'):
        raise ValueError('private work/log directory required')
    work.mkdir(parents=True, exist_ok=True)
    log.mkdir(parents=True, exist_ok=True)

    prior = ROOT / 'logs/c40_production_runs' / args.regression_run
    prior_state = json.loads((prior / 'summary.json').read_text(encoding='utf-8-sig'))
    candidate_text = four_row_source()
    if (prior_state['state'] != 'complete' or prior_state['tests'] != 15 or
            prior_state['native_capture_frames'] != 2 or prior_state['private_sampler_substitution']):
        raise ValueError('production regression prerequisite incomplete')
    if (prior / 'production_sampler.sv').read_text(encoding='utf-8') != candidate_text:
        raise ValueError('production sampler changed after prerequisite')
    matrix = ROOT / 'logs/c40_production_runs' / (args.regression_run + '_matrix100')
    matrix_state = json.loads((matrix / 'summary.json').read_text(encoding='utf-8-sig'))
    if (matrix_state['state'] != 'complete' or matrix_state['tests'] != 18 or
            matrix_state['model_count'] != 3 or not matrix_state['matrix100_only'] or
            matrix_state['actual_RAM_corruption_controls'] != 6 or
            (matrix / 'production_sampler.sv').read_text(encoding='utf-8') != candidate_text):
        raise ValueError('three-model 100MHz production matrix incomplete')

    check()
    source_gate()
    package, config, provenance = bound_candidate(ROOT / 'outputs' / MODEL)
    vector_dir = work / 'vectors'
    meta = build_vectors(vector_dir, 640, 480, package, config, provenance)

    testbench_text = fixture((ROOT / 'sim' / f'{TOP}.sv').read_text(encoding='utf-8-sig'))
    testbench_text = replace_once(
        testbench_text,
        'c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;',
        'c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;\n'
        '        if(c40_core_edges%1000000==0)$display("C40_PROGRESS core_cycles=%0d simulation_ns=%0t",c40_core_edges,$time);')
    testbench = work / f'{TOP}.sv'
    testbench.write_text(testbench_text, encoding='utf-8')

    selected = [p for p in sources() if p.name not in ('execution_plan.sv', 'row_fusion_plan.sv')]
    original = ROOT / 'rtl/r2/c1_r2_resize_line_sampler.sv'
    if selected.count(original) != 1:
        raise ValueError('production sampler must occur exactly once')
    selected += [vector_dir / 'package/execution_plan.sv', vector_dir / 'fusion_plan.sv']
    if len(selected) != 49 or not all(p.is_file() for p in selected):
        raise ValueError('C40 source closure incomplete')

    opts = dict(WIDTH=640, HEIGHT=480, STALLS=0, BANK_WORDS=524288, MAX_CYCLES=120000000,
        MEMORY_DIV=2, COMMAND_LATENCY=20, AW_WAIT_W=2, NN_TARGET=6, FRAME_DIVISOR=1,
        CLOCKS_NATIVE=1, CPU_START_NEGATIVE=0, NEGATIVE_CONTROL=0,
        STAGE_COUNT=meta['stage_count'], RGB_STAGE=meta['rgb_stage'],
        FUSED_DW_STAGE=meta['dw_stage'], FUSED_PW_STAGE=meta['pw_stage'])
    camera = meta['sources'][0]
    for key, field in [('SW','width'),('SH','height'),('RX','roi_x'),('RY','roi_y'),
                       ('RW','roi_width'),('RH','roi_height')]:
        opts['CAMERA_' + key] = camera[field]
    plusargs = [f'DIR={vector_dir.as_posix()}', f'P={meta["parameter_words"]}',
                f'I={meta["input_words"]}', f'E={meta["expected_words"]}', f'DW={meta["dw_packets"]}']
    for index, source in enumerate(meta['sources']):
        plusargs += [f'{tag}{index}={source[field]}' for tag, field in
                     [('SW','width'),('SH','height'),('XS','xs'),('YS','ys'),('XP','xp'),('YP','yp')]]
    manifest = dict(top=TOP, snapshot='c40_100mhz_xsim_native', model=MODEL,
        sources=[str(p) for p in selected],
        support_sources=[str(ROOT/'sim/c1_r2_axi_memory_bfm.sv'), str(ROOT/'sim/c1_r2_axi_traffic_agent.sv')],
        testbench=str(testbench), options=opts, plusargs=plusargs,
        regression_run=args.regression_run, actual_CPU_IP=False, core_hz=100000000,
        simulator='Vivado xsim 2023.1', four_rows=True, private_sampler_substitution=False)
    write_json(work / 'manifest.json', manifest)
    write_json(log / 'manifest.json', manifest)
    write_json(log / 'metadata.json', meta)
    (log / 'testbench.sv').write_text(testbench_text, encoding='utf-8')
    (log / 'candidate.sv').write_text(candidate_text, encoding='utf-8')
    (log / 'execution_plan.sv').write_text(selected[-2].read_text(encoding='utf-8'), encoding='utf-8')
    (log / 'fusion_plan.sv').write_text(selected[-1].read_text(encoding='utf-8'), encoding='utf-8')
    print('C40_XSIM_PREPARE_PASS sources=49 width=640 height=480 nn_target=6 core_hz=100000000 four_rows=1')


if __name__ == '__main__':
    main()
