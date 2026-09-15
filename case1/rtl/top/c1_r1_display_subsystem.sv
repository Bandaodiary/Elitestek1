// Portable two-clock display subsystem: DDR pair prefetch, coordinated
// line-store flush, frame/underflow CDC, 720p timing, split compositor and OSD.
module c1_r1_display_subsystem #(
    parameter integer FRAME_WIDTH = 640,
    parameter integer X_BITS =
        (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer ENABLE_RESPONSE_FIFO = 0,
    parameter integer RESPONSE_FIFO_DEPTH = 64,
    parameter integer SEPARATE_ORIGINAL_GEOMETRY = 0
) (
    input  logic                  core_clk,
    input  logic                  core_rst,
    input  logic                  pixel_clk,
    input  logic                  pixel_rst,
    input  logic                  start_valid,
    output logic                  start_ready,
    input  logic                  abort,
    input  logic                  flush_request,
    output logic                  flush_busy,
    output logic                  flush_done,
    input  logic [31:0]           original_base,
    input  logic [31:0]           original_stride,
    input  logic [31:0]           styled_base,
    input  logic [31:0]           styled_stride,
    input  logic [15:0]           width_pixels,
    input  logic [15:0]           height_lines,
    output logic                  busy,
    output logic                  done,
    output logic                  aborted,
    output logic                  error,
    output logic                  primed,
    input  logic                  feed_active,
    input  logic                  hold_requests,
    input  logic [7:0]            display_mode,
    input  logic [31:0]           osd_status_word,
    input  logic                  osd_alarm,
    output logic                  frame_start_event,
    output logic                  underflow_event,
    output logic [23:0]           video_rgb,
    output logic                  video_de,
    output logic                  video_hsync,
    output logic                  video_vsync,

    output logic [31:0]           original_axi_araddr,
    output logic [7:0]            original_axi_arlen,
    output logic [2:0]            original_axi_arsize,
    output logic [1:0]            original_axi_arburst,
    output logic                  original_axi_arvalid,
    input  logic                  original_axi_arready,
    input  logic [127:0]          original_axi_rdata,
    input  logic [1:0]            original_axi_rresp,
    input  logic                  original_axi_rlast,
    input  logic                  original_axi_rvalid,
    output logic                  original_axi_rready,
    output logic [31:0]           styled_axi_araddr,
    output logic [7:0]            styled_axi_arlen,
    output logic [2:0]            styled_axi_arsize,
    output logic [1:0]            styled_axi_arburst,
    output logic                  styled_axi_arvalid,
    input  logic                  styled_axi_arready,
    input  logic [127:0]          styled_axi_rdata,
    input  logic [1:0]            styled_axi_rresp,
    input  logic                  styled_axi_rlast,
    input  logic                  styled_axi_rvalid,
    output logic                  styled_axi_rready,
    input  logic [15:0]           original_width_pixels,
    input  logic [15:0]           original_height_lines
);

    logic pair_start_ready;
    logic pair_core_soft_reset;
    logic pair_pixel_reset;
    logic request_enable_core;
    logic request_enable_sync1_q, request_enable_sync2_q;
    logic request_enable_frame_q;
    logic hold_sync1_pixel, hold_sync2_pixel;
    logic [10:0] timing_x;
    logic [9:0] timing_y;
    logic timing_de, timing_hsync, timing_vsync;
    logic timing_line_start, timing_frame_start;
    logic compositor_original_request;
    logic [9:0] compositor_original_x;
    logic [8:0] compositor_original_y;
    logic compositor_styled_request;
    logic [9:0] compositor_styled_x;
    logic [8:0] compositor_styled_y;
    logic prefetch_original_request;
    logic [9:0] prefetch_original_x;
    logic [8:0] prefetch_original_y;
    logic prefetch_styled_request;
    logic [9:0] prefetch_styled_x;
    logic [8:0] prefetch_styled_y;
    logic drain_original_request;
    logic drain_styled_request;
    logic drain_window;
    logic original_drain_window;
    logic original_response_valid;
    logic styled_response_valid;
    logic [23:0] original_rgb;
    logic [23:0] styled_rgb;
    logic original_underflow;
    logic styled_underflow;
    logic [23:0] compositor_rgb;
    logic compositor_de, compositor_hsync, compositor_vsync;
    logic [23:0] osd_rgb;
    logic [10:0] timing_x_q1, timing_x_q2;
    logic [9:0] timing_y_q1, timing_y_q2;
    logic [15:0] width_sync1_pixel, width_sync2_pixel;
    logic [15:0] height_sync1_pixel, height_sync2_pixel;
    logic [15:0] width_active_core, height_active_core;
    logic [15:0] original_width_active_core, original_height_active_core;
    (* ASYNC_REG = "TRUE" *) logic [15:0] original_width_sync1_pixel, original_width_sync2_pixel;
    (* ASYNC_REG = "TRUE" *) logic [15:0] original_height_sync1_pixel, original_height_sync2_pixel;
    logic [15:0] original_width_cfg, original_height_cfg;
    logic [40:0] display_snapshot_pixel;
    logic display_snapshot_valid;
    logic [7:0] mode_frame_q;
    logic [31:0] status_frame_q;
    logic alarm_frame_q;
    logic frame_pending_q;
    logic frame_src_ready;
    logic frame_src_pulse;
    logic underflow_pending_q;
    logic underflow_reported_q;
    logic underflow_src_ready;
    logic underflow_src_pulse;
    logic pair_core_rst;
    logic bootstrap_feed_enable;

    always_comb begin
        original_width_cfg = SEPARATE_ORIGINAL_GEOMETRY ? original_width_pixels : width_pixels;
        original_height_cfg = SEPARATE_ORIGINAL_GEOMETRY ? original_height_lines : height_lines;
        start_ready = pair_start_ready && !flush_busy && !flush_request;
        pair_core_rst = core_rst || pair_core_soft_reset;
        // A two-line store can only accept the next line after the pixel
        // domain has acknowledged the corresponding old line.  During the
        // very first prefetch there is not yet a current display pair, so
        // feed_active is intentionally low; gating requests solely with it
        // would leave both readers permanently stopped after their first two
        // lines.  Once both banks are primed, allow the raster to consume
        // those lines as a bootstrap stream.  The pixel-domain latch below
        // still commits this enable only at a frame boundary, preserving the
        // normal no-tearing swap contract.
        bootstrap_feed_enable = busy && !feed_active && primed &&
                                !flush_busy && !hold_requests;
        // Once a current pair is feeding the raster, keep the request gate
        // live even while one of the two line stores is temporarily empty.
        // Requiring `primed` here deadlocks the background reader after its
        // first two lines: primed drops while a line is being consumed, the
        // pixel-domain latch disables requests at the next frame boundary,
        // and a later pending pair can never finish prefetch.  Bootstrap
        // still requires primed so the first pair cannot request before its
        // initial two lines exist.
        request_enable_core = ((feed_active && !hold_requests) ||
                               bootstrap_feed_enable) && !flush_busy;
        // The prefetch pair owns two independent line stores, but the
        // compositor may read only one source in ORIGINAL/STYLED modes.  If
        // the unselected reader is not consumed, its ping-pong bank remains
        // owned forever and the reader deadlocks after two lines.  Drain the
        // unselected source over the first `width` pixels of each active
        // raster line; selected-source coordinates remain those generated by
        // the compositor.  SPLIT mode naturally consumes both sources.
        drain_window = timing_de && (timing_y >= 10'd120) &&
                       (timing_y < 10'd600) &&
                       ((timing_y - 10'd120) < height_sync2_pixel) &&
                       (timing_x < width_sync2_pixel);
        original_drain_window = timing_de && (timing_y >= 10'd120) &&
                       (timing_y < 10'd600) &&
                       ((timing_y - 10'd120) < original_height_sync2_pixel) &&
                       (timing_x < original_width_sync2_pixel);
        drain_original_request = 1'b0;
        drain_styled_request = 1'b0;
        case (mode_frame_q[1:0])
            2'd0: drain_original_request = original_drain_window; // STYLED
            2'd1: drain_styled_request = drain_window;   // ORIGINAL
            2'd2: begin                                  // SPLIT
                drain_original_request = 1'b0;
                drain_styled_request = 1'b0;
            end
            default: begin
                drain_original_request = original_drain_window;
                drain_styled_request = drain_window;
            end
        endcase
        prefetch_original_request = compositor_original_request ||
                                    drain_original_request;
        prefetch_original_x = drain_original_request ?
                              timing_x[9:0] : compositor_original_x;
        prefetch_original_y = drain_original_request ?
                              (timing_y - 10'd120) : compositor_original_y;
        prefetch_styled_request = compositor_styled_request ||
                                  drain_styled_request;
        prefetch_styled_x = drain_styled_request ?
                            timing_x[9:0] : compositor_styled_x;
        prefetch_styled_y = drain_styled_request ?
                            (timing_y - 10'd120) : compositor_styled_y;
        // Compare full coordinates BEFORE narrowing to the line-store port.
        // Smaller images occupy the upper-left of each fixed 640x480 panel;
        // the remainder is black padding, not repeated reads of wrapped x.
        prefetch_original_request = prefetch_original_request &&
            (prefetch_original_x < original_width_sync2_pixel) &&
            (prefetch_original_y < original_height_sync2_pixel);
        prefetch_styled_request = prefetch_styled_request &&
            (prefetch_styled_x < width_sync2_pixel) &&
            (prefetch_styled_y < height_sync2_pixel);
        frame_src_pulse = frame_pending_q;
        underflow_src_pulse = underflow_pending_q;
        video_rgb = osd_rgb;
        video_de = compositor_de;
        video_hsync = compositor_hsync;
        video_vsync = compositor_vsync;
    end

    // Match the reader's accepted transaction, not mutable software inputs.
    // Geometry remains bundled and stable while that prefetch is active.
    always_ff @(posedge core_clk) begin
        if (pair_core_rst) begin
            width_active_core <= 16'd0;
            height_active_core <= 16'd0;
            original_width_active_core <= 16'd0;
            original_height_active_core <= 16'd0;
        end else if (start_valid && start_ready) begin
            width_active_core <= width_pixels;
            height_active_core <= height_lines;
            original_width_active_core <= original_width_cfg;
            original_height_active_core <= original_height_cfg;
        end
    end

    c1_display_flush_reset u_flush (
        .core_clk(core_clk),
        .core_rst(core_rst),
        .request(flush_request),
        .safe_to_flush(!busy),
        .busy(flush_busy),
        .done(flush_done),
        .core_soft_reset(pair_core_soft_reset),
        .pixel_clk(pixel_clk),
        .pixel_rst(pixel_rst),
        .pixel_soft_reset(pair_pixel_reset)
    );

    c1_display_prefetch_pair #(
        .MAX_WIDTH((FRAME_WIDTH < 640) ? FRAME_WIDTH : 640),
        .MAX_HEIGHT(480),
        .X_BITS(X_BITS),
        .Y_BITS(16),
        .ENABLE_RESPONSE_FIFO(ENABLE_RESPONSE_FIFO),
        .RESPONSE_FIFO_DEPTH(RESPONSE_FIFO_DEPTH),
        .SEPARATE_ORIGINAL_GEOMETRY(SEPARATE_ORIGINAL_GEOMETRY)
    ) u_prefetch (
        .original_width_pixels(original_width_cfg), .original_height_lines(original_height_cfg),
        .core_clk(core_clk),
        .core_rst(pair_core_rst),
        .start_valid(start_valid && !flush_busy && !flush_request),
        .start_ready(pair_start_ready),
        // A flush stops raster consumption, so it must also cancel active
        // prefetch. Otherwise safe_to_flush(!busy) waits on pixels that the
        // flush itself prevents from being consumed. Pair recovery retires
        // AXI and clears its buffers before the outer reset is allowed.
        .abort(abort || flush_request || flush_busy),
        .hold_requests(hold_requests),
        .original_base(original_base),
        .original_stride(original_stride),
        .styled_base(styled_base),
        .styled_stride(styled_stride),
        .width_pixels(width_pixels),
        .height_lines(height_lines),
        .busy(busy),
        .done(done),
        .aborted(aborted),
        .error(error),
        .primed(primed),
        .pixel_clk(pixel_clk),
        .pixel_rst(pair_pixel_reset),
        .original_request(
            prefetch_original_request && request_enable_frame_q &&
            !hold_sync2_pixel),
        // Source capacity may make X_BITS wider than the 10-bit fixed panel
        // coordinate. A part-select above bit 9 would inject X; sized casts
        // zero-extend unsigned coordinates (or narrow after range gating).
        .original_request_x(X_BITS'(prefetch_original_x)),
        .original_request_y({7'd0, prefetch_original_y}),
        .original_response_valid(original_response_valid),
        .original_rgb(original_rgb),
        .original_underflow(original_underflow),
        .styled_request(
            prefetch_styled_request && request_enable_frame_q &&
            !hold_sync2_pixel),
        .styled_request_x(X_BITS'(prefetch_styled_x)),
        .styled_request_y({7'd0, prefetch_styled_y}),
        .styled_response_valid(styled_response_valid),
        .styled_rgb(styled_rgb),
        .styled_underflow(styled_underflow),
        .original_axi_araddr(original_axi_araddr),
        .original_axi_arlen(original_axi_arlen),
        .original_axi_arsize(original_axi_arsize),
        .original_axi_arburst(original_axi_arburst),
        .original_axi_arvalid(original_axi_arvalid),
        .original_axi_arready(original_axi_arready),
        .original_axi_rdata(original_axi_rdata),
        .original_axi_rresp(original_axi_rresp),
        .original_axi_rlast(original_axi_rlast),
        .original_axi_rvalid(original_axi_rvalid),
        .original_axi_rready(original_axi_rready),
        .styled_axi_araddr(styled_axi_araddr),
        .styled_axi_arlen(styled_axi_arlen),
        .styled_axi_arsize(styled_axi_arsize),
        .styled_axi_arburst(styled_axi_arburst),
        .styled_axi_arvalid(styled_axi_arvalid),
        .styled_axi_arready(styled_axi_arready),
        .styled_axi_rdata(styled_axi_rdata),
        .styled_axi_rresp(styled_axi_rresp),
        .styled_axi_rlast(styled_axi_rlast),
        .styled_axi_rvalid(styled_axi_rvalid),
        .styled_axi_rready(styled_axi_rready)
    );

    c1_video_timing_720p u_timing (
        .pixel_clk(pixel_clk),
        .rst_n(~pixel_rst),
        .pixel_x(timing_x),
        .pixel_y(timing_y),
        .de(timing_de),
        .hsync(timing_hsync),
        .vsync(timing_vsync),
        .line_start(timing_line_start),
        .frame_start(timing_frame_start)
    );

    c1_split_compositor u_compositor (
        .pixel_clk(pixel_clk),
        .rst_n(~pixel_rst),
        .timing_x(timing_x),
        .timing_y(timing_y),
        .timing_de(timing_de),
        .timing_hsync(timing_hsync),
        .timing_vsync(timing_vsync),
        .display_mode(mode_frame_q[1:0]),
        .original_request(compositor_original_request),
        .original_x(compositor_original_x),
        .original_y(compositor_original_y),
        .original_rgb(original_response_valid ?
                      original_rgb : 24'd0),
        .styled_request(compositor_styled_request),
        .styled_x(compositor_styled_x),
        .styled_y(compositor_styled_y),
        .styled_rgb(styled_response_valid ?
                    styled_rgb : 24'd0),
        .rgb(compositor_rgb),
        .de(compositor_de),
        .hsync(compositor_hsync),
        .vsync(compositor_vsync)
    );

    c1_hex_osd_overlay u_osd (
        .pixel_x(timing_x_q2),
        .pixel_y(timing_y_q2),
        .enable(mode_frame_q[7]),
        .alarm(alarm_frame_q),
        .status_word(status_frame_q),
        .in_rgb(compositor_rgb),
        .out_rgb(osd_rgb)
    );

    // Mode, status and alarm are one source-clock snapshot. A local buffer
    // flush must not reset this handshake independently of its source.
    c1_cdc_latest_snapshot #(.WIDTH(41)) u_display_snapshot (
        .src_clk(core_clk), .src_rst(core_rst),
        .src_data({display_mode, osd_status_word, osd_alarm}),
        .dst_clk(pixel_clk), .dst_rst(pixel_rst),
        .dst_data(display_snapshot_pixel), .dst_valid(display_snapshot_valid),
        .dst_update()
    );

    always_ff @(posedge pixel_clk) begin
        if (pixel_rst) begin
            request_enable_sync1_q <= 1'b0;
            request_enable_sync2_q <= 1'b0;
            hold_sync1_pixel <= 1'b0;
            hold_sync2_pixel <= 1'b0;
            timing_x_q1 <= 11'd0;
            timing_x_q2 <= 11'd0;
            timing_y_q1 <= 10'd0;
            timing_y_q2 <= 10'd0;
            width_sync1_pixel <= 16'd0;
            width_sync2_pixel <= 16'd0;
            height_sync1_pixel <= 16'd0;
            height_sync2_pixel <= 16'd0;
            original_width_sync1_pixel <= 16'd0;
            original_width_sync2_pixel <= 16'd0;
            original_height_sync1_pixel <= 16'd0;
            original_height_sync2_pixel <= 16'd0;
        end else begin
            request_enable_sync1_q <= request_enable_core;
            request_enable_sync2_q <= request_enable_sync1_q;
            // The core-domain pending-pair hold must gate the actual pixel
            // requests immediately; waiting for the frame-boundary latch
            // alone would let the raster consume the newly prefetched lines
            // before VSYNC.  Two flops keep this CDC explicit.
            hold_sync1_pixel <= hold_requests;
            hold_sync2_pixel <= hold_sync1_pixel;
            timing_x_q1 <= timing_x;
            timing_x_q2 <= timing_x_q1;
            timing_y_q1 <= timing_y;
            timing_y_q2 <= timing_y_q1;
            width_sync1_pixel <= width_active_core;
            width_sync2_pixel <= width_sync1_pixel;
            height_sync1_pixel <= height_active_core;
            height_sync2_pixel <= height_sync1_pixel;
            original_width_sync1_pixel <= original_width_active_core;
            original_width_sync2_pixel <= original_width_sync1_pixel;
            original_height_sync1_pixel <= original_height_active_core;
            original_height_sync2_pixel <= original_height_sync1_pixel;
        end
    end

    // Release line-store requests only on a local pixel-domain frame
    // boundary.  A core-domain prefetch may become primed during active
    // video, especially after abort/flush recovery; enabling immediately in
    // that case would pair raster line N with newly loaded line zero.
    always_ff @(posedge pixel_clk) begin
        if (pair_pixel_reset) begin
            request_enable_frame_q <= 1'b0;
            mode_frame_q <= 8'd0;
            status_frame_q <= 32'd0;
            alarm_frame_q <= 1'b0;
        end else if (timing_frame_start) begin
            request_enable_frame_q <= request_enable_sync2_q;
            if(display_snapshot_valid)
                {mode_frame_q, status_frame_q, alarm_frame_q} <= display_snapshot_pixel;
        end
    end

    always_ff @(posedge pixel_clk) begin
        if (pixel_rst) begin
            frame_pending_q <= 1'b0;
            underflow_pending_q <= 1'b0;
            underflow_reported_q <= 1'b0;
        end else begin
            if (timing_frame_start)
                frame_pending_q <= 1'b1;
            else if (frame_pending_q && frame_src_ready)
                frame_pending_q <= 1'b0;

            // A missing line can pulse once per requested pixel.  Collapse
            // those pulses to one software-visible event per video frame;
            // otherwise the toggle CDC would repeatedly count the same line
            // starvation while its acknowledgement returned.
            if (timing_frame_start)
                underflow_reported_q <= 1'b0;
            if (underflow_pending_q && underflow_src_ready)
                underflow_pending_q <= 1'b0;
            if ((original_underflow || styled_underflow) &&
                (timing_frame_start || !underflow_reported_q)) begin
                // A coincident pulse belongs to the newly opened frame;
                // the old frame's reported bit must not suppress it.
                underflow_pending_q <= 1'b1;
                underflow_reported_q <= 1'b1;
            end
        end
    end

    c1_event_cdc u_frame_event_cdc (
        .src_clk(pixel_clk),
        .src_rst(pixel_rst),
        .src_pulse(frame_src_pulse),
        .src_ready(frame_src_ready),
        .dst_clk(core_clk),
        .dst_rst(core_rst),
        .dst_pulse(frame_start_event)
    );

    c1_event_cdc u_underflow_event_cdc (
        .src_clk(pixel_clk),
        .src_rst(pixel_rst),
        .src_pulse(underflow_src_pulse),
        .src_ready(underflow_src_ready),
        .dst_clk(core_clk),
        .dst_rst(core_rst),
        .dst_pulse(underflow_event)
    );

endmodule
