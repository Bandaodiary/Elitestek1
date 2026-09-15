`timescale 1ns/1ps

module tb_c1_residual_add_c8;
    localparam integer X_BITS = 16;
    localparam integer Y_BITS = 16;
    localparam integer FRAME_COUNT = 6;
    localparam integer TOTAL_PIXELS = 149;
    localparam logic [1:0] ERROR_NONE = 2'd0;
    localparam logic [1:0] ERROR_COORDINATE = 2'd1;
    localparam logic [1:0] ERROR_MARKER = 2'd2;
    localparam logic [1:0] ERROR_COORDINATE_AND_MARKER = 2'd3;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;
    logic start_valid = 1'b0;
    logic start_ready;
    logic cfg_relu = 1'b0;
    logic busy;
    logic done;
    logic error_pulse;
    logic [1:0] error_code;

    logic main_valid = 1'b0;
    logic main_ready;
    logic [63:0] main_data_s8 = '0;
    logic [X_BITS-1:0] main_x = '0;
    logic [Y_BITS-1:0] main_y = '0;
    logic main_sof = 1'b0;
    logic main_eol = 1'b0;
    logic main_eof = 1'b0;
    logic skip_valid = 1'b0;
    logic skip_ready;
    logic [63:0] skip_data_s8 = '0;
    logic [X_BITS-1:0] skip_x = '0;
    logic [Y_BITS-1:0] skip_y = '0;
    logic skip_sof = 1'b0;
    logic skip_eol = 1'b0;
    logic skip_eof = 1'b0;

    logic out_valid;
    logic out_ready = 1'b0;
    logic [63:0] out_data_s8;
    logic [X_BITS-1:0] out_x;
    logic [Y_BITS-1:0] out_y;
    logic out_sof;
    logic out_eol;
    logic out_eof;

    logic [127:0] frame_records [0:FRAME_COUNT-1];
    logic [63:0] main_pixels [0:TOTAL_PIXELS-1];
    logic [63:0] skip_pixels [0:TOTAL_PIXELS-1];
    logic [63:0] expected_pixels [0:TOTAL_PIXELS-1];
    logic [31:0] main_prng = 32'h7a15_0c93;
    logic [31:0] skip_prng = 32'hd04b_6281;
    logic [31:0] sink_prng = 32'h35e9_a417;

    integer current_frame = -1;
    integer accepted_main = 0;
    integer accepted_skip = 0;
    integer accepted_output = 0;
    integer main_hole_cycles = 0;
    integer skip_hole_cycles = 0;
    integer main_hold_checks = 0;
    integer skip_hold_checks = 0;
    integer output_hold_checks = 0;
    integer output_stall_cycles = 0;
    integer main_only_accepts = 0;
    integer skip_only_accepts = 0;
    integer full_rate_overlap_cycles = 0;
    integer completed_frames = 0;
    integer mismatch_checks = 0;
    integer abort_checks = 0;

    logic held_main = 1'b0;
    logic [98:0] held_main_payload = '0;
    logic held_skip = 1'b0;
    logic [98:0] held_skip_payload = '0;
    logic held_output = 1'b0;
    logic [98:0] held_output_payload = '0;

    c1_residual_add_c8 #(
        .X_BITS(X_BITS), .Y_BITS(Y_BITS)
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
            $display("C1_RESIDUAL_ADD_C8_FAIL time=%0t frame=%0d: %s",
                     $time, current_frame, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic start_frame(input logic relu);
        logic accepted;
        begin
            @(negedge clk);
            cfg_relu = relu;
            start_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (start_valid && start_ready)
                    accepted = 1'b1;
            end
            #1;
            if (!busy || !main_ready || !skip_ready || done || error_pulse)
                fail("start did not enter active empty-buffer state");
            @(negedge clk);
            start_valid = 1'b0;
            cfg_relu = ~relu;
        end
    endtask

    task automatic set_side_payload(
        input integer side,
        input integer pixel_offset,
        input integer pixel_index,
        input integer pixel_count,
        input integer width
    );
        integer x_value;
        integer y_value;
        begin
            x_value = pixel_index % width;
            y_value = pixel_index / width;
            if (side == 0) begin
                main_data_s8 = main_pixels[pixel_offset + pixel_index];
                main_x = x_value;
                main_y = y_value;
                main_sof = (pixel_index == 0);
                main_eol = (x_value == width - 1);
                main_eof = (pixel_index == pixel_count - 1);
                main_valid = 1'b1;
            end else begin
                skip_data_s8 = skip_pixels[pixel_offset + pixel_index];
                skip_x = x_value;
                skip_y = y_value;
                skip_sof = (pixel_index == 0);
                skip_eol = (x_value == width - 1);
                skip_eof = (pixel_index == pixel_count - 1);
                skip_valid = 1'b1;
            end
        end
    endtask

    task automatic drive_side(
        input integer side,
        input integer pixel_offset,
        input integer pixel_count,
        input integer width
    );
        integer pixel_index;
        integer gap_remaining;
        logic fired;
        logic currently_valid;
        begin
            pixel_index = 0;
            gap_remaining = 0;
            @(negedge clk);
            set_side_payload(side, pixel_offset, 0, pixel_count, width);
            while (pixel_index < pixel_count) begin
                @(posedge clk);
                if (side == 0)
                    fired = main_valid && main_ready;
                else
                    fired = skip_valid && skip_ready;
                if (fired) begin
                    pixel_index = pixel_index + 1;
                    if (side == 0) begin
                        accepted_main = accepted_main + 1;
                        main_prng = prng_next(main_prng);
                        gap_remaining = main_prng[2:0] % 5;
                    end else begin
                        accepted_skip = accepted_skip + 1;
                        skip_prng = prng_next(skip_prng);
                        gap_remaining = skip_prng[2:0] % 5;
                    end
                end
                @(negedge clk);
                currently_valid = (side == 0) ? main_valid : skip_valid;
                if (pixel_index >= pixel_count) begin
                    if (side == 0)
                        main_valid = 1'b0;
                    else
                        skip_valid = 1'b0;
                end else if (currently_valid && !fired) begin
                    // Hold this side while its one-beat skid buffer is full.
                end else if (gap_remaining > 0) begin
                    if (side == 0) begin
                        main_valid = 1'b0;
                        main_hole_cycles = main_hole_cycles + 1;
                    end else begin
                        skip_valid = 1'b0;
                        skip_hole_cycles = skip_hole_cycles + 1;
                    end
                    gap_remaining = gap_remaining - 1;
                end else begin
                    set_side_payload(side, pixel_offset, pixel_index,
                                     pixel_count, width);
                end
            end
        end
    endtask

    task automatic check_outputs(
        input integer pixel_offset,
        input integer pixel_count,
        input integer width
    );
        integer pixel_index;
        integer expected_x;
        integer expected_y;
        logic expected_sof;
        logic expected_eol;
        logic expected_eof;
        begin
            pixel_index = 0;
            while (pixel_index < pixel_count) begin
                @(negedge clk);
                sink_prng = prng_next(sink_prng);
                out_ready = sink_prng[0] && sink_prng[3];
                @(posedge clk);
                if (out_valid && out_ready) begin
                    expected_x = pixel_index % width;
                    expected_y = pixel_index / width;
                    expected_sof = (pixel_index == 0);
                    expected_eol = (expected_x == width - 1);
                    expected_eof = (pixel_index == pixel_count - 1);
                    if ((out_data_s8 !== expected_pixels[pixel_offset + pixel_index]) ||
                        (out_x !== expected_x) || (out_y !== expected_y) ||
                        (out_sof !== expected_sof) ||
                        (out_eol !== expected_eol) ||
                        (out_eof !== expected_eof))
                        fail("residual data/coordinate/marker mismatch");
                    accepted_output = accepted_output + 1;
                    pixel_index = pixel_index + 1;
                    #1;
                    if (expected_eof) begin
                        if (!done || busy)
                            fail("done/busy mismatch on EOF output handshake");
                    end else if (done || !busy) begin
                        fail("frame retired before EOF output handshake");
                    end
                end
            end
            @(negedge clk);
            out_ready = 1'b0;
        end
    endtask

    task automatic run_frame(input integer frame_index);
        integer pixel_offset;
        integer pixel_count;
        integer width;
        integer relu;
        begin
            current_frame = frame_index;
            pixel_offset = frame_records[frame_index][31:0];
            pixel_count = frame_records[frame_index][63:32];
            width = frame_records[frame_index][79:64];
            relu = frame_records[frame_index][96];
            start_frame(relu);
            fork
                drive_side(0, pixel_offset, pixel_count, width);
                drive_side(1, pixel_offset, pixel_count, width);
                check_outputs(pixel_offset, pixel_count, width);
            join
            completed_frames = completed_frames + 1;
        end
    endtask

    task automatic inject_mismatch(
        input logic coordinate_bad,
        input logic marker_bad,
        input logic [1:0] expected_code
    );
        begin
            current_frame = -2 - expected_code;
            start_frame(1'b0);
            @(negedge clk);
            main_valid = 1'b1;
            main_data_s8 = 64'h7f80_00ff_0102_0304;
            main_x = 16'd0;
            main_y = 16'd0;
            main_sof = 1'b1;
            main_eol = 1'b1;
            main_eof = 1'b1;
            skip_valid = 1'b1;
            skip_data_s8 = 64'h0102_0304_0506_0708;
            skip_x = coordinate_bad ? 16'd1 : 16'd0;
            skip_y = 16'd0;
            skip_sof = 1'b1;
            skip_eol = marker_bad ? 1'b0 : 1'b1;
            skip_eof = 1'b1;
            @(posedge clk);
            if (!(main_valid && main_ready && skip_valid && skip_ready))
                fail("mismatch pair was not captured into both skid buffers");
            @(negedge clk);
            main_valid = 1'b0;
            skip_valid = 1'b0;
            @(posedge clk);
            #1;
            if (!error_pulse || (error_code !== expected_code) || busy ||
                done || out_valid)
                fail("mismatch drop/frame-abort policy mismatch");
            mismatch_checks = mismatch_checks + 1;
            @(posedge clk);
            #1;
            if (error_pulse || (error_code != ERROR_NONE) || !start_ready)
                fail("mismatch error did not clear/re-arm start");
        end
    endtask

    task automatic check_stalled_mismatch;
        begin
            current_frame=-8;
            start_frame(1'b0);
            @(negedge clk);
            out_ready=0;
            main_valid=1; skip_valid=1;
            main_data_s8={8{8'd3}}; skip_data_s8={8{8'd4}};
            main_x=0; skip_x=0; main_y=0; skip_y=0;
            main_sof=1; skip_sof=1;
            main_eol=0; skip_eol=0; main_eof=0; skip_eof=0;
            @(posedge clk);
            if(!main_ready || !skip_ready) fail("first pair not accepted");
            @(negedge clk); main_valid=0; skip_valid=0;
            wait(out_valid);
            @(negedge clk);
            main_valid=1; skip_valid=1;
            main_x=1; skip_x=2; main_sof=0; skip_sof=0;
            @(posedge clk);
            if(!main_ready || !skip_ready) fail("bad pair not buffered behind stalled output");
            @(negedge clk); main_valid=0; skip_valid=0;
            repeat(5) begin
                @(negedge clk);
                if(!out_valid || out_data_s8!=={8{8'd7}} || out_x!=0 ||
                   !out_sof || error_pulse || !busy || main_ready || skip_ready)
                    fail("mismatch bypassed/stole previous stalled result");
            end
            out_ready=1;
            @(posedge clk);
            if(!out_valid || out_data_s8!=={8{8'd7}})
                fail("previous valid result not retired before mismatch");
            #1;
            if(!error_pulse || error_code!=ERROR_COORDINATE || busy || done || out_valid)
                fail("buffered mismatch did not terminate after previous output retirement");
            @(negedge clk); out_ready=0;
            @(posedge clk); #1;
            if(error_pulse || !start_ready) fail("stalled mismatch did not rearm");
            $display("C1_RESIDUAL_STALLED_MISMATCH_PASS prior_output_preserved=1");
        end
    endtask

    task automatic check_abort;
        begin
            current_frame = -6;
            start_frame(1'b1);
            @(negedge clk);
            main_valid = 1'b1;
            main_data_s8 = 64'h8080_8080_7f7f_7f7f;
            main_x = 0;
            main_y = 0;
            main_sof = 1'b1;
            main_eol = 1'b0;
            main_eof = 1'b0;
            @(posedge clk);
            if (!(main_valid && main_ready))
                fail("orphan main token was not captured before abort");
            @(negedge clk);
            main_valid = 1'b0;
            abort = 1'b1;
            #1;
            if (main_ready || skip_ready || start_ready)
                fail("abort did not suppress handshakes");
            @(posedge clk);
            #1;
            if (busy || done || out_valid || error_pulse)
                fail("abort did not clear buffered orphan/frame state");
            abort_checks = abort_checks + 1;
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        logic main_fire;
        logic skip_fire;
        main_fire = main_valid && main_ready;
        skip_fire = skip_valid && skip_ready;
        if (rst) begin
            held_main = 1'b0;
            held_skip = 1'b0;
            held_output = 1'b0;
        end else begin
            if (held_main && !abort) begin
                main_hold_checks = main_hold_checks + 1;
                if (!main_valid ||
                    ({main_eof, main_eol, main_sof, main_y, main_x,
                      main_data_s8} !== held_main_payload))
                    fail("main payload changed while stalled");
            end
            if (held_skip && !abort) begin
                skip_hold_checks = skip_hold_checks + 1;
                if (!skip_valid ||
                    ({skip_eof, skip_eol, skip_sof, skip_y, skip_x,
                      skip_data_s8} !== held_skip_payload))
                    fail("skip payload changed while stalled");
            end
            if (held_output && !abort) begin
                output_hold_checks = output_hold_checks + 1;
                if (!out_valid ||
                    ({out_eof, out_eol, out_sof, out_y, out_x,
                      out_data_s8} !== held_output_payload))
                    fail("output payload changed while stalled");
            end
            if (out_valid && !out_ready && !abort)
                output_stall_cycles = output_stall_cycles + 1;
            if (main_fire && !skip_fire)
                main_only_accepts = main_only_accepts + 1;
            if (skip_fire && !main_fire)
                skip_only_accepts = skip_only_accepts + 1;
            if (main_fire && skip_fire && out_valid && out_ready)
                full_rate_overlap_cycles = full_rate_overlap_cycles + 1;
            if (done && busy)
                fail("done and busy asserted together");

            held_main = main_valid && !main_ready && !abort;
            held_main_payload = {main_eof, main_eol, main_sof,
                                 main_y, main_x, main_data_s8};
            held_skip = skip_valid && !skip_ready && !abort;
            held_skip_payload = {skip_eof, skip_eol, skip_sof,
                                 skip_y, skip_x, skip_data_s8};
            held_output = out_valid && !out_ready && !abort;
            held_output_payload = {out_eof, out_eol, out_sof,
                                   out_y, out_x, out_data_s8};
        end
    end

    initial begin
        integer frame_index;
        $readmemh("residual_add_c8_frames.mem", frame_records);
        $readmemh("residual_add_c8_main.mem", main_pixels);
        $readmemh("residual_add_c8_skip.mem", skip_pixels);
        $readmemh("residual_add_c8_expected.mem", expected_pixels);
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!start_ready || busy || done || main_ready || skip_ready ||
            out_valid || error_pulse)
            fail("reset/idle contract mismatch");

        inject_mismatch(1'b1, 1'b0, ERROR_COORDINATE);
        inject_mismatch(1'b0, 1'b1, ERROR_MARKER);
        inject_mismatch(1'b1, 1'b1, ERROR_COORDINATE_AND_MARKER);
        check_abort();
        check_stalled_mismatch();

        for (frame_index = 0; frame_index < FRAME_COUNT;
             frame_index = frame_index + 1)
            run_frame(frame_index);

        if ((completed_frames != FRAME_COUNT) ||
            (accepted_main != TOTAL_PIXELS) ||
            (accepted_skip != TOTAL_PIXELS) ||
            (accepted_output != TOTAL_PIXELS))
            fail("frame/input/output accounting mismatch");
        if ((mismatch_checks != 3) || (abort_checks != 1) ||
            (main_hole_cycles == 0) || (skip_hole_cycles == 0) ||
            (main_hold_checks == 0) || (skip_hold_checks == 0) ||
            (output_hold_checks == 0) || (output_stall_cycles == 0) ||
            (main_only_accepts == 0) || (skip_only_accepts == 0) ||
            (full_rate_overlap_cycles == 0))
            fail("gap/skid/stall/mismatch/throughput coverage incomplete");

        $display("C1_RESIDUAL_ADD_C8_PASS frames=%0d pixels=%0d main_holes=%0d skip_holes=%0d main_hold=%0d skip_hold=%0d output_hold=%0d output_stall=%0d main_leads=%0d skip_leads=%0d full_rate=%0d",
                 completed_frames, accepted_output, main_hole_cycles,
                 skip_hole_cycles, main_hold_checks, skip_hold_checks,
                 output_hold_checks, output_stall_cycles,
                 main_only_accepts, skip_only_accepts,
                 full_rate_overlap_cycles);
        $finish;
    end

    initial begin
        #10_000_000;
        fail("global timeout/deadlock");
    end

endmodule
