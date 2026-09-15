`timescale 1ns/1ps

// Focused boardless regression for
// c1_axi128_write_mlp.ISSUE_AW_BEFORE_PAYLOAD.
//
// The legacy tb_c1_axi128_write_mlp keeps malformed frames local and is
// intentionally left unchanged.  This test exercises the opt-in contract:
// command-valid descriptors may handshake AW before their payload frame is
// complete, while W remains ordered and waits for payload_done.  Early LAST,
// late LAST, and flush frames still emit a full declared-length AXI burst;
// uncaptured beats must be zero data/zero strobe.  A command-invalid
// descriptor must remain poisoned and must not issue AW.
module tb_c1_axi128_write_mlp_aw_before_payload #(parameter bit PIPELINE_W=1'b0);
    localparam integer MAX_OUTSTANDING = 4;
    localparam integer MAX_BEATS = 4;
    localparam integer RSP_FIFO_DEPTH = 4;
    localparam integer TOTAL_CASES = 6;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    logic [31:0] cmd_addr = 32'd0;
    logic [8:0] cmd_beats = 9'd0;
    logic payload_valid = 1'b0;
    logic payload_ready;
    logic [127:0] payload_data = 128'd0;
    logic [15:0] payload_strb = 16'd0;
    logic payload_last = 1'b0;
    logic payload_flush = 1'b0;

    logic rsp_valid, rsp_ready;
    logic rsp_error;
    logic [31:0] rsp_addr;
    logic [8:0] rsp_beats;
    logic [15:0] rsp_tag;

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

    logic protocol_error;
    logic early_payload_last_error, late_payload_last_error;
    logic payload_flush_error, orphan_payload_error;
    logic early_b_error, orphan_b_error;
    logic perf_busy;
    logic [63:0] perf_cmd_accept_count, perf_payload_beat_count;
    logic [63:0] perf_axi_burst_count, perf_axi_beat_count;
    logic [63:0] perf_aw_issue_count, perf_rsp_count, perf_error_count;
    logic [63:0] perf_aw_stall_count, perf_w_stall_count, perf_b_stall_count;
    logic [7:0] perf_cmd_occupancy, perf_max_cmd_occupancy;
    logic [7:0] perf_outstanding, perf_max_outstanding;

    c1_axi128_write_mlp #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .TAG_WIDTH(16),
        .ISSUE_AW_BEFORE_PAYLOAD(1'b1),.PIPELINE_WRITE_DATA(PIPELINE_W)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_addr, .cmd_beats,
        .payload_valid, .payload_ready, .payload_data, .payload_strb,
        .payload_last, .payload_flush,
        .rsp_valid, .rsp_ready, .rsp_error, .rsp_addr, .rsp_beats, .rsp_tag,
        .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_awvalid, .m_axi_awready,
        .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_wvalid, .m_axi_wready, .m_axi_bresp,
        .m_axi_bvalid, .m_axi_bready,
        .protocol_error, .early_payload_last_error, .late_payload_last_error,
        .payload_flush_error, .orphan_payload_error,
        .early_b_error, .orphan_b_error,
        .perf_busy, .perf_cmd_accept_count, .perf_payload_beat_count,
        .perf_axi_burst_count, .perf_axi_beat_count, .perf_aw_issue_count,
        .perf_rsp_count, .perf_error_count, .perf_aw_stall_count,
        .perf_w_stall_count, .perf_b_stall_count, .perf_cmd_occupancy,
        .perf_max_cmd_occupancy, .perf_outstanding, .perf_max_outstanding
    );

    integer cycle_count;
    integer cmd_seen, payload_seen, rsp_seen;
    integer aw_seen, w_seen, b_seen;
    integer current_case, current_w_beat, aw_expect_case;
    logic bvalid_q;
    logic [1:0] bresp_q;
    logic [31:0] case_addr [0:TOTAL_CASES-1];
    logic [8:0] case_beats [0:TOTAL_CASES-1];
    logic case_error [0:TOTAL_CASES-1];
    logic [127:0] expected_data [0:TOTAL_CASES-1][0:MAX_BEATS-1];
    logic [15:0] expected_strb [0:TOTAL_CASES-1][0:MAX_BEATS-1];

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire payload_fire = payload_valid && payload_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    task automatic fail(input string message);
        begin
            $display("C1_AXI128_WRITE_MLP_AW_EARLY_FAIL t=%0t case=%0d cmd=%0d payload=%0d rsp=%0d aw=%0d w=%0d b=%0d: %s",
                     $time, current_case, cmd_seen, payload_seen, rsp_seen,
                     aw_seen, w_seen, b_seen, message);
            $fatal(1);
        end
    endtask

    task automatic send_cmd(input logic [31:0] addr, input integer beats);
        begin
            @(negedge clk); #1;
            cmd_addr = addr;
            cmd_beats = beats;
            cmd_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (cmd_ready) begin
                    @(negedge clk); #1;
                    cmd_valid = 1'b0;
                    break;
                end
            end
        end
    endtask

    task automatic send_payload(input logic [127:0] data,
                                input logic [15:0] strb,
                                input logic last);
        begin
            @(negedge clk); #1;
            payload_data = data;
            payload_strb = strb;
            payload_last = last;
            payload_valid = 1'b1;
            while (1) begin
                @(posedge clk);
                if (payload_ready) begin
                    @(negedge clk); #1;
                    payload_valid = 1'b0;
                    payload_last = 1'b0;
                    break;
                end
            end
        end
    endtask

    task automatic send_flush;
        begin
            @(negedge clk); #1;
            payload_flush = 1'b1;
            @(posedge clk);
            @(negedge clk); #1;
            payload_flush = 1'b0;
        end
    endtask

    task automatic wait_for_response(input integer target);
        integer guard;
        begin
            guard = 0;
            while ((rsp_seen < target) && (guard < 200)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (rsp_seen < target)
                fail("timeout waiting for ordered response");
        end
    endtask

    // Always-ready AXI BFM.  A B response is generated one cycle after WLAST
    // and is always OKAY; payload framing errors must still reach rsp_error.
    always_comb begin
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b1;
        rsp_ready = 1'b1;
        m_axi_bvalid = bvalid_q;
        m_axi_bresp = bresp_q;
    end

    // Handshake scoreboard and tiny B channel model.  Signals are sampled in
    // the active region before DUT NBA updates, so current_w_beat describes
    // the beat actually transferred on this edge.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
            cmd_seen = 0;
            payload_seen = 0;
            rsp_seen = 0;
            aw_seen = 0;
            w_seen = 0;
            b_seen = 0;
            current_w_beat = 0;
            aw_expect_case = 0;
            bvalid_q <= 1'b0;
            bresp_q <= 2'b00;
        end else begin
            cycle_count = cycle_count + 1;
            if (cmd_fire)
                cmd_seen = cmd_seen + 1;
            if (payload_fire)
                payload_seen = payload_seen + 1;

            if (aw_fire) begin
                aw_seen = aw_seen + 1;
                if (aw_expect_case >= TOTAL_CASES-1)
                    fail("command-invalid descriptor issued AW");
                if (m_axi_awaddr !== case_addr[aw_expect_case])
                    fail("AW address/order mismatch");
                if (m_axi_awlen !== (case_beats[aw_expect_case] - 1'b1))
                    fail("AW declared length mismatch");
                if (m_axi_awsize !== 3'd4 || m_axi_awburst !== 2'b01)
                    fail("AW size/burst mismatch");
                aw_expect_case = aw_expect_case + 1;
            end

            if (w_fire) begin
                if (current_case >= TOTAL_CASES-1)
                    fail("command-invalid descriptor issued W");
                if (current_w_beat >= MAX_BEATS)
                    fail("too many W beats");
                if (m_axi_wdata !== expected_data[current_case][current_w_beat])
                    fail("W data mismatch (including zero-fill)");
                if (m_axi_wstrb !== expected_strb[current_case][current_w_beat])
                    fail("W strobe mismatch (including zero-fill)");
                if (m_axi_wlast !==
                    (current_w_beat == (case_beats[current_case] - 1'b1)))
                    fail("W LAST mismatch");
                current_w_beat = current_w_beat + 1;
                w_seen = w_seen + 1;
                if (m_axi_wlast) begin
                    bresp_q <= 2'b00;
                    bvalid_q <= 1'b1;
                end
            end

            if (b_fire) begin
                bvalid_q <= 1'b0;
                b_seen = b_seen + 1;
            end

            if (rsp_fire) begin
                if (rsp_seen >= TOTAL_CASES)
                    fail("excess response");
                if (rsp_tag !== rsp_seen[15:0])
                    fail("response tag order mismatch");
                if (rsp_addr !== case_addr[rsp_seen])
                    fail("response address order mismatch");
                if (rsp_beats !== case_beats[rsp_seen])
                    fail("response beat count mismatch");
                if (rsp_error !== case_error[rsp_seen])
                    fail("response error mismatch");
                rsp_seen = rsp_seen + 1;
            end
        end
    end

    initial begin : stimulus
        integer i, j;
        integer payload_before_aw;
        for (i = 0; i < TOTAL_CASES; i = i + 1) begin
            case_addr[i] = 32'h0000_A000 + (i * 32'h100);
            case_beats[i] = 9'd3;
            case_error[i] = 1'b1;
            for (j = 0; j < MAX_BEATS; j = j + 1) begin
                expected_data[i][j] = 128'd0;
                expected_strb[i][j] = 16'd0;
            end
        end
        // Case 0: complete frame (also primes the slot before ring reuse).
        case_beats[0] = MAX_BEATS;
        case_error[0] = 1'b0;
        for (j = 0; j < MAX_BEATS; j = j + 1) begin
            expected_data[0][j] = 128'hA000_0000 + j;
            expected_strb[0][j] = 16'hffff;
        end
        // Case 1: early LAST after one captured beat; remaining beats zero.
        expected_data[1][0] = 128'hE100;
        expected_strb[1][0] = 16'ha5a5;
        // Case 2: flush after one captured beat; remaining beats zero.
        expected_data[2][0] = 128'hE200;
        expected_strb[2][0] = 16'h5a5a;
        // Case 3: late LAST at the declared two-beat boundary; both captured.
        case_beats[3] = 9'd2;
        expected_data[3][0] = 128'hE300;
        expected_data[3][1] = 128'hE301;
        expected_strb[3][0] = 16'h0f0f;
        expected_strb[3][1] = 16'hf0f0;
        // Case 4: early frame after ring-slot reuse, catching stale RAM data.
        expected_data[4][0] = 128'hE400;
        expected_strb[4][0] = 16'h33cc;
        // Case 5: command-invalid (unaligned) descriptor; no AXI transfer.
        case_addr[5] = 32'h0000_A501;
        case_beats[5] = 9'd2;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Queue two commands before streaming either payload.  This exercises
        // simultaneous command acceptance/fill scheduling and proves that a
        // later descriptor can issue AW while the older slot is still being
        // captured.
        current_case = 0;
        current_w_beat = 0;
        send_cmd(case_addr[0], case_beats[0]);
        send_cmd(case_addr[1], case_beats[1]);
        payload_before_aw = payload_seen;
        while (aw_seen < 2) begin
            @(posedge clk);
            if (payload_seen != payload_before_aw)
                fail("payload arrived before queued early AWs");
        end
        for (j = 0; j < MAX_BEATS; j = j + 1)
            send_payload(expected_data[0][j], expected_strb[0][j],
                         (j == MAX_BEATS-1));
        wait_for_response(1);

        // Early frame for the second descriptor, whose AW was already issued
        // while descriptor 0 was still being captured.
        current_case = 1;
        current_w_beat = 0;
        send_payload(expected_data[1][0], expected_strb[1][0], 1'b1);
        wait_for_response(2);

        // Flush frame.
        current_case = 2;
        current_w_beat = 0;
        send_cmd(case_addr[2], case_beats[2]);
        payload_before_aw = payload_seen;
        while (aw_seen < 3) begin
            @(posedge clk);
            if (payload_seen != payload_before_aw)
                fail("flush frame payload preceded AW");
        end
        send_payload(expected_data[2][0], expected_strb[2][0], 1'b0);
        send_flush();
        wait_for_response(3);

        // Late frame.
        current_case = 3;
        current_w_beat = 0;
        send_cmd(case_addr[3], case_beats[3]);
        payload_before_aw = payload_seen;
        while (aw_seen < 4) begin
            @(posedge clk);
            if (payload_seen != payload_before_aw)
                fail("late frame payload preceded AW");
        end
        send_payload(expected_data[3][0], expected_strb[3][0], 1'b0);
        send_payload(expected_data[3][1], expected_strb[3][1], 1'b0);
        wait_for_response(4);

        // Reuse the first ring slot and repeat early termination.  Zero-fill
        // must not expose case 0's stale payload RAM contents.
        current_case = 4;
        current_w_beat = 0;
        send_cmd(case_addr[4], case_beats[4]);
        payload_before_aw = payload_seen;
        while (aw_seen < 5) begin
            @(posedge clk);
            if (payload_seen != payload_before_aw)
                fail("reused-slot payload preceded AW");
        end
        send_payload(expected_data[4][0], expected_strb[4][0], 1'b1);
        wait_for_response(5);

        // Poisoned command: AW must stay absent until the payload frame is
        // consumed, and no W/B may be generated.
        current_case = 5;
        current_w_beat = 0;
        send_cmd(case_addr[5], case_beats[5]);
        repeat (3) @(posedge clk);
        if (aw_seen != 5 || w_seen != 15 || b_seen != 5)
            fail("poisoned command escaped before payload");
        send_payload(128'hE500, 16'hffff, 1'b0);
        send_payload(128'hE501, 16'hffff, 1'b1);
        wait_for_response(6);

        repeat (3) @(posedge clk);
        if (rsp_seen != TOTAL_CASES || perf_busy)
            fail("engine did not quiesce");
        if (aw_seen != 5 || w_seen != 15 || b_seen != 5)
            fail("unexpected AXI transfer count");
        if (!early_payload_last_error || !late_payload_last_error ||
            !payload_flush_error || !protocol_error)
            fail("framing diagnostics missing");
        if (perf_error_count != 5)
            fail("payload/command errors not counted");
        $display("C1_AXI128_WRITE_MLP_AW_EARLY_PASS desc=%0d aw=%0d w=%0d b=%0d errors=%0d",
                 rsp_seen, aw_seen, w_seen, b_seen, perf_error_count);
        $finish;
    end
endmodule
