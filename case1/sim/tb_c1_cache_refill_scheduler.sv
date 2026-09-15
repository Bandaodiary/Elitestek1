`timescale 1ns/1ps

// Compact protocol test for c1_cache_refill_scheduler.
//
// The leaf model is an in-order, delayed logical read endpoint.  The test
// intentionally fences a row while two requests are outstanding, verifies
// that old responses are drained but never leak, then submits a new-epoch row
// and checks address/index/last sidebands.  A held-high flush is also checked
// for one-shot epoch advancement.  This test does not instantiate an AXI
// fabric and is small enough for boardless xsim runs.
module tb_c1_cache_refill_scheduler #(
    parameter integer MAX_OUT = 2,
    parameter bit REQ_HANDOFF = 1'b0
);
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer LEAF_Q_DEPTH = 8;
    localparam integer RESPONSE_DELAY = 10;
    localparam integer MAX_CYCLES = 4000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid, cmd_ready;
    logic [ADDR_W-1:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;
    logic abort_req, abort_done, flush_req, flush_done;
    logic [EPOCH_W-1:0] current_epoch;
    logic leaf_req_valid, leaf_req_ready;
    logic [ADDR_W-1:0] leaf_req_addr;
    logic [EPOCH_W-1:0] leaf_req_epoch;
    logic leaf_req_flush;
    logic [7:0] leaf_req_occupancy;
    logic leaf_quiescent;
    logic leaf_rsp_valid, leaf_rsp_ready;
    logic [DATA_W-1:0] leaf_rsp_data;
    logic leaf_rsp_error;
    logic word_valid, word_ready;
    logic [DATA_W-1:0] word_data;
    logic word_error, word_last;
    logic [15:0] word_row, word_index;
    logic [EPOCH_W-1:0] word_epoch;
    logic cmd_done, cmd_done_error;
    logic [15:0] cmd_done_row;
    logic [EPOCH_W-1:0] cmd_done_epoch;
    logic busy, quiescent, drain_pending;
    logic [7:0] outstanding, max_outstanding_seen, cmd_occupancy;
    logic [63:0] perf_cmd_accept_count, perf_req_count, perf_rsp_count;
    logic [63:0] perf_word_count, perf_stale_drop_count;
    logic [63:0] perf_orphan_rsp_count, perf_error_count;

    c1_cache_refill_scheduler #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_DEPTH), .MAX_OUTSTANDING(MAX_OUT),
        .ALLOW_REQ_HANDOFF(REQ_HANDOFF)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_base_addr, .cmd_stride_bytes,
        .cmd_row, .cmd_word_count, .cmd_epoch,
        .abort_req, .abort_done, .flush_req, .flush_done, .current_epoch,
        .leaf_req_valid, .leaf_req_ready, .leaf_req_addr, .leaf_req_epoch,
        .leaf_req_flush, .leaf_req_occupancy, .leaf_quiescent,
        .leaf_rsp_valid, .leaf_rsp_ready, .leaf_rsp_data, .leaf_rsp_error,
        .word_valid, .word_ready, .word_data, .word_error, .word_last,
        .word_row, .word_index, .word_epoch,
        .drain_word_ready(1'b1),
        .cmd_done, .cmd_done_error, .cmd_done_row, .cmd_done_epoch,
        .busy, .quiescent, .drain_pending, .outstanding,
        .max_outstanding_seen, .cmd_occupancy,
        .perf_cmd_accept_count, .perf_req_count, .perf_rsp_count,
        .perf_word_count, .perf_stale_drop_count, .perf_orphan_rsp_count,
        .perf_error_count
    );

    // ------------------------------------------------------------------
    // Delayed in-order leaf model.
    // ------------------------------------------------------------------
    logic [ADDR_W-1:0] leaf_addr_mem [0:LEAF_Q_DEPTH-1];
    logic [EPOCH_W-1:0] leaf_epoch_mem [0:LEAF_Q_DEPTH-1];
    integer leaf_delay_mem [0:LEAF_Q_DEPTH-1];
    integer leaf_head, leaf_tail, leaf_count;
    integer cycle_count;
    integer leaf_req_count_tb, leaf_rsp_count_tb;
    logic hold_leaf_ready;
    logic orphan_request;
    logic orphan_active_q;
    wire leaf_req_fire = leaf_req_valid && leaf_req_ready;
    wire leaf_rsp_fire = leaf_rsp_valid && leaf_rsp_ready;

    always_comb begin
        leaf_req_ready = !hold_leaf_ready && (leaf_count < LEAF_Q_DEPTH) &&
                         ((cycle_count % 3) != 1);
        leaf_req_occupancy = leaf_count;
        // The model reports quiescent only after all queued responses have
        // been consumed.  This mirrors the burst client's perf_busy fence.
        leaf_quiescent = (leaf_count == 0) && !orphan_active_q;
        if (leaf_count != 0) begin
            leaf_rsp_valid = (leaf_delay_mem[leaf_head] <= 0);
            leaf_rsp_data = 64'hD000_0000_0000_0000 |
                            {32'd0, leaf_addr_mem[leaf_head]};
        end else begin
            leaf_rsp_valid = orphan_active_q;
            leaf_rsp_data = 64'h0BAD_0000_0000_0001;
        end
        leaf_rsp_error = 1'b0;
        word_ready = ((cycle_count % 4) != 2);
    end

    integer leaf_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            leaf_head <= 0;
            leaf_tail <= 0;
            leaf_count <= 0;
            cycle_count <= 0;
            leaf_req_count_tb <= 0;
            leaf_rsp_count_tb <= 0;
            orphan_active_q <= 1'b0;
            for (leaf_i = 0; leaf_i < LEAF_Q_DEPTH; leaf_i = leaf_i + 1)
                leaf_delay_mem[leaf_i] <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            for (leaf_i = 0; leaf_i < LEAF_Q_DEPTH; leaf_i = leaf_i + 1)
                if (leaf_delay_mem[leaf_i] > 0)
                    leaf_delay_mem[leaf_i] <= leaf_delay_mem[leaf_i] - 1;

            if (leaf_req_fire) begin
                if (leaf_count >= LEAF_Q_DEPTH)
                    $fatal(1, "leaf model queue overflow");
                leaf_addr_mem[leaf_tail] <= leaf_req_addr;
                leaf_epoch_mem[leaf_tail] <= leaf_req_epoch;
                leaf_delay_mem[leaf_tail] <= RESPONSE_DELAY;
                leaf_tail <= (leaf_tail + 1) % LEAF_Q_DEPTH;
                leaf_req_count_tb <= leaf_req_count_tb + 1;
            end
            if (leaf_rsp_fire) begin
                if (leaf_count != 0)
                    leaf_head <= (leaf_head + 1) % LEAF_Q_DEPTH;
                if (orphan_active_q && (leaf_count == 0))
                    orphan_active_q <= 1'b0;
                leaf_rsp_count_tb <= leaf_rsp_count_tb + 1;
            end
            if (orphan_request)
                orphan_active_q <= 1'b1;
            case ({leaf_req_fire, leaf_rsp_fire})
                2'b10: leaf_count <= leaf_count + 1;
                2'b01: leaf_count <= leaf_count - 1;
                default: leaf_count <= leaf_count;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Scoreboard and stimulus.
    // ------------------------------------------------------------------
    integer old_word_count, new_word_count, new_done_count;
    integer stale_seen_at_fence;
    integer timeout_count;
    integer abort_done_count;
    integer flush_done_count;
    integer reject_done_count;
    logic saw_flush_pulse;
    logic saw_pending_stall;
    integer handoff_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            old_word_count <= 0;
            new_word_count <= 0;
            new_done_count <= 0;
            stale_seen_at_fence <= 0;
            abort_done_count <= 0;
            flush_done_count <= 0;
            reject_done_count <= 0;
            saw_flush_pulse <= 1'b0;
            saw_pending_stall <= 1'b0;
            handoff_count <= 0;
        end else begin
            if (dut.launch_event && leaf_req_fire)
                handoff_count <= handoff_count + 1;
            if (leaf_req_valid && !leaf_req_ready)
                saw_pending_stall <= 1'b1;
            if (leaf_req_flush)
                saw_flush_pulse <= 1'b1;
            if (word_valid && word_ready) begin
                if (word_error)
                    $fatal(1, "unexpected word error");
                if (word_epoch == 0) begin
                    old_word_count <= old_word_count + 1;
                    // Old words are allowed before the fence, but never
                    // after current_epoch has advanced.
                    if (current_epoch != 0)
                        $fatal(1, "old epoch word leaked after fence");
                end else if (word_epoch == 1) begin
                    if (word_row != 9 || word_index != new_word_count ||
                        word_data[31:0] != (32'h0000_3000 +
                                            new_word_count * 32'd8))
                        $fatal(1, "new epoch word sideband/address mismatch");
                    if (word_last != (new_word_count == 2))
                        $fatal(1, "new epoch last mismatch");
                    new_word_count <= new_word_count + 1;
                end else begin
                    $fatal(1, "unexpected word epoch %0d", word_epoch);
                end
            end
            if (cmd_done && cmd_done_epoch == 1) begin
                if (cmd_done_error)
                    $fatal(1, "new epoch command completed with error");
                new_done_count <= new_done_count + 1;
            end
            if (abort_done)
                abort_done_count <= abort_done_count + 1;
            if (flush_done)
                flush_done_count <= flush_done_count + 1;
            if (cmd_done && cmd_done_error)
                reject_done_count <= reject_done_count + 1;
        end
    end

    task automatic send_command(
        input logic [31:0] base,
        input logic [31:0] stride,
        input logic [15:0] row,
        input logic [15:0] words,
        input logic [EPOCH_W-1:0] ep
    );
        begin
            @(negedge clk);
            cmd_base_addr = base;
            cmd_stride_bytes = stride;
            cmd_row = row;
            cmd_word_count = words;
            cmd_epoch = ep;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task automatic pulse_flush;
        begin
            @(negedge clk);
            flush_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            flush_req = 1'b0;
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort_req = 1'b0;
        end
    endtask

    initial begin
        cmd_valid = 1'b0;
        cmd_base_addr = 0;
        cmd_stride_bytes = 0;
        cmd_row = 0;
        cmd_word_count = 0;
        cmd_epoch = 0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        hold_leaf_ready = 1'b0;
        orphan_request = 1'b0;
        timeout_count = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // First row: two requests are accepted and held in the leaf model;
        // queue a second row to exercise command FIFO cancellation.
        send_command(32'h0000_1000, 32'd8, 16'd4, 16'd6, 3'd0);
        send_command(32'h0000_2000, 32'd8, 16'd5, 16'd2, 3'd0);
        // Force a deterministic stalled pending request.  The abort edge is
        // asserted while VALID is held and READY is low; the DUT must retain
        // the exact payload until READY is released after the fence.
        hold_leaf_ready = 1'b1;
        while (!leaf_req_valid) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 200)
                $fatal(1, "scheduler did not present a pending request");
        end
        repeat (3) @(posedge clk);
        // A held request must have experienced at least one leaf stall.
        if (!saw_pending_stall)
            $fatal(1, "test did not exercise stalled leaf request hold");
        pulse_abort();
        // Keep READY low over the maintenance edge, then release the held
        // request so it can be safely drained as stale traffic.
        repeat (2) @(posedge clk);
        hold_leaf_ready = 1'b0;

        timeout_count = 0;
        while (!abort_done) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 1000)
                $fatal(1, "abort drain timeout outstanding=%0d leaf=%0d",
                       outstanding, leaf_count);
        end
        if (current_epoch != 1)
            $fatal(1, "abort did not advance epoch exactly once: %0d",
                   current_epoch);
        if (perf_stale_drop_count == 0)
            $fatal(1, "abort did not count stale response drops");
        if (!saw_flush_pulse)
            $fatal(1, "scheduler did not emit leaf close pulse");
        if (new_word_count != 0)
            $fatal(1, "new epoch words appeared before command");

        // New epoch row; all three words must arrive in order.
        send_command(32'h0000_3000, 32'd8, 16'd9, 16'd3, 3'd1);
        timeout_count = 0;
        while ((new_word_count != 3) || (new_done_count != 1)) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 1500)
                $fatal(1, "new epoch command timeout words=%0d done=%0d",
                       new_word_count, new_done_count);
        end
        if (max_outstanding_seen != MAX_OUT)
            $fatal(1, "credit maximum mismatch: %0d", max_outstanding_seen);

        // Flush with no in-flight work exercises the second maintenance
        // channel and the one-shot behavior while the request is held high.
        // Keep the level asserted until completion; dropping and reasserting
        // between the event and done pulse would intentionally be a new edge.
        @(negedge clk);
        flush_req = 1'b1;
        timeout_count = 0;
        while (!flush_done) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 1000)
                $fatal(1, "flush completion timeout");
        end
        // Allow the scoreboard's nonblocking counter update to settle before
        // checking the pulse count.
        @(negedge clk);
        if (flush_done_count != 1 || current_epoch != 2)
            $fatal(1, "flush completion/epoch mismatch done=%0d epoch=%0d",
                   flush_done_count, current_epoch);
        repeat (5) @(posedge clk);
        if (flush_done_count != 1 || current_epoch != 2)
            $fatal(1, "held flush repeated unexpectedly");
        flush_req = 1'b0;

        // Inject one response without metadata.  The scheduler must consume
        // it, count an orphan protocol error, and remain live.
        orphan_request = 1'b1;
        @(posedge clk);
        orphan_request = 1'b0;
        timeout_count = 0;
        while (perf_orphan_rsp_count == 0) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > 100)
                $fatal(1, "orphan response was not drained");
        end

        if (REQ_HANDOFF && MAX_OUT > 1 && handoff_count == 0)
            $fatal(1, "enabled handoff was not exercised");
        if ((!REQ_HANDOFF || MAX_OUT == 1) && handoff_count != 0)
            $fatal(1, "handoff occurred without a spare credit or enable");
        $display("C1_REFILL_HANDOFF_COVERAGE enabled=%0d window=%0d handoffs=%0d", REQ_HANDOFF, MAX_OUT, handoff_count);
        $display("C1_CACHE_REFILL_SCHEDULER_PASS cmd_accept=%0d req=%0d rsp=%0d words=%0d stale_drop=%0d orphan=%0d max_outstanding=%0d epoch=%0d abort_done=%0d flush_done=%0d flush_pulse=%0d cycles=%0d",
                 perf_cmd_accept_count, perf_req_count, perf_rsp_count,
                 perf_word_count, perf_stale_drop_count,
                 perf_orphan_rsp_count, max_outstanding_seen,
                 current_epoch, abort_done_count, flush_done_count,
                 saw_flush_pulse, cycle_count);
        $finish;
    end
endmodule
