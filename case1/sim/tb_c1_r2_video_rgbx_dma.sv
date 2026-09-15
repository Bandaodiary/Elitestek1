`timescale 1ns/1ps
module tb_c1_r2_video_rgbx_dma;
    parameter integer WIDTH=8,HEIGHT=12,STALLS=0,AW_WAIT_W=0;
    localparam CF=WIDTH>32 ? 256 : 8,SF=WIDTH>32 ? 512 : 32,BW=65536;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,clear_faults=0,hold_b=0;reg [2:0] inject_r=0;reg [1:0] inject_b=0;
    wire fault_r_seen,fault_b_seen,service_read,service_write,idle;
    wire [31:0] service_read_address,service_write_address;wire [127:0] service_read_data;
    integer ar_total,aw_total,r_total,w_total,b_total,peak_read,peak_write;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_rid,m_axi_bid;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    wire [2:0] m_axi_arsize,m_axi_awsize;
    wire [1:0] m_axi_arburst,m_axi_awburst,m_axi_rresp,m_axi_bresp;
    wire m_axi_arvalid,m_axi_arready,m_axi_rvalid,m_axi_rready,m_axi_rlast;
    wire m_axi_awvalid,m_axi_awready,m_axi_wvalid,m_axi_wready,m_axi_wlast,m_axi_bvalid,m_axi_bready;
    wire [127:0] m_axi_wdata,m_axi_rdata;wire [15:0] m_axi_wstrb;
    c1_r2_axi_memory_bfm #(.STALLS(STALLS),.MEMORY_DIV(2),.LATENCY(20),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    reg cap_cmd=0,cap_cancel=0,s_valid=0,s_sof=0,s_eol=0,s_eof=0,cap_ack=0;
    reg [31:0] cap_base=0,cap_tag=0;reg [10:0] cap_width=WIDTH;reg [9:0] cap_height=HEIGHT;reg [23:0] s_rgb=0;
    wire cap_ready,cap_busy,cap_done,cap_error,cap_drop,cap_overflow,cap_protocol;
    wire [31:0] cap_done_base,cap_done_tag;wire [7:0] cap_outstanding;wire [$clog2(CF+1)-1:0] cap_peak;
    c1_r2_video_capture_rgbx32 #(.FIFO_DEPTH(CF)) capture (
        .clk(clk),.rst(rst),.cmd_valid(cap_cmd),.cmd_ready(cap_ready),.cfg_base(cap_base),.cfg_tag(cap_tag),.cfg_width(cap_width),.cfg_height(cap_height),
        .cancel(cap_cancel),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),.s_rgb(s_rgb),.busy(cap_busy),
        .done_valid(cap_done),.done_ready(cap_ack),.done_error(cap_error),.done_dropped(cap_drop),.done_base(cap_done_base),.done_tag(cap_done_tag),
        .overflow_pulse(cap_overflow),.peak_level(cap_peak),.protocol_error(cap_protocol),.outstanding(cap_outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
    reg scan_cmd=0,scan_cancel=0,p_req=0,p_sof=0,p_eol=0,p_eof=0,scan_ack=0;
    reg [31:0] raw_base=0,style_base='h00800000,scan_tag=0;reg [10:0] scan_width=WIDTH;reg [9:0] scan_height=HEIGHT;
    wire scan_ready,scan_busy,scan_done,scan_error,scan_cancelled,scan_underflow,scan_protocol,prefill_ready;
    wire m_valid,m_sof,m_eol,m_eof;wire [23:0] m_rgb;
    wire [31:0] scan_raw,scan_style,scan_done_tag;wire [7:0] scan_outstanding;wire [$clog2(SF+1)-1:0] scan_peak,scan_min;
    c1_r2_video_scanout_rgbx32 #(.FIFO_DEPTH(SF)) scanout (
        .clk(clk),.rst(rst),.cmd_valid(scan_cmd),.cmd_ready(scan_ready),.cfg_raw_base(raw_base),.cfg_style_base(style_base),.cfg_tag(scan_tag),
        .cfg_width(scan_width),.cfg_height(scan_height),.cancel(scan_cancel),.p_req(p_req),.p_sof(p_sof),.p_eol(p_eol),.p_eof(p_eof),
        .m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_rgb(m_rgb),.busy(scan_busy),.prefill_ready(prefill_ready),
        .done_valid(scan_done),.done_error(scan_error),.done_cancelled(scan_cancelled),.done_ready(scan_ack),
        .done_raw_base(scan_raw),.done_style_base(scan_style),.done_tag(scan_done_tag),.underflow_pulse(scan_underflow),
        .peak_level(scan_peak),.min_active_level(scan_min),.protocol_error(scan_protocol),.outstanding(scan_outstanding),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready)
    );
    reg [127:0] ram[0:3*BW-1];bit initialized[0:3*BW-1];
    integer cycles=0,capture_runs=0,scan_runs=0,overflows=0,underflows=0,pixels=0,mode_scan=0,concurrent=0;
    function automatic [23:0] rgb(input integer plane,input integer x,input integer y);
        rgb={8'(x*3+y*7+plane*19+1),8'(x*11+y*5+plane*47+2),8'(x*17+y*13+plane*23+3)};
    endfunction
    function automatic [31:0] lane(input [23:0] c);lane={8'd0,c[7:0],c[15:8],c[23:16]};endfunction
    function automatic integer idx(input [31:0] a);
        begin if(a[3:0]!=0 || a[31:23]>2 || a[22:4]>=BW)$fatal(1,"video memory range %h",a);idx=a[31:23]*BW+a[22:4];end
    endfunction
    assign service_read_data=service_read ? ram[idx(service_read_address)] : 0;
    always @(posedge clk) begin : monitor
        integer k,x,y,plane;reg [127:0] expected;
        cycles=cycles+1;if(cycles>2000000)$fatal(1,"video watchdog cap=%b scan=%b",cap_busy,scan_busy);
        if(!rst) begin
            if(cap_outstanding!=mem.b_count || scan_outstanding!=mem.r_count)$fatal(1,"video physical credit mismatch");
            if(cap_overflow)overflows=overflows+1;if(scan_underflow)underflows=underflows+1;
            if(capture.owned&&scanout.owned)concurrent=concurrent+1;
            if(service_write)begin
                k=idx(service_write_address);plane=service_write_address[31:23];x=(service_write_address[22:4]*4)%WIDTH;y=(service_write_address[22:4]*4)/WIDTH;
                expected={lane(rgb(plane,x+3,y)),lane(rgb(plane,x+2,y)),lane(rgb(plane,x+1,y)),lane(rgb(plane,x,y))};
                if(m_axi_wdata!==expected || m_axi_wstrb!==16'hffff)$fatal(1,"video capture packing/address mismatch at %h",service_write_address);
                ram[k]=m_axi_wdata;initialized[k]=1;
            end
            if(service_read&&!initialized[idx(service_read_address)])$fatal(1,"scan read not produced by capture");
        end
    end
    task clear_errors;
        begin if(!idle)$fatal(1,"clear while memory active");@(negedge clk);clear_faults=1;inject_b=0;inject_r=0;@(negedge clk);clear_faults=0;end
    endtask
    task cap_arm(input integer plane);
        begin
            @(negedge clk);cap_base=plane*'h00800000;cap_tag='hc1100000+plane;cap_width=WIDTH;cap_height=HEIGHT;cap_cmd=1;
            #1;if(!cap_ready)$fatal(1,"cap admission refused");@(negedge clk);cap_cmd=0;cap_base='hffffffff;cap_tag=0;cap_width=3;cap_height=1;
        end
    endtask
    task cap_pixels(input integer plane,input integer fault);
        begin
            for(integer y=0;y<HEIGHT;y=y+1)for(integer x=0;x<WIDTH;x=x+1)begin
                @(negedge clk);s_valid=1;s_rgb=rgb(plane,x,y);s_sof=x==0&&y==0;s_eol=x==WIDTH-1;s_eof=x==WIDTH-1&&y==HEIGHT-1;
                if(fault==1 && y==0 && x==WIDTH-2)s_eol=1;
                @(negedge clk);s_valid=0;repeat(5)@(negedge clk);
            end
        end
    endtask
    task cap_finish(input integer plane,input integer fault,input integer before_w);
        begin
            while(!cap_done)@(negedge clk);
            if(cap_error!==(fault!=0&&fault!=4) || cap_drop!==(fault!=0) || cap_done_base!=plane*'h00800000 || cap_done_tag!='hc1100000+plane)$fatal(1,"cap result mismatch fault=%0d",fault);
            if(!idle || cap_outstanding!=0)$fatal(1,"cap result before B fence");
            if(fault==0 && w_total-before_w!=WIDTH*HEIGHT/4)$fatal(1,"cap frame incomplete");
            repeat(7)begin @(negedge clk);if(!cap_done||!cap_busy||cap_ready)$fatal(1,"cap result not held");end
            $display("C1_R2_RGBX_VIDEO_CAPTURE_PASS fault=%0d plane=%0d words=%0d peak_fifo=%0d physical_peak=%0d",fault,plane,w_total-before_w,cap_peak,peak_write);
            cap_ack=1;@(negedge clk);cap_ack=0;capture_runs=capture_runs+1;repeat(4)@(negedge clk);
        end
    endtask
    task run_capture(input integer plane,input integer fault);
        integer before_w,before_overflow;
        begin
            clear_errors();before_w=w_total;before_overflow=overflows;
            if(fault==2)inject_b=1;
            if(fault==3||fault==4)hold_b=1;
            cap_arm(plane);
            if(fault==4)begin
                fork
                    cap_pixels(plane,fault);
                    begin
                        while(cap_outstanding==0)@(negedge clk);cap_cancel=1;@(negedge clk);cap_cancel=0;
                        repeat(37)begin @(negedge clk);if(cap_done)$fatal(1,"cancel completed with B held");end
                        hold_b=0;
                    end
                join
            end else cap_pixels(plane,fault);
            if(fault==3)begin if(overflows!=before_overflow+1 || cap_done)$fatal(1,"overflow fence not exercised");hold_b=0;end
            cap_finish(plane,fault,before_w);
        end
    endtask
    task scan_arm;
        begin
            @(negedge clk);raw_base=0;style_base='h00800000;scan_tag='hc1110000;scan_width=WIDTH;scan_height=HEIGHT;scan_cmd=1;
            #1;if(!scan_ready)$fatal(1,"scan admission refused");@(negedge clk);scan_cmd=0;raw_base='hffffffff;style_base=0;scan_tag=0;scan_width=3;scan_height=1;
        end
    endtask
    task scan_pixels(input integer fault);
        reg [23:0] expected;
        begin
            for(integer y=0;y<HEIGHT;y=y+1)for(integer x=0;x<2*WIDTH;x=x+1)begin
                @(negedge clk);p_req=1;p_sof=x==0&&y==0;p_eol=x==2*WIDTH-1;p_eof=x==2*WIDTH-1&&y==HEIGHT-1;
                expected=fault==0 ? rgb(x>=WIDTH,x%WIDTH,y) : 24'd0;
                @(negedge clk);p_req=0;
                if(!m_valid || m_rgb!==expected || m_sof!==(x==0&&y==0) || m_eol!==(x==2*WIDTH-1) || m_eof!==(x==2*WIDTH-1&&y==HEIGHT-1))
                    $fatal(1,"scan pixel mismatch x=%0d y=%0d fault=%0d rgb=%h want=%h",x,y,fault,m_rgb,expected);
                pixels=pixels+1;repeat(3)@(negedge clk);
            end
        end
    endtask
    task run_scan(input integer fault);
        integer before_underflow,before_r;
        begin
            clear_errors();before_underflow=underflows;before_r=r_total;
            if(fault==2)inject_r=1;scan_arm();
            if(fault==3)begin
                while(scan_outstanding==0)@(negedge clk);scan_cancel=1;@(negedge clk);scan_cancel=0;
            end else begin
                if(fault==0)while(!prefill_ready)@(negedge clk);
                if(fault==2)while(!scanout.poison)@(negedge clk);
                scan_pixels(fault);
            end
            while(!scan_done)@(negedge clk);
            if(scan_error!==(fault==1||fault==2) || scan_cancelled!==(fault==3) || scan_raw!=0 || scan_style!='h00800000 || scan_done_tag!='hc1110000 || !idle)$fatal(1,"scan result mismatch fault=%0d",fault);
            if(fault==1 && underflows!=before_underflow+1)$fatal(1,"underflow absent");
            if(fault==0 && (underflows!=before_underflow || r_total-before_r!=WIDTH*HEIGHT/2))$fatal(1,"scan traffic/underrun");
            repeat(7)begin @(negedge clk);if(!scan_done||!scan_busy||scan_ready)$fatal(1,"scan result not held");end
            $display("C1_R2_RGBX_VIDEO_SCAN_PASS fault=%0d reads=%0d peak_fifo=%0d min_fifo=%0d underruns=%0d",fault,r_total-before_r,scan_peak,scan_min,underflows-before_underflow);
            scan_ack=1;@(negedge clk);scan_ack=0;scan_runs=scan_runs+1;repeat(4)@(negedge clk);
        end
    endtask
    initial begin
        for(integer i=0;i<3*BW;i=i+1)begin ram[i]='hdeadbeef;initialized[i]=0;end
        repeat(4)@(negedge clk);rst=0;
        cap_width=3;cap_cmd=1;scan_width=3;scan_cmd=1;#1;if(cap_ready||scan_ready)$fatal(1,"bad geometry admitted");
        @(negedge clk);cap_cmd=0;scan_cmd=0;
        run_capture(0,0);run_capture(1,0);run_scan(0);
        for(integer f=1;f<=4;f=f+1)begin run_capture(2,f);run_capture(2,0);end
        for(integer f=1;f<=3;f=f+1)begin run_scan(f);run_scan(0);end
        if(cap_protocol||scan_protocol||capture_runs!=10||scan_runs!=7||aw_total!=b_total)$fatal(1,"video unit incomplete");
        $display("C1_R2_RGBX_VIDEO_DMA_PASS width=%0d height=%0d stalls=%0d aw_wait_w=%0d captures=%0d scans=%0d pixels=%0d overflow=%0d underflow=%0d aw=%0d b=%0d",WIDTH,HEIGHT,STALLS,AW_WAIT_W,capture_runs,scan_runs,pixels,overflows,underflows,aw_total,b_total);$finish;
    end
endmodule
