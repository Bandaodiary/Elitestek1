"""Create independent candidates via apply_patch; C37/vendor files stay frozen."""
from pathlib import Path
import sys
from c37_sources import ROOT, sources as retained_sources


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('candidate anchor changed: ' + old[:100])
    return text.replace(old, new)


def artifacts():
    compute = (ROOT / 'rtl/c37/c37_compute6_indexed.sv').read_text(encoding='utf-8-sig')
    compute = replace_once(compute, 'c1_requant_bank8_compact #(', 'c39_requant_bank8_narrow #(')
    yield 'rtl/c39/c37_compute6_indexed.sv', compute
    engine = (ROOT / 'rtl/c37/c1_r2_cnn_row_shadow_engine.sv').read_text(encoding='utf-8-sig')
    engine = replace_once(engine, 'REQUEST_BITS=1597', 'REQUEST_BITS=1264')
    anchor = '    wire [REQUEST_BITS-1:0] selected_request={'
    engine = replace_once(engine, anchor, '''    wire [767:0] selected_a=own_linear_pool ? f_a[0+:768] : f_a[768+:768];
    wire [431:0] packed_a;
    c39_operand_pack u_pack(.mode(owner_q),.expanded(selected_a),.packed_a(packed_a));
    wire [REQUEST_BITS-1:0] selected_request={''')
    engine = replace_once(engine,
        '        own_linear_pool ? f_a[0+:768] : f_a[768+:768],',
        '        packed_a,owner_q,')
    engine = replace_once(engine,
        '    assign {q_first,q_last,q_mask,q_tag,q_a,q_b,q_channels,q_residual}=request_q;',
        '''    wire [431:0] q_packed_a;
    wire [2:0] q_mode;
    assign {q_first,q_last,q_mask,q_tag,q_packed_a,q_mode,q_b,q_channels,q_residual}=request_q;
    c39_operand_unpack u_unpack(.mode(q_mode),.channels(q_channels),.packed_a(q_packed_a),.expanded(q_a));
`ifndef SYNTHESIS
    wire [767:0] checked_a;
    c39_operand_unpack u_pack_check(.mode(owner_q),.channels(residual_request ? 36'd0 : weight_channels_q),.packed_a(packed_a),.expanded(checked_a));
    always @(posedge clk)if(!rst && selected_valid && request_slot_ready && checked_a!==selected_a)
        $fatal(1,"C39 feeder violates lossless operand packing contract");
`endif''')
    yield 'rtl/c39/c1_r2_cnn_row_shadow_engine.sv', engine
    spatial = (ROOT / 'rtl/c37/c1_r2_spatial_partitioned_feeder.sv').read_text(encoding='utf-8-sig')
    spatial = replace_once(spatial, '    wire [767:0] issue_a;\n', '')
    spatial = replace_once(spatial, '    logic [767:0] rd_a_q;', '''    logic [431:0] rd_packed_a_q;
    wire [767:0] issue_a;
    wire [767:0] rd_a_q;
    wire [431:0] issue_packed_a;
    c39_operand_pack u_spatial_pack(.mode(dw_q ? 3'd2 : 3'd1),.expanded(issue_a),.packed_a(issue_packed_a));
    c39_operand_unpack u_spatial_unpack(.mode(rd_dw_q ? 3'd2 : 3'd1),.channels(36'd0),.packed_a(rd_packed_a_q),.expanded(rd_a_q));''')
    spatial = replace_once(spatial, 'rd_a_q<=issue_a;', 'rd_packed_a_q<=issue_packed_a;')
    yield 'rtl/c39/c1_r2_spatial_partitioned_feeder.sv', spatial
    window = (ROOT / 'rtl/c37/c1_r2_partitioned_window_store.sv').read_text(encoding='utf-8-sig')
    anchor = '    for(genvar entry=0;entry<2;entry=entry+1) begin : g_slot'
    window = replace_once(window, anchor, '''    // Shared decode per logical row / parity, followed by static bit planes.
    // No stage removal: both reservation slots and half-read ownership remain.
    wire [383:0] selected_bank_data;
    for(genvar view=0;view<6;view=view+1)begin : g_bank_view
        wire [2:0] index={pending_rows[(view/2)*2+:2],pending_parity[view%2]};
        wire [5:0] select_bank;
        for(genvar bank=0;bank<6;bank=bank+1)begin : g_decode
            assign select_bank[bank]=index==bank;
        end
        for(genvar bit_id=0;bit_id<64;bit_id=bit_id+1)begin : g_bit
            wire [5:0] plane;
            for(genvar bank=0;bank<6;bank=bank+1)begin : g_bank
                assign plane[bank]=select_bank[bank] && bank_data[bank*64+bit_id];
            end
            assign selected_bank_data[view*64+bit_id]=|plane;
        end
    end
''' + anchor)
    window = replace_once(window, 'pixel_q<=bank_data[index*64+:64];',
                          'pixel_q<=selected_bank_data[(ROW*2+COL%2)*64+:64];')
    yield 'rtl/c39/c1_r2_partitioned_window_store.sv', window


REPLACEMENTS = {
    'rtl/cnn/c1_requant_bank8_compact.sv': 'rtl/c39/c39_requant_bank8_narrow.sv',
    **{old: 'rtl/c39/' + Path(old).name for old in (
        'rtl/c37/c37_compute6_indexed.sv',
        'rtl/c37/c1_r2_cnn_row_shadow_engine.sv',
        'rtl/c37/c1_r2_spatial_partitioned_feeder.sv',
        'rtl/c37/c1_r2_partitioned_window_store.sv',
    )},
}


def sources(*args, **kwargs):
    result, seen = [], set()
    for source in retained_sources(*args, **kwargs):
        relative = source.relative_to(ROOT).as_posix()
        if relative in REPLACEMENTS:
            seen.add(relative)
            source = ROOT / REPLACEMENTS[relative]
        if not source.is_file():
            raise ValueError('missing candidate ' + str(source))
        result.append(source)
    if seen != set(REPLACEMENTS):
        raise ValueError('incomplete C39 replacement closure')
    result.append(ROOT / 'rtl/c39/c39_operand_codec.sv')
    return result


if __name__ == '__main__':
    if '--emit-patch' in sys.argv:
        print('*** Begin Patch')
        for relative, content in artifacts():
            assert not (ROOT / relative).exists(), 'refuse overwrite ' + relative
            print('*** Add File: ' + (ROOT / relative).as_posix())
            print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        for relative, content in artifacts():
            assert (ROOT / relative).read_text(encoding='utf-8-sig') == content, relative
        print(f'C39_SOURCE_REPRODUCTION_PASS generated=4 closure={len(sources())} baseline_modified=0')
