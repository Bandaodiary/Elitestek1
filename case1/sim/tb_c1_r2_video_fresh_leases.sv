`timescale 1ns/1ps
module tb_c1_r2_video_fresh_leases;
    parameter integer BASELINE=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,enable=1,cap_request=0,cap_cmd_ready=0,cap_done_valid=0,cap_done_bad=0;
    reg nn_request=0,nn_cmd_ready=0,nn_done_valid=0,nn_done_bad=0;
    reg display_request=0,display_cmd_ready=0,display_done_valid=0,display_done_bad=0;
    reg [31:0] capture_tag=0;
    wire cap_request_ready,cap_cmd_valid,cap_done_ready,nn_request_ready,nn_cmd_valid,nn_done_ready;
    wire display_request_ready,display_cmd_valid,display_done_ready;
    wire [31:0] cap_base,cap_tag,nn_input,nn_output,nn_workspace,nn_parameters,nn_tag,display_raw,display_style,display_tag;
    wire [3:0] input_owned;wire [2:0] output_owned;wire capture_active,nn_active,display_active,front_valid;
    wire [31:0] dropped_captures,retired_pairs,display_errors;wire protocol_error;
    generate if(BASELINE)begin : g_old c1_r2_video_rgbx_leases dut(.*);end
             else begin : g_new c1_r2_video_fresh_leases dut(.*);end endgenerate
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
    integer scenarios=0;
    task clear_system;
        begin
            @(negedge clk);rst=1;enable=1;
            cap_request=0;nn_request=0;display_request=0;
            cap_done_valid=0;nn_done_valid=0;display_done_valid=0;
            cap_cmd_ready=0;nn_cmd_ready=0;display_cmd_ready=0;
            repeat(3)@(negedge clk);rst=0;
            check(!capture_active&&!nn_active&&!display_active&&!front_valid&&!protocol_error,"clean state");
        end
    endtask
    task scenario(input integer mode,input [31:0] older_tag,latest_tag,replacement_tag);
        reg [31:0] older_address,latest_address;
        begin
            clear_system();
            cap_start(10);cap_finish(0);nn_start(10);
            cap_start(20);cap_finish(0);nn_finish(0);nn_start(20);display_start(10);
            cap_start(30);cap_finish(0);cap_start(40);
            check(cap_base=='h0d000000,"FREE beats reclaiming READY");
            cap_finish(0);
            cap_start(older_tag);older_address=cap_base;
            check(older_address=='h0c000000,"older READY occupies high-index slot");
            nn_finish(0);nn_start(40);cap_finish(0);
            display_finish(0);display_start(20);
            cap_start(latest_tag);latest_address=cap_base;
            check(latest_address=='h08000000,"display swap released low-index slot");
            if(mode==1)begin
                // The previous capture completes at exactly the next request.
                // The selector must use latest_i_n, not its old registered value.
                @(negedge clk);cap_done_valid=1;capture_tag=replacement_tag;cap_request=1;
                // Let combinational admission settle before passing its value
                // to check(); task input arguments are sampled at invocation.
                #1;
                check(cap_done_ready&&cap_request_ready,"same-edge finish/new request admitted");
                @(negedge clk);cap_done_valid=0;cap_request=0;
                check(cap_cmd_valid&&cap_base==older_address&&cap_tag==replacement_tag,"freshness: latest READY was reclaimed");
                repeat(4)begin
                    capture_tag=capture_tag+1;
                    check(cap_cmd_valid&&cap_base==older_address&&cap_tag==replacement_tag&&!cap_done_ready,"held replacement descriptor");
                    @(negedge clk);
                end
                cap_cmd_ready=1;@(negedge clk);cap_cmd_ready=0;cap_jobs=cap_jobs+1;
                check(capture_active&&cap_done_ready,"replacement active");
                nn_finish(0);nn_start(latest_tag);
            end else if(mode==2)begin
                // No alternative READY: FRONT, pending pair and NN own the
                // other three inputs. Capture must remain admissible.
                nn_finish(0);nn_start(older_tag);cap_finish(0);
                cap_start(replacement_tag);
                check(cap_base==latest_address,"sole READY remains reclaimable");
            end else begin
                cap_finish(0);cap_start(replacement_tag);
                check(cap_base==older_address&&cap_base!=latest_address,"freshness: latest READY was reclaimed");
                nn_finish(0);nn_start(latest_tag);
            end
            if(mode!=2)check(nn_input==latest_address&&nn_input!=cap_base,"NN retained freshest input during capture");
            check(display_tag==20&&display_active&&capture_active&&nn_active,"all active owners remain protected");
            nn_finish(1);cap_finish(1);display_finish(0);
            check(!protocol_error,"freshness selection did not break protocol");
            scenarios=scenarios+1;
        end
    endtask
    initial begin
        scenario(0,50,60,70);
        scenario(1,50,60,70);
        scenario(0,32'hfffffffe,32'h00000000,32'h00000001);
        scenario(2,50,60,70);
        clear_system();
        $display("C1_R2_FRESH_LEASE_PASS checks=%0d cases=%0d captures=%0d nn=%0d displays=%0d alternatives_preserve_latest=3 same_edge=1 tag_wrap=1 only_ready_reclaimed=1 reset=1",checks,scenarios,cap_jobs,nn_jobs,display_jobs);
        $finish;
    end
    initial begin #1000000;$fatal(1,"fresh lease watchdog");end
endmodule
