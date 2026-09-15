"""C21 actual compact host/operator evidence. Native performance is opt-in."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re

import check_r2_planned_host_evidence as c18
import check_r2_host_recovery_evidence as c19
from run_r2_compact_host_probe import ROOT, SOURCES

need = c18.need
PREFIX = 'C1_R2_COMPACT_HOST_SYSTEM_'
NAMES = dict(c1_r2_pw_bulk_feeder='c1_r2_pw_lane_feeder', c1_r2_encoder_feeder='c1_r2_encoder_lane_feeder',
             c1_r2_spatial_bulk_feeder='c1_r2_spatial_lane_feeder', c1_r2_cnn_bulk_engine='c1_r2_cnn_compact_engine',
             c1_r2_planned_pingpong_graph='c1_r2_compact_pingpong_graph',
             c1_r2_planned_rgbx_axi_graph='c1_r2_compact_rgbx_axi_graph',
             c1_r2_video_planned_system='c1_r2_video_compact_system',
             c1_r2_planned_host_system='c1_r2_compact_host_system',
             c1_ti60_r2_planned_host96='c1_ti60_r2_compact_host96')


def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def translated(text):
    return text.replace(PREFIX, c18.PREFIX)


def tokens(text):
    return re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S))


def source_gate():
    retained = c18.derivation()
    for old, new in NAMES.items():
        folder = 'efinity/' if old.startswith('c1_ti60') else 'rtl/r2/'
        expected, actual = read(folder+old+'.sv'), read(folder+new+'.sv')
        for a, b in NAMES.items():
            actual = actual.replace(b, a)
        if 'feeder' in old:
            actual = actual.replace('    output wire [53:0] weight_lane_addr,\n', '').replace('input wire [767:0] weight_data,', 'input wire [1023:0] weight_data,')
            if old in ('c1_r2_pw_bulk_feeder', 'c1_r2_encoder_feeder'):
                actual = re.sub(r'    for\(genvar lane=0;lane<6;lane=lane\+1\) begin : g_lane_address\n.*?    end\n', '', actual, flags=re.S)
                actual = actual.replace('weight_data[r*128+:128]', 'weight_data[bank*128+:128]')
            if old == 'c1_r2_pw_bulk_feeder':
                actual = actual.replace('bulk_en && bulk_word && bulk_address<512', 'bulk_en && bulk_word')
            if old == 'c1_r2_spatial_bulk_feeder':
                actual = actual.replace('    wire [53:0] e_lane_addr;\n', '').replace(',.weight_lane_addr(e_lane_addr)', '')
                actual = re.sub(r'        localparam \[2:0\] RGB_BANK=RGB_C;\n.*?\{RGB_BANK,3\'d0,beat_q\};\n', '', actual, flags=re.S)
                actual = actual.replace('weight_data[r*128+:72]', 'weight_data[CHANNEL*128+:72]').replace('weight_data[r*128+:128]', 'weight_data[RGB_C*128+:128]')
        if old == 'c1_r2_cnn_bulk_engine':
            actual = actual.replace('wire [767:0] weight_data;\n    wire [107:0] f_lane_addr;', 'wire [1023:0] weight_data;')
            actual = actual.replace('    wire [53:0] weight_lane_addr=own_linear_pool ? f_lane_addr[0+:54] : f_lane_addr[54+:54];\n', '')
            actual = actual.replace('c1_r2_weight_store6 #(.PACKED(1)) u_weights', 'c1_r2_weight_store8 u_weights')
            actual = actual.replace(',.lane_addr(weight_lane_addr)', '').replace(',.weight_lane_addr(f_lane_addr[0+:54])', '').replace(',.weight_lane_addr(f_lane_addr[54+:54])', '')
            actual = actual.replace('3\'d3)+(bulk_group>>1);', "3'd3)+(mode==3 ? ((3+bulk_group)>>1) : (bulk_group>>1));")
        need(tokens(actual) == tokens(expected), 'unexpected C21 change outside lane routing/capacity repair: '+new)
    expected_sources = list(c18.SOURCES)
    for index, name in enumerate(expected_sources):
        for a, b in NAMES.items():
            name = name.replace(a, b)
        expected_sources[index] = name.replace('c1_r2_weight_store8.sv', 'c1_r2_weight_store6.sv')
    expected_sources.append('rtl/r2/c1_r2_weight_asym_ram.sv')
    need(len(SOURCES) == len(set(SOURCES)) == 33 and set(SOURCES) == set(expected_sources), 'wrong compact source closure')
    need('c1_r2_weight_store6 #(.PACKED(1)) u_weights' in read('rtl/r2/c1_r2_cnn_compact_engine.sv'), 'packed storage not selected')
    for old, new, old_prefix, new_prefix in (
        ('tb_c1_r2_planned_host_system','tb_c1_r2_compact_host_system',c18.PREFIX,PREFIX),
        ('tb_c1_r2_host_recovery_system','tb_c1_r2_compact_recovery_system',c19.PREFIX,'C1_R2_COMPACT_RECOVERY_')):
        expected = read('sim/'+old+'.sv').replace(old,new).replace(old_prefix,new_prefix)
        for a,b in NAMES.items():
            expected = expected.replace(a,b)
        need(tokens(expected) == tokens(read('sim/'+new+'.sv')), 'changed retained system/recovery stimulus')
    return dict(retained_c18=retained, compared_modules_and_probe=9, source_files=33,
                packed_weights=True, six_lane_read_interface=True, residual_capacity_fix=True,
                external_abi_and_generated_graph_unchanged=True)


def recovery_gate(text, keys, **kwargs):
    result = c19.matrix(text.replace('C1_R2_COMPACT_RECOVERY_', c19.PREFIX), keys, **kwargs)
    # Reuse the transaction checker, not its historical implementation label.
    result.pop('actual_c18_production', None)
    return dict(result, actual_c21_candidate=True)


def same_trace(new, old):
    # Compare all actual source/output/CPU/frame/stage timing, not only PASS.
    n, o = c18.normalized(translated(new)), c18.normalized(old)
    for kind in ('REQUEST', 'CAPTURE', 'NN_START', 'FRAME', 'HOST', 'IDS', 'PASS', 'STAGE', 'PLAN'):
        need(c18.c12.rows(n, kind) == c18.c12.rows(o, kind), 'compact/C18 trace mismatch: '+kind)
    return dict(actual_event_kinds=9, cycles_and_traffic_identical=True, fps_gain_claimed=False)


def operator_gate(text):
    prefix = 'C1_R2_COMPACT_OPERATOR_'
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'failed operator run')
    lines = text.splitlines()
    meta_lines = [x[len(prefix+'VECTORS '):] for x in lines if x.startswith(prefix+'VECTORS ')]
    need(len(meta_lines) == 1, 'missing operator vector metadata')
    meta = json.loads(meta_lines[0])
    need(tuple(meta[k] for k in ('commands', 'bulk', 'jobs', 'vectors', 'scalars', 'trained_scalars', 'residual_capacity_jobs')) ==
         (150731, 115822, 187, 167635, 925169, 367360, 2), 'operator golden coverage changed')
    need(meta['pw_shapes'] == [[ci, co] for ci in (16, 24, 48) for co in (8, 16, 24, 48)], 'missing PW shape')
    passes = [c18.c12.fields(x) for x in lines if x.startswith(prefix+'PASS ')]
    jobs = [c18.c12.fields(x) for x in lines if x.startswith(prefix+'JOB ')]
    need(len(passes) == 2 and [x['stalls'] for x in passes] == [0, 1] and len(jobs) == 374, 'missing operator profiles')
    for p in passes:
        need((p['jobs'], p['vectors'], p['bulk_writes'], p['reset_modes'], p['packed_weights'], p['lanes']) ==
             (187, 167635, 115822, 6, 1, 6) and p['parameter_reads'] > 0 and p['busy_rejections'] > 20,
             'wrong operator protocol counters')
        if p['stalls']:
            need(p['held_cycles'] > 20, 'no backpressure')
        js = [x for x in jobs if x['stalls'] == p['stalls']]
        need([x['job'] for x in js] == list(range(187)) and sum(x['vectors'] for x in js) == 167635,
             'operator jobs missing/duplicate')
        need({str(mode): sum(x['mode'] == mode for x in js) for mode in range(6)} == meta['mode_jobs'], 'missing operator mode')
        need({x['size'] for x in js if x['mode'] == 3 and x['size'] > 8160} == {8191, 8192}, 'capacity tail not executed')
        for x in js:
            nb = x['vectors']*(((x['channels']+15)//16) if x['mode'] == 0 else {1:5, 4:2, 5:7}.get(x['mode'], 1))
            overhead = 13 if x['mode'] in (0, 3) else {4:17, 5:19}.get(x['mode'], 16)
            need(x['mac_beats'] == nb and (x['stalls'] or x['cycles'] == nb+overhead), 'operator scheduling regression')
    need(text.count(prefix+'CLEAN temporary_vectors_and_simulator_removed=1') == 1, 'operator cleanup missing')
    return dict(jobs=374, scalars_checked=1850338, trained_scalars_checked=734720,
                reset_modes_per_profile=6, all_12_pw_shapes=True, residual_8191_and_8192=True,
                no_extra_compute_cycles=True)


def xsim(run, native=False):
    folder = Path('logs/r2_compact_host_xsim_runs')/run
    s = json.loads(read(folder/'status.json'))
    need(s['state'] == 'complete' and s['exit_code'] == 0 and s['worker_in_windows_job'] is False and
         not s['simulator_directory_present'] and not Path(s['run_directory']).exists(), 'xsim incomplete/job/unclean')
    expected = (640,480,0,0,6,2,20) if native else (12,12,1,2,6,2,20)
    need(tuple(s[k] for k in ('width','height','stalls','aw_wait_w','nn_target','memory_div','command_latency')) == expected and
         s['profile'] == 'microstyle24', 'wrong xsim stimulus')
    text = translated(read(folder/'result.log'))
    c18.planned_profiles(text, 'microstyle24', 1)
    nt = c18.normalized(text)
    p, fs = c18.c12.rows(nt, 'PASS')[0], c18.c12.rows(nt, 'FRAME')
    timeline = c18.run(p, fs, nt, 'microstyle24', native)
    package = c18.compile_package(c18.profile_nodes('microstyle24'))
    need(read(folder/'execution_plan.sv') == package.plan_sv and json.loads(read(folder/'plan_manifest.json')) ==
         json.loads(json.dumps(package.manifest)), 'wrong xsim plan/parameters metadata')
    if native:
        cc = c18.c12.rows(nt, 'STAGE')
        need(len(cc) == 132, 'missing native layer commits')
        for f in fs:
            rows = [x for x in cc if x['tag'] == f['tag']]
            need([x['stage'] for x in rows] == list(range(22)) and rows[-1]['cycles'] == f['cycles'] and
                 rows[-1]['words'] == f['write_beats'], 'native layer trace mismatch')
    return dict(run=run, cycles=[x['cycles'] for x in fs], timeline=timeline, **c18.c12.throughput(timeline, native),
                board=False, actual_cpu_ip=False, seconds=s['elapsed_seconds'])


def physical(run):
    folder = Path('logs/efinity_resource_runs')/run
    s, m = [json.loads(read(folder/name)) for name in ('status.json', 'summary.json')]
    need(s['state'] == m['state'] == 'complete' and s['exit_code'] == m['pnr_exit_code'] == 0 and
         (m['marker'],m['family'],m['device'],m['flow']) ==
         ('C1_TI60_R2_COMPACT_HOST96_MAP_PNR_PASS','Titanium','Ti60F225','map+pnr'), 'wrong/incomplete physical run')
    private = Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_compact_host96_'+run)
    need(not private.exists() and '--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'), 'wrong grade/cleanup')
    r, t, metrics = m['pnr_resources'], m['timing'], m['metrics']
    need((r['memory_blocks_used'],r['dsp_blocks_used']) == (150,112) and 0 < r['xlr_cells_used'] < 46531, 'resource saving lost/pruned')
    need(metrics['primitive_counts'].get('EFX_DSP24') == 96 and metrics['primitive_counts'].get('EFX_DSP48') == 16, 'wrong MAC/quantizer')
    hierarchy = set(metrics['module_rows']+metrics.get('module_focus_rows', []))
    for name in ('+u_host:c1_r2_compact_host_system', '+u_cpu_adapter:c1_r2_cpu_axi_adapter',
                 '+u_system:c1_r2_video_compact_system', '+u_cnn:c1_r2_compact_rgbx_axi_graph',
                 '+u_graph:c1_r2_compact_pingpong_graph', '+u_operator:c1_r2_cnn_compact_engine',
                 '+u_weights:c1_r2_weight_store6(PACKED=1)', '+u_plan:c1_r2_microstyle_plan'):
        need(sum(name in row for row in hierarchy) == 1, 'missing physical hierarchy: '+name)
    need(t['final_slack_ns'] >= 0 and t['final_hold_slack_ns'] >= 0 and
         abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002, '150MHz setup/hold failure')
    return dict(run=run, resources=r, timing=t, ram_saved=22, xlr_saved=46531-r['xlr_cells_used'],
                scope='pin-reduced complete host/CNN/video/fabric; no CPU IP/PHY/ISP/CDC/board IO')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--pnr-run', default='c21_compact_host96_i3_20260913_b')
    p.add_argument('--native-run')
    p.add_argument('--require-15fps', action='store_true')
    a = p.parse_args()
    need(not a.require_15fps or a.native_run, 'native FPS cannot be inherited')
    emit = lambda name, value: print('C1_R2_C21_'+name+' '+json.dumps(value, separators=(',', ':')), flush=True)
    emit('SOURCE_GATE_PASS', source_gate())
    main_text = read('logs/r2_compact_host_matrix_20260913_b.log')
    emit('SYSTEM_GATE_PASS', c18.matrix(translated(main_text), 'microstyle24'))
    emit('RETAINED_EQUIVALENCE_PASS', same_trace(main_text, read('logs/r2_planned_host_matrix_20260913_a.log')))
    variant = read('logs/r2_compact_host_variant_20260913_b.log')
    emit('VARIANT_GATE_PASS', c18.matrix(translated(variant), 'drop_res1'))
    emit('VARIANT_EQUIVALENCE_PASS', same_trace(variant, read('logs/r2_planned_host_variant_20260913_a.log')))
    operator = read('logs/r2_compact_operator_20260913_b.log')
    emit('OPERATOR_GATE_PASS', operator_gate(operator))
    emit('RAM_NEGATIVE_GATE_PASS', c18.negative(translated(read('logs/r2_compact_host_negative_20260913_a.log'))))
    fault = read('logs/r2_compact_recovery_matrix_20260913_a.log')
    emit('RECOVERY_GATE_PASS', recovery_gate(fault, {(8,8,s,m,0) for s in (0,1) for m in range(1,5)}))
    debt = read('logs/r2_compact_recovery_debt_20260913_a.log')
    emit('RECOVERY_DEBT_GATE_PASS', recovery_gate(debt, {(128,4,1,4,0)}, hold_cycles=256, min_cnn_debt=2))
    emit('XSIM_GATE_PASS', xsim('c21_compact_host_xsim_12x12_20260913_b'))
    emit('XSIM_EQUIVALENCE_PASS', same_trace(read('logs/r2_compact_host_xsim_runs/c21_compact_host_xsim_12x12_20260913_b/result.log'),
                                         read('logs/r2_planned_host_xsim_runs/c18_planned_host_xsim_12x12_20260913_a/result.log')))
    for old, new in [('reset_modes=6','reset_modes=0'), ('size=8192','size=8160'), ('packed_weights=1','packed_weights=0')]:
        need(old in operator, 'missing operator mutation target')
        try:
            operator_gate(operator.replace(old,new,1))
        except ValueError:
            pass
        else:
            raise ValueError('operator evidence mutation accepted')
    emit('AUDIT_NEGATIVE_PASS', dict(operator_mutations_rejected=3))
    emit('PHYSICAL_GATE_PASS', physical(a.pnr_run))
    if a.native_run:
        result = xsim(a.native_run, True)
        emit('NATIVE_GATE_PASS', result)
        if a.require_15fps:
            c18.c12.require_throughput(result, 4)


if __name__ == '__main__':
    main()
