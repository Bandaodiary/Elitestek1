`timescale 1ns/1ps

module tb_c1_r1_integration_skeleton;

    localparam integer APB_ADDR_W = 12;
    localparam integer ISP_FRAME_WIDTH = 8;
    localparam integer ISP_FRAME_HEIGHT = 6;
    localparam integer ISP_X_BITS = 3;
    localparam integer ISP_Y_BITS = 3;

    logic clk;
    logic rst_n;
    logic psel;
    logic penable;
    logic pwrite;
    logic [APB_ADDR_W-1:0] paddr;
    logic [31:0] pwdata;
    logic [3:0] pstrb;
    logic [31:0] prdata;
    logic pready;
    logic pslverr;
    logic irq;

    logic job_command_valid;
    logic job_command_ready;
    logic job_command_accept_pulse;
    logic job_abort_pulse;
    logic [15:0] job_frame_width;
    logic [15:0] job_frame_height;
    logic job_continuous_mode;
    logic job_drop_oldest_mode;
    logic [31:0] job_input_stride_bytes;
    logic [31:0] job_output_stride_bytes;
    logic [3:0] job_input_pixel_format;
    logic [3:0] job_output_pixel_format;
    logic [63:0] job_input_buffer_table_base;
    logic [63:0] job_output_buffer_table_base;
    logic [31:0] job_descriptor_base;
    logic [15:0] job_descriptor_count;
    logic [7:0] job_style_id;
    logic [63:0] job_weight_base;
    logic [7:0] job_display_mode;
    logic job_retire_done_event;
    logic job_retire_error_event;
    logic [7:0] job_retire_error_code;
    logic [31:0] job_retire_error_address;
    logic external_engine_busy;
    logic system_busy;

    logic input_dma_start;
    logic [31:0] input_dma_base_addr;
    logic input_dma_busy;
    logic input_dma_done;
    logic input_dma_error;
    logic output_dma_start;
    logic [31:0] output_dma_base_addr;
    logic output_dma_busy;
    logic output_dma_done;
    logic output_dma_error;

    logic dma_input_valid;
    logic dma_input_ready;
    logic [23:0] dma_input_rgb;
    logic dma_input_sof;
    logic dma_input_eol;
    logic dma_input_eof;
    logic [15:0] dma_input_x;
    logic [15:0] dma_input_y;

    logic engine_output_valid;
    logic engine_output_ready;
    logic [23:0] engine_output_rgb;
    logic engine_output_sof;
    logic engine_output_eol;
    logic engine_output_eof;

    logic layer_command_valid;
    logic layer_command_ready;
    logic [15:0] layer_command_index;
    logic [511:0] layer_command_descriptor;
    logic layer_done_pulse;
    logic layer_error_pulse;
    logic descriptor_busy;
    logic descriptor_done_pulse;
    logic descriptor_error_pulse;
    logic descriptor_aborted_pulse;
    logic [15:0] active_layer_index;

    logic raw_input_valid;
    logic raw_input_sof;
    logic raw_input_eol;
    logic raw_input_eof;
    logic [ISP_X_BITS-1:0] raw_input_x;
    logic [ISP_Y_BITS-1:0] raw_input_y;
    logic [9:0] raw_input_raw10;

    logic isp_stream_valid;
    logic isp_stream_ready;
    logic [23:0] isp_stream_rgb;
    logic isp_stream_sof;
    logic isp_stream_eol;
    logic isp_stream_eof;
    logic [ISP_X_BITS-1:0] isp_stream_x;
    logic [ISP_Y_BITS-1:0] isp_stream_y;
    logic isp_stream_overflow_event;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    logic m_axi_bready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;

    logic axi_read_active;
    logic [1:0] axi_read_beat;
    integer axi_gap;
    integer ar_count;
    integer rbeat_count;
    integer job_accept_count;
    integer job_abort_count;
    integer layer_command_count;
    integer descriptor_done_count;
    integer isp_commit_count;
    integer gamma_write_count;
    integer guard;
    logic [31:0] status_value;

    c1_r1_integration_skeleton #(
        .APB_ADDR_W(APB_ADDR_W),
        .ISP_FRAME_WIDTH(ISP_FRAME_WIDTH),
        .ISP_FRAME_HEIGHT(ISP_FRAME_HEIGHT),
        .ISP_X_BITS(ISP_X_BITS),
        .ISP_Y_BITS(ISP_Y_BITS),
        .ISP_FIFO_DEPTH(4)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic [31:0] descriptor_word(input integer word_index);
        begin
            descriptor_word = 32'hd15c_0000 ^
                              (32'h1020_4081 * (word_index + 1));
        end
    endfunction

    function automatic [127:0] descriptor_beat(input logic [1:0] beat_index);
        logic [127:0] result;
        integer lane;
        begin
            result = 128'd0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                result[lane*32 +: 32] =
                    descriptor_word(beat_index*4 + lane);
            end
            descriptor_beat = result;
        end
    endfunction

    function automatic [511:0] descriptor_image;
        logic [511:0] result;
        integer beat;
        begin
            result = 512'd0;
            for (beat = 0; beat < 4; beat = beat + 1)
                result[beat*128 +: 128] = descriptor_beat(beat[1:0]);
            descriptor_image = result;
        end
    endfunction

    task automatic apb_write(
        input logic [APB_ADDR_W-1:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b1;
            paddr = address;
            pwdata = data;
            pstrb = 4'hf;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            if (!pready || pslverr)
                $fatal(1, "APB write failed address=%03x", address);
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = '0;
            pwdata = '0;
            pstrb = '0;
        end
    endtask

    task automatic apb_read(
        input logic [APB_ADDR_W-1:0] address,
        output logic [31:0] data
    );
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = address;
            pwdata = '0;
            pstrb = '0;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            if (!pready || pslverr)
                $fatal(1, "APB read failed address=%03x", address);
            @(negedge clk);
            data = prdata;
            psel = 1'b0;
            penable = 1'b0;
            paddr = '0;
        end
    endtask

    task automatic wait_job_valid;
        begin
            guard = 0;
            while (!job_command_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 200) $fatal(1, "job command valid timeout");
            end
        end
    endtask

    task automatic wait_counter(
        input integer selector,
        input integer target
    );
        integer current;
        begin
            guard = 0;
            current = 0;
            while (current < target) begin
                @(negedge clk);
                case (selector)
                    0: current = job_accept_count;
                    1: current = job_abort_count;
                    2: current = layer_command_count;
                    default: current = descriptor_done_count;
                endcase
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "counter timeout selector=%0d target=%0d", selector, target);
            end
        end
    endtask

    // Downstream memory model only services the one descriptor burst used by
    // this smoke test.  Any write or differently-shaped read is a wiring bug.
    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            axi_read_active <= 1'b0;
            axi_read_beat <= 2'd0;
            axi_gap <= 0;
            ar_count <= 0;
            rbeat_count <= 0;
        end else begin
            m_axi_arready <= 1'b1;

            if (m_axi_arvalid && m_axi_arready) begin
                if (axi_read_active || m_axi_rvalid)
                    $fatal(1, "smoke memory saw multiple outstanding reads");
                if ((m_axi_araddr !== 32'h0000_2000) ||
                    (m_axi_arlen !== 8'd3) ||
                    (m_axi_arsize !== 3'd4) ||
                    (m_axi_arburst !== 2'b01)) begin
                    $fatal(1, "descriptor AXI route/attributes mismatch");
                end
                axi_read_active <= 1'b1;
                axi_read_beat <= 2'd0;
                axi_gap <= 1;
                ar_count <= ar_count + 1;
            end

            if (m_axi_rvalid) begin
                if (m_axi_rready) begin
                    m_axi_rvalid <= 1'b0;
                    rbeat_count <= rbeat_count + 1;
                    if (axi_read_beat == 2'd3) begin
                        axi_read_active <= 1'b0;
                    end else begin
                        axi_read_beat <= axi_read_beat + 2'd1;
                        axi_gap <= 1;
                    end
                end
            end else if (axi_read_active) begin
                if (axi_gap > 0) begin
                    axi_gap <= axi_gap - 1;
                end else begin
                    m_axi_rdata <= descriptor_beat(axi_read_beat);
                    m_axi_rresp <= 2'b00;
                    m_axi_rlast <= (axi_read_beat == 2'd3);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            job_accept_count = 0;
            job_abort_count = 0;
            layer_command_count = 0;
            descriptor_done_count = 0;
            isp_commit_count = 0;
            gamma_write_count = 0;
        end else begin
            if (job_command_accept_pulse)
                job_accept_count = job_accept_count + 1;
            if (job_abort_pulse)
                job_abort_count = job_abort_count + 1;
            if (dut.isp_cfg_commit && dut.isp_cfg_ready)
                isp_commit_count = isp_commit_count + 1;
            if (dut.isp_gamma_cfg_we && dut.isp_gamma_cfg_ready)
                gamma_write_count = gamma_write_count + 1;

            if (layer_command_valid && layer_command_ready) begin
                if ((layer_command_index !== 16'd0) ||
                    (active_layer_index !== 16'd0) ||
                    (layer_command_descriptor !== descriptor_image())) begin
                    $fatal(1, "descriptor command boundary content mismatch");
                end
                layer_command_count = layer_command_count + 1;
            end

            if (descriptor_done_pulse)
                descriptor_done_count = descriptor_done_count + 1;
            if (descriptor_error_pulse || descriptor_aborted_pulse)
                $fatal(1, "accepted smoke descriptor run unexpectedly failed");
            if (m_axi_awvalid || m_axi_wvalid)
                $fatal(1, "idle frame writer unexpectedly issued AXI write");
            if (isp_stream_overflow_event)
                $fatal(1, "idle ISP reported overflow");
        end
    end

    initial begin
        rst_n = 1'b1;
        psel = 1'b0;
        penable = 1'b0;
        pwrite = 1'b0;
        paddr = '0;
        pwdata = '0;
        pstrb = '0;
        job_command_ready = 1'b0;
        job_retire_done_event = 1'b0;
        job_retire_error_event = 1'b0;
        job_retire_error_code = 8'd0;
        job_retire_error_address = 32'd0;
        external_engine_busy = 1'b0;
        input_dma_start = 1'b0;
        input_dma_base_addr = 32'h0000_4000;
        output_dma_start = 1'b0;
        output_dma_base_addr = 32'h0000_8000;
        dma_input_ready = 1'b1;
        engine_output_valid = 1'b0;
        engine_output_rgb = 24'd0;
        engine_output_sof = 1'b0;
        engine_output_eol = 1'b0;
        engine_output_eof = 1'b0;
        layer_command_ready = 1'b1;
        layer_done_pulse = 1'b0;
        layer_error_pulse = 1'b0;
        raw_input_valid = 1'b0;
        raw_input_sof = 1'b0;
        raw_input_eol = 1'b0;
        raw_input_eof = 1'b0;
        raw_input_x = '0;
        raw_input_y = '0;
        raw_input_raw10 = '0;
        isp_stream_ready = 1'b1;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;

        // Assert reset away from a clock edge and require the local reset to
        // assert immediately.  Release is also off-edge, but local_rst_n may
        // rise only after two complete synchronizer clock edges.
        @(negedge clk);
        #2 rst_n = 1'b0;
        #1;
        if ((dut.local_rst_n !== 1'b0) || (dut.core_rst !== 1'b1))
            $fatal(1, "local reset did not assert asynchronously");
        repeat (3) @(posedge clk);
        @(negedge clk);
        #2 rst_n = 1'b1;
        #1;
        if (dut.local_rst_n !== 1'b0)
            $fatal(1, "local reset released asynchronously");
        @(posedge clk);
        #1;
        if (dut.local_rst_n !== 1'b0)
            $fatal(1, "local reset released before two synchronizer stages");
        @(posedge clk);
        #1;
        if ((dut.local_rst_n !== 1'b1) || (dut.core_rst !== 1'b0))
            $fatal(1, "local reset failed to release synchronously");
        repeat (3) @(posedge clk);

        if (system_busy || job_command_valid || descriptor_busy ||
            input_dma_busy || output_dma_busy || m_axi_arvalid ||
            m_axi_awvalid || m_axi_wvalid || dma_input_valid ||
            isp_stream_valid) begin
            $fatal(1, "integration skeleton was not idle after reset");
        end
        if (!dut.isp_cfg_ready || !dut.isp_gamma_cfg_ready)
            $fatal(1, "idle APB-driven ISP configuration path was not ready");

        // Program the ISP shadow bank and Gamma command exclusively through
        // the top-level APB port.  The config block must snapshot these values
        // and deliver them to the active pixel pipeline without an external
        // configuration seam.
        apb_write(12'h210, 32'h0000_000d); // GBRG, odd x/y ROI origin
        apb_write(12'h214, 32'h0000_0021);
        apb_write(12'h218, 32'h0000_0032);
        apb_write(12'h21c, 32'h0000_0043);
        apb_write(12'h220, 32'h0000_0054);
        apb_write(12'h224, 32'h0000_4100);
        apb_write(12'h228, 32'h0000_3f00);
        apb_write(12'h22c, 32'h0000_4200);
        apb_write(12'h230, 32'h0000_2100);
        apb_write(12'h234, 32'h0000_ff80);
        apb_write(12'h238, 32'h0000_0040);
        apb_write(12'h23c, 32'h0000_ffc0);
        apb_write(12'h240, 32'h0000_2000);
        apb_write(12'h244, 32'h0000_0020);
        apb_write(12'h248, 32'h0000_0010);
        apb_write(12'h24c, 32'h0000_ffe0);
        apb_write(12'h250, 32'h0000_1f00);
        apb_write(12'h254, 32'h0000_2000);
        apb_write(12'h258, 32'hffff_e000);
        apb_write(12'h25c, 32'h0000_1000);
        apb_write(12'h260, 32'h0000_0155);
        apb_write(12'h264, 32'h0000_00a6);
        apb_read(12'h210, status_value);
        if (status_value !== 32'h0000_000d)
            $fatal(1, "ISP shadow readback did not traverse APB mux");
        apb_write(12'h268, 32'h0000_0001); // Gamma WRITE
        apb_write(12'h200, 32'h0000_0001); // scalar COMMIT

        guard = 0;
        while ((isp_commit_count != 1) || (gamma_write_count != 1)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 100)
                $fatal(1, "APB ISP commit/Gamma handshake timeout");
        end
        repeat (2) @(posedge clk);

        if ((dut.u_r1_isp.active_bayer_pattern !== 2'b01) ||
            !dut.u_r1_isp.active_roi_x_parity ||
            !dut.u_r1_isp.active_roi_y_parity ||
            (dut.u_r1_isp.active_black_r !== 10'h021) ||
            (dut.u_r1_isp.active_black_gr !== 10'h032) ||
            (dut.u_r1_isp.active_black_gb !== 10'h043) ||
            (dut.u_r1_isp.active_black_b !== 10'h054) ||
            (dut.u_r1_isp.active_awb_gain_r !== 16'h4100) ||
            (dut.u_r1_isp.active_awb_gain_g !== 16'h3f00) ||
            (dut.u_r1_isp.active_awb_gain_b !== 16'h4200) ||
            (dut.u_r1_isp.active_ccm_rr !== 16'sh2100) ||
            (dut.u_r1_isp.active_ccm_rg !== -16'sd128) ||
            (dut.u_r1_isp.active_ccm_rb !== 16'sh0040) ||
            (dut.u_r1_isp.active_ccm_gr !== -16'sd64) ||
            (dut.u_r1_isp.active_ccm_gg !== 16'sh2000) ||
            (dut.u_r1_isp.active_ccm_gb !== 16'sh0020) ||
            (dut.u_r1_isp.active_ccm_br !== 16'sh0010) ||
            (dut.u_r1_isp.active_ccm_bg !== -16'sd32) ||
            (dut.u_r1_isp.active_ccm_bb !== 16'sh1f00) ||
            (dut.u_r1_isp.active_ccm_offset_r !== 32'sh0000_2000) ||
            (dut.u_r1_isp.active_ccm_offset_g !== -32'sd8192) ||
            (dut.u_r1_isp.active_ccm_offset_b !== 32'sh0000_1000)) begin
            $fatal(1, "APB ISP scalar snapshot did not reach active pipeline configuration");
        end
        if ((dut.u_r1_isp.u_color.gamma_r_mem[10'h155] !== 8'ha6) ||
            (dut.u_r1_isp.u_color.gamma_g_mem[10'h155] !== 8'ha6) ||
            (dut.u_r1_isp.u_color.gamma_b_mem[10'h155] !== 8'ha6)) begin
            $fatal(1, "APB Gamma write did not reach all three pipeline banks");
        end
        apb_read(12'h204, status_value);
        if (status_value[2:0] !== 3'b000)
            $fatal(1, "ISP APB requests remained pending after pipeline acceptance");

        // Program a complete software job image.
        apb_write(12'h010, 32'h0000_0019); // enable + continuous + drop-oldest
        apb_write(12'h040, 32'h5566_7788);
        apb_write(12'h044, 32'h1122_3344);
        apb_write(12'h048, 32'hddee_ff00);
        apb_write(12'h04c, 32'h99aa_bbcc);
        apb_write(12'h050, 32'h0001_0004); // H=1, W=4
        apb_write(12'h054, 32'd16);
        apb_write(12'h058, 32'd16);
        apb_write(12'h05c, 32'h0000_0022); // XRGB in/out
        apb_write(12'h080, 32'h0000_2000);
        apb_write(12'h084, 32'h0000_0000);
        apb_write(12'h088, 32'h0000_0001);
        apb_write(12'h08c, 32'h0000_002a);
        apb_write(12'h090, 32'h89ab_cdef);
        apb_write(12'h094, 32'h0123_4567);
        apb_write(12'h0c0, 32'h0000_0003);

        // First start is held at the job-controller boundary, proving atomic
        // config snapshot/valid hold.  A later live CSR write must not alter it.
        apb_write(12'h010, 32'h0000_001b); // configured modes + start
        wait_job_valid();
        if (!system_busy || job_command_accept_pulse ||
            (job_frame_width !== 16'd4) ||
            (job_frame_height !== 16'd1) ||
            !job_continuous_mode || !job_drop_oldest_mode ||
            (job_input_stride_bytes !== 32'd16) ||
            (job_output_stride_bytes !== 32'd16) ||
            (job_input_pixel_format !== 4'd2) ||
            (job_output_pixel_format !== 4'd2) ||
            (job_input_buffer_table_base !== 64'h1122_3344_5566_7788) ||
            (job_output_buffer_table_base !== 64'h99aa_bbcc_ddee_ff00) ||
            (job_descriptor_base !== 32'h0000_2000) ||
            (job_descriptor_count !== 16'd1) ||
            (job_style_id !== 8'h2a) ||
            (job_weight_base !== 64'h0123_4567_89ab_cdef) ||
            (job_display_mode !== 8'h03)) begin
            $fatal(1, "latched job command/config route mismatch");
        end

        apb_write(12'h050, 32'h0002_0008);
        if ((job_frame_width !== 16'd4) || (job_frame_height !== 16'd1))
            $fatal(1, "pending job snapshot followed live CSR changes");
        repeat (3) @(posedge clk);
        if (!job_command_valid || m_axi_arvalid)
            $fatal(1, "job valid was not held or launched before ready");

        // Abort before command acceptance returns every implemented block idle.
        apb_write(12'h010, 32'h0000_001d); // configured modes + abort
        wait_counter(1, 1);
        repeat (4) @(posedge clk);
        if (job_command_valid || system_busy || descriptor_busy ||
            input_dma_busy || output_dma_busy || (ar_count != 0)) begin
            $fatal(1, "pending-command abort did not restore idle state");
        end

        // Restore frame dimensions, start again, and accept the command.  The
        // resulting descriptor fetch must traverse both AXI arbiters.
        apb_write(12'h050, 32'h0001_0004);
        apb_write(12'h010, 32'h0000_001b);
        wait_job_valid();
        @(negedge clk);
        job_command_ready = 1'b1;
        wait_counter(0, 1);
        @(negedge clk);
        job_command_ready = 1'b0;

        wait_counter(2, 1);
        @(negedge clk);
        layer_done_pulse = 1'b1;
        @(posedge clk);
        @(negedge clk);
        layer_done_pulse = 1'b0;
        wait_counter(3, 1);
        repeat (5) @(posedge clk);

        if ((ar_count != 1) || (rbeat_count != 4) || system_busy ||
            descriptor_busy || input_dma_busy || output_dma_busy ||
            axi_read_active || m_axi_rvalid || m_axi_arvalid) begin
            $fatal(1, "accepted descriptor run failed to retire cleanly");
        end

        apb_read(12'h014, status_value);
        if ((status_value[1] !== 1'b0) || (status_value[0] !== 1'b1))
            $fatal(1, "CSR status did not report final idle state");

        $display("C1_R1_INTEGRATION_SKELETON_PASS job_accept=%0d job_abort=%0d isp_commit=%0d gamma_write=%0d ar=%0d rbeats=%0d layers=%0d descriptor_done=%0d",
                 job_accept_count, job_abort_count, isp_commit_count,
                 gamma_write_count,
                 ar_count, rbeat_count, layer_command_count,
                 descriptor_done_count);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "global integration skeleton smoke timeout");
    end

endmodule
