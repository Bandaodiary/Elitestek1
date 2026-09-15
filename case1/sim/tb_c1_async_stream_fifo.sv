`timescale 1ns/1ps

module c1_async_fifo_random_case #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH = 16,
    parameter integer TOTAL_ITEMS = 4096,
    parameter integer WARMUP_WR_CYCLES = 40,
    parameter integer WARMUP_RD_CYCLES = 28,
    parameter realtime WR_HALF_PERIOD = 3.5,
    parameter realtime RD_HALF_PERIOD = 5.3,
    parameter realtime RD_PHASE = 1.1,
    parameter bit REQUIRE_MIDRUN_EMPTY = 1'b0
);

    localparam integer PTR_WIDTH = $clog2(DEPTH) + 1;

    logic wr_clk = 1'b0;
    logic wr_rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [DATA_WIDTH-1:0] in_data = '0;
    logic wr_full;

    logic rd_clk = 1'b0;
    logic rd_rst = 1'b1;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [DATA_WIDTH-1:0] out_data;
    logic rd_empty;

    integer push_count = 0;
    integer pop_count = 0;
    integer wr_cycle = 0;
    integer rd_cycle = 0;
    integer input_hold_checks = 0;
    integer output_hold_checks = 0;
    logic [31:0] wr_prng = 32'h6d2b_79f5;
    logic [31:0] rd_prng = 32'h1b87_3593;
    logic previous_push_accepted = 1'b0;
    logic held_input = 1'b0;
    logic [DATA_WIDTH-1:0] held_input_data = '0;
    logic held_output = 1'b0;
    logic [DATA_WIDTH-1:0] held_output_data = '0;
    logic saw_full = 1'b0;
    logic saw_empty = 1'b0;
    logic saw_input_stall = 1'b0;
    logic saw_output_stall = 1'b0;
    logic saw_random_source_pause = 1'b0;
    logic saw_random_sink_stall = 1'b0;
    logic first_full_checked = 1'b0;
    logic saw_wr_extended_wrap = 1'b0;
    logic saw_rd_extended_wrap = 1'b0;
    integer midrun_empty_entries = 0;
    logic previous_empty = 1'b1;
    logic [PTR_WIDTH-1:0] previous_wr_gray = '0;
    logic [PTR_WIDTH-1:0] previous_rd_gray = '0;

    wire push_fire = in_valid && in_ready;
    wire pop_fire = out_valid && out_ready;

    c1_async_stream_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .wr_clk,
        .wr_rst,
        .in_valid,
        .in_ready,
        .in_data,
        .wr_full,
        .rd_clk,
        .rd_rst,
        .out_valid,
        .out_ready,
        .out_data,
        .rd_empty
    );

    function automatic [DATA_WIDTH-1:0] item_value(input integer index);
        begin
            // Unique for every item in this test; exact index ordering catches
            // loss, duplication, reordering, and stale-address reuse.
            item_value = 32'hc100_0000 | index[23:0];
        end
    endfunction

    function automatic [31:0] prng_next(input [31:0] state);
        reg feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_ASYNC_FIFO_FAIL time=%0t wr_cycle=%0d rd_cycle=%0d push=%0d pop=%0d: %s",
                     $time, wr_cycle, rd_cycle, push_count, pop_count, message);
            $fatal(1);
            $finish;
        end
    endtask

    // 7.0 ns and 10.6 ns periods, plus a 1.1 ns read-clock phase offset.
    // Their active edges never coincide in this testbench.
    always #(WR_HALF_PERIOD) wr_clk = ~wr_clk;
    initial begin
        #(RD_PHASE);
        forever #(RD_HALF_PERIOD) rd_clk = ~rd_clk;
    end

    // Both resets are synchronous to their own clocks and deassert at
    // different times, exercising independent-domain startup.  Deassertion
    // occurs between active and stimulus edges to avoid testbench races.
    initial begin
        repeat (6) @(posedge wr_clk);
        #0.2;
        wr_rst = 1'b0;
    end

    initial begin
        repeat (9) @(posedge rd_clk);
        #0.2;
        rd_rst = 1'b0;
    end

    // Source stimulus changes only on the inactive write-clock edge.  During
    // warmup it drives continuously to guarantee full/back-pressure coverage;
    // the remainder inserts deterministic pseudo-random source pauses.
    always @(negedge wr_clk) begin
        if (wr_rst) begin
            in_valid <= 1'b0;
            in_data <= '0;
            wr_prng <= 32'h6d2b_79f5;
        end else begin
            wr_prng <= prng_next(wr_prng);
            if (in_valid && !previous_push_accepted) begin
                in_valid <= in_valid;
                in_data <= in_data;
            end else if (push_count >= TOTAL_ITEMS) begin
                in_valid <= 1'b0;
                in_data <= in_data;
            end else if (wr_cycle < WARMUP_WR_CYCLES) begin
                in_valid <= 1'b1;
                in_data <= item_value(push_count);
            end else if (wr_prng[0] || wr_prng[3] || wr_prng[7]) begin
                in_valid <= 1'b1;
                in_data <= item_value(push_count);
            end else begin
                in_valid <= 1'b0;
                in_data <= in_data;
            end
        end
    end

    // Sink warmup withholds ready so the FIFO fills, then applies independent
    // pseudo-random stalls.  Once the source is complete it drains promptly.
    always @(negedge rd_clk) begin
        if (rd_rst) begin
            out_ready <= 1'b0;
            rd_prng <= 32'h1b87_3593;
        end else begin
            rd_prng <= prng_next(rd_prng);
            if (rd_cycle < WARMUP_RD_CYCLES)
                out_ready <= 1'b0;
            else if (push_count >= TOTAL_ITEMS)
                out_ready <= 1'b1;
            else
                out_ready <= rd_prng[1] || rd_prng[5];
        end
    end

    // Write-domain contract and source-hold checks.
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            push_count = 0;
            wr_cycle = 0;
            previous_push_accepted = 1'b0;
            held_input = 1'b0;
            held_input_data = '0;
            input_hold_checks = 0;
            saw_full = 1'b0;
            saw_input_stall = 1'b0;
            saw_random_source_pause = 1'b0;
            first_full_checked = 1'b0;
            saw_wr_extended_wrap = 1'b0;
            previous_wr_gray = '0;
        end else begin
            wr_cycle = wr_cycle + 1;
            if (in_ready !== (!wr_rst && !wr_full))
                fail("in_ready disagrees with write-domain full flag");
            if ((dut.wr_gray ^ previous_wr_gray) != '0 &&
                (((dut.wr_gray ^ previous_wr_gray) &
                  ((dut.wr_gray ^ previous_wr_gray) - 1'b1)) != '0))
                fail("write Gray pointer changed by more than one bit");
            if (held_input) begin
                input_hold_checks = input_hold_checks + 1;
                if (!in_valid || (in_data !== held_input_data))
                    fail("source changed in_valid/in_data while write side was stalled");
            end
            if (push_fire) begin
                if (push_count >= TOTAL_ITEMS)
                    fail("accepted more source words than requested");
                if (in_data !== item_value(push_count))
                    fail("accepted source word does not match its sequence index");
                if (dut.wr_bin == (2*DEPTH-1))
                    saw_wr_extended_wrap = 1'b1;
                push_count = push_count + 1;
            end
            if (!first_full_checked && wr_full) begin
                if (push_count != DEPTH)
                    fail("first full did not occur at the exact configured capacity");
                if (!in_valid || in_ready)
                    fail("the word following the initial full fill was not back-pressured");
                first_full_checked = 1'b1;
            end
            if (wr_full)
                saw_full = 1'b1;
            if (in_valid && !in_ready)
                saw_input_stall = 1'b1;
            if ((wr_cycle > WARMUP_WR_CYCLES) && !in_valid &&
                (push_count < TOTAL_ITEMS))
                saw_random_source_pause = 1'b1;

            held_input = in_valid && !in_ready;
            held_input_data = in_data;
            previous_push_accepted = push_fire;
            previous_wr_gray = dut.wr_gray;
        end
    end

    // Read-domain scoreboard.  The expected value is derived solely from the
    // next sequence index, so any lost, duplicated, or reordered word fails.
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            pop_count = 0;
            rd_cycle = 0;
            held_output = 1'b0;
            held_output_data = '0;
            output_hold_checks = 0;
            saw_empty = 1'b0;
            saw_output_stall = 1'b0;
            saw_random_sink_stall = 1'b0;
            saw_rd_extended_wrap = 1'b0;
            midrun_empty_entries = 0;
            previous_empty = 1'b1;
            previous_rd_gray = '0;
        end else begin
            rd_cycle = rd_cycle + 1;
            if (out_valid !== (!rd_rst && !rd_empty))
                fail("out_valid disagrees with read-domain empty flag");
            if ((dut.rd_gray ^ previous_rd_gray) != '0 &&
                (((dut.rd_gray ^ previous_rd_gray) &
                  ((dut.rd_gray ^ previous_rd_gray) - 1'b1)) != '0))
                fail("read Gray pointer changed by more than one bit");
            if (held_output) begin
                output_hold_checks = output_hold_checks + 1;
                if (!out_valid || (out_data !== held_output_data))
                    fail("FIFO output changed while sink was stalled");
            end
            if (pop_fire) begin
                if (pop_count >= TOTAL_ITEMS)
                    fail("FIFO produced a duplicated/extra word");
                if (out_data !== item_value(pop_count))
                    fail("FIFO output order/data mismatch");
                if (dut.rd_bin == (2*DEPTH-1))
                    saw_rd_extended_wrap = 1'b1;
                pop_count = pop_count + 1;
            end
            if (rd_empty)
                saw_empty = 1'b1;
            if (out_valid && !out_ready)
                saw_output_stall = 1'b1;
            if ((rd_cycle > WARMUP_RD_CYCLES) && out_valid && !out_ready)
                saw_random_sink_stall = 1'b1;
            if (!previous_empty && rd_empty &&
                (rd_cycle > WARMUP_RD_CYCLES) &&
                (push_count < TOTAL_ITEMS))
                midrun_empty_entries = midrun_empty_entries + 1;

            held_output = out_valid && !out_ready;
            held_output_data = out_data;
            previous_empty = rd_empty;
            previous_rd_gray = dut.rd_gray;
        end
    end

    initial begin
        wait (!wr_rst && !rd_rst);
        wait (pop_count == TOTAL_ITEMS);
        repeat (5) @(posedge rd_clk);
        #0.1;
        if (push_count != TOTAL_ITEMS)
            fail("not all requested source words were accepted");
        if (!rd_empty || out_valid)
            fail("read domain did not return to empty after drain");
        if (!saw_full || !saw_empty || !saw_input_stall ||
            !saw_output_stall || !saw_random_source_pause ||
            !saw_random_sink_stall || !first_full_checked ||
            !saw_wr_extended_wrap || !saw_rd_extended_wrap)
            fail("required full/empty/stall/random/wrap coverage was not observed");
        if (REQUIRE_MIDRUN_EMPTY && (midrun_empty_entries < 2))
            fail("read-fast case did not repeatedly enter empty during traffic");
        if ((input_hold_checks == 0) || (output_hold_checks == 0))
            fail("ready/valid hold checks were not exercised");
        $display("C1_ASYNC_FIFO_PASS depth=%0d items=%0d wr_cycles=%0d rd_cycles=%0d input_hold=%0d output_hold=%0d midrun_empty=%0d",
                 DEPTH, TOTAL_ITEMS, wr_cycle, rd_cycle,
                 input_hold_checks, output_hold_checks, midrun_empty_entries);
        $finish;
    end

    initial begin
        #1_000_000;
        fail("global timeout");
    end

endmodule

// Write-fast/read-slow nominal configuration with a practical CDC depth.
module tb_c1_async_stream_fifo;
    c1_async_fifo_random_case #(
        .DEPTH(16),
        .TOTAL_ITEMS(4096),
        .WR_HALF_PERIOD(3.5),
        .RD_HALF_PERIOD(5.3),
        .RD_PHASE(1.1),
        .REQUIRE_MIDRUN_EMPTY(1'b0)
    ) test();
endmodule

// Minimum legal depth, with the read clock faster than the write clock.  This
// exercises the zero-width lower part of the full-mask concatenation and
// repeatedly crosses into and out of empty during active traffic.
module tb_c1_async_stream_fifo_depth2;
    c1_async_fifo_random_case #(
        .DEPTH(2),
        .TOTAL_ITEMS(2048),
        .WARMUP_WR_CYCLES(24),
        .WARMUP_RD_CYCLES(34),
        .WR_HALF_PERIOD(5.7),
        .RD_HALF_PERIOD(3.1),
        .RD_PHASE(1.3),
        .REQUIRE_MIDRUN_EMPTY(1'b1)
    ) test();
endmodule
