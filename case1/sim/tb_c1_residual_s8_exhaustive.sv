`timescale 1ns/1ps
module tb_c1_residual_s8_exhaustive;
    reg clk=0,rst=1,in_valid=0,in_sof=0,in_eol=0,in_eof=0,in_relu=0;
    reg [9:0] in_x=0;
    reg [8:0] in_y=0;
    reg signed [7:0] in_main=0,in_skip=0;
    wire out_valid,out_sof,out_eol,out_eof;
    wire [9:0] out_x;
    wire [8:0] out_y;
    wire signed [7:0] out_data;
    reg previous_valid=0;
    reg [7:0] previous_data=0;
    reg [21:0] previous_meta=0;
    integer accepted=0, checked=0, n, sum_ref;
    reg current_valid;
    reg [7:0] current_data;
    reg [21:0] current_meta;
    always #5 clk=~clk;
    c1_residual_add_s8 dut(.*);
    always @(posedge clk) begin
        if(!rst) begin
            current_valid=in_valid;
            sum_ref=$signed(in_main);
            sum_ref=sum_ref+$signed(in_skip);
            if(sum_ref>127) sum_ref=127;
            if(sum_ref< -128) sum_ref=-128;
            if(in_relu && sum_ref<0) sum_ref=0;
            current_data=sum_ref[7:0];
            current_meta={in_sof,in_eol,in_eof,in_x,in_y};
            if(in_valid) accepted++;
            #1;
            if(out_valid!==previous_valid) $fatal(1,"residual valid latency mismatch");
            if(previous_valid) begin
                if(out_data!==previous_data ||
                   {out_sof,out_eol,out_eof,out_x,out_y}!==previous_meta)
                    $fatal(1,"residual data/metadata mismatch sample=%0d",checked);
                checked++;
            end
            previous_valid=current_valid;
            previous_data=current_data;
            previous_meta=current_meta;
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst=0;
        // Every signed8 pair, with ReLU off and on: 2 * 256 * 256.
        for(n=0;n<131072;n++) begin
            @(negedge clk);
            in_valid=1; in_main=n[7:0]; in_skip=n[15:8]; in_relu=n[16];
            in_x=n[9:0]; in_y=n[18:10];
            in_sof=(n%13==0); in_eol=(n%7==0); in_eof=(n%23==0);
            if(n%17==0) begin @(negedge clk); in_valid=0; end
        end
        @(negedge clk); in_valid=0;
        repeat(4) @(negedge clk);
        if(accepted!=131072 || checked!=accepted) $fatal(1,"residual count mismatch");
        $display("C1_RESIDUAL_S8_EXHAUSTIVE_PASS cases=%0d relu_modes=2 bubbles=1",checked);
        $finish;
    end
    initial begin #2000000; $fatal(1,"exhaustive residual timeout"); end
endmodule
