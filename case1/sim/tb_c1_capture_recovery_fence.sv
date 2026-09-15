`timescale 1ns/1ps
module tb_c1_capture_recovery_fence #(parameter integer CAMERA_HALF=7);
    logic core_clk=0,camera_clk=0,camera_run=1;
    always #5 core_clk=~core_clk;
    always #(CAMERA_HALF) if(camera_run) camera_clk=~camera_clk;
    logic core_rst=1,camera_rst=1,request=0,source_quiescent=0,fabric_drained=0;
    wire request_ready,busy,done,core_fifo_reset,camera_fifo_reset;
    logic iv=0,or_ready=0;
    wire ir,ov;
    logic [7:0] idata=0;
    wire [7:0] odata;
    integer completions=0,scenario;
    c1_capture_recovery_fence dut(.*);
    c1_async_stream_fifo #(.DATA_WIDTH(8),.DEPTH(16)) fifo (
        .wr_clk(camera_clk),.wr_rst(camera_rst || camera_fifo_reset),
        .in_valid(iv),.in_ready(ir),.in_data(idata),.wr_full(),
        .rd_clk(core_clk),.rd_rst(core_rst || core_fifo_reset),
        .out_valid(ov),.out_ready(or_ready),.out_data(odata),.rd_empty()
    );
    always @(posedge core_clk) begin
        #1;
        if(!core_rst && done) begin
            if(core_fifo_reset || camera_fifo_reset || busy)
                $fatal(1,"capture recovery done before reset handshake finished");
            completions++;
        end
    end
    task automatic put(input integer value);
        @(negedge camera_clk);iv=1;idata=8'(value);
        @(posedge camera_clk);while(!ir) @(posedge camera_clk);
        @(negedge camera_clk);iv=0;
    endtask
    task automatic hold_check(input integer count,input bit resetting);
        repeat(count) begin
            @(negedge core_clk);
            if(!busy || done || request_ready || core_fifo_reset!==resetting)
                $fatal(1,"capture recovery fence lost pending command scenario=%0d",scenario);
        end
    endtask
    initial begin
        repeat(6) @(negedge camera_clk);
        @(negedge core_clk);core_rst=0;camera_rst=0;
        for(scenario=0;scenario<3;scenario++) begin
            for(integer k=0;k<7;k++) put(32+k);
            wait(ov);
            @(negedge core_clk);request=1;source_quiescent=0;fabric_drained=0;
            hold_check(12,0);
            if(scenario==2) fabric_drained=1;
            else source_quiescent=1;
            hold_check(12,0);
            if(!ov || odata!==8'd32 || camera_fifo_reset)
                $fatal(1,"FIFO erased before AXI drain permission");
            if(scenario==1) begin @(negedge camera_clk);camera_run=0;end
            @(negedge core_clk);fabric_drained=1;source_quiescent=1;
            wait(core_fifo_reset);
            if(scenario==1) begin hold_check(31,1);camera_run=1;end
            if(scenario==2) begin
                wait(camera_fifo_reset);
                @(negedge camera_clk);camera_run=0;
                hold_check(31,1);camera_run=1;
            end
            wait(done);repeat(20) @(negedge core_clk);
            if(completions!=scenario+1 || busy || ov || request_ready)
                $fatal(1,"held command retriggered or stale FIFO data survived");
            // Keep request high across new traffic: never reflush that traffic.
            for(integer k=0;k<7;k++) put(160+k);
            for(integer k=0;k<7;k++) begin
                @(negedge core_clk);or_ready=1;
                @(posedge core_clk);while(!ov) @(posedge core_clk);
                if(odata!==8'(160+k)) $fatal(1,"post-recovery FIFO payload mismatch");
                @(negedge core_clk);or_ready=0;
            end
            repeat(8) @(negedge core_clk);
            if(ov || busy || completions!=scenario+1)
                $fatal(1,"post-recovery extra token/completion");
            request=0;source_quiescent=0;fabric_drained=0;
            @(negedge core_clk);if(!request_ready) $fatal(1,"request not rearmed");
        end
        $display("C1_CAPTURE_RECOVERY_FENCE_PASS half=%0d completions=3 old_tokens_flushed=21 new_tokens_checked=21 held_request_once=1",CAMERA_HALF);
        $finish;
    end
    initial begin #200000; $fatal(1,"capture recovery fence timeout");end
endmodule
