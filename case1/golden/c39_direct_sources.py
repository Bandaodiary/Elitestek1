"""C39 direct producer format experiment; leaves measured combined sources frozen."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from c39_candidate_sources import ROOT, sources as parent_sources, replace_once, artifacts as parent_artifacts

REPLACEMENTS = {
    'rtl/c39/c1_r2_cnn_row_shadow_engine.sv': 'rtl/c39_direct/c1_r2_cnn_row_shadow_engine.sv',
    'rtl/c39/c1_r2_spatial_partitioned_feeder.sv': 'rtl/c39_direct/c1_r2_spatial_partitioned_feeder.sv',
}


def sources(*args, **kwargs):
    return [ROOT / REPLACEMENTS.get(p.relative_to(ROOT).as_posix(), p.relative_to(ROOT).as_posix())
            for p in parent_sources(*args, **kwargs)]


def artifacts():
    engine = (ROOT / 'rtl/c39/c1_r2_cnn_row_shadow_engine.sv').read_text(encoding='utf-8-sig')
    engine = replace_once(engine,
        '    wire [431:0] packed_a;\n    c39_operand_pack u_pack(.mode(owner_q),.expanded(selected_a),.packed_a(packed_a));',
        '''    // Producer-native format: never unpack the spatial operand only to repack it.
    wire [431:0] spatial_packed_a;
    wire [95:0] linear_residual_a;
    for(genvar c39_lane=0;c39_lane<6;c39_lane=c39_lane+1)begin : g_direct_residual
        assign linear_residual_a[c39_lane*16+:16]=f_a[c39_lane*128+:16];
    end
    wire [431:0] linear_packed_a=residual_request ? {336'd0,linear_residual_a} :
        {176'd0,f_a[640+:128],f_a[0+:128]};
    wire [431:0] packed_a=own_linear_pool ? linear_packed_a : spatial_packed_a;''')
    engine = replace_once(engine,
        '        .req_a(f_a[768+:768]),.req_b(f_b[768+:768]),.req_bias(f_bias[192+:192]),',
        '        .req_a(f_a[768+:768]),.req_packed_a(spatial_packed_a),.req_b(f_b[768+:768]),.req_bias(f_bias[192+:192]),')
    yield REPLACEMENTS['rtl/c39/c1_r2_cnn_row_shadow_engine.sv'], engine
    spatial = (ROOT / 'rtl/c39/c1_r2_spatial_partitioned_feeder.sv').read_text(encoding='utf-8-sig')
    spatial = replace_once(spatial, '    output wire [767:0] req_a,req_b,',
        '    output wire [431:0] req_packed_a,\n    output wire [767:0] req_a,req_b,')
    spatial = replace_once(spatial,
        '    assign req_valid=encoder_q ? e_valid : rd_valid_q;',
        '''    // Legacy expanded output stays available for independent testbenches.
    // The integrated engine consumes only this native format in synthesis.
    assign req_packed_a=encoder_q ? {304'd0,e_a[0+:128]} : rd_packed_a_q;
    assign req_valid=encoder_q ? e_valid : rd_valid_q;''')
    yield REPLACEMENTS['rtl/c39/c1_r2_spatial_partitioned_feeder.sv'], spatial
    old, new = 'c1_ti60_c39_host_combined', 'c1_ti60_c39_host_direct'
    yield 'efinity/' + new + '.sv', (ROOT / 'efinity' / (old + '.sv')).read_text(encoding='utf-8-sig').replace(old, new)
    ns = 'http://www.efinixinc.com/enf_proj'
    ET.register_namespace('efx', ns)
    ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    project = ET.parse(ROOT / 'efinity' / (old + '.xml')).getroot()
    project.set('name', new)
    project.set('description', 'C39 direct producer format experiment; not production signoff')
    for element in project.iter():
        kind = element.tag.rsplit('}', 1)[-1]
        if kind == 'top_module':
            element.set('name', new)
        if kind == 'design_file':
            path = Path(element.attrib['name'])
            relative = path.relative_to(ROOT).as_posix()
            if path.name == old + '.sv':
                element.set('name', (ROOT / 'efinity' / (new + '.sv')).as_posix())
            elif relative in REPLACEMENTS:
                element.set('name', (ROOT / REPLACEMENTS[relative]).as_posix())
    ET.indent(project, space='    ')
    yield 'efinity/' + new + '.xml', ET.tostring(project, encoding='unicode') + '\n'
    yield 'efinity/' + new + '.sdc', (ROOT / 'efinity' / (old + '.sdc')).read_text(encoding='utf-8-sig')


def verify():
    for relative, expected in list(parent_artifacts()) + list(artifacts()):
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('direct candidate or parent differs: ' + relative)
    if len(sources()) != 49 or not all(p.is_file() for p in sources()):
        raise ValueError('incomplete direct closure')


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
        print('C39_DIRECT_SOURCE_PASS sources=49 full_numeric_validation=False')
