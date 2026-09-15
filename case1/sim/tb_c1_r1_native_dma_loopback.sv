`timescale 1ns/1ps

// Native read/write DMA loopback preflight.
//
// This is the next boardless boundary after the independent native input-DMA
// and capture-writer tests.  A real frame-table reader and XRGB frame reader
// share a real ID-less read arbiter, while the reader stream is connected
// directly to a real XRGB frame writer behind a second real AXI arbiter.  The
// read and write BFMs run concurrently, so the test exercises the ownership
// and backpressure behavior that is hidden by serialized unit tests.  Three
// 640x480 frames are read from the native input slots and written to a
// disjoint output arena; the associative DDR model checks every output pixel.
//
// Deliberate boundary: no CNN, tensor cache, display reader, CSI/RAW10 IP, or
// portable-SoC software job frontend is instantiated here.  This bench proves
// the reusable DMA/AXI seam before those clients are added.
module tb_c1_r1_native_dma_loopback;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer STRIDE = FRAME_W * 4;
    localparam integer FRAME_BYTES = STRIDE * FRAME_H;
    localparam integer SLOT_BYTES = 32'h0012_c000;
    localparam integer ROW_BEATS = FRAME_W / 4;
    localparam integer FRAME_BEATS = FRAME_H * ROW_BEATS;
    localparam integer FRAME_BURSTS = FRAME_H * ((ROW_BEATS + 15) / 16);
    localparam logic [31:0] TABLE_BASE = 32'h0008_0000;
    localparam logic [31:0] INPUT_BASE = 32'h0010_0000;
    localparam logic [31:0] OUTPUT_BASE = 32'h0060_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Frame-table reader (read-arbiter master 0)
    // ------------------------------------------------------------------
    logic table_abort = 1'b0;
    logic table_request_valid = 1'b0;
    logic table_request_ready;
    logic [63:0] table_request_base = TABLE_BASE;
    logic [1:0] table_request_index = '0;
    logic table_response_valid;
    logic table_response_ready = 1'b1;
    logic table_response_error;
    logic [127:0] table_response_raw;
    logic [63:0] table_response_base;
    logic [31:0] table_response_stride;
    logic [15:0] table_response_width;
    logic [15:0] table_response_height;
    logic [31:0] table_araddr;
    logic [7:0] table_arlen;
    logic [2:0] table_arsize;
    logic [1:0] table_arburst;
    logic table_arvalid;
    logic table_arready;
    logic [127:0] table_rdata;
    logic [1:0] table_rresp;
    logic table_rlast;
    logic table_rvalid;
    logic table_rready;

    c1_axi_frame_buffer_table_reader #(.INDEX_BITS(2)) u_table_reader (
        .clk, .rst, .abort(table_abort),
        .request_valid(table_request_valid), .request_ready(table_request_ready),
        .request_table_base(table_request_base),
        .request_entry_index(table_request_index),
        .response_valid(table_response_valid), .response_ready(table_response_ready),
        .response_error(table_response_error), .response_raw(table_response_raw),
        .response_base_address(table_response_base),
        .response_stride_bytes(table_response_stride),
        .response_width_pixels(table_response_width),
        .response_height_lines(table_response_height),
        .m_axi_araddr(table_araddr), .m_axi_arlen(table_arlen),
        .m_axi_arsize(table_arsize), .m_axi_arburst(table_arburst),
        .m_axi_arvalid(table_arvalid), .m_axi_arready(table_arready),
        .m_axi_rdata(table_rdata), .m_axi_rresp(table_rresp),
        .m_axi_rlast(table_rlast), .m_axi_rvalid(table_rvalid),
        .m_axi_rready(table_rready)
    );

    // ------------------------------------------------------------------
    // Native input frame reader (read-arbiter master 1)
    // ------------------------------------------------------------------
    logic reader_start = 1'b0;
    logic reader_cancel = 1'b0;
    logic [31:0] reader_cfg_base = '0;
    logic [15:0] reader_cfg_width = FRAME_W;
    logic [15:0] reader_cfg_height = FRAME_H;
    logic [31:0] reader_cfg_stride = STRIDE;
    logic reader_busy;
    logic reader_done;
    logic reader_error;
    logic reader_m_valid;
    logic reader_m_ready;
    logic [23:0] reader_m_rgb;
    logic reader_m_sof;
    logic reader_m_eol;
    logic reader_m_eof;
    logic [15:0] reader_m_x;
    logic [15:0] reader_m_y;
    logic [31:0] reader_araddr;
    logic [7:0] reader_arlen;
    logic [2:0] reader_arsize;
    logic [1:0] reader_arburst;
    logic reader_arvalid;
    logic reader_arready;
    logic [127:0] reader_rdata;
    logic [1:0] reader_rresp;
    logic reader_rlast;
    logic reader_rvalid;
    logic reader_rready;

    c1_axi_xrgb_frame_reader u_frame_reader (
        .clk, .rst, .start(reader_start), .cancel(reader_cancel),
        .cfg_base_addr(reader_cfg_base),
        .cfg_width_pixels(reader_cfg_width),
        .cfg_height_lines(reader_cfg_height),
        .cfg_stride_bytes(reader_cfg_stride),
        .busy(reader_busy), .done(reader_done), .error(reader_error),
        .m_valid(reader_m_valid), .m_ready(reader_m_ready),
        .m_rgb(reader_m_rgb), .m_sof(reader_m_sof), .m_eol(reader_m_eol),
        .m_eof(reader_m_eof), .m_x(reader_m_x), .m_y(reader_m_y),
        .m_axi_araddr(reader_araddr), .m_axi_arlen(reader_arlen),
        .m_axi_arsize(reader_arsize), .m_axi_arburst(reader_arburst),
         .m_axi_arvalid(reader_arvalid), .m_axi_arready(reader_arready),
         .m_axi_rdata(reader_rdata), .m_axi_rresp(reader_rresp),
         .m_axi_rlast(reader_rlast), .m_axi_rvalid(reader_rvalid),
         .m_axi_rready(reader_rready), .m_axi_ar_allow(1'b1)
     );

    // ------------------------------------------------------------------
    // Native output frame writer (write-arbiter master 0)
    // ------------------------------------------------------------------
    logic writer_start = 1'b0;
    logic writer_cancel = 1'b0;
    logic [31:0] writer_cfg_base = '0;
    logic [15:0] writer_cfg_width = FRAME_W;
    logic [15:0] writer_cfg_height = FRAME_H;
    logic [31:0] writer_cfg_stride = STRIDE;
    logic writer_busy;
    logic writer_done;
    logic writer_error;
    logic writer_s_valid;
    logic writer_s_ready;
    logic [23:0] writer_s_rgb;
    logic writer_s_sof;
    logic writer_s_eol;
    logic writer_s_eof;
    logic [31:0] writer_awaddr;
    logic [7:0] writer_awlen;
    logic [2:0] writer_awsize;
    logic [1:0] writer_awburst;
    logic writer_awvalid;
    logic [127:0] writer_wdata;
    logic [15:0] writer_wstrb;
    logic writer_wlast;
    logic writer_wvalid;
    logic writer_bready;

    // The logical loopback is a real ready/valid connection.  The writer's
    // burst-buffer and B-response stalls propagate to the reader; only the
    // simulation shell below registers the BFM-facing edges.
    assign writer_s_valid = reader_m_valid;
    assign writer_s_rgb = reader_m_rgb;
    assign writer_s_sof = reader_m_sof;
    assign writer_s_eol = reader_m_eol;
    assign writer_s_eof = reader_m_eof;
    assign reader_m_ready = writer_s_ready;

    // Keep arbiter-side nets separate from the writer.  The one-entry bridge
    // below absorbs the arbiter's clocked grant/READY delta cycle.
    logic arb_writer_awready;
    logic arb_writer_wready;
    logic [1:0] arb_writer_bresp;
    logic arb_writer_bvalid;
    logic writer_awready_shell;
    logic writer_wready_shell;
    logic [1:0] writer_bresp_shell;
    logic writer_bvalid_shell;
    wire bridge_s_awready;
    wire bridge_s_wready;
    wire [1:0] bridge_s_bresp;
    wire bridge_s_bvalid;
    logic [31:0] bridge_m_awaddr;
    logic [7:0] bridge_m_awlen;
    logic [2:0] bridge_m_awsize;
    logic [1:0] bridge_m_awburst;
    logic bridge_m_awvalid;
    wire bridge_m_bready;
    logic bridge_m_awready;
    logic [127:0] bridge_m_wdata;
    logic [15:0] bridge_m_wstrb;
    logic bridge_m_wlast;
    logic bridge_m_wvalid;
    logic bridge_m_wready;
    logic [1:0] bridge_m_bresp;
    logic bridge_m_bvalid;
    // Simulation-side clocked seam: sample the arbiter's downstream response
    // signals at the opposite edge so the synchronous bridge never observes
    // a grant/state delta-cycle transition as X.  This models the registered
    // AXI shell used only at the simulation/BFM boundary.  It represents the
    // registered vendor-facing shell boundary, not an extra native datapath.
    always @(negedge clk) begin
        if (rst) begin
            writer_awready_shell <= 1'b0;
            writer_wready_shell <= 1'b0;
            writer_bresp_shell <= 2'b00;
            writer_bvalid_shell <= 1'b0;
            bridge_m_awready <= 1'b0;
            bridge_m_wready <= 1'b0;
            bridge_m_bresp <= 2'b00;
            bridge_m_bvalid <= 1'b0;
        end else begin
            writer_awready_shell <= bridge_s_awready;
            writer_wready_shell <= bridge_s_wready;
            writer_bresp_shell <= bridge_s_bresp;
            writer_bvalid_shell <= bridge_s_bvalid;
            bridge_m_awready <= arb_writer_awready;
            bridge_m_wready <= arb_writer_wready;
            bridge_m_bresp <= arb_writer_bresp;
            bridge_m_bvalid <= arb_writer_bvalid;
        end
    end

    c1_axi_xrgb_frame_writer u_frame_writer (
        .clk, .rst, .start(writer_start), .cancel(writer_cancel),
        .cfg_base_addr(writer_cfg_base),
        .cfg_width_pixels(writer_cfg_width),
        .cfg_height_lines(writer_cfg_height),
        .cfg_stride_bytes(writer_cfg_stride),
        .busy(writer_busy), .done(writer_done), .error(writer_error),
        .s_valid(writer_s_valid), .s_ready(writer_s_ready),
        .s_rgb(writer_s_rgb), .s_sof(writer_s_sof), .s_eol(writer_s_eol),
        .s_eof(writer_s_eof),
        .m_axi_awaddr(writer_awaddr), .m_axi_awlen(writer_awlen),
        .m_axi_awsize(writer_awsize), .m_axi_awburst(writer_awburst),
        .m_axi_awvalid(writer_awvalid), .m_axi_awready(writer_awready_shell),
        .m_axi_wdata(writer_wdata), .m_axi_wstrb(writer_wstrb),
        .m_axi_wlast(writer_wlast), .m_axi_wvalid(writer_wvalid),
        .m_axi_wready(writer_wready_shell), .m_axi_bresp(writer_bresp_shell),
        .m_axi_bvalid(writer_bvalid_shell), .m_axi_bready(writer_bready)
    );

    c1_axi_write_skid_bridge u_write_bridge (
        .clk, .rst,
        .s_awaddr(writer_awaddr), .s_awlen(writer_awlen),
        .s_awsize(writer_awsize), .s_awburst(writer_awburst),
        .s_awvalid(writer_awvalid), .s_awready(bridge_s_awready),
        .s_wdata(writer_wdata), .s_wstrb(writer_wstrb),
        .s_wlast(writer_wlast), .s_wvalid(writer_wvalid),
        .s_wready(bridge_s_wready), .s_bresp(bridge_s_bresp),
        .s_bvalid(bridge_s_bvalid), .s_bready(writer_bready),
        .m_awaddr(bridge_m_awaddr), .m_awlen(bridge_m_awlen),
        .m_awsize(bridge_m_awsize), .m_awburst(bridge_m_awburst),
        .m_awvalid(bridge_m_awvalid), .m_awready(bridge_m_awready),
        .m_wdata(bridge_m_wdata), .m_wstrb(bridge_m_wstrb),
        .m_wlast(bridge_m_wlast), .m_wvalid(bridge_m_wvalid),
        .m_wready(bridge_m_wready), .m_bresp(bridge_m_bresp),
        .m_bvalid(bridge_m_bvalid), .m_bready(bridge_m_bready)
    );

    // ------------------------------------------------------------------
    // Real read arbiter: table lookup and raster reader.
    // ------------------------------------------------------------------
    logic [31:0] rd_m_araddr;
    logic [7:0] rd_m_arlen;
    logic [2:0] rd_m_arsize;
    logic [1:0] rd_m_arburst;
    logic rd_m_arvalid;
    logic rd_m_arready;
    logic [127:0] rd_m_rdata;
    logic [1:0] rd_m_rresp;
    logic rd_m_rlast;
    logic rd_m_rvalid;
    logic rd_m_rready;

    c1_axi2_serial_arbiter_128 u_read_arbiter (
        .clk, .rst,
        .s0_awaddr('0), .s0_awlen('0), .s0_awsize('0), .s0_awburst('0),
        .s0_awvalid(1'b0), .s0_awready(), .s0_wdata('0), .s0_wstrb('0),
        .s0_wlast(1'b0), .s0_wvalid(1'b0), .s0_wready(),
        .s0_bresp(), .s0_bvalid(), .s0_bready(1'b0),
        .s0_araddr(table_araddr), .s0_arlen(table_arlen),
        .s0_arsize(table_arsize), .s0_arburst(table_arburst),
        .s0_arvalid(table_arvalid), .s0_arready(table_arready),
        .s0_rdata(table_rdata), .s0_rresp(table_rresp),
        .s0_rlast(table_rlast), .s0_rvalid(table_rvalid),
        .s0_rready(table_rready),
        .s1_awaddr('0), .s1_awlen('0), .s1_awsize('0), .s1_awburst('0),
        .s1_awvalid(1'b0), .s1_awready(), .s1_wdata('0), .s1_wstrb('0),
        .s1_wlast(1'b0), .s1_wvalid(1'b0), .s1_wready(),
        .s1_bresp(), .s1_bvalid(), .s1_bready(1'b0),
        .s1_araddr(reader_araddr), .s1_arlen(reader_arlen),
        .s1_arsize(reader_arsize), .s1_arburst(reader_arburst),
        .s1_arvalid(reader_arvalid), .s1_arready(reader_arready),
        .s1_rdata(reader_rdata), .s1_rresp(reader_rresp),
        .s1_rlast(reader_rlast), .s1_rvalid(reader_rvalid),
        .s1_rready(reader_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(),
        .m_awready(1'b0), .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(),
        .m_wready(1'b0), .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready(),
        .m_araddr(rd_m_araddr), .m_arlen(rd_m_arlen), .m_arsize(rd_m_arsize),
        .m_arburst(rd_m_arburst), .m_arvalid(rd_m_arvalid),
        .m_arready(rd_m_arready), .m_rdata(rd_m_rdata), .m_rresp(rd_m_rresp),
        .m_rlast(rd_m_rlast), .m_rvalid(rd_m_rvalid), .m_rready(rd_m_rready)
    );

    // ------------------------------------------------------------------
    // Real write arbiter: writer master 0; master 1 is intentionally idle.
    // ------------------------------------------------------------------
    logic [31:0] wr_m_awaddr;
    logic [7:0] wr_m_awlen;
    logic [2:0] wr_m_awsize;
    logic [1:0] wr_m_awburst;
    logic wr_m_awvalid;
    logic wr_m_awready;
    logic [127:0] wr_m_wdata;
    logic [15:0] wr_m_wstrb;
    logic wr_m_wlast;
    logic wr_m_wvalid;
    logic wr_m_wready;
    wire [1:0] wr_m_bresp;
    wire wr_m_bvalid;
    logic wr_m_bready;

    c1_axi2_serial_arbiter_128 u_write_arbiter (
        .clk, .rst,
        .s0_awaddr(bridge_m_awaddr), .s0_awlen(bridge_m_awlen),
        .s0_awsize(bridge_m_awsize), .s0_awburst(bridge_m_awburst),
        .s0_awvalid(bridge_m_awvalid), .s0_awready(arb_writer_awready),
        .s0_wdata(bridge_m_wdata), .s0_wstrb(bridge_m_wstrb),
        .s0_wlast(bridge_m_wlast), .s0_wvalid(bridge_m_wvalid),
        .s0_wready(arb_writer_wready), .s0_bresp(arb_writer_bresp),
        .s0_bvalid(arb_writer_bvalid), .s0_bready(bridge_m_bready),
        .s0_araddr('0), .s0_arlen('0), .s0_arsize('0), .s0_arburst('0),
        .s0_arvalid(1'b0), .s0_arready(), .s0_rdata(), .s0_rresp(),
        .s0_rlast(), .s0_rvalid(), .s0_rready(1'b0),
        .s1_awaddr('0), .s1_awlen('0), .s1_awsize('0), .s1_awburst('0),
        .s1_awvalid(1'b0), .s1_awready(), .s1_wdata('0), .s1_wstrb('0),
        .s1_wlast(1'b0), .s1_wvalid(1'b0), .s1_wready(),
        .s1_bresp(), .s1_bvalid(), .s1_bready(1'b0),
        .s1_araddr('0), .s1_arlen('0), .s1_arsize('0), .s1_arburst('0),
        .s1_arvalid(1'b0), .s1_arready(), .s1_rdata(), .s1_rresp(),
        .s1_rlast(), .s1_rvalid(), .s1_rready(1'b0),
        .m_awaddr(wr_m_awaddr), .m_awlen(wr_m_awlen), .m_awsize(wr_m_awsize),
        .m_awburst(wr_m_awburst), .m_awvalid(wr_m_awvalid),
        .m_awready(wr_m_awready), .m_wdata(wr_m_wdata), .m_wstrb(wr_m_wstrb),
        .m_wlast(wr_m_wlast), .m_wvalid(wr_m_wvalid), .m_wready(wr_m_wready),
        .m_bresp(wr_m_bresp), .m_bvalid(wr_m_bvalid), .m_bready(wr_m_bready),
        .m_araddr(), .m_arlen(), .m_arsize(), .m_arburst(), .m_arvalid(),
        .m_arready(1'b0), .m_rdata(), .m_rresp(), .m_rlast(), .m_rvalid(),
        .m_rready()
    );

    // ------------------------------------------------------------------
    // Helpers and deterministic pixel model.
    // ------------------------------------------------------------------
    function automatic [31:0] input_slot_base(input integer slot);
        input_slot_base = INPUT_BASE + slot * SLOT_BYTES;
    endfunction

    function automatic [31:0] output_slot_base(input integer slot);
        output_slot_base = OUTPUT_BASE + slot * SLOT_BYTES;
    endfunction

    function automatic [23:0] pixel_value(input integer slot,
                                           input integer x,
                                           input integer y);
        reg [7:0] red;
        reg [7:0] green;
        reg [7:0] blue;
        begin
            red = slot*8'h29 + x*3 + y*17;
            green = slot*8'h53 + x*11 + y*5;
            blue = slot*8'h87 + x*7 + y*13;
            pixel_value = {red, green, blue};
        end
    endfunction

    function automatic [127:0] table_entry(input integer slot);
        table_entry = {16'd480, 16'd640, 32'h0000_0a00,
                       32'd0, input_slot_base(slot)};
    endfunction

    function automatic [127:0] input_frame_beat(input integer address,
                                                input integer slot,
                                                input integer beat_index);
        integer lane;
        integer pixel_index;
        integer px;
        integer py;
        begin
            input_frame_beat = '0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                pixel_index = ((address - input_slot_base(slot)) +
                               beat_index*16 + lane*4) / 4;
                px = pixel_index % FRAME_W;
                py = pixel_index / FRAME_W;
                input_frame_beat[lane*32 +: 32] =
                    {8'h00, pixel_value(slot, px, py)};
            end
        end
    endfunction

    // Keep diagnostic-task references visible to Vivado xvlog at the point
    // of declaration (xvlog does not defer module-scope identifier lookup).
    logic failure_seen = 1'b0;
    integer active_model_slot = 0;
    integer stream_pixel_count = 0;
    integer frame_ar_count = 0;
    integer total_aw_count = 0;

    task automatic fail(input string message);
        begin
            if (!failure_seen) begin
                failure_seen = 1'b1;
                $display("C1_R1_NATIVE_DMA_LOOPBACK_FAIL time=%0t slot=%0d rd_ar=%0d wr_aw=%0d pixels=%0d: %s",
                         $time, active_model_slot, frame_ar_count,
                         total_aw_count, stream_pixel_count, message);
                $fatal(1);
                $finish;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Read-side AXI BFM.  It is address-aware and allows table lookups to
    // contend with raster bursts while a write is progressing independently.
    // ------------------------------------------------------------------
    integer cycle_count = 0;
    integer shared_rd_ar_count = 0;
    integer shared_rd_r_count = 0;
    integer table_ar_count = 0;
    integer table_r_count = 0;
    integer frame_r_count = 0;
    integer ar_stall_count = 0;
    integer r_stall_count = 0;
    integer r_gap_count = 0;
    integer table_active_slot = 0;
    integer rd_active_kind = -1; // 0=table, 1=frame
    integer rd_active_slot = 0;
    integer rd_active_ar_addr = 0;
    integer rd_active_ar_beats = 0;
    integer rd_active_r_index = 0;
    integer rd_delay = 0;
    logic rd_burst_active = 1'b0;
    logic [127:0] rd_rdata_reg = '0;
    logic [1:0] rd_rresp_reg = 2'b00;
    logic rd_rlast_reg = 1'b0;
    logic rd_rvalid_reg = 1'b0;

    integer frame_expected_next_addr = INPUT_BASE;
    integer frame_expected_row = 0;
    integer frame_expected_row_bytes = STRIDE;
    integer frame_expected_slot = 0;

    assign rd_m_rdata = rd_rdata_reg;
    assign rd_m_rresp = rd_rresp_reg;
    assign rd_m_rlast = rd_rlast_reg;
    assign rd_m_rvalid = rd_rvalid_reg;

    always_comb begin
        rd_m_arready = !rd_burst_active && !rd_rvalid_reg &&
                       ((cycle_count % 23) != 0);
    end

    // ------------------------------------------------------------------
    // Write-side AXI BFM and associative output DDR model.
    // ------------------------------------------------------------------
    logic [127:0] output_mem [longint unsigned];
    integer wr_burst_active = 0;
    integer wr_active_aw_addr = 0;
    integer wr_active_aw_beats = 0;
    integer wr_active_w_index = 0;
    logic wr_response_pending = 1'b0;
    integer wr_response_delay = 0;
    logic wr_bvalid_reg = 1'b0;
    logic [1:0] wr_bresp_reg = 2'b00;
    integer write_expected_next_addr = OUTPUT_BASE;
    integer write_expected_row = 0;
    integer write_expected_row_bytes = STRIDE;
    integer active_input_slot = 0;
    logic write_model_active = 1'b0;
    integer write_aw_count = 0;
    integer write_w_count = 0;
    integer write_b_count = 0;
    integer write_aw_stall_count = 0;
    integer write_w_stall_count = 0;
    integer write_b_delay_count = 0;

    assign wr_m_bvalid = wr_bvalid_reg;
    assign wr_m_bresp = wr_bresp_reg;


    integer stream_stall_count = 0;
    integer stream_sof_count = 0;
    integer stream_eol_count = 0;
    integer stream_eof_count = 0;
    integer writer_done_count = 0;
    integer reader_done_count = 0;
    integer expected_x = 0;
    integer expected_y = 0;
    logic stream_held = 1'b0;
    logic [23:0] held_rgb = '0;
    logic held_sof = 1'b0;
    logic held_eol = 1'b0;
    logic held_eof = 1'b0;
    integer frame_stream_count = 0;
    integer frame_stream_sof = 0;
    integer frame_stream_eol = 0;
    integer frame_stream_eof = 0;

    always @(posedge clk) begin : read_axi_bfm
        integer idx;
        integer planned_beats;
        integer burst_bytes;
        integer row_offset;
        integer boundary_beats;
        if (rst) begin
            cycle_count <= 0;
            rd_burst_active <= 1'b0;
            rd_rvalid_reg <= 1'b0;
            rd_rdata_reg <= '0;
            rd_rresp_reg <= 2'b00;
            rd_rlast_reg <= 1'b0;
            rd_active_kind <= -1;
            rd_active_r_index <= 0;
            rd_delay <= 0;
            shared_rd_ar_count <= 0;
            shared_rd_r_count <= 0;
            table_ar_count <= 0;
            table_r_count <= 0;
            frame_ar_count <= 0;
            frame_r_count <= 0;
            ar_stall_count <= 0;
            r_stall_count <= 0;
            r_gap_count <= 0;
            frame_expected_next_addr <= INPUT_BASE;
            frame_expected_row <= 0;
            frame_expected_row_bytes <= STRIDE;
        end else begin
            cycle_count <= cycle_count + 1;
            if (rd_m_arvalid && !rd_m_arready)
                ar_stall_count <= ar_stall_count + 1;
            if (rd_m_rvalid && !rd_m_rready)
                r_stall_count <= r_stall_count + 1;

            if (rd_m_arvalid && rd_m_arready) begin
                if (rd_burst_active || rd_rvalid_reg)
                    fail("read BFM accepted AR while prior burst was active");
                if ((rd_m_arsize != 3'd4) || (rd_m_arburst != 2'b01) ||
                    (rd_m_araddr[3:0] != 0))
                    fail("read AR attributes/alignment invalid");
                rd_active_ar_addr <= rd_m_araddr;
                rd_active_r_index <= 0;
                rd_active_kind <= -1;
                rd_active_slot <= 0;
                if ((rd_m_araddr >= TABLE_BASE) &&
                    (rd_m_araddr < TABLE_BASE + 3*16)) begin
                    if (rd_m_arlen != 0 || ((rd_m_araddr - TABLE_BASE) & 15) != 0)
                        fail("table AR is not one aligned beat");
                    idx = (rd_m_araddr - TABLE_BASE) >> 4;
                    if (idx < 0 || idx > 2)
                        fail("table AR index outside native table");
                    rd_active_kind <= 0;
                    rd_active_slot <= idx;
                    rd_active_ar_beats <= 1;
                    table_ar_count <= table_ar_count + 1;
                end else begin
                    if (rd_m_arlen > 8'd15)
                        fail("input AR burst exceeds 16 beats");
                    if ((rd_m_araddr < input_slot_base(frame_expected_slot)) ||
                        (rd_m_araddr >= input_slot_base(frame_expected_slot) + FRAME_BYTES))
                        fail("input AR outside active slot");
                    if (rd_m_araddr !== frame_expected_next_addr[31:0])
                        fail("input AR address skipped or reordered");
                    boundary_beats = (4096 - (rd_m_araddr & 4095)) / 16;
                    planned_beats = 16;
                    if ((frame_expected_row_bytes / 16) < planned_beats)
                        planned_beats = frame_expected_row_bytes / 16;
                    if (boundary_beats < planned_beats)
                        planned_beats = boundary_beats;
                    if ((rd_m_arlen + 1) != planned_beats)
                        fail("input ARLEN row/4KiB plan mismatch");
                    burst_bytes = planned_beats * 16;
                    if (((rd_m_araddr & 4095) + burst_bytes) > 4096)
                        fail("input burst crosses 4KiB boundary");
                    row_offset = rd_m_araddr -
                                 (input_slot_base(frame_expected_slot) +
                                  frame_expected_row*STRIDE);
                    if (row_offset + burst_bytes > STRIDE)
                        fail("input burst crosses row boundary");
                    rd_active_kind <= 1;
                    rd_active_slot <= frame_expected_slot;
                    rd_active_ar_beats <= planned_beats;
                    frame_ar_count <= frame_ar_count + 1;
                    if (frame_expected_row_bytes == burst_bytes) begin
                        frame_expected_row <= frame_expected_row + 1;
                        if (frame_expected_row + 1 < FRAME_H) begin
                            frame_expected_next_addr <=
                                input_slot_base(frame_expected_slot) +
                                (frame_expected_row + 1)*STRIDE;
                            frame_expected_row_bytes <= STRIDE;
                        end else begin
                            frame_expected_row_bytes <= 0;
                        end
                    end else begin
                        frame_expected_next_addr <=
                            frame_expected_next_addr + burst_bytes;
                        frame_expected_row_bytes <=
                            frame_expected_row_bytes - burst_bytes;
                    end
                end
                rd_burst_active <= 1'b1;
                rd_delay <= 1 + (cycle_count % 3);
                shared_rd_ar_count <= shared_rd_ar_count + 1;
            end

            if (rd_m_rvalid && rd_m_rready) begin
                if (!rd_burst_active)
                    fail("read R handshake without active burst");
                if (rd_m_rlast !== (rd_active_r_index == rd_active_ar_beats-1))
                    fail("read RLAST disagrees with ARLEN");
                shared_rd_r_count <= shared_rd_r_count + 1;
                if (rd_active_kind == 0)
                    table_r_count <= table_r_count + 1;
                else if (rd_active_kind == 1)
                    frame_r_count <= frame_r_count + 1;
                if (rd_m_rlast || (rd_active_r_index == rd_active_ar_beats-1)) begin
                    rd_burst_active <= 1'b0;
                    rd_rvalid_reg <= 1'b0;
                    rd_rlast_reg <= 1'b0;
                end else begin
                    rd_active_r_index <= rd_active_r_index + 1;
                    rd_rvalid_reg <= 1'b0;
                    rd_rlast_reg <= 1'b0;
                    rd_delay <= 0;
                end
            end else if (!rd_rvalid_reg && rd_burst_active) begin
                if (rd_delay > 0) begin
                    rd_delay <= rd_delay - 1;
                    r_gap_count <= r_gap_count + 1;
                end else begin
                    if (rd_active_kind == 0)
                        rd_rdata_reg <= table_entry(rd_active_slot);
                    else
                        rd_rdata_reg <= input_frame_beat(rd_active_ar_addr,
                                                          rd_active_slot,
                                                          rd_active_r_index);
                    rd_rresp_reg <= 2'b00;
                    rd_rlast_reg <= (rd_active_r_index == rd_active_ar_beats-1);
                    rd_rvalid_reg <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin : write_axi_bfm
        integer planned_beats;
        integer burst_bytes;
        integer lane;
        integer byte_lane;
        integer expected_pixel_offset;
        integer pixel_index;
        integer px;
        integer py;
        longint unsigned assoc_key;
        logic [127:0] expected_data;
        logic [31:0] expected_pixel_addr;
        if (rst) begin
            wr_burst_active <= 0;
            wr_response_pending <= 1'b0;
            wr_bvalid_reg <= 1'b0;
            wr_bresp_reg <= 2'b00;
            wr_m_awready <= 1'b0;
            wr_m_wready <= 1'b0;
            wr_active_w_index <= 0;
            write_aw_count <= 0;
            write_w_count <= 0;
            write_b_count <= 0;
            write_aw_stall_count <= 0;
            write_w_stall_count <= 0;
            write_b_delay_count <= 0;
            write_expected_next_addr <= OUTPUT_BASE;
            write_expected_row <= 0;
            write_expected_row_bytes <= STRIDE;
            write_model_active <= 1'b0;
        end else begin
            // Registered downstream READY avoids a combinational delta-cycle
            // race with the serial arbiter's grant/state transition.
            wr_m_awready <= !wr_burst_active && !wr_response_pending &&
                            !wr_bvalid_reg && ((cycle_count % 11) != 0);
            wr_m_wready <= wr_burst_active && !wr_response_pending &&
                           !wr_bvalid_reg && ((cycle_count % 7) != 0);
            if (wr_m_awvalid && !wr_m_awready)
                write_aw_stall_count <= write_aw_stall_count + 1;
            if (wr_m_wvalid && !wr_m_wready)
                write_w_stall_count <= write_w_stall_count + 1;

            if (writer_start && !writer_busy) begin
                active_input_slot <= active_model_slot;
                write_expected_next_addr <= output_slot_base(active_model_slot);
                write_expected_row <= 0;
                write_expected_row_bytes <= STRIDE;
                write_aw_count <= 0;
                write_w_count <= 0;
                write_b_count <= 0;
                write_model_active <= 1'b1;
            end

            if (wr_m_awvalid && wr_m_awready) begin
                if (!write_model_active)
                    fail("AW issued without active loopback write model");
                if (wr_burst_active || wr_response_pending || wr_bvalid_reg)
                    fail("new AW issued before previous B response");
                if (wr_m_awaddr !== write_expected_next_addr[31:0])
                    fail("output AW address sequence mismatch");
                if ((wr_m_awsize != 3'd4) || (wr_m_awburst != 2'b01) ||
                    (wr_m_awaddr[3:0] != 0))
                    fail("output AW attributes/alignment invalid");
                if ((wr_m_awaddr < output_slot_base(active_input_slot)) ||
                    (wr_m_awaddr >= output_slot_base(active_input_slot) + FRAME_BYTES))
                    fail("output AW outside active output slot");
                if (wr_m_awlen > 8'd15)
                    fail("output AW burst exceeds 16 beats");
                planned_beats = 16;
                if ((write_expected_row_bytes / 16) < planned_beats)
                    planned_beats = write_expected_row_bytes / 16;
                if (((4096 - (wr_m_awaddr & 4095)) / 16) < planned_beats)
                    planned_beats = (4096 - (wr_m_awaddr & 4095)) / 16;
                if ((wr_m_awlen + 1) != planned_beats)
                    fail("output AWLEN row/4KiB plan mismatch");
                burst_bytes = planned_beats * 16;
                if (((wr_m_awaddr & 4095) + burst_bytes) > 4096)
                    fail("output burst crosses 4KiB boundary");
                if ((wr_m_awaddr - output_slot_base(active_input_slot)) -
                    (write_expected_row * STRIDE) + burst_bytes > STRIDE)
                    fail("output burst crosses row boundary");
                wr_burst_active <= 1;
                wr_active_aw_addr <= wr_m_awaddr;
                wr_active_aw_beats <= planned_beats;
                wr_active_w_index <= 0;
                write_aw_count <= write_aw_count + 1;
                total_aw_count <= total_aw_count + 1;
                if (write_expected_row_bytes == burst_bytes) begin
                    write_expected_row <= write_expected_row + 1;
                    if (write_expected_row + 1 < FRAME_H) begin
                        write_expected_next_addr <=
                            output_slot_base(active_input_slot) +
                            (write_expected_row + 1)*STRIDE;
                        write_expected_row_bytes <= STRIDE;
                    end else begin
                        write_expected_row_bytes <= 0;
                    end
                end else begin
                    write_expected_next_addr <= write_expected_next_addr + burst_bytes;
                    write_expected_row_bytes <= write_expected_row_bytes - burst_bytes;
                end
            end

            if (wr_m_wvalid && wr_m_wready) begin
                if (!wr_burst_active)
                    fail("W accepted without active output AW");
                if (wr_m_wstrb !== 16'hffff)
                    fail("output WSTRB is not full");
                if (wr_m_wlast !== (wr_active_w_index == wr_active_aw_beats-1))
                    fail("output WLAST mismatch");
                expected_data = '0;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    expected_pixel_offset = (wr_active_aw_addr -
                                              output_slot_base(active_input_slot)) +
                                             wr_active_w_index*16 + lane*4;
                    pixel_index = expected_pixel_offset / 4;
                    px = pixel_index % FRAME_W;
                    py = pixel_index / FRAME_W;
                    expected_pixel_addr = input_slot_base(active_input_slot) +
                                          py*STRIDE + px*4;
                    expected_data[lane*32 +: 32] =
                        {8'h00, pixel_value(active_input_slot, px, py)};
                end
                if (wr_m_wdata !== expected_data)
                    fail("loopback packed WDATA/pixel mismatch");
                assoc_key = (wr_active_aw_addr + wr_active_w_index*16) >> 4;
                if (!output_mem.exists(assoc_key))
                    output_mem[assoc_key] = '0;
                for (byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1)
                    if (wr_m_wstrb[byte_lane])
                        output_mem[assoc_key][byte_lane*8 +: 8] =
                            wr_m_wdata[byte_lane*8 +: 8];
                write_w_count <= write_w_count + 1;
                if (wr_m_wlast) begin
                    wr_burst_active <= 0;
                    wr_response_pending <= 1'b1;
                    wr_response_delay <= 1 + (cycle_count % 5);
                    wr_bresp_reg <= 2'b00;
                end else begin
                    wr_active_w_index <= wr_active_w_index + 1;
                end
            end

            if (wr_bvalid_reg && wr_m_bready) begin
                wr_bvalid_reg <= 1'b0;
                write_b_count <= write_b_count + 1;
            end else if (!wr_bvalid_reg && wr_response_pending) begin
                if (wr_response_delay > 0) begin
                    wr_response_delay <= wr_response_delay - 1;
                    write_b_delay_count <= write_b_delay_count + 1;
                end else begin
                    wr_bvalid_reg <= 1'b1;
                    wr_response_pending <= 1'b0;
                end
            end
        end
    end


    // Stream scoreboard and source hold monitor.
    always @(posedge clk) begin
        integer expected_rgb;
        if (rst) begin
            stream_pixel_count <= 0;
            stream_stall_count <= 0;
            stream_sof_count <= 0;
            stream_eol_count <= 0;
            stream_eof_count <= 0;
            writer_done_count <= 0;
            reader_done_count <= 0;
            expected_x <= 0;
            expected_y <= 0;
            stream_held <= 1'b0;
            frame_stream_count <= 0;
            frame_stream_sof <= 0;
            frame_stream_eol <= 0;
            frame_stream_eof <= 0;
        end else begin
            if (stream_held && !reader_m_ready) begin
                if (!reader_m_valid || reader_m_rgb !== held_rgb ||
                    reader_m_sof !== held_sof || reader_m_eol !== held_eol ||
                    reader_m_eof !== held_eof)
                    fail("loopback stream changed while writer backpressured");
            end
            if (reader_m_valid && !reader_m_ready)
                stream_stall_count <= stream_stall_count + 1;
            stream_held <= reader_m_valid && !reader_m_ready;
            held_rgb <= reader_m_rgb;
            held_sof <= reader_m_sof;
            held_eol <= reader_m_eol;
            held_eof <= reader_m_eof;

            if (reader_m_valid && reader_m_ready) begin
                expected_rgb = pixel_value(active_model_slot, expected_x, expected_y);
                if (reader_m_rgb !== expected_rgb[23:0])
                    fail("loopback reader RGB mismatch");
                if (reader_m_x !== expected_x[15:0] ||
                    reader_m_y !== expected_y[15:0])
                    fail("loopback coordinate mismatch");
                if (reader_m_sof !== ((expected_x == 0) && (expected_y == 0)))
                    fail("loopback SOF mismatch");
                if (reader_m_eol !== (expected_x == FRAME_W-1))
                    fail("loopback EOL mismatch");
                if (reader_m_eof !== ((expected_x == FRAME_W-1) &&
                                      (expected_y == FRAME_H-1)))
                    fail("loopback EOF mismatch");
                stream_pixel_count <= stream_pixel_count + 1;
                frame_stream_count <= frame_stream_count + 1;
                if (reader_m_sof) begin
                    stream_sof_count <= stream_sof_count + 1;
                    frame_stream_sof <= frame_stream_sof + 1;
                end
                if (reader_m_eol) begin
                    stream_eol_count <= stream_eol_count + 1;
                    frame_stream_eol <= frame_stream_eol + 1;
                end
                if (reader_m_eof) begin
                    stream_eof_count <= stream_eof_count + 1;
                    frame_stream_eof <= frame_stream_eof + 1;
                end
                if (expected_x == FRAME_W-1) begin
                    expected_x <= 0;
                    expected_y <= expected_y + 1;
                end else begin
                    expected_x <= expected_x + 1;
                end
            end
            if (writer_done)
                writer_done_count <= writer_done_count + 1;
            if (reader_done)
                reader_done_count <= reader_done_count + 1;
            if (reader_error || writer_error)
                fail("native loopback reader/writer asserted error");
        end
    end

    // ------------------------------------------------------------------
    // Table and frame control tasks.
    // ------------------------------------------------------------------
    integer table_seen_count = 0;
    logic table_seen [0:2];
    logic [31:0] desc_base [0:2];
    logic [31:0] desc_stride [0:2];
    logic [15:0] desc_width [0:2];
    logic [15:0] desc_height [0:2];

    always @(posedge clk) begin
        if (!rst && table_response_valid && table_response_ready) begin
            if (table_response_error || table_response_base[63:32] != 0)
                fail("table response reported error/high address");
            if (table_response_base[31:0] !== input_slot_base(table_active_slot) ||
                table_response_stride !== STRIDE ||
                table_response_width !== FRAME_W ||
                table_response_height !== FRAME_H)
                fail("table descriptor fields mismatch");
            desc_base[table_active_slot] <= table_response_base[31:0];
            desc_stride[table_active_slot] <= table_response_stride;
            desc_width[table_active_slot] <= table_response_width;
            desc_height[table_active_slot] <= table_response_height;
            table_seen[table_active_slot] <= 1'b1;
            table_seen_count <= table_seen_count + 1;
        end
    end

    task automatic request_table(input integer slot);
        integer guard;
        begin
            table_active_slot = slot;
            @(negedge clk);
            table_request_index <= slot[1:0];
            table_request_base <= TABLE_BASE;
            table_request_valid <= 1'b1;
            guard = 0;
            while (!table_request_ready) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("table request-ready timeout");
            end
            @(negedge clk);
            table_request_valid <= 1'b0;
            while (!table_seen[slot]) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("table response timeout");
            end
        end
    endtask

    task automatic start_frame(input integer slot);
        integer guard;
        begin
            guard = 0;
            while (reader_busy || writer_busy) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("DMA clients remained busy before next frame");
            end
            active_model_slot = slot;
            frame_expected_slot = slot;
            frame_expected_next_addr = input_slot_base(slot);
            frame_expected_row = 0;
            frame_expected_row_bytes = STRIDE;
            expected_x = 0;
            expected_y = 0;
            frame_stream_count = 0;
            frame_stream_sof = 0;
            frame_stream_eol = 0;
            frame_stream_eof = 0;
            @(negedge clk);
            reader_cfg_base <= desc_base[slot];
            reader_cfg_stride <= desc_stride[slot];
            reader_cfg_width <= desc_width[slot];
            reader_cfg_height <= desc_height[slot];
            writer_cfg_base <= output_slot_base(slot);
            writer_cfg_stride <= STRIDE;
            writer_cfg_width <= FRAME_W;
            writer_cfg_height <= FRAME_H;
            reader_start <= 1'b1;
            writer_start <= 1'b1;
            @(negedge clk);
            reader_start <= 1'b0;
            writer_start <= 1'b0;
        end
    endtask

    task automatic readback_frame(input integer slot);
        integer x, y, lane;
        longint unsigned key;
        logic [127:0] line;
        begin
            for (y = 0; y < FRAME_H; y = y + 1) begin
                for (x = 0; x < FRAME_W; x = x + 1) begin
                    key = (output_slot_base(slot) + y*STRIDE + x*4) >> 4;
                    if (!output_mem.exists(key))
                        fail("output associative DDR line missing");
                    line = output_mem[key];
                    lane = x & 3;
                    if (line[lane*32 +: 32] !==
                        {8'h00, pixel_value(slot, x, y)})
                        fail("output readback pixel mismatch");
                end
            end
        end
    endtask

    task automatic wait_frame_done(input integer slot);
        integer guard;
        integer before_reader;
        integer before_writer;
        begin
            before_reader = reader_done_count;
            before_writer = writer_done_count;
            guard = 0;
            while ((reader_done_count == before_reader) ||
                   (writer_done_count == before_writer)) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000000)
                    fail("native read/write loopback completion timeout");
            end
            #0.1;
            if (reader_busy || writer_busy || reader_error || writer_error)
                fail("native loopback ended busy/error");
            if (frame_stream_count != FRAME_W*FRAME_H ||
                frame_stream_sof != 1 || frame_stream_eol != FRAME_H ||
                frame_stream_eof != 1)
                fail("loopback stream geometry/marker count mismatch");
            if (frame_expected_row != FRAME_H ||
                write_expected_row != FRAME_H)
                fail("read/write address planners did not complete all rows");
            if (write_aw_count != FRAME_BURSTS ||
                write_w_count != FRAME_BEATS ||
                write_b_count != FRAME_BURSTS)
                fail("loopback output AW/W/B count mismatch");
            readback_frame(slot);
            write_model_active = 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin : main_test
        integer slot;
        for (slot = 0; slot < 3; slot = slot + 1)
            table_seen[slot] = 1'b0;
        if ((input_slot_base(2) + FRAME_BYTES) >= OUTPUT_BASE)
            fail("input and output native arenas overlap");
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        request_table(0);
        start_frame(0);
        // Prefetch the next descriptor while both read and write traffic for
        // frame 0 are active.  This is the intended shared-fabric seam.
        request_table(1);
        wait_frame_done(0);
        start_frame(1);
        request_table(2);
        wait_frame_done(1);
        start_frame(2);
        wait_frame_done(2);

        if (table_seen_count != 3 || table_ar_count != 3 || table_r_count != 3)
            fail("three table lookups did not complete");
        if (frame_ar_count != 3*FRAME_BURSTS || frame_r_count != 3*FRAME_BEATS)
            fail("native input AR/R aggregate mismatch");
        if (shared_rd_ar_count != table_ar_count + frame_ar_count ||
            shared_rd_r_count != table_r_count + frame_r_count)
            fail("read arbiter counters do not balance");
        if (total_aw_count != 3*FRAME_BURSTS)
            fail("native output AW aggregate mismatch");
        if (stream_pixel_count != 3*FRAME_W*FRAME_H)
            fail("native loopback pixel aggregate mismatch");
        if (ar_stall_count == 0 || r_gap_count == 0 ||
            stream_stall_count == 0 || write_aw_stall_count == 0 ||
            write_w_stall_count == 0 || write_b_delay_count == 0)
            fail("simultaneous read/write backpressure coverage incomplete");

        $display("C1_R1_NATIVE_DMA_LOOPBACK_PASS frames=3 frame_pixels=%0d table_ar=%0d table_r=%0d input_ar=%0d input_r=%0d output_aw=%0d output_w=%0d output_b=%0d read_ar_stalls=%0d read_r_stalls=%0d read_gaps=%0d stream_stalls=%0d aw_stalls=%0d w_stalls=%0d b_delays=%0d input_slots=%08x/%08x/%08x output_slots=%08x/%08x/%08x",
                 stream_pixel_count, table_ar_count, table_r_count,
                 frame_ar_count, frame_r_count, total_aw_count,
                 3*FRAME_BEATS, 3*FRAME_BURSTS, ar_stall_count,
                 r_stall_count, r_gap_count, stream_stall_count,
                 write_aw_stall_count, write_w_stall_count,
                 write_b_delay_count, input_slot_base(0), input_slot_base(1),
                 input_slot_base(2), output_slot_base(0), output_slot_base(1),
                 output_slot_base(2));
        $finish;
    end

    initial begin
        // Native loopback is intentionally below the signed 32-bit delay
        // limit and leaves ample room for a stalled 640x480 run.
        #200_000_000;
        fail("native read/write loopback global timeout/deadlock");
    end
endmodule
