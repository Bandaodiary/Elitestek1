`timescale 1ns/1ps

module tb_c1_r1_rgb_source_mux;

    localparam integer MAX_PIXELS = 128;
    localparam logic [2:0] ERROR_FIRST_BEAT = 3'd1;
    localparam logic [2:0] ERROR_COORDINATE = 3'd2;
    localparam logic [2:0] ERROR_EOL = 3'd4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;
    logic start_valid = 1'b0;
    logic start_ready;
    logic source_select = 1'b0;
    logic busy;
    logic done;
    logic error;
    logic [2:0] error_code;
    logic [15:0] error_x;
    logic [15:0] error_y;

    logic isp_valid = 1'b0;
    logic isp_ready;
    logic [23:0] isp_rgb888 = 24'd0;
    logic [15:0] isp_x = 16'd0;
    logic [15:0] isp_y = 16'd0;
    logic isp_sof = 1'b0;
    logic isp_eol = 1'b0;
    logic isp_eof = 1'b0;

    logic dma_valid = 1'b0;
    logic dma_ready;
    logic [23:0] dma_rgb888 = 24'd0;
    logic [15:0] dma_x = 16'd0;
    logic [15:0] dma_y = 16'd0;
    logic dma_sof = 1'b0;
    logic dma_eol = 1'b0;
    logic dma_eof = 1'b0;

    logic out_valid;
    logic out_ready;
    logic [23:0] out_rgb888;
    logic [15:0] out_x;
    logic [15:0] out_y;
    logic out_sof;
    logic out_eol;
    logic out_eof;

    logic [23:0] expected_rgb [0:MAX_PIXELS-1];
    logic [15:0] expected_x [0:MAX_PIXELS-1];
    logic [15:0] expected_y [0:MAX_PIXELS-1];
    logic expected_sof [0:MAX_PIXELS-1];
    logic expected_eol [0:MAX_PIXELS-1];
    logic expected_eof [0:MAX_PIXELS-1];
    integer score_count;
    integer score_output_index;
    logic score_active;

    logic [31:0] lfsr = 32'h91e1_0da5;
    logic sink_ready_random = 1'b0;
    logic force_output_block = 1'b0;
    logic previous_output_stall;
    logic [58:0] previous_output_payload;
    logic previous_isp_stall;
    logic [58:0] previous_isp_payload;
    logic previous_dma_stall;
    logic [58:0] previous_dma_payload;
    logic previous_eof_fire;
    logic previous_done;
    logic previous_error;
    logic active_source_model;

    integer start_count = 0;
    integer done_count = 0;
    integer error_count = 0;
    integer abort_count = 0;
    integer isp_accept_count = 0;
    integer dma_accept_count = 0;
    integer output_count = 0;
    integer output_stall_count = 0;
    integer input_stall_count = 0;
    integer input_gap_count = 0;
    integer unselected_isolation_cycles = 0;
    integer live_select_change_count = 0;
    integer eof_stall_count = 0;
    integer restart_count = 0;

    integer index;
    integer guard;
    integer snapshot;
    integer target;

    always #5 clk = ~clk;
    assign out_ready = !force_output_block && sink_ready_random;

    c1_r1_rgb_source_mux dut (.*);

    task automatic prepare_frame(
        input integer pixel_count,
        input integer line_width,
        input integer seed
    );
        integer item;
        begin
            if ((pixel_count <= 0) || (pixel_count > MAX_PIXELS) ||
                ((pixel_count % line_width) != 0))
                $fatal(1, "invalid RGB mux test frame");
            for (item = 0; item < pixel_count; item = item + 1) begin
                expected_rgb[item][23:16] =
                    (seed + item * 31) & 8'hff;
                expected_rgb[item][15:8] =
                    (seed * 3 + item * 67 + 5) & 8'hff;
                expected_rgb[item][7:0] =
                    (seed * 7 + item * 109 + 11) & 8'hff;
                expected_x[item] = item % line_width;
                expected_y[item] = item / line_width;
                expected_sof[item] = (item == 0);
                expected_eol[item] = ((item % line_width) == line_width-1);
                expected_eof[item] = (item == pixel_count-1);
            end
            score_count = pixel_count;
            score_output_index = 0;
            score_active = 1'b1;
        end
    endtask

    task automatic start_job(input logic select_dma);
        integer start_target;
        begin
            source_select = select_dma;
            start_target = start_count + 1;
            @(negedge clk);
            start_valid = 1'b1;
            guard = 0;
            while (start_count < start_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "RGB source mux start timeout");
            end
            start_valid = 1'b0;
            if (!busy || error)
                $fatal(1, "RGB source mux did not enter clean run state");
        end
    endtask

    task automatic drive_raw(
        input logic select_dma,
        input logic [23:0] data_value,
        input logic [15:0] x_value,
        input logic [15:0] y_value,
        input logic sof_value,
        input logic eol_value,
        input logic eof_value,
        input integer gap_cycles
    );
        integer accept_target;
        begin
            repeat (gap_cycles) begin
                @(posedge clk);
                input_gap_count = input_gap_count + 1;
            end

            if (select_dma)
                accept_target = dma_accept_count + 1;
            else
                accept_target = isp_accept_count + 1;

            @(negedge clk);
            if (select_dma) begin
                dma_valid = 1'b1;
                dma_rgb888 = data_value;
                dma_x = x_value;
                dma_y = y_value;
                dma_sof = sof_value;
                dma_eol = eol_value;
                dma_eof = eof_value;
            end else begin
                isp_valid = 1'b1;
                isp_rgb888 = data_value;
                isp_x = x_value;
                isp_y = y_value;
                isp_sof = sof_value;
                isp_eol = eol_value;
                isp_eof = eof_value;
            end

            guard = 0;
            while ((select_dma && (dma_accept_count < accept_target)) ||
                   (!select_dma && (isp_accept_count < accept_target))) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "selected RGB source handshake timeout");
            end

            if (select_dma) begin
                dma_valid = 1'b0;
                dma_rgb888 = 24'd0;
                dma_x = 16'd0;
                dma_y = 16'd0;
                dma_sof = 1'b0;
                dma_eol = 1'b0;
                dma_eof = 1'b0;
            end else begin
                isp_valid = 1'b0;
                isp_rgb888 = 24'd0;
                isp_x = 16'd0;
                isp_y = 16'd0;
                isp_sof = 1'b0;
                isp_eol = 1'b0;
                isp_eof = 1'b0;
            end
        end
    endtask

    task automatic drive_expected(
        input logic select_dma,
        input integer item,
        input integer gap_cycles
    );
        begin
            drive_raw(select_dma, expected_rgb[item], expected_x[item],
                      expected_y[item], expected_sof[item],
                      expected_eol[item], expected_eof[item], gap_cycles);
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            #1;
            if (out_valid || isp_ready || dma_ready)
                $fatal(1, "abort did not immediately fence RGB handshakes");
            @(posedge clk);
            @(negedge clk);
            abort = 1'b0;
            abort_count = abort_count + 1;
            score_active = 1'b0;
            repeat (2) @(posedge clk);
            if (busy || error || out_valid || isp_ready || dma_ready ||
                !start_ready)
                $fatal(1, "abort did not restore RGB mux idle state");
            restart_count = restart_count + 1;
        end
    endtask

    task automatic wait_done(input integer done_target);
        begin
            guard = 0;
            while (done_count < done_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 3000)
                    $fatal(1, "RGB mux done timeout");
            end
            repeat (2) @(posedge clk);
            if (busy || error || out_valid || !start_ready)
                $fatal(1, "RGB mux did not retire to idle");
        end
    endtask

    task automatic expect_frozen_error(
        input logic [2:0] expected_code_value,
        input logic [15:0] expected_x_value,
        input logic [15:0] expected_y_value
    );
        begin
            guard = 0;
            while (!error) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "RGB mux protocol error timeout");
            end
            if (!busy || out_valid || isp_ready || dma_ready || start_ready ||
                (error_code !== expected_code_value) ||
                (error_x !== expected_x_value) ||
                (error_y !== expected_y_value)) begin
                $fatal(1, "RGB mux frozen error mismatch code=%0d x=%0d y=%0d",
                       error_code, error_x, error_y);
            end
            repeat (4) begin
                @(posedge clk);
                #1;
                if (!error || !busy || out_valid || isp_ready || dma_ready)
                    $fatal(1, "RGB mux did not remain frozen on protocol error");
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= 32'h91e1_0da5;
            sink_ready_random <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            sink_ready_random <= lfsr[0] || lfsr[5] || lfsr[11];
        end
    end

    // Isolation, stability and end-to-end payload scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            start_count = 0;
            done_count = 0;
            error_count = 0;
            isp_accept_count = 0;
            dma_accept_count = 0;
            output_count = 0;
            output_stall_count = 0;
            input_stall_count = 0;
            unselected_isolation_cycles = 0;
            previous_output_stall = 1'b0;
            previous_isp_stall = 1'b0;
            previous_dma_stall = 1'b0;
            previous_output_payload = '0;
            previous_isp_payload = '0;
            previous_dma_payload = '0;
            previous_eof_fire = 1'b0;
            previous_done = 1'b0;
            previous_error = 1'b0;
            active_source_model = 1'b0;
        end else begin
            if (previous_output_stall &&
                ({out_eof,out_eol,out_sof,out_y,out_x,out_rgb888} !==
                 previous_output_payload))
                $fatal(1, "RGB mux output changed while stalled");
            if (previous_isp_stall &&
                ({isp_eof,isp_eol,isp_sof,isp_y,isp_x,isp_rgb888} !==
                 previous_isp_payload))
                $fatal(1, "ISP source changed while stalled");
            if (previous_dma_stall &&
                ({dma_eof,dma_eol,dma_sof,dma_y,dma_x,dma_rgb888} !==
                 previous_dma_payload))
                $fatal(1, "DMA source changed while stalled");

            previous_output_stall = out_valid && !out_ready && !abort;
            previous_isp_stall = isp_valid && !isp_ready && !abort;
            previous_dma_stall = dma_valid && !dma_ready && !abort;
            previous_output_payload =
                {out_eof,out_eol,out_sof,out_y,out_x,out_rgb888};
            previous_isp_payload =
                {isp_eof,isp_eol,isp_sof,isp_y,isp_x,isp_rgb888};
            previous_dma_payload =
                {dma_eof,dma_eol,dma_sof,dma_y,dma_x,dma_rgb888};

            if (out_valid && !out_ready && !abort)
                output_stall_count = output_stall_count + 1;
            if ((isp_valid && !isp_ready && !abort) ||
                (dma_valid && !dma_ready && !abort))
                input_stall_count = input_stall_count + 1;

            if (isp_ready && dma_ready)
                $fatal(1, "RGB mux asserted ready to both sources");
            if (busy && !error) begin
                if ((!active_source_model && dma_ready) ||
                    (active_source_model && isp_ready))
                    $fatal(1, "RGB mux asserted unselected-source ready");
                if (dut.source_select_q !== active_source_model)
                    $fatal(1, "live source_select changed the locked source");
                if ((!active_source_model && dma_valid && !dma_ready) ||
                    (active_source_model && isp_valid && !isp_ready))
                    unselected_isolation_cycles =
                        unselected_isolation_cycles + 1;
            end

            if (start_valid && start_ready) begin
                start_count = start_count + 1;
                active_source_model = source_select;
            end
            if (isp_valid && isp_ready)
                isp_accept_count = isp_accept_count + 1;
            if (dma_valid && dma_ready)
                dma_accept_count = dma_accept_count + 1;

            if (out_valid && out_ready) begin
                if (!score_active || score_output_index >= score_count)
                    $fatal(1, "unexpected RGB mux output");
                if ((out_rgb888 !== expected_rgb[score_output_index]) ||
                    (out_x !== expected_x[score_output_index]) ||
                    (out_y !== expected_y[score_output_index]) ||
                    ({out_sof,out_eol,out_eof} !==
                     {expected_sof[score_output_index],
                      expected_eol[score_output_index],
                      expected_eof[score_output_index]})) begin
                    $fatal(1, "RGB mux payload/marker mismatch item=%0d",
                           score_output_index);
                end
                score_output_index = score_output_index + 1;
                output_count = output_count + 1;
            end

            if (done) begin
                if (!previous_eof_fire || !score_active ||
                    (score_output_index != score_count))
                    $fatal(1, "RGB mux done did not follow final EOF handshake");
                done_count = done_count + 1;
                score_active = 1'b0;
            end
            if (done && previous_done)
                $fatal(1, "RGB mux done was not a one-cycle pulse");
            previous_done = done;
            previous_eof_fire = out_valid && out_ready && out_eof;

            if (error && !previous_error)
                error_count = error_count + 1;
            previous_error = error;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        if (!start_ready || busy || done || error || isp_ready || dma_ready)
            $fatal(1, "RGB mux reset state mismatch");

        // ISP-selected frame.  DMA continuously presents poison data, live
        // source_select toggles, and EOF is held under output backpressure.
        prepare_frame(35, 7, 23);
        dma_valid = 1'b1;
        dma_rgb888 = 24'hde_ad_01;
        dma_x = 16'hdead;
        dma_y = 16'hbeef;
        dma_sof = 1'b1;
        dma_eol = 1'b1;
        dma_eof = 1'b1;
        start_job(1'b0);
        for (index = 0; index < 35; index = index + 1) begin
            source_select = index[0];
            live_select_change_count = live_select_change_count + 1;
            drive_expected(1'b0, index, (index * 3 + 1) % 4);
        end
        force_output_block = 1'b1;
        guard = 0;
        while (!(out_valid && out_eof)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 100)
                $fatal(1, "ISP EOF did not reach stalled mux output");
        end
        snapshot = done_count;
        repeat (8) begin
            @(posedge clk);
            eof_stall_count = eof_stall_count + 1;
            #1;
            if (!busy || done || !out_valid || !out_eof ||
                (done_count != snapshot))
                $fatal(1, "RGB mux retired stalled EOF early");
        end
        @(negedge clk);
        force_output_block = 1'b0;
        wait_done(snapshot + 1);
        dma_valid = 1'b0;

        // DMA-selected frame with an ISP poison stream proves the opposite
        // selection and response path.
        prepare_frame(24, 6, 61);
        isp_valid = 1'b1;
        isp_rgb888 = 24'hca_fe_02;
        isp_x = 16'h1111;
        isp_y = 16'h2222;
        isp_sof = 1'b1;
        isp_eol = 1'b1;
        isp_eof = 1'b1;
        start_job(1'b1);
        for (index = 0; index < 24; index = index + 1) begin
            source_select = !index[0];
            live_select_change_count = live_select_change_count + 1;
            drive_expected(1'b1, index, (index * 5 + 2) % 5);
        end
        target = done_count + 1;
        wait_done(target);
        isp_valid = 1'b0;

        // Invalid first beat is consumed and frozen, never emitted.
        score_active = 1'b0;
        start_job(1'b0);
        drive_raw(1'b0, 24'h01_02_03, 16'd1, 16'd0,
                  1'b0, 1'b0, 1'b0, 0);
        expect_frozen_error(ERROR_FIRST_BEAT, 16'd1, 16'd0);
        pulse_abort();

        // Valid first beat followed by a skipped x coordinate.
        prepare_frame(4, 2, 79);
        start_job(1'b1);
        drive_expected(1'b1, 0, 0);
        drive_raw(1'b1, expected_rgb[1], 16'd2, 16'd0,
                  1'b0, 1'b1, 1'b0, 1);
        expect_frozen_error(ERROR_COORDINATE, 16'd2, 16'd0);
        pulse_abort();

        // First EOL establishes width two.  A later missing EOL at x=1 is a
        // marker/raster error and freezes before the malformed beat escapes.
        prepare_frame(4, 2, 97);
        start_job(1'b0);
        drive_expected(1'b0, 0, 0);
        drive_expected(1'b0, 1, 1);
        drive_expected(1'b0, 2, 0);
        drive_raw(1'b0, expected_rgb[3], 16'd1, 16'd1,
                  1'b0, 1'b0, 1'b0, 0);
        expect_frozen_error(ERROR_EOL, 16'd1, 16'd1);
        pulse_abort();

        // Abort a legal pending beat while the output is stalled.  It must be
        // discarded without done/error and both sources must become restartable.
        prepare_frame(4, 2, 111);
        start_job(1'b0);
        drive_expected(1'b0, 0, 0);
        force_output_block = 1'b1;
        guard = 0;
        while (!out_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 50)
                $fatal(1, "abort test did not hold a pending output");
        end
        snapshot = done_count;
        pulse_abort();
        force_output_block = 1'b0;
        if (done_count != snapshot)
            $fatal(1, "abort incorrectly produced done");

        // Clean restart after every frozen/error and pending-output abort.
        prepare_frame(15, 5, 137);
        start_job(1'b1);
        for (index = 0; index < 15; index = index + 1)
            drive_expected(1'b1, index, (index * 7 + 3) % 6);
        target = done_count + 1;
        wait_done(target);

        repeat (8) @(posedge clk);
        if ((start_count != 7) || (done_count != 3) ||
            (error_count != 3) || (abort_count != 4) ||
            (isp_accept_count != 41) || (dma_accept_count != 41) ||
            (output_count != 78) || (output_stall_count == 0) ||
            (input_stall_count == 0) || (input_gap_count == 0) ||
            (unselected_isolation_cycles == 0) ||
            (live_select_change_count != 59) ||
            (eof_stall_count != 8) || (restart_count != 4) ||
            busy || error || out_valid || isp_ready || dma_ready) begin
            $fatal(1, "RGB mux coverage mismatch starts=%0d done=%0d errors=%0d aborts=%0d isp=%0d dma=%0d out=%0d out_stall=%0d in_stall=%0d isolation=%0d live_select=%0d eof_stall=%0d restart=%0d",
                   start_count, done_count, error_count, abort_count,
                   isp_accept_count, dma_accept_count, output_count,
                   output_stall_count, input_stall_count,
                   unselected_isolation_cycles, live_select_change_count,
                   eof_stall_count, restart_count);
        end

        $display("C1_R1_RGB_SOURCE_MUX_PASS starts=%0d done=%0d errors=%0d aborts=%0d isp=%0d dma=%0d outputs=%0d output_stalls=%0d input_stalls=%0d gaps=%0d isolation=%0d live_select=%0d eof_stalls=%0d restarts=%0d",
                 start_count, done_count, error_count, abort_count,
                 isp_accept_count, dma_accept_count, output_count,
                 output_stall_count, input_stall_count, input_gap_count,
                 unselected_isolation_cycles, live_select_change_count,
                 eof_stall_count, restart_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "global R1 RGB-source-mux testbench timeout");
    end

endmodule
