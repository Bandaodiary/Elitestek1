`timescale 1ns/1ps
// Diagnostic reproducer, not a passing regression or a DUT fix.
module tb_axi_audit_20260910;
  parameter integer SKID = 0;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1;
  reg awvalid = 0, wvalid = 0, arvalid = 0;
  reg rvalid = 0;
  reg awready = 0;
  wire mawvalid, mwvalid, marvalid, mrready;
  wire sawready, swready, sarready, srvalid, srlast;
  wire [1:0] srresp;
  integer aw_count = 0, w_count = 0;
  // Legal subordinate dependency: registered AWREADY waits for WVALID.
  always @(posedge clk) begin
    if (rst) begin
      awready <= 0;
      aw_count <= 0;
      w_count <= 0;
    end else begin
      awready <= mwvalid;
      if (mawvalid && awready) aw_count <= aw_count + 1;
      if (mwvalid) w_count <= w_count + 1;
    end
  end
  c1_axi_n_serial_arbiter_128 #(.CLIENTS(1), .INDEX_W(1),
    .READ_RESPONSE_SKID(SKID)) dut (
    .clk(clk), .rst(rst),
    .s_awaddr(32'h1000), .s_awlen(8'd0), .s_awsize(3'd4),
    .s_awburst(2'd1), .s_awvalid(awvalid), .s_awready(sawready),
    .s_wdata(128'h1234), .s_wstrb(16'hffff), .s_wlast(1'b1),
    .s_wvalid(wvalid), .s_wready(swready), .s_bready(1'b1),
    .s_araddr(32'h2000), .s_arlen(8'd0), .s_arsize(3'd4),
    .s_arburst(2'd1), .s_arvalid(arvalid), .s_arready(sarready),
    .s_rvalid(srvalid), .s_rlast(srlast), .s_rresp(srresp), .s_rready(1'b1),
    .m_awvalid(mawvalid), .m_awready(awready),
    .m_wvalid(mwvalid), .m_wready(1'b1), .m_bvalid(1'b0), .m_bresp(2'd0),
    .m_arvalid(marvalid), .m_arready(1'b1),
    .m_rvalid(rvalid), .m_rdata(128'habcd), .m_rresp(2'd0),
    .m_rlast(1'b0), .m_rready(mrready)
  );
  initial begin
    repeat(3) @(negedge clk);
    rst = 0; arvalid = 1;
    do @(posedge clk); while (!sarready);
    @(negedge clk); arvalid = 0; rvalid = 1;
    do @(posedge clk); while (!srvalid);
    $display("AUDIT_READ skid=%0d injected_rlast=0 observed_rlast=%0d observed_resp=%0d", SKID, srlast, srresp);
    if (SKID == 1 && srlast == 1 && srresp == 0)
      $display("REPRODUCED_RLAST_ERROR_MASKING");
    @(negedge clk); rvalid = 0; rst = 1;
    repeat(3) @(negedge clk);
    rst = 0; awvalid = 1; wvalid = 1;
    repeat(30) @(negedge clk);
    $display("AUDIT_WRITE skid=%0d aw_handshakes=%0d w_handshakes=%0d downstream_awvalid=%0d downstream_wvalid=%0d", SKID, aw_count, w_count, mawvalid, mwvalid);
    if (aw_count == 0 && w_count == 0 && mawvalid && !mwvalid)
      $display("REPRODUCED_AW_W_DEADLOCK");
    $finish;
  end
  initial begin #10000; $fatal(1,"audit watchdog"); end
endmodule
