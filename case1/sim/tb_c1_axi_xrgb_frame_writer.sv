`timescale 1ns/1ps

module tb_c1_axi_xrgb_frame_writer;

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

    logic s_valid = 1'b0;
    logic s_ready;
    logic [23:0] s_rgb = '0;
    logic s_sof = 1'b0;
    logic s_eol = 1'b0;
    logic s_eof = 1'b0;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid;
    logic m_axi_awready = 1'b0;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready = 1'b0;
    logic [1:0] m_axi_bresp = 2'b00;
    logic m_axi_bvalid = 1'b0;
    logic m_axi_bready;

    logic [7:0] byte_memory [0:65535];

    integer model_frame_id = 0;
    integer model_base = 0;
    integer model_width = 0;
    integer model_height = 0;
    integer model_stride = 0;
    integer model_line_bytes = 0;
    integer inject_error_burst = -1;
    logic model_frame_active = 1'b0;

    integer expected_next_addr = 0;
    integer expected_row = 0;
    integer expected_row_bytes_remaining = 0;
    integer frame_aw_count = 0;
    integer frame_w_beat_count = 0;
    integer frame_b_count = 0;
    integer frame_error_responses = 0;
    integer all_aw_count = 0;
    integer source_accept_count = 0;

    logic aw_active = 1'b0;
    integer active_aw_addr = 0;
    integer active_aw_beats = 0;
    integer active_w_index = 0;
    logic [1:0] active_bresp = 2'b00;
    logic response_pending = 1'b0;
    integer response_delay = 0;
    logic [1:0] pending_bresp = 2'b00;

    logic [31:0] bfm_prng = 32'h8f31_6ad7;
    integer aw_stall_cycles = 0;
    integer w_stall_cycles = 0;
    integer b_delay_cycles = 0;
    integer source_hold_checks = 0;
    logic saw_4k_split = 1'b0;
    logic saw_max_burst = 1'b0;
    logic force_aw_stall = 1'b0;
    logic force_aw_accept = 1'b0;
    logic force_w_stall = 1'b0;
    logic force_b_hold = 1'b0;
    integer cancel_case_count = 0;
    integer recovery_restart_count = 0;

    logic held_source = 1'b0;
    logic [23:0] held_source_rgb = '0;
    logic held_source_sof = 1'b0;
    logic held_source_eol = 1'b0;
    logic held_source_eof = 1'b0;
    logic held_aw = 1'b0;
    logic [31:0] held_awaddr = '0;
    logic [7:0] held_awlen = '0;
    logic [2:0] held_awsize = '0;
    logic [1:0] held_awburst = '0;
    logic held_w = 1'b0;
    logic [127:0] held_wdata = '0;
    logic [15:0] held_wstrb = '0;
    logic held_wlast = 1'b0;

    integer planned_beats;
    integer burst_bytes;
    integer byte_index;
    integer memory_address;
    integer initialize_index;

    c1_axi_xrgb_frame_writer dut (
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
        .s_valid,
        .s_ready,
        .s_rgb,
        .s_sof,
        .s_eol,
        .s_eof,
        .m_axi_awaddr,
        .m_axi_awlen,
        .m_axi_awsize,
        .m_axi_awburst,
        .m_axi_awvalid,
        .m_axi_awready,
        .m_axi_wdata,
        .m_axi_wstrb,
        .m_axi_wlast,
        .m_axi_wvalid,
        .m_axi_wready,
        .m_axi_bresp,
        .m_axi_bvalid,
        .m_axi_bready
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

    task automatic fail(input string message);
        begin
            $display("C1_AXI_XRGB_FRAME_WRITER_FAIL time=%0t frame=%0d aw=%0d w=%0d b=%0d src=%0d: %s",
                     $time, model_frame_id, frame_aw_count,
                     frame_w_beat_count, frame_b_count,
                     source_accept_count, message);
            $fatal(1);
            $finish;
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

    // Source-side ready/valid hold contract and accepted-pixel count.
    always @(posedge clk) begin
        if (rst) begin
            held_source = 1'b0;
            source_accept_count = 0;
            source_hold_checks = 0;
        end else begin
            if (held_source) begin
                source_hold_checks = source_hold_checks + 1;
                if (!s_valid || (s_rgb !== held_source_rgb) ||
                    (s_sof !== held_source_sof) ||
                    (s_eol !== held_source_eol) ||
                    (s_eof !== held_source_eof))
                    fail("source changed RGB/markers while back-pressured");
            end
            if (s_valid && s_ready)
                source_accept_count = source_accept_count + 1;
            held_source = s_valid && !s_ready;
            held_source_rgb = s_rgb;
            held_source_sof = s_sof;
            held_source_eol = s_eol;
            held_source_eof = s_eof;
        end
    end

    // Random-delay, byte-addressed AXI write slave model.  The master under
    // test permits one outstanding burst. This address-indexed memory model
    // only accepts W after AW; the independent-channel test separately covers
    // W-before-AW slaves. Both channels are checked for payload stability.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_awready <= 1'b0;
            m_axi_wready <= 1'b0;
            m_axi_bvalid <= 1'b0;
            m_axi_bresp <= 2'b00;
            bfm_prng <= 32'h8f31_6ad7;
            aw_active = 1'b0;
            response_pending = 1'b0;
            response_delay = 0;
            held_aw = 1'b0;
            held_w = 1'b0;
        end else begin
            bfm_prng <= prng_next(bfm_prng);
            // About 25% AW acceptance and 50% W acceptance after an address
            // is known. Do not advertise WREADY without storage for early W.
            if (force_aw_accept)
                m_axi_awready <= 1'b1;
            else if (force_aw_stall)
                m_axi_awready <= 1'b0;
            else
                m_axi_awready <= bfm_prng[0] && bfm_prng[4];
            if (force_w_stall)
                m_axi_wready <= 1'b0;
            else
                m_axi_wready <= aw_active && (bfm_prng[1] ^ bfm_prng[7]);

            if (held_aw) begin
                if (!m_axi_awvalid || (m_axi_awaddr !== held_awaddr) ||
                    (m_axi_awlen !== held_awlen) ||
                    (m_axi_awsize !== held_awsize) ||
                    (m_axi_awburst !== held_awburst))
                    fail("AW payload changed before AWREADY handshake");
            end
            if (held_w) begin
                if (!m_axi_wvalid || (m_axi_wdata !== held_wdata) ||
                    (m_axi_wstrb !== held_wstrb) ||
                    (m_axi_wlast !== held_wlast))
                    fail("W payload changed before WREADY handshake");
            end

            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_cycles = aw_stall_cycles + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_cycles = w_stall_cycles + 1;

            if (m_axi_awvalid && m_axi_awready) begin
                if (!model_frame_active)
                    fail("AW issued without an active frame model");
                if (aw_active || response_pending || m_axi_bvalid)
                    fail("new AW issued before the prior B response completed");
                if (expected_row >= model_height)
                    fail("extra AW issued after all rows were planned");
                if (m_axi_awaddr !== expected_next_addr[31:0])
                    fail("AW address skipped, duplicated, or reordered a burst");
                if (m_axi_awsize !== 3'd4)
                    fail("AWSIZE is not 16 bytes");
                if (m_axi_awburst !== 2'b01)
                    fail("AWBURST is not INCR");
                if (m_axi_awlen > 8'd15)
                    fail("burst exceeds 16 beats");

                planned_beats = expected_burst_beats(
                    expected_next_addr, expected_row_bytes_remaining);
                if ((m_axi_awlen + 1) !== planned_beats)
                    fail("AWLEN does not match row/4KiB/max16 plan");
                burst_bytes = planned_beats * 16;
                if (((m_axi_awaddr & 4095) + burst_bytes) > 4096)
                    fail("burst crosses a 4KiB boundary");
                if ((m_axi_awaddr & 15) != 0)
                    fail("AWADDR is not 16-byte aligned");
                if (planned_beats == 16)
                    saw_max_burst = 1'b1;
                if (((m_axi_awaddr & 4095) != 0) &&
                    (((m_axi_awaddr & 4095) + burst_bytes) == 4096))
                    saw_4k_split = 1'b1;

                aw_active = 1'b1;
                active_aw_addr = m_axi_awaddr;
                active_aw_beats = planned_beats;
                active_w_index = 0;
                active_bresp = (frame_aw_count == inject_error_burst) ?
                               2'b10 : 2'b00;
                frame_aw_count = frame_aw_count + 1;
                all_aw_count = all_aw_count + 1;

                if (expected_row_bytes_remaining == burst_bytes) begin
                    expected_row = expected_row + 1;
                    if (expected_row < model_height) begin
                        expected_next_addr =
                            model_base + expected_row*model_stride;
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

            if (m_axi_wvalid && m_axi_wready) begin
                if (!aw_active)
                    fail("W beat accepted without an active AW transaction");
                if (m_axi_wstrb !== 16'hffff)
                    fail("WSTRB is not full for a complete four-pixel beat");
                if (m_axi_wlast !== (active_w_index == active_aw_beats-1))
                    fail("WLAST does not identify the final planned beat");

                for (byte_index = 0; byte_index < 16;
                     byte_index = byte_index + 1) begin
                    memory_address = active_aw_addr +
                                     active_w_index*16 + byte_index;
                    if ((memory_address < 0) || (memory_address >= 65536))
                        fail("BFM memory address outside test range");
                    byte_memory[memory_address] =
                        m_axi_wdata[byte_index*8 +: 8];
                end
                frame_w_beat_count = frame_w_beat_count + 1;

                if (m_axi_wlast) begin
                    aw_active = 1'b0;
                    response_pending = 1'b1;
                    // One through eight cycles, fixed-seed pseudo-random.
                    response_delay = 1 + bfm_prng[10:8];
                    pending_bresp = active_bresp;
                end else begin
                    active_w_index = active_w_index + 1;
                end
            end

            if (m_axi_bvalid && m_axi_bready) begin
                if (m_axi_bresp != 2'b00)
                    frame_error_responses = frame_error_responses + 1;
                frame_b_count = frame_b_count + 1;
                m_axi_bvalid <= 1'b0;
            end else if (!m_axi_bvalid && response_pending) begin
                if (force_b_hold) begin
                    b_delay_cycles = b_delay_cycles + 1;
                end else if (response_delay == 0) begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bresp <= pending_bresp;
                    response_pending = 1'b0;
                end else begin
                    response_delay = response_delay - 1;
                    b_delay_cycles = b_delay_cycles + 1;
                end
            end

            held_aw = m_axi_awvalid && !m_axi_awready;
            held_awaddr = m_axi_awaddr;
            held_awlen = m_axi_awlen;
            held_awsize = m_axi_awsize;
            held_awburst = m_axi_awburst;
            held_w = m_axi_wvalid && !m_axi_wready;
            held_wdata = m_axi_wdata;
            held_wstrb = m_axi_wstrb;
            held_wlast = m_axi_wlast;

            if (done && model_frame_active) begin
                if (frame_b_count != frame_aw_count)
                    fail("done asserted before every AW received a B response");
                if (busy)
                    fail("busy remained asserted with done");
            end
        end
    end

    task automatic clear_frame_region(
        input integer base,
        input integer height,
        input integer stride
    );
        integer y;
        integer offset;
        begin
            for (y = 0; y < height; y = y + 1)
                for (offset = 0; offset < stride; offset = offset + 1)
                    byte_memory[base + y*stride + offset] = MEMORY_SENTINEL;
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
            if (aw_active || response_pending || m_axi_bvalid)
                fail("new frame configured while prior AXI response remained active");
            model_frame_id = frame_id;
            model_base = base;
            model_width = width;
            model_height = height;
            model_stride = stride;
            model_line_bytes = width*4;
            inject_error_burst = error_burst;
            expected_next_addr = base;
            expected_row = 0;
            expected_row_bytes_remaining = width*4;
            frame_aw_count = 0;
            frame_w_beat_count = 0;
            frame_b_count = 0;
            frame_error_responses = 0;
            source_accept_count = 0;
            model_frame_active = 1'b1;
        end
    endtask

    task automatic pulse_start(
        input integer base,
        input integer width,
        input integer height,
        input integer stride
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

    task automatic send_prefix_pixels(
        input integer frame_id,
        input integer width,
        input integer count
    );
        integer index;
        integer x;
        integer y;
        logic accepted;
        begin
            for (index = 0; index < count; index = index + 1) begin
                x = index % width;
                y = index / width;
                @(negedge clk);
                s_valid = 1'b1;
                s_rgb = pixel_value(frame_id, x, y);
                s_sof = (x == 0) && (y == 0);
                s_eol = (x == width-1);
                s_eof = 1'b0;
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (s_valid && s_ready)
                        accepted = 1'b1;
                end
            end
            @(negedge clk);
            s_valid = 1'b0;
            s_rgb = '0;
            s_sof = 1'b0;
            s_eol = 1'b0;
            s_eof = 1'b0;
        end
    endtask

    task automatic verify_frame_untouched(
        input integer base,
        input integer height,
        input integer stride
    );
        integer y;
        integer offset;
        begin
            for (y = 0; y < height; y = y + 1)
                for (offset = 0; offset < stride; offset = offset + 1)
                    if (byte_memory[base + y*stride + offset] !==
                        MEMORY_SENTINEL)
                        fail("pre-AW cancel modified memory");
        end
    endtask

    task automatic prepare_cancel_frame(
        input integer frame_id,
        input integer base,
        input integer error_burst
    );
        begin
            clear_frame_region(base, 1, 64);
            configure_model(frame_id, base, 16, 1, 64, error_burst);
        end
    endtask

    task automatic wait_cancel_done(
        input logic expected_error,
        input integer expected_aw,
        input integer expected_w,
        input integer expected_b,
        input integer expected_source
    );
        integer guard;
        begin
            guard = 0;
            while (done !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000)
                    fail("cancelled writer operation did not complete");
            end
            #0.1;
            if (busy)
                fail("busy remained high at cancelled completion");
            if (error !== expected_error)
                fail("cancelled writer sticky error mismatch");
            if ((frame_aw_count != expected_aw) ||
                (frame_w_beat_count != expected_w) ||
                (frame_b_count != expected_b))
                fail("cancelled writer AXI transaction count mismatch");
            if (source_accept_count != expected_source)
                fail("cancelled writer source acceptance mismatch");
            if (aw_active || response_pending || m_axi_bvalid)
                fail("cancelled writer completed before AXI drain");
            model_frame_active = 1'b0;
            @(posedge clk);
            #0.1;
            if (done)
                fail("cancelled writer done was not a single-cycle pulse");
        end
    endtask

    task automatic run_idle_cancel_priority;
        integer aw_before;
        begin
            aw_before = all_aw_count;
            @(negedge clk);
            cfg_base_addr = 32'h0000_5800;
            cfg_width_pixels = 16;
            cfg_height_lines = 1;
            cfg_stride_bytes = 64;
            start = 1'b1;
            cancel = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cancel = 1'b0;
            repeat (2) @(posedge clk);
            #0.1;
            if (busy || done || (all_aw_count != aw_before))
                fail("idle cancel did not take priority over start");
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_before_capture;
        begin
            prepare_cancel_frame(20, 32'h0000_5900, -1);
            @(negedge clk);
            cfg_base_addr = 32'h0000_5900;
            cfg_width_pixels = 16;
            cfg_height_lines = 1;
            cfg_stride_bytes = 64;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cancel = 1'b1;
            @(negedge clk);
            cancel = 1'b0;
            wait_cancel_done(1'b0, 0, 0, 0, 0);
            verify_frame_untouched(32'h0000_5900, 1, 64);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_partial_capture;
        begin
            prepare_cancel_frame(21, 32'h0000_5a00, -1);
            pulse_start(32'h0000_5a00, 16, 1, 64);
            send_prefix_pixels(21, 16, 3);
            pulse_cancel();
            wait_cancel_done(1'b0, 0, 0, 0, 3);
            verify_frame_untouched(32'h0000_5a00, 1, 64);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_aw_handshake;
        logic [31:0] saved_awaddr;
        logic [7:0] saved_awlen;
        begin
            prepare_cancel_frame(22, 32'h0000_5b00, -1);
            force_aw_stall = 1'b1;
            pulse_start(32'h0000_5b00, 16, 1, 64);
            send_frame_pixels(22, 16, 1);
            while (!m_axi_awvalid) @(negedge clk);
            saved_awaddr = m_axi_awaddr;
            saved_awlen = m_axi_awlen;
            repeat (3) begin
                @(negedge clk);
                if (!m_axi_awvalid || (m_axi_awaddr !== saved_awaddr) ||
                    (m_axi_awlen !== saved_awlen))
                    fail("stalled AW changed before cancel");
            end
            cancel = 1'b1;
            force_aw_stall = 1'b0;
            force_aw_accept = 1'b1;
            while (frame_aw_count != 1) @(negedge clk);
            cancel = 1'b0;
            force_aw_accept = 1'b0;
            wait_cancel_done(1'b0, 1, 4, 1, 16);
            verify_frame_memory(22, 32'h0000_5b00, 16, 1, 64);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_stalled_w;
        begin
            prepare_cancel_frame(23, 32'h0000_5c00, -1);
            force_w_stall = 1'b1;
            pulse_start(32'h0000_5c00, 16, 1, 64);
            send_frame_pixels(23, 16, 1);
            while (!m_axi_wvalid) @(negedge clk);
            pulse_cancel();
            repeat (3) @(negedge clk);
            if (!busy || !m_axi_wvalid || s_ready)
                fail("cancelled committed W burst was not held/draining");
            force_w_stall = 1'b0;
            wait_cancel_done(1'b0, 1, 4, 1, 16);
            verify_frame_memory(23, 32'h0000_5c00, 16, 1, 64);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic run_cancel_waiting_b_with_error;
        begin
            prepare_cancel_frame(24, 32'h0000_5d00, 0);
            force_b_hold = 1'b1;
            pulse_start(32'h0000_5d00, 16, 1, 64);
            send_frame_pixels(24, 16, 1);
            while (frame_w_beat_count != 4) @(negedge clk);
            pulse_cancel();
            repeat (3) @(negedge clk);
            if (!busy || !m_axi_bready)
                fail("cancelled writer did not wait for committed BRESP");
            force_b_hold = 1'b0;
            wait_cancel_done(1'b1, 1, 4, 1, 16);
            verify_frame_memory(24, 32'h0000_5d00, 16, 1, 64);
            cancel_case_count = cancel_case_count + 1;
        end
    endtask

    task automatic send_frame_pixels(
        input integer frame_id,
        input integer width,
        input integer height
    );
        integer x;
        integer y;
        logic accepted;
        begin
            for (y = 0; y < height; y = y + 1) begin
                for (x = 0; x < width; x = x + 1) begin
                    @(negedge clk);
                    s_valid = 1'b1;
                    s_rgb = pixel_value(frame_id, x, y);
                    s_sof = (x == 0) && (y == 0);
                    s_eol = (x == width-1);
                    s_eof = (x == width-1) && (y == height-1);
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (s_valid && s_ready)
                            accepted = 1'b1;
                    end
                end
            end
            @(negedge clk);
            s_valid = 1'b0;
            s_rgb = '0;
            s_sof = 1'b0;
            s_eol = 1'b0;
            s_eof = 1'b0;
        end
    endtask

    task automatic verify_frame_memory(
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
        logic [23:0] expected_rgb;
        begin
            for (y = 0; y < height; y = y + 1) begin
                for (x = 0; x < width; x = x + 1) begin
                    address = base + y*stride + x*4;
                    expected_rgb = pixel_value(frame_id, x, y);
                    if ((byte_memory[address+0] !== expected_rgb[7:0]) ||
                        (byte_memory[address+1] !== expected_rgb[15:8]) ||
                        (byte_memory[address+2] !== expected_rgb[23:16]) ||
                        (byte_memory[address+3] !== 8'h00))
                        fail("byte-exact little-endian XRGB memory mismatch");
                end
                for (offset = width*4; offset < stride; offset = offset + 1)
                    if (byte_memory[base + y*stride + offset] !==
                        MEMORY_SENTINEL)
                        fail("row padding was modified");
            end
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
            clear_frame_region(base, height, stride);
            configure_model(frame_id, base, width, height, stride, error_burst);
            pulse_start(base, width, height, stride);
            if (!busy)
                fail("valid start did not assert busy");
            // Scramble the live configuration ports immediately after start;
            // every subsequent address/shape decision must use the latched
            // frame descriptor rather than these changing inputs.
            cfg_base_addr = 32'hdead_bee0;
            cfg_width_pixels = 16'd4;
            cfg_height_lines = 16'd1;
            cfg_stride_bytes = 32'd16;

            send_frame_pixels(frame_id, width, height);
            wait (done === 1'b1);
            #0.1;
            expected_beats = (width/4)*height;
            if (busy)
                fail("busy did not clear at frame completion");
            if (error !== (error_burst >= 0))
                fail("sticky error flag disagrees with injected BRESP");
            if (source_accept_count != width*height)
                fail("accepted input pixel count mismatch");
            if (frame_aw_count != expected_bursts)
                fail("unexpected number of AXI bursts");
            if (frame_w_beat_count != expected_beats)
                fail("AXI W beat count indicates loss or duplication");
            if (frame_b_count != frame_aw_count)
                fail("B response count does not match AW count");
            if (frame_error_responses != ((error_burst >= 0) ? 1 : 0))
                fail("injected BRESP error count mismatch");
            if (expected_row != height)
                fail("burst planner did not reach the final row");
            verify_frame_memory(frame_id, base, width, height, stride);
            model_frame_active = 1'b0;

            @(posedge clk);
            #0.1;
            if (done)
                fail("done was not a single-cycle pulse");
        end
    endtask

    task automatic run_invalid_config(
        input integer base,
        input integer width,
        input integer height,
        input integer stride
    );
        integer aw_before;
        begin
            aw_before = all_aw_count;
            model_frame_active = 1'b0;
            pulse_start(base, width, height, stride);
            wait (done === 1'b1);
            #0.1;
            if (busy || !error)
                fail("illegal configuration was not rejected with done/error");
            if (all_aw_count != aw_before)
                fail("illegal configuration emitted an AW transaction");
            @(posedge clk);
            #0.1;
            if (done)
                fail("illegal-config done was not a single-cycle pulse");
        end
    endtask

    initial begin
        wait (!rst);
        // Row zero begins one beat below 4KiB.  Its 20 beats must split into
        // 1 + 16 + 3, while subsequent rows exercise max16 and row splits.
        run_valid_frame(1, 32'h0000_0ff0, 80, 3, 384, -1, 7);

        // A second frame verifies restart and sticky handling of a non-OKAY B
        // response while all memory writes still complete exactly.
        run_valid_frame(2, 32'h0000_2ff0, 20, 4, 96, 2, 5);

        // Cancellation is exercised in idle/start priority, before capture,
        // during partial capture, with a proposed/stalled AW, during W, and
        // while waiting for B.  Committed bursts must always finish W+B.
        run_idle_cancel_priority();
        run_cancel_before_capture();
        run_cancel_partial_capture();
        run_cancel_aw_handshake();
        run_cancel_stalled_w();
        run_cancel_waiting_b_with_error();

        // Clean restart after both pre-AW discard and committed-BRESP error.
        run_valid_frame(25, 32'h0000_5e00, 16, 1, 64, -1, 1);
        recovery_restart_count = recovery_restart_count + 1;

        // Explicitly exercise the documented configuration constraints.
        run_invalid_config(32'h0000_4000, 18, 1, 80);
        run_invalid_config(32'h0000_4000, 20, 1, 84);
        run_invalid_config(32'hffff_fff0, 4, 2, 16);

        if (!saw_4k_split || !saw_max_burst)
            fail("4KiB and max-16 burst coverage was not observed");
        if ((aw_stall_cycles == 0) || (w_stall_cycles == 0) ||
            (b_delay_cycles == 0) || (source_hold_checks == 0))
            fail("random AXI delay/back-pressure coverage was not observed");
        if ((cancel_case_count != 6) || (recovery_restart_count != 1))
            fail("writer cancel/restart coverage incomplete");
        if (all_aw_count != 16)
            fail("combined valid-frame burst count mismatch");

        $display("C1_AXI_XRGB_FRAME_WRITER_PASS normal_frames=3 cancel_cases=%0d restart=%0d bursts=%0d aw_stall=%0d w_stall=%0d b_delay=%0d source_hold=%0d",
                 cancel_case_count, recovery_restart_count, all_aw_count,
                 aw_stall_cycles, w_stall_cycles,
                 b_delay_cycles, source_hold_checks);
        $finish;
    end

    initial begin
        #2_000_000;
        fail("global timeout/deadlock");
    end

endmodule
