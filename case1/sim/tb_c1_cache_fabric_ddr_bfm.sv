`timescale 1ns/1ps

// Boardless fabric-level regression for the next R1 integration step.
//
// The test is deliberately below the portable-SoC/APB layer so it can run in
// a few thousand cycles and remain independent of board dimensions.  Six
// synthetic frame/control clients and the real tensor client (C8 cache seam
// -> 64/128 bridge) share the real seven-client arbiter.  A byte-addressed
// DDR model at the master port supplies randomized channel back-pressure,
// delayed R/B responses, byte-lane writes, and read-after-write checking.
//
// This is not a replacement for the later full portable-SoC test: it proves
// the exact client-6 contract and gives a small, deterministic memory-fabric
// gate before the 640x480 native artifact is exercised.
module tb_c1_cache_fabric_ddr_bfm;
  localparam integer CLIENTS = 7;
  localparam integer SYNTH_CLIENTS = 6;
  localparam integer CACHE_CLIENT = 6;
  localparam integer CLIENT_TXNS = 3;
  localparam integer MEM_BYTES = 65536;
  localparam logic [31:0] TENSOR_BASE = 32'h0001_0000;
  localparam logic [15:0] TENSOR_W = 16'd4;
  localparam logic [15:0] TENSOR_H = 16'd4;
  localparam logic [3:0]  TENSOR_GROUPS = 4'd1;

  logic clk = 1'b0, rst = 1'b1, go = 1'b0;
  always #5 clk = ~clk;

  // The six synthetic clients are kept separate from the packed arbiter
  // arrays; this avoids multiple procedural drivers on packed-array bits.
  logic [SYNTH_CLIENTS-1:0][31:0] c_awaddr = '0;
  logic [SYNTH_CLIENTS-1:0][7:0]  c_awlen = '0;
  logic [SYNTH_CLIENTS-1:0][2:0]  c_awsize = '0;
  logic [SYNTH_CLIENTS-1:0][1:0]  c_awburst = '0;
  logic [SYNTH_CLIENTS-1:0]       c_awvalid = '0, c_awready;
  logic [SYNTH_CLIENTS-1:0][127:0] c_wdata = '0;
  logic [SYNTH_CLIENTS-1:0][15:0]  c_wstrb = '0;
  logic [SYNTH_CLIENTS-1:0]       c_wlast = '0, c_wvalid = '0, c_wready;
  logic [SYNTH_CLIENTS-1:0][1:0]  c_bresp;
  logic [SYNTH_CLIENTS-1:0]       c_bvalid, c_bready = '0;
  logic [SYNTH_CLIENTS-1:0][31:0] c_araddr = '0;
  logic [SYNTH_CLIENTS-1:0][7:0]  c_arlen = '0;
  logic [SYNTH_CLIENTS-1:0][2:0]  c_arsize = '0;
  logic [SYNTH_CLIENTS-1:0][1:0]  c_arburst = '0;
  logic [SYNTH_CLIENTS-1:0]       c_arvalid = '0, c_arready;
  logic [SYNTH_CLIENTS-1:0][127:0] c_rdata;
  logic [SYNTH_CLIENTS-1:0][1:0]  c_rresp;
  logic [SYNTH_CLIENTS-1:0]       c_rlast, c_rvalid, c_rready = '0;

  logic [CLIENTS-1:0][31:0] s_awaddr;
  logic [CLIENTS-1:0][7:0]  s_awlen;
  logic [CLIENTS-1:0][2:0]  s_awsize;
  logic [CLIENTS-1:0][1:0]  s_awburst;
  logic [CLIENTS-1:0]       s_awvalid, s_awready;
  logic [CLIENTS-1:0][127:0] s_wdata;
  logic [CLIENTS-1:0][15:0]  s_wstrb;
  logic [CLIENTS-1:0]       s_wlast, s_wvalid, s_wready;
  logic [CLIENTS-1:0][1:0]  s_bresp;
  logic [CLIENTS-1:0]       s_bvalid, s_bready;
  logic [CLIENTS-1:0][31:0] s_araddr;
  logic [CLIENTS-1:0][7:0]  s_arlen;
  logic [CLIENTS-1:0][2:0]  s_arsize;
  logic [CLIENTS-1:0][1:0]  s_arburst;
  logic [CLIENTS-1:0]       s_arvalid, s_arready;
  logic [CLIENTS-1:0][127:0] s_rdata;
  logic [CLIENTS-1:0][1:0]  s_rresp;
  logic [CLIENTS-1:0]       s_rlast, s_rvalid, s_rready;

  logic [31:0] m_awaddr;
  logic [7:0]  m_awlen;
  logic [2:0]  m_awsize;
  logic [1:0]  m_awburst;
  logic        m_awvalid, m_awready = 1'b0;
  logic [127:0] m_wdata;
  logic [15:0]  m_wstrb;
  logic         m_wlast, m_wvalid, m_wready = 1'b0;
  logic [1:0]   m_bresp = 2'b00;
  logic         m_bvalid = 1'b0, m_bready;
  logic [31:0]  m_araddr;
  logic [7:0]   m_arlen;
  logic [2:0]   m_arsize;
  logic [1:0]   m_arburst;
  logic         m_arvalid, m_arready = 1'b0;
  logic [127:0] m_rdata = '0;
  logic [1:0]   m_rresp = 2'b00;
  logic         m_rlast = 1'b0, m_rvalid = 1'b0, m_rready;

  // Real tensor cache and 64/128 bridge attached to client 6.
  logic cache_stage_start_valid = 1'b0, cache_stage_start_ready;
  logic cache_stage_done, cache_active, cache_fallback;
  logic [3:0] cache_reason;
  logic cache_abort = 1'b0, cache_abort_done;
  logic cache_flush = 1'b0, cache_flush_done;
  logic cache_s_req_valid = 1'b0, cache_s_req_ready;
  logic cache_s_req_write;
  logic [31:0] cache_s_req_addr;
  logic [63:0] cache_s_req_wdata;
  logic [7:0] cache_s_req_wstrb;
  logic cache_s_req_cacheable;
  logic signed [16:0] cache_s_req_x, cache_s_req_y;
  logic [2:0] cache_s_req_group;
  logic cache_s_rsp_valid, cache_s_rsp_ready = 1'b0, cache_s_rsp_error;
  logic [63:0] cache_s_rsp_rdata;
  logic cache_m_req_valid, cache_m_req_ready, cache_m_req_write;
  logic [31:0] cache_m_req_addr;
  logic [63:0] cache_m_req_wdata;
  logic [7:0] cache_m_req_wstrb;
  logic cache_m_rsp_valid, cache_m_rsp_ready, cache_m_rsp_error;
  logic [63:0] cache_m_rsp_rdata;
  logic cache_error;
  logic [2:0] cache_error_code;
  logic cache_busy, cache_quiescent;

  logic bridge_mem_req_valid, bridge_mem_req_ready, bridge_mem_req_write;
  logic [31:0] bridge_mem_req_addr;
  logic [63:0] bridge_mem_req_wdata;
  logic [7:0] bridge_mem_req_wstrb;
  logic bridge_mem_rsp_valid, bridge_mem_rsp_ready, bridge_mem_rsp_error;
  logic [63:0] bridge_mem_rsp_rdata;
  logic bridge_awvalid, bridge_awready;
  logic [31:0] bridge_awaddr;
  logic [7:0] bridge_awlen;
  logic [2:0] bridge_awsize;
  logic [1:0] bridge_awburst;
  logic bridge_wvalid, bridge_wready, bridge_wlast;
  logic [127:0] bridge_wdata;
  logic [15:0] bridge_wstrb;
  logic bridge_bvalid, bridge_bready;
  logic [1:0] bridge_bresp;
  logic bridge_arvalid, bridge_arready;
  logic [31:0] bridge_araddr;
  logic [7:0] bridge_arlen;
  logic [2:0] bridge_arsize;
  logic [1:0] bridge_arburst;
  logic bridge_rvalid, bridge_rready, bridge_rlast;
  logic [127:0] bridge_rdata;
  logic [1:0] bridge_rresp;

  // The explicit client-6 wrapper owns both the optional seam and the
  // 64->128 bridge.  Keeping this TB on the wrapper proves the same boundary
  // that the portable SoC uses; the earlier direct seam+bridge run remains a
  // useful lower-level diagnostic if a future wrapper change regresses.
  c1_tensor_window_cache_axi_client #(.ENABLE_CACHE(1)) u_cache_client (
      .clk, .rst,
      .stage_start_valid(cache_stage_start_valid),
      .stage_start_ready(cache_stage_start_ready),
      .stage_cache_enable(1'b1), .stage_base_addr(TENSOR_BASE),
      .stage_width(TENSOR_W), .stage_height(TENSOR_H),
      .stage_groups(TENSOR_GROUPS), .stage_start_done(cache_stage_done),
      .stage_cache_active(cache_active), .stage_cache_fallback(cache_fallback),
      .stage_cache_reason(cache_reason), .abort_req(cache_abort),
      .abort_done(cache_abort_done), .flush_req(cache_flush),
      .flush_done(cache_flush_done), .s_req_valid(cache_s_req_valid),
      .s_req_ready(cache_s_req_ready), .s_req_write(cache_s_req_write),
      .s_req_addr(cache_s_req_addr), .s_req_wdata(cache_s_req_wdata),
      .s_req_wstrb(cache_s_req_wstrb), .s_req_cacheable(cache_s_req_cacheable),
      .s_req_cache_x(cache_s_req_x), .s_req_cache_y(cache_s_req_y),
      .s_req_cache_group(cache_s_req_group), .s_rsp_valid(cache_s_rsp_valid),
      .s_rsp_ready(cache_s_rsp_ready), .s_rsp_error(cache_s_rsp_error),
      .s_rsp_rdata(cache_s_rsp_rdata), .m_axi_awvalid(bridge_awvalid),
      .m_axi_awready(bridge_awready), .m_axi_awaddr(bridge_awaddr),
      .m_axi_awlen(bridge_awlen), .m_axi_awsize(bridge_awsize),
      .m_axi_awburst(bridge_awburst), .m_axi_wvalid(bridge_wvalid),
      .m_axi_wready(bridge_wready), .m_axi_wdata(bridge_wdata),
      .m_axi_wstrb(bridge_wstrb), .m_axi_wlast(bridge_wlast),
      .m_axi_bresp(bridge_bresp), .m_axi_bvalid(bridge_bvalid),
      .m_axi_bready(bridge_bready), .m_axi_arvalid(bridge_arvalid),
      .m_axi_arready(bridge_arready), .m_axi_araddr(bridge_araddr),
      .m_axi_arlen(bridge_arlen), .m_axi_arsize(bridge_arsize),
      .m_axi_arburst(bridge_arburst), .m_axi_rdata(bridge_rdata),
      .m_axi_rresp(bridge_rresp), .m_axi_rlast(bridge_rlast),
      .m_axi_rvalid(bridge_rvalid), .m_axi_rready(bridge_rready),
      .cache_error(cache_error), .cache_error_code(cache_error_code),
      .busy(cache_busy), .quiescent(cache_quiescent)
  );

  c1_axi_n_serial_arbiter_128 #(.CLIENTS(CLIENTS)) u_arbiter (
      .clk, .rst, .s_awaddr, .s_awlen, .s_awsize, .s_awburst,
      .s_awvalid, .s_awready, .s_wdata, .s_wstrb, .s_wlast, .s_wvalid,
      .s_wready, .s_bresp, .s_bvalid, .s_bready, .s_araddr, .s_arlen,
      .s_arsize, .s_arburst, .s_arvalid, .s_arready, .s_rdata, .s_rresp,
      .s_rlast, .s_rvalid, .s_rready, .m_awaddr, .m_awlen, .m_awsize,
      .m_awburst, .m_awvalid, .m_awready, .m_wdata, .m_wstrb, .m_wlast,
      .m_wvalid, .m_wready, .m_bresp, .m_bvalid, .m_bready, .m_araddr,
      .m_arlen, .m_arsize, .m_arburst, .m_arvalid, .m_arready,
      .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  // Pack/unpack the six procedural clients and the real bridge as client 6.
  integer pack_i;
  always_comb begin
    s_awaddr = '0; s_awlen = '0; s_awsize = '0; s_awburst = '0;
    s_awvalid = '0; s_wdata = '0; s_wstrb = '0; s_wlast = '0;
    s_wvalid = '0; s_bready = '0; s_araddr = '0; s_arlen = '0;
    s_arsize = '0; s_arburst = '0; s_arvalid = '0; s_rready = '0;
    for (pack_i = 0; pack_i < SYNTH_CLIENTS; pack_i = pack_i + 1) begin
      s_awaddr[pack_i] = c_awaddr[pack_i]; s_awlen[pack_i] = c_awlen[pack_i];
      s_awsize[pack_i] = c_awsize[pack_i]; s_awburst[pack_i] = c_awburst[pack_i];
      s_awvalid[pack_i] = c_awvalid[pack_i]; s_wdata[pack_i] = c_wdata[pack_i];
      s_wstrb[pack_i] = c_wstrb[pack_i]; s_wlast[pack_i] = c_wlast[pack_i];
      s_wvalid[pack_i] = c_wvalid[pack_i]; s_bready[pack_i] = c_bready[pack_i];
      s_araddr[pack_i] = c_araddr[pack_i]; s_arlen[pack_i] = c_arlen[pack_i];
      s_arsize[pack_i] = c_arsize[pack_i]; s_arburst[pack_i] = c_arburst[pack_i];
      s_arvalid[pack_i] = c_arvalid[pack_i]; s_rready[pack_i] = c_rready[pack_i];
    end
    s_awaddr[CACHE_CLIENT] = bridge_awaddr; s_awlen[CACHE_CLIENT] = bridge_awlen;
    s_awsize[CACHE_CLIENT] = bridge_awsize; s_awburst[CACHE_CLIENT] = bridge_awburst;
    s_awvalid[CACHE_CLIENT] = bridge_awvalid; s_wdata[CACHE_CLIENT] = bridge_wdata;
    s_wstrb[CACHE_CLIENT] = bridge_wstrb; s_wlast[CACHE_CLIENT] = bridge_wlast;
    s_wvalid[CACHE_CLIENT] = bridge_wvalid; s_bready[CACHE_CLIENT] = bridge_bready;
    s_araddr[CACHE_CLIENT] = bridge_araddr; s_arlen[CACHE_CLIENT] = bridge_arlen;
    s_arsize[CACHE_CLIENT] = bridge_arsize; s_arburst[CACHE_CLIENT] = bridge_arburst;
    s_arvalid[CACHE_CLIENT] = bridge_arvalid; s_rready[CACHE_CLIENT] = bridge_rready;
  end
  always_comb begin
    c_awready = s_awready[SYNTH_CLIENTS-1:0];
    c_wready = s_wready[SYNTH_CLIENTS-1:0];
    c_bvalid = s_bvalid[SYNTH_CLIENTS-1:0];
    c_bresp = s_bresp[SYNTH_CLIENTS-1:0];
    c_arready = s_arready[SYNTH_CLIENTS-1:0];
    c_rvalid = s_rvalid[SYNTH_CLIENTS-1:0];
    c_rdata = s_rdata[SYNTH_CLIENTS-1:0];
    c_rresp = s_rresp[SYNTH_CLIENTS-1:0];
    c_rlast = s_rlast[SYNTH_CLIENTS-1:0];
    bridge_awready = s_awready[CACHE_CLIENT]; bridge_wready = s_wready[CACHE_CLIENT];
    bridge_bvalid = s_bvalid[CACHE_CLIENT]; bridge_bresp = s_bresp[CACHE_CLIENT];
    bridge_arready = s_arready[CACHE_CLIENT]; bridge_rvalid = s_rvalid[CACHE_CLIENT];
    bridge_rdata = s_rdata[CACHE_CLIENT]; bridge_rresp = s_rresp[CACHE_CLIENT];
    bridge_rlast = s_rlast[CACHE_CLIENT];
  end

  logic [7:0] mem_bytes [0:MEM_BYTES-1];
  function automatic [7:0] seed_byte(input integer unsigned a);
    seed_byte = (a[7:0] ^ (a[15:8] * 8'h1d) ^ 8'h5a);
  endfunction
  function automatic [127:0] mem_read128(input logic [31:0] base);
    integer j; begin
      mem_read128 = '0;
      for (j = 0; j < 16; j = j + 1)
        mem_read128[j*8 +: 8] = mem_bytes[(base[15:0] + j) & 16'hffff];
    end
  endfunction
  function automatic [63:0] mem_read64(input logic [31:0] base);
    integer j; begin
      mem_read64 = '0;
      for (j = 0; j < 8; j = j + 1)
        mem_read64[j*8 +: 8] = mem_bytes[(base[15:0] + j) & 16'hffff];
    end
  endfunction
  function automatic [31:0] client_addr(input integer c, input integer t);
    client_addr = 32'h0000_2000 + (c * 32'h100) + (t * 32'h20);
  endfunction
  function automatic [127:0] client_data(input integer c, input integer t);
    client_data = {32'hc1000000 | c, 32'hd2000000 | t,
                   32'he3000000 | (c << 8) | t, 32'hf40000a5 | c};
  endfunction
  function automatic [31:0] tensor_addr(input integer x, input integer y);
    tensor_addr = TENSOR_BASE + ((y * TENSOR_W + x) * 8);
  endfunction

  integer wr_count = 0, w_count = 0, b_count = 0, ar_count = 0, r_count = 0;
  integer ar_stalls = 0, aw_stalls = 0, w_stalls = 0, r_stalls = 0, b_stalls = 0;
  integer r_gap_cycles = 0, b_gap_cycles = 0;
  integer tensor_ar_count = 0, tensor_logical_reads = 0, tensor_refill_reads = 0;
  integer cache_rsp_count = 0, cache_write_count = 0, cache_error_count = 0;
  integer client_error_count = 0;
  logic [31:0] prng = 32'h91a2_b3c4;
  function automatic [31:0] next_prng(input [31:0] x);
    next_prng = {x[30:0], x[31]^x[21]^x[1]^x[0]};
  endfunction

  logic rd_active = 1'b0, wr_active = 1'b0, b_pending = 1'b0;
  logic [31:0] rd_base_q = '0, wr_base_q = '0;
  logic [7:0] rd_len_q = '0, rd_beat_q = '0, wr_len_q = '0, wr_beat_q = '0;
  integer rd_gap = 0, b_gap = 0;
  integer mem_i;
  logic [31:0] w_eff_addr;
  logic [7:0] w_eff_beat, w_eff_len;

  always @(negedge clk) begin
    if (rst) begin
      m_awready <= 1'b0; m_wready <= 1'b0; m_arready <= 1'b0; prng <= 32'h91a2_b3c4;
    end else begin
      prng <= next_prng(prng);
      m_awready <= prng[0] | prng[4];
      m_wready <= prng[1] | prng[5];
      m_arready <= prng[2] | prng[6];
    end
  end

  // DDR read channel: one outstanding burst, with deterministic R gaps.
  always @(posedge clk) begin
    if (rst) begin
      rd_active <= 1'b0; rd_base_q <= '0; rd_len_q <= '0; rd_beat_q <= '0;
      rd_gap <= 0; m_rvalid <= 1'b0; m_rdata <= '0; m_rresp <= 2'b00; m_rlast <= 1'b0;
      ar_count = 0; r_count = 0;
    end else begin
      if (m_arvalid && !m_arready) ar_stalls = ar_stalls + 1;
      if (m_arvalid && m_arready) begin
        if (rd_active) $fatal(1, "DDR accepted AR while read active");
        rd_active <= 1'b1; rd_base_q <= m_araddr; rd_len_q <= m_arlen; rd_beat_q <= 0;
        rd_gap <= 1 + (prng[10:8]); ar_count = ar_count + 1;
        if ((m_araddr >= TENSOR_BASE) && (m_araddr < TENSOR_BASE + 32'd256)) begin
          tensor_ar_count = tensor_ar_count + 1; tensor_refill_reads = tensor_refill_reads + 1;
        end
      end
      if (m_rvalid && !m_rready) r_stalls = r_stalls + 1;
      if (m_rvalid && m_rready) begin
        m_rvalid <= 1'b0;
        if (rd_beat_q == rd_len_q) rd_active <= 1'b0;
        else begin rd_beat_q <= rd_beat_q + 1'b1; rd_gap <= 1 + prng[13:11]; end
        r_count = r_count + 1;
      end else if (!m_rvalid && rd_active) begin
        if (rd_gap > 0) begin rd_gap <= rd_gap - 1; r_gap_cycles = r_gap_cycles + 1; end
        else begin
          m_rdata <= mem_read128(rd_base_q + (rd_beat_q * 16));
          m_rresp <= 2'b00; m_rlast <= (rd_beat_q == rd_len_q); m_rvalid <= 1'b1;
        end
      end
    end
  end

  // DDR write channels: AW and W are independent; byte strobes are merged
  // into the backing array, then B is delayed and held under back-pressure.
  always @(posedge clk) begin
    if (rst) begin
      wr_active <= 1'b0; wr_base_q <= '0; wr_len_q <= '0; wr_beat_q <= '0;
      b_pending <= 1'b0; b_gap <= 0; m_bvalid <= 1'b0; m_bresp <= 2'b00;
      wr_count = 0; w_count = 0; b_count = 0;
    end else begin
      if (m_awvalid && !m_awready) aw_stalls = aw_stalls + 1;
      if (m_wvalid && !m_wready) w_stalls = w_stalls + 1;
      if (m_bvalid && !m_bready) b_stalls = b_stalls + 1;
      if (m_awvalid && m_awready) begin
        if (wr_active) $fatal(1, "DDR accepted AW while write active");
        wr_active <= 1'b1; wr_base_q <= m_awaddr; wr_len_q <= m_awlen; wr_beat_q <= 0; wr_count = wr_count + 1;
      end
      if (m_wvalid && m_wready) begin
        if (!wr_active && !(m_awvalid && m_awready)) $fatal(1, "DDR W without AW");
        if (wr_active) begin w_eff_addr = wr_base_q; w_eff_beat = wr_beat_q; w_eff_len = wr_len_q; end
        else begin w_eff_addr = m_awaddr; w_eff_beat = 0; w_eff_len = m_awlen; end
        if (m_wlast !== (w_eff_beat == w_eff_len)) $fatal(1, "DDR WLAST mismatch");
        for (mem_i = 0; mem_i < 16; mem_i = mem_i + 1)
          if (m_wstrb[mem_i]) mem_bytes[(w_eff_addr[15:0] + w_eff_beat*16 + mem_i) & 16'hffff] <= m_wdata[mem_i*8 +: 8];
        w_count = w_count + 1;
        if (w_eff_beat == w_eff_len) begin wr_active <= 1'b0; b_pending <= 1'b1; b_gap <= 1 + prng[16:14]; end
        else begin wr_beat_q <= w_eff_beat + 1'b1; wr_active <= 1'b1; end
      end
      if (m_bvalid && m_bready) begin m_bvalid <= 1'b0; b_count = b_count + 1; end
      else if (!m_bvalid && b_pending) begin
        if (b_gap > 0) begin b_gap <= b_gap - 1; b_gap_cycles = b_gap_cycles + 1; end
        else begin m_bvalid <= 1'b1; m_bresp <= 2'b00; b_pending <= 1'b0; end
      end
    end
  end

  integer client_wr_done [0:SYNTH_CLIENTS-1];
  integer client_rd_done [0:SYNTH_CLIENTS-1];
  task automatic drive_client(input integer c);
    integer t; logic [31:0] a; logic [127:0] d;
    begin
      wait(go);
      for (t = 0; t < CLIENT_TXNS; t = t + 1) begin
        a = client_addr(c,t); d = client_data(c,t);
        @(negedge clk); c_awaddr[c] <= a; c_awlen[c] <= 0; c_awsize[c] <= 4; c_awburst[c] <= 1; c_awvalid[c] <= 1;
        forever begin @(posedge clk); if (c_awvalid[c] && c_awready[c]) break; end
        @(negedge clk); c_awvalid[c] <= 0;
        @(negedge clk); c_wdata[c] <= d; c_wstrb[c] <= 16'hffff; c_wlast[c] <= 1; c_wvalid[c] <= 1;
        forever begin @(posedge clk); if (c_wvalid[c] && c_wready[c]) break; end
        @(negedge clk); c_wvalid[c] <= 0; c_wlast[c] <= 0;
        // Hold the response channel closed briefly so the shared arbiter and
        // DDR BFM exercise BVALID/BREADY back-pressure, not only latency.
        @(negedge clk); c_bready[c] <= 0; repeat (12 + (c & 1)) @(negedge clk); c_bready[c] <= 1;
        forever begin @(posedge clk); if (c_bvalid[c] && c_bready[c]) break; end
        if (c_bresp[c] != 0) client_error_count = client_error_count + 1;
        @(negedge clk); c_bready[c] <= 0;
        @(negedge clk); c_araddr[c] <= a; c_arlen[c] <= 0; c_arsize[c] <= 4; c_arburst[c] <= 1; c_arvalid[c] <= 1;
        forever begin @(posedge clk); if (c_arvalid[c] && c_arready[c]) break; end
        @(negedge clk); c_arvalid[c] <= 0; c_rready[c] <= 0; repeat (12 + (t & 1)) @(negedge clk); c_rready[c] <= 1;
        forever begin @(posedge clk); if (c_rvalid[c] && c_rready[c]) break; end
        if (c_rresp[c] != 0 || !c_rlast[c] || c_rdata[c] !== d) begin
          client_error_count = client_error_count + 1;
          $fatal(1, "client %0d readback mismatch t=%0d got=%h exp=%h", c,t,c_rdata[c],d);
        end
        @(negedge clk); c_rready[c] <= 0;
      end
      client_wr_done[c] = 1; client_rd_done[c] = 1;
    end
  endtask

  task automatic cache_req(input logic is_write, input logic cacheable,
                           input logic [31:0] a, input integer x, input integer y,
                           input logic [63:0] wd);
    begin
      @(negedge clk); cache_s_req_write <= is_write; cache_s_req_cacheable <= cacheable;
      cache_s_req_addr <= a; cache_s_req_wdata <= wd; cache_s_req_wstrb <= is_write ? 8'hff : 8'h00;
      cache_s_req_x <= x; cache_s_req_y <= y; cache_s_req_group <= 0; cache_s_req_valid <= 1;
      forever begin @(posedge clk); if (cache_s_req_valid && cache_s_req_ready) break; end
      @(negedge clk); cache_s_req_valid <= 0; cache_s_rsp_ready <= 0; repeat (2) @(negedge clk); cache_s_rsp_ready <= 1;
      forever begin @(posedge clk); if (cache_s_rsp_valid && cache_s_rsp_ready) break; end
      cache_rsp_count = cache_rsp_count + 1;
      if (cache_s_rsp_error) begin cache_error_count = cache_error_count + 1; $fatal(1, "cache response error addr=%h",a); end
      if (is_write) cache_write_count = cache_write_count + 1;
      else begin
        if (cacheable) tensor_logical_reads = tensor_logical_reads + 1;
        if (cache_s_rsp_rdata !== mem_read64(a)) begin
        cache_error_count = cache_error_count + 1;
        $fatal(1, "cache read mismatch addr=%h got=%h exp=%h",a,cache_s_rsp_rdata,mem_read64(a));
        end
      end
      @(negedge clk); cache_s_rsp_ready <= 0;
    end
  endtask

  integer si;
  initial begin
    for (si = 0; si < MEM_BYTES; si = si + 1) mem_bytes[si] = seed_byte(si);
    for (si = 0; si < SYNTH_CLIENTS; si = si + 1) begin client_wr_done[si] = 0; client_rd_done[si] = 0; end
    repeat (8) @(posedge clk); rst = 1'b0; repeat (3) @(posedge clk);
    // Stage configuration is intentionally a small 4x4xC8 window.
    @(negedge clk); cache_stage_start_valid <= 1;
    forever begin @(posedge clk); if (cache_stage_start_valid && cache_stage_start_ready) break; end
    @(negedge clk); cache_stage_start_valid <= 0;
    forever begin @(posedge clk); if (cache_stage_done) break; end
    if (!cache_active || cache_fallback || cache_reason != 0) $fatal(1, "cache stage did not activate reason=%0d",cache_reason);
    go = 1'b1;
    fork
      drive_client(0); drive_client(1); drive_client(2); drive_client(3);
      drive_client(4); drive_client(5);
    join_none
    // Three row misses plus same-row hits, one bypass read/write, and a flush
    // establish both cache reduction and direct-lane correctness.
    cache_req(0,1,TENSOR_BASE+0,0,0,0);
    cache_req(0,1,TENSOR_BASE+8,1,0,0);
    cache_req(0,1,TENSOR_BASE+16,2,0,0);
    cache_req(0,1,TENSOR_BASE+32,0,1,0);
    cache_req(0,1,TENSOR_BASE+56,3,1,0);
    cache_req(0,1,TENSOR_BASE+72,1,2,0);
    cache_req(0,1,TENSOR_BASE+80,2,2,0);
    cache_req(0,1,TENSOR_BASE+72,1,2,0);
    // The bypass address is deliberately outside the configured 4x4 window;
    // it still exercises the bridge's upper 64-bit lane at address[3]=1.
    cache_req(0,0,TENSOR_BASE+16'h1008,0,0,0);
    cache_req(1,0,TENSOR_BASE+16'h1008,0,0,64'h1122_3344_5566_7788);
    cache_req(0,0,TENSOR_BASE+16'h1008,0,0,0);
    @(negedge clk); cache_flush <= 1; @(posedge clk); @(negedge clk); cache_flush <= 0;
    forever begin @(posedge clk); if (cache_flush_done) break; end
    cache_req(0,1,TENSOR_BASE+0,0,0,0);
    wait((client_wr_done[0]+client_wr_done[1]+client_wr_done[2]+client_wr_done[3]+client_wr_done[4]+client_wr_done[5]) == SYNTH_CLIENTS);
    repeat (20) @(posedge clk);
    if (cache_rsp_count != 12 || cache_write_count != 1 || cache_error_count != 0 || client_error_count != 0)
      $fatal(1, "scoreboard mismatch cache_rsp=%0d writes=%0d cache_err=%0d client_err=%0d",cache_rsp_count,cache_write_count,cache_error_count,client_error_count);
    if (tensor_refill_reads <= 0 || tensor_refill_reads >= (tensor_logical_reads * 4) ||
        tensor_ar_count != tensor_refill_reads)
      $fatal(1, "cache did not reduce downstream reads logical=%0d refill=%0d",tensor_logical_reads,tensor_refill_reads);
    if (aw_stalls == 0 || w_stalls == 0 || ar_stalls == 0 || r_gap_cycles == 0 || b_gap_cycles == 0 ||
        r_stalls == 0 || b_stalls == 0)
      $fatal(1, "DDR backpressure coverage missing aw=%0d w=%0d ar=%0d rstall=%0d bstall=%0d rgap=%0d bgap=%0d",aw_stalls,w_stalls,ar_stalls,r_stalls,b_stalls,r_gap_cycles,b_gap_cycles);
    if (!cache_quiescent || cache_busy || !cache_active) $fatal(1, "cache not quiescent at end");
    $display("C1_CACHE_FABRIC_DDR_BFM_PASS clients=%0d client_txns=%0d cache_logical_reads=%0d cache_refill_reads=%0d cache_rsp=%0d writes=%0d axi_aw=%0d axi_w=%0d axi_b=%0d axi_ar=%0d axi_r=%0d aw_stalls=%0d w_stalls=%0d ar_stalls=%0d r_stalls=%0d b_stalls=%0d r_gaps=%0d b_gaps=%0d",CLIENTS,CLIENT_TXNS,tensor_logical_reads,tensor_refill_reads,cache_rsp_count,cache_write_count,wr_count,w_count,b_count,ar_count,r_count,aw_stalls,w_stalls,ar_stalls,r_stalls,b_stalls,r_gap_cycles,b_gap_cycles);
    $finish;
  end
  initial begin #2_000_000; $fatal(1, "cache fabric DDR BFM timeout"); end
endmodule
