// Board-independent 8-output-channel INT8 dot/convolution compute core.
//
// The external scheduler supplies one group of eight activations and eight
// independent eight-weight rows per accepted input beat.  Thus the core
// performs eight INT8 MACs for each of eight output channels (64 multiplies)
// per beat.  Window extraction, tensor addressing, and weight storage remain
// external to this module.
//
// A start_valid/start_ready handshake begins one positive-length dot product
// and snapshots eight signed32 biases, eight signed18 requant multipliers,
// eight 0..47 shifts, the global optional ReLU mode, and output metadata.
// Input groups then use ready/valid; in_last marks the final group.  lane_mask
// applies independently to all output channels, allowing arbitrary K through
// a masked final group.  Channel 0 and lane 0 occupy the least-significant
// packed slices.
//
// Signed32 accumulation deliberately wraps modulo 2**32.  Overflow indication
// from the reused dot accumulators is collected in overflow_seen, but does not
// alter the result.  Requantization is the existing c1_requant_bank8 contract:
// signed32*signed18, shift with nearest/ties-away rounding, signed8 saturation,
// then optional ReLU.
//
// By default, only one dot-product transaction may be in flight. Optional
// OVERLAP_REQUANTIZATION reuses the accumulators once their prior result and
// config enter the five-stage requant pipeline. Results remain ordered, with
// at most five requant transactions plus one active dot. In that mode busy
// covers the whole outstanding set; overflow_seen is aggregate sticky status
// for a contiguous busy interval, NOT metadata for a particular result.

`timescale 1ns/1ps

module c1_dot8x8_requant_core #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9,
    // Optional arithmetic pipeline; default preserves the legacy one-cycle
    // accumulator implementation and its exact latency.
    parameter integer PIPELINED_DOT_TREE = 0,
    // Full product->pair->quad->dot elastic tree.  This is independent of
    // PIPELINED_DOT_TREE so the existing final-dot-sum experiment retains its
    // exact behavior when this parameter is zero.
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    // Optional elastic restart: when the current result is accepted on this
    // edge, allow START for the next transaction without inserting an idle
    // cycle.  The old output is sampled from the pre-edge pipeline state and
    // the new configuration is captured for the following input beat.  This
    // is disabled by default because it adds out_ready -> start_ready logic.
    parameter bit ALLOW_OUTPUT_RESTART = 1'b0,
    // Reuse accumulators once their complete result/config enters the
    // existing requant pipeline, without waiting for its output retirement.
    // Outputs remain ordered; busy covers ALL accepted transactions. In
    // this mode overflow_seen is sticky across the contiguous busy interval.
    parameter bit OVERLAP_REQUANTIZATION = 1'b0
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   start_valid,
    output logic                   start_ready,
    input  logic [255:0]           start_bias_s32,
    input  logic [143:0]           start_mult_s18,
    input  logic [47:0]            start_shift_u6,
    input  logic                   start_relu,
    input  logic                   start_sof,
    input  logic                   start_eol,
    input  logic                   start_eof,
    input  logic [X_BITS-1:0]      start_x,
    input  logic [Y_BITS-1:0]      start_y,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic                   in_last,
    input  logic [7:0]             in_lane_mask,
    input  logic [63:0]            in_activations_s8,
    input  logic [511:0]           in_weights_s8,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [63:0]            out_data_s8,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic                   busy,
    output logic                   overflow_seen
);

    logic accepting_input;
    logic first_beat;
    logic [255:0] bias_q;
    logic [143:0] mult_q;
    logic [47:0] shift_q;
    logic relu_q;
    logic sof_q, eol_q, eof_q;
    logic [X_BITS-1:0] x_q;
    logic [Y_BITS-1:0] y_q;

    logic [7:0] dot_in_ready;
    logic [7:0] dot_out_valid;
    logic [7:0] dot_overflow;
    logic [7:0] dot_sof;
    logic [7:0] dot_eol;
    logic [7:0] dot_eof;
    logic [X_BITS-1:0] dot_x [0:7];
    logic [Y_BITS-1:0] dot_y [0:7];
    logic signed [31:0] dot_acc [0:7];
    logic [255:0] requant_acc_bus;
    logic [15:0] requant_activation;
    logic requant_in_ready;
    logic all_dot_ready;
    logic all_dot_valid;
    logic dot_input_valid;
    logic dot_output_ready;
    logic input_fire;
    logic start_fire;
    logic busy_clear_fire;
    logic dot_pending_q;
    logic [3:0] transactions_pending_q;
    wire requant_accept = all_dot_valid && requant_in_ready;
    always_ff @(posedge clk) begin
        if(rst || !OVERLAP_REQUANTIZATION) begin
            dot_pending_q<=0;transactions_pending_q<=0;
        end else begin
            if(start_fire) dot_pending_q<=1;
            else if(requant_accept) dot_pending_q<=0;
            case({start_fire,out_valid && out_ready})
                2'b10: transactions_pending_q<=transactions_pending_q+1'b1;
                2'b01: transactions_pending_q<=transactions_pending_q-1'b1;
                default: ;
            endcase
        end
    end
    integer activation_channel;

    // Keep the conservative default structurally separate from the optional
    // ready path.  Some synthesis front ends retain a parameterized mux even
    // when a bit generic is zero; a generate split lets the default netlist
    // remain the historical ``!busy`` path.
    generate
        if (OVERLAP_REQUANTIZATION) begin : g_requant_overlap_ready
            assign start_ready = !dot_pending_q || requant_accept;
            assign busy_clear_fire = out_valid && out_ready &&
                                     transactions_pending_q==1 && !start_fire;
        end else if (ALLOW_OUTPUT_RESTART) begin : g_output_restart_ready
            assign start_ready = !busy || (out_valid && out_ready);
            assign busy_clear_fire = out_valid && out_ready && !start_fire;
        end else begin : g_output_restart_default
            assign start_ready = !busy;
            assign busy_clear_fire = out_valid && out_ready;
        end
    endgenerate

    always_comb begin
        start_fire = start_valid && start_ready;
        all_dot_ready = &dot_in_ready;
        all_dot_valid = &dot_out_valid;
        in_ready = accepting_input && all_dot_ready;
        input_fire = in_valid && in_ready;
        // Present a beat to the reused accumulators only when all eight can
        // accept it, preserving exact lockstep even under downstream stalls.
        dot_input_valid = input_fire;
        dot_output_ready = requant_in_ready && all_dot_valid;

        for (activation_channel = 0; activation_channel < 8;
             activation_channel = activation_channel + 1)
            requant_activation[activation_channel*2 +: 2] =
                relu_q ? 2'd1 : 2'd0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            accepting_input <= 1'b0;
            first_beat <= 1'b0;
            bias_q <= '0;
            mult_q <= '0;
            shift_q <= '0;
            relu_q <= 1'b0;
            sof_q <= 1'b0;
            eol_q <= 1'b0;
            eof_q <= 1'b0;
            x_q <= '0;
            y_q <= '0;
            busy <= 1'b0;
            overflow_seen <= 1'b0;
        end else begin
            if (start_fire) begin
                bias_q <= start_bias_s32;
                mult_q <= start_mult_s18;
                shift_q <= start_shift_u6;
                relu_q <= start_relu;
                sof_q <= start_sof;
                eol_q <= start_eol;
                eof_q <= start_eof;
                x_q <= start_x;
                y_q <= start_y;
                accepting_input <= 1'b1;
                first_beat <= 1'b1;
                busy <= 1'b1;
                if(!OVERLAP_REQUANTIZATION || transactions_pending_q==0)
                    overflow_seen <= 1'b0;
            end

            if (input_fire) begin
                first_beat <= 1'b0;
                if (in_last)
                    accepting_input <= 1'b0;
            end

            if (|dot_overflow)
                overflow_seen <= 1'b1;

            if (busy_clear_fire)
                busy <= 1'b0;
        end
    end

    genvar output_channel;
    generate
        for (output_channel = 0; output_channel < 8;
             output_channel = output_channel + 1) begin : g_dot
            if (PIPELINED_DOT_TREE_FULL != 0) begin : g_treepipe
                c1_s8_dot8_accum_treepipe #(
                    .X_BITS(X_BITS),
                    .Y_BITS(Y_BITS),
                    .ASSERT_ON_OVERFLOW(1'b0),
                    .ASSERT_PROTOCOL(1'b1)
                ) u_dot (
                    .clk,
                    .rst,
                    .in_valid(dot_input_valid),
                    .in_ready(dot_in_ready[output_channel]),
                    .in_first(first_beat),
                    .in_last(in_last),
                    .in_lane_mask(in_lane_mask),
                    .in_activations_s8(in_activations_s8),
                    .in_weights_s8(
                        in_weights_s8[output_channel*64 +: 64]),
                    .in_bias_s32(
                        $signed(bias_q[output_channel*32 +: 32])),
                    .in_sof(sof_q),
                    .in_eol(eol_q),
                    .in_eof(eof_q),
                    .in_x(x_q),
                    .in_y(y_q),
                    .out_valid(dot_out_valid[output_channel]),
                    .out_ready(dot_output_ready),
                    .out_acc_s32(dot_acc[output_channel]),
                    .out_sof(dot_sof[output_channel]),
                    .out_eol(dot_eol[output_channel]),
                    .out_eof(dot_eof[output_channel]),
                    .out_x(dot_x[output_channel]),
                    .out_y(dot_y[output_channel]),
                    .acc_overflow(dot_overflow[output_channel])
                );
            end else if (PIPELINED_DOT_TREE == 0) begin : g_legacy
                c1_s8_dot8_accum #(
                    .X_BITS(X_BITS),
                    .Y_BITS(Y_BITS),
                    .ASSERT_ON_OVERFLOW(1'b0),
                    .ASSERT_PROTOCOL(1'b1)
                ) u_dot (
                    .clk,
                    .rst,
                    .in_valid(dot_input_valid),
                    .in_ready(dot_in_ready[output_channel]),
                    .in_first(first_beat),
                    .in_last(in_last),
                    .in_lane_mask(in_lane_mask),
                    .in_activations_s8(in_activations_s8),
                    .in_weights_s8(
                        in_weights_s8[output_channel*64 +: 64]),
                    .in_bias_s32(
                        $signed(bias_q[output_channel*32 +: 32])),
                    .in_sof(sof_q),
                    .in_eol(eol_q),
                    .in_eof(eof_q),
                    .in_x(x_q),
                    .in_y(y_q),
                    .out_valid(dot_out_valid[output_channel]),
                    .out_ready(dot_output_ready),
                    .out_acc_s32(dot_acc[output_channel]),
                    .out_sof(dot_sof[output_channel]),
                    .out_eol(dot_eol[output_channel]),
                    .out_eof(dot_eof[output_channel]),
                    .out_x(dot_x[output_channel]),
                    .out_y(dot_y[output_channel]),
                    .acc_overflow(dot_overflow[output_channel])
                );
            end else begin : g_pipelined
                c1_s8_dot8_accum_pipelined #(
                    .X_BITS(X_BITS),
                    .Y_BITS(Y_BITS),
                    .ASSERT_ON_OVERFLOW(1'b0),
                    .ASSERT_PROTOCOL(1'b1)
                ) u_dot (
                    .clk,
                    .rst,
                    .in_valid(dot_input_valid),
                    .in_ready(dot_in_ready[output_channel]),
                    .in_first(first_beat),
                    .in_last(in_last),
                    .in_lane_mask(in_lane_mask),
                    .in_activations_s8(in_activations_s8),
                    .in_weights_s8(
                        in_weights_s8[output_channel*64 +: 64]),
                    .in_bias_s32(
                        $signed(bias_q[output_channel*32 +: 32])),
                    .in_sof(sof_q),
                    .in_eol(eol_q),
                    .in_eof(eof_q),
                    .in_x(x_q),
                    .in_y(y_q),
                    .out_valid(dot_out_valid[output_channel]),
                    .out_ready(dot_output_ready),
                    .out_acc_s32(dot_acc[output_channel]),
                    .out_sof(dot_sof[output_channel]),
                    .out_eol(dot_eol[output_channel]),
                    .out_eof(dot_eof[output_channel]),
                    .out_x(dot_x[output_channel]),
                    .out_y(dot_y[output_channel]),
                    .acc_overflow(dot_overflow[output_channel])
                );
            end

            assign requant_acc_bus[output_channel*32 +: 32] =
                dot_acc[output_channel];
        end
    endgenerate

    c1_requant_bank8 #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_requant (
        .clk,
        .rst,
        .in_valid(all_dot_valid),
        .in_ready(requant_in_ready),
        .in_acc_s32(requant_acc_bus),
        .in_mult_s18(mult_q),
        .in_shift_u6(shift_q),
        .in_activation(requant_activation),
        .in_sof(dot_sof[0]),
        .in_eol(dot_eol[0]),
        .in_eof(dot_eof[0]),
        .in_x(dot_x[0]),
        .in_y(dot_y[0]),
        .out_valid,
        .out_ready,
        .out_data_s8,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y
    );

`ifndef SYNTHESIS
    integer check_channel;
    always_ff @(posedge clk) begin
        if (!rst) begin
            if(OVERLAP_REQUANTIZATION) begin
                if((transactions_pending_q==0)!==(!busy) || transactions_pending_q>6)
                    $fatal(1,"dot/requant outstanding conservation violated");
                if(out_valid && transactions_pending_q==0)
                    $fatal(1,"dot/requant emitted an unowned result");
                if(start_fire && dot_pending_q && !requant_accept)
                    $fatal(1,"dot/requant replaced active accumulator config");
            end
            if (start_valid && start_ready) begin
                for (check_channel = 0; check_channel < 8;
                     check_channel = check_channel + 1)
                    if (start_shift_u6[check_channel*6 +: 6] > 6'd47)
                        $fatal(1,
                               "c1_dot8x8_requant_core shift[%0d] exceeds 47",
                               check_channel);
            end
            if (in_valid && in_ready && (in_lane_mask == 8'h00))
                $fatal(1, "c1_dot8x8_requant_core accepted an empty lane mask");
            if ((dot_out_valid != 8'h00) &&
                (dot_out_valid != 8'hff))
                $fatal(1, "c1_dot8x8_requant_core dot outputs lost lockstep");
            if (all_dot_valid) begin
                for (check_channel = 1; check_channel < 8;
                     check_channel = check_channel + 1)
                    if ((dot_sof[check_channel] !== dot_sof[0]) ||
                        (dot_eol[check_channel] !== dot_eol[0]) ||
                        (dot_eof[check_channel] !== dot_eof[0]) ||
                        (dot_x[check_channel] !== dot_x[0]) ||
                        (dot_y[check_channel] !== dot_y[0]))
                        $fatal(1,
                               "c1_dot8x8_requant_core metadata lost lockstep");
            end
        end
    end
`endif

endmodule
