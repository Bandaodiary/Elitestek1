`timescale 1ns/1ps
module tb_c1_isp_frame_flush #(parameter integer HOLD=1);
    logic clk=0,rst=1,frame_flush=0,in_valid=0,in_sof=0,in_eol=0,in_eof=0;
    logic [2:0] in_x=0,in_y=0;
    logic cfg_commit=0,gamma_cfg_we=0;
    logic [9:0] black=16,gamma_cfg_addr=0;
    logic [7:0] gamma_cfg_data=0;
    wire cfg_ready,gamma_cfg_ready,out_valid,out_sof,out_eol,out_eof;
    wire [2:0] out_x,out_y;
    wire [23:0] out_rgb888;
    logic compare=0;
    integer pixels=0,frames=0,scenario,prefix;
    always #5 clk=~clk;
    c1_r1_isp_pipeline #(.FRAME_WIDTH(6),.FRAME_HEIGHT(5),.ENABLE_FRAME_FLUSH(1)) dut (
        .clk(clk),.rst(rst),.frame_flush(frame_flush),
        .in_valid(in_valid),.in_sof(in_sof),.in_eol(in_eol),.in_eof(in_eof),
        .in_x(in_x),.in_y(in_y),.in_raw10(10'd256),
        .cfg_commit(cfg_commit),.cfg_ready(cfg_ready),
        .cfg_bayer_pattern(2'd0),.cfg_roi_x_parity(1'b0),.cfg_roi_y_parity(1'b0),
        .cfg_black_r(black),.cfg_black_gr(black),.cfg_black_gb(black),.cfg_black_b(black),
        .cfg_awb_gain_r(16'd16384),.cfg_awb_gain_g(16'd16384),.cfg_awb_gain_b(16'd16384),
        .cfg_ccm_rr(16'sd8192),.cfg_ccm_rg(16'sd0),.cfg_ccm_rb(16'sd0),
        .cfg_ccm_gr(16'sd0),.cfg_ccm_gg(16'sd8192),.cfg_ccm_gb(16'sd0),
        .cfg_ccm_br(16'sd0),.cfg_ccm_bg(16'sd0),.cfg_ccm_bb(16'sd8192),
        .cfg_ccm_offset_r(32'sd0),.cfg_ccm_offset_g(32'sd0),.cfg_ccm_offset_b(32'sd0),
        .gamma_cfg_we(gamma_cfg_we),.gamma_cfg_addr(gamma_cfg_addr),
        .gamma_cfg_data(gamma_cfg_data),.gamma_cfg_ready(gamma_cfg_ready),
        .out_valid(out_valid),.out_sof(out_sof),.out_eol(out_eol),.out_eof(out_eof),
        .out_x(out_x),.out_y(out_y),.out_rgb888(out_rgb888)
    );
    always @(posedge clk) begin
        if(compare && out_valid) begin
            // BLC=16, identity color, inverse LUT: 255-((256-16)>>2)=195.
            if(out_rgb888!==24'hc3c3c3 || out_x!==3'(pixels%4+1) ||
               out_y!==3'(pixels/4+1) || out_sof!==(pixels==0) ||
               out_eol!==(pixels%4==3) || out_eof!==(pixels==11) || pixels>=12)
                $fatal(1,"ISP flush recovery/config retention mismatch pixel=%0d rgb=%h",pixels,out_rgb888);
            pixels++;
        end
    end
    task automatic send_prefix(input integer n);
        for(integer k=0;k<n;k++) begin
            @(negedge clk);in_valid=1;in_x=3'(k%6);in_y=3'(k/6);
            in_sof=(k==0);in_eol=(k%6==5);in_eof=(k==29);
        end
        @(negedge clk);in_valid=0;
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(integer k=0;k<1024;k++) begin
            @(negedge clk);gamma_cfg_we=1;gamma_cfg_addr=10'(k);gamma_cfg_data=8'(255-(k>>2));
            @(posedge clk);if(!gamma_cfg_ready) $fatal(1,"Gamma initialization not ready");
        end
        @(negedge clk);gamma_cfg_we=0;cfg_commit=1;
        @(negedge clk);cfg_commit=0;
        for(scenario=0;scenario<3;scenario++) begin
            prefix=(scenario==0)?5:(scenario==1)?17:30;
            send_prefix(prefix);
            @(negedge clk);frame_flush=1;in_valid=1;cfg_commit=1;
            black=0;gamma_cfg_we=1;gamma_cfg_addr=240;gamma_cfg_data=0;
            #1;
            if(out_valid || cfg_ready || gamma_cfg_ready) $fatal(1,"flush did not fence interfaces");
            repeat(HOLD) @(negedge clk);
            frame_flush=0;in_valid=0;cfg_commit=0;gamma_cfg_we=0;
            repeat(16) begin
                @(negedge clk);
                if(out_valid || !cfg_ready || dut.pipeline_busy) $fatal(1,"partial frame survived local flush");
            end
            pixels=0;compare=1;
            send_prefix(30);
            wait(pixels==12);wait(cfg_ready);
            repeat(3) @(negedge clk);compare=0;frames++;
        end
        $display("C1_ISP_FRAME_FLUSH_PASS hold=%0d discarded_prefixes=5/17/30 recovered_frames=%0d retained_config=1 retained_gamma=1",HOLD,frames);
        $finish;
    end
    initial begin #1000000;$fatal(1,"ISP local flush timeout");end
endmodule
