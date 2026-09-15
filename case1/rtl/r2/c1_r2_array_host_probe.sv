`timescale 1ns/1ps
// Small-IO resource probe with externally writable, independent operands.
// Every product, bias and result is controllable/observable; no LFSR/constant
// stimulus or XOR-only observation allows lane merging/pruning. These input
// assembly registers are NOT a demonstrated full-bandwidth tile scratchpad.
module c1_r2_array_host_probe #(parameter integer ROWS=8)(
    input wire clk,rst,
    input wire load_valid,
    input wire [6:0] load_addr,
    input wire [31:0] load_data,
    input wire issue_valid,issue_first,issue_last,
    output wire issue_ready,
    input wire [ROWS-1:0] issue_mask,
    input wire [7:0] issue_tag,
    output wire result_valid,
    input wire result_ready,
    input wire [2:0] result_row,
    output wire [31:0] result_data,
    output wire [ROWS-1:0] result_mask,
    output wire [7:0] result_tag,
    output wire busy
);
    logic [ROWS*128-1:0] a_q,b_q;
    logic [ROWS*32-1:0] bias_q;
    wire [ROWS*32-1:0] result_all;
    generate for(genvar r=0;r<ROWS;r=r+1) begin : g_host_row
        for(genvar k=0;k<4;k=k+1) begin : g_word
            always @(posedge clk) if(load_valid && !rst) begin
                if(load_addr==r*4+k) a_q[(r*4+k)*32+:32]<=load_data;
                if(load_addr==32+r*4+k) b_q[(r*4+k)*32+:32]<=load_data;
            end
        end
        always @(posedge clk) if(load_valid && !rst && load_addr==64+r)
            bias_q[r*32+:32]<=load_data;
    end endgenerate
    assign result_data=(result_row<ROWS) ? result_all[result_row*32+:32] : 32'd0;
    c1_r2_dot16_array #(.ROWS(ROWS),.TAG_BITS(8)) u_array(
        .clk,.rst,.in_valid(issue_valid),.in_ready(issue_ready),
        .in_first(issue_first),.in_last(issue_last),.in_mask(issue_mask),.in_tag(issue_tag),
        .in_a(a_q),.in_b(b_q),.in_bias(bias_q),
        .out_valid(result_valid),.out_ready(result_ready),.out_mask(result_mask),
        .out_tag(result_tag),.out_acc(result_all),.busy
    );
endmodule
