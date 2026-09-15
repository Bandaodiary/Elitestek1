`timescale 1ns/1ps

// Board-independent read-only cache-refill scheduler.
//
// This block is an intentionally separate seam between a line-cache refill
// command source and the existing logical 64-bit read burst client.  It does
// not own an AXI port; leaf_req_* / leaf_rsp_* may be connected to
// c1_tensor_mem_axi128_read_burst_client or to a compact simulation BFM.
//
// Protocol summary
// ----------------
// * A command describes one contiguous row (base, byte stride, row, word
//   count and explicit epoch).  Commands are queued, but only one row is
//   active.  This preserves complete-row cache commit semantics.
// * A registered one-entry request pending slot holds a leaf request until
//   handshake.  This is important at an epoch fence: an abort/flush edge may
//   not withdraw a stalled ready/valid request.
// * At most MAX_OUTSTANDING requests are accepted by the leaf.  Metadata for
//   each accepted request is retained in an ID-less in-order FIFO, carrying
//   row/index/last and epoch sideband to the word stream.
// * After the final request (or a maintenance fence), leaf_req_flush is a
//   one-cycle close pulse once leaf_req_occupancy reaches zero.  The caller
//   must drive leaf_req_occupancy from the leaf request FIFO and
//   leaf_quiescent when its builder/descriptors/response path are drained.
// * abort_req and flush_req are edge-qualified.  The first newly observed
//   edge increments the epoch (with saturation protection), stops new command
//   admission, drops queued/active work, and drains accepted old responses.
//   Old-epoch responses are consumed but never exposed as words.  A second
//   distinct edge during the same drain is folded into the existing fence and
//   adds its done pulse without another epoch transition; held-high requests
//   do not repeat.
// * If a response arrives with no metadata, it is consumed as an orphan and
//   counted as a protocol error.  This prevents an ID-less leaf fault from
//   deadlocking the maintenance fence while making the fault observable.
// * If a current-epoch word is already presented while word_ready is low,
//   an abort/flush edge is deferred until that word handshakes.  This keeps
//   the word stream ready/valid stable across a fence request; the edge is
//   still remembered and advances the epoch exactly once after the drain.
// * With EMIT_DRAIN_WORDS=1, accepted stale metadata is exposed on
//   drain_word_* and is retired only on drain_word_ready.  The stream cannot
//   synthesize words for a declared command that never reached the leaf; a
//   line-cache consumer requiring a full declared count still needs a
//   cancellation/completion adapter for that unissued suffix.
//
// Used by the optional scalar-burst AND column-cache paths of portable SoC.
// ALLOW_REQ_HANDOFF and MAX_OUTSTANDING apply to both paths; the column
// frontend does not replace this ordered logical-request/epoch owner.
(* use_dsp = "no" *)
module c1_cache_refill_scheduler #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 64,
    parameter integer EPOCH_W = 8,
    parameter integer CMD_FIFO_DEPTH = 4,
    parameter integer MAX_OUTSTANDING = 4,
    // When enabled, canceled/stale responses are exposed on the separate
    // drain stream instead of being silently consumed.  The default keeps
    // the legacy current-word-only interface unchanged.
    parameter integer EMIT_DRAIN_WORDS = 0,
    // Replace a just-accepted pending request with the next word. Keep one
    // credit reserved for that new registered request; do not borrow credit
    // from a same-cycle response or bypass the VALID/payload register.
    parameter bit ALLOW_REQ_HANDOFF = 1'b0,
    // Exact-count consumers may already own a row declaration when epoch
    // saturation occurs. Accept/reject such commands with an error terminal
    // token, without issuing any leaf request or wrapping the epoch. Legacy
    // standalone users retain the historical admission-stop policy by default.
    parameter bit REJECT_ON_EPOCH_EXHAUSTION = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Refill command FIFO input.  stride_bytes is normally 8 for C8 words.
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [ADDR_W-1:0]            cmd_base_addr,
    input  logic [ADDR_W-1:0]            cmd_stride_bytes,
    input  logic [15:0]                  cmd_row,
    input  logic [15:0]                  cmd_word_count,
    input  logic [EPOCH_W-1:0]           cmd_epoch,

    // Edge-qualified maintenance controls and the current scheduler epoch.
    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,
    output logic [EPOCH_W-1:0]            current_epoch,

    // Logical leaf request stream (connect to read_burst_client req_*).
    output logic                         leaf_req_valid,
    input  logic                         leaf_req_ready,
    output logic [ADDR_W-1:0]            leaf_req_addr,
    output logic [EPOCH_W-1:0]           leaf_req_epoch,
    output logic                         leaf_req_flush,
    // Occupancy is the logical request FIFO count inside the leaf.  The
    // scheduler waits for zero before pulsing leaf_req_flush.
    input  logic [7:0]                   leaf_req_occupancy,
    // True only when the leaf has no builder, issued descriptor, response or
    // internal request state belonging to this scheduler.
    input  logic                         leaf_quiescent,

    // Logical leaf response stream (connect to read_burst_client rsp_*).
    input  logic                         leaf_rsp_valid,
    output logic                         leaf_rsp_ready,
    input  logic [DATA_W-1:0]            leaf_rsp_data,
    input  logic                         leaf_rsp_error,

    // Completed refill words.  word_epoch remains a diagnostic sideband;
    // word_valid is suppressed whenever it is stale.
    output logic                         word_valid,
    input  logic                         word_ready,
    output logic [DATA_W-1:0]            word_data,
    output logic                         word_error,
    output logic                         word_last,
    output logic [15:0]                  word_row,
    output logic [15:0]                  word_index,
    output logic [EPOCH_W-1:0]           word_epoch,

    // Optional canceled-refill drain stream.  This stream is mutually
    // exclusive with word_valid.  It is intended for a consumer (for
    // example a line-cache refill sink) which must receive every accepted
    // word even after an epoch fence.  A drain word carries error=1 to mark
    // that it is not part of the current epoch's committed output.
    output logic                         drain_word_valid,
    input  logic                         drain_word_ready,
    output logic [DATA_W-1:0]            drain_word_data,
    output logic                         drain_word_error,
    output logic                         drain_word_last,
    output logic [15:0]                  drain_word_row,
    output logic [15:0]                  drain_word_index,
    output logic [EPOCH_W-1:0]           drain_word_epoch,

    // One-cycle completion pulse for the active command.  A zero-length or
    // epoch-mismatched command is completed locally with cmd_done_error=1.
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
    output logic [63:0]                  perf_error_count
);

    localparam integer CMD_PTR_W = (CMD_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(CMD_FIFO_DEPTH);
    localparam integer CMD_CNT_W = (CMD_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(CMD_FIFO_DEPTH + 1);
    localparam integer META_PTR_W = (MAX_OUTSTANDING <= 1) ? 1 :
                                    $clog2(MAX_OUTSTANDING);
    localparam integer META_CNT_W = (MAX_OUTSTANDING <= 1) ? 1 :
                                    $clog2(MAX_OUTSTANDING + 1);

    initial begin
        if (ADDR_W < 8)
            $fatal(1, "ADDR_W must be at least eight");
        if (DATA_W < 1)
            $fatal(1, "DATA_W must be positive");
        if (EPOCH_W < 1)
            $fatal(1, "EPOCH_W must be positive");
        if (CMD_FIFO_DEPTH < 2)
            $fatal(1, "CMD_FIFO_DEPTH must be at least two");
        if (CMD_FIFO_DEPTH > 255)
            $fatal(1, "CMD_FIFO_DEPTH must be <=255");
        if (MAX_OUTSTANDING < 1)
            $fatal(1, "MAX_OUTSTANDING must be positive");
        if (MAX_OUTSTANDING > 255)
            $fatal(1, "MAX_OUTSTANDING must be <=255");
        if ((EMIT_DRAIN_WORDS != 0) && (EMIT_DRAIN_WORDS != 1))
            $fatal(1, "EMIT_DRAIN_WORDS must be 0 or 1");
    end

    // ------------------------------------------------------------------
    // Command FIFO.
    // ------------------------------------------------------------------
    logic [ADDR_W-1:0]  cmd_base_mem [0:CMD_FIFO_DEPTH-1];
    logic [ADDR_W-1:0]  cmd_stride_mem [0:CMD_FIFO_DEPTH-1];
    logic [15:0]        cmd_row_mem [0:CMD_FIFO_DEPTH-1];
    logic [15:0]        cmd_words_mem [0:CMD_FIFO_DEPTH-1];
    logic [EPOCH_W-1:0] cmd_epoch_mem [0:CMD_FIFO_DEPTH-1];
    logic [CMD_PTR_W-1:0] cmd_head_q, cmd_tail_q;
    logic [CMD_CNT_W-1:0] cmd_count_q;
    logic cmd_push, cmd_pop;

    function automatic logic [CMD_PTR_W-1:0] cmd_ptr_inc(
        input logic [CMD_PTR_W-1:0] ptr
    );
        begin
            if (ptr == CMD_FIFO_DEPTH-1)
                cmd_ptr_inc = '0;
            else
                cmd_ptr_inc = ptr + 1'b1;
        end
    endfunction

    // ------------------------------------------------------------------
    // Active command and registered pending request.
    // ------------------------------------------------------------------
    logic active_valid_q;
    logic issue_done_q;
    logic complete_pending_q;
    logic [ADDR_W-1:0] active_base_q, active_stride_q;
    logic [15:0] active_row_q, active_words_q, issue_index_q;
    logic [EPOCH_W-1:0] active_epoch_q;
    logic active_error_q;

    // The pending slot is the ready/valid hold point.  It remains valid over
    // a maintenance edge if the leaf is stalled, and therefore prevents an
    // epoch fence from withdrawing an already-presented request.
    logic req_pending_q;
    logic [ADDR_W-1:0] req_pending_addr_q;
    logic [EPOCH_W-1:0] req_pending_epoch_q;
    logic [15:0] req_pending_row_q, req_pending_index_q;
    logic req_pending_last_q;

    // ------------------------------------------------------------------
    // Accepted-request metadata/credit FIFO.
    // ------------------------------------------------------------------
    logic [EPOCH_W-1:0] meta_epoch_mem [0:MAX_OUTSTANDING-1];
    logic [15:0]        meta_row_mem [0:MAX_OUTSTANDING-1];
    logic [15:0]        meta_index_mem [0:MAX_OUTSTANDING-1];
    logic               meta_last_mem [0:MAX_OUTSTANDING-1];
    logic [META_PTR_W-1:0] meta_head_q, meta_tail_q;
    logic [META_CNT_W-1:0] meta_count_q;

    function automatic logic [META_PTR_W-1:0] meta_ptr_inc(
        input logic [META_PTR_W-1:0] ptr
    );
        begin
            if (ptr == MAX_OUTSTANDING-1)
                meta_ptr_inc = '0;
            else
                meta_ptr_inc = ptr + 1'b1;
        end
    endfunction

    function automatic logic [ADDR_W-1:0] stride_product(
        input logic [ADDR_W-1:0] stride,
        input logic [15:0]       index
    );
        logic [ADDR_W-1:0] acc;
        integer k;
        begin
            acc = '0;
            for (k = 0; k < 16; k = k + 1)
                if (index[k])
                    acc = acc + (stride << k);
            stride_product = acc;
        end
    endfunction

    // ------------------------------------------------------------------
    // Control/event wires.  All declarations precede assignments to keep
    // Vivado's front end happy for small parameter values.
    // ------------------------------------------------------------------
    logic [EPOCH_W-1:0] epoch_q;
    logic epoch_exhausted_q;
    logic abort_seen_q, flush_seen_q;
    // A maintenance edge which arrives while a current-epoch word is
    // presented cannot be acted on until that word retires.  The deferred
    // event bits carry the requested done pulses; deferred_start_q is set
    // after the handshake so the *next* response is fenced/drained rather
    // than accidentally exposed as another current word.
    logic deferred_abort_q, deferred_flush_q;
    logic deferred_start_q;
    logic maintenance_q;
    logic abort_wait_q, flush_wait_q;
    logic flush_pending_q;
    logic new_abort, new_flush, maintenance_raw_edge, maintenance_edge;
    logic maintenance_start, maintenance_extend;
    logic command_start_event;
    logic command_reject_zero, command_reject_epoch, command_reject_event;
    logic launch_event;
    logic leaf_flush_fire;
    logic req_fire, rsp_fire;
    logic meta_push, meta_pop;
    logic stale_head, stale_rsp, orphan_rsp, normal_rsp;
    logic word_candidate_valid, word_stall;
    logic drain_candidate_valid, drain_stall, drain_fire;
    logic final_response_event, command_complete_event;
    logic maintenance_complete;
    logic [3:0] perf_error_inc_count;

    assign current_epoch = epoch_q;
    assign new_abort = abort_req && !abort_seen_q;
    assign new_flush = flush_req && !flush_seen_q;
    assign maintenance_raw_edge = new_abort || new_flush;
    // A current-epoch response which is already visible to the word sink is
    // allowed to complete before a fence starts.  This is the same drain
    // principle used by the window-cache seam and avoids a VALID withdrawal
    // when word_ready is low.
    assign word_candidate_valid = !rst && !maintenance_q &&
                                  (leaf_rsp_valid && (meta_count_q != 0) &&
                                   !stale_head);
    assign word_stall = word_candidate_valid && !word_ready;
    // In drain mode a stale/maintenance response is presented on a separate
    // stream.  Keeping the response VALID dependent only on the head metadata
    // and leaf VALID (not on READY) gives the drain consumer the usual
    // ready/valid hold contract across additional maintenance edges.
    assign drain_candidate_valid = (EMIT_DRAIN_WORDS != 0) && !rst &&
                                   leaf_rsp_valid && (meta_count_q != 0) &&
                                   (stale_head || maintenance_q ||
                                    maintenance_start || maintenance_extend);
    assign drain_stall = drain_candidate_valid && !drain_word_ready;
    // Held-high requests remain one event.  A raw edge during a visible word
    // is remembered in deferred_*; once that word is ready/accepted,
    // deferred_start_q launches the fence on the following cycle.  The
    // explicit start bit is important when the leaf presents a second
    // response immediately after the first handshake.
    assign maintenance_edge = maintenance_start || maintenance_extend;
    // Only the first edge starts a fence and advances the epoch.  A distinct
    // edge observed while that fence is draining is folded into the existing
    // wait flags (both done pulses are still reported), but cannot create a
    // second epoch transition in the same drain window.
    assign maintenance_start = !maintenance_q &&
                               (deferred_start_q ||
                                (!word_candidate_valid &&
                                 (maintenance_raw_edge ||
                                  deferred_abort_q || deferred_flush_q)));
    assign maintenance_extend = maintenance_q && maintenance_raw_edge;

    assign command_start_event = !rst && !maintenance_q &&
                                 !maintenance_start &&
                                 !maintenance_raw_edge &&
                                 !deferred_start_q &&
                                 !deferred_abort_q && !deferred_flush_q &&
                                 (!epoch_exhausted_q || REJECT_ON_EPOCH_EXHAUSTION) &&
                                 !active_valid_q && !complete_pending_q &&
                                 leaf_quiescent && (cmd_count_q != 0);
    assign cmd_pop = command_start_event;
    // Permit full-FIFO pop/push in one cycle.  cmd_pop is independent of
    // cmd_ready, so this expression is acyclic.
    assign cmd_ready = !rst && !maintenance_q && !maintenance_start &&
                       !maintenance_raw_edge &&
                       !deferred_start_q &&
                       !deferred_abort_q && !deferred_flush_q &&
                       (!epoch_exhausted_q || REJECT_ON_EPOCH_EXHAUSTION) &&
                       ((cmd_count_q < CMD_FIFO_DEPTH) || cmd_pop);
    assign cmd_push = cmd_valid && cmd_ready;
    assign command_reject_zero = command_start_event &&
                                 (cmd_words_mem[cmd_head_q] == 0);
    assign command_reject_epoch = command_start_event &&
                                  (epoch_exhausted_q || cmd_epoch_mem[cmd_head_q] != epoch_q);
    assign command_reject_event = command_reject_zero || command_reject_epoch;

    // Launch a request into the registered pending slot only when credit is
    // available. Default behavior retains a one-cycle bubble. Optional
    // handoff reserves credit using the pre-edge count only, so it does not
    // couple this decision to the response consumer's READY path.
    wire handoff_event = ALLOW_REQ_HANDOFF && req_fire && !req_pending_last_q &&
                         (meta_count_q < MAX_OUTSTANDING-1);
    wire [15:0] launch_index = issue_index_q + (handoff_event ? 16'd1 : 16'd0);
    assign launch_event = !rst && !maintenance_q && !maintenance_start &&
                          !maintenance_raw_edge &&
                          !deferred_start_q &&
                          !deferred_abort_q && !deferred_flush_q &&
                          active_valid_q && !issue_done_q &&
                          ((!req_pending_q && (meta_count_q < MAX_OUTSTANDING)) ||
                           handoff_event);

    assign leaf_req_valid = !rst && req_pending_q;
    assign leaf_req_addr = req_pending_addr_q;
    assign leaf_req_epoch = req_pending_epoch_q;
    assign req_fire = leaf_req_valid && leaf_req_ready;

    // The close pulse is generated only after every scheduler request has
    // entered the leaf FIFO.  It is also generated after a maintenance edge,
    // so a builder cannot merge stale work with a future epoch.
    assign leaf_flush_fire = flush_pending_q && !req_pending_q &&
                             (leaf_req_occupancy == 0);
    assign leaf_req_flush = !rst && leaf_flush_fire;

    always_comb begin
        stale_head = (meta_count_q != 0) &&
                     (meta_epoch_mem[meta_head_q] != epoch_q);

        word_valid = 1'b0;
        word_data = '0;
        word_error = 1'b0;
        word_last = 1'b0;
        word_row = 16'd0;
        word_index = 16'd0;
        word_epoch = epoch_q;

        drain_word_valid = 1'b0;
        drain_word_data = '0;
        drain_word_error = 1'b0;
        drain_word_last = 1'b0;
        drain_word_row = 16'd0;
        drain_word_index = 16'd0;
        drain_word_epoch = epoch_q;
        if (!rst && !maintenance_q && !maintenance_start &&
            leaf_rsp_valid && (meta_count_q != 0) && !stale_head) begin
            word_valid = 1'b1;
            word_data = leaf_rsp_data;
            word_error = leaf_rsp_error;
            word_last = meta_last_mem[meta_head_q];
            word_row = meta_row_mem[meta_head_q];
            word_index = meta_index_mem[meta_head_q];
            word_epoch = meta_epoch_mem[meta_head_q];
        end
        if (drain_candidate_valid) begin
            drain_word_valid = 1'b1;
            drain_word_data = leaf_rsp_data;
            // A drain word is explicitly canceled/stale.  Preserve a leaf
            // error if present, but never present a clean current word here.
            drain_word_error = 1'b1 | leaf_rsp_error;
            drain_word_last = meta_last_mem[meta_head_q];
            drain_word_row = meta_row_mem[meta_head_q];
            drain_word_index = meta_index_mem[meta_head_q];
            drain_word_epoch = meta_epoch_mem[meta_head_q];
        end

        // Ready is high for orphan/stale responses and throughout a fence;
        // current-epoch responses follow the downstream word sink.  In drain
        // mode, stale responses may advance only when the drain sink accepts
        // the corresponding word.
        leaf_rsp_ready = 1'b0;
        if (!rst) begin
            if (meta_count_q == 0)
                leaf_rsp_ready = 1'b1;
            else if (maintenance_q || maintenance_edge || stale_head)
                if (EMIT_DRAIN_WORDS != 0)
                    leaf_rsp_ready = drain_word_ready;
                else
                    leaf_rsp_ready = 1'b1;
            else
                leaf_rsp_ready = word_ready;
        end
    end
    assign rsp_fire = leaf_rsp_valid && leaf_rsp_ready;
    assign drain_fire = drain_word_valid && drain_word_ready;
    assign orphan_rsp = rsp_fire && (meta_count_q == 0);
    assign stale_rsp = rsp_fire && (meta_count_q != 0) &&
                       (stale_head || maintenance_q || maintenance_edge);
    assign normal_rsp = rsp_fire && (meta_count_q != 0) && !stale_rsp;
    assign meta_push = req_fire;
    assign meta_pop = rsp_fire && (meta_count_q != 0);

    // A final response first arms complete_pending_q.  Completion is emitted
    // only after the leaf itself reports quiescent and the close pulse has
    // retired, preventing a new row from merging with the old builder.
    assign final_response_event = normal_rsp && active_valid_q &&
                                  issue_done_q && (meta_count_q == 1);
    assign command_complete_event = complete_pending_q && active_valid_q &&
                                    (meta_count_q == 0) && leaf_quiescent &&
                                    !req_pending_q && !flush_pending_q &&
                                    !leaf_rsp_valid && !maintenance_edge;

    assign maintenance_complete = maintenance_q && (meta_count_q == 0) &&
                                  leaf_quiescent && !req_pending_q &&
                                  !flush_pending_q && !leaf_rsp_valid &&
                                  !maintenance_edge;

    // Count all error causes once per cycle.  Keeping this as one increment
    // avoids multiple nonblocking assignments overwriting one another when,
    // for example, a stale leaf error and an orphan fault are observed on the
    // same clock edge.
    always_comb begin
        perf_error_inc_count = 4'd0;
        if (maintenance_start && (epoch_q == {EPOCH_W{1'b1}}))
            perf_error_inc_count = perf_error_inc_count + 1'b1;
        if (command_reject_event)
            perf_error_inc_count = perf_error_inc_count + 1'b1;
        if (orphan_rsp)
            perf_error_inc_count = perf_error_inc_count + 1'b1;
        if (stale_rsp && leaf_rsp_error)
            perf_error_inc_count = perf_error_inc_count + 1'b1;
        if (normal_rsp && leaf_rsp_error)
            perf_error_inc_count = perf_error_inc_count + 1'b1;
    end

    assign busy = active_valid_q || complete_pending_q ||
                  (cmd_count_q != 0) || (meta_count_q != 0) ||
                  req_pending_q || flush_pending_q || maintenance_q ||
                  deferred_abort_q || deferred_flush_q || deferred_start_q ||
                  !leaf_quiescent;
    assign quiescent = !busy;
    assign drain_pending = maintenance_q &&
                           ((meta_count_q != 0) || req_pending_q ||
                           flush_pending_q || !leaf_quiescent ||
                           leaf_rsp_valid) ||
                           deferred_abort_q || deferred_flush_q ||
                           deferred_start_q;
    assign outstanding = meta_count_q;
    assign cmd_occupancy = cmd_count_q;

    // ------------------------------------------------------------------
    // State and storage updates.
    // ------------------------------------------------------------------
    integer reset_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            cmd_head_q <= '0;
            cmd_tail_q <= '0;
            cmd_count_q <= '0;
            active_valid_q <= 1'b0;
            issue_done_q <= 1'b0;
            complete_pending_q <= 1'b0;
            active_base_q <= '0;
            active_stride_q <= '0;
            active_row_q <= '0;
            active_words_q <= '0;
            issue_index_q <= '0;
            active_epoch_q <= '0;
            active_error_q <= 1'b0;
            req_pending_q <= 1'b0;
            req_pending_addr_q <= '0;
            req_pending_epoch_q <= '0;
            req_pending_row_q <= '0;
            req_pending_index_q <= '0;
            req_pending_last_q <= 1'b0;
            meta_head_q <= '0;
            meta_tail_q <= '0;
            meta_count_q <= '0;
            epoch_q <= '0;
            epoch_exhausted_q <= 1'b0;
            abort_seen_q <= 1'b0;
            flush_seen_q <= 1'b0;
            deferred_abort_q <= 1'b0;
            deferred_flush_q <= 1'b0;
            deferred_start_q <= 1'b0;
            maintenance_q <= 1'b0;
            abort_wait_q <= 1'b0;
            flush_wait_q <= 1'b0;
            flush_pending_q <= 1'b0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            cmd_done <= 1'b0;
            cmd_done_error <= 1'b0;
            cmd_done_row <= '0;
            cmd_done_epoch <= '0;
            max_outstanding_seen <= '0;
            perf_cmd_accept_count <= 64'd0;
            perf_req_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_word_count <= 64'd0;
            perf_stale_drop_count <= 64'd0;
            perf_orphan_rsp_count <= 64'd0;
            perf_error_count <= 64'd0;
            for (reset_i = 0; reset_i < CMD_FIFO_DEPTH; reset_i = reset_i + 1) begin
                cmd_base_mem[reset_i] <= '0;
                cmd_stride_mem[reset_i] <= '0;
                cmd_row_mem[reset_i] <= '0;
                cmd_words_mem[reset_i] <= '0;
                cmd_epoch_mem[reset_i] <= '0;
            end
            for (reset_i = 0; reset_i < MAX_OUTSTANDING; reset_i = reset_i + 1) begin
                meta_epoch_mem[reset_i] <= '0;
                meta_row_mem[reset_i] <= '0;
                meta_index_mem[reset_i] <= '0;
                meta_last_mem[reset_i] <= 1'b0;
            end
        end else begin
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            cmd_done <= 1'b0;
            cmd_done_error <= 1'b0;

            // Edge qualification; a low level rearms the detector.
            if (!abort_req)
                abort_seen_q <= 1'b0;
            else if (new_abort)
                abort_seen_q <= 1'b1;
            if (!flush_req)
                flush_seen_q <= 1'b0;
            else if (new_flush)
                flush_seen_q <= 1'b1;

            // Defer a maintenance edge whenever a current-epoch word is
            // visible.  This includes the word_ready=1 case: the response
            // handshake and the fence are then ordered on adjacent cycles,
            // rather than losing an edge because the edge detector is
            // re-armed before maintenance can start.  The edge detectors
            // above still mark the input level as seen; deferred_* preserve
            // the event until the visible word retires.  Once a visible word
            // is accepted, deferred_start_q is asserted so a following
            // response cannot slip through as another current word.
            if (!maintenance_q && word_candidate_valid &&
                (maintenance_raw_edge || deferred_abort_q || deferred_flush_q)) begin
                if (new_abort)
                    deferred_abort_q <= 1'b1;
                if (new_flush)
                    deferred_flush_q <= 1'b1;
                if (word_ready)
                    deferred_start_q <= 1'b1;
            end

            // Command FIFO writes and the full-FIFO simultaneous pop/push
            // case.  Maintenance has priority below and clears the queue.
            if (cmd_push) begin
                cmd_base_mem[cmd_tail_q] <= cmd_base_addr;
                cmd_stride_mem[cmd_tail_q] <= cmd_stride_bytes;
                cmd_row_mem[cmd_tail_q] <= cmd_row;
                cmd_words_mem[cmd_tail_q] <= cmd_word_count;
                cmd_epoch_mem[cmd_tail_q] <= cmd_epoch;
                cmd_tail_q <= cmd_ptr_inc(cmd_tail_q);
                perf_cmd_accept_count <= perf_cmd_accept_count + 1'b1;
            end
            if (cmd_pop)
                cmd_head_q <= cmd_ptr_inc(cmd_head_q);
            case ({cmd_push, cmd_pop})
                2'b10: cmd_count_q <= cmd_count_q + 1'b1;
                2'b01: cmd_count_q <= cmd_count_q - 1'b1;
                default: cmd_count_q <= cmd_count_q;
            endcase

            // A maintenance edge is a hard admission fence.  Keep a
            // currently pending request until its handshake; all other
            // queued/active work is discarded, and a close pulse is required
            // before the leaf may be considered quiescent in the new epoch.
            if (maintenance_start) begin
                if (epoch_q == {EPOCH_W{1'b1}}) begin
                    epoch_exhausted_q <= 1'b1;
                end else begin
                    epoch_q <= epoch_q + 1'b1;
                end
                maintenance_q <= 1'b1;
                abort_wait_q <= abort_wait_q || new_abort || deferred_abort_q;
                flush_wait_q <= flush_wait_q || new_flush || deferred_flush_q;
                deferred_abort_q <= 1'b0;
                deferred_flush_q <= 1'b0;
                deferred_start_q <= 1'b0;
                cmd_head_q <= '0;
                cmd_tail_q <= '0;
                cmd_count_q <= '0;
                active_valid_q <= 1'b0;
                issue_done_q <= 1'b0;
                complete_pending_q <= 1'b0;
                active_error_q <= 1'b0;
                // req_pending_q is intentionally not assigned here.
                flush_pending_q <= 1'b1;
            end else if (maintenance_extend) begin
                // Fold a second edge into the active fence without another
                // epoch transition.  This keeps the fence epoch atomic while
                // still acknowledging both maintenance requests.
                abort_wait_q <= abort_wait_q || new_abort;
                flush_wait_q <= flush_wait_q || new_flush;
            end else if (maintenance_complete) begin
                maintenance_q <= 1'b0;
                if (abort_wait_q) begin
                    abort_done <= 1'b1;
                    abort_wait_q <= 1'b0;
                end
                if (flush_wait_q) begin
                    flush_done <= 1'b1;
                    flush_wait_q <= 1'b0;
                end
            end

            // A flush close pulse is a one-cycle event.  If a maintenance
            // edge happens to coincide with the pulse, the already-issued
            // close still satisfies the new fence; do not re-arm it and
            // accidentally present duplicate close pulses on the next cycle.
            if (leaf_flush_fire)
                flush_pending_q <= 1'b0;

            // Activate one command after a FIFO pop.  Invalid commands are
            // completed locally and cannot reach the leaf.
            if (command_start_event && !maintenance_start) begin
                if (command_reject_event) begin
                    cmd_done <= 1'b1;
                    cmd_done_error <= 1'b1;
                    cmd_done_row <= cmd_row_mem[cmd_head_q];
                    cmd_done_epoch <= cmd_epoch_mem[cmd_head_q];
                end else begin
                    active_valid_q <= 1'b1;
                    issue_done_q <= 1'b0;
                    complete_pending_q <= 1'b0;
                    active_base_q <= cmd_base_mem[cmd_head_q];
                    active_stride_q <= cmd_stride_mem[cmd_head_q];
                    active_row_q <= cmd_row_mem[cmd_head_q];
                    active_words_q <= cmd_words_mem[cmd_head_q];
                    issue_index_q <= 16'd0;
                    active_epoch_q <= cmd_epoch_mem[cmd_head_q];
                    active_error_q <= 1'b0;
                end
            end

            // Fill the registered pending request slot.  It is not filled
            // while a fence is active, so no new epoch request can be born
            // behind stale leaf traffic.
            if (launch_event) begin
                req_pending_q <= 1'b1;
                req_pending_addr_q <= handoff_event ?
                    req_pending_addr_q + active_stride_q :
                    active_base_q + stride_product(active_stride_q,launch_index);
                req_pending_epoch_q <= active_epoch_q;
                req_pending_row_q <= active_row_q;
                req_pending_index_q <= launch_index;
                req_pending_last_q <=
                    (launch_index == active_words_q - 1'b1);
            end

            if (req_fire) begin
                req_pending_q <= launch_event;
                meta_epoch_mem[meta_tail_q] <= req_pending_epoch_q;
                meta_row_mem[meta_tail_q] <= req_pending_row_q;
                meta_index_mem[meta_tail_q] <= req_pending_index_q;
                meta_last_mem[meta_tail_q] <= req_pending_last_q;
                meta_tail_q <= meta_ptr_inc(meta_tail_q);
                perf_req_count <= perf_req_count + 1'b1;
                if (req_pending_last_q) begin
                    issue_done_q <= 1'b1;
                    flush_pending_q <= 1'b1;
                end else begin
                    issue_index_q <= issue_index_q + 1'b1;
                end
            end

            if (rsp_fire) begin
                perf_rsp_count <= perf_rsp_count + 1'b1;
                if (orphan_rsp) begin
                    perf_orphan_rsp_count <= perf_orphan_rsp_count + 1'b1;
                end else begin
                    meta_head_q <= meta_ptr_inc(meta_head_q);
                    if (stale_rsp) begin
                        perf_stale_drop_count <= perf_stale_drop_count + 1'b1;
                    end else begin
                        perf_word_count <= perf_word_count + 1'b1;
                        if (leaf_rsp_error) begin
                            active_error_q <= 1'b1;
                        end
                        if (final_response_event)
                            complete_pending_q <= 1'b1;
                    end
                end

                if (final_response_event) begin
                    // Keep active_valid until command_complete_event so the
                    // completion metadata remains stable while leaf drains.
                    issue_done_q <= 1'b1;
                end
            end

            // Complete only after the response FIFO and leaf internals are
            // empty.  This is deliberately separate from final_response_event
            // because leaf_quiescent is generally registered one cycle later.
            if (command_complete_event) begin
                cmd_done <= 1'b1;
                cmd_done_error <= active_error_q;
                cmd_done_row <= active_row_q;
                cmd_done_epoch <= active_epoch_q;
                active_valid_q <= 1'b0;
                issue_done_q <= 1'b0;
                complete_pending_q <= 1'b0;
                active_error_q <= 1'b0;
            end

            // Metadata credit count.  An orphan response has no metadata to
            // pop.  Simultaneous request/response keeps occupancy unchanged.
            case ({meta_push, meta_pop})
                2'b10: meta_count_q <= meta_count_q + 1'b1;
                2'b01: meta_count_q <= meta_count_q - 1'b1;
                default: meta_count_q <= meta_count_q;
            endcase
            if (req_fire && ((meta_count_q + 1'b1) > max_outstanding_seen))
                max_outstanding_seen <= meta_count_q + 1'b1;
            if (perf_error_inc_count != 0)
                perf_error_count <= perf_error_count + perf_error_inc_count;
        end
    end

`ifndef SYNTHESIS
    logic leaf_req_stalled_q;
    logic [ADDR_W+EPOCH_W+16+16+1-1:0] leaf_req_payload_q;
    logic leaf_rsp_stalled_q;
    logic [DATA_W-1:0] leaf_rsp_payload_q;
    logic word_stalled_q;
    logic [DATA_W+EPOCH_W+16+16+1+1-1:0] word_payload_q;
    logic drain_word_stalled_q;
    logic [DATA_W+EPOCH_W+16+16+1+1-1:0] drain_word_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            leaf_req_stalled_q <= 1'b0;
            leaf_rsp_stalled_q <= 1'b0;
            word_stalled_q <= 1'b0;
            drain_word_stalled_q <= 1'b0;
        end else begin
            if (leaf_req_stalled_q &&
                (!leaf_req_valid ||
                 ({leaf_req_addr, leaf_req_epoch,
                   req_pending_row_q, req_pending_index_q,
                   req_pending_last_q} != leaf_req_payload_q)))
                $fatal(1, "cache refill scheduler changed stalled leaf request");
            if (leaf_rsp_stalled_q &&
                (!leaf_rsp_valid || (leaf_rsp_data != leaf_rsp_payload_q)))
                $fatal(1, "cache refill scheduler withdrew stalled leaf response");
            if (word_stalled_q &&
                (!word_valid ||
                 ({word_data, word_error, word_last, word_row,
                   word_index, word_epoch} != word_payload_q)))
                $fatal(1, "cache refill scheduler changed/withdrew stalled word");
            if (drain_word_stalled_q &&
                (!drain_word_valid ||
                 ({drain_word_data, drain_word_error, drain_word_last,
                   drain_word_row, drain_word_index, drain_word_epoch} !=
                  drain_word_payload_q)))
                $fatal(1, "cache refill scheduler changed/withdrew stalled drain word");
            if (word_valid && drain_word_valid)
                $fatal(1, "normal and drain word streams are not mutually exclusive");
            if ((EMIT_DRAIN_WORDS == 0) && drain_word_valid)
                $fatal(1, "drain word appeared while EMIT_DRAIN_WORDS=0");
            if (drain_word_valid && (rsp_fire != drain_fire))
                $fatal(1, "drain response handshake mismatch");
            leaf_req_stalled_q <= leaf_req_valid && !leaf_req_ready;
            leaf_req_payload_q <= {leaf_req_addr, leaf_req_epoch,
                                   req_pending_row_q, req_pending_index_q,
                                   req_pending_last_q};
            leaf_rsp_stalled_q <= leaf_rsp_valid && !leaf_rsp_ready;
            leaf_rsp_payload_q <= leaf_rsp_data;
            word_stalled_q <= word_valid && !word_ready;
            word_payload_q <= {word_data, word_error, word_last, word_row,
                               word_index, word_epoch};
            drain_word_stalled_q <= drain_word_valid && !drain_word_ready;
            drain_word_payload_q <= {drain_word_data, drain_word_error,
                                     drain_word_last, drain_word_row,
                                     drain_word_index, drain_word_epoch};
            if (word_valid && (word_epoch != current_epoch))
                $fatal(1, "stale response leaked onto refill word stream");
            if (meta_count_q > MAX_OUTSTANDING)
                $fatal(1, "cache refill scheduler credit overflow");
            if (meta_count_q + (req_pending_q ? 1 : 0) > MAX_OUTSTANDING)
                $fatal(1, "cache refill pending request over-reserved credit");
            if (leaf_req_flush && req_pending_q)
                $fatal(1, "refill close pulse overlapped a pending request");
            // The ID-less metadata FIFO is updated at the sampling edge, so
            // a fall-through leaf response in the same cycle as the first
            // request would otherwise be classified as an orphan.  The
            // shipped AXI128 reader is registered and satisfies this contract;
            // reject an incompatible leaf early in simulation.
            if (req_fire && leaf_rsp_valid && (meta_count_q == 0))
                $fatal(1, "leaf response arrived in the same cycle as first request");
        end
    end
`endif

endmodule
