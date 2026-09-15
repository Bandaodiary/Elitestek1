`timescale 1ns/1ps

// Boardless regression for the optional multi-descriptor write arbiter.
// Inputs are driven on falling edges and the downstream BFM consumes
// handshakes on rising edges, so VALID payloads are not changed in the active
// region of the DUT clock edge.  Three independent writers issue overlapping
// AW descriptors; the arbiter must queue them, serialize W in AW order, and
// retire B in the same order without requiring AXI IDs.
module tb_c1_axi_n_write_burst_arbiter_128 #(
    parameter integer FIFO_DEPTH = 4
);
    localparam integer CLIENTS = 3;
    localparam integer TXNS_PER_CLIENT = 2;
    localparam integer TOTAL_TXNS = CLIENTS * TXNS_PER_CLIENT;
    localparam integer BFM_DEPTH = 16;
`ifdef C1_EMPTY_AW_BYPASS_TB
    localparam bit EMPTY_AW_BYPASS = 1'b1;
`else
    localparam bit EMPTY_AW_BYPASS = 1'b0;
`endif
`ifdef C1_W_AHEAD_OF_B_TB
    localparam bit W_AHEAD_OF_B = 1'b1;
`else
    localparam bit W_AHEAD_OF_B = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [CLIENTS-1:0][31:0] s_awaddr = '0;
    logic [CLIENTS-1:0][7:0] s_awlen = '0;
    logic [CLIENTS-1:0][2:0] s_awsize = '0;
    logic [CLIENTS-1:0][1:0] s_awburst = '0;
    logic [CLIENTS-1:0] s_awvalid = '0;
    logic [CLIENTS-1:0] s_awready;
    logic [CLIENTS-1:0][127:0] s_wdata = '0;
    logic [CLIENTS-1:0][15:0] s_wstrb = '0;
    logic [CLIENTS-1:0] s_wlast = '0;
    logic [CLIENTS-1:0] s_wvalid = '0;
    logic [CLIENTS-1:0] s_wready;
    logic [CLIENTS-1:0][1:0] s_bresp;
    logic [CLIENTS-1:0] s_bvalid;
    logic [CLIENTS-1:0] s_bready;

    logic [31:0] m_awaddr;
    logic [7:0] m_awlen;
    logic [2:0] m_awsize;
    logic [1:0] m_awburst;
    logic m_awvalid;
    logic m_awready;
    logic [127:0] m_wdata;
    logic [15:0] m_wstrb;
    logic m_wlast;
    logic m_wvalid;
    logic m_wready;
    logic [1:0] m_bresp;
    logic m_bvalid;
    logic m_bready;

    logic protocol_error;
    logic early_wlast_error, missing_wlast_error;
    logic early_b_error, orphan_b_error;
    logic [7:0] perf_outstanding, perf_max_outstanding;
    logic [63:0] perf_aw_accept_count, perf_aw_issue_count;
    logic [63:0] perf_w_beat_count, perf_b_count;

    // The BREADY pattern is changed only on a falling edge, so it is stable
    // for the complete following DUT cycle.  This lets the BFM create a real
    // B-channel stall without introducing an active-region race.
    logic [CLIENTS-1:0] s_bready_q;
    assign s_bready = s_bready_q;

    // All first descriptors are accepted before any client starts its first W
    // stream.  This is a directed barrier proving that AW can run ahead of W.
    logic [CLIENTS-1:0] aw0_done_q;
    logic first_aw_accept_seen_q;
    logic first_aw_issue_seen_q;
    logic first_aw_same_cycle_q;
    integer first_aw_accept_cycle_q;
    integer first_aw_issue_cycle_q;
    integer first_aw_latency_q;

    c1_axi_n_write_burst_arbiter_128 #(
        .CLIENTS(CLIENTS), .FIFO_DEPTH(FIFO_DEPTH),
        .EMPTY_AW_BYPASS(EMPTY_AW_BYPASS),.W_AHEAD_OF_B(W_AHEAD_OF_B)
    ) dut (
        .clk, .rst,
        .s_awaddr, .s_awlen, .s_awsize, .s_awburst,
        .s_awvalid, .s_awready,
        .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
        .s_bresp, .s_bvalid, .s_bready,
        .m_awaddr, .m_awlen, .m_awsize, .m_awburst,
        .m_awvalid, .m_awready,
        .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready,
        .protocol_error, .early_wlast_error, .missing_wlast_error,
        .early_b_error, .orphan_b_error,
        .perf_outstanding, .perf_max_outstanding,
        .perf_aw_accept_count, .perf_aw_issue_count,
        .perf_w_beat_count, .perf_b_count
    );

    function automatic integer burst_len(input integer owner,
                                         input integer txn);
        begin
            // Deliberately different lengths exercise WLAST and queue reuse.
            case ({owner, txn})
                4'd0: burst_len = 3;
                4'd1: burst_len = 1;
                4'd2: burst_len = 2;
                4'd3: burst_len = 4;
                4'd4: burst_len = 1;
                default: burst_len = 2;
            endcase
        end
    endfunction

    function automatic [31:0] make_addr(input integer owner,
                                         input integer txn);
        make_addr = 32'h0010_0000 + (owner * 32'h0001_0000) +
                    (txn * 32'h0000_1000);
    endfunction

    function automatic [127:0] make_data(input integer owner,
                                          input integer txn,
                                          input integer beat);
        make_data = {32'hA000_0000 | owner,
                     32'hB000_0000 | txn,
                     32'hC000_0000 | (owner << 8) | txn,
                     32'hD000_0000 | beat};
    endfunction

    function automatic [15:0] make_strb(input integer owner,
                                        input integer txn,
                                        input integer beat);
        begin
            // Partial strobes are legal and make sure the arbiter is a pure
            // channel router rather than modifying W payloads.
            if (((owner + txn + beat) % 3) == 0)
                make_strb = 16'h0fff;
            else if (((owner + beat) % 3) == 1)
                make_strb = 16'hf0ff;
            else
                make_strb = 16'hffff;
        end
    endfunction

    // ------------------------------------------------------------------
    // Downstream write BFM. AW descriptors are queued in issue order. W is
    // checked against its own cursor; B has a separate retirement cursor to
    // allow multiple W-complete bursts before any response. B is delayed to create
    // genuine descriptor overlap and response backpressure.
    // ------------------------------------------------------------------
    integer q_owner [0:BFM_DEPTH-1];
    integer q_txn [0:BFM_DEPTH-1];
    integer q_len [0:BFM_DEPTH-1];
    integer q_wbeat [0:BFM_DEPTH-1];
    logic q_done [0:BFM_DEPTH-1];
    integer q_head, q_tail, q_count, q_whead, w_ahead_beats;
    integer b_delay;
    logic bvalid_q;
    logic [1:0] bresp_q;
    integer cycle_q;
    integer bfm_aw_count, bfm_w_beat, bfm_b_count;
    integer bfm_max_queue;

    // Handshakes are sampled on the rising edge and consumed by the BFM on
    // the following falling edge.  The separation is important here: the DUT
    // updates its descriptor state in an NBA region at posedge, while the BFM
    // must continue to see the pre-edge AXI payload for that handshake.
    logic aw_fire_sample_q, w_fire_sample_q, b_fire_sample_q;
    logic [31:0] aw_addr_sample_q;
    logic [7:0] aw_len_sample_q;
    logic [2:0] aw_size_sample_q;
    logic [1:0] aw_burst_sample_q;
    logic [127:0] w_data_sample_q;
    logic [15:0] w_strb_sample_q;
    logic w_last_sample_q;
    logic [1:0] b_resp_sample_q;
    logic [CLIENTS-1:0] client_b_fire_sample_q;
    logic [CLIENTS-1:0][1:0] client_bresp_sample_q;

    logic aw_stall_hold_q, w_stall_hold_q, b_stall_hold_q;
    logic [44:0] aw_stall_payload_q;
    logic [144:0] w_stall_payload_q;
    logic [1:0] b_stall_payload_q;
    integer aw_stall_seen, w_stall_seen, b_stall_seen, b_hold_seen;
    integer sample_client;

    logic awready_q, wready_q;
    integer b_hold_count_q;
    logic b_hold_injected_q;

    task automatic fail(input string message);
        begin
            $display("C1_AXI_N_WRITE_BURST_ARBITER_FAIL t=%0t awq=%0d bq=%0d wbeat=%0d: %s",
                     $time, q_count, bfm_b_count, bfm_w_beat, message);
            $fatal(1);
        end
    endtask

    // Capture all downstream and client-side handshakes before either the DUT
    // or the BFM changes state for the edge.  The payload registers are also
    // used by the BFM at negedge, avoiding simulator scheduling dependence.
    always @(posedge clk) begin
        if (rst) begin
            aw_fire_sample_q <= 1'b0;
            w_fire_sample_q <= 1'b0;
            b_fire_sample_q <= 1'b0;
            client_b_fire_sample_q <= '0;
            aw_stall_hold_q <= 1'b0;
            w_stall_hold_q <= 1'b0;
            b_stall_hold_q <= 1'b0;
            aw_stall_seen = 0;
            w_stall_seen = 0;
            b_stall_seen = 0;
            b_hold_seen = 0;
            first_aw_accept_seen_q <= 1'b0;
            first_aw_issue_seen_q <= 1'b0;
            first_aw_same_cycle_q <= 1'b0;
            first_aw_accept_cycle_q = -1;
            first_aw_issue_cycle_q = -1;
            first_aw_latency_q = -1;
        end else begin
            // The directed BFM keeps AWREADY high on the first active cycle,
            // so bypass mode should handshake the first input and downstream
            // AW on that same edge.  The flag is diagnostic only in the
            // default mode, where enqueue-then-issue latency is retained.
            if (!first_aw_accept_seen_q && (|(s_awvalid & s_awready))) begin
                first_aw_accept_seen_q <= 1'b1;
                first_aw_accept_cycle_q = cycle_q;
                if (m_awvalid && m_awready)
                    first_aw_same_cycle_q <= 1'b1;
            end
            if (!first_aw_issue_seen_q && (m_awvalid && m_awready)) begin
                first_aw_issue_seen_q <= 1'b1;
                first_aw_issue_cycle_q = cycle_q;
            end

            // AXI VALID payloads must remain unchanged while READY is low.
            if (aw_stall_hold_q &&
                (!m_awvalid ||
                 ({m_awaddr, m_awlen, m_awsize, m_awburst} !=
                  aw_stall_payload_q)))
                fail("downstream AW payload changed while stalled");
            if (w_stall_hold_q &&
                (!m_wvalid || ({m_wdata, m_wstrb, m_wlast} !=
                               w_stall_payload_q)))
                fail("downstream W payload changed while stalled");
            if (b_stall_hold_q &&
                (!m_bvalid || (m_bresp !== b_stall_payload_q)))
                fail("downstream B payload changed/withdrew while stalled");

            aw_fire_sample_q <= m_awvalid && m_awready;
            aw_addr_sample_q <= m_awaddr;
            aw_len_sample_q <= m_awlen;
            aw_size_sample_q <= m_awsize;
            aw_burst_sample_q <= m_awburst;
            w_fire_sample_q <= m_wvalid && m_wready;
            w_data_sample_q <= m_wdata;
            w_strb_sample_q <= m_wstrb;
            w_last_sample_q <= m_wlast;
            b_fire_sample_q <= m_bvalid && m_bready;
            b_resp_sample_q <= m_bresp;
            for (sample_client = 0; sample_client < CLIENTS;
                 sample_client = sample_client + 1) begin
                client_b_fire_sample_q[sample_client] <=
                    s_bvalid[sample_client] && s_bready[sample_client];
                client_bresp_sample_q[sample_client] <=
                    s_bresp[sample_client];
            end

            if (m_awvalid && !m_awready)
                aw_stall_seen = aw_stall_seen + 1;
            if (m_wvalid && !m_wready)
                w_stall_seen = w_stall_seen + 1;
            if (m_bvalid && !m_bready) begin
                b_stall_seen = b_stall_seen + 1;
                b_hold_seen = b_hold_seen + 1;
            end

            aw_stall_hold_q <= m_awvalid && !m_awready;
            aw_stall_payload_q <= {m_awaddr, m_awlen, m_awsize, m_awburst};
            w_stall_hold_q <= m_wvalid && !m_wready;
            w_stall_payload_q <= {m_wdata, m_wstrb, m_wlast};
            b_stall_hold_q <= m_bvalid && !m_bready;
            b_stall_payload_q <= m_bresp;
        end
    end

    always_comb begin
        // Address and data channels have independent, deterministic stalls.
        m_awready = awready_q;
        m_wready = wready_q;
        m_bvalid = bvalid_q;
        m_bresp = bresp_q;
    end

    integer owner_decoded, txn_decoded, expected_len;
    always @(negedge clk) begin
        if (rst) begin
            q_head = 0;
            q_whead = 0;
            w_ahead_beats = 0;
            q_tail = 0;
            q_count = 0;
            b_delay = 0;
            bvalid_q = 1'b0;
            bresp_q = 2'b00;
            cycle_q = 0;
            bfm_aw_count = 0;
            bfm_w_beat = 0;
            bfm_b_count = 0;
            bfm_max_queue = 0;
            awready_q = 1'b1;
            wready_q = 1'b1;
            s_bready_q = '1;
            b_hold_count_q = 0;
            b_hold_injected_q = 1'b0;
        end else begin
            cycle_q = cycle_q + 1;

            // Deterministic but finite backpressure on AW/W.  These values
            // are registered at negedge and therefore cannot change during a
            // posedge handshake.
            // Keep the first active cycle ready so the optional bypass can
            // demonstrate a true same-cycle AW handshake.  Later modulo
            // stalls still exercise VALID hold behavior.
            awready_q = ((cycle_q % 5) != 3);
            wready_q = ((cycle_q % 4) != 2);

            // Force one visible BVALID hold, then add sparse independent
            // client stalls so every response eventually makes progress.  The
            // first hold is armed below in the same negedge that asserts
            // bvalid_q; arming it one edge later would allow an unintended
            // one-cycle B handshake before the stall became visible.
            if (b_hold_count_q > 0) begin
                s_bready_q = '0;
                b_hold_count_q = b_hold_count_q - 1;
            end else begin
                s_bready_q[0] = !((cycle_q % 11) == 3 ||
                                   (cycle_q % 11) == 4);
                s_bready_q[1] = !((cycle_q % 13) == 6);
                s_bready_q[2] = !((cycle_q % 17) == 9);
            end

            if (aw_fire_sample_q) begin
                if (q_count >= BFM_DEPTH)
                    fail("BFM AW queue overflow");
                if (aw_size_sample_q != 3'd4 || aw_burst_sample_q != 2'b01)
                    fail("AW attributes mismatch");
                if (aw_addr_sample_q[3:0] != 0)
                    fail("unaligned AW");
                if (({1'b0, aw_addr_sample_q[11:0]} +
                     ({8'd0, aw_len_sample_q} + 1'b1) * 13'd16) > 13'd4096)
                    fail("AW crossed 4KiB boundary");
                owner_decoded = (aw_addr_sample_q - 32'h0010_0000) >> 16;
                txn_decoded = ((aw_addr_sample_q - 32'h0010_0000) >> 12) & 16'hf;
                if (owner_decoded < 0 || owner_decoded >= CLIENTS ||
                    txn_decoded < 0 || txn_decoded >= TXNS_PER_CLIENT)
                    fail("AW owner/transaction decode mismatch");
                expected_len = burst_len(owner_decoded, txn_decoded);
                if (aw_len_sample_q != expected_len - 1)
                    fail("AW length mismatch");
                q_owner[q_tail] = owner_decoded;
                q_txn[q_tail] = txn_decoded;
                q_len[q_tail] = expected_len;
                q_wbeat[q_tail] = 0;
                q_done[q_tail] = 1'b0;
                q_tail = (q_tail + 1) % BFM_DEPTH;
                q_count = q_count + 1;
                bfm_aw_count = bfm_aw_count + 1;
                if (q_count > bfm_max_queue)
                    bfm_max_queue = q_count;
            end

            if (w_fire_sample_q) begin
                if (q_count == 0)
                    fail("W arrived before AW");
                if (q_done[q_whead])
                    fail("W arrived after WLAST");
                if (w_data_sample_q !== make_data(q_owner[q_whead],
                                                  q_txn[q_whead],
                                                  q_wbeat[q_whead]))
                    fail("W data/order mismatch");
                if (w_strb_sample_q !== make_strb(q_owner[q_whead],
                                                  q_txn[q_whead],
                                                  q_wbeat[q_whead]))
                    fail("WSTRB mismatch");
                if (w_last_sample_q != (q_wbeat[q_whead] == q_len[q_whead] - 1))
                    fail("WLAST mismatch");
                if (q_whead != q_head) w_ahead_beats = w_ahead_beats + 1;
                bfm_w_beat = bfm_w_beat + 1;
                if (w_last_sample_q) begin
                    q_done[q_whead] = 1'b1;
                    q_wbeat[q_whead] = 0;
                    q_whead = (q_whead + 1) % BFM_DEPTH;
                    b_delay = 3;
                end else begin
                    q_wbeat[q_whead] = q_wbeat[q_whead] + 1;
                end
            end

            if (b_fire_sample_q) begin
                if (q_count == 0 || !q_done[q_head])
                    fail("B arrived before terminal W");
                q_done[q_head] = 1'b0;
                q_head = (q_head + 1) % BFM_DEPTH;
                q_count = q_count - 1;
                bvalid_q = 1'b0;
                bfm_b_count = bfm_b_count + 1;
            end

            if (!bvalid_q && q_count != 0 && q_done[q_head]) begin
                if (b_delay > 0)
                    b_delay = b_delay - 1;
                else begin
                    // One deterministic BRESP error is propagated through
                    // the arbiter to the owning client.
                    bresp_q = ((q_owner[q_head] == 1) &&
                               (q_txn[q_head] == 1)) ? 2'b10 : 2'b00;
                    bvalid_q = 1'b1;
                    if (!b_hold_injected_q) begin
                        b_hold_injected_q = 1'b1;
                        b_hold_count_q = 4;
                        s_bready_q = '0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Independent client producers.  Each producer waits only for its own
    // AW/W/B handshakes; three producers therefore create multiple accepted
    // descriptors even though W itself remains ordered by the arbiter.
    // ------------------------------------------------------------------
    task automatic drive_client(input integer owner);
        integer txn, beat, len;
        begin
            for (txn = 0; txn < TXNS_PER_CLIENT; txn = txn + 1) begin
                len = burst_len(owner, txn);
                @(negedge clk); #1;
                s_awaddr[owner] = make_addr(owner, txn);
                s_awlen[owner] = len - 1;
                s_awsize[owner] = 3'd4;
                s_awburst[owner] = 2'b01;
                s_awvalid[owner] = 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (s_awready[owner]) begin
                        @(negedge clk); #1;
                        s_awvalid[owner] = 1'b0;
                        break;
                    end
                end

                // Do not let any client present W for txn0 until every
                // client has accepted its first AW.  FIFO_DEPTH=4 therefore
                // has several descriptors in flight before the first data
                // beat, which directly exercises AW look-ahead.
                if (txn == 0) begin
                    aw0_done_q[owner] = 1'b1;
                    while (aw0_done_q !== {CLIENTS{1'b1}})
                        @(posedge clk);
                end

                for (beat = 0; beat < len; beat = beat + 1) begin
                    @(negedge clk); #1;
                    s_wdata[owner] = make_data(owner, txn, beat);
                    s_wstrb[owner] = make_strb(owner, txn, beat);
                    s_wlast[owner] = (beat == len - 1);
                    s_wvalid[owner] = 1'b1;
                    while (1) begin
                        @(posedge clk);
                        if (s_wready[owner]) begin
                            @(negedge clk); #1;
                            s_wvalid[owner] = 1'b0;
                            break;
                        end
                    end
                end

                // Wait for the routed response.  s_bready is deliberately
                // stalled by the BFM for a few cycles, so this also checks
                // that the client-side BVALID/BRESP pair survives backpressure.
                while (1) begin
                    @(posedge clk);
                    if (s_bvalid[owner] && s_bready[owner]) begin
                        // Sample BRESP on the handshake edge.  The arbiter
                        // may retire the descriptor in its NBA region and
                        // change the routed payload before the following
                        // negedge, so checking it later would be a TB race.
                        if (s_bresp[owner] !==
                            (((owner == 1) && (txn == 1)) ? 2'b10 : 2'b00))
                            fail("BRESP did not route in order");
                        @(negedge clk); #1;
                        break;
                    end
                end
            end
            @(negedge clk); #1;
            s_awvalid[owner] = 1'b0;
            s_wvalid[owner] = 1'b0;
        end
    endtask

    integer timeout_count;
    initial begin
        s_awvalid = '0;
        s_wvalid = '0;
        aw0_done_q = '0;
        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;

        fork
            drive_client(0);
            drive_client(1);
            drive_client(2);
        join

        timeout_count = 0;
        while ((bfm_b_count < TOTAL_TXNS) && (timeout_count < 4000)) begin
            @(negedge clk); #1;
            timeout_count = timeout_count + 1;
        end
        if (bfm_b_count != TOTAL_TXNS)
            fail("write response timeout");
        if (q_count != 0 || perf_aw_accept_count != TOTAL_TXNS ||
            perf_aw_issue_count != TOTAL_TXNS || perf_b_count != TOTAL_TXNS)
            fail("descriptor/counter conservation mismatch");
        if (perf_w_beat_count != bfm_w_beat)
            fail("W beat counter mismatch");
        if (perf_max_outstanding < 2 || bfm_max_queue < 2)
            fail("did not prove multiple outstanding descriptors");
        if (perf_outstanding != 0)
            fail("perf_outstanding did not return to zero");
        if (!first_aw_accept_seen_q || !first_aw_issue_seen_q)
            fail("first AW handshake was not observed");
        first_aw_latency_q = first_aw_issue_cycle_q - first_aw_accept_cycle_q;
        if (first_aw_latency_q < 0)
            fail("first AW issue preceded acceptance");
        if (EMPTY_AW_BYPASS && !first_aw_same_cycle_q)
            fail("empty-FIFO AW bypass did not remove first-AW latency");
        if (!EMPTY_AW_BYPASS && first_aw_same_cycle_q)
            fail("default arbiter unexpectedly bypassed empty FIFO");
        if (aw_stall_seen == 0 || w_stall_seen == 0)
            fail("AW/W backpressure was not exercised");
        if (b_stall_seen == 0 || b_hold_seen == 0)
            fail("B backpressure/BVALID hold was not exercised");
        if (protocol_error)
            fail("normal traffic raised a protocol error");
        if (W_AHEAD_OF_B && w_ahead_beats==0)
            fail("W did not advance past unretired B head");
        if (!W_AHEAD_OF_B && w_ahead_beats!=0)
            fail("legacy W ordering changed");
        $display("C1_WRITE_W_AHEAD_PASS enabled=%0d depth=%0d ahead_beats=%0d",W_AHEAD_OF_B,FIFO_DEPTH,w_ahead_beats);

        $display("C1_AXI_N_WRITE_BURST_ARBITER_PASS empty_bypass=%0d first_aw_same=%0d first_aw_latency=%0d aw=%0d beats=%0d b=%0d max_outstanding=%0d max_bfm_queue=%0d aw_stall=%0d w_stall=%0d b_stall=%0d",
                 EMPTY_AW_BYPASS, first_aw_same_cycle_q, first_aw_latency_q,
                 bfm_aw_count, bfm_w_beat, bfm_b_count,
                 perf_max_outstanding, bfm_max_queue,
                 aw_stall_seen, w_stall_seen, b_stall_seen);
        $finish;
    end
endmodule
