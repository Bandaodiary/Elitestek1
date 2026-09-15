`timescale 1ns/1ps

// Compact boardless contract test for the exact line-cache integration seam.
//
// The first row exercises the ordinary row/base/pack2 path.  The second row
// deliberately holds AXI AR service off, accepts a few logical requests, and
// then raises flush.  The completion adapter must feed the cache an
// exact-count stream (accepted stale words plus synthetic zero/error suffix),
// after which the still-pending tap retries successfully in the new epoch.
module tb_c1_window_line_cache_c8_exact_burst_shell;
`ifdef C1_EXACT_REPEAT_ABORT
    localparam bit USE_ABORT=1;
`else
    localparam bit USE_ABORT=0;
`endif
    localparam integer W = 4;
`ifdef C1_EXACT_MIXED_MAINTENANCE
    localparam bit MIXED=1;
`else
    localparam bit MIXED=0;
`endif
    localparam integer H = 2;
    localparam integer G = 2;
    localparam integer ROW_WORDS = W * G;
    localparam integer BASE = 32'h0000_1000;
    localparam integer BFM_DEPTH = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic stage_base_valid = 1'b1;
    logic [31:0] stage_base_addr = BASE;
    logic group_start_valid = 1'b0;
    logic group_start_ready;
    logic [15:0] frame_width = W;
    logic [15:0] frame_height = H;
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
    logic refill_protocol_error, refill_done, refill_done_error;
    logic busy, quiescent;
    logic [63:0] perf_refill_count, perf_refill_word_count;
    logic [63:0] perf_axi_burst_count, perf_axi_beat_count;
    logic [63:0] perf_cache_rsp_count;
    logic [7:0] perf_max_outstanding;
    logic [3:0] current_epoch;
    logic drain_pending;
    logic [7:0] outstanding, max_outstanding_seen, cmd_occupancy;
    logic [63:0] perf_cmd_accept_count, perf_req_count, perf_rsp_count;
    logic [63:0] perf_word_count, perf_stale_drop_count;
    logic [63:0] perf_orphan_rsp_count, perf_scheduler_error_count;
    logic [63:0] leaf_perf_req_accept_count, leaf_perf_axi_burst_count;
    logic [63:0] leaf_perf_axi_beat_count, leaf_perf_rsp_count;
    logic [63:0] leaf_perf_packed_request_count, leaf_perf_error_count;
    logic [7:0] leaf_perf_req_occupancy, leaf_perf_max_req_occupancy;
    logic [7:0] leaf_perf_outstanding, leaf_perf_max_outstanding;

    c1_window_line_cache_c8_exact_burst_shell #(
        .DATA_W(64), .LINE_ROWS(3), .MAX_ROW_WORDS(ROW_WORDS),
        .MAX_GROUPS(8), .EPOCH_W(4), .CMD_FIFO_DEPTH(2),
        .SCHED_MAX_OUTSTANDING(4), .REQ_FIFO_DEPTH(8),
        .BURST_BEATS(4), .READER_MAX_OUTSTANDING(2),
        .RSP_FIFO_DEPTH(16), .BUILD_TIMEOUT_CYCLES(2)
    ) dut (
        .clk, .rst, .stage_base_valid, .stage_base_addr,
        .group_start_valid, .group_start_ready,
        .frame_width, .frame_height, .frame_groups,
        .group_start_done, .group_start_error, .group_start_error_code,
        .config_valid, .abort_req(USE_ABORT ? flush_req : abort_req), .abort_done,
        .flush_req(USE_ABORT ? abort_req : flush_req), .flush_done,
        .tap_valid, .tap_ready, .tap_x, .tap_y, .tap_group,
        .tap_rsp_valid, .tap_rsp_ready, .tap_rsp_data_s8, .tap_rsp_error,
        .m_axi_arvalid, .m_axi_arready, .m_axi_araddr, .m_axi_arlen,
        .m_axi_arsize, .m_axi_arburst, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
        .cache_error, .cache_error_code, .refill_protocol_error,
        .refill_done, .refill_done_error, .busy, .quiescent,
        .perf_refill_count, .perf_refill_word_count,
        .perf_axi_burst_count, .perf_axi_beat_count,
        .perf_cache_rsp_count, .perf_max_outstanding,
        .current_epoch, .drain_pending, .outstanding,
        .max_outstanding_seen, .cmd_occupancy,
        .perf_cmd_accept_count, .perf_req_count, .perf_rsp_count,
        .perf_word_count, .perf_stale_drop_count,
        .perf_orphan_rsp_count, .perf_scheduler_error_count,
        .leaf_perf_req_accept_count, .leaf_perf_axi_burst_count,
        .leaf_perf_axi_beat_count, .leaf_perf_rsp_count,
        .leaf_perf_packed_request_count, .leaf_perf_error_count,
        .leaf_perf_req_occupancy, .leaf_perf_max_req_occupancy,
        .leaf_perf_outstanding, .leaf_perf_max_outstanding
    );

    // ------------------------------------------------------------------
    // Small in-order AXI read BFM.  Data encodes the byte address, matching
    // the existing shell tests and making row-base/pack-lane errors visible.
    // ------------------------------------------------------------------
    integer cycle_count = 0;
    integer ar_count = 0;
    integer beat_count = 0;
    integer bfm_head = 0, bfm_tail = 0, bfm_count = 0;
    integer bfm_beat = 0;
    integer bfm_start_delay = 0;
    logic bfm_active = 1'b0;
    logic bfm_r_hold = 1'b0;
    logic allow_axi = 1'b1;
    logic [31:0] bfm_base [0:BFM_DEPTH-1];
    logic [8:0] bfm_len [0:BFM_DEPTH-1];

    function automatic [63:0] value_for_addr(input logic [31:0] a);
        begin
            value_for_addr = a[3] ?
                (64'hB000_0000_0000_0000 | {32'd0, {a[31:4],4'd0}}) :
                (64'hA000_0000_0000_0000 | {32'd0, {a[31:4],4'd0}});
        end
    endfunction

    always_comb begin
        m_axi_arready = allow_axi && (bfm_count < BFM_DEPTH) &&
                        ((cycle_count % 3) != 1);
        m_axi_rvalid = bfm_active &&
                       (bfm_r_hold || ((cycle_count % 4) != 2));
        m_axi_rresp = 2'b00;
        m_axi_rlast = bfm_active &&
                      (bfm_beat == (bfm_len[bfm_head] - 1));
        m_axi_rdata = {
            value_for_addr(bfm_base[bfm_head] + bfm_beat*16 + 8),
            value_for_addr(bfm_base[bfm_head] + bfm_beat*16)
        };
    end

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            ar_count <= 0;
            beat_count <= 0;
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_beat <= 0;
            bfm_start_delay <= 0;
            bfm_active <= 1'b0;
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
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "bad AXI attributes");
                if ((m_axi_araddr >> 12) !=
                    ((m_axi_araddr + (m_axi_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "AXI burst crossed 4-KiB boundary");
                bfm_base[bfm_tail] <= m_axi_araddr;
                bfm_len[bfm_tail] <= m_axi_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_DEPTH;
                ar_count <= ar_count + 1;
                if (bfm_count == 0)
                    bfm_start_delay <= 3;
            end
            if (r_fire) begin
                beat_count <= beat_count + 1;
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
            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    integer response_count = 0;
    integer expected_x = 0, expected_y = 0, expected_g = 0;
    integer flush_count = 0;
    integer other_count = 0;
    integer refill_done_count = 0;
    integer cancel_req_start = 0;
    integer cancel_req_observed = 0;
    integer cancel_source_observed = 0;
    integer cancel_drain_observed = 0;
    integer cancel_synthetic_observed = 0;
    integer cancel_unified_observed = 0;
    integer cancel_error_done_count = 0;
    logic cancel_measure_active = 1'b0;
    logic saw_cancel_error = 1'b0;

    function automatic [63:0] expected_word(
        input integer x, input integer y, input integer g
    );
        logic [31:0] a;
        begin
            a = BASE + ((y * ROW_WORDS + x * G + g) * 8);
            expected_word = value_for_addr(a);
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            response_count <= 0;
            flush_count <= 0;
            other_count <= 0;
            refill_done_count <= 0;
            cancel_req_observed <= 0;
            cancel_source_observed <= 0;
            cancel_drain_observed <= 0;
            cancel_synthetic_observed <= 0;
            cancel_unified_observed <= 0;
            cancel_error_done_count <= 0;
            cancel_measure_active <= 1'b0;
            saw_cancel_error <= 1'b0;
        end else begin
            if (tap_rsp_valid && tap_rsp_ready) begin
                if (tap_rsp_error)
                    $fatal(1, "unexpected tap response error");
                if (tap_rsp_data_s8 !== expected_word(expected_x, expected_y,
                                                       expected_g))
                    $fatal(1, "tap mismatch x/y/g=%0d/%0d/%0d got=%h exp=%h",
                           expected_x, expected_y, expected_g,
                           tap_rsp_data_s8,
                           expected_word(expected_x, expected_y, expected_g));
                response_count <= response_count + 1;
            end
            if (USE_ABORT ? abort_done : flush_done)
                flush_count <= flush_count + 1;
            if (USE_ABORT ? flush_done : abort_done)
                other_count <= other_count + 1;
            if (refill_done) begin
                refill_done_count <= refill_done_count + 1;
                if (refill_done_error)
                    saw_cancel_error <= 1'b1;
            end
            if (refill_done && refill_done_error)
                cancel_error_done_count <= cancel_error_done_count + 1;
            if (refill_protocol_error)
                saw_cancel_error <= 1'b1;

            // The hierarchy is intentionally used only by this compact
            // contract TB.  It makes the cancellation marker distinguish an
            // accepted logical prefix, responses drained from that prefix,
            // and locally synthesized poison suffix words.
            if (cancel_measure_active) begin
                if (dut.u_exact.u_core.u_scheduler.req_fire)
                    cancel_req_observed <= cancel_req_observed + 1;
                if (dut.u_exact.u_completion.source_fire) begin
                    cancel_source_observed <= cancel_source_observed + 1;
                    if (dut.u_exact.u_core.u_scheduler.stale_rsp)
                        cancel_drain_observed <= cancel_drain_observed + 1;
                end
                if (dut.u_exact.u_completion.synthetic_fire)
                    cancel_synthetic_observed <= cancel_synthetic_observed + 1;
                if (dut.u_exact.u_completion.refill_fire)
                    cancel_unified_observed <= cancel_unified_observed + 1;
            end
        end
    end

    task automatic do_tap(input integer x, input integer y, input integer g);
        integer guard;
        integer target;
        begin
            expected_x = x;
            expected_y = y;
            expected_g = g;
            target = response_count + 1;
            @(negedge clk);
            tap_x = x;
            tap_y = y;
            tap_group = g;
            tap_valid = 1'b1;
            guard = 0;
            while (!tap_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "tap_ready timeout x/y/g=%0d/%0d/%0d", x,y,g);
            end
            @(posedge clk);
            @(negedge clk);
            tap_valid = 1'b0;
            guard = 0;
            while (response_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "tap response timeout x/y/g=%0d/%0d/%0d", x,y,g);
            end
        end
    endtask

    task automatic start_group;
        integer guard;
        begin
            @(negedge clk);
            group_start_valid = 1'b1;
            guard = 0;
            while (!group_start_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 50)
                    $fatal(1, "group_start_ready timeout");
            end
            @(posedge clk);
            @(negedge clk);
            group_start_valid = 1'b0;
            if (!group_start_done || group_start_error || !config_valid)
                $fatal(1, "group start failed done=%0b err=%0b cfg=%0b",
                       group_start_done, group_start_error, config_valid);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        start_group();

        // Normal row/base/pack2 path.
        do_tap(0, 0, 0);
        do_tap(3, 0, 1);
        if (perf_refill_count != 1 || perf_refill_word_count != ROW_WORDS ||
            perf_cache_rsp_count != ROW_WORDS)
            $fatal(1, "normal refill accounting mismatch ref=%0d words=%0d rsp=%0d",
                   perf_refill_count, perf_refill_word_count,
                   perf_cache_rsp_count);

        // Cancellation path.  Hold AXI service off after the cache starts the
        // next row so accepted logical requests exist but no response can
        // arrive before the fence.
        allow_axi = 1'b0;
        cancel_req_start = perf_req_count;
        cancel_measure_active = 1'b1;
        cancel_req_observed = 0;
        cancel_source_observed = 0;
        cancel_drain_observed = 0;
        cancel_synthetic_observed = 0;
        cancel_unified_observed = 0;
        cancel_error_done_count = 0;
        @(negedge clk);
        expected_x = 1;
        expected_y = 1;
        expected_g = 0;
        tap_x = 1;
        tap_y = 1;
        tap_group = 0;
        tap_valid = 1'b1;
        while (perf_req_count < (cancel_req_start + 2)) begin
            @(negedge clk);
            if (cycle_count > 500)
                $fatal(1, "scheduler did not accept pre-flush requests");
        end
        @(negedge clk);
        flush_req = 1'b1;
        // The scheduler's close pulse waits for the reader request FIFO to
        // drain.  Holding AR service off until flush_done would therefore
        // deadlock the very queue we are trying to fence.  Capture one clean
        // flush edge, then release AXI so the accepted prefix can drain.
        @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        // Directly forwarded requests differ from the outer cache client's
        // held child request. Exercise another pulse before AXI can drain.
        repeat(12) begin
            @(negedge clk);
            if(!(USE_ABORT ? dut.abort_pending_q : dut.flush_pending_q) ||
               (USE_ABORT ? abort_done : flush_done) || flush_count!=0)
                $fatal(1,"exact-shell flush retired before stalled AR drain");
        end
        if(MIXED) abort_req=1; else flush_req=1;
        @(negedge clk);flush_req=0;abort_req=0;
        allow_axi = 1'b1;
        while (flush_count == 0 || (MIXED && other_count==0)) begin
            @(negedge clk);
            if (cycle_count > 1000)
                $fatal(1, "flush_done timeout");
        end
        // Freeze the cancellation counters after the adapter's error
        // completion; the following retry belongs to the new epoch.
        while (cancel_error_done_count == 0) begin
            @(negedge clk);
            if (cycle_count > 1200)
                $fatal(1, "canceled refill_done_error timeout");
        end
        cancel_measure_active = 1'b0;
        if(USE_ABORT || MIXED) begin
            // Abort invalidates the group; flush retains it. A held tap must
            // not produce data until the caller explicitly configures again.
            repeat(12) begin
                @(negedge clk);
                if(config_valid || tap_ready || response_count!=2)
                    $fatal(1,"abort allowed tap output without reconfiguration");
            end
            start_group();
        end

        // The pending tap must retry after the poisoned row is discarded and
        // then return the real row-1 word from a fresh epoch.
        while (response_count < 3) begin
            @(negedge clk);
            if (cycle_count > 1500)
                $fatal(1, "post-flush tap response timeout");
        end
        tap_valid = 1'b0;

        if (!saw_cancel_error || current_epoch == 0)
            $fatal(1, "cancellation evidence missing protocol=%0b epoch=%0d",
                   saw_cancel_error, current_epoch);
        if (cancel_req_observed < 2)
            $fatal(1, "accepted cancellation prefix too short req=%0d",
                   cancel_req_observed);
        if (cancel_unified_observed != ROW_WORDS ||
            (cancel_source_observed + cancel_synthetic_observed) != ROW_WORDS ||
            cancel_drain_observed != cancel_source_observed)
            $fatal(1, "exact cancellation accounting mismatch req=%0d source=%0d drain=%0d synthetic=%0d unified=%0d",
                   cancel_req_observed, cancel_source_observed,
                   cancel_drain_observed, cancel_synthetic_observed,
                   cancel_unified_observed);
        if (perf_refill_count < 3 || perf_refill_word_count < (ROW_WORDS*2))
            $fatal(1, "post-flush refill accounting too small ref=%0d words=%0d",
                   perf_refill_count, perf_refill_word_count);

        repeat (10) @(posedge clk);
        if (!quiescent || busy)
            $fatal(1, "exact line-cache shell did not quiesce busy=%0b q=%0b",
                   busy, quiescent);
        if(flush_count!=1 || other_count!=MIXED)
            $fatal(1,"repeated exact-shell flush did not merge while pending count=%0d",flush_count);
        $display("C1_EXACT_SHELL_REPEATED_MAINTENANCE_PASS abort=%0d pulses=2 ar_hold=12 completions=1 retry_correct=1",USE_ABORT);
        if(MIXED)
            $display("C1_EXACT_SHELL_MIXED_MAINTENANCE_PASS first_abort=%0d abort_done=1 flush_done=1 reconfigured=1",USE_ABORT);
        begin : completion_boundary
            integer baseline,guard;
            @(negedge clk);baseline=flush_count;
            flush_req=1;
            @(negedge clk);flush_req=0;
            guard=0;
            while(!(USE_ABORT ? abort_done : flush_done)) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"first boundary maintenance did not complete");
            end
            // The request was low long enough to rearm. Assert the next
            // request on the cycle carrying the old registered completion.
            flush_req=1;
            @(posedge clk);
            if(!(USE_ABORT ? abort_done : flush_done))
                $fatal(1,"boundary fixture missed old done/new request overlap");
            @(negedge clk);flush_req=0;
            guard=0;
            while(flush_count<baseline+2) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"new request lost at old completion boundary");
            end
            repeat(12) @(negedge clk);
            if(flush_count!=baseline+2 || !quiescent || busy)
                $fatal(1,"boundary request duplicated completion or failed drain");
            $display("C1_EXACT_SHELL_DONE_OVERLAP_PASS abort=%0d requests=2 completions=2",USE_ABORT);
        end
        begin : join_boundary
            integer baseline,guard;
            @(negedge clk);baseline=flush_count;flush_req=1;
            @(negedge clk);flush_req=0;
            guard=0;
            while(!(USE_ABORT ?
                (dut.abort_pending_q && (dut.abort_cache_seen_q || dut.cache_abort_done) &&
                 (dut.abort_exact_seen_q || dut.exact_abort_done)) :
                (dut.flush_pending_q && (dut.flush_cache_seen_q || dut.cache_flush_done) &&
                 (dut.flush_exact_seen_q || dut.exact_flush_done)))) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"join-boundary fixture missed child confirmations");
            end
            if(USE_ABORT ? abort_done : flush_done)
                $fatal(1,"join-boundary stimulus arrived after parent completion");
            flush_req=1;
            @(negedge clk);flush_req=0;
            guard=0;
            while(flush_count<baseline+1) begin
                if((USE_ABORT ? abort_done : flush_done) && (busy || !quiescent))
                    $fatal(1,"parent completed while newly forwarded maintenance was still busy");
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"join-boundary maintenance lost completion");
            end
            repeat(12) @(negedge clk);
            if(flush_count!=baseline+1 || busy || !quiescent)
                $fatal(1,"join-boundary pending requests failed coalesced drain");
            $display("C1_EXACT_SHELL_JOIN_OVERLAP_PASS abort=%0d pending_requests=2 completions=1",USE_ABORT);
        end
        $display("C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS responses=%0d refills=%0d words=%0d ar=%0d beats=%0d flush=%0d epoch=%0d cancel_req=%0d cancel_source=%0d cancel_drain=%0d cancel_synthetic=%0d cancel_unified=%0d cycles=%0d",
                 response_count, perf_refill_count, perf_refill_word_count,
                 ar_count, beat_count, flush_count, current_epoch,
                 cancel_req_observed, cancel_source_observed,
                 cancel_drain_observed, cancel_synthetic_observed,
                 cancel_unified_observed, cycle_count);
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "timeout");
    end
endmodule
