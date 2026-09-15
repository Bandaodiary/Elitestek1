// Portable camera-domain RAW10 capture path through the complete R1 ISP and
// an XRGB8888 DDR writer. Frame ownership/address decisions remain in the SoC
// controller; this block supplies the table-reader and writer datapaths.
module c1_r1_capture_subsystem #(
    parameter integer SENSOR_WIDTH = 642,
    parameter integer SENSOR_HEIGHT = 482,
    parameter integer CAMERA_FIFO_DEPTH = 2048,
    parameter integer OUTPUT_FIFO_DEPTH = 128,
    parameter integer X_BITS =
        (SENSOR_WIDTH <= 1) ? 1 : $clog2(SENSOR_WIDTH),
    parameter integer Y_BITS =
        (SENSOR_HEIGHT <= 1) ? 1 : $clog2(SENSOR_HEIGHT),
    // Optional registered table-response boundary.  Disabled by default to
    // preserve the original one-entry table reader timing/latency contract.
    parameter integer ENABLE_TABLE_RESPONSE_FIFO = 0,
    parameter bit CAMERA_READY_VALID_SOURCE = 1'b0,
    parameter bit CHECK_RAW_RASTER = 1'b0,
    parameter integer RAW_IDLE_TIMEOUT_CYCLES = 0,
    parameter bit ENABLE_EXPLICIT_RECOVERY = 1'b0
) (
    input  logic                    camera_clk,
    input  logic                    camera_rst,
    input  logic                    camera_valid,
    output logic                    camera_ready,
    input  logic [9:0]              camera_raw10,
    input  logic [X_BITS-1:0]       camera_x,
    input  logic [Y_BITS-1:0]       camera_y,
    input  logic                    camera_sof,
    input  logic                    camera_eol,
    input  logic                    camera_eof,
    output logic                    camera_overflow,

    input  logic                    core_clk,
    input  logic                    core_rst,
    output logic                    frame_waiting,
    input  logic                    begin_frame,
    output logic                    begin_ready,
    input  logic                    drop_frame,
    input  logic                    discard_idle,
    input  logic                    abort_frame,
    input  logic                    clear_error,
    output logic                    cleanup_busy,
    output logic                    frame_ingress_done,
    output logic                    frame_dropped,
    output logic                    frame_aborted,
    output logic                    capture_error,
    output logic [7:0]              capture_error_code,

    input  logic                    cfg_commit,
    output logic                    cfg_ready,
    input  logic [1:0]              cfg_bayer_pattern,
    input  logic                    cfg_roi_x_parity,
    input  logic                    cfg_roi_y_parity,
    input  logic [9:0]              cfg_black_r,
    input  logic [9:0]              cfg_black_gr,
    input  logic [9:0]              cfg_black_gb,
    input  logic [9:0]              cfg_black_b,
    input  logic [15:0]             cfg_awb_gain_r,
    input  logic [15:0]             cfg_awb_gain_g,
    input  logic [15:0]             cfg_awb_gain_b,
    input  logic signed [15:0]      cfg_ccm_rr,
    input  logic signed [15:0]      cfg_ccm_rg,
    input  logic signed [15:0]      cfg_ccm_rb,
    input  logic signed [15:0]      cfg_ccm_gr,
    input  logic signed [15:0]      cfg_ccm_gg,
    input  logic signed [15:0]      cfg_ccm_gb,
    input  logic signed [15:0]      cfg_ccm_br,
    input  logic signed [15:0]      cfg_ccm_bg,
    input  logic signed [15:0]      cfg_ccm_bb,
    input  logic signed [31:0]      cfg_ccm_offset_r,
    input  logic signed [31:0]      cfg_ccm_offset_g,
    input  logic signed [31:0]      cfg_ccm_offset_b,
    input  logic                    gamma_cfg_we,
    input  logic [9:0]              gamma_cfg_addr,
    input  logic [7:0]              gamma_cfg_data,
    output logic                    gamma_cfg_ready,

    input  logic                    table_request_valid,
    output logic                    table_request_ready,
    input  logic [63:0]             table_request_base,
    input  logic [1:0]              table_request_index,
    output logic                    table_response_valid,
    input  logic                    table_response_ready,
    output logic                    table_response_error,
    output logic [63:0]             table_response_base,
    output logic [31:0]             table_response_stride,
    output logic [15:0]             table_response_width,
    output logic [15:0]             table_response_height,
    input  logic                    table_abort_request,
    output logic                    table_abort_pending,

    input  logic                    writer_start,
    input  logic                    writer_cancel,
    input  logic [31:0]             writer_base,
    input  logic [31:0]             writer_stride,
    input  logic [15:0]             writer_width,
    input  logic [15:0]             writer_height,
    output logic                    writer_busy,
    output logic                    writer_done,
    output logic                    writer_error,

    output logic [31:0]             table_axi_araddr,
    output logic [7:0]              table_axi_arlen,
    output logic [2:0]              table_axi_arsize,
    output logic [1:0]              table_axi_arburst,
    output logic                    table_axi_arvalid,
    input  logic                    table_axi_arready,
    input  logic [127:0]            table_axi_rdata,
    input  logic [1:0]              table_axi_rresp,
    input  logic                    table_axi_rlast,
    input  logic                    table_axi_rvalid,
    output logic                    table_axi_rready,

    output logic [31:0]             writer_axi_awaddr,
    output logic [7:0]              writer_axi_awlen,
    output logic [2:0]              writer_axi_awsize,
    output logic [1:0]              writer_axi_awburst,
    output logic                    writer_axi_awvalid,
    input  logic                    writer_axi_awready,
    output logic [127:0]            writer_axi_wdata,
    output logic [15:0]             writer_axi_wstrb,
    output logic                    writer_axi_wlast,
    output logic                    writer_axi_wvalid,
    input  logic                    writer_axi_wready,
    input  logic [1:0]              writer_axi_bresp,
    input  logic                    writer_axi_bvalid,
    output logic                    writer_axi_bready,
    input logic recovery_request,recovery_source_quiescent,recovery_fabric_drained,
    output logic recovery_ready,recovery_busy,recovery_done
);

    logic stream_valid;
    logic table_leaf_ready;
    wire recovery_cancel = ENABLE_EXPLICIT_RECOVERY && recovery_busy;
    wire recovery_leaf_safe = recovery_fabric_drained && !writer_busy &&
        !writer_axi_awvalid && !writer_axi_wvalid && table_leaf_ready &&
        !table_axi_arvalid && !table_abort_pending;
    assign table_request_ready=table_leaf_ready && !recovery_cancel;
    logic stream_ready;
    logic [23:0] stream_rgb;
    logic stream_sof, stream_eol, stream_eof;
    logic table_abort_to_reader;
    logic [127:0] table_response_raw_unused;
    logic table_reader_response_valid, table_reader_response_ready;
    logic table_reader_response_error;
    logic [63:0] table_reader_response_base;
    logic [31:0] table_reader_response_stride;
    logic [15:0] table_reader_response_width;
    logic [15:0] table_reader_response_height;
    logic camera_clear_pending_q;
    logic camera_clear_src_ready;
    logic camera_clear_src_fire;
    logic camera_clear_error_pulse;

    // clear_error is generated in the core clock domain, while the camera
    // overflow sticky bit is owned by camera_clk.  Keep an idempotent clear
    // request pending until the toggle/acknowledge CDC accepts it; a one-cycle
    // manager-abort pulse must never be sampled directly by camera_clk.
    always_comb begin
        camera_clear_src_fire = camera_clear_pending_q &&
                                camera_clear_src_ready;
    end

    always_ff @(posedge core_clk) begin
        if (core_rst)
            camera_clear_pending_q <= 1'b0;
        else if (clear_error)
            camera_clear_pending_q <= 1'b1;
        else if (camera_clear_src_fire)
            camera_clear_pending_q <= 1'b0;
    end

    c1_event_cdc u_camera_clear_error_cdc (
        .src_clk(core_clk),
        .src_rst(core_rst),
        .src_pulse(camera_clear_pending_q),
        .src_ready(camera_clear_src_ready),
        .dst_clk(camera_clk),
        .dst_rst(camera_rst),
        .dst_pulse(camera_clear_error_pulse)
    );

    c1_r1_capture_frontend #(
        .CAMERA_READY_VALID_SOURCE(CAMERA_READY_VALID_SOURCE),
        .CHECK_RAW_RASTER(CHECK_RAW_RASTER),
        .RAW_IDLE_TIMEOUT_CYCLES(RAW_IDLE_TIMEOUT_CYCLES),
        .ENABLE_EXPLICIT_RECOVERY(ENABLE_EXPLICIT_RECOVERY),
        .SENSOR_WIDTH(SENSOR_WIDTH),
        .SENSOR_HEIGHT(SENSOR_HEIGHT),
        .X_BITS(X_BITS), .Y_BITS(Y_BITS),
        .CAMERA_FIFO_DEPTH(CAMERA_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) u_frontend (
        .recovery_request(recovery_request),
        .recovery_source_quiescent(recovery_source_quiescent),
        .recovery_fabric_drained(recovery_leaf_safe),
        .recovery_ready(recovery_ready),.recovery_busy(recovery_busy),.recovery_done(recovery_done),
        .camera_clk(camera_clk),
        .camera_rst(camera_rst),
        .camera_valid(camera_valid),
        .camera_ready(camera_ready),
        .camera_raw10(camera_raw10),
        .camera_x(camera_x),
        .camera_y(camera_y),
        .camera_sof(camera_sof),
        .camera_eol(camera_eol),
        .camera_eof(camera_eof),
        .camera_clear_error(camera_clear_error_pulse),
        .camera_overflow(camera_overflow),
        .core_clk(core_clk),
        .core_rst(core_rst),
        .frame_waiting(frame_waiting),
        .begin_frame(begin_frame),
        .begin_ready(begin_ready),
        .drop_frame(drop_frame),
        .discard_idle(discard_idle),
        .abort_frame(abort_frame),
        .clear_error(clear_error),
        .cleanup_busy(cleanup_busy),
        .frame_ingress_done(frame_ingress_done),
        .frame_dropped(frame_dropped),
        .frame_aborted(frame_aborted),
        .capture_error(capture_error),
        .capture_error_code(capture_error_code),
        .cfg_commit(cfg_commit),
        .cfg_ready(cfg_ready),
        .cfg_bayer_pattern(cfg_bayer_pattern),
        .cfg_roi_x_parity(cfg_roi_x_parity),
        .cfg_roi_y_parity(cfg_roi_y_parity),
        .cfg_black_r(cfg_black_r),
        .cfg_black_gr(cfg_black_gr),
        .cfg_black_gb(cfg_black_gb),
        .cfg_black_b(cfg_black_b),
        .cfg_awb_gain_r(cfg_awb_gain_r),
        .cfg_awb_gain_g(cfg_awb_gain_g),
        .cfg_awb_gain_b(cfg_awb_gain_b),
        .cfg_ccm_rr(cfg_ccm_rr),
        .cfg_ccm_rg(cfg_ccm_rg),
        .cfg_ccm_rb(cfg_ccm_rb),
        .cfg_ccm_gr(cfg_ccm_gr),
        .cfg_ccm_gg(cfg_ccm_gg),
        .cfg_ccm_gb(cfg_ccm_gb),
        .cfg_ccm_br(cfg_ccm_br),
        .cfg_ccm_bg(cfg_ccm_bg),
        .cfg_ccm_bb(cfg_ccm_bb),
        .cfg_ccm_offset_r(cfg_ccm_offset_r),
        .cfg_ccm_offset_g(cfg_ccm_offset_g),
        .cfg_ccm_offset_b(cfg_ccm_offset_b),
        .gamma_cfg_we(gamma_cfg_we),
        .gamma_cfg_addr(gamma_cfg_addr),
        .gamma_cfg_data(gamma_cfg_data),
        .gamma_cfg_ready(gamma_cfg_ready),
        .m_valid(stream_valid),
        .m_ready(stream_ready),
        .m_rgb(stream_rgb),
        .m_sof(stream_sof),
        .m_eol(stream_eol),
        .m_eof(stream_eof)
    );

    c1_axi_read_abort_fence u_table_abort_fence (
        .clk(core_clk),
        .rst(core_rst),
        .abort_request(table_abort_request || recovery_cancel),
        .leaf_arvalid(table_axi_arvalid),
        .leaf_arready(table_axi_arready),
        .abort_pending(table_abort_pending),
        .abort_to_leaf(table_abort_to_reader)
    );

    c1_axi_frame_buffer_table_reader #(
        .INDEX_BITS(2)
    ) u_table_reader (
        .clk(core_clk),
        .rst(core_rst),
        .abort(table_abort_to_reader),
        .request_valid(table_request_valid && !recovery_cancel),
        .request_ready(table_leaf_ready),
        .request_table_base(table_request_base),
        .request_entry_index(table_request_index),
        .response_valid(table_reader_response_valid),
        .response_ready(table_reader_response_ready),
        .response_error(table_reader_response_error),
        .response_raw(table_response_raw_unused),
        .response_base_address(table_reader_response_base),
        .response_stride_bytes(table_reader_response_stride),
        .response_width_pixels(table_reader_response_width),
        .response_height_lines(table_reader_response_height),
        .m_axi_araddr(table_axi_araddr),
        .m_axi_arlen(table_axi_arlen),
        .m_axi_arsize(table_axi_arsize),
        .m_axi_arburst(table_axi_arburst),
        .m_axi_arvalid(table_axi_arvalid),
        .m_axi_arready(table_axi_arready),
        .m_axi_rdata(table_axi_rdata),
        .m_axi_rresp(table_axi_rresp),
        .m_axi_rlast(table_axi_rlast),
        .m_axi_rvalid(table_axi_rvalid),
        .m_axi_rready(table_axi_rready)
    );

    generate
        if (ENABLE_TABLE_RESPONSE_FIFO != 0) begin : g_table_response_fifo
            c1_table_response_elastic_fifo u_table_response_fifo (
                .clk(core_clk),
                .rst(core_rst),
                .abort(table_abort_request || recovery_cancel),
                .in_valid(table_reader_response_valid),
                .in_ready(table_reader_response_ready),
                .in_error(table_reader_response_error),
                .in_base(table_reader_response_base),
                .in_stride(table_reader_response_stride),
                .in_width(table_reader_response_width),
                .in_height(table_reader_response_height),
                .out_valid(table_response_valid),
                .out_ready(table_response_ready),
                .out_error(table_response_error),
                .out_base(table_response_base),
                .out_stride(table_response_stride),
                .out_width(table_response_width),
                .out_height(table_response_height)
            );
        end else begin : g_table_response_direct
            assign table_reader_response_ready = table_response_ready;
            assign table_response_valid = table_reader_response_valid;
            assign table_response_error = table_reader_response_error;
            assign table_response_base = table_reader_response_base;
            assign table_response_stride = table_reader_response_stride;
            assign table_response_width = table_reader_response_width;
            assign table_response_height = table_reader_response_height;
        end
    endgenerate

    c1_axi_xrgb_frame_writer u_writer (
        .clk(core_clk),
        .rst(core_rst),
        .start(writer_start && !recovery_cancel),
        .cancel(writer_cancel || recovery_cancel),
        .cfg_base_addr(writer_base),
        .cfg_width_pixels(writer_width),
        .cfg_height_lines(writer_height),
        .cfg_stride_bytes(writer_stride),
        .busy(writer_busy),
        .done(writer_done),
        .error(writer_error),
        .s_valid(stream_valid),
        .s_ready(stream_ready),
        .s_rgb(stream_rgb),
        .s_sof(stream_sof),
        .s_eol(stream_eol),
        .s_eof(stream_eof),
        .m_axi_awaddr(writer_axi_awaddr),
        .m_axi_awlen(writer_axi_awlen),
        .m_axi_awsize(writer_axi_awsize),
        .m_axi_awburst(writer_axi_awburst),
        .m_axi_awvalid(writer_axi_awvalid),
        .m_axi_awready(writer_axi_awready),
        .m_axi_wdata(writer_axi_wdata),
        .m_axi_wstrb(writer_axi_wstrb),
        .m_axi_wlast(writer_axi_wlast),
        .m_axi_wvalid(writer_axi_wvalid),
        .m_axi_wready(writer_axi_wready),
        .m_axi_bresp(writer_axi_bresp),
        .m_axi_bvalid(writer_axi_bvalid),
        .m_axi_bready(writer_axi_bready)
    );

endmodule
