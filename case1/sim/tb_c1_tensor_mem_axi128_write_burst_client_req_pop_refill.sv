`timescale 1ns/1ps

// Focused A/B test for the optional write request-FIFO pop/refill path.
//
// AXI is held off while a one-beat descriptor is built and the logical request
// FIFO fills with non-contiguous addresses.  Releasing AW then lets the oldest
// descriptor leave the scheduler while the producer still has a request held
// valid.  Optional mode accepts that replacement on the same edge; the
// conservative mode intentionally inserts one ready bubble.  The test keeps
// the BFM single-outstanding and tiny so it is suitable for detached xsim.
module tb_c1_tensor_mem_axi128_write_burst_client_req_pop_refill #(parameter bit USE_END=0);
`ifdef C1_WRITE_REQ_POP_REFILL_TB
    localparam bit DUT_ALLOW_REQ_POP_REFILL = 1'b1;
`else
    localparam bit DUT_ALLOW_REQ_POP_REFILL = 1'b0;
`endif

    localparam integer REQ_DEPTH = 4;
    localparam integer BURST_BEATS = 2;
    localparam integer RSP_DEPTH = 4;
    localparam integer REQUESTS = 12;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic req_valid = 1'b0;
    logic req_ready;
    logic req_flush = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [63:0] req_wdata = 64'd0;
    logic [7:0] req_wstrb = 8'hff;

    logic rsp_valid;
    logic rsp_ready = 1'b1;
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
    logic [1:0] m_axi_bresp = 2'b00;
    logic m_axi_bvalid, m_axi_bready;

    logic perf_busy;
    logic [63:0] perf_req_accept_count, perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count, perf_rsp_count;
    logic [63:0] perf_packed_request_count, perf_error_count;
    logic [7:0] perf_req_occupancy, perf_max_req_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_tensor_mem_axi128_write_burst_client #(
        .REQ_FIFO_DEPTH(REQ_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .MAX_OUTSTANDING(1),
        .RSP_FIFO_DEPTH(RSP_DEPTH),
        .BUILD_TIMEOUT_CYCLES(1),
        .ALLOW_SAME_LANE_DUP(1'b0),
        .ALLOW_REQ_POP_REFILL(DUT_ALLOW_REQ_POP_REFILL), .USE_REQUEST_END(USE_END)
    ) dut (
        .clk, .rst, .req_end(1'b1),
        .req_valid, .req_ready, .req_flush, .req_addr,
        .req_wdata, .req_wstrb,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_wvalid, .m_axi_wready,
        .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
        .perf_busy, .perf_req_accept_count, .perf_axi_burst_count,
        .perf_axi_beat_count, .perf_rsp_count,
        .perf_packed_request_count, .perf_error_count,
        .perf_req_occupancy, .perf_max_req_occupancy,
        .perf_outstanding, .perf_max_outstanding
    );

    wire req_fire = req_valid && req_ready;
    wire rsp_fire = rsp_valid && rsp_ready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

    // ------------------------------------------------------------------
    // Tiny single-outstanding AXI write BFM.
    // ------------------------------------------------------------------
    logic release_axi;
    logic aw_active;
    logic bvalid_q;
    logic [31:0] aw_base_q;
    integer aw_len_q;
    integer w_beat_q;
    integer aw_count;
    integer w_count;
    integer b_count;

    always_comb begin
        m_axi_awready = release_axi && !aw_active && !bvalid_q;
        m_axi_wready = aw_active;
        m_axi_bvalid = bvalid_q;
        m_axi_bresp = 2'b00;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_active <= 1'b0;
            bvalid_q <= 1'b0;
            aw_base_q <= 32'd0;
            aw_len_q <= 0;
            w_beat_q <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
        end else begin
            if (aw_fire) begin
                if (m_axi_awsize != 3'd4 || m_axi_awburst != 2'b01)
                    $fatal(1, "write req/refill bad AW attributes");
                if (m_axi_awaddr[3:0] != 4'd0)
                    $fatal(1, "write req/refill unaligned AW");
                if (m_axi_awlen != 0)
                    $fatal(1, "write req/refill expected one-beat descriptors");
                aw_active <= 1'b1;
                aw_base_q <= m_axi_awaddr;
                aw_len_q <= m_axi_awlen;
                w_beat_q <= 0;
                aw_count <= aw_count + 1;
            end
            if (w_fire) begin
                if (!aw_active)
                    $fatal(1, "write req/refill W before AW");
                if (m_axi_wlast != (w_beat_q == aw_len_q))
                    $fatal(1, "write req/refill WLAST mismatch");
                if (m_axi_wstrb != 16'h00ff)
                    $fatal(1, "write req/refill strobe mismatch");
                if (m_axi_wdata[31:0] != aw_base_q)
                    $fatal(1, "write req/refill payload/order mismatch");
                w_count <= w_count + 1;
                if (m_axi_wlast) begin
                    aw_active <= 1'b0;
                    bvalid_q <= 1'b1;
                end else begin
                    w_beat_q <= w_beat_q + 1;
                end
            end
            if (b_fire) begin
                bvalid_q <= 1'b0;
                b_count <= b_count + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Producer, request-FIFO boundary monitor, and ordered response check.
    // ------------------------------------------------------------------
    logic [31:0] expected_addr [0:REQUESTS-1];
    integer req_seen;
    integer rsp_seen;
    integer cycle_count;
    integer full_cycle;
    integer first_post_full_cycle;
    integer full_to_accept;
    logic full_seen;
    logic post_full_accept_seen;
    logic same_cycle_seen;
    logic producer_done;

    // Release AXI only after the request FIFO is full and the first descriptor
    // is waiting in ST_AW (enum value 2).  This makes the A/B boundary
    // independent of simulator scheduling and of the producer's exact pace.
    always_ff @(posedge clk) begin
        if (rst) begin
            release_axi <= 1'b0;
            req_seen <= 0;
            cycle_count <= 0;
            full_cycle <= -1;
            first_post_full_cycle <= -1;
            full_to_accept <= -1;
            full_seen <= 1'b0;
            post_full_accept_seen <= 1'b0;
            same_cycle_seen <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (req_fire) begin
                if (req_seen >= REQUESTS)
                    $fatal(1, "write req/refill excess request");
                expected_addr[req_seen] <= req_addr;
                req_seen <= req_seen + 1;
            end
            if (!full_seen && (dut.req_count_q == REQ_DEPTH) &&
                (dut.state_q == 3'd2)) begin
                full_seen <= 1'b1;
                full_cycle <= cycle_count;
                release_axi <= 1'b1;
            end
            if (full_seen && !post_full_accept_seen && req_fire) begin
                post_full_accept_seen <= 1'b1;
                first_post_full_cycle <= cycle_count;
                full_to_accept <= cycle_count - full_cycle;
            end
            if ((dut.req_count_q == REQ_DEPTH) && dut.req_pop && req_fire)
                same_cycle_seen <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_seen <= 0;
        end else if (rsp_fire) begin
            if (rsp_seen >= req_seen)
                $fatal(1, "write req/refill response without request");
            if (rsp_error)
                $fatal(1, "write req/refill aligned response error");
            if (rsp_rdata[31:0] != expected_addr[rsp_seen])
                $fatal(1, "write req/refill response ordering mismatch");
            rsp_seen <= rsp_seen + 1;
        end
    end

    task automatic send_request(input logic [31:0] address_value);
        begin
            @(negedge clk);
            req_addr = address_value;
            req_wdata = {32'hC1A5_0000, address_value};
            req_wstrb = 8'hff;
            req_valid = 1'b1;
            forever begin
                @(posedge clk);
                if (req_fire) begin
                    @(negedge clk);
                    req_valid = 1'b0;
                    disable send_request;
                end
            end
        end
    endtask

    initial begin : stimulus
        integer i;
        req_valid = 1'b0;
        req_flush = 1'b0;
        producer_done = 1'b0;
        repeat (5) @(posedge clk);
        rst = 1'b0;

        // Non-contiguous aligned addresses force one descriptor per request.
        for (i = 0; i < REQUESTS; i = i + 1)
            send_request(32'h0001_0000 + i * 32'h0000_0100);
        producer_done = 1'b1;

        // Publish any final partial builder without changing the request FIFO
        // boundary being measured above.
        @(negedge clk);
        req_flush = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_flush = 1'b0;

        wait (rsp_seen == REQUESTS);
        wait (!perf_busy);
        repeat (4) @(posedge clk);

        if (!full_seen || !post_full_accept_seen)
            $fatal(1, "write req/refill full-FIFO boundary not observed");
        if (req_seen != REQUESTS || rsp_seen != REQUESTS)
            $fatal(1, "write req/refill request/response count mismatch req=%0d rsp=%0d",
                   req_seen, rsp_seen);
        if (aw_count != REQUESTS || w_count != REQUESTS || b_count != REQUESTS)
            $fatal(1, "write req/refill AXI count mismatch aw=%0d w=%0d b=%0d",
                   aw_count, w_count, b_count);
        if (perf_req_accept_count != REQUESTS || perf_rsp_count != REQUESTS)
            $fatal(1, "write req/refill perf count mismatch req=%0d rsp=%0d",
                   perf_req_accept_count, perf_rsp_count);
        if (perf_error_count != 0 || perf_max_req_occupancy != REQ_DEPTH ||
            perf_packed_request_count != 0)
            $fatal(1, "write req/refill unexpected error/occupancy err=%0d max=%0d",
                   perf_error_count, perf_max_req_occupancy);
`ifdef C1_WRITE_REQ_POP_REFILL_TB
        if (!same_cycle_seen)
            $fatal(1, "write req/refill optional path did not fire");
`else
        if (same_cycle_seen)
            $fatal(1, "write req/refill conservative path accepted full pop/push");
`endif
        $display("C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_REQ_POP_REFILL_PASS mode=%0d full_cycle=%0d first_post_full_cycle=%0d full_to_accept=%0d same_cycle=%0d req=%0d aw=%0d beats=%0d max_req=%0d",
                 DUT_ALLOW_REQ_POP_REFILL, full_cycle,
                 first_post_full_cycle, full_to_accept, same_cycle_seen,
                 rsp_seen, aw_count, w_count, perf_max_req_occupancy);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "write request pop/refill timeout");
    end
endmodule
