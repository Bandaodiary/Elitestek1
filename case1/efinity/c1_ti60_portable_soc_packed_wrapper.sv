`timescale 1ns/1ps

// Boardless Efinity front-end probe for the complete portable Case-1 SoC.
//
// The wrapper deliberately gives the SoC only a narrow stimulus/observation
// shell.  It is not a board top and it does not instantiate Sapphire, DDR3,
// MIPI, HDMI, PLL or pin/periphery IP.  Its sole purpose is to answer a small
// but important compatibility question: can Efinity elaborate/map the real
// c1_r1_portable_soc hierarchy when PACKED_AFFINE_CACHE=1 is propagated to
// the CNN bridge?  All default production parameters remain unchanged in the
// real top; this is an isolated candidate build.
module c1_ti60_portable_soc_packed_wrapper (
    input  logic        clk,
    input  logic        rst,
    input  logic [63:0] stimulus,
    output logic [63:0] observe
);
    localparam integer APB_ADDR_W = 12;
    localparam integer FRAME_WIDTH = 8;
    localparam integer FRAME_HEIGHT = 8;
    localparam integer SENSOR_WIDTH = FRAME_WIDTH + 2;
    localparam integer SENSOR_HEIGHT = FRAME_HEIGHT + 2;
    localparam integer CAMERA_X_BITS = (SENSOR_WIDTH <= 1) ? 1 : $clog2(SENSOR_WIDTH);
    localparam integer CAMERA_Y_BITS = (SENSOR_HEIGHT <= 1) ? 1 : $clog2(SENSOR_HEIGHT);

    logic arst_n;
    logic psel, penable, pwrite;
    logic [APB_ADDR_W-1:0] paddr;
    logic [31:0] pwdata;
    logic [3:0] pstrb;
    logic [31:0] prdata;
    logic pready, pslverr, irq;

    logic camera_valid, camera_ready;
    logic [9:0] camera_raw10;
    logic [CAMERA_X_BITS-1:0] camera_x;
    logic [CAMERA_Y_BITS-1:0] camera_y;
    logic camera_sof, camera_eol, camera_eof, camera_overflow;

    logic [23:0] video_rgb;
    logic video_de, video_hsync, video_vsync;
    logic [4:0] engine_stage_index;
    logic [7:0] engine_stage_opcode;
    logic engine_stage_active, engine_overflow_seen, system_busy;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid, m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid, m_axi_bready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    // Keep every external input unconstrained enough that the mapper cannot
    // prove the complete hierarchy idle, while avoiding a testbench or any
    // board-specific primitive in this project.
    assign arst_n = ~rst;
    assign psel = stimulus[0];
    assign penable = stimulus[1];
    assign pwrite = stimulus[2];
    assign paddr = stimulus[15:4];
    assign pwdata = {4{stimulus[23:16]}};
    assign pstrb = stimulus[27:24];

    assign camera_valid = stimulus[28];
    assign camera_raw10 = {10{stimulus[29]}};
    assign camera_x = stimulus[33:30];
    assign camera_y = stimulus[37:34];
    assign camera_sof = stimulus[38];
    assign camera_eol = stimulus[39];
    assign camera_eof = stimulus[40];

    assign m_axi_awready = stimulus[41];
    assign m_axi_wready = stimulus[42];
    assign m_axi_bresp = stimulus[44:43];
    assign m_axi_bvalid = stimulus[45];
    assign m_axi_arready = stimulus[46];
    assign m_axi_rdata = {16{stimulus[54:47]}};
    assign m_axi_rresp = stimulus[56:55];
    assign m_axi_rlast = stimulus[57];
    assign m_axi_rvalid = stimulus[58];

    (* keep = "true" *) logic [63:0] observe_keep;
    assign observe_keep = {
        system_busy, irq, camera_ready, camera_overflow,
        video_de, video_hsync, video_vsync,
        engine_stage_index, engine_stage_opcode,
        engine_stage_active, engine_overflow_seen,
        m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready,
        m_axi_arvalid, m_axi_rready, m_axi_awlen, m_axi_arlen,
        m_axi_awaddr[7:0], m_axi_araddr[7:0],
        ^prdata, pready, pslverr, ^video_rgb,
        ^m_axi_wdata, ^m_axi_wstrb, ^m_axi_rdata
    };
    assign observe = observe_keep;

    c1_r1_portable_soc #(
        .APB_ADDR_W(APB_ADDR_W),
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .SENSOR_WIDTH(SENSOR_WIDTH),
        .SENSOR_HEIGHT(SENSOR_HEIGHT),
        .PARAM_ADDR_W(11),
        .JOB_CYCLE_BUDGET(32'd100000),
        .ENABLE_TENSOR_WINDOW_CACHE(0),
        .ENABLE_TENSOR_BURST_REFILL(0),
        .ENABLE_DISPLAY_RESPONSE_FIFO(0),
        .ENABLE_FABRIC_READ_RESPONSE_SKID(0),
        .ENABLE_TABLE_RESPONSE_FIFO(0),
        .STRICT_DESCRIPTOR_VALIDATION(1),
        .PIPELINED_DESCRIPTOR_VALIDATION(0),
        .NARROW_DESCRIPTOR_SIZE_CHECK(0),
        .FAST_TENSOR_ADDRESS_ARITH(0),
        .PIPELINED_TENSOR_ADDRESS(0),
        .PIPELINED_TENSOR_PIXEL_INDEX(0),
        .PIPELINED_DESCRIPTOR_SIZE_ARITH(0),
        .FIXED_DESCRIPTOR_SIZE_LIMITS(0),
        .PIPELINED_DESCRIPTOR_PIXEL_COUNT(0),
        .PIPELINED_START_CONFIG(0),
        .REGISTER_ABORT_RESET(0),
        .PIPELINED_DOT_TREE(0),
        .PIPELINED_DOT_TREE_FULL(0),
        .PIPELINED_DESCRIPTOR_REPLAY(0),
        .PREVALIDATE_DESCRIPTOR_REPLAY(0),
        .PIPELINED_DECODER_VALIDATION(0),
        .REPLICATE_ABORT_CONTROL(0),
        .REGISTER_FATAL_TICKET(0),
        .ENABLE_UNIFIED_OUTPUT_FIFO(0),
        .ENABLE_UNIFIED_OUTPUT_SKID(0),
        .PACKED_AFFINE_CACHE(1),
        .ENABLE_SHARED_QOS_MONITOR(0),
        .KEEP_DESCRIPTOR_SIZE_OPERANDS(0),
        .ITERATIVE_DESCRIPTOR_PIXEL_COUNT(0),
        .PRECLAMPED_TAP_COORDS(0)
    ) dut (
        .core_clk(clk),
        .pixel_clk(clk),
        .camera_clk(clk),
        .arst_n(arst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb),
        .prdata(prdata), .pready(pready), .pslverr(pslverr), .irq(irq),
        .camera_valid(camera_valid), .camera_ready(camera_ready),
        .camera_raw10(camera_raw10), .camera_x(camera_x), .camera_y(camera_y),
        .camera_sof(camera_sof), .camera_eol(camera_eol), .camera_eof(camera_eof),
        .camera_overflow(camera_overflow),
        .video_rgb(video_rgb), .video_de(video_de),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .engine_stage_index(engine_stage_index),
        .engine_stage_opcode(engine_stage_opcode),
        .engine_stage_active(engine_stage_active),
        .engine_overflow_seen(engine_overflow_seen), .system_busy(system_busy),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );
endmodule
