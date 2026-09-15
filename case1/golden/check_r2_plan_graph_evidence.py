"""C16 generated-plan evidence. Core-only results never imply host/board fps."""
from __future__ import annotations

import json
import re
from pathlib import Path

import check_r2_pingpong_evidence as c8

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'C1_R2_PLAN_GRAPH_'


def need(ok, message):
    if not ok:
        raise ValueError(message)


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def rows(text, kind):
    return [c8.fields(s) for s in text.splitlines() if s.startswith(PREFIX+kind+' ')]


def clean(text):
    need(not re.search(r'FATAL|ERROR|RuntimeError|TimeoutExpired|Traceback', text), 'failed simulation')
    need(text.splitlines().count(PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1') == 1,
         'missing/duplicate cleanup')


def matrix(text):
    clean(text)
    metas = [json.loads(s.split(' ', 1)[1]) for s in text.splitlines() if s.startswith(PREFIX+'VECTORS ')]
    fs, ps, faults = rows(text, 'FRAME'), rows(text, 'PASS'), rows(text, 'FAULT')
    need(len(metas) == 4 and {(m['width'], m['height']) for m in metas} ==
         {(4, 4), (12, 12), (32, 32), (640, 12)}, 'missing/duplicate geometry')
    need((len(fs), len(ps), len(faults)) == (18, 8, 24), 'missing matrix cases')
    scalars = words = 0
    for m in metas:
        w, h = m['width'], m['height']
        b = c8.budget(w, h)
        need((m['parameter_words'], m['input_words'], m['expected_words']) ==
             (2333, w*h//2, b['write_beats']*2), 'wrong vector plan')
        need(len(m['frames']) == 2, 'wrong golden frame count')
        for mf in m['frames']:
            need(len(mf['stages']) == 19 and {s['stage'] for s in mf['stages']} == set(range(22))-{14, 17, 21},
                 'missing materialized compute nodes')
            need(sum(s['words'] for s in mf['stages']) == b['write_beats'] and
                 sum(s['shape'][0]*s['shape'][1]*s['shape'][2] for s in mf['stages']) == mf['scalars'],
                 'golden coverage mismatch')
        for stalls in (0, 1):
            frames = [f for f in fs if (f['width'], f['height'], f['stalls']) == (w, h, stalls)]
            passes = [p for p in ps if (p['width'], p['height'], p['stalls']) == (w, h, stalls)]
            n = 3 if w == 12 else 2
            need(len(passes) == 1 and [f['frame'] for f in frames] == ([0, 1, 1] if n == 3 else [0, 1]),
                 'missing/duplicate numeric frames')
            p = passes[0]
            need(tuple(p[k] for k in ('normal_frames', 'faults', 'invalid_shapes', 'expected_input_only')) ==
                 (n, 12 if n == 3 else 0, 10, 1), 'missing lifecycle coverage')
            need(tuple(p[k] for k in ('cache', 'overlap', 'compute_overlap', 'refill_priority',
                                     'write_throttle', 'memdiv', 'latency')) == (1, 1, 1, 1, 0, 0, 0),
                 'wrong execution profile')
            need(p['max_pages'] <= 2 and (w < 12 or (p['max_pages'] == 2 and p['full_pages_cycles'] > 0
                 and p['compute_write_cycles'] > 0)), 'missing actual double-buffer overlap')
            need((p['blocked_writes'] > 0) == bool(stalls) and p['max_read_run'] >= 2, 'backpressure/refill coverage')
            if n == 2:
                need((p['bulk_beats'], p['reads'], p['writes']) ==
                     (2*b['feature_read_beats'], 2*b['read_beats'], 2*b['write_beats']), 'wrong total traffic')
            for f in frames:
                c8.check_frame(f)
                scalars += m['frames'][f['frame']]['scalars']
                words += f['write_beats']
            need(stalls or len({f['cycles'] for f in frames}) == 1, 'unstable continuous schedule')
    for stalls in (0, 1):
        c8.check_faults(faults, stalls)
    return dict(configs=8, normal_frames=18, error_frames=24, valid_scalars=scalars, normal_write_words=words)


def reset(text):
    clean(text)
    need(rows(text, 'RESET_PASS') == [dict(phase=i, restart_golden=1, cleared_pages=1) for i in range(6)]*2,
         'missing reset phases')
    need(rows(text, 'RESET_SUITE_PASS') == [dict(phases=6, normal_restarts=6, system_reset_only=1)]*2,
         'wrong reset suite count/scope')
    fs = rows(text, 'FRAME')
    need(len(fs) == 12 and [f['stalls'] for f in fs] == [0]*6+[1]*6, 'missing reset configurations')
    for f in fs:
        need((f['width'], f['height'], f['frame']) == (8, 8, 1), 'wrong reset restart')
        c8.check_frame(f, 0, 1)
    return dict(configs=2, phases_per_config=6, full_golden_restarts=12, system_reset_only=True)


def handoff(text):
    clean(text)
    need(rows(text, 'HANDOFF_NEGATIVE_PASS') == [dict(corruption=i, detected_at_stage=1) for i in (1, 2)]*2,
         'missing actual RAM handoff corruption')
    return dict(actual_memory_corruptions_detected=4, corruption_types=2)


def planner():
    t = read('logs/r2_execution_plan_unit_20260913_b.log')
    need(not re.search(r'FAIL|ERROR|Traceback', t) and re.search(r'Ran 12 tests in ', t) and
         t.rstrip().endswith('OK'), 'planning tests incomplete')
    t = read('logs/r2_plan_decode_20260913_a.log')
    rs = [c8.fields(s) for s in t.splitlines() if s.startswith('C1_R2_PLAN_DECODE_PASS ')]
    need(not re.search(r'FATAL|ERROR|Traceback', t) and rs == [dict(checks=1107, geometries=9,
         executable=171, views=27, invalid=90, actual_retained_decoder=1, execution_claim=0)] and
         t.splitlines().count('C1_R2_PLAN_DECODE_CLEAN temporary_simulator_removed=1') == 1,
         'decode comparison missing')
    import sys
    sys.path.insert(0, str(ROOT/'model'))
    from r2_execution_plan import microstyle_plan, render_sv
    need(read('rtl/r2/c1_r2_microstyle_plan.sv') == render_sv(microstyle_plan()), 'ROM not current')
    executor = read('rtl/r2/c1_r2_planned_pingpong_graph.sv')
    need('c1_r2_microstyle_plan u_plan' in executor and
         not re.search(r'case\s*\(stage_q\)|stage_q\s*==', executor), 'fixed-stage execution branch remains')
    return dict(python_tests=12, decode_checks=1107, current_graph_steps=22, parameter_words=2333,
                workspace_banks=3, removed_block_variant_steps=18, variant_numeric_execution=False)


def xsim():
    run = 'c16_plan_graph_xsim_12x12_20260913_a'
    folder = Path('logs/r2_plan_graph_xsim_runs')/run
    s = json.loads(read(folder/'status.json'))
    need(s['run_id'] == run and s['state'] == 'complete' and s['exit_code'] == 0, 'xsim incomplete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and
         not Path(s['run_directory']).exists(), 'xsim not detached/clean')
    need(tuple(s[k] for k in ('width', 'height', 'memory_div', 'command_latency')) == (12, 12, 2, 20),
         'wrong xsim profile')
    t = read(folder/'result.log')
    need(not re.search(r'FATAL|ERROR|Traceback', t), 'xsim failed')
    fs, ps = rows(t, 'FRAME'), rows(t, 'PASS')
    need(len(fs) == len(ps) == 1 and (fs[0]['width'], fs[0]['height'], fs[0]['cycles'], fs[0]['stalls']) ==
         (12, 12, 17232, 0), 'xsim numeric schedule mismatch')
    c8.check_frame(fs[0], 2)
    need(tuple(ps[0][k] for k in ('normal_frames', 'faults', 'invalid_shapes', 'expected_input_only', 'max_pages')) ==
         (1, 0, 10, 1, 2), 'xsim lifecycle mismatch')
    return dict(run=run, cycles=17232, frames=1, worker_in_windows_job=False, private_removed=True,
                scope='12x12 row-transfer core, not physical AXI/video/CPU')


def physical():
    run = 'c16_plan_graph96_i3_20260913_a'
    folder = Path('logs/efinity_resource_runs')/run
    s, st = json.loads(read(folder/'summary.json')), json.loads(read(folder/'status.json'))
    r, t = s['pnr_resources'], s['timing']
    need(st['run_id'] == s['run_id'] == run and st['state'] == s['state'] == 'complete' and
         st['exit_code'] == s['pnr_exit_code'] == 0 and s['flow'] == 'map+pnr', 'physical run incomplete')
    need((r['xlr_cells_used'], r['memory_blocks_used'], r['dsp_blocks_used']) == (38846, 160, 112),
         'wrong physical snapshot')
    need(t['final_slack_ns'] >= 0 and t['final_hold_slack_ns'] >= 0 and t['final_period_ns'] <= 6.666,
         '150MHz setup/hold not closed')
    need(s['metrics']['primitive_counts']['EFX_DSP24'] == 96 and s['metrics']['primitive_counts']['EFX_DSP48'] == 16,
         'missing physical compute resources')
    for name, ram, dsp in (('u_plan:c1_r2_microstyle_plan', 0, 0),
                           ('u_operator:c1_r2_cnn_bulk_engine', 128, 108),
                           ('u_writer:c1_r2_tensor_pingpong_writer', 32, 0)):
        rr = [row for row in s['metrics']['module_rows'] if name in row]
        need(len(rr) == 1 and [int(v) for v in re.findall(r'(\d+)\(', rr[0])][-2:] == [ram, dsp],
             'wrong resource hierarchy: '+name)
    temp = Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_plan_graph96_'+run)
    need(not temp.exists(), 'physical private directory remains')
    return dict(run=run, xlr=38846, ram=160, dsp=112, setup_ns=t['final_slack_ns'], hold_ns=t['final_hold_slack_ns'],
                scope='generated-plan row-transfer core only, not host/video/DDR PHY/CPU/CDC/IO')


def main():
    emit = lambda name, result: print(PREFIX+name+'_GATE_PASS '+json.dumps(result))
    emit('PLANNER', planner())
    t = read('logs/r2_plan_graph_matrix_20260913_a.log')
    emit('MATRIX', matrix(t))
    retained = read('logs/r2_pingpong_probe_20260913_b.log')+'\n'+read('logs/r2_pingpong_probe_20260913_c.log')
    c8.matrix(retained)
    # An old fault/restart snapshot differed by two clocks. Re-run the actual
    # retained source, not a patched expected count or a timing tolerance.
    fresh = read('logs/r2_c16_retained_schedule_20260913_b.log')
    c8.clean(fresh)
    need([len(c8.rec(fresh, kind)) for kind in ('FRAME', 'PASS', 'FAULT')] == [3, 1, 12],
         'retained rerun incomplete')
    for f in c8.rec(fresh, 'FRAME'):
        need((f['width'], f['height'], f['stalls']) == (12, 12, 1), 'wrong retained rerun profile')
        c8.check_frame(f)
    c8.check_faults(c8.rec(fresh, 'FAULT'), 1)
    for kind in ('FRAME', 'PASS', 'FAULT'):
        selected = lambda r: r['stalls'] == 1 and (kind == 'FAULT' or (r['width'], r['height']) == (12, 12))
        need([r for r in rows(t, kind) if not selected(r)] ==
             [r for r in c8.rec(retained, kind) if not selected(r)], 'retained historical comparison: '+kind)
        need([r for r in rows(t, kind) if selected(r)] == c8.rec(fresh, kind), 'retained rerun differs: '+kind)
    emit('RETAINED_SCHEDULE', dict(normal_frames=18, fault_frames=24, equal_cycles_and_traffic=True,
                                   historical_normal_frames=15, newly_rerun_normal_frames=3, native_comparison=False))
    shared_text = read('logs/r2_plan_graph_shared_20260913_a.log')
    emit('SHARED', c8.shared(shared_text.replace(PREFIX, 'C1_R2_PINGPONG_')))
    fs = rows(shared_text, 'FRAME')
    need(all(f['cycles'] == 17232 for f in fs if f['stalls'] == 0), 'cross-simulator schedule differs')
    emit('RESET', reset(read('logs/r2_plan_graph_reset_20260913_a.log')))
    emit('HANDOFF', handoff(read('logs/r2_plan_graph_negative_20260913_a.log')))
    first = rows(t, 'FRAME')[0]
    mutations = [('commits=22', 'commits=21'), ('invalid_shapes=10', 'invalid_shapes=9'),
                 ('drained=1', 'drained=0'), ('compute_error=1', 'compute_error=0'),
                 ('two_pages_error=1', 'two_pages_error=0'), ('expected_input_only=1', 'expected_input_only=0'),
                 ('max_pages=2', 'max_pages=3'), ('cycles='+str(first['cycles']), 'cycles=1'),
                 (PREFIX+'CLEAN temporary_vectors_and_simulator_removed=1', '')]
    for old, new in mutations:
        need(old in t, 'missing negative evidence anchor')
        try:
            matrix(t.replace(old, new, 1))
        except ValueError:
            pass
        else:
            raise ValueError('accepted invalid evidence: '+old)
    emit('AUDIT_NEGATIVE', dict(rejected=len(mutations), actual_hardware_faults=False))
    emit('XSIM', xsim())
    emit('PHYSICAL', physical())
    print(PREFIX+'SCOPE core_only=1 full_host_integration=0 native_fps_claim=0 board_execution=0')


if __name__ == '__main__':
    main()
