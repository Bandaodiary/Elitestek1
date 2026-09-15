"""C17 graph/parameter co-generation evidence, never a native/quality claim."""
import json
import re
from pathlib import Path

from r2_plan_vectors import ROOT, profile_nodes, compile_package
from r2_plan_package import verify
from r2_execution_plan import FRAME, OP_UPSAMPLE2, OP_OUTPUT_RGB, OP_DWCONV3X3

PREFIX = 'C1_R2_BOUND_GRAPH_'


def fields(line):
    return {k: int(v) if re.fullmatch(r'-?\d+', v) else v for k, v in re.findall(r'(\w+)=([^\s]+)', line)}


def need(ok, why):
    if not ok:
        raise ValueError(why)


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def rows(t, kind):
    return [fields(s) for s in t.splitlines() if s.startswith(PREFIX+kind+' ')]


def clean(t):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired', t), 'failed run')
    need(t.splitlines().count(PREFIX+'CLEAN temporary_packages_vectors_and_simulator_removed=1') == 1,
         'missing/duplicate cleanup')


def budget(profile, w, h):
    nodes = profile_nodes(profile, w, h)
    shapes = {FRAME: (w, h, 3)}
    roots = {FRAME: FRAME}
    features = writes = scalars = macs = 0
    stage_words = {}
    words = lambda shape: ((shape[0]+1)//2)*shape[1]*((shape[2]+7)//8)
    for i, node in enumerate(nodes):
        s = node.spec
        shapes[s.name] = (s.output_width, s.output_height, s.output_channels)
        if s.opcode in (OP_UPSAMPLE2, OP_OUTPUT_RGB):
            roots[s.name] = roots[node.inputs[0]]
            continue
        roots[s.name] = s.name
        features += sum(words(shapes[roots[x]]) for x in node.inputs)
        n = words(shapes[s.name])
        writes += n
        scalars += s.output_width*s.output_height*s.output_channels
        stage_words[i] = n
        if s.weight_count:
            macs += s.output_width*s.output_height*s.output_channels*s.kernel*s.kernel*(
                1 if s.opcode == OP_DWCONV3X3 else s.input_channels)
    params = 2333 if profile == 'microstyle24' else 1781
    return dict(stages=len(nodes), rgb_stage=len(nodes)-2, parameters=params, reads=params+features,
                features=features, writes=writes, scalars=scalars, macs=macs, stage_words=stage_words)


def frame(f, profile, memdiv=0, throttle=0):
    b = budget(profile, f['width'], f['height'])
    need(tuple(f[k] for k in ('cache', 'overlap', 'compute_overlap', 'refill_priority', 'write_throttle', 'memdiv', 'latency')) ==
         (1, 1, 1, 1, throttle, memdiv, 20 if memdiv else 0), 'wrong frame configuration')
    need(tuple(f[k] for k in ('commits', 'read_beats', 'write_beats', 'producer_reads')) ==
         (b['stages'], b['reads'], b['writes'], b['features']), 'numeric commit/traffic mismatch')
    need(f['cycles'] > max(b['reads'], b['writes'], (b['macs']+95)//96) and
         0 <= f['compute_write_beats'] <= b['writes'], 'impossible work/cycle count')
    need(f['width'] < 12 or f['compute_write_beats'] > 0, 'missing compute/write overlap')
    return b


def traces(text, profile):
    pending, checked = [], 0
    for line in text.splitlines():
        if line.startswith(PREFIX+'STAGE_COMMIT '):
            pending.append(fields(line))
        elif line.startswith(PREFIX+'FRAME '):
            f = fields(line)
            b = budget(profile, f['width'], f['height'])
            need([s['stage'] for s in pending] == list(range(b['stages'])) and
                 all(s['fault'] == 0 and s['frame'] == f['frame'] for s in pending), 'missing actual stage commits')
            total = 0
            for i, s in enumerate(pending):
                total += b['stage_words'].get(i, 0)
                need(s['words'] == total and (i == 0 or s['cycles'] > pending[i-1]['cycles']), 'view/retirement trace mismatch')
            need(pending[-1]['cycles'] == f['cycles'], 'terminal plan entry did not finish frame')
            pending = []
            checked += 1
        elif line.startswith(PREFIX+'FAULT '):
            f = fields(line)
            need([s['stage'] for s in pending] == list(range(f['commits'])) and
                 all(s['fault'] == f['fault'] for s in pending), 'wrong failed-frame commit trace')
            pending = []
    need(not pending, 'unterminated commit trace')
    return checked


def run(text, profile, shapes, memdiv=0, cleanup=True, expected_stalls=(0, 1)):
    if cleanup:
        clean(text)
    else:
        need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'failed xsim')
    fs, ps, faults = rows(text, 'FRAME'), rows(text, 'PASS'), rows(text, 'FAULT')
    need(len(ps) == len(shapes)*len(expected_stalls), 'missing pass profiles')
    expected_n = sum(3 if w == h == 12 else 2 for w, h in shapes)*len(expected_stalls)
    need(len(fs) == expected_n and traces(text, profile) == expected_n, 'missing numeric frames')
    total_scalars = total_words = 0
    for w, h in shapes:
        b = budget(profile, w, h)
        for stalls in expected_stalls:
            pp = [p for p in ps if (p['width'], p['height'], p['stalls']) == (w, h, stalls)]
            ff = [f for f in fs if (f['width'], f['height'], f['stalls']) == (w, h, stalls)]
            n = 3 if (w, h) == (12, 12) else 2
            need(len(pp) == 1 and [f['frame'] for f in ff] == ([0, 1, 1] if n == 3 else [0, 1]), 'wrong frame sequence')
            p = pp[0]
            need(tuple(p[k] for k in ('normal_frames', 'faults', 'invalid_shapes', 'expected_input_only', 'stage_count', 'rgb_stage')) ==
                 (n, 12 if n == 3 else 0, 10, 1, b['stages'], b['rgb_stage']), 'missing lifecycle or changed topology')
            need(p['max_pages'] <= 2 and (w < 12 or (p['max_pages'] == 2 and p['full_pages_cycles'] > 0)), 'missing writer pages')
            if stalls:
                need(p['blocked_writes'] > 0, 'missing backpressure')
            if n == 2:
                need((p['reads'], p['writes'], p['bulk_beats']) == (2*b['reads'], 2*b['writes'], 2*b['features']), 'total traffic mismatch')
            for f in ff:
                frame(f, profile, memdiv)
                total_scalars += b['scalars']
                total_words += b['writes']
    need(len(faults) == (12*len(expected_stalls) if (12, 12) in shapes else 0), 'missing faults')
    for stalls in expected_stalls if (12, 12) in shapes else ():
        ff = [f for f in faults if f['stalls'] == stalls]
        b = budget(profile, 12, 12)
        need([f['fault'] for f in ff] == list(range(1, 13)), 'fault coverage incomplete')
        for f in ff:
            need(f['drained'] == 1 and f['commits'] == (b['rgb_stage'] if f['fault'] == 7 else 0), 'unsafe fault retirement')
            need((f['overlapped_error'], f['compute_error'], f['two_pages_error']) ==
                 (int(f['fault'] in (9, 10, 12)), int(f['fault'] == 11), int(f['fault'] >= 11)), 'missing overlapping faults')
    return dict(profile=profile, configs=len(ps), normal_frames=len(fs), faults=len(faults),
                valid_scalars=total_scalars, normal_write_words=total_words)


def metadata(text, profile, shapes):
    ms = [json.loads(s.split(' ', 1)[1]) for s in text.splitlines() if s.startswith(PREFIX+'VECTORS ')]
    need(len(ms) == len(shapes) and {(m['width'], m['height']) for m in ms} == set(shapes), 'missing fixture profiles')
    for m in ms:
        b = budget(profile, m['width'], m['height'])
        need(m['profile'] == profile and (m['stage_count'], m['parameter_words'], m['planned_parameter_words']) ==
             (b['stages'], b['parameters'], b['parameters']), 'wrong bound fixture')
        need(m['input_words'] == m['width']*m['height']//2 and m['expected_words'] == 2*b['writes'] and
             len(m['frames']) == 2 and not m['quality_validated'], 'wrong oracle coverage/quality claim')
        for f in m['frames']:
            need(f['scalars'] == b['scalars'] and {s['stage']: s['words'] for s in f['stages']} == b['stage_words'],
                 'wrong oracle materialization')


def main():
    emit = lambda label, result: print(PREFIX+label+'_GATE_PASS '+json.dumps(result))
    t = read('logs/r2_plan_package_unit_20260913_a.log')
    need(not re.search(r'FAIL|ERROR|Traceback', t) and 'Ran 10 tests in ' in t and t.rstrip().endswith('OK'), 'unit tests missing')
    for profile, directory in (('microstyle24', 'r2_microstyle24_bound_plan'), ('drop_res1', 'r2_drop_res1_bound_plan')):
        p = compile_package(profile_nodes(profile))
        verify(p, ROOT/'model'/directory)
        emit('PACKAGE', dict(profile=profile, steps=len(p.manifest['steps']), parameter_words=p.manifest['transfer_beats128'],
                             image_bytes=len(p.image), independently_decoded=True, quality_validated=False))
    variant = read('logs/r2_bound_variant_matrix_20260913_a.log')
    shapes = [(4, 4), (12, 12), (32, 32), (640, 12)]
    metadata(variant, 'drop_res1', shapes)
    emit('VARIANT_MATRIX', run(variant, 'drop_res1', shapes))
    base = read('logs/r2_bound_baseline_matrix_20260913_a.log')
    metadata(base, 'microstyle24', [(12, 12), (32, 32)])
    emit('BASE_MATRIX', run(base, 'microstyle24', [(12, 12), (32, 32)]))
    import check_r2_plan_graph_evidence as c16
    old = c16.read('logs/r2_plan_graph_matrix_20260913_a.log')
    for kind in ('FRAME', 'PASS', 'FAULT'):
        current = [{k: v for k, v in r.items() if k not in ('stage_count', 'rgb_stage')} for r in rows(base, kind)]
        previous = [r for r in c16.rows(old, kind) if kind == 'FAULT' or (r['width'], r['height']) in ((12, 12), (32, 32))]
        need(current == previous, 'baseline current C16 schedule mismatch: '+kind)
    emit('BASE_COMPAT', dict(normal_frames=10, faults=24, equal_cycles_and_traffic=True))
    shared = read('logs/r2_bound_variant_shared_20260913_a.log')
    metadata(shared, 'drop_res1', [(12, 12)])
    emit('SHARED', run(shared, 'drop_res1', [(12, 12)], 2))
    reset = read('logs/r2_bound_variant_reset_20260913_a.log')
    clean(reset)
    need(rows(reset, 'RESET_PASS') == [dict(phase=i, restart_golden=1, cleared_pages=1) for i in range(6)]*2 and
         rows(reset, 'RESET_SUITE_PASS') == [dict(phases=6, normal_restarts=6, system_reset_only=1)]*2,
         'reset phases missing')
    fs = rows(reset, 'FRAME')
    need(len(fs) == 12 and [f['stalls'] for f in fs] == [0]*6+[1]*6, 'reset configurations missing')
    for f in fs:
        need((f['width'], f['height'], f['frame']) == (8, 8, 1), 'wrong reset geometry')
        frame(f, 'drop_res1', 0, 1)
    emit('RESET', dict(configs=2, full_golden_restarts=12, system_reset_only=True))
    for name, cases in (('package', ('stale_plan', 'stale_parameters')), ('handoff', ('handoff1', 'handoff2'))):
        path = 'logs/r2_bound_package_negative_20260913_a.log' if name == 'package' else 'logs/r2_bound_variant_handoff_20260913_a.log'
        t = read(path)
        clean(t)
        need(rows(t, 'NEGATIVE_PASS') == [dict(profile='drop_res1', stalls=s, case=c, actual_ram_or_plan=1)
                                         for s in (0, 1) for c in cases], 'missing actual negative cases')
        emit(name.upper()+'_NEGATIVE', dict(cases=4, production_runtime_identity_check=False))
    mutations = [('commits=18', 'commits=22'), ('stage_count=18', 'stage_count=22'), ('drained=1', 'drained=0'),
                 ('expected_input_only=1', 'expected_input_only=0'), ('two_pages_error=1', 'two_pages_error=0'),
                 ('stage=17 ', 'stage=21 '), (PREFIX+'CLEAN temporary_packages_vectors_and_simulator_removed=1', '')]
    for before, after in mutations:
        need(before in variant, 'mutation anchor missing')
        try:
            run(variant.replace(before, after, 1), 'drop_res1', shapes)
        except ValueError:
            pass
        else:
            raise ValueError('accepted invalid evidence '+before)
    emit('AUDIT_NEGATIVE', dict(rejected=len(mutations), actual_hardware_faults=False))
    run_id = 'c17_bound_xsim_12x12_20260913_a'
    folder = Path('logs/r2_bound_graph_xsim_runs')/run_id
    s = json.loads(read(folder/'status.json'))
    need(s['run_id'] == run_id and s['state'] == 'complete' and s['exit_code'] == 0 and s['worker_in_windows_job'] is False,
         'xsim incomplete or in Windows job')
    need(not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim not cleaned')
    need(tuple(s[k] for k in ('width', 'height', 'profile', 'frame_runs', 'stalls', 'memory_div', 'command_latency')) ==
         (12, 12, 'drop_res1', 2, 1, 2, 20), 'xsim profile mismatch')
    t = read(folder/'result.log')
    result = run(t, 'drop_res1', [(12, 12)], 2, cleanup=False, expected_stalls=(1,))
    need(rows(t, 'FRAME') == [f for f in rows(shared, 'FRAME') if f['stalls'] == 1], 'xsim/Icarus cycle/traffic mismatch')
    emit('XSIM', dict(result, run_id=run_id, worker_in_windows_job=False, private_removed=True))
    run_id = 'c17_bound_plan96_i3_20260913_a'
    folder = Path('logs/efinity_resource_runs')/run_id
    s, st = json.loads(read(folder/'summary.json')), json.loads(read(folder/'status.json'))
    r, t = s['pnr_resources'], s['timing']
    need(s['run_id'] == st['run_id'] == run_id and s['state'] == st['state'] == 'complete' and
         st['exit_code'] == s['pnr_exit_code'] == 0 and s['flow'] == 'map+pnr', 'PNR incomplete')
    need(0 < r['xlr_cells_used'] <= 60800 and (r['memory_blocks_used'], r['dsp_blocks_used']) == (160, 112), 'physical resources changed')
    need(t['final_slack_ns'] >= 0 and t['final_hold_slack_ns'] >= 0 and t['final_period_ns'] <= 6.666, '150MHz timing not closed')
    for name, ram, dsp in (('u_plan:c1_r2_microstyle_plan', 0, 0), ('u_operator:c1_r2_cnn_bulk_engine', 128, 108),
                           ('u_writer:c1_r2_tensor_pingpong_writer', 32, 0)):
        rr = [row for row in s['metrics']['module_rows'] if name in row]
        need(len(rr) == 1 and [int(v) for v in re.findall(r'(\d+)\(', rr[0])][-2:] == [ram, dsp], 'resource ownership mismatch')
    need(not (Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_bound_plan96_'+run_id)).exists(),
         'PNR private directory remains')
    emit('PHYSICAL', dict(run_id=run_id, xlr=r['xlr_cells_used'], ram=160, dsp=112,
                         setup_ns=t['final_slack_ns'], hold_ns=t['final_hold_slack_ns'], scope='18-node plan row core only'))
    print(PREFIX+'SCOPE core_only=1 native_fps_claim=0 variant_quality_validated=0 actual_cpu_or_board=0')


if __name__ == '__main__':
    main()
