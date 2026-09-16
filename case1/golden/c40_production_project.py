"""Exact production host closure, four-row Resize, frame divisor one, 100 MHz."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from c39_onehot_sources import ROOT, sources

NAME = 'c1_ti60_c40_host_100'
BASE = 'c1_ti60_c39_host_onehot'
NS = 'http://www.efinixinc.com/enf_proj'


def artifacts():
    top = (ROOT / 'efinity' / (BASE + '.sv')).read_text(encoding='utf-8-sig')
    top = top[top.index('module '):].replace(BASE, NAME)
    anchor = 'c1_r2_fused_rgb2_host_system u_host ('
    assert top.count(anchor) == 1
    top = top.replace(anchor, 'c1_r2_fused_rgb2_host_system #(.FRAME_DIVISOR(1)) u_host (')
    top = '// Production C40 host resource/timing boundary: 640x480, 100 MHz, camera frame divisor 1.\n' + \
          '// Includes all 49 host RTL sources; CPU/DDR PHY and board IO timing are separate integration work.\n' + top
    sdc = (ROOT / 'efinity' / (BASE + '.sdc')).read_text(encoding='utf-8-sig')
    assert sdc.count('create_clock -name core_clk -period 6.666') == 1
    sdc = sdc.replace('create_clock -name core_clk -period 6.666', 'create_clock -name core_clk -period 10.000')
    sdc = '# C40 production host, core 100 MHz and independent camera clock.\n' + sdc
    ET.register_namespace('efx', NS)
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    root = ET.parse(ROOT / 'efinity' / (BASE + '.xml')).getroot()
    root.set('name', NAME)
    root.set('description', 'Production C40 host four-row Resize at 100MHz; no physical board IO signoff')
    design = root.find(f'{{{NS}}}design_info')
    for item in list(design):
        design.remove(item)
    ET.SubElement(design, f'{{{NS}}}top_module', name=NAME)
    for path in sources() + [ROOT / 'efinity' / (NAME + '.sv')]:
        ET.SubElement(design, f'{{{NS}}}design_file', name=path.as_posix(), version='default', library='default')
    root.find(f'{{{NS}}}constraint_info/{{{NS}}}sdc_file').set('name', (ROOT / 'efinity' / (NAME + '.sdc')).as_posix())
    ET.indent(root, space='    ')
    return {NAME + '.sv': top, NAME + '.sdc': sdc, NAME + '.xml': ET.tostring(root, encoding='unicode') + '\n'}


def verify():
    for name, content in artifacts().items():
        actual = (ROOT / 'efinity' / name).read_text(encoding='utf-8-sig')
        # Efinity rewrites the XML without its final newline. Keep all other
        # project/source/constraint bytes significant; do not ignore attributes.
        if name.endswith('.xml'):
            actual, content = actual.rstrip('\n'), content.rstrip('\n')
        if actual != content:
            raise ValueError('production project mismatch: ' + name)
    print('C40_PROJECT_PASS host_sources=49 core_ns=10 camera_ns=14.286 frame_divisor=1')


if __name__ == '__main__':
    if '--emit-patch' in sys.argv:
        print('*** Begin Patch')
        for name, content in artifacts().items():
            path = ROOT / 'efinity' / name
            assert not path.exists()
            print('*** Add File: ' + path.as_posix())
            print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        verify()
