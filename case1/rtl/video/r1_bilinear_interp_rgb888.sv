`timescale 1ns/1ps

// R1 RGB888 bilinear interpolation arithmetic core.
//
// The four input pixels are samples at (y0,x0), (y0,x1), (y1,x0), (y1,x1).
// Each horizontal interpolation performs (+2048)>>12 independently; the
// vertical interpolation then performs its own (+2048)>>12, exactly matching
// FIXED_POINT_SPEC.md.  Legal weight pairs each sum to 4096.
//
// This is only the arithmetic/elastic-pipeline core.  It does not implement
// source address generation, a four-sample fetcher, line buffers, or DDR.
// Four elastic registered stages sustain one output per clock when unstalled:
// horizontal interpolation, registered vertical operands, vertical products,
// then rounded vertical sum.  The operand stage prevents a horizontal DSP's
// relatively slow registered P output from feeding a second DSP multiplier in
// the same cycle.
module r1_bilinear_interp_rgb888 #(
    parameter integer X_BITS = 16,
    parameter integer Y_BITS = 16
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,
    input  logic [23:0]            in_rgb_y0x0,
    input  logic [23:0]            in_rgb_y0x1,
    input  logic [23:0]            in_rgb_y1x0,
    input  logic [23:0]            in_rgb_y1x1,
    input  logic [12:0]            in_wx0,
    input  logic [12:0]            in_wx1,
    input  logic [12:0]            in_wy0,
    input  logic [12:0]            in_wy1,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic [23:0]            out_rgb
);

    logic stage0_valid;
    logic stage0_sof;
    logic stage0_eol;
    logic stage0_eof;
    logic [X_BITS-1:0] stage0_x;
    logic [Y_BITS-1:0] stage0_y;
    logic [23:0] stage0_h0;
    logic [23:0] stage0_h1;
    logic [12:0] stage0_wy0;
    logic [12:0] stage0_wy1;

    logic stage0b_valid;
    logic stage0b_sof;
    logic stage0b_eol;
    logic stage0b_eof;
    logic [X_BITS-1:0] stage0b_x;
    logic [Y_BITS-1:0] stage0b_y;
    // Preserve these two arithmetic boundaries as real fabric registers.
    // Without DONT_TOUCH, Vivado register balancing absorbs the operand and
    // product payloads into adjacent DSP PREG/BREG sites and recreates the
    // original DSP-to-DSP critical path despite the explicit RTL stages.
    // Other vendor tools may safely ignore the synthesis attribute.
    (* DONT_TOUCH = "yes" *) logic [23:0] stage0b_h0;
    (* DONT_TOUCH = "yes" *) logic [23:0] stage0b_h1;
    (* DONT_TOUCH = "yes" *) logic [12:0] stage0b_wy0;
    (* DONT_TOUCH = "yes" *) logic [12:0] stage0b_wy1;

    logic stage1_valid;
    logic stage1_sof;
    logic stage1_eol;
    logic stage1_eof;
    logic [X_BITS-1:0] stage1_x;
    logic [Y_BITS-1:0] stage1_y;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_r0;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_r1;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_g0;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_g1;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_b0;
    (* DONT_TOUCH = "yes" *) logic [19:0] stage1_b1;

    logic stage2_ready;
    logic stage1_ready;
    logic stage0b_ready;
    logic stage0_ready;

    function automatic logic [7:0] interpolate_pair_u8 (
        input logic [7:0]  sample0,
        input logic [7:0]  sample1,
        input logic [12:0] weight0,
        input logic [12:0] weight1
    );
        // The resize contract guarantees weight0+weight1=4096.  Therefore
        // the rounded numerator is at most 255*4096+2048=1,046,528,
        // which fits in 20 bits, and bits [19:12] are already an unsigned
        // 8-bit result.  A defensive >255 saturator is unreachable for legal
        // requests and would add a wide carry chain after the DSP cascade.
        logic [19:0] product0;
        logic [19:0] product1;
        logic [19:0] rounded_sum;
        begin
            product0 = sample0 * weight0;
            product1 = sample1 * weight1;
            rounded_sum = product0 + product1 + 20'd2048;
            interpolate_pair_u8 = rounded_sum[19:12];
        end
    endfunction

    function automatic logic [19:0] multiply_u8_q12 (
        input logic [7:0]  sample,
        input logic [12:0] weight
    );
        begin
            multiply_u8_q12 = sample * weight;
        end
    endfunction

    function automatic logic [7:0] round_pair_products_u8 (
        input logic [19:0] product0,
        input logic [19:0] product1
    );
        logic [19:0] rounded_sum;
        begin
            rounded_sum = product0 + product1 + 20'd2048;
            round_pair_products_u8 = rounded_sum[19:12];
        end
    endfunction

`ifndef SYNTHESIS
    // The narrowed arithmetic above intentionally relies on the public Q0.12
    // complement-weight contract.  Fail at the accepting boundary if a
    // future producer violates it instead of silently wrapping the numerator.
    always_ff @(posedge clk) begin
        if (!rst && in_valid && in_ready) begin
            if (({1'b0, in_wx0} + {1'b0, in_wx1}) != 14'd4096)
                $fatal(1, "bilinear X weights must sum to 4096");
            if (({1'b0, in_wy0} + {1'b0, in_wy1}) != 14'd4096)
                $fatal(1, "bilinear Y weights must sum to 4096");
        end
    end
`endif

    always_comb begin
        stage2_ready = !out_valid || out_ready;
        stage1_ready = !stage1_valid || stage2_ready;
        stage0b_ready = !stage0b_valid || stage1_ready;
        stage0_ready = !stage0_valid || stage0b_ready;
        in_ready = stage0_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            stage0_valid <= 1'b0;
            stage0_sof   <= 1'b0;
            stage0_eol   <= 1'b0;
            stage0_eof   <= 1'b0;
            stage0_x     <= '0;
            stage0_y     <= '0;
            stage0_h0    <= 24'h000000;
            stage0_h1    <= 24'h000000;
            stage0_wy0   <= 13'd0;
            stage0_wy1   <= 13'd0;

            stage0b_valid <= 1'b0;
            stage0b_sof   <= 1'b0;
            stage0b_eol   <= 1'b0;
            stage0b_eof   <= 1'b0;
            stage0b_x     <= '0;
            stage0b_y     <= '0;
            stage0b_h0    <= 24'd0;
            stage0b_h1    <= 24'd0;
            stage0b_wy0   <= 13'd0;
            stage0b_wy1   <= 13'd0;

            stage1_valid <= 1'b0;
            stage1_sof   <= 1'b0;
            stage1_eol   <= 1'b0;
            stage1_eof   <= 1'b0;
            stage1_x     <= '0;
            stage1_y     <= '0;
            stage1_r0    <= 20'd0;
            stage1_r1    <= 20'd0;
            stage1_g0    <= 20'd0;
            stage1_g1    <= 20'd0;
            stage1_b0    <= 20'd0;
            stage1_b1    <= 20'd0;

            out_valid    <= 1'b0;
            out_sof      <= 1'b0;
            out_eol      <= 1'b0;
            out_eof      <= 1'b0;
            out_x        <= '0;
            out_y        <= '0;
            out_rgb      <= 24'h000000;
        end else begin
            // Rounded vertical-sum/output stage advances only if empty or
            // consumed.  No multiplier remains on this register boundary.
            if (stage2_ready) begin
                out_valid <= stage1_valid;
                out_sof   <= stage1_valid && stage1_sof;
                out_eol   <= stage1_valid && stage1_eol;
                out_eof   <= stage1_valid && stage1_eof;
                if (stage1_valid) begin
                    out_rgb[23:16] <= round_pair_products_u8(
                        stage1_r0, stage1_r1);
                    out_rgb[15:8] <= round_pair_products_u8(
                        stage1_g0, stage1_g1);
                    out_rgb[7:0] <= round_pair_products_u8(
                        stage1_b0, stage1_b1);
                    out_x <= stage1_x;
                    out_y <= stage1_y;
                end
            end

            // Register both vertical products independently.  This prevents
            // Vivado from cascading two DSPs and a carry chain between the
            // horizontal-result and output registers.
            if (stage1_ready) begin
                stage1_valid <= stage0b_valid;
                stage1_sof   <= stage0b_valid && stage0b_sof;
                stage1_eol   <= stage0b_valid && stage0b_eol;
                stage1_eof   <= stage0b_valid && stage0b_eof;
                if (stage0b_valid) begin
                    stage1_r0 <= multiply_u8_q12(
                        stage0b_h0[23:16], stage0b_wy0);
                    stage1_r1 <= multiply_u8_q12(
                        stage0b_h1[23:16], stage0b_wy1);
                    stage1_g0 <= multiply_u8_q12(
                        stage0b_h0[15:8], stage0b_wy0);
                    stage1_g1 <= multiply_u8_q12(
                        stage0b_h1[15:8], stage0b_wy1);
                    stage1_b0 <= multiply_u8_q12(
                        stage0b_h0[7:0], stage0b_wy0);
                    stage1_b1 <= multiply_u8_q12(
                        stage0b_h1[7:0], stage0b_wy1);
                    stage1_x <= stage0b_x;
                    stage1_y <= stage0b_y;
                end
            end

            // A pure operand register separates horizontal DSP PREG outputs
            // from the vertical multipliers.  It is elastic so a downstream
            // stall freezes samples, weights and metadata as one payload.
            if (stage0b_ready) begin
                stage0b_valid <= stage0_valid;
                stage0b_sof   <= stage0_valid && stage0_sof;
                stage0b_eol   <= stage0_valid && stage0_eol;
                stage0b_eof   <= stage0_valid && stage0_eof;
                if (stage0_valid) begin
                    stage0b_h0 <= stage0_h0;
                    stage0b_h1 <= stage0_h1;
                    stage0b_wy0 <= stage0_wy0;
                    stage0b_wy1 <= stage0_wy1;
                    stage0b_x <= stage0_x;
                    stage0b_y <= stage0_y;
                end
            end

            // Input/horizontal stage can buffer one item behind a stalled
            // output, and otherwise accepts/replaces one item every clock.
            if (stage0_ready) begin
                stage0_valid <= in_valid;
                stage0_sof   <= in_valid && in_sof;
                stage0_eol   <= in_valid && in_eol;
                stage0_eof   <= in_valid && in_eof;
                if (in_valid) begin
                    stage0_h0[23:16] <= interpolate_pair_u8(
                        in_rgb_y0x0[23:16], in_rgb_y0x1[23:16],
                        in_wx0, in_wx1);
                    stage0_h0[15:8] <= interpolate_pair_u8(
                        in_rgb_y0x0[15:8], in_rgb_y0x1[15:8],
                        in_wx0, in_wx1);
                    stage0_h0[7:0] <= interpolate_pair_u8(
                        in_rgb_y0x0[7:0], in_rgb_y0x1[7:0],
                        in_wx0, in_wx1);
                    stage0_h1[23:16] <= interpolate_pair_u8(
                        in_rgb_y1x0[23:16], in_rgb_y1x1[23:16],
                        in_wx0, in_wx1);
                    stage0_h1[15:8] <= interpolate_pair_u8(
                        in_rgb_y1x0[15:8], in_rgb_y1x1[15:8],
                        in_wx0, in_wx1);
                    stage0_h1[7:0] <= interpolate_pair_u8(
                        in_rgb_y1x0[7:0], in_rgb_y1x1[7:0],
                        in_wx0, in_wx1);
                    stage0_wy0 <= in_wy0;
                    stage0_wy1 <= in_wy1;
                    stage0_x   <= in_x;
                    stage0_y   <= in_y;
                end
            end
        end
    end

endmodule
