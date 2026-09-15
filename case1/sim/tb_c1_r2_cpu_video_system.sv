`timescale 1ns/1ps
module tb_c1_r2_cpu_video_system;
    parameter integer WIDTH=8,HEIGHT=8,STALLS=0,BANK_WORDS=16384,MAX_CYCLES=3000000,AW_WAIT_W=0,
                      MEMORY_DIV=2,COMMAND_LATENCY=20,NN_TARGET=(WIDTH==640 && HEIGHT==480 ? 3 : 2),NEGATIVE_CONTROL=0;
    localparam NATIVE=WIDTH==640 && HEIGHT==480;
    localparam [31:0] ARENA=32'h08000000;
    // A finite safety bound, not a reduced camera rate. Long CNN tests must
    // not exhaust the camera source merely because more jobs were requested.
    localparam CAMERA_FRAMES=16*NN_TARGET;
    localparam CAMERA_PERIOD=NATIVE ? 5000000 : WIDTH*HEIGHT*25+4000;
    localparam HTOTAL=NATIVE ? 1650 : 2*WIDTH+8,VTOTAL=NATIVE ? 750 : HEIGHT+6,ROI_TOP=NATIVE ? 120 : 3;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,platform_ready=0,psel=0,penable=0,pwrite=0;
    reg [7:0] paddr=0;reg [31:0] pwdata=0;reg [3:0] pstrb=15;
    wire [31:0] prdata;wire pready,pslverr,irq;
    reg capture_request=0;reg [31:0] capture_tag=0;wire capture_request_ready;
    reg s_valid=0,s_sof=0,s_eol=0,s_eof=0;reg [23:0] s_rgb=0;
    reg display_request=0,p_req=0,p_sof=0,p_eol=0,p_eof=0;
    wire display_request_ready,m_valid,m_sof,m_eol,m_eof;wire [23:0] m_rgb;
    wire front_valid,display_frame_armed;wire [31:0] display_pair_tag;
    wire nn_complete,nn_failed;wire [31:0] nn_result_tag,nn_result_cycles;
    wire fabric_error;wire [7:0] physical_read_outstanding,physical_write_outstanding;
    wire [31:0] cpu_araddr;
    wire [7:0] cpu_arlen;
    wire [2:0] cpu_arsize;
    wire [1:0] cpu_arburst;
    wire cpu_arvalid;
    wire cpu_arready;
    wire [127:0] cpu_rdata;
    wire [1:0] cpu_rresp;
    wire cpu_rlast;
    wire cpu_rvalid;
    wire cpu_rready;
    wire [31:0] cpu_awaddr;
    wire [7:0] cpu_awlen;
    wire [2:0] cpu_awsize;
    wire [1:0] cpu_awburst;
    wire cpu_awvalid;
    wire cpu_awready;
    wire [127:0] cpu_wdata;
    wire [15:0] cpu_wstrb;
    wire cpu_wlast;
    wire cpu_wvalid;
    wire cpu_wready;
    wire [1:0] cpu_bresp;
    wire cpu_bvalid;
    wire cpu_bready;
    wire [3:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache,m_axi_arqos;
    wire [2:0] m_axi_arprot;
    wire m_axi_arvalid;
    wire m_axi_arready;
    wire [3:0] m_axi_rid;
    wire [127:0] m_axi_rdata;
    wire [1:0] m_axi_rresp;
    wire m_axi_rlast,m_axi_rvalid;
    wire m_axi_rready;
    wire [3:0] m_axi_awid;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awlock;
    wire [3:0] m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_awprot;
    wire m_axi_awvalid;
    wire m_axi_awready;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    wire m_axi_wlast,m_axi_wvalid;
    wire m_axi_wready;
    wire [3:0] m_axi_bid;
    wire [1:0] m_axi_bresp;
    wire m_axi_bvalid;
    wire m_axi_bready;
    // C13 real adapter in front of the unchanged C12 CPU fabric client.
    wire [31:0] host_cpu_araddr,host_cpu_awaddr;
    wire [7:0] host_cpu_arlen,host_cpu_awlen;
    wire [2:0] host_cpu_arsize,host_cpu_awsize;
    wire [1:0] host_cpu_arburst,host_cpu_awburst,host_cpu_rresp,host_cpu_bresp;
    wire [127:0] host_cpu_wdata,host_cpu_rdata;
    wire [15:0] host_cpu_wstrb;
    wire  host_cpu_arvalid,host_cpu_arready,host_cpu_awvalid,host_cpu_awready,host_cpu_rvalid,host_cpu_rready,host_cpu_rlast,host_cpu_wvalid,host_cpu_wready,host_cpu_wlast,host_cpu_bvalid,host_cpu_bready;
    reg [7:0] host_cpu_arid=8'h81,host_cpu_awid=8'he1;
    reg [7:0] expected_cpu_rid=0,expected_cpu_bid=0;
    wire [7:0] host_cpu_rid,host_cpu_bid;
    wire cpu_adapter_busy,cpu_adapter_fault;
    integer cpu_id_reads=0,cpu_id_writes=0;
    c1_r2_cpu_axi_adapter u_cpu_adapter (
        .clk(clk),.rst(rst),.s_arid(host_cpu_arid),.s_awid(host_cpu_awid),
        .s_arlock(1'b0),.s_awlock(1'b0),.s_arregion(4'd0),.s_awregion(4'd0),
        .s_rid(host_cpu_rid),.s_bid(host_cpu_bid),.busy(cpu_adapter_busy),.protocol_error(cpu_adapter_fault),
        .s_araddr(host_cpu_araddr),.m_araddr(cpu_araddr),
        .s_awaddr(host_cpu_awaddr),.m_awaddr(cpu_awaddr),
        .s_arlen(host_cpu_arlen),.m_arlen(cpu_arlen),
        .s_awlen(host_cpu_awlen),.m_awlen(cpu_awlen),
        .s_arsize(host_cpu_arsize),.m_arsize(cpu_arsize),
        .s_awsize(host_cpu_awsize),.m_awsize(cpu_awsize),
        .s_arburst(host_cpu_arburst),.m_arburst(cpu_arburst),
        .s_awburst(host_cpu_awburst),.m_awburst(cpu_awburst),
        .s_rresp(host_cpu_rresp),.m_rresp(cpu_rresp),
        .s_bresp(host_cpu_bresp),.m_bresp(cpu_bresp),
        .s_wdata(host_cpu_wdata),.m_wdata(cpu_wdata),
        .s_rdata(host_cpu_rdata),.m_rdata(cpu_rdata),
        .s_wstrb(host_cpu_wstrb),.m_wstrb(cpu_wstrb),
        .s_arvalid(host_cpu_arvalid),.m_arvalid(cpu_arvalid),
        .s_arready(host_cpu_arready),.m_arready(cpu_arready),
        .s_awvalid(host_cpu_awvalid),.m_awvalid(cpu_awvalid),
        .s_awready(host_cpu_awready),.m_awready(cpu_awready),
        .s_rvalid(host_cpu_rvalid),.m_rvalid(cpu_rvalid),
        .s_rready(host_cpu_rready),.m_rready(cpu_rready),
        .s_rlast(host_cpu_rlast),.m_rlast(cpu_rlast),
        .s_wvalid(host_cpu_wvalid),.m_wvalid(cpu_wvalid),
        .s_wready(host_cpu_wready),.m_wready(cpu_wready),
        .s_wlast(host_cpu_wlast),.m_wlast(cpu_wlast),
        .s_bvalid(host_cpu_bvalid),.m_bvalid(cpu_bvalid),
        .s_bready(host_cpu_bready),.m_bready(cpu_bready)
    );
    always @(posedge clk)begin
        if(rst)begin host_cpu_arid<=8'h81;host_cpu_awid<=8'he1;expected_cpu_rid<=0;expected_cpu_bid<=0;cpu_id_reads<=0;cpu_id_writes<=0;end
        else begin
            if(host_cpu_arvalid&&host_cpu_arready)begin expected_cpu_rid<=host_cpu_arid;host_cpu_arid<=host_cpu_arid+8'd13;end
            if(host_cpu_awvalid&&host_cpu_awready)begin expected_cpu_bid<=host_cpu_awid;host_cpu_awid<=host_cpu_awid+8'd17;end
            if(host_cpu_rvalid&&host_cpu_rid!==expected_cpu_rid)$fatal(1,"CPU full RID lost in shared system");
            if(host_cpu_bvalid&&host_cpu_bid!==expected_cpu_bid)$fatal(1,"CPU full BID lost in shared system");
            if(host_cpu_rvalid&&host_cpu_rready&&host_cpu_rlast)cpu_id_reads<=cpu_id_reads+1;
            if(host_cpu_bvalid&&host_cpu_bready)cpu_id_writes<=cpu_id_writes+1;
            if(cpu_adapter_fault)$fatal(1,"CPU adapter fault during CNN/video load");
        end
    end

    c1_r2_video_rgbx_system #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) dut(.*);
    reg clear_faults=0,hold_b=0;reg [2:0] inject_r=0;reg [1:0] inject_b=0;
    wire fault_r_seen,fault_b_seen,service_read,service_write,idle;
    wire [31:0] service_read_address,service_write_address;wire [127:0] service_read_data;
    integer ar_total,aw_total,r_total,w_total,b_total,peak_read,peak_write;
    c1_r2_axi_memory_bfm #(.STALLS(STALLS),.MEMORY_DIV(MEMORY_DIV),.LATENCY(COMMAND_LATENCY),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    reg cpu_start=0,cpu_stop=0;wire cpu_active,cpu_finished,cpu_error,cpu_check;
    wire [31:0] cpu_write_address,cpu_read_address;wire [127:0] cpu_write_value,cpu_read_value;
    integer cpu_bursts,cpu_reads,cpu_writes,cpu_late;
    c1_r2_axi_traffic_agent cpu (
        .clk(clk),.rst(rst),.start(cpu_start),.stop(cpu_stop),.cfg_base(ARENA+32'h04800000),.cfg_words(32'd256),
        .cfg_period(NATIVE ? 32'd4096 : 32'd131),.cfg_mode(2'd2),.cfg_repeat(1'b1),
        .active(cpu_active),.finished(cpu_finished),.error(cpu_error),.write_address(cpu_write_address),.write_value(cpu_write_value),
        .read_check(cpu_check),.read_address(cpu_read_address),.read_value(cpu_read_value),
        .bursts(cpu_bursts),.read_beats(cpu_reads),.write_beats(cpu_writes),.max_late(cpu_late),
        .araddr(host_cpu_araddr),
        .arlen(host_cpu_arlen),
        .arsize(host_cpu_arsize),
        .arburst(host_cpu_arburst),
        .arvalid(host_cpu_arvalid),
        .arready(host_cpu_arready),
        .rdata(host_cpu_rdata),
        .rresp(host_cpu_rresp),
        .rlast(host_cpu_rlast),
        .rvalid(host_cpu_rvalid),
        .rready(host_cpu_rready),
        .awaddr(host_cpu_awaddr),
        .awlen(host_cpu_awlen),
        .awsize(host_cpu_awsize),
        .awburst(host_cpu_awburst),
        .awvalid(host_cpu_awvalid),
        .awready(host_cpu_awready),
        .wdata(host_cpu_wdata),
        .wstrb(host_cpu_wstrb),
        .wlast(host_cpu_wlast),
        .wvalid(host_cpu_wvalid),
        .wready(host_cpu_wready),
        .bresp(host_cpu_bresp),
        .bvalid(host_cpu_bvalid),
        .bready(host_cpu_bready)
    );
    reg [127:0] memory[0:12*BANK_WORDS-1];integer owner_stage[0:12*BANK_WORDS-1],owner_tag[0:12*BANK_WORDS-1];
    reg [159:0] parameter_words[0:4095];reg [127:0] input0[0:BANK_WORDS-1],input1[0:BANK_WORDS-1];
    reg [164:0] expected[0:8*BANK_WORDS-1];
    integer np,ni,ne,cycle=0,cnn_starts=0,cnn_finishes=0,commits=0,expected_index=0,cnn_writes=0,cnn_reads=0,producer_reads=0;
    integer job_begin_w=0,job_begin_r=0,job_begin_p=0,last_completed_tag=-1,cap_frames=0,cap_writes[0:CAMERA_FRAMES-1];
    integer display_pixels=0,good_pixels=0,display_frames=0,display_misses=0,apb_checks=0,concurrent_cycles=0;
    integer cap_start_cycle[0:CAMERA_FRAMES-1],nn_end_cycle[0:NN_TARGET-1];
    bit video_run=0,camera_run=0,camera_stop=0,camera_finished=0,show_valid=0;
    integer hpos=0,vpos=0,phase=0,request_x=0,request_y=0,show_tag=0;
    bit shown[0:CAMERA_FRAMES-1];
    integer client_r_debt[0:3],client_w_debt[0:3],client_aw[0:3],client_b[0:3];
    integer read_owner_pending[0:63],write_owner_pending[0:63],read_owner_physical[0:63],write_owner_physical[0:63];
    reg [39:0] read_desc[0:63],write_desc[0:63];integer ra_tail=0,ra_issue=0,wa_tail=0,wa_issue=0;
    string directory,path;
    function integer index_of(input [31:0] a);
        reg [31:0] off;
        begin off=a-ARENA;if(a<ARENA||a[3:0]!=0||off[31:23]>=12||off[22:4]>=BANK_WORDS)$fatal(1,"system memory range %h",a);index_of=off[31:23]*BANK_WORDS+off[22:4];end
    endfunction
    function integer source_owner(input integer stage,input integer slot);
        case(stage)
            0:source_owner=-2;1:source_owner=0;2:source_owner=1;3:source_owner=2;4:source_owner=3;
            5:source_owner=slot==2 ? 1 : 4;6:source_owner=5;7:source_owner=6;8:source_owner=7;
            9:source_owner=slot==3 ? 5 : 8;10:source_owner=9;11:source_owner=10;12:source_owner=11;
            13:source_owner=slot==2 ? 9 : 12;15:source_owner=13;16:source_owner=15;18:source_owner=16;19:source_owner=18;20:source_owner=19;
            default:source_owner=-99;
        endcase
    endfunction
    function automatic [127:0] pattern(input [31:0] a);pattern={a^32'habcdef01,a+32'h11223344,~a,a^32'h55aa5566};endfunction
    function automatic [23:0] rgb_lane(input [127:0] word_value,input bit odd);
        reg [63:0] value;begin value=odd ? word_value[127:64] : word_value[63:0];rgb_lane={value[7:0],value[15:8],value[23:16]};end
    endfunction
    function automatic [31:0] expect_address(input [31:0] a);
        expect_address=a[31:23]==4 ? dut.output_base+(a[22:0]>>1) : ARENA+a;
    endfunction
    function automatic [127:0] pack_rgbx(input [127:0] a,input [127:0] b);
        pack_rgbx={8'd0,b[87:64],8'd0,b[23:0],8'd0,a[87:64],8'd0,a[23:0]};
    endfunction
    assign service_read_data=service_read ? memory[index_of(service_read_address)] : 0;
    assign cpu_write_value=pattern(cpu_write_address);
    always @(posedge clk)begin : monitor
        integer ro,wo,mi,want,slot,ei,tag;reg [31:0] addr,off;reg [127:0] value;
        if(rst)begin
            cycle<=0;ra_tail<=0;ra_issue<=0;wa_tail<=0;wa_issue<=0;
            for(integer j=0;j<4;j=j+1)begin client_r_debt[j]<=0;client_w_debt[j]<=0;client_aw[j]<=0;client_b[j]<=0;end
        end else begin
            cycle<=cycle+1;
            if((^{dut.cap_cmd_valid,dut.graph_start_valid,dut.disp_cmd_valid,capture_request_ready,display_request_ready})===1'bx)$fatal(1,"unknown video handshake after reset");
            if(cycle>MAX_CYCLES)$fatal(1,"video system watchdog starts=%0d done=%0d cam=%0d",cnn_starts,cnn_finishes,cap_frames);
            if(NATIVE&&cycle%1000000==0)$display("C1_R2_CPU_VIDEO_SYSTEM_PROGRESS cycle=%0d cnn_done=%0d captures=%0d displays=%0d scan_level=%0d",cycle,cnn_finishes,cap_frames,display_frames,dut.u_scanout.level);
            if(fabric_error||dut.lease_error||dut.overflow_event||dut.underflow_event||cpu_error)$fatal(1,"video system error fabric=%b lease=%b overflow=%b underflow=%b",fabric_error,dut.lease_error,dut.overflow_event,dut.underflow_event);
            if(physical_read_outstanding!=mem.r_count||physical_write_outstanding!=mem.b_count)$fatal(1,"system physical credit mismatch");
            if(dut.read_outstanding!=client_r_debt[0]||dut.write_outstanding!=client_w_debt[0])$fatal(1,"CNN local debt mismatch");
            if(dut.graph_busy&&(dut.cap_active||dut.display_active))concurrent_cycles<=concurrent_cycles+1;
            if(capture_request)$display("C1_R2_CPU_VIDEO_SYSTEM_REQUEST cycle=%0d tag=%0d ready=%b enabled=%b lease_owned=%b pending=%b cmd=%b/%b base=%h legal=%b",cycle,capture_tag,capture_request_ready,dut.run_enable,dut.u_leases.cap_owned,dut.u_leases.cap_pending,dut.cap_cmd_valid,dut.cap_cmd_ready,dut.cap_base,dut.u_capture.legal);
            if(dut.cap_cmd_valid&&dut.cap_cmd_ready)$display("C1_R2_CPU_VIDEO_SYSTEM_ARM tag=%0d base=%h cycle=%0d",dut.cap_tag,dut.cap_base,cycle);
            // Direct four-bit cases: this installed simulator returned 5
            // for $countones(4'b0000 & 4'b0000) in the expression above.
            // Enumerating the exact legal set also rejects X handshakes.
            case(dut.s_arvalid&dut.s_arready)4'b0000,4'b0001,4'b0010,4'b0100,4'b1000:begin end default:$fatal(1,"multiple/unknown AR owners");endcase
            case(dut.s_awvalid&dut.s_awready)4'b0000,4'b0001,4'b0010,4'b0100,4'b1000:begin end default:$fatal(1,"multiple/unknown AW owners");endcase
            for(integer j=0;j<4;j=j+1)begin
                if(dut.s_arvalid[j]&&dut.s_arready[j])begin read_owner_pending[ra_tail]=j;read_desc[ra_tail]={dut.s_araddr[j],dut.s_arlen[j]};ra_tail<=(ra_tail+1)%64;end
                if(dut.s_awvalid[j]&&dut.s_awready[j])begin write_owner_pending[wa_tail]=j;write_desc[wa_tail]={dut.s_awaddr[j],dut.s_awlen[j]};wa_tail<=(wa_tail+1)%64;client_aw[j]<=client_aw[j]+1;end
                case({dut.s_arvalid[j]&&dut.s_arready[j],dut.s_rvalid[j]&&dut.s_rready[j]&&dut.s_rlast[j]})
                    2'b10:client_r_debt[j]<=client_r_debt[j]+1;2'b01:client_r_debt[j]<=client_r_debt[j]-1;default:begin end
                endcase
                case({dut.s_awvalid[j]&&dut.s_awready[j],dut.s_bvalid[j]&&dut.s_bready[j]})
                    2'b10:client_w_debt[j]<=client_w_debt[j]+1;2'b01:client_w_debt[j]<=client_w_debt[j]-1;default:begin end
                endcase
                if(dut.s_bvalid[j]&&dut.s_bready[j])client_b[j]<=client_b[j]+1;
            end
            if(m_axi_arvalid&&m_axi_arready)begin
                if(read_desc[ra_issue]!=={m_axi_araddr,m_axi_arlen})$fatal(1,"wrong physical AR owner/address");
                read_owner_physical[mem.rtail]=read_owner_pending[ra_issue];ra_issue<=(ra_issue+1)%64;
            end
            if(m_axi_awvalid&&m_axi_awready)begin
                if(write_desc[wa_issue]!=={m_axi_awaddr,m_axi_awlen})$fatal(1,"wrong physical AW owner/address");
                write_owner_physical[mem.wtail]=write_owner_pending[wa_issue];wa_issue<=(wa_issue+1)%64;
            end
            if(m_axi_rvalid&&dut.s_rvalid!==(4'b1<<read_owner_physical[mem.rhead]))$fatal(1,"R routing mismatch");
            if(m_axi_bvalid&&dut.s_bvalid!==(4'b1<<write_owner_physical[mem.bhead]))$fatal(1,"B routing mismatch");
            if(dut.graph_start_valid&&dut.graph_start_ready)begin
                if(cnn_starts>=NN_TARGET)$fatal(1,"extra CNN start after pause");
                cnn_starts=cnn_starts+1;commits=0;expected_index=(nn_result_tag==0 ? 0 : ne/2);
                job_begin_w=cnn_writes;job_begin_r=cnn_reads;job_begin_p=producer_reads;
                if((cnn_starts==1)!=(nn_result_tag==0))$fatal(1,"two different input sets not exercised");
                $display("C1_R2_CPU_VIDEO_SYSTEM_NN_START job=%0d tag=%0d cycle=%0d input=%h output=%h",cnn_starts,nn_result_tag,cycle,dut.input_base,dut.output_base);
            end
            if(service_read)begin
                ro=read_owner_physical[mem.rhead];mi=index_of(service_read_address);off=service_read_address-ARENA;slot=off[31:23];
                if(ro==0)begin
                    cnn_reads=cnn_reads+1;
                    if(slot==5)begin if(owner_stage[mi]!=-3)$fatal(1,"uninitialized parameter");end
                    else begin
                        want=source_owner(dut.active_stage,slot);
                        if(owner_stage[mi]!=want||owner_tag[mi]!=nn_result_tag)$fatal(1,"CNN producer/tag mismatch stage=%0d owner=%0d tag=%0d want=%0d",dut.active_stage,owner_stage[mi],owner_tag[mi],nn_result_tag);
                        producer_reads=producer_reads+1;
                    end
                end else if(ro==2)begin
                    want=service_read_address[31:23]==dut.disp_raw[31:23] ? -2 : 20;
                    if(owner_stage[mi]!=want||owner_tag[mi]!=dut.disp_tag)$fatal(1,"display pair not actually produced");
                end else if(ro!=3)$fatal(1,"capture issued read");
            end
            if(service_write)begin
                wo=write_owner_physical[mem.whead];addr=service_write_address;off=addr-ARENA;mi=index_of(addr);
                if(mem.early_mode)begin
                    if(write_desc[wa_issue]!=={m_axi_awaddr,m_axi_awlen})$fatal(1,"early W has no accepted owner");
                    wo=write_owner_pending[wa_issue];
                end
                if(m_axi_wstrb!==16'hffff)$fatal(1,"partial video write");
                if(wo==0)begin
                    value=dut.active_stage==20 ? pack_rgbx(expected[expected_index][127:0],expected[expected_index+1][127:0]) : expected[expected_index][127:0];
                    if(expected_index>=ne||{dut.active_stage,addr,m_axi_wdata}!=={expected[expected_index][164:160],expect_address(expected[expected_index][159:128]),value})
                        $fatal(1,"CNN golden mismatch stage=%0d index=%0d addr=%h",dut.active_stage,expected_index,addr);
                    expected_index=expected_index+(dut.active_stage==20 ? 2 : 1);cnn_writes=cnn_writes+1;owner_stage[mi]=dut.active_stage;owner_tag[mi]=nn_result_tag;
                end else if(wo==1)begin
                    tag=dut.cap_tag;if(tag<0||tag>=CAMERA_FRAMES)$fatal(1,"capture tag out of test range");
                    value=tag==0 ? pack_rgbx(input0[off[22:4]*2],input0[off[22:4]*2+1]) : pack_rgbx(input1[off[22:4]*2],input1[off[22:4]*2+1]);
                    if(addr[31:23]!=dut.cap_base[31:23]||off[22:4]>=ni/2||m_axi_wdata!==value)$fatal(1,"actual capture payload mismatch");
                    owner_stage[mi]=-2;owner_tag[mi]=tag;cap_writes[tag]=cap_writes[tag]+1;
                end else if(wo==3)begin
                    if(off[31:23]!=9||m_axi_wdata!==pattern(addr))$fatal(1,"CPU write mismatch");
                    owner_stage[mi]=-4;owner_tag[mi]=-1;
                end else $fatal(1,"display issued write");
                memory[mi]=m_axi_wdata;
                // Checker negative controls: alter actual RAM, never the
                // expected stream. Capture corruption must propagate into
                // CNN numerics; result-tag corruption must fail pair ownership.
                if(NEGATIVE_CONTROL==1&&wo==1&&dut.cap_tag==0&&off[22:4]==0)memory[mi]=m_axi_wdata^128'h000000000000000000000000000000ff;
                if(NEGATIVE_CONTROL==2&&wo==0&&dut.active_stage==20&&off[22:4]==0)owner_tag[mi]=32'h76543210;
            end
            if(cpu_check&&(cpu_read_value!==pattern(cpu_read_address)||owner_stage[index_of(cpu_read_address)]!=-4))$fatal(1,"CPU read not actually written");
            if(dut.cap_event)begin
                if(dut.cap_bad||cap_writes[dut.cap_tag]!=ni/2||client_w_debt[1]!=0)$fatal(1,"bad/incomplete capture published");
                cap_frames=cap_frames+1;
                $display("C1_R2_CPU_VIDEO_SYSTEM_CAPTURE tag=%0d words=%0d cycle=%0d",dut.cap_tag,cap_writes[dut.cap_tag],cycle);
            end
            if(dut.stage_done)begin
                if(dut.stage_done_index!=commits||client_r_debt[0]!=0||client_w_debt[0]!=0)$fatal(1,"CNN premature layer commit");
                commits=commits+1;
                if(NATIVE)$display("C1_R2_CPU_VIDEO_SYSTEM_STAGE tag=%0d stage=%0d cycles=%0d words=%0d",nn_result_tag,dut.stage_done_index,nn_result_cycles,cnn_writes-job_begin_w);
            end
            if(nn_complete)begin
                if(nn_failed||commits!=22||cnn_writes-job_begin_w!=(ne-ni)/2)$fatal(1,"incomplete CNN frame");
                nn_end_cycle[cnn_finishes]=cycle;cnn_finishes=cnn_finishes+1;last_completed_tag=nn_result_tag;
                $display("C1_R2_CPU_VIDEO_SYSTEM_FRAME width=%0d height=%0d stalls=%0d tag=%0d cycles=%0d read_beats=%0d write_beats=%0d producers=%0d commits=%0d",WIDTH,HEIGHT,STALLS,nn_result_tag,nn_result_cycles,cnn_reads-job_begin_r,cnn_writes-job_begin_w,producer_reads-job_begin_p,commits);
            end
            if(display_request)begin
                show_valid=0;
                if(front_valid&&!display_request_ready)display_misses=display_misses+1;
            end
            if(display_frame_armed)begin show_valid=1;show_tag=display_pair_tag;end
            if(dut.display_event)begin
                if(dut.display_bad||client_r_debt[2]!=0||!shown[dut.disp_tag])$fatal(1,"display completion without full ROI/drain");
                display_frames=display_frames+1;
            end
            #1;
            if(m_valid!==p_req)$fatal(1,"video timing was stalled");
            if(p_req)begin
                value=0;
                if(show_valid)begin
                    if(request_x<WIDTH)value=show_tag==0 ? input0[request_y*(WIDTH/2)+request_x/2] : input1[request_y*(WIDTH/2)+request_x/2];
                    else begin
                        ei=(show_tag==0 ? ne/2 : ne)-ni+request_y*(WIDTH/2)+(request_x-WIDTH)/2;
                        value=expected[ei][127:0];
                    end
                    good_pixels=good_pixels+1;
                end
                if(m_rgb!==rgb_lane(value,request_x[0])||m_sof!==p_sof||m_eol!==p_eol||m_eof!==p_eof)begin
                    $display("VIDEO_SCAN_STATE owned=%b poison=%b underflow=%b x=%0d y=%0d level=%0d read_row=%0d plane=%b fifo=%h",dut.u_scanout.owned,dut.u_scanout.poison,dut.underflow_event,dut.u_scanout.x,dut.u_scanout.y,dut.u_scanout.level,dut.u_scanout.read_row,dut.u_scanout.plane,dut.u_scanout.fout_data);
                    $fatal(1,"display golden mismatch x=%0d y=%0d tag=%0d rgb=%h expected=%h word=%h markers=%b/%b",request_x,request_y,show_tag,m_rgb,rgb_lane(value,request_x[0]),value,{m_sof,m_eol,m_eof},{p_sof,p_eol,p_eof});
                end
                display_pixels=display_pixels+1;
                if(p_eof&&show_valid)shown[show_tag]=1;
            end
        end
    end
    // Native 720p60: 74.25MHz pixel events sampled in a 150MHz core domain,
    // exact 99/200 ratio, 1650x750 total. Two 640x480 images are centered
    // vertically (120 black rows above/below) in the 1280x720 active canvas.
    // Small modes use slower scaled timing to avoid extrapolating tiny-burst
    // command overhead as a native display benchmark.
    always @(negedge clk)begin
        display_request=0;p_req=0;p_sof=0;p_eol=0;p_eof=0;
        if(rst||!video_run)begin hpos=0;vpos=0;phase=0;end
        else begin
            phase=phase+(NATIVE ? 99 : 1);
            if(phase>=(NATIVE ? 200 : 16))begin
                phase=phase-(NATIVE ? 200 : 16);
                display_request=hpos==0&&vpos==0;
                if(hpos<2*WIDTH&&vpos>=ROI_TOP&&vpos<ROI_TOP+HEIGHT)begin
                    p_req=1;request_x=hpos;request_y=vpos-ROI_TOP;
                    p_sof=request_x==0&&request_y==0;p_eol=request_x==2*WIDTH-1;p_eof=p_eol&&request_y==HEIGHT-1;
                end
                if(hpos==HTOTAL-1)begin hpos=0;vpos=vpos==VTOTAL-1 ? 0 : vpos+1;end
                else hpos=hpos+1;
            end
        end
    end
    initial begin : camera_driver
        integer origin,cam_phase;reg [127:0] word_value;
        wait(camera_run);origin=cycle;cam_phase=0;
        for(integer f=0;f<CAMERA_FRAMES;f=f+1)begin : camera_frames
            while(cycle<origin+f*CAMERA_PERIOD&&!camera_stop)@(negedge clk);
            if(camera_stop)begin camera_finished=1;disable camera_driver;end
            @(negedge clk);capture_request=1;capture_tag=f;#1;
            if(!capture_request_ready)begin
                $display("VIDEO_CAPTURE_STATE tag=%0d owned=%b started=%b x=%0d y=%0d input_done=%b write_row=%0d row_active=%b level=%0d poison=%b",f,dut.u_capture.owned,dut.u_capture.started,dut.u_capture.x,dut.u_capture.y,dut.u_capture.input_done,dut.u_capture.write_row,dut.u_capture.row_active,dut.u_capture.level,dut.u_capture.poison);
                $fatal(1,"camera SOF not admitted");
            end
            cap_start_cycle[f]=cycle;
            @(negedge clk);capture_request=0;repeat(3)@(negedge clk);
            for(integer y=0;y<HEIGHT;y=y+1)for(integer x=0;x<(NATIVE ? 800 : WIDTH+8);x=x+1)begin
                do begin
                    @(negedge clk);s_valid=0;s_sof=0;s_eol=0;s_eof=0;
                    cam_phase=cam_phase+(NATIVE ? 21 : 1);
                end while(cam_phase<(NATIVE ? 125 : 7));
                cam_phase=cam_phase-(NATIVE ? 125 : 7);
                if(x<WIDTH)begin
                    word_value=f==0 ? input0[y*(WIDTH/2)+x/2] : input1[y*(WIDTH/2)+x/2];
                    s_rgb=rgb_lane(word_value,x[0]);s_valid=1;s_sof=x==0&&y==0;s_eol=x==WIDTH-1;s_eof=s_eol&&y==HEIGHT-1;
                end
            end
            @(negedge clk);s_valid=0;s_sof=0;s_eol=0;s_eof=0;
        end
        camera_finished=1;
        if(!camera_stop)$fatal(1,"camera safety bound exhausted before requested CNN jobs");
    end
    task apb(input bit wr,input [7:0] address,input [31:0] value,input bit error_expected);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=address;pwdata=value;
            @(negedge clk);penable=1;#1;
            if(!pready||pslverr!==error_expected)$fatal(1,"C11 APB error address=%h",address);
            @(negedge clk);psel=0;penable=0;apb_checks=apb_checks+1;
        end
    endtask
    initial begin
        if(NN_TARGET<2||NN_TARGET>6)$fatal(1,"NN_TARGET outside supported test range 2..6");
        if(!$value$plusargs("DIR=%s",directory)||!$value$plusargs("P=%d",np)||!$value$plusargs("I=%d",ni)||!$value$plusargs("E=%d",ne))$fatal(1,"missing video system vectors");
        if(np>4096||ni>BANK_WORDS||ne>8*BANK_WORDS)$fatal(1,"video system vector capacity");
        path=$sformatf("%s/parameters.mem",directory);$readmemh(path,parameter_words,0,np-1);
        path=$sformatf("%s/input0.mem",directory);$readmemh(path,input0,0,ni-1);
        path=$sformatf("%s/input1.mem",directory);$readmemh(path,input1,0,ni-1);
        path=$sformatf("%s/expected.mem",directory);$readmemh(path,expected,0,ne-1);
        if((^expected[ne-1])===1'bx)$fatal(1,"missing golden tail");
        for(integer i=0;i<12*BANK_WORDS;i=i+1)begin memory[i]='hdeadc0de;owner_stage[i]=-1;owner_tag[i]=-1;end
        // Only parameters are initialized. All image and feature data must
        // arrive through actual capture/CNN W channels, never expected[] RAM.
        for(integer i=0;i<np;i=i+1)begin memory[index_of(ARENA+parameter_words[i][159:128])]=parameter_words[i][127:0];owner_stage[index_of(ARENA+parameter_words[i][159:128])]=-3;end
        for(integer i=0;i<CAMERA_FRAMES;i=i+1)begin cap_writes[i]=0;shown[i]=0;cap_start_cycle[i]=-1;end
        repeat(4)@(negedge clk);rst=0;
        apb(0,'h00,0,0);if(prdata!='h52325632)$fatal(1,"wrong C11 ABI");
        apb(1,'h00,0,1);apb(1,'h08,16,1);apb(1,'h34,15,0);
        apb(1,'h08,15,0);repeat(6)@(negedge clk);
        if(capture_request_ready||display_request_ready||dut.graph_start_valid)$fatal(1,"admitted before platform ready");
        platform_ready=1;video_run=1;camera_run=1;cpu_start=1;@(negedge clk);cpu_start=0;
        while(cnn_starts<NN_TARGET)@(negedge clk);
        // Stop NEW CNN jobs while the target job is still running, retaining
        // capture at 30fps and both display readers throughout its duration.
        apb(1,'h08,11,0);
        while(cnn_finishes<NN_TARGET)@(negedge clk);
        camera_stop=1;
        while(!camera_finished)@(negedge clk);
        while(last_completed_tag<0||!shown[last_completed_tag])@(negedge clk);
        apb(1,'h08,0,0);cpu_stop=1;
        while(dut.cap_active||dut.nn_active||dut.display_active||cpu_active||!idle)@(negedge clk);
        video_run=0;repeat(8)@(negedge clk);
        if(cnn_starts!=NN_TARGET||cnn_finishes!=NN_TARGET||cap_frames<NN_TARGET||display_frames<NN_TARGET||good_pixels<2*NN_TARGET*WIDTH*HEIGHT||concurrent_cycles==0||display_misses!=0)$fatal(1,"video system coverage incomplete");
        if(dut.capture_count!=cap_frames||dut.nn_count!=NN_TARGET||dut.display_count!=display_frames||dut.underflow_count!=0||dut.last_nn_tag!=last_completed_tag)$fatal(1,"CPU counters disagree");
        for(integer i=1;i<cap_frames;i=i+1)if(cap_start_cycle[i]-cap_start_cycle[i-1]!=CAMERA_PERIOD)$fatal(1,"camera cadence drift");
        for(integer i=0;i<4;i=i+1)if(client_r_debt[i]!=0||client_w_debt[i]!=0||client_aw[i]!=client_b[i])$fatal(1,"undrained client");
        apb(0,'h10,0,0);if(prdata!=NN_TARGET)$fatal(1,"CPU completion count");
        apb(1,'h30,15,0);if(irq)$fatal(1,"IRQ failed to clear");
        if(cpu_adapter_busy||cpu_id_reads<2||cpu_id_writes<2)$fatal(1,"missing CPU ID/drain coverage");
        $display("C1_R2_CPU_VIDEO_SYSTEM_IDS reads=%0d writes=%0d restored_bits=8",cpu_id_reads,cpu_id_writes);
        $display("C1_R2_CPU_VIDEO_SYSTEM_PASS width=%0d height=%0d stalls=%0d native_timing=%0d captures=%0d cnn_frames=%0d displays=%0d good_pixels=%0d underflow=0 display_misses=%0d camera_period=%0d nn_interval=%0d cpu_r=%0d cpu_w=%0d peak_r=%0d peak_w=%0d apb_checks=%0d actual_capture_only=1 rgbx32=1 cpu_adapter=1",WIDTH,HEIGHT,STALLS,NATIVE,cap_frames,cnn_finishes,display_frames,good_pixels,display_misses,CAMERA_PERIOD,nn_end_cycle[NN_TARGET-1]-nn_end_cycle[NN_TARGET-2],cpu_reads,cpu_writes,peak_read,peak_write,apb_checks);
        $finish;
    end
endmodule
