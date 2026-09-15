`timescale 1ns/1ps
module tb_c1_r2_shared_row_engine;
    parameter integer STALLS=0;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,load_valid=0,start_valid=0,out_ready=0;
    logic [1:0] mode=0,load_kind=0;
    logic [12:0] load_addr=0;
    logic [31:0] load_data=0;
    logic [10:0] start_size=0;
    logic row_top=0,row_bottom=0;
    wire load_ready,start_ready,busy,out_valid,out_last;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [15:0] out_index;
    wire [1:0] out_mode;
    c1_r2_shared_row_engine dut(.*);
    logic [49:0] commands[0:100000];
    logic [71:0] expected[0:30000];
    string ip,op;
    integer n,m,cycles=0,received=0,jobs=0,job_start=0,job_vectors=0,job_beats=0,job_size=0,job_mode=0;
    integer first_output=0,last_output=0,blocked=0,busy_rejections=0,mode_changes=0,previous_mode=-1;
    bit checking=1,force_hold=0,held=0,reset_tested=0;
    logic [72:0] held_payload;
    always @(negedge clk) out_ready=!rst && !force_hold && (!STALLS || (cycles%97>=43 && cycles%11!=0));
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>400000) $fatal(1,"R2 shared watchdog");
        if(rst) held=0;
        else begin
            if(held && (!out_valid || {out_last,out_mode,out_index,out_mask,out_data}!==held_payload)) $fatal(1,"shared held output changed");
            held=out_valid && !out_ready;held_payload={out_last,out_mode,out_index,out_mask,out_data};
            if(checking && start_valid && start_ready) begin
                job_start=cycles;job_vectors=0;job_beats=0;job_size=start_size;job_mode=mode;first_output=0;
                if(previous_mode>=0 && previous_mode!=mode) mode_changes=mode_changes+1;
                previous_mode=mode;
            end
            if(checking && dut.u_compute.accept) job_beats=job_beats+1;
            if(checking && busy && load_valid && start_valid && !load_ready && !start_ready) busy_rejections=busy_rejections+1;
            if(checking && out_valid && !out_ready) blocked=blocked+1;
            if(checking && out_valid && out_ready) begin
                if(received>=m || {out_mode,out_index,out_mask,out_data}!==expected[received])
                    $fatal(1,"shared mismatch index=%0d got=%h expected=%h",received,{out_mode,out_index,out_mask,out_data},expected[received]);
                if(out_mode!=job_mode || out_last!==(job_mode==0 ? out_index+6>=job_size*8 : out_index+2>=job_size)) $fatal(1,"shared wrong job metadata");
                received=received+1;job_vectors=job_vectors+1;if(first_output==0) first_output=cycles;last_output=cycles;
                if(out_last) begin
                    if(job_vectors!=(job_mode==0 ? (job_size*8+5)/6 : (job_size+1)/2) || job_beats!=job_vectors*(job_mode==0 ? 1 : 5))
                        $fatal(1,"shared wrong compute count");
                    if(!STALLS && (cycles-job_start!=job_beats+(job_mode==0 ? 12 : 15) || last_output-first_output!=(job_vectors-1)*(job_mode==0 ? 1 : 5)))
                        $fatal(1,"shared scheduling overhead mode=%0d size=%0d cycles=%0d beats=%0d",job_mode,job_size,cycles-job_start,job_beats);
                    $display("C1_R2_SHARED_JOB stalls=%0d job=%0d mode=%0d size=%0d vectors=%0d mac_beats=%0d cycles=%0d",STALLS,jobs,job_mode,job_size,job_vectors,job_beats,cycles-job_start);
                    jobs=jobs+1;
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("INPUTS=%s",ip) || !$value$plusargs("OUTPUTS=%s",op) || !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m)) $fatal(1,"missing vectors");
        $readmemh(ip,commands,0,n-1);$readmemh(op,expected,0,m-1);
        repeat(4) @(negedge clk);rst=0;
        start_valid=1;start_size=3;mode=2;#1;if(start_ready) $fatal(1,"invalid mode 2 accepted");
        @(negedge clk);mode=3;#1;if(start_ready) $fatal(1,"invalid mode 3 accepted");
        @(negedge clk);mode=0;start_size=0;#1;if(start_ready) $fatal(1,"zero extent accepted");
        @(negedge clk);start_size=1025;#1;if(start_ready) $fatal(1,"excessive extent accepted");
        @(negedge clk);start_valid=0;load_valid=1;mode=1;load_kind=1;load_addr=60;#1;if(load_ready) $fatal(1,"invalid address accepted");
        @(negedge clk);load_kind=3;load_addr=0;load_data=32'h00fc0000;#1;if(load_ready) $fatal(1,"invalid shift accepted");
        @(negedge clk);load_valid=0;
        for(integer i=0;i<n;i=i+1) begin
            @(negedge clk);mode={1'b0,commands[i][45]};
            if(commands[i][49:46]<4) begin
                load_kind=commands[i][47:46];load_addr=commands[i][44:32];load_data=commands[i][31:0];load_valid=1;
                @(posedge clk);while(!load_ready) @(posedge clk);
                @(negedge clk);load_valid=0;
            end else if(commands[i][49:46]==4) begin
                start_size=commands[i][10:0];row_top=commands[i][11];row_bottom=commands[i][12];
                if(mode==1 && !reset_tested) begin
                    checking=0;start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"reset preflight start refused");
                    @(negedge clk);start_valid=0;repeat(7) @(negedge clk);
                    if(!dut.u_compute.u_mac.input_open_q) $fatal(1,"reset did not reach partial K");
                    rst=1;repeat(3) @(negedge clk);rst=0;repeat(20) @(negedge clk);
                    if(busy || out_valid || dut.compute_busy) $fatal(1,"partial reset failed");
                    force_hold=1;start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"held reset start refused");
                    @(negedge clk);start_valid=0;while(!out_valid) @(negedge clk);
                    repeat(100) @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;force_hold=0;
                    repeat(20) @(negedge clk);if(busy || out_valid || dut.compute_busy) $fatal(1,"held reset failed");
                    reset_tested=1;checking=1;
                end
                start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
                @(negedge clk);
                // Adversarial software changes live mode, flags and size while
                // trying to reload/restart. Owner and params must remain bound.
                mode=mode^1;start_size=1;row_top=~row_top;row_bottom=~row_bottom;
                load_valid=1;load_kind=3;load_addr=0;load_data=0;
                while(busy) begin
                    if(load_ready || start_ready) $fatal(1,"shared accepted active mutation");
                    @(negedge clk);mode=mode^1;
                end
                load_valid=0;start_valid=0;
            end else $fatal(1,"bad opcode");
        end
        repeat(20) @(negedge clk);
        if(received!=m || jobs!=28 || mode_changes!=27 || busy || out_valid || dut.compute_busy || busy_rejections<20 || (STALLS && blocked<20))
            $fatal(1,"shared incomplete verification");
        $display("C1_R2_SHARED_PASS stalls=%0d jobs=%0d vectors=%0d mode_changes=%0d blocked=%0d busy_rejections=%0d reset_inflight=2 invalid_commands=6 cached_jobs=2",STALLS,jobs,received,mode_changes,blocked,busy_rejections);
        $finish;
    end
endmodule
