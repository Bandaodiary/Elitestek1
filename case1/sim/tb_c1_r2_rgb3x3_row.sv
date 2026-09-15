`timescale 1ns/1ps
module tb_c1_r2_rgb3x3_row;
    parameter integer STALLS=0;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,load_valid=0,start_valid=0,out_ready=0;
    wire load_ready,start_ready,busy,out_valid,out_last;
    logic [1:0] load_kind=0;
    logic [12:0] load_addr=0;
    logic [31:0] load_data=0;
    logic [10:0] row_width=0;
    logic row_top=0,row_bottom=0;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [9:0] out_x;
    c1_r2_rgb3x3_row dut(.*);
    logic [48:0] commands[0:100000];
    logic [63:0] expected[0:20000];
    logic [63:0] source_words[0:3071];
    string input_path,output_path;
    integer n,m,received=0,cycles=0,job_start=0,job_outputs=0,job_count=0;
    integer first_output=0,last_output=0,blocked=0,load_blocked=0,mac_blocked=0;
    integer job_width=0,requests=0,ram_reads=0,beats=0,job_blocked_start=0,job_mac_blocked_start=0;
    bit checking=0,held=0,force_hold=0,window_held=0,job_top=0,job_bottom=0;
    logic [64:0] held_data;
    logic [777:0] held_window;
    integer window_checks=0,physical_row,sample_x;
    always @(negedge clk)
        out_ready=!rst && !force_hold && (!STALLS || (cycles%97>=43 && cycles%11!=0));
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>300000) $fatal(1,"R2 RGB watchdog");
        if(rst) begin held=0;window_held=0;end
        else begin
            if(load_valid && load_ready && load_kind==0)
                source_words[load_addr[12:1]][load_addr[0]*32+:32]=load_data;
            if(window_held && (!dut.window_valid || {dut.window_x,dut.window_data}!==held_window))
                $fatal(1,"R2 RGB held gather window changed");
            window_held=dut.window_valid && !dut.window_ready;
            held_window={dut.window_x,dut.window_data};
            if(held && (!out_valid || {out_last,out_x,out_mask,out_data}!==held_data)) $fatal(1,"R2 RGB held output changed");
            held=out_valid && !out_ready;held_data={out_last,out_x,out_mask,out_data};
            if(checking && start_valid && start_ready) begin
                job_start=cycles;job_outputs=0;first_output=0;job_width=row_width;requests=0;ram_reads=0;beats=0;
                job_top=row_top;job_bottom=row_bottom;
                job_blocked_start=blocked;job_mac_blocked_start=mac_blocked;
            end
            if(checking && dut.request_valid && dut.request_ready) requests=requests+1;
            if(checking && dut.u_window.read_fire) ram_reads=ram_reads+1;
            if(checking && dut.window_valid && dut.mac_ready) beats=beats+1;
            if(checking && dut.window_valid && dut.window_ready) begin
                // Check every gathered feature byte independently of MAC /
                // quantization, where saturation could otherwise hide errors.
                for(integer ry=0;ry<3;ry=ry+1) begin
                    physical_row=((ry==0 && job_top) || (ry==2 && job_bottom)) ? 1 : ry;
                    for(integer cx=0;cx<4;cx=cx+1) begin
                        sample_x=int'(dut.window_x)+cx-1;
                        if(sample_x<0) sample_x=0;
                        if(sample_x>=job_width) sample_x=job_width-1;
                        if(dut.window_data[(ry*4+cx)*64+:64]!==source_words[physical_row*1024+sample_x])
                            $fatal(1,"R2 RGB window mismatch x=%0d ry=%0d cx=%0d",dut.window_x,ry,cx);
                    end
                end
                window_checks=window_checks+1;
            end
            if(checking && dut.window_valid && !dut.mac_ready) mac_blocked=mac_blocked+1;
            if(checking && busy && load_valid && !load_ready) load_blocked=load_blocked+1;
            if(checking && out_valid && !out_ready) blocked=blocked+1;
            if(checking && out_valid && out_ready) begin
                if(received>=m || {out_x,out_mask,out_data}!==expected[received])
                    $fatal(1,"R2 RGB mismatch index=%0d got=%h expected=%h",received,{out_x,out_mask,out_data},expected[received]);
                if(out_last !== (out_x+2>=job_width)) $fatal(1,"R2 RGB wrong last");
                received=received+1;job_outputs=job_outputs+1;
                if(first_output==0) first_output=cycles;
                last_output=cycles;
                if(out_last) begin
                    if(job_outputs!=(job_width+1)/2 || requests!=job_outputs || ram_reads!=job_outputs*2 || beats!=job_outputs*5)
                        $fatal(1,"R2 RGB redundant/missing RAM request or MAC beat");
                    if(!STALLS && (last_output-first_output!=(job_outputs-1)*5 || cycles-job_start!=job_outputs*5+15))
                        $fatal(1,"R2 RGB throughput outputs=%0d span=%0d latency=%0d",job_outputs,last_output-first_output+1,cycles-job_start);
                    $display("C1_R2_RGB_JOB stalls=%0d job=%0d width=%0d vectors=%0d ram_windows=%0d ram_read_cycles=%0d mac_beats=%0d start_to_last=%0d blocked=%0d mac_blocked=%0d",STALLS,job_count,job_width,job_outputs,requests,ram_reads,beats,cycles-job_start,blocked-job_blocked_start,mac_blocked-job_mac_blocked_start);
                    job_count=job_count+1;
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("OUTPUTS=%s",output_path) ||
           !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m)) $fatal(1,"missing vectors/counts");
        $readmemh(input_path,commands,0,n-1);$readmemh(output_path,expected,0,m-1);
        repeat(4) @(negedge clk);rst=0;
        start_valid=1;row_width=0;#1;if(start_ready) $fatal(1,"zero width accepted");
        @(negedge clk);row_width=1025;#1;if(start_ready) $fatal(1,"excessive width accepted");
        @(negedge clk);start_valid=0;
        for(integer i=0;i<n;i=i+1) begin
            @(negedge clk);
            if(commands[i][48:45]<4) begin
                load_kind=commands[i][46:45];load_addr=commands[i][44:32];load_data=commands[i][31:0];load_valid=1;
                @(posedge clk);while(!load_ready) @(posedge clk);
                @(negedge clk);load_valid=0;
            end else if(commands[i][48:45]==4) begin
                row_width=commands[i][10:0];row_top=commands[i][11];row_bottom=commands[i][12];
                if(!checking) begin
                    start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"initial start refused");
                    @(negedge clk);start_valid=0;
                    repeat(7) @(negedge clk);
                    if(!dut.u_mac.input_open_q) $fatal(1,"preflight did not reach an incomplete reduction");
                    rst=1;
                    repeat(3) @(negedge clk);rst=0;
                    repeat(20) @(negedge clk);if(busy || out_valid) $fatal(1,"partial reduction reset failed");
                    force_hold=1;start_valid=1;
                    @(posedge clk);if(!start_ready) $fatal(1,"held start refused");
                    @(negedge clk);start_valid=0;
                    while(!out_valid) @(negedge clk);
                    repeat(80) @(negedge clk);rst=1;
                    repeat(3) @(negedge clk);rst=0;force_hold=0;
                    repeat(20) @(negedge clk);if(busy || out_valid) $fatal(1,"held reduction reset failed");
                    checking=1;
                end
                start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
                @(negedge clk);start_valid=0;
                load_valid=1;load_kind=3;load_addr=0;load_data=0;
                while(busy) begin
                    if(load_ready) $fatal(1,"active parameter reload accepted");
                    @(negedge clk);
                end
                load_valid=0;
            end else $fatal(1,"invalid opcode");
        end
        repeat(20) @(negedge clk);
        if(received!=m || window_checks!=m || busy || out_valid || load_blocked<20 || (STALLS && (blocked<20 || mac_blocked<20)))
            $fatal(1,"R2 RGB incomplete verification");
        $display("C1_R2_RGB_PASS stalls=%0d jobs=%0d vectors=%0d windows_checked=%0d blocked=%0d mac_blocked=%0d rejected_load_cycles=%0d reset_inflight=2 invalid_extents=2",STALLS,job_count,received,window_checks,blocked,mac_blocked,load_blocked);
        $finish;
    end
endmodule
