`timescale 1ns/1ps
module tb_c1_r2_rgbx_row_dma;
    parameter integer BURST_BEATS=16,OUTSTANDING=4,STALLS=1,AW_WAIT_W=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,rcmd=0,wcmd=0,rready=0,wvalid=0,wlast=0,response_ready=0;
    reg rgbx=0;
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

    c1_r2_rgbx_row_read #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_read(
        .clk(clk),.rst(rst),.cmd_valid(rcmd),.cmd_ready(rcmd_ready),.cmd_address(address),.cmd_beats(beats),.cmd_rgbx(rgbx),
        .data_valid(rvalid),.data_ready(rready),.data(rdata),.data_last(rlast),.data_error(rerror),
        .busy(rbusy),.protocol_error(rprotocol),.outstanding(rout),.m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
    c1_r2_rgbx_row_write #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_write(
        .clk(clk),.rst(rst),.cmd_valid(wcmd),.cmd_ready(wcmd_ready),.cmd_address(address),.cmd_beats(beats),.cmd_rgbx(rgbx),
        .data_valid(wvalid),.data_ready(wready),.data(wdata),.data_last(wlast),
        .response_valid(response_valid),.response_ready(response_ready),.response_error(response_error),
        .busy(wbusy),.protocol_error(wprotocol),.outstanding(wout),.m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready));
    c1_r2_axi_memory_bfm #(.BURST_BEATS(BURST_BEATS),.STALLS(STALLS),.LATENCY(20),.MEMORY_DIV(2),.AW_WAIT_W(AW_WAIT_W)) mem(.*);
    reg [127:0] memory[0:4095];
    integer cycle=0,jobs=0,ri=0,wi=0,logical_n=0,physical_n=0,first_burst=0,read_fault=0,write_fault=0;
    integer start_ar,start_aw,start_r,start_w,start_b,normal_jobs=0,fault_jobs=0,reject_jobs=0;
    reg [31:0] logical_address=0,physical_address=0;
    reg compact_mode=0,write_active=0,read_active=0,held_r=0;
    reg [129:0] old_r;
    function automatic integer idx(input [31:0] a);
        begin if(a[3:0]!=0 || a[22:4]>=4096)$fatal(1,"RGBX BFM address range %h",a);idx=a[15:4];end
    endfunction
    function automatic [127:0] pattern(input integer j,input bit c);
        reg [31:0] a;begin
            a=32'h13235700+j*32'h00050317;
            pattern=c ? {40'd0,(a[23:0]^24'h934ba7),40'd0,a[23:0]} : {a^32'habcdef01,a+32'h34567890,~a,a};
        end
    endfunction
    function automatic [127:0] pack_words(input [127:0] a,input [127:0] b);
        pack_words={8'd0,b[87:64],8'd0,b[23:0],8'd0,a[87:64],8'd0,a[23:0]};
    endfunction
    assign service_read_data=service_read ? memory[idx(service_read_address)] : 0;
    always @(posedge clk)begin : score
        reg [127:0] want,a,b;reg want_error;
        if(rst)begin cycle<=0;held_r<=0;end
        else begin
            cycle<=cycle+1;if(cycle>500000)$fatal(1,"RGBX watchdog");
            if(held_r&&(!rvalid||old_r!=={rerror,rlast,rdata}))$fatal(1,"RGBX logical response not held");
            held_r<=rvalid&&!rready;old_r<={rerror,rlast,rdata};
            if(rout!=mem.r_count || wout!=mem.b_count)$fatal(1,"RGBX physical credit mismatch");
            if(write_active&&service_write)begin
                a=pattern(compact_mode ? wi*2 : wi,compact_mode);b=pattern(wi*2+1,1);
                if(write_fault==2)begin if(wi!=0)a=0;b=0;end
                want=compact_mode ? pack_words(a,b) : a;
                if(m_axi_wdata!==want || service_write_address!==physical_address+wi*16 ||
                   m_axi_wstrb!==(write_fault==2&&!compact_mode&&wi!=0 ? 16'h0000 : 16'hffff))$fatal(1,"RGBX actual W mismatch i=%0d compact=%0d",wi,compact_mode);
                memory[idx(service_write_address)]=m_axi_wdata;wi=wi+1;
            end
            if(read_active&&rvalid&&rready)begin
                want=pattern(ri,compact_mode);
                if(read_fault==3 && ri>=(compact_mode ? 2 : 1) && ri<first_burst*(compact_mode ? 2 : 1))want=0;
                want_error=read_fault!=0;
                if(read_fault==4)want_error=(ri/(compact_mode ? 2 : 1))>=first_burst-1;
                if(rdata!==want||rlast!==(ri==logical_n-1)||rerror!==want_error)$fatal(1,"RGBX logical R mismatch i=%0d data=%h want=%h error=%b/%b last=%b",ri,rdata,want,rerror,want_error,rlast);
                ri=ri+1;
                if(rlast&&rout!=0)$fatal(1,"RGBX last before physical R drain");
            end
            if(response_valid&&(wout!=0||m_axi_awvalid||m_axi_wvalid))$fatal(1,"RGBX response before W/B drain");
        end
    end
    task reset_system;
        begin
            @(negedge clk);rst=1;rcmd=0;wcmd=0;wvalid=0;rready=0;response_ready=0;write_active=0;read_active=0;
            inject_r=0;inject_b=0;hold_b=0;clear_faults=0;
            repeat(4)@(negedge clk);rst=0;repeat(2)@(negedge clk);
            if(rbusy||wbusy||rprotocol||wprotocol)$fatal(1,"RGBX reset");
        end
    endtask
    task setup_job(input bit c,input integer n,input [31:0] a);
        begin
            compact_mode=c;logical_n=n;physical_n=c ? n/2 : n;logical_address=a;
            physical_address=c ? {a[31:23],1'b0,a[22:1]} : a;
            first_burst=physical_n<BURST_BEATS ? physical_n : BURST_BEATS;
            if(first_burst>256-int'(physical_address[11:4]))first_burst=256-int'(physical_address[11:4]);
            ri=0;wi=0;address=a;beats=n;rgbx=c;start_ar=ar_total;start_aw=aw_total;start_r=r_total;start_w=w_total;start_b=b_total;
        end
    endtask
    task write_row(input integer fault);
        begin
            write_fault=fault;inject_b=fault==1 ? 1 : fault==4 ? 2 : 0;write_active=1;
            @(negedge clk);address=logical_address;beats=logical_n;rgbx=compact_mode;wcmd=1;
            do @(posedge clk);while(!wcmd_ready);
            @(negedge clk);wcmd=0;address='hdead0010;beats=3;rgbx=!compact_mode;
            for(integer j=0;j<(fault==2 ? 1 : logical_n);j=j+1)begin
                repeat((j%3)+1)@(negedge clk);
                wvalid=1;wdata=pattern(j,compact_mode);wlast=fault==2 ? 1 : fault==3 ? 0 : j==logical_n-1;
                do @(posedge clk);while(!wready);
                @(negedge clk);wvalid=0;
            end
            while(!response_valid)@(negedge clk);
            repeat(7)begin
                if(!response_valid||response_error!==(fault!=0)||!wbusy||wout!=0)$fatal(1,"RGBX held write response");
                @(negedge clk);
            end
            if(wi!=physical_n||w_total-start_w!=physical_n||aw_total-start_aw!=b_total-start_b)$fatal(1,"RGBX physical write saving/drain");
            if(wprotocol!==(fault>=2))$fatal(1,"RGBX write fault severity");
            response_ready=1;@(negedge clk);response_ready=0;write_active=0;
            if(wbusy)$fatal(1,"RGBX busy after response ACK");
        end
    endtask
    task read_row(input integer fault);
        begin
            read_fault=fault;inject_r=fault==1 ? 1 : fault==2 ? 4 : fault==3 ? 2 : fault==4 ? 3 : 0;
            read_active=1;ri=0;start_r=r_total;
            @(negedge clk);address=logical_address;beats=logical_n;rgbx=compact_mode;rcmd=1;
            do @(posedge clk);while(!rcmd_ready);
            @(negedge clk);rcmd=0;address='hdead0010;beats=3;rgbx=!compact_mode;
            while(ri<logical_n)begin @(negedge clk);rready=cycle%7!=0&&cycle%7!=1;end
            @(negedge clk);rready=0;read_active=0;
            if(rbusy||!idle||rprotocol!==(fault>=2))$fatal(1,"RGBX read drain/severity");
            if(r_total-start_r!=physical_n-(fault==3 ? first_burst-1 : 0))$fatal(1,"RGBX physical read saving");
        end
    endtask
    task reject_bad(input [31:0] a,input integer n);
        integer old_ar,old_aw;
        begin
            old_ar=ar_total;old_aw=aw_total;
            @(negedge clk);address=a;beats=n;rgbx=1;wcmd=1;rcmd=1;
            @(negedge clk);wcmd=0;rcmd=0;
            while(!response_valid||!rvalid)@(negedge clk);
            repeat(5)begin
                if(!response_valid||!response_error||!rvalid||!rlast||!rerror||rdata!=0||wready||ar_total!=old_ar||aw_total!=old_aw)$fatal(1,"invalid RGBX command not contained");
                @(negedge clk);
            end
            rready=1;response_ready=1;@(negedge clk);rready=0;response_ready=0;
            if(rbusy||wbusy||rprotocol||wprotocol||!idle)$fatal(1,"invalid RGBX command did not recover");
            reject_jobs=reject_jobs+1;
        end
    endtask
    initial begin
        reset_system();
        for(integer c=0;c<2;c=c+1)begin
            for(integer k=0;k<5;k=k+1)begin
                setup_job(c,k==0 ? 2 : k==1 ? 6 : k==2 ? 32 : k==3 ? 70 : 320,c ? 'h08001fc0 : 'h08000fe0);
                write_row(0);read_row(0);normal_jobs=normal_jobs+1;
            end
            for(integer f=1;f<=4;f=f+1)begin
                reset_system();setup_job(c,40,c ? 'h08001fc0 : 'h08000fe0);write_row(f);fault_jobs=fault_jobs+1;
                if(f==1)begin
                    inject_b=0;clear_faults=1;@(negedge clk);clear_faults=0;
                    setup_job(c,6,'h08000400);write_row(0);read_row(0);normal_jobs=normal_jobs+1;
                end
            end
            for(integer f=1;f<=4;f=f+1)begin
                reset_system();setup_job(c,40,c ? 'h08001fc0 : 'h08000fe0);write_row(0);read_row(f);fault_jobs=fault_jobs+1;
                if(f==1)begin
                    inject_r=0;clear_faults=1;@(negedge clk);clear_faults=0;
                    setup_job(c,6,'h08000400);write_row(0);read_row(0);normal_jobs=normal_jobs+1;
                end
            end
            reset_system();
        end
        reject_bad('h08000010,4);reject_bad('h08000000,3);reject_bad('h08000000,0);reject_bad('h087fffe0,4);
        setup_job(1,4,'h08000000);write_row(0);read_row(0);normal_jobs=normal_jobs+1;
        $display("C1_R2_RGBX_ROW_PASS stalls=%0d aw_wait_w=%0d outstanding=%0d normal=%0d faults=%0d rejects=%0d physical_ratio=2 snapshot=1 held_response=1 drain=1",STALLS,AW_WAIT_W,OUTSTANDING,normal_jobs,fault_jobs,reject_jobs);
        $finish;
    end
endmodule
