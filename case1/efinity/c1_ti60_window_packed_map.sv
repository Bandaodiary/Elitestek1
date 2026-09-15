// C29 independent leaf MAP comparison, NOT a pin-compatible board top.
module c1_ti60_window_packed_map (
    input wire clk,rst,write_en,
    input wire [13:0] write_addr, // {row[1:0],parity,bank_word[9:0],word32}
    input wire [31:0] write_data,
    input wire bulk_en,
    input wire [1:0] bulk_row,
    input wire [9:0] bulk_pair,
    input wire [2:0] bulk_group,bulk_groups,
    input wire [127:0] bulk_data,
    input wire linear_rd_en,
    input wire [17:0] linear_rd_addr,
    output wire [255:0] linear_rd_data,
    input wire [7:0] linear_wr_en,
    input wire [71:0] linear_wr_addr,
    input wire [255:0] linear_wr_data,
    input wire req_valid,
    output wire req_ready,
    input wire [9:0] req_x,
    input wire [10:0] req_width,
    input wire [2:0] req_group,req_groups,
    input wire req_top,req_bottom,
    input wire req_up2,req_row_phase,
    input wire [5:0] req_row_map,
    output wire out_valid,
    input wire out_ready,
    output wire [9:0] out_x,
    output wire [2:0] out_group,
    output wire [767:0] out_window
);
    c1_r2_overlay_window_store_packed u_leaf(.*);
endmodule
