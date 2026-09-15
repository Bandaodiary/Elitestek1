`timescale 1ns/1ps
module tb_c1_r2_pw16x8_tile;
    parameter integer STALLS=0;
    logic clk=0; always #5 clk=~clk;
    logic rst=1,load_valid=0,start_valid=0,out_ready=0;
    wire load_ready,start_ready,busy,out_valid,out_last;
    logic [1:0] load_kind=0;
    logic [11:0] load_addr=0;
    logic [31:0] load_data=0;
    logic [10:0] pixel_count=0;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [12:0] out_base;
    c1_r2_pw16x8_tile dut(.*);
    logic [47:0] commands[0:60000];
    logic [66:0] expected[0:30000];
    string input_path,output_path;
    integer n,m,received=0,cycles=0,job_start=0,job_outputs=0,job_count=0;
    integer first_output=0,last_output=0,blocked=0,load_blocked=0;
    integer job_blocked_start=0,job_pixels=0;
    bit checking=0,held=0,force_hold=0;
    logic [67:0] held_data;
    always @(negedge clk) begin
        out_ready=!rst && !force_hold && (!STALLS || (cycles%19>=6 && cycles%7!=0));
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>250000) $fatal(1,"R2 PW watchdog");
        if(rst) held=0;
        else begin
            if(held && (!out_valid || {out_last,out_base,out_mask,out_data}!==held_data))
                $fatal(1,"R2 PW output changed under stall");
            held=out_valid && !out_ready;
            held_data={out_last,out_base,out_mask,out_data};
            if(checking && start_valid && start_ready) begin
                job_start=cycles; job_outputs=0; first_output=0; job_pixels=pixel_count;
                job_blocked_start=blocked;
            end
            if(checking && busy && load_valid && !load_ready) load_blocked=load_blocked+1;
            if(checking && out_valid && !out_ready) blocked=blocked+1;
            if(checking && out_valid && out_ready) begin
                if(received>=m || {out_base,out_mask,out_data}!==expected[received])
                    $fatal(1,"R2 PW mismatch index=%0d got=%h expected=%h",received,{out_base,out_mask,out_data},expected[received]);
                if(out_last !== (out_base+6>=job_pixels*8)) $fatal(1,"R2 PW wrong last");
                received=received+1;job_outputs=job_outputs+1;
                if(first_output==0) first_output=cycles;
                last_output=cycles;
                if(out_last) begin
                    if(job_outputs!=(job_pixels*8+5)/6) $fatal(1,"R2 PW wrong vector count");
                    if(!STALLS && (last_output-first_output+1!=job_outputs || cycles-job_start!=job_outputs+12))
                        $fatal(1,"R2 PW noncontinuous schedule/latency outputs=%0d span=%0d latency=%0d",job_outputs,last_output-first_output+1,cycles-job_start);
                    $display("C1_R2_PW_JOB stalls=%0d job=%0d pixels=%0d vectors=%0d start_to_last=%0d output_span=%0d blocked=%0d",STALLS,job_count,job_pixels,job_outputs,cycles-job_start,last_output-first_output+1,blocked-job_blocked_start);
                    job_count=job_count+1;
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("OUTPUTS=%s",output_path) ||
           !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m)) $fatal(1,"missing files/counts");
        $readmemh(input_path,commands,0,n-1);$readmemh(output_path,expected,0,m-1);
        repeat(4) @(negedge clk);rst=0;
        // Invalid extents are rejected in hardware, not just by assertions.
        start_valid=1;pixel_count=0;#1;
        if(start_ready) $fatal(1,"R2 PW accepted zero extent");
        @(negedge clk);pixel_count=1025;#1;
        if(start_ready) $fatal(1,"R2 PW accepted excessive extent");
        @(negedge clk);start_valid=0;
        for(integer i=0;i<n;i=i+1) begin
            @(negedge clk);
            if(commands[i][47:44]<4) begin
                load_kind=commands[i][45:44];load_addr=commands[i][43:32];load_data=commands[i][31:0];load_valid=1;
                @(posedge clk);while(!load_ready) @(posedge clk);
                @(negedge clk);load_valid=0;
            end else if(commands[i][47:44]==4) begin
                pixel_count=commands[i][10:0];
                if(!checking) begin
                    // Flush after a RAM response and accepted MAC work; reset
                    // keeps features/weights but must remove all pending output.
                    start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"initial start rejected");
                    @(negedge clk);start_valid=0;
                    repeat(3) @(negedge clk);rst=1;
                    repeat(3) @(negedge clk);rst=0;
                    repeat(15) @(negedge clk);
                    if(busy || out_valid) $fatal(1,"R2 PW reset did not flush");
                    // Also reset with RAM/MAC/quantizer fully backpressured.
                    force_hold=1;start_valid=1;
                    @(posedge clk);if(!start_ready) $fatal(1,"held-reset start rejected");
                    @(negedge clk);start_valid=0;
                    while(!out_valid) @(negedge clk);
                    repeat(20) @(negedge clk);
                    rst=1;repeat(3) @(negedge clk);rst=0;force_hold=0;
                    repeat(15) @(negedge clk);
                    if(busy || out_valid) $fatal(1,"R2 PW held reset did not flush");
                    checking=1;
                end
                start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
                @(negedge clk);start_valid=0;
                // Illegal concurrent reload is not accepted (also tests config
                // ownership after last read while quantized output still drains).
                load_valid=1;load_kind=3;load_addr=0;load_data=0;
                while(busy) begin
                    if(load_ready) $fatal(1,"R2 PW allowed active reload");
                    @(negedge clk);
                end
                load_valid=0;
            end else $fatal(1,"invalid test opcode");
        end
        repeat(20) @(negedge clk);
        if(received!=m || busy || out_valid || (STALLS && blocked<20) || load_blocked<20)
            $fatal(1,"R2 PW incomplete verification");
        $display("C1_R2_PW_PASS stalls=%0d jobs=%0d vectors=%0d blocked=%0d rejected_load_cycles=%0d reset_inflight=2 invalid_extents=2",STALLS,job_count,received,blocked,load_blocked);
        $finish;
    end
endmodule
