// Programmable AWB and 3x3 colour-correction matrix.
// Gain is unsigned Q8.8; CCM coefficients are signed Q3.14; offsets are signed
// output-code values. Both stages use the project's symmetric rounding rule.
//
// The arithmetic is split at every multiplier/adder boundary so the module can
// accept one pixel per clock without an AWB-multiply -> CCM-multiply cascade.
// Configuration is snapshotted with each accepted pixel, which also makes an
// in-flight pixel deterministic if software writes a coefficient mid-stream.
`timescale 1ns/1ps

module c1_color_correct #(
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
    input  logic [5:0]            cfg_addr,
    input  logic [31:0]           cfg_wdata,
    output logic                  out_valid,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y,
    output logic [23:0]           out_rgb
);
    import c1_fixed_pkg::*;

    logic [15:0] awb_gain [0:2];
    logic signed [17:0] ccm [0:2][0:2];
    logic signed [15:0] offset [0:2];

    // S0: AWB products and an atomic snapshot of the colour configuration.
    logic signed [31:0] awb_product_s0 [0:2];
    logic signed [17:0] ccm_s0 [0:2][0:2];
    logic signed [15:0] offset_s0 [0:2];

    // S1: rounded/clamped AWB channels.
    logic [7:0] gained_s1 [0:2];
    logic signed [17:0] ccm_s1 [0:2][0:2];
    logic signed [15:0] offset_s1 [0:2];

    // S2: the nine independent CCM products.
    logic signed [31:0] ccm_product_s2 [0:2][0:2];
    logic signed [15:0] offset_s2 [0:2];

    // S3: three complete Q14 matrix accumulators.
    logic signed [31:0] matrix_acc_s3 [0:2];

    logic [3:0] valid_pipe;
    logic [3:0] sof_pipe;
    logic [3:0] eol_pipe;
    logic [3:0] eof_pipe;
    logic [X_BITS-1:0] x_pipe [0:3];
    logic [Y_BITS-1:0] y_pipe [0:3];

    integer ch;
    integer src;
    integer stage;
    integer flat_index;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (ch = 0; ch < 3; ch = ch + 1) begin
                awb_gain[ch] <= 16'd256;
                offset[ch] <= 16'sd0;
                awb_product_s0[ch] <= 32'sd0;
                offset_s0[ch] <= 16'sd0;
                gained_s1[ch] <= 8'd0;
                offset_s1[ch] <= 16'sd0;
                offset_s2[ch] <= 16'sd0;
                matrix_acc_s3[ch] <= 32'sd0;
                for (src = 0; src < 3; src = src + 1) begin
                    ccm[ch][src] <= (ch == src) ? 18'sd16384 : 18'sd0;
                    ccm_s0[ch][src] <= 18'sd0;
                    ccm_s1[ch][src] <= 18'sd0;
                    ccm_product_s2[ch][src] <= 32'sd0;
                end
            end
            valid_pipe <= 4'b0000;
            sof_pipe <= 4'b0000;
            eol_pipe <= 4'b0000;
            eof_pipe <= 4'b0000;
            for (stage = 0; stage < 4; stage = stage + 1) begin
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
            // Sidebands pass through the same four internal arithmetic stages.
            valid_pipe[0] <= in_valid;
            sof_pipe[0] <= in_valid && in_sof;
            eol_pipe[0] <= in_valid && in_eol;
            eof_pipe[0] <= in_valid && in_eof;
            x_pipe[0] <= in_x;
            y_pipe[0] <= in_y;
            for (stage = 1; stage < 4; stage = stage + 1) begin
                valid_pipe[stage] <= valid_pipe[stage-1];
                sof_pipe[stage] <= sof_pipe[stage-1];
                eol_pipe[stage] <= eol_pipe[stage-1];
                eof_pipe[stage] <= eof_pipe[stage-1];
                x_pipe[stage] <= x_pipe[stage-1];
                y_pipe[stage] <= y_pipe[stage-1];
            end

            if (in_valid) begin
                awb_product_s0[0] <= $signed({1'b0, in_rgb[23:16]}) *
                                     $signed({1'b0, awb_gain[0]});
                awb_product_s0[1] <= $signed({1'b0, in_rgb[15:8]}) *
                                     $signed({1'b0, awb_gain[1]});
                awb_product_s0[2] <= $signed({1'b0, in_rgb[7:0]}) *
                                     $signed({1'b0, awb_gain[2]});
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    offset_s0[ch] <= offset[ch];
                    for (src = 0; src < 3; src = src + 1)
                        ccm_s0[ch][src] <= ccm[ch][src];
                end
            end

            if (valid_pipe[0]) begin
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    gained_s1[ch] <= c1_clamp_u8(
                        c1_round_shift_s32(awb_product_s0[ch], 5'd8));
                    offset_s1[ch] <= offset_s0[ch];
                    for (src = 0; src < 3; src = src + 1)
                        ccm_s1[ch][src] <= ccm_s0[ch][src];
                end
            end

            if (valid_pipe[1]) begin
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    offset_s2[ch] <= offset_s1[ch];
                    for (src = 0; src < 3; src = src + 1)
                        ccm_product_s2[ch][src] <=
                            $signed({1'b0, gained_s1[src]}) * ccm_s1[ch][src];
                end
            end

            if (valid_pipe[2]) begin
                for (ch = 0; ch < 3; ch = ch + 1)
                    matrix_acc_s3[ch] <=
                        ($signed(ccm_product_s2[ch][0]) +
                         $signed(ccm_product_s2[ch][1])) +
                        ($signed(ccm_product_s2[ch][2]) +
                         ($signed({{16{offset_s2[ch][15]}}, offset_s2[ch]}) <<< 14));
            end

            out_valid <= valid_pipe[3];
            out_sof <= valid_pipe[3] && sof_pipe[3];
            out_eol <= valid_pipe[3] && eol_pipe[3];
            out_eof <= valid_pipe[3] && eof_pipe[3];
            if (valid_pipe[3]) begin
                out_x <= x_pipe[3];
                out_y <= y_pipe[3];
                out_rgb <= {
                    c1_clamp_u8(c1_round_shift_s32(matrix_acc_s3[0], 5'd14)),
                    c1_clamp_u8(c1_round_shift_s32(matrix_acc_s3[1], 5'd14)),
                    c1_clamp_u8(c1_round_shift_s32(matrix_acc_s3[2], 5'd14))
                };
            end

            if (cfg_we) begin
                if (cfg_addr < 6'd3)
                    awb_gain[cfg_addr] <= cfg_wdata[15:0];
                else if ((cfg_addr >= 6'd16) && (cfg_addr < 6'd25)) begin
                    flat_index = cfg_addr - 6'd16;
                    ccm[flat_index/3][flat_index%3] <= cfg_wdata[17:0];
                end else if ((cfg_addr >= 6'd32) && (cfg_addr < 6'd35))
                    offset[cfg_addr-6'd32] <= cfg_wdata[15:0];
            end
        end
    end
endmodule
