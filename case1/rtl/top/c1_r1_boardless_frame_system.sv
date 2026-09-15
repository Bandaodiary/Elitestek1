`timescale 1ns/1ps

// Board-independent R1 frame-job composition.
//
// This is the first portable top in which the control preflight, XRGB input
// and output DMAs, active-config dispatcher, and streaming compute shell are
// real instances in one job lifecycle:
//
//   software job command
//       -> c1_r1_job_frontend
//          -> frame-table + descriptor preflight
//          -> atomic input-DMA/output-DMA/engine start
//   XRGB input DMA -> Resize/centered-C8 ingress -> external CNN seam
//   external CNN seam -> centered-C8/RGB egress -> XRGB output DMA
//
// The 22-stage CNN datapath remains deliberately external.  The two external
// interfaces are (1) one descriptor ready/valid stream in physical-stage
// order and (2) C8 pixel ready/valid streams.  No placeholder convolution is
// instantiated here.
//
// Config-dispatch ordering contract:
//   * c1_r1_config_dispatcher and c1_r1_compute_shell start on the same
//     frontend engine_start edge.
//   * cnn_start_ready means the external CNN can accept a new job/config
//     sequence; it does not mean the 22 stage descriptors are installed.
//   * This top gates both C8 directions until the final stage descriptor has
//     transferred and dispatcher done has been observed.  Backpressure holds
//     the first ingress pixel inside the existing elastic pipeline.  Thus no
//     CNN pixel handshake can precede the last stage_config handshake.
//
// Abort/error and DMA drain contract:
//   * job_abort is an immediate stream fence and is also routed to the two DMA
//     cancel inputs.  A later frontend engine_abort_pulse has the same effect.
//   * The cancel-capable reader never retracts a presented AR and drains a
//     committed read burst while suppressing pixels.  The writer discards an
//     uncommitted partial capture, or completes an already presented AW/W/B
//     burst.  Both pulse done when their protocol-safe cancel has retired.
//   * The frontend therefore observes real DMA terminal events and can safely
//     retire abort/error without asynchronous reset or a fabricated frame.
//
// Memory composition:
//   * one read arbiter combines frontend preflight reads and XRGB input reads;
//   * the XRGB writer drives the independent AXI write channels directly.
// AXI read and write directions are independent, so a second full-interface
// arbiter would add state without arbitrating any competing client.  The
// exported port is a vendor-neutral, ID-less AXI4-128 subset suitable for a
// later DDR adapter and permits a read burst and write burst concurrently.
//
// Default mode uses job_width/job_height for both frames. With
// SEPARATE_INPUT_GEOMETRY=1 the appended job_input_* ports describe the source
// and job_width/job_height describe the target. The resolved source geometry
// drives input DMA/Resize, and target geometry drives Resize/output DMA.
// ENABLE_PREVIEW adds a target-sized C8/RGB preview fork and independent AXI
// write port. The parent must supply a nonoverlapping preview allocation;
// base/stride are captured at job admission. Job completion includes its B
// retirement. Default disabled mode preserves the original interface behavior.
module c1_r1_boardless_frame_system #(
    parameter integer MAX_WIDTH           = 2048,
    parameter integer MAX_STAGES          = 22,
    parameter integer COUNT_BITS          = 16,
    parameter integer GENERATION_BITS     = 8,
    parameter integer READ_TIMEOUT_CYCLES = 256,
    parameter bit     SYNC_READ           = 1'b1,
    parameter bit     FAST_WIDE           = 1'b0,
    // Optional one-cycle register boundary between the resolved frame
    // configuration and the Resize/compute shell launch.
    parameter integer PIPELINED_START_CONFIG = 0,
    // Optional registered destructive-flush boundary in the Resize ingress.
    // External abort fencing remains immediate; only the child synchronous
    // reset is delayed/held for one clock.
    parameter integer REGISTER_ABORT_RESET = 0,
    parameter integer SEPARATE_INPUT_GEOMETRY = 0,
    parameter bit ENABLE_PREVIEW = 1'b0,
    parameter logic [32:0] PREVIEW_REGION_BEGIN=33'd0,
    parameter logic [32:0] PREVIEW_REGION_END=33'h1_0000_0000,
    parameter bit CHECK_INPUT_SNAPSHOT=1'b0,
    parameter bit CHECK_WRITE_REGIONS=1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         job_start_valid,
    output logic                         job_start_ready,
    input  logic                         job_abort,
    input  logic [63:0]                  job_input_table_base,
    input  logic [63:0]                  job_output_table_base,
    input  logic [1:0]                   job_input_buffer_index,
    input  logic [1:0]                   job_output_buffer_index,
    input  logic [15:0]                  job_width_pixels,
    input  logic [15:0]                  job_height_lines,
    input  logic [31:0]                  job_descriptor_base,
    input  logic [COUNT_BITS-1:0]        job_descriptor_count,
    input  logic [31:0]                  job_cycle_budget,
    input  logic signed [31:0]           job_x_step_q16,
    input  logic signed [31:0]           job_y_step_q16,
    input  logic signed [31:0]           job_x_phase0_q16,
    input  logic signed [31:0]           job_y_phase0_q16,

    output logic                         busy,
    output logic                         job_done,
    output logic                         job_error,
    output logic                         job_aborted,
    output logic [7:0]                   error_code,
    output logic [31:0]                  error_address,

    output logic [31:0]                  resolved_input_base,
    output logic [31:0]                  resolved_input_stride,
    output logic [15:0]                  resolved_input_width,
    output logic [15:0]                  resolved_input_height,
    output logic [31:0]                  resolved_output_base,
    output logic [31:0]                  resolved_output_stride,
    output logic [15:0]                  resolved_output_width,
    output logic [15:0]                  resolved_output_height,

    output logic                         active_config_bank,
    output logic [COUNT_BITS-1:0]        active_config_count,
    output logic [GENERATION_BITS-1:0]   active_config_generation,
    output logic                         stage_dispatch_complete,

    output logic                         stage_config_valid,
    input  logic                         stage_config_ready,
    output logic [COUNT_BITS-1:0]        stage_config_index,
    output logic [511:0]                 stage_config_descriptor,
    output logic [GENERATION_BITS-1:0]   stage_config_generation,

    output logic                         cnn_start_valid,
    input  logic                         cnn_start_ready,
    output logic                         cnn_abort,
    input  logic                         cnn_error,
    input  logic [7:0]                   cnn_error_code,

    output logic                         cnn_in_valid,
    input  logic                         cnn_in_ready,
    output logic [63:0]                  cnn_in_data_s8,
    output logic [15:0]                  cnn_in_x,
    output logic [15:0]                  cnn_in_y,
    output logic                         cnn_in_sof,
    output logic                         cnn_in_eol,
    output logic                         cnn_in_eof,

    input  logic                         cnn_out_valid,
    output logic                         cnn_out_ready,
    input  logic [63:0]                  cnn_out_data_s8,
    input  logic [15:0]                  cnn_out_x,
    input  logic [15:0]                  cnn_out_y,
    input  logic                         cnn_out_sof,
    input  logic                         cnn_out_eol,
    input  logic                         cnn_out_eof,

    output logic [31:0]                  m_axi_awaddr,
    output logic [7:0]                   m_axi_awlen,
    output logic [2:0]                   m_axi_awsize,
    output logic [1:0]                   m_axi_awburst,
    output logic                         m_axi_awvalid,
    input  logic                         m_axi_awready,
    output logic [127:0]                 m_axi_wdata,
    output logic [15:0]                  m_axi_wstrb,
    output logic                         m_axi_wlast,
    output logic                         m_axi_wvalid,
    input  logic                         m_axi_wready,
    input  logic [1:0]                   m_axi_bresp,
    input  logic                         m_axi_bvalid,
    output logic                         m_axi_bready,
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,
    input logic [15:0]                   job_input_width_pixels,
    input logic [15:0]                   job_input_height_lines,
    input logic [31:0] job_preview_base,job_preview_stride,
    output logic [31:0] preview_axi_awaddr,
    output logic [7:0] preview_axi_awlen,
    output logic [2:0] preview_axi_awsize,
    output logic [1:0] preview_axi_awburst,
    output logic preview_axi_awvalid,input logic preview_axi_awready,
    output logic [127:0] preview_axi_wdata,
    output logic [15:0] preview_axi_wstrb,
    output logic preview_axi_wlast,preview_axi_wvalid,input logic preview_axi_wready,
    input logic [1:0] preview_axi_bresp,input logic preview_axi_bvalid,output logic preview_axi_bready,
    // Job-admission snapshots; publish only with this job's successful done.
    output logic [31:0] resolved_preview_base,resolved_preview_stride,
    input logic [96:0] job_expected_input,
    output wire region_request,region_cancel,
    input logic region_response,
    input logic [7:0] region_error_code,
    input logic [31:0] region_error_address
);

    localparam logic [7:0] INPUT_DMA_ERROR_CODE  = 8'h61;
    localparam logic [7:0] OUTPUT_DMA_ERROR_CODE = 8'h62;

    logic job_start_fire;
    logic signed [31:0] x_step_q16_q;
    logic signed [31:0] y_step_q16_q;
    logic signed [31:0] x_phase0_q16_q;
    logic signed [31:0] y_phase0_q16_q;

    logic config_loading_unused;
    logic config_commit_pulse_unused;
    logic config_read_enable;
    logic [COUNT_BITS-1:0] config_read_index;
    logic config_read_ready;
    logic config_read_busy;
    logic config_read_valid;
    logic [511:0] config_read_descriptor;
    logic [GENERATION_BITS-1:0] config_read_generation;

    logic input_dma_start;
    logic input_dma_busy;
    logic input_dma_done;
    logic input_dma_error_raw;
    logic input_dma_error_for_controller;
    logic output_dma_start;
    logic output_dma_busy;
    logic output_dma_done;
    logic output_dma_error_raw;
    logic output_dma_error_for_controller;

    logic descriptor_abort_pulse;
    logic dispatcher_start_ready;
    logic dispatcher_busy;
    logic dispatcher_done;
    logic dispatcher_error;
    logic dispatcher_aborted_unused;
    logic [7:0] dispatcher_error_code;
    logic [31:0] dispatcher_error_address;

    logic engine_ready;
    logic engine_start;
    logic compute_launch,runtime_busy,runtime_done,runtime_error;
    logic [7:0] runtime_error_code;
    logic [31:0] runtime_error_address,preview_base_q,preview_stride_q;
    assign resolved_preview_base=ENABLE_PREVIEW ? preview_base_q : 32'd0;
    assign resolved_preview_stride=ENABLE_PREVIEW ? preview_stride_q : 32'd0;
    logic engine_abort_pulse;
    logic compute_start_ready;
    logic compute_busy;
    logic compute_done;
    logic compute_error;
    logic [7:0] compute_error_code;
    logic compute_abort;
    logic descriptor_abort;
    logic dma_cancel;

    logic dispatch_complete_q;
    wire dispatch_open = dispatch_complete_q && !job_start_fire &&
                         !engine_start && !descriptor_abort && !compute_abort;

    logic input_stream_valid;
    logic input_stream_ready;
    logic [23:0] input_stream_rgb;
    logic input_stream_sof;
    logic input_stream_eol;
    logic input_stream_eof;
    logic [15:0] input_stream_x;
    logic [15:0] input_stream_y;
    logic shell_dma_ready;

    logic shell_cnn_in_valid;
    logic shell_cnn_in_ready;
    logic [63:0] shell_cnn_in_data_s8;
    logic [15:0] shell_cnn_in_x;
    logic [15:0] shell_cnn_in_y;
    logic shell_cnn_in_sof;
    logic shell_cnn_in_eol;
    logic shell_cnn_in_eof;
    logic shell_cnn_out_valid;
    logic shell_cnn_out_ready;

    logic shell_out_valid;
    logic shell_out_ready;
    logic [23:0] shell_out_rgb;
    logic [15:0] shell_out_x_unused;
    logic [15:0] shell_out_y_unused;
    logic shell_out_sof;
    logic shell_out_eol;
    logic shell_out_eof;

    logic [31:0] frontend_araddr;
    logic [7:0] frontend_arlen;
    logic [2:0] frontend_arsize;
    logic [1:0] frontend_arburst;
    logic frontend_arvalid;
    logic frontend_arready;
    logic [127:0] frontend_rdata;
    logic [1:0] frontend_rresp;
    logic frontend_rlast;
    logic frontend_rvalid;
    logic frontend_rready;

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

    generate if(ENABLE_PREVIEW) begin: g_preview
        wire preview_in_ready;
        assign shell_cnn_in_ready=preview_in_ready && dispatch_open;
        c1_r1_preview_runtime #(
            .DEST_REGION_BEGIN(PREVIEW_REGION_BEGIN),.DEST_REGION_END(PREVIEW_REGION_END)
        ) u_runtime (
            .clk(clk),.rst(rst),.start_valid(engine_start),.start_ready(engine_ready),.cancel(compute_abort),
            .compute_start(compute_launch),.compute_ready(compute_start_ready&&dispatcher_start_ready),
            .compute_busy(compute_busy),.compute_done(compute_done),.compute_error(compute_error),
            .compute_error_code(compute_error_code),.compute_error_address(32'd0),
            .base_addr(preview_base_q),.stride_bytes(preview_stride_q),
            .width_pixels(resolved_output_width),.height_lines(resolved_output_height),
            .busy(runtime_busy),.done(runtime_done),.error(runtime_error),
            .error_code(runtime_error_code),.error_address(runtime_error_address),
            .preview_ready(),.preview_busy(),.preview_done(),.preview_error(),.preview_aborted(),
            .in_valid(shell_cnn_in_valid&&dispatch_open),.in_ready(preview_in_ready),
            .in_data_s8(shell_cnn_in_data_s8),.in_x(shell_cnn_in_x),.in_y(shell_cnn_in_y),
            .in_sof(shell_cnn_in_sof),.in_eol(shell_cnn_in_eol),.in_eof(shell_cnn_in_eof),
            .cnn_valid(cnn_in_valid),.cnn_ready(cnn_in_ready),.cnn_data_s8(cnn_in_data_s8),
            .cnn_x(cnn_in_x),.cnn_y(cnn_in_y),.cnn_sof(cnn_in_sof),.cnn_eol(cnn_in_eol),.cnn_eof(cnn_in_eof),
            .m_axi_awaddr(preview_axi_awaddr),.m_axi_awlen(preview_axi_awlen),.m_axi_awsize(preview_axi_awsize),
            .m_axi_awburst(preview_axi_awburst),.m_axi_awvalid(preview_axi_awvalid),.m_axi_awready(preview_axi_awready),
            .m_axi_wdata(preview_axi_wdata),.m_axi_wstrb(preview_axi_wstrb),.m_axi_wlast(preview_axi_wlast),
            .m_axi_wvalid(preview_axi_wvalid),.m_axi_wready(preview_axi_wready),.m_axi_bresp(preview_axi_bresp),
            .m_axi_bvalid(preview_axi_bvalid),.m_axi_bready(preview_axi_bready)
        );
    end else begin: g_no_preview
        assign engine_ready=compute_start_ready&&dispatcher_start_ready;
        assign compute_launch=engine_start;
        assign runtime_busy=compute_busy;
        assign runtime_done=compute_done;
        assign runtime_error=compute_error;
        assign runtime_error_code=compute_error_code;
        assign runtime_error_address=32'd0;
        assign cnn_in_valid=shell_cnn_in_valid&&dispatch_open;
        assign shell_cnn_in_ready=cnn_in_ready&&dispatch_open;
        assign {cnn_in_data_s8,cnn_in_x,cnn_in_y,cnn_in_sof,cnn_in_eol,cnn_in_eof}=
               {shell_cnn_in_data_s8,shell_cnn_in_x,shell_cnn_in_y,shell_cnn_in_sof,shell_cnn_in_eol,shell_cnn_in_eof};
        assign {preview_axi_awaddr,preview_axi_awlen,preview_axi_awsize,preview_axi_awburst,
                preview_axi_awvalid,preview_axi_wdata,preview_axi_wstrb,preview_axi_wlast,
                preview_axi_wvalid,preview_axi_bready}='0;
    end endgenerate

    always_comb begin
        job_start_fire = job_start_valid && job_start_ready;

        compute_abort = job_abort || engine_abort_pulse;
        descriptor_abort = job_abort || descriptor_abort_pulse;
        dma_cancel = job_abort || engine_abort_pulse;

        input_dma_error_for_controller = input_dma_error_raw &&
                                         (input_dma_busy || input_dma_done);
        output_dma_error_for_controller = output_dma_error_raw &&
                                          (output_dma_busy || output_dma_done);

        // Both runtime children must be able to accept the common engine_start
        // edge.  Dispatcher busy is separately visible as descriptor_busy.

        // A canceling reader drains internally; do not expose any residual
        // pixel to the already-aborted compute stream.
        input_stream_ready = dma_cancel ? 1'b1 : shell_dma_ready;

        // Stage configuration is an explicit barrier in front of pixel data.

        shell_cnn_out_valid = cnn_out_valid && dispatch_open;
        cnn_out_ready = shell_cnn_out_ready && dispatch_open;

        stage_dispatch_complete = dispatch_open;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            preview_base_q<=0;preview_stride_q<=0;
            x_step_q16_q <= 32'sd0;
            y_step_q16_q <= 32'sd0;
            x_phase0_q16_q <= 32'sd0;
            y_phase0_q16_q <= 32'sd0;
        end else if (job_start_fire) begin
            preview_base_q<=job_preview_base;preview_stride_q<=job_preview_stride;
            x_step_q16_q <= job_x_step_q16;
            y_step_q16_q <= job_y_step_q16;
            x_phase0_q16_q <= job_x_phase0_q16;
            y_phase0_q16_q <= job_y_phase0_q16;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dispatch_complete_q <= 1'b0;
        end else begin
            if (job_start_fire || engine_start || descriptor_abort || compute_abort)
                dispatch_complete_q <= 1'b0;
            else if (dispatcher_done)
                dispatch_complete_q <= 1'b1;
        end
    end

    c1_r1_job_frontend #(
        .CHECK_WRITE_REGIONS(CHECK_WRITE_REGIONS),
        .CHECK_INPUT_SNAPSHOT(CHECK_INPUT_SNAPSHOT),
        .CHECK_PREVIEW_LAYOUT(ENABLE_PREVIEW),
        .PREVIEW_REGION_BEGIN(PREVIEW_REGION_BEGIN),.PREVIEW_REGION_END(PREVIEW_REGION_END),
        .SEPARATE_INPUT_GEOMETRY(SEPARATE_INPUT_GEOMETRY),
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .SYNC_READ(SYNC_READ),
        .FAST_WIDE(FAST_WIDE)
    ) u_job_frontend (
        .job_preview_base(job_preview_base),.job_preview_stride(job_preview_stride),
        .job_expected_input(job_expected_input),
        .region_request(region_request),.region_cancel(region_cancel),
        .region_response(region_response),.region_error_code(region_error_code),
        .region_error_address(region_error_address),
        .job_input_width_pixels(job_input_width_pixels),
        .job_input_height_lines(job_input_height_lines),
        .clk(clk),
        .rst(rst),
        .job_start_valid(job_start_valid),
        .job_start_ready(job_start_ready),
        .job_abort(job_abort),
        .job_input_table_base(job_input_table_base),
        .job_output_table_base(job_output_table_base),
        .job_input_buffer_index(job_input_buffer_index),
        .job_output_buffer_index(job_output_buffer_index),
        .job_width_pixels(job_width_pixels),
        .job_height_lines(job_height_lines),
        .job_descriptor_base(job_descriptor_base),
        .job_descriptor_count(job_descriptor_count),
        .job_cycle_budget(job_cycle_budget),
        .busy(busy),
        .job_done(job_done),
        .job_error(job_error),
        .job_aborted(job_aborted),
        .error_code(error_code),
        .error_address(error_address),
        .resolved_input_base(resolved_input_base),
        .resolved_input_stride(resolved_input_stride),
        .resolved_input_width(resolved_input_width),
        .resolved_input_height(resolved_input_height),
        .resolved_output_base(resolved_output_base),
        .resolved_output_stride(resolved_output_stride),
        .resolved_output_width(resolved_output_width),
        .resolved_output_height(resolved_output_height),
        .config_loading(config_loading_unused),
        .config_commit_pulse(config_commit_pulse_unused),
        .active_config_bank(active_config_bank),
        .active_config_count(active_config_count),
        .active_config_generation(active_config_generation),
        .config_read_enable(config_read_enable),
        .config_read_index(config_read_index),
        .config_read_ready(config_read_ready),
        .config_read_busy(config_read_busy),
        .config_read_valid(config_read_valid),
        .config_read_descriptor(config_read_descriptor),
        .config_read_generation(config_read_generation),
        .input_dma_ready(!input_dma_busy),
        .input_dma_start(input_dma_start),
        .input_dma_busy(input_dma_busy),
        .input_dma_done(input_dma_done),
        .input_dma_error(input_dma_error_for_controller),
        .input_dma_error_code(INPUT_DMA_ERROR_CODE),
        .input_dma_error_address(resolved_input_base),
        .output_dma_ready(!output_dma_busy),
        .output_dma_start(output_dma_start),
        .output_dma_busy(output_dma_busy),
        .output_dma_done(output_dma_done),
        .output_dma_error(output_dma_error_for_controller),
        .output_dma_error_code(OUTPUT_DMA_ERROR_CODE),
        .output_dma_error_address(resolved_output_base),
        .descriptor_busy(dispatcher_busy),
        .descriptor_done(dispatcher_done),
        .descriptor_error(dispatcher_error),
        .descriptor_error_code(dispatcher_error_code),
        .descriptor_error_address(dispatcher_error_address),
        .descriptor_abort_pulse(descriptor_abort_pulse),
        .engine_ready(engine_ready),
        .engine_start(engine_start),
        .engine_busy(runtime_busy),
        .engine_done(runtime_done),
        .engine_error(runtime_error),
        .engine_error_code(runtime_error_code),
        .engine_error_address(runtime_error_address),
        .engine_abort_pulse(engine_abort_pulse),
        .m_axi_araddr(frontend_araddr),
        .m_axi_arlen(frontend_arlen),
        .m_axi_arsize(frontend_arsize),
        .m_axi_arburst(frontend_arburst),
        .m_axi_arvalid(frontend_arvalid),
        .m_axi_arready(frontend_arready),
        .m_axi_rdata(frontend_rdata),
        .m_axi_rresp(frontend_rresp),
        .m_axi_rlast(frontend_rlast),
        .m_axi_rvalid(frontend_rvalid),
        .m_axi_rready(frontend_rready)
    );

    c1_axi_xrgb_frame_reader u_input_dma (
        .clk(clk),
        .rst(rst),
        .start(input_dma_start),
        .cancel(dma_cancel),
        .cfg_base_addr(resolved_input_base),
        .cfg_width_pixels(resolved_input_width),
        .cfg_height_lines(resolved_input_height),
        .cfg_stride_bytes(resolved_input_stride),
        .busy(input_dma_busy),
        .done(input_dma_done),
        .error(input_dma_error_raw),
        .m_valid(input_stream_valid),
        .m_ready(input_stream_ready),
        .m_rgb(input_stream_rgb),
        .m_sof(input_stream_sof),
        .m_eol(input_stream_eol),
        .m_eof(input_stream_eof),
        .m_x(input_stream_x),
        .m_y(input_stream_y),
        .m_axi_araddr(reader_araddr),
        .m_axi_arlen(reader_arlen),
        .m_axi_arsize(reader_arsize),
        .m_axi_arburst(reader_arburst),
         .m_axi_arvalid(reader_arvalid),
         .m_axi_arready(reader_arready),
         .m_axi_rdata(reader_rdata),
        .m_axi_rresp(reader_rresp),
        .m_axi_rlast(reader_rlast),
        .m_axi_rvalid(reader_rvalid),
         .m_axi_rready(reader_rready),
         .m_axi_ar_allow(1'b1)
     );

    c1_r1_config_dispatcher #(
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES)
    ) u_config_dispatcher (
        .clk(clk),
        .rst(rst),
        .start(engine_start),
        .start_ready(dispatcher_start_ready),
        .abort(descriptor_abort),
        .active_count(active_config_count),
        .active_generation(active_config_generation),
        .config_read_enable(config_read_enable),
        .config_read_index(config_read_index),
        .config_read_ready(config_read_ready),
        .config_read_busy(config_read_busy),
        .config_read_valid(config_read_valid),
        .config_read_descriptor(config_read_descriptor),
        .config_read_generation(config_read_generation),
        .stage_config_valid(stage_config_valid),
        .stage_config_ready(stage_config_ready),
        .stage_config_index(stage_config_index),
        .stage_config_descriptor(stage_config_descriptor),
        .stage_config_generation(stage_config_generation),
        .busy(dispatcher_busy),
        .done(dispatcher_done),
        .error(dispatcher_error),
        .aborted(dispatcher_aborted_unused),
        .error_code(dispatcher_error_code),
        .error_address(dispatcher_error_address)
    );

    c1_r1_compute_shell #(
        .MAX_WIDTH(MAX_WIDTH),
        .PIPELINED_START_CONFIG(PIPELINED_START_CONFIG),
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET)
    ) u_compute_shell (
        .clk(clk),
        .rst(rst),
        .start_valid(compute_launch),
        .start_ready(compute_start_ready),
        .abort(compute_abort),
        .source_select(1'b1),
        .cfg_win(resolved_input_width),
        .cfg_hin(resolved_input_height),
        .cfg_wout(resolved_output_width),
        .cfg_hout(resolved_output_height),
        .cfg_x_step_q16(x_step_q16_q),
        .cfg_y_step_q16(y_step_q16_q),
        .cfg_x_phase0_q16(x_phase0_q16_q),
        .cfg_y_phase0_q16(y_phase0_q16_q),
        .busy(compute_busy),
        .done(compute_done),
        .error(compute_error),
        .error_code(compute_error_code),
        .cnn_start_valid(cnn_start_valid),
        .cnn_start_ready(cnn_start_ready),
        .cnn_abort(cnn_abort),
        .cnn_error(cnn_error),
        .cnn_error_code(cnn_error_code),
        .isp_valid(1'b0),
        .isp_ready(),
        .isp_rgb888(24'd0),
        .isp_x(16'd0),
        .isp_y(16'd0),
        .isp_sof(1'b0),
        .isp_eol(1'b0),
        .isp_eof(1'b0),
        .dma_valid(input_stream_valid && !dma_cancel),
        .dma_ready(shell_dma_ready),
        .dma_rgb888(input_stream_rgb),
        .dma_x(input_stream_x),
        .dma_y(input_stream_y),
        .dma_sof(input_stream_sof),
        .dma_eol(input_stream_eol),
        .dma_eof(input_stream_eof),
        .cnn_in_valid(shell_cnn_in_valid),
        .cnn_in_ready(shell_cnn_in_ready),
        .cnn_in_data_s8(shell_cnn_in_data_s8),
        .cnn_in_x(shell_cnn_in_x),
        .cnn_in_y(shell_cnn_in_y),
        .cnn_in_sof(shell_cnn_in_sof),
        .cnn_in_eol(shell_cnn_in_eol),
        .cnn_in_eof(shell_cnn_in_eof),
        .cnn_out_valid(shell_cnn_out_valid),
        .cnn_out_ready(shell_cnn_out_ready),
        .cnn_out_data_s8(cnn_out_data_s8),
        .cnn_out_x(cnn_out_x),
        .cnn_out_y(cnn_out_y),
        .cnn_out_sof(cnn_out_sof),
        .cnn_out_eol(cnn_out_eol),
        .cnn_out_eof(cnn_out_eof),
        .out_valid(shell_out_valid),
        .out_ready(shell_out_ready),
        .out_rgb888(shell_out_rgb),
        .out_x(shell_out_x_unused),
        .out_y(shell_out_y_unused),
        .out_sof(shell_out_sof),
        .out_eol(shell_out_eol),
        .out_eof(shell_out_eof)
    );

    c1_axi_xrgb_frame_writer u_output_dma (
        .clk(clk),
        .rst(rst),
        .start(output_dma_start),
        .cancel(dma_cancel),
        .cfg_base_addr(resolved_output_base),
        .cfg_width_pixels(resolved_output_width),
        .cfg_height_lines(resolved_output_height),
        .cfg_stride_bytes(resolved_output_stride),
        .busy(output_dma_busy),
        .done(output_dma_done),
        .error(output_dma_error_raw),
        .s_valid(shell_out_valid && !dma_cancel),
        .s_ready(shell_out_ready),
        .s_rgb(shell_out_rgb),
        .s_sof(shell_out_sof),
        .s_eol(shell_out_eol),
        .s_eof(shell_out_eof),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    c1_axi2_serial_arbiter_128 u_read_arbiter (
        .clk(clk), .rst(rst),
        .s0_awaddr(32'd0), .s0_awlen(8'd0), .s0_awsize(3'd0),
        .s0_awburst(2'd0), .s0_awvalid(1'b0), .s0_awready(),
        .s0_wdata(128'd0), .s0_wstrb(16'd0), .s0_wlast(1'b0),
        .s0_wvalid(1'b0), .s0_wready(), .s0_bresp(), .s0_bvalid(),
        .s0_bready(1'b1),
        .s0_araddr(frontend_araddr), .s0_arlen(frontend_arlen),
        .s0_arsize(frontend_arsize), .s0_arburst(frontend_arburst),
        .s0_arvalid(frontend_arvalid), .s0_arready(frontend_arready),
        .s0_rdata(frontend_rdata), .s0_rresp(frontend_rresp),
        .s0_rlast(frontend_rlast), .s0_rvalid(frontend_rvalid),
        .s0_rready(frontend_rready),
        .s1_awaddr(32'd0), .s1_awlen(8'd0), .s1_awsize(3'd0),
        .s1_awburst(2'd0), .s1_awvalid(1'b0), .s1_awready(),
        .s1_wdata(128'd0), .s1_wstrb(16'd0), .s1_wlast(1'b0),
        .s1_wvalid(1'b0), .s1_wready(), .s1_bresp(), .s1_bvalid(),
        .s1_bready(1'b1),
        .s1_araddr(reader_araddr), .s1_arlen(reader_arlen),
        .s1_arsize(reader_arsize), .s1_arburst(reader_arburst),
        .s1_arvalid(reader_arvalid), .s1_arready(reader_arready),
        .s1_rdata(reader_rdata), .s1_rresp(reader_rresp),
        .s1_rlast(reader_rlast), .s1_rvalid(reader_rvalid),
        .s1_rready(reader_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(),
        .m_awvalid(), .m_awready(1'b0),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(),
        .m_wready(1'b0), .m_bresp(2'b00),
        .m_bvalid(1'b0), .m_bready(),
        .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst),
        .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready),
        .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast), .m_rvalid(m_axi_rvalid),
        .m_rready(m_axi_rready)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (engine_start && (!compute_start_ready ||
                                 !dispatcher_start_ready))
                $fatal(1, "engine_start was not accepted atomically");
            if ((cnn_in_valid && cnn_in_ready) && !dispatch_complete_q)
                $fatal(1, "CNN input transferred before config dispatch completed");
            if ((cnn_out_valid && cnn_out_ready) && !dispatch_complete_q)
                $fatal(1, "CNN output transferred before config dispatch completed");
            if (job_abort && (input_dma_start || output_dma_start || engine_start))
                $fatal(1, "job launched while abort was asserted");
        end
    end
`endif

endmodule
