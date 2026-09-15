`timescale 1ns/1ps

// Optional fully staged eight-lane signed-INT8 dot accumulator.
//
// This module is intentionally separate from c1_s8_dot8_accum_pipelined:
// product, pair, quad and final-dot reductions each have an elastic register
// boundary.  The interface and sequence semantics are otherwise identical to
// the legacy accumulator.  A beat is accepted every clock after pipeline fill
// when downstream is ready; the completed result has four arithmetic stages of
// latency (rather than the legacy single-cycle reduction).
//
// The pipeline carries first/last, bias and frame metadata with every beat.
// The accumulator itself remains a single recurrence at the final stage, so a
// sequence of beats still updates one signed32 state in order.  Backpressure
// propagates from the output through all four stages.  As in the existing
// optional pipeline, input acceptance is additionally gated by output-slot
// availability to preserve the compatibility contract that a held completed
// result blocks a new sequence.
module c1_s8_dot8_accum_treepipe #(
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

    logic signed [15:0] product_comb [0:7];
    logic signed [15:0] product_q [0:7];
    logic signed [16:0] pair_comb [0:3];
    logic signed [16:0] pair_q [0:3];
    logic signed [17:0] quad_comb [0:1];
    logic signed [17:0] quad_q [0:1];
    logic signed [18:0] dot_comb;
    logic signed [18:0] dot_q;

    logic stage0_valid_q, stage1_valid_q, stage2_valid_q, stage3_valid_q;
    logic stage0_first_q, stage0_last_q;
    logic stage1_first_q, stage1_last_q;
    logic stage2_first_q, stage2_last_q;
    logic stage3_first_q, stage3_last_q;
    logic signed [31:0] stage0_bias_q, stage1_bias_q;
    logic signed [31:0] stage2_bias_q, stage3_bias_q;
    logic stage0_sof_q, stage0_eol_q, stage0_eof_q;
    logic stage1_sof_q, stage1_eol_q, stage1_eof_q;
    logic stage2_sof_q, stage2_eol_q, stage2_eof_q;
    logic stage3_sof_q, stage3_eol_q, stage3_eof_q;
    logic [X_BITS-1:0] stage0_x_q, stage1_x_q, stage2_x_q, stage3_x_q;
    logic [Y_BITS-1:0] stage0_y_q, stage1_y_q, stage2_y_q, stage3_y_q;

    logic signed [31:0] accumulator_q;
    logic sequence_active_q;
    logic signed [32:0] accumulator_base_extended;
    logic signed [32:0] accumulator_next_extended;
    logic overflow_comb;
    logic output_slot_ready;
    logic stage3_fire, stage2_fire, stage1_fire, stage0_fire;
    logic stage3_ready, stage2_ready, stage1_ready, stage0_ready;
    logic input_fire;
    integer lane_comb;
    integer lane_seq;

    always_comb begin
        for (lane_comb = 0; lane_comb < 8; lane_comb = lane_comb + 1) begin
            if (in_lane_mask[lane_comb])
                product_comb[lane_comb] =
                    $signed(in_activations_s8[lane_comb*8 +: 8]) *
                    $signed(in_weights_s8[lane_comb*8 +: 8]);
            else
                product_comb[lane_comb] = 16'sd0;
        end

        pair_comb[0] = $signed({product_q[0][15], product_q[0]}) +
                       $signed({product_q[1][15], product_q[1]});
        pair_comb[1] = $signed({product_q[2][15], product_q[2]}) +
                       $signed({product_q[3][15], product_q[3]});
        pair_comb[2] = $signed({product_q[4][15], product_q[4]}) +
                       $signed({product_q[5][15], product_q[5]});
        pair_comb[3] = $signed({product_q[6][15], product_q[6]}) +
                       $signed({product_q[7][15], product_q[7]});
        quad_comb[0] = $signed({pair_q[0][16], pair_q[0]}) +
                       $signed({pair_q[1][16], pair_q[1]});
        quad_comb[1] = $signed({pair_q[2][16], pair_q[2]}) +
                       $signed({pair_q[3][16], pair_q[3]});
        dot_comb = $signed({quad_q[0][17], quad_q[0]}) +
                   $signed({quad_q[1][17], quad_q[1]});

        output_slot_ready = !out_valid || out_ready;

        // The final stage may retire a non-last beat without consuming the
        // output slot.  A last beat requires the slot to be free/replaced.
        stage3_fire = stage3_valid_q &&
                      (!stage3_last_q || output_slot_ready);
        stage3_ready = !stage3_valid_q || stage3_fire;
        stage2_fire = stage2_valid_q && stage3_ready;
        stage2_ready = !stage2_valid_q || stage2_fire;
        stage1_fire = stage1_valid_q && stage2_ready;
        stage1_ready = !stage1_valid_q || stage1_fire;
        stage0_fire = stage0_valid_q && stage1_ready;
        stage0_ready = !stage0_valid_q || stage0_fire;

        // Keep legacy output-stall/new-sequence behavior.  Internal beats can
        // continue draining while a non-last stage3 beat is retiring.
        in_ready = !rst && stage0_ready && output_slot_ready;
        input_fire = in_valid && in_ready;

        if (stage3_first_q)
            accumulator_base_extended =
                {stage3_bias_q[31], stage3_bias_q};
        else
            accumulator_base_extended =
                {accumulator_q[31], accumulator_q};
        accumulator_next_extended = accumulator_base_extended +
                                     $signed({{14{dot_q[18]}}, dot_q});
        overflow_comb = (accumulator_next_extended > 33'sd2147483647) ||
                        (accumulator_next_extended < -33'sd2147483648);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            stage0_valid_q <= 1'b0;
            stage1_valid_q <= 1'b0;
            stage2_valid_q <= 1'b0;
            stage3_valid_q <= 1'b0;
            stage0_first_q <= 1'b0;
            stage0_last_q <= 1'b0;
            stage1_first_q <= 1'b0;
            stage1_last_q <= 1'b0;
            stage2_first_q <= 1'b0;
            stage2_last_q <= 1'b0;
            stage3_first_q <= 1'b0;
            stage3_last_q <= 1'b0;
            stage0_bias_q <= 32'sd0;
            stage1_bias_q <= 32'sd0;
            stage2_bias_q <= 32'sd0;
            stage3_bias_q <= 32'sd0;
            stage0_sof_q <= 1'b0;
            stage0_eol_q <= 1'b0;
            stage0_eof_q <= 1'b0;
            stage1_sof_q <= 1'b0;
            stage1_eol_q <= 1'b0;
            stage1_eof_q <= 1'b0;
            stage2_sof_q <= 1'b0;
            stage2_eol_q <= 1'b0;
            stage2_eof_q <= 1'b0;
            stage3_sof_q <= 1'b0;
            stage3_eol_q <= 1'b0;
            stage3_eof_q <= 1'b0;
            stage0_x_q <= '0;
            stage0_y_q <= '0;
            stage1_x_q <= '0;
            stage1_y_q <= '0;
            stage2_x_q <= '0;
            stage2_y_q <= '0;
            stage3_x_q <= '0;
            stage3_y_q <= '0;
            for (lane_seq = 0; lane_seq < 8; lane_seq = lane_seq + 1)
                product_q[lane_seq] <= 16'sd0;
            for (lane_seq = 0; lane_seq < 4; lane_seq = lane_seq + 1)
                pair_q[lane_seq] <= 17'sd0;
            for (lane_seq = 0; lane_seq < 2; lane_seq = lane_seq + 1)
                quad_q[lane_seq] <= 18'sd0;
            dot_q <= 19'sd0;
            accumulator_q <= 32'sd0;
            sequence_active_q <= 1'b0;
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

            if (stage3_fire) begin
                accumulator_q <= accumulator_next_extended[31:0];
                acc_overflow <= overflow_comb;
                if (stage3_last_q) begin
                    out_valid <= 1'b1;
                    out_acc_s32 <= accumulator_next_extended[31:0];
                    out_sof <= stage3_sof_q;
                    out_eol <= stage3_eol_q;
                    out_eof <= stage3_eof_q;
                    out_x <= stage3_x_q;
                    out_y <= stage3_y_q;
                end
`ifndef SYNTHESIS
                if (ASSERT_ON_OVERFLOW && overflow_comb)
                    $error("c1_s8_dot8_accum_treepipe signed32 accumulator overflow");
`endif
            end

            if (stage3_ready) begin
                stage3_valid_q <= stage2_fire;
                if (stage2_fire) begin
                    stage3_first_q <= stage2_first_q;
                    stage3_last_q <= stage2_last_q;
                    stage3_bias_q <= stage2_bias_q;
                    stage3_sof_q <= stage2_sof_q;
                    stage3_eol_q <= stage2_eol_q;
                    stage3_eof_q <= stage2_eof_q;
                    stage3_x_q <= stage2_x_q;
                    stage3_y_q <= stage2_y_q;
                    dot_q <= dot_comb;
                end else begin
                    stage3_first_q <= 1'b0;
                    stage3_last_q <= 1'b0;
                end
            end

            if (stage2_ready) begin
                stage2_valid_q <= stage1_fire;
                if (stage1_fire) begin
                    stage2_first_q <= stage1_first_q;
                    stage2_last_q <= stage1_last_q;
                    stage2_bias_q <= stage1_bias_q;
                    stage2_sof_q <= stage1_sof_q;
                    stage2_eol_q <= stage1_eol_q;
                    stage2_eof_q <= stage1_eof_q;
                    stage2_x_q <= stage1_x_q;
                    stage2_y_q <= stage1_y_q;
                    quad_q[0] <= quad_comb[0];
                    quad_q[1] <= quad_comb[1];
                end else begin
                    stage2_first_q <= 1'b0;
                    stage2_last_q <= 1'b0;
                end
            end

            if (stage1_ready) begin
                stage1_valid_q <= stage0_fire;
                if (stage0_fire) begin
                    stage1_first_q <= stage0_first_q;
                    stage1_last_q <= stage0_last_q;
                    stage1_bias_q <= stage0_bias_q;
                    stage1_sof_q <= stage0_sof_q;
                    stage1_eol_q <= stage0_eol_q;
                    stage1_eof_q <= stage0_eof_q;
                    stage1_x_q <= stage0_x_q;
                    stage1_y_q <= stage0_y_q;
                    pair_q[0] <= pair_comb[0];
                    pair_q[1] <= pair_comb[1];
                    pair_q[2] <= pair_comb[2];
                    pair_q[3] <= pair_comb[3];
                end else begin
                    stage1_first_q <= 1'b0;
                    stage1_last_q <= 1'b0;
                end
            end

            if (stage0_ready) begin
                stage0_valid_q <= input_fire;
                if (input_fire) begin
                    stage0_first_q <= in_first;
                    stage0_last_q <= in_last;
                    stage0_bias_q <= in_bias_s32;
                    stage0_sof_q <= in_sof;
                    stage0_eol_q <= in_eol;
                    stage0_eof_q <= in_eof;
                    stage0_x_q <= in_x;
                    stage0_y_q <= in_y;
                    for (lane_seq = 0; lane_seq < 8; lane_seq = lane_seq + 1)
                        product_q[lane_seq] <= product_comb[lane_seq];
                end else begin
                    stage0_first_q <= 1'b0;
                    stage0_last_q <= 1'b0;
                end
            end

            if (input_fire)
                sequence_active_q <= !in_last;

`ifndef SYNTHESIS
            if (input_fire && ASSERT_PROTOCOL) begin
                if (in_first && sequence_active_q)
                    $error("c1_s8_dot8_accum_treepipe first asserted inside active sequence");
                if (!in_first && !sequence_active_q)
                    $error("c1_s8_dot8_accum_treepipe continuation without first");
            end
`endif
        end
    end

endmodule
