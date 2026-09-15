"""Second independent experiment: construct compact RGB/DW operands before selection."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from c39_direct_sources import ROOT, sources as direct_sources, verify as verify_direct
from c39_candidate_sources import replace_once

OLD_SOURCE = 'rtl/c39_direct/c1_r2_spatial_partitioned_feeder.sv'
NEW_SOURCE = 'rtl/c39_native/c1_r2_spatial_partitioned_feeder.sv'


def sources(*args, **kwargs):
    return [ROOT / NEW_SOURCE if p == ROOT / OLD_SOURCE else p for p in direct_sources(*args, **kwargs)]


def artifacts():
    text = (ROOT / OLD_SOURCE).read_text(encoding='utf-8-sig')
    text = replace_once(text, '    wire [255:0] rgb_operands;\n', '')
    text = replace_once(text,
        "    c39_operand_pack u_spatial_pack(.mode(dw_q ? 3'd2 : 3'd1),.expanded(issue_a),.packed_a(issue_packed_a));",
        '''    // Select in native format; do not first choose six expanded RGB/DW vectors.
    wire [255:0] rgb_operands;
    wire [431:0] dw_issue_packed;
    assign issue_packed_a=dw_q ? dw_issue_packed : {176'd0,rgb_operands};''')
    text = replace_once(text,
        '        assign issue_a[r*128+:128]=dw_q ? dw_a : rgb_operands[(r/3)*128+:128];',
        '''        assign dw_issue_packed[r*72+:72]=dw_a[0+:72];
        assign issue_a[r*128+:128]=dw_q ? dw_a : rgb_operands[(r/3)*128+:128];''')
    yield NEW_SOURCE, text
    old, new = 'c1_ti60_c39_host_direct', 'c1_ti60_c39_host_native'
    yield 'efinity/' + new + '.sv', (ROOT / 'efinity' / (old + '.sv')).read_text(encoding='utf-8-sig').replace(old, new)
    ns = 'http://www.efinixinc.com/enf_proj'
    ET.register_namespace('efx', ns)
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    project = ET.parse(ROOT / 'efinity' / (old + '.xml')).getroot()
    project.set('name', new)
    project.set('description', 'C39 native RGB/DW construction experiment; not production signoff')
    for element in project.iter():
        kind = element.tag.rsplit('}', 1)[-1]
        if kind == 'top_module':
            element.set('name', new)
        if kind == 'design_file':
            path = Path(element.attrib['name'])
            if path.name == old + '.sv':
                element.set('name', (ROOT / 'efinity' / (new + '.sv')).as_posix())
            elif path == ROOT / OLD_SOURCE:
                element.set('name', (ROOT / NEW_SOURCE).as_posix())
    ET.indent(project, space='    ')
    yield 'efinity/' + new + '.xml', ET.tostring(project, encoding='unicode') + '\n'
    yield 'efinity/' + new + '.sdc', (ROOT / 'efinity' / (old + '.sdc')).read_text(encoding='utf-8-sig')


def verify():
    verify_direct()
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('native-format experiment differs: ' + relative)
    if len(sources()) != 49 or not all(p.is_file() for p in sources()):
        raise ValueError('incomplete native closure')


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
        print('C39_NATIVE_SOURCE_PASS sources=49 full_numeric_validation=False')
