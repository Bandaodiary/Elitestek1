// Seventeen-point, piecewise-linear gamma LUT. Nine-bit knot values allow an
// exact identity endpoint at 256; the final result is saturated to RGB888.
// The lookup, delta, interpolation and output quantization are independently
// registered so the 17-way LUT mux is not in the output-register critical path.
`timescale 1ns/1ps

module c1_gamma_lut16 #(
    parameter integer FRAME_WIDTH  = 2560,
    parameter integer FRAME_HEIGHT = 1440,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  in_valid,
    input  logic                  in_sof,
    input  logic                  in_eol,
    input  logic                  in_eof,
    input  logic [X_BITS-1:0]     in_x,
    input  logic [Y_BITS-1:0]     in_y,
    input  logic [23:0]           in_rgb,
    input  logic                  cfg_we,
    input  logic [4:0]            cfg_addr,
    input  logic [8:0]            cfg_wdata,
    output logic                  out_valid,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y,
    output logic [23:0]           out_rgb
);
    logic [8:0] lut [0:16];

    // S0: snapshot the two selected knots and the four-bit fraction.
    logic [8:0] lower_s0 [0:2];
    logic [8:0] upper_s0 [0:2];
    logic [3:0] fraction_s0 [0:2];

    // S1: signed endpoint delta. The lower endpoint remains unsigned.
    logic signed [10:0] delta_s1 [0:2];
    logic [8:0] lower_s1 [0:2];
    logic [3:0] fraction_s1 [0:2];

    // S2: Q4 interpolation numerator, including the half-up rounding bias.
    logic signed [16:0] interp_s2 [0:2];

    logic [2:0] valid_pipe;
    logic [2:0] sof_pipe;
    logic [2:0] eol_pipe;
    logic [2:0] eof_pipe;
    logic [X_BITS-1:0] x_pipe [0:2];
    logic [Y_BITS-1:0] y_pipe [0:2];

    logic [7:0] input_channel [0:2];
    logic [3:0] input_segment [0:2];
    logic [8:0] selected_lower [0:2];
    logic [8:0] selected_upper [0:2];
    integer ch_comb;
    integer ch;
    integer stage;
    integer knot_reset;

    function automatic logic [7:0] gamma_quantize(
        input logic signed [16:0] numerator
    );
        logic signed [16:0] rounded;
        begin
            rounded = numerator >>> 4;
            if (rounded < 0)
                gamma_quantize = 8'h00;
            else if (rounded > 17'sd255)
                gamma_quantize = 8'hff;
            else
                gamma_quantize = rounded[7:0];
        end
    endfunction

    always_comb begin
        input_channel[0] = in_rgb[23:16];
        input_channel[1] = in_rgb[15:8];
        input_channel[2] = in_rgb[7:0];
        for (ch_comb = 0; ch_comb < 3; ch_comb = ch_comb + 1) begin
            input_segment[ch_comb] = input_channel[ch_comb][7:4];
            // Keep both dynamic unpacked-array reads in one combinational
            // block. Vivado xsim 2023.1 otherwise mis-indexes the bare lower
            // read when it appears directly in the sequential for-loop.
            selected_lower[ch_comb] = lut[input_channel[ch_comb][7:4]];
            selected_upper[ch_comb] = lut[{1'b0, input_channel[ch_comb][7:4]} + 5'd1];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (knot_reset = 0; knot_reset < 17; knot_reset = knot_reset + 1)
                lut[knot_reset] <= knot_reset * 16;
            for (ch = 0; ch < 3; ch = ch + 1) begin
                lower_s0[ch] <= 9'd0;
                upper_s0[ch] <= 9'd0;
                fraction_s0[ch] <= 4'd0;
                delta_s1[ch] <= 11'sd0;
                lower_s1[ch] <= 9'd0;
                fraction_s1[ch] <= 4'd0;
                interp_s2[ch] <= 17'sd0;
            end
            valid_pipe <= 3'b000;
            sof_pipe <= 3'b000;
            eol_pipe <= 3'b000;
            eof_pipe <= 3'b000;
            for (stage = 0; stage < 3; stage = stage + 1) begin
                x_pipe[stage] <= '0;
                y_pipe[stage] <= '0;
            end
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            if (cfg_we && (cfg_addr <= 5'd16))
                lut[cfg_addr] <= cfg_wdata;

            valid_pipe[0] <= in_valid;
            sof_pipe[0] <= in_valid && in_sof;
            eol_pipe[0] <= in_valid && in_eol;
            eof_pipe[0] <= in_valid && in_eof;
            x_pipe[0] <= in_x;
            y_pipe[0] <= in_y;
            for (stage = 1; stage < 3; stage = stage + 1) begin
                valid_pipe[stage] <= valid_pipe[stage-1];
                sof_pipe[stage] <= sof_pipe[stage-1];
                eol_pipe[stage] <= eol_pipe[stage-1];
                eof_pipe[stage] <= eof_pipe[stage-1];
                x_pipe[stage] <= x_pipe[stage-1];
                y_pipe[stage] <= y_pipe[stage-1];
            end

            if (in_valid) begin
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    lower_s0[ch] <= selected_lower[ch];
                    upper_s0[ch] <= selected_upper[ch];
                    fraction_s0[ch] <= input_channel[ch][3:0];
                end
            end

            if (valid_pipe[0]) begin
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    delta_s1[ch] <= $signed({1'b0, upper_s0[ch]}) -
                                    $signed({1'b0, lower_s0[ch]});
                    lower_s1[ch] <= lower_s0[ch];
                    fraction_s1[ch] <= fraction_s0[ch];
                end
            end

            if (valid_pipe[1]) begin
                for (ch = 0; ch < 3; ch = ch + 1)
                    interp_s2[ch] <=
                        ($signed({8'b0, lower_s1[ch]}) <<< 4) +
                        $signed({{6{delta_s1[ch][10]}}, delta_s1[ch]}) *
                        $signed({12'b0, 1'b0, fraction_s1[ch]}) +
                        17'sd8;
            end

            out_valid <= valid_pipe[2];
            out_sof <= valid_pipe[2] && sof_pipe[2];
            out_eol <= valid_pipe[2] && eol_pipe[2];
            out_eof <= valid_pipe[2] && eof_pipe[2];
            if (valid_pipe[2]) begin
                out_x <= x_pipe[2];
                out_y <= y_pipe[2];
                out_rgb <= {
                    gamma_quantize(interp_s2[0]),
                    gamma_quantize(interp_s2[1]),
                    gamma_quantize(interp_s2[2])
                };
            end
        end
    end
endmodule
