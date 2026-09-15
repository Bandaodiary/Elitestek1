"""Independent joint resource probe with narrowly inherited host CDC constraints.

This does not validate physical DDR/JTAG/reset interfaces. Pin counts and timing
must be checked in an actual mapped/routed design before claiming CDC evidence.
"""
import json
import sys
import xml.etree.ElementTree as ET
from c39_joint_projects import artifacts as joint_artifacts
from c39_onehot_sources import ROOT, verify as verify_onehot

BASE = 'c1_ti60_c39_joint_s2_onehot'
NAME = BASE + '_cdc'
REFERENCE = 'c1_ti60_c37_resource24'
CPU = ROOT / 'efinity/c39_cpu_s2_generate_20260915a'


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('joint CDC derivation anchor differs: ' + old)
    return text.replace(old, new)


def validate(sdc, audit, top):
    if top.count('#(.FRAME_DIVISOR(1)) u_host (') != 1:
        raise ValueError('joint probe must retain every-frame acquisition')
    if sdc.count('create_clock ') != 6 or 'create_clock -name core_clk -period 10 [get_ports core_clk]' not in sdc:
        raise ValueError('joint clocks changed')
    commands = [line.strip() for line in sdc.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    allowed = ('create_clock ', 'set_max_delay ', 'set_false_path -hold ', 'set_bus_skew ')
    if any(not command.startswith(allowed) for command in commands):
        raise ValueError('unreviewed timing command, blanket group or setup false path')
    delays = [line for line in commands if line.startswith('set_max_delay ')]
    skew = [line for line in commands if line.startswith('set_bus_skew ')]
    holds = [line for line in commands if line.startswith('set_false_path -hold ')]
    if len(delays) != 7 or any(not line.endswith(' 5.000') for line in delays):
        raise ValueError('host crossing bound missing or changed')
    if len(skew) != 2 or any(not line.endswith(' 1.000') for line in skew) or len(holds) != 7:
        raise ValueError('Gray skew / first-stage hold exception inventory changed')
    if 'camera_clk' in sdc or 'camera_clk' in audit:
        raise ValueError('unmapped old camera clock name')
    required = (
        'check_pins tag_source {u_host/u_system/u_ingress/source_tag[*]~FF|CLK} 32',
        'check_pins tag_destination {u_host/u_system/capture_tag[*]~FF|D} 32',
        'check_pins tag_lsb_present {u_host/u_system/u_ingress/source_tag[0]~FF|CLK u_host/u_system/capture_tag[0]~FF|D} 2',
    )
    if any(audit.count(line) != 1 for line in required) or 'tag_lsb_absent' in audit:
        raise ValueError('FRAME_DIVISOR=1 tag bit inventory was weakened')


def artifacts():
    verify_onehot()
    for relative, expected in joint_artifacts(CPU, 'onehot').items():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('base official joint source differs: ' + relative)
    top = (ROOT / 'efinity' / (BASE + '.sv')).read_text(encoding='utf-8-sig')
    top = replace_once(top, 'module ' + BASE + ' (', 'module ' + NAME + ' (')
    base_sdc = (ROOT / 'efinity' / (BASE + '.sdc')).read_text(encoding='utf-8-sig')
    host_sdc = (ROOT / 'efinity' / (REFERENCE + '.sdc')).read_text(encoding='utf-8-sig')
    start = '# FIFO Gray buses: bound flight time and inter-bit skew separately.'
    if host_sdc.count(start) != 1:
        raise ValueError('retained host constraints changed')
    cdc = host_sdc[host_sdc.index(start):].replace('camera_clk', 'cam_clk')
    sdc = base_sdc + '\n# C39 reviewed host-only CDC inheritance; physical IP clocks remain unqualified.\n' + cdc
    audit = (ROOT / 'efinity' / (REFERENCE + '.audit.tcl')).read_text(encoding='utf-8-sig').replace('camera_clk', 'cam_clk')
    old_comment = '''# This fixed probe uses FRAME_DIVISOR=2: admitted raw frame tags are even.
# MAP removes bit 0 on BOTH sides. Python also verifies the exact bits 1..31;
# do not generalize these counts to a different divisor or mask other bits.'''
    audit = replace_once(audit, old_comment, '''# C39 joint probe uses FRAME_DIVISOR=1: both odd and even raw tags occur.
# Require all 32 source/destination bits, including LSB on both sides.
# These are expected mapped counts; absence is an audit FAILURE, not permission to skip.''')
    for label, pins in (
        ('tag_source', 'u_host/u_system/u_ingress/source_tag[*]~FF|CLK'),
        ('tag_destination', 'u_host/u_system/capture_tag[*]~FF|D'),
    ):
        audit = replace_once(audit, f'check_pins {label} {{{pins}}} 31', f'check_pins {label} {{{pins}}} 32')
    audit = replace_once(audit,
        'check_pins tag_lsb_absent {u_host/u_system/u_ingress/source_tag[0]~FF|CLK u_host/u_system/capture_tag[0]~FF|D} 0',
        'check_pins tag_lsb_present {u_host/u_system/u_ingress/source_tag[0]~FF|CLK u_host/u_system/capture_tag[0]~FF|D} 2')
    validate(sdc, audit, top)
    ns = 'http://www.efinixinc.com/enf_proj'
    ET.register_namespace('efx', ns)
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    project = ET.parse(ROOT / 'efinity' / (BASE + '.xml')).getroot()
    project.set('name', NAME)
    project.set('description', 'C39 S2 onehot joint with endpoint-scoped host CDC; not board/PHY signoff')
    for item in project.iter():
        kind = item.tag.rsplit('}', 1)[-1]
        if kind == 'top_module':
            item.set('name', NAME)
        elif kind == 'design_file' and item.attrib['name'].replace('\\', '/').endswith('/' + BASE + '.sv'):
            item.set('name', (ROOT / 'efinity' / (NAME + '.sv')).as_posix())
        elif kind == 'sdc_file':
            item.set('name', NAME + '.sdc')
    ET.indent(project, space='    ')
    classification = (ROOT / 'efinity' / (REFERENCE + '.cdc.tcl')).read_text(encoding='utf-8-sig').replace('camera_clk', 'cam_clk')
    yield 'efinity/' + NAME + '.sv', top
    yield 'efinity/' + NAME + '.xml', ET.tostring(project, encoding='unicode') + '\n'
    yield 'efinity/' + NAME + '.sdc', sdc
    yield 'efinity/' + NAME + '.audit.tcl', audit
    yield 'efinity/' + NAME + '.cdc.tcl', classification
    contract = dict(project=NAME, base_project=BASE, retained_host_constraints=REFERENCE,
        frame_divisor=1, core_clock_mhz=100, source_and_destination_tag_bits=32,
        tag_lsb_must_exist_on_both_sides=True, crossing_max_delay_ns=5, gray_bus_skew_ns=1,
        no_blanket_clock_groups=True, no_setup_false_paths=True,
        mapped_pin_counts_verified=False, final_timing_verified=False,
        physical_CPU_DDR_JTAG_reset_signoff=False, board_signoff=False)
    yield 'review/C39_JOINT_S2_ONEHOT_CDC_CONTRACT.json', json.dumps(contract, indent=2) + '\n'


def verify():
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('joint CDC artifact differs: ' + relative)
    # Recheck the actual installed/public CPU configuration and BSP against
    # every joint variant, not only the early C37/C39 wrappers.
    from c39_sapphire_platform_contract import audit
    audit(CPU, ('c37', 'c39', 'native', 'onehot', 'onehot_cdc'))


def selftest():
    files = dict(artifacts())
    sdc, audit, top = (files['efinity/' + NAME + suffix] for suffix in ('.sdc', '.audit.tcl', '.sv'))
    cases = (
        (sdc + '\nset_clock_groups -asynchronous -group core_clk -group cam_clk\n', audit, top),
        (sdc.replace('set_false_path -hold ', 'set_false_path ', 1), audit, top),
        (sdc.replace(' 5.000', ' 50.000', 1), audit, top),
        (sdc.replace(' 1.000', ' 10.000', 1), audit, top),
        (sdc, audit.replace('} 32', '} 31', 1), top),
        (sdc, audit.replace('tag_lsb_present', 'tag_lsb_absent'), top),
        (sdc, audit, top.replace('FRAME_DIVISOR(1)', 'FRAME_DIVISOR(2)')),
    )
    for candidate in cases:
        try:
            validate(*candidate)
        except ValueError:
            continue
        raise AssertionError('weakened joint constraints accepted')
    print('C39_JOINT_CDC_SOURCE_SELFTEST_PASS negative_evidence_cases=7 actual_STA=False')


if __name__ == '__main__':
    if '--emit-patch' in sys.argv:
        print('*** Begin Patch')
        for relative, content in artifacts():
            if (ROOT / relative).exists():
                raise ValueError('refuse overwrite ' + relative)
            print('*** Add File: ' + (ROOT / relative).as_posix())
            print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        verify()
        selftest()
        print('C39_JOINT_CDC_SOURCE_PASS actual_pin_counts_and_timing_pending=True')
