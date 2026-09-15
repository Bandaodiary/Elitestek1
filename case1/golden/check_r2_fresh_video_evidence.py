"""C14 freshness regression and full-system audit; no inherited FPS claim."""
import argparse
import json
import re
from pathlib import Path

import check_r2_rgbx_system_evidence as c12
import check_r2_cpu_video_evidence as c13

ROOT = c12.ROOT
need = c12.need


def read(path):
    return (ROOT / path).read_text(encoding='utf-8-sig')


def normalized(text):
    return text.replace('C1_R2_FRESH_VIDEO_SYSTEM_', 'C1_R2_RGBX_SYSTEM_')


def cpu_ids(text):
    return c13.cpu_ids(text.replace('C1_R2_FRESH_VIDEO_SYSTEM_', 'C1_R2_CPU_VIDEO_SYSTEM_'))


def freshness_unit(text):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'fresh lease test failed')
    expected = {
        'C1_R2_FRESH_LEGACY_PASS checks=132 captures=7 nn=4 displays=3 raw_slots=4 output_slots=3 concurrent_front_pending_nn_capture=1 no_swap_wait=1 reset=1',
        'C1_R2_FRESH_LEASE_PASS checks=462 cases=4 captures=28 nn=16 displays=8 alternatives_preserve_latest=3 same_edge=1 tag_wrap=1 only_ready_reclaimed=1 reset=1',
        'C1_R2_FRESH_NEGATIVE_PASS original_c12=1 actual_selector=1 latest_reclaimed_detected=1',
        'C1_R2_FRESH_LEASE_CLEAN temporary_simulator_removed=1',
    }
    need(len(text.splitlines()) == 4 and set(text.splitlines()) == expected,
         'missing freshness/baseline/same-edge/wrap/fallback/cleanup evidence')
    return dict(legacy_checks=132, focused_checks=462, scenarios=4, actual_baseline_negative=1)


def derivation():
    # Direct text comparison, not a checksum: freeze the actual scope of the
    # C14 core change while old source versions have native runs in flight.
    old = read('rtl/r2/c1_r2_video_rgbx_system.sv')
    expected = old.replace('c1_r2_video_rgbx_system', 'c1_r2_video_fresh_system').replace(
        'c1_r2_video_rgbx_leases', 'c1_r2_video_fresh_leases').replace('// C12', '// C14')
    need(read('rtl/r2/c1_r2_video_fresh_system.sv') == expected, 'unexpected C14 core change')
    old = read('efinity/c1_ti60_r2_cpu_video96.sv')
    expected = old.replace('c1_ti60_r2_cpu_video96', 'c1_ti60_r2_fresh_video96').replace(
        'c1_r2_video_rgbx_system', 'c1_r2_video_fresh_system').replace(
        'C13 CPU ID/narrow DDR seam + retained C12', 'C14 fresh-input leases + retained C13 CPU ID seam')
    need(read('efinity/c1_ti60_r2_fresh_video96.sv') == expected, 'unexpected CPU/probe change')
    return dict(core_change='lease instance only', cpu_adapter='retained C13', numeric_golden='unchanged')


def fresh_profiles(text, count):
    need(cpu_ids(text) == count, 'missing C14 CPU ID profiles')
    ps = c12.rows(normalized(text), 'PASS')
    need(len(ps) == count and all(p.get('fresh_leases') == 1 for p in ps), 'missing C14 lease integration')


def negative(text):
    nt = normalized(text)
    c12.clean(nt)
    rs = c12.rows(nt, 'NEGATIVE_PASS')
    need(len(rs) == 4 and {
        (r['width'], r['height'], r['stalls'], r['corruption'], r['actual_ram_mutation']) for r in rs
    } == {(8, 8, s, n, 1) for s in (0, 1) for n in (1, 2)}, 'missing actual RAM negative controls')
    return dict(actual_ram_mutations=4)


def native_freshness(normalized_text, require_latest=True):
    """Audit the six-job native trace against actual capture completion order.

    This finite, non-wrapping trace is not a proof about arbitrary future
    camera/NN rates. Unit tests separately cover same-edge/tag-wrap cases.
    """
    captures = c12.rows(normalized_text, 'CAPTURE')
    starts = c12.rows(normalized_text, 'NN_START')
    need(len(captures) == 13 and len({c['tag'] for c in captures}) == 13 and
         [s['job'] for s in starts] == list(range(1, 7)), 'incomplete native freshness trace')
    need(all(a['cycle'] < b['cycle'] for a, b in zip(captures, captures[1:])), 'capture completion order invalid')
    by_tag = {c['tag']: c for c in captures}
    samples = []
    for start in starts:
        ready = [c for c in captures if c['cycle'] <= start['cycle']]
        need(ready and start['tag'] in by_tag and by_tag[start['tag']]['cycle'] <= start['cycle'],
             'NN used a frame before actual capture completion')
        latest = ready[-1]
        samples.append(dict(job=start['job'], tag=start['tag'], latest_completed_tag=latest['tag'],
                            capture_complete_to_start_cycles=start['cycle']-by_tag[start['tag']]['cycle']))
    misses = [s['job'] for s in samples if s['tag'] != s['latest_completed_tag']]
    need(not require_latest or not misses, 'newest completed input not selected')
    return dict(samples=samples, not_latest_jobs=misses, scope='six-job finite trace; tags, not six distinct images')


def xsim(run_id, native=False):
    folder = Path('logs/r2_fresh_video_xsim_runs') / run_id
    s = json.loads(read(folder / 'status.json'))
    need(s['run_id'] == run_id and s['state'] == 'complete' and s['exit_code'] == 0, 'C14 xsim incomplete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and
         not Path(s['run_directory']).exists(), 'C14 xsim not isolated/clean')
    profile = (640, 480, 0, 0, 6, 2, 20) if native else (12, 12, 1, 2, 6, 2, 20)
    need(tuple(s[k] for k in ('width', 'height', 'stalls', 'aw_wait_w', 'nn_target', 'memory_div', 'command_latency')) == profile,
         'wrong C14 xsim profile')
    text = read(folder / 'result.log')
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired', text), 'failed C14 xsim evidence')
    fresh_profiles(text, 1)
    nt = normalized(text)
    ps, fs = c12.rows(nt, 'PASS'), c12.rows(nt, 'FRAME')
    timeline = c12.run(ps[0], fs, nt, native, 6)
    if native:
        commits = c12.rows(nt, 'STAGE')
        need(len(commits) == 132, 'missing native stage evidence')
        for frame in fs:
            cc = [x for x in commits if x['tag'] == frame['tag']]
            need([x['stage'] for x in cc] == list(range(22)) and cc[-1]['words'] == frame['write_beats'] and
                 cc[-1]['cycles'] == frame['cycles'], 'native stage commit mismatch')
        meta = json.loads(read(folder / 'metadata.json'))
        need((meta['parameter_words'], meta['input_words'], meta['expected_words'], meta['frames'][0]['scalars']) ==
             (2333, 153600, 2860800, 21043200), 'wrong native golden')
    return dict(run_id=run_id, cnn_frames=6, frame_cycles=[x['cycles'] for x in fs], timeline=timeline,
                **c12.throughput(timeline, native), actual_cpu_ip_execution=False, board_validation=False,
                freshness=native_freshness(nt) if native else None)


def physical(run_id):
    folder = Path('logs/efinity_resource_runs') / run_id
    s, m = (json.loads(read(folder / name)) for name in ('status.json', 'summary.json'))
    need(s['run_id'] == m['run_id'] == run_id and s['state'] == m['state'] == 'complete' and
         s['exit_code'] == m['pnr_exit_code'] == 0, 'C14 Efinity incomplete')
    need(m['marker'] == 'C1_TI60_R2_FRESH_VIDEO96_MAP_PNR_PASS' and m['family'] == 'Titanium' and
         m['device'] == 'Ti60F225' and m['flow'] == 'map+pnr', 'wrong C14 physical target')
    private = Path('C:/Users/30982/AppData/Local/Temp') / ('c1_efinity_resource_c1_ti60_r2_fresh_video96_' + run_id)
    need(not private.exists() and '--timing_model I3 ' in read(folder / 'efinity.pnr.stdout.tail.log'), 'wrong grade/unclean PNR')
    resources, timing, metrics = m['pnr_resources'], m['timing'], m['metrics']
    hierarchy = set(metrics['module_rows'] + metrics.get('module_focus_rows', []))
    need(resources['dsp_blocks_used'] == 112 and resources['memory_blocks_used'] == 172 and
         0 < resources['xlr_cells_used'] <= 60800, 'unexpected/pruned C14 footprint')
    need(metrics['primitive_counts'].get('EFX_DSP24') == 96 and metrics['primitive_counts'].get('EFX_DSP48') == 16,
         'wrong retained array')
    for name in ('+u_cpu_adapter:c1_r2_cpu_axi_adapter', '+u_system:c1_r2_video_fresh_system',
                 '+u_leases:c1_r2_video_fresh_leases', '+u_cnn:c1_r2_microstyle_rgbx_axi_graph',
                 '+u_capture:c1_r2_video_capture_rgbx32', '+u_scanout:c1_r2_video_scanout_rgbx32'):
        need(sum(name in row for row in hierarchy) == 1, 'missing C14 hierarchy: ' + name)
    need(timing['final_slack_ns'] >= 0 and timing['final_hold_slack_ns'] >= 0 and
         abs(timing['final_slack_ns'] + timing['final_period_ns'] - 6.666) < .002, 'C14 150MHz timing failed')
    return dict(run_id=run_id, resources=resources, timing=timing, scope='core probe, no actual CPU/PHY/ISP/CDC/board IO')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pnr-run')
    parser.add_argument('--native-run')
    parser.add_argument('--require-15fps', action='store_true')
    args = parser.parse_args()
    need(not args.require_15fps or (args.native_run and args.pnr_run),
         'C14 15fps claim requires both its native run and its 150MHz physical evidence')
    lease = read('logs/r2_fresh_lease_20260913_b.log')
    matrix = read('logs/r2_fresh_video_system_sixframe_20260913_a.log')
    print('C1_R2_C14_SCOPE_GATE_PASS ' + json.dumps(derivation()))
    print('C1_R2_C14_LEASE_GATE_PASS ' + json.dumps(freshness_unit(lease)))
    print('C1_R2_C14_RETAINED_CPU_GATE_PASS ' + json.dumps(c13.unit(read('logs/r2_cpu_axi_adapter_matrix_20260913_b.log'))))
    fresh_profiles(matrix, 4)
    print('C1_R2_C14_SYSTEM_GATE_PASS ' + json.dumps(c12.matrix(normalized(matrix), ((8, 8), (32, 32)), 6)))
    print('C1_R2_C14_RAM_NEGATIVE_GATE_PASS ' + json.dumps(negative(read('logs/r2_fresh_video_system_negative_20260913_a.log'))))
    print('C1_R2_C14_XSIM_GATE_PASS ' + json.dumps(xsim('c14_fresh_video_xsim_12x12_20260913_a')))
    for old, new in [('same_edge=1', 'same_edge=0'), ('tag_wrap=1', 'tag_wrap=0'),
                     ('only_ready_reclaimed=1', 'only_ready_reclaimed=0'), ('original_c12=1', 'original_c12=0')]:
        need(old in lease, 'missing audit mutation')
        try:
            freshness_unit(lease.replace(old, new, 1))
        except ValueError:
            pass
        else:
            raise ValueError('corrupt freshness evidence accepted')
    for old, new in [('fresh_leases=1', 'fresh_leases=0'), ('restored_bits=8', 'restored_bits=4')]:
        need(old in matrix, 'missing system mutation')
        try:
            fresh_profiles(matrix.replace(old, new, 1), 4)
        except ValueError:
            pass
        else:
            raise ValueError('corrupt C14 integration evidence accepted')
    print('C1_R2_C14_AUDIT_NEGATIVE_PASS rejected=6')
    if args.native_run:
        result = xsim(args.native_run, True)
        print('C1_R2_C14_NATIVE_FUNCTIONAL_GATE_PASS ' + json.dumps(result))
        if args.require_15fps:
            c12.require_throughput(result, 4)
        # A valid older full-system run is the negative control, not a made-up
        # marker. It has the same throughput but selects older tag4 at job4.
        old_run = 'c13_cpu_video_xsim_native_sixframe_20260913_a'
        c13.xsim(old_run, True)
        old_text = read(Path('logs/r2_cpu_video_xsim_runs')/old_run/'result.log').replace(
            'C1_R2_CPU_VIDEO_SYSTEM_', 'C1_R2_RGBX_SYSTEM_')
        old = native_freshness(old_text, require_latest=False)
        need(old['not_latest_jobs'] == [4], 'old freshness negative control changed')
        try:
            native_freshness(old_text)
        except ValueError:
            pass
        else:
            raise ValueError('old non-latest input trace was accepted')
        print('C1_R2_C14_NATIVE_FRESHNESS_NEGATIVE_PASS '+json.dumps(dict(old_not_latest_jobs=[4],
              old_job4_age_cycles=old['samples'][3]['capture_complete_to_start_cycles'],
              new_job4_age_cycles=result['freshness']['samples'][3]['capture_complete_to_start_cycles'],
              scope='capture completion to NN start; not end-to-end video latency')))
    else:
        need(not args.require_15fps, 'native run required for C14 throughput claim')
    if args.pnr_run:
        print('C1_R2_C14_PHYSICAL_GATE_PASS ' + json.dumps(physical(args.pnr_run)))


if __name__ == '__main__':
    main()
