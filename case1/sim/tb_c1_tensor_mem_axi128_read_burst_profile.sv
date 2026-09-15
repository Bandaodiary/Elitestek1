`timescale 1ns/1ps

// Boardless BURST_BEATS A/B profile for the AXI128 read client.
//
// This test deliberately uses a compact, deterministic stream rather than a
// native frame.  It contains a long packed region (which distinguishes
// BURST_BEATS=16 from 32), a region that crosses a 4-KiB page, a non-contiguous
// descriptor, one malformed request, and a same-lane duplicate.  The BFM
// returns beats in AR order and the scoreboard checks every logical response
// in request order.  It is intended for xsim before a Ti60/Efinity board is
// available; it does not alter the default SoC parameters.
module tb_c1_tensor_mem_axi128_read_burst_profile;
`ifdef C1_BURST32_PROFILE_TB
    localparam integer DUT_BURST_BEATS = 32;
    localparam integer EXPECTED_AR = 7;
`else
    localparam integer DUT_BURST_BEATS = 16;
    localparam integer EXPECTED_AR = 9;
`endif
    localparam integer DUT_MAX_OUTSTANDING = 4;
    localparam integer DUT_REQ_FIFO_DEPTH = 32;
    localparam integer DUT_RSP_FIFO_DEPTH = 2 * DUT_BURST_BEATS * DUT_MAX_OUTSTANDING;
    localparam integer REGION_A_BEATS = 64;
    localparam integer REGION_B_BEATS = 24;
    localparam integer REGION_C_BEATS = 5;
    localparam integer EXPECTED_REQS =
        (REGION_A_BEATS + REGION_B_BEATS + REGION_C_BEATS) * 2 + 1 + 2;
    localparam integer EXPECTED_AXI_BEATS =
        REGION_A_BEATS + REGION_B_BEATS + REGION_C_BEATS + 1;
    localparam integer BFM_Q_DEPTH = 16;
    localparam integer MAX_CYCLES = 100000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic req_valid, req_ready, req_flush;
    logic [31:0] req_addr;
    logic rsp_valid, rsp_ready, rsp_error;
    logic [63:0] rsp_rdata;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    logic perf_busy;
    logic [63:0] perf_req_accept_count, perf_axi_burst_count;
    logic [63:0] perf_axi_beat_count, perf_rsp_count;
    logic [63:0] perf_packed_request_count, perf_error_count;
    logic [7:0] perf_req_occupancy, perf_max_req_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_tensor_mem_axi128_read_burst_client #(
        .REQ_FIFO_DEPTH(DUT_REQ_FIFO_DEPTH),
        .BURST_BEATS(DUT_BURST_BEATS),
        .MAX_OUTSTANDING(DUT_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(DUT_RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(2),
        .RSP_FIFO_BEAT_MODE(1'b0),
        .ALLOW_RSP_POP_REFILL(1'b0),
        .ALLOW_REQ_POP_REFILL(1'b0)
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
    // Compact in-order AXI read BFM.
    // ------------------------------------------------------------------
    logic [31:0] bfm_base [0:BFM_Q_DEPTH-1];
    integer bfm_beats [0:BFM_Q_DEPTH-1];
    integer bfm_head, bfm_tail, bfm_count;
    logic bfm_r_active, bfm_r_hold;
    integer bfm_r_beat;
    integer cycle_count, ar_count, axi_beat_count;
    integer full_burst_count, short_burst_count;
    logic saw_page_split;

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        // Deterministic stalls exercise both ARVALID hold and RREADY flow
        // control without producing a large simulation trace.
        m_axi_arready = ((cycle_count % 5) != 1);
        m_axi_rvalid = bfm_r_active &&
                       (bfm_r_hold || ((cycle_count % 7) != 3));
        m_axi_rresp = 2'b00;
        m_axi_rlast = bfm_r_active &&
                      (bfm_r_beat == (bfm_beats[bfm_head] - 1));
        m_axi_rdata = {
            64'hB000_0000_0000_0000 |
                {32'd0, bfm_base[bfm_head] + bfm_r_beat*16},
            64'hA000_0000_0000_0000 |
                {32'd0, bfm_base[bfm_head] + bfm_r_beat*16}
        };
        // The profile intentionally drains continuously; the long response
        // FIFO is sized to hold all four descriptor windows.
        rsp_ready = 1'b1;
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
            full_burst_count <= 0;
            short_burst_count <= 0;
            saw_page_split <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (!bfm_r_active && (bfm_count != 0)) begin
                bfm_r_active <= 1'b1;
                bfm_r_beat <= 0;
                bfm_r_hold <= 1'b0;
            end

            if (ar_fire) begin
                if (bfm_count >= BFM_Q_DEPTH)
                    $fatal(1, "profile BFM AR queue overflow");
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "profile AXI attributes mismatch");
                if ((m_axi_arlen + 1) > DUT_BURST_BEATS)
                    $fatal(1, "AR exceeds configured BURST_BEATS");
                // Every emitted burst must stay within one 4-KiB page.
                if ((m_axi_araddr >> 12) !=
                    ((m_axi_araddr + (m_axi_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "profile observed a 4-KiB crossing AR");
                if (m_axi_araddr == 32'h0000_3000)
                    saw_page_split <= 1'b1;
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_beats[bfm_tail] <= m_axi_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_Q_DEPTH;
                ar_count <= ar_count + 1;
                if ((m_axi_arlen + 1) == DUT_BURST_BEATS)
                    full_burst_count <= full_burst_count + 1;
                else
                    short_burst_count <= short_burst_count + 1;
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

            if (m_axi_rvalid && !m_axi_rready)
                bfm_r_hold <= 1'b1;
            else if (r_fire || !bfm_r_active)
                bfm_r_hold <= 1'b0;

            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Request generator and strict in-order response scoreboard.
    // ------------------------------------------------------------------
    logic [31:0] expected_addr [0:EXPECTED_REQS-1];
    integer expected_wr, expected_rd, response_count, error_count;
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

    task automatic queue_packed_region(input logic [31:0] base,
                                       input integer beats);
        integer i;
        begin
            for (i = 0; i < beats; i = i + 1) begin
                queue_request(base + i*16);
                queue_request(base + i*16 + 8);
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

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_rd <= 0;
            response_count <= 0;
            error_count <= 0;
        end else if (rsp_valid && rsp_ready) begin
            if (expected_rd >= expected_wr)
                $fatal(1, "profile response arrived without request");
            if (expected_addr[expected_rd][2:0] != 0) begin
                if (!rsp_error || (rsp_rdata != 64'd0))
                    $fatal(1, "profile malformed request response mismatch");
                error_count <= error_count + 1;
            end else begin
                if (rsp_error)
                    $fatal(1, "profile aligned response marked error");
                if (rsp_rdata[63:60] !=
                    (expected_addr[expected_rd][3] ? 4'hB : 4'hA))
                    $fatal(1, "profile lane ordering mismatch");
                if (rsp_rdata[31:0] !=
                    {expected_addr[expected_rd][31:4],4'd0})
                    $fatal(1, "profile address ordering mismatch");
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

        // 64 full beats: four 16-beat bursts versus two 32-beat bursts.
        queue_packed_region(32'h0000_1000, REGION_A_BEATS);
        // 24 beats beginning at 0x2f00: the 0x3000 page boundary must split
        // the descriptor (16 beats + 8 beats for either profile).
        queue_packed_region(32'h0000_2F00, REGION_B_BEATS);
        // Four contiguous beats followed by one isolated beat, preserving
        // response order while forcing a non-contiguous descriptor.
        queue_packed_region(32'h0000_5000, 4);
        queue_packed_region(32'h0000_5060, 1);
        // One local alignment error and two repeated reads of one lane.
        queue_request(32'h0000_6004);
        queue_request(32'h0000_7000);
        queue_request(32'h0000_7000);
        flush_builder();

        while (response_count != EXPECTED_REQS) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "profile timeout responses=%0d requests=%0d ar=%0d",
                       response_count, expected_wr, ar_count);
        end
        repeat (8) @(posedge clk);

        if (expected_wr != EXPECTED_REQS)
            $fatal(1, "profile request generator count mismatch: %0d", expected_wr);
        if (perf_req_accept_count != EXPECTED_REQS)
            $fatal(1, "profile request counter mismatch: %0d", perf_req_accept_count);
        if (perf_rsp_count != EXPECTED_REQS)
            $fatal(1, "profile response counter mismatch: %0d", perf_rsp_count);
        if (perf_error_count != 1 || error_count != 1)
            $fatal(1, "profile error counter mismatch perf=%0d tb=%0d",
                   perf_error_count, error_count);
        if (ar_count != EXPECTED_AR)
            $fatal(1, "profile AR count mismatch got=%0d expected=%0d",
                   ar_count, EXPECTED_AR);
        if (axi_beat_count != EXPECTED_AXI_BEATS)
            $fatal(1, "profile beat count mismatch got=%0d expected=%0d",
                   axi_beat_count, EXPECTED_AXI_BEATS);
        if (perf_packed_request_count < (EXPECTED_AXI_BEATS - 1))
            $fatal(1, "profile packing counter too small: %0d",
                   perf_packed_request_count);
        if (!saw_page_split)
            $fatal(1, "profile did not observe the required 4-KiB split");
        if (perf_max_outstanding < 2)
            $fatal(1, "profile did not exercise multiple outstanding descriptors");
        if (perf_busy)
            $fatal(1, "profile client remains busy");

        $display("C1_TENSOR_MEM_AXI128_READ_BURST_PROFILE_PASS burst_beats=%0d req=%0d ar=%0d beats=%0d packed=%0d full_bursts=%0d short_bursts=%0d max_outstanding=%0d page_split=%0d cycles=%0d",
                 DUT_BURST_BEATS, expected_wr, ar_count, axi_beat_count,
                 perf_packed_request_count, full_burst_count,
                 short_burst_count, perf_max_outstanding,
                 saw_page_split, cycle_count);
        $finish;
    end
endmodule
