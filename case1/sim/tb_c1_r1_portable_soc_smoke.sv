`timescale 1ns/1ps

// Structural smoke test for the complete board-independent R1 composition.
// It deliberately keeps all data-plane producers idle: the purpose is to
// prove that every portable RTL block compiles/elaborates together, all three
// reset domains release, and the APB control path remains reachable.
module tb_c1_r1_portable_soc_smoke #(
    parameter bit QUEUED_WRITE=0,
    parameter bit FATAL_TICKET=0,
    parameter bit PREVIEW_CAPTURE=0,
    parameter integer PREVIEW_BAD_ALLOC=0,
    parameter bit PREVIEW_DISPLAY=0,
    parameter integer QOS_WIDTH=24,
    parameter logic [31:0] QOS_DEADLINE=0,
    parameter logic [31:0] EXPECT_QOS_DEADLINE=0,
    parameter bit CAMERA_READY_VALID_SOURCE=0,
    parameter bit EXPLICIT_RECOVERY=0,
    parameter integer CACHE_DW_WEIGHT_TILES=0,
    parameter integer MAC_PREFETCH_OVERLAP=0,
    parameter integer PREFETCH_NEXT_TAP_ADDRESS=0,
    parameter bit COLUMN_READS=0,
    parameter bit SCALAR_READ_CACHE=0, PRECISE_INVALIDATION=0, PACKED_TENSOR_WRITES=0,
    parameter bit VIRTUAL_UPSAMPLE=0,
    parameter bit STREAM_DW=0,
    parameter bit COLUMN_WRITE_OVERLAP=0, PIPE_RESULT_WRITES=0,
    parameter bit POINTWISE_COLUMNS=0,
    parameter bit COLUMN_RESPONSE_BYPASS=0, COLUMN_LOOKUP_READS=0,
    parameter bit PIXEL_PREFETCH=0, SOURCE_PIPELINE=0, POINTWISE_REDUCTION=0,
    parameter bit REQUANT_OVERLAP=0, ALL_PIXEL_GROUPS=0, DOT_PIXELS=0,
    parameter integer WRITE_OUTSTANDING=1,
    parameter integer PIXEL_BATCH=1, WRITE_BUILD_TIMEOUT=8, WRITE_END=0,
    parameter bit DW_PIXELS=0, ALL_DOT_GROUPS=0, PACK_RGB=0, ELIDE_VIEWS=0,
    parameter bit COLUMN_ROW_MAP=0, FUSE_FINAL=0, DW_FRAME=0,
    parameter integer REFILL_WINDOW=16,
    parameter integer READ_CACHE_ENTRIES=1,
    parameter bit REFILL_HANDOFF=0
);
`ifdef C1_PACKED_AFFINE_CACHE
    localparam integer PACKED_AFFINE_CACHE = 1;
`else
    localparam integer PACKED_AFFINE_CACHE = 0;
`endif
    logic core_clk = 1'b0;
    logic pixel_clk = 1'b0;
    logic camera_clk = 1'b0;
    logic arst_n = 1'b0;
    logic recovery_request=0,source_quiescent=0;
    wire recovery_ready,recovery_busy,recovery_done;

    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [11:0] paddr = 12'd0;
    logic [31:0] pwdata = 32'd0;
    logic [3:0] pstrb = 4'd0;
    logic [31:0] prdata;
    logic pready;
    logic pslverr;

    logic camera_ready;
    logic camera_overflow;
    logic [23:0] video_rgb;
    logic video_de;
    logic video_hsync;
    logic video_vsync;
    logic [31:0] observed_id;
    logic [31:0] observed_tensor;
    logic m_axi_awvalid, m_axi_wvalid, m_axi_arvalid;
    logic inject_b=0;wire m_axi_bready;

    always #5 core_clk = ~core_clk;
    always #7 pixel_clk = ~pixel_clk;
    always #6 camera_clk = ~camera_clk;

    c1_r1_portable_soc #(
        .TENSOR_WRITE_OUTSTANDING(WRITE_OUTSTANDING),
        .PIPELINE_DW_PIXELS(DW_PIXELS),
        .STREAM_DW_FRAME(DW_FRAME),
        .PIPELINE_ALL_DOT_GROUPS(ALL_DOT_GROUPS),
        .PACK_RGB_CONV_REDUCTION(PACK_RGB),
        .ELIDE_VIRTUAL_UPSAMPLE(ELIDE_VIEWS),
        .PIXEL_WRITE_BATCH_WORDS(PIXEL_BATCH),.TENSOR_WRITE_BUILD_TIMEOUT(WRITE_BUILD_TIMEOUT),
        .USE_TENSOR_WRITE_END(WRITE_END),
        .ENABLE_TENSOR_COLUMN_READS(COLUMN_READS),
        .TENSOR_BURST_SCHED_MAX_OUTSTANDING(REFILL_WINDOW),
        .TENSOR_BURST_SCHED_REQ_HANDOFF(REFILL_HANDOFF),
        .TENSOR_SCALAR_READ_BEAT_CACHE(SCALAR_READ_CACHE),
        .TENSOR_SCALAR_READ_CACHE_ENTRIES(READ_CACHE_ENTRIES),
        .TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION(PRECISE_INVALIDATION),
        .VIRTUAL_UPSAMPLE_TENSORS(VIRTUAL_UPSAMPLE),
        .ENABLE_TENSOR_PACKED_WRITES(PACKED_TENSOR_WRITES),
        .CACHE_DW_WEIGHT_TILES(CACHE_DW_WEIGHT_TILES),
        .STREAM_DW_GROUPS(STREAM_DW),
        .OVERLAP_COLUMN_WRITEBACK(COLUMN_WRITE_OVERLAP),
        .POINTWISE_COLUMN_READS(POINTWISE_COLUMNS),
        .PREFETCH_NEXT_PIXEL_COLUMN(PIXEL_PREFETCH),
        .PREFETCH_ALL_PIXEL_GROUPS(ALL_PIXEL_GROUPS),
        .PIPELINED_SOURCE_WRITES(SOURCE_PIPELINE),
        .STREAM_POINTWISE_REDUCTION(POINTWISE_REDUCTION),
        .OVERLAP_MAC_REQUANTIZATION(REQUANT_OVERLAP),
        .PIPELINE_DOT_PIXELS(DOT_PIXELS),
        .TENSOR_COLUMN_RESPONSE_BYPASS(COLUMN_RESPONSE_BYPASS),
        .TENSOR_COLUMN_REUSE_ROW_MAP(COLUMN_ROW_MAP),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL),
        .TENSOR_COLUMN_READ_ON_LOOKUP(COLUMN_LOOKUP_READS),
        .PIPELINED_RESULT_WRITES(PIPE_RESULT_WRITES),
        .MAC_PREFETCH_OVERLAP(MAC_PREFETCH_OVERLAP),
        .PREFETCH_NEXT_TAP_ADDRESS(PREFETCH_NEXT_TAP_ADDRESS),
        .CAMERA_READY_VALID_SOURCE(CAMERA_READY_VALID_SOURCE),
        .ENABLE_EXPLICIT_CAPTURE_RECOVERY(EXPLICIT_RECOVERY),
        .DISPLAY_RESIZED_PREVIEW(PREVIEW_DISPLAY),
        .ENABLE_PREVIEW_CAPTURE(PREVIEW_CAPTURE),
        .PREVIEW_BUFFER0_BASE(32'h0800_0000),
        .PREVIEW_BUFFER1_BASE(PREVIEW_BAD_ALLOC==1 ? 32'h0800_0000 :
                             PREVIEW_BAD_ALLOC==2 ? 32'h07f0_0000 :
                             PREVIEW_BAD_ALLOC==3 ? 32'hffff_0000 :
                             PREVIEW_BAD_ALLOC==4 ? 32'h0840_0004 : 32'h0840_0000),
        .PREVIEW_REGION_BEGIN(33'h0800_0000),.PREVIEW_REGION_END(33'h0900_0000),
        .FABRIC_WRITE_FIFO_DEPTH(QUEUED_WRITE ? 4 : 0),
        .FABRIC_WRITE_W_AHEAD_OF_B(QUEUED_WRITE),
        .FABRIC_WRITE_EMPTY_AW_BYPASS(QUEUED_WRITE),
        .ENABLE_SHARED_QOS_MONITOR(QUEUED_WRITE),
        .SHARED_QOS_COUNTER_W(QOS_WIDTH),
        .SHARED_QOS_DEADLINE_CYCLES(QOS_DEADLINE),
        .REGISTER_FATAL_TICKET(FATAL_TICKET),
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
    ) dut (
        .capture_recovery_request(recovery_request),.capture_source_quiescent(source_quiescent),
        .capture_recovery_ready(recovery_ready),.capture_recovery_busy(recovery_busy),
        .capture_recovery_done(recovery_done),
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
        .camera_ready(camera_ready),
        .camera_raw10(10'd0),
        .camera_x('0),
        .camera_y('0),
        .camera_sof(1'b0),
        .camera_eol(1'b0),
        .camera_eof(1'b0),
        .camera_overflow(camera_overflow),

        .video_rgb(video_rgb),
        .video_de(video_de),
        .video_hsync(video_hsync),
        .video_vsync(video_vsync),

        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_arvalid(m_axi_arvalid),

        .m_axi_awready(1'b1),
        .m_axi_wready(1'b1),
        .m_axi_bresp(2'b00),
        .m_axi_bvalid(inject_b),.m_axi_bready(m_axi_bready),
        .m_axi_arready(1'b1),
        .m_axi_rdata('0),
        .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0)
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
            if (pslverr) begin
                $fatal(1, "APB read at 0x%03x returned PSLVERR", address);
            end
            psel <= 1'b0;
            penable <= 1'b0;
            paddr <= 12'd0;
        end
    endtask

    task automatic apb_write(
        input logic [11:0] address,
        input logic [31:0] data,
        input bit expect_error = 1'b0,
        input logic [3:0] strobes = 4'hf,
        input bit simultaneous_hardware_request = 0
    );
        begin
            @(negedge core_clk);
            psel <= 1'b1;
            penable <= 1'b0;
            pwrite <= 1'b1;
            paddr <= address;
            pwdata <= data;
            pstrb <= strobes;
            @(negedge core_clk);
            penable <= 1'b1;
            if(simultaneous_hardware_request) recovery_request<=1;
            do @(posedge core_clk); while (!pready);
            if(simultaneous_hardware_request &&
               (!dut.capture_recovery_accept || dut.csr_capture_recovery_request))
                $fatal(1,"same-edge hardware/software recovery arbitration failed");
            if (pslverr !== expect_error)
                $fatal(1, "APB write at 0x%03x data=%08x busy=%b PSLVERR=%b expected=%b", address,data,dut.control_status_busy,pslverr,expect_error);
            @(negedge core_clk);
            psel <= 1'b0;
            penable <= 1'b0;
            pwrite <= 1'b0;
            paddr <= 12'd0;
            pwdata <= 32'd0;
            pstrb <= 4'd0;
            if(simultaneous_hardware_request) recovery_request<=0;
        end
    endtask

    initial begin
        repeat (6) @(posedge core_clk);
        arst_n <= 1'b1;
        repeat (8) @(posedge core_clk);
        apb_read(12'h008,observed_id);
        if(observed_id[16]!==EXPLICIT_RECOVERY) $fatal(1,"recovery capability mismatch");
        if(EXPLICIT_RECOVERY) begin
            @(negedge core_clk);recovery_request=1;
            repeat(12) begin
                @(negedge core_clk);
                if(!recovery_busy || !dut.system_busy || recovery_done ||
                   dut.u_capture.u_frontend.recovery_core_reset ||
                   !dut.u_control.input_region_cancel_hold_q)
                    $fatal(1,"SoC recovery failed admission/ownership fence while source unconfirmed");
            end
            apb_write(12'h010,32'h13,1'b1);
            @(negedge core_clk);source_quiescent=1;
            wait(recovery_done);
            repeat(24) @(negedge core_clk);
            if(recovery_busy || recovery_ready || dut.system_busy ||
               dut.u_control.input_region_cancel_hold_q ||
               m_axi_arvalid || m_axi_awvalid || m_axi_wvalid)
                $fatal(1,"SoC recovery retriggered or did not release after complete flush");
            recovery_request=0;
            @(negedge core_clk);if(!recovery_ready) $fatal(1,"SoC recovery did not rearm");
            $display("C1_SOC_EXPLICIT_RECOVERY_SMOKE_PASS queued=%0d ticket=%0d start_rejected=1 source_ack_wait=12 held_request_once=1",QUEUED_WRITE,FATAL_TICKET);
            apb_read(12'h134,observed_id);
            if(observed_id!==32'h1b) $fatal(1,"hardware recovery completion not sticky in APB");
            apb_write(12'h134,0,1);
            apb_write(12'h130,3,1);
            apb_write(12'h130,4,1);
            apb_write(12'h130,2);
            apb_read(12'h134,observed_id);
            if(observed_id!==32'h13) $fatal(1,"recovery done acknowledge failed");
            source_quiescent=0;
            apb_write(12'h130,32'hffffffff,0,0);
            apb_write(12'h130,1,0,4'h2);
            if(recovery_busy) $fatal(1,"masked recovery write started a flush");
            apb_write(12'h130,32'h100,1,4'h2);
            apb_write(12'h130,1);
            repeat(8) @(negedge core_clk);
            apb_read(12'h134,observed_id);
            if(observed_id!==32'h5 || !dut.system_busy)
                $fatal(1,"software recovery failed to wait for hardware source ACK");
            apb_write(12'h130,1,1);
            apb_write(12'h010,32'h13,1);
            @(negedge core_clk);source_quiescent=1;
            wait(recovery_done);
            repeat(24) @(negedge core_clk);
            apb_read(12'h134,observed_id);
            if(observed_id!==32'h1b || dut.system_busy)
                $fatal(1,"software recovery completion/status failed");
            $display("C1_SOC_APB_RECOVERY_PASS queued=%0d ticket=%0d",QUEUED_WRITE,FATAL_TICKET);
            source_quiescent=0;
            apb_write(12'h130,1,1,4'hf,1);
            repeat(8) @(negedge core_clk);
            if(!recovery_busy || !dut.system_busy)
                $fatal(1,"winning hardware recovery disappeared");
            source_quiescent=1;
            wait(recovery_done);
            repeat(24) @(negedge core_clk);
            if(recovery_busy || !recovery_ready || dut.system_busy)
                $fatal(1,"arbitrated recovery failed to retire");
            $display("C1_SOC_APB_RECOVERY_RACE_PASS hardware_wins=1 software_rejected=1");
        end else begin
            apb_write(12'h130,1,1);
            apb_write(12'h134,0,1);
        end

        // Check pending offers before a clock edge can grant them. This is
        // combinational boundary verification, not an AXI transaction test.
        @(negedge core_clk);force dut.axi_s_arvalid='1;
        #1;if(!dut.fabric_read_quiescent || dut.u_control.fabric_read_quiescent!==1'b0)
            $fatal(1,"ungranted AR missing from drain qualification");
        release dut.axi_s_arvalid;
        @(negedge core_clk);force dut.axi_s_awvalid='1;
        #1;if(!dut.fabric_write_quiescent || dut.u_control.fabric_write_quiescent!==1'b0)
            $fatal(1,"ungranted AW missing from drain qualification");
        release dut.axi_s_awvalid;
        @(negedge core_clk);force dut.axi_s_wvalid='1;
        #1;if(!dut.fabric_write_quiescent || dut.u_control.fabric_write_quiescent!==1'b0)
            $fatal(1,"ungranted W missing from drain qualification");
        release dut.axi_s_wvalid;
        #1;if(dut.u_control.fabric_read_quiescent!==1'b1 || dut.u_control.fabric_write_quiescent!==1'b1)
            $fatal(1,"idle fabric failed drain qualification");
        $display("C1_SOC_DRAIN_OFFERS_PASS ar=1 aw=1 w=1 no_clocked_transfer=1");
        if(dut.u_capture.u_frontend.CAMERA_READY_VALID_SOURCE !== CAMERA_READY_VALID_SOURCE)
            $fatal(1,"camera source contract parameter not propagated");
        $display("C1_SOC_CAMERA_SOURCE_MODE_PASS ready_valid=%0d",CAMERA_READY_VALID_SOURCE);

        apb_read(12'h000, observed_id);
        if (observed_id !== 32'h4331_5254) begin
            $fatal(1, "CSR ID mismatch: got 0x%08x", observed_id);
        end
        apb_read(12'h004, observed_id);
        if (observed_id !== 32'h0001_0100)
            $fatal(1, "CSR version mismatch: got 0x%08x", observed_id);
        apb_write(12'h098, 32'h0200_0000);
        apb_read(12'h098, observed_id);
        if (observed_id !== 32'h0200_0000)
            $fatal(1, "tensor arena CSR mismatch: got 0x%08x", observed_id);
        observed_tensor=observed_id;

        repeat (20) @(posedge core_clk);
        if (camera_overflow !== 1'b0) begin
            $fatal(1, "idle camera path unexpectedly overflowed");
        end
        if (m_axi_awvalid || m_axi_wvalid || m_axi_arvalid)
            $fatal(1, "idle integrated SoC issued a spurious AXI request");
        if(QUEUED_WRITE) begin
            apb_write(12'h010,32'h1);
            // An unsolicited physical B exercises the real arbiter diagnostic,
            // not a forced internal fault signal or a scripted control input.
            @(negedge core_clk);inject_b=1;
            @(negedge core_clk);
            if(!m_axi_bready) $fatal(1,"orphan B was not drained");
            inject_b=0;
            repeat(8) @(negedge core_clk);
            apb_read(12'h020,observed_id);
            if(observed_id!==32'h14) $fatal(1,"fabric fault did not reach APB error code");
            apb_read(12'h024,observed_id);
            if(observed_id!==0) $fatal(1,"fabric fault fabricated an address");
            apb_write(12'h01c,32'hffffffff); // IRQ W1C must not repair AXI state.
            apb_write(12'h010,32'h5); // enable + ABORT
            apb_write(12'h010,32'h0);
            apb_write(12'h010,32'h1);
            // Persistent cancellation keeps display cleanup fenced: START
            // must be rejected by the real CSR busy gate in this SoC state.
            apb_write(12'h010,32'h3,1'b1);
            repeat(12) begin
                @(negedge core_clk);
                if(m_axi_awvalid || m_axi_wvalid || m_axi_arvalid ||
                   !dut.u_control.fabric_fault_active || dut.u_control.run_armed_q)
                    $fatal(1,"software control bypassed integrated fabric lock");
            end
            arst_n=0;repeat(6) @(negedge core_clk);arst_n=1;
            repeat(8) @(negedge core_clk);
            apb_read(12'h020,observed_id);
            if(observed_id!==0 || dut.fabric_write_protocol_error || dut.u_control.fabric_fault_active)
                $fatal(1,"common reset failed to clear integrated fault");
            $display("C1_SOC_QUEUED_WRITE_FAULT_PASS ticket=%0d physical_orphan_B=1 apb_code=14 no_axi_restart=1 reset_unlock=1",FATAL_TICKET);
        end
        if(QUEUED_WRITE) begin
            if(dut.g_shared_qos_monitor.u_monitor.frame_deadline_cycles !== QOS_WIDTH'(EXPECT_QOS_DEADLINE))
                $fatal(1,"QoS deadline adaptation width=%0d requested=%h expected=%h",
                    QOS_WIDTH,QOS_DEADLINE,EXPECT_QOS_DEADLINE);
            $display("C1_SOC_QOS_DEADLINE_PASS width=%0d requested=%h effective=%h",
                QOS_WIDTH,QOS_DEADLINE,EXPECT_QOS_DEADLINE);
        end
        if(PREVIEW_CAPTURE || PREVIEW_DISPLAY) begin
            if(dut.AXI_CLIENTS!=8+COLUMN_READS || dut.PREVIEW_ALLOCATION_VALID!==(PREVIEW_BAD_ALLOC==0))
                $fatal(1,"preview allocation guard configuration");
            if(PREVIEW_BAD_ALLOC!=0 && dut.preview_job_stride!==0)
                $fatal(1,"invalid preview allocation did not poison preflight stride");
            if(dut.preview_awvalid || dut.preview_wvalid || dut.axi_s_arvalid[7] || dut.axi_s_rready[7])
                $fatal(1,"idle preview port has traffic");
            $display("C1_SOC_PREVIEW_ALLOCATION_PASS bad_alloc=%0d clients=%0d",PREVIEW_BAD_ALLOC,dut.AXI_CLIENTS);
            if(PREVIEW_DISPLAY) begin
                if(!dut.u_control.DISPLAY_RESIZED_PREVIEW || !dut.u_boardless.ENABLE_PREVIEW)
                    $fatal(1,"preview display did not enable producer and consumer");
                $display("C1_SOC_PREVIEW_DISPLAY_CONFIG_PASS capture_implied=1 clients=8");
            end
        end
        if(dut.u_microstyle.u_cnn.u_engine.CACHE_DW_WEIGHT_TILES != CACHE_DW_WEIGHT_TILES ||
           dut.u_microstyle.u_cnn.u_engine.MAC_PREFETCH_OVERLAP != MAC_PREFETCH_OVERLAP)
            $fatal(1,"SoC engine throughput parameters were not forwarded");
        $display("C1_SOC_ENGINE_OPTIONS_PASS dw_cache=%0d mac_overlap=%0d",CACHE_DW_WEIGHT_TILES,MAC_PREFETCH_OVERLAP);
        if (dut.u_tensor_adapter.PREFETCH_NEXT_TAP_ADDRESS != PREFETCH_NEXT_TAP_ADDRESS)
            $fatal(1,"SoC tap address prefetch option did not reach adapter");
        $display("C1_SOC_TAP_ADDRESS_OPTION_PASS enabled=%0d",PREFETCH_NEXT_TAP_ADDRESS);
        $display("C1_R1_PORTABLE_SOC_SMOKE_PASS tensor=%08x", observed_tensor);
        $finish;
    end

    generate if(COLUMN_READS) begin : g_column_refill_config_check
        initial begin
            if(dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.MAX_OUTSTANDING!=REFILL_WINDOW ||
               dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.ALLOW_REQ_HANDOFF!=REFILL_HANDOFF)
                $fatal(1,"column refill capacity/handoff did not reach actual scheduler");
            $display("C1_SOC_COLUMN_REFILL_CONFIG_PASS window=%0d handoff=%0d",REFILL_WINDOW,REFILL_HANDOFF);
        end
    end endgenerate
    initial begin
        #20000;
        $fatal(1, "portable SoC smoke timeout");
    end
endmodule
