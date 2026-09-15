`timescale 1ns/1ps

// Case-1 R1 one-entry CNN-result skid boundary.
//
// This is deliberately a separate implementation from
// c1_r1_unified_output_fifo.  It is the smallest registered cut at the
// engine-result -> adapter-result seam:
//
//   * one complete 103-bit payload is stored in a register;
//   * an empty entry never falls through an input beat in the same cycle;
//   * in_ready is occupancy-only and never depends on out_ready;
//   * a full entry does not accept a simultaneous replacement when it is
//     popped (there is an intentional bubble);
//   * abort and error_flush clear the valid bit synchronously; abort always
//     fences the external handshake, while COMBINATIONAL_ERROR_GATE selects
//     whether error_flush also fences it before the clearing edge.
//
// The bridge integration uses COMBINATIONAL_ERROR_GATE=0 and gates the
// adapter-side handshake with its already-registered lifecycle error.  The
// standalone default remains the conservative combinational error fence.
module c1_r1_unified_output_skid #(
    parameter integer COMBINATIONAL_ERROR_GATE = 1
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   abort,
    input  logic                   error_flush,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [63:0]             in_data_s8,
    input  logic [2:0]              in_group_index,
    input  logic                   in_group_last,
    input  logic [15:0]             in_x,
    input  logic [15:0]             in_y,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [63:0]             out_data_s8,
    output logic [2:0]              out_group_index,
    output logic                   out_group_last,
    output logic [15:0]             out_x,
    output logic [15:0]             out_y,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,

    output logic                   level,
    output logic                   full,
    output logic                   empty
);

    localparam integer PAYLOAD_WIDTH = 64 + 3 + 1 + 16 + 16 + 3;

    typedef struct packed {
        logic [63:0] data_s8;
        logic [2:0]  group_index;
        logic        group_last;
        logic [15:0] x;
        logic [15:0] y;
        logic        sof;
        logic        eol;
        logic        eof;
    } payload_t;

    payload_t payload_q;
    payload_t in_payload;
    logic valid_q;
    logic push_fire;
    logic pop_fire;
    logic flush;
    logic handshake_flush;
    logic stalled_q;
    payload_t stalled_payload_q;

    always_comb begin
        flush = abort || error_flush;
        handshake_flush = abort ||
                          (COMBINATIONAL_ERROR_GATE && error_flush);

        level = valid_q;
        full = valid_q;
        empty = !valid_q;

        // rst is synchronous in this family, but fencing the interface while
        // rst is high prevents a visible transfer before the reset edge.
        in_ready = !rst && !handshake_flush && !valid_q;
        out_valid = !rst && !handshake_flush && valid_q;

        in_payload = '0;
        in_payload.data_s8 = in_data_s8;
        in_payload.group_index = in_group_index;
        in_payload.group_last = in_group_last;
        in_payload.x = in_x;
        in_payload.y = in_y;
        in_payload.sof = in_sof;
        in_payload.eol = in_eol;
        in_payload.eof = in_eof;

        out_data_s8 = '0;
        out_group_index = '0;
        out_group_last = 1'b0;
        out_x = '0;
        out_y = '0;
        out_sof = 1'b0;
        out_eol = 1'b0;
        out_eof = 1'b0;
        if (out_valid) begin
            out_data_s8 = payload_q.data_s8;
            out_group_index = payload_q.group_index;
            out_group_last = payload_q.group_last;
            out_x = payload_q.x;
            out_y = payload_q.y;
            out_sof = payload_q.sof;
            out_eol = payload_q.eol;
            out_eof = payload_q.eof;
        end

        push_fire = in_valid && in_ready;
        pop_fire = out_valid && out_ready;
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            valid_q <= 1'b0;
            payload_q <= '0;
        end else begin
            // push_fire and pop_fire cannot both be true: in_ready is low
            // whenever valid_q is set.  Keeping the cases explicit documents
            // the intentional full-state bubble and avoids hidden bypass.
            if (push_fire) begin
                payload_q <= in_payload;
                valid_q <= 1'b1;
            end else if (pop_fire) begin
                valid_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            stalled_q <= 1'b0;
            stalled_payload_q <= '0;
        end else begin
            if (stalled_q &&
                (!out_valid ||
                 ({out_data_s8, out_group_index, out_group_last,
                   out_x, out_y, out_sof, out_eol, out_eof} !==
                  {stalled_payload_q.data_s8,
                   stalled_payload_q.group_index,
                   stalled_payload_q.group_last,
                   stalled_payload_q.x,
                   stalled_payload_q.y,
                   stalled_payload_q.sof,
                   stalled_payload_q.eol,
                   stalled_payload_q.eof})))
                $fatal(1,
                       "c1_r1_unified_output_skid changed payload while stalled");

            stalled_q <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                stalled_payload_q <= payload_q;
            end

            if (push_fire && pop_fire)
                $fatal(1,
                       "c1_r1_unified_output_skid accepted full-state replacement");
            if (handshake_flush && (in_ready || out_valid))
                $fatal(1,
                       "c1_r1_unified_output_skid handshake visible during flush");
        end
    end

    initial begin
        if ((COMBINATIONAL_ERROR_GATE != 0) &&
            (COMBINATIONAL_ERROR_GATE != 1))
            $fatal(1,
                   "COMBINATIONAL_ERROR_GATE must be 0 or 1");
        if (PAYLOAD_WIDTH != 103)
            $fatal(1,
                   "unified output skid payload width changed from 103 bits");
    end
`endif

endmodule
