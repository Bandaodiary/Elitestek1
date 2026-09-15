`timescale 1ns/1ps

module tb_c1_axi_xrgb_frame_reader;

    localparam logic [7:0] MEMORY_SENTINEL = 8'ha5;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start = 1'b0;
    logic cancel = 1'b0;
    logic [31:0] cfg_base_addr = '0;
    logic [15:0] cfg_width_pixels = '0;
    logic [15:0] cfg_height_lines = '0;
    logic [31:0] cfg_stride_bytes = '0;
    logic busy;
    logic done;
    logic error;

    logic m_valid;
    logic m_ready = 1'b0;
    logic [23:0] m_rgb;
    logic m_sof;
    logic m_eol;
    logic m_eof;
    logic [15:0] m_x;
    logic [15:0] m_y;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready = 1'b0;
    logic [127:0] m_axi_rdata = '0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;

    logic [7:0] byte_memory [0:65535];

    integer model_frame_id = 0;
    integer model_base = 0;
    integer model_width = 0;
    integer model_height = 0;
    integer model_stride = 0;
    integer model_line_bytes = 0;
    integer inject_error_burst = -1;
    integer inject_early_rlast_burst = -1;
    integer inject_early_rlast_beat = -1;
    integer inject_missing_rlast_burst = -1;
    logic model_frame_active = 1'b0;
    logic model_expect_full_output = 1'b1;

    integer expected_next_addr = 0;
    integer expected_row = 0;
    integer expected_row_bytes_remaining = 0;
    integer frame_ar_count = 0;
    integer frame_r_beat_count = 0;
    integer frame_error_responses = 0;
    integer frame_output_count = 0;
    integer all_ar_count = 0;

    logic burst_active = 1'b0;
    integer active_ar_addr = 0;
    integer active_ar_beats = 0;
    integer active_r_index = 0;
    integer active_burst_number = 0;
    integer r_delay = 0;

    logic [31:0] bfm_prng = 32'h5c91_37e2;
    integer ar_stall_cycles = 0;
    integer r_gap_cycles = 0;
    integer r_backpressure_cycles = 0;
    integer downstream_stall_cycles = 0;
    integer output_hold_checks = 0;
    integer final_stall_cycles = 0;
    integer final_stall_remaining = 0;
    logic final_stall_injected = 1'b0;
    logic saw_final_pixel_stall = 1'b0;
    logic saw_4k_split = 1'b0;
    logic saw_max_burst = 1'b0;
    logic force_ar_stall = 1'b0;
    logic force_r_gap = 1'b0;
    logic force_output_stall = 1'b0;
    integer cancel_case_count = 0;
    integer protocol_error_case_count = 0;
    integer recovery_restart_count = 0;

    logic held_ar = 1'b0;
    logic [31:0] held_araddr = '0;
    logic [7:0] held_arlen = '0;
    logic [2:0] held_arsize = '0;
    logic [1:0] held_arburst = '0;
    logic held_r = 1'b0;
    logic [127:0] held_rdata = '0;
    logic [1:0] held_rresp = '0;
    logic held_rlast = 1'b0;
    logic held_output = 1'b0;
    logic [23:0] held_rgb = '0;
    logic held_sof = 1'b0;
    logic held_eol = 1'b0;
    logic held_eof = 1'b0;
    logic [15:0] held_x = '0;
    logic [15:0] held_y = '0;

    integer initialize_index;
    integer planned_beats;
    integer burst_bytes;
    integer expected_output_x;
    integer expected_output_y;
    logic [23:0] expected_rgb;

    c1_axi_xrgb_frame_reader dut (
        .clk,
        .rst,
        .start,
        .cancel,
        .cfg_base_addr,
        .cfg_width_pixels,
        .cfg_height_lines,
        .cfg_stride_bytes,
        .busy,
        .done,
        .error,
        .m_valid,
        .m_ready,
        .m_rgb,
        .m_sof,
        .m_eol,
        .m_eof,
        .m_x,
        .m_y,
        .m_axi_araddr,
        .m_axi_arlen,
        .m_axi_arsize,
        .m_axi_arburst,
        .m_axi_arvalid,
        .m_axi_arready,
        .m_axi_rdata,
        .m_axi_rresp,
         .m_axi_rlast,
         .m_axi_rvalid,
         .m_axi_rready,
         .m_axi_ar_allow(1'b1)
     );

    function automatic [31:0] prng_next(input [31:0] state);
        reg feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    function automatic [23:0] pixel_value(
        input integer frame_id,
        input integer x,
        input integer y
    );
        reg [7:0] red;
        reg [7:0] green;
        reg [7:0] blue;
        begin
            red = frame_id*8'h31 + x*3 + y*17;
            green = frame_id*8'h57 + x*11 + y*5;
            blue = frame_id*8'h93 + x*7 + y*13;
            pixel_value = {red, green, blue};
        end
    endfunction

    function automatic [127:0] memory_beat(input integer address);
        integer byte_index;
        begin
            memory_beat = '0;
            for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                memory_beat[byte_index*8 +: 8] = byte_memory[address + byte_index];
        end
    endfunction

    function automatic integer expected_burst_beats(
        input integer address,
        input integer row_bytes_remaining
    );
        integer beats_to_boundary;
        integer row_beats;
        integer selected;
        begin
            beats_to_boundary = (4096 - (address & 4095)) / 16;
            row_beats = row_bytes_remaining / 16;
            selected = 16;
            if (row_beats < selected)
                selected = row_beats;
            if (beats_to_boundary < selected)
                selected = beats_to_boundary;
            expected_burst_beats = selected;
        end
    endfunction

    function automatic [1:0] response_for_beat(
        input integer burst_number,
        input integer beat_index
    );
        begin
            response_for_beat = ((burst_number == inject_error_burst) &&
                                 (beat_index == 0)) ? 2'b10 : 2'b00;
        end
    endfunction

    function automatic logic rlast_for_beat(
        input integer burst_number,
        input integer beat_index,
        input integer burst_beats
    );
        begin
            if ((burst_number == inject_early_rlast_burst) &&
                (beat_index == inject_early_rlast_beat))
                rlast_for_beat = 1'b1;
            else if ((burst_number == inject_missing_rlast_burst) &&
                     (beat_index == burst_beats-1))
                rlast_for_beat = 1'b0;
            else
                rlast_for_beat = (beat_index == burst_beats-1);
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_AXI_XRGB_FRAME_READER_FAIL time=%0t frame=%0d ar=%0d r=%0d out=%0d: %s",
                     $time, model_frame_id, frame_ar_count,
                     frame_r_beat_count, frame_output_count, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic present_r_beat(input integer beat_index);
        begin
            m_axi_rdata <= memory_beat(active_ar_addr + beat_index*16);
            m_axi_rresp <= response_for_beat(active_burst_number, beat_index);
            m_axi_rlast <= rlast_for_beat(
                active_burst_number, beat_index, active_ar_beats);
            m_axi_rvalid <= 1'b1;
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        for (initialize_index = 0; initialize_index < 65536;
             initialize_index = initialize_index + 1)
            byte_memory[initialize_index] = MEMORY_SENTINEL;
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
    end

    // Random-delay AXI read slave.  It can present the next R beat with no
    // gap, forcing the one-beat reader to deassert RREADY while four pixels
    // are consumed.  Every R payload is held until the handshake.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rdata <= '0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            bfm_prng <= 32'h5c91_37e2;
            burst_active = 1'b0;
            active_r_index = 0;
            r_delay = 0;
            held_ar = 1'b0;
            held_r = 1'b0;
        end else begin
            bfm_prng <= prng_next(bfm_prng);
            if (force_ar_stall)
                m_axi_arready <= 1'b0;
            else
                m_axi_arready <= bfm_prng[0] && bfm_prng[4];

            if (held_ar) begin
                if (!m_axi_arvalid || (m_axi_araddr !== held_araddr) ||
                    (m_axi_arlen !== held_arlen) ||
                    (m_axi_arsize !== held_arsize) ||
                    (m_axi_arburst !== held_arburst))
                    fail("AR payload changed before ARREADY handshake");
            end
            if (held_r) begin
                if (!m_axi_rvalid || (m_axi_rdata !== held_rdata) ||
                    (m_axi_rresp !== held_rresp) ||
                    (m_axi_rlast !== held_rlast))
                    fail("R payload changed while the reader deasserted RREADY");
            end

            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_cycles = ar_stall_cycles + 1;
            if (m_axi_rvalid && !m_axi_rready)
                r_backpressure_cycles = r_backpressure_cycles + 1;

            if (m_axi_arvalid && m_axi_arready) begin
                if (!model_frame_active)
                    fail("AR issued without an active frame model");
                if (burst_active || m_axi_rvalid)
                    fail("new AR issued before the previous R burst completed");
                if (expected_row >= model_height)
                    fail("extra AR issued after the final row");
                if (m_axi_araddr !== expected_next_addr[31:0])
                    fail("AR address skipped, duplicated, or reordered a burst");
                if (m_axi_arsize !== 3'd4)
                    fail("ARSIZE is not 16 bytes");
                if (m_axi_arburst !== 2'b01)
                    fail("ARBURST is not INCR");
                if (m_axi_arlen > 8'd15)
                    fail("read burst exceeds 16 beats");
                if ((m_axi_araddr & 15) != 0)
                    fail("ARADDR is not 16-byte aligned");

                planned_beats = expected_burst_beats(
                    expected_next_addr, expected_row_bytes_remaining);
                if ((m_axi_arlen + 1) !== planned_beats)
                    fail("ARLEN does not match row/4KiB/max16 plan");
                burst_bytes = planned_beats * 16;
                if (((m_axi_araddr & 4095) + burst_bytes) > 4096)
                    fail("read burst crosses a 4KiB boundary");
                if (planned_beats == 16)
                    saw_max_burst = 1'b1;
                if (((m_axi_araddr & 4095) != 0) &&
                    (((m_axi_araddr & 4095) + burst_bytes) == 4096))
                    saw_4k_split = 1'b1;

                burst_active = 1'b1;
                active_ar_addr = m_axi_araddr;
                active_ar_beats = planned_beats;
                active_r_index = 0;
                active_burst_number = frame_ar_count;
                r_delay = 1 + bfm_prng[10:8];
                frame_ar_count = frame_ar_count + 1;
                all_ar_count = all_ar_count + 1;

                if (expected_row_bytes_remaining == burst_bytes) begin
                    expected_row = expected_row + 1;
                    if (expected_row < model_height) begin
                        expected_next_addr = model_base + expected_row*model_stride;
                        expected_row_bytes_remaining = model_line_bytes;
                    end else begin
                        expected_row_bytes_remaining = 0;
                    end
                end else begin
                    expected_next_addr = expected_next_addr + burst_bytes;
                    expected_row_bytes_remaining =
                        expected_row_bytes_remaining - burst_bytes;
                end
            end

            if (m_axi_rvalid && m_axi_rready) begin
                if (!burst_active)
                    fail("R beat accepted without an active AR burst");
                if (m_axi_rlast !== rlast_for_beat(
                        active_burst_number, active_r_index,
                        active_ar_beats))
                    fail("BFM RLAST generation disagrees with active burst");
                frame_r_beat_count = frame_r_beat_count + 1;
                if (m_axi_rresp != 2'b00)
                    frame_error_responses = frame_error_responses + 1;

                if (m_axi_rlast ||
                    (active_r_index == active_ar_beats-1)) begin
                    burst_active = 1'b0;
                    m_axi_rvalid <= 1'b0;
                end else begin
                    active_r_index = active_r_index + 1;
                    // Guarantee at least one zero-gap next beat per burst;
                    // other beats receive a pseudo-random delay.
                    if ((active_r_index == 1) || bfm_prng[12]) begin
                        present_r_beat(active_r_index);
                    end else begin
                        m_axi_rvalid <= 1'b0;
                        r_delay = 1 + bfm_prng[15:13];
                    end
                end
            end else if (!m_axi_rvalid && burst_active) begin
                if (force_r_gap) begin
                    r_gap_cycles = r_gap_cycles + 1;
                end else if (r_delay == 0)
                    present_r_beat(active_r_index);
                else begin
                    r_delay = r_delay - 1;
                    r_gap_cycles = r_gap_cycles + 1;
                end
            end

            held_ar = m_axi_arvalid && !m_axi_arready;
            held_araddr = m_axi_araddr;
            held_arlen = m_axi_arlen;
            held_arsize = m_axi_arsize;
            held_arburst = m_axi_arburst;
            held_r = m_axi_rvalid && !m_axi_rready;
            held_rdata = m_axi_rdata;
            held_rresp = m_axi_rresp;
            held_rlast = m_axi_rlast;
        end
    end

    // Randomly back-pressured RGB sink and complete raster scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            m_ready <= 1'b0;
            frame_output_count = 0;
            held_output = 1'b0;
            final_stall_remaining = 0;
            final_stall_injected = 1'b0;
            saw_final_pixel_stall = 1'b0;
        end else begin
            if (held_output && !cancel) begin
                output_hold_checks = output_hold_checks + 1;
                if (!m_valid || (m_rgb !== held_rgb) ||
                    (m_sof !== held_sof) || (m_eol !== held_eol) ||
                    (m_eof !== held_eof) ||
                    (m_x !== held_x) || (m_y !== held_y))
                    fail("RGB output changed while downstream was stalled");
            end

            if (m_valid && !m_ready) begin
                downstream_stall_cycles = downstream_stall_cycles + 1;
                if (model_frame_active &&
                    (frame_output_count == model_width*model_height-1)) begin
                    saw_final_pixel_stall = 1'b1;
                    final_stall_cycles = final_stall_cycles + 1;
                    if (done)
                        fail("done asserted while the final pixel was stalled");
                end
            end

            if (m_valid && m_ready) begin
                if (!model_frame_active)
                    fail("RGB pixel emitted without an active frame model");
                if (frame_output_count >= model_width*model_height)
                    fail("reader emitted an extra RGB pixel");
                expected_output_x = frame_output_count % model_width;
                expected_output_y = frame_output_count / model_width;
                expected_rgb = pixel_value(
                    model_frame_id, expected_output_x, expected_output_y);
                if (m_rgb !== expected_rgb)
                    fail("little-endian XRGB unpack or pixel order mismatch");
                if ((m_x !== expected_output_x[15:0]) ||
                    (m_y !== expected_output_y[15:0]))
                    fail("RGB output coordinate mismatch");
                if (m_sof !== ((expected_output_x == 0) &&
                               (expected_output_y == 0)))
                    fail("SOF mismatch");
                if (m_eol !== (expected_output_x == model_width-1))
                    fail("EOL mismatch");
                if (m_eof !== ((expected_output_x == model_width-1) &&
                               (expected_output_y == model_height-1)))
                    fail("EOF mismatch");

                // Force a multi-cycle final-pixel stall after accepting the
                // penultimate pixel, proving the done handshake contract.
                if ((frame_output_count == model_width*model_height-2) &&
                    !final_stall_injected) begin
                    final_stall_remaining = 7;
                    final_stall_injected = 1'b1;
                end
                frame_output_count = frame_output_count + 1;
            end

            if (force_output_stall) begin
                m_ready <= 1'b0;
            end else if (final_stall_remaining > 0) begin
                m_ready <= 1'b0;
                final_stall_remaining = final_stall_remaining - 1;
            end else begin
                m_ready <= bfm_prng[2] ^ bfm_prng[9];
            end

            held_output = m_valid && !m_ready;
            held_rgb = m_rgb;
            held_sof = m_sof;
            held_eol = m_eol;
            held_eof = m_eof;
            held_x = m_x;
            held_y = m_y;

            if (done && model_frame_active) begin
                if (model_expect_full_output &&
                    (frame_output_count != model_width*model_height))
                    fail("done asserted before the final RGB handshake");
                if (busy)
                    fail("busy remained asserted with done");
            end
        end
    end

    task automatic fill_frame_memory(
        input integer frame_id,
        input integer base,
        input integer width,
        input integer height,
        input integer stride
    );
        integer x;
        integer y;
        integer offset;
        integer address;
        logic [23:0] rgb;
        begin
            for (y = 0; y < height; y = y + 1) begin
                for (offset = 0; offset < stride; offset = offset + 1)
                    byte_memory[base + y*stride + offset] = MEMORY_SENTINEL;
                for (x = 0; x < width; x = x + 1) begin
                    address = base + y*stride + x*4;
                    rgb = pixel_value(frame_id, x, y);
                    byte_memory[address+0] = rgb[7:0];
                    byte_memory[address+1] = rgb[15:8];
                    byte_memory[address+2] = rgb[23:16];
                    byte_memory[address+3] = 8'h00;
                end
            end
        end
    endtask

    task automatic configure_model(
        input integer frame_id,
        input integer base,
        input integer width,
        input integer height,
        input integer stride,
        input integer error_burst
    );
        begin
            if (burst_active || m_axi_rvalid)
                fail("new frame configured while a prior R burst remained active");
            model_frame_id = frame_id;
            model_base = base;
            model_width = width;
            model_height = height;
            model_stride = stride;
            model_line_bytes = width*4;
            inject_error_burst = error_burst;
            model_expect_full_output = 1'b1;
            expected_next_addr = base;
            expected_row = 0;
            expected_row_bytes_remaining = width*4;
            frame_ar_count = 0;
            frame_r_beat_count = 0;
            frame_error_responses = 0;
            frame_output_count = 0;
            final_stall_remaining = 0;
            final_stall_injected = 1'b0;
            saw_final_pixel_stall = 1'b0;
            model_frame_active = 1'b1;
        end
    endtask

    task automatic pulse_start(
        input logic [31:0] base,
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [31:0] stride
    );
        begin
            @(negedge clk);
            cfg_base_addr = base;
            cfg_width_pixels = width;
            cfg_height_lines = height;
            cfg_stride_bytes = stride;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic pulse_cancel;
        begin
            @(negedge clk);
            cancel = 1'b1;
            @(negedge clk);
            cancel = 1'b0;
        end
    endtask

    task automatic wait_partial_done(
        input logic expected_error,
        input integer expected_ars,
        input integer expected_r_beats,
        input integer expected_outputs
    );
        integer guard;
        begin
            guard = 0;
            while (done !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000)
                    fail("partial/cancel operation did not complete");
            end
            #0.1;
            if (busy)
                fail("busy remained high at partial/cancel completion");
            if (error !== expected_error)
                fail("partial/cancel sticky error mismatch");
            if (frame_ar_count != expected_ars)
                fail("partial/cancel AR count mismatch");
            if (frame_r_beat_count != expected_r_beats)
                fail("partial/cancel R beat count mismatch");
            if (frame_output_count != expected_outputs)
                fail("partial/cancel RGB output count mismatch");
            if (burst_active || m_axi_rvalid)
                fail("done preceded completion of the committed R drain");
            model_frame_active = 1'b0;
            @(posedge clk);
            #0.1;
            if (done)
                fail("partial/cancel done was not a single-cycle pulse");
        end
    endtask

    task automatic prepare_partial_frame(
        input integer frame_id,
        input integer base
    );
        begin
            fill_frame_memory(frame_id, base, 16, 1, 64);
            configure_model(frame_id, base, 16, 1, 64, -1);
            model_expect_full_output = 1'b0;
            inject_early_rlast_burst = -1;
            inject_early_rlast_beat = -1;
            inject_missing_rlast_burst = -1;
        end
    endtask

    task automatic run_cancel_before_ar;
        begin
            prepare_partial_frame(10, 32'h0000_5000);
            @(negedge clk);
            cfg_base_addr = 32'h0000_5000;
            cfg_width_pixels = 16;
            cfg_height_lines = 1;
            cfg_stride_bytes = 64;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cancel = 1'b1;
            @(negedge clk);
            cancel = 1'b0;
            wait_partial_done(1'b0, 0, 0, 0);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_while_ar_stalled;
        logic [31:0] saved_araddr;
        logic [7:0] saved_arlen;
        begin
            prepare_partial_frame(11, 32'h0000_5100);
            force_ar_stall = 1'b1;
            pulse_start(32'h0000_5100, 16, 1, 64);
            while (!m_axi_arvalid) @(negedge clk);
            saved_araddr = m_axi_araddr;
            saved_arlen = m_axi_arlen;
            cancel = 1'b1;
            repeat (4) begin
                @(negedge clk);
                if (!m_axi_arvalid || (m_axi_araddr !== saved_araddr) ||
                    (m_axi_arlen !== saved_arlen))
                    fail("cancel withdrew or changed stalled ARVALID");
            end
            cancel = 1'b0;
            force_ar_stall = 1'b0;
            wait_partial_done(1'b0, 1, 4, 0);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_while_waiting_r;
        begin
            prepare_partial_frame(12, 32'h0000_5200);
            force_r_gap = 1'b1;
            pulse_start(32'h0000_5200, 16, 1, 64);
            while (frame_ar_count != 1) @(negedge clk);
            pulse_cancel();
            repeat (3) @(negedge clk);
            if (!busy || !m_axi_rready)
                fail("reader did not remain busy/RREADY while cancel-draining");
            force_r_gap = 1'b0;
            wait_partial_done(1'b0, 1, 4, 0);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_buffered_output;
        begin
            prepare_partial_frame(13, 32'h0000_5300);
            force_output_stall = 1'b1;
            pulse_start(32'h0000_5300, 16, 1, 64);
            while (!m_valid) @(negedge clk);
            if (frame_output_count != 0)
                fail("buffered-output cancel test emitted an early pixel");
            pulse_cancel();
            force_output_stall = 1'b0;
            wait_partial_done(1'b0, 1, 4, 0);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_early_rlast_recovery;
        begin
            prepare_partial_frame(14, 32'h0000_5400);
            inject_early_rlast_burst = 0;
            inject_early_rlast_beat = 1;
            pulse_start(32'h0000_5400, 16, 1, 64);
            wait_partial_done(1'b1, 1, 2, 4);
            inject_early_rlast_burst = -1;
            inject_early_rlast_beat = -1;
            protocol_error_case_count = protocol_error_case_count + 1;
        end
    endtask

    task automatic run_missing_rlast_recovery;
        begin
            prepare_partial_frame(15, 32'h0000_5500);
            inject_missing_rlast_burst = 0;
            pulse_start(32'h0000_5500, 16, 1, 64);
            wait_partial_done(1'b1, 1, 4, 12);
            inject_missing_rlast_burst = -1;
            protocol_error_case_count = protocol_error_case_count + 1;
        end
    endtask

    task automatic run_rresp_recovery;
        begin
            fill_frame_memory(16, 32'h0000_5600, 16, 1, 64);
            configure_model(16, 32'h0000_5600, 16, 1, 64, 0);
            model_expect_full_output = 1'b0;
            inject_early_rlast_burst = -1;
            inject_early_rlast_beat = -1;
            inject_missing_rlast_burst = -1;
            pulse_start(32'h0000_5600, 16, 1, 64);
            wait_partial_done(1'b1, 1, 4, 0);
            protocol_error_case_count = protocol_error_case_count + 1;
        end
    endtask

    task automatic run_valid_frame(
        input integer frame_id,
        input integer base,
        input integer width,
        input integer height,
        input integer stride,
        input integer error_burst,
        input integer expected_bursts
    );
        integer expected_beats;
        begin
            inject_early_rlast_burst = -1;
            inject_early_rlast_beat = -1;
            inject_missing_rlast_burst = -1;
            fill_frame_memory(frame_id, base, width, height, stride);
            configure_model(frame_id, base, width, height, stride, error_burst);
            pulse_start(base, width, height, stride);
            if (!busy)
                fail("valid start did not assert busy");

            // Live configuration ports are deliberately corrupted after the
            // accepted start; all in-flight decisions must use latched values.
            cfg_base_addr = 32'hdead_bee0;
            cfg_width_pixels = 16'd4;
            cfg_height_lines = 16'd1;
            cfg_stride_bytes = 32'd16;

            wait (done === 1'b1);
            #0.1;
            expected_beats = (width/4)*height;
            if (busy)
                fail("busy did not clear at frame completion");
            if (error !== (error_burst >= 0))
                fail("sticky error flag disagrees with injected RRESP");
            if (frame_output_count != width*height)
                fail("accepted RGB pixel count mismatch");
            if (frame_ar_count != expected_bursts)
                fail("unexpected AXI AR burst count");
            if (frame_r_beat_count != expected_beats)
                fail("AXI R beat count indicates loss or duplication");
            if (frame_error_responses != ((error_burst >= 0) ? 1 : 0))
                fail("injected RRESP error count mismatch");
            if (expected_row != height)
                fail("read burst planner did not reach the final row");
            if (!final_stall_injected || !saw_final_pixel_stall)
                fail("final-pixel downstream stall coverage was not observed");
            model_frame_active = 1'b0;

            @(posedge clk);
            #0.1;
            if (done)
                fail("done was not a single-cycle pulse");
        end
    endtask

    task automatic run_invalid_config(
        input logic [31:0] base,
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [31:0] stride
    );
        integer ar_before;
        begin
            ar_before = all_ar_count;
            model_frame_active = 1'b0;
            pulse_start(base, width, height, stride);
            wait (done === 1'b1);
            #0.1;
            if (busy || !error)
                fail("illegal configuration was not rejected with done/error");
            if (all_ar_count != ar_before)
                fail("illegal configuration emitted an AR transaction");
            @(posedge clk);
            #0.1;
            if (done)
                fail("illegal-config done was not a single-cycle pulse");
        end
    endtask

    initial begin
        wait (!rst);

        // Row zero begins one beat below 4 KiB.  Its 20 beats split 1+16+3;
        // later rows exercise max-16 and row-boundary termination.
        run_valid_frame(1, 32'h0000_0ff0, 80, 3, 384, -1, 7);

        // Restart with a different shape and independently randomized stalls.
        run_valid_frame(2, 32'h0000_2ff0, 20, 4, 96, -1, 5);

        // Safe-cancel coverage before AR, with a stalled ARVALID, while
        // waiting for R, and while a stream beat is buffered/stalled.
        run_cancel_before_ar();
        run_cancel_while_ar_stalled();
        run_cancel_while_waiting_r();
        run_cancel_buffered_output();

        // Malformed/read-error recovery must terminate rather than waiting
        // forever for an impossible RLAST position.
        run_early_rlast_recovery();
        run_missing_rlast_recovery();
        run_rresp_recovery();

        // A clean restart proves sticky cancel/error/drain state was cleared.
        run_valid_frame(17, 32'h0000_5700, 16, 1, 64, -1, 1);
        recovery_restart_count = recovery_restart_count + 1;

        run_invalid_config(32'h0000_4000, 0, 1, 16);
        run_invalid_config(32'h0000_4000, 20, 0, 80);
        run_invalid_config(32'h0000_4004, 20, 1, 80);
        run_invalid_config(32'h0000_4000, 18, 1, 80);
        run_invalid_config(32'h0000_4000, 20, 1, 84);
        run_invalid_config(32'h0000_4000, 20, 1, 64);
        run_invalid_config(32'hffff_fff0, 8, 1, 32);

        if (!saw_4k_split || !saw_max_burst)
            fail("4KiB and max-16 read-burst coverage was not observed");
        if ((ar_stall_cycles == 0) || (r_gap_cycles == 0) ||
            (r_backpressure_cycles == 0) ||
            (downstream_stall_cycles == 0) ||
            (output_hold_checks == 0) || (final_stall_cycles == 0))
            fail("random AR/R/downstream back-pressure coverage was incomplete");
        if ((cancel_case_count != 4) ||
            (protocol_error_case_count != 3) ||
            (recovery_restart_count != 1))
            fail("cancel/protocol-error/restart coverage incomplete");
        if (all_ar_count != 19)
            fail("combined valid-frame AR burst count mismatch");

        $display("C1_AXI_XRGB_FRAME_READER_PASS normal_frames=3 cancel_cases=%0d protocol_errors=%0d restart=%0d bursts=%0d ar_stall=%0d r_gap=%0d r_backpressure=%0d downstream_stall=%0d final_stall=%0d output_hold=%0d",
                 cancel_case_count, protocol_error_case_count,
                 recovery_restart_count, all_ar_count,
                 ar_stall_cycles, r_gap_cycles, r_backpressure_cycles,
                 downstream_stall_cycles, final_stall_cycles,
                 output_hold_checks);
        $finish;
    end

    initial begin
        #4_000_000;
        fail("global timeout/deadlock");
    end

endmodule
