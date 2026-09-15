`timescale 1ns/1ps

// Maximum-row-capacity regression for c1_window_line_cache_c8.
//
// The configured row is exactly MAX_ROW_WORDS words:
//
//     640 pixels * 2 C8 groups = 1280 64-bit words.
//
// The external-memory model emits one complete row in the adapter's native
// x-major/group-minor order.  Independent stream and tap checkers cover the
// first, two centre, and final x locations for both groups.  A second pass over
// the same taps proves that a resident maximum-sized row is not refilled.
module tb_c1_window_line_cache_c8_maxrow #(parameter integer BANKED=0);
    localparam integer DATA_W = 64;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 1;
    localparam integer GROUPS = 2;
    localparam integer MAX_ROW_WORDS = 1280;
    localparam integer SAMPLE_COUNT = 8;
    localparam integer PASSES = 2;
    localparam integer EXPECTED_TAPS = SAMPLE_COUNT * PASSES;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic group_start_valid;
    logic group_start_ready;
    logic [15:0] frame_width;
    logic [15:0] frame_height;
    logic [3:0] frame_groups;
    logic group_start_done;
    logic group_start_error;
    logic [2:0] group_start_error_code;
    logic config_valid;

    logic abort_req;
    logic abort_done;
    logic flush_req;
    logic flush_done;

    logic tap_valid;
    logic tap_ready;
    logic signed [16:0] tap_x;
    logic signed [16:0] tap_y;
    logic [2:0] tap_group;
    logic tap_rsp_valid;
    logic tap_rsp_ready;
    logic [DATA_W-1:0] tap_rsp_data_s8;
    logic tap_rsp_error;

    logic refill_req_valid;
    logic refill_req_ready;
    logic [15:0] refill_req_row;
    logic [15:0] refill_req_word_count;
    logic refill_word_valid;
    logic refill_word_ready;
    logic [DATA_W-1:0] refill_word_data_s8;
    logic refill_word_last;
    logic refill_word_error;

    logic cache_error;
    logic [2:0] cache_error_code;
    logic busy;
    logic quiescent;

    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(3),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(8), .ROW_BANKED_STORAGE(BANKED)
    ) dut (
        .clk(clk),
        .rst(rst),
        .group_start_valid(group_start_valid),
        .group_start_ready(group_start_ready),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .frame_groups(frame_groups),
        .group_start_done(group_start_done),
        .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),
        .config_valid(config_valid),
        .abort_req(abort_req),
        .abort_done(abort_done),
        .flush_req(flush_req),
        .flush_done(flush_done),
        .tap_valid(tap_valid),
        .tap_ready(tap_ready),
        .tap_x(tap_x),
        .tap_y(tap_y),
        .tap_group(tap_group),
        .tap_rsp_valid(tap_rsp_valid),
        .tap_rsp_ready(tap_rsp_ready),
        .tap_rsp_data_s8(tap_rsp_data_s8),
        .tap_rsp_error(tap_rsp_error),
        .refill_req_valid(refill_req_valid),
        .refill_req_ready(refill_req_ready),
        .refill_req_row(refill_req_row),
        .refill_req_word_count(refill_req_word_count),
        .refill_word_valid(refill_word_valid),
        .refill_word_ready(refill_word_ready),
        .refill_word_data_s8(refill_word_data_s8),
        .refill_word_last(refill_word_last),
        .refill_word_error(refill_word_error),
        .cache_error(cache_error),
        .cache_error_code(cache_error_code),
        .busy(busy),
        .quiescent(quiescent)
    );

    integer cycle_count;
    integer tap_accept_count;
    integer response_count;
    integer refill_count;
    integer refill_words_seen;
    integer refill_req_stall_cycles;
    integer refill_source_gap_cycles;
    integer response_stall_cycles;
    integer stream_monitor_index;

    logic tap_hold_q;
    logic signed [16:0] tap_hold_x_q;
    logic signed [16:0] tap_hold_y_q;
    logic [2:0] tap_hold_group_q;
    logic rsp_hold_q;
    logic [DATA_W-1:0] rsp_hold_data_q;
    logic rsp_hold_error_q;

    function automatic [DATA_W-1:0] tensor_word(
        input integer column,
        input integer group_index
    );
        integer lane;
        integer byte_value;
        begin
            tensor_word = '0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                // The low byte wraps naturally.  The relatively prime column,
                // group, and lane terms make address/group swaps observable.
                byte_value = column * 37 + group_index * 113 + lane * 19 + 7;
                tensor_word[lane*8 +: 8] = byte_value[7:0];
            end
        end
    endfunction

    // Independent protocol and order monitor.  It checks what the memory BFM
    // actually transfers rather than relying only on its generation loop.
    always @(posedge clk) begin : protocol_monitor
        integer monitor_x;
        integer monitor_group;
        if (rst) begin
            cycle_count <= 0;
            tap_accept_count <= 0;
            response_count <= 0;
            response_stall_cycles <= 0;
            stream_monitor_index <= 0;
            tap_hold_q <= 1'b0;
            rsp_hold_q <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (tap_valid && tap_ready)
                tap_accept_count <= tap_accept_count + 1;
            if (tap_rsp_valid && tap_rsp_ready)
                response_count <= response_count + 1;

            if (tap_hold_q) begin
                if (!tap_valid || tap_x !== tap_hold_x_q ||
                    tap_y !== tap_hold_y_q || tap_group !== tap_hold_group_q)
                    $fatal(1, "tap changed while stalled at cycle %0d",
                           cycle_count);
            end
            tap_hold_q <= tap_valid && !tap_ready;
            tap_hold_x_q <= tap_x;
            tap_hold_y_q <= tap_y;
            tap_hold_group_q <= tap_group;

            if (rsp_hold_q) begin
                if (!tap_rsp_valid || tap_rsp_data_s8 !== rsp_hold_data_q ||
                    tap_rsp_error !== rsp_hold_error_q)
                    $fatal(1, "tap response changed while stalled");
            end
            if (tap_rsp_valid && !tap_rsp_ready)
                response_stall_cycles <= response_stall_cycles + 1;
            rsp_hold_q <= tap_rsp_valid && !tap_rsp_ready;
            rsp_hold_data_q <= tap_rsp_data_s8;
            rsp_hold_error_q <= tap_rsp_error;

            if (refill_word_valid && refill_word_ready) begin
                if (stream_monitor_index >= MAX_ROW_WORDS)
                    $fatal(1, "refill stream exceeded 1280 words");
                monitor_x = stream_monitor_index / GROUPS;
                monitor_group = stream_monitor_index % GROUPS;
                if (refill_word_data_s8 !==
                    tensor_word(monitor_x, monitor_group))
                    $fatal(1,
                           "x-major/group-minor stream mismatch index=%0d x=%0d group=%0d got=%h expected=%h",
                           stream_monitor_index, monitor_x, monitor_group,
                           refill_word_data_s8,
                           tensor_word(monitor_x, monitor_group));
                if (refill_word_last !==
                    (stream_monitor_index == MAX_ROW_WORDS - 1))
                    $fatal(1, "refill last mismatch index=%0d last=%0b",
                           stream_monitor_index, refill_word_last);
                stream_monitor_index <= stream_monitor_index + 1;
            end
        end
    end

    // One complete-row external-memory response.  The refill request is held
    // off for three clocks and the word source inserts four isolated bubbles.
    initial begin : refill_memory_bfm
        integer word_index;
        integer word_x;
        integer word_group;

        refill_req_ready = 1'b0;
        refill_word_valid = 1'b0;
        refill_word_data_s8 = '0;
        refill_word_last = 1'b0;
        refill_word_error = 1'b0;
        refill_count = 0;
        refill_words_seen = 0;
        refill_req_stall_cycles = 0;
        refill_source_gap_cycles = 0;

        wait (!rst);
        forever begin
            while (!refill_req_valid)
                @(negedge clk);

            if (refill_req_row !== 16'd0)
                $fatal(1, "unexpected refill row %0d", refill_req_row);
            if (refill_req_word_count !== 16'd1280)
                $fatal(1, "maximum-row request count got=%0d expected=1280",
                       refill_req_word_count);

            repeat (3) begin
                if (!refill_req_valid || refill_req_row !== 16'd0 ||
                    refill_req_word_count !== 16'd1280)
                    $fatal(1, "refill request changed while backpressured");
                refill_req_stall_cycles = refill_req_stall_cycles + 1;
                @(negedge clk);
            end

            refill_req_ready = 1'b1;
            @(posedge clk);
            if (!refill_req_valid)
                $fatal(1, "refill request vanished on handshake edge");
            @(negedge clk);
            refill_req_ready = 1'b0;
            refill_count = refill_count + 1;
            if (refill_count > 1)
                $fatal(1, "resident maximum row was refilled");

            for (word_index = 0; word_index < MAX_ROW_WORDS;
                 word_index = word_index + 1) begin
                if ((word_index == 1) || (word_index == 319) ||
                    (word_index == 640) || (word_index == 1279)) begin
                    refill_source_gap_cycles = refill_source_gap_cycles + 1;
                    @(negedge clk);
                end

                word_x = word_index / GROUPS;
                word_group = word_index % GROUPS;
                refill_word_data_s8 = tensor_word(word_x, word_group);
                refill_word_last = (word_index == MAX_ROW_WORDS - 1);
                refill_word_valid = 1'b1;

                do begin
                    @(posedge clk);
                end while (!refill_word_ready);

                refill_words_seen = refill_words_seen + 1;
                @(negedge clk);
                refill_word_valid = 1'b0;
                refill_word_last = 1'b0;
            end
        end
    end

    task automatic start_stage;
        begin
            @(negedge clk);
            group_start_valid = 1'b1;
            while (!group_start_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!group_start_done)
                $fatal(1, "group_start_done did not acknowledge handshake");
            group_start_valid = 1'b0;
            if (group_start_error || group_start_error_code != 3'd0)
                $fatal(1, "maximum geometry rejected code=%0d",
                       group_start_error_code);
            if (!config_valid)
                $fatal(1, "maximum geometry did not become valid");
        end
    endtask

    task automatic tap_and_check(
        input integer column,
        input integer group_index
    );
        logic [DATA_W-1:0] expected_data;
        begin
            expected_data = tensor_word(column, group_index);

            // Keep ready low before the request.  This still permits the tap
            // to enter an empty response slot, then guarantees response
            // backpressure once the synchronous RAM read completes.
            @(negedge clk);
            tap_rsp_ready = 1'b0;
            tap_x = column;
            tap_y = 17'sd0;
            tap_group = group_index;
            tap_valid = 1'b1;
            do begin
                @(posedge clk);
            end while (!tap_ready);
            @(negedge clk);
            tap_valid = 1'b0;

            while (!tap_rsp_valid)
                @(negedge clk);
            if (tap_rsp_error || tap_rsp_data_s8 !== expected_data)
                $fatal(1,
                       "bit-exact hit mismatch x=%0d group=%0d got=%h err=%0b expected=%h",
                       column, group_index, tap_rsp_data_s8,
                       tap_rsp_error, expected_data);

            // Hold each result for two clocks and let the protocol monitor
            // prove that valid/data/error remain stable.
            repeat (2) @(posedge clk);
            @(negedge clk);
            tap_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tap_rsp_ready = 1'b0;
        end
    endtask

    task automatic sample_row;
        begin
            // word indices: 0/1, 638/639, 640/641, and 1278/1279.
            tap_and_check(0, 0);
            tap_and_check(0, 1);
            tap_and_check(319, 0);
            tap_and_check(319, 1);
            tap_and_check(320, 0);
            tap_and_check(320, 1);
            tap_and_check(639, 0);
            tap_and_check(639, 1);
        end
    endtask

    initial begin : main_test
        integer refills_before_repeat;

        group_start_valid = 1'b0;
        frame_width = FRAME_W;
        frame_height = FRAME_H;
        frame_groups = GROUPS;
        abort_req = 1'b0;
        flush_req = 1'b0;
        tap_valid = 1'b0;
        tap_x = '0;
        tap_y = '0;
        tap_group = '0;
        tap_rsp_ready = 1'b0;

        repeat (5) @(negedge clk);
        rst = 1'b0;

        start_stage();
        sample_row();

        refills_before_repeat = refill_count;
        sample_row();
        if (refill_count != refills_before_repeat)
            $fatal(1, "repeat hits caused refill count to change %0d -> %0d",
                   refills_before_repeat, refill_count);

        repeat (3) @(negedge clk);
        if (tap_accept_count != EXPECTED_TAPS ||
            response_count != EXPECTED_TAPS)
            $fatal(1, "tap totals got accept=%0d response=%0d expected=%0d",
                   tap_accept_count, response_count, EXPECTED_TAPS);
        if (refill_count != 1 || refill_words_seen != MAX_ROW_WORDS ||
            stream_monitor_index != MAX_ROW_WORDS)
            $fatal(1,
                   "refill totals got requests=%0d BFM_words=%0d monitor_words=%0d",
                   refill_count, refill_words_seen, stream_monitor_index);
        if (refill_req_stall_cycles != 3 ||
            refill_source_gap_cycles != 4 ||
            response_stall_cycles < EXPECTED_TAPS * 2)
            $fatal(1,
                   "backpressure coverage req_stalls=%0d source_gaps=%0d rsp_stalls=%0d",
                   refill_req_stall_cycles, refill_source_gap_cycles,
                   response_stall_cycles);
        if (cache_error || cache_error_code != 3'd0)
            $fatal(1, "unexpected cache error code=%0d", cache_error_code);
        if (!config_valid || busy || !quiescent)
            $fatal(1,
                   "unexpected final control state config=%0b busy=%0b quiescent=%0b",
                   config_valid, busy, quiescent);

        $display("C1_WINDOW_LINE_CACHE_C8_MAXROW_PASS taps=%0d refills=%0d refill_words=%0d row_words=%0d req_stalls=%0d source_gaps=%0d rsp_stalls=%0d",
                 response_count, refill_count, refill_words_seen,
                 MAX_ROW_WORDS, refill_req_stall_cycles,
                 refill_source_gap_cycles, response_stall_cycles);
        $finish;
    end

    initial begin : timeout_watchdog
        repeat (50000) @(posedge clk);
        $fatal(1, "maximum-row cache regression timeout");
    end
endmodule
