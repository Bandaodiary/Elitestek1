`timescale 1ns/1ps

// Board-independent read-only tensor traffic prototype.
//
// The legacy tensor seam accepts one 64-bit request and waits for its response
// before producing another request.  This block is intentionally a separate
// experiment: it accepts a small FIFO of 64-bit, 8-byte-aligned reads, groups
// adjacent 16-byte locations into AXI INCR bursts, and permits several bursts
// to be outstanding.  The AXI port is ID-less; consequently responses are
// consumed in the same order as the AR transactions.  A descriptor ring keeps
// the lane mask and request order for every beat, while a response FIFO hides
// AXI/RREADY stalls from the local requester.
//
// A burst is closed when it reaches BURST_BEATS, encounters a non-contiguous
// address (or a 4-KiB boundary), receives req_flush, or has waited
// BUILD_TIMEOUT_CYCLES clocks for another request.  At most two logical reads
// (the lower and upper 64-bit halves) are retained for one 128-bit beat.  A
// third request to the same beat starts a later descriptor, preserving order.
//
// Misaligned requests are retained as local-error descriptors.  They therefore
// still produce exactly one ordered response and cannot bypass older AXI reads.
// Early/missing RLAST is reported on the affected responses; an early RLAST
// additionally synthesizes error responses for the unreturned descriptor lanes
// so the local stream cannot deadlock.
module c1_tensor_mem_axi128_read_burst_client #(
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS * MAX_OUTSTANDING,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    // A repeated read of the same 64-bit half is still two ordered logical
    // requests.  Allowing it to share one AXI beat is useful for CNN border
    // windows; set to zero for the stricter opposite-lane-only policy.
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    // When set, the response FIFO stores one record per AXI R beat instead
    // of one record per 64-bit logical response.  A record contains the
    // complete 128-bit beat plus its lane count/order metadata; the local
    // response port drains one or two sub-lanes before retiring the record.
    // The default remains zero so existing integrations retain their exact
    // logical-entry FIFO semantics.  In beat mode RSP_FIFO_DEPTH is measured
    // in beat records and may normally be set to BURST_BEATS*MAX_OUTSTANDING.
    parameter bit RSP_FIFO_BEAT_MODE = 1'b0,
    // When enabled, an R beat may refill response-FIFO capacity released by a
    // local response handshake in the very same cycle.  The default keeps the
    // registered/conservative RREADY boundary used by the original timing
    // closure work.  Enable only after checking the extra rsp_ready->RREADY
    // combinational path in the target implementation.
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    // When enabled, a request may be accepted in the same cycle that the
    // burst builder consumes the current FIFO head.  This only matters while
    // the logical request FIFO is full: the pop frees the exact storage slot
    // that the push overwrites, so occupancy remains full and the producer
    // avoids a one-cycle bubble.  The default keeps req_ready independent of
    // builder state for the conservative timing boundary used by existing
    // integrations.
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic                         req_flush,
    input  logic [31:0]                  req_addr,

    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_error,
    output logic [63:0]                  rsp_rdata,

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

    output logic                         perf_busy,
    output logic [63:0]                  perf_req_accept_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_packed_request_count,
    output logic [63:0]                  perf_error_count,
    output logic [7:0]                   perf_req_occupancy,
    output logic [7:0]                   perf_max_req_occupancy,
    output logic [7:0]                   perf_outstanding,
    output logic [7:0]                   perf_max_outstanding
);

    localparam integer REQ_PTR_W = (REQ_FIFO_DEPTH <= 1) ? 1 : $clog2(REQ_FIFO_DEPTH);
    localparam integer REQ_CNT_W = (REQ_FIFO_DEPTH <= 1) ? 1 : $clog2(REQ_FIFO_DEPTH + 1);
    localparam integer DESC_DEPTH = MAX_OUTSTANDING + 2;
    localparam integer DESC_PTR_W = (DESC_DEPTH <= 1) ? 1 : $clog2(DESC_DEPTH);
    localparam integer DESC_CNT_W = (DESC_DEPTH <= 1) ? 1 : $clog2(DESC_DEPTH + 1);
    localparam integer BEAT_W = (BURST_BEATS <= 1) ? 1 : $clog2(BURST_BEATS + 1);
    localparam integer RSP_PTR_W = (RSP_FIFO_DEPTH <= 1) ? 1 : $clog2(RSP_FIFO_DEPTH);
    localparam integer RSP_CNT_W = (RSP_FIFO_DEPTH <= 1) ? 1 : $clog2(RSP_FIFO_DEPTH + 1);
    localparam integer AGE_W = (BUILD_TIMEOUT_CYCLES <= 1) ? 1 :
                               $clog2(BUILD_TIMEOUT_CYCLES);

    typedef enum logic [1:0] {
        RD_IDLE,
        RD_AXI,
        RD_SYNTH
    } rd_state_t;

    initial begin
        if (REQ_FIFO_DEPTH < 2)
            $fatal(1, "REQ_FIFO_DEPTH must be at least two");
        if (REQ_FIFO_DEPTH > 255)
            $fatal(1, "REQ_FIFO_DEPTH must be <=255 for 8-bit occupancy counters");
        if ((BURST_BEATS < 1) || (BURST_BEATS > 256))
            $fatal(1, "BURST_BEATS must be in the range 1..256");
        if (MAX_OUTSTANDING < 1)
            $fatal(1, "MAX_OUTSTANDING must be positive");
        if ((!RSP_FIFO_BEAT_MODE && (RSP_FIFO_DEPTH < 2)) ||
            (RSP_FIFO_BEAT_MODE && (RSP_FIFO_DEPTH < 1)))
            $fatal(1, "RSP_FIFO_DEPTH is below the minimum for the selected mode");
        if (RSP_FIFO_BEAT_MODE &&
            (RSP_FIFO_DEPTH < (BURST_BEATS * MAX_OUTSTANDING)))
            $fatal(1, "beat-mode RSP_FIFO_DEPTH must cover BURST_BEATS*MAX_OUTSTANDING records");
        if (BUILD_TIMEOUT_CYCLES < 1)
            $fatal(1, "BUILD_TIMEOUT_CYCLES must be positive");
    end

    // ------------------------------------------------------------------
    // Logical request FIFO.
    // ------------------------------------------------------------------
    logic [31:0] req_mem [0:REQ_FIFO_DEPTH-1];
    logic [REQ_PTR_W-1:0] req_head_q, req_tail_q;
    logic [REQ_CNT_W-1:0] req_count_q;
    logic req_push, req_pop;
    // Builder control is declared before req_pop because Vivado's front-end
    // requires a signal declaration to precede every continuous assignment.
    logic build_start, build_append, build_close;

    function automatic logic [REQ_PTR_W-1:0] req_ptr_add(
        input logic [REQ_PTR_W-1:0] ptr,
        input integer step
    );
        integer tmp;
        begin
            tmp = ptr + step;
            if (tmp >= REQ_FIFO_DEPTH)
                tmp = tmp - REQ_FIFO_DEPTH;
            if (tmp >= REQ_FIFO_DEPTH)
                tmp = tmp - REQ_FIFO_DEPTH;
            req_ptr_add = tmp[REQ_PTR_W-1:0];
        end
    endfunction

    // `req_pop` is derived solely from the registered FIFO/builder state and
    // therefore does not depend on req_ready/req_push.  The optional term is
    // consequently acyclic: when the FIFO is full, a simultaneous builder
    // pop grants one replacement request without changing occupancy.
    assign req_ready = !rst && ((req_count_q < REQ_FIFO_DEPTH) ||
                                (ALLOW_REQ_POP_REFILL && req_pop));
    assign req_push = req_valid && req_ready;

    // ------------------------------------------------------------------
    // Descriptor ring.  A slot is reserved when its first logical request is
    // removed from req_mem, becomes complete when the burst is closed, and is
    // marked issued after AR (or immediately for a local-error descriptor).
    // ------------------------------------------------------------------
    logic [31:0] desc_base_mem [0:DESC_DEPTH-1];
    logic [BEAT_W-1:0] desc_beats_mem [0:DESC_DEPTH-1];
    logic [2*BURST_BEATS-1:0] desc_lane_count_mem [0:DESC_DEPTH-1];
    logic [BURST_BEATS-1:0] desc_lane_first_mem [0:DESC_DEPTH-1];
    logic [BURST_BEATS-1:0] desc_lane_second_mem [0:DESC_DEPTH-1];
    logic desc_local_mem [0:DESC_DEPTH-1];
    logic desc_complete_mem [0:DESC_DEPTH-1];
    logic desc_issued_mem [0:DESC_DEPTH-1];

    logic [DESC_PTR_W-1:0] desc_alloc_ptr_q, desc_issue_ptr_q, desc_rsp_ptr_q;
    logic [DESC_CNT_W-1:0] desc_total_count_q, desc_issued_count_q;

    // Current burst builder.
    logic build_active_q;
    logic [DESC_PTR_W-1:0] build_slot_q;
    logic [31:0] build_base_q;
    logic [BEAT_W-1:0] build_beats_q;
    logic [BEAT_W:0] build_req_count_q;
    logic [2*BURST_BEATS-1:0] build_lane_count_q;
    logic [BURST_BEATS-1:0] build_lane_first_q, build_lane_second_q;
    logic [AGE_W-1:0] build_age_q;

    logic [31:0] q_head_addr;
    logic [31:0] q_head_aligned;
    logic q_head_lane;
    logic q_head_aligned_ok;
    logic [32:0] build_last_addr_wide, build_next_addr_wide;
    logic same_beat, next_beat, append_legal;
    logic build_start_local_error;
    logic desc_space;

    assign q_head_addr = req_mem[req_head_q];
    assign q_head_aligned = {q_head_addr[31:4], 4'b0};
    assign q_head_lane = q_head_addr[3];
    assign q_head_aligned_ok = (q_head_addr[2:0] == 3'b000);
    assign build_last_addr_wide = {1'b0, build_base_q} +
                                  ((build_beats_q == 0) ? 33'd0 :
                                   (({28'd0, build_beats_q} - 1'b1) << 4));
    assign build_next_addr_wide = {1'b0, build_base_q} +
                                  ({28'd0, build_beats_q} << 4);
    assign same_beat = build_active_q && (build_beats_q != 0) &&
                       ({1'b0, q_head_aligned} == build_last_addr_wide);
    assign next_beat = build_active_q && (build_beats_q != 0) &&
                       ({1'b0, q_head_aligned} == build_next_addr_wide) &&
                       (q_head_aligned[31:12] == build_base_q[31:12]);
    assign append_legal = build_active_q && (req_count_q != 0) &&
                           q_head_aligned_ok &&
                           ((same_beat &&
                             (build_lane_count_q[(build_beats_q-1'b1)*2 +: 2] == 1) &&
                             (ALLOW_SAME_LANE_DUP ||
                              (q_head_lane !=
                               build_lane_first_q[build_beats_q-1'b1]))) ||
                           (next_beat && (build_beats_q < BURST_BEATS)));
    assign desc_space = (desc_total_count_q < DESC_DEPTH);
    assign build_start = !build_active_q && (req_count_q != 0) && desc_space;
    assign build_start_local_error = build_start && (q_head_addr[2:0] != 3'b000);
    // A request leaves the logical FIFO exactly when the builder consumes it.
    // This includes the first request of a local-error descriptor.
    assign req_pop = build_start || build_append;

    // A close is performed on the cycle after the last request was appended;
    // this keeps the descriptor payload registered and stable for ARVALID.
    assign build_append = append_legal && !req_flush;
    // If the final beat is currently half-full, the opposite lane may be
    // appended even when the burst has reached BURST_BEATS.  Close only on
    // the following cycle so the registered lane map includes that append.
    assign build_close = build_active_q && !build_append &&
                         (req_flush ||
                          !append_legal &&
                          ((req_count_q != 0) ||
                           (build_age_q >= BUILD_TIMEOUT_CYCLES-1)) ||
                            // Once the maximum number of 128-bit beats is
                            // reached, still admit a second lane that may
                            // arrive a few cycles later.  If the request FIFO
                            // is empty, BUILD_TIMEOUT_CYCLES provides the
                            // bounded wait before publishing the full burst.
                            ((build_beats_q >= BURST_BEATS) &&
                             (req_count_q != 0) && !append_legal));

    // ------------------------------------------------------------------
    // AXI response FIFO.
    // ------------------------------------------------------------------
    // Logical-entry mode (the historical implementation) stores one
    // 64-bit response per slot.  Beat mode stores one complete AXI beat per
    // slot and drains its one/two logical lanes over successive handshakes.
    // Keeping both declarations in the source is intentional: the inactive
    // bank is removed by elaboration/synthesis when the parameter is a
    // constant, while this avoids unsafe packed-array width tricks for small
    // parameter values.
    logic [63:0] rsp_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_err_mem [0:RSP_FIFO_DEPTH-1];
    logic [127:0] rsp_beat_mem [0:RSP_FIFO_DEPTH-1];
    logic [1:0] rsp_beat_lane_count_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_beat_first_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_beat_second_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_beat_err_mem [0:RSP_FIFO_DEPTH-1];
    logic [RSP_PTR_W-1:0] rsp_head_q, rsp_tail_q;
    logic [RSP_CNT_W-1:0] rsp_count_q;
    // In beat mode this selects the sub-lane currently presented at the
    // local response port.  It changes only after a successful response
    // handshake, so VALID/DATA/ERROR remain stable under backpressure.
    logic rsp_lane_q;
    logic rsp_pop;
    logic rsp_record_pop;

    // Present either a logical FIFO entry or the selected sub-lane of a beat
    // record.  `rsp_lane_q` is only advanced on a handshake; this is the
    // ready/valid hold point required by the local requester.
    always_comb begin
        rsp_valid = !rst && (rsp_count_q != 0);
        rsp_error = 1'b0;
        rsp_rdata = 64'd0;
        if (rsp_valid) begin
            if (RSP_FIFO_BEAT_MODE) begin
                rsp_error = rsp_beat_err_mem[rsp_head_q];
                if (rsp_lane_q) begin
                    rsp_rdata = rsp_beat_second_mem[rsp_head_q] ?
                                rsp_beat_mem[rsp_head_q][127:64] :
                                rsp_beat_mem[rsp_head_q][63:0];
                end else begin
                    rsp_rdata = rsp_beat_first_mem[rsp_head_q] ?
                                rsp_beat_mem[rsp_head_q][127:64] :
                                rsp_beat_mem[rsp_head_q][63:0];
                end
            end else begin
                rsp_error = rsp_err_mem[rsp_head_q];
                rsp_rdata = rsp_mem[rsp_head_q];
            end
        end
    end
    assign rsp_pop = rsp_valid && rsp_ready;

    // A beat record retires only after its final logical lane has been
    // consumed.  In logical-entry mode every handshake retires one FIFO
    // slot, so the signal is exactly `rsp_pop`.
    always_comb begin
        rsp_record_pop = rsp_pop;
        if (RSP_FIFO_BEAT_MODE && rsp_pop && rsp_count_q != 0) begin
            rsp_record_pop = (rsp_beat_lane_count_mem[rsp_head_q] != 2) ||
                             rsp_lane_q;
        end
    end

    function automatic logic [RSP_PTR_W-1:0] rsp_ptr_add(
        input logic [RSP_PTR_W-1:0] ptr,
        input integer step
    );
        integer tmp;
        begin
            tmp = ptr + step;
            if (tmp >= RSP_FIFO_DEPTH)
                tmp = tmp - RSP_FIFO_DEPTH;
            if (tmp >= RSP_FIFO_DEPTH)
                tmp = tmp - RSP_FIFO_DEPTH;
            rsp_ptr_add = tmp[RSP_PTR_W-1:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // Read-side descriptor consumer.  AXI has no IDs at this boundary, so the
    // oldest issued descriptor owns the R channel until its terminal beat.
    // ------------------------------------------------------------------
    rd_state_t rd_state_q;
    logic [DESC_PTR_W-1:0] rd_slot_q;
    logic [BEAT_W-1:0] rd_beat_q;
    logic [BEAT_W-1:0] synth_beat_q;
    logic [1:0] synth_lane_index_q;

    logic rd_activate;
    logic rd_local_active;
    logic [1:0] rd_lane_count;
    logic rd_expected_last;
    logic rd_terminal;
    logic rd_early_last;
    logic [1:0] rd_push_count;
    logic rsp_capacity;
    logic r_fire;
    logic local_rsp_push;
    logic synth_rsp_push;
    logic normal_axi_done;
    logic desc_done;
    logic [1:0] rsp_push_count_w;
    logic issue_event;
    logic local_issue_event;
    logic ar_fire;

    assign rd_activate = (rd_state_q == RD_IDLE) &&
                         (desc_issued_count_q != 0) &&
                         desc_issued_mem[desc_rsp_ptr_q];
    assign rd_local_active = (rd_state_q == RD_AXI) && desc_local_mem[rd_slot_q];
    assign rd_lane_count = (rd_state_q == RD_AXI) ?
        desc_lane_count_mem[rd_slot_q][rd_beat_q*2 +: 2] : 2'd0;
    assign rd_expected_last = (rd_state_q == RD_AXI) &&
                              (rd_beat_q == desc_beats_mem[rd_slot_q] - 1'b1);
    assign rd_terminal = m_axi_rlast || rd_expected_last;
    assign rd_early_last = m_axi_rlast && !rd_expected_last;
    assign rd_push_count = rd_lane_count;

    // Reserve response FIFO space for the next transfer.  By default do not
    // fold rsp_pop into this decision: that keeps downstream rsp_ready out of
    // the AXI RREADY timing path.  The optional refill mode admits a transfer
    // only when the exact record that will be retired this cycle makes enough
    // room for its full payload.  Logical-entry mode needs room for both
    // halves of a beat; beat mode needs one record regardless of lane_count.
    // Therefore even optional mode never accepts a two-lane beat into a full
    // logical FIFO after freeing just one entry.
    always_comb begin
        if (RSP_FIFO_BEAT_MODE) begin
            rsp_capacity = (rsp_count_q < RSP_FIFO_DEPTH) ||
                           (ALLOW_RSP_POP_REFILL && rsp_record_pop);
        end else begin
            case (rd_push_count)
                2'd0:    rsp_capacity = 1'b1;
                2'd1:    rsp_capacity =
                    (rsp_count_q < RSP_FIFO_DEPTH) ||
                    (ALLOW_RSP_POP_REFILL && rsp_pop);
                default: rsp_capacity =
                    (rsp_count_q < (RSP_FIFO_DEPTH - 1)) ||
                    (ALLOW_RSP_POP_REFILL && rsp_pop &&
                     (rsp_count_q < RSP_FIFO_DEPTH));
            endcase
        end
    end

    always_comb begin
        m_axi_araddr = desc_base_mem[desc_issue_ptr_q];
        m_axi_arlen = (desc_beats_mem[desc_issue_ptr_q] == 0) ? 8'd0 :
                      desc_beats_mem[desc_issue_ptr_q] - 1'b1;
        m_axi_arsize = 3'd4;
        m_axi_arburst = 2'b01;
        m_axi_arvalid = !rst &&
                        (desc_issued_count_q < MAX_OUTSTANDING) &&
                        (desc_total_count_q != 0) &&
                        desc_complete_mem[desc_issue_ptr_q] &&
                        !desc_issued_mem[desc_issue_ptr_q] &&
                        !desc_local_mem[desc_issue_ptr_q] &&
                        !local_issue_event;

        // For a local-error descriptor no AXI transfer is needed.  It is
        // marked issued in the sequential block and then retired through the
        // same ordered response machinery.
        m_axi_rready = !rst && (rd_state_q == RD_AXI) && !rd_local_active &&
                       rsp_capacity;
        ar_fire = m_axi_arvalid && m_axi_arready;
        r_fire = m_axi_rvalid && m_axi_rready;
        local_rsp_push = (rd_state_q == RD_AXI) && rd_local_active &&
                         (rsp_count_q < RSP_FIFO_DEPTH);
        synth_rsp_push = (rd_state_q == RD_SYNTH) &&
                          (rsp_count_q < RSP_FIFO_DEPTH);
        normal_axi_done = (rd_state_q == RD_AXI) && !rd_local_active &&
                          r_fire && rd_terminal && !rd_early_last;
        desc_done = ((rd_state_q == RD_AXI) && rd_local_active &&
                     local_rsp_push) ||
                    normal_axi_done ||
                    ((rd_state_q == RD_SYNTH) && synth_rsp_push &&
                     (synth_beat_q >= desc_beats_mem[rd_slot_q]-1'b1) &&
                     ((synth_lane_index_q >= 1) ||
                      (desc_lane_count_mem[rd_slot_q][synth_beat_q*2 +: 2] == 1)));
        local_issue_event = (desc_issued_count_q < MAX_OUTSTANDING) &&
                            (desc_total_count_q != 0) &&
                            desc_complete_mem[desc_issue_ptr_q] &&
                            !desc_issued_mem[desc_issue_ptr_q] &&
                            desc_local_mem[desc_issue_ptr_q];
        issue_event = ar_fire || local_issue_event;
    end

    always_comb begin
        rsp_push_count_w = 2'd0;
        if (RSP_FIFO_BEAT_MODE) begin
            // One AXI beat (including a two-lane beat) occupies one record.
            if (r_fire && (rd_push_count != 0))
                rsp_push_count_w = 2'd1;
            else if (local_rsp_push || synth_rsp_push)
                rsp_push_count_w = 2'd1;
        end else begin
            if (r_fire)
                rsp_push_count_w = rd_push_count;
            else if (local_rsp_push || synth_rsp_push)
                rsp_push_count_w = 2'd1;
        end
    end

    assign perf_busy = (req_count_q != 0) || build_active_q ||
                       (desc_total_count_q != 0) || (rsp_count_q != 0) ||
                       (rd_state_q != RD_IDLE);
    assign perf_req_occupancy = req_count_q;
    assign perf_outstanding = desc_issued_count_q;

    // ------------------------------------------------------------------
    // State and storage updates.
    // ------------------------------------------------------------------
    integer init_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            req_head_q <= '0;
            req_tail_q <= '0;
            req_count_q <= '0;
            desc_alloc_ptr_q <= '0;
            desc_issue_ptr_q <= '0;
            desc_rsp_ptr_q <= '0;
            desc_total_count_q <= '0;
            desc_issued_count_q <= '0;
            build_active_q <= 1'b0;
            build_slot_q <= '0;
            build_base_q <= '0;
            build_beats_q <= '0;
            build_req_count_q <= '0;
            build_lane_count_q <= '0;
            build_lane_first_q <= '0;
            build_lane_second_q <= '0;
            build_age_q <= '0;
            rsp_head_q <= '0;
            rsp_tail_q <= '0;
            rsp_count_q <= '0;
            rsp_lane_q <= 1'b0;
            rd_state_q <= RD_IDLE;
            rd_slot_q <= '0;
            rd_beat_q <= '0;
            synth_beat_q <= '0;
            synth_lane_index_q <= '0;
            perf_req_accept_count <= 64'd0;
            perf_axi_burst_count <= 64'd0;
            perf_axi_beat_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_packed_request_count <= 64'd0;
            perf_error_count <= 64'd0;
            perf_max_req_occupancy <= 8'd0;
            perf_max_outstanding <= 8'd0;
            for (init_i = 0; init_i < DESC_DEPTH; init_i = init_i + 1) begin
                desc_base_mem[init_i] <= 32'd0;
                desc_beats_mem[init_i] <= '0;
                desc_lane_count_mem[init_i] <= '0;
                desc_lane_first_mem[init_i] <= '0;
                desc_lane_second_mem[init_i] <= '0;
                desc_local_mem[init_i] <= 1'b0;
                desc_complete_mem[init_i] <= 1'b0;
                desc_issued_mem[init_i] <= 1'b0;
            end
        end else begin
            // Request FIFO push/pop accounting.
            if (req_push) begin
                req_mem[req_tail_q] <= req_addr;
                req_tail_q <= req_ptr_add(req_tail_q, 1);
                perf_req_accept_count <= perf_req_accept_count + 1'b1;
            end
            if (req_pop)
                req_head_q <= req_ptr_add(req_head_q, 1);
            case ({req_push, req_pop})
                2'b10: req_count_q <= req_count_q + 1'b1;
                2'b01: req_count_q <= req_count_q - 1'b1;
                default: req_count_q <= req_count_q;
            endcase
            // A simultaneous full-FIFO pop/push keeps the physical occupancy
            // unchanged.  Do not count the replacement enqueue twice in the
            // diagnostic maximum (the old expression could report
            // REQ_FIFO_DEPTH+1 when ALLOW_REQ_POP_REFILL was enabled).
            if (req_push && !req_pop &&
                ((req_count_q + 1'b1) > perf_max_req_occupancy))
                perf_max_req_occupancy <= req_count_q + 1'b1;

            // Reserve a descriptor and consume the first request.
            if (build_start) begin
                req_head_q <= req_ptr_add(req_head_q, 1);
                if (build_start_local_error) begin
                    desc_base_mem[desc_alloc_ptr_q] <= 32'd0;
                    desc_beats_mem[desc_alloc_ptr_q] <= '0;
                    desc_lane_count_mem[desc_alloc_ptr_q] <= {{(2*BURST_BEATS-2){1'b0}}, 2'd1};
                    desc_lane_first_mem[desc_alloc_ptr_q] <= '0;
                    desc_lane_second_mem[desc_alloc_ptr_q] <= '0;
                    desc_local_mem[desc_alloc_ptr_q] <= 1'b1;
                    desc_complete_mem[desc_alloc_ptr_q] <= 1'b1;
                    desc_issued_mem[desc_alloc_ptr_q] <= 1'b0;
                    desc_alloc_ptr_q <= (desc_alloc_ptr_q == DESC_DEPTH-1) ?
                                        '0 : desc_alloc_ptr_q + 1'b1;
                end else begin
                    build_active_q <= 1'b1;
                    build_slot_q <= desc_alloc_ptr_q;
                    build_base_q <= q_head_aligned;
                    build_beats_q <= 1;
                    build_req_count_q <= 1;
                    build_lane_count_q <= '0;
                    build_lane_count_q[1:0] <= 2'd1;
                    build_lane_first_q <= '0;
                    build_lane_second_q <= '0;
                    build_lane_first_q[0] <= q_head_lane;
                    build_age_q <= '0;
                    desc_local_mem[desc_alloc_ptr_q] <= 1'b0;
                    desc_complete_mem[desc_alloc_ptr_q] <= 1'b0;
                    desc_issued_mem[desc_alloc_ptr_q] <= 1'b0;
                    desc_alloc_ptr_q <= (desc_alloc_ptr_q == DESC_DEPTH-1) ?
                                        '0 : desc_alloc_ptr_q + 1'b1;
                end
            end else if (build_append) begin
                req_head_q <= req_ptr_add(req_head_q, 1);
                build_req_count_q <= build_req_count_q + 1'b1;
                build_age_q <= '0;
                if (same_beat) begin
                    if (build_lane_count_q[(build_beats_q-1'b1)*2 +: 2] == 1) begin
                        build_lane_count_q[(build_beats_q-1'b1)*2 +: 2] <= 2'd2;
                        build_lane_second_q[build_beats_q-1'b1] <= q_head_lane;
                    end
                end else begin
                    build_lane_count_q[build_beats_q*2 +: 2] <= 2'd1;
                    build_lane_first_q[build_beats_q] <= q_head_lane;
                    build_beats_q <= build_beats_q + 1'b1;
                end
            end else if (build_active_q) begin
                if (build_age_q < BUILD_TIMEOUT_CYCLES-1)
                    build_age_q <= build_age_q + 1'b1;
            end

            // Close and publish the current descriptor.  The builder may have
            // consumed the final request in the same edge; all fields below
            // are the registered values visible before that edge, with the
            // append case handled by the explicit +1 correction.
            if (build_close) begin
                desc_base_mem[build_slot_q] <= build_base_q;
                desc_beats_mem[build_slot_q] <= build_beats_q;
                desc_lane_count_mem[build_slot_q] <= build_lane_count_q;
                desc_lane_first_mem[build_slot_q] <= build_lane_first_q;
                desc_lane_second_mem[build_slot_q] <= build_lane_second_q;
                desc_local_mem[build_slot_q] <= 1'b0;
                desc_complete_mem[build_slot_q] <= 1'b1;
                build_active_q <= 1'b0;
                if (build_req_count_q > build_beats_q)
                    perf_packed_request_count <= perf_packed_request_count +
                                                 (build_req_count_q - build_beats_q);
            end

            // Descriptor total count changes on reservation and response
            // retirement.  Local-error descriptors are reserved immediately;
            // normal descriptors are reserved before their burst is complete.
            case ({build_start, desc_done})
                2'b10: desc_total_count_q <= desc_total_count_q + 1'b1;
                2'b01: desc_total_count_q <= desc_total_count_q - 1'b1;
                default: desc_total_count_q <= desc_total_count_q;
            endcase

            if (local_issue_event) begin
                desc_issued_mem[desc_issue_ptr_q] <= 1'b1;
                desc_issue_ptr_q <= (desc_issue_ptr_q == DESC_DEPTH-1) ?
                                    '0 : desc_issue_ptr_q + 1'b1;
            end else if (ar_fire) begin
                desc_issued_mem[desc_issue_ptr_q] <= 1'b1;
                desc_issue_ptr_q <= (desc_issue_ptr_q == DESC_DEPTH-1) ?
                                    '0 : desc_issue_ptr_q + 1'b1;
                perf_axi_burst_count <= perf_axi_burst_count + 1'b1;
            end

            if (desc_done) begin
                desc_issued_mem[rd_slot_q] <= 1'b0;
                desc_complete_mem[rd_slot_q] <= 1'b0;
                desc_rsp_ptr_q <= (desc_rsp_ptr_q == DESC_DEPTH-1) ?
                                  '0 : desc_rsp_ptr_q + 1'b1;
            end

            case ({issue_event, desc_done})
                2'b10: desc_issued_count_q <= desc_issued_count_q + 1'b1;
                2'b01: desc_issued_count_q <= desc_issued_count_q - 1'b1;
                default: desc_issued_count_q <= desc_issued_count_q;
            endcase
            if (issue_event && ((desc_issued_count_q + 1'b1) > perf_max_outstanding))
                perf_max_outstanding <= desc_issued_count_q + 1'b1;

            // Activate the oldest issued descriptor after its AR handshake has
            // been observed in the registered descriptor bit.
            if (rd_activate) begin
                rd_slot_q <= desc_rsp_ptr_q;
                rd_beat_q <= '0;
                if (desc_local_mem[desc_rsp_ptr_q]) begin
                    rd_state_q <= RD_AXI;
                end else begin
                    rd_state_q <= RD_AXI;
                end
            end

            if (r_fire) begin
                perf_axi_beat_count <= perf_axi_beat_count + 1'b1;
                if ((m_axi_rresp != 2'b00) ||
                    (m_axi_rlast != rd_expected_last))
                    perf_error_count <= perf_error_count + rd_push_count;
                if (rd_terminal) begin
                    if (rd_early_last && (rd_beat_q < desc_beats_mem[rd_slot_q]-1'b1)) begin
                        // Synthesize ordered errors for all later requested
                        // lanes; no further AXI beat belongs to this burst.
                        synth_beat_q <= rd_beat_q + 1'b1;
                        synth_lane_index_q <= 0;
                        rd_state_q <= RD_SYNTH;
                    end else begin
                        rd_state_q <= RD_IDLE;
                    end
                end else begin
                    rd_beat_q <= rd_beat_q + 1'b1;
                end
            end

            if (local_rsp_push) begin
                perf_error_count <= perf_error_count + 1'b1;
                rd_state_q <= RD_IDLE;
            end

            if (synth_rsp_push) begin
                perf_error_count <= perf_error_count + 1'b1;
                if (synth_lane_index_q == 1) begin
                    synth_lane_index_q <= 0;
                    if (synth_beat_q >= desc_beats_mem[rd_slot_q]-1'b1)
                        rd_state_q <= RD_IDLE;
                    else
                        synth_beat_q <= synth_beat_q + 1'b1;
                end else if (desc_lane_count_mem[rd_slot_q][synth_beat_q*2 +: 2] == 2) begin
                    synth_lane_index_q <= 1;
                end else begin
                    if (synth_beat_q >= desc_beats_mem[rd_slot_q]-1'b1)
                        rd_state_q <= RD_IDLE;
                    else
                        synth_beat_q <= synth_beat_q + 1'b1;
                end
            end

            // Response payload storage.  In logical-entry mode a two-lane
            // AXI beat occupies two slots.  In beat mode the complete beat
            // and lane metadata occupy one slot; local/synthetic errors are
            // represented as one-lane zero-data records.
            if (RSP_FIFO_BEAT_MODE) begin
                if (local_rsp_push || synth_rsp_push) begin
                    rsp_beat_mem[rsp_tail_q] <= 128'd0;
                    rsp_beat_lane_count_mem[rsp_tail_q] <= 2'd1;
                    rsp_beat_first_mem[rsp_tail_q] <= 1'b0;
                    rsp_beat_second_mem[rsp_tail_q] <= 1'b0;
                    rsp_beat_err_mem[rsp_tail_q] <= 1'b1;
                    rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 1);
                end else if (r_fire && (rd_push_count != 0)) begin
                    rsp_beat_mem[rsp_tail_q] <= m_axi_rdata;
                    rsp_beat_lane_count_mem[rsp_tail_q] <= rd_lane_count;
                    rsp_beat_first_mem[rsp_tail_q] <=
                        desc_lane_first_mem[rd_slot_q][rd_beat_q];
                    rsp_beat_second_mem[rsp_tail_q] <=
                        desc_lane_second_mem[rd_slot_q][rd_beat_q];
                    rsp_beat_err_mem[rsp_tail_q] <=
                        (m_axi_rresp != 2'b00) ||
                        (m_axi_rlast != rd_expected_last);
                    rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 1);
                end
            end else begin
                // Up to two response FIFO entries can be pushed by one AXI
                // beat.  The lane order is the original request order
                // captured by the descriptor, not necessarily lower-half
                // before upper-half.
                if (local_rsp_push || synth_rsp_push) begin
                    rsp_mem[rsp_tail_q] <= 64'd0;
                    rsp_err_mem[rsp_tail_q] <= 1'b1;
                    rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 1);
                end else if (r_fire && (rd_push_count != 0)) begin
                    rsp_mem[rsp_tail_q] <= rd_lane_count >= 1 ?
                        (desc_lane_first_mem[rd_slot_q][rd_beat_q] ?
                         m_axi_rdata[127:64] : m_axi_rdata[63:0]) : 64'd0;
                    rsp_err_mem[rsp_tail_q] <=
                        (m_axi_rresp != 2'b00) ||
                        (m_axi_rlast != rd_expected_last);
                    rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 1);
                    if (rd_push_count == 2) begin
                        rsp_mem[rsp_ptr_add(rsp_tail_q, 1)] <=
                            desc_lane_second_mem[rd_slot_q][rd_beat_q] ?
                            m_axi_rdata[127:64] : m_axi_rdata[63:0];
                        rsp_err_mem[rsp_ptr_add(rsp_tail_q, 1)] <=
                            (m_axi_rresp != 2'b00) ||
                            (m_axi_rlast != rd_expected_last);
                        rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 2);
                    end
                end
            end

            // Response FIFO count.  Synthetic/local pushes are mutually
            // exclusive with AXI pushes because rd_state has one owner.  In
            // beat mode `rsp_record_pop` can lag `rsp_pop` by one handshake
            // while the second lane of a two-lane record is being drained.
            if (RSP_FIFO_BEAT_MODE) begin
                case ({(rsp_push_count_w != 0), rsp_record_pop})
                    2'b10: rsp_count_q <= rsp_count_q + 1'b1;
                    2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                    2'b11: rsp_count_q <= rsp_count_q;
                    default: rsp_count_q <= rsp_count_q;
                endcase
                if (rsp_record_pop)
                    rsp_head_q <= rsp_ptr_add(rsp_head_q, 1);
                if (rsp_pop) begin
                    if ((rsp_beat_lane_count_mem[rsp_head_q] == 2) &&
                        !rsp_lane_q)
                        rsp_lane_q <= 1'b1;
                    else
                        rsp_lane_q <= 1'b0;
                end
            end else begin
                case ({(rsp_push_count_w != 0), rsp_record_pop})
                    2'b10: rsp_count_q <= rsp_count_q + rsp_push_count_w;
                    2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                    2'b11: rsp_count_q <= rsp_count_q + rsp_push_count_w - 1'b1;
                    default: rsp_count_q <= rsp_count_q;
                endcase
                if (rsp_record_pop)
                    rsp_head_q <= rsp_ptr_add(rsp_head_q, 1);
                if (rsp_pop)
                    perf_rsp_count <= perf_rsp_count + 1'b1;
            end
            if (RSP_FIFO_BEAT_MODE && rsp_pop)
                perf_rsp_count <= perf_rsp_count + 1'b1;
        end
    end

`ifndef SYNTHESIS
    logic [44:0] ar_payload_q;
    logic ar_stalled_q;
    logic [127:0] r_payload_q;
    logic r_stalled_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            ar_stalled_q <= 1'b0;
            r_stalled_q <= 1'b0;
        end else begin
            if (ar_stalled_q &&
                (!m_axi_arvalid ||
                 ({m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst} !=
                  ar_payload_q)))
                $fatal(1, "read burst client changed stalled AR payload");
            if (r_stalled_q &&
                (!m_axi_rvalid || (m_axi_rdata != r_payload_q)))
                $fatal(1, "read burst client withdrew stalled R payload");
            ar_stalled_q <= m_axi_arvalid && !m_axi_arready;
            ar_payload_q <= {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
            r_stalled_q <= m_axi_rvalid && !m_axi_rready;
            r_payload_q <= m_axi_rdata;
            if (m_axi_arvalid &&
                ({1'b0,m_axi_araddr[11:0]} +
                 ({8'd0,m_axi_arlen}+1'b1)*13'd16 > 13'd4096))
                $fatal(1, "read burst client crossed 4KiB boundary");
            if (rsp_valid && rsp_ready && (perf_rsp_count >= perf_req_accept_count))
                $fatal(1, "read burst client emitted excess response");
        end
    end
`endif

endmodule
