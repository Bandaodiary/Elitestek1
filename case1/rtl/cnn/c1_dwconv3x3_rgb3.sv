`timescale 1ns/1ps

// Three-channel depthwise 3x3 convolution.
//
// Four registered stages sustain one input window per clock:
//   product -> 3 sums of 3 -> final sum+bias -> requant
// An input sampled on edge N produces out_valid on edge N+3.
module c1_dwconv3x3_rgb3 #(
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
    input  logic [9*24-1:0]        in_window,
    input  logic                   cfg_we,
    input  logic [5:0]             cfg_addr,
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

    logic signed [7:0] weights [0:2][0:2][0:2];
    logic signed [31:0] bias [0:2];
    logic [4:0] shift;

    logic signed [16:0] product_pipe [0:2][0:8];
    logic signed [17:0] sum_pipe [0:2][0:2];
    logic signed [31:0] accum_pipe [0:2];
    logic signed [31:0] product_bias [0:2];
    logic signed [31:0] sum_bias [0:2];
    logic [4:0] product_shift, sum_shift, accum_shift;

    logic product_valid, sum_valid, accum_valid;
    logic product_sof, product_eol, product_eof;
    logic sum_sof, sum_eol, sum_eof;
    logic accum_sof, accum_eol, accum_eof;
    logic [X_BITS-1:0] product_x, sum_x, accum_x;
    logic [Y_BITS-1:0] product_y, sum_y, accum_y;

    integer channel_pipe, ky_pipe, kx_pipe, group_pipe;
    integer channel_reset, ky_reset, kx_reset;
    integer flat_index;

    function automatic logic signed [7:0] default_weight(
        input integer row,
        input integer column
    );
        begin
            case (row*3+column)
                1, 3, 5, 7: default_weight = -8'sd1;
                4: default_weight = 8'sd5;
                default: default_weight = 8'sd0;
            endcase
        end
    endfunction

    function automatic logic [7:0] get_channel(
        input logic [23:0] rgb,
        input integer select_channel
    );
        begin
            case (select_channel)
                0: get_channel = rgb[23:16];
                1: get_channel = rgb[15:8];
                default: get_channel = rgb[7:0];
            endcase
        end
    endfunction

    function automatic logic signed [17:0] add3_s17(
        input logic signed [16:0] a,
        input logic signed [16:0] b,
        input logic signed [16:0] c
    );
        begin
            add3_s17 = $signed({a[16], a}) +
                       $signed({b[16], b}) +
                       $signed({c[16], c});
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
            for (channel_reset = 0; channel_reset < 3; channel_reset = channel_reset + 1) begin
                bias[channel_reset] <= 32'sd0;
                for (ky_reset = 0; ky_reset < 3; ky_reset = ky_reset + 1)
                    for (kx_reset = 0; kx_reset < 3; kx_reset = kx_reset + 1)
                        weights[channel_reset][ky_reset][kx_reset]
                            <= default_weight(ky_reset, kx_reset);
            end
            shift <= 5'd0;

            product_valid <= 1'b0;
            sum_valid <= 1'b0;
            accum_valid <= 1'b0;
            out_valid <= 1'b0;
            product_sof <= 1'b0;
            product_eol <= 1'b0;
            product_eof <= 1'b0;
            sum_sof <= 1'b0;
            sum_eol <= 1'b0;
            sum_eof <= 1'b0;
            accum_sof <= 1'b0;
            accum_eol <= 1'b0;
            accum_eof <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            product_x <= '0;
            product_y <= '0;
            sum_x <= '0;
            sum_y <= '0;
            accum_x <= '0;
            accum_y <= '0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            // Stage 0: nine independent products for every channel.
            product_valid <= in_valid;
            product_sof <= in_valid && in_sof;
            product_eol <= in_valid && in_eol;
            product_eof <= in_valid && in_eof;
            if (in_valid) begin
                product_x <= in_x;
                product_y <= in_y;
                product_shift <= shift;
                for (channel_pipe = 0; channel_pipe < 3; channel_pipe = channel_pipe + 1) begin
                    product_bias[channel_pipe] <= bias[channel_pipe];
                    for (ky_pipe = 0; ky_pipe < 3; ky_pipe = ky_pipe + 1) begin
                        for (kx_pipe = 0; kx_pipe < 3; kx_pipe = kx_pipe + 1) begin
                            product_pipe[channel_pipe][ky_pipe*3+kx_pipe] <=
                                $signed({1'b0, get_channel(
                                    in_window[(ky_pipe*3+kx_pipe)*24 +: 24], channel_pipe)}) *
                                weights[channel_pipe][ky_pipe][kx_pipe];
                        end
                    end
                end
            end

            // Stage 1: reduce the nine products to three groups.
            sum_valid <= product_valid;
            sum_sof <= product_valid && product_sof;
            sum_eol <= product_valid && product_eol;
            sum_eof <= product_valid && product_eof;
            if (product_valid) begin
                sum_x <= product_x;
                sum_y <= product_y;
                sum_shift <= product_shift;
                for (channel_pipe = 0; channel_pipe < 3; channel_pipe = channel_pipe + 1) begin
                    sum_bias[channel_pipe] <= product_bias[channel_pipe];
                    for (group_pipe = 0; group_pipe < 3; group_pipe = group_pipe + 1)
                        sum_pipe[channel_pipe][group_pipe] <= add3_s17(
                            product_pipe[channel_pipe][group_pipe*3],
                            product_pipe[channel_pipe][group_pipe*3+1],
                            product_pipe[channel_pipe][group_pipe*3+2]);
                end
            end

            // Stage 2: balanced final sum with the per-pixel bias snapshot.
            accum_valid <= sum_valid;
            accum_sof <= sum_valid && sum_sof;
            accum_eol <= sum_valid && sum_eol;
            accum_eof <= sum_valid && sum_eof;
            if (sum_valid) begin
                accum_x <= sum_x;
                accum_y <= sum_y;
                accum_shift <= sum_shift;
                for (channel_pipe = 0; channel_pipe < 3; channel_pipe = channel_pipe + 1) begin
                    accum_pipe[channel_pipe] <=
                        ($signed({{14{sum_pipe[channel_pipe][0][17]}}, sum_pipe[channel_pipe][0]}) +
                         $signed({{14{sum_pipe[channel_pipe][1][17]}}, sum_pipe[channel_pipe][1]})) +
                        ($signed({{14{sum_pipe[channel_pipe][2][17]}}, sum_pipe[channel_pipe][2]}) +
                         sum_bias[channel_pipe]);
                end
            end

            // Stage 3: project-defined rounding, shifting and clamp.
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
                if (cfg_addr < 6'd27) begin
                    flat_index = cfg_addr;
                    weights[flat_index/9][(flat_index%9)/3][flat_index%3] <= cfg_wdata[7:0];
                end else if (cfg_addr < 6'd30) begin
                    bias[cfg_addr-6'd27] <= cfg_wdata;
                end else if (cfg_addr == 6'd30) begin
                    shift <= cfg_wdata[4:0];
                end
            end
        end
    end

endmodule
