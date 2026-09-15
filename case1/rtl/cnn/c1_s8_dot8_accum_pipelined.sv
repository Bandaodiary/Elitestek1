`timescale 1ns/1ps

// Optional one-stage arithmetic pipeline for the signed-INT8 eight-lane dot
// accumulator.  The default c1_s8_dot8_accum remains the compatibility path.
//
// Stage 1 registers the complete reduction result (the product/pair/quad tree
// remains combinational in this first experiment).  Stage 2 performs
// the accumulator add and overflow check, then writes the existing elastic
// output register.  The two stages overlap, so a long dot sequence still
// accepts one beat per clock after the first beat.  The extra register adds one
// cycle from the final input beat to out_valid and delays the diagnostic
// overflow pulse by one cycle; numerical output and ready/valid semantics are
// unchanged.
module c1_s8_dot8_accum_pipelined #(
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

    logic signed [15:0] lane_product_comb [0:7];
    logic signed [16:0] pair_sum_comb [0:3];
    logic signed [17:0] quad_sum_comb [0:1];
    logic signed [18:0] dot_sum_comb;

    logic               stage1_valid_q;
    logic               stage1_first_q;
    logic               stage1_last_q;
    logic signed [18:0] stage1_dot_sum_q;
    logic signed [31:0] stage1_bias_q;
    logic               stage1_sof_q;
    logic               stage1_eol_q;
    logic               stage1_eof_q;
    logic [X_BITS-1:0]  stage1_x_q;
    logic [Y_BITS-1:0]  stage1_y_q;

    logic signed [31:0] accumulator_q;
    logic               sequence_active_q;
    logic signed [32:0] accumulator_base_extended;
    logic signed [32:0] accumulator_next_extended;
    logic               overflow_comb;
    logic               output_slot_ready;
    logic               stage2_fire;
    logic               stage1_slot_ready;
    logic               input_fire;
    integer lane;

    always_comb begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (in_lane_mask[lane])
                lane_product_comb[lane] =
                    $signed(in_activations_s8[lane*8 +: 8]) *
                    $signed(in_weights_s8[lane*8 +: 8]);
            else
                lane_product_comb[lane] = 16'sd0;
        end

        pair_sum_comb[0] = $signed({lane_product_comb[0][15], lane_product_comb[0]}) +
                           $signed({lane_product_comb[1][15], lane_product_comb[1]});
        pair_sum_comb[1] = $signed({lane_product_comb[2][15], lane_product_comb[2]}) +
                           $signed({lane_product_comb[3][15], lane_product_comb[3]});
        pair_sum_comb[2] = $signed({lane_product_comb[4][15], lane_product_comb[4]}) +
                           $signed({lane_product_comb[5][15], lane_product_comb[5]});
        pair_sum_comb[3] = $signed({lane_product_comb[6][15], lane_product_comb[6]}) +
                           $signed({lane_product_comb[7][15], lane_product_comb[7]});
        quad_sum_comb[0] = $signed({pair_sum_comb[0][16], pair_sum_comb[0]}) +
                          $signed({pair_sum_comb[1][16], pair_sum_comb[1]});
        quad_sum_comb[1] = $signed({pair_sum_comb[2][16], pair_sum_comb[2]}) +
                          $signed({pair_sum_comb[3][16], pair_sum_comb[3]});
        dot_sum_comb = $signed({quad_sum_comb[0][17], quad_sum_comb[0]}) +
                       $signed({quad_sum_comb[1][17], quad_sum_comb[1]});

        output_slot_ready = !out_valid || out_ready;
        // A non-final stage-1 beat can always advance.  A final beat advances
        // only when the output register can be replaced/consumed.
        stage2_fire = stage1_valid_q &&
                      (!stage1_last_q || output_slot_ready);
        stage1_slot_ready = !stage1_valid_q || stage2_fire;
        // Keep the legacy contract that a new sequence is not accepted while
        // an earlier result is held under backpressure.  The stage-1 register
        // still overlaps successive beats within the active sequence.
        in_ready = !rst && stage1_slot_ready && output_slot_ready;
        input_fire = in_valid && in_ready;

        if (stage1_first_q)
            accumulator_base_extended =
                {stage1_bias_q[31], stage1_bias_q};
        else
            accumulator_base_extended =
                {accumulator_q[31], accumulator_q};
        accumulator_next_extended = accumulator_base_extended +
                                     $signed({{14{stage1_dot_sum_q[18]}},
                                              stage1_dot_sum_q});
        overflow_comb = (accumulator_next_extended > 33'sd2147483647) ||
                        (accumulator_next_extended < -33'sd2147483648);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            stage1_valid_q <= 1'b0;
            stage1_first_q <= 1'b0;
            stage1_last_q <= 1'b0;
            stage1_dot_sum_q <= 19'sd0;
            stage1_bias_q <= 32'sd0;
            stage1_sof_q <= 1'b0;
            stage1_eol_q <= 1'b0;
            stage1_eof_q <= 1'b0;
            stage1_x_q <= '0;
            stage1_y_q <= '0;
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

            if (stage2_fire) begin
                accumulator_q <= accumulator_next_extended[31:0];
                acc_overflow <= overflow_comb;
                if (stage1_last_q) begin
                    out_valid <= 1'b1;
                    out_acc_s32 <= accumulator_next_extended[31:0];
                    out_sof <= stage1_sof_q;
                    out_eol <= stage1_eol_q;
                    out_eof <= stage1_eof_q;
                    out_x <= stage1_x_q;
                    out_y <= stage1_y_q;
                end

`ifndef SYNTHESIS
                if (ASSERT_ON_OVERFLOW && overflow_comb)
                    $error("c1_s8_dot8_accum_pipelined signed32 accumulator overflow");
`endif
            end

            if (stage1_slot_ready) begin
                stage1_valid_q <= input_fire;
                if (input_fire) begin
                    stage1_first_q <= in_first;
                    stage1_last_q <= in_last;
                    stage1_dot_sum_q <= dot_sum_comb;
                    stage1_bias_q <= in_bias_s32;
                    stage1_sof_q <= in_sof;
                    stage1_eol_q <= in_eol;
                    stage1_eof_q <= in_eof;
                    stage1_x_q <= in_x;
                    stage1_y_q <= in_y;
                end else begin
                    stage1_first_q <= 1'b0;
                    stage1_last_q <= 1'b0;
                end
            end

            // Protocol tracking follows input acceptance (not stage-2
            // retirement), because a continuation may be accepted in the same
            // edge that the preceding stage-1 beat is retired.
            if (input_fire)
                sequence_active_q <= !in_last;

`ifndef SYNTHESIS
            if (input_fire && ASSERT_PROTOCOL) begin
                if (in_first && sequence_active_q)
                    $error("c1_s8_dot8_accum_pipelined first asserted inside active sequence");
                if (!in_first && !sequence_active_q)
                    $error("c1_s8_dot8_accum_pipelined continuation without first");
            end
`endif
        end
    end

endmodule
