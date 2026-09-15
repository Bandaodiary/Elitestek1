// Six live lanes; equal external boundary, no constant input arithmetic.
module c1_ti60_c39_quant_narrow (
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
    c39_requant_bank8_narrow #(.X_BITS(10),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(in_valid),.out_ready(out_ready),
        .in_acc_s32({64'd0,acc}),.in_mult_s18({36'd0,mult}),
        .in_shift_u6({12'd0,shift}),.in_activation({4'd0,activation}),
        .in_sof(meta[18]),.in_eol(meta[17]),.in_eof(meta[16]),.in_x(meta[15:6]),.in_y(meta[5:0]),
        .in_ready(in_ready),.out_valid(out_valid),.out_data_s8(all_data),
        .out_sof(out_meta[18]),.out_eol(out_meta[17]),.out_eof(out_meta[16]),.out_x(out_meta[15:6]),.out_y(out_meta[5:0])
    );
endmodule
