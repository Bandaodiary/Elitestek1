`timescale 1ns/1ps

// Drain-stream regression for c1_cache_refill_scheduler.
//
// EMIT_DRAIN_WORDS=1 turns canceled/stale metadata into a separate
// ready/valid stream.  This test fences a row while two requests are in the
// leaf, deliberately stalls the first drain word, and checks that every
// accepted response is drained in order with error=1.  It does not claim that
// unissued words are synthesized after a cancellation; a refill consumer that
// requires the full declared row still needs a cancellation-token adapter.
module tb_c1_cache_refill_scheduler_drain;
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer MAX_OUT = 2;
    localparam integer LEAF_DEPTH = 4;
    localparam integer RESPONSE_DELAY = 8;
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
    logic drain_word_valid, drain_word_ready;
    logic [DATA_W-1:0] drain_word_data;
    logic drain_word_error, drain_word_last;
    logic [15:0] drain_word_row, drain_word_index;
    logic [EPOCH_W-1:0] drain_word_epoch;
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
        .EMIT_DRAIN_WORDS(1)
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
        .drain_word_valid, .drain_word_ready, .drain_word_data,
        .drain_word_error, .drain_word_last, .drain_word_row,
        .drain_word_index, .drain_word_epoch,
        .cmd_done, .cmd_done_error, .cmd_done_row, .cmd_done_epoch,
        .busy, .quiescent, .drain_pending, .outstanding,
        .max_outstanding_seen, .cmd_occupancy,
        .perf_cmd_accept_count, .perf_req_count, .perf_rsp_count,
        .perf_word_count, .perf_stale_drop_count, .perf_orphan_rsp_count,
        .perf_error_count
    );

    // ------------------------------------------------------------------
    // Delayed in-order leaf response queue.
    // ------------------------------------------------------------------
    logic [ADDR_W-1:0] addr_mem [0:LEAF_DEPTH-1];
    logic [EPOCH_W-1:0] epoch_mem [0:LEAF_DEPTH-1];
    integer delay_mem [0:LEAF_DEPTH-1];
    integer head_q, tail_q, count_q;
    logic rsp_valid_q;
    integer cycle_count, req_count_tb, rsp_count_tb, drain_count_tb;
    integer flush_pulse_count, timeout_count;
    logic drain_ready_ctl;
    logic saw_drain_stall;
    logic ever_drain_stall;
    logic [DATA_W-1:0] stalled_drain_data;
    logic [15:0] stalled_drain_row, stalled_drain_index;
    logic [EPOCH_W-1:0] stalled_drain_epoch;

    assign leaf_req_ready = (count_q < LEAF_DEPTH);
    // Model the leaf's request/response queue occupancy.  Keeping this
    // nonzero until the response retires also exercises scheduler close-pulse
    // ordering (req_flush must not precede leaf quiescence).
    assign leaf_req_occupancy = count_q;
    assign leaf_quiescent = (count_q == 0) && !rsp_valid_q;
    assign leaf_rsp_valid = rsp_valid_q;
    assign leaf_rsp_data = rsp_valid_q ?
                           (64'hD0A1_0000_0000_0000 |
                            {32'd0, addr_mem[head_q]}) : '0;
    // Mark the second accepted response with a leaf-side error.  The drain
    // stream must retain the cancellation indication and still account for
    // the underlying leaf error in the scheduler diagnostics.
    assign leaf_rsp_error = rsp_valid_q && (addr_mem[head_q][3:0] == 4'h8);
    assign word_ready = 1'b1;
    assign drain_word_ready = drain_ready_ctl;

    wire leaf_req_fire = leaf_req_valid && leaf_req_ready;
    wire leaf_rsp_fire = leaf_rsp_valid && leaf_rsp_ready;
    wire drain_word_fire = drain_word_valid && drain_word_ready;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= 0;
            tail_q <= 0;
            count_q <= 0;
            rsp_valid_q <= 1'b0;
            cycle_count <= 0;
            req_count_tb <= 0;
            rsp_count_tb <= 0;
            drain_count_tb <= 0;
            flush_pulse_count <= 0;
            for (i = 0; i < LEAF_DEPTH; i = i + 1)
                delay_mem[i] <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            for (i = 0; i < LEAF_DEPTH; i = i + 1)
                if (delay_mem[i] > 0)
                    delay_mem[i] <= delay_mem[i] - 1;

            if (leaf_req_fire) begin
                if (count_q >= LEAF_DEPTH)
                    $fatal(1, "drain BFM queue overflow");
                addr_mem[tail_q] <= leaf_req_addr;
                epoch_mem[tail_q] <= leaf_req_epoch;
                delay_mem[tail_q] <= RESPONSE_DELAY;
                tail_q <= (tail_q + 1) % LEAF_DEPTH;
                req_count_tb <= req_count_tb + 1;
            end
            if (!rsp_valid_q && (count_q != 0) &&
                (delay_mem[head_q] <= 0))
                rsp_valid_q <= 1'b1;
            if (leaf_rsp_fire) begin
                rsp_valid_q <= 1'b0;
                head_q <= (head_q + 1) % LEAF_DEPTH;
                rsp_count_tb <= rsp_count_tb + 1;
            end
            case ({leaf_req_fire, leaf_rsp_fire})
                2'b10: count_q <= count_q + 1;
                2'b01: count_q <= count_q - 1;
                default: count_q <= count_q;
            endcase
            if (leaf_req_flush)
                flush_pulse_count <= flush_pulse_count + 1;
            if (drain_word_fire)
                drain_count_tb <= drain_count_tb + 1;
        end
    end

    // Drain payload must obey the same hold contract as the normal word
    // stream.  Also check that canceled words never leak to word_valid.
    always_ff @(posedge clk) begin
        if (rst) begin
            saw_drain_stall <= 1'b0;
            ever_drain_stall <= 1'b0;
            stalled_drain_data <= '0;
            stalled_drain_row <= '0;
            stalled_drain_index <= '0;
            stalled_drain_epoch <= '0;
        end else begin
            if (word_valid && drain_word_valid)
                $fatal(1, "normal/drain streams overlapped");
            if (word_valid)
                $fatal(1, "stale response leaked onto normal word stream");
            if (drain_word_valid && !drain_word_ready) begin
                if (!saw_drain_stall) begin
                    saw_drain_stall <= 1'b1;
                    ever_drain_stall <= 1'b1;
                    stalled_drain_data <= drain_word_data;
                    stalled_drain_row <= drain_word_row;
                    stalled_drain_index <= drain_word_index;
                    stalled_drain_epoch <= drain_word_epoch;
                end else if (drain_word_data != stalled_drain_data ||
                             drain_word_row != stalled_drain_row ||
                             drain_word_index != stalled_drain_index ||
                             drain_word_epoch != stalled_drain_epoch ||
                             !drain_word_error) begin
                    $fatal(1, "stalled drain payload changed");
                end
            end
            if (drain_word_fire)
                saw_drain_stall <= 1'b0;
            if (drain_word_fire) begin
                if (!drain_word_error || drain_word_epoch != 3'd0 ||
                    drain_word_row != 16'd7 ||
                    drain_word_index != drain_count_tb)
                    $fatal(1, "drain sideband mismatch row=%0d idx=%0d ep=%0d",
                           drain_word_row, drain_word_index, drain_word_epoch);
                if (drain_word_data[31:0] !=
                    (32'h0000_4100 + drain_count_tb * 8) ||
                    drain_word_last)
                    $fatal(1, "drain payload/last mismatch data=%h last=%0d",
                           drain_word_data, drain_word_last);
            end
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

    initial begin
        cmd_valid = 1'b0;
        cmd_base_addr = '0;
        cmd_stride_bytes = '0;
        cmd_row = '0;
        cmd_word_count = '0;
        cmd_epoch = '0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        drain_ready_ctl = 1'b0;
        timeout_count = 0;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        // Four declared words, but fence after the first two accepted
        // requests.  The delayed leaf ensures both become stale metadata.
        send_command(32'h0000_4100, 32'd8, 16'd7, 16'd4, 3'd0);
        timeout_count = 0;
        while (req_count_tb < MAX_OUT) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "did not reach two accepted requests");
        end

        @(negedge clk);
        flush_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;

        // Wait for the first stale response to be presented, then hold the
        // drain sink closed for several cycles to exercise payload stability.
        timeout_count = 0;
        while (!drain_word_valid) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "drain word did not arrive");
        end
        repeat (3) @(posedge clk);
        if (!drain_word_valid || drain_word_ready)
            $fatal(1, "drain word was not held while sink stalled");
        @(negedge clk);
        drain_ready_ctl = 1'b1;

        timeout_count = 0;
        while (!flush_done) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "drain fence completion timeout meta=%0d leaf=%0d",
                       outstanding, count_q);
        end
        @(negedge clk);
            if (req_count_tb != MAX_OUT || rsp_count_tb != MAX_OUT ||
                drain_count_tb != MAX_OUT || perf_word_count != 0 ||
                perf_stale_drop_count != MAX_OUT || current_epoch != 3'd1 ||
                flush_pulse_count == 0 || !ever_drain_stall ||
                perf_error_count == 0)
                $fatal(1, "drain result mismatch req=%0d rsp=%0d drain=%0d words=%0d stale=%0d ep=%0d flush=%0d stalled=%0d",
                   req_count_tb, rsp_count_tb, drain_count_tb,
                   perf_word_count, perf_stale_drop_count, current_epoch,
                   flush_pulse_count, ever_drain_stall);

        $display("C1_CACHE_REFILL_SCHEDULER_DRAIN_PASS req=%0d rsp=%0d drain=%0d stale=%0d max_outstanding=%0d epoch=%0d flush=%0d cycles=%0d",
                 req_count_tb, rsp_count_tb, drain_count_tb,
                 perf_stale_drop_count, max_outstanding_seen,
                 current_epoch, flush_pulse_count, cycle_count);
        $finish;
    end
endmodule
