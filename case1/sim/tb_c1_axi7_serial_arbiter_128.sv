`timescale 1ns/1ps

// Seven-client shared-AXI stress.  This is intentionally below the portable
// SoC/APB layer: it isolates the actual N-way arbiter used by the SoC and
// exercises the concurrency contract without depending on board registers or
// a particular camera-start sequence.
module tb_c1_axi7_serial_arbiter_128;
  localparam integer CLIENTS = 7;
  localparam integer TXNS = 8;
  localparam integer READ_BEATS = 4;
`ifdef C1_READ_RESPONSE_SKID
  localparam integer ARB_READ_RESPONSE_SKID = 1;
`else
  localparam integer ARB_READ_RESPONSE_SKID = 0;
`endif

  logic clk=0, rst=1, go=0;
  always #5 clk=~clk;

  logic [CLIENTS-1:0][31:0] s_awaddr='0;
  logic [CLIENTS-1:0][7:0] s_awlen='0;
  logic [CLIENTS-1:0][2:0] s_awsize='0;
  logic [CLIENTS-1:0][1:0] s_awburst='0;
  logic [CLIENTS-1:0] s_awvalid='0, s_awready;
  logic [CLIENTS-1:0][127:0] s_wdata='0;
  logic [CLIENTS-1:0][15:0] s_wstrb='0;
  logic [CLIENTS-1:0] s_wlast='0, s_wvalid='0, s_wready;
  logic [CLIENTS-1:0][1:0] s_bresp;
  logic [CLIENTS-1:0] s_bvalid, s_bready='0;
  logic [CLIENTS-1:0][31:0] s_araddr='0;
  logic [CLIENTS-1:0][7:0] s_arlen='0;
  logic [CLIENTS-1:0][2:0] s_arsize='0;
  logic [CLIENTS-1:0][1:0] s_arburst='0;
  logic [CLIENTS-1:0] s_arvalid='0, s_arready;
  logic [CLIENTS-1:0][127:0] s_rdata;
  logic [CLIENTS-1:0][1:0] s_rresp;
  logic [CLIENTS-1:0] s_rlast, s_rvalid, s_rready='0;

  logic [31:0] m_awaddr; logic [7:0] m_awlen; logic [2:0] m_awsize; logic [1:0] m_awburst;
  logic m_awvalid, m_awready=0;
  logic [127:0] m_wdata; logic [15:0] m_wstrb; logic m_wlast, m_wvalid, m_wready=0;
  logic [1:0] m_bresp=0; logic m_bvalid=0, m_bready;
  logic [31:0] m_araddr; logic [7:0] m_arlen; logic [2:0] m_arsize; logic [1:0] m_arburst;
  logic m_arvalid, m_arready=0;
  logic [127:0] m_rdata=0; logic [1:0] m_rresp=0; logic m_rlast=0, m_rvalid=0, m_rready;

  integer wr_done[0:CLIENTS-1], rd_done[0:CLIENTS-1];
  integer grant_wr[0:CLIENTS-1], grant_rd[0:CLIENTS-1];
  integer aw_count=0, w_count=0, b_count=0, ar_count=0, r_count=0;
  integer malformed_read_count=0;
  integer aw_stalls=0, ar_stalls=0, b_stalls=0, r_stalls=0;
  integer max_aw_wait=0, max_ar_wait=0, aw_wait[0:CLIENTS-1], ar_wait[0:CLIENTS-1];
  integer wr_owner=-1, wr_txn=-1, rd_owner=-1, rd_txn=-1;
  integer rd_beat=0, client_rd_beat[0:CLIENTS-1];
  logic wr_lock=0, rd_lock=0, b_pending=0, r_pending=0;
  integer b_delay=0, r_delay=0;
  logic parallel_seen=0;
  logic [31:0] prng=32'h7a31_c9e5;

  c1_axi_n_serial_arbiter_128 #(
    .CLIENTS(CLIENTS),
    .READ_RESPONSE_SKID(ARB_READ_RESPONSE_SKID)
  ) dut (
    .clk, .rst,
    .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bresp, .s_bvalid, .s_bready,
    .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arvalid, .s_arready,
    .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
    .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bresp, .m_bvalid, .m_bready,
    .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arvalid, .m_arready,
    .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  function automatic [31:0] next_prng(input [31:0] x);
    next_prng = {x[30:0], x[31]^x[21]^x[1]^x[0]};
  endfunction
  function automatic [31:0] wr_addr(input integer c,input integer t);
    wr_addr = 32'h1000_0000 + (c<<20) + (t<<8) + 32'h40;
  endfunction
  function automatic [31:0] rd_addr(input integer c,input integer t);
    rd_addr = 32'h4000_0000 + (c<<20) + (t<<8) + 32'h80;
  endfunction
  function automatic [127:0] wr_data(input integer c,input integer t);
    wr_data = {32'hA5000000|c,32'hB6000000|t,32'hC7000000|(c<<8)|t,32'hD8000000};
  endfunction
  function automatic [127:0] rd_data(input integer c,input integer t,input integer b);
    rd_data = {32'h51000000|c,32'h62000000|t,
               32'h73000000|(c<<8)|t,32'h84000000|b};
  endfunction

  task automatic fail(input string msg);
    begin
      $display("C1_AXI7_SERIAL_ARBITER_FAIL time=%0t aw=%0d w=%0d b=%0d ar=%0d r=%0d: %s",$time,aw_count,w_count,b_count,ar_count,r_count,msg);
      $fatal(1);
    end
  endtask

  initial begin
    integer k;
    for(k=0;k<CLIENTS;k=k+1) begin wr_done[k]=0; rd_done[k]=0; grant_wr[k]=0; grant_rd[k]=0; aw_wait[k]=0; ar_wait[k]=0; client_rd_beat[k]=0; end
    repeat(8) @(posedge clk); rst=0; @(negedge clk); go=1;
  end

  // Randomized slave readiness and response generation.  Ready is changed at
  // falling edges, while all handshakes are observed at rising edges.
  always @(negedge clk) begin
    integer k;
    if(rst) begin
      m_awready<=0; m_wready<=0; m_arready<=0;
      for(k=0;k<CLIENTS;k=k+1) begin s_bready[k]<=0; s_rready[k]<=0; end
      prng<=32'h7a31_c9e5;
    end else begin
      prng<=next_prng(prng);
      m_awready<=prng[0]|prng[4];
      m_wready<=prng[1]^prng[5];
      m_arready<=prng[2]|prng[6];
      for(k=0;k<CLIENTS;k=k+1) begin
        s_bready[k]<=prng[(k+3)%16];
        s_rready[k]<=prng[(k+9)%16];
      end
    end
  end

  // Downstream scoreboard and one-beat response BFM.
  always @(posedge clk) begin
    integer c;
    integer decoded;
    if(rst) begin
      m_bvalid<=0; m_rvalid<=0; b_pending<=0; r_pending<=0; wr_lock<=0; rd_lock<=0;
      aw_count=0;w_count=0;b_count=0;ar_count=0;r_count=0;
    end else begin
      if(m_awvalid && !m_awready) aw_stalls=aw_stalls+1;
      if(m_arvalid && !m_arready) ar_stalls=ar_stalls+1;
      if(m_bvalid && !m_bready) b_stalls=b_stalls+1;

      if(m_awvalid && m_awready) begin
        if(wr_lock) fail("new AW before prior write completed");
        decoded=(m_awaddr-32'h1000_0000)>>20;
        if(decoded<0 || decoded>=CLIENTS || m_awaddr!==wr_addr(decoded,(m_awaddr>>8)&8'hff)) fail("AW owner/address mismatch");
        wr_owner=decoded; wr_txn=(m_awaddr>>8)&8'hff; wr_lock=1; grant_wr[decoded]=grant_wr[decoded]+1; aw_count=aw_count+1;
      end
      if(m_wvalid && m_wready) begin
        if(!wr_lock || m_wdata!==wr_data(wr_owner,wr_txn) || !m_wlast) fail("W payload/lock mismatch");
        w_count=w_count+1; wr_lock=0; b_pending=1; b_delay=1+(prng[11:9]);
      end
      if(m_bvalid && m_bready) begin b_count=b_count+1; m_bvalid<=0; end
      else if(!m_bvalid && b_pending) begin
        if(b_delay==0) begin m_bvalid<=1; m_bresp<=0; b_pending=0; end else b_delay=b_delay-1;
      end
      if(m_bvalid) begin
        if(wr_owner<0 || !s_bvalid[wr_owner] || s_bresp[wr_owner]!==m_bresp) fail("B response routing mismatch");
      end

      if(m_arvalid && m_arready) begin
        if(rd_lock) fail("new AR before prior read completed");
        decoded=(m_araddr-32'h4000_0000)>>20;
        if(decoded<0 || decoded>=CLIENTS || m_araddr!==rd_addr(decoded,(m_araddr>>8)&8'hff)) fail("AR owner/address mismatch");
        if(m_arlen!==(READ_BEATS-1)) fail("ARLEN mismatch");
        rd_owner=decoded; rd_txn=(m_araddr>>8)&8'hff; rd_beat=0;
        client_rd_beat[decoded]=0; rd_lock=1;
        grant_rd[decoded]=grant_rd[decoded]+1; ar_count=ar_count+1;
        r_pending=1; r_delay=1+(prng[15:13]);
        m_rdata<=rd_data(decoded,rd_txn,0); m_rresp<=0;
        m_rlast<=(READ_BEATS==1) &&
                 !((ARB_READ_RESPONSE_SKID!=0) && (decoded==0) && (rd_txn==0));
      end
      if(m_rvalid && m_rready) begin
        r_count=r_count+1;
        if(rd_beat==READ_BEATS-1) begin
          m_rvalid<=0; rd_lock=0;
        end else begin
          rd_beat=rd_beat+1;
          m_rdata<=rd_data(rd_owner,rd_txn,rd_beat);
          // In skid mode, omit the physical RLAST on one directed burst.
          // The arbiter retires ownership at the captured length but must
          // preserve missing RLAST and report SLVERR, not repair it to OKAY.
          m_rlast<=(rd_beat==READ_BEATS-1) &&
                   !((ARB_READ_RESPONSE_SKID!=0) &&
                     (rd_owner==0) && (rd_txn==0));
          // Keep VALID asserted to cover a full-rate downstream burst and
          // the skid consume-and-replace path.
          m_rvalid<=1;
        end
      end
      else if(!m_rvalid && r_pending) begin
        if(r_delay==0) begin m_rvalid<=1; r_pending=0; end else r_delay=r_delay-1;
      end
      // READ_RESPONSE_SKID=1 intentionally separates the downstream and
      // client-side handshakes.  Validate routing at the actual client
      // boundary and count client backpressure there instead of requiring
      // m_rvalid and s_rvalid in the same cycle.
      for(c=0;c<CLIENTS;c=c+1) begin
        if(s_rvalid[c]) begin
          if(c!=rd_owner ||
             s_rdata[c]!==rd_data(rd_owner,rd_txn,client_rd_beat[c]) ||
             s_rlast[c]!=((client_rd_beat[c]==READ_BEATS-1) &&
               !((ARB_READ_RESPONSE_SKID!=0) && c==0 && rd_txn==0)))
            fail("R response routing mismatch");
          if ((ARB_READ_RESPONSE_SKID!=0) && c==0 && rd_txn==0 &&
              client_rd_beat[c]==READ_BEATS-1) begin
            if(s_rresp[c]!==2'b10) fail("missing RLAST error was masked");
            if(s_rready[c]) malformed_read_count=malformed_read_count+1;
          end else if(s_rresp[c]!==2'b00) fail("unexpected read error");
          if(!s_rready[c]) r_stalls=r_stalls+1;
          if(s_rready[c]) client_rd_beat[c]=client_rd_beat[c]+1;
        end
      end
      if((m_awvalid||m_wvalid||m_bvalid)&&(m_arvalid||m_rvalid)) parallel_seen=1;

      for(c=0;c<CLIENTS;c=c+1) begin
        if(s_awvalid[c]&&!s_awready[c]) begin aw_wait[c]=aw_wait[c]+1; if(aw_wait[c]>max_aw_wait)max_aw_wait=aw_wait[c]; end else aw_wait[c]=0;
        if(s_arvalid[c]&&!s_arready[c]) begin ar_wait[c]=ar_wait[c]+1; if(ar_wait[c]>max_ar_wait)max_ar_wait=ar_wait[c]; end else ar_wait[c]=0;
      end
    end
  end

  task automatic drive_write(input integer c);
    integer t; begin
      wait(go);
      for(t=0;t<TXNS;t=t+1) begin
        @(negedge clk); #1; s_awaddr[c]=wr_addr(c,t); s_awlen[c]=0; s_awsize[c]=4; s_awburst[c]=1; s_awvalid[c]=1;
        while(!s_awready[c]) begin @(negedge clk); #1; end
        @(posedge clk); @(negedge clk); s_awvalid[c]=0;
        @(negedge clk); #1; s_wdata[c]=wr_data(c,t); s_wstrb[c]=16'hffff; s_wlast[c]=1; s_wvalid[c]=1;
        while(!s_wready[c]) begin @(negedge clk); #1; end
        @(posedge clk); @(negedge clk); s_wvalid[c]=0; s_wlast[c]=0;
        while(!(s_bvalid[c]&&s_bready[c])) begin @(negedge clk); #1; end
        @(posedge clk);
      end
      wr_done[c]=1;
    end
  endtask
  task automatic drive_read(input integer c);
    integer t; begin
      wait(go);
      for(t=0;t<TXNS;t=t+1) begin
        @(negedge clk); #1; s_araddr[c]=rd_addr(c,t); s_arlen[c]=READ_BEATS-1; s_arsize[c]=4; s_arburst[c]=1; s_arvalid[c]=1;
        while(!s_arready[c]) begin @(negedge clk); #1; end
        @(posedge clk); @(negedge clk); s_arvalid[c]=0;
        while(client_rd_beat[c] < READ_BEATS) begin @(negedge clk); #1; end
      end
      rd_done[c]=1;
    end
  endtask

  genvar g;
  generate for(g=0;g<CLIENTS;g=g+1) begin : CLIENTS_GEN
    initial drive_write(g);
    initial drive_read(g);
  end endgenerate

  initial begin
    integer k;
    wait(!rst);
    wait((wr_done[0]+wr_done[1]+wr_done[2]+wr_done[3]+wr_done[4]+wr_done[5]+wr_done[6])==CLIENTS);
    wait((rd_done[0]+rd_done[1]+rd_done[2]+rd_done[3]+rd_done[4]+rd_done[5]+rd_done[6])==CLIENTS);
    repeat(12) @(posedge clk);
    for(k=0;k<CLIENTS;k=k+1) begin
      if(grant_wr[k]!==TXNS || grant_rd[k]!==TXNS) fail("round-robin starvation or duplication");
    end
    if(aw_count!==CLIENTS*TXNS || w_count!==aw_count || b_count!==aw_count ||
       ar_count!==CLIENTS*TXNS || r_count!==ar_count*READ_BEATS)
      fail("final transaction counts mismatch");
    if(aw_stalls==0 || ar_stalls==0 || b_stalls==0 || r_stalls==0) fail("stall coverage missing");
    if(!parallel_seen) fail("read/write directions never overlapped");
    if(malformed_read_count != ((ARB_READ_RESPONSE_SKID!=0)?1:0))
      fail("malformed read response count mismatch");
    $display("C1_R1_AXI7_SERIAL_ARBITER_STRESS_PASS clients=%0d write_txns=%0d read_bursts=%0d read_beats=%0d aw_stalls=%0d ar_stalls=%0d b_stalls=%0d r_stalls=%0d max_aw_wait=%0d max_ar_wait=%0d parallel=1",CLIENTS,aw_count,ar_count,r_count,aw_stalls,ar_stalls,b_stalls,r_stalls,max_aw_wait,max_ar_wait);
    $finish;
  end
  initial begin
    #2_000_000;
    $display("AXI7_DBG wr_state=%0d wr_owner=%0d rd_state=%0d rd_owner=%0d m_awvalid=%b m_awready=%b m_wvalid=%b m_wready=%b m_bvalid=%b m_bready=%b s_awvalid=%b s_wvalid=%b s_bvalid=%b s_bready=%b", dut.wr_state_q, dut.wr_owner_q, dut.rd_state_q, dut.rd_owner_q, m_awvalid,m_awready,m_wvalid,m_wready,m_bvalid,m_bready,s_awvalid,s_wvalid,s_bvalid,s_bready);
    fail("global timeout/deadlock");
  end
endmodule
