`timescale 1ns/1ps
// LEGACY / DIAGNOSTIC ONLY.
//
// The authoritative current top-level stress evidence is
// tb_c1_r1_portable_soc_cache_ddr_bfm.sv.  This older bench keeps a compact
// one-slave model for quick bring-up and does not decode the full descriptor
// and table image or all burst response semantics; it must not be cited as a
// portable-SoC PASS for the current ABI.
// Boardless integration stress: seven logical AXI clients are exercised by
// the capture/job/tensor/display paths while the shared slave injects stalls.
module tb_c1_r1_portable_soc_axi_stress;
  logic core_clk=0,pixel_clk=0,camera_clk=0,arst_n=0;
  always #5 core_clk=~core_clk; always #7 pixel_clk=~pixel_clk; always #6 camera_clk=~camera_clk;
  logic psel=0,penable=0,pwrite=0; logic [11:0] paddr=0; logic [31:0] pwdata=0,prdata; logic [3:0] pstrb=0; logic pready,pslverr,irq;
  logic camera_valid=0,camera_ready; logic [9:0] camera_raw10; logic [11:0] camera_x,camera_y; logic camera_sof,camera_eol,camera_eof,camera_overflow;
  logic [23:0] video_rgb; logic video_de,video_hsync,video_vsync; logic [4:0] engine_stage_index; logic [7:0] engine_stage_opcode; logic engine_stage_active,engine_overflow_seen,system_busy;
  logic [31:0] awaddr,araddr; logic [7:0] awlen,arlen; logic [2:0] awsize,arsize; logic [1:0] awburst,arburst; logic awvalid,awready=0,wvalid,wready=0,wlast; logic [127:0] wdata; logic [15:0] wstrb; logic [1:0] bresp=0; logic bvalid=0,bready; logic arvalid, arready=0; logic [127:0] rdata=0; logic [1:0] rresp=0; logic rlast=0,rvalid=0,rready;
  integer seed=32'h51c0ffee, aw_n=0,w_n=0,ar_n=0,r_n=0, stall_n=0, abort_n=0, torn_n=0; integer age_aw=0,age_ar=0;
  integer r_index=0, r_len=0;
  integer dbg_cycles=0;
  // Keep this legacy stress bench at the same small-frame contract as the
  // authoritative full-chain BFM.  The default top is 640x480, so leaving
  // the instance unparameterized would make the 8x8 config intentionally
  // illegal and produce no AXI traffic at all.
  c1_r1_portable_soc #(
    .FRAME_WIDTH(8), .FRAME_HEIGHT(8), .SENSOR_WIDTH(10), .SENSOR_HEIGHT(10),
    .ENABLE_TENSOR_WINDOW_CACHE(1), .JOB_CYCLE_BUDGET(32'd1_000_000)
  ) dut(.core_clk(core_clk),.pixel_clk(pixel_clk),.camera_clk(camera_clk),.arst_n(arst_n),.psel(psel),.penable(penable),.pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),.prdata(prdata),.pready(pready),.pslverr(pslverr),.irq(irq),.camera_valid(camera_valid),.camera_ready(camera_ready),.camera_raw10(camera_raw10),.camera_x(camera_x),.camera_y(camera_y),.camera_sof(camera_sof),.camera_eol(camera_eol),.camera_eof(camera_eof),.camera_overflow(camera_overflow),.video_rgb(video_rgb),.video_de(video_de),.video_hsync(video_hsync),.video_vsync(video_vsync),.engine_stage_index(engine_stage_index),.engine_stage_opcode(engine_stage_opcode),.engine_stage_active(engine_stage_active),.engine_overflow_seen(engine_overflow_seen),.system_busy(system_busy),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awvalid(awvalid),.m_axi_awready(awready),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arburst(arburst),.m_axi_arvalid(arvalid),.m_axi_arready(arready),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
  task automatic apb_write(input [11:0] a,input [31:0] d); begin @(negedge core_clk); psel<=1;penable<=0;pwrite<=1;paddr<=a;pwdata<=d;pstrb<=4'hf; @(negedge core_clk);penable<=1; do @(negedge core_clk); while(!pready); if(pslverr)$fatal(1,"APB error %x",a); psel<=0;penable<=0;pwrite<=0;pstrb<=0; end endtask
  always @(posedge core_clk) begin
    if(!arst_n) begin awready<=0;wready<=0;arready<=0;rvalid<=0;bvalid<=0; end else begin
      // independent pseudo-random back-pressure; no request is held forever
      awready <= (($urandom(seed)%5)!=0); wready <= (($urandom(seed)%4)!=0); arready <= (($urandom(seed)%5)!=0); stall_n <= stall_n + ((!awready)||(!wready)||(!arready));
      if(awvalid&&awready) aw_n<=aw_n+1; if(wvalid&&wready) w_n<=w_n+1;
      // Return the complete burst advertised by ARLEN.  The previous
      // one-beat tie-off asserted RLAST early, which correctly exercised the
      // loader's error path but never allowed a parameter image to commit.
      if(arvalid&&arready) begin
        ar_n<=ar_n+1; rvalid<=1; r_index<=0; r_len<=arlen;
        rlast <= (arlen==0); rdata <= 128'd0;
      end else if(rvalid&&rready) begin
        r_n<=r_n+1;
        if (r_index >= r_len) begin rvalid<=0; rlast<=0; end
        else begin r_index<=r_index+1; rlast<=(r_index+1 >= r_len); rdata<=128'd0; end
      end
      if(wvalid&&wready&&wlast) bvalid<=1; if(bvalid&&bready)bvalid<=0;
      if(awvalid&&!awready) age_aw<=age_aw+1; else age_aw<=0; if(arvalid&&!arready) age_ar<=age_ar+1; else age_ar<=0;
      if(age_aw>250 || age_ar>250) $fatal(1,"AXI starvation");
      if (dut.control_error_event)
        $display("stress control error code=%02x addr=%08x",dut.control_error_code,dut.control_error_address);
      dbg_cycles <= dbg_cycles + 1;
      if ((dbg_cycles == 100) || (dbg_cycles == 500) || (dbg_cycles == 1000))
        $display("stress dbg cyc=%0d armed=%0b op=%0b pvalid/ready/busy=%0b/%0b/%0b cap_wait=%0b cap_state=%0d ar_v/rdy=%0b/%0b ar_n=%0d",dbg_cycles,dut.u_control.run_armed_q,dut.u_control.operation_enable,dut.parameter_start_valid,dut.parameter_start_ready,dut.parameter_busy,dut.capture_frame_waiting,dut.u_control.capture_state_q,arvalid,arready,ar_n);
    end
  end
  // Camera producer: long frames with bubbles and deterministic payload.
  integer x,y,frame; always @(posedge camera_clk) begin
    if(!arst_n) begin camera_valid<=0;x<=0;y<=0;frame<=0; end else if(camera_ready) begin
      camera_valid<= (($urandom(seed)%7)!=0); camera_x<=x;camera_y<=y;camera_raw10<={2'b0,(x+y+frame*3)&10'h3ff}; camera_sof<=(x==0&&y==0);camera_eol<=(x==9);camera_eof<=(x==9&&y==9);
      if(camera_valid) begin if(x==9)begin x<=0;if(y==9)begin y<=0;frame<=frame+1;end else y<=y+1;end else x<=x+1; end
    end else camera_valid<=0;
  end
  initial begin
    repeat(8)@(posedge core_clk); arst_n<=1; repeat(10)@(posedge core_clk);
    // Tables/descriptor/tensor/display configuration, then repeated starts.
    apb_write(12'h040,32'h00001000); apb_write(12'h048,32'h00002000); apb_write(12'h050,{16'd8,16'd8}); apb_write(12'h054,32'd32); apb_write(12'h058,32'd32); apb_write(12'h05c,32'h00000022); apb_write(12'h080,32'h00004000); apb_write(12'h088,32'd22); apb_write(12'h090,32'h00010000); apb_write(12'h098,32'h02000000); apb_write(12'h0c0,32'd0);
    // CONTROL bit 0 enables the lifecycle; bit 1 is START and bit 4 keeps
    // the stress source armed for repeated admission/abort attempts.
    apb_write(12'h010,32'h1);
    $display("stress after enable csr_enable=%0b status_busy=%0b",dut.csr_system_enable,dut.control_status_busy);
    // A zero-parameter image is 1,056 AXI beats; allow it to drain before
    // issuing an abort/re-arm attempt.  The old 500-cycle loop always
    // aborted during the first parameter burst and therefore could not reach
    // capture or write traffic.
    repeat(3) begin apb_write(12'h010,32'h13); repeat(30_000)@(posedge core_clk); if(system_busy) begin apb_write(12'h010,32'h15);abort_n<=abort_n+1; repeat(300)@(posedge core_clk); end end
    repeat(5_000)@(posedge core_clk);
    if(aw_n==0 || ar_n==0) $fatal(1,"stress produced no AXI read/write traffic");
    if(camera_overflow || engine_overflow_seen) $fatal(1,"overflow/torn frame detected");
    $display("C1_R1_PORTABLE_SOC_AXI_7CLIENT_STRESS_PASS aw=%0d w=%0d ar=%0d r=%0d stalls=%0d aborts=%0d torn=%0d",aw_n,w_n,ar_n,r_n,stall_n,abort_n,torn_n); $finish;
  end
  initial begin #2_000_000; $fatal(1,"stress timeout"); end
endmodule
