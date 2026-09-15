`timescale 1ns/1ps

// Small lock-step bank smoke test.  Two output groups receive the same
// activation vector but independent weights/affine settings; both results
// must retire together and remain stable while out_ready is low.
module tb_c1_dot8x8_requant_bank;
    localparam integer LANES = 2;
    localparam integer X_BITS = 8;
    localparam integer Y_BITS = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [LANES*256-1:0] start_bias_s32 = '0;
    logic [LANES*144-1:0] start_mult_s18 = '0;
    logic [LANES*48-1:0] start_shift_u6 = '0;
    logic [LANES-1:0] start_relu = '0;
    logic [LANES-1:0] start_sof = '0;
    logic [LANES-1:0] start_eol = '0;
    logic [LANES-1:0] start_eof = '0;
    logic [LANES*X_BITS-1:0] start_x = '0;
    logic [LANES*Y_BITS-1:0] start_y = '0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic in_last = 1'b0;
    logic [7:0] in_lane_mask = 8'hff;
    logic [63:0] in_activations_s8 = '0;
    logic [LANES*512-1:0] in_weights_s8 = '0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic [LANES*64-1:0] out_data_s8;
    logic [LANES-1:0] out_sof, out_eol, out_eof;
    logic [LANES*X_BITS-1:0] out_x;
    logic [LANES*Y_BITS-1:0] out_y;
    logic busy;
    logic [LANES-1:0] overflow_seen;

    c1_dot8x8_requant_bank #(
        .LANES(LANES), .X_BITS(X_BITS), .Y_BITS(Y_BITS),
        .PIPELINED_DOT_TREE(1), .PIPELINED_DOT_TREE_FULL(1)
    ) dut (
        .clk, .rst,
        .start_valid, .start_ready,
        .start_bias_s32, .start_mult_s18, .start_shift_u6,
        .start_relu, .start_sof, .start_eol, .start_eof,
        .start_x, .start_y,
        .in_valid, .in_ready, .in_last, .in_lane_mask,
        .in_activations_s8, .in_weights_s8,
        .out_valid, .out_ready, .out_data_s8,
        .out_sof, .out_eol, .out_eof, .out_x, .out_y,
        .busy, .overflow_seen
    );

    integer cycles;
    integer i;
    initial begin
        repeat (6) @(posedge clk);
        rst = 1'b0;

        // One C8 group: eight activations of +1.  Lane 0 uses +2 weights,
        // lane 1 uses +3 weights; multiplier=1 and shift=0 keep the expected
        // values obvious (16 and 24 respectively).
        in_activations_s8 = {8{8'sd1}};
        for (i = 0; i < 8; i = i + 1) begin
            in_weights_s8[i*8 +: 8] = 8'sd2;
            in_weights_s8[512 + i*8 +: 8] = 8'sd3;
        end
        for (i = 0; i < 8; i = i + 1) begin
            start_mult_s18[i*18 +: 18] = 18'sd1;
            start_mult_s18[144 + i*18 +: 18] = 18'sd1;
        end
        start_sof = 2'b11;
        start_eol = 2'b11;
        start_eof = 2'b11;
        start_x = {X_BITS'(8'd9), X_BITS'(8'd9)};
        start_y = {Y_BITS'(8'd4), Y_BITS'(8'd4)};

        @(negedge clk);
        start_valid = 1'b1;
        do @(posedge clk); while (!start_ready);
        @(negedge clk);
        start_valid = 1'b0;

        in_last = 1'b1;
        in_valid = 1'b1;
        do @(posedge clk); while (!in_ready);
        @(negedge clk);
        in_valid = 1'b0;
        in_last = 1'b0;

        // Deliberate output stall exercises the bank's lock-step hold.
        repeat (8) @(posedge clk);
        out_ready = 1'b1;
        wait (out_valid);
        if (out_data_s8[7:0] !== 8'd16 ||
            out_data_s8[64 +: 8] !== 8'd24)
            $fatal(1, "bank result mismatch data=%h", out_data_s8);
        if (!out_sof[0] || !out_sof[1] || !out_eof[0] || !out_eof[1])
            $fatal(1, "bank metadata mismatch sof/eof=%b/%b", out_sof, out_eof);
        // Keep ready asserted for the retirement edge and sample after NBA
        // updates have settled.
        @(posedge clk);
        #1;
        if (out_valid)
            $fatal(1, "bank output did not retire");

        $display("C1_DOT8X8_REQUANT_BANK_PASS lanes=%0d data0=%0d data1=%0d",
                 LANES, out_data_s8[7:0], out_data_s8[64 +: 8]);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "bank smoke timeout");
    end
endmodule
