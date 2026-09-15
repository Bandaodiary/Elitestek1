`timescale 1ns/1ps

// Board-independent control seam for a shared ID-less AXI read/write fabric.
//
// This block deliberately does not mux AXI payloads.  The existing
// c1_axi_n_serial_arbiter_128 remains the data-path owner.  Instead, this
// fence is the single admission/epoch authority that a future shared owner
// mux can use:
//
//   * read_admit/write_admit go low on the same cycle an abort/flush edge is
//     observed, so a not-yet-accepted VALID is never withdrawn after a
//     handshake;
//   * already accepted read/write transactions are allowed to drain, as
//     represented by the two quiescent/busy inputs;
//   * abort_done/flush_done and current_epoch advance only after both
//     directions are quiescent;
//   * an abort clears the optional context-active bit, while a flush keeps it.
//
// The interface is intentionally small enough to sit in front of either the
// current seven-client arbiter or a future owner/QoS scheduler.  `read_fire`
// and `write_fire` are observation pulses (normally AR/AW acceptance), not
// data-path controls; a sticky protocol_error records a *new idle-owner*
// transaction that bypassed the admission fence.  A fire while the
// corresponding owner is already busy is legal: a selected/stalled AR or AW
// may have to complete before the fence can drain it.
module c1_axi_shared_owner_epoch_fence #(
    parameter integer EPOCH_W = 4,
    parameter bit REQUIRE_CONTEXT = 1'b1,
    parameter bit ALLOW_RESTART = 1'b1
) (
    input  logic                     clk,
    input  logic                     rst,

    input  logic                     context_start_valid,
    output logic                     context_start_ready,
    input  logic                     abort_req,
    input  logic                     flush_req,

    input  logic                     read_busy,
    input  logic                     read_quiescent,
    input  logic                     write_busy,
    input  logic                     write_quiescent,
    input  logic                     read_fire,
    input  logic                     write_fire,

    output logic                     read_admit,
    output logic                     write_admit,
    output logic                     context_active,
    output logic [EPOCH_W-1:0]       current_epoch,
    output logic                     fence_busy,
    output logic                     abort_done,
    output logic                     flush_done,
    output logic                     epoch_bump,
    output logic                     protocol_error,
    output logic [63:0]              perf_fence_count,
    output logic [63:0]              perf_abort_count,
    output logic [63:0]              perf_flush_count
);

    typedef enum logic {FENCE_IDLE, FENCE_DRAIN} fence_state_t;
    fence_state_t state_q;
    logic abort_seen_q;
    logic flush_seen_q;
    logic abort_pending_q;
    logic flush_pending_q;

    logic abort_edge;
    logic flush_edge;
    logic all_quiescent;
    logic admission_ok;
    logic start_fire;

    initial begin
        if (EPOCH_W < 1)
            $fatal(1, "EPOCH_W must be positive");
    end

    assign abort_edge = abort_req && !abort_seen_q;
    assign flush_edge = flush_req && !flush_seen_q;
    assign all_quiescent = read_quiescent && write_quiescent &&
                           !read_busy && !write_busy;

    // Include the current request edge in the combinational block.  This is
    // what prevents a source from accepting a new transaction in the same
    // cycle that software raises abort/flush.
    assign fence_busy = (state_q == FENCE_DRAIN) ||
                        abort_pending_q || flush_pending_q;
    assign admission_ok = !rst && !fence_busy && !abort_req && !flush_req &&
                          !abort_edge && !flush_edge &&
                          (!REQUIRE_CONTEXT || context_active);
    assign read_admit = admission_ok;
    assign write_admit = admission_ok;

    assign context_start_ready = !rst &&
                                 (state_q == FENCE_IDLE) &&
                                 !abort_pending_q && !flush_pending_q &&
                                 all_quiescent && !abort_req && !flush_req &&
                                 !abort_edge && !flush_edge &&
                                 (!REQUIRE_CONTEXT || !context_active ||
                                  ALLOW_RESTART);
    assign start_fire = context_start_valid && context_start_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= FENCE_IDLE;
            abort_seen_q <= 1'b0;
            flush_seen_q <= 1'b0;
            abort_pending_q <= 1'b0;
            flush_pending_q <= 1'b0;
            context_active <= 1'b0;
            current_epoch <= '0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            epoch_bump <= 1'b0;
            protocol_error <= 1'b0;
            perf_fence_count <= 64'd0;
            perf_abort_count <= 64'd0;
            perf_flush_count <= 64'd0;
        end else begin
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            epoch_bump <= 1'b0;

            if (!abort_req)
                abort_seen_q <= 1'b0;
            else
                abort_seen_q <= 1'b1;
            if (!flush_req)
                flush_seen_q <= 1'b0;
            else
                flush_seen_q <= 1'b1;

            if (start_fire)
                context_active <= 1'b1;

            if (abort_edge)
                abort_pending_q <= 1'b1;
            if (flush_edge)
                flush_pending_q <= 1'b1;
            if (abort_edge || flush_edge)
                state_q <= FENCE_DRAIN;

            // A direction that bypasses read_admit/write_admit is a wiring
            // error in the eventual owner mux.  Keep this sticky rather than
            // killing a long boardless run; software can expose the bit as a
            // diagnostic until the final CSR is assigned.
            if ((read_fire && !read_admit && !read_busy) ||
                (write_fire && !write_admit && !write_busy))
                protocol_error <= 1'b1;

            if ((state_q == FENCE_DRAIN) && all_quiescent) begin
                if (abort_pending_q || abort_edge) begin
                    abort_done <= 1'b1;
                    perf_abort_count <= perf_abort_count + 1'b1;
                    context_active <= 1'b0;
                end
                if (flush_pending_q || flush_edge) begin
                    flush_done <= 1'b1;
                    perf_flush_count <= perf_flush_count + 1'b1;
                end
                if (abort_pending_q || flush_pending_q ||
                    abort_edge || flush_edge) begin
                    current_epoch <= current_epoch + 1'b1;
                    epoch_bump <= 1'b1;
                    perf_fence_count <= perf_fence_count + 1'b1;
                end
                abort_pending_q <= 1'b0;
                flush_pending_q <= 1'b0;
                state_q <= FENCE_IDLE;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (epoch_bump && !all_quiescent)
                $fatal(1, "owner/epoch fence bumped before both directions quiesced");
            if (abort_done && !epoch_bump)
                $fatal(1, "abort_done without epoch bump");
            if (flush_done && !epoch_bump)
                $fatal(1, "flush_done without epoch bump");
            if (read_admit && fence_busy)
                $fatal(1, "read admission remained open while fence was busy");
            if (write_admit && fence_busy)
                $fatal(1, "write admission remained open while fence was busy");
        end
    end
`endif

endmodule
