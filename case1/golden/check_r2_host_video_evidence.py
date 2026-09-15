"""C15 actual host-shell checks; APB agent is not Sapphire CPU execution."""
import argparse
import json
import re
from pathlib import Path

import check_r2_rgbx_system_evidence as c12
import check_r2_cpu_video_evidence as c13
import check_r2_fresh_video_evidence as c14

ROOT, need = c12.ROOT, c12.need


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def normalized(text):
    return text.replace('C1_R2_HOST_VIDEO_SYSTEM_', 'C1_R2_RGBX_SYSTEM_')


def unit(text):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'host control failure')
    need(text.splitlines().count('C1_R2_HOST_CONTROL_CLEAN temporary_simulator_removed=1') == 1, 'control cleanup missing')
    rs = [c12.fields(x) for x in text.splitlines() if x.startswith('C1_R2_HOST_CONTROL_PASS ')]
    need(len(rs) == 1, 'missing/duplicate host control evidence')
    r = rs[0]
    need((r['checks'], r['accesses'], r['rejects'], r['upper_pages']) == (2451, 541, 520, 254), 'control coverage incomplete')
    need(all(r[k] == 1 for k in ('actual_csr', 'full_word_apb3', 'irq_union', 'cpu_fault_level_input', 'set_wins', 'reset')),
         'missing actual CSR/APB/IRQ/reset coverage')
    return dict(checks=2451, accesses=541, rejected=520, high_pages=254, cpu_fault_is_bridge_input_stimulus=True)


def host_profiles(text, count):
    c14.fresh_profiles(text.replace('C1_R2_HOST_VIDEO_SYSTEM_', 'C1_R2_FRESH_VIDEO_SYSTEM_'), count)
    previous = []
    profiles = 0
    for line in text.splitlines():
        if line.startswith('C1_R2_HOST_VIDEO_SYSTEM_HOST '):
            previous.append(c12.fields(line))
        if line.startswith('C1_R2_HOST_VIDEO_SYSTEM_PASS '):
            p = c12.fields(line)
            need(len(previous) == 1 and p['host_shell'] == 1, 'missing actual host shell')
            h = previous[0]
            need((h['apb_bits'], h['checks'], h['irq_level_verified'], h['high_alias_rejected'], p['apb_checks']) ==
                 (16, 13, 1, 1, 9), 'missing APB/IRQ/upper-address checks')
            previous = []
            profiles += 1
    need(not previous and profiles == count, 'unterminated host profile')


def narrow(text):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'host narrow test failed')
    need(text.splitlines().count('C1_R2_HOST_NARROW_CLEAN temporary_simulator_removed=1') == 1, 'narrow cleanup absent')
    rs = [c12.fields(x) for x in text.splitlines() if x.startswith('C1_R2_HOST_NARROW_PASS ')]
    need(len(rs) == 4 and {(r['stalls'], r['aw_mode'], r['id_bits']) for r in rs} ==
         {(s, w, 8) for s in (0, 1) for w in (0, 2)}, 'missing host narrow configurations')
    for r in rs:
        need(tuple(r[k] for k in ('reads', 'writes', 'rejects', 'protocol_cases', 'response_cases', 'narrow_sizes', 'max_beats')) ==
             (32, 32, 16, 0, 0, 5, 256), 'wrong narrow coverage/scope')
        need(all(r[k] == 1 for k in ('actual_byte_ram', 'independent_rw', 'held_ids', 'host_shell', 'actual_fabric', 'video_disabled')),
             'missing actual host/fabric/RAM or misrepresented video scope')
    return dict(configs=4, jobs=256, normal=192, local_rejected=64, actual_host_fabric_byte_ram=True,
                concurrent_video=False, protocol_fault_recovery=False)


def driver(text):
    need(not re.search(r'error:|Traceback|RuntimeError', text), 'host driver link failed')
    need(text.splitlines().count('C1_R2_HOST_DRIVER_CLEAN temporary_objects_removed=1') == 1, 'driver not clean')
    rs = [c12.fields(x) for x in text.splitlines() if x.startswith('C1_R2_HOST_DRIVER_LINK_PASS ')]
    need(len(rs) == 1 and tuple(rs[0][k] for k in ('rv32imac', 'ilp32', 'functions', 'fences', 'undefined_symbols', 'hardware_execution')) ==
         (1, 1, 5, 9, 0, 0), 'driver compile/link scope mismatch')
    return dict(functions=5, fences=9, undefined_symbols=0, hardware_execution=False)


def xsim(run_id, native=False):
    folder = Path('logs/r2_host_video_xsim_runs')/run_id
    s = json.loads(read(folder/'status.json'))
    need(s['run_id'] == run_id and s['state'] == 'complete' and s['exit_code'] == 0, 'C15 xsim incomplete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and
         not Path(s['run_directory']).exists(), 'C15 xsim not isolated/clean')
    profile = (640, 480, 0, 0, 6, 2, 20) if native else (12, 12, 1, 2, 6, 2, 20)
    need(tuple(s[k] for k in ('width', 'height', 'stalls', 'aw_wait_w', 'nn_target', 'memory_div', 'command_latency')) == profile,
         'wrong C15 xsim profile')
    text = read(folder/'result.log')
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired', text), 'failed C15 xsim')
    host_profiles(text, 1)
    nt = normalized(text)
    ps, fs = c12.rows(nt, 'PASS'), c12.rows(nt, 'FRAME')
    timeline = c12.run(ps[0], fs, nt, native, 6)
    if native:
        commits = c12.rows(nt, 'STAGE')
        need(len(commits) == 132, 'missing native commits')
        for frame in fs:
            cc = [x for x in commits if x['tag'] == frame['tag']]
            need([x['stage'] for x in cc] == list(range(22)) and cc[-1]['words'] == frame['write_beats'] and
                 cc[-1]['cycles'] == frame['cycles'], 'native commit mismatch')
        meta = json.loads(read(folder/'metadata.json'))
        need((meta['parameter_words'], meta['input_words'], meta['expected_words'], meta['frames'][0]['scalars']) ==
             (2333, 153600, 2860800, 21043200), 'wrong native golden')
    return dict(run_id=run_id, cnn_frames=6, frame_cycles=[x['cycles'] for x in fs], timeline=timeline,
                freshness=c14.native_freshness(nt) if native else None,
                **c12.throughput(timeline, native), actual_cpu_ip_execution=False, board_validation=False)


def physical(run_id):
    folder = Path('logs/efinity_resource_runs')/run_id
    s, m = (json.loads(read(folder/name)) for name in ('status.json', 'summary.json'))
    need(s['run_id'] == m['run_id'] == run_id and s['state'] == m['state'] == 'complete' and
         s['exit_code'] == m['pnr_exit_code'] == 0, 'C15 Efinity incomplete')
    need(m['marker'] == 'C1_TI60_R2_HOST_VIDEO96_MAP_PNR_PASS' and m['family'] == 'Titanium' and
         m['device'] == 'Ti60F225' and m['flow'] == 'map+pnr', 'wrong C15 physical target')
    private = Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_host_video96_'+run_id)
    need(not private.exists() and '--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'), 'wrong grade/unclean PNR')
    resources, timing, metrics = m['pnr_resources'], m['timing'], m['metrics']
    hierarchy = set(metrics['module_rows']+metrics.get('module_focus_rows', []))
    need(resources['dsp_blocks_used'] == 112 and resources['memory_blocks_used'] == 172 and
         0 < resources['xlr_cells_used'] <= 60800, 'unexpected/pruned C15 footprint')
    need(metrics['primitive_counts'].get('EFX_DSP24') == 96 and metrics['primitive_counts'].get('EFX_DSP48') == 16,
         'wrong retained array')
    for name in ('+u_host:c1_r2_host_video_system', '+u_control_bridge:c1_r2_host_control_bridge',
                 '+u_cpu_adapter:c1_r2_cpu_axi_adapter', '+u_system:c1_r2_video_fresh_system',
                 '+u_leases:c1_r2_video_fresh_leases', '+u_cnn:c1_r2_microstyle_rgbx_axi_graph'):
        need(sum(name in row for row in hierarchy) == 1, 'missing C15 hierarchy: '+name)
    need(timing['final_slack_ns'] >= 0 and timing['final_hold_slack_ns'] >= 0 and
         abs(timing['final_slack_ns']+timing['final_period_ns']-6.666) < .002, 'C15 150MHz timing failed')
    return dict(run_id=run_id, resources=resources, timing=timing, scope='actual host shell, no CPU IP/PHY/ISP/CDC/board IO')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pnr-run')
    parser.add_argument('--native-run')
    parser.add_argument('--require-15fps', action='store_true')
    args = parser.parse_args()
    need(not args.require_15fps or (args.native_run and args.pnr_run), 'C15 FPS requires native and physical evidence')
    control = read('logs/r2_host_control_20260913_a.log')
    narrow_text = read('logs/r2_host_narrow_20260913_a.log')
    matrix = read('logs/r2_host_video_system_sixframe_20260913_a.log')
    print('C1_R2_C15_RETAINED_CORE_GATE_PASS '+json.dumps(c14.derivation()))
    print('C1_R2_C15_CONTROL_GATE_PASS '+json.dumps(unit(control)))
    print('C1_R2_C15_RETAINED_CPU_GATE_PASS '+json.dumps(c13.unit(read('logs/r2_cpu_axi_adapter_matrix_20260913_b.log'))))
    print('C1_R2_C15_HOST_NARROW_GATE_PASS '+json.dumps(narrow(narrow_text)))
    host_profiles(matrix, 4)
    print('C1_R2_C15_SYSTEM_GATE_PASS '+json.dumps(c12.matrix(normalized(matrix), ((8, 8), (32, 32)), 6)))
    negatives = read('logs/r2_host_video_system_negative_20260913_a.log').replace('C1_R2_HOST_VIDEO_SYSTEM_', 'C1_R2_FRESH_VIDEO_SYSTEM_')
    print('C1_R2_C15_RAM_NEGATIVE_GATE_PASS '+json.dumps(c14.negative(negatives)))
    print('C1_R2_C15_XSIM_GATE_PASS '+json.dumps(xsim('c15_host_video_xsim_12x12_20260913_a')))
    print('C1_R2_C15_DRIVER_GATE_PASS '+json.dumps(driver(read('logs/r2_host_driver_link_20260913_a.log'))))
    for old, new in [('actual_csr=1', 'actual_csr=0'), ('upper_pages=254', 'upper_pages=0'), ('irq_union=1', 'irq_union=0')]:
        need(old in control, 'missing control mutation')
        try:
            unit(control.replace(old, new, 1))
        except ValueError:
            pass
        else:
            raise ValueError('corrupt control evidence accepted')
    for old, new in [('host_shell=1', 'host_shell=0'), ('apb_bits=16', 'apb_bits=8'),
                     ('irq_level_verified=1', 'irq_level_verified=0'), ('high_alias_rejected=1', 'high_alias_rejected=0')]:
        need(old in matrix, 'missing integration mutation')
        try:
            host_profiles(matrix.replace(old, new, 1), 4)
        except ValueError:
            pass
        else:
            raise ValueError('corrupt host-shell evidence accepted')
    for old, new in [('actual_fabric=1', 'actual_fabric=0'), ('video_disabled=1', 'video_disabled=0'), ('max_beats=256', 'max_beats=16')]:
        need(old in narrow_text, 'missing narrow mutation')
        try:
            narrow(narrow_text.replace(old, new, 1))
        except ValueError:
            pass
        else:
            raise ValueError('corrupt narrow evidence accepted')
    print('C1_R2_C15_AUDIT_NEGATIVE_PASS rejected=10')
    if args.native_run:
        result = xsim(args.native_run, True)
        print('C1_R2_C15_NATIVE_FUNCTIONAL_GATE_PASS '+json.dumps(result))
        if args.require_15fps:
            c12.require_throughput(result, 4)
    if args.pnr_run:
        print('C1_R2_C15_PHYSICAL_GATE_PASS '+json.dumps(physical(args.pnr_run)))


if __name__ == '__main__':
    main()
