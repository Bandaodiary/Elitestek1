`timescale 1ns/1ps

// Directed cache-refill/burst integration smoke.  The tap protocol is kept
// intentionally small while the BFM returns an entire AXI burst with valid
// and ready gaps.  The scoreboard checks cache data, burst attributes and
// that several AR descriptors can be outstanding.
module tb_c1_window_line_cache_c8_burst_shell;
`ifdef C1_CACHE_MAXROW_TB
    // Native maximum-row profile: 640 pixels x 2 C8 groups = 1280
    // logical 64-bit words (640 AXI128 beats).  A 32-beat descriptor is
    // exactly 512 bytes, so the 0x1000 base crosses two 4-KiB boundaries
    // without relying on a page-aligned synthetic short row.
    localparam integer W = 640;
`elsif C1_CACHE_LONG_BURST_TB
    // W=64/G=2 gives 128 logical words (64 AXI beats) per row, so the
    // 16-beat profile can actually keep several descriptors in flight.
    localparam integer W = 64;
`else
    localparam integer W = 8;
`endif
`ifdef C1_CACHE_MAXROW_TB
    localparam integer H = 1;
`else
    localparam integer H = 4;
`endif
    localparam integer G = 2;
    localparam integer ROW_WORDS = W * G;
    localparam integer BASE = 32'h0000_1000;
`ifdef C1_CACHE_MAXROW_TB
    // Four descriptors may be issued before the delayed first R beat.  Keep
    // extra queue slots so the BFM itself cannot hide an outstanding limit.
    localparam integer BFM_DEPTH = 16;
`else
    localparam integer BFM_DEPTH = 8;
`endif
`ifdef C1_CACHE_MAXROW_TB
    localparam integer BURST_BEATS = 32;
    localparam integer MAX_OUTSTANDING = 4;
`ifdef C1_CACHE_BEAT_FIFO_TB
    localparam integer RSP_DEPTH = BURST_BEATS * MAX_OUTSTANDING;
    localparam bit BEAT_FIFO_MODE = 1'b1;
`else
    localparam integer RSP_DEPTH = 2 * BURST_BEATS * MAX_OUTSTANDING;
    localparam bit BEAT_FIFO_MODE = 1'b0;
`endif
    localparam integer REQ_DEPTH = 32;
    localparam integer BFM_START_DELAY = 200;
`elsif C1_CACHE_LONG_BURST_TB
    localparam integer BURST_BEATS = 16;
    localparam integer MAX_OUTSTANDING = 4;
`ifdef C1_CACHE_BEAT_FIFO_TB
    localparam integer RSP_DEPTH = BURST_BEATS * MAX_OUTSTANDING;
    localparam bit BEAT_FIFO_MODE = 1'b1;
`else
    localparam integer RSP_DEPTH = 2 * BURST_BEATS * MAX_OUTSTANDING;
    localparam bit BEAT_FIFO_MODE = 1'b0;
`endif
    localparam integer REQ_DEPTH = 32;
    localparam integer BFM_START_DELAY = 200;
`else
`ifdef C1_CACHE_BEAT_FIFO_TB
    localparam integer RSP_DEPTH = 12;
    localparam bit BEAT_FIFO_MODE = 1'b1;
`else
    localparam integer RSP_DEPTH = 32;
    localparam bit BEAT_FIFO_MODE = 1'b0;
`endif
    localparam integer BURST_BEATS = 4;
    localparam integer MAX_OUTSTANDING = 3;
    localparam integer REQ_DEPTH = 16;
    localparam integer BFM_START_DELAY = 20;
`endif
`ifdef C1_CACHE_TAIL_FLUSH_TB
    localparam bit TAIL_FLUSH_MODE = 1'b1;
`else
    localparam bit TAIL_FLUSH_MODE = 1'b0;
`endif
`ifdef C1_CACHE_REQ_POP_REFILL_TB
    localparam bit REQ_POP_REFILL_MODE = 1'b1;
`else
    localparam bit REQ_POP_REFILL_MODE = 1'b0;
`endif
`ifdef C1_CACHE_RSP_POP_REFILL_TB
    localparam bit RSP_POP_REFILL_MODE = 1'b1;
`else
    localparam bit RSP_POP_REFILL_MODE = 1'b0;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic stage_base_valid = 1'b1;
    logic [31:0] stage_base_addr = BASE;
    logic group_start_valid = 1'b0, group_start_ready;
    logic [15:0] frame_width = W, frame_height = H;
    logic [3:0] frame_groups = G;
    logic group_start_done, group_start_error;
    logic [2:0] group_start_error_code;
    logic config_valid;
    logic abort_req = 1'b0, abort_done;
    logic flush_req = 1'b0, flush_done;
    logic tap_valid = 1'b0, tap_ready;
    logic signed [16:0] tap_x = '0, tap_y = '0;
    logic [2:0] tap_group = '0;
    logic tap_rsp_valid, tap_rsp_ready = 1'b1;
    logic [63:0] tap_rsp_data_s8;
    logic tap_rsp_error;
    logic m_axi_arvalid, m_axi_arready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic cache_error;
    logic [2:0] cache_error_code;
    logic busy, quiescent;
    logic [63:0] perf_refill_count, perf_refill_word_count;
    logic [63:0] perf_axi_burst_count, perf_axi_beat_count;
    logic [63:0] perf_cache_rsp_count;
    logic [7:0] perf_max_outstanding;

    c1_window_line_cache_c8_burst_shell #(
        .DATA_W(64), .LINE_ROWS(3), .MAX_ROW_WORDS(ROW_WORDS),
        .MAX_GROUPS(8), .REQ_FIFO_DEPTH(REQ_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .MAX_OUTSTANDING(MAX_OUTSTANDING), .RSP_FIFO_DEPTH(RSP_DEPTH),
        .BUILD_TIMEOUT_CYCLES(3),
        .REFILL_TAIL_FLUSH(TAIL_FLUSH_MODE),
        .RSP_FIFO_BEAT_MODE(BEAT_FIFO_MODE),
        .ALLOW_RSP_POP_REFILL(RSP_POP_REFILL_MODE),
        .ALLOW_REQ_POP_REFILL(REQ_POP_REFILL_MODE)
    ) dut (
        .clk, .rst, .stage_base_valid, .stage_base_addr,
        .group_start_valid, .group_start_ready,
        .frame_width, .frame_height, .frame_groups,
        .group_start_done, .group_start_error, .group_start_error_code,
        .config_valid, .abort_req, .abort_done, .flush_req, .flush_done,
        .tap_valid, .tap_ready, .tap_x, .tap_y, .tap_group,
        .tap_rsp_valid, .tap_rsp_ready, .tap_rsp_data_s8, .tap_rsp_error,
        .m_axi_arvalid, .m_axi_arready, .m_axi_araddr, .m_axi_arlen,
        .m_axi_arsize, .m_axi_arburst, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
        .cache_error, .cache_error_code, .busy, .quiescent,
        .perf_refill_count, .perf_refill_word_count,
        .perf_axi_burst_count, .perf_axi_beat_count,
        .perf_cache_rsp_count, .perf_max_outstanding
    );

    integer cycle_count = 0;
    integer ar_count = 0;
    integer ar_beats_sum = 0;
    integer ar_page_split_count = 0;
    integer bfm_head = 0, bfm_tail = 0, bfm_count = 0;
    integer bfm_beat = 0;
    logic [31:0] expected_next_ar_addr = 32'd0;
    // Hold the first response long enough for the reader to publish and issue
    // the next descriptor.  This models DDR read latency; ARREADY stalls alone
    // cannot exercise multiple outstanding reads after an AR has handshaken.
    integer bfm_start_delay = 0;
    logic bfm_active = 1'b0;
    logic bfm_r_hold = 1'b0;
    logic [31:0] bfm_base [0:BFM_DEPTH-1];
    logic [8:0] bfm_len [0:BFM_DEPTH-1];
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        m_axi_arready = ((cycle_count % 5) != 1) && (bfm_count < BFM_DEPTH);
        // Once VALID is presented while READY is low, hold it (and the
        // associated beat/last/data) until the handshake, as required by
        // AXI.  The modulo term only creates idle gaps between beats.
        m_axi_rvalid = bfm_active &&
                       (bfm_r_hold || ((cycle_count % 4) != 2));
        m_axi_rresp = 2'b00;
        m_axi_rlast = bfm_active &&
                      (bfm_beat == bfm_len[bfm_head] - 1);
        m_axi_rdata = {
            64'hB000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_beat*16},
            64'hA000_0000_0000_0000 | {32'd0, bfm_base[bfm_head] + bfm_beat*16}
        };
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            ar_count <= 0;
            ar_beats_sum <= 0;
            ar_page_split_count <= 0;
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_beat <= 0;
            bfm_active <= 1'b0;
            bfm_start_delay <= 0;
            bfm_r_hold <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (!bfm_active && bfm_count != 0) begin
                if (bfm_start_delay != 0)
                    bfm_start_delay <= bfm_start_delay - 1;
                else begin
                    bfm_active <= 1'b1;
                    bfm_beat <= 0;
                    bfm_r_hold <= 1'b0;
                end
            end
            if (ar_fire) begin
                $display("TB_CACHE_AR addr=%h len=%0d t=%0t", m_axi_araddr,
                         m_axi_arlen, $time);
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "bad AXI burst attributes");
                if ((m_axi_araddr >> 12) !=
                    ((m_axi_araddr + (m_axi_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "burst crossed 4KiB boundary");
`ifdef C1_CACHE_MAXROW_TB
                // The maximum-row profile is a contiguous 1280-word stream.
                // Check descriptor adjacency at the AR boundary so a passing
                // burst count cannot conceal a dropped or duplicated beat.
                if (ar_count == 0) begin
                    if (m_axi_araddr !== BASE)
                        $fatal(1, "maximum-row first AR base mismatch got=%h expected=%h",
                               m_axi_araddr, BASE);
                end else if (m_axi_araddr !== expected_next_ar_addr) begin
                    $fatal(1, "maximum-row AR gap/order mismatch index=%0d got=%h expected=%h",
                           ar_count, m_axi_araddr, expected_next_ar_addr);
                end
                if ((ar_count != 0) && (m_axi_araddr[11:0] == 12'h000))
                    ar_page_split_count <= ar_page_split_count + 1;
                expected_next_ar_addr <= m_axi_araddr +
                    ((m_axi_arlen + 1) * 16);
                ar_beats_sum <= ar_beats_sum + m_axi_arlen + 1;
`endif
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_len[bfm_tail] <= m_axi_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_DEPTH;
                ar_count <= ar_count + 1;
                if (bfm_count == 0)
                    // Keep the first long-profile response pending long
                    // enough for the reader to publish all four ARs in the
                    // long profile; the normal smoke retains 20 cycles.
                    bfm_start_delay <= BFM_START_DELAY;
            end
            if (r_fire) begin
                $display("TB_CACHE_R beat=%0d last=%0d t=%0t", bfm_beat,
                         m_axi_rlast, $time);
                if (m_axi_rlast) begin
                    bfm_active <= 1'b0;
                    bfm_head <= (bfm_head + 1) % BFM_DEPTH;
                end else begin
                    bfm_beat <= bfm_beat + 1;
                end
            end
            if (m_axi_rvalid && !m_axi_rready)
                bfm_r_hold <= 1'b1;
            else if (r_fire || !bfm_active)
                bfm_r_hold <= 1'b0;
            // Preserve queue occupancy when an AR enqueue and the previous
            // burst's terminal R beat share a clock edge.
            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (dut.refill_start_fire)
                $display("TB_REFILL_START row=%0d words=%0d t=%0t",
                         dut.cache_refill_req_row,
                         dut.cache_refill_req_word_count, $time);
            if (dut.req_fire)
                $display("TB_READER_REQ idx=%0d addr=%h t=%0t",
                         dut.feed_index_q, dut.client_req_addr, $time);
            if (dut.rsp_fire)
                $display("TB_READER_RSP idx=%0d last=%0d t=%0t",
                         dut.rsp_index_q, dut.cache_refill_word_last, $time);
            if ((cycle_count >= 20) && (cycle_count <= 40))
                $display("TB_READER_STATE t=%0t q=%0d build=%0d total=%0d issued=%0d complete0=%0d complete1=%0d issue0=%0d issue1=%0d",
                         $time, dut.u_reader.req_count_q,
                         dut.u_reader.build_active_q,
                         dut.u_reader.desc_total_count_q,
                         dut.u_reader.desc_issued_count_q,
                         dut.u_reader.desc_complete_mem[0],
                         dut.u_reader.desc_complete_mem[1],
                         dut.u_reader.desc_issued_mem[0],
                         dut.u_reader.desc_issued_mem[1]);
        end
    end

    function automatic [63:0] expected_word(input integer x, input integer y,
                                             input integer g);
        logic [31:0] a;
        begin
            a = BASE + ((y * ROW_WORDS + x * G + g) * 8);
            expected_word = a[3] ?
                (64'hB000_0000_0000_0000 | {32'd0, {a[31:4],4'd0}}) :
                (64'hA000_0000_0000_0000 | {32'd0, {a[31:4],4'd0}});
        end
    endfunction

    integer expected_x, expected_y, expected_g;
    integer response_count = 0;
    integer tap_count = 0;
    integer timeout_count = 0;
    integer tail_flush_count = 0;
    integer close_count = 0;
    integer flush_close_count = 0;
    integer close_cycle_sum = 0;
    integer flush_cycle_sum = 0;

    // Count the internal pulse only as a lightweight proof that the optional
    // mode closed every known row tail.  The pulse is deliberately generated
    // after the reader request FIFO drains, so it cannot suppress pack2.
    always @(posedge clk) begin
        if (rst) begin
            tail_flush_count <= 0;
            close_count <= 0;
            flush_close_count <= 0;
            close_cycle_sum <= 0;
            flush_cycle_sum <= 0;
        end else begin
            if (dut.client_req_flush)
                tail_flush_count <= tail_flush_count + 1;
            if (dut.u_reader.build_close) begin
                close_count <= close_count + 1;
                close_cycle_sum <= close_cycle_sum + cycle_count;
            end
            if (dut.client_req_flush)
                flush_cycle_sum <= flush_cycle_sum + cycle_count;
            if (dut.client_req_flush && dut.u_reader.build_close)
                flush_close_count <= flush_close_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            response_count <= 0;
        end else if (tap_rsp_valid && tap_rsp_ready) begin
            if (tap_rsp_error)
                $fatal(1, "unexpected cache response error");
            if (tap_rsp_data_s8 !== expected_word(expected_x, expected_y,
                                                  expected_g))
                $fatal(1, "cache response mismatch x/y/g=%0d/%0d/%0d got=%h exp=%h",
                       expected_x, expected_y, expected_g, tap_rsp_data_s8,
                       expected_word(expected_x, expected_y, expected_g));
            response_count <= response_count + 1;
        end
    end

    task automatic do_tap(input integer x, input integer y, input integer g);
        begin
            expected_x = x; expected_y = y; expected_g = g;
            @(negedge clk);
            $display("TB_TAP_LAUNCH x/y/g=%0d/%0d/%0d ready=%0d t=%0t",
                     x, y, g, tap_ready, $time);
            tap_x = x; tap_y = y; tap_group = g; tap_valid = 1'b1;
            do @(posedge clk); while (!tap_ready);
            @(negedge clk);
            tap_valid = 1'b0;
            tap_count = tap_count + 1;
            wait (response_count == tap_count);
        end
    endtask

    initial begin
        repeat (6) @(posedge clk);
        @(negedge clk); rst = 1'b0; group_start_valid = 1'b1;
        $display("TB_GROUP_LAUNCH ready=%0d t=%0t", group_start_ready, $time);
        do @(posedge clk); while (!group_start_ready);
        $display("TB_GROUP_FIRE t=%0t", $time);
        @(negedge clk); group_start_valid = 1'b0;
        // group_start_done is a one-cycle pulse on the handshake edge;
        // allow the cache's registered geometry to settle before taps.
        repeat (2) @(posedge clk);

`ifdef C1_CACHE_MAXROW_TB
        // Native 640x1x2 row profile.  The selected taps straddle both
        // 4-KiB boundaries (0x2000/0x3000) and exercise both packed lanes;
        // the repeated resident-row accesses must not trigger another refill.
        do_tap(0,   0, 0);
        do_tap(0,   0, 1);
        do_tap(255, 0, 0);
        do_tap(255, 0, 1);
        do_tap(256, 0, 0);
        do_tap(511, 0, 1);
        do_tap(512, 0, 0);
        do_tap(639, 0, 1);

        repeat (40) @(posedge clk);
        if (cache_error || group_start_error)
            $fatal(1, "maximum-row cache shell reported error code=%0d",
                   cache_error_code);
        if (perf_refill_count != 1 || perf_refill_word_count != 1280 ||
            perf_cache_rsp_count != 1280)
            $fatal(1, "maximum-row refill accounting mismatch refills=%0d words=%0d rsp=%0d",
                   perf_refill_count, perf_refill_word_count,
                   perf_cache_rsp_count);
        if (perf_axi_burst_count != 20 || perf_axi_beat_count != 640)
            $fatal(1, "maximum-row AXI geometry mismatch bursts=%0d beats=%0d",
                   perf_axi_burst_count, perf_axi_beat_count);
        if (dut.client_packed_count != 640)
            $fatal(1, "maximum-row pack2 count mismatch packed=%0d expected=640",
                   dut.client_packed_count);
        if (ar_count != 20 || ar_beats_sum != 640 ||
            ar_page_split_count != 2)
            $fatal(1, "maximum-row AR coverage mismatch ar=%0d beats=%0d page_splits=%0d",
                   ar_count, ar_beats_sum, ar_page_split_count);
        if (perf_max_outstanding != 4)
            $fatal(1, "maximum-row outstanding coverage mismatch max=%0d expected=4",
                   perf_max_outstanding);
`else
        // Four rows cause replacement in the three-row cache.  Each refill
        // is long enough to create multiple AXI bursts and outstanding ARs.
        do_tap(0, 0, 0);
        do_tap(1, 0, 1);
        do_tap(2, 1, 0);
        do_tap(3, 2, 1);
        do_tap(4, 3, 0);
        do_tap(5, 0, 1); // row 0 may have been evicted; checks re-fill path

        repeat (20) @(posedge clk);
        if (cache_error || group_start_error)
            $fatal(1, "cache shell reported error code=%0d", cache_error_code);
        if (perf_refill_count < 4 || perf_refill_word_count != perf_cache_rsp_count)
            $fatal(1, "refill accounting mismatch refills=%0d words=%0d rsp=%0d",
                   perf_refill_count, perf_refill_word_count, perf_cache_rsp_count);
        if (perf_axi_burst_count >= perf_refill_word_count)
            $fatal(1, "burst reduction missing bursts=%0d words=%0d",
                   perf_axi_burst_count, perf_refill_word_count);
        if (perf_max_outstanding < 2)
            $fatal(1, "multi-outstanding coverage missing max=%0d",
                   perf_max_outstanding);
        if (TAIL_FLUSH_MODE && (tail_flush_count < perf_refill_count))
            $fatal(1, "tail flush coverage missing pulses=%0d refills=%0d",
                   tail_flush_count, perf_refill_count);
        if (!TAIL_FLUSH_MODE && (tail_flush_count != 0))
            $fatal(1, "tail flush unexpectedly active pulses=%0d",
                   tail_flush_count);
        if (flush_close_count != tail_flush_count)
            $fatal(1, "tail flush did not close a descriptor pulses=%0d closes=%0d",
                   tail_flush_count, flush_close_count);
        if (busy)
            $fatal(1, "cache shell remains busy");
        $display("C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=%0d refills=%0d words=%0d bursts=%0d beats=%0d max_outstanding=%0d tail_flush=%0d rsp_pop_refill=%0d req_pop_refill=%0d flush_closes=%0d closes=%0d close_cycle_sum=%0d flush_cycle_sum=%0d cycles=%0d",
                  tap_count, perf_refill_count, perf_refill_word_count,
                  perf_axi_burst_count, perf_axi_beat_count,
                  perf_max_outstanding, tail_flush_count, RSP_POP_REFILL_MODE,
                  REQ_POP_REFILL_MODE,
                 flush_close_count,
                  close_count, close_cycle_sum, flush_cycle_sum, cycle_count);
        $finish;
`endif
`ifdef C1_CACHE_MAXROW_TB
        if (TAIL_FLUSH_MODE && (tail_flush_count < perf_refill_count))
            $fatal(1, "maximum-row tail flush coverage missing pulses=%0d refills=%0d",
                   tail_flush_count, perf_refill_count);
        if (!TAIL_FLUSH_MODE && (tail_flush_count != 0))
            $fatal(1, "maximum-row tail flush unexpectedly active pulses=%0d",
                   tail_flush_count);
        if (flush_close_count != tail_flush_count)
            $fatal(1, "maximum-row tail flush close mismatch pulses=%0d closes=%0d",
                   tail_flush_count, flush_close_count);
        if (busy)
            $fatal(1, "maximum-row cache shell remains busy");
        $display("C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_MAXROW_PASS taps=%0d refills=%0d words=%0d bursts=%0d beats=%0d packed=%0d ar=%0d ar_beats=%0d page_splits=%0d max_outstanding=%0d tail_flush=%0d cycles=%0d",
                  tap_count, perf_refill_count, perf_refill_word_count,
                  perf_axi_burst_count, perf_axi_beat_count,
                  dut.client_packed_count, ar_count, ar_beats_sum,
                  ar_page_split_count, perf_max_outstanding,
                  tail_flush_count, cycle_count);
        $finish;
`endif
    end

    initial begin
        #500000;
        $fatal(1, "cache burst shell timeout");
    end
endmodule
