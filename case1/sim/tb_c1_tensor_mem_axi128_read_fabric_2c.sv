`timescale 1ns/1ps

// End-to-end boardless check: two 64-bit leaf packers feed the optional
// multi-outstanding ID-less read fabric and a delayed AXI128 BFM.  The test
// deliberately checks logical response order per client, not just aggregate
// beat counts, so a cross-client routing error cannot hide behind a valid
// total.
module tb_c1_tensor_mem_axi128_read_fabric_2c #(
    parameter integer FAULT_MODE=0, parameter bit STRESS_BACKPRESSURE=0);
    // 1: omit last on the packed 0x1200 beat; 2: terminate the 0x1000
    // two-beat burst after its first beat. Apply to both clients.
    integer injected_faults=0, observed_errors=0;
    localparam integer CLIENTS = 2;
    localparam integer NREQ_PER_CLIENT = 8;
    localparam integer TOTAL_REQ = CLIENTS * NREQ_PER_CLIENT;
    localparam integer EXPECT_DEPTH = 32;
    localparam integer BFM_DEPTH = 32;
`ifdef C1_BEAT_FIFO_FABRIC_TB
    localparam integer LEAF_RESPONSE_DEPTH = STRESS_BACKPRESSURE ? 2 : 32;
    localparam bit LEAF_BEAT_MODE = 1'b1;
`else
    localparam integer LEAF_RESPONSE_DEPTH = STRESS_BACKPRESSURE ? 2 : 64;
    localparam bit LEAF_BEAT_MODE = 1'b0;
`endif
`ifdef C1_REQ_POP_REFILL_FABRIC_TB
    localparam bit LEAF_REQ_POP_REFILL = 1'b1;
`else
    localparam bit LEAF_REQ_POP_REFILL = 1'b0;
`endif
`ifdef C1_EMPTY_AR_BYPASS_FABRIC_TB
    localparam bit EMPTY_AR_BYPASS_MODE = 1'b1;
`else
    localparam bit EMPTY_AR_BYPASS_MODE = 1'b0;
`endif

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [CLIENTS-1:0] req_valid = '0;
    logic [CLIENTS-1:0] req_ready;
    logic [CLIENTS-1:0] req_flush = '0;
    logic [CLIENTS-1:0][31:0] req_addr = '0;
    logic [CLIENTS-1:0] rsp_valid;
    logic [CLIENTS-1:0] rsp_ready;
    logic [CLIENTS-1:0] rsp_error;
    logic [CLIENTS-1:0][63:0] rsp_rdata;

    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_arvalid;
    logic m_arready;
    logic [127:0] m_rdata;
    logic [1:0] m_rresp;
    logic m_rlast;
    logic m_rvalid;
    logic m_rready;

    logic protocol_error, early_rlast_error, missing_rlast_error, orphan_r_error;
    logic [63:0] perf_req_accept_count, perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count, perf_rsp_count;
    logic [63:0] perf_packed_request_count, perf_error_count;
    logic [7:0] perf_leaf_outstanding, perf_max_leaf_outstanding;

    c1_tensor_mem_axi128_read_fabric_2c #(
        .LEAF_REQ_FIFO_DEPTH(16), .LEAF_BURST_BEATS(STRESS_BACKPRESSURE ? 2 : 4),
        .LEAF_MAX_OUTSTANDING(STRESS_BACKPRESSURE ? 1 : 4), .LEAF_RSP_FIFO_DEPTH(LEAF_RESPONSE_DEPTH),
        .FABRIC_FIFO_DEPTH(8), .BUILD_TIMEOUT_CYCLES(3),
        .ALLOW_SAME_LANE_DUP(1'b1),
        .LEAF_RSP_FIFO_BEAT_MODE(LEAF_BEAT_MODE),
        .LEAF_ALLOW_REQ_POP_REFILL(LEAF_REQ_POP_REFILL),
        .EMPTY_AR_BYPASS(EMPTY_AR_BYPASS_MODE)
    ) dut (
        .clk, .rst,
        .req_valid, .req_ready, .req_flush, .req_addr,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata,
        .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid),
        .m_axi_rready(m_rready),
        .protocol_error, .early_rlast_error,
        .missing_rlast_error, .orphan_r_error,
        .perf_req_accept_count, .perf_axi_burst_count,
        .perf_axi_beat_count, .perf_rsp_count,
        .perf_packed_request_count, .perf_error_count,
        .perf_leaf_outstanding, .perf_max_leaf_outstanding
    );

    function automatic [31:0] request_addr(input integer owner,
                                            input integer index);
        begin
            case (index)
                0: request_addr = 32'h0000_1000 + owner * 32'h0001_0000;
                1: request_addr = 32'h0000_1008 + owner * 32'h0001_0000;
                2: request_addr = 32'h0000_1010 + owner * 32'h0001_0000;
                3: request_addr = 32'h0000_1018 + owner * 32'h0001_0000;
                4: request_addr = 32'h0000_1200 + owner * 32'h0001_0000;
                5: request_addr = 32'h0000_1208 + owner * 32'h0001_0000;
                6: request_addr = 32'h0000_1404 + owner * 32'h0001_0000;
                default: request_addr = 32'h0000_1800 + owner * 32'h0001_0000;
            endcase
        end
    endfunction

    function automatic [63:0] logical_data(input [31:0] address);
        logical_data = {address ^ 32'h5a5a_0000, address + 32'h1357_9bdf};
    endfunction

    logic [63:0] expected_data [0:CLIENTS-1][0:EXPECT_DEPTH-1];
    logic expected_error [0:CLIENTS-1][0:EXPECT_DEPTH-1];
    integer expected_head [0:CLIENTS-1];
    integer expected_tail [0:CLIENTS-1];
    integer expected_count [0:CLIENTS-1];
    integer response_count;

    // Sample downstream handshakes on the rising edge; consume them and
    // update the delayed BFM on the falling edge.  This avoids races between
    // DUT NBA state and BFM queue updates.
    logic ar_sample_q, r_sample_q;
    logic [31:0] ar_addr_sample_q;
    logic [7:0] ar_len_sample_q;
    logic [127:0] r_data_sample_q;
    logic r_last_sample_q;
    logic [1:0] r_resp_sample_q;
    integer cycle_count, ar_count, axi_beat_count;
    integer bfm_owner [0:BFM_DEPTH-1];
    integer bfm_base [0:BFM_DEPTH-1];
    integer bfm_len [0:BFM_DEPTH-1];
    integer bfm_head, bfm_tail, bfm_count, bfm_beat, bfm_delay;
    logic bfm_active;
    integer max_inflight;

    task automatic fail(input string message);
        begin
            $display("C1_TENSOR_MEM_AXI128_READ_FABRIC_FAIL t=%0t ar=%0d beats=%0d responses=%0d bfm=%0d: %s",
                     $time, ar_count, axi_beat_count, response_count,
                     bfm_count, message);
            $fatal(1);
        end
    endtask

    wire ar_fire = m_arvalid && m_arready;
    wire r_fire = m_rvalid && m_rready;

    integer sample_owner;
    logic [1:0] held_rsp=0;
    logic [1:0][64:0] held_payload;
    integer hold_checks=0, full0=0, full1=0, physical_stalls=0;
    always @(posedge clk) begin
        if (rst) begin
            ar_sample_q <= 1'b0;
            r_sample_q <= 1'b0;
            held_rsp <= 0;
        end else begin
            if (dut.gen_leaf[0].u_leaf.rsp_count_q==LEAF_RESPONSE_DEPTH) full0=full0+1;
            if (dut.gen_leaf[1].u_leaf.rsp_count_q==LEAF_RESPONSE_DEPTH) full1=full1+1;
            if (m_rvalid&&!m_rready) physical_stalls=physical_stalls+1;
            ar_sample_q <= ar_fire;
            ar_addr_sample_q <= m_araddr;
            ar_len_sample_q <= m_arlen;
            r_sample_q <= r_fire;
            r_data_sample_q <= m_rdata;
            r_resp_sample_q <= m_rresp;
            r_last_sample_q <= m_rlast;
            for (sample_owner = 0; sample_owner < CLIENTS;
                 sample_owner = sample_owner + 1) begin
                if (held_rsp[sample_owner]) begin
                    hold_checks=hold_checks+1;
                    if (!rsp_valid[sample_owner] ||
                        {rsp_error[sample_owner],rsp_rdata[sample_owner]} !== held_payload[sample_owner])
                        fail("stalled logical response changed");
                end
                held_rsp[sample_owner] <= rsp_valid[sample_owner]&&!rsp_ready[sample_owner];
                held_payload[sample_owner] <= {rsp_error[sample_owner],rsp_rdata[sample_owner]};
                if (rsp_valid[sample_owner] && rsp_ready[sample_owner]) begin
                    if (expected_count[sample_owner] == 0)
                        fail("unexpected logical response");
                    if (rsp_error[sample_owner] !==
                        expected_error[sample_owner][expected_head[sample_owner]])
                        fail("logical response error mismatch");
                    if (rsp_rdata[sample_owner] !==
                        expected_data[sample_owner][expected_head[sample_owner]])
                        fail("logical response data/order mismatch");
                    expected_head[sample_owner] =
                        (expected_head[sample_owner] + 1) % EXPECT_DEPTH;
                    expected_count[sample_owner] =
                        expected_count[sample_owner] - 1;
                    response_count = response_count + 1;
                    if (rsp_error[sample_owner]) observed_errors = observed_errors + 1;
                end
            end
        end
    end

    always_comb begin
        rsp_ready[0] = !STRESS_BACKPRESSURE || (cycle_count>=300 && cycle_count%5!=1);
        rsp_ready[1] = !STRESS_BACKPRESSURE || (cycle_count>=450 && cycle_count%7!=2);
        m_arready = ((cycle_count % 5) != 1);
        m_rdata = 128'd0;
        m_rresp = 2'b00;
        m_rlast = 1'b0;
        m_rvalid = 1'b0;
        if (bfm_active) begin
            m_rdata[63:0] = logical_data(
                bfm_base[bfm_head] + bfm_beat * 16);
            m_rdata[127:64] = logical_data(
                bfm_base[bfm_head] + bfm_beat * 16 + 8);
            m_rvalid = (bfm_delay == 0);
            m_rlast = (bfm_beat == bfm_len[bfm_head]);
            if (FAULT_MODE==1 && (bfm_base[bfm_head]&16'hffff)==16'h1200)
                m_rlast = 1'b0;
            if (FAULT_MODE==2 && (bfm_base[bfm_head]&16'hffff)==16'h1000)
                m_rlast = (bfm_beat==0);
        end
    end

    integer owner_decoded;
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
        end else begin
            cycle_count = cycle_count + 1;
            if (ar_sample_q) begin
                if (bfm_count >= BFM_DEPTH)
                    fail("BFM descriptor overflow");
                if (ar_addr_sample_q[3:0] != 0 ||
                    ar_len_sample_q > 8'd3)
                    fail("invalid packed AR descriptor");
                owner_decoded = (ar_addr_sample_q[16:12] == 5'h0) ? 0 : 1;
                bfm_owner[bfm_tail] = owner_decoded;
                bfm_base[bfm_tail] = ar_addr_sample_q;
                bfm_len[bfm_tail] = ar_len_sample_q;
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                ar_count = ar_count + 1;
                if (bfm_count > max_inflight)
                    max_inflight = bfm_count;
            end
            if (r_sample_q) begin
                axi_beat_count = axi_beat_count + 1;
                if (bfm_count == 0)
                    fail("R without AR descriptor");
                if (r_data_sample_q[63:0] !==
                    logical_data(bfm_base[bfm_head] + bfm_beat * 16) ||
                    r_data_sample_q[127:64] !==
                    logical_data(bfm_base[bfm_head] + bfm_beat * 16 + 8))
                    fail("AXI R payload mismatch");
                if (FAULT_MODE==1 && (bfm_base[bfm_head]&16'hffff)==16'h1200) begin
                    if (bfm_len[bfm_head]!=0 || r_last_sample_q) fail("missing-last injection invalid");
                    injected_faults=injected_faults+1;
                end else if (FAULT_MODE==2 && (bfm_base[bfm_head]&16'hffff)==16'h1000) begin
                    if (bfm_len[bfm_head]!=1 || bfm_beat!=0 || !r_last_sample_q) fail("early-last injection invalid");
                    injected_faults=injected_faults+1;
                end else if (r_last_sample_q != (bfm_beat == bfm_len[bfm_head]))
                    fail("AXI RLAST mismatch");
                // The faulty source ends at the declared length or its early
                // LAST; it never emits ambiguous extra physical beats.
                if (r_last_sample_q || bfm_beat == bfm_len[bfm_head]) begin
                    bfm_head = (bfm_head + 1) % BFM_DEPTH;
                    bfm_count = bfm_count - 1;
                    bfm_active = 1'b0;
                end else begin
                    bfm_beat = bfm_beat + 1;
                end
            end
            if (!bfm_active && bfm_count != 0) begin
                bfm_active = 1'b1;
                bfm_beat = 0;
                bfm_delay = (ar_count <= 1) ? 8 : 1;
            end else if (bfm_active && bfm_delay != 0) begin
                bfm_delay = bfm_delay - 1;
            end
        end
    end

    task automatic send_request(input integer owner, input integer index);
        reg [31:0] address;
        begin
            address = request_addr(owner, index);
            @(negedge clk); #1;
            req_addr[owner] = address;
            req_valid[owner] = 1'b1;
            while (1) begin
                @(posedge clk);
                if (req_ready[owner]) begin
                    @(negedge clk); #1;
                    req_valid[owner] = 1'b0;
                    if (expected_count[owner] >= EXPECT_DEPTH)
                        fail("expected queue overflow");
                    expected_data[owner][expected_tail[owner]] =
                        ((address[2:0] != 0) || (FAULT_MODE==2 && (index==2 || index==3)))
                        ? 64'd0 : logical_data(address);
                    expected_error[owner][expected_tail[owner]] =
                        (address[2:0] != 0) || (FAULT_MODE==1 && (index==4 || index==5)) ||
                        (FAULT_MODE==2 && index<4);
                    expected_tail[owner] =
                        (expected_tail[owner] + 1) % EXPECT_DEPTH;
                    expected_count[owner] = expected_count[owner] + 1;
                    break;
                end
            end
        end
    endtask

    task automatic flush_client(input integer owner);
        begin
            @(negedge clk); #1;
            req_flush[owner] = 1'b1;
            @(posedge clk);
            @(negedge clk); #1;
            req_flush[owner] = 1'b0;
        end
    endtask

    integer init_i;
    integer idx0, idx1;
    integer timeout_count;
    initial begin
        req_valid = '0;
        req_flush = '0;
        for (init_i = 0; init_i < CLIENTS; init_i = init_i + 1) begin
            expected_head[init_i] = 0;
            expected_tail[init_i] = 0;
            expected_count[init_i] = 0;
        end
        response_count = 0;
        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;
        fork
            begin
                for (idx0 = 0; idx0 < NREQ_PER_CLIENT; idx0 = idx0 + 1)
                    send_request(0, idx0);
                flush_client(0);
            end
            begin
                for (idx1 = 0; idx1 < NREQ_PER_CLIENT; idx1 = idx1 + 1)
                    send_request(1, idx1);
                flush_client(1);
            end
        join

        timeout_count = 0;
        while ((response_count < TOTAL_REQ || bfm_count != 0 ||
                bfm_active) && (timeout_count < 12000)) begin
            @(negedge clk); #1;
            timeout_count = timeout_count + 1;
        end
        if (response_count != TOTAL_REQ)
            fail("logical response timeout");
        if (bfm_count != 0 || bfm_active)
            fail("BFM did not drain");
        if (perf_req_accept_count != TOTAL_REQ ||
            perf_rsp_count != TOTAL_REQ)
            fail("logical traffic counter mismatch");
        if (perf_axi_burst_count != ar_count ||
            perf_axi_beat_count != axi_beat_count)
            fail("AXI traffic counter mismatch");
        if (perf_packed_request_count == 0)
            fail("packing was not exercised");
        if (max_inflight < 2)
            fail("fabric did not prove multiple outstanding reads");
        if (protocol_error !== (FAULT_MODE!=0) || early_rlast_error !== (FAULT_MODE==2) ||
            missing_rlast_error !== (FAULT_MODE==1) || orphan_r_error)
            fail("integrated read error flags mismatch");
        if (injected_faults!=(FAULT_MODE==0?0:2) ||
            observed_errors!=(FAULT_MODE==0?2:(FAULT_MODE==1?6:10)) ||
            expected_count[0]!=0 || expected_count[1]!=0)
            fail("fault/response accounting mismatch");
        if (FAULT_MODE!=0)
            $display("C1_READ_FABRIC_FAULT_PASS mode=%0d injected=%0d errors=%0d responses=%0d beat_fifo=%0d",
                FAULT_MODE,injected_faults,observed_errors,response_count,LEAF_BEAT_MODE);
        if (STRESS_BACKPRESSURE) begin
            if (full0<20 || full1<20 || hold_checks<100)
                fail("FIFO full/long backpressure coverage missing");
            $display("C1_READ_FAULT_BACKPRESSURE_PASS mode=%0d beat_fifo=%0d full0=%0d full1=%0d holds=%0d r_stalls=%0d",
                FAULT_MODE,LEAF_BEAT_MODE,full0,full1,hold_checks,physical_stalls);
        end

        $display("C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS req=%0d ar=%0d beats=%0d packed=%0d max_inflight=%0d req_pop_refill=%0d empty_ar_bypass=%0d",
                 perf_req_accept_count, ar_count, axi_beat_count,
                 perf_packed_request_count, max_inflight,
                 LEAF_REQ_POP_REFILL, EMPTY_AR_BYPASS_MODE);
        $finish;
    end
endmodule
