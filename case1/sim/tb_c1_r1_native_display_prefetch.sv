`timescale 1ns/1ps

// Board-independent native display/DDR staged preflight.
//
// This test deliberately stops at the display boundary: it instantiates the
// real c1_display_prefetch_pair (two 640x480 AXI XRGB readers plus the
// dual-clock two-line stores), but does not instantiate the CNN/SoC control
// path.  A pair of independent AXI read BFMs checks every burst address,
// 4-KiB/row boundary and returned beat.  A synthetic pixel raster consumes
// both stores one pixel per pixel clock and compares every RGB response with
// the address-derived pattern.  It therefore exercises the native DDR map,
// line-store ownership CDC and full-frame drain in a short, deterministic
// run without making a claim about CNN throughput or board timing.
module tb_c1_r1_native_display_prefetch;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer X_BITS = $clog2(FRAME_W);
    localparam integer Y_BITS = 16;
    localparam integer STRIDE = FRAME_W * 4;
    localparam integer ROW_BEATS = FRAME_W / 4;
    localparam integer EXPECTED_BURSTS = FRAME_H * ((ROW_BEATS + 15) / 16);
    localparam integer EXPECTED_BEATS = FRAME_H * ROW_BEATS;
    localparam integer EXPECTED_PIXELS = FRAME_W * FRAME_H;
    localparam logic [31:0] ORIGINAL_BASE = 32'h0010_0000;
    localparam logic [31:0] STYLED_BASE   = 32'h0060_0000;
`ifdef C1_DISPLAY_RESPONSE_FIFO
    localparam integer ENABLE_RESPONSE_FIFO = 1;
    localparam integer RESPONSE_FIFO_DEPTH = 128;
`else
    localparam integer ENABLE_RESPONSE_FIFO = 0;
    localparam integer RESPONSE_FIFO_DEPTH = 64;
`endif

    logic core_clk = 1'b0;
    logic pixel_clk = 1'b0;
    logic core_rst = 1'b1;
    logic pixel_rst = 1'b1;
    always #5 core_clk = ~core_clk;
    always #7 pixel_clk = ~pixel_clk;

    logic start_valid = 1'b0;
    logic start_ready;
    logic abort = 1'b0;
    logic [31:0] original_base = ORIGINAL_BASE;
    logic [31:0] styled_base = STYLED_BASE;
    logic [31:0] original_stride = STRIDE;
    logic [31:0] styled_stride = STRIDE;
    logic [15:0] width_pixels = FRAME_W;
    logic [15:0] height_lines = FRAME_H;
    logic prefetch_busy, prefetch_done, prefetch_aborted;
    logic prefetch_error, prefetch_primed;

    logic original_request = 1'b0;
    logic [X_BITS-1:0] original_request_x = '0;
    logic [Y_BITS-1:0] original_request_y = '0;
    logic original_response_valid;
    logic [23:0] original_rgb;
    logic original_underflow;
    logic styled_request = 1'b0;
    logic [X_BITS-1:0] styled_request_x = '0;
    logic [Y_BITS-1:0] styled_request_y = '0;
    logic styled_response_valid;
    logic [23:0] styled_rgb;
    logic styled_underflow;

    logic [31:0] original_araddr;
    logic [7:0] original_arlen;
    logic [2:0] original_arsize;
    logic [1:0] original_arburst;
    logic original_arvalid, original_arready;
    logic [127:0] original_rdata;
    logic [1:0] original_rresp = 2'b00;
    logic original_rlast;
    logic original_rvalid, original_rready;

    logic [31:0] styled_araddr;
    logic [7:0] styled_arlen;
    logic [2:0] styled_arsize;
    logic [1:0] styled_arburst;
    logic styled_arvalid, styled_arready;
    logic [127:0] styled_rdata;
    logic [1:0] styled_rresp = 2'b00;
    logic styled_rlast;
    logic styled_rvalid, styled_rready;

    c1_display_prefetch_pair #(
        .MAX_WIDTH(FRAME_W), .X_BITS(X_BITS), .Y_BITS(Y_BITS),
        .ENABLE_RESPONSE_FIFO(ENABLE_RESPONSE_FIFO),
        .RESPONSE_FIFO_DEPTH(RESPONSE_FIFO_DEPTH)
    ) dut (
        .original_width_pixels(16'd0), .original_height_lines(16'd0),
        .core_clk(core_clk), .core_rst(core_rst),
         .start_valid(start_valid), .start_ready(start_ready),
         .abort(abort),
         .hold_requests(1'b0),
        .original_base(original_base), .original_stride(original_stride),
        .styled_base(styled_base), .styled_stride(styled_stride),
        .width_pixels(width_pixels), .height_lines(height_lines),
        .busy(prefetch_busy), .done(prefetch_done),
        .aborted(prefetch_aborted), .error(prefetch_error),
        .primed(prefetch_primed),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
        .original_request(original_request),
        .original_request_x(original_request_x),
        .original_request_y(original_request_y),
        .original_response_valid(original_response_valid),
        .original_rgb(original_rgb), .original_underflow(original_underflow),
        .styled_request(styled_request),
        .styled_request_x(styled_request_x),
        .styled_request_y(styled_request_y),
        .styled_response_valid(styled_response_valid),
        .styled_rgb(styled_rgb), .styled_underflow(styled_underflow),
        .original_axi_araddr(original_araddr),
        .original_axi_arlen(original_arlen),
        .original_axi_arsize(original_arsize),
        .original_axi_arburst(original_arburst),
        .original_axi_arvalid(original_arvalid),
        .original_axi_arready(original_arready),
        .original_axi_rdata(original_rdata),
        .original_axi_rresp(original_rresp),
        .original_axi_rlast(original_rlast),
        .original_axi_rvalid(original_rvalid),
        .original_axi_rready(original_rready),
        .styled_axi_araddr(styled_araddr),
        .styled_axi_arlen(styled_arlen),
        .styled_axi_arsize(styled_arsize),
        .styled_axi_arburst(styled_arburst),
        .styled_axi_arvalid(styled_arvalid),
        .styled_axi_arready(styled_arready),
        .styled_axi_rdata(styled_rdata),
        .styled_axi_rresp(styled_rresp),
        .styled_axi_rlast(styled_rlast),
        .styled_axi_rvalid(styled_rvalid),
        .styled_axi_rready(styled_rready)
    );

    // The low 24 bits of each returned XRGB word are its byte address.  This
    // makes every pixel independently checkable without a multi-megabyte
    // memory image while retaining different values for the two frame bases.
    function automatic [127:0] make_beat(input logic [31:0] addr);
        logic [127:0] value;
        logic [31:0] word;
        integer lane;
        begin
            value = '0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                word = addr + (lane * 4);
                value[lane*32 +: 32] = {8'h00, word[23:0]};
            end
            make_beat = value;
        end
    endfunction

    function automatic [23:0] expected_rgb(
        input logic [31:0] base,
        input integer x,
        input integer y
    );
        logic [31:0] pixel_addr;
        begin
            pixel_addr = base + (y * STRIDE) + (x * 4);
            expected_rgb = pixel_addr[23:0];
        end
    endfunction

    integer core_cycle_count = 0;
    integer original_ar_count = 0, styled_ar_count = 0;
    integer original_r_count = 0, styled_r_count = 0;
    integer original_ar_stall_count = 0, styled_ar_stall_count = 0;
    integer original_r_stall_count = 0, styled_r_stall_count = 0;

    logic original_r_active = 1'b0, original_rvalid_q = 1'b0;
    logic [31:0] original_ar_base_q = '0;
    logic [7:0] original_ar_len_q = '0;
    integer original_r_index_q = 0, original_r_delay_q = 0;
    logic [127:0] original_rdata_q = '0;
    logic original_rlast_q = 1'b0;

    logic styled_r_active = 1'b0, styled_rvalid_q = 1'b0;
    logic [31:0] styled_ar_base_q = '0;
    logic [7:0] styled_ar_len_q = '0;
    integer styled_r_index_q = 0, styled_r_delay_q = 0;
    logic [127:0] styled_rdata_q = '0;
    logic styled_rlast_q = 1'b0;

    // Expected sequential burst address state.  The reader is required to
    // issue ten 16-beat bursts per 640-pixel row (160 beats), with the final
    // burst of every row ending exactly at the row boundary.
    logic [31:0] original_expected_addr = ORIGINAL_BASE;
    logic [31:0] styled_expected_addr = STYLED_BASE;
    integer original_expected_row = 0, styled_expected_row = 0;
    integer original_expected_row_beats = ROW_BEATS;
    integer styled_expected_row_beats = ROW_BEATS;

    always_comb begin
        original_arready = !original_r_active && !original_rvalid_q &&
                           ((core_cycle_count % 11) != 0);
        styled_arready = !styled_r_active && !styled_rvalid_q &&
                         ((core_cycle_count % 13) != 0);
        original_rvalid = original_rvalid_q;
        original_rdata = original_rdata_q;
        original_rlast = original_rlast_q;
        styled_rvalid = styled_rvalid_q;
        styled_rdata = styled_rdata_q;
        styled_rlast = styled_rlast_q;
    end

    always @(posedge core_clk) begin : axi_read_bfm
        integer burst_bytes;
        integer burst_beats;
        integer row_end_addr;
        if (core_rst) begin
            core_cycle_count <= 0;
            original_r_active <= 1'b0;
            original_rvalid_q <= 1'b0;
            original_r_index_q <= 0;
            original_r_delay_q <= 0;
            styled_r_active <= 1'b0;
            styled_rvalid_q <= 1'b0;
            styled_r_index_q <= 0;
            styled_r_delay_q <= 0;
            original_ar_count <= 0;
            styled_ar_count <= 0;
            original_r_count <= 0;
            styled_r_count <= 0;
            original_ar_stall_count <= 0;
            styled_ar_stall_count <= 0;
            original_r_stall_count <= 0;
            styled_r_stall_count <= 0;
            original_expected_addr <= ORIGINAL_BASE;
            styled_expected_addr <= STYLED_BASE;
            original_expected_row <= 0;
            styled_expected_row <= 0;
            original_expected_row_beats <= ROW_BEATS;
            styled_expected_row_beats <= ROW_BEATS;
        end else begin
            core_cycle_count <= core_cycle_count + 1;
            if (original_arvalid && !original_arready)
                original_ar_stall_count <= original_ar_stall_count + 1;
            if (styled_arvalid && !styled_arready)
                styled_ar_stall_count <= styled_ar_stall_count + 1;
            if (original_rvalid_q && !original_rready)
                original_r_stall_count <= original_r_stall_count + 1;
            if (styled_rvalid_q && !styled_rready)
                styled_r_stall_count <= styled_r_stall_count + 1;

            if (start_valid && start_ready) begin
                original_expected_addr <= ORIGINAL_BASE;
                styled_expected_addr <= STYLED_BASE;
                original_expected_row <= 0;
                styled_expected_row <= 0;
                original_expected_row_beats <= ROW_BEATS;
                styled_expected_row_beats <= ROW_BEATS;
            end

            if (original_arvalid && original_arready) begin
                burst_beats = original_arlen + 1;
                burst_bytes = burst_beats * 16;
                row_end_addr = ORIGINAL_BASE +
                               ((original_expected_row + 1) * STRIDE);
                if ((original_arsize !== 3'd4) ||
                    (original_arburst !== 2'b01) ||
                    (original_araddr[3:0] !== 4'd0))
                    $fatal(1, "native original AR attributes invalid");
                if (original_araddr !== original_expected_addr)
                    $fatal(1, "native original AR sequence mismatch got=%08x exp=%08x row=%0d",
                           original_araddr, original_expected_addr,
                           original_expected_row);
                if ((original_araddr[11:0] + burst_bytes) > 4096)
                    $fatal(1, "native original burst crosses 4KiB addr=%08x len=%0d",
                           original_araddr, original_arlen);
                if ((original_araddr + burst_bytes) > row_end_addr)
                    $fatal(1, "native original burst crosses row addr=%08x row_end=%08x",
                           original_araddr, row_end_addr);
                if (burst_beats > original_expected_row_beats)
                    $fatal(1, "native original burst exceeds row remainder");

                original_r_active <= 1'b1;
                original_ar_base_q <= original_araddr;
                original_ar_len_q <= original_arlen;
                original_r_index_q <= 0;
                original_r_delay_q <= 1 + (core_cycle_count % 3);
                original_ar_count <= original_ar_count + 1;
                if (burst_beats == original_expected_row_beats) begin
                    original_expected_row <= original_expected_row + 1;
                    original_expected_addr <= ORIGINAL_BASE +
                                              ((original_expected_row + 1) * STRIDE);
                    original_expected_row_beats <= ROW_BEATS;
                end else begin
                    original_expected_addr <= original_expected_addr + burst_bytes;
                    original_expected_row_beats <=
                        original_expected_row_beats - burst_beats;
                end
            end

            if (styled_arvalid && styled_arready) begin
                burst_beats = styled_arlen + 1;
                burst_bytes = burst_beats * 16;
                row_end_addr = STYLED_BASE +
                               ((styled_expected_row + 1) * STRIDE);
                if ((styled_arsize !== 3'd4) ||
                    (styled_arburst !== 2'b01) ||
                    (styled_araddr[3:0] !== 4'd0))
                    $fatal(1, "native styled AR attributes invalid");
                if (styled_araddr !== styled_expected_addr)
                    $fatal(1, "native styled AR sequence mismatch got=%08x exp=%08x row=%0d",
                           styled_araddr, styled_expected_addr,
                           styled_expected_row);
                if ((styled_araddr[11:0] + burst_bytes) > 4096)
                    $fatal(1, "native styled burst crosses 4KiB addr=%08x len=%0d",
                           styled_araddr, styled_arlen);
                if ((styled_araddr + burst_bytes) > row_end_addr)
                    $fatal(1, "native styled burst crosses row addr=%08x row_end=%08x",
                           styled_araddr, row_end_addr);
                if (burst_beats > styled_expected_row_beats)
                    $fatal(1, "native styled burst exceeds row remainder");

                styled_r_active <= 1'b1;
                styled_ar_base_q <= styled_araddr;
                styled_ar_len_q <= styled_arlen;
                styled_r_index_q <= 0;
                styled_r_delay_q <= 1 + ((core_cycle_count + 1) % 3);
                styled_ar_count <= styled_ar_count + 1;
                if (burst_beats == styled_expected_row_beats) begin
                    styled_expected_row <= styled_expected_row + 1;
                    styled_expected_addr <= STYLED_BASE +
                                            ((styled_expected_row + 1) * STRIDE);
                    styled_expected_row_beats <= ROW_BEATS;
                end else begin
                    styled_expected_addr <= styled_expected_addr + burst_bytes;
                    styled_expected_row_beats <=
                        styled_expected_row_beats - burst_beats;
                end
            end

            if (original_r_active && !original_rvalid_q) begin
                if (original_r_delay_q > 0)
                    original_r_delay_q <= original_r_delay_q - 1;
                else begin
                    original_rdata_q <= make_beat(
                        original_ar_base_q + (original_r_index_q * 16));
                    original_rlast_q <=
                        (original_r_index_q == original_ar_len_q);
                    original_rvalid_q <= 1'b1;
                end
            end
            if (styled_r_active && !styled_rvalid_q) begin
                if (styled_r_delay_q > 0)
                    styled_r_delay_q <= styled_r_delay_q - 1;
                else begin
                    styled_rdata_q <= make_beat(
                        styled_ar_base_q + (styled_r_index_q * 16));
                    styled_rlast_q <= (styled_r_index_q == styled_ar_len_q);
                    styled_rvalid_q <= 1'b1;
                end
            end

            if (original_rvalid_q && original_rready) begin
                original_rvalid_q <= 1'b0;
                original_r_count <= original_r_count + 1;
                if (original_rlast_q)
                    original_r_active <= 1'b0;
                else
                    original_r_index_q <= original_r_index_q + 1;
            end
            if (styled_rvalid_q && styled_rready) begin
                styled_rvalid_q <= 1'b0;
                styled_r_count <= styled_r_count + 1;
                if (styled_rlast_q)
                    styled_r_active <= 1'b0;
                else
                    styled_r_index_q <= styled_r_index_q + 1;
            end
        end
    end

    integer original_response_count = 0, styled_response_count = 0;
    integer original_underflow_count = 0, styled_underflow_count = 0;
    logic [X_BITS-1:0] previous_original_x = '0;
    logic [Y_BITS-1:0] previous_original_y = '0;
    logic [X_BITS-1:0] previous_styled_x = '0;
    logic [Y_BITS-1:0] previous_styled_y = '0;
    logic scan_finished = 1'b0;
    logic done_seen = 1'b0;

    // Responses are registered by the line store, so a negedge monitor sees
    // the response associated with the request driven on the preceding
    // negedge.  The pixel task updates the previous-coordinate registers with
    // nonblocking assignments, preserving that one-cycle association.
    always @(negedge pixel_clk) begin
        if (!pixel_rst) begin
            if (original_response_valid) begin
                original_response_count <= original_response_count + 1;
                if (original_rgb !== expected_rgb(
                        ORIGINAL_BASE, previous_original_x,
                        previous_original_y))
                    $fatal(1, "native original RGB mismatch x=%0d y=%0d got=%06x exp=%06x",
                           previous_original_x, previous_original_y,
                           original_rgb,
                           expected_rgb(ORIGINAL_BASE, previous_original_x,
                                        previous_original_y));
            end
            if (styled_response_valid) begin
                styled_response_count <= styled_response_count + 1;
                if (styled_rgb !== expected_rgb(
                        STYLED_BASE, previous_styled_x,
                        previous_styled_y))
                    $fatal(1, "native styled RGB mismatch x=%0d y=%0d got=%06x exp=%06x",
                           previous_styled_x, previous_styled_y,
                           styled_rgb,
                           expected_rgb(STYLED_BASE, previous_styled_x,
                                        previous_styled_y));
            end
            if (original_underflow)
                original_underflow_count <= original_underflow_count + 1;
            if (styled_underflow)
                styled_underflow_count <= styled_underflow_count + 1;
        end
    end

    always @(posedge core_clk) begin
        if (!core_rst && prefetch_done)
            done_seen <= 1'b1;
        if (!core_rst && prefetch_error)
            $fatal(1, "native display prefetch reported error");
    end

    task automatic run_pixel_scan;
        integer x, y;
        begin
            wait (prefetch_primed === 1'b1);
            // Ready toggles and line numbers cross through three pixel-domain
            // synchronizer flops; leave explicit margin before row zero.
            repeat (12) @(negedge pixel_clk);
            for (y = 0; y < FRAME_H; y = y + 1) begin
                for (x = 0; x < FRAME_W; x = x + 1) begin
                    @(negedge pixel_clk);
                    original_request <= 1'b1;
                    original_request_x <= x[X_BITS-1:0];
                    original_request_y <= y[Y_BITS-1:0];
                    previous_original_x <= x[X_BITS-1:0];
                    previous_original_y <= y[Y_BITS-1:0];
                    styled_request <= 1'b1;
                    styled_request_x <= x[X_BITS-1:0];
                    styled_request_y <= y[Y_BITS-1:0];
                    previous_styled_x <= x[X_BITS-1:0];
                    previous_styled_y <= y[Y_BITS-1:0];
                end
            end
            @(negedge pixel_clk);
            original_request <= 1'b0;
            styled_request <= 1'b0;
            scan_finished <= 1'b1;
        end
    endtask

    initial begin : main_test
        integer wait_cycles;
        core_rst <= 1'b1;
        pixel_rst <= 1'b1;
        start_valid <= 1'b0;
        abort <= 1'b0;
        original_request <= 1'b0;
        styled_request <= 1'b0;
        repeat (10) @(posedge core_clk);
        core_rst <= 1'b0;
        repeat (10) @(posedge pixel_clk);
        pixel_rst <= 1'b0;

        wait (start_ready === 1'b1);
        @(negedge core_clk);
        start_valid <= 1'b1;
        @(negedge core_clk);
        start_valid <= 1'b0;

        fork
            run_pixel_scan();
        join_none

        wait_cycles = 0;
        while ((!done_seen || !scan_finished) && (wait_cycles < 20_000_000)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
        // Allow final pixel-domain response counters to settle across the
        // clock boundary before evaluating exact counts.
        repeat (8) @(negedge pixel_clk);

        if (!done_seen || !scan_finished)
            $fatal(1, "native display preflight timeout done=%0b scan=%0b busy=%0b primed=%0b",
                   done_seen, scan_finished, prefetch_busy, prefetch_primed);
        if (prefetch_aborted || prefetch_error)
            $fatal(1, "native display prefetch aborted/error aborted=%0b error=%0b",
                   prefetch_aborted, prefetch_error);
        if (original_underflow_count != 0 || styled_underflow_count != 0)
            $fatal(1, "native display underflow original/styled=%0d/%0d",
                   original_underflow_count, styled_underflow_count);
        if (original_response_count != EXPECTED_PIXELS ||
            styled_response_count != EXPECTED_PIXELS)
            $fatal(1, "native display response count original/styled=%0d/%0d expected=%0d",
                   original_response_count, styled_response_count, EXPECTED_PIXELS);
        if (original_ar_count != EXPECTED_BURSTS ||
            styled_ar_count != EXPECTED_BURSTS ||
            original_r_count != EXPECTED_BEATS ||
            styled_r_count != EXPECTED_BEATS)
            $fatal(1, "native display AXI count AR=%0d/%0d R=%0d/%0d expected AR=%0d R=%0d",
                   original_ar_count, styled_ar_count,
                   original_r_count, styled_r_count,
                   EXPECTED_BURSTS, EXPECTED_BEATS);
        if (original_expected_row != FRAME_H || styled_expected_row != FRAME_H)
            $fatal(1, "native display address checker ended at row %0d/%0d",
                   original_expected_row, styled_expected_row);
        if (original_ar_stall_count == 0 || styled_ar_stall_count == 0 ||
            original_r_stall_count == 0 || styled_r_stall_count == 0)
            $fatal(1, "native display BFM did not exercise backpressure");

        $display("C1_R1_NATIVE_DISPLAY_PREFETCH_PASS frame=%0dx%0d done=%0b primed=%0b responses=%0d/%0d axi_ar=%0d/%0d axi_r=%0d/%0d ar_stalls=%0d/%0d r_stalls=%0d/%0d underflow=%0d/%0d",
                 FRAME_W, FRAME_H, done_seen, prefetch_primed,
                 original_response_count, styled_response_count,
                 original_ar_count, styled_ar_count,
                 original_r_count, styled_r_count,
                 original_ar_stall_count, styled_ar_stall_count,
                 original_r_stall_count, styled_r_stall_count,
                 original_underflow_count, styled_underflow_count);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1, "native display prefetch timeout");
    end
endmodule
