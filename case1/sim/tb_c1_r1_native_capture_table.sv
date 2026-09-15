`timescale 1ns/1ps

// Native capture/table staged preflight.
//
// This bench deliberately stops at c1_r1_capture_subsystem.  It drives the
// real 642x482 RAW10 camera ingress, waits for frame-table ownership, starts
// the real R1 ISP and XRGB writer, and checks the writer's native 640x480
// address stream.  The table and writer AXI channels have independent BFMs;
// no CNN, SoC controller, shared arbiter, or board-specific IP is instantiated.
module tb_c1_r1_native_capture_table;
    localparam integer SENSOR_W = 642;
    localparam integer SENSOR_H = 482;
    localparam integer FRAME_W  = SENSOR_W - 2;
    localparam integer FRAME_H  = SENSOR_H - 2;
    localparam integer STRIDE   = FRAME_W * 4;
    localparam integer FRAME_BYTES = STRIDE * FRAME_H;
    localparam integer FRAME_SLOT_BYTES = 32'h0012_c000;
    localparam integer ROW_BEATS = FRAME_W / 4;
    localparam integer BURSTS_PER_FRAME = FRAME_H * ((ROW_BEATS + 15) / 16);
    localparam integer BEATS_PER_FRAME = FRAME_H * ROW_BEATS;
    localparam logic [31:0] TABLE_BASE = 32'h0008_0000;
    localparam logic [31:0] INPUT_BASE = 32'h0010_0000;

    logic camera_clk = 1'b0;
    logic core_clk = 1'b0;
    logic camera_rst = 1'b1;
    logic core_rst = 1'b1;
    always #4 camera_clk = ~camera_clk;
    always #5 core_clk = ~core_clk;

    logic camera_valid = 1'b0;
    logic camera_ready;
    logic [9:0] camera_raw10 = '0;
    logic [9:0] camera_x = '0;
    logic [8:0] camera_y = '0;
    logic camera_sof = 1'b0, camera_eol = 1'b0, camera_eof = 1'b0;
    logic camera_overflow;

    logic frame_waiting, begin_frame = 1'b0, begin_ready;
    logic drop_frame = 1'b0, discard_idle = 1'b0, abort_frame = 1'b0;
    logic clear_error = 1'b0;
    logic cleanup_busy, frame_ingress_done, frame_dropped, frame_aborted;
    logic capture_error;
    logic [7:0] capture_error_code;

    logic cfg_commit = 1'b0, cfg_ready;
    logic gamma_cfg_ready;

    logic [1:0] cfg_bayer_pattern = 2'b00;
    logic cfg_roi_x_parity = 1'b0, cfg_roi_y_parity = 1'b0;
    logic [9:0] cfg_black_r = 10'd0, cfg_black_gr = 10'd0;
    logic [9:0] cfg_black_gb = 10'd0, cfg_black_b = 10'd0;
    logic [15:0] cfg_awb_gain_r = 16'd16384;
    logic [15:0] cfg_awb_gain_g = 16'd16384;
    logic [15:0] cfg_awb_gain_b = 16'd16384;
    logic signed [15:0] cfg_ccm_rr = 16'sd8192;
    logic signed [15:0] cfg_ccm_rg = 16'sd0;
    logic signed [15:0] cfg_ccm_rb = 16'sd0;
    logic signed [15:0] cfg_ccm_gr = 16'sd0;
    logic signed [15:0] cfg_ccm_gg = 16'sd8192;
    logic signed [15:0] cfg_ccm_gb = 16'sd0;
    logic signed [15:0] cfg_ccm_br = 16'sd0;
    logic signed [15:0] cfg_ccm_bg = 16'sd0;
    logic signed [15:0] cfg_ccm_bb = 16'sd8192;
    logic signed [31:0] cfg_ccm_offset_r = 32'sd0;
    logic signed [31:0] cfg_ccm_offset_g = 32'sd0;
    logic signed [31:0] cfg_ccm_offset_b = 32'sd0;
    logic gamma_cfg_we = 1'b0;
    logic [9:0] gamma_cfg_addr = '0;
    logic [7:0] gamma_cfg_data = '0;

    logic table_request_valid = 1'b0, table_request_ready;
    logic [63:0] table_request_base = TABLE_BASE;
    logic [1:0] table_request_index = '0;
    logic table_response_valid, table_response_ready = 1'b1;
    logic table_response_error;
    logic [63:0] table_response_base;
    logic [31:0] table_response_stride;
    logic [15:0] table_response_width, table_response_height;
    logic table_abort_request = 1'b0, table_abort_pending;

    logic writer_start = 1'b0, writer_cancel = 1'b0;
    logic [31:0] writer_base = '0, writer_stride = STRIDE;
    logic [15:0] writer_width = FRAME_W, writer_height = FRAME_H;
    logic writer_busy, writer_done, writer_error;

    logic [31:0] table_araddr;
    logic [7:0] table_arlen;
    logic [2:0] table_arsize;
    logic [1:0] table_arburst;
    logic table_arvalid, table_arready = 1'b0;
    logic [127:0] table_rdata = '0;
    logic [1:0] table_rresp = 2'b00;
    logic table_rlast = 1'b0, table_rvalid = 1'b0, table_rready;

    logic [31:0] writer_awaddr;
    logic [7:0] writer_awlen;
    logic [2:0] writer_awsize;
    logic [1:0] writer_awburst;
    logic writer_awvalid, writer_awready = 1'b0;
    logic [127:0] writer_wdata;
    logic [15:0] writer_wstrb;
    logic writer_wlast, writer_wvalid, writer_wready = 1'b0;
    logic [1:0] writer_bresp = 2'b00;
    logic writer_bvalid = 1'b0, writer_bready;

    c1_r1_capture_subsystem #(
        .SENSOR_WIDTH(SENSOR_W), .SENSOR_HEIGHT(SENSOR_H),
        .CAMERA_FIFO_DEPTH(4096), .OUTPUT_FIFO_DEPTH(2048)
    ) dut (
        .camera_clk(camera_clk), .camera_rst(camera_rst),
        .camera_valid(camera_valid), .camera_ready(camera_ready),
        .camera_raw10(camera_raw10), .camera_x(camera_x), .camera_y(camera_y),
        .camera_sof(camera_sof), .camera_eol(camera_eol), .camera_eof(camera_eof),
        .camera_overflow(camera_overflow),
        .core_clk(core_clk), .core_rst(core_rst),
        .frame_waiting(frame_waiting), .begin_frame(begin_frame),
        .begin_ready(begin_ready), .drop_frame(drop_frame),
        .discard_idle(discard_idle), .abort_frame(abort_frame),
        .clear_error(clear_error), .cleanup_busy(cleanup_busy),
        .frame_ingress_done(frame_ingress_done), .frame_dropped(frame_dropped),
        .frame_aborted(frame_aborted), .capture_error(capture_error),
        .capture_error_code(capture_error_code),
        .cfg_commit(cfg_commit), .cfg_ready(cfg_ready),
        .cfg_bayer_pattern(cfg_bayer_pattern), .cfg_roi_x_parity(cfg_roi_x_parity),
        .cfg_roi_y_parity(cfg_roi_y_parity), .cfg_black_r(cfg_black_r),
        .cfg_black_gr(cfg_black_gr), .cfg_black_gb(cfg_black_gb),
        .cfg_black_b(cfg_black_b), .cfg_awb_gain_r(cfg_awb_gain_r),
        .cfg_awb_gain_g(cfg_awb_gain_g), .cfg_awb_gain_b(cfg_awb_gain_b),
        .cfg_ccm_rr(cfg_ccm_rr), .cfg_ccm_rg(cfg_ccm_rg), .cfg_ccm_rb(cfg_ccm_rb),
        .cfg_ccm_gr(cfg_ccm_gr), .cfg_ccm_gg(cfg_ccm_gg), .cfg_ccm_gb(cfg_ccm_gb),
        .cfg_ccm_br(cfg_ccm_br), .cfg_ccm_bg(cfg_ccm_bg), .cfg_ccm_bb(cfg_ccm_bb),
        .cfg_ccm_offset_r(cfg_ccm_offset_r), .cfg_ccm_offset_g(cfg_ccm_offset_g),
        .cfg_ccm_offset_b(cfg_ccm_offset_b), .gamma_cfg_we(gamma_cfg_we),
        .gamma_cfg_addr(gamma_cfg_addr), .gamma_cfg_data(gamma_cfg_data),
        .gamma_cfg_ready(gamma_cfg_ready),
        .table_request_valid(table_request_valid),
        .table_request_ready(table_request_ready),
        .table_request_base(table_request_base),
        .table_request_index(table_request_index),
        .table_response_valid(table_response_valid),
        .table_response_ready(table_response_ready),
        .table_response_error(table_response_error),
        .table_response_base(table_response_base),
        .table_response_stride(table_response_stride),
        .table_response_width(table_response_width),
        .table_response_height(table_response_height),
        .table_abort_request(table_abort_request),
        .table_abort_pending(table_abort_pending),
        .writer_start(writer_start), .writer_cancel(writer_cancel),
        .writer_base(writer_base), .writer_stride(writer_stride),
        .writer_width(writer_width), .writer_height(writer_height),
        .writer_busy(writer_busy), .writer_done(writer_done),
        .writer_error(writer_error),
        .table_axi_araddr(table_araddr), .table_axi_arlen(table_arlen),
        .table_axi_arsize(table_arsize), .table_axi_arburst(table_arburst),
        .table_axi_arvalid(table_arvalid), .table_axi_arready(table_arready),
        .table_axi_rdata(table_rdata), .table_axi_rresp(table_rresp),
        .table_axi_rlast(table_rlast), .table_axi_rvalid(table_rvalid),
        .table_axi_rready(table_rready),
        .writer_axi_awaddr(writer_awaddr), .writer_axi_awlen(writer_awlen),
        .writer_axi_awsize(writer_awsize), .writer_axi_awburst(writer_awburst),
        .writer_axi_awvalid(writer_awvalid), .writer_axi_awready(writer_awready),
        .writer_axi_wdata(writer_wdata), .writer_axi_wstrb(writer_wstrb),
        .writer_axi_wlast(writer_wlast), .writer_axi_wvalid(writer_wvalid),
        .writer_axi_wready(writer_wready), .writer_axi_bresp(writer_bresp),
        .writer_axi_bvalid(writer_bvalid), .writer_axi_bready(writer_bready)
    );

    function automatic [31:0] slot_base(input integer slot);
        slot_base = INPUT_BASE + slot * FRAME_SLOT_BYTES;
    endfunction

    function automatic [127:0] table_entry(input integer slot);
        table_entry = {16'd480, 16'd640, 32'h0000_0a00, 32'd0,
                       slot_base(slot)};
    endfunction

    function automatic [9:0] raw_pattern(input integer x, input integer y,
                                         input integer tone);
        raw_pattern = (10'h041 + x*11 + y*37 + tone*53) & 10'h3ff;
    endfunction

    integer cycle_count = 0;
    integer table_ar_count = 0, table_r_count = 0, table_response_count = 0;
    integer table_ar_stalls = 0, table_r_delays = 0;
    integer writer_aw_count = 0, writer_w_count = 0, writer_b_count = 0;
    integer writer_aw_stalls = 0, writer_w_stalls = 0, writer_b_delays = 0;
    integer ingress_count = 0, done_count = 0;
    integer stream_pixel_count = 0, stream_sof_count = 0;
    integer stream_eol_count = 0, stream_eof_count = 0;
    integer gamma_write_count = 0;
    integer current_slot = 0, current_tone = 0;
    logic [63:0] response_base_latched = '0;
    logic [31:0] response_stride_latched = '0;
    logic [15:0] response_width_latched = '0, response_height_latched = '0;
    logic response_error_latched = 1'b0;
    logic failure_seen = 1'b0;

    // One-beat frame-table AXI slave.  It intentionally inserts small AR/R
    // stalls and checks that every lookup uses TABLE_BASE + index*16.
    logic table_slave_active = 1'b0;
    integer table_delay = 0;
    logic [127:0] table_pending_data = '0;
    always_comb begin
        table_arready = !table_slave_active && !table_rvalid &&
                        ((cycle_count % 7) != 0);
    end

    // Writer-side AXI slave state and row planner.
    logic writer_aw_active = 1'b0;
    logic writer_response_pending = 1'b0;
    integer writer_response_delay = 0;
    logic [31:0] active_aw_addr = '0;
    integer active_aw_beats = 0, active_w_index = 0;
    integer expected_row = 0, expected_row_bytes = STRIDE;
    logic [31:0] expected_next_addr = INPUT_BASE;
    logic [31:0] active_writer_base = INPUT_BASE;
    integer frame_aw_count = 0, frame_w_count = 0, frame_b_count = 0;
    logic [127:0] line_store [longint unsigned];

    function automatic integer expected_burst_beats(input integer address,
                                                     input integer remaining);
        integer boundary_beats;
        integer selected;
        begin
            boundary_beats = (4096 - (address & 4095)) / 16;
            selected = (remaining / 16 < 16) ? (remaining / 16) : 16;
            if (boundary_beats < selected) selected = boundary_beats;
            expected_burst_beats = selected;
        end
    endfunction

    always_comb begin
        writer_awready = !writer_aw_active && !writer_response_pending &&
                         !writer_bvalid && ((cycle_count % 17) != 0);
        writer_wready = writer_aw_active && !writer_response_pending &&
                        !writer_bvalid && ((cycle_count % 13) != 0);
    end

    task automatic fail(input string message);
        begin
            // Some xsim builds continue scheduling sibling processes after a
            // severity-1 $fatal.  Guard the report and explicitly finish so a
            // malformed native run cannot produce hundreds of thousands of
            // duplicate FAIL lines or consume the global timeout.
            if (!failure_seen) begin
                failure_seen = 1'b1;
                $display("C1_R1_NATIVE_CAPTURE_TABLE_FAIL time=%0t slot=%0d table_ar=%0d table_r=%0d aw=%0d w=%0d b=%0d: %s",
                         $time, current_slot, table_ar_count, table_r_count,
                         writer_aw_count, writer_w_count, writer_b_count, message);
                $fatal(1);
                $finish;
            end
        end
    endtask

    always @(posedge core_clk) begin : axi_bfm
        integer index;
        integer planned;
        integer burst_bytes;
        longint unsigned key;
        if (core_rst) begin
            cycle_count <= 0;
            table_slave_active <= 1'b0;
            table_rvalid <= 1'b0;
            table_rlast <= 1'b0;
            writer_aw_active <= 1'b0;
            writer_response_pending <= 1'b0;
            writer_bvalid <= 1'b0;
            expected_next_addr <= INPUT_BASE;
            expected_row <= 0;
            expected_row_bytes <= STRIDE;
        end else begin
            cycle_count <= cycle_count + 1;
            if (table_arvalid && !table_arready) table_ar_stalls <= table_ar_stalls + 1;
            if (writer_awvalid && !writer_awready) writer_aw_stalls <= writer_aw_stalls + 1;
            if (writer_wvalid && !writer_wready) writer_w_stalls <= writer_w_stalls + 1;

            if (table_arvalid && table_arready) begin
                if ((table_arlen != 0) || (table_arsize != 3'd4) ||
                    (table_arburst != 2'b01) || table_araddr[3:0] != 0)
                    fail("invalid frame-table AR attributes");
                if (table_araddr < TABLE_BASE ||
                    table_araddr >= TABLE_BASE + 3*16 ||
                    ((table_araddr - TABLE_BASE) & 15) != 0)
                    fail("frame-table AR outside native table");
                index = (table_araddr - TABLE_BASE) >> 4;
                table_pending_data <= table_entry(index);
                table_delay <= 1 + (cycle_count % 3);
                table_slave_active <= 1'b1;
                table_ar_count <= table_ar_count + 1;
            end
            if (table_slave_active && !table_rvalid) begin
                if (table_delay > 0) begin
                    table_delay <= table_delay - 1;
                    table_r_delays <= table_r_delays + 1;
                end else begin
                    table_rdata <= table_pending_data;
                    table_rresp <= 2'b00;
                    table_rlast <= 1'b1;
                    table_rvalid <= 1'b1;
                    table_slave_active <= 1'b0;
                end
            end
            if (table_rvalid && table_rready) begin
                table_rvalid <= 1'b0;
                table_rlast <= 1'b0;
                table_r_count <= table_r_count + 1;
            end
            if (table_response_valid && table_response_ready) begin
                table_response_count <= table_response_count + 1;
                response_base_latched <= table_response_base;
                response_stride_latched <= table_response_stride;
                response_width_latched <= table_response_width;
                response_height_latched <= table_response_height;
                response_error_latched <= table_response_error;
            end

            if (writer_start && !writer_busy) begin
                expected_next_addr <= writer_base;
                active_writer_base <= writer_base;
                expected_row <= 0;
                expected_row_bytes <= STRIDE;
                frame_aw_count <= 0;
                frame_w_count <= 0;
                frame_b_count <= 0;
            end
            if (writer_awvalid && writer_awready) begin
                if (writer_awaddr !== expected_next_addr)
                    fail("writer AW address does not follow table-owned slot");
                if (writer_awsize != 3'd4 || writer_awburst != 2'b01 ||
                    writer_awaddr[3:0] != 0 || writer_awlen > 15)
                    fail("writer AW attributes invalid");
                planned = expected_burst_beats(expected_next_addr,
                                                expected_row_bytes);
                if ((writer_awlen + 1) != planned)
                    fail("writer AWLEN does not match native row plan");
                burst_bytes = planned * 16;
                if ((writer_awaddr[11:0] + burst_bytes) > 4096)
                    fail("writer burst crosses 4KiB boundary");
                if ((writer_awaddr + burst_bytes) >
                    active_writer_base + (expected_row + 1) * STRIDE)
                    fail("writer burst crosses row boundary");
                writer_aw_active <= 1'b1;
                active_aw_addr <= writer_awaddr;
                active_aw_beats <= planned;
                active_w_index <= 0;
                frame_aw_count <= frame_aw_count + 1;
                writer_aw_count <= writer_aw_count + 1;
                if (expected_row_bytes == burst_bytes) begin
                    expected_row <= expected_row + 1;
                    if ((expected_row + 1) < FRAME_H) begin
                        expected_next_addr <= active_writer_base +
                                              (expected_row + 1) * STRIDE;
                        expected_row_bytes <= STRIDE;
                    end else begin
                        expected_row_bytes <= 0;
                    end
                end else begin
                    expected_next_addr <= expected_next_addr + burst_bytes;
                    expected_row_bytes <= expected_row_bytes - burst_bytes;
                end
            end
            if (writer_wvalid && writer_wready) begin
                if (!writer_aw_active || writer_wstrb != 16'hffff ||
                    writer_wlast != (active_w_index == active_aw_beats-1))
                    fail("writer W channel protocol mismatch");
                if (^writer_wdata === 1'bx)
                    fail("writer WDATA contains X");
                key = (active_aw_addr + active_w_index*16) >> 4;
                line_store[key] = writer_wdata;
                writer_w_count <= writer_w_count + 1;
                frame_w_count <= frame_w_count + 1;
                if (writer_wlast) begin
                    writer_aw_active <= 1'b0;
                    writer_response_pending <= 1'b1;
                    writer_response_delay <= 1 + (cycle_count % 3);
                end else begin
                    active_w_index <= active_w_index + 1;
                end
            end
            if (writer_bvalid && writer_bready) begin
                writer_bvalid <= 1'b0;
                writer_bresp <= 2'b00;
                writer_b_count <= writer_b_count + 1;
                frame_b_count <= frame_b_count + 1;
            end else if (!writer_bvalid && writer_response_pending) begin
                if (writer_response_delay > 0) begin
                    writer_response_delay <= writer_response_delay - 1;
                    writer_b_delays <= writer_b_delays + 1;
                end else begin
                    writer_bvalid <= 1'b1;
                    writer_response_pending <= 1'b0;
                end
            end
        end
    end

    always @(posedge core_clk) begin
        if (core_rst) begin
            ingress_count <= 0;
            done_count <= 0;
            stream_pixel_count <= 0;
            stream_sof_count <= 0;
            stream_eol_count <= 0;
            stream_eof_count <= 0;
            gamma_write_count <= 0;
        end else begin
            if (frame_ingress_done) ingress_count <= ingress_count + 1;
            if (writer_done) done_count <= done_count + 1;
            // `stream_*` is the real RGB24 handshake between the ISP output
            // FIFO and the XRGB writer.  AXI W-beat counts alone cannot prove
            // that RAW10 produced exactly one 640x480 raster.
            if (dut.stream_valid && dut.stream_ready) begin
                stream_pixel_count <= stream_pixel_count + 1;
                if (dut.stream_sof) stream_sof_count <= stream_sof_count + 1;
                if (dut.stream_eol) stream_eol_count <= stream_eol_count + 1;
                if (dut.stream_eof) stream_eof_count <= stream_eof_count + 1;
            end
            if (capture_error || camera_overflow || writer_error)
                fail($sformatf("capture/frontend/writer error asserted capture=%b overflow=%b writer=%b code=%02x ingress=%0d done=%0d stream=%0d",
                               capture_error, camera_overflow, writer_error,
                               capture_error_code, ingress_count, done_count,
                               stream_pixel_count));
        end
    end

    // The native R1 color pipeline has a software-programmed 1024x8 Gamma
    // memory with no reset contents.  Program the specified linear LUT before
    // admitting the first frame; otherwise X values legitimately propagate
    // into writer WDATA and a protocol-only test would be inconclusive.
    task automatic program_gamma_lut;
        integer lut_index;
        integer lut_value;
        begin
            for (lut_index = 0; lut_index < 1024; lut_index = lut_index + 1) begin
                lut_value = (lut_index + 2) >> 2;
                if (lut_value > 255)
                    lut_value = 255;
                @(negedge core_clk);
                gamma_cfg_addr <= lut_index[9:0];
                gamma_cfg_data <= lut_value[7:0];
                gamma_cfg_we <= 1'b1;
                while (!gamma_cfg_ready)
                    @(posedge core_clk);
                @(posedge core_clk);
                gamma_write_count <= gamma_write_count + 1;
            end
            @(negedge core_clk);
            gamma_cfg_we <= 1'b0;
        end
    endtask

    task automatic pulse_table_request(input integer index);
        integer guard;
        begin
            @(negedge core_clk);
            table_request_index <= index[1:0];
            table_request_base <= TABLE_BASE;
            table_request_valid <= 1'b1;
            guard = 0;
            while (!table_request_ready) begin
                @(posedge core_clk);
                guard = guard + 1;
                if (guard > 1000) fail("table request handshake timeout");
            end
            @(negedge core_clk);
            table_request_valid <= 1'b0;
        end
    endtask

    // The DUT treats camera_valid && !camera_ready as a sensor overflow
    // (the physical camera has no retry channel).  Therefore the BFM inserts
    // blanking cycles before asserting each word instead of holding valid
    // through a not-ready interval, while still checking the ready/valid
    // handshake at the sampling edge.
    task automatic send_camera_word(input integer px, input integer py,
                                    input integer tone, input logic sof_i,
                                    input logic eol_i, input logic eof_i);
        integer guard;
        begin
            camera_valid <= 1'b0;
            camera_sof <= 1'b0;
            camera_eol <= 1'b0;
            camera_eof <= 1'b0;
            guard = 0;
            while (!camera_ready) begin
                @(posedge camera_clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("camera pacing wait timeout");
            end
            @(negedge camera_clk);
            camera_valid <= 1'b1;
            camera_raw10 <= raw_pattern(px, py, tone);
            camera_x <= px;
            camera_y <= py;
            camera_sof <= sof_i;
            camera_eol <= eol_i;
            camera_eof <= eof_i;
            @(posedge camera_clk);
            if (!camera_ready)
                fail("camera ready changed low after paced word launch");
            @(negedge camera_clk);
            camera_valid <= 1'b0;
            camera_sof <= 1'b0;
            camera_eol <= 1'b0;
            camera_eof <= 1'b0;
        end
    endtask

    task automatic send_first_pixel(input integer tone);
        begin
            send_camera_word(0, 0, tone, 1'b1, 1'b0, 1'b0);
        end
    endtask

    task automatic pulse_begin_and_writer;
        integer guard;
        begin
            guard = 0;
            while (!begin_ready) begin
                @(negedge core_clk);
                guard = guard + 1;
                if (guard > 10000) fail("capture begin_ready timeout");
            end
            @(negedge core_clk);
            writer_start <= 1'b1;
            begin_frame <= 1'b1;
            @(posedge core_clk);
            @(negedge core_clk);
            writer_start <= 1'b0;
            begin_frame <= 1'b0;
        end
    endtask

    task automatic send_remaining_raw(input integer tone);
        integer x, y;
        begin
            for (y = 0; y < SENSOR_H; y = y + 1) begin
                for (x = 0; x < SENSOR_W; x = x + 1) begin
                    if ((x == 0) && (y == 0)) begin
                        // The SOF pixel was sent before begin_frame admission.
                    end else begin
                        send_camera_word(x, y, tone, 1'b0,
                                         (x == SENSOR_W-1),
                                         (x == SENSOR_W-1) && (y == SENSOR_H-1));
                    end
                end
            end
            @(negedge camera_clk);
            camera_valid <= 1'b0;
            camera_eol <= 1'b0;
            camera_eof <= 1'b0;
        end
    endtask

    task automatic wait_frame_done(input integer target);
        integer guard;
        begin
            guard = 0;
            while ((done_count < target) || (ingress_count < target)) begin
                @(negedge core_clk);
                guard = guard + 1;
                if (guard > 20000000) fail("native capture frame completion timeout");
            end
        end
    endtask

    task automatic run_slot(input integer slot, input integer tone);
        integer before_aw;
        integer before_w;
        integer before_b;
        integer before_stream_pixels;
        integer before_stream_sof;
        integer before_stream_eol;
        integer before_stream_eof;
        begin
            current_slot = slot;
            current_tone = tone;
            pulse_table_request(slot);
            wait (table_response_count >= slot + 1);
            #0.1;
            if (response_error_latched ||
                response_base_latched !== slot_base(slot) ||
                response_stride_latched !== STRIDE ||
                response_width_latched !== FRAME_W ||
                response_height_latched !== FRAME_H)
                fail("frame-table descriptor fields mismatch");
            writer_base <= response_base_latched[31:0];
            writer_stride <= response_stride_latched;
            writer_width <= response_width_latched;
            writer_height <= response_height_latched;
            before_aw = writer_aw_count;
            before_w = writer_w_count;
            before_b = writer_b_count;
            before_stream_pixels = stream_pixel_count;
            before_stream_sof = stream_sof_count;
            before_stream_eol = stream_eol_count;
            before_stream_eof = stream_eof_count;
            send_first_pixel(tone);
            pulse_begin_and_writer();
            send_remaining_raw(tone);
            wait_frame_done(slot + 1);
            #0.1;
            if (writer_error || writer_busy)
                fail("native capture writer ended with busy/error");
            if ((writer_aw_count - before_aw) != BURSTS_PER_FRAME ||
                (writer_w_count - before_w) != BEATS_PER_FRAME ||
                (writer_b_count - before_b) != BURSTS_PER_FRAME ||
                expected_row != FRAME_H)
                fail("native capture writer transaction count mismatch");
            if ((stream_pixel_count - before_stream_pixels) != FRAME_W * FRAME_H ||
                (stream_sof_count - before_stream_sof) != 1 ||
                (stream_eol_count - before_stream_eol) != FRAME_H ||
                (stream_eof_count - before_stream_eof) != 1)
                fail("native RAW10-to-RGB stream geometry/markers mismatch");
        end
    endtask

    initial begin : main_test
        integer slot;
        repeat (8) @(posedge camera_clk);
        repeat (8) @(posedge core_clk);
        @(negedge camera_clk);
        camera_rst <= 1'b0;
        @(negedge core_clk);
        core_rst <= 1'b0;

        wait (cfg_ready);
        program_gamma_lut();
        if (gamma_write_count != 1024)
            fail("native Gamma LUT programming handshake count mismatch");
        wait (cfg_ready);
        @(negedge core_clk);
        cfg_commit <= 1'b1;
        @(posedge core_clk);
        @(negedge core_clk);
        cfg_commit <= 1'b0;

        for (slot = 0; slot < 3; slot = slot + 1)
            run_slot(slot, 19 + slot*71);

        if (table_ar_count != 3 || table_r_count != 3 ||
            table_response_count != 3)
            fail("three native frame-table lookups did not complete");
        if (writer_aw_count != 3*BURSTS_PER_FRAME ||
            writer_w_count != 3*BEATS_PER_FRAME ||
            writer_b_count != 3*BURSTS_PER_FRAME)
            fail("aggregate native writer AXI count mismatch");
        if (table_ar_stalls == 0 || table_r_delays == 0 ||
            writer_aw_stalls == 0 || writer_w_stalls == 0 ||
            writer_b_delays == 0)
            fail("native staged BFMs did not exercise backpressure");
        if (slot_base(2) + FRAME_BYTES >= 32'h0200_0000)
            fail("native three input slots overlap tensor arena");

        $display("C1_R1_NATIVE_CAPTURE_TABLE_PASS frames=3 sensor=%0dx%0d output=%0dx%0d pixels=%0d sof=%0d eol=%0d eof=%0d gamma=%0d table_ar=%0d table_r=%0d aw=%0d w=%0d b=%0d table_ar_stalls=%0d table_r_delays=%0d aw_stalls=%0d w_stalls=%0d b_delays=%0d slots=%08x/%08x/%08x",
                 SENSOR_W, SENSOR_H, FRAME_W, FRAME_H,
                 stream_pixel_count, stream_sof_count, stream_eol_count,
                 stream_eof_count, gamma_write_count, table_ar_count,
                 table_r_count, writer_aw_count, writer_w_count,
                 writer_b_count, table_ar_stalls, table_r_delays,
                 writer_aw_stalls, writer_w_stalls, writer_b_delays,
                 slot_base(0), slot_base(1), slot_base(2));
        $finish;
    end

    initial begin
        // Keep the timeout below the signed 32-bit unsized-delay limit.
        #100_000_000;
        fail("native capture/table global timeout");
    end
endmodule
