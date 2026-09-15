`timescale 1ns/1ps
// Real XRGB writers (the same writer used by preview/output), not scripted W.
module tb_c1_two_frame_writers_w_ahead #(
    parameter bit W_AHEAD=1,
    parameter bit BYPASS=0,
    parameter bit SHARED_FABRIC=0,
    parameter bit READ_SKID=0
);
    logic clk=0,rst=1;always #5 clk=~clk;
    logic start=0,cancel=0,allow_aw=0,allow_w=0,allow_b=0;
    logic [1:0] busy,done,error,s_valid,s_ready;
    logic [1:0][31:0] s_awaddr;
    logic [1:0][7:0] s_awlen;
    logic [1:0][2:0] s_awsize;
    logic [1:0][1:0] s_awburst,s_bresp;
    logic [1:0] s_awvalid,s_awready,s_wlast,s_wvalid,s_wready,s_bvalid,s_bready;
    logic [1:0][127:0] s_wdata;logic [1:0][15:0] s_wstrb;
    wire [31:0] m_awaddr;wire [7:0] m_awlen;wire [2:0] m_awsize;wire [1:0] m_awburst;
    wire m_awvalid,m_awready,m_wlast,m_wvalid,m_wready,m_bvalid,m_bready;
    wire [127:0] m_wdata;wire [15:0] m_wstrb;wire [1:0] m_bresp;
    wire protocol_error;wire [7:0] perf_outstanding,perf_max_outstanding;
    wire write_busy,write_quiescent,write_owner,write_data_busy,write_data_owner;
    wire [1:0][31:0] qos_aw,qos_w,qos_b,qos_ar,qos_r,qos_owner_hold;
    wire [31:0] qos_busy_cycles,qos_errors,qos_frames;
    logic frame_closed=0;
    wire frame_done;
    integer sent[0:1],done_seen[0:1],b_seen[0:1];
    assign frame_done=(done_seen[0]==1 && done_seen[1]==1 && !frame_closed);
    integer aw_count=0,w_beats=0,b_count=0,mode=0,owner[0:1];
    integer runs=0,ahead_cases=0,aw_stalled_w_cases=0;
    integer accepted_owner[0:1],accepted_count=0;
    logic read_req=0;
    wire read_busy,read_quiescent,read_owner,arvalid,rready;
    wire [31:0] araddr;wire [7:0] arlen;wire [2:0] arsize;wire [1:0] arburst;
    wire [1:0] s_rvalid,s_rlast,s_arready;wire [1:0][127:0] s_rdata;wire [1:0][1:0] s_rresp;
    integer ar_count=0,r_count=0,read_responses=0,concurrent_reads=0;
    function automatic [23:0] rgb(input integer id,input integer n);
        rgb={8'(id*64+n),8'(id*32+n+1),8'(n+2)};
    endfunction
    for(genvar g=0;g<2;g++) begin:g_writer
        localparam integer WRITER=g;
        assign s_valid[WRITER]=sent[WRITER]<8;
        c1_axi_xrgb_frame_writer u_writer (
            .clk(clk),.rst(rst),.start(start),.cancel(cancel),
            .cfg_base_addr(32'h1000+WRITER*32'h1000),.cfg_width_pixels(16'd8),
            .cfg_height_lines(16'd1),.cfg_stride_bytes(32'd32),
            .busy(busy[WRITER]),.done(done[WRITER]),.error(error[WRITER]),
            .s_valid(s_valid[WRITER]),.s_ready(s_ready[WRITER]),.s_rgb(rgb(WRITER,sent[WRITER])),
            .s_sof(sent[WRITER]==0),.s_eol(sent[WRITER]==7),.s_eof(sent[WRITER]==7),
            .m_axi_awaddr(s_awaddr[WRITER]),.m_axi_awlen(s_awlen[WRITER]),.m_axi_awsize(s_awsize[WRITER]),
            .m_axi_awburst(s_awburst[WRITER]),.m_axi_awvalid(s_awvalid[WRITER]),.m_axi_awready(s_awready[WRITER]),
            .m_axi_wdata(s_wdata[WRITER]),.m_axi_wstrb(s_wstrb[WRITER]),.m_axi_wlast(s_wlast[WRITER]),
            .m_axi_wvalid(s_wvalid[WRITER]),.m_axi_wready(s_wready[WRITER]),
            .m_axi_bresp(s_bresp[WRITER]),.m_axi_bvalid(s_bvalid[WRITER]),.m_axi_bready(s_bready[WRITER])
        );
    end
    generate if(!SHARED_FABRIC) begin:g_direct
    assign read_busy=0;assign read_quiescent=1;assign read_owner=0;
    assign arvalid=0;assign araddr=0;assign arlen=0;assign arsize=0;assign arburst=0;
    assign rready=0;assign s_rvalid=0;assign s_rlast=0;assign s_rdata=0;assign s_rresp=0;
    assign s_arready=0;
    c1_axi_n_write_burst_arbiter_128 #(.CLIENTS(2),.FIFO_DEPTH(2),
        .W_AHEAD_OF_B(W_AHEAD),.EMPTY_AW_BYPASS(BYPASS)) u_arbiter (
        .clk(clk),.rst(rst),.s_awaddr(s_awaddr),.s_awlen(s_awlen),.s_awsize(s_awsize),
        .s_awburst(s_awburst),.s_awvalid(s_awvalid),.s_awready(s_awready),
        .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wlast(s_wlast),.s_wvalid(s_wvalid),.s_wready(s_wready),
        .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
        .m_awaddr(m_awaddr),.m_awlen(m_awlen),.m_awsize(m_awsize),.m_awburst(m_awburst),
        .m_awvalid(m_awvalid),.m_awready(m_awready),.m_wdata(m_wdata),.m_wstrb(m_wstrb),
        .m_wlast(m_wlast),.m_wvalid(m_wvalid),.m_wready(m_wready),
        .m_bresp(m_bresp),.m_bvalid(m_bvalid),.m_bready(m_bready),
        .protocol_error(protocol_error),.early_wlast_error(),.missing_wlast_error(),
        .early_b_error(),.orphan_b_error(),.perf_outstanding(perf_outstanding),
        .perf_max_outstanding(perf_max_outstanding),.perf_aw_accept_count(),
        .perf_aw_issue_count(),.perf_w_beat_count(),.perf_b_count(),
        .write_busy(write_busy),.write_quiescent(write_quiescent),.write_owner(write_owner),
        .write_data_busy(write_data_busy),.write_data_owner(write_data_owner)
    );
    end else begin:g_shared
        c1_axi_n_serial_arbiter_128 #(.CLIENTS(2),.WRITE_FIFO_DEPTH(2),
            .WRITE_W_AHEAD_OF_B(W_AHEAD),.WRITE_EMPTY_AW_BYPASS(BYPASS),.READ_RESPONSE_SKID(READ_SKID)
        ) u_arbiter (
            .clk(clk),.rst(rst),.s_awaddr(s_awaddr),.s_awlen(s_awlen),.s_awsize(s_awsize),
            .s_awburst(s_awburst),.s_awvalid(s_awvalid),.s_awready(s_awready),
            .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wlast(s_wlast),.s_wvalid(s_wvalid),.s_wready(s_wready),
            .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
            .m_awaddr(m_awaddr),.m_awlen(m_awlen),.m_awsize(m_awsize),.m_awburst(m_awburst),
            .m_awvalid(m_awvalid),.m_awready(m_awready),.m_wdata(m_wdata),.m_wstrb(m_wstrb),
            .m_wlast(m_wlast),.m_wvalid(m_wvalid),.m_wready(m_wready),
            .m_bresp(m_bresp),.m_bvalid(m_bvalid),.m_bready(m_bready),
            .s_araddr({32'd0,32'h9000}),.s_arlen(16'd0),.s_arsize({3'd4,3'd4}),
            .s_arburst({2'b01,2'b01}),.s_arvalid({1'b0,read_req}),.s_arready(s_arready),
            .s_rdata(s_rdata),.s_rresp(s_rresp),.s_rlast(s_rlast),.s_rvalid(s_rvalid),.s_rready(2'b01),
            .m_araddr(araddr),.m_arlen(arlen),.m_arsize(arsize),.m_arburst(arburst),
            .m_arvalid(arvalid),.m_arready(1'b1),.m_rdata(128'h0123456789abcdef1020304050607080),
            .m_rresp(2'b00),.m_rlast(1'b1),.m_rvalid(ar_count>r_count),.m_rready(rready),
            .read_busy(read_busy),.read_quiescent(read_quiescent),.read_owner(read_owner),
            .write_busy(write_busy),.write_quiescent(write_quiescent),.write_owner(write_owner),
            .write_protocol_error(protocol_error),.write_data_busy(write_data_busy),.write_data_owner(write_data_owner)
        );
        assign perf_outstanding=u_arbiter.g_queued_write.u_writer.perf_outstanding;
        assign perf_max_outstanding=u_arbiter.g_queued_write.u_writer.perf_max_outstanding;
    end endgenerate
    c1_axi_shared_qos_monitor #(.CLIENTS(2),.COUNTER_W(32)) u_qos (
        .clk(clk),.rst(rst),.clear_stats(1'b0),
        .awvalid(s_awvalid),.awready(s_awready),.wvalid(s_wvalid),.wready(s_wready),
        .bvalid(s_bvalid),.bready(s_bready),.arvalid({1'b0,read_req}),.arready(s_arready),
        .rvalid(s_rvalid),.rready(2'b01),.read_busy(read_busy),.read_quiescent(read_quiescent),.read_owner(read_owner),
        .write_busy(write_busy),.write_quiescent(write_quiescent),.write_owner(write_owner),
        .frame_start(start),.frame_done(frame_done),.frame_abort(1'b0),.frame_deadline_cycles(32'd0),
        .display_underflow_event(1'b0),.aw_accept_count(qos_aw),.w_accept_count(qos_w),
        .b_accept_count(qos_b),.write_owner_hold_total(qos_owner_hold),
        .ar_accept_count(qos_ar),.r_accept_count(qos_r),
        .write_busy_cycles(qos_busy_cycles),.protocol_error_count(qos_errors),.frame_count(qos_frames)
    );
    always @(posedge clk) begin
        if(rst || start) frame_closed<=0;
        else if(frame_done) frame_closed<=1;
    end
    assign m_awready=allow_aw;
    assign m_wready=allow_w;
    assign m_bvalid=allow_b && b_count<aw_count && w_beats>=2*(b_count+1);
    assign m_bresp=(mode==2 && b_count<2 && owner[b_count]==0) ? 2'b10 : 2'b00;
    always @(posedge clk) if(!rst) begin
        if(protocol_error) $fatal(1,"normal writer traffic raised arbiter fault");
        if(arvalid) begin
            if(ar_count!=0 || araddr!==32'h9000 || arlen!==0 || arsize!==4 || arburst!==1)
                $fatal(1,"concurrent read AR mismatch");
            ar_count<=ar_count+1;
        end
        if(ar_count>r_count && rready) r_count<=r_count+1;
        if(s_rvalid[0]) begin
            if(s_rdata[0]!==128'h0123456789abcdef1020304050607080 || s_rresp[0]!==0 || !s_rlast[0] ||
               !write_busy || b_count!=0) $fatal(1,"read failed while writes waiting for B");
            read_responses<=read_responses+1;
        end
        if(s_rvalid[1]) $fatal(1,"read routed to wrong client");
        if(write_busy!==(accepted_count>b_count) || write_quiescent!==!write_busy)
            $fatal(1,"fabric quiescence does not cover every unretired descriptor");
        if(write_data_busy!==(accepted_count*2>w_beats)) $fatal(1,"W-pending status mismatch");
        if(write_busy && write_owner!==1'(accepted_owner[b_count])) $fatal(1,"wrong B-head owner status");
        if(write_data_busy && write_data_owner!==1'(accepted_owner[w_beats/2])) $fatal(1,"wrong W-pending owner status");
        for(integer id=0;id<2;id++) begin
            if(s_valid[id]&&s_ready[id]) sent[id]<=sent[id]+1;
            if(s_awvalid[id]&&s_awready[id]) begin
                if(accepted_count>=2) $fatal(1,"extra upstream descriptor");
                accepted_owner[accepted_count]<=id;accepted_count<=accepted_count+1;
            end
            if(s_bvalid[id]&&s_bready[id]) begin
                if(!m_bvalid || !m_bready || owner[b_count]!=id || s_bresp[id]!==m_bresp)
                    $fatal(1,"B routed to wrong writer");
                b_seen[id]<=b_seen[id]+1;
            end
            if(done[id]) begin
                if(busy[id] || b_seen[id]!=1 || done_seen[id]!=0) $fatal(1,"writer retired before B or twice");
                done_seen[id]<=done_seen[id]+1;
            end
        end
        if(m_awvalid&&m_awready) begin
            if(aw_count>=2 || m_awlen!==1 || m_awsize!==4 || m_awburst!==1 ||
               (m_awaddr!==32'h1000 && m_awaddr!==32'h2000)) $fatal(1,"AW mismatch");
            owner[aw_count]<=m_awaddr==32'h1000 ? 0 : 1;
            aw_count<=aw_count+1;
        end
        if(m_wvalid&&m_wready) begin
            // W may legitimately precede downstream AW. Independent upstream
            // acceptance order provides the reference without assuming AWREADY.
            if(w_beats>=4 || accepted_count<=w_beats/2 || m_wstrb!==16'hffff || m_wlast!==(w_beats%2==1))
                $fatal(1,"W framing/order mismatch");
            for(integer n=0;n<4;n++)
                if(m_wdata[n*32+:32]!=={8'd0,rgb(accepted_owner[w_beats/2],(w_beats%2)*4+n)})
                    $fatal(1,"packed XRGB data crossed writers");
            w_beats<=w_beats+1;
        end
        if(m_bvalid&&m_bready) begin
            if(owner[b_count]!=accepted_owner[b_count]) $fatal(1,"AW changed descriptor order");
            b_count<=b_count+1;
        end
    end
    initial begin
        for(integer id=0;id<2;id++) begin sent[id]=0;done_seen[id]=0;b_seen[id]=0;end
        repeat(4) @(negedge clk);rst=0;
        for(mode=0;mode<4;mode++) begin
            @(negedge clk);
            aw_count=0;w_beats=0;b_count=0;accepted_count=0;
            ar_count=0;r_count=0;read_responses=0;read_req=0;
            for(integer id=0;id<2;id++) begin sent[id]=0;done_seen[id]=0;b_seen[id]=0;end
            allow_aw=(mode!=1);allow_w=0;allow_b=0;
            start=1;@(negedge clk);start=0;
            wait(accepted_count==2);@(negedge clk);
            if(mode==1) begin cancel=1;@(negedge clk);cancel=0;end
            allow_w=1;
            wait(w_beats==(W_AHEAD ? 4 : 2));@(negedge clk);
            repeat(12) begin
                @(negedge clk);
                if(b_count!=0 || done_seen[0]!=0 || done_seen[1]!=0 || busy!==2'b11 || perf_outstanding!=2)
                    $fatal(1,"B-delayed ownership was released");
                if(w_beats!=(W_AHEAD ? 4 : 2)) $fatal(1,"unexpected W-ahead behavior");
            end
            if(W_AHEAD) ahead_cases=ahead_cases+1;
            if(SHARED_FABRIC) begin
                read_req=1;wait(ar_count==1);@(negedge clk);read_req=0;
                wait(read_responses==1);repeat(2) @(negedge clk);
                if(read_busy || !read_quiescent || r_count!=1 || b_count!=0 || !write_busy)
                    $fatal(1,"read/write independence or quiescence failed");
                concurrent_reads=concurrent_reads+1;
            end
            if(mode==1) begin
                if(aw_count!=0) $fatal(1,"AW gate ineffective");
                aw_stalled_w_cases=aw_stalled_w_cases+1;
            end
            allow_aw=1;wait(aw_count==2);@(negedge clk);allow_b=1;
            wait(done_seen[0]==1 && done_seen[1]==1);
            repeat(4) @(negedge clk);
            if(error!==(mode==2 ? 2'b01 : 2'b00) || w_beats!=4 || b_count!=2 || perf_outstanding!=0)
                $fatal(1,"final result/response ownership mismatch mode=%0d",mode);
            if(qos_errors!=0 || qos_frames!=mode+1 || write_busy || !write_quiescent || write_data_busy)
                $fatal(1,"QoS/fabric retirement mismatch");
            if(qos_ar[0]!=(SHARED_FABRIC ? mode+1 : 0) || qos_r[0]!=(SHARED_FABRIC ? mode+1 : 0) ||
               qos_ar[1]!=0 || qos_r[1]!=0) $fatal(1,"read QoS count/owner mismatch");
            for(integer id=0;id<2;id++)
                if(qos_aw[id]!=mode+1 || qos_b[id]!=mode+1 || qos_w[id]!=2*(mode+1))
                    $fatal(1,"per-writer QoS accounting mismatch");
            runs=runs+1;
        end
        if(qos_owner_hold[0]+qos_owner_hold[1]!=qos_busy_cycles)
            $fatal(1,"B-head owner time does not partition busy cycles");
        $display("C1_WRITE_STATUS_QOS_PASS frames=%0d busy_cycles=%0d protocol_errors=%0d",qos_frames,qos_busy_cycles,qos_errors);
        if(SHARED_FABRIC && concurrent_reads!=4) $fatal(1,"missing shared read coverage");
        $display("C1_SHARED_QUEUED_WRITE_PASS shared=%0d read_skid=%0d concurrent_reads=%0d",SHARED_FABRIC,READ_SKID,concurrent_reads);
        $display("C1_TWO_WRITERS_W_AHEAD_PASS enabled=%0d bypass=%0d runs=%0d ahead_cases=%0d aw_stalled_w=%0d pixels=64 no_reset=1",W_AHEAD,BYPASS,runs,ahead_cases,aw_stalled_w_cases);
        $finish;
    end
    initial begin #200000;$fatal(1,"two frame writer timeout mode=%0d",mode);end
endmodule
