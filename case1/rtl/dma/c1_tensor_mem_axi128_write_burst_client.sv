`timescale 1ns/1ps

// Board-independent write-side tensor traffic prototype.
//
// The legacy tensor write seam accepts one 64-bit write at a time.  This
// block is an intentionally separate experiment which accepts a FIFO of
// logical 64-bit writes and emits one AXI4 128-bit INCR write burst.  Two
// adjacent 64-bit writes are packed into one AXI beat and adjacent beats are
// collected up to BURST_BEATS (without crossing a 4-KiB boundary).
//
// This first implementation deliberately has one AXI write transaction in
// flight.  The request FIFO continues to absorb traffic while AW/W/B are in
// progress, so it is useful as a boardless packing/traffic prototype while
// keeping ordering and response handling easy to audit.  MAX_OUTSTANDING is
// retained as an integration-facing parameter and is required to be one;
// a later multi-descriptor version can preserve this local interface.
// AW and W are independently driven once the complete burst is built. Either
// channel may finish first; B is accepted only after both have completed.
// An ordered end marker closes the descriptor on the same edge that consumes
// its FIFO entry. AW/W still come only from registered descriptor storage;
// an idle/empty client may load a terminal request directly into those same
// descriptor registers, skipping FIFO storage but never bypassing the AXI
// output registers or issuing an early logical acknowledgement.
//
// A write response is an ordered logical acknowledgement.  rsp_rdata echoes
// the original logical write data (zero for a locally rejected misaligned
// request), and rsp_error is asserted for a non-OKAY BRESP or a local error.
// Same-lane duplicate writes are never merged when their payload differs,
// because one AXI lane cannot represent two different values.  If
// ALLOW_SAME_LANE_DUP is enabled, identical data+strobe duplicates may share
// a lane; the two logical acknowledgements are still returned in order.
module c1_tensor_mem_axi128_write_burst_client #(
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer MAX_OUTSTANDING = 1,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b0,
    // When enabled, a producer may replace the request-FIFO head in the
    // same cycle that the burst builder consumes it.  This only changes the
    // full-FIFO boundary: the conservative/default path keeps req_ready
    // independent of builder state, while the opt-in path removes one
    // producer bubble when a packed burst starts or appends.  The term is
    // acyclic because req_pop is derived solely from registered builder/FIFO
    // state (never from req_ready or req_push).
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0,
    parameter bit USE_REQUEST_END = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic                         req_flush,
    input  logic [31:0]                  req_addr,
    input  logic [63:0]                  req_wdata,
    input  logic [7:0]                   req_wstrb,

    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_error,
    output logic [63:0]                  rsp_rdata,

    output logic [31:0]                  m_axi_awaddr,
    output logic [7:0]                   m_axi_awlen,
    output logic [2:0]                   m_axi_awsize,
    output logic [1:0]                   m_axi_awburst,
    output logic                         m_axi_awvalid,
    input  logic                         m_axi_awready,

    output logic [127:0]                 m_axi_wdata,
    output logic [15:0]                  m_axi_wstrb,
    output logic                         m_axi_wlast,
    output logic                         m_axi_wvalid,
    input  logic                         m_axi_wready,

    input  logic [1:0]                   m_axi_bresp,
    input  logic                         m_axi_bvalid,
    output logic                         m_axi_bready,

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
    output logic [7:0]                   perf_max_outstanding,
    // Optional ordered end marker, sampled with the logical request. Unlike
    // req_flush, this marker travels through the FIFO with its payload.
    input logic                         req_end
);

    localparam integer MAX_LOGICAL = 2 * BURST_BEATS;
    localparam integer REQ_PTR_W = (REQ_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(REQ_FIFO_DEPTH);
    localparam integer REQ_CNT_W = (REQ_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(REQ_FIFO_DEPTH + 1);
    localparam integer BEAT_IDX_W = (BURST_BEATS <= 1) ? 1 :
                                    $clog2(BURST_BEATS);
    localparam integer BEAT_CNT_W = (BURST_BEATS <= 1) ? 1 :
                                    $clog2(BURST_BEATS + 1);
    localparam integer LOGICAL_CNT_W = (MAX_LOGICAL <= 1) ? 1 :
                                       $clog2(MAX_LOGICAL + 1);
    localparam integer RSP_PTR_W = (RSP_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(RSP_FIFO_DEPTH);
    localparam integer RSP_CNT_W = (RSP_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(RSP_FIFO_DEPTH + 1);
    localparam integer AGE_W = (BUILD_TIMEOUT_CYCLES <= 1) ? 1 :
                               $clog2(BUILD_TIMEOUT_CYCLES);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_BUILD,
        ST_AW,
        ST_W, // reserved legacy encoding; AW/W now progress together in ST_AW
        ST_B,
        ST_RESP
    } state_t;

    state_t state_q;

    initial begin
        if (REQ_FIFO_DEPTH < 2)
            $fatal(1, "REQ_FIFO_DEPTH must be at least two");
        if (REQ_FIFO_DEPTH > 255)
            $fatal(1, "REQ_FIFO_DEPTH must be <=255 for 8-bit occupancy counters");
        if ((BURST_BEATS < 1) || (BURST_BEATS > 256))
            $fatal(1, "BURST_BEATS must be in the range 1..256");
        if (MAX_OUTSTANDING != 1)
            $fatal(1, "write burst prototype currently supports one outstanding burst");
        if (RSP_FIFO_DEPTH < 2)
            $fatal(1, "RSP_FIFO_DEPTH must be at least two");
        if (RSP_FIFO_DEPTH < MAX_LOGICAL)
            $fatal(1, "RSP_FIFO_DEPTH must cover one descriptor response set");
        if (BUILD_TIMEOUT_CYCLES < 1)
            $fatal(1, "BUILD_TIMEOUT_CYCLES must be positive");
    end

    // ------------------------------------------------------------------
    // Logical write FIFO.
    // ------------------------------------------------------------------
    logic [31:0] req_addr_mem [0:REQ_FIFO_DEPTH-1];
    logic [63:0] req_data_mem [0:REQ_FIFO_DEPTH-1];
    logic [7:0]  req_strb_mem [0:REQ_FIFO_DEPTH-1];
    logic req_end_mem [0:REQ_FIFO_DEPTH-1];
    logic build_end_q;
    logic [REQ_PTR_W-1:0] req_head_q, req_tail_q;
    logic [REQ_CNT_W-1:0] req_count_q;
    logic req_push, req_pop, req_fifo_push;
    logic direct_start;

    logic [31:0] q_head_addr;
    logic [63:0] q_head_data;
    logic [7:0]  q_head_strb;
    logic [31:0] q_head_aligned;
    logic q_head_lane;
    logic q_head_aligned_ok;
    logic q_head_end;

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

    // Empty FIFO guarantees request capacity. Derive this term without
    // req_ready/req_pop, including when full-FIFO pop/refill is enabled.
    // Older logical responses may remain in the response FIFO; they keep
    // their order, and this descriptor still waits for real B before emitting.
    assign direct_start = USE_REQUEST_END && !rst && state_q==ST_IDLE &&
                          req_count_q==0 && req_valid && req_end;
    assign q_head_addr = direct_start ? req_addr : req_addr_mem[req_head_q];
    assign q_head_data = direct_start ? req_wdata : req_data_mem[req_head_q];
    assign q_head_strb = direct_start ? req_wstrb : req_strb_mem[req_head_q];
    assign q_head_end = direct_start ? req_end : req_end_mem[req_head_q];
    assign q_head_aligned = {q_head_addr[31:4], 4'b0};
    assign q_head_lane = q_head_addr[3];
    assign q_head_aligned_ok = (q_head_addr[2:0] == 3'b000);

    assign req_ready = !rst &&
                       ((req_count_q < REQ_FIFO_DEPTH) ||
                        (ALLOW_REQ_POP_REFILL && req_pop));
    assign req_push = req_valid && req_ready;
    assign req_fifo_push = req_push && !direct_start;

    // ------------------------------------------------------------------
    // One burst builder/transaction descriptor.
    // ------------------------------------------------------------------
    logic [31:0] build_base_q;
    logic [BEAT_CNT_W-1:0] build_beats_q;
    logic [LOGICAL_CNT_W-1:0] build_req_count_q;
    logic [AGE_W-1:0] build_age_q;
    logic build_local_q;
    logic build_error_q;

    logic build_lane0_present_q [0:BURST_BEATS-1];
    logic build_lane1_present_q [0:BURST_BEATS-1];
    // Number of logical writes represented by each physical beat.  Keeping
    // this separate from the presence bits prevents a third identical
    // same-lane request from being appended indefinitely.
    logic [1:0] build_lane_count_q [0:BURST_BEATS-1];
    logic [63:0] build_lane0_data_q [0:BURST_BEATS-1];
    logic [63:0] build_lane1_data_q [0:BURST_BEATS-1];
    logic [7:0]  build_lane0_strb_q [0:BURST_BEATS-1];
    logic [7:0]  build_lane1_strb_q [0:BURST_BEATS-1];
    logic [63:0] build_order_data_q [0:MAX_LOGICAL-1];

    logic [BEAT_IDX_W-1:0] current_beat_idx;
    logic [32:0] build_last_addr_wide;
    logic [32:0] build_next_addr_wide;
    logic same_beat, next_beat;
    logic current_lane0_only, current_lane1_only;
    logic same_lane_payload_equal;
    logic append_legal;
    logic build_start;
    logic build_append;
    logic build_close;

    assign current_beat_idx = (build_beats_q == 0) ? '0 :
                              build_beats_q - 1'b1;
    assign build_last_addr_wide = {1'b0, build_base_q} +
        ((build_beats_q == 0) ? 33'd0 :
         (({28'd0, build_beats_q} - 1'b1) << 4));
    assign build_next_addr_wide = {1'b0, build_base_q} +
                                  ({28'd0, build_beats_q} << 4);
    assign same_beat = (state_q == ST_BUILD) && (build_beats_q != 0) &&
                       ({1'b0, q_head_aligned} == build_last_addr_wide);
    assign next_beat = (state_q == ST_BUILD) && (build_beats_q != 0) &&
                       (build_beats_q < BURST_BEATS) &&
                       !build_next_addr_wide[32] &&
                       ({1'b0, q_head_aligned} == build_next_addr_wide) &&
                       (q_head_aligned[31:12] == build_base_q[31:12]);
    assign current_lane0_only = (build_lane_count_q[current_beat_idx] == 1) &&
                                build_lane0_present_q[current_beat_idx] &&
                                !build_lane1_present_q[current_beat_idx];
    assign current_lane1_only = (build_lane_count_q[current_beat_idx] == 1) &&
                                build_lane1_present_q[current_beat_idx] &&
                                !build_lane0_present_q[current_beat_idx];
    assign same_lane_payload_equal =
        (q_head_lane == 1'b0) ?
        (current_lane0_only &&
         (q_head_data == build_lane0_data_q[current_beat_idx]) &&
         (q_head_strb == build_lane0_strb_q[current_beat_idx])) :
        (current_lane1_only &&
         (q_head_data == build_lane1_data_q[current_beat_idx]) &&
         (q_head_strb == build_lane1_strb_q[current_beat_idx]));

    // A same-beat append is legal for the missing lane.  A duplicate lane is
    // legal only when explicitly enabled *and* its payload is identical; a
    // 128-bit W beat cannot carry two different values for one lane.
    assign append_legal = (state_q == ST_BUILD) && (req_count_q != 0) &&
        q_head_aligned_ok &&
        ((same_beat && (current_lane0_only || current_lane1_only) &&
          ((!q_head_lane && current_lane1_only) ||
           (q_head_lane && current_lane0_only) ||
           (ALLOW_SAME_LANE_DUP && same_lane_payload_equal))) ||
         next_beat);

    assign build_start = (state_q == ST_IDLE) && ((req_count_q != 0) || direct_start);
    assign build_append = append_legal && !req_flush && !build_end_q;
    assign build_close = (state_q == ST_BUILD) && !build_append &&
                         (req_flush || build_end_q ||
                          (!append_legal &&
                           ((req_count_q != 0) ||
                            (build_age_q >= BUILD_TIMEOUT_CYCLES-1))));
    assign req_pop = (build_start && !direct_start) || build_append;

    // ------------------------------------------------------------------
    // Response FIFO.  Responses are emitted one logical write per cycle
    // after B, so the implementation does not need a multi-write RAM port.
    // ------------------------------------------------------------------
    logic [63:0] rsp_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_err_mem [0:RSP_FIFO_DEPTH-1];
    logic [RSP_PTR_W-1:0] rsp_head_q, rsp_tail_q;
    logic [RSP_CNT_W-1:0] rsp_count_q;
    logic [LOGICAL_CNT_W-1:0] rsp_emit_idx_q;
    logic rsp_pop;
    logic rsp_space;
    logic rsp_push;
    logic rsp_last_push;

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

    assign rsp_valid = !rst && (rsp_count_q != 0);
    assign rsp_error = rsp_valid ? rsp_err_mem[rsp_head_q] : 1'b0;
    assign rsp_rdata = rsp_valid ? rsp_mem[rsp_head_q] : 64'd0;
    assign rsp_pop = rsp_valid && rsp_ready;

    // Keep BREADY independent of the downstream pop/ready signal.  The
    // previous "free_slots + rsp_pop" form made the wrapper's response tag
    // FIFO feed a wide arithmetic/carry chain and then return through BREADY
    // into the leaf FSM.  That path was the timing limiter in the two-lane
    // fabric (tag_mem -> rsp_pop -> free_slots -> BREADY).  A conservative
    // full/not-full test is safe: when the FIFO is full we may insert one
    // bubble even if a response is consumed in the same cycle, but we never
    // accept a B response without a reserved FIFO entry.
    assign rsp_space = (rsp_count_q < RSP_FIFO_DEPTH);

    assign rsp_push = (state_q == ST_RESP) && rsp_space;
    assign rsp_last_push = rsp_push &&
                           (rsp_emit_idx_q == build_req_count_q - 1'b1);

    // ------------------------------------------------------------------
    // AXI write channel outputs.
    // ------------------------------------------------------------------
    logic [BEAT_IDX_W-1:0] w_beat_q;
    logic aw_fire, w_fire, b_fire;
    logic aw_done_q, w_done_q;
    logic [127:0] w_data_comb;
    logic [15:0] w_strb_comb;

    always_comb begin
        m_axi_awaddr = build_base_q;
        m_axi_awlen = (build_beats_q == 0) ? 8'd0 :
                      build_beats_q - 1'b1;
        m_axi_awsize = 3'd4;
        m_axi_awburst = 2'b01;
        m_axi_awvalid = !rst && (state_q == ST_AW) && !build_local_q && !aw_done_q;

        w_data_comb = 128'd0;
        w_strb_comb = 16'd0;
        if (state_q == ST_AW) begin
            if (build_lane0_present_q[w_beat_q]) begin
                w_data_comb[63:0] = build_lane0_data_q[w_beat_q];
                w_strb_comb[7:0] = build_lane0_strb_q[w_beat_q];
            end
            if (build_lane1_present_q[w_beat_q]) begin
                w_data_comb[127:64] = build_lane1_data_q[w_beat_q];
                w_strb_comb[15:8] = build_lane1_strb_q[w_beat_q];
            end
        end
        m_axi_wdata = w_data_comb;
        m_axi_wstrb = w_strb_comb;
        m_axi_wlast = (state_q == ST_AW) &&
                      (w_beat_q == (build_beats_q - 1'b1));
        m_axi_wvalid = !rst && (state_q == ST_AW) && !build_local_q && !w_done_q;
        m_axi_bready = !rst && (state_q == ST_B) && rsp_space;
    end

    assign aw_fire = m_axi_awvalid && m_axi_awready;
    assign w_fire = m_axi_wvalid && m_axi_wready;
    assign b_fire = m_axi_bvalid && m_axi_bready;

    assign perf_busy = (state_q != ST_IDLE) || (req_count_q != 0) ||
                       (rsp_count_q != 0);
    assign perf_req_occupancy = req_count_q;
    assign perf_outstanding = (((state_q == ST_AW) && aw_done_q) || (state_q == ST_B)) ?
                               8'd1 : 8'd0;

    // ------------------------------------------------------------------
    // State and storage updates.
    // ------------------------------------------------------------------
    integer init_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            req_head_q <= '0;
            req_tail_q <= '0;
            req_count_q <= '0;
            build_base_q <= '0;
            build_beats_q <= '0;
            build_req_count_q <= '0;
            build_age_q <= '0;
            build_end_q <= 1'b0;
            build_local_q <= 1'b0;
            build_error_q <= 1'b0;
            w_beat_q <= '0;
            aw_done_q <= 1'b0;
            w_done_q <= 1'b0;
            rsp_head_q <= '0;
            rsp_tail_q <= '0;
            rsp_count_q <= '0;
            rsp_emit_idx_q <= '0;
            perf_req_accept_count <= 64'd0;
            perf_axi_burst_count <= 64'd0;
            perf_axi_beat_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_packed_request_count <= 64'd0;
            perf_error_count <= 64'd0;
            perf_max_req_occupancy <= 8'd0;
            perf_max_outstanding <= 8'd0;
            for (init_i = 0; init_i < BURST_BEATS; init_i = init_i + 1) begin
                build_lane0_present_q[init_i] <= 1'b0;
                build_lane1_present_q[init_i] <= 1'b0;
                build_lane_count_q[init_i] <= 2'd0;
                build_lane0_data_q[init_i] <= 64'd0;
                build_lane1_data_q[init_i] <= 64'd0;
                build_lane0_strb_q[init_i] <= 8'd0;
                build_lane1_strb_q[init_i] <= 8'd0;
            end
            for (init_i = 0; init_i < MAX_LOGICAL; init_i = init_i + 1)
                build_order_data_q[init_i] <= 64'd0;
        end else begin
            // Request FIFO push/pop accounting.
            if (req_push)
                perf_req_accept_count <= perf_req_accept_count + 1'b1;
            if (req_fifo_push) begin
                req_addr_mem[req_tail_q] <= req_addr;
                req_data_mem[req_tail_q] <= req_wdata;
                req_strb_mem[req_tail_q] <= req_wstrb;
                req_end_mem[req_tail_q] <= USE_REQUEST_END && req_end;
                req_tail_q <= req_ptr_add(req_tail_q, 1);
            end
            if (req_pop)
                req_head_q <= req_ptr_add(req_head_q, 1);
            case ({req_fifo_push, req_pop})
                2'b10: req_count_q <= req_count_q + 1'b1;
                2'b01: req_count_q <= req_count_q - 1'b1;
                default: req_count_q <= req_count_q;
            endcase
            // A full-FIFO pop/push keeps occupancy at REQ_FIFO_DEPTH.  Do not
            // report a fictitious DEPTH+1 maximum in that optional mode.
            if (req_fifo_push && !req_pop &&
                ((req_count_q + 1'b1) > perf_max_req_occupancy))
                perf_max_req_occupancy <= req_count_q + 1'b1;

            case (state_q)
                ST_IDLE: begin
                    if (build_start) begin
                        // Clear the lane metadata for the new descriptor;
                        // payload arrays are only read when present=1.
                        for (init_i = 0; init_i < BURST_BEATS;
                             init_i = init_i + 1) begin
                            build_lane0_present_q[init_i] <= 1'b0;
                            build_lane1_present_q[init_i] <= 1'b0;
                            build_lane_count_q[init_i] <= 2'd0;
                        end
                        build_base_q <= q_head_aligned;
                        build_beats_q <= 1;
                        build_req_count_q <= 1;
                        build_age_q <= '0;
                        build_end_q <= USE_REQUEST_END && q_head_end;
                        // A local-error descriptor enters ST_RESP directly;
                        // reset the response token index here as well as on
                        // the normal B handshake path.
                        rsp_emit_idx_q <= '0;
                        build_order_data_q[0] <= q_head_data;
                        if (q_head_lane == 1'b0) begin
                            build_lane0_present_q[0] <= 1'b1;
                            build_lane0_data_q[0] <= q_head_data;
                            build_lane0_strb_q[0] <= q_head_strb;
                        end else begin
                            build_lane1_present_q[0] <= 1'b1;
                            build_lane1_data_q[0] <= q_head_data;
                            build_lane1_strb_q[0] <= q_head_strb;
                        end
                        build_lane_count_q[0] <= 2'd1;
                        if (q_head_addr[2:0] != 3'b000) begin
                            // Keep one ordered local error response and do
                            // not issue an illegal AXI address.
                            build_local_q <= 1'b1;
                            build_error_q <= 1'b1;
                            build_base_q <= 32'd0;
                            state_q <= ST_RESP;
                        end else begin
                            build_local_q <= 1'b0;
                            build_error_q <= 1'b0;
                            if (USE_REQUEST_END && q_head_end) begin
                                // A one-request terminated descriptor is
                                // already complete; do not spend a BUILD
                                // cycle rediscovering its registered end bit.
                                w_beat_q <= '0;
                                aw_done_q <= 1'b0;
                                w_done_q <= 1'b0;
                                state_q <= ST_AW;
                            end else state_q <= ST_BUILD;
                        end
                    end
                end

                ST_BUILD: begin
                    if (build_append) begin
                        build_end_q <= USE_REQUEST_END && q_head_end;
                        build_req_count_q <= build_req_count_q + 1'b1;
                        build_order_data_q[build_req_count_q] <= q_head_data;
                        build_age_q <= '0;
                        if (same_beat) begin
                            if (q_head_lane == 1'b0) begin
                                build_lane0_present_q[current_beat_idx] <= 1'b1;
                                build_lane0_data_q[current_beat_idx] <= q_head_data;
                                build_lane0_strb_q[current_beat_idx] <= q_head_strb;
                            end else begin
                                build_lane1_present_q[current_beat_idx] <= 1'b1;
                                build_lane1_data_q[current_beat_idx] <= q_head_data;
                                build_lane1_strb_q[current_beat_idx] <= q_head_strb;
                            end
                            build_lane_count_q[current_beat_idx] <= 2'd2;
                        end else begin
                            if (q_head_lane == 1'b0) begin
                                build_lane0_present_q[build_beats_q] <= 1'b1;
                                build_lane0_data_q[build_beats_q] <= q_head_data;
                                build_lane0_strb_q[build_beats_q] <= q_head_strb;
                            end else begin
                                build_lane1_present_q[build_beats_q] <= 1'b1;
                                build_lane1_data_q[build_beats_q] <= q_head_data;
                                build_lane1_strb_q[build_beats_q] <= q_head_strb;
                            end
                            build_lane_count_q[build_beats_q] <= 2'd1;
                            build_beats_q <= build_beats_q + 1'b1;
                        end
                        if (USE_REQUEST_END && q_head_end) begin
                            // Include the just-consumed item in the packing
                            // count: a same-beat append saves one more beat;
                            // a next-beat append increments both quantities.
                            perf_packed_request_count <= perf_packed_request_count +
                                (build_req_count_q - build_beats_q) +
                                (same_beat ? 64'd1 : 64'd0);
                            w_beat_q <= '0;
                            aw_done_q <= 1'b0;
                            w_done_q <= 1'b0;
                            state_q <= ST_AW;
                        end
                    end else if (build_close) begin
                        if (build_req_count_q > build_beats_q)
                            perf_packed_request_count <=
                                perf_packed_request_count +
                                (build_req_count_q - build_beats_q);
                        w_beat_q <= '0;
                        aw_done_q <= 1'b0;
                        w_done_q <= 1'b0;
                        state_q <= ST_AW;
                    end else if (build_age_q < BUILD_TIMEOUT_CYCLES-1) begin
                        build_age_q <= build_age_q + 1'b1;
                    end
                end

                ST_AW: begin
                    if (aw_fire) begin
                        perf_axi_burst_count <= perf_axi_burst_count + 1'b1;
                        if (perf_max_outstanding < 1)
                            perf_max_outstanding <= 8'd1;
                        aw_done_q <= 1'b1;
                    end
                    // The complete burst is already buffered. W must not
                    // depend on downstream AWREADY. Retain either completed
                    // channel until the other finishes, then accept B.
                    if (w_fire) begin
                        perf_axi_beat_count <= perf_axi_beat_count + 1'b1;
                        if (m_axi_wlast) begin
                            w_done_q <= 1'b1;
                        end else begin
                            w_beat_q <= w_beat_q + 1'b1;
                        end
                    end
                    if ((aw_done_q || aw_fire) &&
                        (w_done_q || (w_fire && m_axi_wlast)))
                        state_q <= ST_B;
                end

                ST_B: begin
                    if (b_fire) begin
                        build_error_q <= (m_axi_bresp != 2'b00);
                        rsp_emit_idx_q <= '0;
                        state_q <= ST_RESP;
                    end
                end

                ST_RESP: begin
                    if (rsp_push) begin
                        // Keep the original logical payload available even
                        // when BRESP reports an error; rsp_error carries the
                        // status bit and ordering remains unchanged.
                        rsp_mem[rsp_tail_q] <= build_local_q ? 64'd0 :
                                               build_order_data_q[rsp_emit_idx_q];
                        rsp_err_mem[rsp_tail_q] <= build_error_q;
                        if (build_error_q)
                            perf_error_count <= perf_error_count + 1'b1;
                        rsp_emit_idx_q <= rsp_emit_idx_q + 1'b1;
                        if (rsp_last_push) begin
                            state_q <= ST_IDLE;
                            build_local_q <= 1'b0;
                        end
                    end
                end

                default: state_q <= ST_IDLE;
            endcase

            // Response FIFO count and pointers.  A response push and local
            // consumer pop may occur in the same clock.
            if (rsp_push)
                rsp_tail_q <= rsp_ptr_add(rsp_tail_q, 1);
            if (rsp_pop) begin
                rsp_head_q <= rsp_ptr_add(rsp_head_q, 1);
                perf_rsp_count <= perf_rsp_count + 1'b1;
            end
            case ({rsp_push, rsp_pop})
                2'b10: rsp_count_q <= rsp_count_q + 1'b1;
                2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                default: rsp_count_q <= rsp_count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    logic [44:0] aw_payload_q;
    logic aw_stalled_q;
    // 128-bit data + 16-bit strobe + WLAST is 145 bits.  Keeping the full
    // concatenation is important: truncating bit 144 causes a false VALID
    // hold failure whenever the payload's top bit changes (or WLAST toggles).
    logic [144:0] w_payload_q;
    logic w_stalled_q;
    logic b_stalled_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_stalled_q <= 1'b0;
            w_stalled_q <= 1'b0;
            b_stalled_q <= 1'b0;
        end else begin
            if(direct_start && (!req_push || req_fifo_push || req_pop ||
                               req_count_q!=0 || state_q!=ST_IDLE))
                $fatal(1,"direct write intake violated FIFO ownership");
            if(req_count_q>REQ_FIFO_DEPTH || (req_pop && req_count_q==0))
                $fatal(1,"write request FIFO overflow/underflow");
            if ((state_q == ST_BUILD) &&
                (build_req_count_q > (build_beats_q << 1)))
                $fatal(1, "write burst client exceeded two logical writes per beat");
            if (aw_stalled_q &&
                (!m_axi_awvalid ||
                 ({m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst} !=
                  aw_payload_q)))
                $fatal(1, "write burst client changed stalled AW payload");
            if (w_stalled_q &&
                (!m_axi_wvalid ||
                 ({m_axi_wdata,m_axi_wstrb,m_axi_wlast} != w_payload_q)))
                $fatal(1, "write burst client changed stalled W payload");
            if (b_stalled_q && !m_axi_bvalid)
                $fatal(1, "write burst client withdrew stalled B payload");
            aw_stalled_q <= m_axi_awvalid && !m_axi_awready;
            aw_payload_q <= {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            w_stalled_q <= m_axi_wvalid && !m_axi_wready;
            w_payload_q <= {m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            b_stalled_q <= m_axi_bvalid && !m_axi_bready;
            if (m_axi_awvalid && m_axi_awready &&
                ({1'b0,m_axi_awaddr[11:0]} +
                 ({8'd0,m_axi_awlen}+1'b1)*13'd16 > 13'd4096))
                $fatal(1, "write burst client crossed 4KiB boundary");
            if (m_axi_awvalid && m_axi_awready &&
                (m_axi_awaddr[3:0] != 4'b0000))
                $fatal(1, "write burst client issued unaligned AW");
        end
    end
`endif

endmodule
