`timescale 1ns/1ps

// Beat-FIFO negative-path regression.  The first descriptor receives an
// early RLAST (the remaining beats must be synthesized as ordered errors);
// the second descriptor omits RLAST on its terminal beat (the terminal
// logical responses must be flagged while the descriptor still retires).
module tb_c1_tensor_mem_axi128_read_burst_client_beatfifo_malformed;
    localparam integer REQS_PER_DESC = 8;
    localparam integer TOTAL_REQS = 2 * REQS_PER_DESC;
    localparam integer BFM_Q_DEPTH = 4;

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
        .REQ_FIFO_DEPTH(16), .BURST_BEATS(4), .MAX_OUTSTANDING(2),
        .RSP_FIFO_DEPTH(8), .BUILD_TIMEOUT_CYCLES(2),
        .RSP_FIFO_BEAT_MODE(1'b1)
    ) dut (
        .clk, .rst, .req_valid, .req_ready, .req_flush, .req_addr,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_rdata,
        .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
        .m_axi_arvalid, .m_axi_arready, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready, .perf_busy,
        .perf_req_accept_count, .perf_axi_burst_count, .perf_axi_beat_count,
        .perf_rsp_count, .perf_packed_request_count, .perf_error_count,
        .perf_req_occupancy, .perf_max_req_occupancy, .perf_outstanding,
        .perf_max_outstanding
    );

    logic [31:0] bfm_base [0:BFM_Q_DEPTH-1];
    logic [8:0] bfm_beats [0:BFM_Q_DEPTH-1];
    integer bfm_scenario [0:BFM_Q_DEPTH-1];
    integer bfm_head, bfm_tail, bfm_count;
    logic bfm_active, bfm_hold;
    integer bfm_beat, cycle_count, ar_count, axi_beat_count;
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        m_axi_arready = ((cycle_count % 3) != 1);
        m_axi_rvalid = bfm_active;
        m_axi_rresp = 2'b00;
        m_axi_rdata = {
            64'hB000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_beat*16},
            64'hA000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_beat*16}
        };
        // Descriptor 0: early RLAST after beat 1.  Descriptor 1: no RLAST
        // at all, including its expected terminal beat.
        if (bfm_active && (bfm_scenario[bfm_head] == 0))
            m_axi_rlast = (bfm_beat == 1);
        else
            m_axi_rlast = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bfm_head <= 0; bfm_tail <= 0; bfm_count <= 0;
            bfm_active <= 1'b0; bfm_hold <= 1'b0; bfm_beat <= 0;
            cycle_count <= 0; ar_count <= 0; axi_beat_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (!bfm_active && (bfm_count != 0)) begin
                bfm_active <= 1'b1;
                bfm_beat <= 0;
                bfm_hold <= 1'b0;
            end
            if (ar_fire) begin
                if (bfm_count >= BFM_Q_DEPTH)
                    $fatal(1, "malformed BFM queue overflow");
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_beats[bfm_tail] <= m_axi_arlen + 1;
                // Bases are issued in test order: first is early, second is
                // missing RLAST.  Keep this independent of AR stalls.
                bfm_scenario[bfm_tail] <= (ar_count == 0) ? 0 : 1;
                bfm_tail <= (bfm_tail + 1) % BFM_Q_DEPTH;
                ar_count <= ar_count + 1;
                if (m_axi_arlen != 3 || m_axi_arsize != 3'd4 ||
                    m_axi_arburst != 2'b01)
                    $fatal(1, "unexpected malformed-test AR attributes");
            end
            if (r_fire) begin
                axi_beat_count <= axi_beat_count + 1;
                // Retire on forced early RLAST, or after the advertised beat
                // count for the missing-RLAST descriptor.
                if (m_axi_rlast || (bfm_beat == bfm_beats[bfm_head]-1)) begin
                    bfm_active <= 1'b0;
                    bfm_head <= (bfm_head + 1) % BFM_Q_DEPTH;
                end else begin
                    bfm_beat <= bfm_beat + 1;
                end
            end
            if (m_axi_rvalid && !m_axi_rready)
                bfm_hold <= 1'b1;
            else if (r_fire || !bfm_active)
                bfm_hold <= 1'b0;
            // Hold R payload under backpressure; the data/last expressions
            // above are functions of the held queue state.
            case ({ar_fire, (r_fire &&
                             (m_axi_rlast ||
                              (bfm_beat == bfm_beats[bfm_head]-1)))})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    // Responses are intentionally throttled so a two-lane beat remains in
    // the FIFO across both sub-lane handshakes.
    always_comb rsp_ready = ((cycle_count % 5) != 2);

    logic [31:0] expected_addr [0:TOTAL_REQS-1];
    logic expected_error [0:TOTAL_REQS-1];
    logic expected_zero [0:TOTAL_REQS-1];
    integer expected_wr, expected_rd, response_count, error_count;
    integer timeout_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_rd <= 0; response_count <= 0; error_count <= 0;
        end else if (rsp_valid && rsp_ready) begin
            if (expected_rd >= expected_wr)
                $fatal(1, "unexpected malformed-test response");
            if (rsp_error !== expected_error[expected_rd])
                $fatal(1, "error flag mismatch idx=%0d got=%b exp=%b",
                       expected_rd, rsp_error, expected_error[expected_rd]);
            if (rsp_error) begin
                if (expected_zero[expected_rd] && (rsp_rdata != 64'd0))
                    $fatal(1, "synthetic/local error data is not zero");
                error_count <= error_count + 1;
            end else if (rsp_rdata[63:60] !=
                         (expected_addr[expected_rd][3] ? 4'hB : 4'hA)) begin
                $fatal(1, "malformed-test lane ordering mismatch idx=%0d",
                       expected_rd);
            end
            expected_rd <= expected_rd + 1;
            response_count <= response_count + 1;
        end
    end

    task automatic send_request(input logic [31:0] a, input logic e,
                                input logic z);
        begin
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_addr = a; req_valid = 1'b1; req_flush = 1'b0;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            expected_addr[expected_wr] = a;
            expected_error[expected_wr] = e;
            expected_zero[expected_wr] = z;
            expected_wr = expected_wr + 1;
        end
    endtask

    task automatic flush_builder;
        begin
            @(negedge clk); req_flush = 1'b1; @(posedge clk);
            @(negedge clk); req_flush = 1'b0;
        end
    endtask

    integer k;
    initial begin
        req_valid = 1'b0; req_flush = 1'b0; req_addr = 0;
        expected_wr = 0; timeout_count = 0;
        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (k = 0; k < REQS_PER_DESC; k = k + 1) begin
            // Deliberately request the upper half before the lower half in
            // every beat; the beat record must preserve this logical order.
            send_request(32'h0000_1000 + (k/2)*16 + ((k % 2) == 0 ? 8 : 0),
                         (k >= 2), (k >= 4)); // early + synthesized tail
        end
        flush_builder();
        for (k = 0; k < REQS_PER_DESC; k = k + 1) begin
            send_request(32'h0000_2000 + (k/2)*16 + ((k % 2) == 0 ? 8 : 0),
                         (k >= 6), 1'b0); // terminal beat has missing RLAST
        end
        flush_builder();

        while (response_count != TOTAL_REQS) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 5000) begin
                $display("TIMEOUT malformed resp=%0d req=%0d ar=%0d beats=%0d bfm=%0d active=%b state=%0d rsp_fifo=%0d",
                         response_count, expected_wr, ar_count,
                         axi_beat_count, bfm_count, bfm_active,
                         dut.rd_state_q, dut.rsp_count_q);
                $fatal(1, "beat FIFO malformed-path timeout");
            end
        end
        repeat (8) @(posedge clk);
        if (expected_rd != TOTAL_REQS || expected_wr != TOTAL_REQS)
            $fatal(1, "malformed scoreboard count mismatch rd=%0d wr=%0d",
                   expected_rd, expected_wr);
        if (error_count != 8 || perf_error_count != 8)
            $fatal(1, "malformed error count mismatch local=%0d perf=%0d",
                   error_count, perf_error_count);
        if (perf_axi_beat_count != 6)
            $fatal(1, "malformed AXI beat count mismatch: %0d",
                   perf_axi_beat_count);
        if (perf_rsp_count != TOTAL_REQS || perf_busy)
            $fatal(1, "malformed client did not drain rsp=%0d busy=%b",
                   perf_rsp_count, perf_busy);
        $display("C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_MALFORMED_PASS req=%0d ar=%0d beats=%0d errors=%0d fifo_depth=8",
                 response_count, ar_count, axi_beat_count, error_count);
        $finish;
    end
endmodule
