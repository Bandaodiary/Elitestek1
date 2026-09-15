`timescale 1ns/1ps
// Real DW/PW shared-MAC arithmetic, actual shadow storage and cache reuse.
// Golden arrays are checker-only and never drive any DUT input/read response.
module tb_c1_r2_cnn_row_shadow_engine;
    parameter integer STALLS=0,NEGATIVE=0,RESET_PHASE=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,partition_en=0,start_shadow_capture=0,start_shadow_read=0;
    reg [8:0] partition_base=1;
    reg [9:0] partition_end=3;
    reg [2:0] mode=0,bulk_group=0,bulk_groups=2;
    reg load_valid=0,bulk_valid=0,start_valid=0,out_ready=0;
    reg [1:0] load_kind=0,bulk_row=0;
    reg [13:0] load_addr=0,start_size=0;
    reg [31:0] load_data=0;
    reg [9:0] bulk_pair=0;
    reg [127:0] bulk_data=0;
    reg bulk_residual_b=0,row_top=0,row_bottom=0,virtual_up2=0,row_phase=0;
    reg [5:0] start_channels=16,start_outputs=16,start_row_map=6'b10_01_00;
    wire load_ready,bulk_ready,start_ready,busy,out_valid,out_last,shadow_available,shadow_error,op_done;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [15:0] out_index;
    wire [2:0] out_mode;
    c1_r2_cnn_row_shadow_engine dut(.*);
    reg [167:0] commands[0:32767];
    reg [72:0] expected[0:32767];
    reg [31:0] shadow[0:32767];
    reg [8191:0] ip,op,sp;
    integer n,m,sn,j,expected_bulk,expected_params,bad_bias_channel;
    integer cycles=0,received=0,jobs=0,dw_rows=0,pw_rows=0,shadow_words=0;
    integer bulk_writes=0,parameter_writes=0,mac_beats=0,held_cycles=0,busy_rejections=0;
    integer job_packets=0,job_expected=0,job_mode=0,job_start=0;
    integer resets=0,discarded_packets=0,shadow_probes=0;
    integer overlap_cycles=0;
    reg held=0,checking=1,reset_done=0;
    reg [70:0] held_payload;
    wire capture_fire=busy && dut.capture_q && dut.compute_valid && dut.sink_ready;
    wire external_fire=out_valid && out_ready;
    function automatic [31:0] peek_shadow(input integer bank,address);
        case(bank)
            0:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[0].u_ram.mem[address];
            1:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[1].u_ram.mem[address];
            2:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[2].u_ram.mem[address];
            3:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[3].u_ram.mem[address];
            4:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[4].u_ram.mem[address];
            5:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[5].u_ram.mem[address];
            6:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[6].u_ram.mem[address];
            7:peek_shadow=dut.u_spatial.u_store.u_overlay.g_ram[7].u_ram.mem[address];
            default:peek_shadow=32'hxxxxxxxx;
        endcase
    endfunction
    always @(negedge clk)out_ready=!rst && (!STALLS || (cycles%19>=8 && cycles%7!=0));
    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles>2000000)$fatal(1,"shadow engine timeout");
        if(rst)held=0;
        else if(checking)begin
            if(held && (!out_valid || {out_last,out_index,out_mask,out_data}!==held_payload))
                $fatal(1,"shadow engine held output changed");
            held=out_valid && !out_ready;held_payload={out_last,out_index,out_mask,out_data};
            if(held)held_cycles=held_cycles+1;
            if(bulk_valid && bulk_ready)bulk_writes=bulk_writes+1;
            if(load_valid && load_ready)parameter_writes=parameter_writes+1;
            if(dut.u_compute.in_valid && dut.u_compute.in_ready)mac_beats=mac_beats+1;
            if(|dut.shadow_wr_en && (dut.u_spatial.u_store.reserved_count!=0 || dut.u_spatial.u_store.second_q ||
               dut.u_spatial.u_store.pending_valid || dut.u_spatial.u_store.push))overlap_cycles=overlap_cycles+1;
            if(start_valid && start_ready)begin
                job_mode=mode;job_packets=0;job_start=cycles;
                job_expected=start_shadow_capture ? start_size*6 : (start_size*8+5)/6;
            end
            if(dut.capture_q && out_valid)$fatal(1,"DW intermediate leaked to external writer");
            if(capture_fire && external_fire)$fatal(1,"two result owners");
            if(capture_fire || external_fire)begin
                if(received>=m || {out_mode,out_index,out_mask}!==expected[received][72:48])
                    $fatal(1,"shadow engine packet metadata mismatch packet=%0d",received);
                for(integer lane=0;lane<6;lane=lane+1)if(out_mask[lane])
                    if(out_data[lane*8+:8]!==expected[received][lane*8+:8])
                        $fatal(1,"shadow engine DW/PW numeric mismatch packet=%0d mode=%0d lane=%0d got=%h expected=%h",received,out_mode,lane,out_data,expected[received][47:0]);
                if(out_last!=(job_packets+1==job_expected))$fatal(1,"shadow engine premature/missing last");
                received=received+1;job_packets=job_packets+1;
                if(out_last)begin
                    jobs=jobs+1;
                    if(capture_fire)dw_rows=dw_rows+1;else pw_rows=pw_rows+1;
                    $display("C35_SHADOW_ENGINE_ROW mode=%0d packets=%0d cycles=%0d",job_mode,job_packets,cycles-job_start);
                end
            end
        end
    end
    task idle;
        begin load_valid=0;bulk_valid=0;start_valid=0;end
    endtask
    initial begin : stimulus
        if(!$value$plusargs("INPUTS=%s",ip) || !$value$plusargs("OUTPUTS=%s",op) || !$value$plusargs("SHADOW=%s",sp) ||
           !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m) || !$value$plusargs("S=%d",sn) ||
           !$value$plusargs("J=%d",j) || !$value$plusargs("BULK=%d",expected_bulk) ||
           !$value$plusargs("PARAMS=%d",expected_params) || !$value$plusargs("BAD_BIAS=%d",bad_bias_channel))
            $fatal(1,"missing shadow engine vectors");
        if(n<1 || n>32768 || m<1 || m>32768 || sn<1 || sn>32768)$fatal(1,"shadow engine vector capacity");
        $readmemh(ip,commands,0,n-1);$readmemh(op,expected,0,m-1);$readmemh(sp,shadow,0,sn-1);
        repeat(4)@(negedge clk);rst=0;
        for(integer index=0;index<n;index=index+1)begin
            @(negedge clk);idle;mode=commands[index][163:161];
            case(commands[index][167:164])
                1,2,3:begin
                    load_kind=commands[index][165:164];load_addr=commands[index][141:128];load_data=commands[index][31:0];load_valid=1;
                    if(NEGATIVE==2 && dw_rows==0 && mode==2 && load_kind==2 && load_addr==bad_bias_channel)
                        load_data=32'h40000000;
                    #1;if(!load_ready)$fatal(1,"shadow engine parameter rejected index=%0d",index);
                    @(posedge clk);@(negedge clk);load_valid=0;
                end
                5:begin
                    bulk_pair=commands[index][137:128];bulk_group=commands[index][140:138];bulk_groups=commands[index][143:141];
                    bulk_row=commands[index][145:144];bulk_residual_b=commands[index][146];bulk_data=commands[index][127:0];bulk_valid=1;
                    #1;if(!bulk_ready)$fatal(1,"shadow engine source refill rejected index=%0d",index);
                    @(posedge clk);@(negedge clk);bulk_valid=0;
                end
                6:begin
                    if(busy || dut.compute_busy || dut.request_valid_q || dut.sink_busy)$fatal(1,"partition changed before drain");
                    partition_en=commands[index][0];partition_base=commands[index][9:1];partition_end=commands[index][19:10];
                    @(posedge clk);@(negedge clk);
                end
                4:begin : execute_row
                    start_size=commands[index][13:0];start_channels=commands[index][19:14];start_outputs=commands[index][25:20];
                    virtual_up2=commands[index][26];row_top=commands[index][27];row_bottom=commands[index][28];row_phase=commands[index][29];
                    start_shadow_capture=commands[index][30];start_shadow_read=commands[index][31];start_row_map=commands[index][37:32];
                    if(start_shadow_read && !shadow_available)$fatal(1,"PW starts before actual DW publication");
                    start_valid=1;#1;if(!start_ready)$fatal(1,"shadow engine row start rejected index=%0d",index);
                    @(posedge clk);@(negedge clk);start_valid=0;
                    load_valid=1;load_kind=3;load_addr=0;load_data=0;
                    while(busy)begin
                        #1;if(load_ready || start_ready)$fatal(1,"shadow engine accepted busy mutation");
                        busy_rejections=busy_rejections+1;
                        if(NEGATIVE==3 && dut.capture_q && job_packets>=3)begin
                            // Premature PW read must remain illegal even though
                            // a correctly partitioned shadow WRITE is allowed.
                            force dut.u_spatial.u_store.linear_rd_addr=18'h00603;
                            force dut.u_spatial.u_store.linear_rd_en=1'b1;
                        end
                        if(!reset_done && RESET_PHASE!=0 && job_packets>=3 &&
                           ((RESET_PHASE==1 && dut.capture_q) || (RESET_PHASE==2 && !dut.capture_q)))begin
                            idle;checking=0;rst=1;repeat(3)@(negedge clk);rst=0;
                            repeat(4)@(negedge clk);
                            if(busy || out_valid || shadow_available || dut.compute_busy || dut.request_valid_q ||
                               dut.u_spatial.u_store.reserved_count!=0 || dut.u_spatial.u_encoder.reserved_count!=0)
                                $fatal(1,"shadow engine reset did not drain local state");
                            discarded_packets=received;received=0;jobs=0;dw_rows=0;pw_rows=0;shadow_words=0;shadow_probes=0;
                            bulk_writes=0;parameter_writes=0;mac_beats=0;held_cycles=0;busy_rejections=0;overlap_cycles=0;
                            checking=1;resets=resets+1;reset_done=1;index=-1;disable execute_row;
                        end
                        @(negedge clk);
                    end
                    load_valid=0;
                    if(!op_done || shadow_error || dut.compute_busy || dut.request_valid_q)$fatal(1,"shadow row finished with unresolved work");
                    if(start_shadow_capture && !shadow_available)$fatal(1,"DW row was not published");
                    if(start_shadow_read && shadow_available)$fatal(1,"PW row lease not consumed");
                end
                7:begin : check_shadow
                    integer width;
                    width=commands[index][10:0];
                    if(!shadow_available || busy || dut.sink_busy)$fatal(1,"shadow check before complete row");
                    if(NEGATIVE==1 && shadow_words==0)
                        dut.u_spatial.u_store.u_overlay.g_ram[0].u_ram.mem[partition_base]=peek_shadow(0,partition_base)^32'h00000100;
                    for(integer pair=0;pair<width/2;pair=pair+1)for(integer bank=0;bank<8;bank=bank+1)begin
                        if(shadow_words>=sn || peek_shadow(bank,partition_base+pair)!==shadow[shadow_words])
                            $fatal(1,"shadow memory golden mismatch word=%0d bank=%0d",shadow_words,bank);
                        shadow_words=shadow_words+1;
                    end
                    shadow_probes=shadow_probes+1;
                end
                default:$fatal(1,"unknown shadow engine command");
            endcase
        end
        repeat(12)@(negedge clk);
        if(received!=m || jobs!=j || dw_rows*2!=j || pw_rows!=dw_rows || shadow_words!=sn || shadow_probes!=dw_rows ||
           mac_beats!=m || bulk_writes!=expected_bulk || parameter_writes!=expected_params ||
           busy || out_valid || shadow_available || (STALLS && held_cycles<8) ||
           (RESET_PHASE!=0 && (resets!=1 || discarded_packets<3)))$fatal(1,"shadow engine final coverage mismatch");
        $display("C35_SHADOW_ENGINE_PASS stalls=%0d reset_phase=%0d operations=%0d DW_rows=%0d PW_rows=%0d packets=%0d mac_beats=%0d shadow_words=%0d bulk_writes=%0d parameter_writes=%0d held_cycles=%0d resets=%0d discarded_packets=%0d overlap_cycles=%0d real_DW_PW_arithmetic=1 checker_only_intermediates=1 actual_AXI=0 full_graph=0",STALLS,RESET_PHASE,jobs,dw_rows,pw_rows,received,mac_beats,shadow_words,bulk_writes,parameter_writes,held_cycles,resets,discarded_packets,overlap_cycles);
        $finish;
    end
endmodule
