`timescale 1ns/1ps

// Native capture/DMA staged preflight.
//
// This test stops at the real c1_axi_xrgb_frame_writer boundary.  It drives
// three serialized 640x480 RGB24 frames into the writer, using the native
// three-input-slot map, and checks every AW/W/B transaction against an
// address-aware AXI write BFM.  The BFM stores complete 128-bit lines in an
// associative map; a post-frame readback compares every XRGB byte and proves
// that the three slots do not alias.  No camera frontend, CNN, frame manager,
// shared AXI arbiter, or display reader is instantiated here.
module tb_c1_r1_native_capture_writer;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer STRIDE = FRAME_W * 4;
    localparam integer ROW_BEATS = FRAME_W / 4;
    localparam integer FRAME_BYTES = STRIDE * FRAME_H;
    localparam integer FRAME_SLOT_BYTES = 32'h0012_c000;
    localparam integer EXPECTED_BURSTS_PER_FRAME = FRAME_H * ((ROW_BEATS + 15) / 16);
    localparam integer EXPECTED_BEATS_PER_FRAME = FRAME_H * ROW_BEATS;
    localparam logic [31:0] INPUT_BASE = 32'h0010_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic start = 1'b0;
    logic cancel = 1'b0;
    logic [31:0] cfg_base_addr = INPUT_BASE;
    logic [15:0] cfg_width_pixels = FRAME_W;
    logic [15:0] cfg_height_lines = FRAME_H;
    logic [31:0] cfg_stride_bytes = STRIDE;
    logic busy, done, error;

    logic s_valid = 1'b0;
    logic s_ready;
    logic [23:0] s_rgb = '0;
    logic s_sof = 1'b0, s_eol = 1'b0, s_eof = 1'b0;

    logic [31:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic awvalid, awready = 1'b0;
    logic [127:0] wdata;
    logic [15:0] wstrb;
    logic wlast, wvalid, wready = 1'b0;
    logic [1:0] bresp = 2'b00;
    logic bvalid = 1'b0, bready;

    c1_axi_xrgb_frame_writer dut (
        .clk(clk), .rst(rst), .start(start), .cancel(cancel),
        .cfg_base_addr(cfg_base_addr),
        .cfg_width_pixels(cfg_width_pixels),
        .cfg_height_lines(cfg_height_lines),
        .cfg_stride_bytes(cfg_stride_bytes),
        .busy(busy), .done(done), .error(error),
        .s_valid(s_valid), .s_ready(s_ready), .s_rgb(s_rgb),
        .s_sof(s_sof), .s_eol(s_eol), .s_eof(s_eof),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    function automatic [31:0] slot_base(input integer slot);
        slot_base = INPUT_BASE + (slot * FRAME_SLOT_BYTES);
    endfunction

    // The source pattern is a reversible function of byte address and a
    // frame-specific tone.  The BFM can therefore verify every packed lane
    // without retaining a second pixel stream model.
    function automatic [23:0] pixel_pattern(
        input logic [31:0] pixel_addr,
        input integer tone
    );
        logic [31:0] mixed;
        begin
            mixed = pixel_addr ^ (32'h005a_31c7 + (tone * 32'h0001_0101));
            pixel_pattern = mixed[23:0];
        end
    endfunction

    function automatic [31:0] expected_word(
        input logic [31:0] pixel_addr,
        input integer tone
    );
        expected_word = {8'h00, pixel_pattern(pixel_addr, tone)};
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

    // Native writeback storage: one entry per complete AXI128 line.
    logic [127:0] mem_line_assoc [longint unsigned];

    integer cycle_count = 0;
    integer frame_index_cfg = 0;
    integer frame_tone_cfg = 0;
    integer active_tone = 0;
    logic [31:0] active_base = INPUT_BASE;
    logic frame_model_active = 1'b0;

    integer expected_next_addr = INPUT_BASE;
    integer expected_row = 0;
    integer expected_row_bytes_remaining = FRAME_W * 4;
    integer frame_aw_count = 0, frame_w_count = 0, frame_b_count = 0;
    integer total_aw_count = 0, total_w_count = 0, total_b_count = 0;
    integer frame_source_count = 0;
    integer frame_done_count = 0;
    integer arith_readback_count = 0;
    integer aw_stall_count = 0, w_stall_count = 0;
    integer b_delay_count = 0;

    logic aw_active = 1'b0;
    logic [31:0] active_aw_addr = '0;
    integer active_aw_beats = 0;
    integer active_w_index = 0;
    logic response_pending = 1'b0;
    integer response_delay = 0;
    logic [127:0] active_wdata_expected = '0;
    logic [1:0] pending_bresp = 2'b00;

    always_comb begin
        // Independent, deterministic stalls.  The writer has only one
        // outstanding burst, so AWREADY may be offered only when no W/B is
        // in flight; WREADY remains independently backpressured.
        awready = !aw_active && !response_pending && !bvalid &&
                  ((cycle_count % 11) != 0);
        wready = aw_active && !response_pending && !bvalid &&
                 ((cycle_count % 7) != 0);
    end

    task automatic fail(input string message);
        begin
            $display("C1_R1_NATIVE_CAPTURE_WRITER_FAIL time=%0t frame=%0d base=%08x aw=%0d w=%0d b=%0d src=%0d: %s",
                     $time, frame_index_cfg, active_base,
                     frame_aw_count, frame_w_count, frame_b_count,
                     frame_source_count, message);
            $fatal(1);
        end
    endtask

    always @(posedge clk) begin : axi_write_bfm
        integer planned_beats;
        integer burst_bytes;
        integer lane;
        integer byte_lane;
        integer write_address;
        longint unsigned assoc_key;
        logic [127:0] expected_data;
        logic [31:0] expected_pixel_addr;
        if (rst) begin
            cycle_count <= 0;
            aw_active <= 1'b0;
            response_pending <= 1'b0;
            bvalid <= 1'b0;
            bresp <= 2'b00;
            active_w_index <= 0;
            frame_aw_count <= 0;
            frame_w_count <= 0;
            frame_b_count <= 0;
            total_aw_count <= 0;
            total_w_count <= 0;
            total_b_count <= 0;
            aw_stall_count <= 0;
            w_stall_count <= 0;
            b_delay_count <= 0;
            expected_next_addr <= INPUT_BASE;
            expected_row <= 0;
            expected_row_bytes_remaining <= FRAME_W * 4;
        end else begin
            cycle_count <= cycle_count + 1;
            if (awvalid && !awready)
                aw_stall_count <= aw_stall_count + 1;
            if (wvalid && !wready)
                w_stall_count <= w_stall_count + 1;

            // The frame task configures base/tone before the start edge.  The
            // BFM latches those values at the same edge as the writer.
            if (start && !busy) begin
                active_base <= cfg_base_addr;
                active_tone <= frame_tone_cfg;
                expected_next_addr <= cfg_base_addr;
                expected_row <= 0;
                expected_row_bytes_remaining <= FRAME_W * 4;
                frame_aw_count <= 0;
                frame_w_count <= 0;
                frame_b_count <= 0;
                frame_source_count <= 0;
                frame_model_active <= 1'b1;
            end

            if (awvalid && awready) begin
                if (!frame_model_active)
                    fail("AW issued without an active native frame model");
                if (aw_active || response_pending || bvalid)
                    fail("new AW issued before previous B response");
                if (awaddr !== expected_next_addr[31:0])
                    fail("AW address sequence mismatch");
                if ((awsize !== 3'd4) || (awburst !== 2'b01) ||
                    (awaddr[3:0] !== 4'd0))
                    fail("AW attributes/alignment invalid");
                if (awlen > 8'd15)
                    fail("AW burst exceeds 16 beats");

                planned_beats = expected_burst_beats(
                    expected_next_addr, expected_row_bytes_remaining);
                if ((awlen + 1) != planned_beats)
                    fail("AWLEN does not match row/max16 plan");
                burst_bytes = planned_beats * 16;
                if (((awaddr[11:0]) + burst_bytes) > 4096)
                    fail("AW burst crosses a 4KiB boundary");
                if ((awaddr + burst_bytes) >
                    (active_base + ((expected_row + 1) * STRIDE)))
                    fail("AW burst crosses an active row boundary");

                aw_active <= 1'b1;
                active_aw_addr <= awaddr;
                active_aw_beats <= planned_beats;
                active_w_index <= 0;
                frame_aw_count <= frame_aw_count + 1;
                total_aw_count <= total_aw_count + 1;

                if (expected_row_bytes_remaining == burst_bytes) begin
                    expected_row <= expected_row + 1;
                    if ((expected_row + 1) < FRAME_H) begin
                        expected_next_addr <= active_base +
                                              ((expected_row + 1) * STRIDE);
                        expected_row_bytes_remaining <= FRAME_W * 4;
                    end else begin
                        expected_row_bytes_remaining <= 0;
                    end
                end else begin
                    expected_next_addr <= expected_next_addr + burst_bytes;
                    expected_row_bytes_remaining <=
                        expected_row_bytes_remaining - burst_bytes;
                end
            end

            if (wvalid && wready) begin
                if (!aw_active)
                    fail("W accepted without an active AW");
                if (wstrb !== 16'hffff)
                    fail("WSTRB is not full");
                if (wlast !== (active_w_index == active_aw_beats - 1))
                    fail("WLAST mismatch");

                expected_data = '0;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    expected_pixel_addr = active_aw_addr +
                                           (active_w_index * 16) +
                                           (lane * 4);
                    expected_data[lane*32 +: 32] =
                        expected_word(expected_pixel_addr, active_tone);
                end
                if (wdata !== expected_data)
                    fail("packed WDATA lane/pixel mismatch");

                assoc_key = (active_aw_addr + active_w_index*16) >> 4;
                if (!mem_line_assoc.exists(assoc_key))
                    mem_line_assoc[assoc_key] = '0;
                for (byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1)
                    if (wstrb[byte_lane])
                        mem_line_assoc[assoc_key][byte_lane*8 +: 8] =
                            wdata[byte_lane*8 +: 8];

                frame_w_count <= frame_w_count + 1;
                total_w_count <= total_w_count + 1;
                if (wlast) begin
                    aw_active <= 1'b0;
                    response_pending <= 1'b1;
                    response_delay <= 1 + (cycle_count % 5);
                    pending_bresp <= 2'b00;
                end else begin
                    active_w_index <= active_w_index + 1;
                end
            end

            if (bvalid && bready) begin
                bvalid <= 1'b0;
                frame_b_count <= frame_b_count + 1;
                total_b_count <= total_b_count + 1;
            end else if (!bvalid && response_pending) begin
                if (response_delay > 0) begin
                    response_delay <= response_delay - 1;
                    b_delay_count <= b_delay_count + 1;
                end else begin
                    bvalid <= 1'b1;
                    bresp <= pending_bresp;
                    response_pending <= 1'b0;
                end
            end
        end
    end

    // Source-side ready/valid hold and accepted-pixel accounting.
    logic source_held = 1'b0;
    logic [23:0] held_rgb = '0;
    logic held_sof = 1'b0, held_eol = 1'b0, held_eof = 1'b0;
    integer source_hold_count = 0;
    always @(posedge clk) begin
        if (rst) begin
            source_held <= 1'b0;
            source_hold_count <= 0;
        end else begin
            if (source_held) begin
                if (!s_valid || (s_rgb !== held_rgb) ||
                    (s_sof !== held_sof) || (s_eol !== held_eol) ||
                    (s_eof !== held_eof))
                    fail("source payload changed while s_ready was low");
                source_hold_count <= source_hold_count + 1;
            end
            source_held <= s_valid && !s_ready;
            held_rgb <= s_rgb;
            held_sof <= s_sof;
            held_eol <= s_eol;
            held_eof <= s_eof;
            if (s_valid && s_ready)
                frame_source_count <= frame_source_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst && done)
            frame_done_count <= frame_done_count + 1;
        if (!rst && error)
            fail("writer asserted sticky error during a valid native frame");
    end

    task automatic pulse_start(input logic [31:0] base);
        begin
            @(negedge clk);
            cfg_base_addr <= base;
            cfg_width_pixels <= FRAME_W;
            cfg_height_lines <= FRAME_H;
            cfg_stride_bytes <= STRIDE;
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;
        end
    endtask

    task automatic send_native_frame(input logic [31:0] base, input integer tone);
        integer x, y;
        logic accepted;
        begin
            for (y = 0; y < FRAME_H; y = y + 1) begin
                for (x = 0; x < FRAME_W; x = x + 1) begin
                    @(negedge clk);
                    s_valid <= 1'b1;
                    s_rgb <= pixel_pattern(base + (y * STRIDE) + (x * 4), tone);
                    s_sof <= (x == 0) && (y == 0);
                    s_eol <= (x == FRAME_W - 1);
                    s_eof <= (x == FRAME_W - 1) && (y == FRAME_H - 1);
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (s_valid && s_ready)
                            accepted = 1'b1;
                    end
                end
            end
            @(negedge clk);
            s_valid <= 1'b0;
            s_rgb <= '0;
            s_sof <= 1'b0;
            s_eol <= 1'b0;
            s_eof <= 1'b0;
        end
    endtask

    task automatic readback_frame(
        input logic [31:0] base,
        input integer tone
    );
        integer x, y, lane;
        longint unsigned key;
        logic [127:0] line;
        logic [31:0] pixel_addr;
        begin
            for (y = 0; y < FRAME_H; y = y + 1) begin
                for (x = 0; x < FRAME_W; x = x + 1) begin
                    pixel_addr = base + (y * STRIDE) + (x * 4);
                    key = pixel_addr >> 4;
                    if (!mem_line_assoc.exists(key))
                        fail("readback line missing from associative DDR store");
                    line = mem_line_assoc[key];
                    lane = x & 3;
                    if (line[lane*32 +: 32] !==
                        expected_word(pixel_addr, tone))
                        fail("readback XRGB pixel mismatch");
                    arith_readback_count = arith_readback_count + 1;
                end
            end
        end
    endtask

    task automatic run_frame(
        input integer slot,
        input integer tone
    );
        integer before_done;
        integer guard;
        logic [31:0] base;
        begin
            base = slot_base(slot);
            frame_index_cfg = slot;
            frame_tone_cfg = tone;
            if (aw_active || response_pending || bvalid)
                fail("new native slot started before prior B drained");
            frame_model_active = 1'b0;
            before_done = frame_done_count;
            pulse_start(base);
            guard = 0;
            while (!busy) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    fail("native writer did not assert busy after start");
            end
            send_native_frame(base, tone);
            guard = 0;
            while (frame_done_count == before_done) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 20_000_000)
                    fail("native writer frame timed out");
            end
            #0.1;
            if (busy || error)
                fail("native writer completion busy/error mismatch");
            if (frame_source_count != FRAME_W * FRAME_H)
                fail("native source accepted-pixel count mismatch");
            if (frame_aw_count != EXPECTED_BURSTS_PER_FRAME ||
                frame_w_count != EXPECTED_BEATS_PER_FRAME ||
                frame_b_count != EXPECTED_BURSTS_PER_FRAME)
                fail("native AW/W/B count mismatch");
            if (expected_row != FRAME_H)
                fail("native address planner did not complete all rows");
            readback_frame(base, tone);
            frame_model_active = 1'b0;
            @(posedge clk);
            #0.1;
            if (done)
                fail("native done was not a one-cycle pulse");
        end
    endtask

    initial begin : main_test
        integer slot;
        if ((slot_base(0) + FRAME_SLOT_BYTES) > slot_base(1) ||
            (slot_base(1) + FRAME_SLOT_BYTES) > slot_base(2))
            fail("native input slot map overlaps");
        if ((slot_base(2) + FRAME_BYTES) >= 32'h0200_0000)
            fail("native input slots overlap tensor arena");

        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        for (slot = 0; slot < 3; slot = slot + 1)
            run_frame(slot, 17 + slot * 73);

        if (total_aw_count != 3 * EXPECTED_BURSTS_PER_FRAME ||
            total_w_count != 3 * EXPECTED_BEATS_PER_FRAME ||
            total_b_count != 3 * EXPECTED_BURSTS_PER_FRAME)
            fail("native three-slot aggregate AXI count mismatch");
        if (arith_readback_count != 3 * FRAME_W * FRAME_H)
            fail("native three-slot readback count mismatch");
        if (aw_stall_count == 0 || w_stall_count == 0 ||
            b_delay_count == 0 || source_hold_count == 0)
            fail("native writer BFM did not exercise backpressure");

        $display("C1_R1_NATIVE_CAPTURE_WRITER_PASS frames=3 frame_pixels=%0d aw=%0d w=%0d b=%0d readback_pixels=%0d aw_stalls=%0d w_stalls=%0d b_delays=%0d source_holds=%0d slots=%08x/%08x/%08x",
                 FRAME_W * FRAME_H, total_aw_count, total_w_count,
                 total_b_count, arith_readback_count,
                 aw_stall_count, w_stall_count, b_delay_count,
                 source_hold_count, slot_base(0), slot_base(1), slot_base(2));
        $finish;
    end

    initial begin
        // Keep the guard below the signed 32-bit unsized-delay limit.  The
        // native three-frame run completes in roughly 13 ms of sim time;
        // 100 ms leaves ample margin without a literal overflow that would
        // schedule the timeout at time zero.
        #100_000_000;
        fail("native capture writer global timeout/deadlock");
    end
endmodule
