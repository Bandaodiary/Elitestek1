`timescale 1ns/1ps

// R1 same-scale signed-INT8 residual addition primitive.
//
// The two inputs are explicitly sign-extended and added in signed9, then
// saturated to signed8.  ReLU, when enabled, is applied after saturation.
// Two registered stages sustain one sample per clock; input edge N appears at
// the output on edge N+1.
module c1_residual_add_s8 #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    in_valid,
    input  logic                    in_sof,
    input  logic                    in_eol,
    input  logic                    in_eof,
    input  logic [X_BITS-1:0]       in_x,
    input  logic [Y_BITS-1:0]       in_y,
    input  logic signed [7:0]       in_main,
    input  logic signed [7:0]       in_skip,
    input  logic                    in_relu,

    output logic                    out_valid,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [X_BITS-1:0]       out_x,
    output logic [Y_BITS-1:0]       out_y,
    output logic signed [7:0]       out_data
);

    wire logic signed [8:0] sum_full;
    assign sum_full = $signed({in_main[7], in_main}) +
                      $signed({in_skip[7], in_skip});

    logic signed [8:0] sum_pipe;
    logic              relu_pipe;
    logic              sum_valid;
    logic              sum_sof;
    logic              sum_eol;
    logic              sum_eof;
    logic [X_BITS-1:0] sum_x;
    logic [Y_BITS-1:0] sum_y;

    function automatic logic signed [7:0] saturate_relu_s9 (
        input logic signed [8:0] value,
        input logic              relu_enable
    );
        logic signed [7:0] saturated;
        begin
            if (value > 9'sd127)
                saturated = 8'sh7f;
            else if (value < -9'sd128)
                saturated = 8'sh80;
            else
                saturated = value[7:0];

            if (relu_enable && saturated[7])
                saturate_relu_s9 = 8'sd0;
            else
                saturate_relu_s9 = saturated;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            sum_pipe  <= '0;
            relu_pipe <= 1'b0;
            sum_valid <= 1'b0;
            sum_sof   <= 1'b0;
            sum_eol   <= 1'b0;
            sum_eof   <= 1'b0;
            sum_x     <= '0;
            sum_y     <= '0;

            out_valid <= 1'b0;
            out_sof   <= 1'b0;
            out_eol   <= 1'b0;
            out_eof   <= 1'b0;
            out_x     <= '0;
            out_y     <= '0;
            out_data  <= '0;
        end else begin
            // Stage 0: exact signed9 residual sum and metadata snapshot.
            sum_valid <= in_valid;
            sum_sof   <= in_valid && in_sof;
            sum_eol   <= in_valid && in_eol;
            sum_eof   <= in_valid && in_eof;
            if (in_valid) begin
                sum_pipe  <= sum_full;
                relu_pipe <= in_relu;
                sum_x     <= in_x;
                sum_y     <= in_y;
            end

            // Stage 1: signed8 saturation followed by optional ReLU.
            out_valid <= sum_valid;
            out_sof   <= sum_valid && sum_sof;
            out_eol   <= sum_valid && sum_eol;
            out_eof   <= sum_valid && sum_eof;
            if (sum_valid) begin
                out_data <= saturate_relu_s9(sum_pipe, relu_pipe);
                out_x    <= sum_x;
                out_y    <= sum_y;
            end
        end
    end

endmodule
