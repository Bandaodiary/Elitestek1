`timescale 1ns/1ps

// Focused A/B test for the optional request-FIFO pop/refill path.
//
// The AXI side is held off while the leaf reserves its descriptor slots.  A
// stream of non-contiguous requests then fills the logical request FIFO.  Once
// AXI is released, the oldest descriptor retires and the builder consumes one
// request while the producer still has a request held valid.  In optional mode
// that full-FIFO cycle must accept the replacement request immediately; the
// conservative mode intentionally inserts one ready bubble.
module tb_c1_tensor_mem_axi128_read_burst_client_req_pop_refill;
`ifdef C1_REQ_POP_REFILL_TB
    localparam bit DUT_ALLOW_REQ_POP_REFILL = 1'b1;
`else
    localparam bit DUT_ALLOW_REQ_POP_REFILL = 1'b0;
`endif

    localparam integer REQ_DEPTH = 4;
    localparam integer DUT_BURST_BEATS = 2;
    localparam integer DUT_MAX_OUTSTANDING = 1;
    localparam integer DUT_DESC_DEPTH = DUT_MAX_OUTSTANDING + 2;
    localparam integer DUT_RSP_FIFO_DEPTH = 8;
    localparam integer REQUESTS = 12;
    localparam integer BFM_Q_DEPTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    logic req_valid;
    logic req_ready;
    logic req_flush;
    logic [31:0] req_addr;
    logic rsp_valid;
    logic rsp_ready;
    logic rsp_error;
    logic [63:0] rsp_rdata;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;

    logic perf_busy;
    logic [63:0] perf_req_accept_count;
    logic [63:0] perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count;
    logic [63:0] perf_rsp_count;
    logic [63:0] perf_packed_request_count;
    logic [63:0] perf_error_count;
    logic [7:0] perf_req_occupancy;
    logic [7:0] perf_max_req_occupancy;
    logic [7:0] perf_outstanding;
    logic [7:0] perf_max_outstanding;

    c1_tensor_mem_axi128_read_burst_client #(
        .REQ_FIFO_DEPTH(REQ_DEPTH),
        .BURST_BEATS(DUT_BURST_BEATS),
        .MAX_OUTSTANDING(DUT_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(DUT_RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(1),
        .ALLOW_SAME_LANE_DUP(1'b1),
        .RSP_FIFO_BEAT_MODE(1'b0),
        .ALLOW_RSP_POP_REFILL(1'b0),
        .ALLOW_REQ_POP_REFILL(DUT_ALLOW_REQ_POP_REFILL)
    ) dut (
        .clk, .rst,
        .req_valid, .req_ready, .req_flush, .req_addr,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata,
        .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
        .m_axi_arvalid, .m_axi_arready,
        .m_axi_rdata, .m_axi_rresp, .m_axi_rlast, .m_axi_rvalid,
        .m_axi_rready,
        .perf_busy, .perf_req_accept_count, .perf_axi_burst_count,
        .perf_axi_beat_count, .perf_rsp_count, .perf_packed_request_count,
        .perf_error_count, .perf_req_occupancy, .perf_max_req_occupancy,
        .perf_outstanding, .perf_max_outstanding
    );

    // ------------------------------------------------------------------
    // Deterministic single-ID AXI read BFM.
    // ------------------------------------------------------------------
    logic [31:0] bfm_base [0:BFM_Q_DEPTH-1];
    logic [8:0] bfm_beats [0:BFM_Q_DEPTH-1];
    integer bfm_head;
    integer bfm_tail;
    integer bfm_count;
    logic bfm_r_active;
    integer bfm_r_beat;
    logic release_axi;
    integer ar_count;
    integer axi_beat_count;

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        m_axi_arready = release_axi && (bfm_count < BFM_Q_DEPTH);
        m_axi_rvalid = bfm_r_active;
        m_axi_rresp = 2'b00;
        m_axi_rlast = bfm_r_active &&
                      (bfm_r_beat == (bfm_beats[bfm_head] - 1));
        if (bfm_r_active) begin
            m_axi_rdata = {
                64'hB000_0000_0000_0000 |
                    {32'd0, bfm_base[bfm_head] + bfm_r_beat*16},
                64'hA000_0000_0000_0000 |
                    {32'd0, bfm_base[bfm_head] + bfm_r_beat*16}
            };
        end else begin
            m_axi_rdata = 128'd0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_r_active <= 1'b0;
            bfm_r_beat <= 0;
            ar_count <= 0;
            axi_beat_count <= 0;
        end else begin
            if (!bfm_r_active && (bfm_count != 0)) begin
                bfm_r_active <= 1'b1;
                bfm_r_beat <= 0;
            end

            if (ar_fire) begin
                if (bfm_count >= BFM_Q_DEPTH)
                    $fatal(1, "request pop/refill BFM queue overflow");
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_beats[bfm_tail] <= m_axi_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_Q_DEPTH;
                ar_count <= ar_count + 1;
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "unexpected AXI attributes");
                if ((m_axi_araddr >> 12) !=
                    ((m_axi_araddr + (m_axi_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "AXI burst crossed a 4-KiB boundary");
            end

            if (r_fire) begin
                axi_beat_count <= axi_beat_count + 1;
                if (m_axi_rlast) begin
                    bfm_r_active <= 1'b0;
                    bfm_head <= (bfm_head + 1) % BFM_Q_DEPTH;
                end else begin
                    bfm_r_beat <= bfm_r_beat + 1;
                end
            end

            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Request producer and scoreboards.
    // ------------------------------------------------------------------
    logic [31:0] expected_addr [0:REQUESTS-1];
    integer expected_wr;
    integer expected_rd;
    integer response_count;
    integer cycle_count;
    integer full_cycle;
    integer first_post_full_cycle;
    integer full_to_accept;
    integer wait_cycles;
    logic full_seen;
    logic post_full_accept_seen;
    logic same_cycle_seen;
    logic producer_done;

    task automatic drive_request(input logic [31:0] address_value);
        begin
            @(negedge clk);
            req_addr = address_value;
            req_valid = 1'b1;
            req_flush = 1'b0;
            forever begin
                @(posedge clk);
                if (req_valid && req_ready) begin
                    expected_addr[expected_wr] = address_value;
                    expected_wr = expected_wr + 1;
                    @(negedge clk);
                    req_valid = 1'b0;
                    disable drive_request;
                end
            end
        end
    endtask

    task automatic flush_builder;
        begin
            @(negedge clk);
            req_flush = 1'b1;
            @(posedge clk);
            @(negedge clk);
            req_flush = 1'b0;
        end
    endtask

    assign rsp_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            full_cycle <= -1;
            first_post_full_cycle <= -1;
            full_to_accept <= -1;
            release_axi <= 1'b0;
            full_seen <= 1'b0;
            post_full_accept_seen <= 1'b0;
            same_cycle_seen <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            // The monitor samples pre-edge state, exactly as the DUT's
            // request FIFO pop/push decisions are evaluated.
            if (!full_seen &&
                (dut.req_count_q == REQ_DEPTH) &&
                (dut.desc_total_count_q == DUT_DESC_DEPTH)) begin
                full_seen <= 1'b1;
                full_cycle <= cycle_count;
                release_axi <= 1'b1;
            end
            if (full_seen && !post_full_accept_seen &&
                req_valid && req_ready) begin
                post_full_accept_seen <= 1'b1;
                first_post_full_cycle <= cycle_count;
                full_to_accept <= cycle_count - full_cycle;
            end
            if ((dut.req_count_q == REQ_DEPTH) && dut.req_pop &&
                req_valid && req_ready)
                same_cycle_seen <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_rd <= 0;
            response_count <= 0;
        end else if (rsp_valid && rsp_ready) begin
            if (expected_rd >= expected_wr)
                $fatal(1, "response arrived without an expected request");
            if (rsp_error)
                $fatal(1, "aligned request returned an error");
            if (rsp_rdata[31:0] != expected_addr[expected_rd])
                $fatal(1, "response ordering/data mismatch: got=%h exp=%h",
                       rsp_rdata[31:0], expected_addr[expected_rd]);
            expected_rd <= expected_rd + 1;
            response_count <= response_count + 1;
        end
    end

    initial begin
        req_valid = 1'b0;
        req_flush = 1'b0;
        req_addr = 32'd0;
        expected_wr = 0;
        producer_done = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // Non-contiguous addresses force one descriptor per request and make
        // descriptor exhaustion deterministic while AXI is held off.
        fork
            begin
                for (integer i = 0; i < REQUESTS; i = i + 1)
                    drive_request(32'h0001_0000 + i*32'h0000_0100);
                producer_done = 1'b1;
            end
        join_none

        // Wait until the FIFO is genuinely full with no descriptor slot left;
        // the monitor releases AXI in that exact state.
        wait_cycles = 0;
        while (!full_seen) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 1000)
                $fatal(1, "request FIFO did not reach the full/no-descriptor state");
        end

        wait_cycles = 0;
        while (!producer_done) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 3000)
                $fatal(1, "request producer stalled after AXI release");
        end
        flush_builder();

        wait_cycles = 0;
        while (response_count != REQUESTS) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 5000)
                $fatal(1, "request pop/refill response timeout: rsp=%0d req=%0d fifo=%0d desc=%0d",
                       response_count, expected_wr, dut.req_count_q,
                       dut.desc_total_count_q);
        end
        repeat (6) @(posedge clk);

        if (!full_seen || !post_full_accept_seen)
            $fatal(1, "full-FIFO replacement request was not observed");
        if (expected_wr != REQUESTS || expected_rd != REQUESTS)
            $fatal(1, "request/response scoreboard mismatch wr=%0d rd=%0d",
                   expected_wr, expected_rd);
        if (perf_req_accept_count != REQUESTS || perf_rsp_count != REQUESTS)
            $fatal(1, "performance counters mismatch req=%0d rsp=%0d",
                   perf_req_accept_count, perf_rsp_count);
        if (perf_error_count != 0 || perf_busy)
            $fatal(1, "unexpected error/busy state errors=%0d busy=%b",
                   perf_error_count, perf_busy);
`ifdef C1_REQ_POP_REFILL_TB
        if (!same_cycle_seen)
            $fatal(1, "optional request pop/refill path did not fire");
`else
        if (same_cycle_seen)
            $fatal(1, "conservative request FIFO unexpectedly accepted full pop/push");
`endif
        $display("C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_REQ_POP_REFILL_PASS mode=%0d full_cycle=%0d first_post_full_cycle=%0d full_to_accept=%0d same_cycle=%0d req=%0d ar=%0d beats=%0d max_req=%0d",
                 DUT_ALLOW_REQ_POP_REFILL, full_cycle,
                 first_post_full_cycle, full_to_accept, same_cycle_seen,
                 response_count, ar_count, axi_beat_count,
                 perf_max_req_occupancy);
        $finish;
    end
endmodule
