`timescale 1ns/1ps

module tb_c1_s8_upsample2_c8;
    localparam integer MAX_WIDTH = 640;
    localparam integer FRAME_COUNT = 7;
    localparam integer TOTAL_INPUT_PIXELS = 1390;
    localparam integer TOTAL_OUTPUT_PIXELS = 5560;
    localparam logic [1:0] START_ERR_NONE = 2'd0;
    localparam logic [1:0] START_ERR_ZERO_DIMENSION = 2'd1;
    localparam logic [1:0] START_ERR_WIDTH_EXCEEDS_MAX = 2'd2;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;
    logic start_valid = 1'b0;
    logic start_ready;
    logic [15:0] cfg_input_width = '0;
    logic [15:0] cfg_input_height = '0;
    logic start_error;
    logic [1:0] start_error_code;
    logic busy;
    logic done;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [63:0] in_data_s8 = '0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [63:0] out_data_s8;
    logic out_sof;
    logic out_eol;
    logic out_eof;
    logic [16:0] out_x;
    logic [16:0] out_y;

    logic [127:0] frame_records [0:FRAME_COUNT-1];
    logic [63:0] input_pixels [0:TOTAL_INPUT_PIXELS-1];
    logic [63:0] expected_pixels [0:TOTAL_OUTPUT_PIXELS-1];
    logic [31:0] source_prng = 32'h41d2_07a5;
    logic [31:0] sink_prng = 32'h9c63_b817;
    integer current_frame = -1;
    integer accepted_inputs = 0;
    integer accepted_outputs = 0;
    integer source_hole_cycles = 0;
    integer input_hold_checks = 0;
    integer output_hold_checks = 0;
    integer output_stall_cycles = 0;
    integer completed_frames = 0;
    integer invalid_start_checks = 0;
    integer abort_checks = 0;

    logic held_input = 1'b0;
    logic [63:0] held_input_data = '0;
    logic held_output = 1'b0;
    logic [63:0] held_output_data = '0;
    logic held_sof = 1'b0;
    logic held_eol = 1'b0;
    logic held_eof = 1'b0;
    logic [16:0] held_x = '0;
    logic [16:0] held_y = '0;

    c1_s8_upsample2_c8 #(
        .MAX_WIDTH(MAX_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic [31:0] prng_next(input [31:0] state);
        logic feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_S8_UPSAMPLE2_C8_FAIL time=%0t frame=%0d: %s",
                     $time, current_frame, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic try_invalid_start(
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [1:0] expected_error
    );
        begin
            @(negedge clk);
            cfg_input_width = width;
            cfg_input_height = height;
            start_valid = 1'b1;
            @(posedge clk);
            if (!(start_valid && start_ready))
                fail("invalid start was not handshaken while idle");
            #1;
            if (!start_error || (start_error_code !== expected_error) ||
                busy || in_ready || out_valid || done)
                fail("invalid start response mismatch");
            invalid_start_checks = invalid_start_checks + 1;
            @(negedge clk);
            start_valid = 1'b0;
            @(posedge clk);
            #1;
            if (start_error || (start_error_code != START_ERR_NONE))
                fail("start_error did not clear after one cycle");
        end
    endtask

    task automatic start_frame(
        input logic [15:0] width,
        input logic [15:0] height
    );
        begin
            @(negedge clk);
            cfg_input_width = width;
            cfg_input_height = height;
            start_valid = 1'b1;
            while (!(start_valid && start_ready))
                @(posedge clk);
            @(posedge clk);
            #1;
            if (!busy || start_error || in_ready !== 1'b1)
                fail("valid start did not enter capture state");
            @(negedge clk);
            start_valid = 1'b0;
            // Prove configuration is snapshotted on the handshake.
            cfg_input_width = 16'hffff;
            cfg_input_height = 16'hffff;
        end
    endtask

    task automatic drive_frame_input(
        input integer input_offset,
        input integer input_count
    );
        integer input_index;
        integer gap_remaining;
        logic fired;
        begin
            input_index = 0;
            gap_remaining = 0;
            @(negedge clk);
            in_data_s8 = input_pixels[input_offset];
            in_valid = 1'b1;
            while (input_index < input_count) begin
                @(posedge clk);
                fired = in_valid && in_ready;
                if (fired) begin
                    accepted_inputs = accepted_inputs + 1;
                    input_index = input_index + 1;
                    source_prng = prng_next(source_prng);
                    gap_remaining = source_prng[1:0];
                end
                @(negedge clk);
                if (input_index >= input_count) begin
                    in_valid = 1'b0;
                end else if (in_valid && !fired) begin
                    // Hold both valid and payload until the engine is ready.
                end else if (gap_remaining > 0) begin
                    in_valid = 1'b0;
                    gap_remaining = gap_remaining - 1;
                    source_hole_cycles = source_hole_cycles + 1;
                end else begin
                    in_data_s8 = input_pixels[input_offset + input_index];
                    in_valid = 1'b1;
                end
            end
        end
    endtask

    task automatic check_frame_output(
        input integer output_offset,
        input integer output_count,
        input integer width,
        input integer height
    );
        integer output_index;
        integer expected_x;
        integer expected_y;
        integer output_width;
        logic expected_sof;
        logic expected_eol;
        logic expected_eof;
        begin
            output_index = 0;
            output_width = width * 2;
            while (output_index < output_count) begin
                @(negedge clk);
                sink_prng = prng_next(sink_prng);
                out_ready = sink_prng[0] && sink_prng[3];
                @(posedge clk);
                if (out_valid && out_ready) begin
                    expected_x = output_index % output_width;
                    expected_y = output_index / output_width;
                    expected_sof = (output_index == 0);
                    expected_eol = (expected_x == output_width - 1);
                    expected_eof = (output_index == output_count - 1);
                    if ((out_data_s8 !==
                         expected_pixels[output_offset + output_index]) ||
                        (out_x !== expected_x) || (out_y !== expected_y) ||
                        (out_sof !== expected_sof) ||
                        (out_eol !== expected_eol) ||
                        (out_eof !== expected_eof))
                        fail("output data/coordinate/frame-marker mismatch");
                    accepted_outputs = accepted_outputs + 1;
                    output_index = output_index + 1;
                    #1;
                    if (expected_eof) begin
                        if (!done || busy)
                            fail("done/busy mismatch after final output handshake");
                    end else if (done || !busy) begin
                        fail("frame retired before final output handshake");
                    end
                end
            end
            @(negedge clk);
            out_ready = 1'b0;
        end
    endtask

    task automatic run_frame(input integer frame_index);
        integer input_offset;
        integer output_offset;
        integer width;
        integer height;
        integer input_count;
        integer output_count;
        begin
            current_frame = frame_index;
            input_offset = frame_records[frame_index][31:0];
            output_offset = frame_records[frame_index][63:32];
            width = frame_records[frame_index][79:64];
            height = frame_records[frame_index][95:80];
            input_count = width * height;
            output_count = input_count * 4;
            start_frame(width, height);
            fork
                drive_frame_input(input_offset, input_count);
                check_frame_output(output_offset, output_count, width, height);
            join
            completed_frames = completed_frames + 1;
        end
    endtask

    task automatic check_abort;
        integer pixel_index;
        begin
            current_frame = -2;
            start_frame(4, 1);
            for (pixel_index = 0; pixel_index < 4;
                 pixel_index = pixel_index + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data_s8 = 64'h0102_0304_0506_0708 + pixel_index;
                while (!(in_valid && in_ready))
                    @(posedge clk);
                @(posedge clk);
            end
            @(negedge clk);
            in_valid = 1'b0;
            out_ready = 1'b0;
            while (!out_valid)
                @(posedge clk);
            repeat (2) @(posedge clk);
            @(negedge clk);
            abort = 1'b1;
            #1;
            if (out_valid || in_ready || start_ready)
                fail("abort did not immediately suppress stream handshakes");
            @(posedge clk);
            #1;
            if (busy || done || out_valid || start_error)
                fail("abort did not clear active frame state");
            abort_checks = abort_checks + 1;
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    // Independent ready/valid payload-stability monitors.
    always @(posedge clk) begin
        if (rst) begin
            held_input = 1'b0;
            held_output = 1'b0;
        end else begin
            if (held_input && !abort) begin
                input_hold_checks = input_hold_checks + 1;
                if (!in_valid || (in_data_s8 !== held_input_data))
                    fail("input payload changed while stalled");
            end
            if (held_output && !abort) begin
                output_hold_checks = output_hold_checks + 1;
                if (!out_valid || (out_data_s8 !== held_output_data) ||
                    (out_sof !== held_sof) || (out_eol !== held_eol) ||
                    (out_eof !== held_eof) || (out_x !== held_x) ||
                    (out_y !== held_y))
                    fail("output payload changed while stalled");
            end
            if (out_valid && !out_ready && !abort)
                output_stall_cycles = output_stall_cycles + 1;
            if (done && busy)
                fail("done and busy asserted together");

            held_input = in_valid && !in_ready && !abort;
            held_input_data = in_data_s8;
            held_output = out_valid && !out_ready && !abort;
            held_output_data = out_data_s8;
            held_sof = out_sof;
            held_eol = out_eol;
            held_eof = out_eof;
            held_x = out_x;
            held_y = out_y;
        end
    end

    initial begin
        integer frame_index;
        $readmemh("upsample2_c8_frames.mem", frame_records);
        $readmemh("upsample2_c8_input.mem", input_pixels);
        $readmemh("upsample2_c8_expected.mem", expected_pixels);
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!start_ready || busy || done || in_ready || out_valid)
            fail("reset/idle contract mismatch");

        try_invalid_start(0, 1, START_ERR_ZERO_DIMENSION);
        try_invalid_start(1, 0, START_ERR_ZERO_DIMENSION);
        try_invalid_start(MAX_WIDTH + 1, 1,
                          START_ERR_WIDTH_EXCEEDS_MAX);
        check_abort();

        for (frame_index = 0; frame_index < FRAME_COUNT;
             frame_index = frame_index + 1)
            run_frame(frame_index);

        if ((completed_frames != FRAME_COUNT) ||
            (accepted_inputs != TOTAL_INPUT_PIXELS) ||
            (accepted_outputs != TOTAL_OUTPUT_PIXELS))
            fail("frame/input/output accounting mismatch");
        if ((invalid_start_checks != 3) || (abort_checks != 1) ||
            (source_hole_cycles == 0) || (input_hold_checks == 0) ||
            (output_hold_checks == 0) || (output_stall_cycles == 0))
            fail("error/abort/random-stall coverage incomplete");

        $display("C1_S8_UPSAMPLE2_C8_PASS frames=%0d input=%0d output=%0d source_holes=%0d input_hold=%0d output_hold=%0d output_stall=%0d line_buffer_bytes=%0d",
                 completed_frames, accepted_inputs, accepted_outputs,
                 source_hole_cycles, input_hold_checks, output_hold_checks,
                 output_stall_cycles, MAX_WIDTH*8);
        $finish;
    end

    initial begin
        #20_000_000;
        fail("global timeout/deadlock");
    end

endmodule
