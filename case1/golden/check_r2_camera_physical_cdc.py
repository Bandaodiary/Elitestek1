"""C27 bounded evidence audit. Successful audit is NOT physical CDC sign-off."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RUNS = ROOT / 'logs/efinity_resource_runs'


def need(ok, message):
    if not ok:
        raise AssertionError(message)


def read(path):
    need(path.is_file() and path.stat().st_size < 2_000_000, 'missing/oversize '+str(path))
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig').replace('\r\n', '\n')


def run(name, terminal='complete'):
    directory = RUNS / name
    status = json.loads(read(directory / 'status.json'))
    need(status['state'] == terminal, 'not expected terminal status: '+name)
    if terminal == 'complete':
        need(status['exit_code'] == 0, 'nonzero successful status')
    artifacts = json.loads(read(directory / 'cdc_artifact_names.json'))
    # Artifact names also anchor the unique private directory without retaining it.
    for item in artifacts:
        path = item.get('FullName', item.get('path', ''))
        if path:
            need(not Path(path).exists(), 'terminal private artifact still exists')
            need(not Path(path).parent.parent.exists(), 'terminal private directory still exists')
    return directory, status


def ff_blocks(text):
    result = {}
    rx = r'^\s*EFX_FF\s+\\(\S+)\s+\((.*?)\)\s*/\*([^*]*(?:\*(?!/)[^*]*)*)\*/\s*;'
    for match in re.finditer(rx, text, re.M | re.S):
        name, body, attrs = match.groups()
        need('EFX_FF' not in body, 'malformed/truncated retained FF block')
        pins = {k: re.sub(r'\s+', '', v).lstrip('\\')
                for k, v in re.findall(r'\.(D|Q|CLK)\(([^()]*)\)', body)}
        need(set(pins) == {'D', 'Q', 'CLK'}, 'missing FF connection '+name)
        block = {'pins': pins, 'attrs': attrs}
        if name in result:
            need(result[name] == block, 'conflicting duplicate FF excerpt '+name)
        result[name] = block
    need(result, 'empty mapped FF inventory')
    return result


def fifo_inventory(text, prefix):
    blocks = ff_blocks(text)
    for side in ('wr', 'rd'):
        for bit in range(10):
            one = blocks[f'{prefix}/{side}_sync1[{bit}]~FF']
            two = blocks[f'{prefix}/{side}_sync2[{bit}]~FF']
            for cell in (one, two):
                need(re.search(r'async_reg="true"', cell['attrs'], re.I), 'lost async_reg')
            need(two['pins']['D'] == one['pins']['Q'], 'logic inserted between primary sync FFs')
            source = f'{prefix}/{side}_'+('bin[9]' if bit == 9 else f'gray[{bit}]')
            need(one['pins']['D'] == source, 'wrong Gray source mapping')
            clock = 'clk' if side == 'wr' else 'cam_clk'
            need(one['pins']['CLK'] == two['pins']['CLK'] == clock, 'wrong sync clock')
    derived = [n for n in blocks if n.startswith(prefix+'/') and re.search(r'_sync[12].*~FF_rt_', n)]
    return {'retained_ff': len(blocks), 'primary_sync_ff': 40, 'retimed_sync_ff': len(derived)}


def closure_gate():
    ns = {'e': 'http://www.efinixinc.com/enf_proj'}
    def sources(name):
        p = ROOT / 'efinity' / (name+'.xml')
        return [(p.parent / e.attrib['name']).resolve()
                for e in ET.parse(p).findall('.//e:design_file', ns)]
    old = sources('c1_ti60_r2_camera_host96')
    new = sources('c1_ti60_r2_camera_cdc96')
    old_top = ROOT/'efinity/c1_ti60_r2_camera_host96.sv'
    new_top = ROOT/'efinity/c1_ti60_r2_camera_cdc96.sv'
    need(len(old) == len(new) == 45 and old_top in old and new_top in new and
         [p for p in old if p != old_top] == [p for p in new if p != new_top], 'C26 production closure changed')
    need(all(p.is_file() for p in new), 'missing production source')
    def rtl(s):
        return re.sub(r'\s+', '', re.sub(r'//[^\n]*', '', s))
    need(rtl(read(old_top)).replace('c1_ti60_r2_camera_host96', 'C27_TOP') ==
         rtl(read(new_top)).replace('c1_ti60_r2_camera_cdc96', 'C27_TOP'), 'changed probe logic')
    sdc = read(ROOT / 'efinity/c1_ti60_r2_camera_cdc96.sdc')
    actual = '\n'.join(x for x in sdc.splitlines() if x.strip() and not x.lstrip().startswith('#'))
    need('set_clock_groups' not in actual, 'blanket asynchronous group masks max delay')
    need(all('-hold' in line for line in actual.splitlines() if 'set_false_path' in line), 'setup false path')
    need(actual.count('set_bus_skew ') == 2 and actual.count('set_max_delay ') == 7, 'incomplete crossing constraints')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pnr-run')
    args = parser.parse_args()
    closure_gate()
    print('C27_SOURCE_AND_TARGETED_CONSTRAINTS_PASS production_sources=44 changed=0')
    full, _ = run('c27_camera_cdc96_map_20260913_a')
    base = fifo_inventory(read(full/'cdc_mapped_registers.txt'), 'u_host/u_system/u_ingress/u_fifo')
    need(base['retimed_sync_ff'] == 2, 'expected C26 retiming finding changed')
    pair, _ = run('c27_fifo_attribute_map_20260913_a')
    pair_text = read(pair/'cdc_mapped_registers.txt')
    for prefix in ('u_ingress_upper', 'u_ingress_lower'):
        need(fifo_inventory(pair_text, prefix)['retimed_sync_ff'] == 4, 'case alone not proven ineffective')
    results = {}
    for variant in ('plain', 'keep'):
        folder, _ = run(f'c27_fifo_single_{variant}_map_20260913_a')
        branch = 'g_plain' if variant == 'plain' else 'g_keep'
        results[variant] = fifo_inventory(read(folder/'cdc_mapped_registers.txt'), f'u_probe/{branch}.u_ingress')
    need(results['plain']['retimed_sync_ff'] == 3 and results['keep']['retimed_sync_ff'] == 0,
         'independent syn_keep comparison failed')
    # Exact behavioral identity of the test clone; only name + attributes differ.
    original = read(ROOT/'rtl/r2/c1_r2_async_pixel_fifo.sv').strip()
    clone = read(ROOT/'efinity/c1_ti60_cdc_fifo_keep_probe.sv')
    clone = clone[clone.index('`timescale'):].strip()
    expected = original.replace('module c1_r2_async_pixel_fifo #', 'module c27_fifo_keep #').replace(
        '(* ASYNC_REG="TRUE" *)', '(* async_reg="true", syn_keep="true" *)')
    need(clone == expected, 'syn_keep experiment changed behavior')
    print('C27_RETIMING_FINDING_AND_ISOLATED_FIX_PASS '+json.dumps(results, separators=(',', ':')))
    regression = read(ROOT/'logs/c27_fifo_guard_regression_20260913_a.log')
    cases = re.findall(r'^C27_FIFO_KEEP_PASS depth=(\d+) wh=(\d+) rh=(\d+) words=(\d+) epochs=3 held=(\d+) full_cycles=(\d+) capacity=(\d+)$', regression, re.M)
    need(len(cases) == 10, 'guard FIFO missing regression cases')
    seen = set()
    total = 0
    for row in cases:
        depth, wh, rh, words, held, full_cycles, capacity = map(int, row)
        need(words == 3*(depth*3+137) and held > 0 and full_cycles > 0 and capacity == depth+1,
             'guard FIFO coverage/count mismatch')
        seen.add((depth, wh, rh))
        total += words
    need(seen == {(d, w, r) for d in (2,4,32,512,1024) for w,r in ((7,5),(5,11))}, 'duplicate/missing FIFO case')
    need(regression.count('C27_FIFO_KEEP_CLEAN temporary_simulator_removed=1') == 1 and
         not list((ROOT/'sim').glob('c27_fifo_keep_*')), 'FIFO temporary cleanup incomplete')
    print(f'C27_FIFO_GUARD_DIGITAL_PASS cases=10 epochs=30 words={total} temporary_removed=1')
    # Negative control: removing one MSB synchronizer must be rejected.
    text = read(full/'cdc_mapped_registers.txt')
    mutated = text.replace('u_fifo/wr_sync1[9]~FF', 'u_fifo/REMOVED[9]~FF')
    try:
        fifo_inventory(mutated, 'u_host/u_system/u_ingress/u_fifo')
    except (AssertionError, KeyError):
        pass
    else:
        raise AssertionError('missing-MSB negative control accepted')
    print('C27_MISSING_MSB_NEGATIVE_CONTROL_PASS')
    # A familiar stage-2 name must not hide a combinational input.
    mutated = text.replace('.D(\\u_host/u_system/u_ingress/u_fifo/wr_sync1 [0])',
                           '.D(\\u_host/u_system/u_ingress/u_fifo/COMBINATIONAL [0])')
    need(mutated != text, 'stage-2 negative control did not mutate evidence')
    try:
        fifo_inventory(mutated, 'u_host/u_system/u_ingress/u_fifo')
    except (AssertionError, KeyError):
        pass
    else:
        raise AssertionError('stage-2 cone negative control accepted')
    print('C27_STAGE2_CONNECTION_NEGATIVE_CONTROL_PASS')
    if args.pnr_run:
        folder, status = run(args.pnr_run)
        sta = read(folder/'cdc_sta.stdout.log')
        need(len(re.findall(r'^C27_MATCH .* expected=', sta, re.M)) == 14, 'missing post-route pin checks')
        need(re.findall(r'^C27_AUDIT_PASS$', sta, re.M) == ['C27_AUDIT_PASS'], 'incomplete STA extraction')
        report_summary = {}
        mapped = ff_blocks(read(folder/'cdc_mapped_registers.txt'))
        prefix = 'u_host/u_system/'
        cam_ends = {f'{prefix}u_ingress/u_fifo/wr_sync1[{i}]~FF|D' for i in range(10)}
        cam_ends |= {prefix+'u_ingress/'+s+'~FF|D' for s in ('req_sync1','done_sync1','bad_sync1')}
        cam_ends |= {prefix+'u_camera_snapshot/req_sync1_q~FF|D'}
        dest_rx = r'^(?:u_host/u_system/capture_tag|u_host/u_system/u_ingress/failed_code|camera_result_code|camera_seen|camera_skipped|camera_fifo_peak|u_host/u_system/camera_snapshot)\[\d+\]~FF$'
        cam_ends |= {n+'|D' for n in mapped if re.match(dest_rx, n)}
        core_ends = {f'{prefix}u_ingress/u_fifo/rd_sync1[{i}]~FF|D' for i in range(10)}
        core_ends |= {prefix+'u_ingress/'+s+'~FF|D' for s in ('ack_sync1','enable_sync1','cancel_sync1')}
        core_ends |= {prefix+'u_camera_snapshot/ack_sync1_q~FF|D'}
        need(len(cam_ends) == 127 and len(core_ends) == 14, 'incorrect expected CDC endpoint inventory')
        for name in ('core_setup', 'core_hold', 'camera_setup', 'camera_hold', 'camera_to_core', 'core_to_camera'):
            report = read(folder/('c27_'+name+'.rpt'))
            slacks = [float(v) for v in re.findall(r'^Slack\s*:\s*([-+\d.]+) ns', report, re.M)]
            delays = [float(v) for v in re.findall(r'^Data Path Delay\s*:\s*([-+\d.]+) ns', report, re.M)]
            need(slacks and delays and len(slacks) == len(delays), 'missing actual timing paths '+name)
            need(min(slacks) >= 0, 'actual reported timing violation '+name)
            if name in ('camera_to_core', 'core_to_camera'):
                ends = re.findall(r'^Path End\s*:\s*(\S+)\s*$', report, re.M)
                expected_ends = cam_ends if name == 'camera_to_core' else core_ends
                need(set(ends) == expected_ends and len(ends) == len(expected_ends), 'missing/extra crossing paths '+name)
                need(max(delays) < 5.0, 'actual crossing flight time exceeds independent 5 ns check')
                need(report.count('Timing Exception : Max Delay Path 5.000 ns') == len(ends), 'crossing max-delay masked')
            report_summary[name] = {'paths': len(slacks), 'min_slack_ns': min(slacks), 'max_data_delay_ns': max(delays)}
        bus = read(folder/'c27_bus_setup.rpt')
        skew = [tuple(map(float, row)) for row in re.findall(
            r'^\[get_pins .*\|\s*Slow\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([-+\d.]+)\s*$', bus, re.M)]
        need(len(skew) == 2 and all(req == 1 and 0 <= actual < 1 and slack > 0 for req,actual,slack in skew), 'Gray setup skew not proven')
        # A unique minimum-reference bit may be omitted (9 comparisons);
        # tied minimum references can produce 10. Verify bit identities too.
        comparisons = re.findall(r'^Endpoints: (\d+)$', bus, re.M)
        bits = {(direction, int(bit)) for direction, bit in re.findall(
            r'u_ingress/u_fifo/(wr|rd)_sync1\[(\d+)\]~FF\|D', bus)}
        need(len(comparisons) == 2 and all(n in ('9','10') for n in comparisons) and
             bits == {(d,i) for d in ('wr','rd') for i in range(10)}, 'skew comparison inventory')
        print('C27_REGISTER_PATH_TIMING_PASS cross_endpoints=141 gray_setup_skew_ns='+str([s[1] for s in skew]))
        resources = status['metrics']['pnr_resources']
        print('C27_PNR_EVIDENCE_EXTRACTED '+json.dumps({'resources': resources, 'paths': report_summary}, separators=(',', ':')))
        print('C27_CDC_CLASSIFICATION '+read(folder/'cdc_classification_status.json').replace('\n', ' '))
    print('C27_AUDIT_COMPLETE physical_cdc_signoff=0 guard_integrated=0 board_verified=0 performance_claim=0')


if __name__ == '__main__':
    main()
