`timescale 1ns/1ps

// Fault/capacity regression for c1_window_line_cache_c8.
//
// This test is intentionally independent from the raster/bit-exact functional
// testbench.  Small parameters keep the refill fault cases fast while making
// every capacity boundary explicit:
//   row_words = frame_width * frame_groups <= 8.
module tb_c1_window_line_cache_c8_faults #(parameter integer BANKED=0);
    localparam integer DATA_W = 16;
    localparam integer LINE_ROWS = 2;
    localparam integer MAX_ROW_WORDS = 8;
    localparam integer MAX_GROUPS = 2;
    localparam integer VALID_W = 4;
    localparam integer VALID_H = 3;
    localparam integer VALID_GROUPS = 2;
    localparam integer VALID_ROW_WORDS = VALID_W * VALID_GROUPS;

    logic clk = 1'b0;
    logic rst = 1'b1;

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

    integer config_check_count;
    integer fault_case_count;
    integer maintenance_case_count;
    integer refill_request_count;
    integer refill_word_count_seen;
    integer response_count;

    always #5 clk = ~clk;

    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(LINE_ROWS),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(MAX_GROUPS), .ROW_BANKED_STORAGE(BANKED)
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

    function automatic logic [DATA_W-1:0] refill_payload(
        input integer row_index,
        input integer word_index
    );
        begin
            refill_payload = ((row_index & 8'hff) << 8) |
                             (word_index & 8'hff);
        end
    endfunction

    task automatic hard_reset;
        begin
            rst = 1'b1;
            group_start_valid = 1'b0;
            frame_width = 16'd0;
            frame_height = 16'd0;
            frame_groups = 4'd0;
            abort_req = 1'b0;
            flush_req = 1'b0;
            tap_valid = 1'b0;
            tap_x = '0;
            tap_y = '0;
            tap_group = '0;
            tap_rsp_ready = 1'b1;
            refill_req_ready = 1'b0;
            refill_word_valid = 1'b0;
            refill_word_data_s8 = '0;
            refill_word_last = 1'b0;
            refill_word_error = 1'b0;
            repeat (4) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
            if (!quiescent || busy || config_valid || cache_error)
                $fatal(1, "reset state mismatch q=%0b busy=%0b cfg=%0b err=%0b",
                       quiescent, busy, config_valid, cache_error);
        end
    endtask

    task automatic issue_config(
        input integer width_value,
        input integer height_value,
        input integer group_value,
        input logic expect_error,
        input logic [2:0] expect_code
    );
        integer guard;
        begin
            @(negedge clk);
            frame_width = width_value;
            frame_height = height_value;
            frame_groups = group_value;
            group_start_valid = 1'b1;
            guard = 0;
            while (!group_start_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "group_start_ready timeout");
            end
            @(posedge clk);
            @(negedge clk);
            if (!group_start_done)
                $fatal(1, "group_start_done missing");
            if (group_start_error !== expect_error ||
                group_start_error_code !== expect_code)
                $fatal(1,
                       "group_start result mismatch w=%0d h=%0d g=%0d got_err=%0b got_code=%0d expected_err=%0b expected_code=%0d",
                       width_value, height_value, group_value,
                       group_start_error, group_start_error_code,
                       expect_error, expect_code);
            if (config_valid === expect_error)
                $fatal(1, "config_valid mismatch after group_start");
            group_start_valid = 1'b0;
            config_check_count = config_check_count + 1;
            @(posedge clk);
            @(negedge clk);
            if (group_start_done || group_start_error ||
                group_start_error_code != 3'd0)
                $fatal(1, "group_start result was not a one-cycle pulse");
        end
    endtask

    task automatic begin_miss(
        input integer x_value,
        input integer y_value,
        input integer group_value
    );
        integer guard;
        begin
            @(negedge clk);
            tap_x = x_value;
            tap_y = y_value;
            tap_group = group_value;
            tap_valid = 1'b1;
            guard = 0;
            while (!refill_req_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "refill request timeout for miss");
            end
            if (tap_ready)
                $fatal(1, "miss tap was incorrectly accepted");
        end
    endtask

    task automatic accept_refill_request(
        input integer expected_row
    );
        logic [15:0] held_row;
        logic [15:0] held_words;
        begin
            held_row = refill_req_row;
            held_words = refill_req_word_count;
            if (held_row != expected_row || held_words != VALID_ROW_WORDS)
                $fatal(1,
                       "refill request mismatch got row=%0d words=%0d expected row=%0d words=%0d",
                       held_row, held_words, expected_row, VALID_ROW_WORDS);

            // Exercise the no-withdrawal rule before accepting the request.
            repeat (2) begin
                @(posedge clk);
                @(negedge clk);
                if (!refill_req_valid || refill_req_row != held_row ||
                    refill_req_word_count != held_words)
                    $fatal(1, "stalled refill request changed");
            end
            refill_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            refill_req_ready = 1'b0;
            if (!refill_word_ready || refill_req_valid)
                $fatal(1, "DUT did not enter refill-data state");
            refill_request_count = refill_request_count + 1;
        end
    endtask

    task automatic send_refill_word(
        input integer row_index,
        input integer word_index,
        input logic drive_last,
        input logic drive_error
    );
        begin
            if (!refill_word_ready)
                $fatal(1, "refill_word_ready low before word %0d", word_index);
            refill_word_data_s8 = refill_payload(row_index, word_index);
            refill_word_last = drive_last;
            refill_word_error = drive_error;
            refill_word_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            refill_word_valid = 1'b0;
            refill_word_last = 1'b0;
            refill_word_error = 1'b0;
            refill_word_count_seen = refill_word_count_seen + 1;
        end
    endtask

    task automatic run_fault_case(
        input integer fault_mode,
        input logic [2:0] expected_cache_code
    );
        integer word_index;
        logic drive_last;
        logic drive_error;
        begin
            hard_reset();
            issue_config(VALID_W, VALID_H, VALID_GROUPS, 1'b0, 3'd0);
            begin_miss(2, 1, 1);
            accept_refill_request(1);

            for (word_index = 0; word_index < VALID_ROW_WORDS;
                 word_index = word_index + 1) begin
                drive_last = (word_index == VALID_ROW_WORDS - 1);
                drive_error = 1'b0;
                case (fault_mode)
                    0: drive_error = (word_index == 2); // data error
                    1: begin                          // early last
                        if (word_index == 2)
                            drive_last = 1'b1;
                    end
                    2: begin                          // missing/late last
                        if (word_index == VALID_ROW_WORDS - 1)
                            drive_last = 1'b0;
                    end
                    default: $fatal(1, "unknown fault mode %0d", fault_mode);
                endcase
                send_refill_word(1, word_index, drive_last, drive_error);
            end

            if (refill_word_ready || refill_req_valid)
                $fatal(1, "faulted refill did not terminate at declared length");
            if (!cache_error || cache_error_code != expected_cache_code)
                $fatal(1,
                       "sticky cache error mismatch mode=%0d err=%0b code=%0d expected=%0d",
                       fault_mode, cache_error, cache_error_code,
                       expected_cache_code);
            if (dut.row_valid_q !== '0)
                $fatal(1, "faulted partial row became visible mode=%0d tags=%b",
                       fault_mode, dut.row_valid_q);
            if (tap_rsp_valid)
                $fatal(1, "faulted miss unexpectedly produced a response");

            // Prove the error is sticky rather than a completion pulse.
            repeat (3) begin
                @(posedge clk);
                @(negedge clk);
                if (!cache_error || cache_error_code != expected_cache_code)
                    $fatal(1, "cache error did not remain sticky mode=%0d",
                           fault_mode);
                if (dut.row_valid_q !== '0)
                    $fatal(1, "faulted row became valid after drain mode=%0d",
                           fault_mode);
            end
            tap_valid = 1'b0;
            fault_case_count = fault_case_count + 1;
        end
    endtask

    task automatic complete_good_refill(input integer row_index);
        integer word_index;
        begin
            for (word_index = 0; word_index < VALID_ROW_WORDS;
                 word_index = word_index + 1)
                send_refill_word(row_index, word_index,
                                 word_index == VALID_ROW_WORDS - 1, 1'b0);
        end
    endtask

    task automatic accept_and_check_tap_response(
        input integer expected_row,
        input integer expected_word
    );
        integer guard;
        begin
            guard = 0;
            while (!tap_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "tap retry was not accepted after good refill");
            end
            @(posedge clk);
            @(negedge clk);
            tap_valid = 1'b0;
            guard = 0;
            while (!tap_rsp_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "tap response did not arrive after registered RAM address");
            end
            if (!tap_rsp_valid || tap_rsp_error ||
                tap_rsp_data_s8 !== refill_payload(expected_row,
                                                   expected_word))
                $fatal(1,
                       "tap response mismatch valid=%0b err=%0b data=%h expected=%h",
                       tap_rsp_valid, tap_rsp_error, tap_rsp_data_s8,
                       refill_payload(expected_row, expected_word));
            response_count = response_count + 1;
            @(posedge clk);
            @(negedge clk);
            if (tap_rsp_valid)
                $fatal(1, "tap response did not retire");
        end
    endtask

    task automatic run_flush_during_refill;
        integer word_index;
        begin
            hard_reset();
            issue_config(VALID_W, VALID_H, VALID_GROUPS, 1'b0, 3'd0);
            begin_miss(2, 1, 1);
            accept_refill_request(1);
            send_refill_word(1, 0, 1'b0, 1'b0);
            send_refill_word(1, 1, 1'b0, 1'b0);

            flush_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            flush_req = 1'b0;
            if (flush_done || !config_valid || !refill_word_ready)
                $fatal(1,
                       "flush completed early or disrupted accepted refill done=%0b cfg=%0b ready=%0b",
                       flush_done, config_valid, refill_word_ready);

            for (word_index = 2; word_index < VALID_ROW_WORDS;
                 word_index = word_index + 1) begin
                send_refill_word(1, word_index,
                                 word_index == VALID_ROW_WORDS - 1, 1'b0);
                if ((word_index != VALID_ROW_WORDS - 1) && flush_done)
                    $fatal(1, "flush_done asserted before refill drained");
            end
            if (flush_done)
                $fatal(1, "flush_done asserted on final refill-word edge");
            @(posedge clk);
            @(negedge clk);
            if (!flush_done || !config_valid || cache_error ||
                dut.row_valid_q !== '0)
                $fatal(1,
                       "flush completion mismatch done=%0b cfg=%0b err=%0b tags=%b",
                       flush_done, config_valid, cache_error, dut.row_valid_q);

            // The original tap remained pending.  A fresh request for the
            // same row proves the drained refill was discarded.
            @(posedge clk);
            @(negedge clk);
            if (!refill_req_valid)
                $fatal(1, "post-flush pending tap did not request a new refill");
            accept_refill_request(1);
            complete_good_refill(1);
            accept_and_check_tap_response(1, 5);
            maintenance_case_count = maintenance_case_count + 1;
        end
    endtask

    task automatic run_abort_during_refill;
        integer word_index;
        begin
            hard_reset();
            issue_config(VALID_W, VALID_H, VALID_GROUPS, 1'b0, 3'd0);
            begin_miss(0, 2, 0);
            accept_refill_request(2);
            send_refill_word(2, 0, 1'b0, 1'b0);
            send_refill_word(2, 1, 1'b0, 1'b0);
            send_refill_word(2, 2, 1'b0, 1'b0);

            abort_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort_req = 1'b0;
            if (abort_done || !config_valid || !refill_word_ready)
                $fatal(1,
                       "abort completed early or disrupted accepted refill done=%0b cfg=%0b ready=%0b",
                       abort_done, config_valid, refill_word_ready);

            for (word_index = 3; word_index < VALID_ROW_WORDS;
                 word_index = word_index + 1) begin
                send_refill_word(2, word_index,
                                 word_index == VALID_ROW_WORDS - 1, 1'b0);
                if ((word_index != VALID_ROW_WORDS - 1) && abort_done)
                    $fatal(1, "abort_done asserted before refill drained");
            end
            if (abort_done)
                $fatal(1, "abort_done asserted on final refill-word edge");
            @(posedge clk);
            @(negedge clk);
            if (!abort_done || config_valid || cache_error ||
                dut.row_valid_q !== '0)
                $fatal(1,
                       "abort completion mismatch done=%0b cfg=%0b err=%0b tags=%b",
                       abort_done, config_valid, cache_error, dut.row_valid_q);
            tap_valid = 1'b0;
            maintenance_case_count = maintenance_case_count + 1;
        end
    endtask

    initial begin : main_test
        config_check_count = 0;
        fault_case_count = 0;
        maintenance_case_count = 0;
        refill_request_count = 0;
        refill_word_count_seen = 0;
        response_count = 0;

        hard_reset();
        issue_config(0, 3, 1, 1'b1, 3'd1);
        issue_config(1, 1, MAX_GROUPS + 1, 1'b1, 3'd2);
        issue_config(5, 1, 2, 1'b1, 3'd3);
        issue_config(VALID_W, VALID_H, VALID_GROUPS, 1'b0, 3'd0);

        run_fault_case(0, 3'd1);
        run_fault_case(1, 3'd2);
        run_fault_case(2, 3'd2);
        run_flush_during_refill();
        run_abort_during_refill();

        repeat (3) @(negedge clk);
        if (config_check_count != 9 || fault_case_count != 3 ||
            maintenance_case_count != 2)
            $fatal(1,
                   "case totals mismatch configs=%0d faults=%0d maintenance=%0d",
                   config_check_count, fault_case_count,
                   maintenance_case_count);
        if (refill_request_count != 6 || refill_word_count_seen != 48 ||
            response_count != 1)
            $fatal(1,
                   "traffic totals mismatch requests=%0d words=%0d responses=%0d",
                   refill_request_count, refill_word_count_seen,
                   response_count);
        if (busy || !quiescent || cache_error)
            $fatal(1, "final state mismatch busy=%0b q=%0b err=%0b",
                   busy, quiescent, cache_error);

        $display("C1_WINDOW_LINE_CACHE_C8_FAULT_PASS configs=%0d faults=%0d maintenance=%0d refill_requests=%0d refill_words=%0d responses=%0d",
                 config_check_count, fault_case_count,
                 maintenance_case_count, refill_request_count,
                 refill_word_count_seen, response_count);
        $finish;
    end

    initial begin : timeout_watchdog
        repeat (5000) @(posedge clk);
        $fatal(1, "C8 line-cache fault/capacity timeout");
    end
endmodule
