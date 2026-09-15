`timescale 1ns/1ps

// Boardless stress test for c1_axi128_write_mlp.
//
// The first three descriptors are valid and are deliberately presented one
// frame at a time while W is held off.  This forces AW to run ahead of W and
// demonstrates descriptor MLP without relying on AXI IDs.  The BFM then adds
// AW/W/B stalls and a SLVERR on the second descriptor.  Three following
// descriptors exercise early payload_last, missing (late) payload_last, and
// payload_flush; each must return an ordered local error and must not issue
// an illegal AXI burst.
module tb_c1_axi128_write_mlp #(parameter bit DEPENDENT_FIRST_AW=1'b0, PIPELINE_W=1'b0);
    integer bfm_write_head;
    localparam integer MAX_OUTSTANDING = 4;
    localparam integer MAX_BEATS = 4;
    localparam integer VALID_DESC = 3;
    localparam integer TOTAL_DESC = 6;
    localparam integer BFM_DEPTH = 8;
`ifdef C1_WRITE_RSP_POP_REFILL_TB
    localparam bit RSP_POP_REFILL_MODE = 1'b1;
`else
    localparam bit RSP_POP_REFILL_MODE = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    logic [31:0] cmd_addr = 32'd0;
    logic [8:0] cmd_beats = 9'd0;

    logic payload_valid = 1'b0;
    logic payload_ready;
    logic [127:0] payload_data = 128'd0;
    logic [15:0] payload_strb = 16'hffff;
    logic payload_last = 1'b0;
    logic payload_flush = 1'b0;

    logic rsp_valid, rsp_ready;
    logic rsp_error;
    logic [31:0] rsp_addr;
    logic [8:0] rsp_beats;
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

    logic protocol_error;
    logic early_payload_last_error, late_payload_last_error;
    logic payload_flush_error, orphan_payload_error;
    logic early_b_error, orphan_b_error;
    logic perf_busy;
    logic [63:0] perf_cmd_accept_count, perf_payload_beat_count;
    logic [63:0] perf_axi_burst_count, perf_axi_beat_count;
    logic [63:0] perf_aw_issue_count, perf_rsp_count, perf_error_count;
    logic [63:0] perf_aw_stall_count, perf_w_stall_count, perf_b_stall_count;
    logic [7:0] perf_cmd_occupancy, perf_max_cmd_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_axi128_write_mlp #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        // Deliberately shallower than descriptor MLP depth so BREADY must
        // backpressure when rsp_ready is held low.
        .RSP_FIFO_DEPTH(2),
        .TAG_WIDTH(16),
        .ALLOW_RSP_POP_REFILL(RSP_POP_REFILL_MODE),.PIPELINE_WRITE_DATA(PIPELINE_W)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_addr, .cmd_beats,
        .payload_valid, .payload_ready, .payload_data, .payload_strb,
        .payload_last, .payload_flush,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_addr, .rsp_beats, .rsp_tag,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_wvalid, .m_axi_wready,
        .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
        .protocol_error, .early_payload_last_error, .late_payload_last_error,
        .payload_flush_error, .orphan_payload_error,
        .early_b_error, .orphan_b_error,
        .perf_busy, .perf_cmd_accept_count, .perf_payload_beat_count,
        .perf_axi_burst_count, .perf_axi_beat_count, .perf_aw_issue_count,
        .perf_rsp_count, .perf_error_count, .perf_aw_stall_count,
        .perf_w_stall_count, .perf_b_stall_count, .perf_cmd_occupancy,
        .perf_max_cmd_occupancy, .perf_outstanding, .perf_max_outstanding
    );

    integer cycle_count;
    integer cmd_seen;
    integer payload_seen;
    integer rsp_seen;
    integer aw_seen;
    integer w_seen;
    integer b_seen;
    integer max_aw_inflight;
    integer bfm_head, bfm_tail, bfm_count;
    integer bfm_w_beat [0:BFM_DEPTH-1];
    logic bfm_w_done [0:BFM_DEPTH-1];
    logic bfm_b_started [0:BFM_DEPTH-1];
    integer bfm_b_delay;
    logic bfm_bvalid_q;
    logic [1:0] bfm_bresp_q;
    logic orphan_b_inflight;
    integer orphan_b_seen;
    logic w_enable;
    logic saw_aw_ahead;
    logic full_pop_push_seen;

    // Sample AXI handshakes before the DUT's NBA updates.  Processing the
    // live combinational payload at the following negedge would observe the
    // *next* W beat after w_beat_q advanced, creating a false scoreboard
    // mismatch.
    logic aw_sample_q, w_sample_q, b_sample_q;
    logic [31:0] aw_addr_sample_q;
    logic [7:0] aw_len_sample_q;
    logic [2:0] aw_size_sample_q;
    logic [1:0] aw_burst_sample_q;
    logic [127:0] w_data_sample_q;
    logic [15:0] w_strb_sample_q;
    logic w_last_sample_q;
    logic [1:0] b_resp_sample_q;

    logic [31:0] expected_addr [0:TOTAL_DESC-1];
    logic [8:0] expected_beats [0:TOTAL_DESC-1];
    logic expected_error [0:TOTAL_DESC-1];
    logic [127:0] expected_data [0:VALID_DESC-1][0:MAX_BEATS-1];

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire payload_fire = payload_valid && payload_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    task automatic fail(input string message);
        begin
            $display("C1_AXI128_WRITE_MLP_FAIL t=%0t cmd=%0d payload=%0d rsp=%0d aw=%0d w=%0d b=%0d max_out=%0d: %s",
                     $time, cmd_seen, payload_seen, rsp_seen, aw_seen, w_seen,
                     b_seen, max_aw_inflight, message);
            $fatal(1);
        end
    endtask

    task automatic send_cmd(input integer idx, input integer beats,
                            input logic [31:0] addr);
        begin
            @(negedge clk); #1;
            cmd_addr = addr;
            cmd_beats = beats;
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

    task automatic send_payload_beat(input logic [127:0] data,
                                      input logic last);
        begin
            @(negedge clk); #1;
            payload_data = data;
            payload_strb = 16'hffff;
            payload_last = last;
            payload_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (payload_ready) begin
                    @(negedge clk); #1;
                    payload_valid = 1'b0;
                    payload_last = 1'b0;
                    break;
                end
            end
        end
    endtask

    task automatic send_flush;
        begin
            @(negedge clk); #1;
            payload_flush = 1'b1;
            @(posedge clk);
            @(negedge clk); #1;
            payload_flush = 1'b0;
        end
    endtask

    // Deterministic backpressure.  AW is open from the beginning; W is held
    // until all three valid frames have issued AW, making the MLP observable.
    always_comb begin
        // Keep AW closed for the first window to force visible AW stalls,
        // then apply a deterministic sparse-ready pattern.
        m_axi_awready = (cycle_count >= 28) &&
                        (bfm_count < BFM_DEPTH) && ((cycle_count % 5) != 1) &&
                        (!DEPENDENT_FIRST_AW || aw_seen!=0 || m_axi_wvalid);
        m_axi_wready = w_enable && ((cycle_count % 4) != 2);
        m_axi_bvalid = bfm_bvalid_q;
        m_axi_bresp = bfm_bresp_q;
        // Hold the descriptor response FIFO full long enough to stall B;
        // release it later with a periodic consumer pattern.
        rsp_ready = (cycle_count >= 100) && ((cycle_count % 7) != 3);
    end

    // Response scoreboard samples at the active edge; producer outputs are
    // held by the DUT until rsp_ready.
    always @(posedge clk) begin
        if (rst) begin
            aw_sample_q <= 1'b0;
            w_sample_q <= 1'b0;
            b_sample_q <= 1'b0;
        end else if (rsp_fire) begin
            if (rsp_seen >= TOTAL_DESC)
                fail("excess descriptor response");
            if (rsp_tag !== rsp_seen[15:0])
                fail("descriptor tag order mismatch");
            if (rsp_addr !== expected_addr[rsp_seen])
                fail("descriptor address order mismatch");
            if (rsp_beats !== expected_beats[rsp_seen])
                fail("descriptor beat count mismatch");
            if (rsp_error !== expected_error[rsp_seen])
                fail("descriptor error/order mismatch");
            rsp_seen = rsp_seen + 1;
        end
        if (!rst) begin
            // The DUT intentionally keeps rsp_count_q internal.  This
            // simulation-only probe verifies the focused optimization at its
            // exact boundary: a B retirement is accepted while the public
            // response FIFO is full and its head is consumed on the same
            // clock edge.  No such hierarchical probe is used in synthesis.
            if (RSP_POP_REFILL_MODE && (dut.rsp_count_q == 2) &&
                rsp_fire && b_fire)
                full_pop_push_seen <= 1'b1;
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
        end
    end

    // AXI BFM.  AW/W handshakes are sampled after the DUT's posedge NBA at
    // the following negedge, so queue bookkeeping cannot race the DUT.
    always @(negedge clk) begin : bfm_proc
        integer slot;
        integer expected_idx;
        if (rst) begin
            cycle_count = 0;
            cmd_seen = 0;
            payload_seen = 0;
            rsp_seen = 0;
            aw_seen = 0;
            w_seen = 0;
            b_seen = 0;
            max_aw_inflight = 0;
            bfm_head = 0;
            bfm_write_head = 0;
            bfm_tail = 0;
            bfm_count = 0;
            bfm_b_delay = 0;
            bfm_bvalid_q = 1'b0;
            bfm_bresp_q = 2'b00;
            orphan_b_inflight = 1'b0;
            orphan_b_seen = 0;
            w_enable = 1'b0;
            saw_aw_ahead = 1'b0;
            full_pop_push_seen = 1'b0;
            for (slot = 0; slot < BFM_DEPTH; slot = slot + 1) begin
                bfm_w_beat[slot] = 0;
                bfm_w_done[slot] = 1'b0;
                bfm_b_started[slot] = 1'b0;
            end
        end else begin
            cycle_count = cycle_count + 1;
            if (cmd_fire)
                cmd_seen = cmd_seen + 1;
            if (payload_fire)
                payload_seen = payload_seen + 1;

            // Inject one B response before any AW has been issued.  The DUT
            // must drain and flag it without retiring a descriptor; this
            // specifically guards the orphan-B path in the ID-less seam.
            if (!orphan_b_inflight && (orphan_b_seen == 0) &&
                (cycle_count == 1)) begin
                bfm_bvalid_q = 1'b1;
                bfm_bresp_q = 2'b10;
                orphan_b_inflight = 1'b1;
            end

            if (aw_sample_q) begin
                if (bfm_count >= BFM_DEPTH)
                    fail("BFM AW queue overflow");
                bfm_w_beat[bfm_tail] = 0;
                bfm_w_done[bfm_tail] = 1'b0;
                bfm_b_started[bfm_tail] = 1'b0;
                // Valid descriptor addresses are BASE + descriptor*0x100.
                if (aw_addr_sample_q < 32'h0000_8000 ||
                    aw_addr_sample_q[7:0] != 8'h00)
                    fail("unexpected AW address");
                expected_idx = (aw_addr_sample_q - 32'h0000_8000) >> 8;
                if (expected_idx >= VALID_DESC)
                    fail("local-error descriptor issued AW");
                if (aw_len_sample_q !== (MAX_BEATS-1))
                    fail("AW length mismatch");
                if (aw_size_sample_q !== 3'd4 || aw_burst_sample_q !== 2'b01)
                    fail("AW size/burst mismatch");
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                aw_seen = aw_seen + 1;
            end
            if (bfm_count > max_aw_inflight)
                max_aw_inflight = bfm_count;
            if ((aw_seen >= VALID_DESC) && !w_enable)
                saw_aw_ahead = 1'b1;

            if (w_sample_q) begin
                if (bfm_count == 0)
                    fail("W without AW");
                slot = bfm_write_head;
                expected_idx = (bfm_count == 0) ? 0 :
                    ((bfm_head < VALID_DESC) ? bfm_head : 0);
                // Queue order is the descriptor order for this test.
                if (bfm_w_beat[slot] >= MAX_BEATS)
                    fail("too many W beats");
                if (w_data_sample_q !== expected_data[slot][bfm_w_beat[slot]]) begin
                    fail("W payload/order mismatch");
                end
                if (w_strb_sample_q !== 16'hffff)
                    fail("W strobe mismatch");
                if (w_last_sample_q !== (bfm_w_beat[slot] == MAX_BEATS-1))
                    fail("W LAST mismatch");
                bfm_w_beat[slot] = bfm_w_beat[slot] + 1;
                w_seen = w_seen + 1;
                if (w_last_sample_q) begin
                    bfm_w_done[slot] = 1'b1;
                    bfm_write_head=(bfm_write_head+1)%BFM_DEPTH;
                end
            end

            if (!bfm_bvalid_q && (bfm_count != 0) &&
                bfm_w_done[bfm_head] && !bfm_b_started[bfm_head]) begin
                if (bfm_b_delay > 0)
                    bfm_b_delay = bfm_b_delay - 1;
                else begin
                    bfm_bvalid_q = 1'b1;
                    // Second valid descriptor returns SLVERR.
                    bfm_bresp_q = (bfm_head == 1) ? 2'b10 : 2'b00;
                    bfm_b_started[bfm_head] = 1'b1;
                end
            end
            if (b_sample_q) begin
                if (orphan_b_inflight) begin
                    // This B was intentionally unsolicited; do not touch the
                    // normal AW/W/B queue or its count.
                    bfm_bvalid_q = 1'b0;
                    orphan_b_inflight = 1'b0;
                    orphan_b_seen = orphan_b_seen + 1;
                end else begin
                    bfm_bvalid_q = 1'b0;
                    b_seen = b_seen + 1;
                    bfm_head = (bfm_head + 1) % BFM_DEPTH;
                    bfm_count = bfm_count - 1;
                    bfm_b_delay = 2;
                end
            end

            // Release W only after all three AW handshakes have been seen.
            if(perf_outstanding != aw_seen-b_seen)
                fail("physical outstanding counted a local/orphan descriptor");
            if (aw_seen >= VALID_DESC)
                w_enable = 1'b1;
        end
    end

    initial begin : stimulus
        integer i;
        // Expected descriptors: three valid, then early/late/flush errors.
        expected_addr[0] = 32'h0000_8000;
        expected_addr[1] = 32'h0000_8100;
        expected_addr[2] = 32'h0000_8200;
        expected_addr[3] = 32'h0000_9000;
        expected_addr[4] = 32'h0000_9100;
        expected_addr[5] = 32'h0000_9200;
        for (i = 0; i < TOTAL_DESC; i = i + 1)
            expected_beats[i] = (i < 3) ? MAX_BEATS : 3;
        expected_beats[4] = 2;
        expected_error[0] = 1'b0;
        expected_error[1] = 1'b1; // BFM SLVERR
        expected_error[2] = 1'b0;
        expected_error[3] = 1'b1; // early last
        expected_error[4] = 1'b1; // late last
        expected_error[5] = 1'b1; // flush
        for (i = 0; i < VALID_DESC; i = i + 1)
            for (integer j = 0; j < MAX_BEATS; j = j + 1)
                expected_data[i][j] = 128'hC100_0000_0000_0000 +
                                      (i * 16) + j;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Valid descriptors and frames.  AW may run ahead because W is held.
        for (i = 0; i < VALID_DESC; i = i + 1) begin
            send_cmd(i, MAX_BEATS, 32'h0000_8000 + i * 32'h100);
            for (integer j = 0; j < MAX_BEATS; j = j + 1)
                send_payload_beat(expected_data[i][j],
                                  (j == MAX_BEATS-1));
        end

        // Early payload_last: declared three, terminate after one beat.
        send_cmd(3, 3, expected_addr[3]);
        send_payload_beat(128'hE300, 1'b1);

        // Late payload_last: declared two, but final beat omits LAST.  The
        // descriptor is completed with an error at the declared boundary.
        send_cmd(4, 2, expected_addr[4]);
        send_payload_beat(128'hE400, 1'b0);
        send_payload_beat(128'hE401, 1'b0);

        // Flush aborts the third frame after one payload beat.
        send_cmd(5, 3, expected_addr[5]);
        send_payload_beat(128'hE500, 1'b0);
        send_flush();

        // Wait for all descriptor responses and diagnostics.
        for (i = 0; i < 400; i = i + 1) begin
            @(posedge clk);
            if (rsp_seen == TOTAL_DESC && !perf_busy)
                break;
        end
        if (rsp_seen != TOTAL_DESC)
            fail("timeout waiting for descriptor responses");
        if (aw_seen != VALID_DESC)
            fail("unexpected AW count");
        if (w_seen != VALID_DESC * MAX_BEATS)
            fail("unexpected W beat count");
        if (b_seen != VALID_DESC)
            fail("unexpected B count");
        if (orphan_b_seen != 1 || !orphan_b_error)
            fail("orphan B was not drained and flagged");
        if (!saw_aw_ahead || max_aw_inflight < VALID_DESC)
            fail("AW did not run ahead of W");
        if (RSP_POP_REFILL_MODE && !full_pop_push_seen)
            fail("response FIFO did not exercise full pop+push");
        if (perf_aw_stall_count == 0)
            fail("AW stall counter did not observe a stall");
        if (perf_b_stall_count == 0)
            fail("B stall counter did not observe a stall");
        if (!early_payload_last_error || !late_payload_last_error ||
            !payload_flush_error || !protocol_error)
            fail("framing diagnostics missing");
        if (perf_max_outstanding < VALID_DESC)
            fail("performance outstanding counter too small");
        $display("C1_AXI128_WRITE_MLP_PASS rsp_pop_refill=%0d full_pop_push=%0d desc=%0d aw=%0d w=%0d b=%0d max_out=%0d aw_stall=%0d w_stall=%0d b_stall=%0d errors=%0d",
                 RSP_POP_REFILL_MODE, full_pop_push_seen,
                 rsp_seen, aw_seen, w_seen, b_seen, max_aw_inflight,
                 perf_aw_stall_count, perf_w_stall_count,
                 perf_b_stall_count, perf_error_count);
        $finish;
    end
endmodule
