`timescale 1ns/1ps
module tb_c1_r2_shared_subsystem;
    parameter integer STALLS=0,BACKGROUND=1,BANK_WORDS=16384,FRAME_RUNS=2,MAX_CYCLES=12000000;
    parameter integer MEMORY_DIV=2,COMMAND_LATENCY=20,AW_WAIT_W=0;
    parameter integer CAPTURE_CORRUPTION=0; // negative checker control only
    localparam integer BURST_BEATS=16;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,psel=0,penable=0,pwrite=0;
    reg [7:0] paddr=0;reg [31:0] pwdata=0;reg [3:0] pstrb=0;
    wire [31:0] prdata;wire pready,pslverr,irq,busy,publish_valid,fabric_error;
    reg publish_ready=0;
    wire [31:0] publish_base,publish_tag;wire [10:0] publish_width;wire [9:0] publish_height;
    wire [7:0] physical_read_outstanding,physical_write_outstanding;
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


    wire [2:0][31:0] x_araddr;
    wire [2:0][7:0] x_arlen;
    wire [2:0][2:0] x_arsize;
    wire [2:0][1:0] x_arburst;
    wire [2:0] x_arvalid;
    wire [2:0] x_arready;
    wire [2:0][127:0] x_rdata;
    wire [2:0][1:0] x_rresp;
    wire [2:0] x_rlast;
    wire [2:0] x_rvalid;
    wire [2:0] x_rready;
    wire [2:0][31:0] x_awaddr;
    wire [2:0][7:0] x_awlen;
    wire [2:0][2:0] x_awsize;
    wire [2:0][1:0] x_awburst;
    wire [2:0] x_awvalid;
    wire [2:0] x_awready;
    wire [2:0][127:0] x_wdata;
    wire [2:0][15:0] x_wstrb;
    wire [2:0] x_wlast;
    wire [2:0] x_wvalid;
    wire [2:0] x_wready;
    wire [2:0][1:0] x_bresp;
    wire [2:0] x_bvalid;
    wire [2:0] x_bready;
    reg [2:0] bg_start=0,bg_stop=0;
    wire [2:0] bg_active,bg_finished,bg_error,bg_read_check;
    reg [2:0][31:0] bg_base,bg_words,bg_period;
    reg [2:0][1:0] bg_mode;
    reg [2:0] bg_repeat;
    wire [2:0][31:0] bg_write_address,bg_read_address;
    wire [2:0][127:0] bg_write_value,bg_read_value;
    wire signed [31:0] bg_bursts[0:2],bg_reads[0:2],bg_writes[0:2],bg_late[0:2];
    wire capture_busy=bg_active[0],display_busy=bg_active[1];
    wire [31:0] capture_base=bg_base[0],display_base=bg_base[1];
    c1_r2_shared_subsystem dut(.*);
    c1_r2_axi_memory_bfm #(.STALLS(STALLS),.MEMORY_DIV(MEMORY_DIV),.LATENCY(COMMAND_LATENCY),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    for(genvar g=0;g<3;g=g+1) begin : g_traffic
        c1_r2_axi_traffic_agent agent(
            .clk(clk),.rst(rst),.start(bg_start[g]),.stop(bg_stop[g]),.cfg_base(bg_base[g]),.cfg_words(bg_words[g]),
            .cfg_period(bg_period[g]),.cfg_mode(bg_mode[g]),.cfg_repeat(bg_repeat[g]),
            .active(bg_active[g]),.finished(bg_finished[g]),.error(bg_error[g]),
            .write_address(bg_write_address[g]),.write_value(bg_write_value[g]),.read_check(bg_read_check[g]),
            .read_address(bg_read_address[g]),.read_value(bg_read_value[g]),
            .bursts(bg_bursts[g]),.read_beats(bg_reads[g]),.write_beats(bg_writes[g]),.max_late(bg_late[g]),
            .araddr(x_araddr[g]),.arlen(x_arlen[g]),.arsize(x_arsize[g]),.arburst(x_arburst[g]),.arvalid(x_arvalid[g]),.arready(x_arready[g]),.rdata(x_rdata[g]),.rresp(x_rresp[g]),.rlast(x_rlast[g]),.rvalid(x_rvalid[g]),.rready(x_rready[g]),.awaddr(x_awaddr[g]),.awlen(x_awlen[g]),.awsize(x_awsize[g]),.awburst(x_awburst[g]),.awvalid(x_awvalid[g]),.awready(x_awready[g]),.wdata(x_wdata[g]),.wstrb(x_wstrb[g]),.wlast(x_wlast[g]),.wvalid(x_wvalid[g]),.wready(x_wready[g]),.bresp(x_bresp[g]),.bvalid(x_bvalid[g]),.bready(x_bready[g])
        );
    end
    reg [127:0] memory[0:9*BANK_WORDS-1];integer owner[0:9*BANK_WORDS-1];
    reg [159:0] parameter_words[0:4095];reg [127:0] input0[0:BANK_WORDS-1],input1[0:BANK_WORDS-1];
    reg [164:0] expected[0:8*BANK_WORDS-1];
    string directory,parameter_path,input0_path,input1_path,expected_path;
    integer width,height,np,ni,ne,cycle=0,frame_id=0,expected_index=0,commits=0;
    integer normal_frames=0,faults=0,apb_checks=0,producers=0,core_reads=0,core_writes=0,compute_writes=0;
    integer fault_mode=0,final_hold=0;
    integer client_r_debt[0:3],client_w_debt[0:3],client_ar[0:3],client_aw[0:3],client_b[0:3];
    integer read_owner_pending[0:63],write_owner_pending[0:63],read_owner_physical[0:63],write_owner_physical[0:63];
    reg [39:0] read_desc[0:63],write_desc[0:63];
    integer ra_tail=0,ra_issue=0,wa_tail=0,wa_issue=0;
    integer peak_r=0,peak_w=0,concurrent_cycles=0,background_r=0,background_w=0;
    wire [4:0] active_stage=dut.active_stage;
    function integer index_of(input [31:0] addr);
        begin
            if(addr[3:0]!=0 || addr[31:23]>8 || addr[22:4]>=BANK_WORDS) $fatal(1,"TB memory address %h",addr);
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

    function automatic [127:0] pattern(input [31:0] addr);
        pattern={addr^32'ha5830123,addr+32'h33445566,~addr,addr^32'hff00aa55};
    endfunction
    function automatic [31:0] expected_address(input [31:0] a);
        expected_address=frame_id==1 && a[31:23]==4 ? {9'd7,a[22:0]} : a;
    endfunction
    assign service_read_data=service_read ? memory[index_of(service_read_address)] : 128'd0;
    assign bg_write_value[0]=frame_id==0 ? input1[bg_write_address[0][22:4]] : input0[bg_write_address[0][22:4]];
    assign bg_write_value[1]=0;assign bg_write_value[2]=pattern(bg_write_address[2]);
    always @* begin
        inject_r=0;inject_b=0;hold_b=0;
        if(fault_mode==1 && service_read_address[31:23]==5) inject_r=1;
        if(fault_mode==2 && active_stage==20 && expected_index==(frame_id+1)*ne/2 && write_owner_physical[mem.bhead]==0) inject_b=1;
        if(fault_mode==5 && service_read_address[31:23]==5) inject_r=4;
        if(active_stage==20 && expected_index==(frame_id+1)*ne/2 && final_hold<37) hold_b=1;
    end
    always @(posedge clk) begin : monitor
        integer ro,wo,mi,want,selected;reg [31:0] addr;reg [127:0] value;
        if(rst) begin
            cycle<=0;ra_tail<=0;ra_issue<=0;wa_tail<=0;wa_issue<=0;
            for(integer j=0;j<4;j=j+1) begin client_r_debt[j]<=0;client_w_debt[j]<=0;client_ar[j]<=0;client_aw[j]<=0;client_b[j]<=0;end
        end else begin
            cycle<=cycle+1;
            if(cycle>MAX_CYCLES) $fatal(1,"shared watchdog stage=%0d fault=%0d owned=%b protocol=%b",active_stage,fault_mode,busy,fabric_error);
            if(physical_read_outstanding!=mem.r_count || physical_write_outstanding!=mem.b_count) $fatal(1,"physical credit mismatch");
            if(dut.read_outstanding!=client_r_debt[0] || dut.write_outstanding!=client_w_debt[0]) $fatal(1,"CNN local credit mismatch");
            if(physical_read_outstanding>peak_r) peak_r<=physical_read_outstanding;
            if(physical_write_outstanding>peak_w) peak_w<=physical_write_outstanding;
            if(busy && bg_active!=0) concurrent_cycles<=concurrent_cycles+1;
            // Independent accepted-owner queues, NOT the DUT arbitration state.
            for(integer j=0;j<4;j=j+1) begin
                if(dut.s_arvalid[j] && dut.s_arready[j]) begin
                    read_owner_pending[ra_tail]=j;read_desc[ra_tail]={dut.s_araddr[j],dut.s_arlen[j]};ra_tail<=(ra_tail+1)%64;client_ar[j]<=client_ar[j]+1;
                end
                if(dut.s_awvalid[j] && dut.s_awready[j]) begin
                    write_owner_pending[wa_tail]=j;write_desc[wa_tail]={dut.s_awaddr[j],dut.s_awlen[j]};wa_tail<=(wa_tail+1)%64;client_aw[j]<=client_aw[j]+1;
                end
                case({dut.s_arvalid[j] && dut.s_arready[j],dut.s_rvalid[j] && dut.s_rready[j] && dut.s_rlast[j]})
                    2'b10:client_r_debt[j]<=client_r_debt[j]+1;2'b01:client_r_debt[j]<=client_r_debt[j]-1;default:begin end
                endcase
                case({dut.s_awvalid[j] && dut.s_awready[j],dut.s_bvalid[j] && dut.s_bready[j]})
                    2'b10:client_w_debt[j]<=client_w_debt[j]+1;2'b01:client_w_debt[j]<=client_w_debt[j]-1;default:begin end
                endcase
                if(dut.s_bvalid[j] && dut.s_bready[j]) client_b[j]<=client_b[j]+1;
            end
            if(m_axi_arvalid && m_axi_arready) begin
                if(read_desc[ra_issue]!=={m_axi_araddr,m_axi_arlen}) $fatal(1,"fabric AR descriptor not oldest accepted");
                read_owner_physical[mem.rtail]=read_owner_pending[ra_issue];ra_issue<=(ra_issue+1)%64;
            end
            if(m_axi_awvalid && m_axi_awready) begin
                if(write_desc[wa_issue]!=={m_axi_awaddr,m_axi_awlen}) $fatal(1,"fabric AW descriptor not oldest accepted");
                write_owner_physical[mem.wtail]=write_owner_pending[wa_issue];wa_issue<=(wa_issue+1)%64;
            end
            if(m_axi_rvalid) begin
                ro=read_owner_physical[mem.rhead];
                if(dut.s_rvalid!==(4'b0001<<ro)) $fatal(1,"R response routed to wrong owner");
            end
            if(m_axi_bvalid) begin
                wo=write_owner_physical[mem.bhead];
                if(dut.s_bvalid!==(4'b0001<<wo)) $fatal(1,"B response routed to wrong owner");
            end
            if(service_read) begin
                ro=read_owner_physical[mem.rhead];mi=index_of(service_read_address);
                if(ro==0) begin
                    core_reads<=core_reads+1;
                    if(service_read_address[31:23]==5) begin if(owner[mi]!=-3)$fatal(1,"parameter not initialized");end
                    else begin
                        want=source_owner(active_stage,service_read_address[31:23]);
                        if(owner[mi]!=want) $fatal(1,"shared wrong producer stage=%0d owner=%0d want=%0d",active_stage,owner[mi],want);
                        producers<=producers+1;
                    end
                end else background_r<=background_r+1;
            end
            if(service_write) begin
                wo=write_owner_physical[mem.whead];addr=service_write_address;mi=index_of(addr);
                // In the legal full-W-before-AW stress mode, no physical AW
                // owner exists yet. Use the oldest accepted client descriptor,
                // checking the held AW payload; do NOT create physical credit.
                if(mem.early_mode) begin
                    if(write_desc[wa_issue]!=={m_axi_awaddr,m_axi_awlen}) $fatal(1,"early W has no matching accepted descriptor");
                    wo=write_owner_pending[wa_issue];
                end
                if(m_axi_wstrb!==16'hffff) $fatal(1,"partial unexpected write");
                if(wo==0) begin
                    if(expected_index>=ne || {active_stage,addr,m_axi_wdata}!=={expected[expected_index][164:160],expected_address(expected[expected_index][159:128]),expected[expected_index][127:0]}) begin
                        $display("SHARED_MISMATCH stage=%0d idx=%0d addr=%h data=%h expected=%h",active_stage,expected_index,addr,m_axi_wdata,expected[expected_index]);
                        $fatal(1,"shared graph not golden");
                    end
                    owner[mi]=active_stage;expected_index<=expected_index+1;core_writes<=core_writes+1;
                    if(dut.u_cnn.u_graph.op_busy) compute_writes<=compute_writes+1;
                end else if(wo==1) begin
                    if(addr[31:23]!=(frame_id==0 ? 6 : 0) || addr[22:4]>=ni) $fatal(1,"capture corrupted active/other bank");
                    value=frame_id==0 ? input1[addr[22:4]] : input0[addr[22:4]];
                    if(m_axi_wdata!==value) $fatal(1,"capture payload mismatch");
                    owner[mi]=-2;background_w<=background_w+1;
                end else if(wo==3) begin
                    if(addr[31:23]!=8 || m_axi_wdata!==pattern(addr)) $fatal(1,"CPU payload/address mismatch");
                    owner[mi]=-4;background_w<=background_w+1;
                end else $fatal(1,"display wrote memory");
                memory[mi]=m_axi_wdata;
            end
            for(integer j=0;j<3;j=j+1) if(bg_read_check[j]) begin
                addr=bg_read_address[j];value=pattern(addr);
                if(j==1 && bg_base[1]=='h02000000) value=expected[ne/2-ni+addr[22:4]][127:0];
                if(j==1 && bg_base[1]=='h03800000 && frame_id==1) value=expected[ne-ni+addr[22:4]][127:0];
                if(bg_read_value[j]!==value) $fatal(1,"background read data/route mismatch client=%0d addr=%h got=%h expected=%h",j,addr,bg_read_value[j],value);
                if(j==2 && owner[index_of(addr)]!=-4) $fatal(1,"CPU read before actual CPU write");
            end
            if(active_stage==20 && expected_index==(frame_id+1)*ne/2 && final_hold<37) begin
                final_hold<=final_hold+1;
                if(publish_valid) $fatal(1,"published while final B held");
            end
            if(dut.stage_done) begin
                if(dut.stage_done_index!=commits || client_r_debt[0]!=0 || client_w_debt[0]!=0) $fatal(1,"premature CNN commit");
                commits<=commits+1;
                if(height==480) $display("C1_R2_SHARED_STAGE_COMMIT stage=%0d cycles=%0d words=%0d",dut.stage_done_index,dut.graph_cycles,expected_index-frame_id*ne/2);
            end
            if(publish_valid && (client_r_debt[0]!=0 || client_w_debt[0]!=0 || dut.graph_busy)) $fatal(1,"publication before CNN physical/client drain");
        end
    end
    task apb(input bit wr,input [7:0] addr,input [31:0] value,input bit err);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=value;pstrb=15;
            @(negedge clk);penable=1;#1;
            if(!pready || pslverr!==err) $fatal(1,"shared APB addr=%h err=%b expected=%b",addr,pslverr,err);
            @(negedge clk);psel=0;penable=0;apb_checks=apb_checks+1;
        end
    endtask
    task configure(input integer fid);
        begin
            apb(1,'h20,fid==0 ? 0 : 'h03000000,0);apb(1,'h24,'h00800000,0);
            apb(1,'h28,fid==0 ? 'h02000000 : 'h03800000,0);apb(1,'h2c,'h02800000,0);
            apb(1,'h30,(height<<16)|width,0);apb(1,'h34,32'hc1000000+fid,0);
        end
    endtask
    task background_start;
        begin
            @(negedge clk);bg_base[0]=frame_id==0 ? 'h03000000 : 0;
            bg_base[1]=frame_id==0 ? 'h03800000 : 'h02000000;bg_base[2]='h04000000;
            bg_words[0]=ni;bg_words[1]=ni;bg_words[2]=256;
            bg_period[0]=height==480 ? 1041 : 13;bg_period[1]=height==480 ? 260 : 17;bg_period[2]=height==480 ? 4096 : 131;
            bg_mode[0]=0;bg_mode[1]=1;bg_mode[2]=2;bg_repeat=3'b110;
            bg_stop=0;bg_start=BACKGROUND ? 7 : 0;
            @(negedge clk);bg_start=0;
        end
    endtask
    task background_stop;
        begin
            @(negedge clk);bg_stop=3'b110; // let the finite next-frame capture complete
            while(bg_active!=0 || !idle) @(negedge clk);
            if(bg_error!=0) $fatal(1,"background AXI error");
            for(integer j=0;j<4;j=j+1) if(client_r_debt[j]!=0 || client_w_debt[j]!=0 || client_aw[j]!=client_b[j]) $fatal(1,"debt after stopped clients");
        end
    endtask
    task run_frame(input integer fid,input integer fault);
        integer before_r,before_w,before_p,before_bg_r,before_bg_w,before_ar,before_aw,captured_cycles;
        begin
            @(negedge clk);frame_id=fid;fault_mode=fault;expected_index=fid*ne/2;commits=0;final_hold=0;clear_faults=1;
            @(negedge clk);clear_faults=0;
            configure(fid);apb(1,'h18,7,0);background_start();
            before_r=core_reads;before_w=core_writes;before_p=producers;before_bg_r=background_r;before_bg_w=background_w;before_ar=client_ar[0];before_aw=client_aw[0];
            apb(1,'h10,1,0);apb(1,'h10,1,1); // reject another launch while owned
            apb(1,'h20,'hffffffff,0);apb(1,'h34,0,0); // shadow writes must not affect the active frame
            if(fault==3) apb(1,'h10,2,0);
            if(fault==4) begin
                while(active_stage!=20 || expected_index!=(fid+1)*ne/2) @(negedge clk);
                apb(1,'h10,2,0);
            end
            while(!dut.u_control.result_valid) @(negedge clk);
            captured_cycles=dut.u_control.result_cycles;
            if(busy || !irq || dut.u_control.result_error!==(fault==1 || fault==2 || fault==5) ||
               dut.u_control.result_discard!==(fault==3 || fault==4) || publish_valid!==(fault==0)) $fatal(1,"wrong CPU-visible completion fault=%0d",fault);
            if(fault==0 || fault==3 || fault==4) begin
                if(commits!=22 || expected_index!=(fid+1)*ne/2 || final_hold!=37) $fatal(1,"incomplete graph/last-B fence");
            end else if(commits!=(fault==2 ? 20 : 0) || !(fault_r_seen || fault_b_seen)) $fatal(1,"fault not contained");
            if(fault==0) begin
                normal_frames=normal_frames+1;
                $display("C1_R2_SHARED_FRAME stalls=%0d background=%0d width=%0d height=%0d frame=%0d cycles=%0d read_beats=%0d write_beats=%0d producer_reads=%0d ar=%0d aw=%0d commits=%0d bg_reads=%0d bg_writes=%0d peak_read=%0d peak_write=%0d",
                   STALLS,BACKGROUND,width,height,fid,captured_cycles,core_reads-before_r,core_writes-before_w,producers-before_p,client_ar[0]-before_ar,client_aw[0]-before_aw,commits,background_r-before_bg_r,background_w-before_bg_w,peak_r,peak_w);
                if(publish_base!=(fid==0 ? 'h02000000 : 'h03800000) || publish_tag!=32'hc1000000+fid || publish_width!=width || publish_height!=height) $fatal(1,"publication metadata changed");
                repeat(9) begin @(negedge clk);if(!publish_valid || dut.u_control.result_cycles!=captured_cycles) $fatal(1,"completion not held");end
            end else begin
                faults=faults+1;$display("C1_R2_SHARED_FAULT fault=%0d commits=%0d discarded=%0d error=%0d published=0 drained=1",fault,commits,dut.u_control.result_discard,dut.u_control.result_error);
            end
            apb(1,'h10,4,0);
            if(fault==0) begin
                configure(fid);apb(1,'h10,1,1); // publication not yet consumed
                publish_ready=1;@(negedge clk);publish_ready=0;
            end
            apb(1,'h1c,7,0);
            if(fault!=5 && irq) $fatal(1,"IRQ did not clear");
            background_stop();
            if(BACKGROUND && (bg_writes[0]!=ni || bg_reads[1]==0 || bg_reads[2]==0 || bg_writes[2]==0)) $fatal(1,"missing real background traffic");
        end
    endtask
    task reset_system;
        begin
            @(negedge clk);rst=1;publish_ready=0;bg_start=0;bg_stop=0;psel=0;penable=0;
            repeat(4) @(negedge clk);rst=0;repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        if(!$value$plusargs("DIR=%s",directory) || !$value$plusargs("W=%d",width) || !$value$plusargs("H=%d",height) ||
           !$value$plusargs("P=%d",np) || !$value$plusargs("I=%d",ni) || !$value$plusargs("E=%d",ne)) $fatal(1,"missing vectors");
        parameter_path=$sformatf("%s/parameters.mem",directory);input0_path=$sformatf("%s/input0.mem",directory);
        input1_path=$sformatf("%s/input1.mem",directory);expected_path=$sformatf("%s/expected.mem",directory);
        if(np>4096 || ni>BANK_WORDS || ne>8*BANK_WORDS) $fatal(1,"vector capacity");
        $readmemh(parameter_path,parameter_words,0,np-1);$readmemh(input0_path,input0,0,ni-1);
        $readmemh(input1_path,input1,0,ni-1);$readmemh(expected_path,expected,0,ne-1);
        if((^expected[ne-1])===1'bx) $fatal(1,"vectors not loaded");
        for(integer i=0;i<9*BANK_WORDS;i=i+1) begin memory[i]=128'hdeadc0de;owner[i]=-1;end
        for(integer i=0;i<np;i=i+1) begin memory[index_of(parameter_words[i][159:128])]=parameter_words[i][127:0];owner[index_of(parameter_words[i][159:128])]=-3;end
        for(integer i=0;i<ni;i=i+1) begin memory[i]=input0[i];owner[i]=-2;memory[7*BANK_WORDS+i]=pattern('h03800000+i*32'd16);owner[7*BANK_WORDS+i]=-5;end
        reset_system();run_frame(0,0);
        if(FRAME_RUNS>1) begin
            if(!BACKGROUND) for(integer i=0;i<ni;i=i+1) begin memory[6*BANK_WORDS+i]=input1[i];owner[6*BANK_WORDS+i]=-2;end
            if(CAPTURE_CORRUPTION!=0) begin
                if(!BACKGROUND) $fatal(1,"negative control requires real capture");
                for(integer i=0;i<ni;i=i+1) begin
                    if(CAPTURE_CORRUPTION==1) memory[6*BANK_WORDS+i]=memory[6*BANK_WORDS+i]^128'h0000000000ffffff0000000000ffffff;
                    if(CAPTURE_CORRUPTION==2) owner[6*BANK_WORDS+i]=-99;
                end
                $display("C1_R2_SHARED_CAPTURE_CORRUPTED mode=%0d after_actual_write=1",CAPTURE_CORRUPTION);
            end
            run_frame(1,0); // input comes from real capture W writes when BACKGROUND=1
        end
        if(width==12 && height==12 && FRAME_RUNS>1) begin
            // Reuse frame0 input (captured while frame1 ran), and overwrite
            // the old display-only pattern to keep the background independent.
            for(integer fault=1;fault<=5;fault=fault+1) begin
                for(integer i=0;i<ni;i=i+1) begin memory[7*BANK_WORDS+i]=pattern('h03800000+i*32'd16);owner[7*BANK_WORDS+i]=-5;end
                run_frame(0,fault);
                if(fault==5) reset_system();
                run_frame(0,0);
            end
        end
        if(BACKGROUND && concurrent_cycles==0) $fatal(1,"no concurrent masters");
        $display("C1_R2_SHARED_PASS stalls=%0d background=%0d width=%0d height=%0d normal_frames=%0d faults=%0d apb_checks=%0d peak_read=%0d peak_write=%0d concurrent_cycles=%0d actual_capture_handoff=%0d",
                 STALLS,BACKGROUND,width,height,normal_frames,faults,apb_checks,peak_r,peak_w,concurrent_cycles,BACKGROUND && FRAME_RUNS>1);
        $finish;
    end
endmodule
