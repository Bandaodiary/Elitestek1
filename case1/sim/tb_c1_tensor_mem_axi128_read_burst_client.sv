`timescale 1ns/1ps

// Small, board-independent AXI read-channel BFM for
// c1_tensor_mem_axi128_read_burst_client.  The test intentionally keeps the
// request count tiny: it checks packing, 4-KiB splitting, multiple ARs in
// flight, local alignment errors, ordered responses, and ready/valid hold
// behaviour without creating a large simulator work directory.
module tb_c1_tensor_mem_axi128_read_burst_client;
    localparam integer EXPECTED_REQS = 19;
    localparam integer BFM_Q_DEPTH = 8;
`ifdef C1_LONG_BURST_TB
    // Boardless throughput profile: keep the same logical stream but use a
    // 16-beat AXI burst and four descriptor slots.  This is an A/B geometry
    // check, not a change to the default integration parameters.
    localparam integer DUT_BURST_BEATS = 16;
    localparam integer DUT_MAX_OUTSTANDING = 4;
    localparam integer DUT_RSP_FIFO_DEPTH = 64;
    localparam bit DUT_RSP_FIFO_BEAT_MODE = 1'b0;
    localparam bit DUT_ALLOW_RSP_POP_REFILL = 1'b0;
`elsif C1_BEAT_FIFO_TB
    localparam integer DUT_BURST_BEATS = 4;
    localparam integer DUT_MAX_OUTSTANDING = 3;
    localparam integer DUT_RSP_FIFO_DEPTH = 12;
    localparam bit DUT_RSP_FIFO_BEAT_MODE = 1'b1;
    localparam bit DUT_ALLOW_RSP_POP_REFILL = 1'b0;
`elsif C1_RSP_POP_REFILL_TB
    // Deliberately shallow logical-response FIFO: adjacent packed AXI beats
    // force the optional same-cycle local-pop/R-push path without requiring a
    // long stress test or a board DDR model.
    localparam integer DUT_BURST_BEATS = 4;
    localparam integer DUT_MAX_OUTSTANDING = 3;
    localparam integer DUT_RSP_FIFO_DEPTH = 2;
    localparam bit DUT_RSP_FIFO_BEAT_MODE = 1'b0;
    localparam bit DUT_ALLOW_RSP_POP_REFILL = 1'b1;
`else
    localparam integer DUT_BURST_BEATS = 4;
    localparam integer DUT_MAX_OUTSTANDING = 3;
    localparam integer DUT_RSP_FIFO_DEPTH = 24;
    localparam bit DUT_RSP_FIFO_BEAT_MODE = 1'b0;
    localparam bit DUT_ALLOW_RSP_POP_REFILL = 1'b0;
`endif

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
        .REQ_FIFO_DEPTH(8),
        .BURST_BEATS(DUT_BURST_BEATS),
        .MAX_OUTSTANDING(DUT_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(DUT_RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(2),
        .RSP_FIFO_BEAT_MODE(DUT_RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(DUT_ALLOW_RSP_POP_REFILL)
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
    // AXI read BFM.  ARs are accepted with a deterministic stall pattern;
    // responses are emitted in AR order, with a different valid pattern.
    // ------------------------------------------------------------------
    logic [31:0] bfm_base [0:BFM_Q_DEPTH-1];
    logic [8:0] bfm_beats [0:BFM_Q_DEPTH-1];
    integer bfm_head;
    integer bfm_tail;
    integer bfm_count;
    logic bfm_r_active;
    logic bfm_r_hold;
    integer bfm_r_beat;
    integer cycle_count;
    integer ar_count;
    integer axi_beat_count;
    logic saw_packed_pop_refill;

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        // At least one AR stall and one R-channel stall are guaranteed.
        m_axi_arready = ((cycle_count % 4) != 1);
        m_axi_rvalid = bfm_r_active &&
                       (bfm_r_hold || ((cycle_count % 5) != 2));
        m_axi_rresp = 2'b00;
        m_axi_rlast = bfm_r_active &&
                      (bfm_r_beat == (bfm_beats[bfm_head] - 1));
        m_axi_rdata = {
            64'hB000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_r_beat*16},
            64'hA000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_r_beat*16}
        };
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_r_active <= 1'b0;
            bfm_r_hold <= 1'b0;
            bfm_r_beat <= 0;
            cycle_count <= 0;
            ar_count <= 0;
            axi_beat_count <= 0;
            saw_packed_pop_refill <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (!bfm_r_active && (bfm_count != 0)) begin
                bfm_r_active <= 1'b1;
                bfm_r_beat <= 0;
                bfm_r_hold <= 1'b0;
            end

            if (ar_fire) begin
                $display("BFM_AR addr=%h len=%0d", m_axi_araddr, m_axi_arlen);
                if (bfm_count >= BFM_Q_DEPTH)
                    $fatal(1, "BFM AR queue overflow");
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_beats[bfm_tail] <= m_axi_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_Q_DEPTH;
                ar_count <= ar_count + 1;
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "unexpected AXI attributes");
                if ((m_axi_araddr >> 12) !=
                    ((m_axi_araddr + (m_axi_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "BFM observed a 4-KiB crossing burst addr=%h len=%0d",
                           m_axi_araddr, m_axi_arlen);
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

`ifdef C1_RSP_POP_REFILL_TB
            // With a two-entry logical FIFO, accepting a two-lane R beat while
            // one response is popped is legal only in the optional bypass
            // mode.  This is the exact throughput corner the test targets.
            if (r_fire && rsp_valid && rsp_ready &&
                (dut.rsp_count_q == DUT_RSP_FIFO_DEPTH-1) &&
                (dut.rd_push_count == 2))
                saw_packed_pop_refill <= 1'b1;
`endif

            if (m_axi_rvalid && !m_axi_rready)
                bfm_r_hold <= 1'b1;
            else if (r_fire || !bfm_r_active)
                bfm_r_hold <= 1'b0;

            // AR enqueue and completion of the current descriptor can happen
            // on the same edge.  Keep the queue count unchanged in that case
            // rather than letting two nonblocking assignments cancel one
            // another in an order-dependent way.
            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Request and response scoreboards.
    // ------------------------------------------------------------------
    logic [31:0] expected_addr [0:EXPECTED_REQS-1];
    integer expected_wr;
    integer expected_rd;
    integer response_count;
    integer error_count;
    integer timeout_count;

    task automatic queue_request(input logic [31:0] a);
        begin
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_addr = a;
            req_valid = 1'b1;
            req_flush = 1'b0;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            expected_addr[expected_wr] = a;
            expected_wr = expected_wr + 1;
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

    always_comb begin
        // Backpressure is intentional; it exercises the response FIFO.  The
        // pop/refill variant instead drains continuously to expose the
        // full-FIFO same-cycle release corner.
`ifdef C1_RSP_POP_REFILL_TB
        rsp_ready = 1'b1;
`else
        rsp_ready = ((cycle_count % 6) != 3);
`endif
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_rd <= 0;
            response_count <= 0;
            error_count <= 0;
        end else if (rsp_valid && rsp_ready) begin
            if (expected_rd >= expected_wr)
                $fatal(1, "response arrived without an expected request");
            if ((expected_addr[expected_rd][2:0] != 0) && !rsp_error)
                $fatal(1, "misaligned request did not return an error");
            if ((expected_addr[expected_rd][2:0] == 0) && rsp_error)
                $fatal(1, "aligned request returned an error");
            if (expected_addr[expected_rd][2:0] != 0) begin
                if (rsp_rdata != 64'd0)
                    $fatal(1, "local error response data is not zero");
                error_count <= error_count + 1;
            end else begin
                if (rsp_rdata[63:60] !=
                    (expected_addr[expected_rd][3] ? 4'hB : 4'hA))
                    $fatal(1, "response lane ordering/data tag mismatch");
                if (rsp_rdata[31:0] !=
                    {expected_addr[expected_rd][31:4],4'd0})
                    $fatal(1, "response address tag mismatch");
            end
            expected_rd <= expected_rd + 1;
            response_count <= response_count + 1;
        end
    end

    initial begin
        req_valid = 1'b0;
        req_flush = 1'b0;
        req_addr = 32'd0;
        expected_wr = 0;
        timeout_count = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // Two full contiguous bursts (four 16-byte beats total), with every
        // beat carrying both 64-bit halves.
        queue_request(32'h0000_1000);
        queue_request(32'h0000_1008);
        queue_request(32'h0000_1010);
        queue_request(32'h0000_1018);
        queue_request(32'h0000_1020);
        queue_request(32'h0000_1028);
        queue_request(32'h0000_1030);
        queue_request(32'h0000_1038);

        // A local alignment error must remain ordered and must not issue AR.
        queue_request(32'h0000_2004);

        // Crossing a 4-KiB page boundary forces two descriptors.
        queue_request(32'h0000_2FF0);
        queue_request(32'h0000_2FF8);
        queue_request(32'h0000_3000);
        queue_request(32'h0000_3008);

        // A non-contiguous gap forces two one-beat descriptors.
        queue_request(32'h0000_4000);
        queue_request(32'h0000_4018);
        queue_request(32'h0000_5000);
        // Misaligned successor while a legal descriptor is being built must
        // terminate that descriptor and become its own ordered local error;
        // it must not be packed into the upper lane of 0x5000.
        queue_request(32'h0000_5004);
        // Same-lane duplicates are legal read requests and may share one
        // 128-bit beat when ALLOW_SAME_LANE_DUP is enabled.
        queue_request(32'h0000_6000);
        queue_request(32'h0000_6000);
        flush_builder();

        while (response_count != EXPECTED_REQS) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 3000) begin
                $display("TIMEOUT resp=%0d req=%0d perf_rsp=%0d busy=%b ar=%0d beats=%0d bfm_count=%0d bfm_active=%b bfm_beat=%0d desc_total=%0d issued=%0d state=%0d rd_beat=%0d desc_beats=%0d lane=%0d rvalid=%b rready=%b rlast=%b rsp_fifo=%0d",
                         response_count, expected_wr, perf_rsp_count, perf_busy,
                         ar_count, axi_beat_count, bfm_count, bfm_r_active,
                         bfm_r_beat, dut.desc_total_count_q,
                         dut.desc_issued_count_q, dut.rd_state_q, dut.rd_beat_q,
                         dut.desc_beats_mem[dut.rd_slot_q], dut.rd_lane_count,
                         m_axi_rvalid, m_axi_rready, m_axi_rlast, dut.rsp_count_q);
                $fatal(1, "read burst client timeout");
            end
        end
        repeat (8) @(posedge clk);

        if (perf_req_accept_count != EXPECTED_REQS)
            $fatal(1, "request counter mismatch: %0d", perf_req_accept_count);
        if (perf_rsp_count != EXPECTED_REQS)
            $fatal(1, "response counter mismatch: %0d", perf_rsp_count);
        if (perf_error_count != 2)
            $fatal(1, "error counter mismatch: %0d", perf_error_count);
        if (perf_packed_request_count < 7)
            $fatal(1, "packing counter too small: %0d", perf_packed_request_count);
`ifdef C1_LONG_BURST_TB
        // The longer-burst profile is allowed to merge the first contiguous
        // region into one descriptor; four bursts are sufficient for this
        // mixed boundary/gap stream.
        if (ar_count < 4)
            $fatal(1, "too few long-profile AXI bursts: %0d", ar_count);
`else
        if (ar_count < 6)
            $fatal(1, "too few AXI bursts: %0d", ar_count);
`endif
        if (perf_max_outstanding < 2)
            $fatal(1, "multiple outstanding descriptors were not exercised");
        if (perf_busy)
            $fatal(1, "client remains busy after all responses");

`ifdef C1_BEAT_FIFO_TB
        $display("C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_PASS req=%0d ar=%0d beats=%0d packed=%0d fifo_depth=%0d",
                  response_count, ar_count, axi_beat_count,
                  perf_packed_request_count, DUT_RSP_FIFO_DEPTH);
`elsif C1_RSP_POP_REFILL_TB
        if (!saw_packed_pop_refill)
            $fatal(1, "pop/refill test did not exercise packed same-cycle refill");
        $display("C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_POP_REFILL_PASS req=%0d ar=%0d beats=%0d packed=%0d fifo_depth=%0d",
                 response_count, ar_count, axi_beat_count,
                 perf_packed_request_count, DUT_RSP_FIFO_DEPTH);
`else
        $display("C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_PASS burst_beats=%0d max_outstanding=%0d req=%0d ar=%0d beats=%0d packed=%0d",
                 DUT_BURST_BEATS, DUT_MAX_OUTSTANDING,
                 response_count, ar_count, axi_beat_count,
                 perf_packed_request_count);
`endif
        $finish;
    end
endmodule
