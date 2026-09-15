`timescale 1ns/1ps

module tb_c1_compositor_modes;
    logic pixel_clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 pixel_clk = ~pixel_clk;

    logic [10:0] timing_x;
    logic [9:0] timing_y;
    logic timing_de, timing_hsync, timing_vsync;
    logic [1:0] display_mode;
    logic original_request, styled_request;
    logic [9:0] original_x, styled_x;
    logic [8:0] original_y, styled_y;
    logic [23:0] rgb;
    logic de, hsync, vsync;

    c1_split_compositor dut (
        .pixel_clk, .rst_n, .timing_x, .timing_y, .timing_de,
        .timing_hsync, .timing_vsync, .display_mode,
        .original_request, .original_x, .original_y,
        .original_rgb(24'h112233),
        .styled_request, .styled_x, .styled_y,
        .styled_rgb(24'haabbcc), .rgb, .de, .hsync, .vsync
    );

    task automatic check_point(
        input logic [1:0] mode,
        input integer x,
        input integer y,
        input logic expect_original,
        input logic expect_styled,
        input integer expect_x,
        input integer expect_y
    );
        begin
            display_mode = mode;
            timing_x = x[10:0];
            timing_y = y[9:0];
            timing_de = 1'b1;
            #1;
            if ((original_request !== expect_original) ||
                (styled_request !== expect_styled))
                $fatal(1,
                       "mode request mismatch mode=%0d x=%0d y=%0d orig=%b styled=%b",
                       mode, x, y, original_request, styled_request);
            if (expect_original &&
                ((original_x !== expect_x[9:0]) ||
                 (original_y !== expect_y[8:0])))
                $fatal(1, "original coordinate mismatch mode=%0d", mode);
            if (expect_styled &&
                ((styled_x !== expect_x[9:0]) ||
                 (styled_y !== expect_y[8:0])))
                $fatal(1, "styled coordinate mismatch mode=%0d", mode);
            if (!expect_original && ((original_x !== 0) ||
                                     (original_y !== 0)))
                $fatal(1, "inactive original coordinates not zero");
            if (!expect_styled && ((styled_x !== 0) ||
                                   (styled_y !== 0)))
                $fatal(1, "inactive styled coordinates not zero");
        end
    endtask

    initial begin
        timing_x = 0; timing_y = 0; timing_de = 0;
        timing_hsync = 0; timing_vsync = 0; display_mode = 0;
        repeat (3) @(posedge pixel_clk);
        @(negedge pixel_clk); rst_n = 1'b1;

        // Styled/original single-image modes center a 640x480 image.
        check_point(2'd0, 320, 120, 1'b0, 1'b1, 0, 0);
        check_point(2'd0, 959, 599, 1'b0, 1'b1, 639, 479);
        check_point(2'd0, 319, 120, 1'b0, 1'b0, 0, 0);
        check_point(2'd1, 320, 120, 1'b1, 1'b0, 0, 0);
        check_point(2'd1, 959, 599, 1'b1, 1'b0, 639, 479);

        // Split mode retains the original left/styled right geometry.
        check_point(2'd2, 0, 120, 1'b1, 1'b0, 0, 0);
        check_point(2'd2, 639, 599, 1'b1, 1'b0, 639, 479);
        check_point(2'd2, 640, 120, 1'b0, 1'b1, 0, 0);
        check_point(2'd2, 1279, 599, 1'b0, 1'b1, 639, 479);

        // Reserved mode and vertical border are fail-black.
        check_point(2'd3, 640, 120, 1'b0, 1'b0, 0, 0);
        check_point(2'd2, 100, 119, 1'b0, 1'b0, 0, 0);

        $display("C1_COMPOSITOR_MODES_PASS points=11");
        $finish;
    end
endmodule
