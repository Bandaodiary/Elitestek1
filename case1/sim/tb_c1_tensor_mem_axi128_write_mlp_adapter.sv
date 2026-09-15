`timescale 1ns/1ps

// End-to-end boardless check for the logical-write -> pack2 -> burst-level
// MLP seam.  Four six-word descriptors are accepted while W is held off so
// that AW can build a queue; a fifth descriptor terminates early and must be
// returned as an ordered local error without issuing an AXI burst.
//
// Define C1_ADAPTER_ISSUE_AW_BEFORE_PAYLOAD_TB at compile time to exercise
// the adapter's opt-in command-early path.  The same traffic/scoreboard then
// verifies that command issue may overlap logical capture without changing
// packed W order or poisoned-frame behavior.  Keeping the switch here leaves
// the default regression byte-for-byte conservative.
module tb_c1_tensor_mem_axi128_write_mlp_adapter;
    localparam integer MAX_OUTSTANDING = 4;
    localparam integer MAX_BEATS = 4;
    localparam integer VALID_DESC = 4;
    localparam integer VALID_WORDS = 6;
    localparam integer BAD_WORDS_DECL = 4;
    localparam integer BAD_WORDS_SENT = 2;
    localparam integer TOTAL_DESC = VALID_DESC + 1;
    localparam integer TOTAL_RSP = VALID_DESC * VALID_WORDS + BAD_WORDS_SENT;
    localparam integer BFM_DEPTH = 8;
`ifdef C1_ADAPTER_ISSUE_AW_BEFORE_PAYLOAD_TB
    localparam bit ISSUE_AW_BEFORE_PAYLOAD = 1'b1;
`else
    localparam bit ISSUE_AW_BEFORE_PAYLOAD = 1'b0;
`endif
`ifdef C1_ADAPTER_RSP_POP_REFILL_TB
    localparam bit ALLOW_RSP_POP_REFILL = 1'b1;
`else
    localparam bit ALLOW_RSP_POP_REFILL = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    logic [31:0] cmd_addr = 32'd0;
    logic [9:0] cmd_logical_count = 10'd0;
    logic req_valid = 1'b0;
    logic req_ready;
    logic req_last = 1'b0;
    logic req_flush = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [63:0] req_wdata = 64'd0;
    logic [7:0] req_wstrb = 8'hff;

    logic rsp_valid, rsp_ready, rsp_error;
    logic [63:0] rsp_rdata;
    logic [15:0] rsp_tag;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid, m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid, m_axi_wready;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid, m_axi_bready;

    logic protocol_error, early_req_last_error, late_req_last_error;
    logic req_flush_error, orphan_req_error, request_address_error;
    logic perf_busy;
    logic [63:0] perf_cmd_accept_count, perf_logical_req_count;
    logic [63:0] perf_axi_burst_count, perf_axi_beat_count;
    logic [63:0] perf_rsp_count, perf_packed_pair_count, perf_error_count;
    logic [7:0] perf_cmd_occupancy, perf_max_cmd_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_tensor_mem_axi128_write_mlp_adapter #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        .RSP_FIFO_DEPTH(2),
        .TAG_WIDTH(16),
        .ISSUE_AW_BEFORE_PAYLOAD(ISSUE_AW_BEFORE_PAYLOAD),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_addr, .cmd_logical_count,
        .req_valid, .req_ready, .req_last, .req_flush,
        .req_addr, .req_wdata, .req_wstrb,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata, .rsp_tag,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_wvalid, .m_axi_wready,
        .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
        .protocol_error, .early_req_last_error, .late_req_last_error,
        .req_flush_error, .orphan_req_error, .request_address_error,
        .perf_busy, .perf_cmd_accept_count, .perf_logical_req_count,
        .perf_axi_burst_count, .perf_axi_beat_count, .perf_rsp_count,
        .perf_packed_pair_count, .perf_error_count,
        .perf_cmd_occupancy, .perf_max_cmd_occupancy,
        .perf_outstanding, .perf_max_outstanding
    );

    integer cycle_count;
    integer cmd_seen;
    integer req_seen;
    integer rsp_seen;
    integer aw_seen;
    integer w_seen;
    integer b_seen;
    integer bfm_head, bfm_tail, bfm_count;
    integer bfm_w_beat [0:BFM_DEPTH-1];
    logic bfm_w_done [0:BFM_DEPTH-1];
    logic bfm_b_started [0:BFM_DEPTH-1];
    logic [1:0] bfm_slot_resp [0:BFM_DEPTH-1];
    integer bfm_b_delay [0:BFM_DEPTH-1];
    logic [31:0] bfm_base [0:BFM_DEPTH-1];
    logic bfm_bvalid_q;
    logic [1:0] bfm_bresp_q;
    logic w_enable;
    integer max_inflight;
    logic saw_aw_ahead;
    logic saw_aw_before_payload;
    logic b_backpressure_seen;
    logic full_pop_push_seen;

    logic aw_sample_q, w_sample_q, b_sample_q;
    logic cmd_sample_q, req_sample_q;
    logic [31:0] aw_addr_sample_q;
    logic [7:0] aw_len_sample_q;
    logic [2:0] aw_size_sample_q;
    logic [1:0] aw_burst_sample_q;
    logic [127:0] w_data_sample_q;
    logic [15:0] w_strb_sample_q;
    logic w_last_sample_q;
    logic [1:0] b_resp_sample_q;

    wire cmd_fire = cmd_valid && cmd_ready;
    wire req_fire = req_valid && req_ready;
    wire rsp_fire = rsp_valid && rsp_ready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

    function automatic [63:0] word_data(input integer desc, input integer word);
        word_data = 64'hD100_0000_0000_0000 + (desc * 16'h100) + word;
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_FAIL t=%0t cmd=%0d req=%0d rsp=%0d aw=%0d w=%0d b=%0d max_out=%0d: %s",
                     $time, cmd_seen, req_seen, rsp_seen, aw_seen, w_seen,
                     b_seen, max_inflight, message);
            $fatal(1);
        end
    endtask

    task automatic send_cmd(input logic [31:0] address, input integer words);
        begin
            @(negedge clk); #1;
            cmd_addr = address;
            cmd_logical_count = words;
            cmd_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (cmd_ready) begin
                    @(negedge clk); #1;
                    cmd_valid = 1'b0;
                    break;
                end
            end
        end
    endtask

    task automatic send_word(input logic [31:0] address,
                             input logic [63:0] data,
                             input logic last_value);
        begin
            @(negedge clk); #1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            req_last = last_value;
            req_flush = 1'b0;
            req_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (req_ready) begin
                    @(negedge clk); #1;
                    req_valid = 1'b0;
                    req_last = 1'b0;
                    break;
                end
            end
        end
    endtask

    // Deterministic channel stalls.  W is held until all valid descriptors
    // have issued AW, making descriptor-level MLP visible in the trace.
    always_comb begin
        m_axi_awready = (cycle_count >=
                         (ISSUE_AW_BEFORE_PAYLOAD ? 4 : 32)) &&
                        (bfm_count < BFM_DEPTH) && ((cycle_count % 5) != 1);
        m_axi_wready = w_enable && ((cycle_count % 4) != 2);
        m_axi_bvalid = bfm_bvalid_q;
        m_axi_bresp = bfm_bresp_q;
        rsp_ready = (cycle_count >= 120) && ((cycle_count % 7) != 3);
    end

    // Sample handshakes at the active edge before DUT NBA updates; consume
    // the snapshots at negedge in the BFM.
    always @(posedge clk) begin
        if (rst) begin
            aw_sample_q <= 1'b0;
            w_sample_q <= 1'b0;
            b_sample_q <= 1'b0;
            cmd_sample_q <= 1'b0;
            req_sample_q <= 1'b0;
        end else begin
            aw_sample_q <= aw_fire;
            aw_addr_sample_q <= m_axi_awaddr;
            aw_len_sample_q <= m_axi_awlen;
            aw_size_sample_q <= m_axi_awsize;
            aw_burst_sample_q <= m_axi_awburst;
            w_sample_q <= w_fire;
            w_data_sample_q <= m_axi_wdata;
            w_strb_sample_q <= m_axi_wstrb;
            w_last_sample_q <= m_axi_wlast;
            b_sample_q <= b_fire;
            b_resp_sample_q <= m_axi_bresp;
            cmd_sample_q <= cmd_fire;
            req_sample_q <= req_fire;

            // In the focused mode the backend FIFO has depth two.  Observe a
            // full FIFO accepting B while the oldest logical response leaves
            // on the same edge; this is simulation-only and does not become
            // part of the synthesizable adapter interface.
            if (ALLOW_RSP_POP_REFILL && (dut.u_backend.rsp_count_q == 2) &&
                dut.backend_rsp_fire && b_fire)
                full_pop_push_seen <= 1'b1;

            if (rsp_fire) begin
                integer d, w;
                logic exp_error;
                logic [63:0] exp_data;
                if (rsp_seen >= TOTAL_RSP)
                    fail("excess logical response");
                if (rsp_seen < VALID_DESC * VALID_WORDS) begin
                    d = rsp_seen / VALID_WORDS;
                    w = rsp_seen % VALID_WORDS;
                    exp_error = (d == 1); // BFM SLVERR descriptor
                    exp_data = word_data(d, w);
                    if (rsp_tag !== d[15:0])
                        fail("valid descriptor tag order mismatch");
                end else begin
                    d = VALID_DESC;
                    w = rsp_seen - VALID_DESC * VALID_WORDS;
                    exp_error = 1'b1; // early LAST is local poisoned frame
                    exp_data = 64'd0;
                    if (rsp_tag !== d[15:0])
                        fail("poisoned descriptor tag mismatch");
                end
                if (rsp_error !== exp_error)
                    fail("logical response error mismatch");
                if (rsp_rdata !== exp_data)
                    fail("logical response payload/order mismatch");
                rsp_seen = rsp_seen + 1;
            end
        end
    end

    always @(negedge clk) begin : bfm_proc
        integer slot;
        integer desc_idx;
        integer beat;
        if (rst) begin
            cycle_count = 0;
            cmd_seen = 0;
            req_seen = 0;
            rsp_seen = 0;
            aw_seen = 0;
            w_seen = 0;
            b_seen = 0;
            bfm_head = 0;
            bfm_tail = 0;
            bfm_count = 0;
            bfm_bvalid_q = 1'b0;
            bfm_bresp_q = 2'b00;
            w_enable = 1'b0;
            max_inflight = 0;
            saw_aw_ahead = 1'b0;
            saw_aw_before_payload = 1'b0;
            b_backpressure_seen = 1'b0;
            full_pop_push_seen = 1'b0;
            for (slot = 0; slot < BFM_DEPTH; slot = slot + 1) begin
                bfm_w_beat[slot] = 0;
                bfm_w_done[slot] = 1'b0;
                bfm_b_started[slot] = 1'b0;
                bfm_slot_resp[slot] = 2'b00;
                bfm_b_delay[slot] = 0;
            end
        end else begin
            cycle_count = cycle_count + 1;
            if (cmd_sample_q)
                cmd_seen = cmd_seen + 1;
            if (req_sample_q)
                req_seen = req_seen + 1;
            if (m_axi_bvalid && !m_axi_bready)
                b_backpressure_seen = 1'b1;

            if (aw_sample_q) begin
                if (bfm_count >= BFM_DEPTH)
                    fail("AXI AW queue overflow");
                if (aw_addr_sample_q[3:0] != 0 || aw_size_sample_q != 3'd4 ||
                    aw_burst_sample_q != 2'b01 ||
                    ((!ISSUE_AW_BEFORE_PAYLOAD && aw_len_sample_q != 8'd2) ||
                     (ISSUE_AW_BEFORE_PAYLOAD &&
                      (aw_len_sample_q != 8'd2 &&
                       !(aw_addr_sample_q == 32'h0000_2000 &&
                         aw_len_sample_q == 8'd1)))) ||
                    (aw_addr_sample_q[11:0] +
                     (aw_len_sample_q + 1) * 16 > 4096))
                    fail("invalid or crossing AW");
                if (ISSUE_AW_BEFORE_PAYLOAD &&
                    aw_addr_sample_q == 32'h0000_2000)
                    desc_idx = VALID_DESC;
                else
                    desc_idx = (aw_addr_sample_q - 32'h0000_1000) >> 8;
                if (desc_idx < 0 ||
                    (desc_idx >= VALID_DESC &&
                     !(ISSUE_AW_BEFORE_PAYLOAD && desc_idx == VALID_DESC)))
                    fail("poisoned/local descriptor issued AW");
                bfm_w_beat[bfm_tail] = 0;
                bfm_w_done[bfm_tail] = 1'b0;
                bfm_b_started[bfm_tail] = 1'b0;
                bfm_base[bfm_tail] = aw_addr_sample_q;
                bfm_slot_resp[bfm_tail] = (desc_idx == 1) ? 2'b10 : 2'b00;
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                aw_seen = aw_seen + 1;
                if (req_seen == 0)
                    saw_aw_before_payload = 1'b1;
                if (bfm_count > max_inflight)
                    max_inflight = bfm_count;
            end
            if (bfm_count > max_inflight)
                max_inflight = bfm_count;
            if (aw_seen >= VALID_DESC && !w_enable) begin
                w_enable = 1'b1;
                saw_aw_ahead = 1'b1;
            end

            if (w_sample_q) begin
                if (bfm_count == 0)
                    fail("W without AW");
                slot = bfm_head;
                // Determine descriptor identity from the queued base address
                // rather than from a physical slot index.
                if (ISSUE_AW_BEFORE_PAYLOAD &&
                    bfm_base_addr(slot) == 32'h0000_2000)
                    desc_idx = VALID_DESC;
                else
                    desc_idx = (bfm_base_addr(slot) - 32'h0000_1000) >> 8;
                beat = bfm_w_beat[slot];
                if (desc_idx == VALID_DESC && ISSUE_AW_BEFORE_PAYLOAD &&
                    beat == 1) begin
                    if (w_strb_sample_q !== 16'd0 ||
                        w_data_sample_q !== 128'd0)
                        fail("optional malformed tail was not zero-filled");
                end else begin
                    if (w_strb_sample_q !== 16'hffff)
                        fail("packed W strobe mismatch");
                    if (desc_idx == VALID_DESC && ISSUE_AW_BEFORE_PAYLOAD) begin
                        if (w_data_sample_q[63:0] !== 64'hBAD0 ||
                            w_data_sample_q[127:64] !== 64'hBAD1)
                            fail("optional malformed captured beat mismatch");
                    end else if (w_data_sample_q[63:0] !== word_data(desc_idx, beat * 2) ||
                                 w_data_sample_q[127:64] !== word_data(desc_idx, beat * 2 + 1))
                        fail("packed W payload mismatch");
                end
                if (w_last_sample_q !== ((desc_idx == VALID_DESC &&
                                          ISSUE_AW_BEFORE_PAYLOAD) ?
                                         (beat == 1) : (beat == 2)))
                    fail("packed WLAST mismatch");
                bfm_w_beat[slot] = beat + 1;
                w_seen = w_seen + 1;
                if (w_last_sample_q)
                    bfm_w_done[slot] = 1'b1;
                if (w_last_sample_q)
                    bfm_b_delay[slot] = 4 + (aw_seen % 3);
            end

            if (!bfm_bvalid_q && (bfm_count != 0) &&
                bfm_w_done[bfm_head] && !bfm_b_started[bfm_head]) begin
                if (bfm_b_delay[bfm_head] > 0)
                    bfm_b_delay[bfm_head] = bfm_b_delay[bfm_head] - 1;
                else begin
                    bfm_bvalid_q = 1'b1;
                    bfm_bresp_q = bfm_slot_resp[bfm_head];
                    bfm_b_started[bfm_head] = 1'b1;
                end
            end
            if (b_sample_q) begin
                if (!bfm_bvalid_q || bfm_count == 0)
                    fail("unexpected B handshake");
                if (b_resp_sample_q !== bfm_bresp_q)
                    fail("BRESP changed while held");
                bfm_bvalid_q = 1'b0;
                bfm_head = (bfm_head + 1) % BFM_DEPTH;
                bfm_count = bfm_count - 1;
                b_seen = b_seen + 1;
            end
        end
    end

    // Base address helper keeps the BFM queue bookkeeping readable.
    function automatic [31:0] bfm_base_addr(input integer slot_index);
        bfm_base_addr = bfm_base[slot_index];
    endfunction

    initial begin : stimulus
        integer d, w;
        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;

        // Fill the descriptor ring before streaming payloads.  This is the
        // important stress case for the adapter split scheduler: command
        // descriptors can be accepted/issued ahead of the payload feeder,
        // while logical words still arrive in strict descriptor order.
        for (d = 0; d < VALID_DESC; d = d + 1)
            send_cmd(32'h0000_1000 + d * 32'h100, VALID_WORDS);
        for (d = 0; d < VALID_DESC; d = d + 1)
            for (w = 0; w < VALID_WORDS; w = w + 1)
                send_word(32'h0000_1000 + d * 32'h100 + w * 8,
                          word_data(d, w), (w == VALID_WORDS-1));
        // Give the valid descriptors time to drain before reusing a ring
        // slot for the deliberately malformed frame.
        while (rsp_seen < VALID_DESC * VALID_WORDS || perf_busy || bfm_count != 0)
            @(posedge clk);

        send_cmd(32'h0000_2000, BAD_WORDS_DECL);
        send_word(32'h0000_2000, 64'hBAD0, 1'b0);
        send_word(32'h0000_2008, 64'hBAD1, 1'b1);

        for (w = 0; w < 3000; w = w + 1) begin
            @(posedge clk);
            if (rsp_seen == TOTAL_RSP && !perf_busy && bfm_count == 0 &&
                !bfm_bvalid_q)
                break;
        end
        if (rsp_seen != TOTAL_RSP)
            fail("logical response timeout");
        if (cmd_seen != TOTAL_DESC || req_seen != VALID_DESC * VALID_WORDS + BAD_WORDS_SENT)
            fail("input counter mismatch");
        if (aw_seen != (VALID_DESC + (ISSUE_AW_BEFORE_PAYLOAD ? 1 : 0)) ||
            w_seen != VALID_DESC * (VALID_WORDS / 2) +
                      (ISSUE_AW_BEFORE_PAYLOAD ? BAD_WORDS_DECL / 2 : 0) ||
            b_seen != (VALID_DESC + (ISSUE_AW_BEFORE_PAYLOAD ? 1 : 0)))
            fail("AXI traffic count mismatch");
        if (!saw_aw_ahead || max_inflight < 3 || perf_max_outstanding < 3)
            fail("descriptor MLP did not reach three in-flight bursts");
        if (ISSUE_AW_BEFORE_PAYLOAD && !saw_aw_before_payload)
            fail("optional AW-before-payload mode did not issue AW before logical data");
        if (!ISSUE_AW_BEFORE_PAYLOAD && saw_aw_before_payload)
            fail("conservative mode issued AW before logical data");
        if (perf_cmd_accept_count != TOTAL_DESC ||
            perf_logical_req_count != TOTAL_RSP || perf_rsp_count != TOTAL_RSP)
            fail("adapter counters mismatch");
        if (perf_axi_burst_count !=
                (VALID_DESC + (ISSUE_AW_BEFORE_PAYLOAD ? 1 : 0)) ||
            perf_axi_beat_count != VALID_DESC * (VALID_WORDS / 2) +
                (ISSUE_AW_BEFORE_PAYLOAD ? BAD_WORDS_DECL / 2 : 0) ||
            perf_packed_pair_count != (TOTAL_RSP / 2))
            fail("pack/burst counters mismatch");
        if (!early_req_last_error || !protocol_error)
            fail("early-LAST diagnostic missing");
        if (!b_backpressure_seen)
            fail("B backpressure was not exercised");
        if (ALLOW_RSP_POP_REFILL && !full_pop_push_seen)
            fail("adapter response FIFO did not exercise full pop+push");
        $display("C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PASS aw_before=%0d rsp_pop_refill=%0d full_pop_push=%0d desc=%0d req=%0d rsp=%0d aw=%0d beats=%0d packed=%0d errors=%0d max_out=%0d",
                 ISSUE_AW_BEFORE_PAYLOAD, ALLOW_RSP_POP_REFILL,
                 full_pop_push_seen,
                 cmd_seen, req_seen, rsp_seen, aw_seen, w_seen,
                 perf_packed_pair_count, perf_error_count,
                 perf_max_outstanding);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "write MLP adapter timeout");
    end
endmodule
