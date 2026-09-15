"""Actual retained-host evidence and in-memory corruptions; not new joint signoff."""
import json
import re
from c39_joint_cdc_evidence import ROOT, read, inspect_mapped, inspect_timing


def main():
    folder = ROOT / 'logs/efinity_resource_runs/c37_resource24_pnr_20260915b'
    text = read(folder / 'cdc_mapped_registers.txt')
    inventory = inspect_mapped(text, 'clk', 31)
    names = ('core_setup', 'core_hold', 'camera_setup', 'camera_hold', 'camera_to_core', 'core_to_camera', 'bus_setup')
    reports = {name: read(folder / ('c27_' + name + '.rpt')) for name in names}
    result = inspect_timing(reports, inventory)
    mutations = (
        ('missing_FIFO_MSB', text.replace('u_fifo/wr_sync1[9]~FF', 'u_fifo/REMOVED[9]~FF'), 'clk', 31),
        ('wrong_sync_clock', text, 'core_clk', 31),
        ('old_31bit_profile_is_not_joint', text, 'clk', 32),
    )
    rejected = []
    for name, bad, clock, tag_bits in mutations:
        try:
            inspect_mapped(bad, clock, tag_bits)
        except (ValueError, KeyError):
            rejected.append(name)
        else:
            raise AssertionError('mapped corruption accepted: ' + name)
    old = '.D(\\u_host/u_system/u_ingress/u_fifo/wr_sync1 [0])'
    if text.count(old) != 1:
        raise ValueError('actual retained stage-2 input anchor differs')
    try:
        inspect_mapped(text.replace(old, '.D(\\WRONG_COMBINATIONAL_NET )'), 'clk', 31)
    except (ValueError, KeyError):
        rejected.append('logic_between_sync_stages')
    else:
        raise AssertionError('broken stage-2 connection accepted')
    changes = []
    for name, report, pattern, replacement in (
        ('negative_slack', 'core_setup', r'(?m)^Slack\s*:\s*[-+\d.]+ ns', 'Slack : -0.001 ns'),
        ('excess_flight_time', 'camera_to_core', r'(?m)^Data Path Delay\s*:\s*[-+\d.]+ ns', 'Data Path Delay : 5.001 ns'),
        ('wrong_endpoint', 'camera_to_core', r'(?m)^Path End\s*:\s*\S+\s*$', 'Path End : WRONG~FF|D'),
    ):
        changed = dict(reports)
        changed[report], count = re.subn(pattern, replacement, changed[report], count=1)
        if count != 1:
            raise ValueError('actual report mutation anchor missing: ' + name)
        changes.append((name, changed))
    for name, report, old, new in (
        ('missing_max_delay', 'camera_to_core', 'Timing Exception : Max Delay Path 5.000 ns', 'REMOVED_BOUND'),
        ('excess_Gray_skew', 'bus_setup', '0.027', '1.027'),
    ):
        changed = dict(reports)
        if old not in changed[report]:
            raise ValueError('actual report anchor changed: ' + name)
        changed[report] = changed[report].replace(old, new)
        changes.append((name, changed))
    for name, changed in changes:
        try:
            inspect_timing(changed, inventory)
        except ValueError:
            rejected.append(name)
        else:
            raise AssertionError('timing corruption accepted: ' + name)
    print('C39_JOINT_CDC_CHECKER_SELFTEST_PASS ' + json.dumps(dict(
        actual_retained_C37_rechecked=True, synchronizer_ff=inventory['sync_ff'],
        retained_cross_endpoints=140, gray_setup_skew_ns=result['gray_setup_skew_ns'],
        rejected_evidence_mutations=rejected, new_joint_PNR_verified=False,
        source_files_modified=False), separators=(',', ':')))


if __name__ == '__main__':
    main()
