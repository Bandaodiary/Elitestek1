// Core-only physical probe. Narrow result mux keeps all six rows observable;
// not a board pinout, CPU wrapper, DDR controller, or full CNN frame engine.
module c1_ti60_r2_operator96(
    input wire clk,rst,
    input wire [2:0] mode,
    input wire load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [13:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [13:0] start_size,
    input wire [5:0] start_channels,start_outputs,
    input wire row_top,row_bottom,virtual_up2,row_phase,
    output wire busy,out_valid,
    input wire out_ready,
    input wire [2:0] result_row,
    output wire [7:0] result_data,
    output wire [5:0] out_mask,
    output wire [15:0] out_index,
    output wire [2:0] out_mode,
    output wire out_last
);
    wire [47:0] out_data;
    c1_r2_cnn_operator_engine u_engine(.*);
    assign result_data=result_row<6 ? out_data[result_row*8+:8] : 8'd0;
endmodule
