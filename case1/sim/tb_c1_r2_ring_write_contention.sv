`timescale 1ns/1ps
// C34 circular-reservation candidate compared with retained C33: real writer -> RGBX/AXI DMA -> retained
// burst arbiter -> retained AXI BFM, competing with a second real row DMA.
// The second client is synthetic capture traffic, NOT the camera/Resize RTL.
// Slow production intentionally exposes head-of-line blocking; no FPS claim.
module tb_c1_r2_ring_write_contention;
    parameter integer FORCE_REFILL=0,BREAK_DRAIN=0,BREAK_CREDIT=0;
    parameter integer INPUT_GAP=8,START_GAP=128;
    parameter integer CANDIDATE=3,MODE=2,CHANNELS=24,WIDTH=32;
    parameter integer PACKETS=144,WORDS=48,PHYSICAL_WORDS=48;
    parameter integer AW_WAIT_W=0,INJECT_B=0,NN_ROWS=3,CAPTURE_ROWS=4;
    localparam integer RGB=MODE==1;
    localparam [31:0] NN_START=RGB ? 32'h3fe0 : 32'h1ff0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,nn_start=0,nn_valid=0,cap_start=0,cap_valid=0;
    reg [31:0] nn_address=NN_START,cap_address=32'h100000;
    reg [70:0] packet=0;
    reg [127:0] cap_data=0;
    reg cap_last=0;
    reg [70:0] packets_mem[0:16383];
    reg [127:0] expected_mem[0:4095];
    reg seen_nn[0:4095],seen_cap[0:63];
    wire nn_start_ready,nn_ready,nn_cmd_valid,nn_cmd_ready,nn_data_valid,nn_data_ready,nn_last;
    wire [31:0] nn_cmd_address;wire [15:0] nn_beats;wire [127:0] nn_data;
    wire nn_response,nn_response_ready,nn_response_error,nn_done,nn_error;
    wire cap_cmd_ready,cap_ready,cap_response,cap_response_error;
    wire nn_dma_busy,cap_dma_busy,nn_protocol,cap_protocol;
    wire [7:0] nn_outstanding,cap_outstanding;
    wire [1:0][31:0] s_awaddr;wire [1:0][7:0] s_awlen;
    wire [1:0][2:0] s_awsize;wire [1:0][1:0] s_awburst;
    wire [1:0] s_awvalid,s_awready,s_wlast,s_wvalid,s_wready,s_bvalid,s_bready;
    wire [1:0][127:0] s_wdata;wire [1:0][15:0] s_wstrb;wire [1:0][1:0] s_bresp;
    wire [31:0] m_awaddr;wire [7:0] m_awlen;wire [2:0] m_awsize;wire [1:0] m_awburst,m_bresp;
    wire m_awvalid,m_awready,m_wlast,m_wvalid,m_wready,m_bvalid,m_bready;
    wire [127:0] m_wdata;wire [15:0] m_wstrb;
    wire fabric_error,write_busy,write_quiescent,write_owner,write_data_busy,write_data_owner;
    wire [7:0] fabric_outstanding,fabric_peak;
    wire [63:0] fabric_aw_accept,fabric_aw_issue,fabric_w,fabric_b;
    wire service_write,memory_idle,fault_b_seen;wire [31:0] service_address;
    wire [1:0] inject_b=INJECT_B && write_busy && !write_owner ? 2'd1 : 2'd0;
    integer space_waits=0,wraps=0,peak_used=0,simultaneous_reserve_read=0;
    integer cycle=0,nn_started=0,nn_finished=0,cap_finished=0;
    integer nn_errors=0,cap_errors=0,nn_words_seen=0,cap_words_seen=0;
    integer nn_aw_count=0,cap_aw_count=0,nn_b_count=0,cap_b_count=0;
    integer nn_first_start=-1,nn_last_done=-1,early_words=0;
    integer blocked_empty_head=0,empty_run=0,max_empty_run=0;
    integer burst_begin=-1,max_nn_w_occupancy=0;
    integer capture_command_wait_max=0,capture_due_wait_max=0,nn_admit_first_w_max=0;
    integer source_last_cycle[0:NN_ROWS-1],nn_first_admit[0:NN_ROWS-1],nn_first_w[0:NN_ROWS-1];
    integer cap_command_cycle[0:CAPTURE_ROWS-1],cap_first_w[0:CAPTURE_ROWS-1];
    integer memory_ar,memory_aw,memory_r,memory_w,memory_b;
    reg previous_nn_response=0,previous_nn_error=0;
    reg [4095:0] directory,path;
    integer refill_left=0,refill_started=0,refill_fetches=0,refill_wlast=0;
    wire [15:0] nn_published,nn_granted;
    wire credit_read_fire,credit_aw_offer;
    wire stream_enable=cycle%83<70 && refill_left==0;

    function automatic [31:0] physical_base(input integer row);
        reg [31:0] logical_address;
        begin
            logical_address=NN_START+row*32'h8000;
            physical_base=RGB ? {logical_address[31:23],1'b0,logical_address[22:1]} : logical_address;
        end
    endfunction
    function automatic [127:0] capture_word(input integer row,input integer beat);
        for(integer b=0;b<16;b=b+1)capture_word[b*8+:8]=8'(177+row*23+beat*11+b*3);
    endfunction
    function automatic integer bursts_per_row;
        integer left,offset,take;
        begin
            left=PHYSICAL_WORDS;offset=255;bursts_per_row=0;
            while(left>0)begin
                take=left<16 ? left : 16;
                if(take>256-offset)take=256-offset;
                left=left-take;offset=(offset+take)%256;bursts_per_row=bursts_per_row+1;
            end
        end
    endfunction

`define C33_WRITER_PORTS \
        .clk(clk),.rst(rst),.start_valid(nn_start),.start_ready(nn_start_ready),.stream_enable(stream_enable), \
        .start_mode(3'(MODE)),.start_width(11'(WIDTH)),.start_channels(6'(CHANNELS)),.start_rgb(RGB!=0),.start_address(nn_address), \
        .in_valid(nn_valid),.in_ready(nn_ready),.in_data(packet[47:0]),.in_mask(packet[53:48]),.in_index(packet[69:54]),.in_last(packet[70]), \
        .cmd_valid(nn_cmd_valid),.cmd_ready(nn_cmd_ready),.cmd_address(nn_cmd_address),.cmd_beats(nn_beats), \
        .data_valid(nn_data_valid),.data_ready(nn_data_ready),.data(nn_data),.data_last(nn_last), \
        .response_valid(nn_response),.response_error(nn_response_error),.response_ready(nn_response_ready),.done(nn_done),.error(nn_error)
    generate if(CANDIDATE==3)begin : g_ring
        c1_r2_tensor_credit_ring_writer u_writer (
            .published_beats(nn_published),.granted_beats(BREAK_DRAIN ? 16'd0 : nn_granted),
            `C33_WRITER_PORTS);
        assign credit_read_fire=u_writer.read_fire;
        always @(posedge clk)if(!rst)begin
            if(nn_start && !nn_start_ready && !u_writer.collecting && !u_writer.allocated[u_writer.allocating_page] &&
               u_writer.reserve_end>1024) space_waits<=space_waits+1;
            if(nn_start && nn_start_ready && int'(u_writer.allocation_cursor)+int'(u_writer.requested_words)>1024)
                wraps<=wraps+1;
            if(u_writer.used_words>peak_used)peak_used<=u_writer.used_words;
            if(u_writer.reserve && u_writer.read_fire)simultaneous_reserve_read<=simultaneous_reserve_read+1;
        end
    end else if(CANDIDATE==2)begin : g_credit
        c1_r2_tensor_burst_credit_writer u_writer (
            .published_beats(nn_published),.granted_beats(BREAK_DRAIN ? 16'd0 : nn_granted),
            `C33_WRITER_PORTS);
        assign credit_read_fire=u_writer.read_fire;
    end else if(CANDIDATE==1)begin : g_candidate
        c1_r2_tensor_cutthrough_writer u_writer (`C33_WRITER_PORTS);
    end else begin : g_reference
        c1_r2_tensor_pingpong_writer u_writer (`C33_WRITER_PORTS);
    end endgenerate
`undef C33_WRITER_PORTS
    generate if(CANDIDATE<2)begin
        assign nn_published=0;assign nn_granted=0;assign credit_read_fire=0;
    end endgenerate
`define C33_DMA_PORTS \
        .clk(clk),.rst(rst),.cmd_valid(nn_cmd_valid),.cmd_ready(nn_cmd_ready),.cmd_rgbx(RGB!=0), \
        .cmd_address(nn_cmd_address),.cmd_beats(nn_beats),.data_valid(nn_data_valid),.data_ready(nn_data_ready),.data(nn_data),.data_last(nn_last), \
        .response_valid(nn_response),.response_ready(nn_response_ready),.response_error(nn_response_error), \
        .busy(nn_dma_busy),.protocol_error(nn_protocol),.outstanding(nn_outstanding), \
        .m_axi_awaddr(s_awaddr[0]),.m_axi_awlen(s_awlen[0]),.m_axi_awsize(s_awsize[0]),.m_axi_awburst(s_awburst[0]),.m_axi_awvalid(s_awvalid[0]),.m_axi_awready(s_awready[0]), \
        .m_axi_wdata(s_wdata[0]),.m_axi_wstrb(s_wstrb[0]),.m_axi_wlast(s_wlast[0]),.m_axi_wvalid(s_wvalid[0]),.m_axi_wready(s_wready[0]), \
        .m_axi_bid(4'd0),.m_axi_bresp(s_bresp[0]),.m_axi_bvalid(s_bvalid[0]),.m_axi_bready(s_bready[0])
    generate if(CANDIDATE>=2)begin : g_credit_dma
        c1_r2_rgbx_credit_row_write #(.BURST_BEATS(16),.OUTSTANDING(4)) nn_dma (
            .issue_enable(stream_enable),.published_beats(BREAK_CREDIT ? nn_beats : nn_published),
            .granted_beats(nn_granted),`C33_DMA_PORTS);
        assign credit_aw_offer=nn_dma.u_dma.aw_offer;
    end else begin : g_old_dma
        c1_r2_rgbx_row_write #(.BURST_BEATS(16),.OUTSTANDING(4)) nn_dma (`C33_DMA_PORTS);
        assign credit_aw_offer=0;
    end endgenerate
`undef C33_DMA_PORTS
    c1_r2_axi_row_write #(.BURST_BEATS(16),.OUTSTANDING(4)) capture_dma (
        .clk(clk),.rst(rst),.cmd_valid(cap_start),.cmd_ready(cap_cmd_ready),.cmd_address(cap_address),.cmd_beats(16'd16),
        .data_valid(cap_valid),.data_ready(cap_ready),.data(cap_data),.data_last(cap_last),
        .response_valid(cap_response),.response_ready(1'b1),.response_error(cap_response_error),
        .busy(cap_dma_busy),.protocol_error(cap_protocol),.outstanding(cap_outstanding),
        .m_axi_awaddr(s_awaddr[1]),.m_axi_awlen(s_awlen[1]),.m_axi_awsize(s_awsize[1]),.m_axi_awburst(s_awburst[1]),.m_axi_awvalid(s_awvalid[1]),.m_axi_awready(s_awready[1]),
        .m_axi_wdata(s_wdata[1]),.m_axi_wstrb(s_wstrb[1]),.m_axi_wlast(s_wlast[1]),.m_axi_wvalid(s_wvalid[1]),.m_axi_wready(s_wready[1]),
        .m_axi_bid(4'd0),.m_axi_bresp(s_bresp[1]),.m_axi_bvalid(s_bvalid[1]),.m_axi_bready(s_bready[1]));
    c1_axi_n_write_burst_arbiter_128 #(.CLIENTS(2),.FIFO_DEPTH(8),.EMPTY_AW_BYPASS(1),.W_AHEAD_OF_B(1)) fabric (
        .clk(clk),.rst(rst),.s_awaddr(s_awaddr),.s_awlen(s_awlen),.s_awsize(s_awsize),.s_awburst(s_awburst),.s_awvalid(s_awvalid),.s_awready(s_awready),
        .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wlast(s_wlast),.s_wvalid(s_wvalid),.s_wready(s_wready),.s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
        .m_awaddr(m_awaddr),.m_awlen(m_awlen),.m_awsize(m_awsize),.m_awburst(m_awburst),.m_awvalid(m_awvalid),.m_awready(m_awready),
        .m_wdata(m_wdata),.m_wstrb(m_wstrb),.m_wlast(m_wlast),.m_wvalid(m_wvalid),.m_wready(m_wready),.m_bresp(m_bresp),.m_bvalid(m_bvalid),.m_bready(m_bready),
        .protocol_error(fabric_error),.perf_outstanding(fabric_outstanding),.perf_max_outstanding(fabric_peak),
        .perf_aw_accept_count(fabric_aw_accept),.perf_aw_issue_count(fabric_aw_issue),.perf_w_beat_count(fabric_w),.perf_b_count(fabric_b),
        .write_busy(write_busy),.write_quiescent(write_quiescent),.write_owner(write_owner),.write_data_busy(write_data_busy),.write_data_owner(write_data_owner));
    c1_r2_axi_memory_bfm #(.BURST_BEATS(16),.STALLS(1),.MEMORY_DIV(2),.LATENCY(20),.AW_WAIT_W(AW_WAIT_W)) memory (
        .clk(clk),.rst(rst),.clear_faults(1'b0),.inject_r(3'd0),.inject_b(inject_b),.hold_b(1'b0),.fault_b_seen(fault_b_seen),
        .m_axi_arid(4'd0),.m_axi_araddr(32'd0),.m_axi_arlen(8'd0),.m_axi_arsize(3'd4),.m_axi_arburst(2'd1),.m_axi_arvalid(1'b0),.m_axi_rready(1'b1),.service_read_data(128'd0),
        .m_axi_awid(4'd0),.m_axi_awaddr(m_awaddr),.m_axi_awlen(m_awlen),.m_axi_awsize(m_awsize),.m_axi_awburst(m_awburst),.m_axi_awvalid(m_awvalid),.m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata),.m_axi_wstrb(m_wstrb),.m_axi_wlast(m_wlast),.m_axi_wvalid(m_wvalid),.m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp),.m_axi_bvalid(m_bvalid),.m_axi_bready(m_bready),.service_write(service_write),.service_write_address(service_address),
        .idle(memory_idle),.ar_total(memory_ar),.aw_total(memory_aw),.r_total(memory_r),.w_total(memory_w),.b_total(memory_b));

    always @(posedge clk)if(!rst)begin : monitor
        integer row,beat,region_hits,delay;
        cycle<=cycle+1;
        if(FORCE_REFILL && !refill_started && s_awvalid[0] && s_awready[0] && s_awlen[0]==15)begin
            refill_started<=1;refill_left<=180;
        end
        if(refill_left>0)begin
            refill_left<=refill_left-1;
            if(credit_read_fire)refill_fetches<=refill_fetches+1;
            if(s_wvalid[0] && s_wready[0] && s_wlast[0])refill_wlast<=refill_wlast+1;
            if(credit_aw_offer)$fatal(1,"C33 new grant during forced refill");
            if(refill_left==1 && CANDIDATE>=2 && (refill_fetches==0 || refill_wlast==0))
                $fatal(1,"C33 authorized burst failed to drain during refill");
        end
        if(cycle>300000)$fatal(1,"write contention timeout");
        if(nn_protocol || cap_protocol || fabric_error)$fatal(1,"write contention protocol failure");
        if(nn_start&&nn_start_ready)begin
            nn_started<=nn_started+1;if(nn_first_start<0)nn_first_start=cycle;
        end
        if(nn_started-nn_finished>2)$fatal(1,"write page credit exceeds two");
        if(nn_valid&&nn_ready&&packet[70])source_last_cycle[nn_started-1]=cycle;
        if(nn_done!==previous_nn_response || (nn_done && nn_error!==previous_nn_error))$fatal(1,"writer done not actual row response");
        previous_nn_response<=nn_response&&nn_response_ready;previous_nn_error<=nn_response_error;
        if(nn_response&&nn_response_ready)begin
            if(nn_b_count!=(nn_finished+1)*bursts_per_row() || source_last_cycle[nn_finished]<0 || nn_outstanding!=0)
                $fatal(1,"row response before final physical B/producer last");
        end
        if(nn_done)begin
            if(nn_error!==(INJECT_B!=0 && nn_finished==0))$fatal(1,"CNN error attribution/recovery mismatch");
            nn_finished<=nn_finished+1;nn_last_done=cycle;if(nn_error)nn_errors<=nn_errors+1;
        end
        if(cap_start&&cap_cmd_ready)cap_command_cycle[(cap_address-32'h100000)>>12]=cycle;
        if(cap_response)begin
            if(cap_b_count!=cap_finished+1 || cap_outstanding!=0)$fatal(1,"capture done before B");
            cap_finished<=cap_finished+1;if(cap_response_error)cap_errors<=cap_errors+1;
        end
        if(s_awvalid[0]&&s_awready[0])begin
            nn_aw_count<=nn_aw_count+1;
            for(integer r=0;r<NN_ROWS;r=r+1)if(s_awaddr[0]==physical_base(r))nn_first_admit[r]=cycle;
        end
        if(s_awvalid[1]&&s_awready[1])cap_aw_count<=cap_aw_count+1;
        if(s_bvalid[0]&&s_bready[0])nn_b_count<=nn_b_count+1;
        if(s_bvalid[1]&&s_bready[1])cap_b_count<=cap_b_count+1;
        if(write_data_busy && !write_data_owner)begin
            if(burst_begin<0)burst_begin=cycle;
            if(m_wvalid&&m_wready&&m_wlast)begin
                if(cycle-burst_begin+1>max_nn_w_occupancy)max_nn_w_occupancy=cycle-burst_begin+1;
                burst_begin=-1;
            end
        end else burst_begin=-1;
        if(write_data_busy && !write_data_owner && !s_wvalid[0] && s_wvalid[1])begin
            blocked_empty_head<=blocked_empty_head+1;empty_run=empty_run+1;
            if(empty_run>max_empty_run)max_empty_run=empty_run;
        end else empty_run=0;
        if(service_write)begin
            if(m_wstrb!==16'hffff)$fatal(1,"unexpected physical strobe");
            region_hits=0;
            for(integer r=0;r<NN_ROWS;r=r+1)if(service_address>=physical_base(r) && service_address<physical_base(r)+PHYSICAL_WORDS*16)begin
                region_hits=region_hits+1;beat=(service_address-physical_base(r))/16;
                if(seen_nn[r*PHYSICAL_WORDS+beat] || m_wdata!==expected_mem[r*PHYSICAL_WORDS+beat])$fatal(1,"CNN physical golden/duplicate mismatch");
                seen_nn[r*PHYSICAL_WORDS+beat]=1;nn_words_seen<=nn_words_seen+1;
                if(source_last_cycle[r]<0)early_words<=early_words+1;
                if(nn_first_w[r]<0)begin
                    nn_first_w[r]=cycle;
                    if(nn_first_admit[r]<0)$fatal(1,"W before local descriptor acceptance");
                    delay=cycle-nn_first_admit[r];if(delay>nn_admit_first_w_max)nn_admit_first_w_max=delay;
                end
            end
            for(integer r=0;r<CAPTURE_ROWS;r=r+1)if(service_address>=32'h100000+r*32'h1000 && service_address<32'h100000+r*32'h1000+256)begin
                region_hits=region_hits+1;beat=(service_address-(32'h100000+r*32'h1000))/16;
                if(seen_cap[r*16+beat] || m_wdata!==capture_word(r,beat))$fatal(1,"capture physical golden/duplicate mismatch");
                seen_cap[r*16+beat]=1;cap_words_seen<=cap_words_seen+1;
                if(cap_first_w[r]<0)begin
                    cap_first_w[r]=cycle;
                    if(cap_command_cycle[r]<0)$fatal(1,"capture W before command");
                    delay=cycle-cap_command_cycle[r];if(delay>capture_command_wait_max)capture_command_wait_max=delay;
                    delay=cycle-(40+r*160);if(delay>capture_due_wait_max)capture_due_wait_max=delay;
                end
            end
            if(region_hits!=1 || service_address[3:0]!=0)$fatal(1,"physical write escaped expected regions");
        end
    end

    reg aw_stalled=0,w_stalled=0;
    reg [44:0] saved_aw;
    reg [144:0] saved_w;
    always @(posedge clk)if(!rst)begin
        if(aw_stalled && (!m_awvalid || {m_awaddr,m_awlen,m_awsize,m_awburst}!==saved_aw))
            $fatal(1,"AXI AW changed under stall");
        if(w_stalled && (!m_wvalid || {m_wdata,m_wstrb,m_wlast}!==saved_w))
            $fatal(1,"AXI W changed under stall");
        aw_stalled<=m_awvalid&&!m_awready;saved_aw<={m_awaddr,m_awlen,m_awsize,m_awburst};
        w_stalled<=m_wvalid&&!m_wready;saved_w<={m_wdata,m_wstrb,m_wlast};
    end

    initial begin : cnn_source
        if(!$value$plusargs("DIR=%s",directory))$fatal(1,"missing contention vectors");
        if(PACKETS*NN_ROWS>16384 || PHYSICAL_WORDS*NN_ROWS>4096 || CAPTURE_ROWS!=4)$fatal(1,"contention fixture capacity");
        $sformat(path,"%0s/packets.mem",directory);$readmemh(path,packets_mem,0,PACKETS*NN_ROWS-1);
        $sformat(path,"%0s/physical.mem",directory);$readmemh(path,expected_mem,0,PHYSICAL_WORDS*NN_ROWS-1);
        if((^packets_mem[PACKETS*NN_ROWS-1])===1'bx || (^expected_mem[PHYSICAL_WORDS*NN_ROWS-1])===1'bx)$fatal(1,"missing contention vector tail");
        for(integer r=0;r<NN_ROWS;r=r+1)begin source_last_cycle[r]=-1;nn_first_admit[r]=-1;nn_first_w[r]=-1;end
        for(integer r=0;r<CAPTURE_ROWS;r=r+1)begin cap_command_cycle[r]=-1;cap_first_w[r]=-1;end
        for(integer i=0;i<4096;i=i+1)seen_nn[i]=0;
        for(integer i=0;i<64;i=i+1)seen_cap[i]=0;
        repeat(5)@(negedge clk);rst=0;
        for(integer r=0;r<NN_ROWS;r=r+1)begin
            nn_address=NN_START+r*32'h8000;nn_start=1;
            @(posedge clk);while(!nn_start_ready)@(posedge clk);
            @(negedge clk);nn_start=0;
            repeat(START_GAP)@(negedge clk);
            for(integer p=0;p<PACKETS;p=p+1)begin
                packet=packets_mem[r*PACKETS+p];
                if(MODE==2 && WIDTH%2==1 && packet[53:48]==0 && packet[70])repeat(64)@(negedge clk);
                nn_valid=1;
                @(posedge clk);while(!nn_ready)@(posedge clk);
                @(negedge clk);nn_valid=0;
                repeat(INPUT_GAP)@(negedge clk);
            end
        end
        while(nn_finished!=NN_ROWS || cap_finished!=CAPTURE_ROWS || !memory_idle || !write_quiescent)@(negedge clk);
        repeat(5)@(negedge clk);
        if(nn_errors!=INJECT_B || cap_errors!=0 || fault_b_seen!==(INJECT_B!=0))$fatal(1,"physical BRESP coverage/attribution missing");
        if(nn_aw_count!=NN_ROWS*bursts_per_row() || cap_aw_count!=CAPTURE_ROWS || nn_b_count!=nn_aw_count || cap_b_count!=cap_aw_count)$fatal(1,"physical burst/response counts differ");
        if(nn_words_seen!=NN_ROWS*PHYSICAL_WORDS || cap_words_seen!=CAPTURE_ROWS*16)$fatal(1,"physical word coverage incomplete");
        if(memory_ar!=0 || memory_r!=0 || memory_aw!=nn_aw_count+cap_aw_count || memory_b!=memory_aw || memory_w!=nn_words_seen+cap_words_seen)$fatal(1,"BFM accounting differs");
        if(fabric_outstanding!=0 || fabric_aw_accept!=memory_aw || fabric_aw_issue!=memory_aw || fabric_b!=memory_b || fabric_w!=memory_w)$fatal(1,"fabric accounting differs");
        if((CANDIDATE==1 && (early_words==0 || blocked_empty_head==0)) || (CANDIDATE==0 && early_words!=0))
            $fatal(1,"candidate early-write/contention coverage absent");
        if(FORCE_REFILL && (!refill_started || refill_left!=0 || refill_fetches==0 || refill_wlast==0))
            $fatal(1,"C33 forced refill coverage missing");
        $display("C34_WRITE_AXI_PASS candidate=%0d mode=%0d channels=%0d width=%0d aw_wait_w=%0d inject_b=%0d nn_rows=%0d capture_rows=%0d nn_words=%0d capture_words=%0d aw=%0d b=%0d early_words=%0d blocked_empty_head=%0d max_empty_run=%0d max_nn_w_occupancy=%0d capture_command_wait_max=%0d capture_due_wait_max=%0d nn_admit_first_w_max=%0d nn_span_cycles=%0d nn_errors=%0d capture_errors=%0d actual_AXI=1 actual_camera=0 whole_CNN=0 force_refill=%0d refill_fetches=%0d refill_wlast=%0d input_gap=%0d space_waits=%0d wraps=%0d peak_used=%0d simultaneous_reserve_read=%0d",CANDIDATE,MODE,CHANNELS,WIDTH,AW_WAIT_W,INJECT_B,NN_ROWS,CAPTURE_ROWS,nn_words_seen,cap_words_seen,memory_aw,memory_b,early_words,blocked_empty_head,max_empty_run,max_nn_w_occupancy,capture_command_wait_max,capture_due_wait_max,nn_admit_first_w_max,nn_last_done-nn_first_start,nn_errors,cap_errors,FORCE_REFILL,refill_fetches,refill_wlast,INPUT_GAP,space_waits,wraps,peak_used,simultaneous_reserve_read);
        $finish;
    end
    initial begin : capture_source
        wait(!rst);@(negedge clk);
        for(integer r=0;r<CAPTURE_ROWS;r=r+1)begin
            while(cycle<40+r*160 || !cap_cmd_ready)@(negedge clk);
            cap_address=32'h100000+r*32'h1000;cap_start=1;
            @(negedge clk);cap_start=0;
            for(integer b=0;b<16;b=b+1)begin
                cap_data=capture_word(r,b);cap_last=b==15;cap_valid=1;
                @(posedge clk);while(!cap_ready)@(posedge clk);
                @(negedge clk);cap_valid=0;
            end
        end
    end
endmodule
