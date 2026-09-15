`timescale 1ns/1ps

// Boardless regression for c1_axi_n_read_burst_arbiter_128.
//
// The testbench uses a two-phase edge discipline: DUT handshakes are sampled
// at posedge, then the BFM and scoreboard consume those samples at negedge.
// This avoids active/NBA races while still exercising the real ready/valid
// boundaries. Several ARs are accepted before the first R response; client
// RREADY is independently stalled. The second phase injects early and missing
// RLAST and checks sticky containment flags.
module tb_c1_axi_n_read_burst_arbiter_128 #(parameter logic [1:0] TEST_RRESP=2'b00);
    localparam integer CLIENTS = 2;
    localparam integer FIFO_DEPTH = 4;
    localparam integer NORMAL_TXNS_PER_CLIENT = 3;
    localparam integer MALFORMED_TXNS_PER_CLIENT = 2;
    localparam integer BFM_DEPTH = 8;
`ifdef C1_EMPTY_AR_BYPASS_TB
    localparam bit EMPTY_AR_BYPASS_MODE = 1'b1;
`else
    localparam bit EMPTY_AR_BYPASS_MODE = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    integer phase = 0; // 0 reset/idle, 1 normal, 2 malformed
    logic force_ar_stall = 1'b0;

    logic [CLIENTS-1:0][31:0] s_araddr = '0;
    logic [CLIENTS-1:0][7:0]  s_arlen = '0;
    logic [CLIENTS-1:0][2:0]  s_arsize = '0;
    logic [CLIENTS-1:0][1:0]  s_arburst = '0;
    logic [CLIENTS-1:0]       s_arvalid = '0;
    logic [CLIENTS-1:0]       s_arready;
    logic [CLIENTS-1:0][127:0] s_rdata;
    logic [CLIENTS-1:0][1:0]   s_rresp;
    logic [CLIENTS-1:0]        s_rlast;
    logic [CLIENTS-1:0]        s_rvalid;
    logic [CLIENTS-1:0]        s_rready = '0;

    logic [31:0] m_araddr;
    logic [7:0]  m_arlen;
    logic [2:0]  m_arsize;
    logic [1:0]  m_arburst;
    logic        m_arvalid;
    logic        m_arready;
    logic [127:0] m_rdata;
    logic [1:0]   m_rresp;
    logic         m_rlast;
    logic         m_rvalid;
    logic         m_rready;
    logic         protocol_error;
    logic         early_rlast_error;
    logic         missing_rlast_error;
    logic         orphan_r_error;

    c1_axi_n_read_burst_arbiter_128 #(
        .CLIENTS(CLIENTS),
        .FIFO_DEPTH(FIFO_DEPTH),
        .EMPTY_AR_BYPASS(EMPTY_AR_BYPASS_MODE)
    ) dut (
        .clk, .rst,
        .s_araddr, .s_arlen, .s_arsize, .s_arburst,
        .s_arvalid, .s_arready,
        .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
        .m_araddr, .m_arlen, .m_arsize, .m_arburst,
        .m_arvalid, .m_arready,
        .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready,
        .protocol_error, .early_rlast_error,
        .missing_rlast_error, .orphan_r_error
    );

    function automatic [31:0] make_addr(input integer owner,
                                        input integer txn);
        make_addr = 32'h4000_0000 + (owner << 16) + (txn << 8);
    endfunction

    function automatic [127:0] make_data(input integer owner,
                                          input integer txn,
                                          input integer beat);
        make_data = {32'hA100_0000 | owner,
                     32'hB200_0000 | txn,
                     32'hC300_0000 | (owner << 8) | txn,
                     32'hD400_0000 | beat};
    endfunction

    // ------------------------------------------------------------------
    // Posedge sampling. Reads happen before DUT NBA updates; sampled values
    // are consumed by the BFM/scoreboard at the following negedge.
    // ------------------------------------------------------------------
    logic ar_sample_q;
    logic [31:0] ar_addr_sample_q;
    logic [7:0] ar_len_sample_q;
    logic [2:0] ar_size_sample_q;
    logic [1:0] ar_burst_sample_q;
    logic r_sample_q;
    logic [127:0] r_data_sample_q;
    logic [1:0] r_resp_sample_q;
    logic r_last_sample_q;
    logic [CLIENTS-1:0] client_r_sample_q;
    logic [CLIENTS-1:0][127:0] client_data_sample_q;
    logic [CLIENTS-1:0] client_last_sample_q;

    wire ar_fire = m_arvalid && m_arready;
    wire r_fire = m_rvalid && m_rready;
    wire client_ar_fire = |(s_arvalid & s_arready);
    logic client_ar_sample_q;

    integer sample_client;
    logic [CLIENTS-1:0][1:0] client_resp_sample_q;
    always @(posedge clk) begin
        if (rst) begin
            ar_sample_q <= 1'b0;
            r_sample_q <= 1'b0;
            client_ar_sample_q <= 1'b0;
            client_r_sample_q <= '0;
        end else begin
            ar_sample_q <= ar_fire;
            client_ar_sample_q <= client_ar_fire;
            ar_addr_sample_q <= m_araddr;
            ar_len_sample_q <= m_arlen;
            ar_size_sample_q <= m_arsize;
            ar_burst_sample_q <= m_arburst;
            r_sample_q <= r_fire;
            r_data_sample_q <= m_rdata;
            r_resp_sample_q <= m_rresp;
            r_last_sample_q <= m_rlast;
            for (sample_client = 0; sample_client < CLIENTS;
                 sample_client = sample_client + 1) begin
                client_r_sample_q[sample_client] <=
                    s_rvalid[sample_client] && s_rready[sample_client];
                client_data_sample_q[sample_client] <=
                    s_rdata[sample_client];
                client_last_sample_q[sample_client] <=
                    s_rlast[sample_client];
                client_resp_sample_q[sample_client] <= s_rresp[sample_client];
            end
        end
    end

    // ------------------------------------------------------------------
    // Downstream AXI BFM. It queues ARs in issue order and emits one ordered
    // burst at a time, with a delayed first response to expose overlap.
    // ------------------------------------------------------------------
    integer bfm_owner [0:BFM_DEPTH-1];
    integer bfm_txn [0:BFM_DEPTH-1];
    integer bfm_len [0:BFM_DEPTH-1];
    integer bfm_head, bfm_tail, bfm_count;
    integer bfm_beat, bfm_delay;
    logic bfm_active;
    integer cycle_count;
    integer ar_count, axi_beat_count;
    integer max_inflight, inflight_count;

    always_comb begin
        // AR backpressure is deterministic but never permanent.
        // Make the first normal-phase descriptor downstream-ready so the
        // optional fall-through path can be measured as a true same-cycle
        // handshake.  Later ARs retain deterministic backpressure for the
        // multi-descriptor overlap/error checks.
        m_arready = force_ar_stall ? 1'b0 :
                    ((phase == 3) ? 1'b1 :
                     (((phase == 1) && (ar_count == 0)) ? 1'b1 :
                      ((cycle_count % 4) != 1)));
        m_rdata = 128'd0;
        m_rresp = TEST_RRESP;
        m_rlast = 1'b0;
        m_rvalid = 1'b0;
        if (bfm_active) begin
            m_rdata = make_data(bfm_owner[bfm_head], bfm_txn[bfm_head],
                                bfm_beat);
            m_rvalid = (bfm_delay == 0);
            // Directed malformed cases: every owner txn0 is early at beat 1;
            // every owner txn1 omits physical RLAST.
            if ((phase == 2) && (bfm_txn[bfm_head] == 0))
                m_rlast = (bfm_beat == 1);
            else if ((phase == 2) && (bfm_txn[bfm_head] == 1))
                m_rlast = 1'b0;
            else
                m_rlast = (bfm_beat == bfm_len[bfm_head]);
        end
    end

    always_comb begin
        // Independent client backpressure exercises the DUT RREADY gating.
        s_rready[0] = ((cycle_count % 7) != 2);
        s_rready[1] = ((cycle_count % 5) != 1);
    end

    task automatic fail(input string message);
        begin
            $display("C1_AXI_N_READ_BURST_ARBITER_FAIL t=%0t phase=%0d ar=%0d beats=%0d bfm_count=%0d active=%b head=%0d beat=%0d: %s",
                     $time, phase, ar_count, axi_beat_count, bfm_count,
                     bfm_active, bfm_head, bfm_beat, message);
            $fatal(1);
        end
    endtask

    // ------------------------------------------------------------------
    // Ordered response scoreboard. It shares the negedge process with the BFM
    // so AR enqueue and response retirement are observed coherently.
    // ------------------------------------------------------------------
    integer expected_owner [0:BFM_DEPTH-1];
    integer expected_txn [0:BFM_DEPTH-1];
    integer expected_term [0:BFM_DEPTH-1];
    integer expected_head, expected_tail, expected_count;
    integer expected_beat;
    integer response_count;
    integer first_client_ar_cycle;
    integer first_downstream_ar_cycle;
    integer normal_first_ar_latency_saved;
    integer hold_capture_count;

    integer c;
    always @(negedge clk) begin
        if (rst) begin
            bfm_head = 0;
            bfm_tail = 0;
            bfm_count = 0;
            bfm_beat = 0;
            bfm_delay = 0;
            bfm_active = 1'b0;
            cycle_count = 0;
            ar_count = 0;
            axi_beat_count = 0;
            max_inflight = 0;
            inflight_count = 0;
            expected_head = 0;
            expected_tail = 0;
            expected_count = 0;
            expected_beat = 0;
            response_count = 0;
            first_client_ar_cycle = -1;
            first_downstream_ar_cycle = -1;
        end else begin
            cycle_count = cycle_count + 1;

            if (client_ar_sample_q && (first_client_ar_cycle < 0))
                first_client_ar_cycle = cycle_count;
            if (ar_sample_q && (first_downstream_ar_cycle < 0))
                first_downstream_ar_cycle = cycle_count;

            if (ar_sample_q) begin
                integer owner_decoded;
                integer txn_decoded;
                owner_decoded = (ar_addr_sample_q - 32'h4000_0000) >> 16;
                txn_decoded = ((ar_addr_sample_q - 32'h4000_0000) >> 8) & 8'hff;
                if (owner_decoded < 0 || owner_decoded >= CLIENTS)
                    fail("AR owner decode out of range");
                if (ar_size_sample_q != 3'd4 ||
                    ar_burst_sample_q != 2'b01)
                    fail("AR attributes mismatch");
                if (ar_len_sample_q > 8'd7)
                    fail("unexpectedly long AR burst");
                if (bfm_count >= BFM_DEPTH)
                    fail("BFM descriptor queue overflow");
                bfm_owner[bfm_tail] = owner_decoded;
                bfm_txn[bfm_tail] = txn_decoded;
                bfm_len[bfm_tail] = ar_len_sample_q;
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                ar_count = ar_count + 1;
                inflight_count = inflight_count + 1;
                if (inflight_count > max_inflight)
                    max_inflight = inflight_count;

                expected_owner[expected_tail] = owner_decoded;
                expected_txn[expected_tail] = txn_decoded;
                if ((phase == 2) && (txn_decoded == 0))
                    expected_term[expected_tail] = 1;
                else
                    expected_term[expected_tail] = ar_len_sample_q;
                expected_tail = (expected_tail + 1) % BFM_DEPTH;
                expected_count = expected_count + 1;
            end

            if (r_sample_q) begin
                axi_beat_count = axi_beat_count + 1;
                if (r_last_sample_q ||
                    (bfm_beat == bfm_len[bfm_head])) begin
                    bfm_active = 1'b0;
                    bfm_head = (bfm_head + 1) % BFM_DEPTH;
                    bfm_count = bfm_count - 1;
                    inflight_count = inflight_count - 1;
                end else begin
                    bfm_beat = bfm_beat + 1;
                end
            end

            // Start or advance the BFM only after sampled handshakes have been
            // consumed. State changes at negedge remain stable to next posedge.
            if (!bfm_active && (bfm_count != 0)) begin
                bfm_active = 1'b1;
                bfm_beat = 0;
                bfm_delay = (ar_count <= 1) ? 6 : 1;
            end else if (bfm_active && (bfm_delay != 0)) begin
                bfm_delay = bfm_delay - 1;
            end

            if (client_r_sample_q[0] && client_r_sample_q[1])
                fail("one ID-less R beat was delivered to two clients");
            for (c = 0; c < CLIENTS; c = c + 1) begin
                if (client_r_sample_q[c]) begin
                    if (expected_count == 0 ||
                        expected_owner[expected_head] != c)
                        fail("response owner/order mismatch");
                    if (client_data_sample_q[c] !==
                        make_data(c, expected_txn[expected_head], expected_beat))
                        fail("response payload mismatch");
                    if (client_last_sample_q[c] !== r_last_sample_q)
                        fail("physical/client RLAST mismatch");
                    if (client_resp_sample_q[c] !==
                        (((phase==2) && (expected_beat==expected_term[expected_head]) && !TEST_RRESP[1])
                         ? 2'b10 : TEST_RRESP))
                        fail("client length-error RRESP mismatch");
                    // The scoreboard retires using the injected transaction
                    // length; never infer internal ownership from a repaired
                    // RLAST value. Missing RLAST must remain visible.
                    if (expected_beat == expected_term[expected_head]) begin
                        expected_head = (expected_head + 1) % BFM_DEPTH;
                        expected_count = expected_count - 1;
                        expected_beat = 0;
                    end else begin
                        expected_beat = expected_beat + 1;
                    end
                    response_count = response_count + 1;
                end
            end
        end
    end

    task automatic send_ar(input integer owner, input integer txn,
                           input integer len);
        begin
            @(negedge clk); #1;
            s_araddr[owner] = make_addr(owner, txn);
            s_arlen[owner] = len;
            s_arsize[owner] = 3'd4;
            s_arburst[owner] = 2'b01;
            s_arvalid[owner] = 1'b1;
            // Observe the actual handshake edge. Polling READY only at
            // negedge can miss a grant that appears at the next posedge and
            // leave VALID asserted for an extra cycle, duplicating an AR.
            while (1) begin
                @(posedge clk);
                if (s_arready[owner])
                    break;
            end
            @(negedge clk); #1;
            s_arvalid[owner] = 1'b0;
            // Guard edge: do not re-enter VALID on the same falling edge that
            // clears the previous descriptor.
            @(posedge clk);
        end
    endtask

    task automatic drive_client(input integer owner, input integer count);
        integer txn;
        begin
            for (txn = 0; txn < count; txn = txn + 1)
                send_ar(owner, txn, (txn == 2) ? 1 : 2);
        end
    endtask

    integer timeout_count;
    initial begin
        s_arvalid = '0;
        s_araddr = '0;
        s_arlen = '0;
        s_arsize = '0;
        s_arburst = '0;
        timeout_count = 0;
        normal_first_ar_latency_saved = -1;
        hold_capture_count = 0;

        repeat (6) @(posedge clk);
        // Optional-only hold test: accept the source AR while downstream is
        // stalled, then change the live source payload.  The registered hold
        // entry must keep the downstream AR stable until ARREADY returns.
        if (EMPTY_AR_BYPASS_MODE) begin
            logic [31:0] held_addr;
            @(negedge clk); #1;
            phase = 3;
            force_ar_stall = 1'b1;
            rst = 1'b0;
            held_addr = make_addr(0, 7);
            send_ar(0, 7, 0);
            @(negedge clk); #1;
            s_araddr[0] = 32'hDEAD_BEE0;
            repeat (2) begin
                @(negedge clk); #1;
                if (!m_arvalid || (m_araddr != held_addr) ||
                    (m_arlen != 0) || (m_arsize != 3'd4) ||
                    (m_arburst != 2'b01))
                    fail("empty-AR hold register did not preserve payload");
            end
            force_ar_stall = 1'b0;
            timeout_count = 0;
            while (((response_count < 1) || (expected_count != 0) ||
                    (bfm_count != 0) || bfm_active) &&
                   (timeout_count < 1000)) begin
                @(negedge clk); #1;
                timeout_count = timeout_count + 1;
            end
            if (response_count != 1 || expected_count != 0 ||
                bfm_count != 0 || bfm_active || ar_count != 1)
                fail("empty-AR hold phase did not drain cleanly");
            hold_capture_count = 1;
            @(negedge clk); #1;
            phase = 0;
            rst = 1'b1;
            repeat (4) @(posedge clk);
        end
        @(negedge clk); #1;
        phase = 1;
        force_ar_stall = 1'b0;
        rst = 1'b0;
        fork
            drive_client(0, NORMAL_TXNS_PER_CLIENT);
            drive_client(1, NORMAL_TXNS_PER_CLIENT);
        join

        timeout_count = 0;
        // Wait for both logical client beats and the physical BFM queue to
        // drain.  response_count can reach its target on the same edge as
        // the final downstream beat; checking only that counter would sample
        // the BFM one delta/cycle before its retirement bookkeeping.
        while (((response_count < 16) || (expected_count != 0) ||
                (bfm_count != 0) || bfm_active) &&
               (timeout_count < 4000)) begin
            @(negedge clk); #1;
            timeout_count = timeout_count + 1;
        end
        if (response_count != 16)
            fail("normal phase response timeout");
        if (expected_count != 0 || bfm_count != 0 || bfm_active ||
            max_inflight < 2 || ar_count != 6)
            fail("normal phase did not prove overlap/order");
        if (protocol_error)
            fail("normal phase unexpectedly raised protocol_error");
        if ((first_client_ar_cycle < 0) || (first_downstream_ar_cycle < 0))
            fail("first AR handshake was not observed");
        if (EMPTY_AR_BYPASS_MODE &&
            (first_downstream_ar_cycle != first_client_ar_cycle))
            fail("empty AR bypass did not remove first descriptor bubble");
        if (!EMPTY_AR_BYPASS_MODE &&
            (first_downstream_ar_cycle != first_client_ar_cycle + 1))
            fail("default first AR latency changed unexpectedly");
        normal_first_ar_latency_saved =
            first_downstream_ar_cycle - first_client_ar_cycle;

        // Reset the DUT and both scoreboards before malformed-RLAST checks.
        @(negedge clk); #1;
        phase = 2;
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;
        timeout_count = 0;
        fork
            drive_client(0, MALFORMED_TXNS_PER_CLIENT);
            drive_client(1, MALFORMED_TXNS_PER_CLIENT);
        join

        while (((response_count < 10) || (expected_count != 0) ||
                (bfm_count != 0) || bfm_active) &&
               (timeout_count < 4000)) begin
            @(negedge clk); #1;
            timeout_count = timeout_count + 1;
        end
        if (response_count != 10)
            fail("malformed phase response timeout");
        if (!early_rlast_error || !missing_rlast_error || !protocol_error)
            fail("malformed RLAST flags were not raised");
        if (orphan_r_error)
            fail("unexpected orphan response");
        if (expected_count != 0 || bfm_count != 0 || bfm_active ||
            ar_count != 4)
            fail("malformed phase left descriptors queued");

        $display("C1_AXI_N_READ_BURST_ARBITER_PASS empty_ar_bypass=%0d first_ar_latency=%0d hold_capture=%0d normal_beats=16 malformed_beats=%0d max_inflight=%0d ar_total=%0d early=%b missing=%b",
                 EMPTY_AR_BYPASS_MODE,
                 normal_first_ar_latency_saved,
                 hold_capture_count, response_count, max_inflight, ar_count,
                 early_rlast_error, missing_rlast_error);
        $finish;
    end
endmodule
