`timescale 1ns/1ps

// Structural smoke for the optional tensor window-cache branch.  It proves
// that the full portable SoC elaborates with the seam present, all reset
// domains release, and the APB path remains live.  Data-plane traffic remains
// intentionally idle; this is not a dynamic full-frame cache test.
module tb_c1_r1_portable_soc_cache_wiring_smoke;
`ifdef C1_PACKED_AFFINE_CACHE
    localparam integer PACKED_AFFINE_CACHE = 1;
`else
    localparam integer PACKED_AFFINE_CACHE = 0;
`endif
    logic core_clk = 1'b0;
    logic pixel_clk = 1'b0;
    logic camera_clk = 1'b0;
    logic arst_n = 1'b0;

    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [11:0] paddr = 12'd0;
    logic [31:0] pwdata = 32'd0;
    logic [3:0] pstrb = 4'd0;
    logic [31:0] prdata;
    logic pready;
    logic pslverr;
    logic [31:0] observed_data;
    logic m_axi_awvalid, m_axi_wvalid, m_axi_arvalid;

    always #5 core_clk = ~core_clk;
    always #7 pixel_clk = ~pixel_clk;
    always #6 camera_clk = ~camera_clk;

    c1_r1_portable_soc #(
        .ENABLE_TENSOR_WINDOW_CACHE(1),
        // Exercise the production QoS observation boundary in the same
        // compile/elaboration gate while leaving the AXI payload path idle.
        .ENABLE_SHARED_QOS_MONITOR(1),
        .SHARED_QOS_DEADLINE_CYCLES(32'd1000),
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
    ) dut (
        .core_clk(core_clk),
        .pixel_clk(pixel_clk),
        .camera_clk(camera_clk),
        .arst_n(arst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .pstrb(pstrb),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .camera_valid(1'b0),
        .camera_ready(),
        .camera_raw10(10'd0),
        .camera_x('0),
        .camera_y('0),
        .camera_sof(1'b0),
        .camera_eol(1'b0),
        .camera_eof(1'b0),
        .camera_overflow(),
        .video_rgb(),
        .video_de(),
        .video_hsync(),
        .video_vsync(),
        .engine_stage_index(),
        .engine_stage_opcode(),
        .engine_stage_active(),
        .engine_overflow_seen(),
        .system_busy(),
        .m_axi_awaddr(),
        .m_axi_awlen(),
        .m_axi_awsize(),
        .m_axi_awburst(),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(1'b1),
        .m_axi_wdata(),
        .m_axi_wstrb(),
        .m_axi_wlast(),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(1'b1),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(1'b0),
        .m_axi_bready(),
        .m_axi_araddr(),
        .m_axi_arlen(),
        .m_axi_arsize(),
        .m_axi_arburst(),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(1'b1),
        .m_axi_rdata('0),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0),
        .m_axi_rready(),
        .irq()
    );

    task automatic apb_read(
        input logic [11:0] address,
        output logic [31:0] data
    );
        begin
            @(negedge core_clk);
            psel <= 1'b1;
            penable <= 1'b0;
            pwrite <= 1'b0;
            paddr <= address;
            @(negedge core_clk);
            penable <= 1'b1;
            do @(negedge core_clk); while (!pready);
            data = prdata;
            if (pslverr)
                $fatal(1, "APB read at 0x%03x returned PSLVERR", address);
            psel <= 1'b0;
            penable <= 1'b0;
            paddr <= 12'd0;
        end
    endtask

    task automatic apb_write(
        input logic [11:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge core_clk);
            psel <= 1'b1;
            penable <= 1'b0;
            pwrite <= 1'b1;
            paddr <= address;
            pwdata <= data;
            pstrb <= 4'hf;
            @(negedge core_clk);
            penable <= 1'b1;
            do @(negedge core_clk); while (!pready);
            if (pslverr)
                $fatal(1, "APB write at 0x%03x returned PSLVERR", address);
            psel <= 1'b0;
            penable <= 1'b0;
            pwrite <= 1'b0;
            paddr <= 12'd0;
            pwdata <= 32'd0;
            pstrb <= 4'd0;
        end
    endtask

    initial begin
        integer qos_addr;
        repeat (6) @(posedge core_clk);
        arst_n <= 1'b1;
        repeat (8) @(posedge core_clk);

        // These hierarchical references also make elaboration prove that the
        // enabled generate branch and seam instance physically exist.
        if (dut.g_tensor_legacy_client.u_tensor_cache_axi_client.g_cache.u_seam.cache_error !==
            1'b0)
            $fatal(1, "enabled tensor cache seam reported an idle error");
        if (dut.g_tensor_legacy_client.u_tensor_cache_axi_client.g_cache.u_seam.quiescent !==
            1'b1)
            $fatal(1, "enabled tensor cache seam failed to become quiescent");
        if (dut.g_tensor_legacy_client.u_tensor_cache_axi_client.g_cache.u_seam.busy !== 1'b0)
            $fatal(1, "enabled tensor cache seam remained busy while idle");
        if (dut.tensor_cache_stage_start_ready !== 1'b1)
            $fatal(1, "enabled tensor cache seam is not ready while idle");

        apb_read(12'h000, observed_data);
        if (observed_data !== 32'h4331_5254)
            $fatal(1, "CSR ID mismatch: got 0x%08x", observed_data);
        apb_write(12'h098, 32'h0200_0000);
        apb_read(12'h098, observed_data);
        if (observed_data !== 32'h0200_0000)
            $fatal(1, "tensor arena CSR mismatch: got 0x%08x", observed_data);

        // The optional monitor is enabled in this smoke build.  Verify the
        // software-facing aggregate snapshot window is live even before any
        // traffic occurs; all counters must remain zero while STATUS[0]
        // advertises monitor presence.
        apb_read(12'h108, observed_data);
        if (observed_data !== 32'h0000_0001)
            $fatal(1, "QoS status CSR mismatch: got 0x%08x", observed_data);
        for (qos_addr = 12'h10c; qos_addr <= 12'h12c; qos_addr = qos_addr + 4) begin
            apb_read(qos_addr, observed_data);
            if (observed_data !== 32'd0)
                $fatal(1, "idle QoS snapshot CSR %03x is nonzero: 0x%08x",
                       qos_addr, observed_data);
        end

        repeat (20) @(posedge core_clk);
        if (m_axi_awvalid || m_axi_wvalid || m_axi_arvalid)
            $fatal(1, "idle cache-enabled SoC issued a spurious AXI request");
        if (dut.tensor_cache_error !== 1'b0 ||
            dut.tensor_cache_quiescent !== 1'b1)
            $fatal(1, "cache diagnostics changed during idle CSR activity");
        if (dut.g_shared_qos_monitor.u_monitor.frame_count !== 32'd0 ||
            dut.g_shared_qos_monitor.u_monitor.display_underflow_count !== 32'd0 ||
            dut.g_shared_qos_monitor.u_monitor.protocol_error_count !== 32'd0 ||
            dut.g_shared_qos_monitor.u_monitor.monitor_overflow !== 1'b0)
            $fatal(1, "idle QoS monitor accumulated unexpected telemetry");

        // Structural proof for the software-visible external-memory fence.
        // Drive the already-idle cache status only after all behavioral smoke
        // checks; xsim does not necessarily re-evaluate a released procedural
        // output until one of that output's combinational inputs changes.
        force dut.tensor_cache_busy = 1'b1;
        #1;
        if (dut.system_busy !== 1'b1)
            $fatal(1, "tensor cache busy was omitted from system_busy");
        release dut.tensor_cache_busy;

        $display("C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=%08x quiescent=%0b fence=1 qos=1",
                 observed_data, dut.tensor_cache_quiescent);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "cache-enabled portable SoC smoke timeout");
    end
endmodule
