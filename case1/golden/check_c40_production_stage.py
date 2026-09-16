"""Read retained primary evidence before accepting the production C40 stage."""
import argparse
import json
import re
from pathlib import Path
from c40_production_project import ROOT, NAME, verify
from c40_four_row_candidate import render, SOURCE
from c40_100mhz_contract import throughput
from c39_onehot_sources import sources
from check_r2_trained_host_evidence import check_text
from run_c40_iverilog_pipeline import MODELS, verify_output


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def read_tool_log(path):
    raw = path.read_bytes()
    # Windows PowerShell 5 redirects native stdout as BOM-tagged UTF-16;
    # copied Efinity .rpt files and explicit UTF8 logs use UTF-8 instead.
    encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    return raw.decode(encoding).replace('\r\n', '\n').replace('\r', '\n')


def need(condition, message):
    if not condition:
        raise ValueError(message)


def audit(run_id):
    verify()
    small = ROOT / 'logs/c40_production_runs' / run_id
    native = ROOT / 'logs/c40_100mhz_xsim_runs' / (run_id + '_native')
    eda = ROOT / 'logs/efinity_resource_runs' / (run_id + '_pnr')
    summary = read_json(small / 'summary.json')
    need(summary['state'] == 'complete' and summary['tests'] == 15, 'production matrix incomplete')
    need(not summary['private_sampler_substitution'], 'private sampler used')
    need((small / 'production_sampler.sv').read_text(encoding='utf-8-sig') == render(), 'production sampler changed')
    need(summary['native_capture_frames'] == 2 and summary['actual_RAM_corruption_controls'] == 2,
         'capture/fault coverage missing')
    expected_cases = {f'resize_{overlap}_reset_{reset}' for overlap in (0, 1) for reset in (0, 1)}
    expected_cases |= {f'capture_odd{odd}_stall{stalls}' for odd in (0, 1) for stalls in (0, 1)}
    expected_cases |= {'capture_native100', 'host_8_0', 'host_8_1', 'host_32_0', 'host_32_1',
                       'host_negative_1', 'host_negative_2'}
    need({c['case'] for c in summary['cases']} == expected_cases and all(c['passed'] for c in summary['cases']),
         'production test coverage differs')
    for case in summary['cases']:
        folder = small / case['case']
        manifest = read_json(folder / 'manifest.json')
        need(manifest['sources'].count(str(SOURCE)) == 1 and not manifest['private_sampler_substitution'],
             'case lacks unique production sampler: ' + case['case'])
        for step in ('compile', 'elaborate'):
            need(read_json(folder / (step + '.exit.json'))['exit_code'] == 0, 'build failed')
        text = (folder / 'simulate.log').read_text(encoding='utf-8', errors='replace')
        if 'expected_failure' in case:
            need(case['expected_failure'] in text and 'C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS ' not in text,
                 'negative control not evidenced')
        else:
            need(read_json(folder / 'simulate.exit.json')['exit_code'] == 0 and 'PASS ' in text and
                 not re.search(r'(?im)\bFATAL\b|^ERROR:', text), 'simulation failed')
    matrix = ROOT / 'logs/c40_production_runs' / (run_id + '_matrix100')
    matrix_summary = read_json(matrix / 'summary.json')
    need(matrix_summary['state'] == 'complete' and matrix_summary['tests'] == 18 and
         matrix_summary['matrix100_only'] and matrix_summary['model_count'] == 3 and
         matrix_summary['actual_RAM_corruption_controls'] == 6, 'three-model 100MHz matrix incomplete')
    need((matrix / 'production_sampler.sv').read_text(encoding='utf-8-sig') == render(), 'matrix sampler changed')
    expected_matrix = {f'host_m{i}_{case}' for i in range(3) for case in
                       ('8_0', '8_1', '32_0', '32_1', 'negative_1', 'negative_2')}
    need({c['case'] for c in matrix_summary['cases']} == expected_matrix, 'matrix configurations missing')
    need({c['model'] for c in matrix_summary['cases']} == set(MODELS), 'matrix model set differs')
    for case in matrix_summary['cases']:
        folder = matrix / case['case']
        manifest = read_json(folder / 'manifest.json')
        need(manifest['sources'].count(str(SOURCE)) == 1 and not manifest['private_sampler_substitution'] and
             manifest['options']['CLOCKS_NATIVE'] == 1 and manifest['options']['FRAME_DIVISOR'] == 2,
             'matrix production/clock configuration differs')
        for step in ('compile', 'elaborate'):
            need(read_json(folder / (step + '.exit.json'))['exit_code'] == 0, 'matrix build failed')
        raw = (folder / 'simulate.log').read_text(encoding='utf-8', errors='replace')
        if 'expected_failure' in case:
            need(case['expected_failure'] in raw and 'C1_R2_FUSED_RGB2_HOST_SYSTEM_PASS ' not in raw,
                 'matrix fault not evidenced')
        else:
            need(read_json(folder / 'simulate.exit.json')['exit_code'] == 0, 'matrix simulation failed')
            verify_output(raw, dict(blocks=2, expansion=24, preproject=True), native=False)
    state = read_json(native / 'status.json')
    need(state['state'] == 'complete' and state['exit_code'] == 0 and not state['work_directory_present'],
         'native simulation unfinished/temporary files remain')
    need({x['name'] for x in state['completed_steps']} == {'matrix100', 'prepare', 'xvlog', 'xelab', 'xsim'} and
         all(x['exit_code'] == 0 and x['in_windows_job'] is False for x in state['completed_steps']),
         'native process/exit evidence incomplete')
    manifest = read_json(native / 'manifest.json')
    selected = [str(p) for p in sources() if p.name not in ('execution_plan.sv', 'row_fusion_plan.sv')]
    need(manifest['sources'][:-2] == selected and not manifest['private_sampler_substitution'], 'native source table differs')
    need(manifest['options']['FRAME_DIVISOR'] == 1 and manifest['options']['NN_TARGET'] == 6 and
         manifest['options']['WIDTH'] == 640 and manifest['options']['HEIGHT'] == 480, 'native configuration differs')
    need((native / 'candidate.sv').read_text(encoding='utf-8-sig') == render(), 'native sampler changed')
    plans = ROOT / 'outputs/c36_qat_b_mosaic_stable_20260915a/plan_fused'
    for logged, production in [('execution_plan.sv', 'execution_plan.sv'), ('fusion_plan.sv', 'row_fusion_plan.sv')]:
        need((native / logged).read_text(encoding='utf-8-sig') == (plans / production).read_text(encoding='utf-8-sig'),
             'simulation/Efinity model plan differs')
    text = (native / 'xsim.stdout.log').read_text(encoding='cp936', errors='replace')
    need(text.count('C40_CLOCK_PASS core_hz=100000000 ') == 1, '100 MHz measurement missing')
    verified = check_text(text, dict(blocks=2, expansion=24, preproject=True), nn=6,
                          camera_profile='camera30', core_period_ps=10000)
    fps = throughput(verified['completion_intervals'])
    need(fps['target_met'], '15 fps target missed')
    state = read_json(eda / 'status.json')
    need(state['state'] == 'complete' and state['exit_code'] == 0 and not state['run_directory_present'] and
         state['worker_in_windows_job'] is False, 'Efinity did not complete/clean up outside Job')
    resource = read_json(eda / 'summary.json')
    need(resource['pnr_exit_code'] == 0, 'PNR did not finish')
    sta = read_json(eda / 'final_sta_table.json')
    need(sta['source'] == 'final_sta_clock_relationship_table' and sta['timing_pass'], 'final STA fails')
    core = [r for r in sta['relationships'] if r['kind'] == 'setup' and r['launch'] == r['capture'] == 'core_clk']
    need(len(core) == 1 and core[0]['constraint_ns'] == 10.0 and core[0]['slack_ns'] >= 0,
         'core clock not actually constrained/passing at 100 MHz')
    primary = (eda / 'timing_max_paths.sample.log').read_text(encoding='utf-8-sig')
    need('Top-level Entity Name: ' + NAME in primary and NAME + '.sdc' in primary and
         re.search(r'core_clk\s+10\.000\s+100\.000', primary), 'primary STA has wrong project/clock')
    audit_text = read_tool_log(eda / 'timing_audit.stdout.log')
    need(len(re.findall(r'^C40_TIMING_AUDIT_PASS$', audit_text, re.M)) == 1, 'independent routed STA incomplete')
    domain_slacks = {}
    for report in ('setup', 'hold', 'core_setup', 'core_hold', 'camera_setup', 'camera_hold',
                   'camera_to_core', 'core_to_camera', 'bus_setup', 'bus_hold'):
        path = eda / ('c40_' + report + '.rpt')
        need(path.is_file() and path.stat().st_size > 0, 'missing routed domain report: ' + report)
        if not report.startswith('bus_'):
            raw = path.read_text(encoding='utf-8-sig')
            values = [float(v) for v in re.findall(r'^\s*\d+\s*\|\s*([-+]?\d+(?:\.\d+)?)\s*\|', raw, re.M)]
            need(values and min(values) >= 0 and 'status : final' in raw, 'domain STA fails: ' + report)
            domain_slacks[report] = min(values)
    bus = (eda / 'c40_bus_setup.rpt').read_text(encoding='utf-8-sig')
    bus_rows = re.findall(r'^\[get_pins .*\|\s*Slow\s*\|\s*1\.000\s*\|\s*([0-9.]+)\s*\|\s*([-+0-9.]+)\s*$', bus, re.M)
    need(len(bus_rows) == 2 and all(float(actual) <= 1 and float(slack) >= 0 for actual, slack in bus_rows),
         'Gray bus skew constraints not satisfied')
    # The fastest reference may be omitted as a self-comparison (9 endpoints
    # plus one reference). Check the actual bit inventory, not that row count.
    bus_counts = [int(n) for n in re.findall(r'^Endpoints: (\d+)$', bus, re.M)]
    need(len(bus_counts) == 2 and all(n in (9, 10) for n in bus_counts), 'unexpected Gray bus report shape')
    for prefix in ('wr', 'rd'):
        bits = {int(n) for n in re.findall(r'/' + prefix + r'_sync1\[(\d+)\]~FF\|D', bus)}
        need(bits == set(range(10)), 'Gray bus endpoint/reference bits incomplete: ' + prefix)
    return dict(run_id=run_id, production_tests=15, matrix100_tests=18, models=list(MODELS), native=verified, performance=fps,
                resources=resource['pnr_resources'], final_sta=sta, domain_slack_ns=domain_slacks,
                gray_bus_actual_ns=[float(row[0]) for row in bus_rows],
                gray_bus_reported_endpoints=bus_counts,
                actual_CPU_IP=False, board_verified=False, temporary_removed=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    need(re.fullmatch(r'[A-Za-z0-9_-]+', args.run_id), 'invalid run id')
    result = audit(args.run_id)
    output = ROOT / 'logs/c40_production_queue' / args.run_id / 'acceptance.json'
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print('C40_PRODUCTION_STAGE_ACCEPTED ' + json.dumps(result, separators=(',', ':')))
