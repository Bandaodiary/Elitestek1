"""Isolated parity-first window mux experiment; no live candidate is modified."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from c39_onehot_sources import ROOT, sources as parent_sources, verify as parent_verify

OLD = 'rtl/c39/c1_r2_partitioned_window_store.sv'
NEW = 'rtl/c39_window_factor/c1_r2_partitioned_window_store.sv'
START = '    // Shared decode per logical row / parity, followed by static bit planes.'
END = '    for(genvar entry=0;entry<2;entry=entry+1) begin : g_slot'
SELECT = '''    // Experimental factoring only: choose parity once per physical row,
    // then select the logical row. No added/removed registers or reservations.
    wire [383:0] parity_bank_data;
    for(genvar row_id=0;row_id<3;row_id=row_id+1)begin : g_parity_row
        for(genvar col=0;col<2;col=col+1)begin : g_col
            assign parity_bank_data[(row_id*2+col)*64+:64]=pending_parity[col] ?
                bank_data[(row_id*2+1)*64+:64] : bank_data[(row_id*2)*64+:64];
        end
    end
    wire [383:0] selected_bank_data;
    for(genvar view=0;view<6;view=view+1)begin : g_row_view
        wire [1:0] row_id=pending_rows[(view/2)*2+:2];
        // Invalid row 3 still produces zero, as in the retained one-hot mux.
        assign selected_bank_data[view*64+:64]=
            ({64{row_id==0}} & parity_bank_data[(0*2+view%2)*64+:64]) |
            ({64{row_id==1}} & parity_bank_data[(1*2+view%2)*64+:64]) |
            ({64{row_id==2}} & parity_bank_data[(2*2+view%2)*64+:64]);
    end
'''


def sources(*args, **kwargs):
    return [ROOT / NEW if p == ROOT / OLD else p for p in parent_sources(*args, **kwargs)]


def artifacts():
    original = (ROOT / OLD).read_text(encoding='utf-8-sig')
    if original.count(START) != 1 or original.count(END) != 1:
        raise ValueError('window selection boundaries changed')
    before, rest = original.split(START)
    _, after = rest.split(END)
    yield NEW, before + SELECT + END + after
    old, new = 'c1_ti60_c39_host_onehot', 'c1_ti60_c39_host_winfactor'
    yield 'efinity/' + new + '.sv', (ROOT / ('efinity/' + old + '.sv')).read_text(encoding='utf-8-sig').replace(old, new)
    ET.register_namespace('efx', 'http://www.efinixinc.com/enf_proj')
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    project = ET.parse(ROOT / ('efinity/' + old + '.xml')).getroot()
    project.set('name', new)
    project.set('description', 'C39 parity-first window mux ablation; not production signoff')
    for item in project.iter():
        kind = item.tag.rsplit('}', 1)[-1]
        if kind == 'top_module':
            item.set('name', new)
        elif kind == 'design_file':
            path = Path(item.attrib['name'])
            if path == ROOT / OLD:
                item.set('name', (ROOT / NEW).as_posix())
            elif path.name == old + '.sv':
                item.set('name', (ROOT / ('efinity/' + new + '.sv')).as_posix())
    ET.indent(project, space='    ')
    yield 'efinity/' + new + '.xml', ET.tostring(project, encoding='unicode') + '\n'
    yield 'efinity/' + new + '.sdc', (ROOT / ('efinity/' + old + '.sdc')).read_text(encoding='utf-8-sig')


def verify():
    parent_verify()
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('window factoring source differs: ' + relative)
    paths = sources()
    if len(paths) != 49 or len(set(paths)) != 49 or not all(p.is_file() for p in paths):
        raise ValueError('window factoring closure incomplete')


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
        print('C39_WINDOW_FACTOR_SOURCE_PASS sources=49 registers_unchanged=1 slots=2 RTL_simulated=0 resource_gain_measured=0')
