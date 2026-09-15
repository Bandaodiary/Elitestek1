`timescale 1ns/1ps

// Board-independent composition of the cache-refill scheduler and the
// existing AXI128 read burst client.
//
// This wrapper deliberately keeps the two blocks' protocol boundary local:
//   * c1_cache_refill_scheduler owns command ordering, epoch fences, request
//     credits, and row/word metadata;
//   * c1_tensor_mem_axi128_read_burst_client owns request FIFOing, adjacent
//     64-bit request packing, AXI burst formation, and AXI response buffering.
//
// The scheduler's leaf occupancy is driven by the reader's logical request
// FIFO occupancy (perf_req_occupancy), and leaf_quiescent is driven by the
// reader's perf_busy indication.  leaf_req_flush is connected to req_flush;
// this is the close pulse which prevents the reader from merging a completed
// row with a later row/epoch.  The reader has no epoch field, so the epoch is
// intentionally retained at the scheduler/word boundary rather than put on
// the AXI channel.
//
// The default EMIT_DRAIN_WORDS=0 preserves the scheduler's normal word-only
// behavior.  Set it to one when the downstream refill sink must consume
// canceled/stale responses (for example, to finish a line-cache refill
// transaction after an epoch fence); connect drain_word_ready accordingly.
// No board-specific primitives or vendor IP are instantiated here.
module c1_cache_refill_scheduler_read_client #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 64,
    parameter integer EPOCH_W = 8,
    parameter integer CMD_FIFO_DEPTH = 4,
    // The scheduler credit is counted in logical 64-bit refill words.  It is
    // intentionally independent from the reader's AXI-burst descriptor
    // credit below: one AXI burst can contain two logical words, and a reader
    // may also queue logical requests while only a few bursts are in flight.
    // A value of 16 is a useful boardless starting point for a row refill;
    // reduce it if the metadata FIFO is intentionally kept small.
    parameter integer SCHED_MAX_OUTSTANDING = 16,
    parameter integer EMIT_DRAIN_WORDS = 0,

    // AXI128 reader parameters.  REQ_FIFO_DEPTH is the logical 64-bit
    // request FIFO; BURST_BEATS controls the maximum AXI INCR burst length.
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer READER_MAX_OUTSTANDING = 4,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS * READER_MAX_OUTSTANDING,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    parameter bit RSP_FIFO_BEAT_MODE = 1'b0,
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0,
    parameter bit ALLOW_SCHED_REQ_HANDOFF = 1'b0,
    parameter bit REJECT_ON_EPOCH_EXHAUSTION = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Refill command stream.  One command describes one contiguous row.
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [ADDR_W-1:0]            cmd_base_addr,
    input  logic [ADDR_W-1:0]            cmd_stride_bytes,
    input  logic [15:0]                  cmd_row,
    input  logic [15:0]                  cmd_word_count,
    input  logic [EPOCH_W-1:0]            cmd_epoch,

    // Edge-qualified maintenance controls and scheduler epoch.
    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,
    output logic [EPOCH_W-1:0]            current_epoch,

    // Committed current-epoch words.
    output logic                         word_valid,
    input  logic                         word_ready,
    output logic [DATA_W-1:0]             word_data,
    output logic                         word_error,
    output logic                         word_last,
    output logic [15:0]                  word_row,
    output logic [15:0]                  word_index,
    output logic [EPOCH_W-1:0]            word_epoch,

    // Optional canceled/stale response stream.  It is present as a stable
    // port even when EMIT_DRAIN_WORDS=0, in which case drain_word_valid is
    // permanently low.  A drain word is never a committed normal word.
    output logic                         drain_word_valid,
    input  logic                         drain_word_ready,
    output logic [DATA_W-1:0]             drain_word_data,
    output logic                         drain_word_error,
    output logic                         drain_word_last,
    output logic [15:0]                  drain_word_row,
    output logic [15:0]                  drain_word_index,
    output logic [EPOCH_W-1:0]            drain_word_epoch,

    // Scheduler command completion and status.
    output logic                         cmd_done,
    output logic                         cmd_done_error,
    output logic [15:0]                  cmd_done_row,
    output logic [EPOCH_W-1:0]            cmd_done_epoch,
    output logic                         busy,
    output logic                         quiescent,
    output logic                         drain_pending,
    output logic [7:0]                   outstanding,
    output logic [7:0]                   max_outstanding_seen,
    output logic [7:0]                   cmd_occupancy,
    output logic [63:0]                  perf_cmd_accept_count,
    output logic [63:0]                  perf_req_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_word_count,
    output logic [63:0]                  perf_stale_drop_count,
    output logic [63:0]                  perf_orphan_rsp_count,
    output logic [63:0]                  perf_error_count,

    // AXI4 read master (128-bit data, ID-less/in-order response path).
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    // Reader-side diagnostics.  These are not needed by the scheduler
    // protocol, but exposing them makes boardless throughput/resource tests
    // and eventual board bring-up observable without probing internals.
    output logic                         leaf_perf_busy,
    output logic [63:0]                  leaf_perf_req_accept_count,
    output logic [63:0]                  leaf_perf_axi_burst_count,
    output logic [63:0]                  leaf_perf_axi_beat_count,
    output logic [63:0]                  leaf_perf_rsp_count,
    output logic [63:0]                  leaf_perf_packed_request_count,
    output logic [63:0]                  leaf_perf_error_count,
    output logic [7:0]                   leaf_perf_req_occupancy,
    output logic [7:0]                   leaf_perf_max_req_occupancy,
    output logic [7:0]                   leaf_perf_outstanding,
    output logic [7:0]                   leaf_perf_max_outstanding
);

    // The leaf reader is currently a fixed 32-bit-address/64-bit-logical
    // request block.  The checks below make accidental parameter widening a
    // deliberate elaboration error instead of a silent truncation at the
    // scheduler-to-reader boundary.
    initial begin
        if (ADDR_W != 32)
            $fatal(1, "c1_cache_refill_scheduler_read_client requires ADDR_W=32");
        if (DATA_W != 64)
            $fatal(1, "c1_cache_refill_scheduler_read_client requires DATA_W=64");
    end

    // Scheduler-to-leaf logical stream.  Epoch is diagnostic at this seam;
    // the reader itself is ID-less and returns responses in AXI AR order.
    logic [ADDR_W-1:0]       leaf_req_addr;
    logic [EPOCH_W-1:0]      leaf_req_epoch;
    logic                    leaf_req_valid;
    logic                    leaf_req_ready;
    logic                    leaf_req_flush;
    logic [63:0]             leaf_rsp_data;
    logic                    leaf_rsp_valid;
    logic                    leaf_rsp_ready;
    logic                    leaf_rsp_error;
    logic                    leaf_quiescent;

    assign leaf_quiescent = !leaf_perf_busy;

    // ------------------------------------------------------------------
    // Command/epoch scheduler.
    // ------------------------------------------------------------------
    c1_cache_refill_scheduler #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_FIFO_DEPTH),
        .MAX_OUTSTANDING(SCHED_MAX_OUTSTANDING),
        .ALLOW_REQ_HANDOFF(ALLOW_SCHED_REQ_HANDOFF),
        .REJECT_ON_EPOCH_EXHAUSTION(REJECT_ON_EPOCH_EXHAUSTION),
        .EMIT_DRAIN_WORDS(EMIT_DRAIN_WORDS)
    ) u_scheduler (
        .clk(clk),
        .rst(rst),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_base_addr(cmd_base_addr),
        .cmd_stride_bytes(cmd_stride_bytes),
        .cmd_row(cmd_row),
        .cmd_word_count(cmd_word_count),
        .cmd_epoch(cmd_epoch),
        .abort_req(abort_req),
        .abort_done(abort_done),
        .flush_req(flush_req),
        .flush_done(flush_done),
        .current_epoch(current_epoch),
        .leaf_req_valid(leaf_req_valid),
        .leaf_req_ready(leaf_req_ready),
        .leaf_req_addr(leaf_req_addr),
        .leaf_req_epoch(leaf_req_epoch),
        .leaf_req_flush(leaf_req_flush),
        .leaf_req_occupancy(leaf_perf_req_occupancy),
        .leaf_quiescent(leaf_quiescent),
        .leaf_rsp_valid(leaf_rsp_valid),
        .leaf_rsp_ready(leaf_rsp_ready),
        .leaf_rsp_data(leaf_rsp_data),
        .leaf_rsp_error(leaf_rsp_error),
        .word_valid(word_valid),
        .word_ready(word_ready),
        .word_data(word_data),
        .word_error(word_error),
        .word_last(word_last),
        .word_row(word_row),
        .word_index(word_index),
        .word_epoch(word_epoch),
        .drain_word_valid(drain_word_valid),
        .drain_word_ready(drain_word_ready),
        .drain_word_data(drain_word_data),
        .drain_word_error(drain_word_error),
        .drain_word_last(drain_word_last),
        .drain_word_row(drain_word_row),
        .drain_word_index(drain_word_index),
        .drain_word_epoch(drain_word_epoch),
        .cmd_done(cmd_done),
        .cmd_done_error(cmd_done_error),
        .cmd_done_row(cmd_done_row),
        .cmd_done_epoch(cmd_done_epoch),
        .busy(busy),
        .quiescent(quiescent),
        .drain_pending(drain_pending),
        .outstanding(outstanding),
        .max_outstanding_seen(max_outstanding_seen),
        .cmd_occupancy(cmd_occupancy),
        .perf_cmd_accept_count(perf_cmd_accept_count),
        .perf_req_count(perf_req_count),
        .perf_rsp_count(perf_rsp_count),
        .perf_word_count(perf_word_count),
        .perf_stale_drop_count(perf_stale_drop_count),
        .perf_orphan_rsp_count(perf_orphan_rsp_count),
        .perf_error_count(perf_error_count)
    );

    // ------------------------------------------------------------------
    // AXI128 read leaf.
    // ------------------------------------------------------------------
    c1_tensor_mem_axi128_read_burst_client #(
        .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .MAX_OUTSTANDING(READER_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL)
    ) u_read_client (
        .clk(clk),
        .rst(rst),
        .req_valid(leaf_req_valid),
        .req_ready(leaf_req_ready),
        .req_flush(leaf_req_flush),
        .req_addr(leaf_req_addr),
        .rsp_valid(leaf_rsp_valid),
        .rsp_ready(leaf_rsp_ready),
        .rsp_error(leaf_rsp_error),
        .rsp_rdata(leaf_rsp_data),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .perf_busy(leaf_perf_busy),
        .perf_req_accept_count(leaf_perf_req_accept_count),
        .perf_axi_burst_count(leaf_perf_axi_burst_count),
        .perf_axi_beat_count(leaf_perf_axi_beat_count),
        .perf_rsp_count(leaf_perf_rsp_count),
        .perf_packed_request_count(leaf_perf_packed_request_count),
        .perf_error_count(leaf_perf_error_count),
        .perf_req_occupancy(leaf_perf_req_occupancy),
        .perf_max_req_occupancy(leaf_perf_max_req_occupancy),
        .perf_outstanding(leaf_perf_outstanding),
        .perf_max_outstanding(leaf_perf_max_outstanding)
    );

`ifndef SYNTHESIS
    // Elaboration-time interface invariants useful when this wrapper is
    // instantiated from a generated top-level.  The reader's request address
    // remains 8-byte aligned.  Do not compare leaf_req_epoch with
    // current_epoch here: the scheduler is explicitly allowed to hold an
    // already-presented old-epoch request across a maintenance edge until
    // that request handshakes.
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (leaf_req_valid && (leaf_req_addr[2:0] != 3'b000))
                $fatal(1, "scheduler emitted non-8-byte-aligned leaf request");
        end
    end
`endif

endmodule
