"""Independently check bounded mapped host CDC and routed timing evidence.

Passing is limited to the host CDC endpoints/constraints in this resource probe,
not real CPU execution, board reset, JTAG, PLL relationships or DDR PHY signoff.
"""
import argparse
import json
from pathlib import Path
import re
from check_r2_camera_physical_cdc import ROOT, ff_blocks, read
from c39_joint_cdc_projects import NAME, verify
from efinity_map_top_row import parse_top_row

PREFIX = 'u_host/u_system/'
INGRESS = PREFIX + 'u_ingress/'
FIFO = INGRESS + 'u_fifo/'
SNAPSHOT = PREFIX + 'u_camera_snapshot/'


def need(condition, message):
    if not condition:
        raise ValueError(message)


def inspect_mapped(text, core_wire, tag_bits):
    blocks = ff_blocks(text)
    need(tag_bits in (31, 32), 'unsupported explicit tag profile')
    sync_count = 0

    def pair(first, second, source, clock):
        nonlocal sync_count
        one, two = blocks[first + '~FF'], blocks[second + '~FF']
        for cell in (one, two):
            need(re.search(r'async_reg="true"', cell['attrs'], re.I), 'synchronizer attribute lost')
            need(cell['pins']['CLK'] == clock, 'synchronizer clock changed')
        need(one['pins']['D'] == source, 'first stage source changed: ' + first)
        need(two['pins']['D'] == one['pins']['Q'], 'logic or wrong net between synchronization stages')
        sync_count += 2

    for side, clock in (('wr', core_wire), ('rd', 'cam_clk')):
        for bit in range(10):
            source = FIFO + side + ('_bin[9]' if bit == 9 else f'_gray[{bit}]')
            pair(FIFO + f'{side}_sync1[{bit}]', FIFO + f'{side}_sync2[{bit}]', source, clock)
    for stem, source in (('req', 'request_q'), ('done', 'source_done'), ('bad', 'source_bad')):
        pair(INGRESS + stem + '_sync1', INGRESS + stem + '_sync2', INGRESS + source, core_wire)
    for stem, source in (('ack', 'ack_q'), ('enable', 'enable_source_q'), ('cancel', 'cancel_source_q')):
        pair(INGRESS + stem + '_sync1', INGRESS + stem + '_sync2', INGRESS + source, 'cam_clk')
    pair(SNAPSHOT + 'req_sync1_q', SNAPSHOT + 'req_sync2_q', SNAPSHOT + 'request_q', core_wire)
    pair(SNAPSHOT + 'ack_sync1_q', SNAPSHOT + 'ack_sync2_q', SNAPSHOT + 'acknowledge_q', 'cam_clk')
    need(sync_count == 56, 'incomplete synchronization stage inventory')
    need(not [n for n in blocks if n.startswith(PREFIX) and '_sync' in n and '~FF_rt_' in n],
         'retimed synchronization stage requires new review')
    for signal in ('enable_source_q', 'cancel_source_q'):
        need(blocks[INGRESS + signal + '~FF']['pins']['CLK'] == core_wire,
             'control signal is not registered in source clock')

    def names(pattern):
        return {n for n in blocks if re.fullmatch(pattern, n)}
    source_tags = names(re.escape(INGRESS) + r'source_tag\[\d+\]~FF')
    destination_tags = names(re.escape(PREFIX) + r'capture_tag\[\d+\]~FF')
    bits = range(1 if tag_bits == 31 else 0, 32)
    need(source_tags == {INGRESS + f'source_tag[{i}]~FF' for i in bits}, 'wrong source tag bit identities')
    need(destination_tags == {PREFIX + f'capture_tag[{i}]~FF' for i in bits}, 'wrong destination tag bit identities')
    snapshot_sources = names(re.escape(SNAPSHOT) + r'payload_q\[\d+\]~FF')
    snapshot_destinations = names(r'(?:camera_seen|camera_skipped|camera_fifo_peak|u_host/u_system/camera_snapshot)\[\d+\]~FF')
    codes = names(r'(?:u_host/u_system/u_ingress/failed_code|camera_result_code)\[\d+\]~FF')
    need(len(snapshot_sources) == len(snapshot_destinations) == 75 and len(codes) == 6,
         'held-bundle bit counts changed')
    for name in source_tags | snapshot_sources:
        need(blocks[name]['pins']['CLK'] == 'cam_clk', 'held bundle source clock changed')
    for name in destination_tags | snapshot_destinations | codes:
        need(blocks[name]['pins']['CLK'] == core_wire, 'held bundle destination clock changed')
    cam_ends = {FIFO + f'wr_sync1[{i}]~FF|D' for i in range(10)}
    cam_ends |= {INGRESS + s + '_sync1~FF|D' for s in ('req', 'done', 'bad')}
    cam_ends |= {SNAPSHOT + 'req_sync1_q~FF|D'}
    cam_ends |= {name + '|D' for name in destination_tags | snapshot_destinations | codes}
    core_ends = {FIFO + f'rd_sync1[{i}]~FF|D' for i in range(10)}
    core_ends |= {INGRESS + s + '_sync1~FF|D' for s in ('ack', 'enable', 'cancel')}
    core_ends |= {SNAPSHOT + 'ack_sync1_q~FF|D'}
    need(len(cam_ends) == 95 + tag_bits and len(core_ends) == 14, 'incorrect endpoint totals')
    return dict(mapped_ff=len(blocks), sync_ff=sync_count, tag_bits=tag_bits,
                camera_to_core=cam_ends, core_to_camera=core_ends)


def inspect_timing(reports, inventory):
    result = {}
    for name in ('core_setup', 'core_hold', 'camera_setup', 'camera_hold', 'camera_to_core', 'core_to_camera'):
        report = reports[name]
        slacks = [float(v) for v in re.findall(r'^Slack\s*:\s*([-+\d.]+) ns', report, re.M)]
        delays = [float(v) for v in re.findall(r'^Data Path Delay\s*:\s*([-+\d.]+) ns', report, re.M)]
        need(slacks and len(slacks) == len(delays), 'missing path/slack/delay fields: ' + name)
        need(min(slacks) >= 0, 'routed timing violation: ' + name)
        if name in ('camera_to_core', 'core_to_camera'):
            ends = re.findall(r'^Path End\s*:\s*(\S+)\s*$', report, re.M)
            need(set(ends) == inventory[name] and len(ends) == len(inventory[name]),
                 'missing/extra actual crossing endpoints: ' + name)
            need(max(delays) < 5.0, 'actual crossing data flight exceeds 5 ns')
            need(report.count('Timing Exception : Max Delay Path 5.000 ns') == len(ends),
                 'endpoint data bound is masked or missing')
        result[name] = dict(paths=len(slacks), min_slack_ns=min(slacks), max_data_delay_ns=max(delays))
    bus = reports['bus_setup']
    skew = [tuple(map(float, row)) for row in re.findall(
        r'^\[get_pins .*\|\s*Slow\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([-+\d.]+)\s*$', bus, re.M)]
    need(len(skew) == 2 and all(req == 1 and 0 <= delay < 1 and slack > 0 for req, delay, slack in skew),
         'actual Gray bus skew not proven')
    counts = re.findall(r'^Endpoints: (\d+)$', bus, re.M)
    bits = {(side, int(bit)) for side, bit in re.findall(r'u_ingress/u_fifo/(wr|rd)_sync1\[(\d+)\]~FF\|D', bus)}
    need(len(counts) == 2 and all(n in ('9', '10') for n in counts) and
         bits == {(side, bit) for side in ('wr', 'rd') for bit in range(10)}, 'Gray skew bit inventory differs')
    result['gray_setup_skew_ns'] = [row[1] for row in skew]
    return result


def check(run):
    need(re.fullmatch('[A-Za-z0-9_-]+', run), 'invalid run name')
    verify()
    folder = ROOT / 'logs/efinity_resource_runs' / run
    status = json.loads(read(folder / 'status.json'))
    summary = json.loads(read(folder / 'summary.json'))
    need(status['run_id'] == run and status['state'] == 'complete' and status['exit_code'] == 0 and
         status['worker_in_windows_job'] is False and status['run_directory_present'] is False and
         not Path(status['run_directory']).exists(), 'joint run not complete/isolated/clean')
    # Efinity abbreviates the repeated module name when the root name is long.
    # Re-parse retained actual rows; never interpret missing FF/RAM fields as zero.
    top_counts = parse_top_row(summary['metrics']['module_rows'], NAME)
    need(summary['pnr_exit_code'] == 0 and top_counts['luts'] == summary['metrics']['le'] and
         top_counts['rams'] == summary['pnr_resources']['memory_blocks_used'] and
         top_counts['dsp_mults'] == summary['pnr_resources']['dsp_blocks_used'],
         'inconsistent actual MAP/PNR root statistics')
    timing = summary['timing']
    need(timing['final_source'] == 'final_sta_clock_relationship_table' and
         timing['final_slack_ns'] is not None and timing['final_slack_ns'] >= 0 and
         timing['final_hold_slack_ns'] is not None and timing['final_hold_slack_ns'] >= 0,
         'joint final STA table not passing')
    sta = read(folder / 'cdc_sta.stdout.log')
    expected_counts = dict(wr_gray=10, rd_gray=10, wr_first=10, rd_first=10, wr_second=10, rd_second=10,
        cam_control=4, core_control=4, tag_source=32, tag_destination=32, tag_lsb_present=2,
        code_source=3, code_destination=6, snapshot_source=75, snapshot_destination=75, source_controls=2)
    rows = re.findall(r'^C27_MATCH (\w+)=(\d+) expected=(\d+)$', sta, re.M)
    need(len(rows) == len(expected_counts) and len({row[0] for row in rows}) == len(rows), 'pin audit checks missing/duplicated')
    need(all(name in expected_counts and int(actual) == int(expected) == expected_counts[name]
             for name, actual, expected in rows), 'pin audit differs from explicit joint geometry')
    need(len(re.findall(r'^C27_AUDIT_PASS$', sta, re.M)) == 1, 'mandatory STA extraction incomplete')
    inventory = inspect_mapped(read(folder / 'cdc_mapped_registers.txt'), 'core_clk', 32)
    reports = {name: read(folder / ('c27_' + name + '.rpt')) for name in
               ('core_setup', 'core_hold', 'camera_setup', 'camera_hold', 'camera_to_core', 'core_to_camera', 'bus_setup')}
    paths = inspect_timing(reports, inventory)
    classification = json.loads(read(folder / 'cdc_classification_status.json'))
    return dict(run=run, mapped_host_CDC_and_timing_pass=True, synchronizer_ff=inventory['sync_ff'],
        camera_to_core_endpoints=len(inventory['camera_to_core']), core_to_camera_endpoints=len(inventory['core_to_camera']),
        tag_bits=32, paths=paths, tool_classification_complete=classification.get('complete') is True,
        resource_xlr=summary['pnr_resources']['xlr_cells_used'], map_metrics=top_counts, temporary_removed=True,
        full_physical_CPU_DDR_JTAG_reset_signoff=False, board_signoff=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    args = parser.parse_args()
    print('C39_JOINT_CDC_EVIDENCE_PASS ' + json.dumps(check(args.run), separators=(',', ':')), flush=True)
