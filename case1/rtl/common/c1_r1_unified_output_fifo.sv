`timescale 1ns/1ps

// Case-1 R1 unified CNN-result elastic FIFO.
//
// This is an opt-in seam for the c1_r1_microstyle_system_bridge.  It is kept
// as a standalone block so the direct CNN-to-adapter_result path remains the
// default until a timing experiment proves the boundary useful.  The FIFO is
// deliberately a *registered*, two-entry queue:
//
//   * an empty FIFO does not fall through an input beat in the same cycle;
//   * in_ready depends only on the registered occupancy (and flush), never on
//     out_ready, so downstream back-pressure cannot recreate the long
//     adapter_result_ready -> CNN/requantization ready path;
//   * when full, a simultaneous pop/push is not accepted.  This one-cycle
//     bubble is intentional and buys a clean timing cut at the cost of at most
//     one cycle whenever the two-entry queue drains from full;
//   * abort/error_flush synchronously discard all queued results.  By default
//     both signals also suppress the handshake combinationally.  The optional
//     bridge experiment disables only the error_flush combinational gate: the
//     bridge gates its adapter-side handshake, and the FIFO still clears on
//     the error edge.  This avoids feeding the error fanout back into the CNN
//     input-ready path while preserving the same post-error epoch boundary.
//
// The payload exactly matches the c1_r1_microstyle_system_bridge
// adapter_result_* contract (103 bits total):
//   data_s8[63:0], group_index[2:0], group_last,
//   x[15:0], y[15:0], sof, eol, eof.
//
// There is intentionally no epoch field in this first experiment.  All
// producers/consumers are in core_clk, and the lifecycle contract flushes on
// abort/error before a new start.  If a future design permits a restart without
// that flush, add an explicit epoch/tag rather than reusing a configuration
// generation as an implicit epoch.
module c1_r1_unified_output_fifo #(
    parameter integer DEPTH = 2,
    // Keep the standalone protocol conservative by default.  The optional
    // bridge experiment can set this to 0: error_flush still clears the queue
    // synchronously on the error edge, but it does not create a combinational
    // error -> ready/valid feedback path before that edge.  `abort` remains a
    // combinational handshake gate in either mode.
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

    // Diagnostics are useful in a boardless timing/functional experiment and
    // do not participate in the ready/valid contract.
    output logic [1:0]              level,
    output logic                   full,
    output logic                   empty
);

    localparam integer PAYLOAD_WIDTH = 64 + 3 + 1 + 16 + 16 + 3;
    localparam integer PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam integer LEVEL_WIDTH = (DEPTH < 2) ? 1 : $clog2(DEPTH + 1);

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

    payload_t storage [0:DEPTH-1];
    payload_t in_payload;
    payload_t out_payload;
    payload_t stalled_payload_q;

    logic [PTR_WIDTH-1:0] write_ptr_q;
    logic [PTR_WIDTH-1:0] read_ptr_q;
    logic [LEVEL_WIDTH-1:0] level_q;
    logic push_fire;
    logic pop_fire;
    logic flush;
    logic handshake_flush;
    logic stalled_q;

    always_comb begin
        // rst is synchronous in this design family, but gating the external
        // handshake while it is asserted prevents a visible transfer before
        // the reset edge has cleared the state.
        flush = abort || error_flush;
        handshake_flush = abort ||
                          (COMBINATIONAL_ERROR_GATE && error_flush);

        level = level_q[1:0];
        empty = (level_q == '0);
        full = (level_q == DEPTH);

        // No fall-through and no replacement-on-pop: this is the key timing
        // property of the experiment.  In particular, out_ready is absent
        // from in_ready.
        in_ready = !rst && !handshake_flush && !full;
        out_valid = !rst && !handshake_flush && !empty;

        in_payload = '0;
        in_payload.data_s8 = in_data_s8;
        in_payload.group_index = in_group_index;
        in_payload.group_last = in_group_last;
        in_payload.x = in_x;
        in_payload.y = in_y;
        in_payload.sof = in_sof;
        in_payload.eol = in_eol;
        in_payload.eof = in_eof;

        // The array is never reset; its contents are ignored while empty.
        // Keeping the read mux registered by occupancy gives a stable payload
        // during a downstream stall without a fall-through bypass.
        out_payload = storage[read_ptr_q];
        out_data_s8 = '0;
        out_group_index = '0;
        out_group_last = 1'b0;
        out_x = '0;
        out_y = '0;
        out_sof = 1'b0;
        out_eol = 1'b0;
        out_eof = 1'b0;
        if (out_valid) begin
            out_data_s8 = out_payload.data_s8;
            out_group_index = out_payload.group_index;
            out_group_last = out_payload.group_last;
            out_x = out_payload.x;
            out_y = out_payload.y;
            out_sof = out_payload.sof;
            out_eol = out_payload.eol;
            out_eof = out_payload.eof;
        end

        push_fire = in_valid && in_ready;
        pop_fire = out_valid && out_ready;
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            write_ptr_q <= '0;
            read_ptr_q <= '0;
            level_q <= '0;
        end else begin
            if (push_fire) begin
                storage[write_ptr_q] <= in_payload;
                if (write_ptr_q == DEPTH - 1)
                    write_ptr_q <= '0;
                else
                    write_ptr_q <= write_ptr_q + 1'b1;
            end

            if (pop_fire) begin
                if (read_ptr_q == DEPTH - 1)
                    read_ptr_q <= '0;
                else
                    read_ptr_q <= read_ptr_q + 1'b1;
            end

            case ({push_fire, pop_fire})
                2'b10: level_q <= level_q + 1'b1;
                2'b01: level_q <= level_q - 1'b1;
                default: level_q <= level_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    // A held output must remain a complete, unchanged payload until accepted.
    // The packed struct comparison covers all 103 bits, including metadata.
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
                       "c1_r1_unified_output_fifo changed payload while stalled");

            stalled_q <= out_valid && !out_ready;
            if (out_valid && !out_ready) begin
                stalled_payload_q.data_s8 <= out_data_s8;
                stalled_payload_q.group_index <= out_group_index;
                stalled_payload_q.group_last <= out_group_last;
                stalled_payload_q.x <= out_x;
                stalled_payload_q.y <= out_y;
                stalled_payload_q.sof <= out_sof;
                stalled_payload_q.eol <= out_eol;
                stalled_payload_q.eof <= out_eof;
            end

            if (level_q > DEPTH)
                $fatal(1, "c1_r1_unified_output_fifo occupancy overflow");
            if (full && in_ready)
                $fatal(1,
                       "c1_r1_unified_output_fifo full state accepted in_ready");
            if (handshake_flush && (in_ready || out_valid))
                $fatal(1,
                       "c1_r1_unified_output_fifo handshake visible during handshake flush");
        end
    end
`endif

`ifndef SYNTHESIS
    initial begin
        if (DEPTH != 2)
            $fatal(1,
                   "c1_r1_unified_output_fifo is intentionally fixed at DEPTH=2");
        if ((COMBINATIONAL_ERROR_GATE != 0) &&
            (COMBINATIONAL_ERROR_GATE != 1))
            $fatal(1,
                   "COMBINATIONAL_ERROR_GATE must be 0 or 1");
        if (PAYLOAD_WIDTH != 103)
            $fatal(1, "unified output payload width changed from 103 bits");
        if (PTR_WIDTH < 1 || LEVEL_WIDTH < 2)
            $fatal(1, "unified output FIFO pointer/level widths are invalid");
    end
`endif

endmodule
