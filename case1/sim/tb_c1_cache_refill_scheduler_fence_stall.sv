`timescale 1ns/1ps

// Directed maintenance-fence regression for c1_cache_refill_scheduler.
//
// This test is deliberately smaller than the scheduler/AXI integration gate:
// the leaf is a one-entry, in-order endpoint and the test focuses on the
// ready/valid contract at an epoch fence.  Two cases are covered:
//   1. a current word is stalled while flush_req rises; the payload must stay
//      presented until word_ready, then the fence must complete;
//   2. flush_req rises in the same cycle that a current word is accepted
//      (word_valid && word_ready); the edge must not be lost.
//
// The second case is useful when changing deferred-fence logic: edge
// qualification must remember an event even when no stall is present.
module tb_c1_cache_refill_scheduler_fence_stall;
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer MAX_OUT = 1;
    localparam integer MAX_CYCLES = 3000;

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
        .CMD_FIFO_DEPTH(CMD_DEPTH), .MAX_OUTSTANDING(MAX_OUT)
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
    // One-entry logical leaf.  A request becomes a response one cycle later
    // and remains VALID until the scheduler accepts it.
    // ------------------------------------------------------------------
    logic rsp_valid_q;
    logic [DATA_W-1:0] rsp_data_q;
    logic rsp_pending_q;
    logic [DATA_W-1:0] pending_data_q;
    integer cycle_count;
    integer req_count_tb, rsp_count_tb, word_count_tb;
    integer flush_done_count;
    integer timeout_count;
    logic word_ready_ctl;

    assign leaf_req_ready = 1'b1;
    assign leaf_req_occupancy = 8'd0;
    assign leaf_quiescent = !rsp_valid_q && !rsp_pending_q;
    assign leaf_rsp_valid = rsp_valid_q;
    assign leaf_rsp_data = rsp_data_q;
    assign leaf_rsp_error = 1'b0;
    assign word_ready = word_ready_ctl;

    wire leaf_req_fire = leaf_req_valid && leaf_req_ready;
    wire leaf_rsp_fire = leaf_rsp_valid && leaf_rsp_ready;
    wire word_fire = word_valid && word_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_pending_q <= 1'b0;
            rsp_data_q <= '0;
            pending_data_q <= '0;
            cycle_count <= 0;
            req_count_tb <= 0;
            rsp_count_tb <= 0;
            word_count_tb <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (leaf_req_fire) begin
                if (rsp_valid_q || rsp_pending_q)
                    $fatal(1, "one-entry leaf received request while occupied");
                pending_data_q <= 64'hCAFE_0000_0000_0000 |
                                  {32'd0, leaf_req_addr};
                rsp_pending_q <= 1'b1;
                req_count_tb <= req_count_tb + 1;
            end
            // Move a request into the response register one cycle after
            // acceptance.  The nonblocking assignments intentionally make
            // this visible to the scheduler on the following cycle.
            if (rsp_pending_q) begin
                rsp_pending_q <= 1'b0;
                rsp_valid_q <= 1'b1;
                rsp_data_q <= pending_data_q;
            end
            if (leaf_rsp_fire) begin
                rsp_valid_q <= 1'b0;
                rsp_count_tb <= rsp_count_tb + 1;
            end
            if (word_fire)
                word_count_tb <= word_count_tb + 1;
        end
    end

    // Catch a withdrawal or payload change while the response word is
    // stalled.  This is intentionally an immediate assertion in the TB so
    // it remains useful even when RTL simulation assertions are disabled.
    logic stalled_seen;
    logic [DATA_W-1:0] stalled_data;
    logic [15:0] stalled_row, stalled_index;
    logic [EPOCH_W-1:0] stalled_epoch;
    always_ff @(posedge clk) begin
        if (rst) begin
            stalled_seen <= 1'b0;
            stalled_data <= '0;
            stalled_row <= '0;
            stalled_index <= '0;
            stalled_epoch <= '0;
            flush_done_count <= 0;
        end else begin
            if (flush_done)
                flush_done_count <= flush_done_count + 1;
            if (word_valid && !word_ready) begin
                if (!stalled_seen) begin
                    stalled_seen <= 1'b1;
                    stalled_data <= word_data;
                    stalled_row <= word_row;
                    stalled_index <= word_index;
                    stalled_epoch <= word_epoch;
                end else if (!word_valid || word_data != stalled_data ||
                             word_row != stalled_row ||
                             word_index != stalled_index ||
                             word_epoch != stalled_epoch) begin
                    $fatal(1, "stalled word payload changed across flush edge");
                end
            end
            if (stalled_seen && !word_ready && !word_valid)
                $fatal(1, "stalled word VALID withdrawn before ready");
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

    task automatic wait_flush_done;
        begin
            timeout_count = 0;
            while (!flush_done) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
                if (timeout_count > 500)
                    $fatal(1, "fence completion timeout epoch=%0d busy=%0d rsp=%0d",
                           current_epoch, busy, leaf_rsp_valid);
            end
            // Let NBA scoreboard updates settle before checking pulse count.
            @(negedge clk);
        end
    endtask

    initial begin
        cmd_valid = 1'b0;
        cmd_base_addr = '0;
        cmd_stride_bytes = '0;
        cmd_row = '0;
        cmd_word_count = '0;
        cmd_epoch = '0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        word_ready_ctl = 1'b1;
        timeout_count = 0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Case 1: hold a presented response, then request a flush.  The
        // current word is allowed to retire, after which epoch 1 is fenced.
        send_command(32'h0000_1100, 32'd8, 16'd3, 16'd1, 3'd0);
        while (!leaf_req_fire)
            @(posedge clk);
        @(negedge clk);
        word_ready_ctl = 1'b0;
        while (!word_valid) begin
            @(posedge clk);
            if (cycle_count > MAX_CYCLES)
                $fatal(1, "case1 response did not arrive");
        end
        @(negedge clk);
        if (!word_valid)
            $fatal(1, "case1 word disappeared before flush");
        flush_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        repeat (3) @(posedge clk);
        if (!word_valid || word_ready)
            $fatal(1, "case1 stalled word was not held");
        word_ready_ctl = 1'b1;
        wait_flush_done();
        if (current_epoch != 3'd1 || flush_done_count != 1 ||
            word_count_tb != 1)
            $fatal(1, "case1 fence mismatch epoch=%0d done=%0d words=%0d",
                   current_epoch, flush_done_count, word_count_tb);

        // Re-arm edge detector before the second case.
        repeat (3) @(posedge clk);

        // Case 2: align a flush edge with an accepting word
        // (word_valid && word_ready).  This must still launch a fence.
        send_command(32'h0000_2200, 32'd8, 16'd4, 16'd1, 3'd1);
        word_ready_ctl = 1'b1;
        // Sample at negedges: if we waited for a posedge, the ready word
        // could already have retired at that same edge.  At a negedge the
        // candidate is known to be ready for the *next* posedge.
        while (!(word_valid && word_ready)) begin
            @(negedge clk);
            if (cycle_count > MAX_CYCLES)
                $fatal(1, "case2 response did not arrive");
        end
        // Raising flush_req here makes the edge and rsp handshake same-cycle
        // at the scheduler.
        if (!(word_valid && word_ready))
            $fatal(1, "case2 lost candidate before aligned edge");
        flush_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        // Keep the level high through completion to check one-shot behavior.
        wait_flush_done();
        if (current_epoch != 3'd2 || flush_done_count != 2 ||
            word_count_tb != 2)
            $fatal(1, "case2 same-cycle edge lost epoch=%0d done=%0d words=%0d",
                   current_epoch, flush_done_count, word_count_tb);
        repeat (4) @(posedge clk);
        if (flush_done_count != 2 || current_epoch != 3'd2)
            $fatal(1, "case2 held flush repeated epoch=%0d done=%0d",
                   current_epoch, flush_done_count);
        flush_req = 1'b0;

        $display("C1_CACHE_REFILL_SCHEDULER_FENCE_STALL_PASS req=%0d rsp=%0d words=%0d flush_done=%0d epoch=%0d cycles=%0d",
                 req_count_tb, rsp_count_tb, word_count_tb,
                 flush_done_count, current_epoch, cycle_count);
        $finish;
    end
endmodule
