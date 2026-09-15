`timescale 1ns/1ps

// Exact-count boardless composition for a line-cache refill source.
//
// The ordinary scheduler/read-client wrapper exposes two output streams:
// current-epoch words and canceled/stale drain words.  A line cache has a
// stronger ABI: after accepting a row declaration it must handshake exactly
// that many refill words, even if a fence arrives before all logical requests
// have entered the AXI reader.  This composition inserts
// c1_cache_refill_completion_adapter between the scheduler and the sink.  It
// passes accepted normal/drain words and emits zero/error poison words for an
// unissued suffix after a scheduler terminal token.
//
// This module is deliberately a staged seam.  It owns no vendor primitive,
// DDR controller, or write path, and it is not instantiated by the default
// SoC.  The scheduler's drain mode is forced on because the exact-count
// adapter must be able to retire accepted stale responses rather than silently
// dropping them.
module c1_cache_refill_scheduler_read_client_exact #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 64,
    parameter integer EPOCH_W = 8,
    parameter integer CMD_FIFO_DEPTH = 4,
    parameter integer SCHED_MAX_OUTSTANDING = 16,
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer READER_MAX_OUTSTANDING = 4,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS * READER_MAX_OUTSTANDING,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    parameter bit RSP_FIFO_BEAT_MODE = 1'b0,
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0,
    // A canceled row is invalid data, but an expected frame fence should not
    // permanently poison the cache stage.  Structural sideband/LAST faults
    // remain sticky protocol errors; the completion adapter still reports the
    // canceled refill through refill_done_error.
    parameter bit CANCEL_IS_PROTOCOL_ERROR = 1'b0,
    parameter bit ALLOW_SCHED_REQ_HANDOFF = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // One command describes one contiguous logical row.
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [ADDR_W-1:0]             cmd_base_addr,
    input  logic [ADDR_W-1:0]             cmd_stride_bytes,
    input  logic [15:0]                   cmd_row,
    input  logic [15:0]                   cmd_word_count,
    input  logic [EPOCH_W-1:0]            cmd_epoch,

    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,
    output logic [EPOCH_W-1:0]            current_epoch,

    // Unified exact-count refill stream for c1_window_line_cache_c8.
    output logic                         refill_word_valid,
    input  logic                         refill_word_ready,
    output logic [DATA_W-1:0]             refill_word_data,
    output logic                         refill_word_error,
    output logic                         refill_word_last,
    output logic [15:0]                   refill_word_row,
    output logic [15:0]                   refill_word_index,
    output logic [EPOCH_W-1:0]            refill_word_epoch,
    output logic                         refill_done,
    output logic                         refill_done_error,
    output logic                         protocol_error,
    output logic                         active,
    output logic                         synthetic_active,
    output logic [15:0]                   emitted_count,

    // Raw scheduler completion/status diagnostics.
    output logic                         cmd_done,
    output logic                         cmd_done_error,
    output logic [15:0]                   cmd_done_row,
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

    // AXI4 read master from the packaged leaf.
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

    // Reader diagnostics.
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

    initial begin
        if (ADDR_W != 32)
            $fatal(1, "exact scheduler/read-client composition requires ADDR_W=32");
        if (DATA_W != 64)
            $fatal(1, "exact scheduler/read-client composition requires DATA_W=64");
    end

    // Core scheduler/read-client boundary.
    logic core_cmd_valid, core_cmd_ready;
    logic [ADDR_W-1:0] core_cmd_base_addr, core_cmd_stride_bytes;
    logic [15:0] core_cmd_row, core_cmd_word_count;
    logic [EPOCH_W-1:0] core_cmd_epoch;
    logic core_abort_done, core_flush_done;
    logic [EPOCH_W-1:0] core_epoch;
    logic core_word_valid, core_word_ready;
    logic [DATA_W-1:0] core_word_data;
    logic core_word_error, core_word_last;
    logic [15:0] core_word_row, core_word_index;
    logic [EPOCH_W-1:0] core_word_epoch;
    logic core_drain_valid, core_drain_ready;
    logic [DATA_W-1:0] core_drain_data;
    logic core_drain_error, core_drain_last;
    logic [15:0] core_drain_row, core_drain_index;
    logic [EPOCH_W-1:0] core_drain_epoch;
    logic core_cmd_done, core_cmd_done_error;
    logic [15:0] core_cmd_done_row;
    logic [EPOCH_W-1:0] core_cmd_done_epoch;
    logic core_busy, core_quiescent, core_drain_pending;
    logic [7:0] core_outstanding, core_max_outstanding, core_cmd_occupancy;
    logic [63:0] core_perf_cmd_accept_count, core_perf_req_count;
    logic [63:0] core_perf_rsp_count, core_perf_word_count;
    logic [63:0] core_perf_stale_drop_count, core_perf_orphan_rsp_count;
    logic [63:0] core_perf_error_count;

    c1_cache_refill_scheduler_read_client #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_FIFO_DEPTH),
        .SCHED_MAX_OUTSTANDING(SCHED_MAX_OUTSTANDING),
        .ALLOW_SCHED_REQ_HANDOFF(ALLOW_SCHED_REQ_HANDOFF),
        // A permanent scheduler READY=0 would strand an already accepted
        // cache/column row after epoch exhaustion. An error terminal permits
        // the completion adapter to synthesize its declared poison suffix.
        .REJECT_ON_EPOCH_EXHAUSTION(1'b1),
        .EMIT_DRAIN_WORDS(1),
        .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .READER_MAX_OUTSTANDING(READER_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL)
    ) u_core (
        .clk(clk), .rst(rst),
        .cmd_valid(core_cmd_valid), .cmd_ready(core_cmd_ready),
        .cmd_base_addr(core_cmd_base_addr),
        .cmd_stride_bytes(core_cmd_stride_bytes),
        .cmd_row(core_cmd_row), .cmd_word_count(core_cmd_word_count),
        .cmd_epoch(core_cmd_epoch),
        .abort_req(abort_req), .abort_done(core_abort_done),
        .flush_req(flush_req), .flush_done(core_flush_done),
        .current_epoch(core_epoch),
        .word_valid(core_word_valid), .word_ready(core_word_ready),
        .word_data(core_word_data), .word_error(core_word_error),
        .word_last(core_word_last), .word_row(core_word_row),
        .word_index(core_word_index), .word_epoch(core_word_epoch),
        .drain_word_valid(core_drain_valid), .drain_word_ready(core_drain_ready),
        .drain_word_data(core_drain_data), .drain_word_error(core_drain_error),
        .drain_word_last(core_drain_last), .drain_word_row(core_drain_row),
        .drain_word_index(core_drain_index), .drain_word_epoch(core_drain_epoch),
        .cmd_done(core_cmd_done), .cmd_done_error(core_cmd_done_error),
        .cmd_done_row(core_cmd_done_row), .cmd_done_epoch(core_cmd_done_epoch),
        .busy(core_busy), .quiescent(core_quiescent),
        .drain_pending(core_drain_pending), .outstanding(core_outstanding),
        .max_outstanding_seen(core_max_outstanding),
        .cmd_occupancy(core_cmd_occupancy),
        .perf_cmd_accept_count(core_perf_cmd_accept_count),
        .perf_req_count(core_perf_req_count),
        .perf_rsp_count(core_perf_rsp_count),
        .perf_word_count(core_perf_word_count),
        .perf_stale_drop_count(core_perf_stale_drop_count),
        .perf_orphan_rsp_count(core_perf_orphan_rsp_count),
        .perf_error_count(core_perf_error_count),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .leaf_perf_busy(leaf_perf_busy),
        .leaf_perf_req_accept_count(leaf_perf_req_accept_count),
        .leaf_perf_axi_burst_count(leaf_perf_axi_burst_count),
        .leaf_perf_axi_beat_count(leaf_perf_axi_beat_count),
        .leaf_perf_rsp_count(leaf_perf_rsp_count),
        .leaf_perf_packed_request_count(leaf_perf_packed_request_count),
        .leaf_perf_error_count(leaf_perf_error_count),
        .leaf_perf_req_occupancy(leaf_perf_req_occupancy),
        .leaf_perf_max_req_occupancy(leaf_perf_max_req_occupancy),
        .leaf_perf_outstanding(leaf_perf_outstanding),
        .leaf_perf_max_outstanding(leaf_perf_max_outstanding)
    );

    // Exact-count ABI bridge.  Command fields are forwarded unchanged; the
    // adapter locally retains row/count/epoch for sideband checking and
    // synthetic suffix generation.
    c1_cache_refill_completion_adapter #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CANCEL_IS_PROTOCOL_ERROR(CANCEL_IS_PROTOCOL_ERROR)
    ) u_completion (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_base_addr(cmd_base_addr), .cmd_stride_bytes(cmd_stride_bytes),
        .cmd_row(cmd_row), .cmd_word_count(cmd_word_count),
        .cmd_epoch(cmd_epoch),
        .sched_cmd_valid(core_cmd_valid), .sched_cmd_ready(core_cmd_ready),
        .sched_cmd_base_addr(core_cmd_base_addr),
        .sched_cmd_stride_bytes(core_cmd_stride_bytes),
        .sched_cmd_row(core_cmd_row), .sched_cmd_word_count(core_cmd_word_count),
        .sched_cmd_epoch(core_cmd_epoch),
        .sched_cmd_done(core_cmd_done),
        .sched_cmd_done_error(core_cmd_done_error),
        .sched_cmd_done_row(core_cmd_done_row),
        .sched_cmd_done_epoch(core_cmd_done_epoch),
        .sched_abort_done(core_abort_done), .sched_flush_done(core_flush_done),
        .sched_word_valid(core_word_valid), .sched_word_ready(core_word_ready),
        .sched_word_data(core_word_data), .sched_word_error(core_word_error),
        .sched_word_last(core_word_last), .sched_word_row(core_word_row),
        .sched_word_index(core_word_index), .sched_word_epoch(core_word_epoch),
        .sched_drain_valid(core_drain_valid), .sched_drain_ready(core_drain_ready),
        .sched_drain_data(core_drain_data), .sched_drain_error(core_drain_error),
        .sched_drain_last(core_drain_last), .sched_drain_row(core_drain_row),
        .sched_drain_index(core_drain_index), .sched_drain_epoch(core_drain_epoch),
        .refill_word_valid(refill_word_valid),
        .refill_word_ready(refill_word_ready),
        .refill_word_data(refill_word_data),
        .refill_word_error(refill_word_error),
        .refill_word_last(refill_word_last),
        .refill_word_row(refill_word_row),
        .refill_word_index(refill_word_index),
        .refill_word_epoch(refill_word_epoch),
        .refill_done(refill_done), .refill_done_error(refill_done_error),
        .protocol_error(protocol_error), .active(active),
        .synthetic_active(synthetic_active), .emitted_count(emitted_count)
    );

    assign abort_done = core_abort_done;
    assign flush_done = core_flush_done;
    assign current_epoch = core_epoch;
    assign cmd_done = core_cmd_done;
    assign cmd_done_error = core_cmd_done_error;
    assign cmd_done_row = core_cmd_done_row;
    assign cmd_done_epoch = core_cmd_done_epoch;
    // The adapter may wait a few cycles after the scheduler says its leaf is
    // quiescent, so expose the stricter combined status to the line-cache
    // integration layer.
    assign busy = core_busy || active;
    assign quiescent = core_quiescent && !active;
    assign drain_pending = core_drain_pending || synthetic_active;
    assign outstanding = core_outstanding;
    assign max_outstanding_seen = core_max_outstanding;
    assign cmd_occupancy = core_cmd_occupancy;
    assign perf_cmd_accept_count = core_perf_cmd_accept_count;
    assign perf_req_count = core_perf_req_count;
    assign perf_rsp_count = core_perf_rsp_count;
    assign perf_word_count = core_perf_word_count;
    assign perf_stale_drop_count = core_perf_stale_drop_count;
    assign perf_orphan_rsp_count = core_perf_orphan_rsp_count;
    assign perf_error_count = core_perf_error_count;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (core_word_valid && core_drain_valid)
                $fatal(1, "exact composition saw normal/drain overlap");
        end
    end
`endif

endmodule
