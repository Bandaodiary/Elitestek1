// Narrow observation shell; all six output lanes remain independently visible.
// Host holds out_ready low while selecting result_row. Not a DMA interface.
module c1_ti60_r2_pw96(
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [11:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [10:0] pixel_count,
    output wire busy,out_valid,
    input wire out_ready,
    input wire [2:0] result_row,
    output wire [7:0] result_data,
    output wire [5:0] out_mask,
    output wire [12:0] out_base,
    output wire out_last
);
    wire [47:0] out_data;
    c1_r2_pw16x8_tile u_tile(.*);
    assign result_data=result_row<6 ? out_data[result_row*8+:8] : 8'd0;
endmodule
