"""Independent ablation projects with the exact retained C37 probe/constraints."""
import xml.etree.ElementTree as ET
import sys
from c37_sources import ROOT, sources
from c39_candidate_sources import REPLACEMENTS

NS = 'http://www.efinixinc.com/enf_proj'
ET.register_namespace('efx', NS)
ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')
QUANT = {'rtl/cnn/c1_requant_bank8_compact.sv', 'rtl/c37/c37_compute6_indexed.sv'}
OPERANDS = {'rtl/c37/c1_r2_cnn_row_shadow_engine.sv', 'rtl/c37/c1_r2_spatial_partitioned_feeder.sv'}
WINDOW = {'rtl/c37/c1_r2_partitioned_window_store.sv'}
VARIANTS = {'quant': QUANT, 'operands': OPERANDS, 'window': WINDOW, 'combined': set(REPLACEMENTS)}


def artifacts():
    retained = 'c1_ti60_c37_resource24'
    for variant, selected in VARIANTS.items():
        name = 'c1_ti60_c39_host_' + variant
        top = (ROOT / 'efinity' / (retained + '.sv')).read_text(encoding='utf-8-sig')
        assert top.count('module ' + retained + ' (') == 1
        top = '// C39 fair ablation: original C37 boundary/model/clock profile retained.\n' + top.replace('module ' + retained + ' (', 'module ' + name + ' (')
        root = ET.parse(ROOT / 'efinity' / (retained + '.xml')).getroot()
        root.set('name', name)
        root.set('description', 'C39 explicit resource ablation ' + variant + '; not official CPU/board signoff')
        design = root.find(f'{{{NS}}}design_info')
        for item in list(design):
            design.remove(item)
        ET.SubElement(design, f'{{{NS}}}top_module', name=name)
        files = []
        for file in sources():
            relative = file.relative_to(ROOT).as_posix()
            files.append(ROOT / REPLACEMENTS[relative] if relative in selected else file)
        if OPERANDS & selected:
            files.append(ROOT / 'rtl/c39/c39_operand_codec.sv')
        files.append(ROOT / 'efinity' / (name + '.sv'))
        for file in files:
            ET.SubElement(design, f'{{{NS}}}design_file', name=file.as_posix(), version='default', library='default')
        # Reference the frozen original constraints, including targeted CDC rules.
        for item in root.find(f'{{{NS}}}constraint_info'):
            if item.tag == f'{{{NS}}}sdc_file':
                item.set('name', (ROOT / 'efinity' / (retained + '.sdc')).as_posix())
        ET.indent(root, space='    ')
        yield 'efinity/' + name + '.sv', top
        yield 'efinity/' + name + '.xml', ET.tostring(root, encoding='unicode') + '\n'
        yield 'efinity/' + name + '.sdc', (ROOT / 'efinity' / (retained + '.sdc')).read_text(encoding='utf-8-sig')


if __name__ == '__main__':
    selected_variant = sys.argv[1] if len(sys.argv) == 2 else None
    if selected_variant is not None and selected_variant not in VARIANTS:
        raise ValueError('unknown variant')
    print('*** Begin Patch')
    for relative, content in artifacts():
        if selected_variant is not None and not relative.startswith('efinity/c1_ti60_c39_host_' + selected_variant + '.'):
            continue
        assert not (ROOT / relative).exists(), 'refuse overwrite ' + relative
        print('*** Add File: ' + (ROOT / relative).as_posix())
        print('\n'.join('+' + line for line in content.splitlines()))
    print('*** End Patch')
