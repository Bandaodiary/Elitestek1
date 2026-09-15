`timescale 1ns/1ps

// Three-input/three-output pointwise convolution.
//
// Three registered stages sustain one input pixel per clock:
//   product -> balanced sum+bias -> requant
// An input sampled on edge N produces out_valid on edge N+2.
module c1_pwconv1x1_rgb3 #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   in_valid,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,
    input  logic [23:0]            in_rgb,
    input  logic                   cfg_we,
    input  logic [3:0]             cfg_addr,
    input  logic [31:0]            cfg_wdata,
    output logic                   out_valid,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic [23:0]            out_rgb
);
    import c1_fixed_pkg::*;

    logic signed [7:0] weights [0:2][0:2];
    logic signed [31:0] bias [0:2];
    logic [4:0] shift;

    logic signed [16:0] product_pipe [0:2][0:2];
    logic signed [31:0] accum_pipe [0:2];
    logic signed [31:0] product_bias [0:2];
    logic [4:0] product_shift, accum_shift;

    logic product_valid, accum_valid;
    logic product_sof, product_eol, product_eof;
    logic accum_sof, accum_eol, accum_eof;
    logic [X_BITS-1:0] product_x, accum_x;
    logic [Y_BITS-1:0] product_y, accum_y;

    integer oc_pipe, ic_pipe;
    integer oc_reset, ic_reset;
    integer flat_index;

    function automatic logic signed [7:0] default_weight(
        input integer out_channel,
        input integer in_channel
    );
        begin
            default_weight = (out_channel == in_channel) ? 8'sd10 : -8'sd1;
        end
    endfunction

    function automatic logic [7:0] get_channel(
        input logic [23:0] rgb,
        input integer channel
    );
        begin
            case (channel)
                0: get_channel = rgb[23:16];
                1: get_channel = rgb[15:8];
                default: get_channel = rgb[7:0];
            endcase
        end
    endfunction

    function automatic logic [7:0] requant_u8(
        input logic signed [31:0] value,
        input logic [4:0] value_shift
    );
        logic signed [31:0] rounded;
        begin
            rounded = c1_round_shift_s32(value, value_shift);
            requant_u8 = c1_clamp_u8(rounded);
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (oc_reset = 0; oc_reset < 3; oc_reset = oc_reset + 1) begin
                bias[oc_reset] <= 32'sd0;
                for (ic_reset = 0; ic_reset < 3; ic_reset = ic_reset + 1)
                    weights[oc_reset][ic_reset] <= default_weight(oc_reset, ic_reset);
            end
            shift <= 5'd3;

            product_valid <= 1'b0;
            accum_valid <= 1'b0;
            out_valid <= 1'b0;
            product_sof <= 1'b0;
            product_eol <= 1'b0;
            product_eof <= 1'b0;
            accum_sof <= 1'b0;
            accum_eol <= 1'b0;
            accum_eof <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            product_x <= '0;
            product_y <= '0;
            accum_x <= '0;
            accum_y <= '0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            // Stage 0: the nine pointwise products.
            product_valid <= in_valid;
            product_sof <= in_valid && in_sof;
            product_eol <= in_valid && in_eol;
            product_eof <= in_valid && in_eof;
            if (in_valid) begin
                product_x <= in_x;
                product_y <= in_y;
                product_shift <= shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    product_bias[oc_pipe] <= bias[oc_pipe];
                    for (ic_pipe = 0; ic_pipe < 3; ic_pipe = ic_pipe + 1)
                        product_pipe[oc_pipe][ic_pipe] <=
                            $signed({1'b0, get_channel(in_rgb, ic_pipe)}) *
                            weights[oc_pipe][ic_pipe];
                end
            end

            // Stage 1: balanced sum of three products plus bias.
            accum_valid <= product_valid;
            accum_sof <= product_valid && product_sof;
            accum_eol <= product_valid && product_eol;
            accum_eof <= product_valid && product_eof;
            if (product_valid) begin
                accum_x <= product_x;
                accum_y <= product_y;
                accum_shift <= product_shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    accum_pipe[oc_pipe] <=
                        ($signed({{15{product_pipe[oc_pipe][0][16]}}, product_pipe[oc_pipe][0]}) +
                         $signed({{15{product_pipe[oc_pipe][1][16]}}, product_pipe[oc_pipe][1]})) +
                        ($signed({{15{product_pipe[oc_pipe][2][16]}}, product_pipe[oc_pipe][2]}) +
                         product_bias[oc_pipe]);
                end
            end

            // Stage 2: project-defined rounding, shifting and clamp.
            out_valid <= accum_valid;
            out_sof <= accum_valid && accum_sof;
            out_eol <= accum_valid && accum_eol;
            out_eof <= accum_valid && accum_eof;
            if (accum_valid) begin
                out_x <= accum_x;
                out_y <= accum_y;
                out_rgb <= {requant_u8(accum_pipe[0], accum_shift),
                            requant_u8(accum_pipe[1], accum_shift),
                            requant_u8(accum_pipe[2], accum_shift)};
            end

            if (cfg_we) begin
                if (cfg_addr < 4'd9) begin
                    flat_index = cfg_addr;
                    weights[flat_index/3][flat_index%3] <= cfg_wdata[7:0];
                end else if (cfg_addr < 4'd12) begin
                    bias[cfg_addr-4'd9] <= cfg_wdata;
                end else if (cfg_addr == 4'd12) begin
                    shift <= cfg_wdata[4:0];
                end
            end
        end
    end

endmodule
