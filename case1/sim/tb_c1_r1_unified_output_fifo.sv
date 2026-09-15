`timescale 1ns/1ps

// Minimal boardless contract test for c1_r1_unified_output_fifo.
//
// The test intentionally drives the interface on falling edges and samples a
// transfer immediately before the rising edge that commits it.  This makes
// the no-fall-through and full-without-replacement rules explicit instead of
// relying on simulator scheduling luck.
module tb_c1_r1_unified_output_fifo;
`ifdef C1_UNIFIED_FIFO_REGISTERED_ERROR
    localparam integer COMBINATIONAL_ERROR_GATE_CFG = 0;
`else
    localparam integer COMBINATIONAL_ERROR_GATE_CFG = 1;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;
    logic error_flush = 1'b0;

    logic in_valid = 1'b0;
    logic in_ready;
    logic [63:0] in_data_s8 = '0;
    logic [2:0] in_group_index = '0;
    logic in_group_last = 1'b0;
    logic [15:0] in_x = '0;
    logic [15:0] in_y = '0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;

    logic out_valid;
    logic out_ready = 1'b0;
    logic [63:0] out_data_s8;
    logic [2:0] out_group_index;
    logic out_group_last;
    logic [15:0] out_x;
    logic [15:0] out_y;
    logic out_sof;
    logic out_eol;
    logic out_eof;
    logic [1:0] level;
    logic full;
    logic empty;

    c1_r1_unified_output_fifo #(
        .COMBINATIONAL_ERROR_GATE(COMBINATIONAL_ERROR_GATE_CFG)
    ) dut (
        .clk,
        .rst,
        .abort,
        .error_flush,
        .in_valid,
        .in_ready,
        .in_data_s8,
        .in_group_index,
        .in_group_last,
        .in_x,
        .in_y,
        .in_sof,
        .in_eol,
        .in_eof,
        .out_valid,
        .out_ready,
        .out_data_s8,
        .out_group_index,
        .out_group_last,
        .out_x,
        .out_y,
        .out_sof,
        .out_eol,
        .out_eof,
        .level,
        .full,
        .empty
    );

    always #5 clk = ~clk;

    function automatic logic [63:0] expected_data(input integer seq);
        expected_data = 64'hc1f0_0000_0000_0000 + seq;
    endfunction

    function automatic logic [2:0] expected_group(input integer seq);
        expected_group = seq % 8;
    endfunction

    function automatic logic expected_group_last(input integer seq);
        expected_group_last = ((seq % 3) == 0);
    endfunction

    function automatic logic [15:0] expected_x(input integer seq);
        expected_x = seq;
    endfunction

    function automatic logic [15:0] expected_y(input integer seq);
        expected_y = 16'h1000 + seq;
    endfunction

    function automatic logic expected_sof(input integer seq);
        expected_sof = ((seq % 5) == 0);
    endfunction

    function automatic logic expected_eol(input integer seq);
        expected_eol = ((seq % 4) == 1);
    endfunction

    function automatic logic expected_eof(input integer seq);
        expected_eof = ((seq % 7) == 6);
    endfunction

    task automatic drive_payload(input integer seq);
        begin
            in_data_s8 = expected_data(seq);
            in_group_index = expected_group(seq);
            in_group_last = expected_group_last(seq);
            in_x = expected_x(seq);
            in_y = expected_y(seq);
            in_sof = expected_sof(seq);
            in_eol = expected_eol(seq);
            in_eof = expected_eof(seq);
        end
    endtask

    task automatic check_payload(input integer seq);
        begin
            if (out_data_s8 !== expected_data(seq) ||
                out_group_index !== expected_group(seq) ||
                out_group_last !== expected_group_last(seq) ||
                out_x !== expected_x(seq) ||
                out_y !== expected_y(seq) ||
                out_sof !== expected_sof(seq) ||
                out_eol !== expected_eol(seq) ||
                out_eof !== expected_eof(seq)) begin
                $fatal(1,
                       "payload mismatch expected=%0d data=%h group=%0d/%0b " +
                       "xy=%0d,%0d flags=%0b%0b%0b",
                       seq, out_data_s8, out_group_index, out_group_last,
                       out_x, out_y, out_sof, out_eol, out_eof);
            end
        end
    endtask

    task automatic commit_push(input integer seq);
        begin
            drive_payload(seq);
            if (!in_valid || !in_ready)
                $fatal(1, "input beat %0d was not accepted", seq);
            @(posedge clk);
            #1;
        end
    endtask

    task automatic commit_pop(input integer seq);
        begin
            if (!out_valid || !out_ready)
                $fatal(1, "output beat %0d was not available for pop", seq);
            check_payload(seq);
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        integer cycle;
        integer produced;
        integer consumed;
        logic [7:0] lfsr;

        // Synchronous reset.  The interface must remain fenced while rst is
        // high, even before the first reset edge.
        repeat (2) @(posedge clk);
        #1;
        if (in_ready || out_valid || level != 0)
            $fatal(1, "FIFO visible during reset");
        @(negedge clk);
        rst = 1'b0;
        #1;

        // Empty -> first push: no fall-through before the committing edge.
        out_ready = 1'b0;
        in_valid = 1'b1;
        drive_payload(1);
        if (!in_ready || out_valid || level != 0)
            $fatal(1, "empty FIFO did not show registered-input behavior");
        @(posedge clk);
        #1;
        in_valid = 1'b0;
        if (level != 1 || !out_valid || full || empty)
            $fatal(1, "first push did not create one held output");
        check_payload(1);

        // Hold the first payload through multiple stalled cycles.  The DUT
        // contains the same check internally; this external check gives a
        // clear failure if assertions are compiled out.
        repeat (2) begin
            @(negedge clk);
            if (!out_valid || out_ready)
                $fatal(1, "first payload was not held during stall");
            check_payload(1);
            @(posedge clk);
            #1;
            check_payload(1);
        end

        // Fill the second slot.
        @(negedge clk);
        in_valid = 1'b1;
        drive_payload(2);
        if (!in_ready || !out_valid)
            $fatal(1, "second slot was not writable while first was stalled");
        @(posedge clk);
        #1;
        in_valid = 1'b0;
        if (level != 2 || !full || in_ready)
            $fatal(1, "depth-2 FIFO did not enter full state");

        // Full + pop: in_ready must stay low and the candidate beat must not
        // replace the popped word in the same cycle.  This is the deliberate
        // one-cycle bubble that keeps downstream ready out of the input path.
        @(negedge clk);
        in_valid = 1'b1;
        drive_payload(3);
        out_ready = 1'b1;
        if (in_ready)
            $fatal(1, "full FIFO illegally depended on out_ready for in_ready");
        commit_pop(1);
        in_valid = 1'b1;
        if (level != 1 || !in_ready || !out_valid)
            $fatal(1, "full-pop did not leave exactly one queued beat");

        // Next cycle accepts candidate 3 while popping 2 (occupancy remains 1).
        commit_pop(2);
        if (level != 1 || !out_valid)
            $fatal(1, "simultaneous pop/push at non-full occupancy failed");
        in_valid = 1'b0;
        commit_pop(3);
        if (level != 0 || out_valid || !empty)
            $fatal(1, "FIFO did not drain in order");

        // Abort must flush two queued entries and suppress handshakes even if
        // a producer and consumer are both presenting transfers.
        out_ready = 1'b0;
        in_valid = 1'b1;
        @(negedge clk);
        drive_payload(4);
        commit_push(4);
        @(negedge clk);
        drive_payload(5);
        commit_push(5);
        in_valid = 1'b1;
        @(negedge clk);
        drive_payload(6);
        abort = 1'b1;
        out_ready = 1'b1;
        #1;
        if (in_ready || out_valid)
            $fatal(1, "abort did not immediately fence both interfaces");
        @(posedge clk);
        #1;
        in_valid = 1'b0;
        abort = 1'b0;
        #1;
        if (level != 0 || out_valid || in_ready != 1 || !empty)
            $fatal(1, "abort did not clear the FIFO");

        // Error flush has the same stale-result protection as abort.  The
        // bridge experiment deliberately tests a synchronous error fence:
        // the queue remains observable until the error edge, then clears;
        // the bridge gates the external adapter handshake in that interval.
        out_ready = 1'b0;
        in_valid = 1'b1;
        @(negedge clk);
        drive_payload(7);
        commit_push(7);
        in_valid = 1'b0;
        @(negedge clk);
        error_flush = 1'b1;
`ifdef C1_UNIFIED_FIFO_REGISTERED_ERROR
        out_ready = 1'b0;
        #1;
        if (!out_valid || level != 1)
            $fatal(1, "registered error mode changed payload before flush edge");
`else
        out_ready = 1'b1;
        #1;
        if (in_ready || out_valid)
            $fatal(1, "error_flush did not fence the interface");
`endif
        @(posedge clk);
        #1;
        error_flush = 1'b0;
        #1;
        if (level != 0 || out_valid)
            $fatal(1, "error_flush did not clear the FIFO");

        // A new post-abort/error epoch starts cleanly and preserves all fields.
        out_ready = 1'b1;
        in_valid = 1'b1;
        drive_payload(8);
        if (!in_ready || out_valid)
            $fatal(1, "post-flush first beat did not start from empty");
        @(posedge clk);
        #1;
        in_valid = 1'b0;
        if (!out_valid || level != 1)
            $fatal(1, "post-flush beat was not registered");
        commit_pop(8);
        if (level != 0 || out_valid)
            $fatal(1, "post-flush beat did not retire");

        // Short pseudo-random ready/valid run.  The producer holds the same
        // payload until in_ready, while the consumer uses an LFSR-derived
        // ready pattern.  The queue is drained afterwards to check ordering
        // across both full and empty transitions.
        produced = 20;
        consumed = 20;
        lfsr = 8'hA5;
        in_valid = 1'b0;
        out_ready = 1'b0;
        for (cycle = 0; cycle < 40; cycle = cycle + 1) begin
            @(negedge clk);
            if (produced < 30) begin
                in_valid = 1'b1;
                drive_payload(produced);
            end else begin
                in_valid = 1'b0;
            end
            // Force a drain whenever full so this finite test cannot starve;
            // the LFSR still creates both long and short stall intervals.
            out_ready = lfsr[0] || (level == 2);
            #1;
            if (out_valid && out_ready) begin
                check_payload(consumed);
                consumed = consumed + 1;
            end
            if (in_valid && in_ready)
                produced = produced + 1;
            @(posedge clk);
            #1;
            lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5]};
        end

        for (cycle = 0; cycle < 40 && consumed < produced; cycle = cycle + 1) begin
            @(negedge clk);
            in_valid = 1'b0;
            out_ready = 1'b1;
            #1;
            if (out_valid && out_ready) begin
                check_payload(consumed);
                consumed = consumed + 1;
            end
            @(posedge clk);
            #1;
        end
        if (produced != 30 || consumed != 30 || level != 0 || out_valid)
            $fatal(1,
                   "pseudo-random run lost/duplicated data produced=%0d consumed=%0d level=%0d",
                   produced, consumed, level);

        $display("C1_R1_UNIFIED_OUTPUT_FIFO_PASS depth=2 payload=103");
        $finish;
    end
endmodule
