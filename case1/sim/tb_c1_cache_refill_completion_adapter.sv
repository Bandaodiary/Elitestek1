`timescale 1ns/1ps

// Exact-count cancellation bridge regression.
//
// A five-word command is fenced after two requests have entered an in-order
// leaf.  The scheduler emits those two responses on its drain stream; the
// completion adapter must pass them to the single refill sink and synthesize
// the three unissued suffix words so the sink still observes indices 0..4 and
// exactly one LAST marker.
module tb_c1_cache_refill_completion_adapter;
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer SCH_MAX_OUT = 2;
    localparam integer LEAF_DEPTH = 4;
    localparam integer RESPONSE_DELAY = 6;
    localparam integer MAX_CYCLES = 3000;
    localparam integer WORDS = 5;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // Source/adapter command stream.
    logic cmd_valid, cmd_ready;
    logic [ADDR_W-1:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;

    // Adapter/scheduler command stream.
    logic sched_cmd_valid, sched_cmd_ready;
    logic [ADDR_W-1:0] sched_cmd_base_addr, sched_cmd_stride_bytes;
    logic [15:0] sched_cmd_row, sched_cmd_word_count;
    logic [EPOCH_W-1:0] sched_cmd_epoch;
    logic sched_cmd_done, sched_cmd_done_error;
    logic [15:0] sched_cmd_done_row;
    logic [EPOCH_W-1:0] sched_cmd_done_epoch;
    logic sched_abort_done, sched_flush_done, flush_req;
    logic [EPOCH_W-1:0] current_epoch;

    // Scheduler leaf stream.
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

    // Unified refill sink.
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
        .CMD_FIFO_DEPTH(CMD_DEPTH), .MAX_OUTSTANDING(SCH_MAX_OUT),
        .EMIT_DRAIN_WORDS(1)
    ) u_scheduler (
        .clk, .rst,
        .cmd_valid(sched_cmd_valid), .cmd_ready(sched_cmd_ready),
        .cmd_base_addr(sched_cmd_base_addr),
        .cmd_stride_bytes(sched_cmd_stride_bytes),
        .cmd_row(sched_cmd_row), .cmd_word_count(sched_cmd_word_count),
        .cmd_epoch(sched_cmd_epoch),
        .abort_req(1'b0), .abort_done(sched_abort_done),
        .flush_req, .flush_done(sched_flush_done),
        .current_epoch,
        .leaf_req_valid, .leaf_req_ready, .leaf_req_addr, .leaf_req_epoch,
        .leaf_req_flush, .leaf_req_occupancy, .leaf_quiescent,
        .leaf_rsp_valid, .leaf_rsp_ready, .leaf_rsp_data, .leaf_rsp_error,
        .word_valid, .word_ready(scheduler_word_ready), .word_data,
        .word_error, .word_last,
        .word_row, .word_index, .word_epoch,
        .drain_word_valid, .drain_word_ready(scheduler_drain_ready),
        .drain_word_data,
        .drain_word_error, .drain_word_last, .drain_word_row,
        .drain_word_index, .drain_word_epoch,
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
        .sched_drain_valid(drain_word_valid),
        .sched_drain_ready(scheduler_drain_ready),
        .sched_drain_data(drain_word_data),
        .sched_drain_error(drain_word_error),
        .sched_drain_last(drain_word_last),
        .sched_drain_row(drain_word_row),
        .sched_drain_index(drain_word_index),
        .sched_drain_epoch(drain_word_epoch),
        .refill_word_valid, .refill_word_ready, .refill_word_data,
        .refill_word_error, .refill_word_last, .refill_word_row,
        .refill_word_index, .refill_word_epoch,
        .refill_done, .refill_done_error,
        .protocol_error(adapter_protocol_error), .active(adapter_active),
        .synthetic_active, .emitted_count
    );

    // ------------------------------------------------------------------
    // Delayed in-order leaf BFM.
    // ------------------------------------------------------------------
    logic [ADDR_W-1:0] addr_mem [0:LEAF_DEPTH-1];
    integer delay_mem [0:LEAF_DEPTH-1];
    integer leaf_head, leaf_tail, leaf_count;
    logic leaf_rsp_valid_q;
    integer cycles, req_count_tb, rsp_count_tb, flush_pulses;
    integer output_count, timeout_count;
    logic saw_refill_done, saw_flush_done, done_error_seen;
    logic sink_ready_ctl;

    assign leaf_req_ready = (leaf_count < LEAF_DEPTH);
    assign leaf_req_occupancy = leaf_count;
    assign leaf_quiescent = (leaf_count == 0) && !leaf_rsp_valid_q;
    assign leaf_rsp_valid = leaf_rsp_valid_q;
    assign leaf_rsp_data = leaf_rsp_valid_q ?
                           (64'hC1A5_0000_0000_0000 |
                            {32'd0, addr_mem[leaf_head]}) : '0;
    assign leaf_rsp_error = 1'b0;
    assign refill_word_ready = sink_ready_ctl;

    wire leaf_req_fire = leaf_req_valid && leaf_req_ready;
    wire leaf_rsp_fire = leaf_rsp_valid && leaf_rsp_ready;
    wire refill_fire = refill_word_valid && refill_word_ready;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            leaf_head <= 0;
            leaf_tail <= 0;
            leaf_count <= 0;
            leaf_rsp_valid_q <= 1'b0;
            cycles <= 0;
            req_count_tb <= 0;
            rsp_count_tb <= 0;
            flush_pulses <= 0;
            for (i = 0; i < LEAF_DEPTH; i = i + 1) begin
                addr_mem[i] <= '0;
                delay_mem[i] <= 0;
            end
        end else begin
            cycles <= cycles + 1;
            for (i = 0; i < LEAF_DEPTH; i = i + 1)
                if (delay_mem[i] > 0)
                    delay_mem[i] <= delay_mem[i] - 1;
            if (leaf_req_fire) begin
                addr_mem[leaf_tail] <= leaf_req_addr;
                delay_mem[leaf_tail] <= RESPONSE_DELAY;
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
            if (leaf_req_flush)
                flush_pulses <= flush_pulses + 1;
        end
    end

    integer expected_index;
    always_ff @(posedge clk) begin
        if (rst) begin
            output_count <= 0;
            expected_index <= 0;
            saw_refill_done <= 1'b0;
            saw_flush_done <= 1'b0;
            done_error_seen <= 1'b0;
        end else if (refill_fire) begin
            if (refill_word_row != 16'd7 ||
                refill_word_index != expected_index ||
                refill_word_epoch != 3'd0 || !refill_word_error ||
                refill_word_last != (expected_index == WORDS-1))
                $fatal(1, "completion output mismatch idx=%0d row=%0d ep=%0d err=%0d last=%0d",
                       refill_word_index, refill_word_row, refill_word_epoch,
                       refill_word_error, refill_word_last);
            if ((expected_index < 2) &&
                (refill_word_data[31:0] != (32'h0000_4100 + expected_index*8)))
                $fatal(1, "drained data mismatch idx=%0d data=%h",
                       expected_index, refill_word_data);
            if ((expected_index >= 2) && (refill_word_data != 0))
                $fatal(1, "synthetic suffix was not zero idx=%0d data=%h",
                       expected_index, refill_word_data);
            expected_index <= expected_index + 1;
            output_count <= output_count + 1;
            if (refill_done)
                begin
                    saw_refill_done <= 1'b1;
                    done_error_seen <= refill_done_error;
                end
            if (sched_flush_done)
                saw_flush_done <= 1'b1;
        end else begin
            if (refill_done)
                begin
                    saw_refill_done <= 1'b1;
                    done_error_seen <= refill_done_error;
                end
            if (sched_flush_done)
                saw_flush_done <= 1'b1;
        end
    end

    task automatic send_command;
        begin
            @(negedge clk);
            cmd_base_addr = 32'h0000_4100;
            cmd_stride_bytes = 32'd8;
            cmd_row = 16'd7;
            cmd_word_count = WORDS;
            cmd_epoch = 3'd0;
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
        sink_ready_ctl = 1'b0;
        timeout_count = 0;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        send_command();
        while (req_count_tb < SCH_MAX_OUT) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "did not accept two leaf requests");
        end

        // Fence while the drain sink is stalled.  This ensures the adapter's
        // unified sink backpressure is propagated instead of dropping stale
        // responses.
        @(negedge clk);
        flush_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        repeat (4) @(posedge clk);
        sink_ready_ctl = 1'b1;

        timeout_count = 0;
        while (!saw_refill_done || !saw_flush_done) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "completion adapter timeout out=%0d synth=%0d scheduler=%0d",
                       output_count, synthetic_active, scheduler_busy);
        end
        @(negedge clk);
        if (output_count != WORDS || expected_index != WORDS ||
            !done_error_seen || !adapter_protocol_error ||
            req_count_tb != SCH_MAX_OUT || rsp_count_tb != SCH_MAX_OUT ||
            perf_stale_drop_count != SCH_MAX_OUT ||
            scheduler_outstanding != 0 || scheduler_drain_pending)
            $fatal(1, "completion result mismatch out=%0d idx=%0d done_err=%0d prot=%0d req=%0d rsp=%0d stale=%0d outst=%0d drain=%0d",
                   output_count, expected_index, refill_done_error,
                   adapter_protocol_error, req_count_tb, rsp_count_tb,
                   perf_stale_drop_count, scheduler_outstanding,
                   scheduler_drain_pending);

        $display("C1_CACHE_REFILL_COMPLETION_ADAPTER_PASS words=%0d drained=%0d synthetic=%0d req=%0d rsp=%0d flush=%0d cycles=%0d",
                 output_count, SCH_MAX_OUT, WORDS-SCH_MAX_OUT,
                 req_count_tb, rsp_count_tb, flush_pulses, cycles);
        $finish;
    end

    initial begin
        #40000;
        $fatal(1, "completion adapter timeout watchdog");
    end
endmodule
