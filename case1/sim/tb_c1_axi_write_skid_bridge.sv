`timescale 1ns/1ps
module tb_c1_axi_write_skid_bridge;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic [31:0] s_awaddr='h1000;
    logic [7:0] s_awlen=2;
    logic [2:0] s_awsize=4;
    logic [1:0] s_awburst=1;
    logic s_awvalid=0,s_wvalid=0,s_wlast=0,s_bready=0;
    logic [127:0] s_wdata=0;
    logic [15:0] s_wstrb='hffff;
    wire s_awready,s_wready,s_bvalid;
    wire [1:0] s_bresp;
    wire [31:0] m_awaddr;
    wire [7:0] m_awlen;
    wire [2:0] m_awsize;
    wire [1:0] m_awburst;
    wire m_awvalid,m_wvalid,m_wlast,m_bready;
    wire [127:0] m_wdata;
    wire [15:0] m_wstrb;
    logic m_awready=0,m_wready=0,m_bvalid=0;
    logic [1:0] m_bresp=0;
    integer mode=0,aw=0,w=0,b=0,sb=0,cycle=0,wait_b=0,early_w=0;
    logic held_aw=0,held_w=0;
    logic [44:0] saved_aw;
    logic [144:0] saved_w;
    c1_axi_write_skid_bridge dut (.*);
    always @(negedge clk) begin
        if (mode==0) m_awready=!rst && m_wvalid;
        else if (mode==1) m_awready=!rst && w==3;
        else m_awready=!rst;
        m_wready=!rst && cycle%3!=0 && (mode!=2 || aw==1);
        m_bvalid=!rst && aw==1 && w==3 && wait_b>=12 && b==0;
    end
    always @(posedge clk) begin
        if(rst) begin
            aw=0;w=0;b=0;sb=0;cycle=0;wait_b=0;held_aw=0;held_w=0;
        end else begin
            cycle=cycle+1;
            if(held_aw && (!m_awvalid || saved_aw!=={m_awaddr,m_awlen,m_awsize,m_awburst})) $fatal(1,"AW hold");
            if(held_w && (!m_wvalid || saved_w!=={m_wdata,m_wstrb,m_wlast})) $fatal(1,"W hold");
            held_aw=m_awvalid&&!m_awready;saved_aw={m_awaddr,m_awlen,m_awsize,m_awburst};
            held_w=m_wvalid&&!m_wready;saved_w={m_wdata,m_wstrb,m_wlast};
            if(m_wvalid&&m_wready) begin
                if(aw==0) early_w=early_w+1;
                if(w>=3 || m_wdata!==128'hdc0000+w || m_wstrb!==16'hffff || m_wlast!==(w==2)) $fatal(1,"W mismatch");
                w=w+1;
            end
            if(m_awvalid&&m_awready) begin
                if(aw!=0 || m_awaddr!==32'h1000 || m_awlen!==2 || m_awsize!==4 || m_awburst!==1) $fatal(1,"AW mismatch");
                aw=aw+1;
            end
            if(aw==1&&w==3) wait_b=wait_b+1;
            if(m_bvalid&&m_bready) b=b+1;
            if(s_bvalid&&s_bready) begin
                if(b!=1 || s_bresp!==m_bresp) $fatal(1,"B response mismatch");
                sb=sb+1;
            end
            if(cycle>1000) $fatal(1,"skid deadlock mode=%0d",mode);
        end
    end
    task automatic send_aw;
        begin
            @(negedge clk);s_awvalid=1;
            do @(posedge clk); while(!s_awready);
            @(negedge clk);s_awvalid=0;
        end
    endtask
    task automatic send_w;
        begin
            for(integer p=0;p<3;p=p+1) begin
                @(negedge clk);s_wvalid=1;s_wdata=128'hdc0000+p;s_wlast=(p==2);
                do @(posedge clk); while(!s_wready);
                @(negedge clk);s_wvalid=0;
            end
        end
    endtask
    initial begin
        for(mode=0;mode<3;mode=mode+1) begin
            @(negedge clk);rst=1;s_bready=0;
            repeat(3) @(negedge clk);rst=0;m_bresp=(mode==2)?2'b11:2'b00;
            fork
                begin if(mode==1) repeat(12) @(negedge clk); send_aw(); end
                send_w();
            join
            wait(aw==1&&w==3);
            // B has not arrived yet: WLAST must not free AW admission.
            repeat(5) begin
                @(negedge clk);
                if(s_awready || s_wready || s_bvalid) $fatal(1,"released transaction before B");
            end
            wait(s_bvalid);
            repeat(8) begin
                @(negedge clk);
                if(s_awready || s_wready || !s_bvalid || s_bresp!==m_bresp) $fatal(1,"B hold/ownership");
            end
            s_bready=1;wait(sb==1);@(negedge clk);s_bready=0;
            if(!s_awready||!s_wready||s_bvalid||aw!=1||w!=3||b!=1) $fatal(1,"transaction did not drain");
        end
        // Reset must suppress all six public handshakes immediately, even
        // with active peers; no RAM/reset inference or CDC claim is made.
        rst=1;s_awvalid=1;s_wvalid=1;s_bready=1;
        #1;
        if(s_awready||s_wready||s_bvalid||m_awvalid||m_wvalid||m_bready) $fatal(1,"reset phantom handshake");
        repeat(3) @(negedge clk);s_awvalid=0;s_wvalid=0;s_bready=0;rst=0;
        repeat(3) @(negedge clk);
        if(!s_awready||!s_wready||s_bvalid||m_awvalid||m_wvalid) $fatal(1,"reset recovery");
        if(early_w<3) $fatal(1,"early W missing");
        $display("C1_WRITE_SKID_BRIDGE_PASS transactions=3 beats=9 early_w=%0d response_hold=24 reset=1",early_w);
        $finish;
    end
    initial begin #50000;$fatal(1,"global timeout");end
endmodule
