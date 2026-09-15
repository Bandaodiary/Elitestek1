// R2 independently loaded/observed arithmetic probe, Ti60F225 I3.
module c1_ti60_r2_array128(
    input wire clk,rst,load_valid,
    input wire [6:0] load_addr,
    input wire [31:0] load_data,
    input wire issue_valid,issue_first,issue_last,
    output wire issue_ready,
    input wire [7:0] issue_mask,
    input wire [7:0] issue_tag,
    output wire result_valid,
    input wire result_ready,
    input wire [2:0] result_row,
    output wire [31:0] result_data,
    output wire [7:0] result_mask,
    output wire [7:0] result_tag,
    output wire busy
);
    c1_r2_array_host_probe #(.ROWS(8)) u_probe(.*);
endmodule
