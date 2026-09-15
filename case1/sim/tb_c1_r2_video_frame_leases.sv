`timescale 1ns/1ps
module tb_c1_r2_video_frame_leases;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,enable=1,cap_request=0,cap_cmd_ready=0,cap_done_valid=0,cap_done_bad=0;
    reg nn_request=0,nn_cmd_ready=0,nn_done_valid=0,nn_done_bad=0;
    reg display_request=0,display_cmd_ready=0,display_done_valid=0,display_done_bad=0;
    reg [31:0] capture_tag=0;
    wire cap_request_ready,cap_cmd_valid,cap_done_ready,nn_request_ready,nn_cmd_valid,nn_done_ready;
    wire display_request_ready,display_cmd_valid,display_done_ready;
    wire [31:0] cap_base,cap_tag,nn_input,nn_output,nn_workspace,nn_parameters,nn_tag,display_raw,display_style,display_tag;
    wire [2:0] input_owned;wire [1:0] output_owned;wire capture_active,nn_active,display_active,front_valid;
    wire [31:0] dropped_captures,retired_pairs,display_errors;wire protocol_error;
    c1_r2_video_frame_leases dut(.*);
    integer checks=0,cap_jobs=0,nn_jobs=0,display_jobs=0;
    reg [31:0] cap_held,nn_in_held,nn_out_held,front_raw,front_style;
    task check(input bit value,input string message);
        begin #1;if(!value)$fatal(1,"lease: %s",message);checks=checks+1;end
    endtask
    task cap_start(input [31:0] tag);
        begin
            @(negedge clk);check(cap_request_ready,"capture ready");capture_tag=tag;cap_request=1;
            @(negedge clk);cap_request=0;cap_held=cap_base;
            repeat(4)begin capture_tag=capture_tag+1;check(cap_cmd_valid&&cap_tag==tag&&cap_base==cap_held&&!cap_done_ready&&!cap_request_ready,"held cap descriptor");@(negedge clk);end
            cap_cmd_ready=1;@(negedge clk);cap_cmd_ready=0;check(capture_active&&cap_done_ready&&!cap_cmd_valid,"capture active");cap_jobs=cap_jobs+1;
        end
    endtask
    task cap_finish(input bit bad);
        begin @(negedge clk);cap_done_bad=bad;cap_done_valid=1;check(cap_done_ready,"capture completion owner");@(negedge clk);cap_done_valid=0;cap_done_bad=0;check(!capture_active,"capture drained");end
    endtask
    task nn_start(input [31:0] tag);
        begin
            @(negedge clk);check(nn_request_ready,"NN ready");nn_request=1;
            @(negedge clk);nn_request=0;nn_in_held=nn_input;nn_out_held=nn_output;
            repeat(4)begin check(nn_cmd_valid&&nn_tag==tag&&nn_input==nn_in_held&&nn_output==nn_out_held&&!nn_done_ready,"held NN descriptor");@(negedge clk);end
            check(nn_workspace=='h08800000&&nn_parameters=='h0a800000,"fixed arena");
            nn_cmd_ready=1;@(negedge clk);nn_cmd_ready=0;check(nn_active&&nn_done_ready&&!nn_request_ready,"NN active");nn_jobs=nn_jobs+1;
        end
    endtask
    task nn_finish(input bit bad);
        begin @(negedge clk);nn_done_bad=bad;nn_done_valid=1;check(nn_done_ready,"NN completion owner");@(negedge clk);nn_done_valid=0;nn_done_bad=0;check(!nn_active,"NN drained");end
    endtask
    task display_start(input [31:0] tag);
        begin
            @(negedge clk);check(display_request_ready,"display ready");display_request=1;
            @(negedge clk);display_request=0;front_raw=display_raw;front_style=display_style;
            repeat(4)begin check(display_cmd_valid&&display_tag==tag&&display_raw==front_raw&&display_style==front_style&&!display_done_ready,"held display pair");@(negedge clk);end
            display_cmd_ready=1;@(negedge clk);display_cmd_ready=0;check(display_active&&front_valid&&!display_request_ready,"display active");display_jobs=display_jobs+1;
        end
    endtask
    task display_finish(input bit bad);
        begin @(negedge clk);display_done_bad=bad;display_done_valid=1;check(display_done_ready,"display completion owner");@(negedge clk);display_done_valid=0;display_done_bad=0;check(!display_active&&front_valid,"retained repeated pair");end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;check(!nn_request_ready&&!display_request_ready,"no unproduced frame");
        cap_start(10);cap_finish(0);cap_start(11);cap_finish(0);nn_start(11);
        check(dropped_captures==1,"stale raw retired");
        cap_start(12);check(cap_base!=nn_input,"capture cannot overwrite NN input");cap_finish(0);
        cap_start(13);cap_finish(0);cap_start(14);check(dropped_captures==2,"reclaim READY only");
        nn_finish(0);display_start(11);check(display_raw!=cap_base,"capture cannot overwrite front");cap_finish(0);
        nn_start(14);check(nn_input!=display_raw&&nn_output!=display_style&&dropped_captures==3,"NN cannot overwrite display pair");
        cap_start(15);nn_finish(1);cap_finish(1);check(dropped_captures==4,"bad capture retired");
        display_finish(1);check(display_errors==1,"display error counter");display_start(11);
        cap_start(20);cap_finish(0);nn_start(20);nn_finish(0);
        check(!display_request_ready,"no swap during live scanout");cap_start(21);
        check(cap_base!=display_raw,"third input protects front");
        display_finish(0);display_start(20);check(retired_pairs==1,"old pair released only at drained swap");cap_finish(0);nn_start(21);
        @(negedge clk);enable=0;#1;check(!cap_request_ready&&!nn_request_ready&&!display_request_ready,"disable blocks admissions");
        nn_finish(0);display_finish(0);enable=1;display_start(21);check(retired_pairs==2,"second atomic paired swap");display_finish(0);
        check(!protocol_error&&cap_jobs==8&&nn_jobs==4&&display_jobs==4,"normal lifecycle coverage");
        @(negedge clk);cap_done_valid=1;@(negedge clk);cap_done_valid=0;
        check(protocol_error&&!cap_request_ready&&!nn_request_ready&&!display_request_ready,"orphan completion locks admissions");
        rst=1;repeat(3)@(negedge clk);rst=0;check(!protocol_error&&input_owned==0&&output_owned==0,"system reset recovery");
        $display("C1_R2_VIDEO_LEASE_PASS checks=%0d captures=%0d nn=%0d displays=%0d pending_hold=1 paired_swaps=2 orphan_lock=1 reset=1",checks,cap_jobs,nn_jobs,display_jobs);$finish;
    end
    initial begin #100000;$fatal(1,"lease watchdog");end
endmodule
