`timescale 1ns/1ps

// Boardless control prototype for the first tensor cache step.
//
// This module deliberately tracks row residency rather than storing pixel
// data.  A 3x3 SAME tap request is accepted only when its clamped input row is
// resident.  On a miss, one full-row refill handshake is emitted; the source
// retries the same tap after the refill.  The resulting refill count is the
// traffic quantity that the Python line/window model predicts.  A later RTL
// implementation can replace the row tags with BRAM data and retain this
// handshake/abort-safe control shell.
//
// Contract:
// * group_start invalidates all rows for a new C8 input group.
// * tap_valid/payload must remain stable until tap_ready is observed.
// * refill_valid/refill_row remain stable until refill_ready.
// * no request is withdrawn; a miss is counted once and must be retried.
module c1_window_line_cache_ctrl #(
    parameter integer LINE_ROWS = 3
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       group_start,
    input  logic [15:0]                frame_width,
    input  logic [15:0]                frame_height,

    input  logic                       tap_valid,
    output logic                       tap_ready,
    input  logic [15:0]                tap_x,
    input  logic [15:0]                tap_y,

    output logic                       refill_valid,
    input  logic                       refill_ready,
    output logic [15:0]                refill_row,

    output logic                       tap_fire,
    output logic                       tap_hit,
    output logic                       tap_miss,
    output logic [63:0]                tap_count,
    output logic [63:0]                hit_count,
    output logic [63:0]                miss_count,
    output logic [63:0]                refill_count,
    output logic [63:0]                external_word_count,
    output logic                       busy,
    output logic                       quiescent
);

    initial begin
        if (LINE_ROWS < 1)
            $fatal(1, "LINE_ROWS must be positive");
    end

    // The control prototype uses a deterministic round-robin replacement
    // pointer.  This keeps the RTL contract small and synthesizable while
    // preserving the line-refill count for raster traversal.  The Python
    // traffic model remains the place to compare alternative LRU policies.
    localparam integer PTR_W = (LINE_ROWS <= 1) ? 1 : $clog2(LINE_ROWS);

    typedef enum logic {
        ST_IDLE,
        ST_REFILL
    } state_t;
    state_t state_q;

    logic [LINE_ROWS-1:0] row_valid_q;
    logic [15:0] row_tag_q [0:LINE_ROWS-1];
    logic [PTR_W-1:0] replace_ptr_q;
    logic [15:0] miss_row_q;
    logic [15:0] refill_width_q;
    logic lookup_hit;
    logic [15:0] clamped_row;
    integer hit_slot;
    integer replace_slot;
    integer comb_k;
    integer seq_k;
    logic invalid_found;

    always_comb begin
        if (frame_height == 0)
            clamped_row = 16'd0;
        else if (tap_y >= frame_height)
            clamped_row = frame_height - 1'b1;
        else
            clamped_row = tap_y;

        lookup_hit = 1'b0;
        hit_slot = 0;
        for (comb_k = 0; comb_k < LINE_ROWS; comb_k = comb_k + 1) begin
            if (row_valid_q[comb_k] && (row_tag_q[comb_k] == clamped_row)) begin
                lookup_hit = 1'b1;
                hit_slot = comb_k;
            end
        end

        // Prefer an invalid slot; otherwise use the round-robin victim.
        replace_slot = 0;
        invalid_found = 1'b0;
        for (comb_k = 0; comb_k < LINE_ROWS; comb_k = comb_k + 1) begin
            if (!row_valid_q[comb_k] && !invalid_found) begin
                replace_slot = comb_k;
                invalid_found = 1'b1;
            end
        end
        if (!invalid_found) begin
            replace_slot = replace_ptr_q;
            if (replace_slot >= LINE_ROWS)
                replace_slot = 0;
        end
    end

    always_comb begin
        // Assign ready before fire.  Keeping fire as a function of the
        // already-computed ready term avoids a simulation delta-cycle lag
        // that could otherwise drop the first retry after a refill.
        tap_ready = (state_q == ST_IDLE) && !group_start && lookup_hit;
        tap_fire = tap_valid && tap_ready;
        tap_hit = tap_fire;
        tap_miss = (state_q == ST_IDLE) && tap_valid && !group_start &&
                   !lookup_hit;
        refill_valid = (state_q == ST_REFILL);
        refill_row = miss_row_q;
        busy = (state_q != ST_IDLE) || tap_miss;
        quiescent = !busy && !tap_valid && !group_start;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            row_valid_q <= '0;
            miss_row_q <= 16'd0;
            refill_width_q <= 16'd0;
            tap_count <= 64'd0;
            hit_count <= 64'd0;
            miss_count <= 64'd0;
            refill_count <= 64'd0;
            external_word_count <= 64'd0;
            replace_ptr_q <= '0;
            for (seq_k = 0; seq_k < LINE_ROWS; seq_k = seq_k + 1) begin
                row_tag_q[seq_k] <= 16'd0;
            end
        end else begin
            if (group_start) begin
                state_q <= ST_IDLE;
                row_valid_q <= '0;
                replace_ptr_q <= '0;
                for (seq_k = 0; seq_k < LINE_ROWS; seq_k = seq_k + 1) begin
                    row_tag_q[seq_k] <= 16'd0;
                end
            end else begin
                if (tap_miss) begin
                    state_q <= ST_REFILL;
                    miss_row_q <= clamped_row;
                    refill_width_q <= frame_width;
                    miss_count <= miss_count + 1'b1;
                end

                if (refill_valid && refill_ready) begin
                    state_q <= ST_IDLE;
                    row_valid_q[replace_slot] <= 1'b1;
                    row_tag_q[replace_slot] <= miss_row_q;
                    if (replace_slot == LINE_ROWS-1)
                        replace_ptr_q <= '0;
                    else
                        replace_ptr_q <= replace_slot + 1;
                    refill_count <= refill_count + 1'b1;
                    external_word_count <= external_word_count +
                                           refill_width_q;
                end

                if (tap_fire) begin
                    tap_count <= tap_count + 1'b1;
                    hit_count <= hit_count + 1'b1;
                end
            end
        end
    end

    // tap_x is intentionally part of the stable request ABI even though this
    // row-only prototype only needs tap_y.  Keep an explicit reference so
    // lint/synthesis cannot treat the port as an accidental omission.
    wire unused_tap_x = ^tap_x;
endmodule
