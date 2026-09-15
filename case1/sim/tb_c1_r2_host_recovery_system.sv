`timescale 1ns/1ps
module tb_c1_r2_host_recovery_system;
    parameter integer STAGE_COUNT=22,RGB_STAGE=20,FAULT_MODE=1,FAULT_HOLD=64,FAULT_DISABLE=0,ERROR_IRQ_MASK=2,MIN_HELD_CNN_DEBT=1;
    // Recoverable AXI SLVERR on job 2: parameter R, input R, stage-0 B, final RGB B.
    // Same production C18 source closure; CPU/video remain active. No reset recovery.
    parameter integer WIDTH=8,HEIGHT=8,STALLS=0,BANK_WORDS=16384,MAX_CYCLES=3000000,AW_WAIT_W=0,
                      MEMORY_DIV=2,COMMAND_LATENCY=20,NN_TARGET=4,NEGATIVE_CONTROL=0;
    localparam NATIVE=WIDTH==640 && HEIGHT==480;
    localparam [31:0] ARENA=32'h08000000;
    // A finite safety bound, not a reduced camera rate. Long CNN tests must
    // not exhaust the camera source merely because more jobs were requested.
    localparam CAMERA_FRAMES=16*NN_TARGET;
    localparam CAMERA_PERIOD=NATIVE ? 5000000 : WIDTH*HEIGHT*25+4000;
    localparam HTOTAL=NATIVE ? 1650 : 2*WIDTH+8,VTOTAL=NATIVE ? 750 : HEIGHT+6,ROI_TOP=NATIVE ? 120 : 3;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,platform_ready=0,psel=0,penable=0,pwrite=0;
    reg [15:0] paddr=0;reg [31:0] pwdata=0;reg [3:0] pstrb=15;
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
    // C15 host shell contains the retained CPU adapter and C14 core.
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

    c1_r2_planned_host_system #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) dut (
        .clk(clk),
        .rst(rst),
        .platform_ready(platform_ready),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .irq(irq),
        .capture_request(capture_request),
        .capture_tag(capture_tag),
        .capture_request_ready(capture_request_ready),
        .s_valid(s_valid),
        .s_sof(s_sof),
        .s_eol(s_eol),
        .s_eof(s_eof),
        .s_rgb(s_rgb),
        .display_request(display_request),
        .display_request_ready(display_request_ready),
        .p_req(p_req),
        .p_sof(p_sof),
        .p_eol(p_eol),
        .p_eof(p_eof),
        .m_valid(m_valid),
        .m_sof(m_sof),
        .m_eol(m_eol),
        .m_eof(m_eof),
        .m_rgb(m_rgb),
        .front_valid(front_valid),
        .display_frame_armed(display_frame_armed),
        .display_pair_tag(display_pair_tag),
        .nn_complete(nn_complete),
        .nn_failed(nn_failed),
        .nn_result_tag(nn_result_tag),
        .nn_result_cycles(nn_result_cycles),
        .fabric_error(fabric_error),
        .physical_read_outstanding(physical_read_outstanding),
        .physical_write_outstanding(physical_write_outstanding),
        .cpu_araddr(host_cpu_araddr),
        .cpu_arlen(host_cpu_arlen),
        .cpu_arsize(host_cpu_arsize),
        .cpu_arburst(host_cpu_arburst),
        .cpu_arvalid(host_cpu_arvalid),
        .cpu_arready(host_cpu_arready),
        .cpu_rdata(host_cpu_rdata),
        .cpu_rresp(host_cpu_rresp),
        .cpu_rlast(host_cpu_rlast),
        .cpu_rvalid(host_cpu_rvalid),
        .cpu_rready(host_cpu_rready),
        .cpu_awaddr(host_cpu_awaddr),
        .cpu_awlen(host_cpu_awlen),
        .cpu_awsize(host_cpu_awsize),
        .cpu_awburst(host_cpu_awburst),
        .cpu_awvalid(host_cpu_awvalid),
        .cpu_awready(host_cpu_awready),
        .cpu_wdata(host_cpu_wdata),
        .cpu_wstrb(host_cpu_wstrb),
        .cpu_wlast(host_cpu_wlast),
        .cpu_wvalid(host_cpu_wvalid),
        .cpu_wready(host_cpu_wready),
        .cpu_bresp(host_cpu_bresp),
        .cpu_bvalid(host_cpu_bvalid),
        .cpu_bready(host_cpu_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .cpu_arid(host_cpu_arid),
        .cpu_awid(host_cpu_awid),
        .cpu_rid(host_cpu_rid),
        .cpu_bid(host_cpu_bid),
        .cpu_arlock(1'b0),
        .cpu_awlock(1'b0),
        .cpu_arregion(4'd0),
        .cpu_awregion(4'd0),
        .cpu_adapter_busy(cpu_adapter_busy),
        .cpu_adapter_fault(cpu_adapter_fault)
    );
    reg clear_faults=0,hold_b=0;
    wire [2:0] inject_r;
    wire [1:0] inject_b;
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
    reg [31:0] source_owners[0:191];
    integer np,ni,ne,cycle=0,cnn_starts=0,cnn_finishes=0,commits=0,expected_index=0,cnn_writes=0,cnn_reads=0,producer_reads=0;
    integer job_begin_w=0,job_begin_r=0,job_begin_p=0,last_completed_tag=-1,cap_frames=0,cap_writes[0:CAMERA_FRAMES-1];
    integer failed_count=0,good_cnn_count=0,post_fault_good=0,fault_tag=-1,failure_irq_checks=0;
    integer actual_r_error=0,actual_b_error=0,cpu_video_overlap=0;
    bit check_failure_irq=0;
    integer display_pixels=0,good_pixels=0,display_frames=0,display_misses=0,apb_checks=0,concurrent_cycles=0;
    integer cap_start_cycle[0:CAMERA_FRAMES-1],nn_end_cycle[0:NN_TARGET-1];
    bit video_run=0,camera_run=0,camera_stop=0,camera_finished=0,show_valid=0;
    integer hpos=0,vpos=0,phase=0,request_x=0,request_y=0,show_tag=0;
    bit shown[0:CAMERA_FRAMES-1];
    integer client_r_debt[0:3],client_w_debt[0:3],client_aw[0:3],client_b[0:3];
    integer read_owner_pending[0:63],write_owner_pending[0:63],read_owner_physical[0:63],write_owner_physical[0:63];
    reg [39:0] read_desc[0:63],write_desc[0:63];integer ra_tail=0,ra_issue=0,wa_tail=0,wa_issue=0;
    string directory,path;
    wire [31:0] fault_read_offset=service_read_address-ARENA;
    wire fault_read_selected=cnn_starts==2 && mem.r_count>0 && read_owner_physical[mem.rhead]==0 &&
        dut.u_system.active_stage==0 &&
        ((FAULT_MODE==1 && fault_read_offset[31:23]==5) ||
         (FAULT_MODE==2 && fault_read_offset[31:23]!=5));
    wire fault_write_selected=cnn_starts==2 && mem.b_count>0 && write_owner_physical[mem.bhead]==0 &&
        dut.u_system.active_stage==(FAULT_MODE==4 ? RGB_STAGE : 0);
    assign inject_r=!FAULT_DISABLE && fault_read_selected ? 3'd1 : 3'd0;
    assign inject_b=!FAULT_DISABLE && FAULT_MODE>=3 && fault_write_selected ? 2'd1 : 2'd0;
    bit hold_started=0,hold_finished=0;
    integer held_cycles=0,hold_peak_cnn_debt=0;
    always @(posedge clk)begin
        if(!rst && FAULT_MODE>=3)begin
            if(!hold_started && fault_write_selected)begin hold_b<=1;hold_started<=1;end
            else if(hold_b)begin
                held_cycles<=held_cycles+1;
                if(client_w_debt[0]>hold_peak_cnn_debt)hold_peak_cnn_debt<=client_w_debt[0];
                if(nn_complete)$fatal(1,"CNN completed with deliberately held B");
                if(held_cycles==FAULT_HOLD-1)begin hold_b<=0;hold_finished<=1;end
            end
        end
    end
    function integer index_of(input [31:0] a);
        reg [31:0] off;
        begin off=a-ARENA;if(a<ARENA||a[3:0]!=0||off[31:23]>=12||off[22:4]>=BANK_WORDS)$fatal(1,"system memory range %h",a);index_of=off[31:23]*BANK_WORDS+off[22:4];end
    endfunction
    function integer source_owner(input integer stage,input integer slot);
        begin
            if(stage<0 || stage>=STAGE_COUNT) $fatal(1,"stage outside compiled graph");
            // Camera slots rotate physically; logical input slot is zero.
            if(slot==0 || slot==6 || slot==8 || slot==10) slot=0;
            if(slot<0 || slot>5) $fatal(1,"unexpected tensor input slot");
            source_owner=$signed(source_owners[stage*6+slot]);
        end
    endfunction
    function automatic [127:0] pattern(input [31:0] a);pattern={a^32'habcdef01,a+32'h11223344,~a,a^32'h55aa5566};endfunction
    function automatic [23:0] rgb_lane(input [127:0] word_value,input bit odd);
        reg [63:0] value;begin value=odd ? word_value[127:64] : word_value[63:0];rgb_lane={value[7:0],value[15:8],value[23:16]};end
    endfunction
    function automatic [31:0] expect_address(input [31:0] a);
        expect_address=a[31:23]==4 ? dut.u_system.output_base+(a[22:0]>>1) : ARENA+a;
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
            if(m_axi_rvalid && m_axi_rready && m_axi_rresp!=0)begin
                if(m_axi_rresp!==2 || read_owner_physical[mem.rhead]!=0 || cnn_starts!=2)
                    $fatal(1,"wrong physical R error owner/type/job");
                actual_r_error=actual_r_error+1;
                $display("C1_R2_HOST_RECOVERY_ERROR_RESPONSE channel=R response=%0d owner=0 tag=%0d stage=%0d cycle=%0d",
                    m_axi_rresp,nn_result_tag,dut.u_system.active_stage,cycle);
            end
            if(m_axi_bvalid && m_axi_bready && m_axi_bresp!=0)begin
                if(m_axi_bresp!==2 || write_owner_physical[mem.bhead]!=0 || cnn_starts!=2 || hold_b)
                    $fatal(1,"wrong physical B error owner/type/job/hold");
                actual_b_error=actual_b_error+1;
                $display("C1_R2_HOST_RECOVERY_ERROR_RESPONSE channel=B response=%0d owner=0 tag=%0d stage=%0d cycle=%0d",
                    m_axi_bresp,nn_result_tag,dut.u_system.active_stage,cycle);
            end
            if(check_failure_irq)begin
                if(!irq || !dut.u_system.u_control.irq_status[1])
                    $fatal(1,"failed completion did not raise masked error IRQ");
                $display("C1_R2_HOST_RECOVERY_ERROR_IRQ tag=%0d mask=%0d status=%0d cycle=%0d",
                    fault_tag,dut.u_system.u_control.irq_enable,dut.u_system.u_control.irq_status,cycle);
                failure_irq_checks=failure_irq_checks+1;check_failure_irq=0;
            end
            if(fault_tag>=0 && front_valid &&
               dut.u_system.u_leases.tags[dut.u_system.u_leases.front_i]==fault_tag)
                $fatal(1,"failed result became retained FRONT");
            if(display_frame_armed && display_pair_tag==fault_tag)
                $fatal(1,"failed result armed for display");
            if((^{dut.u_system.cap_cmd_valid,dut.u_system.graph_start_valid,dut.u_system.disp_cmd_valid,capture_request_ready,display_request_ready})===1'bx)$fatal(1,"unknown video handshake after reset");
            if(cycle>MAX_CYCLES)$fatal(1,"video system watchdog starts=%0d done=%0d cam=%0d",cnn_starts,cnn_finishes,cap_frames);
            if(NATIVE&&cycle%1000000==0)$display("C1_R2_HOST_RECOVERY_PROGRESS cycle=%0d cnn_done=%0d captures=%0d displays=%0d scan_level=%0d",cycle,cnn_finishes,cap_frames,display_frames,dut.u_system.u_scanout.level);
            if(fabric_error||dut.u_system.lease_error||dut.u_system.overflow_event||dut.u_system.underflow_event||cpu_error)$fatal(1,"video system error fabric=%b lease=%b overflow=%b underflow=%b",fabric_error,dut.u_system.lease_error,dut.u_system.overflow_event,dut.u_system.underflow_event);
            if(physical_read_outstanding!=mem.r_count||physical_write_outstanding!=mem.b_count)$fatal(1,"system physical credit mismatch");
            if(dut.u_system.read_outstanding!=client_r_debt[0]||dut.u_system.write_outstanding!=client_w_debt[0])$fatal(1,"CNN local debt mismatch");
            if(dut.u_system.graph_busy&&(dut.u_system.cap_active||dut.u_system.display_active))concurrent_cycles<=concurrent_cycles+1;
            if(cpu_active && dut.u_system.graph_busy && (dut.u_system.cap_active||dut.u_system.display_active))
                cpu_video_overlap=cpu_video_overlap+1;
            if(capture_request)$display("C1_R2_HOST_RECOVERY_REQUEST cycle=%0d tag=%0d ready=%b enabled=%b lease_owned=%b pending=%b cmd=%b/%b base=%h legal=%b",cycle,capture_tag,capture_request_ready,dut.u_system.run_enable,dut.u_system.u_leases.cap_owned,dut.u_system.u_leases.cap_pending,dut.u_system.cap_cmd_valid,dut.u_system.cap_cmd_ready,dut.u_system.cap_base,dut.u_system.u_capture.legal);
            if(dut.u_system.cap_cmd_valid&&dut.u_system.cap_cmd_ready)$display("C1_R2_HOST_RECOVERY_ARM tag=%0d base=%h cycle=%0d",dut.u_system.cap_tag,dut.u_system.cap_base,cycle);
            // Direct four-bit cases: this installed simulator returned 5
            // for $countones(4'b0000 & 4'b0000) in the expression above.
            // Enumerating the exact legal set also rejects X handshakes.
            case(dut.u_system.s_arvalid&dut.u_system.s_arready)4'b0000,4'b0001,4'b0010,4'b0100,4'b1000:begin end default:$fatal(1,"multiple/unknown AR owners");endcase
            case(dut.u_system.s_awvalid&dut.u_system.s_awready)4'b0000,4'b0001,4'b0010,4'b0100,4'b1000:begin end default:$fatal(1,"multiple/unknown AW owners");endcase
            for(integer j=0;j<4;j=j+1)begin
                if(dut.u_system.s_arvalid[j]&&dut.u_system.s_arready[j])begin read_owner_pending[ra_tail]=j;read_desc[ra_tail]={dut.u_system.s_araddr[j],dut.u_system.s_arlen[j]};ra_tail<=(ra_tail+1)%64;end
                if(dut.u_system.s_awvalid[j]&&dut.u_system.s_awready[j])begin write_owner_pending[wa_tail]=j;write_desc[wa_tail]={dut.u_system.s_awaddr[j],dut.u_system.s_awlen[j]};wa_tail<=(wa_tail+1)%64;client_aw[j]<=client_aw[j]+1;end
                case({dut.u_system.s_arvalid[j]&&dut.u_system.s_arready[j],dut.u_system.s_rvalid[j]&&dut.u_system.s_rready[j]&&dut.u_system.s_rlast[j]})
                    2'b10:client_r_debt[j]<=client_r_debt[j]+1;2'b01:client_r_debt[j]<=client_r_debt[j]-1;default:begin end
                endcase
                case({dut.u_system.s_awvalid[j]&&dut.u_system.s_awready[j],dut.u_system.s_bvalid[j]&&dut.u_system.s_bready[j]})
                    2'b10:client_w_debt[j]<=client_w_debt[j]+1;2'b01:client_w_debt[j]<=client_w_debt[j]-1;default:begin end
                endcase
                if(dut.u_system.s_bvalid[j]&&dut.u_system.s_bready[j])client_b[j]<=client_b[j]+1;
            end
            if(m_axi_arvalid&&m_axi_arready)begin
                if(read_desc[ra_issue]!=={m_axi_araddr,m_axi_arlen})$fatal(1,"wrong physical AR owner/address");
                read_owner_physical[mem.rtail]=read_owner_pending[ra_issue];ra_issue<=(ra_issue+1)%64;
            end
            if(m_axi_awvalid&&m_axi_awready)begin
                if(write_desc[wa_issue]!=={m_axi_awaddr,m_axi_awlen})$fatal(1,"wrong physical AW owner/address");
                write_owner_physical[mem.wtail]=write_owner_pending[wa_issue];wa_issue<=(wa_issue+1)%64;
            end
            if(m_axi_rvalid&&dut.u_system.s_rvalid!==(4'b1<<read_owner_physical[mem.rhead]))$fatal(1,"R routing mismatch");
            if(m_axi_bvalid&&dut.u_system.s_bvalid!==(4'b1<<write_owner_physical[mem.bhead]))$fatal(1,"B routing mismatch");
            if(dut.u_system.graph_start_valid&&dut.u_system.graph_start_ready)begin
                if(cnn_starts>=NN_TARGET)$fatal(1,"extra CNN start after pause");
                cnn_starts=cnn_starts+1;
                if(cnn_starts==2)fault_tag=nn_result_tag;
                commits=0;expected_index=(nn_result_tag==0 ? 0 : ne/2);
                job_begin_w=cnn_writes;job_begin_r=cnn_reads;job_begin_p=producer_reads;
                if((cnn_starts==1)!=(nn_result_tag==0))$fatal(1,"two different input sets not exercised");
                $display("C1_R2_HOST_RECOVERY_NN_START job=%0d tag=%0d cycle=%0d input=%h output=%h",cnn_starts,nn_result_tag,cycle,dut.u_system.input_base,dut.u_system.output_base);
            end
            if(service_read)begin
                ro=read_owner_physical[mem.rhead];mi=index_of(service_read_address);off=service_read_address-ARENA;slot=off[31:23];
                if(ro==0)begin
                    cnn_reads=cnn_reads+1;
                    if(slot==5)begin if(owner_stage[mi]!=-3)$fatal(1,"uninitialized parameter");end
                    else begin
                        want=source_owner(dut.u_system.active_stage,slot);
                        if(owner_stage[mi]!=want||owner_tag[mi]!=nn_result_tag)$fatal(1,"CNN producer/tag mismatch stage=%0d owner=%0d tag=%0d want=%0d",dut.u_system.active_stage,owner_stage[mi],owner_tag[mi],nn_result_tag);
                        producer_reads=producer_reads+1;
                    end
                end else if(ro==2)begin
                    want=service_read_address[31:23]==dut.u_system.disp_raw[31:23] ? -2 : RGB_STAGE;
                    if(owner_stage[mi]!=want||owner_tag[mi]!=dut.u_system.disp_tag)$fatal(1,"display pair not actually produced");
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
                    value=dut.u_system.active_stage==RGB_STAGE ? pack_rgbx(expected[expected_index][127:0],expected[expected_index+1][127:0]) : expected[expected_index][127:0];
                    if(expected_index>=ne||{dut.u_system.active_stage,addr,m_axi_wdata}!=={expected[expected_index][164:160],expect_address(expected[expected_index][159:128]),value})
                        $fatal(1,"CNN golden mismatch stage=%0d index=%0d addr=%h",dut.u_system.active_stage,expected_index,addr);
                    expected_index=expected_index+(dut.u_system.active_stage==RGB_STAGE ? 2 : 1);cnn_writes=cnn_writes+1;owner_stage[mi]=dut.u_system.active_stage;owner_tag[mi]=nn_result_tag;
                end else if(wo==1)begin
                    tag=dut.u_system.cap_tag;if(tag<0||tag>=CAMERA_FRAMES)$fatal(1,"capture tag out of test range");
                    value=tag==0 ? pack_rgbx(input0[off[22:4]*2],input0[off[22:4]*2+1]) : pack_rgbx(input1[off[22:4]*2],input1[off[22:4]*2+1]);
                    if(addr[31:23]!=dut.u_system.cap_base[31:23]||off[22:4]>=ni/2||m_axi_wdata!==value)$fatal(1,"actual capture payload mismatch");
                    owner_stage[mi]=-2;owner_tag[mi]=tag;cap_writes[tag]=cap_writes[tag]+1;
                end else if(wo==3)begin
                    if(off[31:23]!=9||m_axi_wdata!==pattern(addr))$fatal(1,"CPU write mismatch");
                    owner_stage[mi]=-4;owner_tag[mi]=-1;
                end else $fatal(1,"display issued write");
                memory[mi]=m_axi_wdata;
                // Checker negative controls: alter actual RAM, never the
                // expected stream. Capture corruption must propagate into
                // CNN numerics; result-tag corruption must fail pair ownership.
                if(NEGATIVE_CONTROL==1&&wo==1&&dut.u_system.cap_tag==0&&off[22:4]==0)memory[mi]=m_axi_wdata^128'h000000000000000000000000000000ff;
                if(NEGATIVE_CONTROL==2&&wo==0&&dut.u_system.active_stage==RGB_STAGE&&off[22:4]==0)owner_tag[mi]=32'h76543210;
            end
            if(cpu_check&&(cpu_read_value!==pattern(cpu_read_address)||owner_stage[index_of(cpu_read_address)]!=-4))$fatal(1,"CPU read not actually written");
            if(dut.u_system.cap_event)begin
                if(dut.u_system.cap_bad||cap_writes[dut.u_system.cap_tag]!=ni/2||client_w_debt[1]!=0)$fatal(1,"bad/incomplete capture published");
                cap_frames=cap_frames+1;
                $display("C1_R2_HOST_RECOVERY_CAPTURE tag=%0d words=%0d cycle=%0d",dut.u_system.cap_tag,cap_writes[dut.u_system.cap_tag],cycle);
            end
            if(dut.u_system.stage_done)begin
                if(dut.u_system.u_cnn.u_graph.u_plan.valid!==1'b1) $fatal(1,"missing active generated plan");
                if(dut.u_system.stage_done_index!=commits||client_r_debt[0]!=0||client_w_debt[0]!=0)$fatal(1,"CNN premature layer commit");
                commits=commits+1;
                if(NATIVE)$display("C1_R2_HOST_RECOVERY_STAGE tag=%0d stage=%0d cycles=%0d words=%0d",nn_result_tag,dut.u_system.stage_done_index,nn_result_cycles,cnn_writes-job_begin_w);
            end
            if(nn_complete)begin
                if(cnn_starts==2 && !nn_failed)$fatal(1,"faulted frame reported success");
                if(nn_failed)begin
                    if(cnn_starts!=2 || failed_count!=0 || nn_result_tag!=fault_tag ||
                       !(FAULT_MODE<=2 ? fault_r_seen : fault_b_seen))
                        $fatal(1,"unexpected/uninjected failed completion");
                    if(client_r_debt[0]!=0 || client_w_debt[0]!=0 ||
                       dut.u_system.read_outstanding!=0 || dut.u_system.write_outstanding!=0)
                        $fatal(1,"failed completion before CNN physical drain");
                    if(commits!=(FAULT_MODE==4 ? RGB_STAGE : 0))
                        $fatal(1,"failed layer was committed");
                    if(!front_valid)$fatal(1,"missing retained good FRONT at failure");
                    failed_count=failed_count+1;check_failure_irq=1;
                    $display("C1_R2_HOST_RECOVERY_FAILED mode=%0d tag=%0d cycles=%0d commits=%0d writes=%0d cnn_read_debt=%0d cnn_write_debt=%0d fabric_error=%0d front_tag=%0d complete_cycle=%0d reset_required=0",
                        FAULT_MODE,nn_result_tag,nn_result_cycles,commits,cnn_writes-job_begin_w,
                        client_r_debt[0],client_w_debt[0],fabric_error,dut.u_system.u_leases.tags[dut.u_system.u_leases.front_i],cycle);
                end else begin
                    if(commits!=STAGE_COUNT||cnn_writes-job_begin_w!=(ne-ni)/2)$fatal(1,"incomplete CNN frame");
                    good_cnn_count=good_cnn_count+1;
                    if(failed_count)post_fault_good=post_fault_good+1;
                    last_completed_tag=nn_result_tag;
                    $display("C1_R2_HOST_RECOVERY_FRAME width=%0d height=%0d stalls=%0d tag=%0d cycles=%0d read_beats=%0d write_beats=%0d producers=%0d commits=%0d complete_cycle=%0d",WIDTH,HEIGHT,STALLS,nn_result_tag,nn_result_cycles,cnn_reads-job_begin_r,cnn_writes-job_begin_w,producer_reads-job_begin_p,commits,cycle);
                end
                nn_end_cycle[cnn_finishes]=cycle;cnn_finishes=cnn_finishes+1;
            end
            if(display_request)begin
                show_valid=0;
                if(front_valid&&!display_request_ready)display_misses=display_misses+1;
            end
            if(display_frame_armed)begin show_valid=1;show_tag=display_pair_tag;end
            if(dut.u_system.display_event)begin
                if(dut.u_system.display_bad||client_r_debt[2]!=0||!shown[dut.u_system.disp_tag])$fatal(1,"display completion without full ROI/drain");
                display_frames=display_frames+1;
                $display("C1_R2_HOST_RECOVERY_DISPLAY tag=%0d cycle=%0d",dut.u_system.disp_tag,cycle);
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
                    $display("VIDEO_SCAN_STATE owned=%b poison=%b underflow=%b x=%0d y=%0d level=%0d read_row=%0d plane=%b fifo=%h",dut.u_system.u_scanout.owned,dut.u_system.u_scanout.poison,dut.u_system.underflow_event,dut.u_system.u_scanout.x,dut.u_system.u_scanout.y,dut.u_system.u_scanout.level,dut.u_system.u_scanout.read_row,dut.u_system.u_scanout.plane,dut.u_system.u_scanout.fout_data);
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
                $display("VIDEO_CAPTURE_STATE tag=%0d owned=%b started=%b x=%0d y=%0d input_done=%b write_row=%0d row_active=%b level=%0d poison=%b",f,dut.u_system.u_capture.owned,dut.u_system.u_capture.started,dut.u_system.u_capture.x,dut.u_system.u_capture.y,dut.u_system.u_capture.input_done,dut.u_system.u_capture.write_row,dut.u_system.u_capture.row_active,dut.u_system.u_capture.level,dut.u_system.u_capture.poison);
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
    task apb(input bit wr,input [15:0] address,input [31:0] value,input bit error_expected);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=address;pwdata=value;
            @(negedge clk);penable=1;#1;
            if(!pready||pslverr!==error_expected)$fatal(1,"C11 APB error address=%h",address);
            @(negedge clk);psel=0;penable=0;apb_checks=apb_checks+1;
        end
    endtask

    integer host_apb_checks=0;
    task host_apb(input bit wr,input [15:0] address,input [31:0] value,input bit error_expected,input [31:0] expected);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=address;pwdata=value;#1;
            if(pslverr)$fatal(1,"host APB setup error");
            @(negedge clk);penable=1;#1;
            if(!pready||pslverr!==error_expected)$fatal(1,"host APB response address=%h",address);
            if(!wr&&!error_expected&&prdata!==expected)$fatal(1,"host APB data address=%h got=%h expected=%h",address,prdata,expected);
            if(address[15:8]!=0 && dut.core_psel)$fatal(1,"host high address aliased core");
            @(negedge clk);psel=0;penable=0;host_apb_checks=host_apb_checks+1;
        end
    endtask
    initial begin
        if(NATIVE || NN_TARGET!=4 || FAULT_MODE<1 || FAULT_MODE>4 || FAULT_HOLD<32 || NEGATIVE_CONTROL!=0)
            $fatal(1,"invalid bounded recovery configuration");
        if(!$value$plusargs("DIR=%s",directory)||!$value$plusargs("P=%d",np)||!$value$plusargs("I=%d",ni)||!$value$plusargs("E=%d",ne))$fatal(1,"missing video system vectors");
        if(np>4096||ni>BANK_WORDS||ne>8*BANK_WORDS)$fatal(1,"video system vector capacity");
        if(STAGE_COUNT<1 || STAGE_COUNT>32 || RGB_STAGE!=STAGE_COUNT-2) $fatal(1,"invalid compiled graph envelope");
        path=$sformatf("%s/owners.mem",directory);$readmemh(path,source_owners,0,191);
        if((^source_owners[0])===1'bx) $fatal(1,"missing graph owner metadata");
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
        host_apb(0,'h0100,0,0,'h52324831);host_apb(0,'h0104,0,0,'h10000);
        host_apb(0,'h0108,0,0,0);
        host_apb(1,'h0108,15,1,0);host_apb(1,'h0208,15,1,0);host_apb(1,'hff08,15,1,0);
        host_apb(0,'h0008,0,0,0);host_apb(0,'h010c,0,1,0);
        apb(0,'h00,0,0);if(prdata!='h52325632)$fatal(1,"wrong C11 ABI");
        apb(1,'h00,0,1);apb(1,'h08,16,1);apb(1,'h34,ERROR_IRQ_MASK,0);
        apb(1,'h08,15,0);repeat(6)@(negedge clk);
        if(capture_request_ready||display_request_ready||dut.u_system.graph_start_valid)$fatal(1,"admitted before platform ready");
        platform_ready=1;video_run=1;camera_run=1;cpu_start=1;@(negedge clk);cpu_start=0;
        // Preserve one actually displayed good frame before admitting the
        // faulted job. Camera and CPU continue during this intentional pause.
        while(cnn_starts<1)@(negedge clk);
        apb(1,'h08,11,0);
        while(cnn_finishes<1 || !shown[0])@(negedge clk);
        if(irq)$fatal(1,"successful completion leaked through error-only IRQ mask");
        apb(1,'h08,15,0);
        while(cnn_starts<NN_TARGET)@(negedge clk);
        // Stop NEW CNN jobs while the target job is still running, retaining
        // capture at 30fps and both display readers throughout its duration.
        apb(1,'h08,11,0);
        while(cnn_finishes<NN_TARGET)@(negedge clk);
        camera_stop=1;
        while(!camera_finished)@(negedge clk);
        while(last_completed_tag<0||!shown[last_completed_tag])@(negedge clk);
        apb(1,'h08,0,0);cpu_stop=1;
        while(dut.u_system.cap_active||dut.u_system.nn_active||dut.u_system.display_active||cpu_active||!idle)@(negedge clk);
        video_run=0;repeat(8)@(negedge clk);
        if(cnn_starts!=NN_TARGET||cnn_finishes!=NN_TARGET||cap_frames<NN_TARGET||display_frames<NN_TARGET||good_pixels<2*NN_TARGET*WIDTH*HEIGHT||concurrent_cycles==0||display_misses!=0)$fatal(1,"video system coverage incomplete");
        if(dut.u_system.capture_count!=cap_frames||dut.u_system.nn_count!=good_cnn_count||dut.u_system.display_count!=display_frames||dut.u_system.underflow_count!=0||dut.u_system.last_nn_tag!=last_completed_tag)$fatal(1,"CPU counters disagree");
        for(integer i=1;i<cap_frames;i=i+1)if(cap_start_cycle[i]-cap_start_cycle[i-1]!=CAMERA_PERIOD)$fatal(1,"camera cadence drift");
        for(integer i=0;i<4;i=i+1)if(client_r_debt[i]!=0||client_w_debt[i]!=0||client_aw[i]!=client_b[i])$fatal(1,"undrained client");
        if(!irq)$fatal(1,"failed CNN did not retain host IRQ");
        if(failed_count!=1 || good_cnn_count!=3 || post_fault_good!=2 || failure_irq_checks!=1 ||
           shown[fault_tag] || (FAULT_MODE<=2 ? (!fault_r_seen || fault_b_seen) : (!fault_b_seen || fault_r_seen)))
            $fatal(1,"missing actual fault/recovery/isolation evidence");
        if(FAULT_MODE>=3 && (!hold_started || !hold_finished || held_cycles!=FAULT_HOLD || hold_peak_cnn_debt<MIN_HELD_CNN_DEBT))
            $fatal(1,"missing actual held B debt");
        if(actual_r_error!=(FAULT_MODE<=2 ? 1 : 0) || actual_b_error!=(FAULT_MODE>=3 ? 1 : 0))
            $fatal(1,"missing/duplicate actual physical response error handshake");
        if(cpu_video_overlap<=0)$fatal(1,"missing CPU/CNN/video concurrent activity");
        host_apb(0,'h0108,0,0,4);
        host_apb(1,'h0130,15,1,0);if(!irq)$fatal(1,"high-page W1C cleared core IRQ");
        host_apb(1,'h0108,0,1,0);host_apb(0,'hff34,0,1,0);
        apb(0,'h10,0,0);if(prdata!=good_cnn_count)$fatal(1,"CPU counted failed frame as successful");
        apb(1,'h30,15,0);if(irq)$fatal(1,"IRQ failed to clear");
        host_apb(0,'h0108,0,0,0);
        if(host_apb_checks!=13)$fatal(1,"missing host APB probes");
        $display("C1_R2_HOST_RECOVERY_HOST apb_bits=16 checks=%0d irq_level_verified=1 high_alias_rejected=1",host_apb_checks);
        if(cpu_adapter_busy||cpu_id_reads<2||cpu_id_writes<2)$fatal(1,"missing CPU ID/drain coverage");
        $display("C1_R2_HOST_RECOVERY_IDS reads=%0d writes=%0d restored_bits=8",cpu_id_reads,cpu_id_writes);
        $display("C1_R2_HOST_RECOVERY_PASS width=%0d height=%0d stalls=%0d native_timing=%0d captures=%0d cnn_frames=%0d displays=%0d good_pixels=%0d underflow=0 display_misses=%0d camera_period=%0d nn_interval=%0d cpu_r=%0d cpu_w=%0d peak_r=%0d peak_w=%0d apb_checks=%0d actual_capture_only=1 rgbx32=1 cpu_adapter=1 fresh_leases=1 host_shell=1 planned_graph=1",WIDTH,HEIGHT,STALLS,NATIVE,cap_frames,cnn_finishes,display_frames,good_pixels,display_misses,CAMERA_PERIOD,nn_end_cycle[NN_TARGET-1]-nn_end_cycle[NN_TARGET-2],cpu_reads,cpu_writes,peak_read,peak_write,apb_checks);
        $display("C1_R2_HOST_RECOVERY_PLAN stage_count=%0d rgb_stage=%0d actual_generated_plan=1",STAGE_COUNT,RGB_STAGE);
        $display("C1_R2_HOST_RECOVERY_RESULT mode=%0d aw_wait_w=%0d attempts=%0d good_frames=%0d failed_frames=%0d post_fault_good=%0d failed_tag=%0d error_irq_checks=%0d hold_cycles=%0d hold_peak_cnn_debt=%0d r_error_handshakes=%0d b_error_handshakes=%0d cpu_video_overlap=%0d actual_response_error=1 no_reset=1 failed_front_forbidden=1 cpu_video_concurrent=1",
            FAULT_MODE,AW_WAIT_W,cnn_starts,good_cnn_count,failed_count,post_fault_good,fault_tag,
            failure_irq_checks,held_cycles,hold_peak_cnn_debt,actual_r_error,actual_b_error,cpu_video_overlap);
        $finish;
    end
endmodule
