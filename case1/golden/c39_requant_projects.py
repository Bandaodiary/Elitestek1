"""Emit apply_patch for isolated, equal-constraint six-lane Efinity A/B probes."""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = 'http://www.efinixinc.com/enf_proj'
ET.register_namespace('efx', NS)
ET.register_namespace('xsi', 'http://www.w3.org/2001/XMLSchema-instance')


def artifacts():
    for variant, module, relative in (
        ('baseline', 'c1_requant_bank8_compact', 'rtl/cnn/c1_requant_bank8_compact.sv'),
        ('narrow', 'c39_requant_bank8_narrow', 'rtl/c39/c39_requant_bank8_narrow.sv'),
    ):
        name = 'c1_ti60_c39_quant_' + variant
        rtl = f'''// Six live lanes; equal external boundary, no constant input arithmetic.
module {name} (
    input wire clk,rst,in_valid,out_ready,
    input wire [191:0] acc,
    input wire [107:0] mult,
    input wire [35:0] shift,
    input wire [11:0] activation,
    input wire [18:0] meta,
    output wire in_ready,out_valid,
    output wire [47:0] data,
    output wire [18:0] out_meta
);
    wire [63:0] all_data;
    assign data=all_data[47:0];
    {module} #(.X_BITS(10),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(in_valid),.out_ready(out_ready),
        .in_acc_s32({{64'd0,acc}}),.in_mult_s18({{36'd0,mult}}),
        .in_shift_u6({{12'd0,shift}}),.in_activation({{4'd0,activation}}),
        .in_sof(meta[18]),.in_eol(meta[17]),.in_eof(meta[16]),.in_x(meta[15:6]),.in_y(meta[5:0]),
        .in_ready(in_ready),.out_valid(out_valid),.out_data_s8(all_data),
        .out_sof(out_meta[18]),.out_eol(out_meta[17]),.out_eof(out_meta[16]),.out_x(out_meta[15:6]),.out_y(out_meta[5:0])
    );
endmodule
'''
        root = ET.parse(ROOT / 'efinity/c1_ti60_c38_soc_ddr_resource.xml').getroot()
        root.set('name', name)
        root.set('description', 'C39 six-lane quantization A/B resource-only probe')
        design = root.find(f'{{{NS}}}design_info')
        for element in list(design):
            design.remove(element)
        ET.SubElement(design, f'{{{NS}}}top_module', name=name)
        for file in (ROOT / relative, ROOT / 'efinity' / (name + '.sv')):
            ET.SubElement(design, f'{{{NS}}}design_file', name=file.as_posix(), version='default', library='default')
        constraints = root.find(f'{{{NS}}}constraint_info')
        for element in list(constraints):
            constraints.remove(element)
        ET.SubElement(constraints, f'{{{NS}}}sdc_file', name=name + '.sdc')
        synthesis = root.find(f'{{{NS}}}synthesis')
        for element in list(synthesis):
            if element.get('name') == 'include':
                synthesis.remove(element)
        ET.indent(root, space='    ')
        yield 'efinity/' + name + '.sv', rtl
        yield 'efinity/' + name + '.xml', ET.tostring(root, encoding='unicode') + '\n'
        yield 'efinity/' + name + '.sdc', 'create_clock -name core_clk -period 6.667 [get_ports clk]\n'


if __name__ == '__main__':
    print('*** Begin Patch')
    for relative, content in artifacts():
        assert not (ROOT / relative).exists(), 'refuse overwrite ' + relative
        print('*** Add File: ' + (ROOT / relative).as_posix())
        print('\n'.join('+' + line for line in content.splitlines()))
    print('*** End Patch')
