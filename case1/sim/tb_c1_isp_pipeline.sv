`timescale 1ns/1ps

module tb_c1_isp_pipeline;
    localparam integer INPUT_WIDTH = 18;
    localparam integer INPUT_HEIGHT = 14;
    localparam integer OUTPUT_WIDTH = 8;
    localparam integer OUTPUT_HEIGHT = 6;
    localparam integer IN_X_BITS = $clog2(INPUT_WIDTH);
    localparam integer IN_Y_BITS = $clog2(INPUT_HEIGHT);
    localparam integer OUT_X_BITS = $clog2(OUTPUT_WIDTH);
    localparam integer OUT_Y_BITS = $clog2(OUTPUT_HEIGHT);
    localparam integer INPUT_PIXELS = INPUT_WIDTH*INPUT_HEIGHT;
    localparam integer OUTPUT_PIXELS = OUTPUT_WIDTH*OUTPUT_HEIGHT;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;
    logic [IN_X_BITS-1:0] in_x = '0;
    logic [IN_Y_BITS-1:0] in_y = '0;
    logic [9:0] in_raw10 = '0;
    logic cfg_we = 1'b0;
    logic [7:0] cfg_addr = '0;
    logic [31:0] cfg_wdata = '0;
    logic out_valid, out_sof, out_eol, out_eof;
    logic [OUT_X_BITS-1:0] out_x;
    logic [OUT_Y_BITS-1:0] out_y;
    logic [23:0] out_rgb;

    logic [9:0] input_memory [0:INPUT_PIXELS-1];
    logic [23:0] expected_memory [0:OUTPUT_PIXELS-1];
    integer input_index;
    integer output_index = 0;
    integer cycles = 0;
    integer expected_x;
    integer expected_y;

    always #5 clk = ~clk;

    c1_isp_pipeline #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .OUTPUT_HEIGHT(OUTPUT_HEIGHT),
        .X_OFFSET(1), .Y_OFFSET(1), .H_STEP(2), .V_STEP(2)
    ) dut (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_raw10, .cfg_we, .cfg_addr, .cfg_wdata,
        .out_valid, .out_sof, .out_eol, .out_eof, .out_x, .out_y, .out_rgb
    );

    initial begin
        $readmemh("../vectors/isp_input_raw10.hex", input_memory);
        $readmemh("../vectors/isp_expected_rgb24.hex", expected_memory);
        if ((^input_memory[0] === 1'bx) || (^expected_memory[0] === 1'bx))
            $fatal(1, "ISP vector files were not loaded");
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        for (input_index = 0; input_index < INPUT_PIXELS; input_index = input_index + 1) begin
            in_valid = 1'b1;
            in_x = input_index % INPUT_WIDTH;
            in_y = input_index / INPUT_WIDTH;
            in_sof = (input_index == 0);
            in_eol = ((input_index % INPUT_WIDTH) == INPUT_WIDTH-1);
            in_eof = (input_index == INPUT_PIXELS-1);
            in_raw10 = input_memory[input_index];
            @(negedge clk);
        end
        in_valid = 1'b0;
        in_sof = 1'b0;
        in_eol = 1'b0;
        in_eof = 1'b0;
        wait (output_index == OUTPUT_PIXELS);
        repeat (5) @(negedge clk);
        $display("C1_ISP_PASS input=%0d output=%0d cycles=%0d", INPUT_PIXELS, output_index, cycles);
        $finish;
    end

    always @(negedge clk) begin
        cycles = cycles + 1;
        if (!rst && out_valid) begin
            expected_x = output_index % OUTPUT_WIDTH;
            expected_y = output_index / OUTPUT_WIDTH;
            if (out_x !== expected_x[OUT_X_BITS-1:0] || out_y !== expected_y[OUT_Y_BITS-1:0])
                $fatal(1, "ISP coordinate mismatch idx=%0d got=(%0d,%0d) expected=(%0d,%0d)",
                       output_index, out_x, out_y, expected_x, expected_y);
            if (out_rgb !== expected_memory[output_index])
                $fatal(1, "ISP pixel mismatch idx=%0d xy=(%0d,%0d) got=%h expected=%h",
                       output_index, out_x, out_y, out_rgb, expected_memory[output_index]);
            if (out_sof !== (output_index == 0))
                $fatal(1, "ISP SOF mismatch idx=%0d", output_index);
            if (out_eol !== ((output_index % OUTPUT_WIDTH) == OUTPUT_WIDTH-1))
                $fatal(1, "ISP EOL mismatch idx=%0d", output_index);
            if (out_eof !== (output_index == OUTPUT_PIXELS-1))
                $fatal(1, "ISP EOF mismatch idx=%0d", output_index);
            output_index = output_index + 1;
        end
        if (cycles > 5000)
            $fatal(1, "ISP timeout output_index=%0d", output_index);
    end
endmodule
