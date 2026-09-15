`timescale 1ns/1ps

module tb_c1_r1_compute_shell;

    localparam integer MAX_WIDTH = 16;
    localparam integer MAX_PIXELS = 128;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start_valid = 1'b0;
    logic start_ready;
    logic abort = 1'b0;
    logic source_select = 1'b0;

    logic [15:0] cfg_win = 16'd0;
    logic [15:0] cfg_hin = 16'd0;
    logic [15:0] cfg_wout = 16'd0;
    logic [15:0] cfg_hout = 16'd0;
    logic signed [31:0] cfg_x_step_q16 = 32'sd0;
    logic signed [31:0] cfg_y_step_q16 = 32'sd0;
    logic signed [31:0] cfg_x_phase0_q16 = 32'sd0;
    logic signed [31:0] cfg_y_phase0_q16 = 32'sd0;

    logic busy;
    logic done;
    logic error;
    logic [7:0] error_code;

    logic cnn_start_valid;
    logic cnn_start_ready = 1'b1;
    logic cnn_abort;
    logic cnn_error = 1'b0;
    logic [7:0] cnn_error_code = 8'd0;

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

    logic cnn_in_valid;
    logic cnn_in_ready;
    logic [63:0] cnn_in_data_s8;
    logic [15:0] cnn_in_x;
    logic [15:0] cnn_in_y;
    logic cnn_in_sof;
    logic cnn_in_eol;
    logic cnn_in_eof;

    logic cnn_out_valid;
    logic cnn_out_ready;
    logic [63:0] cnn_out_data_s8;
    logic [15:0] cnn_out_x;
    logic [15:0] cnn_out_y;
    logic cnn_out_sof;
    logic cnn_out_eol;
    logic cnn_out_eof;

    logic out_valid;
    logic out_ready;
    logic [23:0] out_rgb888;
    logic [15:0] out_x;
    logic [15:0] out_y;
    logic out_sof;
    logic out_eol;
    logic out_eof;

    logic [23:0] expected_rgb [0:MAX_PIXELS-1];
    integer frame_width = 0;
    integer frame_height = 0;
    integer frame_pixels = 0;
    integer seam_index = 0;
    integer output_index = 0;
    logic score_active = 1'b0;
    logic output_eof_seen = 1'b0;

    // A one-beat elastic model is intentionally slower than the shell.  It
    // stores the complete C8 sideband, waits a pseudo-random number of cycles,
    // and then holds VALID/payload until the egress accepts it.
    logic loop_valid = 1'b0;
    logic [2:0] loop_delay = 3'd0;
    logic [63:0] loop_data = 64'd0;
    logic [15:0] loop_x = 16'd0;
    logic [15:0] loop_y = 16'd0;
    logic loop_sof = 1'b0;
    logic loop_eol = 1'b0;
    logic loop_eof = 1'b0;

    logic [31:0] lfsr = 32'h6d2b_79f5;
    integer cycle_count = 0;
    logic force_first_output_stall = 1'b1;
    integer forced_output_stall_age = 0;
    wire loop_capture_allow = (cycle_count[2:0] != 3'b000) &&
                              (lfsr[5:3] != 3'b111);
    wire sink_ready_random = (cycle_count % 7 != 0) &&
                             (lfsr[10:8] != 3'b000);

    integer start_count = 0;
    integer cnn_start_count = 0;
    integer done_count = 0;
    integer abort_count = 0;
    integer completed_frame_count = 0;
    integer isp_accept_count = 0;
    integer dma_accept_count = 0;
    integer seam_accept_count = 0;
    integer loop_release_count = 0;
    integer output_accept_count = 0;
    integer duplicate_start_checks = 0;
    integer cnn_start_gate_checks = 0;
    integer cnn_error_checks = 0;
    integer isolation_cycles = 0;
    integer cnn_input_stall_cycles = 0;
    integer cnn_output_stall_cycles = 0;
    integer rgb_output_stall_cycles = 0;
    integer source_gap_cycles = 0;
    logic active_select_dma = 1'b0;

    logic previous_cnn_input_stall = 1'b0;
    logic previous_cnn_output_stall = 1'b0;
    logic previous_rgb_output_stall = 1'b0;
    logic [98:0] previous_cnn_input_payload = '0;
    logic [98:0] previous_cnn_output_payload = '0;
    logic [58:0] previous_rgb_output_payload = '0;
    logic previous_done = 1'b0;

    integer index;
    integer guard;
    integer snapshot;
    integer target;

    always #5 clk = ~clk;

    assign cnn_in_ready = !rst && !abort && !loop_valid &&
                          loop_capture_allow;
    assign cnn_out_valid = !rst && !abort && loop_valid &&
                           (loop_delay == 0);
    assign cnn_out_data_s8 = loop_data;
    assign cnn_out_x = loop_x;
    assign cnn_out_y = loop_y;
    assign cnn_out_sof = loop_sof;
    assign cnn_out_eol = loop_eol;
    assign cnn_out_eof = loop_eof;
    assign out_ready = !rst && !abort && !force_first_output_stall &&
                       sink_ready_random;

    c1_r1_compute_shell #(
        .MAX_WIDTH(MAX_WIDTH)
    ) dut (.*);

    function automatic logic [63:0] centered_c8(
        input logic [23:0] rgb
    );
        begin
            centered_c8 = {40'd0,
                           rgb[7:0] ^ 8'h80,
                           rgb[15:8] ^ 8'h80,
                           rgb[23:16] ^ 8'h80};
        end
    endfunction

    task automatic prepare_frame(
        input integer width_value,
        input integer height_value,
        input integer seed_value
    );
        integer item;
        begin
            if ((width_value <= 0) || (height_value <= 0) ||
                (width_value > MAX_WIDTH) ||
                (width_value * height_value > MAX_PIXELS))
                $fatal(1, "invalid compute-shell test dimensions");

            frame_width = width_value;
            frame_height = height_value;
            frame_pixels = width_value * height_value;
            for (item = 0; item < frame_pixels; item = item + 1) begin
                // Include extrema and non-symmetric channel values so byte
                // order and the centered-s8 XOR transform are both covered.
                case (item)
                    0: expected_rgb[item] = 24'h00_80_ff;
                    1: expected_rgb[item] = 24'hff_00_80;
                    2: expected_rgb[item] = 24'h80_ff_00;
                    default: begin
                        expected_rgb[item][23:16] =
                            (seed_value + item * 37) & 8'hff;
                        expected_rgb[item][15:8] =
                            (seed_value * 3 + item * 71 + 9) & 8'hff;
                        expected_rgb[item][7:0] =
                            (seed_value * 5 + item * 113 + 17) & 8'hff;
                    end
                endcase
            end

            seam_index = 0;
            output_index = 0;
            output_eof_seen = 1'b0;
            score_active = 1'b1;
        end
    endtask

    task automatic apply_identity_config;
        begin
            cfg_win = frame_width[15:0];
            cfg_hin = frame_height[15:0];
            cfg_wout = frame_width[15:0];
            cfg_hout = frame_height[15:0];
            cfg_x_step_q16 = 32'sh0001_0000;
            cfg_y_step_q16 = 32'sh0001_0000;
            cfg_x_phase0_q16 = 32'sd0;
            cfg_y_phase0_q16 = 32'sd0;
        end
    endtask

    task automatic start_job(input logic select_dma_value);
        integer start_target;
        begin
            apply_identity_config();
            source_select = select_dma_value;
            start_target = start_count + 1;
            @(negedge clk);
            start_valid = 1'b1;
            guard = 0;
            while (start_count < start_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "compute shell start timeout");
            end
            start_valid = 1'b0;

            // Prove start is atomic: all live pins are poisoned immediately
            // after the handshake.  The active children must use the values
            // captured on the accepted start edge.
            source_select = !select_dma_value;
            cfg_win = 16'hffff;
            cfg_hin = 16'hfffe;
            cfg_wout = 16'd1;
            cfg_hout = 16'd1;
            cfg_x_step_q16 = -32'sd1;
            cfg_y_step_q16 = -32'sd2;
            cfg_x_phase0_q16 = 32'sh7fff_ffff;
            cfg_y_phase0_q16 = 32'sh8000_0000;

            if (!busy || error || start_ready)
                $fatal(1, "compute shell did not enter a clean active job");
        end
    endtask

    task automatic attempt_start_while_busy;
        integer count_snapshot;
        begin
            count_snapshot = start_count;
            @(negedge clk);
            start_valid = 1'b1;
            source_select = !active_select_dma;
            repeat (4) begin
                @(posedge clk);
                #1;
                if (start_ready)
                    $fatal(1, "compute shell accepted a second active start");
            end
            @(negedge clk);
            start_valid = 1'b0;
            if (start_count != count_snapshot)
                $fatal(1, "active start changed the accepted-start count");
            duplicate_start_checks = duplicate_start_checks + 1;
        end
    endtask

    task automatic check_cnn_start_gate;
        begin
            prepare_frame(2, 2, 9);
            apply_identity_config();
            source_select = 1'b0;
            cnn_start_ready = 1'b0;
            @(negedge clk);
            start_valid = 1'b1;
            repeat (4) begin
                @(posedge clk);
                #1;
                if (start_ready || cnn_start_valid || busy || error)
                    $fatal(1, "external CNN ready did not gate atomic start");
            end
            @(negedge clk);
            start_valid = 1'b0;
            cnn_start_ready = 1'b1;
            score_active = 1'b0;
            cnn_start_gate_checks = cnn_start_gate_checks + 1;
            repeat (2) @(posedge clk);
            #1;
            if (!start_ready || busy || cnn_start_valid)
                $fatal(1, "shell did not recover from CNN start backpressure");
        end
    endtask

    task automatic drive_selected_pixel(
        input logic select_dma_value,
        input integer item,
        input integer gap_cycles
    );
        integer accept_target;
        logic [15:0] x_value;
        logic [15:0] y_value;
        logic sof_value;
        logic eol_value;
        logic eof_value;
        begin
            repeat (gap_cycles) begin
                @(posedge clk);
                source_gap_cycles = source_gap_cycles + 1;
            end

            // The ISP valid crop can start at a non-zero physical origin.
            // DMA is already a logical zero-based raster.  Shell outputs for
            // both cases are always checked against zero-based coordinates.
            x_value = (item % frame_width) + (select_dma_value ? 0 : 1);
            y_value = (item / frame_width) + (select_dma_value ? 0 : 1);
            sof_value = (item == 0);
            eol_value = ((item % frame_width) == frame_width - 1);
            eof_value = (item == frame_pixels - 1);
            accept_target = select_dma_value ?
                            (dma_accept_count + 1) :
                            (isp_accept_count + 1);

            @(negedge clk);
            if (select_dma_value) begin
                dma_valid = 1'b1;
                dma_rgb888 = expected_rgb[item];
                dma_x = x_value;
                dma_y = y_value;
                dma_sof = sof_value;
                dma_eol = eol_value;
                dma_eof = eof_value;
            end else begin
                isp_valid = 1'b1;
                isp_rgb888 = expected_rgb[item];
                isp_x = x_value;
                isp_y = y_value;
                isp_sof = sof_value;
                isp_eol = eol_value;
                isp_eof = eof_value;
            end

            guard = 0;
            while ((select_dma_value &&
                    (dma_accept_count < accept_target)) ||
                   (!select_dma_value &&
                    (isp_accept_count < accept_target))) begin
                @(negedge clk);
                guard = guard + 1;
                source_select = ~source_select;
                if (guard > 5000)
                    $fatal(1, "selected RGB source handshake timeout");
            end

            if (select_dma_value) begin
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

    task automatic set_unselected_poison(input logic selected_dma_value);
        begin
            if (selected_dma_value) begin
                isp_valid = 1'b1;
                isp_rgb888 = 24'hde_ad_11;
                isp_x = 16'hdead;
                isp_y = 16'hbeef;
                isp_sof = 1'b1;
                isp_eol = 1'b1;
                isp_eof = 1'b1;
            end else begin
                dma_valid = 1'b1;
                dma_rgb888 = 24'hca_fe_22;
                dma_x = 16'hcafe;
                dma_y = 16'hbabe;
                dma_sof = 1'b1;
                dma_eol = 1'b1;
                dma_eof = 1'b1;
            end
        end
    endtask

    task automatic clear_sources;
        begin
            isp_valid = 1'b0;
            isp_rgb888 = 24'd0;
            isp_x = 16'd0;
            isp_y = 16'd0;
            isp_sof = 1'b0;
            isp_eol = 1'b0;
            isp_eof = 1'b0;
            dma_valid = 1'b0;
            dma_rgb888 = 24'd0;
            dma_x = 16'd0;
            dma_y = 16'd0;
            dma_sof = 1'b0;
            dma_eol = 1'b0;
            dma_eof = 1'b0;
        end
    endtask

    task automatic wait_for_done(input integer done_target);
        begin
            guard = 0;
            while (done_count < done_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000)
                    $fatal(1, "compute shell completion timeout");
            end
            if ((seam_index != frame_pixels) ||
                (output_index != frame_pixels) || !output_eof_seen)
                $fatal(1, "completed frame count/EOF mismatch");
            completed_frame_count = completed_frame_count + 1;
            score_active = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            if (busy || error || out_valid || cnn_in_valid || loop_valid ||
                !start_ready)
                $fatal(1, "compute shell did not return to clean idle");
        end
    endtask

    task automatic pulse_abort;
        integer done_snapshot;
        begin
            done_snapshot = done_count;
            score_active = 1'b0;
            @(negedge clk);
            abort = 1'b1;
            #1;
            if (start_ready || isp_ready || dma_ready || cnn_in_valid ||
                cnn_out_ready || out_valid || !cnn_abort)
                $fatal(1, "abort did not immediately fence shell streams");
            @(posedge clk);
            #1;
            if (busy || error || (error_code != 8'h00))
                $fatal(1, "abort did not synchronously clear shell state");
            @(negedge clk);
            abort = 1'b0;
            #1;
            if (cnn_abort)
                $fatal(1, "external CNN abort remained asserted");
            abort_count = abort_count + 1;
            repeat (2) @(posedge clk);
            #1;
            if (busy || error || out_valid || cnn_in_valid || loop_valid ||
                !start_ready || (done_count != done_snapshot))
                $fatal(1, "shell was not restartable after abort");
        end
    endtask

    task automatic inject_cnn_error(input logic [7:0] injected_code);
        logic [7:0] expected_shell_code;
        begin
            expected_shell_code = 8'h80 | {1'b0, injected_code[6:0]};
            @(negedge clk);
            cnn_error_code = injected_code;
            cnn_error = 1'b1;
            #1;
            if (isp_ready || dma_ready || cnn_in_valid || cnn_out_ready ||
                out_valid || start_ready)
                $fatal(1, "CNN fault did not immediately fence shell streams");
            @(posedge clk);
            #1;
            if (!busy || !error || (error_code !== expected_shell_code))
                $fatal(1, "CNN fault mapping mismatch got=%h expected=%h",
                       error_code, expected_shell_code);
            @(negedge clk);
            cnn_error = 1'b0;
            cnn_error_code = 8'd0;
            repeat (3) begin
                @(posedge clk);
                #1;
                if (!busy || !error ||
                    (error_code !== expected_shell_code) || isp_ready ||
                    dma_ready || cnn_in_valid || cnn_out_ready || out_valid ||
                    start_ready)
                    $fatal(1, "CNN fault did not remain sticky/frozen");
            end
            cnn_error_checks = cnn_error_checks + 1;
        end
    endtask

    // Deterministic pseudo-random controls and the elastic C8 loopback.
    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= 32'h6d2b_79f5;
            cycle_count <= 0;
            loop_valid <= 1'b0;
            loop_delay <= 3'd0;
            loop_data <= 64'd0;
            loop_x <= 16'd0;
            loop_y <= 16'd0;
            loop_sof <= 1'b0;
            loop_eol <= 1'b0;
            loop_eof <= 1'b0;
            loop_release_count <= 0;
            force_first_output_stall <= 1'b1;
            forced_output_stall_age <= 0;
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            cycle_count <= cycle_count + 1;

            // Hold the first RGB output long enough for the following C8 beat
            // to reach a busy egress.  This deterministically covers both the
            // RGB hold rule and cnn_out_valid && !cnn_out_ready.
            if (force_first_output_stall && out_valid) begin
                if (forced_output_stall_age == 12)
                    force_first_output_stall <= 1'b0;
                else
                    forced_output_stall_age <= forced_output_stall_age + 1;
            end

            if (abort) begin
                loop_valid <= 1'b0;
                loop_delay <= 3'd0;
                loop_data <= 64'd0;
                loop_x <= 16'd0;
                loop_y <= 16'd0;
                loop_sof <= 1'b0;
                loop_eol <= 1'b0;
                loop_eof <= 1'b0;
            end else begin
                if (loop_valid && (loop_delay != 0))
                    loop_delay <= loop_delay - 1'b1;

                if (cnn_out_valid && cnn_out_ready) begin
                    loop_valid <= 1'b0;
                    loop_release_count <= loop_release_count + 1;
                end

                if (cnn_in_valid && cnn_in_ready) begin
                    if (loop_valid)
                        $fatal(1, "C8 loopback overwrote a pending beat");
                    loop_valid <= 1'b1;
                    loop_delay <= {1'b0, lfsr[7:6]};
                    loop_data <= cnn_in_data_s8;
                    loop_x <= cnn_in_x;
                    loop_y <= cnn_in_y;
                    loop_sof <= cnn_in_sof;
                    loop_eol <= cnn_in_eol;
                    loop_eof <= cnn_in_eof;
                end
            end
        end
    end

    // End-to-end scoreboards, source isolation, and all stall-hold checks.
    always @(posedge clk) begin
        if (rst) begin
            start_count = 0;
            cnn_start_count = 0;
            done_count = 0;
            isp_accept_count = 0;
            dma_accept_count = 0;
            seam_accept_count = 0;
            output_accept_count = 0;
            isolation_cycles = 0;
            cnn_input_stall_cycles = 0;
            cnn_output_stall_cycles = 0;
            rgb_output_stall_cycles = 0;
            previous_cnn_input_stall = 1'b0;
            previous_cnn_output_stall = 1'b0;
            previous_rgb_output_stall = 1'b0;
            previous_cnn_input_payload = '0;
            previous_cnn_output_payload = '0;
            previous_rgb_output_payload = '0;
            previous_done = 1'b0;
            active_select_dma = 1'b0;
        end else if (abort) begin
            previous_cnn_input_stall = 1'b0;
            previous_cnn_output_stall = 1'b0;
            previous_rgb_output_stall = 1'b0;
            previous_done = 1'b0;
        end else begin
            if (previous_cnn_input_stall &&
                ({cnn_in_eof,cnn_in_eol,cnn_in_sof,cnn_in_y,cnn_in_x,
                  cnn_in_data_s8} !== previous_cnn_input_payload))
                $fatal(1, "CNN ingress payload changed while stalled");
            if (previous_cnn_output_stall &&
                ({cnn_out_eof,cnn_out_eol,cnn_out_sof,cnn_out_y,cnn_out_x,
                  cnn_out_data_s8} !== previous_cnn_output_payload))
                $fatal(1, "CNN loopback payload changed while stalled");
            if (previous_rgb_output_stall &&
                ({out_eof,out_eol,out_sof,out_y,out_x,out_rgb888} !==
                 previous_rgb_output_payload))
                $fatal(1, "RGB output payload changed while stalled");

            previous_cnn_input_stall = cnn_in_valid && !cnn_in_ready;
            previous_cnn_output_stall = cnn_out_valid && !cnn_out_ready;
            previous_rgb_output_stall = out_valid && !out_ready;
            previous_cnn_input_payload =
                {cnn_in_eof,cnn_in_eol,cnn_in_sof,cnn_in_y,cnn_in_x,
                 cnn_in_data_s8};
            previous_cnn_output_payload =
                {cnn_out_eof,cnn_out_eol,cnn_out_sof,cnn_out_y,cnn_out_x,
                 cnn_out_data_s8};
            previous_rgb_output_payload =
                {out_eof,out_eol,out_sof,out_y,out_x,out_rgb888};

            if (cnn_in_valid && !cnn_in_ready)
                cnn_input_stall_cycles = cnn_input_stall_cycles + 1;
            if (cnn_out_valid && !cnn_out_ready)
                cnn_output_stall_cycles = cnn_output_stall_cycles + 1;
            if (out_valid && !out_ready)
                rgb_output_stall_cycles = rgb_output_stall_cycles + 1;

            if (start_valid && start_ready) begin
                start_count = start_count + 1;
                active_select_dma = source_select;
            end
            if (cnn_start_valid) begin
                if (!(start_valid && start_ready) || !cnn_start_ready)
                    $fatal(1, "external CNN start was not atomic");
                cnn_start_count = cnn_start_count + 1;
            end
            if (isp_valid && isp_ready)
                isp_accept_count = isp_accept_count + 1;
            if (dma_valid && dma_ready)
                dma_accept_count = dma_accept_count + 1;

            if (isp_ready && dma_ready)
                $fatal(1, "shell enabled both RGB sources");
            if (busy && !error) begin
                if ((!active_select_dma && dma_ready) ||
                    (active_select_dma && isp_ready))
                    $fatal(1, "shell enabled its unselected RGB source");
                if ((!active_select_dma && dma_valid && !dma_ready) ||
                    (active_select_dma && isp_valid && !isp_ready))
                    isolation_cycles = isolation_cycles + 1;
                if (start_ready)
                    $fatal(1, "start_ready asserted during an active job");
            end

            if (cnn_in_valid && cnn_in_ready) begin
                if (!score_active || (seam_index >= frame_pixels))
                    $fatal(1, "unexpected CNN ingress beat");
                if (cnn_in_data_s8 !== centered_c8(expected_rgb[seam_index]))
                    $fatal(1, "CNN ingress C8 mismatch item=%0d", seam_index);
                if ((cnn_in_x !== (seam_index % frame_width)) ||
                    (cnn_in_y !== (seam_index / frame_width)) ||
                    (cnn_in_sof !== (seam_index == 0)) ||
                    (cnn_in_eol !==
                     ((seam_index % frame_width) == frame_width - 1)) ||
                    (cnn_in_eof !== (seam_index == frame_pixels - 1)))
                    $fatal(1, "CNN ingress coordinate/marker mismatch item=%0d",
                           seam_index);
                if (cnn_in_data_s8[63:24] !== 40'd0)
                    $fatal(1, "CNN ingress padding lanes were non-zero");
                seam_index = seam_index + 1;
                seam_accept_count = seam_accept_count + 1;
            end

            if (out_valid && out_ready) begin
                if (!score_active || (output_index >= frame_pixels))
                    $fatal(1, "unexpected RGB output beat");
                if (out_rgb888 !== expected_rgb[output_index])
                    $fatal(1, "RGB bit-exact mismatch item=%0d got=%h expected=%h",
                           output_index, out_rgb888,
                           expected_rgb[output_index]);
                if ((out_x !== (output_index % frame_width)) ||
                    (out_y !== (output_index / frame_width)) ||
                    (out_sof !== (output_index == 0)) ||
                    (out_eol !==
                     ((output_index % frame_width) == frame_width - 1)) ||
                    (out_eof !== (output_index == frame_pixels - 1)))
                    $fatal(1, "RGB coordinate/marker mismatch item=%0d",
                           output_index);
                if (out_eof)
                    output_eof_seen = 1'b1;
                output_index = output_index + 1;
                output_accept_count = output_accept_count + 1;
            end

            if (done) begin
                if (!score_active || !output_eof_seen || busy || error)
                    $fatal(1, "shell done did not retire a complete clean frame");
                done_count = done_count + 1;
            end
            if (done && previous_done)
                $fatal(1, "shell done was not a one-cycle pulse");
            previous_done = done;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        if (!start_ready || busy || done || error || isp_ready || dma_ready ||
            cnn_start_valid || cnn_abort || cnn_in_valid || cnn_out_ready ||
            out_valid)
            $fatal(1, "compute shell reset/idle contract mismatch");

        check_cnn_start_gate();

        // ISP-selected identity Resize.  DMA continuously presents a malformed
        // poison frame and live source/config pins change after start.
        prepare_frame(4, 3, 17);
        set_unselected_poison(1'b0);
        start_job(1'b0);
        attempt_start_while_busy();
        for (index = 0; index < frame_pixels; index = index + 1)
            drive_selected_pixel(1'b0, index, (index * 3 + 1) % 3);
        target = done_count + 1;
        wait_for_done(target);
        clear_sources();

        // DMA-selected identity Resize proves the opposite select/ready path.
        prepare_frame(5, 2, 71);
        set_unselected_poison(1'b1);
        start_job(1'b1);
        for (index = 0; index < frame_pixels; index = index + 1)
            drive_selected_pixel(1'b1, index, (index * 5 + 2) % 4);
        target = done_count + 1;
        wait_for_done(target);
        clear_sources();

        // Abort a legal frame with work distributed across Resize/CNN/egress.
        prepare_frame(6, 3, 123);
        set_unselected_poison(1'b0);
        start_job(1'b0);
        for (index = 0; index < 9; index = index + 1)
            drive_selected_pixel(1'b0, index, index % 2);
        snapshot = done_count;
        inject_cnn_error(8'h25);
        pulse_abort();
        clear_sources();
        if (done_count != snapshot)
            $fatal(1, "aborted frame incorrectly produced done");

        // A distinct DMA frame must restart from logical (0,0) without any
        // stale RGB/C8 beat from the aborted ISP frame.
        prepare_frame(3, 3, 201);
        set_unselected_poison(1'b1);
        start_job(1'b1);
        for (index = 0; index < frame_pixels; index = index + 1)
            drive_selected_pixel(1'b1, index, (index * 7 + 3) % 3);
        target = done_count + 1;
        wait_for_done(target);
        clear_sources();

        repeat (8) @(posedge clk);
        #1;
        if ((start_count != 4) || (cnn_start_count != 4) ||
            (done_count != 3) ||
            (abort_count != 1) || (completed_frame_count != 3) ||
            (duplicate_start_checks != 1) || (cnn_start_gate_checks != 1) ||
            (cnn_error_checks != 1) ||
            (isp_accept_count != 21) || (dma_accept_count != 19) ||
            (isolation_cycles == 0) || (cnn_input_stall_cycles == 0) ||
            (cnn_output_stall_cycles == 0) ||
            (rgb_output_stall_cycles == 0) || (source_gap_cycles == 0) ||
            busy || error || out_valid || cnn_in_valid || loop_valid ||
            !start_ready)
            $fatal(1, "compute shell coverage/accounting mismatch starts=%0d cnn_starts=%0d done=%0d aborts=%0d cnn_faults=%0d frames=%0d isp=%0d dma=%0d seam=%0d released=%0d rgb=%0d isolation=%0d cnn_in_stall=%0d cnn_out_stall=%0d rgb_stall=%0d gaps=%0d",
                   start_count, cnn_start_count, done_count, abort_count,
                   cnn_error_checks, completed_frame_count,
                   isp_accept_count, dma_accept_count,
                   seam_accept_count, loop_release_count,
                   output_accept_count, isolation_cycles,
                   cnn_input_stall_cycles, cnn_output_stall_cycles,
                   rgb_output_stall_cycles, source_gap_cycles);

        $display("C1_R1_COMPUTE_SHELL_PASS starts=%0d cnn_starts=%0d done=%0d aborts=%0d cnn_faults=%0d frames=%0d isp=%0d dma=%0d seam=%0d released=%0d rgb=%0d isolation=%0d cnn_in_stalls=%0d cnn_out_stalls=%0d rgb_stalls=%0d",
                 start_count, cnn_start_count, done_count, abort_count,
                 cnn_error_checks, completed_frame_count,
                 isp_accept_count, dma_accept_count,
                 seam_accept_count, loop_release_count, output_accept_count,
                 isolation_cycles, cnn_input_stall_cycles,
                 cnn_output_stall_cycles, rgb_output_stall_cycles);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "global R1 compute-shell testbench timeout");
    end

endmodule
