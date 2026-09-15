"""Isolated native-host experiment: shared decode, parallel masked operand mux.

No change to storage, numeric arithmetic, mode set, tags or pipeline latency.
The existing native candidate and all production sources remain untouched.
"""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from c39_native_sources import ROOT, sources as native_sources, verify as verify_native

OLD = 'rtl/c39/c39_operand_codec.sv'
NEW = 'rtl/c39_onehot/c39_operand_codec.sv'
UNPACK = '''module c39_operand_unpack (
    input wire [2:0] mode,
    input wire [35:0] channels,
    input wire [431:0] packed_a,
    output wire [767:0] expanded
);
    // Mutually exclusive decodes are shared across all data bits and lanes.
    // Reserved modes 6/7 retain the original default behavior (first vector).
    wire is_pw=mode==0, is_rgb=mode==1, is_dw=mode==2, is_res=mode==3;
    wire is_pair=is_pw || is_rgb;
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_lane
        wire pw_second=channels[lane*6+:6]<channels[0+:6];
        wire second=(is_pw && pw_second) || (is_rgb && (lane>=3));
        wire first=!(is_dw || is_res) && (!is_pair || !second);
        assign expanded[lane*128+:128]=
            ({128{first}} & packed_a[0+:128]) |
            ({128{second}} & packed_a[128+:128]) |
            ({128{is_dw}} & {56'd0,packed_a[lane*72+:72]}) |
            ({128{is_res}} & {112'd0,packed_a[lane*16+:16]});
    end
endmodule
'''


def sources(*args, **kwargs):
    return [ROOT / NEW if p == ROOT / OLD else p for p in native_sources(*args, **kwargs)]


def artifacts():
    codec = (ROOT / OLD).read_text(encoding='utf-8-sig')
    assert codec.count('module c39_operand_unpack (') == 1
    yield NEW, codec.split('module c39_operand_unpack (')[0] + UNPACK
    old, new = 'c1_ti60_c39_host_native', 'c1_ti60_c39_host_onehot'
    yield 'efinity/' + new + '.sv', (ROOT / 'efinity' / (old + '.sv')).read_text(encoding='utf-8-sig').replace(old, new)
    ns = 'http://www.efinixinc.com/enf_proj'
    ET.register_namespace('efx', ns)
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    root = ET.parse(ROOT / 'efinity' / (old + '.xml')).getroot()
    root.set('name', new)
    root.set('description', 'C39 one-hot operand decode ablation; not production signoff')
    for item in root.iter():
        kind = item.tag.rsplit('}', 1)[-1]
        if kind == 'top_module':
            item.set('name', new)
        elif kind == 'design_file':
            path = Path(item.attrib['name'])
            if path == ROOT / OLD:
                item.set('name', (ROOT / NEW).as_posix())
            elif path.name == old + '.sv':
                item.set('name', (ROOT / 'efinity' / (new + '.sv')).as_posix())
    ET.indent(root, space='    ')
    yield 'efinity/' + new + '.xml', ET.tostring(root, encoding='unicode') + '\n'
    yield 'efinity/' + new + '.sdc', (ROOT / 'efinity' / (old + '.sdc')).read_text(encoding='utf-8-sig')


def verify():
    verify_native()
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('onehot candidate differs: ' + relative)
    if len(sources()) != 49 or not all(p.is_file() for p in sources()):
        raise ValueError('onehot source closure incomplete')


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
        print('C39_ONEHOT_SOURCE_PASS sources=49 full_numeric_validation=False')
