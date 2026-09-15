`timescale 1ns/1ps

// Boardless integration regression for
// c1_tensor_mem_axi128_write_mlp_fabric_2c.
//
// Client 0 is driven through the logical descriptor/64-bit stream and must
// produce two packed AXI128 descriptors.  Client 1 is a raw AXI128 peer.  The
// downstream BFM accepts all AWs while W is held off, then consumes W/B in
// issue order and routes the B response to the owner selected by the DUT.
// The two-phase (posedge snapshot, negedge consume) discipline keeps the BFM
// and scoreboards out of active/NBA races.
module tb_c1_tensor_mem_axi128_write_mlp_fabric_2c;
    localparam integer MAX_OUTSTANDING = 2;
    localparam integer MAX_BEATS = 4;
`ifdef C1_FABRIC_RSP_POP_REFILL_TB
    localparam integer ADAPTER_RSP_FIFO_DEPTH = 2;
    localparam bit ALLOW_RSP_POP_REFILL = 1'b1;
`else
    localparam integer ADAPTER_RSP_FIFO_DEPTH = 4;
    localparam bit ALLOW_RSP_POP_REFILL = 1'b0;
`endif
    localparam integer FABRIC_FIFO_DEPTH = 4;
    localparam integer TAG_WIDTH = 8;
    localparam integer PEER_DESC = 2;
    localparam integer ADAPTER_DESC = 2;
    localparam integer ADAPTER_WORDS = 4;
    localparam integer TOTAL_AW = ADAPTER_DESC + PEER_DESC;
    localparam integer TOTAL_W = ADAPTER_DESC * 2 + 2 + 1;
    localparam integer TOTAL_ADAPTER_RSP = ADAPTER_DESC * ADAPTER_WORDS;
    localparam integer BFM_DEPTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // Adapter logical interface.
    logic adapter_cmd_valid = 1'b0;
    logic adapter_cmd_ready;
    logic [31:0] adapter_cmd_addr = '0;
    logic [9:0] adapter_cmd_logical_count = '0;
    logic adapter_req_valid = 1'b0;
    logic adapter_req_ready;
    logic adapter_req_last = 1'b0;
    logic adapter_req_flush = 1'b0;
    logic [31:0] adapter_req_addr = '0;
    logic [63:0] adapter_req_wdata = '0;
    logic [7:0] adapter_req_wstrb = 8'hff;
    logic adapter_rsp_valid;
    logic adapter_rsp_ready;
    logic adapter_rsp_error;
    logic [63:0] adapter_rsp_rdata;
    logic [TAG_WIDTH-1:0] adapter_rsp_tag;

    // Raw peer AXI128 interface.
    logic [31:0] peer_awaddr = '0;
    logic [7:0] peer_awlen = '0;
    logic [2:0] peer_awsize = '0;
    logic [1:0] peer_awburst = '0;
    logic peer_awvalid = 1'b0;
    logic peer_awready;
    logic [127:0] peer_wdata = '0;
    logic [15:0] peer_wstrb = '0;
    logic peer_wlast = 1'b0;
    logic peer_wvalid = 1'b0;
    logic peer_wready;
    logic [1:0] peer_bresp;
    logic peer_bvalid;
    logic peer_bready;

    // Shared downstream AXI128 port.
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

    logic adapter_protocol_error;
    logic adapter_early_req_last_error, adapter_late_req_last_error;
    logic adapter_req_flush_error, adapter_orphan_req_error;
    logic adapter_request_address_error;
    logic fabric_protocol_error;
    logic fabric_early_wlast_error, fabric_missing_wlast_error;
    logic fabric_early_b_error, fabric_orphan_b_error;
    logic protocol_error;
    logic [63:0] perf_adapter_cmd_count, perf_adapter_logical_req_count;
    logic [63:0] perf_adapter_burst_count, perf_adapter_axi_beat_count;
    logic [63:0] perf_adapter_rsp_count, perf_adapter_packed_pair_count;
    logic [7:0] perf_adapter_max_outstanding;
    logic [7:0] perf_fabric_outstanding, perf_fabric_max_outstanding;
    logic [63:0] perf_fabric_aw_accept_count, perf_fabric_aw_issue_count;
    logic [63:0] perf_fabric_w_beat_count, perf_fabric_b_count;

    c1_tensor_mem_axi128_write_mlp_fabric_2c #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        .ADAPTER_RSP_FIFO_DEPTH(ADAPTER_RSP_FIFO_DEPTH),
        .TAG_WIDTH(TAG_WIDTH),
        .FABRIC_FIFO_DEPTH(FABRIC_FIFO_DEPTH),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL)
    ) dut (
        .clk, .rst,
        .adapter_cmd_valid, .adapter_cmd_ready, .adapter_cmd_addr,
        .adapter_cmd_logical_count,
        .adapter_req_valid, .adapter_req_ready, .adapter_req_last,
        .adapter_req_flush, .adapter_req_addr, .adapter_req_wdata,
        .adapter_req_wstrb,
        .adapter_rsp_valid, .adapter_rsp_ready, .adapter_rsp_error,
        .adapter_rsp_rdata, .adapter_rsp_tag,
        .peer_awaddr, .peer_awlen, .peer_awsize, .peer_awburst,
        .peer_awvalid, .peer_awready,
        .peer_wdata, .peer_wstrb, .peer_wlast, .peer_wvalid, .peer_wready,
        .peer_bresp, .peer_bvalid, .peer_bready,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid,
        .m_axi_wready, .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
        .adapter_protocol_error, .adapter_early_req_last_error,
        .adapter_late_req_last_error, .adapter_req_flush_error,
        .adapter_orphan_req_error, .adapter_request_address_error,
        .fabric_protocol_error, .fabric_early_wlast_error,
        .fabric_missing_wlast_error, .fabric_early_b_error,
        .fabric_orphan_b_error, .protocol_error,
        .perf_adapter_cmd_count, .perf_adapter_logical_req_count,
        .perf_adapter_burst_count, .perf_adapter_axi_beat_count,
        .perf_adapter_rsp_count, .perf_adapter_packed_pair_count,
        .perf_adapter_max_outstanding, .perf_fabric_outstanding,
        .perf_fabric_max_outstanding, .perf_fabric_aw_accept_count,
        .perf_fabric_aw_issue_count, .perf_fabric_w_beat_count,
        .perf_fabric_b_count
    );

    integer cycle_count;
    integer aw_count, w_count, b_count;
    integer adapter_rsp_seen, peer_b_seen;
    integer bfm_head, bfm_tail, bfm_count, max_bfm_count;
    integer bfm_w_beat [0:BFM_DEPTH-1];
    integer bfm_owner [0:BFM_DEPTH-1];
    integer bfm_desc [0:BFM_DEPTH-1];
    integer bfm_len [0:BFM_DEPTH-1];
    logic bfm_w_done [0:BFM_DEPTH-1];
    logic bfm_b_started [0:BFM_DEPTH-1];
    logic [1:0] bfm_bresp [0:BFM_DEPTH-1];
    integer bfm_b_delay;
    logic bfm_bvalid_q;
    logic [1:0] bfm_bresp_q;
    logic w_enable;
    logic saw_aw_ahead;
    logic adapter_rsp_backpressure_seen;
    logic peer_b_backpressure_seen;
    logic full_pop_push_seen;

    // Handshake snapshots are captured before DUT NBA updates and consumed
    // by the BFM/scoreboards at the following falling edge.
    logic aw_sample_q, w_sample_q, b_sample_q;
    logic adapter_rsp_sample_q, peer_b_sample_q;
    logic [31:0] aw_addr_sample_q;
    logic [7:0] aw_len_sample_q;
    logic [2:0] aw_size_sample_q;
    logic [1:0] aw_burst_sample_q;
    logic [127:0] w_data_sample_q;
    logic [15:0] w_strb_sample_q;
    logic w_last_sample_q;
    logic [1:0] b_resp_sample_q;
    logic [63:0] adapter_rsp_data_sample_q;
    logic adapter_rsp_error_sample_q;
    logic [TAG_WIDTH-1:0] adapter_rsp_tag_sample_q;
    logic [1:0] peer_b_resp_sample_q;

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire adapter_rsp_fire = adapter_rsp_valid && adapter_rsp_ready;
    wire peer_b_fire = peer_bvalid && peer_bready;

    function automatic [63:0] adapter_word_data(input integer desc,
                                                  input integer word);
        adapter_word_data = 64'hA100_0000_0000_0000 +
                            (desc * 16'h100) + word;
    endfunction

    function automatic [63:0] peer_word_data(input integer desc,
                                               input integer word);
        peer_word_data = 64'hB200_0000_0000_0000 +
                         (desc * 16'h100) + word;
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_TENSOR_MEM_AXI128_WRITE_MLP_FABRIC_2C_FAIL t=%0t aw=%0d w=%0d b=%0d adapter_rsp=%0d peer_b=%0d q=%0d max_q=%0d: %s",
                     $time, aw_count, w_count, b_count, adapter_rsp_seen,
                     peer_b_seen, bfm_count, max_bfm_count, message);
            $fatal(1);
        end
    endtask

    // Keep W blocked until all four AW descriptors are visible.  AWREADY is
    // independently stalled to exercise payload hold on the shared channel.
    always_comb begin
        m_axi_awready = ((cycle_count % 5) != 1);
        m_axi_wready = w_enable && ((cycle_count % 4) != 2);
        m_axi_bvalid = bfm_bvalid_q;
        m_axi_bresp = bfm_bresp_q;
        // Hold both client-side response paths closed for a bounded window
        // after the shared BFM starts.  This guarantees that BVALID and the
        // adapter's logical response remain asserted across backpressure,
        // then releases them with a deterministic sparse-ready pattern.
        adapter_rsp_ready = (cycle_count >= 220) && ((cycle_count % 7) != 3);
        peer_bready = (cycle_count >= 220) && ((cycle_count % 6) != 2);
    end

    always @(posedge clk) begin
        if (rst) begin
            aw_sample_q <= 1'b0;
            w_sample_q <= 1'b0;
            b_sample_q <= 1'b0;
            adapter_rsp_sample_q <= 1'b0;
            peer_b_sample_q <= 1'b0;
        end else begin
            if (ALLOW_RSP_POP_REFILL &&
                (dut.u_adapter.u_backend.rsp_count_q == ADAPTER_RSP_FIFO_DEPTH) &&
                adapter_rsp_fire && dut.adapter_bvalid && dut.adapter_bready)
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
            adapter_rsp_sample_q <= adapter_rsp_fire;
            adapter_rsp_data_sample_q <= adapter_rsp_rdata;
            adapter_rsp_error_sample_q <= adapter_rsp_error;
            adapter_rsp_tag_sample_q <= adapter_rsp_tag;
            peer_b_sample_q <= peer_b_fire;
            peer_b_resp_sample_q <= peer_bresp;
        end
    end

    always @(negedge clk) begin : bfm_and_scoreboard
        integer i;
        integer owner;
        integer desc;
        integer beat;
        logic expected_last;
        logic [63:0] expected_lo;
        logic [63:0] expected_hi;
        if (rst) begin
            cycle_count = 0;
            aw_count = 0;
            w_count = 0;
            b_count = 0;
            adapter_rsp_seen = 0;
            peer_b_seen = 0;
            bfm_head = 0;
            bfm_tail = 0;
            bfm_count = 0;
            max_bfm_count = 0;
            bfm_b_delay = 0;
            bfm_bvalid_q = 1'b0;
            bfm_bresp_q = 2'b00;
            w_enable = 1'b0;
            saw_aw_ahead = 1'b0;
            adapter_rsp_backpressure_seen = 1'b0;
            peer_b_backpressure_seen = 1'b0;
            full_pop_push_seen = 1'b0;
            for (i = 0; i < BFM_DEPTH; i = i + 1) begin
                bfm_w_beat[i] = 0;
                bfm_owner[i] = 0;
                bfm_desc[i] = 0;
                bfm_len[i] = 0;
                bfm_w_done[i] = 1'b0;
                bfm_b_started[i] = 1'b0;
                bfm_bresp[i] = 2'b00;
            end
        end else begin
            cycle_count = cycle_count + 1;
            if (adapter_rsp_valid && !adapter_rsp_ready)
                adapter_rsp_backpressure_seen = 1'b1;
            if (peer_bvalid && !peer_bready)
                peer_b_backpressure_seen = 1'b1;

            if (aw_sample_q) begin
                if (bfm_count >= BFM_DEPTH)
                    fail("downstream AW queue overflow");
                if (aw_addr_sample_q[3:0] != 0 || aw_size_sample_q != 3'd4 ||
                    aw_burst_sample_q != 2'b01 ||
                    ({1'b0, aw_addr_sample_q[11:0]} +
                     ({5'd0, aw_len_sample_q} + 1'b1) * 13'd16 > 13'd4096))
                    fail("invalid or crossing shared AW");
                if ((aw_addr_sample_q >= 32'h0000_1000) &&
                    (aw_addr_sample_q < 32'h0000_1200)) begin
                    owner = 0;
                    desc = (aw_addr_sample_q - 32'h0000_1000) >> 8;
                    if (aw_len_sample_q != 8'd1 || desc < 0 || desc >= ADAPTER_DESC)
                        fail("adapter AW descriptor mismatch");
                end else if ((aw_addr_sample_q >= 32'h0000_3000) &&
                             (aw_addr_sample_q < 32'h0000_3100)) begin
                    owner = 1;
                    desc = (aw_addr_sample_q - 32'h0000_3000) >> 6;
                    if ((desc == 0 && aw_len_sample_q != 8'd1) ||
                        (desc == 1 && aw_len_sample_q != 8'd0) ||
                        desc < 0 || desc >= PEER_DESC)
                        fail("peer AW descriptor mismatch");
                end else begin
                    fail("unknown AW owner/address");
                end
                bfm_owner[bfm_tail] = owner;
                bfm_desc[bfm_tail] = desc;
                bfm_len[bfm_tail] = aw_len_sample_q;
                bfm_w_beat[bfm_tail] = 0;
                bfm_w_done[bfm_tail] = 1'b0;
                bfm_b_started[bfm_tail] = 1'b0;
                // Return SLVERR for adapter descriptor 1 and peer descriptor
                // 1; this checks B routing and adapter error propagation.
                bfm_bresp[bfm_tail] = ((owner == 0 && desc == 1) ||
                                       (owner == 1 && desc == 1)) ?
                                      2'b10 : 2'b00;
                bfm_tail = (bfm_tail + 1) % BFM_DEPTH;
                bfm_count = bfm_count + 1;
                aw_count = aw_count + 1;
                if (bfm_count > max_bfm_count)
                    max_bfm_count = bfm_count;
            end

            if (aw_count >= TOTAL_AW && !w_enable) begin
                w_enable = 1'b1;
                if (w_count == 0)
                    saw_aw_ahead = 1'b1;
            end

            if (w_sample_q) begin
                if (bfm_count == 0)
                    fail("W arrived without an issued AW");
                owner = bfm_owner[bfm_head];
                desc = bfm_desc[bfm_head];
                beat = bfm_w_beat[bfm_head];
                if (w_strb_sample_q !== 16'hffff)
                    fail("shared W strobe mismatch");
                expected_last = (beat == bfm_len[bfm_head]);
                if (w_last_sample_q !== expected_last)
                    fail("shared WLAST/order mismatch");
                if (owner == 0) begin
                    expected_lo = adapter_word_data(desc, beat * 2);
                    expected_hi = adapter_word_data(desc, beat * 2 + 1);
                end else begin
                    expected_lo = peer_word_data(desc, beat * 2);
                    expected_hi = peer_word_data(desc, beat * 2 + 1);
                end
                if (w_data_sample_q[63:0] !== expected_lo ||
                    w_data_sample_q[127:64] !== expected_hi)
                    fail("shared W payload/order mismatch");
                w_count = w_count + 1;
                bfm_w_beat[bfm_head] = beat + 1;
                if (w_last_sample_q) begin
                    bfm_w_done[bfm_head] = 1'b1;
                    bfm_b_delay = 3;
                end
            end

            // B is emitted only for the oldest completed descriptor and is
            // held until the shared arbiter (and then the owning client) is
            // ready.  AXI B order is therefore checked against AW order.
            if (!bfm_bvalid_q && (bfm_count != 0) &&
                bfm_w_done[bfm_head] && !bfm_b_started[bfm_head]) begin
                if (bfm_b_delay != 0)
                    bfm_b_delay = bfm_b_delay - 1;
                else begin
                    bfm_bvalid_q = 1'b1;
                    bfm_bresp_q = bfm_bresp[bfm_head];
                    bfm_b_started[bfm_head] = 1'b1;
                end
            end
            if (b_sample_q) begin
                if (!bfm_bvalid_q || bfm_count == 0)
                    fail("unexpected shared B handshake");
                if (b_resp_sample_q !== bfm_bresp_q)
                    fail("shared BRESP changed/order mismatch");
                if (bfm_owner[bfm_head] == 1) begin
                    if (!peer_b_sample_q)
                        fail("peer B was not routed for peer-owned burst");
                end else if (peer_b_sample_q) begin
                    fail("peer B appeared for adapter-owned burst");
                end
                bfm_bvalid_q = 1'b0;
                bfm_head = (bfm_head + 1) % BFM_DEPTH;
                bfm_count = bfm_count - 1;
                b_count = b_count + 1;
            end else if (peer_b_sample_q) begin
                fail("peer B handshake without shared B retirement");
            end

            if (adapter_rsp_sample_q) begin
                if (adapter_rsp_seen >= TOTAL_ADAPTER_RSP)
                    fail("excess adapter logical response");
                desc = adapter_rsp_seen / ADAPTER_WORDS;
                beat = adapter_rsp_seen % ADAPTER_WORDS;
                if (adapter_rsp_tag_sample_q !== desc[TAG_WIDTH-1:0])
                    fail("adapter response tag/order mismatch");
                if (adapter_rsp_data_sample_q !== adapter_word_data(desc, beat))
                    fail("adapter response data/order mismatch");
                if (adapter_rsp_error_sample_q !== (desc == 1))
                    fail("adapter response error propagation mismatch");
                adapter_rsp_seen = adapter_rsp_seen + 1;
            end
            if (peer_b_sample_q)
                peer_b_seen = peer_b_seen + 1;
        end
    end

    task automatic send_adapter_cmd(input logic [31:0] address,
                                    input integer words);
        begin
            @(negedge clk); #1;
            adapter_cmd_addr = address;
            adapter_cmd_logical_count = words;
            adapter_cmd_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (adapter_cmd_ready)
                    break;
            end
            @(negedge clk); #1;
            adapter_cmd_valid = 1'b0;
        end
    endtask

    task automatic send_adapter_word(input logic [31:0] address,
                                     input logic [63:0] data,
                                     input logic last_value);
        begin
            @(negedge clk); #1;
            adapter_req_addr = address;
            adapter_req_wdata = data;
            adapter_req_wstrb = 8'hff;
            adapter_req_last = last_value;
            adapter_req_flush = 1'b0;
            adapter_req_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (adapter_req_ready)
                    break;
            end
            @(negedge clk); #1;
            adapter_req_valid = 1'b0;
            adapter_req_last = 1'b0;
        end
    endtask

    task automatic send_peer_aw(input integer desc);
        begin
            @(negedge clk); #1;
            peer_awaddr = 32'h0000_3000 + desc * 32'h40;
            peer_awlen = (desc == 0) ? 8'd1 : 8'd0;
            peer_awsize = 3'd4;
            peer_awburst = 2'b01;
            peer_awvalid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (peer_awready)
                    break;
            end
            @(negedge clk); #1;
            peer_awvalid = 1'b0;
        end
    endtask

    task automatic send_peer_w(input integer desc, input integer beat);
        begin
            @(negedge clk); #1;
            peer_wdata = {peer_word_data(desc, beat * 2 + 1),
                          peer_word_data(desc, beat * 2)};
            peer_wstrb = 16'hffff;
            peer_wlast = (beat == ((desc == 0) ? 1 : 0));
            peer_wvalid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (peer_wready)
                    break;
            end
            @(negedge clk); #1;
            peer_wvalid = 1'b0;
            peer_wlast = 1'b0;
        end
    endtask

    initial begin : stimulus
        integer d, w;
        repeat (6) @(posedge clk);
        @(negedge clk); #1;
        rst = 1'b0;
        fork
            begin
                integer ad, aw;
                for (ad = 0; ad < ADAPTER_DESC; ad = ad + 1) begin
                    send_adapter_cmd(32'h0000_1000 + ad * 32'h100,
                                     ADAPTER_WORDS);
                    for (aw = 0; aw < ADAPTER_WORDS; aw = aw + 1)
                        send_adapter_word(32'h0000_1000 + ad * 32'h100 + aw * 8,
                                          adapter_word_data(ad, aw),
                                          (aw == ADAPTER_WORDS - 1));
                end
            end
            begin
                integer pd, pw;
                // Issue both peer AWs before presenting peer W.  This makes
                // the peer a genuine raw descriptor source and exposes the
                // shared AW-ahead queue independently of adapter packing.
                for (pd = 0; pd < PEER_DESC; pd = pd + 1)
                    send_peer_aw(pd);
                for (pd = 0; pd < PEER_DESC; pd = pd + 1)
                    for (pw = 0; pw < ((pd == 0) ? 2 : 1); pw = pw + 1)
                        send_peer_w(pd, pw);
            end
        join

        for (w = 0; w < 5000; w = w + 1) begin
            @(posedge clk);
            if (aw_count == TOTAL_AW && w_count == TOTAL_W &&
                b_count == TOTAL_AW && adapter_rsp_seen == TOTAL_ADAPTER_RSP &&
                peer_b_seen == PEER_DESC && bfm_count == 0 &&
                !bfm_bvalid_q && !m_axi_awvalid && !m_axi_wvalid)
                break;
        end

        if (aw_count != TOTAL_AW || w_count != TOTAL_W || b_count != TOTAL_AW)
            fail("shared AW/W/B count timeout");
        if (adapter_rsp_seen != TOTAL_ADAPTER_RSP || peer_b_seen != PEER_DESC)
            fail("client response count timeout");
        if (bfm_count != 0 || bfm_bvalid_q)
            fail("BFM descriptor queue did not drain");
        if (!saw_aw_ahead || max_bfm_count < 3)
            fail("AW-ahead multi-descriptor overlap was not observed");
        if (perf_adapter_cmd_count != ADAPTER_DESC ||
            perf_adapter_logical_req_count != TOTAL_ADAPTER_RSP ||
            perf_adapter_rsp_count != TOTAL_ADAPTER_RSP)
            fail("adapter logical counters mismatch");
        if (perf_adapter_burst_count != ADAPTER_DESC ||
            perf_adapter_axi_beat_count != ADAPTER_DESC * 2 ||
            perf_adapter_packed_pair_count != ADAPTER_DESC * 2)
            fail("adapter pack2/burst counters mismatch");
        if (perf_fabric_aw_accept_count != TOTAL_AW ||
            perf_fabric_aw_issue_count != TOTAL_AW ||
            perf_fabric_w_beat_count != TOTAL_W ||
            perf_fabric_b_count != TOTAL_AW ||
            perf_fabric_outstanding != 0)
            fail("fabric counters/retirement mismatch");
        if (perf_fabric_max_outstanding < 3)
            fail("fabric did not expose multiple outstanding descriptors");
        if (protocol_error || adapter_protocol_error || fabric_protocol_error)
            fail("unexpected protocol error flag");
        if (!adapter_rsp_backpressure_seen || !peer_b_backpressure_seen)
            fail("response backpressure was not exercised");

        $display("C1_TENSOR_MEM_AXI128_WRITE_MLP_FABRIC_2C_PASS rsp_pop_refill=%0d full_pop_push=%0d aw=%0d w=%0d b=%0d adapter_rsp=%0d peer_b=%0d max_inflight=%0d packed=%0d",
                 ALLOW_RSP_POP_REFILL, full_pop_push_seen,
                 aw_count, w_count, b_count, adapter_rsp_seen, peer_b_seen,
                 max_bfm_count, perf_adapter_packed_pair_count);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "write MLP 2c fabric timeout");
    end
endmodule
