"""C18 generated-plan host evidence. No inherited native FPS or CPU/board claim."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

import check_r2_rgbx_system_evidence as c12
import check_r2_fresh_video_evidence as c14
import check_r2_host_video_evidence as c15
import check_r2_bound_plan_evidence as c17
from run_r2_planned_host_probe import SOURCES, PLAN_SOURCE
from r2_plan_package import compile_package, profile_nodes, verify

ROOT, need = c12.ROOT, c12.need
PREFIX = 'C1_R2_PLANNED_HOST_SYSTEM_'
SHAPES = ((8, 8), (32, 32))


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def normalized(text):
    return text.replace(PREFIX, 'C1_R2_RGBX_SYSTEM_')


def derivation():
    # Direct source comparison excluding comments/whitespace; no digests.
    # The only production change is the selected generated-plan graph.
    def tokens(t):
        return re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', t, flags=re.S))
    changes = (
        ('rtl/r2/c1_r2_microstyle_rgbx_axi_graph.sv', 'rtl/r2/c1_r2_planned_rgbx_axi_graph.sv',
         {'c1_r2_microstyle_rgbx_axi_graph': 'c1_r2_planned_rgbx_axi_graph',
          'c1_r2_microstyle_pingpong_graph': 'c1_r2_planned_pingpong_graph'}),
        ('rtl/r2/c1_r2_video_fresh_system.sv', 'rtl/r2/c1_r2_video_planned_system.sv',
         {'c1_r2_video_fresh_system': 'c1_r2_video_planned_system',
          'c1_r2_microstyle_rgbx_axi_graph': 'c1_r2_planned_rgbx_axi_graph'}),
        ('rtl/r2/c1_r2_host_video_system.sv', 'rtl/r2/c1_r2_planned_host_system.sv',
         {'c1_r2_host_video_system': 'c1_r2_planned_host_system',
          'c1_r2_video_fresh_system': 'c1_r2_video_planned_system'}),
        ('efinity/c1_ti60_r2_host_video96.sv', 'efinity/c1_ti60_r2_planned_host96.sv',
         {'c1_ti60_r2_host_video96': 'c1_ti60_r2_planned_host96',
          'c1_r2_host_video_system': 'c1_r2_planned_host_system'}),
    )
    for old, new, renames in changes:
        expected = read(old)
        for a, b in renames.items():
            expected = expected.replace(a, b)
        need(tokens(read(new)) == tokens(expected), 'unexpected wrapper/probe change: '+new)
    need(len(SOURCES) == len(set(SOURCES)) == 32 and SOURCES.count(PLAN_SOURCE) == 1,
         'missing/duplicate generated source closure')
    need(not any('microstyle_pingpong_graph.sv' in s for s in SOURCES), 'old executor in C18 closure')
    need('rtl/r2/c1_r2_planned_pingpong_graph.sv' in SOURCES and all((ROOT/s).is_file() for s in SOURCES),
         'planned executor/source missing')
    for profile in ('microstyle24', 'drop_res1'):
        verify(compile_package(profile_nodes(profile)), ROOT/f'model/r2_{profile}_bound_plan')
    return dict(compared_wrappers_and_probe=4, source_files=32, retained_c16_executor=True,
                retained_external_abi=True, package_byte_comparison=True, cpu_ip=False)


def budget(profile, w, h):
    b = dict(c17.budget(profile, w, h))
    # Only external camera read and final RGB write are RGBX-packed.
    # All intermediate P2C8 tensors and their DAG ownership are unchanged.
    for key in ('reads', 'features', 'writes'):
        b[key] -= w*h//4
    return b


def planned_profiles(text, profile, count):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError|TimeoutExpired', text), 'failed C18 run')
    c15.host_profiles(text.replace(PREFIX, 'C1_R2_HOST_VIDEO_SYSTEM_'), count)
    pending, seen = None, 0
    stages = 22 if profile == 'microstyle24' else 18
    for line in text.splitlines():
        if line.startswith(PREFIX+'PASS '):
            need(pending is None, 'missing per-profile plan marker')
            pending = c12.fields(line)
            need(pending.get('planned_graph') == 1, 'not actual planned graph')
        elif line.startswith(PREFIX+'PLAN '):
            need(pending is not None, 'orphan/duplicate plan marker')
            r = c12.fields(line)
            need((r.get('stage_count'), r.get('rgb_stage'), r.get('actual_generated_plan')) ==
                 (stages, stages-2, 1), 'wrong runtime plan evidence')
            pending = None
            seen += 1
    need(pending is None and seen == count, 'missing runtime plan evidence')


def run(p, fs, text, profile, native=False):
    if profile == 'microstyle24':
        return c12.run(p, fs, text, native, 6)
    need(not native, 'variant is not a native competition-performance candidate')
    w, h = p['width'], p['height']
    need(len(fs) == p['cnn_frames'] == 6, 'wrong variant frame count')
    need(fs[0]['tag'] == 0 and len({f['tag'] for f in fs}) == 6 and all(f['tag'] > 0 for f in fs[1:]),
         'missing captured variant frame tags')
    for f in fs:
        b = budget(profile, w, h)
        need((f['width'], f['height'], f['stalls']) == (w, h, p['stalls']), 'mixed variant profile')
        need(tuple(f[k] for k in ('read_beats', 'write_beats', 'producers', 'commits')) ==
             (b['reads'], b['writes'], b['features'], b['stages']), 'wrong variant traffic/layers')
        need(f['cycles'] > max(b['reads'], b['writes'], (b['macs']+95)//96), 'impossible variant cycles')
    need(p['actual_capture_only'] == p['rgbx32'] == 1 and p['native_timing'] == 0, 'wrong variant source/mode')
    need(p['captures'] >= 6 and p['displays'] >= 6 and p['good_pixels'] >= 12*w*h, 'missing variant lifecycle')
    need(p['underflow'] == p['display_misses'] == 0, 'variant display miss')
    need(p['camera_period'] == w*h*25+4000, 'wrong variant camera cadence')
    need(p['cpu_r'] > 0 and p['cpu_w'] > 0 and p['apb_checks'] == 9, 'missing variant host traffic')
    need(1 < p['peak_r'] <= 8 and 0 < p['peak_w'] <= 8, 'wrong variant physical credits')
    need(p['nn_interval'] >= fs[-1]['cycles'], 'impossible variant interval')
    return c12.timeline(text, p, fs)


def matrix(text, profile):
    planned_profiles(text, profile, 4)
    nt = normalized(text)
    c12.clean(nt)
    profiles, frames, trace = [], [], []
    for line in nt.splitlines():
        trace.append(line)
        if line.startswith('C1_R2_RGBX_SYSTEM_FRAME '):
            frames.append(c12.fields(line))
        if line.startswith('C1_R2_RGBX_SYSTEM_PASS '):
            p = c12.fields(line)
            run(p, frames, '\n'.join(trace), profile)
            profiles.append(p)
            frames, trace = [], []
    need(not frames and {(p['width'], p['height'], p['stalls']) for p in profiles} ==
         {(w, h, s) for w, h in SHAPES for s in (0, 1)}, 'missing/duplicate C18 matrix profiles')
    return dict(profile=profile, configs=4, cnn_frames=24,
                good_display_pixels=sum(p['good_pixels'] for p in profiles), quality_validated=False)


def retained_equivalence(new, old):
    nt, ot = normalized(new), c15.normalized(old)
    for key in ('REQUEST', 'CAPTURE', 'NN_START', 'FRAME', 'HOST', 'IDS', 'PASS', 'STAGE'):
        nn, oo = c12.rows(nt, key), c12.rows(ot, key)
        for row in nn:
            row.pop('planned_graph', None)
        need(nn == oo, 'C18 differs from retained C15 trace: '+key)
    return dict(same_cycle_traffic_and_capture_display_host_trace=True, performance_gain_claimed=False)


def negative(text):
    nt = normalized(text)
    c12.clean(nt)
    rr = c12.rows(nt, 'NEGATIVE_PASS')
    need(len(rr) == 8 and {(r['width'], r['height'], r['stalls'], r['corruption'], r['actual_ram_mutation']) for r in rr} ==
         {(w, h, s, n, 1) for w, h in SHAPES for s in (0, 1) for n in (1, 2)}, 'missing actual RAM corruptions')
    return dict(actual_ram_mutations=8, axi_protocol_fault_injection=False)


def xsim(run_id, native=False):
    folder = Path('logs/r2_planned_host_xsim_runs')/run_id
    state = json.loads(read(folder/'status.json'))
    need(state['run_id'] == run_id and state['state'] == 'complete' and state['exit_code'] == 0,
         'C18 xsim incomplete')
    need(state['worker_in_windows_job'] is False and not state['simulator_directory_present'] and
         not Path(state['run_directory']).exists(), 'C18 xsim not isolated/clean')
    expected = (640, 480, 0, 0, 6, 2, 20) if native else (12, 12, 1, 2, 6, 2, 20)
    need(tuple(state[k] for k in ('width', 'height', 'stalls', 'aw_wait_w', 'nn_target', 'memory_div', 'command_latency')) == expected
         and state['profile'] == 'microstyle24', 'wrong C18 xsim profile')
    text = read(folder/'result.log')
    planned_profiles(text, 'microstyle24', 1)
    nt = normalized(text)
    p, fs = c12.rows(nt, 'PASS')[0], c12.rows(nt, 'FRAME')
    timeline = run(p, fs, nt, 'microstyle24', native)
    package = compile_package(profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv') == package.plan_sv and
         json.loads(read(folder/'plan_manifest.json')) == json.loads(json.dumps(package.manifest)),
         'wrong retained xsim plan/manifest')
    meta = json.loads(read(folder/'metadata.json'))
    b = c17.budget('microstyle24', p['width'], p['height'])
    need(tuple(meta[k] for k in ('stage_count', 'rgb_stage', 'parameter_words', 'input_words', 'expected_words')) ==
         (22, 20, 2333, p['width']*p['height']//2, 2*b['writes']) and meta['frames'][0]['scalars'] == b['scalars'],
         'wrong C18 golden metadata')
    if native:
        commits = c12.rows(nt, 'STAGE')
        need(len(commits) == 132, 'missing native stage trace')
        for f in fs:
            cc = [r for r in commits if r['tag'] == f['tag']]
            need([r['stage'] for r in cc] == list(range(22)) and cc[-1]['words'] == f['write_beats'] and
                 cc[-1]['cycles'] == f['cycles'], 'native stage trace mismatch')
    return dict(run_id=run_id, cnn_frames=6, frame_cycles=[f['cycles'] for f in fs], timeline=timeline,
                freshness=c14.native_freshness(nt) if native else None, **c12.throughput(timeline, native),
                actual_cpu_ip_execution=False, board_validation=False)


def physical(run_id):
    folder = Path('logs/efinity_resource_runs')/run_id
    s, m = (json.loads(read(folder/name)) for name in ('status.json', 'summary.json'))
    need(s['run_id'] == m['run_id'] == run_id and s['state'] == m['state'] == 'complete' and
         s['exit_code'] == m['pnr_exit_code'] == 0, 'C18 physical run incomplete')
    need((m['marker'], m['family'], m['device'], m['flow']) ==
         ('C1_TI60_R2_PLANNED_HOST96_MAP_PNR_PASS', 'Titanium', 'Ti60F225', 'map+pnr'), 'wrong C18 physical target')
    private = Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_planned_host96_'+run_id)
    need(not private.exists() and '--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'), 'wrong grade/unclean C18 PNR')
    resources, timing, metrics = m['pnr_resources'], m['timing'], m['metrics']
    need(resources['dsp_blocks_used'] == 112 and resources['memory_blocks_used'] == 172 and
         0 < resources['xlr_cells_used'] <= 60800, 'unexpected/pruned C18 footprint')
    need(metrics['primitive_counts'].get('EFX_DSP24') == 96 and metrics['primitive_counts'].get('EFX_DSP48') == 16,
         'wrong C18 array')
    hierarchy = set(metrics['module_rows']+metrics.get('module_focus_rows', []))
    for name in ('+u_host:c1_r2_planned_host_system', '+u_control_bridge:c1_r2_host_control_bridge',
                 '+u_cpu_adapter:c1_r2_cpu_axi_adapter', '+u_system:c1_r2_video_planned_system',
                 '+u_leases:c1_r2_video_fresh_leases', '+u_cnn:c1_r2_planned_rgbx_axi_graph',
                 '+u_graph:c1_r2_planned_pingpong_graph', '+u_plan:c1_r2_microstyle_plan'):
        need(sum(name in row for row in hierarchy) == 1, 'missing C18 hierarchy: '+name)
    need(timing['final_slack_ns'] >= 0 and timing['final_hold_slack_ns'] >= 0 and
         abs(timing['final_slack_ns']+timing['final_period_ns']-6.666) < .002, 'C18 150MHz setup/hold failure')
    return dict(run_id=run_id, resources=resources, timing=timing,
                scope='pin-reduced 640x480 host/CNN/video/fabric; no CPU IP/PHY/ISP/CDC/board IO')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pnr-run')
    parser.add_argument('--native-run')
    parser.add_argument('--require-15fps', action='store_true')
    args = parser.parse_args()
    need(not args.require_15fps or (args.native_run and args.pnr_run), 'FPS requires C18 native and physical evidence')
    main_text = read('logs/r2_planned_host_matrix_20260913_a.log')
    variant = read('logs/r2_planned_host_variant_20260913_a.log')
    narrow = read('logs/r2_planned_host_narrow_20260913_a.log').replace('C1_R2_PLANNED_HOST_NARROW_', 'C1_R2_HOST_NARROW_')
    emit = lambda name, value: print('C1_R2_C18_'+name+' '+json.dumps(value), flush=True)
    emit('SOURCE_GATE_PASS', derivation())
    emit('SYSTEM_GATE_PASS', matrix(main_text, 'microstyle24'))
    emit('VARIANT_GATE_PASS', matrix(variant, 'drop_res1'))
    emit('RETAINED_EQUIVALENCE_PASS', retained_equivalence(main_text, read('logs/r2_host_video_system_sixframe_20260913_a.log')))
    emit('RAM_NEGATIVE_GATE_PASS', negative(read('logs/r2_planned_host_negative_20260913_a.log')))
    emit('NARROW_GATE_PASS', c15.narrow(narrow))
    emit('XSIM_GATE_PASS', xsim('c18_planned_host_xsim_12x12_20260913_a'))
    emit('XSIM_EQUIVALENCE_PASS', retained_equivalence(
        read('logs/r2_planned_host_xsim_runs/c18_planned_host_xsim_12x12_20260913_a/result.log'),
        read('logs/r2_host_video_xsim_runs/c15_host_video_xsim_12x12_20260913_a/result.log')))
    mutations = [('planned_graph=1', 'planned_graph=0'), ('actual_generated_plan=1', 'actual_generated_plan=0'),
                 ('stage_count=22', 'stage_count=18'), ('rgb_stage=20', 'rgb_stage=16'),
                 ('restored_bits=8', 'restored_bits=4'), ('irq_level_verified=1', 'irq_level_verified=0'),
                 ('commits=22', 'commits=18'), ('underflow=0', 'underflow=1')]
    for old, new in mutations:
        need(old in main_text, 'missing C18 audit mutation')
        try:
            matrix(main_text.replace(old, new, 1), 'microstyle24')
        except ValueError:
            pass
        else:
            raise ValueError('corrupt C18 evidence accepted: '+old)
    emit('AUDIT_NEGATIVE_PASS', dict(rejected=len(mutations)))
    if args.pnr_run:
        emit('PHYSICAL_GATE_PASS', physical(args.pnr_run))
    if args.native_run:
        result = xsim(args.native_run, True)
        emit('NATIVE_GATE_PASS', result)
        if args.require_15fps:
            c12.require_throughput(result, 4)


if __name__ == '__main__':
    main()
