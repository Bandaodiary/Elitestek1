`timescale 1ns/1ps

module tb_c1_r1_compute_egress;

    localparam integer X_BITS = 8;
    localparam integer Y_BITS = 8;
    localparam integer MAX_PIXELS = 256;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;

    logic start_valid = 1'b0;
    logic start_ready;
    logic busy;
    logic done;

    logic in_valid = 1'b0;
    logic in_ready;
    logic [63:0] in_data_s8 = 64'd0;
    logic [X_BITS-1:0] in_x = '0;
    logic [Y_BITS-1:0] in_y = '0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;

    logic out_valid;
    logic out_ready;
    logic [23:0] out_rgb888;
    logic [X_BITS-1:0] out_x;
    logic [Y_BITS-1:0] out_y;
    logic out_sof;
    logic out_eol;
    logic out_eof;
    logic padding_nonzero_pulse;

    logic [63:0] expected_input [0:MAX_PIXELS-1];
    logic [23:0] expected_rgb [0:MAX_PIXELS-1];
    logic [X_BITS-1:0] expected_x [0:MAX_PIXELS-1];
    logic [Y_BITS-1:0] expected_y [0:MAX_PIXELS-1];
    logic expected_sof [0:MAX_PIXELS-1];
    logic expected_eol [0:MAX_PIXELS-1];
    logic expected_eof [0:MAX_PIXELS-1];
    logic expected_padding [0:MAX_PIXELS-1];

    integer score_count;
    integer score_input_index;
    integer score_output_index;
    logic score_active;

    integer start_count = 0;
    integer input_count = 0;
    integer output_count = 0;
    integer done_count = 0;
    integer padding_expected_count = 0;
    integer padding_pulse_count = 0;
    integer input_stall_count = 0;
    integer output_stall_count = 0;
    integer input_gap_count = 0;
    integer eof_stall_count = 0;
    integer restart_count = 0;

    logic [31:0] lfsr = 32'h6d2b_79f5;
    logic sink_ready_random = 1'b0;
    logic force_output_block = 1'b0;
    logic previous_input_stall;
    logic previous_output_stall;
    logic [67+X_BITS+Y_BITS-1:0] previous_input_payload;
    logic [27+X_BITS+Y_BITS-1:0] previous_output_payload;
    logic previous_padding_expected;
    logic previous_eof_fire;
    logic previous_done;

    integer index;
    integer target;
    integer terminal_snapshot;
    integer guard;

    always #5 clk = ~clk;
    assign out_ready = !force_output_block && sink_ready_random;

    c1_r1_compute_egress #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS),
        .ENABLE_PADDING_DIAGNOSTIC(1'b1)
    ) dut (.*);

    task automatic prepare_frame(
        input integer pixel_count,
        input integer line_width,
        input integer seed
    );
        integer item;
        logic [63:0] beat;
        begin
            if ((pixel_count <= 0) || (pixel_count > MAX_PIXELS) ||
                ((pixel_count % line_width) != 0))
                $fatal(1, "invalid test frame dimensions");

            for (item = 0; item < pixel_count; item = item + 1) begin
                beat = 64'd0;
                case (item)
                    0: begin
                        beat[7:0] = 8'h80;  // R=-128
                        beat[15:8] = 8'hff; // G=-1
                        beat[23:16] = 8'h00;// B=0
                    end
                    1: begin
                        beat[7:0] = 8'h7f;  // R=127
                        beat[15:8] = 8'h80;
                        beat[23:16] = 8'hff;
                    end
                    2: begin
                        beat[7:0] = 8'h00;
                        beat[15:8] = 8'h7f;
                        beat[23:16] = 8'h80;
                    end
                    3: begin
                        beat[7:0] = 8'hff;
                        beat[15:8] = 8'h00;
                        beat[23:16] = 8'h7f;
                    end
                    default: begin
                        beat[7:0] = (seed + item * 37) & 8'hff;
                        beat[15:8] = (seed * 3 + item * 71 + 9) & 8'hff;
                        beat[23:16] = (seed * 5 + item * 113 + 17) & 8'hff;
                    end
                endcase

                // Deliberately non-zero padding must be diagnosed but never
                // contaminate RGB or alter ready/valid behavior.
                if ((item % 9) == 4)
                    beat[31:24] = 8'h01 + item[7:0];
                if ((item % 17) == 0)
                    beat[63:56] = 8'h80 ^ item[7:0];

                expected_input[item] = beat;
                expected_rgb[item] = {beat[7:0] ^ 8'h80,
                                      beat[15:8] ^ 8'h80,
                                      beat[23:16] ^ 8'h80};
                expected_x[item] = item % line_width;
                expected_y[item] = item / line_width;
                expected_sof[item] = (item == 0);
                expected_eol[item] = ((item % line_width) == line_width-1);
                expected_eof[item] = (item == pixel_count-1);
                expected_padding[item] = |beat[63:24];
            end

            score_count = pixel_count;
            score_input_index = 0;
            score_output_index = 0;
            score_active = 1'b1;
        end
    endtask

    task automatic start_frame;
        integer start_target;
        begin
            start_target = start_count + 1;
            @(negedge clk);
            start_valid = 1'b1;
            guard = 0;
            while (start_count < start_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "egress start timeout");
            end
            start_valid = 1'b0;
            if (!busy)
                $fatal(1, "egress did not become busy after start");
        end
    endtask

    task automatic attempt_duplicate_start;
        integer snapshot;
        begin
            snapshot = start_count;
            @(negedge clk);
            start_valid = 1'b1;
            repeat (3) begin
                @(posedge clk);
                #1;
                if (start_ready)
                    $fatal(1, "egress exposed start_ready while busy");
            end
            @(negedge clk);
            start_valid = 1'b0;
            if (start_count != snapshot)
                $fatal(1, "egress accepted duplicate start");
        end
    endtask

    task automatic drive_beat(
        input integer item,
        input integer gap_cycles
    );
        integer input_target;
        begin
            repeat (gap_cycles) begin
                @(posedge clk);
                input_gap_count = input_gap_count + 1;
            end
            input_target = input_count + 1;
            @(negedge clk);
            in_valid = 1'b1;
            in_data_s8 = expected_input[item];
            in_x = expected_x[item];
            in_y = expected_y[item];
            in_sof = expected_sof[item];
            in_eol = expected_eol[item];
            in_eof = expected_eof[item];
            guard = 0;
            while (input_count < input_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "input handshake timeout item=%0d", item);
            end
            in_valid = 1'b0;
            in_data_s8 = 64'd0;
            in_x = '0;
            in_y = '0;
            in_sof = 1'b0;
            in_eol = 1'b0;
            in_eof = 1'b0;
        end
    endtask

    task automatic wait_done(input integer done_target);
        begin
            guard = 0;
            while (done_count < done_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "egress done timeout target=%0d", done_target);
            end
            repeat (2) @(posedge clk);
            if (busy || out_valid || !start_ready)
                $fatal(1, "egress did not return to restartable idle");
        end
    endtask

    // Pseudo-random sink readiness.  Directed force_output_block takes
    // combinational priority for exact EOF-stall and abort coverage.
    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= 32'h6d2b_79f5;
            sink_ready_random <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            sink_ready_random <= lfsr[0] || lfsr[3] || lfsr[7];
        end
    end

    // Bit-exact stream scoreboard and ready/valid stability checks.
    always @(posedge clk) begin
        if (rst) begin
            start_count = 0;
            input_count = 0;
            output_count = 0;
            done_count = 0;
            padding_expected_count = 0;
            padding_pulse_count = 0;
            input_stall_count = 0;
            output_stall_count = 0;
            previous_input_stall = 1'b0;
            previous_output_stall = 1'b0;
            previous_input_payload = '0;
            previous_output_payload = '0;
            previous_padding_expected = 1'b0;
            previous_eof_fire = 1'b0;
            previous_done = 1'b0;
        end else begin
            if (previous_input_stall &&
                ({in_eof,in_eol,in_sof,in_y,in_x,in_data_s8} !==
                 previous_input_payload))
                $fatal(1, "egress input payload changed under backpressure");
            if (previous_output_stall &&
                ({out_eof,out_eol,out_sof,out_y,out_x,out_rgb888} !==
                 previous_output_payload))
                $fatal(1, "egress output payload changed under backpressure");

            previous_input_stall = in_valid && !in_ready && !abort;
            previous_output_stall = out_valid && !out_ready && !abort;
            previous_input_payload =
                {in_eof,in_eol,in_sof,in_y,in_x,in_data_s8};
            previous_output_payload =
                {out_eof,out_eol,out_sof,out_y,out_x,out_rgb888};
            if (in_valid && !in_ready && !abort)
                input_stall_count = input_stall_count + 1;
            if (out_valid && !out_ready && !abort)
                output_stall_count = output_stall_count + 1;

            if (start_valid && start_ready)
                start_count = start_count + 1;

            if (in_valid && in_ready) begin
                if (!score_active || score_input_index >= score_count)
                    $fatal(1, "unexpected egress input handshake");
                if ((in_data_s8 !== expected_input[score_input_index]) ||
                    (in_x !== expected_x[score_input_index]) ||
                    (in_y !== expected_y[score_input_index]) ||
                    ({in_sof,in_eol,in_eof} !==
                     {expected_sof[score_input_index],
                      expected_eol[score_input_index],
                      expected_eof[score_input_index]}))
                    $fatal(1, "egress input stimulus mismatch item=%0d",
                           score_input_index);
                if (expected_padding[score_input_index])
                    padding_expected_count = padding_expected_count + 1;
                score_input_index = score_input_index + 1;
                input_count = input_count + 1;
            end

            if (out_valid && out_ready) begin
                if (!score_active || score_output_index >= score_count)
                    $fatal(1, "unexpected egress output handshake");
                if ((out_rgb888 !== expected_rgb[score_output_index]) ||
                    (out_x !== expected_x[score_output_index]) ||
                    (out_y !== expected_y[score_output_index]) ||
                    ({out_sof,out_eol,out_eof} !==
                     {expected_sof[score_output_index],
                      expected_eol[score_output_index],
                      expected_eof[score_output_index]})) begin
                    $fatal(1, "RGB/coordinate/marker mismatch item=%0d got=%06x",
                           score_output_index, out_rgb888);
                end
                score_output_index = score_output_index + 1;
                output_count = output_count + 1;
            end

            if (padding_nonzero_pulse) begin
                if (!previous_padding_expected)
                    $fatal(1, "padding diagnostic pulse lacked matching input");
                padding_pulse_count = padding_pulse_count + 1;
            end
            previous_padding_expected = in_valid && in_ready &&
                                        (|in_data_s8[63:24]);

            if (done) begin
                if (!previous_eof_fire)
                    $fatal(1, "done was not caused by an EOF output handshake");
                if (!score_active || (score_input_index != score_count) ||
                    (score_output_index != score_count))
                    $fatal(1, "done preceded complete frame retirement");
                done_count = done_count + 1;
                score_active = 1'b0;
            end
            if (done && previous_done)
                $fatal(1, "done was not a one-cycle pulse");
            previous_done = done;
            previous_eof_fire = out_valid && out_ready && out_eof;

            if (!busy && (in_ready || out_valid))
                $fatal(1, "egress exposed stream handshake while idle");
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        if (!start_ready || busy || done || in_ready || out_valid)
            $fatal(1, "egress reset state mismatch");

        // Valid input cannot escape before a frame start.
        @(negedge clk);
        in_valid = 1'b1;
        in_data_s8 = 64'h0102_0304_0500_ff80;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (in_ready || out_valid || busy)
                $fatal(1, "egress accepted data before start");
        end
        @(negedge clk);
        in_valid = 1'b0;

        // Boundary values and a larger random stream.  The final output is
        // deliberately stalled for ten cycles; done must remain low.
        prepare_frame(68, 17, 19);
        start_frame();
        for (index = 0; index < 68; index = index + 1) begin
            drive_beat(index, (index * 3 + 1) % 4);
            if (index == 7)
                attempt_duplicate_start();
        end
        force_output_block = 1'b1;
        guard = 0;
        while (!(out_valid && out_eof)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 200)
                $fatal(1, "EOF did not reach held output");
        end
        terminal_snapshot = done_count;
        repeat (10) begin
            @(posedge clk);
            eof_stall_count = eof_stall_count + 1;
            #1;
            if (!busy || done || !out_valid || !out_eof ||
                (done_count != terminal_snapshot))
                $fatal(1, "EOF stall retired the frame early");
        end
        @(negedge clk);
        force_output_block = 1'b0;
        wait_done(terminal_snapshot + 1);

        // Abort while a converted beat is pending and stalled.  Pending output
        // is discarded, no done is emitted, and restart is immediately legal.
        prepare_frame(16, 4, 73);
        start_frame();
        drive_beat(0, 0);
        force_output_block = 1'b1;
        guard = 0;
        while (!out_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 50)
                $fatal(1, "abort test did not create pending output");
        end
        terminal_snapshot = done_count;
        abort = 1'b1;
        #1;
        if (out_valid || in_ready)
            $fatal(1, "abort did not suppress stream handshakes immediately");
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        force_output_block = 1'b0;
        score_active = 1'b0;
        repeat (2) @(posedge clk);
        if (busy || out_valid || done || !start_ready ||
            (done_count != terminal_snapshot))
            $fatal(1, "abort did not discard pending egress state");
        restart_count = restart_count + 1;

        // Full restart with long randomized gaps/stalls and many padding
        // diagnostics.  Lane 3..7 contents never enter expected RGB.
        prepare_frame(221, 13, 151);
        start_frame();
        for (index = 0; index < 221; index = index + 1)
            drive_beat(index, (index * 5 + 2) % 6);
        target = done_count + 1;
        wait_done(target);

        repeat (8) @(posedge clk);
        if ((start_count != 3) || (done_count != 2) ||
            (input_count != 290) || (output_count != 289) ||
            (padding_pulse_count != padding_expected_count) ||
            (padding_pulse_count == 0) || (input_stall_count == 0) ||
            (output_stall_count == 0) || (input_gap_count == 0) ||
            (eof_stall_count != 10) || (restart_count != 1) ||
            busy || out_valid || in_valid) begin
            $fatal(1, "egress coverage mismatch starts=%0d done=%0d in=%0d out=%0d pad=%0d/%0d in_stall=%0d out_stall=%0d gaps=%0d eof_stall=%0d",
                   start_count, done_count, input_count, output_count,
                   padding_pulse_count, padding_expected_count,
                   input_stall_count, output_stall_count,
                   input_gap_count, eof_stall_count);
        end

        $display("C1_R1_COMPUTE_EGRESS_PASS starts=%0d done=%0d inputs=%0d outputs=%0d padding=%0d input_stalls=%0d output_stalls=%0d gaps=%0d eof_stalls=%0d restarts=%0d",
                 start_count, done_count, input_count, output_count,
                 padding_pulse_count, input_stall_count,
                 output_stall_count, input_gap_count,
                 eof_stall_count, restart_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "global R1 compute-egress testbench timeout");
    end

endmodule
