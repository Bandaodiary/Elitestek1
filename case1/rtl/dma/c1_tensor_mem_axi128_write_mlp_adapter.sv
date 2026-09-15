`timescale 1ns/1ps

// Board-independent logical-write front end for c1_axi128_write_mlp.
//
// The legacy tensor path presents one 64-bit write at a time.  The
// burst-level MLP seam, on the other hand, deliberately accepts a descriptor
// followed by complete 128-bit beats.  This adapter is the missing boardless
// contract between those two interfaces:
//
//   * software (or a tensor scheduler) opens a bounded descriptor with a
//     16-byte aligned base and a logical-word count;
//   * the following logical stream is checked for contiguous 8-byte
//     addresses and packed two words per AXI128 beat;
//   * complete descriptors are buffered in a small ring and fed to
//     c1_axi128_write_mlp, allowing command descriptors for later frames to
//     be accepted while an earlier payload is still being streamed.  The
//     payload stream itself remains strictly descriptor ordered, as required
//     by the ID-less backend;
//   * one ordered logical response is emitted for each captured word.
//
// This is an optional seam.  It intentionally does not alter the default
// portable SoC or claim that a descriptor ring alone solves the native
// 640x480 deadline.  The payload memories are not reset so a vendor flow can
// infer EBR/BRAM; words are only read after the corresponding stream writes
// have completed.
module c1_tensor_mem_axi128_write_mlp_adapter #(
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer MAX_BEATS = 16,
    parameter integer RSP_FIFO_DEPTH = MAX_OUTSTANDING,
    parameter integer TAG_WIDTH = 16,
    // Optional backend mode: issue a valid descriptor's AXI AW as soon as
    // its command is accepted, before the logical payload has finished
    // packing.  The backend still holds W until the complete frame is
    // captured and zero-fills missing beats on malformed frames.  Default
    // zero retains the conservative payload-complete-before-AW contract.
    parameter bit ISSUE_AW_BEFORE_PAYLOAD = 1'b0,
    // Forward the optional backend response-FIFO pop/refill path.  It is
    // disabled by default so the adapter's portable timing contract remains
    // unchanged.
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Descriptor command.  cmd_logical_count is 1..(2*MAX_BEATS).
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [31:0]                  cmd_addr,
    input  logic [9:0]                   cmd_logical_count,

    // Logical payload stream in descriptor order.  req_last is checked but
    // the declared count remains the bounded storage contract.  req_flush
    // terminates the current frame with a local error and is intended as a
    // one-cycle pulse.
    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic                         req_last,
    input  logic                         req_flush,
    input  logic [31:0]                  req_addr,
    input  logic [63:0]                  req_wdata,
    input  logic [7:0]                   req_wstrb,

    // Ordered logical responses.  rsp_tag is constant for all words in one
    // descriptor and increments at descriptor acceptance.
    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_error,
    output logic [63:0]                  rsp_rdata,
    output logic [TAG_WIDTH-1:0]         rsp_tag,

    // AXI4-128 write channel.
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

    // Framing/address diagnostics are sticky until reset.
    output logic                         protocol_error,
    output logic                         early_req_last_error,
    output logic                         late_req_last_error,
    output logic                         req_flush_error,
    output logic                         orphan_req_error,
    output logic                         request_address_error,

    // Compact performance counters.
    output logic                         perf_busy,
    output logic [63:0]                  perf_cmd_accept_count,
    output logic [63:0]                  perf_logical_req_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_packed_pair_count,
    output logic [63:0]                  perf_error_count,
    output logic [7:0]                   perf_cmd_occupancy,
    output logic [7:0]                   perf_max_cmd_occupancy,
    output logic [7:0]                   perf_outstanding,
    output logic [7:0]                   perf_max_outstanding
);

    localparam integer MAX_LOGICAL = 2 * MAX_BEATS;
    localparam integer PTR_W = (MAX_OUTSTANDING <= 1) ? 1 :
                               $clog2(MAX_OUTSTANDING);
    localparam integer CNT_W = (MAX_OUTSTANDING <= 1) ? 1 :
                               $clog2(MAX_OUTSTANDING + 1);
    localparam integer BEAT_PTR_W = (MAX_BEATS <= 1) ? 1 :
                                    $clog2(MAX_BEATS);
    localparam integer COUNT_W = (MAX_LOGICAL <= 1) ? 1 :
                                 $clog2(MAX_LOGICAL + 1);

    initial begin
        if (MAX_OUTSTANDING < 2 || MAX_OUTSTANDING > 255)
            $fatal(1, "MAX_OUTSTANDING must be in the range 2..255");
        if (MAX_BEATS < 1 || MAX_BEATS > 256)
            $fatal(1, "MAX_BEATS must be in the range 1..256");
        if (RSP_FIFO_DEPTH < 2 || RSP_FIFO_DEPTH > 255)
            $fatal(1, "RSP_FIFO_DEPTH must be in the range 2..255");
        if (TAG_WIDTH < 1)
            $fatal(1, "TAG_WIDTH must be positive");
    end

    // ------------------------------------------------------------------
    // Descriptor ring and payload storage.
    // ------------------------------------------------------------------
    logic [31:0] slot_addr_mem [0:MAX_OUTSTANDING-1];
    logic [COUNT_W-1:0] slot_logical_mem [0:MAX_OUTSTANDING-1];
    logic [8:0] slot_beats_mem [0:MAX_OUTSTANDING-1];
    logic [COUNT_W-1:0] slot_resp_count_mem [0:MAX_OUTSTANDING-1];
    logic [TAG_WIDTH-1:0] slot_tag_mem [0:MAX_OUTSTANDING-1];
    logic slot_valid_mem [0:MAX_OUTSTANDING-1];
    logic slot_fill_done_mem [0:MAX_OUTSTANDING-1];
    logic slot_cmd_sent_mem [0:MAX_OUTSTANDING-1];
    // Backend command acceptance and payload delivery are intentionally
    // tracked separately.  A command may be queued ahead of W/B, but its
    // complete payload still has to be delivered in allocation order.
    logic slot_payload_sent_mem [0:MAX_OUTSTANDING-1];
    // Per-beat capture map.  It is only needed to make the speculative
    // AW-before-payload mode deterministic: a short/flush frame must retain
    // the beats that were actually captured and zero-fill the uncaptured
    // tail, rather than replaying stale data from a reused RAM slot.
    logic [MAX_BEATS-1:0] slot_payload_valid_mem [0:MAX_OUTSTANDING-1];
    // Command-time poison is immutable while backend_cmd_valid is stalled.
    // Payload framing/address errors are accumulated separately below and
    // must never change the AW payload under VALID hold.
    logic slot_cmd_error_mem [0:MAX_OUTSTANDING-1];
    logic slot_local_error_mem [0:MAX_OUTSTANDING-1];

    // Keep the original logical payload for ordered response echoing.  The
    // attributes are hints only; the Efinity implementation must still be
    // checked for EBR port/latency inference.
    (* ram_style = "block" *)
    logic [63:0] logical_data_mem [0:MAX_OUTSTANDING-1][0:MAX_LOGICAL-1];
    (* ram_style = "block" *)
    logic [127:0] payload_mem [0:MAX_OUTSTANDING-1][0:MAX_BEATS-1];
    (* ram_style = "block" *)
    logic [15:0] payload_strb_mem [0:MAX_OUTSTANDING-1][0:MAX_BEATS-1];

    logic [PTR_W-1:0] alloc_tail_q;
    logic [PTR_W-1:0] fill_ptr_q;
    logic [PTR_W-1:0] issue_ptr_q;
    logic [PTR_W-1:0] feed_ptr_q;
    logic [PTR_W-1:0] response_ptr_q;
    logic [CNT_W-1:0] slot_count_q;
    logic [CNT_W-1:0] fill_count_q;
    logic [COUNT_W-1:0] fill_index_q;
    logic [TAG_WIDTH-1:0] next_tag_q;

    function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] value);
        integer tmp;
        begin
            tmp = value + 1;
            if (tmp >= MAX_OUTSTANDING)
                tmp = 0;
            ptr_inc = tmp[PTR_W-1:0];
        end
    endfunction

    function automatic [COUNT_W-1:0] clamp_logical(
        input [9:0] value
    );
        begin
            if (value == 0)
                clamp_logical = {{(COUNT_W-1){1'b0}},1'b1};
            else if (value > MAX_LOGICAL)
                clamp_logical = MAX_LOGICAL[COUNT_W-1:0];
            else
                clamp_logical = value[COUNT_W-1:0];
        end
    endfunction

    logic [COUNT_W-1:0] cmd_logical_eff;
    logic [8:0] cmd_beats_eff;
    logic [12:0] cmd_end_offset;
    logic cmd_cross_4k;
    logic cmd_local_error;
    logic cmd_fire;

    always_comb begin
        cmd_logical_eff = clamp_logical(cmd_logical_count);
        cmd_beats_eff = (cmd_logical_eff + 1'b1) >> 1;
        cmd_end_offset = ({3'd0, cmd_logical_eff} << 3);
        cmd_cross_4k = ({1'b0, cmd_addr[11:0]} + cmd_end_offset > 13'd4096);
        cmd_local_error = (cmd_addr[3:0] != 4'b0000) ||
                          (cmd_logical_count == 0) ||
                          (cmd_logical_count > MAX_LOGICAL) ||
                          cmd_cross_4k;
    end

    assign cmd_ready = !rst && (slot_count_q < MAX_OUTSTANDING);
    assign cmd_fire = cmd_valid && cmd_ready;

    // ------------------------------------------------------------------
    // Logical frame capture and pack2.
    // ------------------------------------------------------------------
    logic fill_available;
    logic req_fire;
    logic req_expected_last;
    logic req_early_last;
    logic req_late_last;
    logic req_flush_finish;
    logic frame_finish;
    logic req_addr_bad;
    logic [32:0] req_expected_addr_wide;

    assign fill_available = (fill_count_q != 0) &&
                            slot_valid_mem[fill_ptr_q] &&
                            !slot_fill_done_mem[fill_ptr_q];
    assign req_ready = !rst && fill_available;
    assign req_fire = req_valid && req_ready;
    assign req_expected_last =
        (fill_index_q == (slot_logical_mem[fill_ptr_q] - 1'b1));
    assign req_early_last = req_fire && req_last && !req_expected_last;
    assign req_late_last = req_fire && !req_last && req_expected_last;
    assign req_flush_finish = req_flush && fill_available;
    assign frame_finish = req_flush_finish || req_early_last ||
                          req_late_last || (req_fire && req_expected_last);
    assign req_expected_addr_wide = {1'b0, slot_addr_mem[fill_ptr_q]} +
                                    ({21'd0, fill_index_q} << 3);
    assign req_addr_bad = req_fire &&
                          ({1'b0, req_addr} != req_expected_addr_wide);

    // ------------------------------------------------------------------
    // Feed the packed descriptors to the burst-level MLP seam.
    // ------------------------------------------------------------------
    logic backend_cmd_valid, backend_cmd_ready;
    logic [31:0] backend_cmd_addr;
    logic [8:0] backend_cmd_beats;
    logic backend_payload_valid, backend_payload_ready;
    logic [127:0] backend_payload_data;
    logic [15:0] backend_payload_strb;
    logic backend_payload_last;
    logic backend_rsp_valid, backend_rsp_ready, backend_rsp_error;
    logic [31:0] backend_rsp_addr;
    logic [8:0] backend_rsp_beats;
    logic [TAG_WIDTH-1:0] backend_rsp_tag;
    logic backend_protocol_error;
    logic backend_early_payload_last_error, backend_late_payload_last_error;
    logic backend_payload_flush_error, backend_orphan_payload_error;
    logic backend_early_b_error, backend_orphan_b_error;
    logic backend_busy;
    logic [63:0] backend_cmd_count, backend_payload_count;
    logic [63:0] backend_burst_count, backend_axi_beat_count;
    logic [63:0] backend_aw_count, backend_rsp_count, backend_error_count;
    logic [63:0] backend_aw_stall_count, backend_w_stall_count;
    logic [63:0] backend_b_stall_count;
    logic [7:0] backend_cmd_occupancy, backend_max_cmd_occupancy;
    logic [7:0] backend_outstanding, backend_max_outstanding;

    logic feed_active_q;
    logic [PTR_W-1:0] feed_slot_q;
    logic [BEAT_PTR_W-1:0] feed_beat_q;
    logic issue_candidate;
    logic feed_candidate;
    logic backend_cmd_fire;
    logic backend_payload_fire;

    // Command issue is independent from payload feeding.  Keeping the issue
    // pointer separate lets several already-filled descriptors enter the
    // backend ring while the payload feeder is occupied with an older slot.
    // Both pointers advance strictly in allocation order; no reordering is
    // introduced at the ID-less AXI boundary.
    assign issue_candidate = !rst &&
                             (slot_count_q != 0) &&
                             slot_valid_mem[issue_ptr_q] &&
                             (ISSUE_AW_BEFORE_PAYLOAD ?
                              1'b1 : slot_fill_done_mem[issue_ptr_q]) &&
                             !slot_cmd_sent_mem[issue_ptr_q];
    assign backend_cmd_valid = issue_candidate;
    // A poisoned (misframed/address-invalid) slot is still sent through the
    // backend, but its address is made unaligned so no partial AXI write can
    // escape before the ordered local error response.
    assign backend_cmd_addr = ((ISSUE_AW_BEFORE_PAYLOAD ?
                                slot_cmd_error_mem[issue_ptr_q] :
                                slot_local_error_mem[issue_ptr_q])) ?
                              (slot_addr_mem[issue_ptr_q] | 32'd1) :
                              slot_addr_mem[issue_ptr_q];
    assign backend_cmd_beats = slot_beats_mem[issue_ptr_q];
    assign backend_cmd_fire = backend_cmd_valid && backend_cmd_ready;

    // Payloads are consumed only after their matching backend command has
    // been accepted.  This allows command issue and payload streaming to
    // overlap, while preserving the backend's descriptor-order fill contract.
    assign feed_candidate = !rst && !feed_active_q &&
                            (slot_count_q != 0) &&
                            slot_valid_mem[feed_ptr_q] &&
                            slot_cmd_sent_mem[feed_ptr_q] &&
                            // The backend owns a complete burst payload.  In
                            // ISSUE_AW_BEFORE_PAYLOAD mode AW may be issued
                            // early, but feeding an unfinished slot here
                            // would read stale payload RAM and violate the
                            // descriptor stream contract.  Keep W/response
                            // overlap while waiting for the frame boundary.
                            slot_fill_done_mem[feed_ptr_q] &&
                            !slot_payload_sent_mem[feed_ptr_q];

    always_comb begin
        backend_payload_valid = feed_active_q;
        backend_payload_data = 128'd0;
        backend_payload_strb = 16'd0;
        backend_payload_last = 1'b0;
        if (feed_active_q) begin
            if (slot_payload_valid_mem[feed_slot_q][feed_beat_q]) begin
                backend_payload_data = payload_mem[feed_slot_q][feed_beat_q];
                backend_payload_strb = payload_strb_mem[feed_slot_q][feed_beat_q];
            end
            backend_payload_last =
                (feed_beat_q == (slot_beats_mem[feed_slot_q] - 1'b1));
        end
    end
    assign backend_payload_fire = backend_payload_valid &&
                                  backend_payload_ready;

    c1_axi128_write_mlp #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .TAG_WIDTH(TAG_WIDTH),
        .ISSUE_AW_BEFORE_PAYLOAD(ISSUE_AW_BEFORE_PAYLOAD),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL)
    ) u_backend (
        .clk(clk), .rst(rst),
        .cmd_valid(backend_cmd_valid), .cmd_ready(backend_cmd_ready),
        .cmd_addr(backend_cmd_addr), .cmd_beats(backend_cmd_beats),
        .payload_valid(backend_payload_valid),
        .payload_ready(backend_payload_ready),
        .payload_data(backend_payload_data),
        .payload_strb(backend_payload_strb),
        .payload_last(backend_payload_last),
        .payload_flush(1'b0),
        .rsp_valid(backend_rsp_valid), .rsp_ready(backend_rsp_ready),
        .rsp_error(backend_rsp_error), .rsp_addr(backend_rsp_addr),
        .rsp_beats(backend_rsp_beats), .rsp_tag(backend_rsp_tag),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .protocol_error(backend_protocol_error),
        .early_payload_last_error(backend_early_payload_last_error),
        .late_payload_last_error(backend_late_payload_last_error),
        .payload_flush_error(backend_payload_flush_error),
        .orphan_payload_error(backend_orphan_payload_error),
        .early_b_error(backend_early_b_error),
        .orphan_b_error(backend_orphan_b_error),
        .perf_busy(backend_busy),
        .perf_cmd_accept_count(backend_cmd_count),
        .perf_payload_beat_count(backend_payload_count),
        .perf_axi_burst_count(backend_burst_count),
        .perf_axi_beat_count(backend_axi_beat_count),
        .perf_aw_issue_count(backend_aw_count),
        .perf_rsp_count(backend_rsp_count),
        .perf_error_count(backend_error_count),
        .perf_aw_stall_count(backend_aw_stall_count),
        .perf_w_stall_count(backend_w_stall_count),
        .perf_b_stall_count(backend_b_stall_count),
        .perf_cmd_occupancy(backend_cmd_occupancy),
        .perf_max_cmd_occupancy(backend_max_cmd_occupancy),
        .perf_outstanding(backend_outstanding),
        .perf_max_outstanding(backend_max_outstanding)
    );

    // ------------------------------------------------------------------
    // Ordered logical response expansion.
    // ------------------------------------------------------------------
    logic response_active_q;
    logic [PTR_W-1:0] response_slot_q;
    logic [COUNT_W-1:0] response_index_q;
    logic response_backend_error_q;
    logic backend_rsp_fire;
    logic rsp_fire;
    logic response_last_fire;

    assign backend_rsp_ready = !response_active_q;
    assign backend_rsp_fire = backend_rsp_valid && backend_rsp_ready;
    assign rsp_valid = !rst && response_active_q;
    assign rsp_error = rsp_valid &&
                       (response_backend_error_q ||
                        slot_local_error_mem[response_slot_q]);
    assign rsp_rdata = (rsp_valid && !slot_local_error_mem[response_slot_q]) ?
                       logical_data_mem[response_slot_q][response_index_q] :
                       64'd0;
    assign rsp_tag = rsp_valid ? slot_tag_mem[response_slot_q] : '0;
    assign rsp_fire = rsp_valid && rsp_ready;
    assign response_last_fire = rsp_fire &&
        (response_index_q == (slot_resp_count_mem[response_slot_q] - 1'b1));

    // ------------------------------------------------------------------
    // Sticky diagnostics and counters.
    // ------------------------------------------------------------------
    logic early_req_last_error_q, late_req_last_error_q;
    logic req_flush_error_q, orphan_req_error_q, request_address_error_q;
    assign early_req_last_error = early_req_last_error_q;
    assign late_req_last_error = late_req_last_error_q;
    assign req_flush_error = req_flush_error_q;
    assign orphan_req_error = orphan_req_error_q;
    assign request_address_error = request_address_error_q;
    assign protocol_error = early_req_last_error_q || late_req_last_error_q ||
                            req_flush_error_q || orphan_req_error_q ||
                            request_address_error_q || backend_protocol_error;

    assign perf_busy = (slot_count_q != 0) || (fill_count_q != 0) ||
                       feed_active_q || response_active_q || backend_busy;
    assign perf_cmd_occupancy = slot_count_q;
    assign perf_outstanding = backend_outstanding;
    assign perf_axi_burst_count = backend_burst_count;
    assign perf_axi_beat_count = backend_axi_beat_count;
    assign perf_max_outstanding =
        (backend_max_outstanding > perf_max_cmd_occupancy) ?
        backend_max_outstanding : perf_max_cmd_occupancy;

    integer init_i, init_j;
    always_ff @(posedge clk) begin
        if (rst) begin
            alloc_tail_q <= '0;
            fill_ptr_q <= '0;
            issue_ptr_q <= '0;
            feed_ptr_q <= '0;
            response_ptr_q <= '0;
            slot_count_q <= '0;
            fill_count_q <= '0;
            fill_index_q <= '0;
            next_tag_q <= '0;
            feed_active_q <= 1'b0;
            feed_slot_q <= '0;
            feed_beat_q <= '0;
            response_active_q <= 1'b0;
            response_slot_q <= '0;
            response_index_q <= '0;
            response_backend_error_q <= 1'b0;
            early_req_last_error_q <= 1'b0;
            late_req_last_error_q <= 1'b0;
            req_flush_error_q <= 1'b0;
            orphan_req_error_q <= 1'b0;
            request_address_error_q <= 1'b0;
            perf_cmd_accept_count <= 64'd0;
            perf_logical_req_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_packed_pair_count <= 64'd0;
            perf_error_count <= 64'd0;
            perf_max_cmd_occupancy <= 8'd0;
            for (init_i = 0; init_i < MAX_OUTSTANDING; init_i = init_i + 1) begin
                slot_addr_mem[init_i] <= 32'd0;
                slot_logical_mem[init_i] <= '0;
                slot_beats_mem[init_i] <= 9'd1;
                slot_resp_count_mem[init_i] <= '0;
                slot_tag_mem[init_i] <= '0;
                slot_valid_mem[init_i] <= 1'b0;
                slot_fill_done_mem[init_i] <= 1'b0;
                slot_cmd_sent_mem[init_i] <= 1'b0;
                slot_payload_sent_mem[init_i] <= 1'b0;
                slot_payload_valid_mem[init_i] <= '0;
                slot_cmd_error_mem[init_i] <= 1'b0;
                slot_local_error_mem[init_i] <= 1'b0;
            end
        end else begin
            // Descriptor acceptance.
            if (cmd_fire) begin
                slot_addr_mem[alloc_tail_q] <= cmd_addr;
                slot_logical_mem[alloc_tail_q] <= cmd_logical_eff;
                slot_beats_mem[alloc_tail_q] <= cmd_beats_eff;
                slot_resp_count_mem[alloc_tail_q] <= cmd_logical_eff;
                slot_tag_mem[alloc_tail_q] <= next_tag_q;
                slot_valid_mem[alloc_tail_q] <= 1'b1;
                slot_fill_done_mem[alloc_tail_q] <= 1'b0;
                slot_cmd_sent_mem[alloc_tail_q] <= 1'b0;
                slot_payload_sent_mem[alloc_tail_q] <= 1'b0;
                slot_payload_valid_mem[alloc_tail_q] <= '0;
                slot_cmd_error_mem[alloc_tail_q] <= cmd_local_error;
                slot_local_error_mem[alloc_tail_q] <= cmd_local_error;
                alloc_tail_q <= ptr_inc(alloc_tail_q);
                next_tag_q <= next_tag_q + 1'b1;
                perf_cmd_accept_count <= perf_cmd_accept_count + 1'b1;
            end

            // Capture each logical word and write the corresponding half of
            // the packed beat.  The explicit odd-tail strobe clear prevents
            // stale upper-lane bytes from becoming visible after slot reuse.
            if (req_fire) begin
                logical_data_mem[fill_ptr_q][fill_index_q] <= req_wdata;
                if (!fill_index_q[0]) begin
                    payload_mem[fill_ptr_q][fill_index_q >> 1][63:0] <= req_wdata;
                    payload_strb_mem[fill_ptr_q][fill_index_q >> 1][7:0] <= req_wstrb;
                    if (req_expected_last) begin
                        payload_mem[fill_ptr_q][fill_index_q >> 1][127:64] <= 64'd0;
                        payload_strb_mem[fill_ptr_q][fill_index_q >> 1][15:8] <= 8'd0;
                    end
                end else begin
                    payload_mem[fill_ptr_q][fill_index_q >> 1][127:64] <= req_wdata;
                    payload_strb_mem[fill_ptr_q][fill_index_q >> 1][15:8] <= req_wstrb;
                end
                slot_payload_valid_mem[fill_ptr_q][fill_index_q >> 1] <= 1'b1;
                perf_logical_req_count <= perf_logical_req_count + 1'b1;
                if (fill_index_q[0])
                    perf_packed_pair_count <= perf_packed_pair_count + 1'b1;
                if (req_addr_bad) begin
                    request_address_error_q <= 1'b1;
                    perf_error_count <= perf_error_count + 1'b1;
                end
                fill_index_q <= fill_index_q + 1'b1;
            end

            if (req_valid && !fill_available) begin
                orphan_req_error_q <= 1'b1;
                perf_error_count <= perf_error_count + 1'b1;
            end
            if (req_flush && !fill_available) begin
                orphan_req_error_q <= 1'b1;
                perf_error_count <= perf_error_count + 1'b1;
            end

            if (frame_finish) begin
                slot_fill_done_mem[fill_ptr_q] <= 1'b1;
                if (req_early_last)
                    early_req_last_error_q <= 1'b1;
                if (req_late_last)
                    late_req_last_error_q <= 1'b1;
                if (req_flush_finish)
                    req_flush_error_q <= 1'b1;
                if (req_early_last || req_late_last || req_flush_finish ||
                    req_addr_bad)
                    slot_local_error_mem[fill_ptr_q] <= 1'b1;
                // A flushed empty frame still receives one ordered error
                // token so software cannot wait forever for the command ack.
                if (req_fire && !req_early_last)
                    slot_resp_count_mem[fill_ptr_q] <= slot_logical_mem[fill_ptr_q];
                else if (req_early_last)
                    slot_resp_count_mem[fill_ptr_q] <= fill_index_q + 1'b1;
                else if (fill_index_q == 0)
                    slot_resp_count_mem[fill_ptr_q] <= 1;
                else
                    slot_resp_count_mem[fill_ptr_q] <= fill_index_q;
                fill_index_q <= '0;
                if (cmd_fire && (fill_count_q == 1))
                    fill_ptr_q <= alloc_tail_q;
                else
                    fill_ptr_q <= ptr_inc(fill_ptr_q);
            end else if (cmd_fire && (fill_count_q == 0)) begin
                fill_ptr_q <= alloc_tail_q;
            end

            case ({cmd_fire, frame_finish})
                2'b10: fill_count_q <= fill_count_q + 1'b1;
                2'b01: fill_count_q <= fill_count_q - 1'b1;
                default: fill_count_q <= fill_count_q;
            endcase
            case ({cmd_fire, response_last_fire})
                2'b10: slot_count_q <= slot_count_q + 1'b1;
                2'b01: slot_count_q <= slot_count_q - 1'b1;
                default: slot_count_q <= slot_count_q;
            endcase
            if (cmd_fire && ((slot_count_q + 1'b1) > perf_max_cmd_occupancy))
                perf_max_cmd_occupancy <= slot_count_q + 1'b1;

            // Descriptor command/payload scheduler.
            if (backend_cmd_fire) begin
                // Command acceptance is independent from payload delivery.
                // The issue pointer advances only on this handshake, so the
                // backend still observes descriptors in allocation order.
                slot_cmd_sent_mem[issue_ptr_q] <= 1'b1;
                issue_ptr_q <= ptr_inc(issue_ptr_q);
            end
            if (feed_candidate) begin
                // Start the next payload frame once its command has been
                // accepted.  Since feed_candidate is based on the registered
                // cmd-sent bit, this starts no earlier than the cycle after
                // backend_cmd_fire and remains strictly descriptor ordered.
                feed_slot_q <= feed_ptr_q;
                feed_beat_q <= '0;
                feed_active_q <= 1'b1;
            end
            if (backend_payload_fire) begin
                if (backend_payload_last) begin
                    feed_active_q <= 1'b0;
                    feed_beat_q <= '0;
                    slot_payload_sent_mem[feed_slot_q] <= 1'b1;
                    feed_ptr_q <= ptr_inc(feed_ptr_q);
                end else begin
                    feed_beat_q <= feed_beat_q + 1'b1;
                end
            end

            // Backend descriptor responses are ordered; map each one to the
            // corresponding slot and expand it at the logical boundary.
            if (backend_rsp_fire) begin
                response_active_q <= 1'b1;
                response_slot_q <= response_ptr_q;
                response_index_q <= '0;
                response_backend_error_q <= backend_rsp_error;
                response_ptr_q <= ptr_inc(response_ptr_q);
                if (backend_rsp_error)
                    perf_error_count <= perf_error_count + 1'b1;
            end
            if (rsp_fire) begin
                perf_rsp_count <= perf_rsp_count + 1'b1;
                if (response_last_fire) begin
                    response_active_q <= 1'b0;
                    slot_valid_mem[response_slot_q] <= 1'b0;
                    slot_fill_done_mem[response_slot_q] <= 1'b0;
                    slot_cmd_sent_mem[response_slot_q] <= 1'b0;
                    slot_payload_sent_mem[response_slot_q] <= 1'b0;
                    slot_payload_valid_mem[response_slot_q] <= '0;
                    slot_cmd_error_mem[response_slot_q] <= 1'b0;
                    slot_local_error_mem[response_slot_q] <= 1'b0;
                    slot_resp_count_mem[response_slot_q] <= '0;
                end else begin
                    response_index_q <= response_index_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Lightweight VALID-hold checks at the adapter boundary.  The backend
    // owns the detailed AXI channel assertions.
    logic cmd_stalled_q, req_stalled_q, rsp_stalled_q;
    logic [41:0] cmd_payload_q;
    logic [105:0] req_payload_q;
    logic [TAG_WIDTH+64:0] rsp_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            cmd_stalled_q <= 1'b0;
            req_stalled_q <= 1'b0;
            rsp_stalled_q <= 1'b0;
        end else begin
            if (cmd_stalled_q && (!cmd_valid ||
                ({cmd_addr,cmd_logical_count} != cmd_payload_q)))
                $fatal(1, "write MLP adapter changed stalled command");
            if (req_stalled_q && (!req_valid ||
                ({req_last,req_flush,req_addr,req_wdata,req_wstrb} !=
                 req_payload_q)))
                $fatal(1, "write MLP adapter changed stalled request");
            if (rsp_stalled_q && (!rsp_valid ||
                ({rsp_error,rsp_rdata,rsp_tag} != rsp_payload_q)))
                $fatal(1, "write MLP adapter changed stalled response");
            cmd_stalled_q <= cmd_valid && !cmd_ready;
            cmd_payload_q <= {cmd_addr,cmd_logical_count};
            req_stalled_q <= req_valid && !req_ready;
            req_payload_q <= {req_last,req_flush,req_addr,req_wdata,req_wstrb};
            rsp_stalled_q <= rsp_valid && !rsp_ready;
            rsp_payload_q <= {rsp_error,rsp_rdata,rsp_tag};
        end
    end
`endif

endmodule
