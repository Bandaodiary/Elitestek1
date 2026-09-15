"""C22 physical feature-overlay evidence; independent native performance is opt-in."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re

import check_r2_compact_host_evidence as c21
import check_r2_planned_host_evidence as c18
import check_r2_host_recovery_evidence as c19
from run_r2_overlay_host_probe import ROOT, SOURCES

need = c18.need
PREFIX = 'C1_R2_OVERLAY_HOST_SYSTEM_'
NAMES = dict(c1_r2_pw_lane_feeder='c1_r2_pw_overlay_feeder',
             c1_r2_bulk_window_store='c1_r2_overlay_window_store',
             c1_r2_spatial_lane_feeder='c1_r2_spatial_overlay_feeder',
             c1_r2_cnn_compact_engine='c1_r2_cnn_overlay_engine',
             c1_r2_compact_pingpong_graph='c1_r2_overlay_pingpong_graph',
             c1_r2_compact_rgbx_axi_graph='c1_r2_overlay_rgbx_axi_graph',
             c1_r2_video_compact_system='c1_r2_video_overlay_system',
             c1_r2_compact_host_system='c1_r2_overlay_host_system',
             c1_ti60_r2_compact_host96='c1_ti60_r2_overlay_host96')



def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')


def translated(text):
    return text.replace(PREFIX, c18.PREFIX)


def tokens(text):
    return re.sub(r'\s+', '', re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S))


def source_gate():
    retained = c21.source_gate()
    linear_ports = """
        input wire linear_rd_en,input wire [17:0] linear_rd_addr,
        output wire [255:0] linear_rd_data,input wire [7:0] linear_wr_en,
        input wire [71:0] linear_wr_addr,input wire [255:0] linear_wr_data,
    """
    linear_bind = """
        .linear_rd_en(linear_rd_en),.linear_rd_addr(linear_rd_addr),.linear_rd_data(linear_rd_data),
        .linear_wr_en(linear_wr_en),.linear_wr_addr(linear_wr_addr),.linear_wr_data(linear_wr_data),
    """
    pw_ports = """
        output wire feature_rd_en,output wire [17:0] feature_rd_addr,input wire [255:0] feature_data,
        output wire [7:0] feature_wr_en,output wire [71:0] feature_wr_addr,output wire [255:0] feature_wr_data,
    """
    pw_assign = """
        assign feature_rd_en=read_fire;
        assign feature_rd_addr={feature_address(odd_pixel,chunks_q,issue_k),feature_address(even_pixel,chunks_q,issue_k)};
    """
    pw_exports = """
        assign feature_wr_en[ram_id]=bulk_en && bulk_word && bulk_address<512;
        assign feature_wr_addr[ram_id*9+:9]=bulk_address[8:0];
        assign feature_wr_data[ram_id*32+:32]=bulk_value;
    """
    pw_old_ram = """
        c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)) u_ram (
            .clk(clk),.rd_en(read_fire),.rd_addr(feature_address(BANK==0 ? even_pixel : odd_pixel,chunks_q,issue_k)),
            .rd_data(feature_data[ram_id*32+:32]),
            .wr_en(bulk_en && bulk_word && bulk_address<512),
            .wr_addr(bulk_address[8:0]),.wr_data(bulk_value));
    """
    overlay_block = """
        wire [19:0] shared_read_addr;
        wire [5:0] active_rows=second_q ? second_rows : mapped_rows;
        wire row0_needed=active_rows[1:0]==0 || active_rows[3:2]==0 || active_rows[5:4]==0;
        for(genvar bank=0;bank<2;bank=bank+1)begin : g_shared_address
            wire [9:0] chosen=col1[0]==bank ? col1 : col0;
            assign shared_read_addr[bank*10+:10]=address_of(chosen,groups,group_id);
        end
        c1_r2_feature_overlay_ram u_overlay (
            .clk(clk),.rst(rst),
            .linear_rd_en(linear_rd_en),.linear_rd_addr(linear_rd_addr),.linear_rd_data(linear_rd_data),
            .linear_wr_en(linear_wr_en),.linear_wr_addr(linear_wr_addr),.linear_wr_data(linear_wr_data),
            .spatial_rd_en(read_fire && row0_needed),.spatial_rd_addr(shared_read_addr),.spatial_rd_data(bank_data[127:0]),
            .spatial_wr_en(bulk_en && bulk_row==0),.spatial_wr_addr(bulk_address),.spatial_wr_data(bulk_data));
    """
    window_assert = """
        if((linear_rd_en || |linear_wr_en) && (reserved_count!=0 || second_q || pending_valid || push || bulk_en))
            $fatal(1,"overlay window still owns shared feature storage");
    """
    graph_assert = 'if(state==CONFIG_CAPTURE && cache_valid!=0)$fatal(1,"overlay graph kept cache valid across layers");'
    engine_wires = """
        wire linear_rd_en;wire [17:0] linear_rd_addr;
        wire [255:0] linear_rd_data,linear_wr_data;
        wire [7:0] linear_wr_en;wire [71:0] linear_wr_addr;
    """
    engine_pw_bind = """
        .feature_rd_en(linear_rd_en),.feature_rd_addr(linear_rd_addr),.feature_data(linear_rd_data),
        .feature_wr_en(linear_wr_en),.feature_wr_addr(linear_wr_addr),.feature_wr_data(linear_wr_data),
    """
    def inverse(actual, old, new=''):
        old, new = tokens(old), tokens(new)
        need(actual.count(old) == 1, 'missing/duplicate exact overlay change: '+old[:100])
        return actual.replace(old, new)
    for old, new in NAMES.items():
        folder = 'efinity/' if old.startswith('c1_ti60') else 'rtl/r2/'
        expected, actual = read(folder+old+'.sv'), read(folder+new+'.sv')
        for a,b in NAMES.items():
            actual = actual.replace(b,a)
        actual = tokens(actual)
        if old == 'c1_r2_pw_lane_feeder':
            actual = inverse(actual,pw_ports)
            actual = inverse(actual,pw_assign,'wire [255:0] feature_data;')
            actual = inverse(actual,pw_exports,pw_old_ram)
        elif old == 'c1_r2_spatial_lane_feeder':
            actual = inverse(actual,linear_ports)
            actual = inverse(actual,linear_bind)
        elif old == 'c1_r2_bulk_window_store':
            actual = inverse(actual,linear_ports)
            actual = inverse(actual,overlay_block)
            actual = inverse(actual,'for(genvar slice_id=4;slice_id<12;slice_id=slice_id+1)',
                             'for(genvar slice_id=0;slice_id<12;slice_id=slice_id+1)')
            actual = inverse(actual,window_assert)
        elif old == 'c1_r2_cnn_compact_engine':
            actual = inverse(actual,engine_wires)
            actual = inverse(actual,engine_pw_bind)
            actual = inverse(actual,linear_bind)
        elif old == 'c1_r2_compact_pingpong_graph':
            actual = inverse(actual,graph_assert)
        need(actual == tokens(expected), 'unexpected change outside exact overlay edits: '+new)
    expected_sources = []
    for name in c21.SOURCES:
        for a,b in NAMES.items():
            name = name.replace(a,b)
        expected_sources.append(name)
    expected_sources.append('rtl/r2/c1_r2_feature_overlay_ram.sv')
    need(len(SOURCES) == len(set(SOURCES)) == 34 and set(SOURCES) == set(expected_sources), 'wrong overlay closure')
    for old, new, op, np in (
        ('tb_c1_r2_compact_host_system','tb_c1_r2_overlay_host_system',c21.PREFIX,PREFIX),
        ('tb_c1_r2_compact_recovery_system','tb_c1_r2_overlay_recovery_system',
         'C1_R2_COMPACT_RECOVERY_','C1_R2_OVERLAY_RECOVERY_'),
        ('tb_c1_r2_cnn_compact_engine','tb_c1_r2_cnn_overlay_engine',
         'C1_R2_COMPACT_OPERATOR_','C1_R2_OVERLAY_OPERATOR_')):
        expected = read('sim/'+old+'.sv').replace(old,new).replace(op,np)
        for a,b in NAMES.items():
            expected = expected.replace(a,b)
        need(tokens(expected) == tokens(read('sim/'+new+'.sv')), 'changed retained testbench: '+new)
    return dict(retained_c21=retained, compared_modules_and_probe=9, source_files=34,
                feature_storage_physically_shared=True, new_helper='c1_r2_feature_overlay_ram',
                refill_after_clobber_required=True, simultaneous_pool_persistence=False,
                external_abi_plan_compute_loader_writer_unchanged=True)


def ram_gate(text):
    prefix = 'C1_R2_OVERLAY_RAM_'
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError',text), 'failed overlay RAM unit')
    ps = [c18.c12.fields(x) for x in text.splitlines() if x.startswith(prefix+'PASS ')]
    need(len(ps)==1, 'missing RAM test')
    expected = dict(linear_reads=1536, spatial_reads=2560, linear_word_writes=6380,
                    spatial_writes=1537, resets=17, hold_checks=1536, byte_capacity=16384,
                    read_latency=1, alias_mapping_checked=1)
    need(ps[0] == expected, 'RAM coverage changed')
    negatives = [c18.c12.fields(x)['case'] for x in text.splitlines() if x.startswith(prefix+'NEGATIVE_PASS ')]
    need(negatives==list(range(1,9)), 'missing ownership negative control')
    need(text.count(prefix+'CLEAN temporary_simulator_removed=1')==1, 'RAM cleanup missing')
    return dict(**expected, ownership_negatives=8, independent_byte_array_reference=True)

def recovery_gate(text, keys, **kwargs):
    result = c19.matrix(text.replace('C1_R2_OVERLAY_RECOVERY_', c19.PREFIX), keys, **kwargs)
    # Reuse the transaction checker, not its historical implementation label.
    result.pop('actual_c18_production', None)
    return dict(result, actual_c22_candidate=True)


def same_trace(new, old):
    # Compare all actual source/output/CPU/frame/stage timing, not only PASS.
    n, o = c18.normalized(translated(new)), c18.normalized(old)
    for kind in ('REQUEST', 'CAPTURE', 'NN_START', 'FRAME', 'HOST', 'IDS', 'PASS', 'STAGE', 'PLAN'):
        need(c18.c12.rows(n, kind) == c18.c12.rows(o, kind), 'overlay/C18 trace mismatch: '+kind)
    return dict(actual_event_kinds=9, cycles_and_traffic_identical=True, fps_gain_claimed=False)


def operator_gate(text):
    prefix = 'C1_R2_OVERLAY_OPERATOR_'
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
    folder = Path('logs/r2_overlay_host_xsim_runs')/run
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
         ('C1_TI60_R2_OVERLAY_HOST96_MAP_PNR_PASS','Titanium','Ti60F225','map+pnr'), 'wrong/incomplete physical run')
    private = Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_overlay_host96_'+run)
    need(not private.exists() and '--timing_model I3 ' in read(folder/'efinity.pnr.stdout.tail.log'), 'wrong grade/cleanup')
    r, t, metrics = m['pnr_resources'], m['timing'], m['metrics']
    need((r['memory_blocks_used'],r['dsp_blocks_used']) == (134,112) and 0 < r['xlr_cells_used'] < 41620, 'resource saving lost/pruned')
    need(metrics['primitive_counts'].get('EFX_DSP24') == 96 and metrics['primitive_counts'].get('EFX_DSP48') == 16, 'wrong MAC/quantizer')
    hierarchy = set(metrics['module_rows']+metrics.get('module_focus_rows', []))
    for name in ('+u_host:c1_r2_overlay_host_system', '+u_cpu_adapter:c1_r2_cpu_axi_adapter',
                 '+u_system:c1_r2_video_overlay_system', '+u_cnn:c1_r2_overlay_rgbx_axi_graph',
                 '+u_graph:c1_r2_overlay_pingpong_graph', '+u_operator:c1_r2_cnn_overlay_engine',
                 '+u_weights:c1_r2_weight_store6(PACKED=1)', '+u_plan:c1_r2_microstyle_plan',
                 '+u_overlay:c1_r2_feature_overlay_ram'):
        need(sum(name in row for row in hierarchy) == 1, 'missing physical hierarchy: '+name)
    need(t['final_slack_ns'] >= 0 and t['final_hold_slack_ns'] >= 0 and
         abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002, '150MHz setup/hold failure')
    return dict(run=run, resources=r, timing=t, ram_saved=16, xlr_saved=41620-r['xlr_cells_used'],
                scope='pin-reduced complete host/CNN/video/fabric; no CPU IP/PHY/ISP/CDC/board IO')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--pnr-run', default='c22_overlay_host96_i3_20260913_a')
    p.add_argument('--native-run')
    p.add_argument('--require-15fps', action='store_true')
    a = p.parse_args()
    need(not a.require_15fps or a.native_run, 'native FPS cannot be inherited')
    emit = lambda name, value: print('C1_R2_C22_'+name+' '+json.dumps(value, separators=(',', ':')), flush=True)
    emit('SOURCE_GATE_PASS', source_gate())
    emit('RAM_UNIT_GATE_PASS', ram_gate(read('logs/r2_overlay_ram_unit_20260913_a.log')))
    main_text = read('logs/r2_overlay_host_matrix_20260913_a.log')
    emit('SYSTEM_GATE_PASS', c18.matrix(translated(main_text), 'microstyle24'))
    emit('RETAINED_EQUIVALENCE_PASS', same_trace(main_text, read('logs/r2_planned_host_matrix_20260913_a.log')))
    variant = read('logs/r2_overlay_host_variant_20260913_a.log')
    emit('VARIANT_GATE_PASS', c18.matrix(translated(variant), 'drop_res1'))
    emit('VARIANT_EQUIVALENCE_PASS', same_trace(variant, read('logs/r2_planned_host_variant_20260913_a.log')))
    operator = read('logs/r2_overlay_operator_20260913_a.log')
    emit('OPERATOR_GATE_PASS', operator_gate(operator))
    emit('RAM_NEGATIVE_GATE_PASS', c18.negative(translated(read('logs/r2_overlay_host_negative_20260913_a.log'))))
    fault = read('logs/r2_overlay_recovery_matrix_20260913_a.log')
    emit('RECOVERY_GATE_PASS', recovery_gate(fault, {(8,8,s,m,0) for s in (0,1) for m in range(1,5)}))
    debt = read('logs/r2_overlay_recovery_debt_20260913_a.log')
    emit('RECOVERY_DEBT_GATE_PASS', recovery_gate(debt, {(128,4,1,4,0)}, hold_cycles=256, min_cnn_debt=2))
    emit('XSIM_GATE_PASS', xsim('c22_overlay_host_xsim_12x12_20260913_a'))
    emit('XSIM_EQUIVALENCE_PASS', same_trace(read('logs/r2_overlay_host_xsim_runs/c22_overlay_host_xsim_12x12_20260913_a/result.log'),
                                         read('logs/r2_planned_host_xsim_runs/c18_planned_host_xsim_12x12_20260913_a/result.log')))
    for old, new in [('reset_modes=6','reset_modes=0'), ('size=8192','size=8160'), ('packed_weights=1','packed_weights=0')]:
        need(old in operator, 'missing operator mutation target')
        try:
            operator_gate(operator.replace(old,new,1))
        except ValueError:
            pass
        else:
            raise ValueError('operator evidence mutation accepted')
    ram = read('logs/r2_overlay_ram_unit_20260913_a.log')
    for old,new in [('read_latency=1','read_latency=2'), ('NEGATIVE_PASS case=8','OMITTED case=8')]:
        need(old in ram, 'missing RAM mutation target')
        try:
            ram_gate(ram.replace(old,new,1))
        except ValueError:
            pass
        else:
            raise ValueError('RAM evidence mutation accepted')
    emit('AUDIT_NEGATIVE_PASS', dict(operator_mutations_rejected=3, ram_mutations_rejected=2))
    emit('PHYSICAL_GATE_PASS', physical(a.pnr_run))
    if a.native_run:
        result = xsim(a.native_run, True)
        emit('NATIVE_GATE_PASS', result)
        if a.require_15fps:
            c18.c12.require_throughput(result, 4)


if __name__ == '__main__':
    main()
