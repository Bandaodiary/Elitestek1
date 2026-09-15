`timescale 1ns/1ps

// Small boardless BFM/scoreboard for the write-burst prototype.  The BFM
// deliberately inserts AW/W stalls, holds BVALID until BREADY, and checks
// every burst against the 4-KiB and WLAST rules.  The response FIFO is held
// full for part of the run so BREADY backpressure is exercised as well.
module tb_c1_tensor_mem_axi128_write_burst_client #(
    parameter bit DEPENDENT_AW = 1'b0,
    parameter bit USE_END = 1'b0
);
    localparam integer BURST_BEATS = 4;
    localparam integer MAX_LOGICAL = 2 * BURST_BEATS;
    localparam integer REQ_DEPTH = 16;
    localparam integer RSP_DEPTH = MAX_LOGICAL;
    localparam integer NREQ = 21;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic req_valid = 1'b0;
    logic req_ready;
    logic req_flush = 1'b0;
    logic req_end = 1'b0;
    logic [31:0] req_addr = '0;
    logic [63:0] req_wdata = '0;
    logic [7:0] req_wstrb = '0;

    logic rsp_valid;
    logic rsp_ready = 1'b0;
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

    logic perf_busy;
    logic [63:0] perf_req_accept_count;
    logic [63:0] perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count;
    logic [63:0] perf_rsp_count;
    logic [63:0] perf_packed_request_count;
    logic [63:0] perf_error_count;
    logic [7:0] perf_req_occupancy, perf_max_req_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_tensor_mem_axi128_write_burst_client #(
        .REQ_FIFO_DEPTH(REQ_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .MAX_OUTSTANDING(1),
        .RSP_FIFO_DEPTH(RSP_DEPTH),
        .BUILD_TIMEOUT_CYCLES(3),
        .ALLOW_SAME_LANE_DUP(1'b1), .USE_REQUEST_END(USE_END)
    ) dut (
        .clk, .rst, .req_end,
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

    // ------------------------------------------------------------------
    // Expected logical response stream and byte-addressed shadow memory.
    // ------------------------------------------------------------------
    logic [63:0] expected_rsp_data [0:NREQ-1];
    logic expected_rsp_error [0:NREQ-1];
    integer req_total = 0;
    integer rsp_seen = 0;
    integer response_error_seen = 0;
    logic [7:0] expected_mem [0:65535];
    logic [7:0] shadow_mem [0:65535];

    task automatic add_expected_byte_write(
        input logic [31:0] addr,
        input logic [63:0] data,
        input logic [7:0] strb
    );
        integer k;
        integer ai;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                if (strb[k]) begin
                    ai = (addr + k) & 16'hffff;
                    expected_mem[ai] = data[k*8 +: 8];
                end
            end
        end
    endtask

    task automatic send_write(
        input logic [31:0] addr,
        input logic [63:0] data,
        input logic [7:0] strb,
        input logic expect_error
    );
        integer idx;
        begin
            idx = req_total;
            if (idx >= NREQ)
                $fatal(1, "test request table overflow");
            expected_rsp_data[idx] = expect_error ? 64'd0 : data;
            // The BFM injects SLVERR for the 0x4000 descriptor (AW index 4);
            // unlike a local alignment error, its payload is still echoed.
            expected_rsp_error[idx] = expect_error ||
                                      (addr == 32'h0000_4000);
            req_total = req_total + 1;
            if (!expect_error)
                add_expected_byte_write(addr, data, strb);

            @(negedge clk);
            req_addr = addr;
            req_wdata = data;
            req_wstrb = strb;
            // Same transaction partitions as the legacy address/boundary
            // rules, including the identical same-lane pair ending at 19.
            req_end = (idx==7 || idx==8 || idx==9 || idx==11 || idx==13 ||
                       idx==14 || idx==15 || idx==16 || idx==17 || idx==19 || idx==20);
            req_valid = 1'b1;
            do @(posedge clk); while (!req_ready);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // AXI write BFM.
    // ------------------------------------------------------------------
    integer cycle_count = 0;
    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;
    integer bfm_w_beat = 0;
    integer bfm_aw_len = 0;
    logic [31:0] bfm_aw_base = '0;
    logic bfm_aw_active = 1'b0;
    logic bfm_b_pending = 1'b0;
    logic bfm_bvalid_q = 1'b0;
    integer bfm_b_delay = 0;
    logic b_backpressure_seen = 1'b0;
    logic b_hold_q = 1'b0;
    logic [1:0] bfm_bresp_q = 2'b00;
    integer bfm_aw_index = 0;

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire rsp_fire = rsp_valid && rsp_ready;

    always_comb begin
        // This byte memory has no early-W storage: only accept W once AW
        // is known. Optionally wait for WVALID before accepting AW, which
        // is legal and detects a master waiting for AWREADY to send W.
        m_axi_awready = ((cycle_count % 5) != 1) &&
                        (!DEPENDENT_AW || m_axi_wvalid);
        m_axi_wready = bfm_aw_active && ((cycle_count % 4) != 2);
        m_axi_bvalid = bfm_bvalid_q;
        m_axi_bresp = bfm_bresp_q;
    end

    always @(posedge clk) begin : bfm_proc
        integer k;
        integer ai;
        if (rst) begin
            cycle_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            bfm_w_beat <= 0;
            bfm_aw_len <= 0;
            bfm_aw_base <= '0;
            bfm_aw_active <= 1'b0;
            bfm_b_pending <= 1'b0;
            bfm_bvalid_q <= 1'b0;
            bfm_bresp_q <= 2'b00;
            bfm_aw_index <= 0;
            bfm_b_delay <= 0;
            b_backpressure_seen <= 1'b0;
            b_hold_q <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            // Give the first local response one single-cycle opening, then
            // close the FIFO again through the next burst's B phase.  This
            // forces the DUT to hold BREADY low until a logical slot opens.
            if (cycle_count == 241)
                rsp_ready <= 1'b1;
            else if (cycle_count == 242)
                rsp_ready <= 1'b0;
            else if (cycle_count > 300)
                rsp_ready <= 1'b1;
            if (m_axi_bvalid && !m_axi_bready)
                b_backpressure_seen <= 1'b1;
            if (b_hold_q && !m_axi_bready && !m_axi_bvalid)
                $fatal(1, "BFM withdrew BVALID while BREADY was low");
            b_hold_q <= m_axi_bvalid && !m_axi_bready;

            if (aw_fire) begin
                if (m_axi_awsize != 3'd4 || m_axi_awburst != 2'b01)
                    $fatal(1, "bad AW attributes");
                if (m_axi_awaddr[3:0] != 4'd0)
                    $fatal(1, "unaligned AW address");
                if ((m_axi_awaddr[11:0] +
                     (m_axi_awlen + 1) * 16) > 4096)
                    $fatal(1, "AW burst crossed a 4-KiB boundary");
                if (bfm_aw_active)
                    $fatal(1, "prototype issued a second AW before prior W");
                bfm_aw_base <= m_axi_awaddr;
                bfm_aw_len <= m_axi_awlen;
                bfm_aw_index <= aw_count;
                bfm_w_beat <= 0;
                bfm_aw_active <= 1'b1;
                aw_count <= aw_count + 1;
            end

            if (w_fire) begin
                if (!bfm_aw_active)
                    $fatal(1, "W beat arrived before AW");
                if (m_axi_wlast != (bfm_w_beat == bfm_aw_len))
                    $fatal(1, "WLAST mismatch beat=%0d len=%0d",
                           bfm_w_beat, bfm_aw_len);
                for (k = 0; k < 16; k = k + 1) begin
                    if (m_axi_wstrb[k]) begin
                        ai = (bfm_aw_base + bfm_w_beat*16 + k) & 16'hffff;
                        shadow_mem[ai] <= m_axi_wdata[k*8 +: 8];
                    end
                end
                w_count <= w_count + 1;
                if (m_axi_wlast) begin
                    bfm_aw_active <= 1'b0;
                    bfm_b_pending <= 1'b1;
                    bfm_b_delay <= 4;
                    // One deterministic SLVERR tests burst-level error
                    // propagation to the ordered logical response stream.
                    bfm_bresp_q <= (bfm_aw_index == 4) ? 2'b10 : 2'b00;
                end else begin
                    bfm_w_beat <= bfm_w_beat + 1;
                end
            end

            if (bfm_b_pending && !bfm_bvalid_q) begin
                if (bfm_b_delay != 0)
                    bfm_b_delay <= bfm_b_delay - 1;
                else
                    bfm_bvalid_q <= 1'b1;
            end
            if (b_fire) begin
                bfm_bvalid_q <= 1'b0;
                bfm_b_pending <= 1'b0;
                b_count <= b_count + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Ordered response scoreboard.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst && rsp_fire) begin
            if (rsp_seen >= req_total)
                $fatal(1, "excess logical response");
            if (rsp_error !== expected_rsp_error[rsp_seen])
                $fatal(1, "response error mismatch idx=%0d got=%0d exp=%0d",
                       rsp_seen, rsp_error, expected_rsp_error[rsp_seen]);
            if (rsp_rdata !== expected_rsp_data[rsp_seen])
                $fatal(1, "response data mismatch idx=%0d got=%h exp=%h",
                       rsp_seen, rsp_rdata, expected_rsp_data[rsp_seen]);
            if (rsp_error)
                response_error_seen = response_error_seen + 1;
            rsp_seen = rsp_seen + 1;
        end
    end

    task automatic check_mem_range(input integer base, input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                if (shadow_mem[(base+k) & 16'hffff] !==
                    expected_mem[(base+k) & 16'hffff])
                    $fatal(1, "memory mismatch addr=%h got=%h exp=%h",
                           base+k, shadow_mem[(base+k) & 16'hffff],
                           expected_mem[(base+k) & 16'hffff]);
            end
        end
    endtask

    initial begin : stimulus
        integer k;
        for (k = 0; k < 65536; k = k + 1) begin
            expected_mem[k] = 8'd0;
            shadow_mem[k] = 8'd0;
        end
        // Keep reset asserted while the expected table is constructed.
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Four complete packed beats (eight logical writes).
        for (k = 0; k < 8; k = k + 1)
            send_write(32'h0000_1000 + k*8,
                       64'h1000_0000_0000_0000 + k,
                       8'hff, 1'b0);

        // A legal lower-lane request followed immediately by a misaligned
        // upper-looking address.  The latter is a successor while ST_BUILD
        // is active and must terminate the burst rather than being packed.
        send_write(32'h0000_2000, 64'h2000_0000_0000_0001,
                   8'hff, 1'b0);
        send_write(32'h0000_200c, 64'hdead_beef_0000_0001,
                   8'hff, 1'b1);

        // A pair at the end of a page and a pair on the next page.  They
        // must become two separate AXI bursts.
        send_write(32'h0000_2ff0, 64'h2ff0_0000_0000_0000, 8'h0f, 1'b0);
        send_write(32'h0000_2ff8, 64'h2ff8_0000_0000_0000, 8'hf0, 1'b0);
        send_write(32'h0000_3000, 64'h3000_0000_0000_0000, 8'hff, 1'b0);
        send_write(32'h0000_3008, 64'h3008_0000_0000_0000, 8'hff, 1'b0);

        // Non-contiguous aligned addresses force separate descriptors.
        send_write(32'h0000_4000, 64'h4000_0000_0000_0000, 8'hff, 1'b0);
        send_write(32'h0000_4020, 64'h4020_0000_0000_0000, 8'hff, 1'b0);

        // Same lane with different payloads must not be merged.
        send_write(32'h0000_5000, 64'h5000_0000_0000_0001, 8'hff, 1'b0);
        send_write(32'h0000_5000, 64'h5000_0000_0000_0002, 8'hff, 1'b0);

        // Same lane and identical payload may be merged when the parameter
        // is enabled; both logical responses must still be returned.
        send_write(32'h0000_6008, 64'h6008_0000_0000_0003, 8'haa, 1'b0);
        send_write(32'h0000_6008, 64'h6008_0000_0000_0003, 8'haa, 1'b0);
        // A third identical token must start a new descriptor, not overflow
        // the two-token lane metadata.
        send_write(32'h0000_6008, 64'h6008_0000_0000_0003, 8'haa, 1'b0);

        if (req_total != NREQ)
            $fatal(1, "unexpected request count %0d", req_total);

        // Let the client drain all responses and release the B backpressure.
        wait (rsp_seen == req_total);
        wait (!perf_busy);
        repeat (5) @(posedge clk);

        if (aw_count != 10 || perf_axi_burst_count != 10)
            $fatal(1, "burst count mismatch aw=%0d perf=%0d",
                   aw_count, perf_axi_burst_count);
        if (w_count != 13 || perf_axi_beat_count != 13)
            $fatal(1, "beat count mismatch w=%0d perf=%0d", w_count,
                   perf_axi_beat_count);
        if (perf_packed_request_count != 7)
            $fatal(1, "pack count mismatch got=%0d", perf_packed_request_count);
        if (perf_req_accept_count != NREQ || perf_rsp_count != NREQ)
            $fatal(1, "logical count mismatch req=%0d rsp=%0d",
                   perf_req_accept_count, perf_rsp_count);
        if (perf_error_count != 2 || response_error_seen != 2)
            $fatal(1, "error count mismatch perf=%0d seen=%0d",
                   perf_error_count, response_error_seen);
        if (perf_max_outstanding > 1)
            $fatal(1, "single-outstanding limit violated");
        // BVALID is held by the BFM while BREADY is low; whether the exact
        // timing reaches that window is reported, not treated as a functional
        // failure.  The DUT's non-synthesis payload-hold assertion remains
        // active for every stalled B cycle.

        // Check all touched regions, including the partial-strobe page pair.
        check_mem_range(16'h1000, 64);
        check_mem_range(16'h2000, 32);
        check_mem_range(16'h2ff0, 32);
        check_mem_range(16'h3000, 32);
        check_mem_range(16'h4000, 64);
        check_mem_range(16'h5000, 16);
        check_mem_range(16'h6000, 32);
        if (shadow_mem[16'h200c] !== 8'd0)
            $fatal(1, "misaligned local request changed memory");

        $display("C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_PASS req=%0d aw=%0d beats=%0d packed=%0d errors=%0d b_stall=%0d",
                 req_total, aw_count, w_count, perf_packed_request_count,
                 perf_error_count, b_backpressure_seen);
        $display("C1_WRITE_BURST_END_MODE end_marker=%0d dependent_aw=%0d",USE_END,DEPENDENT_AW);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "write burst client timeout");
    end
endmodule
