`timescale 1ns/1ps

module tb_c1_split_compositor;
    parameter integer MODE = 2;
    localparam integer ORIGINAL_LEFT = MODE == 2 ? 0 : 320;
    localparam integer STYLED_LEFT = MODE == 2 ? 640 : 320;
    localparam integer H_ACTIVE = 1280;
    localparam integer H_FRONT  = 110;
    localparam integer H_SYNC   = 40;
    localparam integer H_TOTAL  = 1650;
    localparam integer V_ACTIVE = 720;
    localparam integer V_FRONT  = 5;
    localparam integer V_SYNC   = 5;
    localparam integer V_TOTAL  = 750;
    localparam integer FRAME_CYCLES = H_TOTAL * V_TOTAL;

    reg pixel_clk = 1'b0;
    reg rst_n = 1'b0;

    wire [10:0] timing_x;
    wire [9:0]  timing_y;
    wire timing_de;
    wire timing_hsync;
    wire timing_vsync;
    wire line_start;
    wire frame_start;

    wire original_request;
    wire [9:0] original_x;
    wire [8:0] original_y;
    reg  [23:0] original_rgb = 24'h000000;
    wire styled_request;
    wire [9:0] styled_x;
    wire [8:0] styled_y;
    reg  [23:0] styled_rgb = 24'h000000;

    wire [23:0] rgb;
    wire de;
    wire hsync;
    wire vsync;

    reg [10:0] reference_x_q = 11'd0;
    reg [9:0]  reference_y_q = 10'd0;
    reg reference_de_q = 1'b0;
    reg reference_hsync_q = 1'b0;
    reg reference_vsync_q = 1'b0;
    reg [23:0] expected_rgb = 24'h000000;
    reg expected_de = 1'b0;
    reg expected_hsync = 1'b0;
    reg expected_vsync = 1'b0;

    integer cycle_index;
    integer expected_x;
    integer expected_y;
    integer active_count;
    integer hsync_count;
    integer vsync_count;
    integer line_start_count;
    integer frame_start_count;
    integer original_request_count;
    integer styled_request_count;
    function automatic integer screen_source(input integer x, input integer y, input logic active);
        begin
            screen_source=0;
            if(active && y>=120 && y<600) begin
                if((MODE==1 || MODE==2) && x>=ORIGINAL_LEFT && x<ORIGINAL_LEFT+640)
                    screen_source=1;
                if((MODE==0 || MODE==2) && x>=STYLED_LEFT && x<STYLED_LEFT+640)
                    screen_source=2;
            end
        end
    endfunction

    // Nominal 74.25 MHz pixel clock.
    always #6.734 pixel_clk = ~pixel_clk;

    function automatic [23:0] original_pattern;
        input [9:0] x;
        input [8:0] y;
        begin
            original_pattern = {x[7:0], y[7:0], 8'ha5};
        end
    endfunction

    function automatic [23:0] styled_pattern;
        input [9:0] x;
        input [8:0] y;
        begin
            styled_pattern = {8'h5a, x[7:0], y[7:0]};
        end
    endfunction

    c1_video_timing_720p u_timing (
        .pixel_clk(pixel_clk),
        .rst_n(rst_n),
        .pixel_x(timing_x),
        .pixel_y(timing_y),
        .de(timing_de),
        .hsync(timing_hsync),
        .vsync(timing_vsync),
        .line_start(line_start),
        .frame_start(frame_start)
    );

    c1_split_compositor u_compositor (
        .pixel_clk(pixel_clk),
        .rst_n(rst_n),
        .timing_x(timing_x),
        .timing_y(timing_y),
        .timing_de(timing_de),
        .timing_hsync(timing_hsync),
        .timing_vsync(timing_vsync),
        .display_mode(MODE[1:0]),
        .original_request(original_request),
        .original_x(original_x),
        .original_y(original_y),
        .original_rgb(original_rgb),
        .styled_request(styled_request),
        .styled_x(styled_x),
        .styled_y(styled_y),
        .styled_rgb(styled_rgb),
        .rgb(rgb),
        .de(de),
        .hsync(hsync),
        .vsync(vsync)
    );

    // One-clock synchronous source models.  These match the compositor's
    // fixed-latency source contract and behave like registered BRAM reads.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            original_rgb <= 24'h000000;
            styled_rgb   <= 24'h000000;
        end else begin
            if (original_request)
                original_rgb <= original_pattern(original_x, original_y);
            else
                original_rgb <= 24'h000000;

            if (styled_request)
                styled_rgb <= styled_pattern(styled_x, styled_y);
            else
                styled_rgb <= 24'h000000;
        end
    end

    // Independent reference pipeline for output alignment and black borders.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            reference_x_q     <= 11'd0;
            reference_y_q     <= 10'd0;
            reference_de_q    <= 1'b0;
            reference_hsync_q <= 1'b0;
            reference_vsync_q <= 1'b0;
            expected_rgb      <= 24'h000000;
            expected_de       <= 1'b0;
            expected_hsync    <= 1'b0;
            expected_vsync    <= 1'b0;
        end else begin
            reference_x_q     <= timing_x;
            reference_y_q     <= timing_y;
            reference_de_q    <= timing_de;
            reference_hsync_q <= timing_hsync;
            reference_vsync_q <= timing_vsync;

            expected_de    <= reference_de_q;
            expected_hsync <= reference_hsync_q;
            expected_vsync <= reference_vsync_q;
            if (screen_source(reference_x_q,reference_y_q,reference_de_q)==1) begin
                expected_rgb <= original_pattern(
                    reference_x_q - ORIGINAL_LEFT, reference_y_q - 10'd120);
            end else if (screen_source(reference_x_q,reference_y_q,reference_de_q)==2) begin
                expected_rgb <= styled_pattern(
                    reference_x_q - STYLED_LEFT,
                    reference_y_q - 10'd120);
            end else begin
                expected_rgb <= 24'h000000;
            end
        end
    end

    // Check the registered compositor output after nonblocking assignments
    // have settled on each pixel clock.
    always @(negedge pixel_clk) begin
        if (rst_n) begin
            if (rgb !== expected_rgb)
                $fatal(1, "RGB mismatch: got=%h expected=%h", rgb, expected_rgb);
            if (de !== expected_de)
                $fatal(1, "DE alignment mismatch: got=%b expected=%b", de, expected_de);
            if (hsync !== expected_hsync)
                $fatal(1, "HSYNC alignment mismatch: got=%b expected=%b",
                       hsync, expected_hsync);
            if (vsync !== expected_vsync)
                $fatal(1, "VSYNC alignment mismatch: got=%b expected=%b",
                       vsync, expected_vsync);
        end
    end

    initial begin
        if(MODE<0 || MODE>3) $fatal(1,"invalid compositor test mode");
        active_count           = 0;
        hsync_count            = 0;
        vsync_count            = 0;
        line_start_count       = 0;
        frame_start_count      = 0;
        original_request_count = 0;
        styled_request_count   = 0;

        repeat (4) @(negedge pixel_clk);
        #1 rst_n = 1'b1;
        #1;

        // Check one complete nominal raster, including all porches and syncs.
        for (cycle_index = 0; cycle_index < FRAME_CYCLES; cycle_index = cycle_index + 1) begin
            expected_x = cycle_index % H_TOTAL;
            expected_y = cycle_index / H_TOTAL;

            if (timing_x !== expected_x[10:0] || timing_y !== expected_y[9:0])
                $fatal(1, "counter mismatch cycle=%0d got=(%0d,%0d) expected=(%0d,%0d)",
                       cycle_index, timing_x, timing_y, expected_x, expected_y);
            if (timing_de !== ((expected_x < H_ACTIVE) && (expected_y < V_ACTIVE)))
                $fatal(1, "raw DE mismatch at (%0d,%0d)", expected_x, expected_y);
            if (timing_hsync !== ((expected_x >= H_ACTIVE + H_FRONT) &&
                                  (expected_x < H_ACTIVE + H_FRONT + H_SYNC)))
                $fatal(1, "raw HSYNC mismatch at (%0d,%0d)", expected_x, expected_y);
            if (timing_vsync !== ((expected_y >= V_ACTIVE + V_FRONT) &&
                                  (expected_y < V_ACTIVE + V_FRONT + V_SYNC)))
                $fatal(1, "raw VSYNC mismatch at (%0d,%0d)", expected_x, expected_y);

            if (original_request && styled_request)
                $fatal(1, "source requests overlap at (%0d,%0d)", expected_x, expected_y);
            if(original_request !== (screen_source(expected_x,expected_y,timing_de)==1) ||
               styled_request !== (screen_source(expected_x,expected_y,timing_de)==2))
                $fatal(1,"missing/extra source request mode=%0d screen=(%0d,%0d)",MODE,expected_x,expected_y);

            if (original_request) begin
                if (!timing_de || expected_x<ORIGINAL_LEFT || expected_x >= ORIGINAL_LEFT+640 ||
                    expected_y < 120 || expected_y >= 600)
                    $fatal(1, "unexpected original request at (%0d,%0d)",
                           expected_x, expected_y);
                if (original_x !== (expected_x-ORIGINAL_LEFT) ||
                    original_y !== (expected_y - 120))
                    $fatal(1, "original coordinate mismatch at (%0d,%0d)",
                           expected_x, expected_y);
            end else if (original_x !== 0 || original_y !== 0) begin
                $fatal(1, "inactive original coordinates are not zero");
            end

            if (styled_request) begin
                if (!timing_de || expected_x < STYLED_LEFT || expected_x >= STYLED_LEFT+640 ||
                    expected_y < 120 || expected_y >= 600)
                    $fatal(1, "unexpected styled request at (%0d,%0d)",
                           expected_x, expected_y);
                if (styled_x !== (expected_x - STYLED_LEFT) ||
                    styled_y !== (expected_y - 120))
                    $fatal(1, "styled coordinate mismatch at (%0d,%0d)",
                           expected_x, expected_y);
            end else if (styled_x !== 0 || styled_y !== 0) begin
                $fatal(1, "inactive styled coordinates are not zero");
            end

            if (timing_de)       active_count = active_count + 1;
            if (timing_hsync)    hsync_count = hsync_count + 1;
            if (timing_vsync)    vsync_count = vsync_count + 1;
            if (line_start)      line_start_count = line_start_count + 1;
            if (frame_start)     frame_start_count = frame_start_count + 1;
            if (original_request) original_request_count = original_request_count + 1;
            if (styled_request)   styled_request_count = styled_request_count + 1;

            @(negedge pixel_clk);
            #1;
        end

        if (active_count != H_ACTIVE * V_ACTIVE)
            $fatal(1, "active pixel count mismatch: %0d", active_count);
        if (hsync_count != H_SYNC * V_TOTAL)
            $fatal(1, "HSYNC pixel count mismatch: %0d", hsync_count);
        if (vsync_count != V_SYNC * H_TOTAL)
            $fatal(1, "VSYNC pixel count mismatch: %0d", vsync_count);
        if (line_start_count != V_TOTAL)
            $fatal(1, "line-start count mismatch: %0d", line_start_count);
        if (frame_start_count != 1)
            $fatal(1, "frame-start count mismatch: %0d", frame_start_count);
        if (original_request_count != ((MODE==1 || MODE==2) ? 640 * 480 : 0))
            $fatal(1, "original request count mismatch: %0d", original_request_count);
        if (styled_request_count != ((MODE==0 || MODE==2) ? 640 * 480 : 0))
            $fatal(1, "styled request count mismatch: %0d", styled_request_count);

        repeat (3) @(negedge pixel_clk);
        $display("C1_SPLIT_COMPOSITOR_PASS frame_cycles=%0d active=%0d original=%0d styled=%0d",
                 FRAME_CYCLES, active_count,
                 original_request_count, styled_request_count);
        $display("C1_COMPOSITOR_RASTER_MODE_PASS mode=%0d",MODE);
        $finish;
    end

endmodule
