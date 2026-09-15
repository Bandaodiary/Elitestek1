// C35 retained all-operator regression, only top/instance and tied-off new ports differ.
`timescale 1ns/1ps
module tb_c1_r2_cnn_row_shadow_fallback;
    parameter integer STALLS=0,BOUNDARY_ONLY=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,load_valid=0,start_valid=0,out_ready=0,bulk_valid=0;
    reg [2:0] mode=0,bulk_group=0,bulk_groups=1;
    reg [1:0] load_kind=0,bulk_row=0;
    reg [13:0] load_addr=0,start_size=0;
    reg [5:0] start_channels=0,start_outputs=8,start_row_map=6'b10_01_00;
    reg [31:0] load_data=0;
    reg [9:0] bulk_pair=0;
    reg [127:0] bulk_data=0;
    reg bulk_residual_b=0,row_top=0,row_bottom=0,virtual_up2=0,row_phase=0;
    wire load_ready,bulk_ready,start_ready,busy,out_valid,out_last;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [15:0] out_index;
    wire [2:0] out_mode;
    c1_r2_cnn_row_shadow_engine dut(
        .partition_en(1'b0),.partition_base(9'd0),.partition_end(10'd0),
        .start_shadow_capture(1'b0),.start_shadow_read(1'b0),
        .shadow_available(),.shadow_error(),.op_done(),.*);
    reg [167:0] commands[0:750000];
    reg [72:0] expected[0:250000];
    string ip,op;
    integer n,m,j,cycles=0,received=0,jobs=0,job_start=0,job_vectors=0,job_beats=0;
    integer job_size=0,job_mode=0,job_channels=0,job_outputs=0,job_width=0,job_groups=0;
    integer held_cycles=0,rejections=0,parameter_reads=0,bulk_writes=0,reset_tests=0;
    integer mode_jobs[0:5];
    reg held=0,checking=1,force_hold=0;
    reg [73:0] held_payload;
    reg [5:0] reset_mode_seen=0;
    reg [31:0] saved_config;
    always @(negedge clk)out_ready=!rst && !force_hold && (!STALLS || (cycles%97>=43 && cycles%11!=0));
    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles>20000000)$fatal(1,"compact operator timeout");
        if(rst)held=0;
        else begin
            if(held && (!out_valid || {out_last,out_mode,out_index,out_mask,out_data}!==held_payload))
                $fatal(1,"compact held output changed");
            held=out_valid && !out_ready;
            held_payload={out_last,out_mode,out_index,out_mask,out_data};
            if(bulk_valid && bulk_ready)bulk_writes=bulk_writes+1;
            if(checking)begin
                if(start_valid && start_ready)begin
                    job_start=cycles;job_vectors=0;job_beats=0;job_size=start_size;job_mode=mode;
                    job_channels=start_channels;job_outputs=start_outputs;
                    job_groups=mode==1 || mode==4 ? 1 : mode==5 ? 2 : start_channels/8;
                    job_width=mode==4 || mode==5 ? (start_size+1)/2 : virtual_up2 ? start_size*2 : start_size;
                end
                if(dut.u_compute.in_valid && dut.u_compute.in_ready)job_beats=job_beats+1;
                if(dut.weight_read_en)parameter_reads=parameter_reads+1;
                if(busy && load_valid && start_valid && !load_ready && !start_ready)rejections=rejections+1;
                if(out_valid && !out_ready)held_cycles=held_cycles+1;
                if(out_valid && out_ready)begin : check_result
                    integer nv,nb,overhead;
                    if(received>=m || {out_mode,out_index,out_mask,out_data}!==expected[received])
                        $fatal(1,"compact CNN golden mismatch job=%0d vector=%0d got=%h expected=%h",jobs,received,{out_mode,out_index,out_mask,out_data},expected[received]);
                    nv=job_mode==0 ? (job_size*job_outputs+5)/6 : job_mode==1 ? (job_width+1)/2 :
                       job_mode==2 ? ((job_width+1)/2)*job_groups*3 : job_mode==3 ? (job_size+5)/6 : job_width*job_outputs/6;
                    if(out_mode!=job_mode || out_last!==(job_vectors+1==nv))$fatal(1,"compact job metadata mismatch");
                    received=received+1;job_vectors=job_vectors+1;
                    if(out_last)begin
                        nb=nv*(job_mode==0 ? (job_channels+15)/16 : job_mode==1 ? 5 : job_mode==4 ? 2 : job_mode==5 ? 7 : 1);
                        overhead=(job_mode==0 || job_mode==3) ? 13 : job_mode==4 ? 17 : job_mode==5 ? 19 : 16;
                        if(job_beats!=nb || (!STALLS && cycles-job_start!=nb+overhead))
                            $fatal(1,"compact schedule mismatch mode=%0d cycles=%0d beats=%0d expected=%0d",job_mode,cycles-job_start,job_beats,nb);
                        $display("C1_R2_OVERLAY_OPERATOR_JOB stalls=%0d job=%0d mode=%0d size=%0d channels=%0d outputs=%0d vectors=%0d mac_beats=%0d cycles=%0d",STALLS,jobs,job_mode,job_size,job_channels,job_outputs,job_vectors,job_beats,cycles-job_start);
                        mode_jobs[job_mode]=mode_jobs[job_mode]+1;jobs=jobs+1;
                    end
                end
            end
        end
    end
    task reset_held_job;
        begin
            checking=0;force_hold=1;start_valid=1;
            @(posedge clk);if(!start_ready)$fatal(1,"compact reset trial start rejected");
            @(negedge clk);start_valid=0;
            while(!out_valid)@(negedge clk);
            repeat(100)@(negedge clk);
            rst=1;repeat(3)@(negedge clk);rst=0;force_hold=0;
            repeat(20)@(negedge clk);
            if(busy || out_valid || dut.compute_busy || dut.request_valid_q || dut.u_spatial.u_store.reserved_count!=0 ||
               dut.u_spatial.u_encoder.reserved_count!=0 || dut.u_spatial.u_encoder.rd_valid_q)
                $fatal(1,"compact reset did not flush pipeline");
            checking=1;reset_tests=reset_tests+1;
        end
    endtask
    initial begin
        for(integer mm=0;mm<6;mm=mm+1)mode_jobs[mm]=0;
        if(BOUNDARY_ONLY)begin
            repeat(4)@(negedge clk);rst=0;mode=3;bulk_groups=3;bulk_pair=170;bulk_valid=1;
            for(integer g=0;g<3;g=g+1)begin
                bulk_group=g;
                #1;if(!bulk_ready)$fatal(1,"residual legal capacity group rejected pair=170 group=%0d",g);
                @(negedge clk);
            end
            bulk_pair=171;bulk_group=0;
            #1;if(bulk_ready)$fatal(1,"residual capacity overflow accepted");
            $display("C1_R2_OVERLAY_OPERATOR_BOUNDARY_PASS legal_groups=3 overflow_rejected=1");$finish;
        end
        if(!$value$plusargs("INPUTS=%s",ip) || !$value$plusargs("OUTPUTS=%s",op) || !$value$plusargs("N=%d",n) ||
           !$value$plusargs("M=%d",m) || !$value$plusargs("J=%d",j))$fatal(1,"missing compact vectors");
        $readmemh(ip,commands,0,n-1);$readmemh(op,expected,0,m-1);
        repeat(4)@(negedge clk);rst=0;
        for(integer index=0;index<n;index=index+1)begin
            @(negedge clk);mode=commands[index][163:161];
            case(commands[index][167:164])
                1,2,3:begin
                    load_kind=commands[index][165:164];load_addr=commands[index][141:128];load_data=commands[index][31:0];load_valid=1;
                    @(posedge clk);if(!load_ready)$fatal(1,"legal compact parameter rejected index=%0d",index);
                    @(negedge clk);load_valid=0;
                end
                5:begin
                    bulk_pair=commands[index][137:128];bulk_group=commands[index][140:138];bulk_groups=commands[index][143:141];
                    bulk_row=commands[index][145:144];bulk_residual_b=commands[index][146];bulk_data=commands[index][127:0];bulk_valid=1;
                    @(posedge clk);if(!bulk_ready)$fatal(1,"legal compact bulk rejected index=%0d mode=%0d pair=%0d group=%0d",index,mode,bulk_pair,bulk_group);
                    @(negedge clk);bulk_valid=0;
                end
                4:begin
                    saved_config=commands[index][31:0];start_size=saved_config[13:0];start_channels=saved_config[19:14];
                    start_outputs=saved_config[27:22];row_top=saved_config[20];row_bottom=saved_config[21];virtual_up2=saved_config[28];row_phase=saved_config[29];
                    if(!reset_mode_seen[mode])begin reset_held_job();reset_mode_seen[mode]=1;end
                    start_valid=1;@(posedge clk);if(!start_ready)$fatal(1,"legal compact start rejected mode=%0d size=%0d",mode,start_size);
                    @(negedge clk);load_valid=1;load_kind=3;load_addr=0;load_data=0;
                    while(busy)begin
                        mode=mode+1;start_size=1;start_channels=7;start_outputs=12;virtual_up2=~virtual_up2;row_phase=~row_phase;
                        if(load_ready || start_ready)$fatal(1,"compact accepted active mutation");
                        @(negedge clk);
                    end
                    load_valid=0;start_valid=0;
                end
                default:$fatal(1,"bad compact opcode");
            endcase
        end
        repeat(20)@(negedge clk);
        if(received!=m || jobs!=j || busy || out_valid || reset_tests!=6 || rejections<20 || parameter_reads<20 ||
           (STALLS && held_cycles<20))$fatal(1,"incomplete compact operator regression");
        for(integer mm=0;mm<6;mm=mm+1)if(mode_jobs[mm]==0)$fatal(1,"uncovered compact mode");
        $display("C1_R2_OVERLAY_OPERATOR_PASS stalls=%0d jobs=%0d vectors=%0d bulk_writes=%0d parameter_reads=%0d reset_modes=%0d busy_rejections=%0d held_cycles=%0d packed_weights=1 lanes=6",STALLS,jobs,received,bulk_writes,parameter_reads,reset_tests,rejections,held_cycles);
        $finish;
    end
endmodule
