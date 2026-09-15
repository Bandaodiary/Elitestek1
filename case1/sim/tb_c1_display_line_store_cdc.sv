`timescale 1ns/1ps

module tb_c1_display_line_store_cdc;
    localparam integer WIDTH = 4;

    logic core_clk = 1'b0;
    logic pixel_clk = 1'b0;
    logic core_rst = 1'b1;
    logic pixel_rst = 1'b1;

    logic s_valid;
    logic s_ready;
    logic [23:0] s_rgb;
    logic [1:0] s_x;
    logic [7:0] s_y;
    logic s_eol;
    logic primed;

    logic request;
    logic [1:0] request_x;
    logic [7:0] request_y;
    logic request_last;
    logic response_valid;
    logic [23:0] response_rgb;
    logic underflow_pulse;

    logic [10:0] osd_x;
    logic [9:0] osd_y;
    logic osd_enable;
    logic osd_alarm;
    logic [31:0] osd_status;
    logic [23:0] osd_in_rgb;
    logic [23:0] osd_out_rgb;

    integer lines_written;
    integer pixels_checked;
    integer stall_cycles;
    integer underflows_checked;
    integer osd_checks;

    always #5 core_clk = ~core_clk;
    always #7 pixel_clk = ~pixel_clk;

    c1_display_line_store_cdc #(
        .MAX_WIDTH(WIDTH),
        .X_BITS(2),
        .Y_BITS(8)
    ) dut (
        .core_clk(core_clk), .core_rst(core_rst),
        .s_valid(s_valid), .s_ready(s_ready), .s_rgb(s_rgb),
        .s_x(s_x), .s_y(s_y), .s_eol(s_eol), .primed(primed),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
        .request(request), .request_x(request_x), .request_y(request_y),
        .request_last(request_last), .response_valid(response_valid),
        .response_rgb(response_rgb), .underflow_pulse(underflow_pulse)
    );

    c1_hex_osd_overlay #(
        .ORIGIN_X(8), .ORIGIN_Y(8), .DIGITS(8)
    ) u_osd (
        .pixel_x(osd_x), .pixel_y(osd_y), .enable(osd_enable),
        .alarm(osd_alarm), .status_word(osd_status),
        .in_rgb(osd_in_rgb), .out_rgb(osd_out_rgb)
    );

    task automatic push_line(input logic [7:0] y,
                             input logic [23:0] base);
        integer x;
        logic accepted;
        begin
            for (x = 0; x < WIDTH; x = x + 1) begin
                @(negedge core_clk);
                s_valid = 1'b1;
                s_rgb = base + x;
                s_x = x[1:0];
                s_y = y;
                s_eol = (x == WIDTH-1);
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge core_clk);
                    accepted = s_ready;
                    if (!s_ready)
                        stall_cycles = stall_cycles + 1;
                end
            end
            @(negedge core_clk);
            s_valid = 1'b0;
            s_eol = 1'b0;
            lines_written = lines_written + 1;
        end
    endtask

    task automatic request_pixel(input logic [7:0] y,
                                 input integer x,
                                 input logic [23:0] expected,
                                 input logic expect_underflow);
        begin
            @(negedge pixel_clk);
            request = 1'b1;
            request_x = x[1:0];
            request_y = y;
            request_last = (x == WIDTH-1);
            @(posedge pixel_clk);
            #1;
            if (!response_valid)
                $fatal(1, "missing display response y=%0d x=%0d", y, x);
            if (response_rgb !== expected)
                $fatal(1, "display RGB mismatch y=%0d x=%0d got=%06x expected=%06x",
                       y, x, response_rgb, expected);
            if (underflow_pulse !== expect_underflow)
                $fatal(1, "underflow mismatch y=%0d x=%0d got=%0b expected=%0b",
                       y, x, underflow_pulse, expect_underflow);
            if (expect_underflow)
                underflows_checked = underflows_checked + 1;
            else
                pixels_checked = pixels_checked + 1;
            @(negedge pixel_clk);
            request = 1'b0;
            request_last = 1'b0;
        end
    endtask

    task automatic request_line(input logic [7:0] y,
                                input logic [23:0] base);
        integer x;
        begin
            for (x = 0; x < WIDTH; x = x + 1)
                request_pixel(y, x, base + x, 1'b0);
        end
    endtask

    initial begin
        s_valid = 1'b0;
        s_rgb = '0;
        s_x = '0;
        s_y = '0;
        s_eol = 1'b0;
        request = 1'b0;
        request_x = '0;
        request_y = '0;
        request_last = 1'b0;
        osd_x = '0;
        osd_y = '0;
        osd_enable = 1'b0;
        osd_alarm = 1'b0;
        osd_status = 32'h0000_0000;
        osd_in_rgb = 24'h123456;
        lines_written = 0;
        pixels_checked = 0;
        stall_cycles = 0;
        underflows_checked = 0;
        osd_checks = 0;

        repeat (5) @(posedge core_clk);
        repeat (4) @(posedge pixel_clk);
        @(negedge core_clk);
        core_rst = 1'b0;
        @(negedge pixel_clk);
        pixel_rst = 1'b0;

        // OSD pass-through, normal foreground, and alarm foreground.
        #1;
        if (osd_out_rgb !== 24'h123456)
            $fatal(1, "disabled OSD did not pass RGB through");
        osd_checks = osd_checks + 1;
        osd_enable = 1'b1;
        osd_x = 11'd9;
        osd_y = 10'd8;
        #1;
        if (osd_out_rgb !== 24'h30ff60)
            $fatal(1, "OSD normal segment color mismatch");
        osd_checks = osd_checks + 1;
        osd_alarm = 1'b1;
        #1;
        if (osd_out_rgb !== 24'hff3030)
            $fatal(1, "OSD alarm segment color mismatch");
        osd_checks = osd_checks + 1;

        push_line(8'd0, 24'h100000);
        repeat (6) @(posedge pixel_clk);
        if (primed)
            $fatal(1, "one line incorrectly reported both banks primed");

        // Bank zero must refuse y=2 until y=0 has been consumed.
        @(negedge core_clk);
        s_valid = 1'b1;
        s_rgb = 24'h300000;
        s_x = 2'd0;
        s_y = 8'd2;
        s_eol = 1'b0;
        repeat (3) begin
            @(posedge core_clk);
            if (s_ready)
                $fatal(1, "busy ping-pong bank accepted overwrite");
            stall_cycles = stall_cycles + 1;
        end
        @(negedge core_clk);
        s_valid = 1'b0;

        request_line(8'd0, 24'h100000);
        repeat (5) @(posedge core_clk);
        push_line(8'd2, 24'h300000);
        push_line(8'd1, 24'h200000);
        if (!primed)
            $fatal(1, "two occupied banks did not report primed");
        repeat (6) @(posedge pixel_clk);

        request_line(8'd1, 24'h200000);
        // An unavailable odd line returns deterministic black and recovers.
        request_pixel(8'd3, 0, 24'h000000, 1'b1);
        request_line(8'd2, 24'h300000);

        $display("C1_DISPLAY_PREFETCH_CDC_PASS lines=%0d pixels=%0d stalls=%0d underflows=%0d osd=%0d",
                 lines_written, pixels_checked, stall_cycles,
                 underflows_checked, osd_checks);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "display line-store CDC test timeout");
    end
endmodule
