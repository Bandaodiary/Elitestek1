`timescale 1ns/1ps
module tb_c1_gamma_initialization;
    parameter integer PROGRAM_LUT = 1;
    logic clk=0, rst=1, valid=0, we=0;
    logic [9:0] addr=0;
    logic [7:0] data=0;
    wire ready, out_valid;
    wire [23:0] rgb;
    always #5 clk=~clk;
    r1_rgb10_color_pipeline dut (
        .clk(clk),.rst(rst),.in_valid(valid),.in_sof(valid),.in_eol(valid),.in_eof(valid),
        .in_x(10'd0),.in_y(9'd0),.in_rgb10({10'd1023,10'd512,10'd0}),
        .cfg_awb_gain_r(16'd16384),.cfg_awb_gain_g(16'd16384),.cfg_awb_gain_b(16'd16384),
        .cfg_ccm_rr(16'sd8192),.cfg_ccm_rg(16'sd0),.cfg_ccm_rb(16'sd0),
        .cfg_ccm_gr(16'sd0),.cfg_ccm_gg(16'sd8192),.cfg_ccm_gb(16'sd0),
        .cfg_ccm_br(16'sd0),.cfg_ccm_bg(16'sd0),.cfg_ccm_bb(16'sd8192),
        .cfg_ccm_offset_r(32'sd0),.cfg_ccm_offset_g(32'sd0),.cfg_ccm_offset_b(32'sd0),
        .gamma_cfg_we(we),.gamma_cfg_addr(addr),.gamma_cfg_data(data),.gamma_cfg_ready(ready),
        .out_valid(out_valid),.out_rgb888(rgb),.out_sof(),.out_eol(),.out_eof(),.out_x(),.out_y()
    );
    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        if(PROGRAM_LUT) begin
            for(integer i=0;i<1024;i=i+1) begin
                @(negedge clk);
                if(ready!==1'b1) $fatal(1,"Gamma not ready while idle");
                we=1; addr=i; data=i>>2;
            end
            @(negedge clk); we=0;
        end
        @(negedge clk); valid=1;
        @(negedge clk); valid=0;
        wait(out_valid);
        @(negedge clk);
        if(!PROGRAM_LUT) $fatal(1,"uninitialized Gamma escaped diagnostic");
        if(rgb!==24'hff8000) $fatal(1,"Gamma identity mismatch: %h",rgb);
        // A control reset must not silently erase a software-programmed LUT.
        rst=1;
        repeat(2) @(negedge clk);
        rst=0;
        @(negedge clk); valid=1;
        @(negedge clk); valid=0;
        wait(out_valid);
        @(negedge clk);
        if(rgb!==24'hff8000) $fatal(1,"Gamma LUT lost on control reset");
        $display("C1_GAMMA_INITIALIZATION_PASS");
        $finish;
    end
    initial begin #20000; $fatal(1,"Gamma test timeout"); end
endmodule
