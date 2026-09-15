`timescale 1ns/1ps
module tb_c1_r2_microstyle_axi_graph;
    parameter integer STALLS=0,BURST_BEATS=16,OUTSTANDING=4,MEMORY_DIV=2,COMMAND_LATENCY=20;
    parameter integer CORRUPT_HANDOFF=0,BANK_WORDS=16384,FRAME_RUNS=2,MAX_CYCLES=6000000,AW_WAIT_W=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start_valid=0,done_ready=0;
    reg [10:0] frame_width;reg [9:0] frame_height;
    reg [31:0] input_base=0,workspace_base=32'h00800000,output_base=32'h02000000,parameter_base=32'h02800000;
    wire start_ready,busy,done_valid,done_error,stage_done,protocol_error;
    wire [31:0] frame_cycles;wire [4:0] stage_done_index,active_stage;
    wire [7:0] read_outstanding,write_outstanding;
    wire m_axi_arlock,m_axi_awlock;
    wire [3:0] m_axi_arcache,m_axi_arqos,m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_arprot,m_axi_awprot;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_rid,m_axi_bid;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    wire [2:0] m_axi_arsize,m_axi_awsize;
    wire [1:0] m_axi_arburst,m_axi_awburst,m_axi_rresp,m_axi_bresp;
    wire m_axi_arvalid,m_axi_arready,m_axi_awvalid,m_axi_awready;
    wire [127:0] m_axi_rdata,m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    wire m_axi_rvalid,m_axi_rready,m_axi_rlast,m_axi_wvalid,m_axi_wready,m_axi_wlast,m_axi_bvalid,m_axi_bready;
    reg clear_faults=0,hold_b=0;
    reg [2:0] inject_r=0;reg [1:0] inject_b=0;
    wire fault_r_seen,fault_b_seen,service_read,service_write,idle;
    wire [31:0] service_read_address,service_write_address;
    wire [127:0] service_read_data;
    wire signed [31:0] ar_total,aw_total,r_total,w_total,b_total,peak_read,peak_write;

    c1_r2_microstyle_axi_graph #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) dut(.*);
    c1_r2_axi_memory_bfm #(.BURST_BEATS(BURST_BEATS),.STALLS(STALLS),.MEMORY_DIV(MEMORY_DIV),.LATENCY(COMMAND_LATENCY),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    reg [127:0] memory[0:6*BANK_WORDS-1];
    integer owner[0:6*BANK_WORDS-1];
    reg [159:0] parameter_words[0:4095];
    reg [127:0] input0[0:BANK_WORDS-1],input1[0:BANK_WORDS-1];
    reg [164:0] expected[0:8*BANK_WORDS-1];
    string directory,parameter_path,input0_path,input1_path,expected_path;
    integer width,height,np,ni,ne,cycle=0,expected_index=0,frame_expected_base=0,commits=0;
    integer producer_reads=0,parameter_reads=0,blocked_writes=0,compute_write_beats=0,max_pages=0;
    integer fault_mode=0,faults_passed=0,normal_frames=0,rejected_pages=0,final_hold_cycles=0;
    integer ar_expected=0,aw_expected=0,read_words_expected=0,write_words_expected=0;
    integer burst_words_read=0,burst_words_write=0;
    function integer index_of(input [31:0] addr);
        begin
            if(addr[3:0]!=0 || addr[31:23]>5 || addr[22:4]>=BANK_WORDS) $fatal(1,"TB memory address %h",addr);
            index_of=addr[31:23]*BANK_WORDS+addr[22:4];
        end
    endfunction
    function integer source_owner(input integer stage,input integer slot);
        case(stage)
            0:source_owner=-2;1:source_owner=0;2:source_owner=1;3:source_owner=2;4:source_owner=3;
            5:source_owner=slot==2 ? 1 : 4;6:source_owner=5;7:source_owner=6;8:source_owner=7;
            9:source_owner=slot==3 ? 5 : 8;10:source_owner=9;11:source_owner=10;12:source_owner=11;
            13:source_owner=slot==2 ? 9 : 12;
            15:source_owner=13;16:source_owner=15;18:source_owner=16;19:source_owner=18;20:source_owner=19;
            default:source_owner=-99;
        endcase
    endfunction
    function integer burst_count(input [31:0] addr,input integer words);
        integer left_words,page_words,n;reg [32:0] a;
        begin
            burst_count=0;left_words=words;a={1'b0,addr};
            while(left_words>0) begin
                page_words=256-int'(a[11:4]);n=left_words<BURST_BEATS ? left_words : BURST_BEATS;
                if(n>page_words) n=page_words;
                left_words=left_words-n;a=a+n*16;burst_count=burst_count+1;
            end
        end
    endfunction
    assign service_read_data=service_read ? memory[index_of(service_read_address)] : 128'd0;
    always @* begin
        inject_r=0;inject_b=0;hold_b=0;
        case(fault_mode)
            1:if(service_read_address[31:23]==5) inject_r=1;
            2:if(service_read_address[31:23]!=5) inject_r=1;
            3:if(active_stage==20 && service_read_address[31:23]!=5) inject_r=1;
            4:inject_b=1;
            5:if(active_stage==20 && expected_index==frame_expected_base+ne/2) inject_b=1;
            6:inject_r=2;
            7:inject_r=3;
            8:inject_r=4;
            9:begin inject_b=2;hold_b=!fault_b_seen && dut.u_graph.write_count<2;end
        endcase
        // Prove publication waits for the LAST physical B, not just WLAST.
        if(active_stage==20 && expected_index==frame_expected_base+ne/2 && final_hold_cycles<37) hold_b=1;
    end
    always @(posedge clk) if(!rst) begin : graph_scoreboard
        integer mi,want;
        cycle<=cycle+1;
        if(cycle>MAX_CYCLES) $fatal(1,"AXI graph watchdog state=%0d stage=%0d fault=%0d pages=%0d read=%0d write=%0d rejects=%0d",
                                  dut.u_graph.state,active_stage,fault_mode,dut.u_graph.write_count,read_outstanding,write_outstanding,dut.reject_write);
        if(read_outstanding!=mem.r_count || write_outstanding!=mem.b_count || read_outstanding>OUTSTANDING || write_outstanding>OUTSTANDING) $fatal(1,"AXI independent credit mismatch");
        if({m_axi_arlock,m_axi_arcache,m_axi_arqos,m_axi_arprot,m_axi_awlock,m_axi_awcache,m_axi_awqos,m_axi_awprot}!==24'd0) $fatal(1,"AXI sideband mismatch");
        if(dut.u_graph.write_count>max_pages) max_pages<=dut.u_graph.write_count;
        if(dut.reject_write==1 && dut.wr_valid && dut.wr_ready && dut.wr_last) rejected_pages<=rejected_pages+1;
        if(dut.u_graph.write_count!=int'(dut.u_graph.u_writer.allocated[0])+int'(dut.u_graph.u_writer.allocated[1])+int'(dut.u_graph.w_done)) $fatal(1,"page ownership divergence");
        if(m_axi_wvalid && !m_axi_wready) blocked_writes<=blocked_writes+1;
        if(active_stage==20 && expected_index==frame_expected_base+ne/2 && final_hold_cycles<37) begin
            final_hold_cycles<=final_hold_cycles+1;
            if(done_valid || stage_done) $fatal(1,"publish while final B held");
        end
        if(dut.rd_cmd_valid && dut.rd_cmd_ready && !protocol_error) begin
            ar_expected<=ar_expected+burst_count(dut.rd_cmd_address,dut.rd_cmd_beats);
            read_words_expected<=read_words_expected+dut.rd_cmd_beats;
        end
        if(dut.wr_cmd_valid && dut.wr_cmd_ready && !protocol_error) begin
            aw_expected<=aw_expected+burst_count(dut.wr_cmd_address,dut.wr_cmd_beats);
            write_words_expected<=write_words_expected+dut.wr_cmd_beats;
        end
        if(m_axi_arvalid && m_axi_arready) burst_words_read<=burst_words_read+int'(m_axi_arlen)+1;
        if(m_axi_awvalid && m_axi_awready) burst_words_write<=burst_words_write+int'(m_axi_awlen)+1;
        if(service_read) begin
            mi=index_of(service_read_address);
            if(service_read_address[31:23]==5) begin
                if(owner[mi]!=-3) $fatal(1,"parameter not initialized");
                parameter_reads<=parameter_reads+1;
            end else begin
                want=source_owner(active_stage,service_read_address[31:23]);
                if(owner[mi]!=want) $fatal(1,"unwritten/wrong producer stage=%0d slot=%0d owner=%0d expected=%0d",active_stage,service_read_address[31:23],owner[mi],want);
                producer_reads<=producer_reads+1;
            end
        end
        if(service_write) begin
            if(expected_index>=ne || expected[expected_index]!=={active_stage,service_write_address,m_axi_wdata} || m_axi_wstrb!==16'hffff) begin
                $display("AXI_MISMATCH stage=%0d index=%0d addr=%h got=%h expected=%h",active_stage,expected_index,service_write_address,m_axi_wdata,expected[expected_index]);
                $fatal(1,"AXI graph tensor write not golden");
            end
            mi=index_of(service_write_address);memory[mi]=m_axi_wdata;owner[mi]=active_stage;
            if(active_stage==0 && service_write_address==32'h00800000) begin
                if(CORRUPT_HANDOFF==1) memory[mi]=m_axi_wdata^128'h80808080808080808080808080808080;
                if(CORRUPT_HANDOFF==2) owner[mi]=99;
            end
            expected_index<=expected_index+1;
            if(dut.u_graph.op_busy) compute_write_beats<=compute_write_beats+1;
        end
        if(stage_done) begin
            if(stage_done_index!=commits || !idle) $fatal(1,"premature/out-of-order AXI stage commit");
            commits<=commits+1;
            if(height==480) $display("C1_R2_AXI_STAGE_COMMIT stage=%0d cycles=%0d words=%0d",stage_done_index,frame_cycles,expected_index-frame_expected_base);
        end
        if(done_valid && (!idle || read_outstanding!=0 || write_outstanding!=0)) $fatal(1,"done before AXI drain");
    end
    task configure;
        begin frame_width=width;frame_height=height;input_base=0;workspace_base=32'h00800000;output_base=32'h02000000;parameter_base=32'h02800000;end
    endtask
    task reset_system;
        begin
            @(negedge clk);rst=1;start_valid=0;done_ready=0;clear_faults=0;
            repeat(4) @(negedge clk);rst=0;repeat(3) @(negedge clk);
            if(busy || done_valid || protocol_error || !idle || !start_ready) $fatal(1,"graph system reset");
            // These counters describe physical traffic since the same reset.
            ar_expected=0;aw_expected=0;read_words_expected=0;write_words_expected=0;burst_words_read=0;burst_words_write=0;
        end
    endtask
    task run_frame(input integer fid,input integer fault);
        integer before_read,before_write,before_producer,before_ar,before_aw,before_b,before_compute,saved_cycle,before_rejected;
        begin
            @(negedge clk);clear_faults=1;fault_mode=0;
            @(negedge clk);clear_faults=0;fault_mode=fault;commits=0;final_hold_cycles=0;
            expected_index=fid*(ne/2);frame_expected_base=expected_index;
            for(integer i=0;i<6*BANK_WORDS;i=i+1) if(owner[i]!=-3) begin memory[i]=128'hdeadc0de00112233feed7654aabbccdd;owner[i]=-1;end
            for(integer i=0;i<ni;i=i+1) begin memory[i]=fid==0 ? input0[i] : input1[i];owner[i]=-2;end
            before_read=r_total;before_write=w_total;before_producer=producer_reads;before_ar=ar_total;before_aw=aw_total;before_b=b_total;before_compute=compute_write_beats;before_rejected=rejected_pages;
            configure();start_valid=1;#1;if(!start_ready) $fatal(1,"legal AXI graph start rejected");
            @(negedge clk);start_valid=0;frame_width=0;frame_height=0;workspace_base=0;parameter_base=32'hffffffff;
            while(!done_valid) begin @(negedge clk);if(start_ready) $fatal(1,"busy graph accepted a new frame");end
            @(negedge clk);
            if(done_error!==(fault!=0) || protocol_error!==(fault>=6)) $fatal(1,"wrong AXI completion fault=%0d error=%0d protocol=%0d",fault,done_error,protocol_error);
            if(ar_total!=ar_expected || aw_total!=aw_expected || aw_total!=b_total || burst_words_read!=read_words_expected ||
               burst_words_write!=write_words_expected || w_total!=write_words_expected) $fatal(1,"row/burst/physical transaction conservation");
            if(fault==0) begin
                if(commits!=22 || expected_index!=(fid+1)*(ne/2) || final_hold_cycles!=37 || r_total-before_read!=producer_reads-before_producer+2333) $fatal(1,"incomplete golden / final B coverage");
                normal_frames=normal_frames+1;
                $display("C1_R2_AXI_FRAME stalls=%0d burst=%0d slots=%0d memdiv=%0d latency=%0d width=%0d height=%0d frame=%0d cycles=%0d read_beats=%0d write_beats=%0d producer_reads=%0d ar=%0d aw=%0d b=%0d commits=%0d compute_write_beats=%0d final_b_hold=%0d",
                    STALLS,BURST_BEATS,OUTSTANDING,MEMORY_DIV,COMMAND_LATENCY,width,height,fid,frame_cycles,r_total-before_read,w_total-before_write,producer_reads-before_producer,ar_total-before_ar,aw_total-before_aw,b_total-before_b,commits,compute_write_beats-before_compute,final_hold_cycles);
            end else begin
                if(!(fault_r_seen || fault_b_seen) || commits>=22 || ((fault==3 || fault==5) && commits!=20)) $fatal(1,"fault not injected / published bad frame");
                if(fault==9 && rejected_pages==before_rejected) $fatal(1,"missing local queued-page reject after poisoned B");
                faults_passed=faults_passed+1;
                $display("C1_R2_AXI_FAULT stalls=%0d fault=%0d commits=%0d drained=1 protocol_lock=%0d rejected_pages=%0d cycles=%0d",
                    STALLS,fault,commits,protocol_error,rejected_pages-before_rejected,frame_cycles);
            end
            saved_cycle=frame_cycles;
            repeat(8) begin @(negedge clk);if(!done_valid || !busy || done_error!=(fault!=0) || frame_cycles!=saved_cycle) $fatal(1,"AXI completion not held");end
            done_ready=1;@(negedge clk);done_ready=0;configure();#1;
            if(busy || start_ready!==(fault<6)) $fatal(1,"AXI release / protocol lock");
            if(fault>=6) begin
                repeat(20) begin @(negedge clk);if(start_ready || m_axi_arvalid || m_axi_awvalid) $fatal(1,"protocol lock not persistent");end
                reset_system();
            end
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",directory) || !$value$plusargs("W=%d",width) || !$value$plusargs("H=%d",height) ||
           !$value$plusargs("P=%d",np) || !$value$plusargs("I=%d",ni) || !$value$plusargs("E=%d",ne)) $fatal(1,"missing vectors");
        parameter_path=$sformatf("%s/parameters.mem",directory);input0_path=$sformatf("%s/input0.mem",directory);
        input1_path=$sformatf("%s/input1.mem",directory);expected_path=$sformatf("%s/expected.mem",directory);
        if(np>4096 || ni>BANK_WORDS || ne>8*BANK_WORDS) $fatal(1,"TB vector capacity");
        $readmemh(parameter_path,parameter_words,0,np-1);$readmemh(input0_path,input0,0,ni-1);
        $readmemh(input1_path,input1,0,ni-1);$readmemh(expected_path,expected,0,ne-1);
        if((^parameter_words[0])===1'bx || (^input0[0])===1'bx || (^expected[ne-1])===1'bx) $fatal(1,"unloaded vectors");
        for(integer i=0;i<6*BANK_WORDS;i=i+1) begin owner[i]=-1;memory[i]=0;end
        for(integer i=0;i<np;i=i+1) begin memory[index_of(parameter_words[i][159:128])]=parameter_words[i][127:0];owner[index_of(parameter_words[i][159:128])]=-3;end
        configure();reset_system();
        run_frame(0,0);if(FRAME_RUNS>1) run_frame(1,0);
        if(width==12 && height==12 && FRAME_RUNS>1) begin
            for(integer f=1;f<=9;f=f+1) begin run_frame(0,f);run_frame(1,0);end
        end
        if(producer_reads==0 || max_pages!=2 || (STALLS && blocked_writes==0)) $fatal(1,"missing graph/backpressure coverage");
        if(peak_read>OUTSTANDING || peak_write>OUTSTANDING) $fatal(1,"exceeded AXI limits");
        $display("C1_R2_AXI_PASS stalls=%0d burst=%0d slots=%0d memdiv=%0d latency=%0d width=%0d height=%0d normal_frames=%0d faults=%0d peak_read=%0d peak_write=%0d blocked_writes=%0d max_pages=%0d expected_input_only=1",
                 STALLS,BURST_BEATS,OUTSTANDING,MEMORY_DIV,COMMAND_LATENCY,width,height,normal_frames,faults_passed,peak_read,peak_write,blocked_writes,max_pages);
        $finish;
    end
endmodule
