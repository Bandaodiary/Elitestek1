`timescale 1ns/1ps
module tb_c1_r2_axi_row_dma;
    parameter integer BURST_BEATS=16,OUTSTANDING=4,STALLS=1,AW_WAIT_W=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,rcmd=0,wcmd=0,rready=0,wvalid=0,wlast=0,response_ready=0;
    reg [31:0] address=0;reg [15:0] beats=0;reg [127:0] wdata=0;
    wire rcmd_ready,wcmd_ready,rvalid,rlast,rerror,rbusy,wbusy,rprotocol,wprotocol,response_valid,response_error,wready;
    wire [127:0] rdata;wire [7:0] rout,wout;
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

    c1_r2_axi_row_read #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_read(
        .clk(clk),.rst(rst),.cmd_valid(rcmd),.cmd_ready(rcmd_ready),.cmd_address(address),.cmd_beats(beats),
        .data_valid(rvalid),.data_ready(rready),.data(rdata),.data_last(rlast),.data_error(rerror),
        .busy(rbusy),.protocol_error(rprotocol),.outstanding(rout),.m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
    c1_r2_axi_row_write #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_write(
        .clk(clk),.rst(rst),.cmd_valid(wcmd),.cmd_ready(wcmd_ready),.cmd_address(address),.cmd_beats(beats),
        .data_valid(wvalid),.data_ready(wready),.data(wdata),.data_last(wlast),
        .response_valid(response_valid),.response_ready(response_ready),.response_error(response_error),
        .busy(wbusy),.protocol_error(wprotocol),.outstanding(wout),.m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready));
    c1_r2_axi_memory_bfm #(.BURST_BEATS(BURST_BEATS),.STALLS(STALLS),.LATENCY(40),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    function automatic [127:0] pattern(input [31:0] a);
        pattern={a^32'hdeadbeef,a+32'h12345678,~a,a};
    endfunction
    assign service_read_data=pattern(service_read_address);
    integer cycle=0,read_index=0,write_index=0,issued_index=0,trials=0,mode=0;
    integer read_expected=0,write_expected=0,first_burst=0,start_cycle=0;
    reg active=0,illegal=0,read_finished=0,w_sent=0;
    reg held_r=0;reg [129:0] old_r;
    always @(posedge clk) begin : scoreboard
        reg [127:0] want;reg want_error;
        if(rst) begin cycle<=0;held_r<=0;w_sent<=0;end
        else begin
            cycle<=cycle+1;
            if(cycle>500000) $fatal(1,"unit watchdog mode=%0d read=%0d write=%0d issue=%0d",mode,read_index,write_index,issued_index);
            if(held_r && (!rvalid || old_r!=={rerror,rlast,rdata})) $fatal(1,"row R not held");
            held_r<=rvalid && !rready;old_r<={rerror,rlast,rdata};
            if(rout!=mem.r_count || wout!=mem.b_count) $fatal(1,"physical credit != independent BFM");
            if(rout>OUTSTANDING || wout>OUTSTANDING) $fatal(1,"outstanding limit");
            if(active && rvalid && rready) begin
                want=illegal || (mode==2 && read_index>0 && read_index<first_burst) ? 0 : pattern(address+read_index*32'd16);
                want_error=illegal || mode==1 || mode==2 || mode==4 || (mode==3 && read_index>=first_burst-1);
                if(mode==2 && read_index==0) want_error=1;
                if(rdata!==want || rlast!==(read_index==read_expected-1) || rerror!==want_error) $fatal(1,"row R mismatch mode=%0d i=%0d data=%h expected=%h error=%b/%b",mode,read_index,rdata,want,rerror,want_error);
                read_index<=read_index+1;
                if(rlast) begin
                    read_finished<=1;
                    if(mem.r_count!=0 || m_axi_rvalid || rout!=0) $fatal(1,"read finished before physical drain");
                end
            end
            if(active && service_write) begin
                want=mode==7 && write_index>0 ? 0 : pattern(address+write_index*32'd16);
                if(m_axi_wdata!==want || m_axi_wstrb!==(mode==7 && write_index>0 ? 16'h0000 : 16'hffff) ||
                   service_write_address!==address+write_index*32'd16) $fatal(1,"write payload/address mismatch mode=%0d i=%0d",mode,write_index);
                write_index<=write_index+1;
            end
            w_sent<=wvalid && wready;
            if(wvalid && wready) issued_index<=issued_index+1;
            if(response_valid && (!idle || wout!=0 || write_index!=write_expected)) $fatal(1,"write response before B drain / complete W");
        end
    end
    task reset_system;
        begin
            @(negedge clk);rst=1;active=0;rcmd=0;wcmd=0;wvalid=0;rready=0;response_ready=0;hold_b=0;
            repeat(4) @(negedge clk);rst=0;repeat(2) @(negedge clk);
            if(rprotocol || wprotocol || rbusy || wbusy || !idle) $fatal(1,"system reset failed");
        end
    endtask
    task run_row(input [31:0] a,input integer n,input integer fault,input integer invalid);
        integer guard,saved_r,saved_w,saved_ar,saved_aw,saved_b,expected_bursts,left_words,page_words,take_words;
        reg [32:0] next_addr;
        begin
            @(negedge clk);clear_faults=1;
            @(negedge clk);clear_faults=0;address=a;beats=n;mode=fault;illegal=invalid;
            read_index=0;write_index=0;issued_index=0;read_finished=0;read_expected=invalid ? 1 : n;write_expected=invalid ? 0 : n;
            first_burst=BURST_BEATS<256-int'(a[11:4]) ? BURST_BEATS : 256-int'(a[11:4]);
            if(first_burst>n) first_burst=n;
            inject_r=fault<=4 ? fault : 0;inject_b=fault==5 ? 1 : fault==6 ? 2 : 0;
            saved_r=r_total;saved_w=w_total;saved_ar=ar_total;saved_aw=aw_total;saved_b=b_total;
            expected_bursts=0;left_words=invalid ? 0 : n;next_addr={1'b0,a};
            while(left_words>0) begin
                page_words=256-int'(next_addr[11:4]);take_words=left_words<BURST_BEATS ? left_words : BURST_BEATS;
                if(take_words>page_words) take_words=page_words;
                expected_bursts=expected_bursts+1;left_words=left_words-take_words;next_addr=next_addr+take_words*16;
            end
            active=1;rcmd=1;wcmd=1;#1;
            if(!rcmd_ready || !wcmd_ready) $fatal(1,"new command not ready");
            @(negedge clk);rcmd=0;wcmd=0;guard=0;hold_b=1;
            while(!read_finished || !response_valid) begin
                rready=!STALLS || cycle%7!=0;
                if(!wvalid || w_sent) begin
                    wvalid=!invalid && issued_index<(fault==7 ? 1 : n) && (!STALLS || cycle%5!=0);
                    wdata=pattern(a+issued_index*32'd16);
                    wlast=fault==7 || (fault!=8 && issued_index==n-1);
                end
                if(guard>=100) hold_b=0;
                @(negedge clk);guard=guard+1;
                if(guard>200000) $fatal(1,"row timeout");
            end
            wvalid=0;hold_b=0;
            if(response_error!==(invalid || fault>=5)) $fatal(1,"wrong write response mode=%0d",fault);
            if(rprotocol!==(fault>=2 && fault<=4) || wprotocol!==(fault>=6)) $fatal(1,"wrong protocol lock mode=%0d",fault);
            if(ar_total-saved_ar!=expected_bursts || aw_total-saved_aw!=expected_bursts || b_total-saved_b!=expected_bursts ||
               w_total-saved_w!=write_expected || read_index!=read_expected || r_total-saved_r!=(invalid ? 0 : n-(fault==2 ? first_burst-1 : 0))) $fatal(1,"transaction conservation failed mode=%0d",fault);
            repeat(17) begin @(negedge clk);if(!response_valid || !wbusy || response_error!==(invalid || fault>=5)) $fatal(1,"response not held");end
            response_ready=1;@(negedge clk);response_ready=0;active=0;
            if(rbusy || wbusy || !idle || rcmd_ready!==(fault<2 || fault>4) || wcmd_ready!==(fault<6)) $fatal(1,"release / lock failure mode=%0d",fault);
            trials=trials+1;
            $display("C1_R2_AXI_DMA_ROW burst=%0d slots=%0d stalls=%0d addr=%h words=%0d fault=%0d invalid=%0d bursts=%0d cycles=%0d",BURST_BEATS,OUTSTANDING,STALLS,a,n,fault,invalid,expected_bursts,guard);
        end
    endtask
    initial begin
        reset_system();
        run_row(32'hff0,640,0,0);
        if(peak_read!=OUTSTANDING || (!AW_WAIT_W && peak_write!=OUTSTANDING)) begin
            // BURST=256 yields only four bursts for this unaligned 640-word row.
            if(OUTSTANDING<=4) $fatal(1,"missing multi-outstanding coverage read=%0d write=%0d",peak_read,peak_write);
        end
        run_row(0,1,0,0);run_row(16,15,0,0);run_row(32,16,0,0);run_row(48,17,0,0);
        run_row(32'h1000,255,0,0);run_row(32'h2000,256,0,0);run_row(32'h3ff0,257,0,0);
        run_row(32'hfffffff0,1,0,0);
        run_row(0,0,0,1);run_row(1,16,0,1);run_row(32'hfffffff0,2,0,1);
        run_row(32'h5000,33,1,0);run_row(32'h6000,19,0,0);
        run_row(32'h7000,33,5,0);run_row(32'h8000,19,0,0);
        for(integer fault=2;fault<=8;fault=fault+1) if(fault!=5 && !(fault==2 && BURST_BEATS==1)) begin
            reset_system();run_row(32'h9000,33,fault,0);
            repeat(20) begin @(negedge clk);if((fault<=4 && rcmd_ready) || (fault>=6 && wcmd_ready)) $fatal(1,"protocol lock did not persist");end
            reset_system();run_row(32'ha000,19,0,0);
        end
        $display("C1_R2_AXI_DMA_PASS burst=%0d slots=%0d stalls=%0d aw_wait_w=%0d rows=%0d",BURST_BEATS,OUTSTANDING,STALLS,AW_WAIT_W,trials);
        $finish;
    end
endmodule
