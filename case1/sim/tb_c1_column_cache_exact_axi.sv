`timescale 1ns/1ps
// Real column cache -> exact-count completion -> scheduler -> AXI128 reader.
// No vendor IP or behavioural replacement of the production refill transport.
module tb_c1_column_cache_exact_axi #(
`ifdef C1_COLUMN_REFILL_HANDOFF
    parameter bit REFILL_HANDOFF=1,
`else
    parameter bit REFILL_HANDOFF=0,
`endif
`ifdef C1_COLUMN_READ_ON_LOOKUP
    parameter bit READ_ON_LOOKUP=1,
`else
    parameter bit READ_ON_LOOKUP=0,
`endif
`ifdef C1_COLUMN_OWNER
    parameter integer OWNER=1,
`else
    parameter integer OWNER=0,
`endif
`ifdef C1_COLUMN_EPOCH_EXHAUST
    parameter integer EXHAUST_TEST=1,
`else
    parameter integer EXHAUST_TEST=0,
`endif
`ifdef C1_COLUMN_BEAT_FIFO
    parameter integer BEAT_FIFO=1,
`else
    parameter integer BEAT_FIFO=0,
`endif
`ifdef C1_COLUMN_SKID_1
    parameter integer SKID_DEPTH=1
`elsif C1_COLUMN_SKID_3
    parameter integer SKID_DEPTH=3
`else
    parameter integer SKID_DEPTH=2
`endif
);
    localparam integer W=11, H=7, G=3, ROW_WORDS=W*G, QDEPTH=16;
    localparam logic [31:0] BASE=32'h00001ff8;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic stage_base_valid=1, group_start_valid=0;
    logic [31:0] stage_base_addr=BASE;
    logic [15:0] frame_width=W, frame_height=H;
    logic [3:0] frame_groups=G;
    wire group_start_ready,group_start_done,group_start_error,config_valid;
    wire [2:0] group_start_error_code;
    logic abort_req=0,flush_req=0;
    wire abort_done,flush_done;
    logic column_valid=0,column_rsp_ready=0;
    logic signed [16:0] column_x=0,column_y=0;
    logic [2:0] column_group=0;
    wire column_ready,column_rsp_valid,column_rsp_error;
    wire [191:0] column_rsp_data;
    wire m_axi_arvalid,m_axi_arready,m_axi_rvalid,m_axi_rready,m_axi_rlast;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst,m_axi_rresp;
    wire [127:0] m_axi_rdata;
    wire cache_error,refill_protocol_error,refill_done,refill_done_error,busy,quiescent;
    wire [2:0] cache_error_code;
    localparam integer EPOCH_BITS=EXHAUST_TEST?2:8;
    wire [EPOCH_BITS-1:0] current_epoch;
    wire [63:0] perf_refill_count,perf_refill_word_count,perf_axi_burst_count,perf_axi_beat_count;
    wire [63:0] perf_req_count,leaf_perf_packed_request_count;
    wire [7:0] leaf_perf_max_outstanding;
    initial $display("C1_COLUMN_AXI_OWNER_CONFIG owner=%0d",OWNER);
    initial $display("C1_COLUMN_AXI_LOOKUP_CONFIG enabled=%0d",READ_ON_LOOKUP);
    initial $display("C1_COLUMN_AXI_HANDOFF_CONFIG enabled=%0d window=32",REFILL_HANDOFF);
    c1_column_cache_owned_exact_burst_shell #(
        .ALLOW_SCHED_REQ_HANDOFF(REFILL_HANDOFF),
        .COLUMN_READ_ON_LOOKUP(READ_ON_LOOKUP),
        .ENABLE_OWNER(OWNER), .LINE_ROWS(3), .MAX_ROW_WORDS(ROW_WORDS), .MAX_GROUPS(8),
        .EPOCH_W(EPOCH_BITS), .CMD_FIFO_DEPTH(2), .SCHED_MAX_OUTSTANDING(32),
        .REQ_FIFO_DEPTH(32), .BURST_BEATS(4), .READER_MAX_OUTSTANDING(4),
        // Minimal word FIFO intentionally forces real AXI R backpressure.
        // Beat mode requires reserved capacity for BURST_BEATS*outstanding.
        .RSP_FIFO_DEPTH(BEAT_FIFO?16:2), .BUILD_TIMEOUT_CYCLES(2),
        .RSP_FIFO_BEAT_MODE(BEAT_FIFO!=0), .REFILL_SKID_DEPTH(SKID_DEPTH)
    ) dut (
        .clk(clk),.rst(rst),.stage_base_valid(stage_base_valid),.stage_base_addr(stage_base_addr),
        .group_start_valid(group_start_valid),.group_start_ready(group_start_ready),
        .frame_width(frame_width),.frame_height(frame_height),.frame_groups(frame_groups),
        .group_start_done(group_start_done),.group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),.config_valid(config_valid),
        .abort_req(abort_req),.abort_done(abort_done),.flush_req(flush_req),.flush_done(flush_done),
        .tap_valid(column_valid),.tap_ready(column_ready),.tap_x(column_x),.tap_y(column_y),
        .tap_group(column_group),.tap_rsp_valid(column_rsp_valid),.tap_rsp_ready(column_rsp_ready),
        .tap_rsp_data_s8(column_rsp_data),.tap_rsp_error(column_rsp_error),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),
        .m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready),
        .cache_error(cache_error),.cache_error_code(cache_error_code),
        .refill_protocol_error(refill_protocol_error),.refill_done(refill_done),
        .refill_done_error(refill_done_error),.busy(busy),.quiescent(quiescent),
        .perf_refill_count(perf_refill_count),.perf_refill_word_count(perf_refill_word_count),
        .perf_axi_burst_count(perf_axi_burst_count),.perf_axi_beat_count(perf_axi_beat_count),
        .perf_req_count(perf_req_count),.current_epoch(current_epoch),
        .leaf_perf_packed_request_count(leaf_perf_packed_request_count),
        .leaf_perf_max_outstanding(leaf_perf_max_outstanding)
    );

    integer cycles=0,ar_count=0,beat_count=0,qhead=0,qtail=0,qcount=0,rbeat=0;
    integer model_epoch=1, fault_resp=0;
    logic allow_ar=1,allow_r=1,active=0,rhold=0;
    logic [31:0] qaddr[0:QDEPTH-1];
    integer qlen[0:QDEPTH-1],qepoch[0:QDEPTH-1],qerror[0:QDEPTH-1];
    integer ar_stalls=0,r_stalls=0,r_gaps=0,ar_boundary=0,multibeat=0;
    function automatic [63:0] memory_word(input logic [31:0] addr,input integer epoch);
        for(integer c=0;c<8;c++)
            memory_word[c*8 +:8]=8'((addr>>3) ^ (addr>>11) ^ (c*39) ^ (epoch*61));
    endfunction
    assign m_axi_arready=!rst && allow_ar && qcount<QDEPTH && cycles%3!=1;
    assign m_axi_rvalid=!rst && active && (rhold || (allow_r && cycles%4!=2));
    assign m_axi_rresp=2'(qerror[qhead]);
    assign m_axi_rlast=active && rbeat==qlen[qhead]-1;
    assign m_axi_rdata={memory_word(qaddr[qhead]+rbeat*16+8,qepoch[qhead]),
                        memory_word(qaddr[qhead]+rbeat*16,qepoch[qhead])};
    wire ar_fire=m_axi_arvalid && m_axi_arready;
    wire r_fire=m_axi_rvalid && m_axi_rready;
    always @(posedge clk) begin
        if(rst) begin
            cycles<=0;qhead<=0;qtail<=0;qcount<=0;active<=0;rhold<=0;rbeat<=0;
        end else begin
            cycles<=cycles+1;
            if(m_axi_arvalid && !m_axi_arready) ar_stalls++;
            if(m_axi_rvalid && !m_axi_rready) r_stalls++;
            if(active && !m_axi_rvalid) r_gaps++;
            if(!active && qcount!=0) begin active<=1;rbeat<=0;end
            if(ar_fire) begin
                if(m_axi_arsize!=4 || m_axi_arburst!=1 || m_axi_araddr[3:0]!=0 ||
                   (m_axi_araddr>>12)!=((m_axi_araddr+(m_axi_arlen+1)*16-1)>>12))
                    $fatal(1,"AXI alignment/size/4KiB boundary violation");
                qaddr[qtail]<=m_axi_araddr; qlen[qtail]<=int'(m_axi_arlen)+1;
                qepoch[qtail]<=model_epoch; qerror[qtail]<=fault_resp;
                qtail<=(qtail+1)%QDEPTH; ar_count++;
                if(m_axi_araddr[11:0]==12'hff0) ar_boundary++;
                if(m_axi_arlen!=0) multibeat++;
            end
            if(r_fire) begin
                beat_count++;
                if(m_axi_rlast) begin active<=0;qhead<=(qhead+1)%QDEPTH;end
                else rbeat<=rbeat+1;
            end
            if(m_axi_rvalid && !m_axi_rready) rhold<=1;
            else if(r_fire || !active) rhold<=0;
            case({ar_fire,r_fire && m_axi_rlast})
                2'b10:qcount<=qcount+1;
                2'b01:qcount<=qcount-1;
                default:begin end
            endcase
        end
    end

    integer accepted=0,responses=0,aborts=0,flushes=0,parallel3=0;
    integer real_handoffs=0, adjacent_requests=0, credit_peak=0;
    logic previous_request=0;
    wire refill_fire=dut.u_backend.u_exact.u_core.u_scheduler.req_fire;
    wire refill_handoff=dut.u_backend.u_exact.u_core.u_scheduler.handoff_event &&
                        dut.u_backend.u_exact.u_core.u_scheduler.launch_event;
    wire [31:0] refill_credits=int'(dut.u_backend.u_exact.u_core.u_scheduler.meta_count_q)+
                              int'(dut.u_backend.u_exact.u_core.u_scheduler.req_pending_q);
    initial begin
        if(dut.u_backend.u_exact.u_core.u_scheduler.ALLOW_REQ_HANDOFF!=REFILL_HANDOFF)
            $fatal(1,"column test handoff parameter did not reach scheduler");
    end
    always @(posedge clk) begin
        if(rst) previous_request<=0;
        else begin
            if($isunknown(refill_credits) || refill_credits>32)
                $fatal(1,"column test exceeded accepted plus offered credit");
            if(refill_credits>credit_peak) credit_peak=refill_credits;
            if(refill_handoff) real_handoffs++;
            if(refill_fire && previous_request) adjacent_requests++;
            if(!REFILL_HANDOFF && (refill_handoff || (refill_fire && previous_request)))
                $fatal(1,"disabled column handoff unexpectedly replaced a request");
            previous_request<=refill_fire;
        end
    end
    task automatic check_handoff;
        begin
            if(REFILL_HANDOFF && (real_handoffs==0 || adjacent_requests==0))
                $fatal(1,"enabled column test did not exercise real handoff");
            $display("C1_COLUMN_AXI_HANDOFF_PASS enabled=%0d handoffs=%0d adjacent=%0d credit_peak=%0d reserved_credit=1",
                     REFILL_HANDOFF,real_handoffs,adjacent_requests,credit_peak);
        end
    endtask
    integer synthetic_words=0,drain_words=0,column_stalls=0;
    logic pending=0,expected_error=0,pending_error=0;
    logic [191:0] expected_data;
    logic [31:0] captured_base=BASE;
    integer cfg_w=W,cfg_h=H,cfg_g=G;
    function automatic integer clamp_int(input integer x,size);
        if(x<0) clamp_int=0;
        else if(x>=size) clamp_int=size-1;
        else clamp_int=x;
    endfunction
    function automatic [191:0] expected_column(input integer x,y,g);
        for(integer r=0;r<3;r++)
            expected_column[r*64 +:64]=memory_word(captured_base+
                (clamp_int(y+r-1,cfg_h)*cfg_w*cfg_g+clamp_int(x,cfg_w)*cfg_g+g)*8,model_epoch);
    endfunction
    logic held_ar=0,held_rsp=0;
    logic [44:0] ar_payload;
    logic [192:0] rsp_payload;
    always @(posedge clk) begin
        if(!rst) begin
            if((dut.u_backend.abort_pending_q || dut.u_backend.flush_pending_q) && dut.child_req_ready)
                $fatal(1,"column acceptance reopened before outer maintenance join");
            if(held_ar && (!m_axi_arvalid ||
                {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst}!==ar_payload))
                $fatal(1,"stalled AR withdrawn/changed across maintenance");
            held_ar=m_axi_arvalid && !m_axi_arready;
            ar_payload={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
            if(held_rsp && (!column_rsp_valid || {column_rsp_error,column_rsp_data}!==rsp_payload))
                $fatal(1,"stalled column changed across maintenance");
            held_rsp=column_rsp_valid && !column_rsp_ready;
            rsp_payload={column_rsp_error,column_rsp_data};
            if(group_start_valid && group_start_ready) begin
                if(pending || qcount!=0 || active) $fatal(1,"config crossed live AXI/column ownership");
                captured_base=stage_base_addr;cfg_w=frame_width;cfg_h=frame_height;cfg_g=frame_groups;
            end
            if(column_valid && column_ready) begin
                if(pending) $fatal(1,"duplicate column acceptance");
                accepted++;pending=1;pending_error=expected_error;
                expected_data=expected_column($signed(column_x),$signed(column_y),column_group);
            end
            if(column_rsp_valid) begin
                if(!pending || column_rsp_error!==pending_error ||
                    column_rsp_data!==(pending_error ? 192'b0:expected_data))
                    $fatal(1,"AXI column mismatch error=%b/%b got=%h expected=%h",column_rsp_error,pending_error,column_rsp_data,expected_data);
                if(column_rsp_ready) begin pending=0;responses++;end
                else column_stalls++;
            end
            if(abort_done) begin
                aborts++;
                if(pending || qcount!=0 || active || config_valid || !quiescent)
                    $fatal(1,"abort done before column/AXI retirement");
            end
            if(flush_done) begin
                flushes++;
                if(pending || qcount!=0 || active || !quiescent)
                    $fatal(1,"flush done before column/AXI retirement");
            end
            if(dut.u_backend.g_column.u_cache.rd_en==3'b111) parallel3++;
            if(dut.u_backend.u_exact.u_completion.synthetic_fire) synthetic_words++;
            if(dut.u_backend.u_exact.u_core.u_scheduler.stale_rsp && dut.u_backend.u_exact.u_completion.source_fire) drain_words++;
        end
    end
    task automatic configure(input logic [31:0] base=BASE,input integer width=W, height=H, groups=G);
        begin
            @(negedge clk);stage_base_addr=base;frame_width=width;frame_height=height;
            frame_groups=groups;group_start_valid=1;
            do @(posedge clk);while(!group_start_ready);
            #1;
            if(!group_start_done || group_start_error || !config_valid)
                $fatal(1,"column AXI config failed code=%0d",group_start_error_code);
            @(negedge clk);group_start_valid=0;
            // Live upstream configuration pins cannot alter a captured stage.
            stage_base_addr=32'h00abc000;frame_width=1;frame_height=1;frame_groups=1;
        end
    endtask
    task automatic issue(input integer x,y,g,err=0);
        begin
            @(negedge clk);column_x=x;column_y=y;column_group=g;
            expected_error=(err!=0);column_valid=1;
            do @(posedge clk);while(!column_ready);
            #1;
            @(negedge clk);column_valid=0;column_x=65535;column_y=-65536;column_group=7;
        end
    endtask
    task automatic collect(input integer hold_cycles=5);
        begin
            while(!column_rsp_valid) @(negedge clk);
            group_start_valid=1;
            repeat(hold_cycles) begin @(posedge clk);#1;
                if(!column_rsp_valid || group_start_ready || column_ready)
                    $fatal(1,"AXI column response/configuration fence failed");
            end
            @(negedge clk);group_start_valid=0;column_rsp_ready=1;
            @(posedge clk);#1;
            @(negedge clk);column_rsp_ready=0;
            if(pending) $fatal(1,"column response did not retire");
        end
    endtask
    task automatic normal_column(input integer x,y,g,refills=-1);
        integer before_refills;
        begin
            before_refills=perf_refill_count;
            issue(x,y,g);collect();
            if(refills>=0 && perf_refill_count-before_refills!=refills)
                $fatal(1,"AXI column unexpected refill count got=%0d expected=%0d",perf_refill_count-before_refills,refills);
        end
    endtask
    task automatic cancel_case(input integer phase,kind);
        integer a0,f0,ar0,req0,words0,refills0,synthetic0;
        begin
            configure();
            a0=aborts;f0=flushes;ar0=ar_count;req0=perf_req_count;
            words0=perf_refill_word_count;refills0=perf_refill_count;synthetic0=synthetic_words;
            allow_ar=(phase!=1);allow_r=1;
            issue(4,3,2,phase!=3);
            case(phase)
                0:while(!dut.u_backend.cache_refill_req_valid) @(negedge clk);
                1:while(perf_req_count-req0<8) @(negedge clk);
                2:begin
                    while(beat_count==0 || !active || rbeat<2) @(negedge clk);
                    allow_r=0;
                end
                3:while(!column_rsp_valid) @(negedge clk);
            endcase
            abort_req=(kind!=2);flush_req=(kind==2);
            repeat(5) begin @(posedge clk);#1;
                if(abort_done || flush_done || group_start_ready || column_ready)
                    $fatal(1,"maintenance retired too early phase=%0d kind=%0d",phase,kind);
            end
            @(negedge clk);
            if(kind==3) flush_req=1;
            else if(kind==1) abort_req=0;
            else flush_req=0;
            @(negedge clk);
            if(kind==1) abort_req=1;
            if(kind==2) flush_req=1;
            allow_ar=1;allow_r=1;
            while(!column_rsp_valid) @(negedge clk);
            repeat(7) begin @(posedge clk);#1;
                // With a response skid, the child may finish and invalidate
                // its config while the owner still owes the upstream reply.
                // The owner must remain busy and prohibit reconfiguration.
                if(aborts!=a0 || flushes!=f0 ||
                    (OWNER ? (!busy || quiescent || dut.config_permit) : !config_valid))
                    $fatal(1,"maintenance ignored held column ownership");
            end
            collect(4);
            while((kind!=2 && aborts==a0) || (kind!=1 && flushes==f0)) @(negedge clk);
            repeat(5) begin @(posedge clk);#1;
                if(aborts-a0!=(kind!=2) || flushes-f0!=(kind!=1))
                    $fatal(1,"maintenance completion duplicated");
            end
            if(config_valid!==(kind==2) || cache_error || refill_protocol_error ||
                perf_refill_word_count-words0!=(phase==3?3:1)*ROW_WORDS ||
                perf_refill_count-refills0!=(phase==3?3:1))
                $fatal(1,"maintenance failed declared row drain/status phase=%0d words=%0d refills=%0d err=%b protocol=%b",phase,perf_refill_word_count-words0,perf_refill_count-refills0,cache_error,refill_protocol_error);
            if(phase==0 && (ar_count!=ar0 || perf_req_count!=req0 || synthetic_words-synthetic0!=ROW_WORDS))
                $fatal(1,"offered refill cancellation did not synthesize exactly the unissued row");
            @(negedge clk);abort_req=0;flush_req=0;
            @(negedge clk);model_epoch++;
            if(kind!=2) configure();
            normal_column(4,3,2,3);
            $display("C1_COLUMN_AXI_CANCEL_PASS phase=%0d kind=%0d exact_count=1 restart=1",phase,kind);
        end
    endtask
    task automatic axi_error_case(input integer response);
        integer words0,rows0;
        begin
            configure();words0=perf_refill_word_count;rows0=perf_refill_count;
            fault_resp=response;
            issue(2,3,1,1);collect(8);
            fault_resp=0;
            if(!cache_error || cache_error_code!=1 ||
                perf_refill_word_count-words0!=ROW_WORDS || perf_refill_count-rows0!=1)
                $fatal(1,"RRESP fault failed exact-count poisoned row drain");
            while(!quiescent) @(negedge clk);
            configure(BASE+32'h180);
            normal_column(2,3,1,3);
            $display("C1_COLUMN_AXI_RRESP_PASS response=%0d exact_count=1 reconfigured=1",response);
        end
    endtask
    task automatic epoch_exhaust_case;
        integer f0,ar0,req0,words0,synth0,resp0;
        begin
            configure();normal_column(4,3,2,3);
            while(!quiescent) @(negedge clk);
            for(integer n=1;n<=3;n++) begin
                f0=flushes;
                @(negedge clk);flush_req=1;
                while(flushes==f0) @(negedge clk);
                if(current_epoch!=n) $fatal(1,"small epoch advance mismatch");
                @(negedge clk);flush_req=0;
                repeat(2) @(negedge clk);
            end
            ar0=ar_count;req0=perf_req_count;words0=perf_refill_word_count;
            synth0=synthetic_words;resp0=responses;f0=flushes;
            issue(4,3,2,1);
            while(!dut.u_backend.cache_refill_req_valid) @(negedge clk);
            // Saturate EXACTLY as a cache refill becomes visible. Its held
            // declaration has the same epoch value (3), so a mere epoch-tag
            // mismatch check would wrongly execute it or strand it forever.
            flush_req=1;
            collect(9);
            while(flushes==f0) @(negedge clk);
            @(negedge clk);flush_req=0;
            repeat(2) @(negedge clk);
            if(current_epoch!=3 || !dut.u_backend.u_exact.u_core.u_scheduler.epoch_exhausted_q)
                $fatal(1,"epoch saturation guard was bypassed/wrapped");
            // Reconfiguration must not silently clear the anti-alias guard.
            // Further requests fail explicitly, rather than hanging or doing
            // stale work. A drained subsystem reset is still required to heal.
            repeat(2) begin
                configure();issue(4,3,2,1);collect(5);
                while(!quiescent) @(negedge clk);
                if(!cache_error || cache_error_code!=1)
                    $fatal(1,"epoch exhaustion failed to report cache data error");
            end
            if(ar_count!=ar0 || perf_req_count!=req0 || current_epoch!=3 ||
                perf_refill_word_count-words0!=3*ROW_WORDS ||
                synthetic_words-synth0!=3*ROW_WORDS || responses-resp0!=3)
                $fatal(1,"epoch exhaustion failed exact count/no-new-AXI guarantee");
            $display("C1_COLUMN_AXI_EPOCH_EXHAUST_PASS epoch=3 rejected_rows=3 words=99 no_new_axi=1 config_cannot_clear=1");
            // Recovery is an explicit drained-domain reset, not another
            // configuration write. Check the external memory has no debt
            // before resetting both owner and transport together.
            if(!quiescent || pending || active || qcount!=0 || column_rsp_valid)
                $fatal(1,"epoch reset attempted before full transaction drain");
            @(negedge clk);rst=1;
            repeat(3) @(negedge clk);
            rst=0;model_epoch++;
            repeat(2) @(negedge clk);
            if(current_epoch!=0 || config_valid || cache_error || refill_protocol_error)
                $fatal(1,"drained epoch reset did not clear domain state");
            ar0=ar_count;resp0=responses;
            configure();normal_column(4,3,2,3);
            while(!quiescent) @(negedge clk);
            if(ar_count<=ar0 || responses-resp0!=1 || pending || active || qcount!=0 || cache_error)
                $fatal(1,"epoch reset failed fresh AXI refill and correct column recovery");
            $display("C1_COLUMN_AXI_EPOCH_RECOVERY_PASS drained_reset=1 fresh_axi=1 golden_column=1");
        end
    endtask
    initial begin
        integer ar0;
        repeat(3) @(negedge clk);rst=0;
        if(EXHAUST_TEST) begin epoch_exhaust_case();check_handoff();$finish;end
        configure();
        allow_r=0;ar0=ar_count;
        issue(0,1,0);
        while(ar_count-ar0<2) @(negedge clk);
        repeat(4) @(negedge clk);
        allow_r=1;collect();
        if(leaf_perf_max_outstanding<2) $fatal(1,"test did not exercise multiple AXI bursts outstanding");
        normal_column(W-1,1,2,0);
        normal_column(-1,0,1,0);
        normal_column(W,2,0,1);
        normal_column(-65536,-65536,2,1);
        normal_column(65535,65535,1,1);
        for(integer phase=0;phase<4;phase++)
            for(integer kind=1;kind<=3;kind++) cancel_case(phase,kind);
        axi_error_case(2);axi_error_case(3);
        while(!quiescent) @(negedge clk);
        if(pending || responses!=accepted || qcount!=0 || active || cache_error ||
            synthetic_words==0 || drain_words==0 || parallel3==0 || ar_boundary==0 ||
            multibeat==0 || leaf_perf_packed_request_count==0 || ar_stalls==0 || r_gaps==0 ||
            (!BEAT_FIFO && r_stalls==0))
            $fatal(1,"column AXI coverage/final ownership failure synth=%0d drain=%0d parallel=%0d boundary=%0d",synthetic_words,drain_words,parallel3,ar_boundary);
        check_handoff();
        $display("C1_COLUMN_CACHE_EXACT_AXI_PASS beat_fifo=%0d skid=%0d columns=%0d refills=%0d words=%0d ar=%0d beats=%0d max_outstanding=%0d packed=%0d parallel3=%0d synthetic=%0d drain=%0d ar_stalls=%0d r_stalls=%0d r_gaps=%0d response_stalls=%0d",
            BEAT_FIFO,SKID_DEPTH,responses,perf_refill_count,perf_refill_word_count,
            ar_count,beat_count,leaf_perf_max_outstanding,leaf_perf_packed_request_count,
            parallel3,synthetic_words,drain_words,ar_stalls,r_stalls,r_gaps,column_stalls);
        $finish;
    end
    initial begin #20000000;$fatal(1,"column AXI timeout columns=%0d/%0d cache_state=%0d cmd_hold=%b pending=%b%b AXI_queue=%0d active=%b exact_q=%b exact_ready=%b exact_busy=%b exact_active=%b synth=%b proto=%b refill=%b%b epoch=%0d",
        responses,accepted,dut.u_backend.g_column.u_cache.state_q,dut.u_backend.cmd_hold_valid_q,
        dut.u_backend.abort_pending_q,dut.u_backend.flush_pending_q,qcount,active,
        dut.u_backend.exact_quiescent,dut.u_backend.exact_cmd_ready,dut.u_backend.exact_busy,dut.u_backend.exact_active,
        dut.u_backend.exact_synthetic_active,dut.u_backend.exact_protocol_error,
        dut.u_backend.cache_refill_req_valid,dut.u_backend.cache_refill_req_ready,current_epoch);end
endmodule
