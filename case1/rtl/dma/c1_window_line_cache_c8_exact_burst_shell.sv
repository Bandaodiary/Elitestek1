`timescale 1ns/1ps

// Boardless exact-count integration seam for the C8 line cache.
//
// c1_window_line_cache_c8 and c1_cache_refill_scheduler_read_client_exact
// deliberately have different command contracts:
//
//   * the cache asks for {row, word_count}; its stage base and row stride are
//     implicit in the stage configuration;
//   * the exact scheduler/read-client asks for {base, stride, row,
//     word_count, epoch} and returns one unified exact-count stream.
//
// This module is the narrow bridge between those contracts.  It captures the
// stage base at the same group_start handshake as the cache geometry, derives
// the row stride with a bounded shift/add tree, and serializes one cache
// refill request into the exact-count reader.  The completion adapter inside
// the exact reader supplies zero/error poison words for an unissued suffix
// after a fence, so the cache's existing "drain the declared count" ABI is
// preserved.
// The scheduler command uses `base = stage_base + row*row_stride` and
// `stride = 8`; `row` is retained as sideband only.  This distinction is
// intentional because the scheduler's stride advances between logical C8
// words, while the cache's row stride advances between image rows.
//
// The seam is intentionally read-only and board-independent.  It owns no
// vendor primitive, DDR controller, or AXI mux.  The default SoC is not
// instantiated here; this module can be used as a staged integration target
// and as a compact contract test top.
module c1_window_line_cache_c8_exact_burst_shell #(
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    parameter integer EPOCH_W = 8,
    parameter integer CMD_FIFO_DEPTH = 2,
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
    // Expected frame-fence cancellation is normally reported as a refill
    // data error but does not poison the stage.  Expose the policy at this
    // shell boundary so a stricter integration can opt back into the legacy
    // sticky protocol-error behavior explicitly.
    parameter bit CANCEL_IS_PROTOCOL_ERROR = 1'b0,
    // Registered refill elasticity.  A count-only ready signal deliberately
    // does not depend on the line-cache output ready, breaking the long
    // cache->adapter->scheduler->AXI RREADY path seen in the first proxy.
    // The FIFO stores all line-cache-visible sideband, even though the cache
    // itself consumes only data/error/last.
    parameter integer REFILL_SKID_DEPTH = 2,
    // The surrounding tensor seam already saturates tap coordinates against
    // the captured stage geometry.  Pass this opt-in through to the payload
    // cache to remove a duplicate width/height compare from tap_ready.
    parameter integer PRECLAMPED_TAP_COORDS = 0,
    parameter bit ALLOW_SCHED_REQ_HANDOFF = 1'b0,
    // Explicit alternate ABI, not a wider scalar tap: tap_x/tap_y name the
    // column x/center_y, and each accepted request (including a miss) returns
    // three C8 words, top/center/bottom. Default keeps the scalar retry ABI.
    // Both modes share the SAME command/epoch/skid/maintenance transport.
    parameter bit COLUMN_MODE = 1'b0,
    parameter bit COLUMN_READ_ON_LOOKUP = 1'b0,
    parameter bit COLUMN_RESPONSE_BYPASS = 1'b0,
    parameter bit COLUMN_REUSE_ROW_MAP = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Stage base is sampled atomically with group_start.  Keeping this valid
    // high while a stage is configured is allowed; only the handshake edge
    // changes the captured base/stride.
    input  logic                         stage_base_valid,
    input  logic [31:0]                  stage_base_addr,

    input  logic                         group_start_valid,
    output logic                         group_start_ready,
    input  logic [15:0]                  frame_width,
    input  logic [15:0]                  frame_height,
    input  logic [3:0]                   frame_groups,
    output logic                         group_start_done,
    output logic                         group_start_error,
    output logic [2:0]                   group_start_error_code,
    output logic                         config_valid,

    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,

    input  logic                         tap_valid,
    output logic                         tap_ready,
    input  logic signed [16:0]           tap_x,
    input  logic signed [16:0]           tap_y,
    input  logic [2:0]                   tap_group,
    output logic                         tap_rsp_valid,
    input  logic                         tap_rsp_ready,
    output logic [(COLUMN_MODE ? 3 : 1)*DATA_W-1:0] tap_rsp_data_s8,
    output logic                         tap_rsp_error,

    // AXI4 read master.  The read client is ID-less and preserves descriptor
    // order; the external fabric may insert arbitrary AR/R back-pressure.
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    // Cache-visible diagnostics.
    output logic                         cache_error,
    output logic [2:0]                   cache_error_code,
    output logic                         refill_protocol_error,
    output logic                         refill_done,
    output logic                         refill_done_error,
    output logic                         busy,
    output logic                         quiescent,
    output logic [63:0]                  perf_refill_count,
    output logic [63:0]                  perf_refill_word_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_cache_rsp_count,
    output logic [7:0]                   perf_max_outstanding,

    // Exact-reader diagnostics are exposed so a board-level owner/mux can
    // observe the logical-word and AXI-burst credits independently.
    output logic [EPOCH_W-1:0]            current_epoch,
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
    output logic [63:0]                  perf_scheduler_error_count,
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
        if (DATA_W != 64)
            $fatal(1, "exact line-cache shell currently requires DATA_W=64");
        if ((MAX_ROW_WORDS < 1) || (MAX_ROW_WORDS > 65535))
            $fatal(1, "MAX_ROW_WORDS must be in the range 1..65535");
        if ((MAX_GROUPS < 1) || (MAX_GROUPS > 8))
            $fatal(1, "MAX_GROUPS must be in the range 1..8");
        if (EPOCH_W < 1)
            $fatal(1, "EPOCH_W must be positive");
        if (REFILL_SKID_DEPTH < 1)
            $fatal(1, "REFILL_SKID_DEPTH must be positive");
        if (COLUMN_MODE && PRECLAMPED_TAP_COORDS != 0)
            $fatal(1, "column mode requires logical center coordinates, not preclamped scalar taps");
    end

    // ------------------------------------------------------------------
    // Stage geometry and command bridge.
    // ------------------------------------------------------------------
    logic [31:0] stage_base_q;
    logic [31:0] row_stride_bytes_q;
    logic [19:0] row_words_full_comb;
    logic [31:0] cache_row_stride_comb;

    function automatic logic [19:0] width_times_groups(
        input logic [15:0] width_value,
        input logic [3:0]  group_value
    );
        logic [19:0] product;
        begin
            product = 20'd0;
            if (group_value[0]) product = product + {4'd0, width_value};
            if (group_value[1]) product = product + ({4'd0, width_value} << 1);
            if (group_value[2]) product = product + ({4'd0, width_value} << 2);
            if (group_value[3]) product = product + ({4'd0, width_value} << 3);
            width_times_groups = product;
        end
    endfunction

    // The scheduler's stride is the byte distance between consecutive
    // logical words (normally eight for one C8 word), not the distance
    // between rows.  Convert the cache's row request into a row-specific base
    // here and keep the scheduler stride at 8.  The bounded shift/add form
    // avoids putting a variable multiply/DSP in the command path.
    function automatic logic [31:0] row_offset_bytes(
        input logic [15:0] row_value,
        input logic [31:0] stride_value
    );
        logic [31:0] accum;
        integer row_bit;
        begin
            accum = 32'd0;
            for (row_bit = 0; row_bit < 16; row_bit = row_bit + 1)
                if (row_value[row_bit])
                    accum = accum + (stride_value << row_bit);
            row_offset_bytes = accum;
        end
    endfunction

    always_comb begin
        row_words_full_comb = width_times_groups(frame_width, frame_groups);
        cache_row_stride_comb = {12'd0, row_words_full_comb} << 3;
    end

    logic cache_group_start_valid, cache_group_start_ready;
    logic group_start_fire;
    logic start_gate;

    logic cache_abort_done, cache_flush_done;
    logic cache_tap_ready, cache_tap_rsp_valid;
    logic [(COLUMN_MODE ? 3 : 1)*DATA_W-1:0] cache_tap_rsp_data;
    logic cache_tap_rsp_error;
    logic cache_config_valid;
    logic cache_error_core;
    logic [2:0] cache_error_code_core;
    logic cache_busy, cache_quiescent;

    logic cache_refill_req_valid, cache_refill_req_ready;
    logic [15:0] cache_refill_req_row, cache_refill_req_word_count;
    logic cache_refill_word_valid, cache_refill_word_ready;
    logic [DATA_W-1:0] cache_refill_word_data;
    logic cache_refill_word_last, cache_refill_word_error;

    // Maintenance join state is declared before any admission equations so
    // older Vivado front ends do not have to resolve a forward net reference.
    logic abort_seen_q, flush_seen_q;
    logic abort_pending_q, flush_pending_q;
    logic abort_cache_seen_q, abort_exact_seen_q;
    logic flush_cache_seen_q, flush_exact_seen_q;
    logic new_abort, new_flush;
    // A column miss is accepted up front. Do not reopen its admission when
    // the cache child finishes before the outer two-child maintenance join.
    // Keep the historical scalar gate unchanged; its tensor owner fences it.
    wire column_admission = !abort_pending_q && !flush_pending_q &&
                            !abort_req && !flush_req && !group_start_valid;

    // A one-entry command holding register gives the line cache and scheduler
    // independent ready/valid timing.  In particular, epoch is captured once
    // and cannot change under a stalled command when a later fence increments
    // the scheduler epoch.
    logic cmd_hold_valid_q;
    logic [31:0] cmd_hold_base_q, cmd_hold_stride_q;
    logic [15:0] cmd_hold_row_q, cmd_hold_words_q;
    logic [EPOCH_W-1:0] cmd_hold_epoch_q;
    logic cmd_hold_fire, exact_cmd_fire;

    logic exact_cmd_valid, exact_cmd_ready;
    logic exact_abort_done, exact_flush_done;
    logic [EPOCH_W-1:0] exact_current_epoch;
    logic exact_refill_word_valid, exact_refill_word_ready;
    logic [DATA_W-1:0] exact_refill_word_data;
    logic exact_refill_word_error, exact_refill_word_last;
    logic [15:0] exact_refill_word_row, exact_refill_word_index;
    logic [EPOCH_W-1:0] exact_refill_word_epoch;
    logic exact_refill_done, exact_refill_done_error, exact_protocol_error;
    logic exact_active, exact_synthetic_active;
    logic [15:0] exact_emitted_count;
    logic exact_cmd_done, exact_cmd_done_error;
    logic [15:0] exact_cmd_done_row;
    logic [EPOCH_W-1:0] exact_cmd_done_epoch;
    logic exact_busy, exact_quiescent, exact_drain_pending;
    logic [7:0] exact_outstanding, exact_max_outstanding, exact_cmd_occupancy;
    logic [63:0] exact_perf_cmd_accept_count, exact_perf_req_count;
    logic [63:0] exact_perf_rsp_count, exact_perf_word_count;
    logic [63:0] exact_perf_stale_drop_count, exact_perf_orphan_rsp_count;
    logic [63:0] exact_perf_error_count;

    // ------------------------------------------------------------------
    // Registered exact-stream skid/FIFO.
    // ------------------------------------------------------------------
    localparam integer SKID_PTR_W = (REFILL_SKID_DEPTH <= 1) ? 1 :
                                    $clog2(REFILL_SKID_DEPTH);
    localparam integer SKID_CNT_W = (REFILL_SKID_DEPTH <= 1) ? 1 :
                                    $clog2(REFILL_SKID_DEPTH + 1);
    logic [DATA_W-1:0] skid_data_mem [0:REFILL_SKID_DEPTH-1];
    logic skid_error_mem [0:REFILL_SKID_DEPTH-1];
    logic skid_last_mem [0:REFILL_SKID_DEPTH-1];
    logic [15:0] skid_row_mem [0:REFILL_SKID_DEPTH-1];
    logic [15:0] skid_index_mem [0:REFILL_SKID_DEPTH-1];
    logic [EPOCH_W-1:0] skid_epoch_mem [0:REFILL_SKID_DEPTH-1];
    logic [SKID_PTR_W-1:0] skid_head_q, skid_tail_q;
    logic [SKID_CNT_W-1:0] skid_count_q;
    logic skid_in_fire, skid_out_fire;

    // Do not let the cache consume group_start while the read side still
    // drains a previous epoch, or while the base is absent.  The valid is also
    // gated before entering the cache; otherwise the cache could handshake a
    // start that the outer shell did not advertise as ready.
    assign start_gate = !rst && stage_base_valid && exact_quiescent &&
                        !cmd_hold_valid_q && !abort_pending_q &&
                        !flush_pending_q && !abort_req && !flush_req;
    assign cache_group_start_valid = group_start_valid && start_gate;
    assign group_start_ready = start_gate && cache_group_start_ready;
    assign group_start_fire = cache_group_start_valid &&
                              cache_group_start_ready;

    generate if (!COLUMN_MODE) begin : g_scalar
    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(LINE_ROWS),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(MAX_GROUPS),
        .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS)
    ) u_cache (
        .clk(clk), .rst(rst),
        .group_start_valid(cache_group_start_valid),
        .group_start_ready(cache_group_start_ready),
        .frame_width(frame_width), .frame_height(frame_height),
        .frame_groups(frame_groups),
        .group_start_done(group_start_done),
        .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),
        .config_valid(cache_config_valid),
        .abort_req(abort_req), .abort_done(cache_abort_done),
        .flush_req(flush_req), .flush_done(cache_flush_done),
        .tap_valid(tap_valid), .tap_ready(cache_tap_ready),
        .tap_x(tap_x), .tap_y(tap_y), .tap_group(tap_group),
        .tap_rsp_valid(cache_tap_rsp_valid), .tap_rsp_ready(tap_rsp_ready),
        .tap_rsp_data_s8(cache_tap_rsp_data),
        .tap_rsp_error(cache_tap_rsp_error),
        .refill_req_valid(cache_refill_req_valid),
        .refill_req_ready(cache_refill_req_ready),
        .refill_req_row(cache_refill_req_row),
        .refill_req_word_count(cache_refill_req_word_count),
        .refill_word_valid(cache_refill_word_valid),
        .refill_word_ready(cache_refill_word_ready),
        .refill_word_data_s8(cache_refill_word_data),
        .refill_word_last(cache_refill_word_last),
        .refill_word_error(cache_refill_word_error),
        .cache_error(cache_error_core),
        .cache_error_code(cache_error_code_core),
        .busy(cache_busy), .quiescent(cache_quiescent)
    );
    end else begin : g_column
    c1_column_line_cache_c8 #(
        .DATA_W(DATA_W), .LINE_ROWS(LINE_ROWS),
        .READ_ON_LOOKUP(COLUMN_READ_ON_LOOKUP),
        .RESPONSE_BYPASS(COLUMN_RESPONSE_BYPASS),
        .REUSE_ROW_MAP(COLUMN_REUSE_ROW_MAP),
        .MAX_ROW_WORDS(MAX_ROW_WORDS), .MAX_GROUPS(MAX_GROUPS)
    ) u_cache (
        .clk(clk), .rst(rst),
        .group_start_valid(cache_group_start_valid),
        .group_start_ready(cache_group_start_ready),
        .frame_width(frame_width), .frame_height(frame_height), .frame_groups(frame_groups),
        .group_start_done(group_start_done), .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code), .config_valid(cache_config_valid),
        .abort_req(abort_req), .abort_done(cache_abort_done),
        .flush_req(flush_req), .flush_done(cache_flush_done),
        .column_valid(tap_valid && column_admission), .column_ready(cache_tap_ready),
        .column_x(tap_x), .column_y(tap_y), .column_group(tap_group),
        .column_rsp_valid(cache_tap_rsp_valid), .column_rsp_ready(tap_rsp_ready),
        .column_rsp_data_s8(cache_tap_rsp_data), .column_rsp_error(cache_tap_rsp_error),
        .refill_req_valid(cache_refill_req_valid), .refill_req_ready(cache_refill_req_ready),
        .refill_req_row(cache_refill_req_row), .refill_req_word_count(cache_refill_req_word_count),
        .refill_word_valid(cache_refill_word_valid), .refill_word_ready(cache_refill_word_ready),
        .refill_word_data_s8(cache_refill_word_data),
        .refill_word_last(cache_refill_word_last), .refill_word_error(cache_refill_word_error),
        .cache_error(cache_error_core), .cache_error_code(cache_error_code_core),
        .busy(cache_busy), .quiescent(cache_quiescent)
    );
    end endgenerate

    // The command bridge is normally admitted only when the exact reader is
    // quiescent, command admission is possible, and no maintenance edge is
    // visible.  There is one deliberate exception: if a fence arrives in the
    // same cycle that the line cache is holding REFILL_REQ, capture that
    // already-visible command into cmd_hold even though the scheduler has
    // closed its command FIFO for the new epoch.  The held command is then
    // presented after the fence and rejected by its old epoch; that rejection
    // supplies the exact-count poison suffix which lets the cache leave
    // REFILL_DATA and complete the fence.  Without this exception the cache
    // remains in ST_REFILL_REQ forever because neither child can make progress.
    assign cache_refill_req_ready = !cmd_hold_valid_q && exact_quiescent &&
                                    ((exact_cmd_ready &&
                                      !abort_pending_q && !flush_pending_q &&
                                      !abort_req && !flush_req) ||
                                     (cache_refill_req_valid &&
                                      (new_abort || new_flush)));
    assign cmd_hold_fire = cache_refill_req_valid && cache_refill_req_ready;
    assign exact_cmd_valid = cmd_hold_valid_q;
    assign exact_cmd_fire = exact_cmd_valid && exact_cmd_ready;

    c1_cache_refill_scheduler_read_client_exact #(
        .ADDR_W(32), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_FIFO_DEPTH),
        .SCHED_MAX_OUTSTANDING(SCHED_MAX_OUTSTANDING),
        .ALLOW_SCHED_REQ_HANDOFF(ALLOW_SCHED_REQ_HANDOFF),
        .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .READER_MAX_OUTSTANDING(READER_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL),
        .CANCEL_IS_PROTOCOL_ERROR(CANCEL_IS_PROTOCOL_ERROR)
    ) u_exact (
        .clk(clk), .rst(rst),
        .cmd_valid(exact_cmd_valid), .cmd_ready(exact_cmd_ready),
        .cmd_base_addr(cmd_hold_base_q),
        .cmd_stride_bytes(cmd_hold_stride_q),
        .cmd_row(cmd_hold_row_q), .cmd_word_count(cmd_hold_words_q),
        .cmd_epoch(cmd_hold_epoch_q),
        .abort_req(abort_req), .abort_done(exact_abort_done),
        .flush_req(flush_req), .flush_done(exact_flush_done),
        .current_epoch(exact_current_epoch),
        .refill_word_valid(exact_refill_word_valid),
        .refill_word_ready(exact_refill_word_ready),
        .refill_word_data(exact_refill_word_data),
        .refill_word_error(exact_refill_word_error),
        .refill_word_last(exact_refill_word_last),
        .refill_word_row(exact_refill_word_row),
        .refill_word_index(exact_refill_word_index),
        .refill_word_epoch(exact_refill_word_epoch),
        .refill_done(exact_refill_done),
        .refill_done_error(exact_refill_done_error),
        .protocol_error(exact_protocol_error),
        .active(exact_active), .synthetic_active(exact_synthetic_active),
        .emitted_count(exact_emitted_count),
        .cmd_done(exact_cmd_done), .cmd_done_error(exact_cmd_done_error),
        .cmd_done_row(exact_cmd_done_row),
        .cmd_done_epoch(exact_cmd_done_epoch),
        .busy(exact_busy), .quiescent(exact_quiescent),
        .drain_pending(exact_drain_pending),
        .outstanding(exact_outstanding),
        .max_outstanding_seen(exact_max_outstanding),
        .cmd_occupancy(exact_cmd_occupancy),
        .perf_cmd_accept_count(exact_perf_cmd_accept_count),
        .perf_req_count(exact_perf_req_count),
        .perf_rsp_count(exact_perf_rsp_count),
        .perf_word_count(exact_perf_word_count),
        .perf_stale_drop_count(exact_perf_stale_drop_count),
        .perf_orphan_rsp_count(exact_perf_orphan_rsp_count),
        .perf_error_count(exact_perf_error_count),
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

    // The exact-count stream is the only source connected to the cache.  The
    // adapter guarantees that a declared row receives exactly its word count;
    // metadata sidebands remain available for assertions/board diagnostics.
    // Input ready depends only on the registered occupancy.  In particular,
    // do not use `cache_refill_word_ready` in this equation: doing so would
    // recreate the combinational path this FIFO is intended to cut.
    assign exact_refill_word_ready = !rst &&
                                     (skid_count_q < REFILL_SKID_DEPTH);
    assign cache_refill_word_valid = !rst && (skid_count_q != 0);
    assign cache_refill_word_data = skid_data_mem[skid_head_q];
    assign cache_refill_word_error = skid_error_mem[skid_head_q];
    assign cache_refill_word_last = skid_last_mem[skid_head_q];
    assign skid_in_fire = exact_refill_word_valid &&
                          exact_refill_word_ready;
    assign skid_out_fire = cache_refill_word_valid &&
                           cache_refill_word_ready;

    assign tap_ready = cache_tap_ready && (!COLUMN_MODE || column_admission);
    assign tap_rsp_valid = cache_tap_rsp_valid;
    assign tap_rsp_data_s8 = cache_tap_rsp_data;
    assign tap_rsp_error = cache_tap_rsp_error;
    assign config_valid = cache_config_valid;

    // ------------------------------------------------------------------
    // Maintenance completion join.
    // ------------------------------------------------------------------
    // Both children receive the external edge.  Their completion pulses are
    // independent (the cache also waits for its tap/row stream), so a small
    // two-bit join retains an early pulse until the other child completes.
    assign new_abort = abort_req && !abort_seen_q;
    assign new_flush = flush_req && !flush_seen_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            abort_seen_q <= 1'b0;
            flush_seen_q <= 1'b0;
            abort_pending_q <= 1'b0;
            flush_pending_q <= 1'b0;
            abort_cache_seen_q <= 1'b0;
            abort_exact_seen_q <= 1'b0;
            flush_cache_seen_q <= 1'b0;
            flush_exact_seen_q <= 1'b0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
        end else begin
            abort_done <= 1'b0;
            flush_done <= 1'b0;

            if (!abort_req)
                abort_seen_q <= 1'b0;
            else if (new_abort)
                abort_seen_q <= 1'b1;
            if (!flush_req)
                flush_seen_q <= 1'b0;
            else if (new_flush)
                flush_seen_q <= 1'b1;

            if (new_abort) begin
                abort_pending_q <= 1'b1;
                abort_cache_seen_q <= 1'b0;
                abort_exact_seen_q <= 1'b0;
            end
            if (new_flush) begin
                flush_pending_q <= 1'b1;
                flush_cache_seen_q <= 1'b0;
                flush_exact_seen_q <= 1'b0;
            end

            // Requests are forwarded directly to both children. If a fresh
            // edge coincides with the old ACK join, it starts/restarts child
            // maintenance: old ACKs must not complete that newly issued work.
            if (abort_pending_q && !new_abort && cache_abort_done)
                abort_cache_seen_q <= 1'b1;
            if (abort_pending_q && !new_abort && exact_abort_done)
                abort_exact_seen_q <= 1'b1;
            if (flush_pending_q && !new_flush && cache_flush_done)
                flush_cache_seen_q <= 1'b1;
            if (flush_pending_q && !new_flush && exact_flush_done)
                flush_exact_seen_q <= 1'b1;

            if (abort_pending_q && !new_abort &&
                (abort_cache_seen_q || cache_abort_done) &&
                (abort_exact_seen_q || exact_abort_done)) begin
                abort_pending_q <= 1'b0;
                abort_cache_seen_q <= 1'b0;
                abort_exact_seen_q <= 1'b0;
                abort_done <= 1'b1;
            end
            if (flush_pending_q && !new_flush &&
                (flush_cache_seen_q || cache_flush_done) &&
                (flush_exact_seen_q || exact_flush_done)) begin
                flush_pending_q <= 1'b0;
                flush_cache_seen_q <= 1'b0;
                flush_exact_seen_q <= 1'b0;
                flush_done <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Command holding and compact shell accounting.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            stage_base_q <= 32'd0;
            row_stride_bytes_q <= 32'd0;
            cmd_hold_valid_q <= 1'b0;
            cmd_hold_base_q <= 32'd0;
            cmd_hold_stride_q <= 32'd0;
            cmd_hold_row_q <= 16'd0;
            cmd_hold_words_q <= 16'd0;
            cmd_hold_epoch_q <= '0;
            perf_refill_count <= 64'd0;
            perf_refill_word_count <= 64'd0;
            perf_cache_rsp_count <= 64'd0;
            skid_head_q <= '0;
            skid_tail_q <= '0;
            skid_count_q <= '0;
        end else begin
            if (group_start_fire) begin
                stage_base_q <= stage_base_addr;
                row_stride_bytes_q <= cache_row_stride_comb;
            end

            if (cmd_hold_fire) begin
                cmd_hold_valid_q <= 1'b1;
                // c1_cache_refill_scheduler advances base by stride per
                // logical word.  The line cache request identifies a row,
                // so fold row*row_stride into the base and use the native
                // 64-bit word stride for each issued request.
                cmd_hold_base_q <= stage_base_q +
                                   row_offset_bytes(cache_refill_req_row,
                                                    row_stride_bytes_q);
                cmd_hold_stride_q <= 32'd8;
                cmd_hold_row_q <= cache_refill_req_row;
                cmd_hold_words_q <= cache_refill_req_word_count;
                cmd_hold_epoch_q <= exact_current_epoch;
                perf_refill_count <= perf_refill_count + 1'b1;
            end
            if (exact_cmd_fire)
                cmd_hold_valid_q <= 1'b0;

            if (skid_in_fire) begin
                skid_data_mem[skid_tail_q] <= exact_refill_word_data;
                skid_error_mem[skid_tail_q] <= exact_refill_word_error;
                skid_last_mem[skid_tail_q] <= exact_refill_word_last;
                skid_row_mem[skid_tail_q] <= exact_refill_word_row;
                skid_index_mem[skid_tail_q] <= exact_refill_word_index;
                skid_epoch_mem[skid_tail_q] <= exact_refill_word_epoch;
                if (skid_tail_q == REFILL_SKID_DEPTH-1)
                    skid_tail_q <= '0;
                else
                    skid_tail_q <= skid_tail_q + 1'b1;
            end
            if (skid_out_fire) begin
                if (skid_head_q == REFILL_SKID_DEPTH-1)
                    skid_head_q <= '0;
                else
                    skid_head_q <= skid_head_q + 1'b1;
                perf_refill_word_count <= perf_refill_word_count + 1'b1;
                perf_cache_rsp_count <= perf_cache_rsp_count + 1'b1;
            end
            case ({skid_in_fire, skid_out_fire})
                2'b10: skid_count_q <= skid_count_q + 1'b1;
                2'b01: skid_count_q <= skid_count_q - 1'b1;
                default: skid_count_q <= skid_count_q;
            endcase
        end
    end

    // Preserve the historical shell's simple error outputs while exposing
    // exact-reader diagnostics separately.  A scheduler/adapter protocol
    // error is reported as a refill-data class error; the cache's own code
    // remains authoritative when it has a more specific LAST/data fault.
    assign refill_protocol_error = exact_protocol_error;
    assign refill_done = exact_refill_done;
    assign refill_done_error = exact_refill_done_error;
    assign cache_error = cache_error_core || exact_protocol_error;
    assign cache_error_code = cache_error_core ? cache_error_code_core :
                              (exact_protocol_error ? 3'd1 : 3'd0);

    assign busy = cache_busy || exact_busy || (skid_count_q != 0) ||
                  cmd_hold_valid_q ||
                  abort_pending_q || flush_pending_q;
    assign quiescent = cache_quiescent && exact_quiescent &&
                       (skid_count_q == 0) && !cmd_hold_valid_q &&
                       !abort_pending_q &&
                       !flush_pending_q;
    assign current_epoch = exact_current_epoch;
    assign drain_pending = exact_drain_pending || exact_synthetic_active;
    assign outstanding = exact_outstanding;
    assign max_outstanding_seen = exact_max_outstanding;
    assign cmd_occupancy = exact_cmd_occupancy;
    assign perf_cmd_accept_count = exact_perf_cmd_accept_count;
    assign perf_req_count = exact_perf_req_count;
    assign perf_rsp_count = exact_perf_rsp_count;
    assign perf_word_count = exact_perf_word_count;
    assign perf_stale_drop_count = exact_perf_stale_drop_count;
    assign perf_orphan_rsp_count = exact_perf_orphan_rsp_count;
    assign perf_scheduler_error_count = exact_perf_error_count;

endmodule
