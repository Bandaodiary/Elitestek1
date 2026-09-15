`timescale 1ns/1ps

// Boardless end-to-end check for the two-lane write fabric.  Four contiguous
// logical writes are dispatched to one leaf at a time; the next block is sent
// to the other leaf.  The AXI BFM deliberately stalls AW/W, delays B, and
// holds BVALID while BREADY is deasserted.  The test therefore exercises the
// block dispatcher, pack2 in both leaves, the ID-less AW/W/B arbiter, and the
// response tag FIFO at the wrapper boundary.
module tb_c1_tensor_mem_axi128_write_parallel_fabric;
`ifdef C1_WRITE_PARALLEL_LANES4_TB
    localparam integer LANES = 4;
    localparam integer NREQ = 32;
    localparam integer BFM_DEPTH = 32;
`else
    localparam integer LANES = 2;
    localparam integer NREQ = 16;
    localparam integer BFM_DEPTH = 16;
`endif
    localparam integer BLOCK_LOGICAL = 4;
    localparam integer BURST_BEATS = 4;
    localparam integer MEM_DEPTH = 65536;
    localparam integer BLOCKS = NREQ / BLOCK_LOGICAL;
    localparam integer ERROR_BLOCK = 2;
`ifdef C1_WRITE_PARALLEL_REQ_POP_REFILL_TB
    localparam bit ALLOW_REQ_POP_REFILL = 1'b1;
`else
    localparam bit ALLOW_REQ_POP_REFILL = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic req_valid = 1'b0;
    logic req_ready;
    logic req_flush = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [63:0] req_wdata = 64'd0;
    logic [7:0] req_wstrb = 8'd0;

    logic rsp_valid;
    logic rsp_ready;
    logic rsp_error;
    logic [63:0] rsp_rdata;

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

    logic protocol_error, early_wlast_error, missing_wlast_error;
    logic early_b_error, orphan_b_error;
    logic perf_busy;
    logic [63:0] perf_req_accept_count, perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count, perf_rsp_count;
    logic [63:0] perf_packed_request_count, perf_error_count;
    logic [7:0] perf_req_occupancy, perf_max_req_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_tensor_mem_axi128_write_parallel_fabric #(
        .LANES(LANES),
        .BLOCK_LOGICAL(BLOCK_LOGICAL),
        .REQ_FIFO_DEPTH(16),
        .BURST_BEATS(BURST_BEATS),
        .RSP_FIFO_DEPTH(2 * BURST_BEATS),
        .FABRIC_FIFO_DEPTH(4),
        .TAG_FIFO_DEPTH(32),
        .BUILD_TIMEOUT_CYCLES(3),
        .ALLOW_SAME_LANE_DUP(1'b0),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL)
    ) dut (
        .clk, .rst,
        .req_valid, .req_ready, .req_flush,
        .req_addr, .req_wdata, .req_wstrb,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_wvalid, .m_axi_wready,
        .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
        .protocol_error, .early_wlast_error, .missing_wlast_error,
        .early_b_error, .orphan_b_error,
        .perf_busy, .perf_req_accept_count, .perf_axi_burst_count,
        .perf_axi_beat_count, .perf_rsp_count,
        .perf_packed_request_count, .perf_error_count,
        .perf_req_occupancy, .perf_max_req_occupancy,
        .perf_outstanding, .perf_max_outstanding
    );

    // ------------------------------------------------------------------
    // Request/response scoreboard.
    // ------------------------------------------------------------------
    logic [63:0] expected_data [0:NREQ-1];
    logic expected_error [0:NREQ-1];
    integer req_total;
    integer rsp_seen;
    integer response_error_seen;
    integer cycle_count;
    integer aw_count;
    integer w_count;
    integer b_count;
    integer bfm_head, bfm_tail, bfm_count;
    integer bfm_w_beat;
    integer bfm_b_delay;
    integer max_inflight;
    integer max_bfm_queue;
    logic bfm_b_pending;
    logic bfm_bvalid_q;
    logic [1:0] bfm_bresp_q;
    logic b_backpressure_seen;
    logic [7:0] expected_mem [0:MEM_DEPTH-1];
    logic [7:0] shadow_mem [0:MEM_DEPTH-1];

    function automatic [31:0] request_addr(input integer index);
        integer block_idx;
        integer in_block;
        begin
            block_idx = index / BLOCK_LOGICAL;
            in_block = index % BLOCK_LOGICAL;
            // Each block is contiguous and page-separated.  The dispatcher
            // sends blocks 0/2 to lane 0 and 1/3 to lane 1.
            request_addr = 32'h0000_1000 + block_idx * 32'h0000_1000 +
                           in_block * 8;
        end
    endfunction

    function automatic [63:0] request_data(input integer index);
        // Set the payload MSB as well as lower bits so the full 145-bit
        // VALID-hold monitor is exercised (including its formerly truncated
        // top bit).
        request_data = 64'hA100_0000_0000_0000 + index;
    endfunction

    task automatic add_expected_bytes(
        input logic [31:0] address,
        input logic [63:0] data,
        input logic [7:0] strb
    );
        integer k;
        integer ai;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                if (strb[k]) begin
                    ai = address[15:0] + k;
                    expected_mem[ai] = data[k*8 +: 8];
                end
            end
        end
    endtask

    task automatic send_request(input integer index);
        logic [31:0] address;
        logic [63:0] data;
        begin
            address = request_addr(index);
            data = request_data(index);
            @(negedge clk); #1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 8'hff;
            req_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (req_ready) begin
                    if (req_total >= NREQ)
                        fail("request scoreboard overflow");
                    expected_data[req_total] = data;
            // One block receives a delayed SLVERR from the
            // BFM.  The leaf must preserve payload/order while
            // propagating the status to all four logical tokens.
            expected_error[req_total] =
                        (index >= ERROR_BLOCK * BLOCK_LOGICAL) &&
                        (index < (ERROR_BLOCK + 1) * BLOCK_LOGICAL);
                    add_expected_bytes(address, data, 8'hff);
                    req_total = req_total + 1;
                    @(negedge clk); #1;
                    req_valid = 1'b0;
                    break;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // AXI write BFM.  Handshakes are sampled on posedge and consumed on the
    // following negedge to keep the BFM independent of DUT NBA updates.
    // ------------------------------------------------------------------
    logic aw_sample_q, w_sample_q, b_sample_q;
    logic [31:0] aw_addr_sample_q;
    logic [7:0] aw_len_sample_q;
    logic [2:0] aw_size_sample_q;
    logic [1:0] aw_burst_sample_q;
    logic [127:0] w_data_sample_q;
    logic [15:0] w_strb_sample_q;
    logic w_last_sample_q;
    logic [1:0] b_resp_sample_q;

    logic [31:0] bfm_base [0:BFM_DEPTH-1];
    logic [7:0] bfm_len [0:BFM_DEPTH-1];
    logic [31:0] aw_base_seen [0:BFM_DEPTH-1];

    task automatic fail(input string message);
        begin
            $display("C1_TENSOR_MEM_AXI128_WRITE_PARALLEL_FAIL t=%0t req=%0d rsp=%0d aw=%0d w=%0d b=%0d max_out=%0d: %s",
                     $time, req_total, rsp_seen, aw_count, w_count,
                     b_count, max_inflight, message);
            $fatal(1);
        end
    endtask

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire rsp_fire = rsp_valid && rsp_ready;

    // Independent deterministic stalls.  BVALID itself is registered by the
    // BFM and remains asserted until the DUT accepts it.
    always_comb begin
        m_axi_awready = ((cycle_count % 7) != 1) &&
                        (bfm_count < BFM_DEPTH);
        m_axi_wready = ((cycle_count % 5) != 2);
        m_axi_bvalid = bfm_bvalid_q;
        m_axi_bresp = bfm_bresp_q;
        rsp_ready = ((cycle_count % 9) != 4);
    end

    always @(posedge clk) begin
        if (rst) begin
            aw_sample_q <= 1'b0;
            w_sample_q <= 1'b0;
            b_sample_q <= 1'b0;
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

            if (rsp_fire) begin
                if (rsp_seen >= req_total)
                    fail("excess logical response");
                if (rsp_error !== expected_error[rsp_seen])
                    fail("logical response error/order mismatch");
                if (rsp_rdata !== expected_data[rsp_seen])
                    fail("logical response payload/order mismatch");
                if (rsp_error)
                    response_error_seen = response_error_seen + 1;
                rsp_seen = rsp_seen + 1;
            end
        end
    end

    always @(negedge clk) begin : bfm_proc
        integer k;
        integer ai;
        if (rst) begin
            cycle_count = 0;
            aw_count = 0;
            w_count = 0;
            b_count = 0;
            bfm_head = 0;
            bfm_tail = 0;
            bfm_count = 0;
            bfm_w_beat = 0;
            bfm_b_delay = 0;
            max_inflight = 0;
            max_bfm_queue = 0;
            bfm_b_pending = 1'b0;
            bfm_bvalid_q = 1'b0;
            bfm_bresp_q = 2'b00;
            b_backpressure_seen = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;

            if (m_axi_bvalid && !m_axi_bready)
                b_backpressure_seen = 1'b1;
            if (aw_sample_q) begin
                if (bfm_count >= BFM_DEPTH)
                    fail("AXI descriptor queue overflow");
                if (aw_addr_sample_q[3:0] != 0 ||
                    aw_size_sample_q != 3'd4 ||
                    aw_burst_sample_q != 2'b01 ||
                    aw_len_sample_q != 8'd1 ||
                    (aw_addr_sample_q[11:0] +
                     (aw_len_sample_q + 1) * 16 > 4096))
                    fail("invalid or 4-KiB-crossing AW");
                aw_base_seen[aw_count] = aw_addr_sample_q;
                bfm_base[bfm_tail] = aw_addr_sample_q;
                bfm_len[bfm_tail] = aw_len_sample_q;
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                aw_count = aw_count + 1;
                if (bfm_count > max_inflight)
                    max_inflight = bfm_count;
                if (bfm_count > max_bfm_queue)
                    max_bfm_queue = bfm_count;
            end

            if (w_sample_q) begin
                if (bfm_count == 0)
                    fail("W beat arrived without AW");
                if (w_last_sample_q != (bfm_w_beat == bfm_len[bfm_head]))
                    fail("WLAST does not match AWLEN");
                // Verify each asserted byte against the logical write shadow.
                for (k = 0; k < 16; k = k + 1) begin
                    if (w_strb_sample_q[k]) begin
                        ai = (bfm_base[bfm_head] + bfm_w_beat * 16 + k) &
                             16'hffff;
                        if (w_data_sample_q[k*8 +: 8] !== expected_mem[ai])
                            fail("AXI W payload does not match logical shadow");
                        shadow_mem[ai] = w_data_sample_q[k*8 +: 8];
                    end
                end
                w_count = w_count + 1;
                if (w_last_sample_q) begin
                    bfm_b_pending = 1'b1;
                    // Keep B outstanding long enough for a second AW to be
                    // accepted/issued.  One descriptor is deliberately an
                    // SLVERR to test status propagation without reordering.
                    bfm_b_delay = 18 + (aw_count % 3);
                    bfm_bresp_q = (bfm_base[bfm_head] ==
                                   (32'h0000_1000 + ERROR_BLOCK * 32'h1000)) ?
                                  2'b10 : 2'b00;
                    bfm_w_beat = 0;
                end else begin
                    bfm_w_beat = bfm_w_beat + 1;
                end
            end

            if (b_sample_q) begin
                if (!bfm_bvalid_q || !bfm_b_pending || bfm_count == 0)
                    fail("unexpected B handshake");
                if (b_resp_sample_q !== bfm_bresp_q)
                    fail("BRESP payload changed or mismatched");
                bfm_bvalid_q = 1'b0;
                bfm_b_pending = 1'b0;
                bfm_head = (bfm_head + 1) % BFM_DEPTH;
                bfm_count = bfm_count - 1;
                b_count = b_count + 1;
                bfm_w_beat = 0;
            end

            if (!bfm_bvalid_q && bfm_b_pending) begin
                if (bfm_b_delay != 0)
                    bfm_b_delay = bfm_b_delay - 1;
                else
                    bfm_bvalid_q = 1'b1;
            end
        end
    end

    task automatic check_mem_range(input integer base, input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                if (shadow_mem[(base + k) & 16'hffff] !==
                    expected_mem[(base + k) & 16'hffff])
                    fail("shadow memory mismatch");
            end
        end
    endtask

    integer init_i;
    integer index_i;
    integer block_i;
    integer search_i;
    logic block_found;
    integer timeout_count;
    initial begin
        req_total = 0;
        rsp_seen = 0;
        response_error_seen = 0;
        for (init_i = 0; init_i < MEM_DEPTH; init_i = init_i + 1) begin
            expected_mem[init_i] = 8'd0;
            shadow_mem[init_i] = 8'd0;
        end
        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;

        for (index_i = 0; index_i < NREQ; index_i = index_i + 1)
            send_request(index_i);
        if (req_total != NREQ)
            fail("stimulus request count mismatch");

        timeout_count = 0;
        while ((rsp_seen < NREQ || bfm_count != 0 || bfm_b_pending ||
                bfm_bvalid_q ||
                perf_busy) && timeout_count < 20000) begin
            @(negedge clk); #1;
            timeout_count = timeout_count + 1;
        end
        if (timeout_count >= 20000)
            fail("end-to-end busy flag/response drain timeout");
        if (rsp_seen != NREQ)
            fail("logical response timeout");
        if (bfm_count != 0 || bfm_b_pending || bfm_bvalid_q)
            fail("AXI BFM did not drain");
        if (perf_req_accept_count != NREQ || perf_rsp_count != NREQ)
            fail("logical traffic counters mismatch");
        if (aw_count != BLOCKS || perf_axi_burst_count != BLOCKS)
            fail("packed block burst count mismatch");
        // Every four-request block must have reached the AXI side exactly
        // once; this also checks that the dispatcher alternated its two
        // leaves rather than silently dropping or coalescing a block.
        for (block_i = 0; block_i < BLOCKS; block_i = block_i + 1) begin
            block_found = 1'b0;
            for (search_i = 0; search_i < aw_count;
                 search_i = search_i + 1) begin
                if (aw_base_seen[search_i] ==
                    (32'h0000_1000 + block_i * 32'h0000_1000))
                    block_found = 1'b1;
            end
            if (!block_found)
                fail("dispatcher block missing at AXI AW");
        end
        if (w_count != BLOCKS * 2 || perf_axi_beat_count != BLOCKS * 2)
            fail("packed AXI beat count mismatch");
        if (perf_packed_request_count != NREQ / 2)
            fail("pack2 count mismatch");
        if (perf_error_count != 4 || response_error_seen != 4)
            fail("SLVERR propagation count mismatch");
        if (max_inflight < LANES || perf_max_outstanding < LANES)
            fail("parallel fabric did not prove requested outstanding descriptors");
        if (!b_backpressure_seen)
            fail("B backpressure was not exercised");
        if (protocol_error || early_wlast_error || missing_wlast_error ||
            early_b_error || orphan_b_error)
            fail("normal traffic raised an AXI protocol diagnostic");

        for (block_i = 0; block_i < BLOCKS; block_i = block_i + 1)
            check_mem_range(16'h1000 + block_i * 16'h1000, BLOCK_LOGICAL * 8);

        $display("C1_TENSOR_MEM_AXI128_WRITE_PARALLEL_PASS req=%0d aw=%0d beats=%0d packed=%0d errors=%0d max_outstanding=%0d bfm_max=%0d b_stall=%0d",
                 req_total, aw_count, w_count, perf_packed_request_count,
                 perf_error_count, perf_max_outstanding, max_bfm_queue,
                 b_backpressure_seen);
        $finish;
    end

    // Keep timeout finite even if a malformed handshake wedges the fabric.
    initial begin
        #1000000;
        $fatal(1, "parallel write fabric timeout");
    end
endmodule
