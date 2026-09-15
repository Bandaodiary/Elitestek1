`timescale 1ns/1ps
// R2 feasibility primitive, NOT integrated in the R1 SoC.
// ROWS independent scalar outputs x 16 signed INT8 products per beat.
// Unlike R1 dot8x8, each row has its own activation vector, permitting
// flattened (pixel, output-channel) rows, including RGB across pixels.
// first starts bias+dot, subsequent beats accumulate modulo 2^32; last
// emits ROWS results. Tags/masks must be constant within a transaction.
// No separate START bubble: consecutive single-beat transactions are legal.
// A global elastic enable freezes ALL arithmetic and metadata on output
// backpressure. Reset flushes this local pipeline, not any external AXI.
// Requantization, window/weight storage and load/store are OUTSIDE this probe.
module c1_r2_dot16_array #(
    parameter integer ROWS=8,
    parameter integer TAG_BITS=16
) (
    input logic clk, rst,
    input logic in_valid,
    output wire in_ready,
    input logic in_first, in_last,
    input logic [ROWS-1:0] in_mask,
    input logic [TAG_BITS-1:0] in_tag,
    input logic [ROWS*128-1:0] in_a, in_b,
    input logic [ROWS*32-1:0] in_bias,
    output logic out_valid,
    input logic out_ready,
    output logic [ROWS-1:0] out_mask,
    output logic [TAG_BITS-1:0] out_tag,
    output logic [ROWS*32-1:0] out_acc,
    output wire busy
);
    initial if(ROWS<1 || ROWS>8 || TAG_BITS<1) $fatal(1,"bad R2 array shape");
    wire advance=!out_valid || out_ready;
    assign in_ready=advance && !rst;
    logic [4:0] valid_q, first_q, last_q;
    logic [ROWS-1:0] mask_q[0:4];
    logic [TAG_BITS-1:0] tag_q[0:4];
    logic [ROWS*32-1:0] bias_q[0:4];
    logic input_open_q;
    assign busy=(|valid_q) || out_valid || input_open_q;

    always_ff @(posedge clk) begin
        if(rst) begin
            valid_q<=0; first_q<=0; last_q<=0;
            out_valid<=0; out_mask<=0; out_tag<=0; input_open_q<=0;
        end else if(advance) begin
            valid_q<={valid_q[3:0],in_valid};
            first_q<={first_q[3:0],in_first};
            last_q<={last_q[3:0],in_last};
            if(in_valid) begin
                mask_q[0]<=in_mask; tag_q[0]<=in_tag; bias_q[0]<=in_bias;
                input_open_q<=!in_last;
            end
            for(integer p=1;p<5;p=p+1) if(valid_q[p-1]) begin
                mask_q[p]<=mask_q[p-1]; tag_q[p]<=tag_q[p-1]; bias_q[p]<=bias_q[p-1];
            end
            out_valid<=valid_q[4] && last_q[4];
            if(valid_q[4] && last_q[4]) begin
                out_mask<=mask_q[4]; out_tag<=tag_q[4];
            end
        end
    end

    generate for(genvar r=0;r<ROWS;r=r+1) begin : g_row
        logic signed [15:0] product_q[0:15];
        logic signed [16:0] pair_q[0:7];
        logic signed [17:0] quad_q[0:3];
        logic signed [18:0] oct_q[0:1];
        logic signed [19:0] sum_q;
        logic [31:0] acc_q;
        wire [31:0] sum32={{12{sum_q[19]}},sum_q};
        wire [31:0] next_acc=(first_q[4] ? bias_q[4][r*32+:32] : acc_q)+sum32;
        for(genvar k=0;k<16;k=k+1) begin : g_product
            wire signed [7:0] a=$signed(in_a[(r*16+k)*8+:8]);
            wire signed [7:0] b=$signed(in_b[(r*16+k)*8+:8]);
            (* use_dsp="yes" *) wire signed [15:0] product=a*b;
            always_ff @(posedge clk) if(!rst && advance && in_valid) product_q[k]<=product;
        end
        always_ff @(posedge clk) begin
            if(!rst && advance) begin
                if(valid_q[0]) for(integer k=0;k<8;k=k+1)
                    pair_q[k]<=$signed({product_q[2*k][15],product_q[2*k]})+
                               $signed({product_q[2*k+1][15],product_q[2*k+1]});
                if(valid_q[1]) for(integer k=0;k<4;k=k+1)
                    quad_q[k]<=$signed({pair_q[2*k][16],pair_q[2*k]})+
                               $signed({pair_q[2*k+1][16],pair_q[2*k+1]});
                if(valid_q[2]) for(integer k=0;k<2;k=k+1)
                    oct_q[k]<=$signed({quad_q[2*k][17],quad_q[2*k]})+
                              $signed({quad_q[2*k+1][17],quad_q[2*k+1]});
                if(valid_q[3]) sum_q<=$signed({oct_q[0][18],oct_q[0]})+
                                      $signed({oct_q[1][18],oct_q[1]});
            end
            if(rst) begin
                acc_q<=0; out_acc[r*32+:32]<=0;
            end else if(advance && valid_q[4]) begin
                acc_q<=next_acc;
                if(last_q[4]) out_acc[r*32+:32]<=mask_q[4][r] ? next_acc : 32'd0;
            end
        end
    end endgenerate
`ifndef SYNTHESIS
    logic held_q;
    logic [ROWS*32+ROWS+TAG_BITS-1:0] held_payload_q;
    always @(posedge clk) begin
        if(rst) held_q<=0;
        else begin
            if(held_q && (!out_valid || {out_acc,out_mask,out_tag}!==held_payload_q))
                $fatal(1,"R2 array changed held output");
            if(in_valid && in_ready && (in_first == input_open_q))
                $fatal(1,"R2 array transaction first/last contract");
            held_q<=out_valid && !out_ready;
            held_payload_q<={out_acc,out_mask,out_tag};
        end
    end
`endif
endmodule
