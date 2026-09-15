`timescale 1ns/1ps

// Lock-step bank of independent 8x8 INT8 output-channel tiles.
//
// c1_dot8x8_requant_core already computes eight output channels (64 INT8
// products) for one input C8 group.  This wrapper makes the next throughput
// step explicit: LANES output groups are started and fed in parallel.  The
// input activation/window beat and protocol metadata are broadcast, while
// each lane receives its own bias/multiplier/shift/weight tile.  No memory
// policy is hidden here; an upstream scheduler must provide LANES adjacent
// output groups and must consume LANES result vectors together.
//
// The default LANES=1 is intentionally equivalent to one core.  The module
// is a boardless integration seam and is not enabled in the legacy engine
// until its scheduler and tensor-bandwidth budget are selected.
module c1_dot8x8_requant_bank #(
    parameter integer LANES = 2,
    parameter integer X_BITS = 16,
    parameter integer Y_BITS = 16,
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    // Forward the optional same-cycle output retirement/restart contract to
    // every lock-step lane.  Default zero keeps the original bank timing.
    parameter bit ALLOW_OUTPUT_RESTART = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         start_valid,
    output logic                         start_ready,
    input  logic [LANES*256-1:0]         start_bias_s32,
    input  logic [LANES*144-1:0]         start_mult_s18,
    input  logic [LANES*48-1:0]          start_shift_u6,
    input  logic [LANES-1:0]             start_relu,
    input  logic [LANES-1:0]             start_sof,
    input  logic [LANES-1:0]             start_eol,
    input  logic [LANES-1:0]             start_eof,
    input  logic [LANES*X_BITS-1:0]      start_x,
    input  logic [LANES*Y_BITS-1:0]      start_y,

    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic                         in_last,
    input  logic [7:0]                   in_lane_mask,
    input  logic [63:0]                  in_activations_s8,
    input  logic [LANES*512-1:0]         in_weights_s8,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic [LANES*64-1:0]          out_data_s8,
    output logic [LANES-1:0]             out_sof,
    output logic [LANES-1:0]             out_eol,
    output logic [LANES-1:0]             out_eof,
    output logic [LANES*X_BITS-1:0]      out_x,
    output logic [LANES*Y_BITS-1:0]      out_y,
    output logic                         busy,
    output logic [LANES-1:0]             overflow_seen
);

    initial begin
        if (LANES < 1)
            $fatal(1, "c1_dot8x8_requant_bank LANES must be positive");
    end

    logic [LANES-1:0] lane_start_ready;
    logic [LANES-1:0] lane_in_ready;
    logic [LANES-1:0] lane_out_valid;
    logic [LANES-1:0] lane_busy;
    logic [LANES-1:0] lane_out_sof;
    logic [LANES-1:0] lane_out_eol;
    logic [LANES-1:0] lane_out_eof;
    logic [LANES*64-1:0] lane_out_data;
    logic [LANES*X_BITS-1:0] lane_out_x;
    logic [LANES*Y_BITS-1:0] lane_out_y;

    assign start_ready = &lane_start_ready;
    assign in_ready = &lane_in_ready;
    // All lanes are launched and fed in lock-step.  If one lane is stalled,
    // the complete bank applies backpressure so result ordering remains a
    // simple lane-indexed vector.
    assign out_valid = &lane_out_valid;
    assign busy = |lane_busy;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            c1_dot8x8_requant_core #(
                .X_BITS(X_BITS),
                .Y_BITS(Y_BITS),
                .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
                .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
                .ALLOW_OUTPUT_RESTART(ALLOW_OUTPUT_RESTART)
            ) u_core (
                .clk(clk),
                .rst(rst),
                .start_valid(start_valid),
                .start_ready(lane_start_ready[g]),
                .start_bias_s32(start_bias_s32[g*256 +: 256]),
                .start_mult_s18(start_mult_s18[g*144 +: 144]),
                .start_shift_u6(start_shift_u6[g*48 +: 48]),
                .start_relu(start_relu[g]),
                .start_sof(start_sof[g]),
                .start_eol(start_eol[g]),
                .start_eof(start_eof[g]),
                .start_x(start_x[g*X_BITS +: X_BITS]),
                .start_y(start_y[g*Y_BITS +: Y_BITS]),
                .in_valid(in_valid),
                .in_ready(lane_in_ready[g]),
                .in_last(in_last),
                .in_lane_mask(in_lane_mask),
                .in_activations_s8(in_activations_s8),
                .in_weights_s8(in_weights_s8[g*512 +: 512]),
                .out_valid(lane_out_valid[g]),
                .out_ready(out_ready),
                .out_data_s8(lane_out_data[g*64 +: 64]),
                .out_sof(lane_out_sof[g]),
                .out_eol(lane_out_eol[g]),
                .out_eof(lane_out_eof[g]),
                .out_x(lane_out_x[g*X_BITS +: X_BITS]),
                .out_y(lane_out_y[g*Y_BITS +: Y_BITS]),
                .busy(lane_busy[g]),
                .overflow_seen(overflow_seen[g])
            );
        end
    endgenerate

    assign out_data_s8 = lane_out_data;
    assign out_sof = lane_out_sof;
    assign out_eol = lane_out_eol;
    assign out_eof = lane_out_eof;
    assign out_x = lane_out_x;
    assign out_y = lane_out_y;

`ifndef SYNTHESIS
    // The bank contract intentionally exposes one lock-step valid.  A
    // divergent lane indicates an integration bug (for example, a scheduler
    // presenting different in_last or ready semantics to one core).
    always_ff @(posedge clk) begin
        if (!rst) begin
            if ((|lane_out_valid) && !(out_valid || (&lane_out_valid)))
                $fatal(1, "c1_dot8x8_requant_bank lane valid mismatch");
            if ((|lane_start_ready) && (start_valid && !start_ready))
                $fatal(1, "c1_dot8x8_requant_bank lane start-ready mismatch");
        end
    end
`endif
endmodule
