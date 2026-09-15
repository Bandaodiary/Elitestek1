`timescale 1ns/1ps
module tb_c1_r2_microstyle_graph;
    parameter integer STALLS=0;
    parameter integer CORRUPT_HANDOFF=0;
    localparam BANK_WORDS=16384;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start_valid=0,done_ready=0;
    reg [10:0] frame_width;reg [9:0] frame_height;
    reg [31:0] input_base=0,workspace_base=32'h00800000,output_base=32'h02000000,parameter_base=32'h02800000;
    wire start_ready,busy,done_valid,done_error,stage_done;
    wire [31:0] frame_cycles;wire [4:0] stage_done_index,active_stage;
    wire rd_cmd_valid,rd_ready,wr_cmd_valid,wr_valid,wr_last,wr_response_ready;
    reg rd_cmd_ready=0,rd_valid=0,rd_last=0,rd_error=0,wr_cmd_ready=0,wr_ready=0,wr_response_valid=0,wr_response_error=0;
    wire [31:0] rd_cmd_address,wr_cmd_address;wire [15:0] rd_cmd_beats,wr_cmd_beats;
    reg [127:0] rd_data=0;wire [127:0] wr_data;
    c1_r2_microstyle_graph dut(.*);
    reg [127:0] memory[0:6*BANK_WORDS-1];
    integer owner[0:6*BANK_WORDS-1];
    reg [159:0] parameter_words[0:4095];
    reg [127:0] input0[0:16383],input1[0:16383];
    reg [164:0] expected[0:131071];
    string directory;integer width,height,np,ni,ne;
    integer cycle=0,frame_id=0,expected_index=0,frame_expected_base=0,commits=0;
    integer rd_commands=0,rd_beats=0,wr_commands=0,wr_beats=0,producer_reads=0,parameter_reads=0,blocked_writes=0;
    integer rpos=0,rlen=0,wpos=0,wlen=0,read_delay=0,response_delay=0;
    reg reading=0,writing=0,response_pending=0;
    reg [31:0] raddr,waddr;
    integer fault_mode=0,faults_passed=0,expected_commits=0,invalid_shapes=0;
    reg fault_injected=0;
    integer stage_cycles[0:21],last_commit_cycle=0;
    reg [31:0] random_q=32'h74633a19;
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
    reg held_rd_cmd=0,held_wr_cmd=0,held_wr=0;
    reg [47:0] previous_rd_cmd,previous_wr_cmd;reg [128:0] previous_wr;
    always @(posedge clk) begin : memory_model
        integer mi,want;reg [127:0] value;reg is_last,inject;
        if(rst) begin
            reading<=0;writing<=0;rd_valid<=0;response_pending<=0;wr_response_valid<=0;
            rd_cmd_ready<=0;wr_cmd_ready<=0;wr_ready<=0;held_rd_cmd<=0;held_wr_cmd<=0;held_wr<=0;
        end else begin
            cycle<=cycle+1;random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if(cycle>6000000) $fatal(1,"graph watchdog state=%0d stage=%0d fault=%0d",dut.state,active_stage,fault_mode);
            rd_cmd_ready<=!reading && !rd_valid && (!STALLS || random_q[0]);
            wr_cmd_ready<=!writing && !response_pending && !wr_response_valid && (!STALLS || random_q[1]);
            wr_ready<=writing && (!STALLS || random_q[2]);
            if(held_rd_cmd && (!rd_cmd_valid || previous_rd_cmd!={rd_cmd_address,rd_cmd_beats})) $fatal(1,"read command not held");
            if(held_wr_cmd && (!wr_cmd_valid || previous_wr_cmd!={wr_cmd_address,wr_cmd_beats})) $fatal(1,"write command not held");
            if(held_wr && (!wr_valid || previous_wr!={wr_last,wr_data})) $fatal(1,"write data not held");
            held_rd_cmd<=rd_cmd_valid && !rd_cmd_ready;previous_rd_cmd<={rd_cmd_address,rd_cmd_beats};
            held_wr_cmd<=wr_cmd_valid && !wr_cmd_ready;previous_wr_cmd<={wr_cmd_address,wr_cmd_beats};
            held_wr<=wr_valid && !wr_ready;previous_wr<={wr_last,wr_data};
            if(wr_valid && !wr_ready) blocked_writes<=blocked_writes+1;
            if(rd_cmd_valid && rd_cmd_ready) begin
                if(reading || rd_valid || response_pending || wr_response_valid) $fatal(1,"read crossed prior transaction/commit");
                reading<=1;raddr<=rd_cmd_address;rlen<=rd_cmd_beats;rpos<=0;read_delay<=STALLS ? 3 : 0;rd_commands<=rd_commands+1;
                if(rd_cmd_beats==0) $fatal(1,"zero read descriptor");
            end
            if(rd_valid && rd_ready) begin
                rd_valid<=0;rd_beats<=rd_beats+1;
                if(rd_last) reading<=0;else rpos<=rpos+1;
            end
            if(reading && !rd_valid) begin
                if(read_delay!=0) read_delay<=read_delay-1;
                else if(!STALLS || random_q[3:2]!=0) begin
                    mi=index_of(raddr+rpos*16);value=memory[mi];is_last=rpos==rlen-1;inject=0;
                    if(raddr[31:23]==5) begin
                        if(owner[mi]!=-3 && !(fault_mode==4 && rpos==rlen)) $fatal(1,"parameter uninitialized");
                        parameter_reads<=parameter_reads+1;
                    end else begin
                        want=source_owner(active_stage,raddr[31:23]);
                        if(owner[mi]!=want) $fatal(1,"unwritten/wrong producer stage=%0d slot=%0d word=%0d owner=%0d expected=%0d",active_stage,raddr[31:23],rpos,owner[mi],want);
                        producer_reads<=producer_reads+1;
                    end
                    rd_error<=0;
                    if(!fault_injected) begin
                        if(fault_mode==1 && rpos==0) begin rd_error<=1;inject=1;end
                        if(fault_mode==2 && raddr[31:23]!=5 && rpos==0) begin rd_error<=1;inject=1;end
                        if(fault_mode==3 && rpos==1) begin is_last=1;inject=1;end
                        if(fault_mode==4 && is_last) begin is_last=0;inject=1;end
                        if(fault_mode==5 && rpos==0) begin value[63]=1;inject=1;end
                        if(fault_mode==8 && rpos==0) begin value[47:46]=0;inject=1;end
                    end else if(fault_mode==4 && rpos==rlen) begin is_last=1;value=0;end
                    if(inject) fault_injected<=1;
                    rd_data<=value;rd_last<=is_last;rd_valid<=1;
                end
            end
            if(wr_cmd_valid && wr_cmd_ready) begin
                if(writing || response_pending || wr_response_valid) $fatal(1,"multiple writes outstanding");
                writing<=1;waddr<=wr_cmd_address;wlen<=wr_cmd_beats;wpos<=0;wr_commands<=wr_commands+1;
                if(wr_cmd_beats==0 || active_stage==14 || active_stage==17 || active_stage==21) $fatal(1,"view wrote tensor");
            end
            if(wr_valid && wr_ready) begin
                if(!writing || wr_last!=(wpos==wlen-1)) $fatal(1,"write length mismatch");
                if(expected_index>=ne || expected[expected_index]!=={active_stage,waddr+wpos*32'd16,wr_data}) begin
                    $display("GRAPH_MISMATCH stage=%0d index=%0d addr=%h got=%h expected=%h",active_stage,expected_index,waddr+wpos*32'd16,wr_data,expected[expected_index]);
                    $fatal(1,"graph tensor write not golden");
                end
                mi=index_of(waddr+wpos*16);memory[mi]=wr_data;owner[mi]=active_stage;
                // Negative-only controls: expected remains unchanged. The
                // next layer must observe this REAL corrupted RAM, proving
                // the checker is not secretly supplying golden activations.
                if(active_stage==0 && waddr==32'h00800000 && wpos==0) begin
                    if(CORRUPT_HANDOFF==1) memory[mi]=wr_data^128'h80808080808080808080808080808080;
                    if(CORRUPT_HANDOFF==2) owner[mi]=99;
                end
                expected_index<=expected_index+1;wr_beats<=wr_beats+1;wpos<=wpos+1;
                if(wr_last) begin
                    writing<=0;response_pending<=1;
                    response_delay<=active_stage==20 ? 19 : STALLS ? 5 : 1;
                end
            end
            if(response_pending && !wr_response_valid) begin
                if(response_delay!=0) response_delay<=response_delay-1;
                else begin
                    wr_response_valid<=1;wr_response_error<=0;response_pending<=0;
                    if(!fault_injected && (fault_mode==6 || (fault_mode==7 && active_stage==20 && expected_index==frame_expected_base+ne/2))) begin wr_response_error<=1;fault_injected<=1;end
                end
            end
            if(wr_response_valid && wr_response_ready) wr_response_valid<=0;
            if(stage_done) begin
                if(stage_done_index!=commits || response_pending || wr_response_valid) $fatal(1,"premature/out of order graph commit");
                stage_cycles[commits]=frame_cycles-last_commit_cycle;last_commit_cycle=frame_cycles;commits<=commits+1;
            end
            if(done_valid && (reading || rd_valid || writing || response_pending || wr_response_valid)) $fatal(1,"done before memory drained");
        end
    end
    task configure;
        begin frame_width=width;frame_height=height;input_base=0;workspace_base=32'h00800000;output_base=32'h02000000;parameter_base=32'h02800000;end
    endtask
    task run_frame(input integer fid,input integer fault);
        integer before_cycles,before_read,before_write,before_producers,saved_cycle;
        begin
            @(negedge clk);frame_id=fid;fault_mode=fault;fault_injected=0;commits=0;last_commit_cycle=0;
            expected_index=fid*(ne/2);frame_expected_base=expected_index;
            for(integer i=0;i<6*BANK_WORDS;i=i+1) if(owner[i]!=-3) begin memory[i]=128'hdeadc0de00112233feed7654aabbccdd;owner[i]=-1;end
            for(integer i=0;i<ni;i=i+1) begin memory[i]=fid==0 ? input0[i] : input1[i];owner[i]=-2;end
            configure();start_valid=1;#1;if(!start_ready) $fatal(1,"legal graph start rejected");
            before_cycles=cycle;before_read=rd_beats;before_write=wr_beats;before_producers=producer_reads;
            @(negedge clk);start_valid=0;
            // Perturb live host configuration throughout the active frame.
            frame_width=0;frame_height=0;workspace_base=0;parameter_base=32'hffffffff;
            while(!done_valid) begin @(negedge clk);if(start_ready) $fatal(1,"busy graph accepted new start");end
            @(negedge clk); // Observe the registered final stage_done pulse.
            if(done_error!=(fault!=0)) $fatal(1,"wrong graph completion status fault=%0d",fault);
            if(fault==0) begin
                if(commits!=22 || expected_index!=(fid+1)*(ne/2)) $fatal(1,"incomplete graph writes/commits %0d %0d",commits,expected_index);
                $display("C1_R2_GRAPH_FRAME stalls=%0d width=%0d height=%0d frame=%0d cycles=%0d read_beats=%0d write_beats=%0d producer_reads=%0d commits=%0d",STALLS,width,height,fid,frame_cycles,rd_beats-before_read,wr_beats-before_write,producer_reads-before_producers,commits);
            end else begin
                if(!fault_injected || commits>=22 || (fault==7 && commits!=20)) $fatal(1,"fault injection failed / published bad frame");
                faults_passed=faults_passed+1;
                $display("C1_R2_GRAPH_FAULT stalls=%0d fault=%0d commits=%0d drained=1 cycles=%0d",STALLS,fault,commits,frame_cycles);
            end
            saved_cycle=frame_cycles;
            repeat(8) begin @(negedge clk);if(!done_valid || !busy || done_error!=(fault!=0) || frame_cycles!=saved_cycle) $fatal(1,"completion not held");end
            done_ready=1;@(negedge clk);done_ready=0;configure();#1;
            if(busy || !start_ready) $fatal(1,"graph did not release owner");
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",directory) || !$value$plusargs("W=%d",width) || !$value$plusargs("H=%d",height) ||
           !$value$plusargs("P=%d",np) || !$value$plusargs("I=%d",ni) || !$value$plusargs("E=%d",ne)) $fatal(1,"missing vectors");
        $readmemh({directory,"/parameters.mem"},parameter_words,0,np-1);$readmemh({directory,"/input0.mem"},input0,0,ni-1);
        $readmemh({directory,"/input1.mem"},input1,0,ni-1);$readmemh({directory,"/expected.mem"},expected,0,ne-1);
        for(integer i=0;i<6*BANK_WORDS;i=i+1) owner[i]=-1;
        for(integer i=0;i<np;i=i+1) begin memory[index_of(parameter_words[i][159:128])]=parameter_words[i][127:0];owner[index_of(parameter_words[i][159:128])]=-3;end
        configure();repeat(4) @(negedge clk);rst=0;
        for(integer trial=0;trial<10;trial=trial+1) begin
            configure();case(trial)
                0:frame_width=0;1:frame_width=642;2:frame_height=2;3:frame_height=484;4:input_base=16;
                5:input_base=workspace_base;6:output_base=workspace_base+32'h01000000;
                7:parameter_base=output_base;8:workspace_base=32'hff800000;9:parameter_base=workspace_base+32'h00800000;
            endcase
            start_valid=1;repeat(2) begin @(negedge clk);if(start_ready || busy) $fatal(1,"invalid graph start accepted");end
            start_valid=0;invalid_shapes=invalid_shapes+1;
        end
        run_frame(0,0);run_frame(1,0);
        if(width==12 && height==12) begin
            for(integer f=1;f<=8;f=f+1) run_frame(0,f);
            run_frame(1,0); // no reset after drained errors; all tensors poisoned
        end
        if(producer_reads==0 || (STALLS && blocked_writes==0)) $fatal(1,"missing graph/backpressure coverage");
        $display("C1_R2_GRAPH_PASS stalls=%0d width=%0d height=%0d normal_frames=%0d faults=%0d invalid_shapes=%0d reads=%0d writes=%0d blocked_writes=%0d expected_input_only=1",STALLS,width,height,width==12 ? 3 : 2,faults_passed,invalid_shapes,rd_beats,wr_beats,blocked_writes);
        $finish;
    end
endmodule
