`timescale 1ns/1ps

module tb_c1_gamma_lut16;
    localparam integer WIDTH = 16;
    localparam integer HEIGHT = 8;
    localparam integer X_BITS = $clog2(WIDTH);
    localparam integer Y_BITS = $clog2(HEIGHT);

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;
    logic [X_BITS-1:0] in_x = '0;
    logic [Y_BITS-1:0] in_y = '0;
    logic [23:0] in_rgb = '0;
    logic cfg_we = 1'b0;
    logic [4:0] cfg_addr = '0;
    logic [8:0] cfg_wdata = '0;
    logic out_valid, out_sof, out_eol, out_eof;
    logic [X_BITS-1:0] out_x;
    logic [Y_BITS-1:0] out_y;
    logic [23:0] out_rgb;
    integer cycles = 0;

    always #5 clk = ~clk;

    c1_gamma_lut16 #(.FRAME_WIDTH(WIDTH), .FRAME_HEIGHT(HEIGHT)) dut (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_rgb, .cfg_we, .cfg_addr, .cfg_wdata,
        .out_valid, .out_sof, .out_eol, .out_eof, .out_x, .out_y, .out_rgb
    );

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        in_valid = 1'b1;
        in_sof = 1'b1;
        in_eol = 1'b1;
        in_eof = 1'b1;
        in_x = 4'd3;
        in_y = 3'd2;
        in_rgb = 24'h6f583a;
        @(negedge clk);
        in_valid = 1'b0;
        in_sof = 1'b0;
        in_eol = 1'b0;
        in_eof = 1'b0;
        wait (out_valid);
        if (out_rgb !== 24'h6f583a)
            $fatal(1,
                "gamma identity mismatch got=%h lower=%0d,%0d,%0d delta=%0d,%0d,%0d interp=%0d,%0d,%0d",
                out_rgb,
                dut.lower_s1[0], dut.lower_s1[1], dut.lower_s1[2],
                dut.delta_s1[0], dut.delta_s1[1], dut.delta_s1[2],
                dut.interp_s2[0], dut.interp_s2[1], dut.interp_s2[2]);
        if (!out_sof || !out_eol || !out_eof || out_x != 4'd3 || out_y != 3'd2)
            $fatal(1, "gamma sideband mismatch");
        $display("C1_GAMMA_PASS output=%h cycles=%0d", out_rgb, cycles);
        $finish;
    end

    always @(negedge clk) begin
        cycles = cycles + 1;
        if (cycles > 100)
            $fatal(1, "gamma timeout");
    end
endmodule
