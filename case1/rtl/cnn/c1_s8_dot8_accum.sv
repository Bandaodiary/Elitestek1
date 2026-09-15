`timescale 1ns/1ps

// R1 signed-INT8, eight-lane dot-product accumulator for one output channel.
//
// Packed lane 0 is bits [7:0], lane 7 is [63:56].  Activations correspond to
// eight adjacent HWC input channels; weights correspond to the same eight
// adjacent input-channel entries in one OI output-channel row.  lane_mask
// suppresses padding lanes in the final input-channel group.
//
// first starts a new dot product from bias_s32.  last emits the completed
// signed32 accumulator and its metadata.  Accepted non-last beats update the
// internal accumulator.  The module accepts one eight-MAC beat per clock when
// its single output register is not stalled.
//
// This is not a convolution window/address generator.  Eight output channels
// in parallel require eight instances driven with eight independent OI weight
// rows, followed for example by c1_requant_bank8.
module c1_s8_dot8_accum #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9,
    parameter bit ASSERT_ON_OVERFLOW = 1'b1,
    parameter bit ASSERT_PROTOCOL = 1'b1
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic                   in_first,
    input  logic                   in_last,
    input  logic [7:0]             in_lane_mask,
    input  logic [63:0]            in_activations_s8,
    input  logic [63:0]            in_weights_s8,
    input  logic signed [31:0]     in_bias_s32,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic signed [31:0]     out_acc_s32,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic                   acc_overflow
);

    logic signed [31:0] accumulator_q;
    logic sequence_active;

    logic signed [15:0] lane_product [0:7];
    logic signed [16:0] pair_sum [0:3];
    logic signed [17:0] quad_sum [0:1];
    logic signed [18:0] dot_sum;
    logic signed [32:0] accumulator_base_extended;
    logic signed [32:0] accumulator_next_extended;
    logic overflow_comb;
    integer lane;

    always_comb begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (in_lane_mask[lane])
                lane_product[lane] =
                    $signed(in_activations_s8[lane*8 +: 8]) *
                    $signed(in_weights_s8[lane*8 +: 8]);
            else
                lane_product[lane] = 16'sd0;
        end

        pair_sum[0] = $signed({lane_product[0][15], lane_product[0]}) +
                      $signed({lane_product[1][15], lane_product[1]});
        pair_sum[1] = $signed({lane_product[2][15], lane_product[2]}) +
                      $signed({lane_product[3][15], lane_product[3]});
        pair_sum[2] = $signed({lane_product[4][15], lane_product[4]}) +
                      $signed({lane_product[5][15], lane_product[5]});
        pair_sum[3] = $signed({lane_product[6][15], lane_product[6]}) +
                      $signed({lane_product[7][15], lane_product[7]});
        quad_sum[0] = $signed({pair_sum[0][16], pair_sum[0]}) +
                      $signed({pair_sum[1][16], pair_sum[1]});
        quad_sum[1] = $signed({pair_sum[2][16], pair_sum[2]}) +
                      $signed({pair_sum[3][16], pair_sum[3]});
        dot_sum = $signed({quad_sum[0][17], quad_sum[0]}) +
                  $signed({quad_sum[1][17], quad_sum[1]});

        if (in_first)
            accumulator_base_extended = {in_bias_s32[31], in_bias_s32};
        else
            accumulator_base_extended = {accumulator_q[31], accumulator_q};
        accumulator_next_extended = accumulator_base_extended +
                                    $signed({{14{dot_sum[18]}}, dot_sum});
        overflow_comb = (accumulator_next_extended > 33'sd2147483647) ||
                        (accumulator_next_extended < -33'sd2147483648);

        in_ready = !out_valid || out_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            accumulator_q <= 32'sd0;
            sequence_active <= 1'b0;
            out_valid <= 1'b0;
            out_acc_s32 <= 32'sd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            acc_overflow <= 1'b0;
        end else begin
            acc_overflow <= 1'b0;

            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                out_sof <= 1'b0;
                out_eol <= 1'b0;
                out_eof <= 1'b0;
            end

            if (in_valid && in_ready) begin
                acc_overflow <= overflow_comb;
                accumulator_q <= accumulator_next_extended[31:0];
                sequence_active <= !in_last;

`ifndef SYNTHESIS
                if (ASSERT_PROTOCOL) begin
                    if (in_first && sequence_active)
                        $error("c1_s8_dot8_accum first asserted inside active sequence");
                    if (!in_first && !sequence_active)
                        $error("c1_s8_dot8_accum continuation without first");
                end
                if (ASSERT_ON_OVERFLOW && overflow_comb)
                    $error("c1_s8_dot8_accum signed32 accumulator overflow");
`endif

                if (in_last) begin
                    out_valid <= 1'b1;
                    out_acc_s32 <= accumulator_next_extended[31:0];
                    out_sof <= in_sof;
                    out_eol <= in_eol;
                    out_eof <= in_eof;
                    out_x <= in_x;
                    out_y <= in_y;
                end
            end
        end
    end

endmodule
