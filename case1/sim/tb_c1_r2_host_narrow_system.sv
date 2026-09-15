`timescale 1ns/1ps
module tb_c1_r2_host_narrow_system;
    parameter integer STALLS=0,AW_MODE=0,ID_BITS=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1;
    reg [ID_BITS-1:0] s_arid=0,s_awid=0;
    reg [31:0] s_araddr=0,s_awaddr=0;
    reg [7:0] s_arlen=0,s_awlen=0;
    reg [2:0] s_arsize=0,s_awsize=0;
    reg [1:0] s_arburst=1,s_awburst=1;
    reg s_arlock=0,s_awlock=0;
    reg [3:0] s_arregion=0,s_awregion=0;
    reg s_arvalid=0,s_awvalid=0,s_rready=0,s_bready=0;
    wire s_arready,s_awready;
    wire [ID_BITS-1:0] s_rid,s_bid;
    wire [127:0] s_rdata;wire [1:0] s_rresp,s_bresp;
    wire s_rlast,s_rvalid,s_bvalid;
    reg [127:0] s_wdata=0;reg [15:0] s_wstrb=0;reg s_wlast=0,s_wvalid=0;
    wire s_wready;
    wire [31:0] m_araddr,m_awaddr;wire [7:0] m_arlen,m_awlen;
    wire [2:0] m_arsize,m_awsize;wire [1:0] m_arburst,m_awburst;
    wire m_arvalid,m_awvalid,m_arready,m_awready;
    reg [127:0] m_rdata=0;reg [1:0] m_rresp=0,m_bresp=0;
    reg m_rlast=0,m_rvalid=0,m_bvalid=0;
    wire m_rready,m_bready;
    wire [127:0] m_wdata;wire [15:0] m_wstrb;wire m_wlast,m_wvalid,m_wready;
    wire busy,protocol_error;
    // Same byte RAM/reference driver as the C13 normal-access tests, but
    // now through the production host shell AND four-client C10 fabric.
    // Video is disabled. This is not concurrent video/narrow or CPU-IP proof.
    wire host_fabric_error;wire [3:0] physical_arid,physical_awid;
    c1_r2_host_video_system #(.CPU_ID_WIDTH(ID_BITS),.WIDTH(8),.HEIGHT(8)) dut (
        .clk(clk),
        .rst(rst),
        .platform_ready(1'b0),
        .psel(1'b0),
        .penable(1'b0),
        .pwrite(1'b0),
        .paddr(16'd0),
        .pwdata(32'd0),
        .capture_request(1'b0),
        .capture_tag(32'd0),
        .s_valid(1'b0),
        .s_sof(1'b0),
        .s_eol(1'b0),
        .s_eof(1'b0),
        .s_rgb(24'd0),
        .display_request(1'b0),
        .p_req(1'b0),
        .p_sof(1'b0),
        .p_eol(1'b0),
        .p_eof(1'b0),
        .fabric_error(host_fabric_error),
        .cpu_araddr(s_araddr),
        .cpu_arlen(s_arlen),
        .cpu_arsize(s_arsize),
        .cpu_arburst(s_arburst),
        .cpu_arvalid(s_arvalid),
        .cpu_arready(s_arready),
        .cpu_rdata(s_rdata),
        .cpu_rresp(s_rresp),
        .cpu_rlast(s_rlast),
        .cpu_rvalid(s_rvalid),
        .cpu_rready(s_rready),
        .cpu_awaddr(s_awaddr),
        .cpu_awlen(s_awlen),
        .cpu_awsize(s_awsize),
        .cpu_awburst(s_awburst),
        .cpu_awvalid(s_awvalid),
        .cpu_awready(s_awready),
        .cpu_wdata(s_wdata),
        .cpu_wstrb(s_wstrb),
        .cpu_wlast(s_wlast),
        .cpu_wvalid(s_wvalid),
        .cpu_wready(s_wready),
        .cpu_bresp(s_bresp),
        .cpu_bvalid(s_bvalid),
        .cpu_bready(s_bready),
        .m_axi_arid(physical_arid),
        .m_axi_araddr(m_araddr),
        .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst),
        .m_axi_arlock(),
        .m_axi_arcache(),
        .m_axi_arqos(),
        .m_axi_arprot(),
        .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),
        .m_axi_rid(4'd0),
        .m_axi_rdata(m_rdata),
        .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid),
        .m_axi_rready(m_rready),
        .m_axi_awid(physical_awid),
        .m_axi_awaddr(m_awaddr),
        .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst),
        .m_axi_awlock(),
        .m_axi_awcache(),
        .m_axi_awqos(),
        .m_axi_awprot(),
        .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata),
        .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid),
        .m_axi_wready(m_wready),
        .m_axi_bid(4'd0),
        .m_axi_bresp(m_bresp),
        .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .cpu_arid(s_arid),
        .cpu_awid(s_awid),
        .cpu_rid(s_rid),
        .cpu_bid(s_bid),
        .cpu_arlock(s_arlock),
        .cpu_awlock(s_awlock),
        .cpu_arregion(s_arregion),
        .cpu_awregion(s_awregion),
        .cpu_adapter_busy(busy),
        .cpu_adapter_fault(protocol_error)
    );
    always @(posedge clk)if(!rst)begin
        if(host_fabric_error)$fatal(1,"fabric error on normal/local-rejected CPU traffic");
        if(m_arvalid&&physical_arid!=0)$fatal(1,"physical RID normalization missing");
        if(m_awvalid&&physical_awid!=0)$fatal(1,"physical BID normalization missing");
    end

    reg [7:0] memory[0:65535],reference[0:65535];
    integer cycle=0,ar_total=0,aw_total=0,r_total=0,w_total=0,b_total=0;
    integer reads=0,writes=0,rejected=0,protocol_cases=0,response_cases=0;
    integer r_fault=0,b_fault=0;
    reg r_open=0,w_open=0,w_done=0,aw_seen=0;
    reg [31:0] ra=0,wa=0;integer rn=0,rs=0,rpos=0,r_due=0,wn=0,ws=0,wpos=0,b_due=0;
    wire allow_r=!STALLS || cycle%5!=2;
    assign m_arready=!rst && !r_open && !m_rvalid && (!STALLS || cycle%3!=0);
    assign m_awready=!rst && !aw_seen && !m_bvalid && (!STALLS || cycle%3!=1) && (AW_MODE==0 || w_done);
    assign m_wready=!rst && w_open && !w_done && (!STALLS || cycle%4!=1);
    function automatic [127:0] contents(input integer address);
        reg [127:0] value;begin
            for(integer b=0;b<16;b=b+1)value[b*8+:8]=memory[(address&65520)+b];
            contents=value;
        end
    endfunction
    function automatic [127:0] payload(input integer beat,input integer salt);
        reg [127:0] value;begin
            for(integer b=0;b<16;b=b+1)value[b*8+:8]=(beat*31+b*17+salt)&255;
            payload=value;
        end
    endfunction
    function automatic [15:0] lanes(input integer address,input integer size);
        lanes=((32'd1<<(1<<size))-1)<<(address&15);
    endfunction
    // Independent actual byte-addressed RAM. Only real physical W handshakes
    // write it. Golden reference is updated by the upstream test driver.
    always @(posedge clk)begin
        cycle<=cycle+1;
        if(cycle>300000)$fatal(1,"CPU adapter watchdog");
        if(rst)begin
            r_open<=0;m_rvalid<=0;m_rlast<=0;m_rdata<=0;m_rresp<=0;
            w_open<=0;w_done<=0;aw_seen<=0;m_bvalid<=0;m_bresp<=0;
            ar_total<=0;aw_total<=0;r_total<=0;w_total<=0;b_total<=0;
            rpos<=0;wpos<=0;
        end else begin
            if(m_arvalid&&m_arready)begin
                if(m_arburst!=1||m_arsize>4)$fatal(1,"invalid physical AR");
                r_open<=1;ra<=m_araddr;rn<=m_arlen+1;rs<=m_arsize;rpos<=0;r_due<=cycle+3;ar_total<=ar_total+1;
            end
            if(m_rvalid&&m_rready)begin
                m_rvalid<=0;r_total<=r_total+1;rpos<=rpos+1;
                if(rpos==rn-1 || (r_fault==2&&rpos==1))r_open<=0;
            end
            if(r_open&&!m_rvalid&&cycle>=r_due&&allow_r)begin
                m_rvalid<=1;m_rdata<=contents(ra+(rpos<<rs));
                m_rresp<=r_fault==1&&rpos==1 ? 2 : r_fault==4&&rpos==1 ? 1 : 0;
                m_rlast<=r_fault==2 ? rpos==1 : r_fault==3 ? 0 : rpos==rn-1;
            end
            // In AW_MODE=2 the slave uses a stable AW offer to accept ALL W
            // first. This is a test scoreboard reservation, not an AW credit.
            if(m_awvalid&&!w_open&&!m_bvalid)begin
                if(m_awburst!=1||m_awsize>4)$fatal(1,"invalid physical AW");
                w_open<=1;wa<=m_awaddr;wn<=m_awlen+1;ws<=m_awsize;wpos<=0;w_done<=0;
            end
            if(m_awvalid&&m_awready)begin aw_seen<=1;aw_total<=aw_total+1;end
            if(m_wvalid&&m_wready)begin
                if(m_wlast!==(wpos==wn-1))$fatal(1,"wrong physical WLAST");
                if((m_wstrb&~lanes(wa+(wpos<<ws),ws))!=0)$fatal(1,"physical W escaped byte lanes");
                for(integer b=0;b<16;b=b+1)if(m_wstrb[b])memory[((wa+(wpos<<ws))&65520)+b]<=m_wdata[b*8+:8];
                wpos<=wpos+1;w_total<=w_total+1;
                if(m_wlast)begin w_done<=1;b_due<=cycle+3;end
            end
            if(w_open&&aw_seen&&!m_bvalid&&((w_done&&cycle>=b_due)||(b_fault==3&&wpos>=1)))begin
                m_bvalid<=1;m_bresp<=b_fault==1 ? 2 : b_fault==2 ? 1 : 0;
            end
            if(m_bvalid&&m_bready)begin m_bvalid<=0;w_open<=0;aw_seen<=0;w_done<=0;b_total<=b_total+1;end
        end
    end
    reg hold_r=0,hold_b=0,hold_ar=0,hold_aw=0,hold_w=0;
    reg [ID_BITS+130:0] saved_r;reg [ID_BITS+1:0] saved_b;
    reg [44:0] saved_ar,saved_aw;reg [144:0] saved_w;
    always @(posedge clk)begin
        if(rst)begin hold_r=0;hold_b=0;hold_ar=0;hold_aw=0;hold_w=0;end
        else begin
            if(hold_r && (!s_rvalid||{s_rid,s_rdata,s_rresp,s_rlast}!==saved_r))$fatal(1,"CPU R changed under stall");
            if(hold_b && (!s_bvalid||{s_bid,s_bresp}!==saved_b))$fatal(1,"CPU B changed under stall");
            if(hold_ar && (!m_arvalid||{m_araddr,m_arlen,m_arsize,m_arburst}!==saved_ar))$fatal(1,"physical AR changed under stall");
            if(hold_aw && (!m_awvalid||{m_awaddr,m_awlen,m_awsize,m_awburst}!==saved_aw))$fatal(1,"physical AW changed under stall");
            if(hold_w && (!m_wvalid||{m_wdata,m_wstrb,m_wlast}!==saved_w))$fatal(1,"physical W changed under stall");
            hold_r=s_rvalid&&!s_rready;saved_r={s_rid,s_rdata,s_rresp,s_rlast};
            hold_b=s_bvalid&&!s_bready;saved_b={s_bid,s_bresp};
            hold_ar=m_arvalid&&!m_arready;saved_ar={m_araddr,m_arlen,m_arsize,m_arburst};
            hold_aw=m_awvalid&&!m_awready;saved_aw={m_awaddr,m_awlen,m_awsize,m_awburst};
            hold_w=m_wvalid&&!m_wready;saved_w={m_wdata,m_wstrb,m_wlast};
        end
    end
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;s_arvalid=0;s_awvalid=0;s_wvalid=0;s_rready=0;s_bready=0;
            r_fault=0;b_fault=0;repeat(4)@(negedge clk);rst=0;repeat(2)@(negedge clk);
            if(busy||protocol_error)$fatal(1,"reset did not clear ownership");
        end
    endtask
    task automatic read_job(input integer address,input integer size,input integer count,input integer id,input integer bad);
        integer accepted,original_ar,a,expect_resp;reg [15:0] mask;
        reg [ID_BITS-1:0] original_id;
        begin
            original_ar=ar_total;original_id=id;accepted=0;
            @(negedge clk);s_araddr=address;s_arsize=size;s_arlen=count-1;s_arid=original_id;
            s_arburst=bad==4 ? 2 : 1;s_arlock=bad==1;s_arregion=bad==2 ? 1 : 0;
            if(bad==3)s_arsize=5;
            s_arvalid=1;s_rready=0;
            do @(posedge clk);while(!s_arready);
            @(negedge clk);s_arvalid=0;s_arid=~original_id;s_araddr=32'hffffffff;s_arlen=0;s_arsize=7;s_arlock=0;s_arregion=0;
            repeat(17)@(negedge clk);
            if(s_arready||!busy)$fatal(1,"read lease released while R held");
            s_rready=1;
            while(accepted<count)begin
                @(posedge clk);
                if(s_rvalid&&s_rready)begin
                    if(s_rid!==original_id||s_rlast!==(accepted==count-1))$fatal(1,"CPU RID/RLAST mismatch");
                    expect_resp=bad!=0 ? 3 : (r_fault==1&&accepted==1)||(r_fault==2&&accepted>=1)||(r_fault==3&&accepted==count-1)||(r_fault==4&&accepted>=1) ? 2 : 0;
                    if(s_rresp!==expect_resp[1:0])$fatal(1,"CPU RRESP mismatch beat=%0d got=%0d expected=%0d",accepted,s_rresp,expect_resp);
                    a=address+(accepted<<size);mask=lanes(a,size);
                    for(integer b=0;b<16;b=b+1)begin
                        if(bad!=0||(r_fault==2&&accepted>1))begin
                            if(s_rdata[b*8+:8]!==8'd0)$fatal(1,"local/padded R is not zero");
                        end else if(mask[b]&&s_rdata[b*8+:8]!==reference[(a&65520)+b])$fatal(1,"RAM read mismatch address=%h lane=%0d got=%h expected=%h actual_ram=%h reads=%0d writes=%0d size=%0d count=%0d beat=%0d physical_addr=%h pos=%0d",a,b,s_rdata[b*8+:8],reference[(a&65520)+b],memory[(a&65520)+b],reads,writes,size,count,accepted,ra,rpos);
                    end
                    accepted=accepted+1;
                end
                @(negedge clk);s_rready=!STALLS || cycle%4!=0;
            end
            s_rready=0;
            if(ar_total-original_ar!=(bad!=0 ? 0 : 1))$fatal(1,"wrong physical read count");
            if(bad!=0)rejected=rejected+1;reads=reads+1;
        end
    endtask
    // wf: early logical LAST, missing final LAST, out-of-lane strobe.
    task automatic write_job(input integer address,input integer size,input integer count,input integer id,input integer bad,input integer wf);
        integer original_aw,original_w,original_b,sent,a,n,expect_resp;
        reg [15:0] mask,strobe;reg [127:0] value;reg [ID_BITS-1:0] original_id;
        begin
            original_aw=aw_total;original_w=w_total;original_b=b_total;original_id=id;
            @(negedge clk);s_awaddr=address;s_awsize=size;s_awlen=count-1;s_awid=original_id;
            s_awburst=bad==4 ? 2 : 1;s_awlock=bad==1;s_awregion=bad==2 ? 1 : 0;
            if(bad==3)s_awsize=5;
            s_awvalid=1;s_bready=0;
            do @(posedge clk);while(!s_awready);
            @(negedge clk);s_awvalid=0;s_awid=~original_id;s_awaddr=32'hffffffff;s_awlen=0;s_awsize=7;s_awlock=0;s_awregion=0;
            n=wf==1 ? 2 : count;
            for(sent=0;sent<n;sent=sent+1)begin
                a=address+(sent<<size);mask=lanes(a,size);value=payload(sent,id);
                strobe=sent%3==2 ? 0 : sent%3==1 ? mask&16'h5555 : mask;
                if(wf==3&&sent==0)strobe=strobe|16'h8000;
                s_wdata=value;s_wstrb=strobe;s_wvalid=1;s_wlast=(sent==n-1)&&wf!=2;
                do @(posedge clk);while(!s_wready);
                if(bad==0)for(integer b=0;b<16;b=b+1)if(strobe[b]&&mask[b])reference[(a&65520)+b]=value[b*8+:8];
                @(negedge clk);
            end
            s_wvalid=0;s_wlast=0;
            while(!s_bvalid)@(negedge clk);
            repeat(17)@(negedge clk);
            if(s_awready||!busy)$fatal(1,"write lease released before CPU B");
            expect_resp=bad!=0 ? 3 : wf!=0||b_fault!=0 ? 2 : 0;
            if(s_bid!==original_id||s_bresp!==expect_resp[1:0])$fatal(1,"CPU BID/BRESP mismatch id=%h/%h resp=%0d/%0d",s_bid,original_id,s_bresp,expect_resp);
            if(aw_total-original_aw!=(bad!=0 ? 0 : 1)||w_total-original_w!=(bad!=0 ? 0 : count)||b_total!=original_b)$fatal(1,"wrong write debt/count");
            s_bready=1;@(posedge clk);@(negedge clk);s_bready=0;
            if(bad!=0)rejected=rejected+1;writes=writes+1;
        end
    endtask
    task automatic check_locked;
        begin
            repeat(3)@(negedge clk);
            if(!protocol_error||s_arready||s_awready||busy)$fatal(1,"protocol fault did not drain and lock admission");
            protocol_cases=protocol_cases+1;
        end
    endtask
    initial begin
        for(integer i=0;i<65536;i=i+1)begin memory[i]=(i*29+7)&255;reference[i]=(i*29+7)&255;end
        reset_all();
        for(integer s=0;s<=4;s=s+1)begin
            for(integer c=0;c<4;c=c+1)begin
                integer n;n=c==0 ? 1 : c==1 ? 3 : c==2 ? 16 : 256;
                write_job(4096+s*4096,s,n,(1<<(ID_BITS-1))|s*3+c,0,0);
                read_job(4096+s*4096,s,n,(1<<(ID_BITS-1))|s*5+c,0);
            end
        end
        // Aligned narrow access in a nonzero lane, with partial/zero strobes.
        write_job('h7006,1,4,'hba,0,0);read_job('h7006,1,4,'hc7,0);
        fork
            write_job('h8000,4,16,'hff,0,0);
            read_job('h5000,4,16,'h81,0);
        join
        for(integer bad=1;bad<=8;bad=bad+1)begin
            integer a,s,n;a=4096;s=2;n=4;
            if(bad==5)a='h10000000;
            if(bad==6)a='h1fff;
            if(bad==7)begin a='h1ff0;s=4;n=2;end
            if(bad==8)begin a='h1004;s=4;end
            write_job(a,s,n,'he1,bad,0);read_job(a,s,n,'hf3,bad);
            if(protocol_error)$fatal(1,"local unsupported command caused fatal lock");
        end
        write_job('h9000,4,4,'hfa,0,0);read_job('h9000,4,4,'hf9,0);
        // Protocol faults are covered independently in the retained C13
        // unit. This test deliberately proves the new end-to-end NORMAL
        // narrow/partial-strobe path and local rejection, without claiming
        // recovery from malformed responses through the shared fabric.
        write_job('hc000,4,4,'h83,0,0);read_job('hc000,4,4,'ha3,0);
        repeat(3)@(negedge clk);
        if(busy||protocol_error||m_rvalid||m_bvalid)$fatal(1,"final debt remains");
        for(integer i=0;i<65536;i=i+1)if(memory[i]!==reference[i])$fatal(1,"final byte RAM differs at %h",i);
        $display("C1_R2_HOST_NARROW_PASS stalls=%0d aw_mode=%0d id_bits=%0d reads=%0d writes=%0d rejects=%0d protocol_cases=%0d response_cases=%0d actual_byte_ram=1 independent_rw=1 held_ids=1 narrow_sizes=5 max_beats=256 host_shell=1 actual_fabric=1 video_disabled=1",STALLS,AW_MODE,ID_BITS,reads,writes,rejected,protocol_cases,response_cases);
        $finish;
    end
endmodule
