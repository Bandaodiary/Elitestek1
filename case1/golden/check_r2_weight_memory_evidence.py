"""C20 component evidence and cross-project capacity warning, not a board gate."""
from pathlib import Path
import json
import os
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
VENDOR = Path('D:/contest/Ti60F225_DemoBoard_v4')
PREFIX = 'C1_R2_WEIGHT_REPLICA_'
UNIT = ROOT/'logs/r2_weight_replica_unit_20260913_d.log'


def need(ok, message):
    if not ok:
        raise AssertionError(message)


def read(path):
    return path.read_text(encoding='utf-8-sig')


def fields(line):
    return {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)}


def unit(text):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError', text), 'failed unit')
    passes = [fields(x) for x in text.splitlines() if x.startswith(PREFIX+'PASS ')]
    need(len(passes) == 2 and [x['packed'] for x in passes] == [0, 1], 'missing/duplicate variant')
    expected = dict(reads=2920, loads=3670, resets=11, hold_checks=2064, logical_banks=8,
                    physical_replicas=6, legal_rows=48, weight_words=1536, checked_weight_words=70080,
                    independent_model=1, retained_baseline=1, read_latency=1, arbitrary_word_updates=1)
    for p in passes:
        need(all(p.get(k) == v for k, v in expected.items()), 'wrong numerical coverage/contract')
    negatives = [fields(x) for x in text.splitlines() if x.startswith(PREFIX+'NEGATIVE_PASS ')]
    need([(p.get('packed'), p.get('case')) for p in negatives] ==
         [(p, c) for p in (0, 1) for c in range(1, 8)], 'missing/duplicate negative')
    need(text.count(PREFIX+'CLEAN temporary_simulator_removed=1') == 1, 'missing cleanup')
    return passes


def hierarchy(path, names):
    # Only the first hierarchical resource table, streamed locally. Do not
    # return full vendor reports or count nested children twice.
    rows = {}
    with path.open(encoding='utf-8-sig') as f:
        for number, line in enumerate(f, 1):
            if number > 600:
                break
            m = re.match(r'^\|\s+\+([\w]+)\s+\|\s*([\d.]+)\([^)]*\)\s*\|\s*(\d+)\([^)]*\)\s*\|\s*(\d+)\(', line)
            if m and m[1] in names and m[1] not in rows:
                rows[m[1]] = dict(xlr=float(m[2]), ram=int(m[3]), dsp=int(m[4]), line=number)
                if rows.keys() == names:
                    break
    need(rows.keys() == names, 'missing primary resource row: '+str(path))
    return rows


def physical(run, ram):
    folder = ROOT/'logs/efinity_resource_runs'/run
    status = json.loads(read(folder/'status.json'))
    summary = json.loads(read(folder/'summary.json'))
    need(status['state'] == summary['state'] == 'complete' and status['exit_code'] == 0 and
         summary['pnr_exit_code'] == 0 and summary['flow'] == 'map+pnr', 'unfinished PNR')
    need(summary['device'] == 'Ti60F225', 'wrong device')
    r, t = summary['pnr_resources'], summary['timing']
    need((r['memory_blocks_used'], r['memory_blocks_total'], r['dsp_blocks_used']) == (ram, 256, 0), 'wrong RAM/DSP')
    need(t['final_slack_ns'] >= 0 and t['final_hold_slack_ns'] >= 0, 'probe internal timing failed')
    return dict(run=run, ram=ram, xlr=r['xlr_cells_used'], setup=t['final_slack_ns'],
                hold=t['final_hold_slack_ns'], seconds=status['elapsed_seconds'])


def xsim(run, expected):
    folder = ROOT/'logs/r2_weight_replica_xsim_runs'/run
    s = json.loads(read(folder/'status.json'))
    need(s['state'] == 'complete' and s['exit_code'] == 0 and s['packed'] == expected['packed'], 'xsim incomplete')
    need(s['worker_in_windows_job'] is False and s['simulator_directory_present'] is False and
         not Path(s['run_directory']).exists(), 'xsim job/cleanup contract')
    markers = read(folder/'result.log').splitlines()
    need(len(markers) == 1 and markers[0].startswith(PREFIX+'PASS ') and fields(markers[0]) == expected,
         'xsim/Icarus coverage mismatch')
    return dict(run=run, seconds=s['elapsed_seconds'], job=False,
                retained_bytes=sum(p.stat().st_size for p in folder.iterdir() if p.is_file()))


def source_contract():
    def tokens(s):
        return re.sub(r'\s+', '', re.sub(r'//[^\n]*', '', s))
    old = read(ROOT/'rtl/r2/c1_r2_weight_store8.sv')
    new = read(ROOT/'rtl/r2/c1_r2_weight_store6.sv')
    old_affine = old[old.index('    for(genvar bank='):old.index('    // Flattened')]
    new_affine = new[new.index('    for(genvar bank='):new.index('    // Flatten indices')]
    need(tokens(old_affine) == tokens(new_affine), 'affine contract changed')
    closure = [x.attrib['name'] for x in ET.parse(ROOT/'efinity/c1_ti60_r2_planned_host96.xml').iter()
               if x.tag.endswith('design_file')]
    need(any('c1_r2_weight_store8.sv' in s for s in closure) and
         not any('weight_store6' in s or 'weight_pair' in s or 'weight_asym' in s for s in closure),
         'experimental storage entered retained C18 closure')
    for suffix in ('sdp', 'replica', 'replica_packed'):
        name = 'c1_ti60_r2_weight_'+suffix
        need('create_clock -name core_clk -period 6.666 [get_ports clk]' in read(ROOT/f'efinity/{name}.sdc'),
             'different probe clock target')
    return dict(affine_source_equal=True, c18_unmodified_selection=True, external_load_format_unchanged=True,
                six_lane_read_interface_requires_integration=True, board_or_fps_gate=False)


def main():
    raw = read(UNIT)
    passes = unit(raw)
    mutations = [raw.replace('read_latency=1', 'read_latency=2', 1),
                 raw.replace('checked_weight_words=70080', 'checked_weight_words=1', 1),
                 raw.replace(PREFIX+'NEGATIVE_PASS packed=1 case=7', 'removed'),
                 raw.replace(PREFIX+'CLEAN temporary_simulator_removed=1', 'removed'),
                 raw+'\n'+next(x for x in raw.splitlines() if x.startswith(PREFIX+'PASS '))]
    for mutant in mutations:
        try:
            unit(mutant)
        except AssertionError:
            continue
        raise AssertionError('audit accepted corrupted coverage')
    soc = hierarchy(VENDOR/'08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/outflow/ddr_demo_ti60-hierarchical_stats.rpt',
                    {'u_sapphire_soc', 'u_ddr3_top'})
    video = hierarchy(VENDOR/'10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v1/outflow/ti60f225_oob-hierarchical_stats.rpt',
                      {'inst_efx_csi2_rx', 'debayer_top'})
    need((soc['u_sapphire_soc']['ram'], soc['u_ddr3_top']['ram'], video['inst_efx_csi2_rx']['ram'],
          video['debayer_top']['ram']) == (43, 22, 36, 4), 'primary platform resources changed')
    probes = [physical('c20_weight_sdp_i3_20260913_a', 64),
              physical('c20_weight_replica_i3_20260913_a', 48),
              physical('c20_weight_replica_packed_i3_20260913_a', 42)]
    failed = json.loads(read(ROOT/'logs/efinity_resource_runs/c20_weight_tdp_i3_20260913_a/status.json'))
    need(failed['state'] == 'failed' and 'EFX-0680' in failed['message'], 'lost rejected TDP evidence')
    sims = [xsim('c20_weight_replica_xsim_word_20260913_a', passes[0]),
            xsim('c20_weight_replica_xsim_packed_20260913_a', passes[1])]
    c18 = json.loads(read(ROOT/'logs/efinity_resource_runs/c18_planned_host96_i3_20260913_a/summary.json'))['pnr_resources']
    need(c18['memory_blocks_used'] == 172, 'changed C18 resource basis')
    essential = sum(soc[n]['ram'] for n in soc)+video['inst_efx_csi2_rx']['ram']
    projection = dict(retained_host_ram=172, soc_and_csi_ram=essential, old_sum=172+essential,
                      candidate_host_ram_if_delta_survives=172-64+42,
                      candidate_sum_with_debayer_if_delta_survives=172-64+42+essential+video['debayer_top']['ram'],
                      jointly_implemented=False, resize_cdc_and_board_glue_excluded=True)
    cleanup = []
    for suffix, run in [('sdp', 'c20_weight_sdp_i3_20260913_a'), ('tdp', 'c20_weight_tdp_i3_20260913_a'),
                        ('replica', 'c20_weight_replica_i3_20260913_a'),
                        ('replica_packed', 'c20_weight_replica_packed_i3_20260913_a')]:
        private = Path(os.environ['TEMP'])/f'c1_efinity_resource_c1_ti60_r2_weight_{suffix}_{run}'
        need(not private.exists(), 'private EDA tree remains: '+str(private))
        folder = ROOT/'logs/efinity_resource_runs'/run
        cleanup.append(dict(run=run, private_removed=True,
                            retained_bytes=sum(p.stat().st_size for p in folder.iterdir() if p.is_file())))
    result = dict(source=source_contract(), unit=passes, audit_mutations_rejected=len(mutations),
                  primary_soc=soc, primary_video=video, probes=probes, xsim=sims, projection=projection,
                  eda_cleanup=cleanup, rejected_tdp_not_integrated=True)
    print('C1_R2_WEIGHT_MEMORY_EVIDENCE '+json.dumps(result, ensure_ascii=False, separators=(',', ':')))
    print('C1_R2_WEIGHT_MEMORY_GATE_PASS component_only=1 packed_ram=42 baseline_ram=64 '
          'board_fit_proved=0 new_system_fps_proved=0 retained_c18=1')


if __name__ == '__main__':
    main()
