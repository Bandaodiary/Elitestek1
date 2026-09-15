`timescale 1ns/1ps
module tb_c1_axi_protocol_fix;
  parameter integer KIND=0, SKID=0, BYPASS=0;
  reg clk=0, rst=1;
  always #5 clk=~clk;
  reg [31:0] s_awaddr=32'h1000, s_araddr=32'h2000;
  reg [7:0] s_awlen=0, s_arlen=0;
  wire [2:0] s_awsize=3'd4, s_arsize=3'd4;
  wire [1:0] s_awburst=2'd1, s_arburst=2'd1;
  reg s_awvalid=0, s_wvalid=0, s_arvalid=0, s_bready=0, s_rready=0;
  reg [127:0] s_wdata=0;
  wire [15:0] s_wstrb=16'hffff;
  reg s_wlast=0;
  wire s_awready,s_wready,s_bvalid,s_arready,s_rvalid,s_rlast;
  wire [1:0] s_bresp,s_rresp;
  wire [127:0] s_rdata;
  wire [31:0] m_awaddr,m_araddr;
  wire [7:0] m_awlen,m_arlen;
  wire [2:0] m_awsize,m_arsize;
  wire [1:0] m_awburst,m_arburst;
  wire m_awvalid,m_wvalid,m_wlast,m_bready,m_arvalid,m_rready;
  wire [127:0] m_wdata;
  wire [15:0] m_wstrb;
  reg m_awready=0,m_wready=0,m_bvalid=0,m_arready=1,m_rvalid=0,m_rlast=0;
  reg [1:0] m_bresp=0,m_rresp=0;
  reg [127:0] m_rdata=0;
  integer mode=0, beats=1, ticks=0, sa=0, sw=0, da=0, dw=0, db=0, sb=0;
  integer tests=0;
  generate if(KIND==0) begin
    c1_axi_n_serial_arbiter_128 #(.CLIENTS(1),.READ_RESPONSE_SKID(SKID)) dut(
      .clk(clk),.rst(rst),.s_awaddr(s_awaddr),
.m_awaddr(m_awaddr),
.s_awlen(s_awlen),
.m_awlen(m_awlen),
.s_awsize(s_awsize),
.m_awsize(m_awsize),
.s_awburst(s_awburst),
.m_awburst(m_awburst),
.s_awvalid(s_awvalid),
.m_awvalid(m_awvalid),
.s_awready(s_awready),
.m_awready(m_awready),
.s_wdata(s_wdata),
.m_wdata(m_wdata),
.s_wstrb(s_wstrb),
.m_wstrb(m_wstrb),
.s_wlast(s_wlast),
.m_wlast(m_wlast),
.s_wvalid(s_wvalid),
.m_wvalid(m_wvalid),
.s_wready(s_wready),
.m_wready(m_wready),
.s_bresp(s_bresp),
.m_bresp(m_bresp),
.s_bvalid(s_bvalid),
.m_bvalid(m_bvalid),
.s_bready(s_bready),
.m_bready(m_bready),.s_araddr(s_araddr),
.m_araddr(m_araddr),
.s_arlen(s_arlen),
.m_arlen(m_arlen),
.s_arsize(s_arsize),
.m_arsize(m_arsize),
.s_arburst(s_arburst),
.m_arburst(m_arburst),
.s_arvalid(s_arvalid),
.m_arvalid(m_arvalid),
.s_arready(s_arready),
.m_arready(m_arready),
.s_rdata(s_rdata),
.m_rdata(m_rdata),
.s_rresp(s_rresp),
.m_rresp(m_rresp),
.s_rlast(s_rlast),
.m_rlast(m_rlast),
.s_rvalid(s_rvalid),
.m_rvalid(m_rvalid),
.s_rready(s_rready),
.m_rready(m_rready));
  end else if(KIND==1) begin
    c1_axi_n_write_burst_arbiter_128 #(.CLIENTS(1),.EMPTY_AW_BYPASS(BYPASS)) dut(
      .clk(clk),.rst(rst),.s_awaddr(s_awaddr),
.m_awaddr(m_awaddr),
.s_awlen(s_awlen),
.m_awlen(m_awlen),
.s_awsize(s_awsize),
.m_awsize(m_awsize),
.s_awburst(s_awburst),
.m_awburst(m_awburst),
.s_awvalid(s_awvalid),
.m_awvalid(m_awvalid),
.s_awready(s_awready),
.m_awready(m_awready),
.s_wdata(s_wdata),
.m_wdata(m_wdata),
.s_wstrb(s_wstrb),
.m_wstrb(m_wstrb),
.s_wlast(s_wlast),
.m_wlast(m_wlast),
.s_wvalid(s_wvalid),
.m_wvalid(m_wvalid),
.s_wready(s_wready),
.m_wready(m_wready),
.s_bresp(s_bresp),
.m_bresp(m_bresp),
.s_bvalid(s_bvalid),
.m_bvalid(m_bvalid),
.s_bready(s_bready),
.m_bready(m_bready));
  end else begin
    c1_axi2_serial_arbiter_128 dut(.clk(clk),.rst(rst),.s0_awaddr(s_awaddr),
.s1_awaddr(32'd0),
.m_awaddr(m_awaddr),
.s0_awlen(s_awlen),
.s1_awlen(8'd0),
.m_awlen(m_awlen),
.s0_awsize(s_awsize),
.s1_awsize(3'd0),
.m_awsize(m_awsize),
.s0_awburst(s_awburst),
.s1_awburst(2'd0),
.m_awburst(m_awburst),
.s0_awvalid(s_awvalid),
.s1_awvalid(1'd0),
.m_awvalid(m_awvalid),
.s0_awready(s_awready),
.s1_awready(),
.m_awready(m_awready),
.s0_wdata(s_wdata),
.s1_wdata(128'd0),
.m_wdata(m_wdata),
.s0_wstrb(s_wstrb),
.s1_wstrb(16'd0),
.m_wstrb(m_wstrb),
.s0_wlast(s_wlast),
.s1_wlast(1'd0),
.m_wlast(m_wlast),
.s0_wvalid(s_wvalid),
.s1_wvalid(1'd0),
.m_wvalid(m_wvalid),
.s0_wready(s_wready),
.s1_wready(),
.m_wready(m_wready),
.s0_bresp(s_bresp),
.s1_bresp(),
.m_bresp(m_bresp),
.s0_bvalid(s_bvalid),
.s1_bvalid(),
.m_bvalid(m_bvalid),
.s0_bready(s_bready),
.s1_bready(1'd0),
.m_bready(m_bready),
.s0_araddr(s_araddr),
.s1_araddr(32'd0),
.m_araddr(m_araddr),
.s0_arlen(s_arlen),
.s1_arlen(8'd0),
.m_arlen(m_arlen),
.s0_arsize(s_arsize),
.s1_arsize(3'd0),
.m_arsize(m_arsize),
.s0_arburst(s_arburst),
.s1_arburst(2'd0),
.m_arburst(m_arburst),
.s0_arvalid(s_arvalid),
.s1_arvalid(1'd0),
.m_arvalid(m_arvalid),
.s0_arready(s_arready),
.s1_arready(),
.m_arready(m_arready),
.s0_rdata(s_rdata),
.s1_rdata(),
.m_rdata(m_rdata),
.s0_rresp(s_rresp),
.s1_rresp(),
.m_rresp(m_rresp),
.s0_rlast(s_rlast),
.s1_rlast(),
.m_rlast(m_rlast),
.s0_rvalid(s_rvalid),
.s1_rvalid(),
.m_rvalid(m_rvalid),
.s0_rready(s_rready),
.s1_rready(1'd0),
.m_rready(m_rready));
  end endgenerate
  always @(posedge clk) begin
    if(rst) begin
      ticks<=0; sa<=0; sw<=0; da<=0; dw<=0; db<=0; sb<=0;
      m_awready<=0; m_wready<=0; m_bvalid<=0;
    end else begin
      ticks<=ticks+1;
      case(mode)
        0: begin m_awready<=1; m_wready<=(ticks>8); end
        1: begin m_awready<=m_wvalid || (dw>0); m_wready<=1; end
        2: begin m_awready<=1; m_wready<=1; end
        3: begin m_awready<=(dw==beats); m_wready<=1; end
      endcase
      if(s_awvalid && s_awready) sa<=sa+1;
      if(s_wvalid && s_wready) sw<=sw+1;
      if(s_bvalid && s_bready) begin
        if(s_bresp!==0) $fatal(1,"bad write response");
        sb<=sb+1;
      end
      if(m_awvalid && m_awready) begin
        if(da!=0 || m_awaddr!==32'h1000 || m_awlen!==beats-1)
          $fatal(1,"duplicate/incorrect AW");
        da<=da+1;
      end
      if(m_wvalid && m_wready) begin
        if(dw>=beats || m_wdata!==128'h100+dw ||
           m_wlast!==(dw==beats-1) || m_wstrb!==16'hffff)
          $fatal(1,"incorrect/duplicate W kind=%0d beat=%0d",KIND,dw);
        dw<=dw+1;
      end
      if(m_bvalid && m_bready) begin m_bvalid<=0; db<=db+1; end
      else if(da==1 && dw==beats && db==0) m_bvalid<=1;
    end
  end
  task reset_test;
    begin
      @(negedge clk); rst=1; s_awvalid=0; s_wvalid=0; s_arvalid=0;
      s_bready=0; s_rready=0; m_rvalid=0;
      repeat(3) @(negedge clk);
      rst=0;
    end
  endtask
  task write_test(input integer md,input integer nb);
    begin
      reset_test(); mode=md; beats=nb; s_awlen=nb-1;
      s_awvalid=1; s_wvalid=1; s_wdata=128'h100; s_wlast=(nb==1);
      while(sb==0) begin
        @(negedge clk);
        if(sa!=0) s_awvalid=0;
        if(sw==nb) s_wvalid=0;
        else begin s_wdata=128'h100+sw; s_wlast=(sw==nb-1); end
        s_bready=(ticks>20); // Hold B long enough to check no replay.
        if(ticks>120) $fatal(1,"write deadlock kind=%0d mode=%0d",KIND,md);
      end
      if(sa!=1 || sw!=nb || da!=1 || dw!=nb || db!=1)
        $fatal(1,"write accounting");
      tests=tests+1;
    end
  endtask
  task read_test(input integer fault);
    integer count,tx,rx;
    reg last_bit;
    reg [1:0] response;
    reg [130:0] held;
    begin
      reset_test(); s_arlen=3; s_arvalid=1;
      do @(posedge clk); while(!s_arready);
      @(negedge clk); s_arvalid=0;
      count=(fault==2)?1:4;
      fork
        begin
          for(tx=0;tx<count;tx=tx+1) begin
            @(negedge clk);
            m_rdata=128'habc0+tx; m_rvalid=1;
            m_rlast=(fault==2) || ((tx==3) && fault!=1);
            m_rresp=(fault==3)?2'b11:2'b00;
            do @(posedge clk); while(!m_rready);
            @(negedge clk); m_rvalid=0;
          end
        end
        begin
          for(rx=0;rx<count;rx=rx+1) begin
            do @(negedge clk); while(!s_rvalid);
            held={s_rdata,s_rresp,s_rlast};
            repeat(3) begin
              @(negedge clk);
              if(!s_rvalid || {s_rdata,s_rresp,s_rlast}!==held)
                $fatal(1,"stalled R payload changed");
            end
            last_bit=(fault==2) || ((rx==3) && fault!=1);
            response=(fault==3)?2'b11:
              (((fault==1 && rx==3)||fault==2)?2'b10:2'b00);
            if(s_rdata!==128'habc0+rx || s_rlast!==last_bit || s_rresp!==response)
              $fatal(1,"R contract fault=%0d skid=%0d beat=%0d resp=%0d last=%0d",fault,SKID,rx,s_rresp,s_rlast);
            s_rready=1;
            @(posedge clk);
            @(negedge clk); s_rready=0;
          end
        end
      join
      tests=tests+1;
    end
  endtask
  initial begin
    for(integer md=0;md<4;md=md+1) begin write_test(md,1); write_test(md,4); end
    if(KIND==0) for(integer fault=0;fault<4;fault=fault+1) read_test(fault);
    $display("C1_AXI_PROTOCOL_FIX_PASS kind=%0d skid=%0d bypass=%0d tests=%0d",KIND,SKID,BYPASS,tests);
    $finish;
  end
  initial begin #100000; $fatal(1,"watchdog"); end
endmodule

