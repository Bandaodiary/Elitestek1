// Independently observable RGB3 row executor; no peripheral or DMA model.
module c1_ti60_r2_rgb96(
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [12:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [10:0] row_width,
    input wire row_top,row_bottom,
    output wire busy,out_valid,
    input wire out_ready,
    input wire [2:0] result_row,
    output wire [7:0] result_data,
    output wire [5:0] out_mask,
    output wire [9:0] out_x,
    output wire out_last
);
    wire [47:0] out_data;
    c1_r2_rgb3x3_row u_row(.*);
    assign result_data=result_row<6 ? out_data[result_row*8+:8] : 8'd0;
endmodule
