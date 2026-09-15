`timescale 1ns/1ps

// Normal-path and command-reject regression for the exact-count completion
// adapter.  The cancellation TB exercises a partially issued row; this TB
// complements it with a clean three-word row, a zero-length reject, and an
// epoch-mismatch reject whose declared words must be synthesized as poison.
module tb_c1_cache_refill_completion_adapter_normal;
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer MAX_OUT = 2;
    localparam integer LEAF_DEPTH = 4;
    localparam integer MAX_CYCLES = 3000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid, cmd_ready;
    logic [ADDR_W-1:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;

    logic sched_cmd_valid, sched_cmd_ready;
    logic [ADDR_W-1:0] sched_cmd_base_addr, sched_cmd_stride_bytes;
    logic [15:0] sched_cmd_row, sched_cmd_word_count;
    logic [EPOCH_W-1:0] sched_cmd_epoch;
    logic sched_cmd_done, sched_cmd_done_error;
    logic [15:0] sched_cmd_done_row;
    logic [EPOCH_W-1:0] sched_cmd_done_epoch;
    logic sched_abort_done, sched_flush_done;
    logic flush_req;
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

    logic word_valid, scheduler_word_ready;
    logic [DATA_W-1:0] word_data;
    logic word_error, word_last;
    logic [15:0] word_row, word_index;
    logic [EPOCH_W-1:0] word_epoch;
    logic drain_word_valid, scheduler_drain_ready;
    logic [DATA_W-1:0] drain_word_data;
    logic drain_word_error, drain_word_last;
    logic [15:0] drain_word_row, drain_word_index;
    logic [EPOCH_W-1:0] drain_word_epoch;
    logic scheduler_busy, scheduler_quiescent, scheduler_drain_pending;
    logic [7:0] scheduler_outstanding, scheduler_max_outstanding;
    logic [7:0] scheduler_cmd_occupancy;
    logic [63:0] perf_cmd_accept_count, perf_req_count, perf_rsp_count;
    logic [63:0] perf_word_count, perf_stale_drop_count;
    logic [63:0] perf_orphan_rsp_count, perf_error_count;

    logic refill_word_valid, refill_word_ready;
    logic [DATA_W-1:0] refill_word_data;
    logic refill_word_error, refill_word_last;
    logic [15:0] refill_word_row, refill_word_index;
    logic [EPOCH_W-1:0] refill_word_epoch;
    logic refill_done, refill_done_error, adapter_protocol_error;
    logic adapter_active, synthetic_active;
    logic [15:0] emitted_count;

    c1_cache_refill_scheduler #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_DEPTH), .MAX_OUTSTANDING(MAX_OUT),
        .EMIT_DRAIN_WORDS(1)
    ) u_scheduler (
        .clk, .rst,
        .cmd_valid(sched_cmd_valid), .cmd_ready(sched_cmd_ready),
        .cmd_base_addr(sched_cmd_base_addr),
        .cmd_stride_bytes(sched_cmd_stride_bytes),
        .cmd_row(sched_cmd_row), .cmd_word_count(sched_cmd_word_count),
        .cmd_epoch(sched_cmd_epoch),
        .abort_req(1'b0), .abort_done(sched_abort_done),
        .flush_req, .flush_done(sched_flush_done), .current_epoch,
        .leaf_req_valid, .leaf_req_ready, .leaf_req_addr, .leaf_req_epoch,
        .leaf_req_flush, .leaf_req_occupancy, .leaf_quiescent,
        .leaf_rsp_valid, .leaf_rsp_ready, .leaf_rsp_data, .leaf_rsp_error,
        .word_valid, .word_ready(scheduler_word_ready), .word_data, .word_error, .word_last,
        .word_row, .word_index, .word_epoch,
        .drain_word_valid, .drain_word_ready(scheduler_drain_ready),
        .drain_word_data, .drain_word_error, .drain_word_last,
        .drain_word_row, .drain_word_index, .drain_word_epoch,
        .cmd_done(sched_cmd_done), .cmd_done_error(sched_cmd_done_error),
        .cmd_done_row(sched_cmd_done_row), .cmd_done_epoch(sched_cmd_done_epoch),
        .busy(scheduler_busy), .quiescent(scheduler_quiescent),
        .drain_pending(scheduler_drain_pending),
        .outstanding(scheduler_outstanding),
        .max_outstanding_seen(scheduler_max_outstanding),
        .cmd_occupancy(scheduler_cmd_occupancy),
        .perf_cmd_accept_count, .perf_req_count, .perf_rsp_count,
        .perf_word_count, .perf_stale_drop_count,
        .perf_orphan_rsp_count, .perf_error_count
    );

    c1_cache_refill_completion_adapter #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W)
    ) u_adapter (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_base_addr, .cmd_stride_bytes,
        .cmd_row, .cmd_word_count, .cmd_epoch,
        .sched_cmd_valid, .sched_cmd_ready,
        .sched_cmd_base_addr, .sched_cmd_stride_bytes,
        .sched_cmd_row, .sched_cmd_word_count, .sched_cmd_epoch,
        .sched_cmd_done, .sched_cmd_done_error, .sched_cmd_done_row,
        .sched_cmd_done_epoch, .sched_abort_done, .sched_flush_done,
        .sched_word_valid(word_valid), .sched_word_ready(scheduler_word_ready),
        .sched_word_data(word_data), .sched_word_error(word_error),
        .sched_word_last(word_last), .sched_word_row(word_row),
        .sched_word_index(word_index), .sched_word_epoch(word_epoch),
        .sched_drain_valid(drain_word_valid), .sched_drain_ready(scheduler_drain_ready),
        .sched_drain_data(drain_word_data), .sched_drain_error(drain_word_error),
        .sched_drain_last(drain_word_last), .sched_drain_row(drain_word_row),
        .sched_drain_index(drain_word_index), .sched_drain_epoch(drain_word_epoch),
        .refill_word_valid, .refill_word_ready, .refill_word_data,
        .refill_word_error, .refill_word_last, .refill_word_row,
        .refill_word_index, .refill_word_epoch,
        .refill_done, .refill_done_error,
        .protocol_error(adapter_protocol_error), .active(adapter_active),
        .synthetic_active, .emitted_count
    );

    // Registered in-order leaf with a two-cycle response delay.  The delay
    // intentionally rules out same-cycle fall-through responses.
    logic [ADDR_W-1:0] addr_mem [0:LEAF_DEPTH-1];
    integer delay_mem [0:LEAF_DEPTH-1];
    integer leaf_head, leaf_tail, leaf_count;
    logic leaf_rsp_valid_q;
    integer cycle_count, req_count_tb, rsp_count_tb;

    assign leaf_req_ready = (leaf_count < LEAF_DEPTH);
    assign leaf_req_occupancy = leaf_count;
    assign leaf_quiescent = (leaf_count == 0) && !leaf_rsp_valid_q;
    assign leaf_rsp_valid = leaf_rsp_valid_q;
    assign leaf_rsp_data = leaf_rsp_valid_q ?
        (64'hDADA_0000_0000_0000 | {32'd0, addr_mem[leaf_head]}) : '0;
    assign leaf_rsp_error = 1'b0;
    assign refill_word_ready = ((cycle_count % 5) != 1);

    wire leaf_req_fire = leaf_req_valid && leaf_req_ready;
    wire leaf_rsp_fire = leaf_rsp_valid && leaf_rsp_ready;

    integer li;
    always_ff @(posedge clk) begin
        if (rst) begin
            leaf_head <= 0;
            leaf_tail <= 0;
            leaf_count <= 0;
            leaf_rsp_valid_q <= 1'b0;
            cycle_count <= 0;
            req_count_tb <= 0;
            rsp_count_tb <= 0;
            for (li = 0; li < LEAF_DEPTH; li = li + 1) begin
                addr_mem[li] <= '0;
                delay_mem[li] <= 0;
            end
        end else begin
            cycle_count <= cycle_count + 1;
            for (li = 0; li < LEAF_DEPTH; li = li + 1)
                if (delay_mem[li] > 0)
                    delay_mem[li] <= delay_mem[li] - 1;
            if (leaf_req_fire) begin
                addr_mem[leaf_tail] <= leaf_req_addr;
                delay_mem[leaf_tail] <= 2;
                leaf_tail <= (leaf_tail + 1) % LEAF_DEPTH;
                req_count_tb <= req_count_tb + 1;
            end
            if (!leaf_rsp_valid_q && (leaf_count != 0) &&
                (delay_mem[leaf_head] <= 0))
                leaf_rsp_valid_q <= 1'b1;
            if (leaf_rsp_fire) begin
                leaf_rsp_valid_q <= 1'b0;
                leaf_head <= (leaf_head + 1) % LEAF_DEPTH;
                rsp_count_tb <= rsp_count_tb + 1;
            end
            case ({leaf_req_fire, leaf_rsp_fire})
                2'b10: leaf_count <= leaf_count + 1;
                2'b01: leaf_count <= leaf_count - 1;
                default: leaf_count <= leaf_count;
            endcase
        end
    end

    integer normal_outputs, synthetic_outputs;
    integer row4_index, row5_index;
    integer done_count, normal_done_count, done_error_count, timeout_count;
    logic normal_done_seen, zero_done_seen, mismatch_done_seen;
    always_ff @(posedge clk) begin
        if (rst) begin
            normal_outputs <= 0;
            synthetic_outputs <= 0;
            row4_index <= 0;
            row5_index <= 0;
            done_count <= 0;
            normal_done_count <= 0;
            done_error_count <= 0;
            normal_done_seen <= 1'b0;
            zero_done_seen <= 1'b0;
            mismatch_done_seen <= 1'b0;
        end else begin
            if (refill_word_valid && refill_word_ready) begin
                if (refill_word_row == 16'd4) begin
                    if (refill_word_error || refill_word_epoch != 0 ||
                        refill_word_index != row4_index ||
                        refill_word_data[31:0] != (32'h0000_2200 + row4_index*8) ||
                        refill_word_last != (row4_index == 2))
                        $fatal(1, "normal output mismatch idx=%0d row=%0d ep=%0d err=%0d last=%0d data=%h",
                               refill_word_index, refill_word_row, refill_word_epoch,
                               refill_word_error, refill_word_last, refill_word_data);
                    normal_outputs <= normal_outputs + 1;
                    row4_index <= row4_index + 1;
                end else if (refill_word_row == 16'd5) begin
                    if (refill_word_error || refill_word_epoch != 0 ||
                        refill_word_index != row5_index ||
                        refill_word_data[31:0] != (32'h0000_2300 + row5_index*8) ||
                        refill_word_last != (row5_index == 1))
                        $fatal(1, "back-to-back normal mismatch idx=%0d row=%0d ep=%0d err=%0d last=%0d data=%h",
                               refill_word_index, refill_word_row, refill_word_epoch,
                               refill_word_error, refill_word_last, refill_word_data);
                    normal_outputs <= normal_outputs + 1;
                    row5_index <= row5_index + 1;
                end else if (refill_word_row == 16'd9) begin
                    if (!refill_word_error || refill_word_index != synthetic_outputs ||
                        refill_word_data != 0 ||
                        refill_word_last != (synthetic_outputs == 1))
                        $fatal(1, "synthetic output mismatch idx=%0d row=%0d err=%0d last=%0d data=%h",
                               refill_word_index, refill_word_row, refill_word_error,
                               refill_word_last, refill_word_data);
                    synthetic_outputs <= synthetic_outputs + 1;
                end else begin
                    $fatal(1, "unexpected adapter output row=%0d", refill_word_row);
                end
            end
            if (refill_done) begin
                done_count <= done_count + 1;
                if (refill_done_error)
                    done_error_count <= done_error_count + 1;
                if (done_count < 2) begin
                    normal_done_count <= normal_done_count + 1;
                    if (normal_done_count >= 1)
                        normal_done_seen <= 1'b1;
                end
                else if (cmd_word_count == 0)
                    zero_done_seen <= 1'b1;
                else if (synthetic_outputs >= 1)
                    mismatch_done_seen <= 1'b1;
            end
        end
    end

    task automatic send_command(
        input logic [ADDR_W-1:0] base,
        input logic [ADDR_W-1:0] stride,
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
        flush_req = 1'b0;
        timeout_count = 0;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        send_command(32'h0000_2200, 32'd8, 16'd4, 16'd3, 3'd0);
        // Do not wait for the first refill_done.  This command remains held
        // while the first row's final word is followed by the scheduler's
        // late terminal token, directly covering the old-token/new-command
        // race at the adapter boundary.
        send_command(32'h0000_2300, 32'd8, 16'd5, 16'd2, 3'd0);
        while (!normal_done_seen) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if ((timeout_count % 500) == 0)
                $display("NORMAL_PROGRESS t=%0d out=%0d done=%0d active=%0d synth=%0d sch_busy=%0d req=%0d rsp=%0d leafq=%0d",
                         timeout_count, normal_outputs, done_count,
                         adapter_active, synthetic_active, scheduler_busy,
                         req_count_tb, rsp_count_tb, leaf_count);
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "normal adapter timeout out=%0d done=%0d active=%0d synth=%0d sch_busy=%0d req=%0d rsp=%0d leafq=%0d",
                       normal_outputs, done_count, adapter_active,
                       synthetic_active, scheduler_busy, req_count_tb,
                       rsp_count_tb, leaf_count);
        end

        // A zero-length command is rejected locally by the scheduler.  The
        // adapter must emit a completion token, not remain active forever.
        send_command(32'h0000_2300, 32'd8, 16'd8, 16'd0, 3'd0);
        timeout_count = 0;
        while (!zero_done_seen) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "zero-length adapter timeout");
        end

        // Epoch mismatch with a non-zero declaration has no leaf requests;
        // the adapter must synthesize both poison words and terminate.
        send_command(32'h0000_2400, 32'd8, 16'd9, 16'd2, 3'd7);
        timeout_count = 0;
        while (!mismatch_done_seen) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "epoch-mismatch adapter timeout");
        end
        @(negedge clk);
        if (normal_outputs != 5 || synthetic_outputs != 2 || done_count != 4 ||
            normal_done_count != 2 ||
            done_error_count != 2 || !adapter_protocol_error || adapter_active ||
            synthetic_active || scheduler_busy || !scheduler_quiescent ||
            req_count_tb != 5 || rsp_count_tb != 5)
            $fatal(1, "adapter normal/reject result mismatch normal=%0d synth=%0d done=%0d errdone=%0d prot=%0d active=%0d synth_active=%0d req=%0d rsp=%0d",
                   normal_outputs, synthetic_outputs, done_count,
                   done_error_count, adapter_protocol_error, adapter_active,
                   synthetic_active, req_count_tb, rsp_count_tb);

        $display("C1_CACHE_REFILL_COMPLETION_ADAPTER_NORMAL_PASS normal=%0d synthetic=%0d done=%0d error_done=%0d req=%0d rsp=%0d cycles=%0d",
                 normal_outputs, synthetic_outputs, done_count,
                 done_error_count, req_count_tb, rsp_count_tb, cycle_count);
        $finish;
    end

    initial begin
        #60000;
        $fatal(1, "normal/reject adapter timeout watchdog");
    end
endmodule
