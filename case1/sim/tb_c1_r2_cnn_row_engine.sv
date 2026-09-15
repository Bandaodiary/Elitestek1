`timescale 1ns/1ps
module tb_c1_r2_cnn_row_engine;
    parameter integer STALLS=0;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,load_valid=0,start_valid=0,out_ready=0;
    logic [1:0] mode=0,load_kind=0;
    logic [13:0] load_addr=0,start_size=0;
    logic [5:0] start_channels=0;
    logic [31:0] load_data=0;
    logic row_top=0,row_bottom=0;
    wire load_ready,start_ready,busy,out_valid,out_last;
    wire [47:0] out_data;wire [5:0] out_mask;
    wire [15:0] out_index;wire [1:0] out_mode;
    c1_r2_cnn_row_engine dut(.*);
    logic [51:0] commands[0:300000];logic [71:0] expected[0:100000];
    logic [31:0] shadow[0:12287];
    string ip,op;
    integer n,m,j,cycles=0,received=0,jobs=0,job_start=0,job_vectors=0,job_beats=0,job_size=0,job_mode=0,job_groups=0;
    integer first_output=0,last_output=0,blocked=0,busy_rejections=0,mode_changes=0,previous_mode=-1;
    integer job_reads=0,job_windows=0,checked_windows=0,zero_masks=0,full_slots=0,simultaneous_push_pop=0;
    integer expected_vectors,expected_beats,expected_windows,offset;
    bit checking=1,force_hold=0,held=0,reset_tested=0;
    logic [72:0] held_payload;
    always @(negedge clk) out_ready=!rst && !force_hold && (!STALLS || (cycles%97>=43 && cycles%11!=0));
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>1400000) $fatal(1,"R2 CNN watchdog");
        if(rst) held=0;
        else begin
            if(held && (!out_valid || {out_last,out_mode,out_index,out_mask,out_data}!==held_payload)) $fatal(1,"CNN held output changed");
            held=out_valid && !out_ready;held_payload={out_last,out_mode,out_index,out_mask,out_data};
            if(load_valid && load_ready && (mode==1 || mode==2) && load_kind==0) shadow[load_addr]=load_data;
            if(checking && start_valid && start_ready) begin
                job_start=cycles;job_vectors=0;job_beats=0;job_size=start_size;job_mode=mode;first_output=0;
                job_groups=mode==1 ? 1 : start_channels/8;job_reads=0;job_windows=0;
                if(previous_mode>=0 && previous_mode!=mode) mode_changes=mode_changes+1;
                previous_mode=mode;
            end
            if(checking && dut.u_compute.accept) job_beats=job_beats+1;
            if(checking && dut.u_spatial.u_store.read_fire) job_reads=job_reads+1;
            if(checking && dut.u_spatial.u_store.push) job_windows=job_windows+1;
            if(checking && dut.u_spatial.u_store.reserved_count==2) full_slots=full_slots+1;
            if(checking && dut.u_spatial.u_store.push && dut.u_spatial.u_store.pop) simultaneous_push_pop=simultaneous_push_pop+1;
            // Compare the entire 96-byte raw SRAM window, independent of the
            // selected DW channels/weights and even while its consumer stalls.
            if(dut.u_spatial.window_valid) begin : check_window
                integer sx,pr,g,a;
                g=dut.u_spatial.window_group;
                for(integer r=0;r<3;r=r+1) begin
                    pr=((r==0 && dut.u_spatial.top_q) || (r==2 && dut.u_spatial.bottom_q)) ? 1 : r;
                    for(integer col=0;col<4;col=col+1) begin
                        sx=dut.u_spatial.window_x+col-1;
                        if(sx<0) sx=0;if(sx>=dut.u_spatial.width_q) sx=dut.u_spatial.width_q-1;
                        a=(pr<<12)|((sx%2)<<11)|(((sx/2)*dut.u_spatial.groups_q+g)<<1);
                        if(dut.u_spatial.window_data[(r*4+col)*64+:64]!=={shadow[a+1],shadow[a]})
                            $fatal(1,"CNN window mismatch x=%0d group=%0d row=%0d col=%0d addr=%0d",dut.u_spatial.window_x,g,r,col,a);
                    end
                end
                if(checking && dut.u_spatial.window_ready) checked_windows=checked_windows+1;
            end
            if(checking && busy && load_valid && start_valid && !load_ready && !start_ready) busy_rejections=busy_rejections+1;
            if(checking && out_valid && !out_ready) blocked=blocked+1;
            if(checking && out_valid && out_ready) begin
                if(received>=m || {out_mode,out_index,out_mask,out_data}!==expected[received])
                    $fatal(1,"CNN mismatch index=%0d got=%h expected=%h",received,{out_mode,out_index,out_mask,out_data},expected[received]);
                expected_vectors=job_mode==0 ? (job_size*8+5)/6 : job_mode==1 ? (job_size+1)/2 : job_mode==2 ? ((job_size+1)/2)*job_groups*3 : (job_size+5)/6;
                if(out_mode!=job_mode || out_last!==(job_vectors+1==expected_vectors)) $fatal(1,"CNN wrong job metadata");
                received=received+1;job_vectors=job_vectors+1;if(first_output==0) first_output=cycles;last_output=cycles;
                if(out_mask==0) zero_masks=zero_masks+1;
                if(out_last) begin
                    expected_beats=expected_vectors*(job_mode==1 ? 5 : 1);
                    expected_windows=(job_mode==1 || job_mode==2) ? ((job_size+1)/2)*job_groups : 0;
                    if(job_vectors!=expected_vectors || job_beats!=expected_beats || job_windows!=expected_windows || job_reads!=expected_windows*2)
                        $fatal(1,"CNN wrong compute/RAM count vectors=%0d beats=%0d windows=%0d reads=%0d",job_vectors,job_beats,job_windows,job_reads);
                    offset=(job_mode==0 || job_mode==3) ? 13 : 15;
                    if(!STALLS && (cycles-job_start!=job_beats+offset || last_output-first_output!=(job_vectors-1)*(job_mode==1 ? 5 : 1)))
                        $fatal(1,"CNN scheduling overhead mode=%0d size=%0d cycles=%0d beats=%0d output_span=%0d",job_mode,job_size,cycles-job_start,job_beats,last_output-first_output);
                    $display("C1_R2_CNN_JOB stalls=%0d job=%0d mode=%0d size=%0d groups=%0d vectors=%0d mac_beats=%0d windows=%0d ram_reads=%0d cycles=%0d",STALLS,jobs,job_mode,job_size,job_groups,job_vectors,job_beats,job_windows,job_reads,cycles-job_start);
                    jobs=jobs+1;
                end
            end
        end
    end
    task automatic reject_start(input [1:0] mm,input integer size,channels);
        @(negedge clk);mode=mm;start_size=size;start_channels=channels;start_valid=1;
        #1;if(start_ready) $fatal(1,"illegal shape accepted mode=%0d size=%0d channels=%0d",mm,size,channels);
    endtask
    task automatic flush_reset;
        rst=1;repeat(3) @(negedge clk);rst=0;force_hold=0;repeat(20) @(negedge clk);
        if(busy || out_valid || dut.compute_busy || dut.request_valid_q || dut.u_spatial.u_store.reserved_count!=0) $fatal(1,"CNN reset failed");
    endtask
    initial begin
        if(!$value$plusargs("INPUTS=%s",ip) || !$value$plusargs("OUTPUTS=%s",op) || !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m) || !$value$plusargs("J=%d",j)) $fatal(1,"missing vectors");
        $readmemh(ip,commands,0,n-1);$readmemh(op,expected,0,m-1);
        repeat(4) @(negedge clk);rst=0;
        reject_start(0,0,16);reject_start(0,1025,16);reject_start(0,3,8);
        reject_start(1,1025,8);reject_start(1,3,16);reject_start(2,0,48);
        reject_start(2,1025,16);reject_start(2,683,24);reject_start(2,341,48);reject_start(2,3,8);
        reject_start(3,0,0);reject_start(3,8193,0);
        @(negedge clk);start_valid=0;load_valid=1;mode=1;load_kind=1;load_addr=60;#1;if(load_ready) $fatal(1,"invalid RGB address accepted");
        @(negedge clk);mode=2;load_addr=144;#1;if(load_ready) $fatal(1,"invalid DW address accepted");
        @(negedge clk);load_kind=0;load_addr=12288;#1;if(load_ready) $fatal(1,"invalid row address accepted");
        @(negedge clk);load_kind=3;load_addr=0;load_data=32'h00fc0000;#1;if(load_ready) $fatal(1,"invalid shift accepted");
        @(negedge clk);load_data=32'h80000000;#1;if(load_ready) $fatal(1,"reserved affine bits accepted");
        @(negedge clk);mode=3;load_kind=1;load_data=0;#1;if(load_ready) $fatal(1,"residual weight mutation accepted");
        @(negedge clk);load_valid=0;
        for(integer i=0;i<n;i=i+1) begin
            @(negedge clk);mode=commands[i][47:46];
            if(commands[i][51:48]<4) begin
                load_kind=commands[i][49:48];load_addr=commands[i][45:32];load_data=commands[i][31:0];load_valid=1;
                @(posedge clk);while(!load_ready) @(posedge clk);
                @(negedge clk);load_valid=0;
            end else if(commands[i][51:48]==4) begin
                start_size=commands[i][13:0];start_channels=commands[i][19:14];row_top=commands[i][20];row_bottom=commands[i][21];
                if(mode==1 && !reset_tested) begin
                    checking=0;start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"window reset start refused");
                    @(negedge clk);start_valid=0;while(!dut.u_spatial.u_store.second_q) @(negedge clk);
                    flush_reset();
                    start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"partial reset start refused");
                    @(negedge clk);start_valid=0;while(!dut.u_compute.u_mac.input_open_q) @(negedge clk);
                    flush_reset();
                    force_hold=1;start_valid=1;@(posedge clk);if(!start_ready) $fatal(1,"held reset start refused");
                    @(negedge clk);start_valid=0;while(!out_valid) @(negedge clk);
                    repeat(100) @(negedge clk);if(dut.u_spatial.u_store.reserved_count!=2) $fatal(1,"reset pressure did not fill slots");
                    flush_reset();reset_tested=1;checking=1;
                end
                start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
                @(negedge clk);mode=mode+1;start_size=1;start_channels=7;row_top=~row_top;row_bottom=~row_bottom;
                load_valid=1;load_kind=3;load_addr=0;load_data=0;
                while(busy) begin
                    if(load_ready || start_ready) $fatal(1,"CNN accepted active mutation");
                    @(negedge clk);mode=mode+1;start_channels=start_channels+1;
                end
                load_valid=0;start_valid=0;
            end else $fatal(1,"bad opcode");
        end
        repeat(20) @(negedge clk);
        if(received!=m || jobs!=j || mode_changes<30 || busy || out_valid || dut.compute_busy || busy_rejections<20 ||
           zero_masks<1 || checked_windows<20 || simultaneous_push_pop<20 || (STALLS && blocked<20)) $fatal(1,"CNN incomplete verification");
        $display("C1_R2_CNN_PASS stalls=%0d jobs=%0d vectors=%0d mode_changes=%0d blocked=%0d busy_rejections=%0d windows=%0d zero_masks=%0d full_slots=%0d simultaneous_push_pop=%0d reset_inflight=3 invalid_commands=18",STALLS,jobs,received,mode_changes,blocked,busy_rejections,checked_windows,zero_masks,full_slots,simultaneous_push_pop);
        $finish;
    end
endmodule
