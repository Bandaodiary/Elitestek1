// C2 shared PW/RGB arithmetic probe, reconstructed after C10 name collision.
// The retained C2 execution RTL is unchanged. No CPU/AXI/peripheral functions.
module c1_ti60_r2_shared96 (
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [1:0] mode,load_kind,
    input wire [12:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_size,
    input wire row_top,row_bottom,
    output wire busy,out_valid,
    input wire out_ready,
    input wire [2:0] result_row,
    output wire [7:0] result_data,
    output wire [5:0] out_mask,
    output wire [15:0] out_index,
    output wire [1:0] out_mode,
    output wire out_last
);
    wire [47:0] out_data;
    c1_r2_shared_row_engine u_engine(.*);
    assign result_data=result_row<6 ? out_data[result_row*8+:8] : 8'd0;
endmodule
