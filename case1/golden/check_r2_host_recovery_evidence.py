"""C19 actual host error/drain/recovery audit; no native FPS/board claim."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

import check_r2_rgbx_system_evidence as c12
import check_r2_cpu_video_evidence as c13
import check_r2_planned_host_evidence as c18
from check_r2_bound_plan_evidence import fields
from r2_plan_package import compile_package, profile_nodes

ROOT, need = c12.ROOT, c12.need
PREFIX = 'C1_R2_HOST_RECOVERY_'


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def rows(text, kind):
    return [fields(line) for line in text.splitlines() if line.startswith(PREFIX+kind+' ')]


def clean(text):
    need(not re.search(r'FATAL|ERROR:|Traceback|RuntimeError|TimeoutExpired', text), 'failed C19 evidence')
    need(text.splitlines().count(PREFIX+'CLEAN temporary_packages_vectors_and_simulator_removed=1') == 1,
         'missing C19 local cleanup')


def one(text, hold_cycles=64, min_cnn_debt=1):
    ps, results, fs, fails = (rows(text, k) for k in ('PASS', 'RESULT', 'FRAME', 'FAILED'))
    need(len(ps) == len(results) == len(fails) == 1 and len(fs) == 3, 'wrong success/failure attempt count')
    p, r, fail = ps[0], results[0], fails[0]
    w, h, mode = p['width'], p['height'], r['mode']
    need(mode in (1, 2, 3, 4) and r['aw_wait_w'] in (0, 2) and p['stalls'] in (0, 1), 'wrong fault profile')
    need((r['attempts'], r['good_frames'], r['failed_frames'], r['post_fault_good'], r['error_irq_checks']) ==
         (4, 3, 1, 2, 1) and p['cnn_frames'] == 4, 'failed attempts counted as good frames')
    need(all(r[k] == 1 for k in ('actual_response_error', 'no_reset', 'failed_front_forbidden', 'cpu_video_concurrent')),
         'missing real response/drain/recovery scope')
    need(r['cpu_video_overlap'] > 0, 'no actual concurrent CPU/CNN/video interval')
    need((r['r_error_handshakes'], r['b_error_handshakes']) == ((1, 0) if mode <= 2 else (0, 1)),
         'missing/duplicate physical SLVERR handshake')
    if mode <= 2:
        need(r['hold_cycles'] == r['hold_peak_cnn_debt'] == 0, 'unrequested B hold')
    else:
        need(r['hold_cycles'] == hold_cycles and min_cnn_debt <= r['hold_peak_cnn_debt'] <= 4,
             'missing held physical CNN B debt')
    need((fail['mode'], fail['tag'], fail['commits'], fail['cnn_read_debt'], fail['cnn_write_debt'],
          fail['fabric_error'], fail['reset_required'], fail['front_tag']) ==
         (mode, r['failed_tag'], 20 if mode == 4 else 0, 0, 0, 0, 0, 0), 'wrong failure barrier/FRONT')
    need(fail['cycles'] > 0 and fail['writes'] >= 0 and (mode <= 2 or fail['writes'] > 0), 'no actual failed write job')
    for f in fs:
        need((f['width'], f['height'], f['stalls']) == (w, h, p['stalls']), 'mixed successful profile')
        c12.frame(f)
    need(fs[0]['tag'] == 0 and len({f['tag'] for f in fs} | {fail['tag']}) == 4, 'missing distinct recovery tags')
    starts = rows(text, 'NN_START')
    need(len(starts) == 4 and [s['job'] for s in starts] == [1, 2, 3, 4], 'missing attempt start trace')
    terminals = [fs[0], fail, fs[1], fs[2]]
    need([s['tag'] for s in starts] == [f['tag'] for f in terminals], 'wrong failure/recovery ordering')
    sequence = [(kind, fields(line)['tag']) for line in text.splitlines()
                for kind in ('NN_START', 'FRAME', 'FAILED') if line.startswith(PREFIX+kind+' ')]
    expected_sequence = []
    for i, terminal in enumerate(terminals):
        expected_sequence.extend([('NN_START', terminal['tag']), ('FAILED' if i == 1 else 'FRAME', terminal['tag'])])
    need(sequence == expected_sequence, 'missing/overlapping terminal barriers')
    captures, requests = rows(text, 'CAPTURE'), rows(text, 'REQUEST')
    need(len(captures) == len(requests) == p['captures'] and len(captures) >= 4, 'missing actual camera trace')
    need([x['tag'] for x in captures] == [x['tag'] for x in requests] == list(range(len(captures))), 'camera tag mismatch')
    need(p['camera_period'] == w*h*25+4000, 'wrong camera cadence')
    done = {x['tag']: x['cycle'] for x in captures}
    for i, (request, capture) in enumerate(zip(requests, captures)):
        need(request['ready'] == 1 and request['cycle'] < capture['cycle'] and capture['words'] == w*h//4,
             'wrong actual capture completion')
        if i:
            need(request['cycle']-requests[i-1]['cycle'] == p['camera_period'], 'camera cadence drift')
    ends = []
    for i, (start, terminal) in enumerate(zip(starts, terminals)):
        need(start['tag'] in done and start['cycle'] > done[start['tag']], 'start before capture completed')
        if i:
            need(start['cycle'] >= ends[-1], 'new attempt before prior error/success drain')
        need(terminal['complete_cycle'] > start['cycle'], 'nonpositive attempt duration')
        need(terminal['complete_cycle'] == start['cycle']+terminal['cycles']+1,
             'CNN counter excludes START edge; wrong actual completion timestamp')
        ends.append(terminal['complete_cycle'])
    need(p['nn_interval'] == ends[-1]-ends[-2], 'bad terminal interval summary')
    # Exercise the shared C12/C13/C14/C15/C18 timeline reconstruction against
    # actual C19 successful AND failed DONE handshakes, not synthetic times.
    reconstructed = c12.timeline(text.replace(PREFIX, 'C1_R2_RGBX_SYSTEM_'), p, terminals)
    need(reconstructed['completion_cycles'] == ends, 'shared timeline differs from actual DONE handshakes')
    displays = rows(text, 'DISPLAY')
    need(len(displays) == p['displays'] and len(displays) >= 4, 'missing actual display trace')
    good_ends = {f['tag']: end for f, end in zip(terminals, ends) if f['tag'] != fail['tag']}
    for display in displays:
        need(display['tag'] != fail['tag'] and display['tag'] in good_ends and display['cycle'] > good_ends[display['tag']],
             'displayed failed/not-yet-completed result')
    need(fs[-1]['tag'] in {x['tag'] for x in displays}, 'last recovered frame not displayed')
    need(p['good_pixels'] == 2*w*h*p['displays'] and p['underflow'] == p['display_misses'] == 0,
         'display pixels/underflow mismatch')
    need(p['native_timing'] == 0 and p['apb_checks'] == 11 and p['cpu_r'] > 0 and p['cpu_w'] > 0 and
         1 < p['peak_r'] <= 8 and 0 < p['peak_w'] <= 8, 'wrong host/physical credit scope')
    need(all(p[k] == 1 for k in ('actual_capture_only', 'rgbx32', 'cpu_adapter', 'fresh_leases', 'host_shell', 'planned_graph')),
         'not actual C18 host pipeline')
    host, plan, errors, irqs = (rows(text, k) for k in ('HOST', 'PLAN', 'ERROR_RESPONSE', 'ERROR_IRQ'))
    need(len(host) == len(plan) == len(errors) == len(irqs) == 1, 'missing host/plan/error response/IRQ evidence')
    need(tuple(host[0][k] for k in ('apb_bits', 'checks', 'irq_level_verified', 'high_alias_rejected')) == (16, 13, 1, 1),
         'wrong APB/IRQ checks')
    need(tuple(plan[0][k] for k in ('stage_count', 'rgb_stage', 'actual_generated_plan')) == (22, 20, 1), 'wrong model')
    e, irq = errors[0], irqs[0]
    need((e['channel'], e['response'], e['owner'], e['tag'], e['stage']) ==
         ('R' if mode <= 2 else 'B', 2, 0, fail['tag'], 20 if mode == 4 else 0), 'wrong error source')
    # Recoverable errors do not require CPU acknowledgement before admitting
    # the next frame. Error IRQ observation and next START may share a clock.
    need(starts[1]['cycle'] < e['cycle'] <= fail['complete_cycle'] < irq['cycle'] <= starts[2]['cycle'],
         'wrong physical error/completion/IRQ/restart sequence')
    need((irq['tag'], irq['mask'], irq['status'] & 2) == (fail['tag'], 2, 2), 'missing error-only IRQ')
    need(c13.cpu_ids(text.replace(PREFIX, 'C1_R2_CPU_VIDEO_SYSTEM_')) == 1, 'missing restored CPU ID trace')
    return dict(width=w, height=h, stalls=p['stalls'], mode=mode, aw_wait_w=r['aw_wait_w'],
                good_frames=3, failed_frames=1, post_fault_good=2, good_pixels=p['good_pixels'],
                held_cnn_debt=r['hold_peak_cnn_debt'], frame_cycles=[f['cycles'] for f in fs])


def profile_texts(text):
    traces, pending = [], []
    for line in text.splitlines():
        pending.append(line)
        if line.startswith(PREFIX+'RESULT '):
            traces.append('\n'.join(pending))
            pending = []
    need(not any(x.startswith(PREFIX+k+' ') for x in pending for k in ('PASS', 'FRAME', 'FAILED', 'NN_START')),
         'unterminated recovery trace')
    return traces


def matrix(text, keys, hold_cycles=64, min_cnn_debt=1):
    clean(text)
    traces = [one(t, hold_cycles, min_cnn_debt) for t in profile_texts(text)]
    need(len(traces) == len(keys) and {(r['width'], r['height'], r['stalls'], r['mode'], r['aw_wait_w']) for r in traces} == keys,
         'missing/duplicate C19 matrix profile')
    return dict(configs=len(traces), good_frames=3*len(traces), failed_frames=len(traces),
                post_fault_good=2*len(traces), good_pixels=sum(r['good_pixels'] for r in traces),
                actual_c18_production=True, protocol_fault_recovery=False, native_fps_claim=False)


def negative(text):
    clean(text)
    rr = rows(text, 'NEGATIVE_PASS')
    need(len(rr) == 4 and {(r['width'], r['height'], r['stalls'], r['mode'], r['aw_wait_w']) for r in rr} ==
         {(8, 8, 1, m, 0) for m in range(1, 5)}, 'missing actual simulator negative controls')
    for r in rr:
        need(r.get('physical_error_disabled' if r['mode'] in (1, 3) else 'error_irq_masked') == 1,
             'wrong simulator negative scope')
    return dict(simulator_negative_controls=4, stale_output_injection=False)


def xsim(run_id):
    folder = Path('logs/r2_host_recovery_xsim_runs')/run_id
    state = json.loads(read(folder/'status.json'))
    need(state['run_id'] == run_id and state['state'] == 'complete' and state['exit_code'] == 0, 'C19 xsim incomplete')
    need(state['worker_in_windows_job'] is False and not state['simulator_directory_present'] and
         not Path(state['run_directory']).exists(), 'C19 xsim not isolated/clean')
    need(tuple(state[k] for k in ('width', 'height', 'stalls', 'aw_wait_w', 'nn_target', 'memory_div', 'command_latency', 'fault_mode')) ==
         (12, 12, 1, 2, 4, 2, 20, 4) and state['profile'] == 'microstyle24', 'wrong C19 xsim profile')
    package = compile_package(profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv') == package.plan_sv and
         json.loads(read(folder/'plan_manifest.json')) == json.loads(json.dumps(package.manifest)), 'wrong xsim generated package')
    result = one(read(folder/'result.log'))
    result.update(run_id=run_id, actual_cpu_ip_execution=False, board_validation=False)
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--xsim-run')
    args = p.parse_args()
    baseline = read('logs/r2_host_recovery_matrix_20260913_b.log')
    wb = read('logs/r2_host_recovery_wbeforeaw_20260913_b.log')
    multiple = read('logs/r2_host_recovery_two_debts_20260913_a.log')
    base_keys = {(8, 8, s, m, 0) for s in (0, 1) for m in range(1, 5)}
    wb_keys = {(12, 12, s, m, 2) for s in (0, 1) for m in (3, 4)}
    emit = lambda name, data: print('C1_R2_C19_'+name+' '+json.dumps(data), flush=True)
    emit('SOURCE_GATE_PASS', c18.derivation())
    emit('MATRIX_GATE_PASS', matrix(baseline, base_keys))
    emit('WBEFOREAW_GATE_PASS', matrix(wb, wb_keys))
    emit('MULTI_DEBT_GATE_PASS', matrix(multiple, {(128, 4, 1, 4, 0)}, hold_cycles=256, min_cnn_debt=2))
    emit('SIM_NEGATIVE_GATE_PASS', negative(read('logs/r2_host_recovery_negative_20260913_b.log')))
    changes = [('no_reset=1', 'no_reset=0'), ('failed_frames=1', 'failed_frames=0'),
               ('post_fault_good=2', 'post_fault_good=1'), ('front_tag=0', 'front_tag=999'),
               ('cnn_read_debt=0', 'cnn_read_debt=1'), ('r_error_handshakes=1', 'r_error_handshakes=0'),
               ('error_irq_checks=1', 'error_irq_checks=0'), ('failed_front_forbidden=1', 'failed_front_forbidden=0')]
    for old, new in changes:
        need(old in baseline, 'missing audit mutation')
        try:
            matrix(baseline.replace(old, new, 1), base_keys)
        except ValueError:
            pass
        else:
            raise ValueError('corrupt C19 evidence accepted: '+old)
    # Independent trace deletion is not repaired by a surviving PASS flag.
    for kind in ('DISPLAY', 'ERROR_RESPONSE', 'ERROR_IRQ'):
        lines = baseline.splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith(PREFIX+kind+' '))
        del lines[index]
        try:
            matrix('\n'.join(lines), base_keys)
        except ValueError:
            pass
        else:
            raise ValueError('missing actual trace accepted: '+kind)
    # Reproduce the old one-clock absolute-completion error without changing
    # retained evidence or production RTL. Intervals alone would miss this.
    timestamp = re.search(r'complete_cycle=(\d+)', baseline)
    need(timestamp is not None, 'missing actual completion timestamp')
    altered = baseline[:timestamp.start(1)]+str(int(timestamp.group(1))-1)+baseline[timestamp.end(1):]
    try:
        matrix(altered, base_keys)
    except ValueError:
        pass
    else:
        raise ValueError('one-clock completion undercount accepted')
    for old, new in (('hold_peak_cnn_debt=2', 'hold_peak_cnn_debt=1'), ('hold_cycles=256', 'hold_cycles=255')):
        need(old in multiple, 'missing actual multiple-debt mutation')
        try:
            matrix(multiple.replace(old, new, 1), {(128, 4, 1, 4, 0)}, hold_cycles=256, min_cnn_debt=2)
        except ValueError:
            pass
        else:
            raise ValueError('insufficient physical debt/hold accepted')
    emit('AUDIT_NEGATIVE_PASS', dict(rejected=len(changes)+6, actual_completion_counter_crosscheck=True))
    if args.xsim_run:
        emit('XSIM_GATE_PASS', xsim(args.xsim_run))
        reference = [t for t in profile_texts(wb) if rows(t, 'PASS')[0]['stalls'] == 1 and rows(t, 'RESULT')[0]['mode'] == 4]
        need(len(reference) == 1, 'missing same-profile Icarus reference')
        xt = read(Path('logs/r2_host_recovery_xsim_runs')/args.xsim_run/'result.log')
        kinds = ('NN_START', 'FRAME', 'FAILED', 'ERROR_RESPONSE', 'ERROR_IRQ', 'DISPLAY',
                 'CAPTURE', 'REQUEST', 'HOST', 'IDS', 'PASS', 'PLAN', 'RESULT')
        for kind in kinds:
            need(rows(xt, kind) == rows(reference[0], kind), 'Icarus/xsim trace disagreement: '+kind)
        emit('CROSS_SIMULATOR_GATE_PASS', dict(actual_event_kinds=len(kinds), cycles_traffic_faults_display_identical=True))


if __name__ == '__main__':
    main()
