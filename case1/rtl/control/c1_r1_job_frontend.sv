`timescale 1ns/1ps

// Board-independent R1 job-control frontend.
//
// This module is deliberately a control-plane composition, not a DMA or CNN
// implementation.  One accepted job command is snapshotted and drives two
// independent preflight clients:
//   * c1_frame_pair_resolver reads one 16-byte input table entry and one
//     16-byte output table entry.  Entry n is at table_base + n*16 and is
//     {height[15:0], width[15:0], stride[31:0], base[63:0]} in AXI bit order.
//   * c1_r1_config_loader_subsystem reads descriptor n at
//     descriptor_base + n*64 as four 128-bit INCR beats and atomically commits
//     the decoded stage bank only after the complete descriptor set succeeds.
//
// The two preflights run concurrently.  The active stage bank is intentionally
// a reusable, validated configuration cache rather than a job-transaction
// shadow: if configuration commits before a later frame-pair failure, the new
// bank and generation remain active for reuse.  There is no job-level rollback
// of a completed config commit.  The controller still requires both successful
// prerequisite responses, so such a failed job can never launch DMA/engine.
//
// The two read-only AXI masters share one ID-less AXI128 AR/R port through
// c1_axi2_serial_arbiter_128.  Its unused write channels are tied inactive.
// The arbiter owns a grant through RLAST, so abort requests to a child whose
// ARVALID is stalled are held until that AR commits.  This preserves the AXI
// VALID-stability rule; the child then drains and drops the committed read.
// New jobs remain blocked until every such drain has completed.
//
// After both preflights respond successfully, c1_r1_job_controller pulses
// input_dma_start, output_dma_start and engine_start together.  The external
// runtime descriptor client has no independent start in the existing
// controller contract: it is expected to begin with engine_start and its
// busy/done/error inputs form the fourth retirement participant.
//
// Explicit abort before launch cannot produce a launch.  After launch, the
// controller aborts descriptor/engine work but never retracts an issued DMA;
// both DMAs must report done/error and all clients must become idle before
// job_aborted/job_error is reported.  Synchronous rst is a system reset and is
// not a substitute for the transaction-draining abort protocol.
//
// The config loader exposes only a summary error pulse.  It is translated to
// prerequisite error code 0x40 with the snapshotted descriptor base as the
// diagnostic address.  Frame-pair and runtime errors retain their native
// codes and addresses through c1_r1_job_controller.
// SEPARATE_INPUT_GEOMETRY=1 snapshots the appended input dimensions at the
// same job-start boundary as output dimensions, tables and descriptors.
// In this mode job_width/job_height describe output, not the source raster.
// CHECK_PREVIEW_LAYOUT holds a successful pair response until all three XRGB
// layouts pass exact active-row disjointness. Preview base/stride are captured
// at job admission; dimensions match the resolved output. Added errors are
// 0x31 geometry, 0x32 extent/preview arena, 0x33 overlap. Arena validation
// precedes overlap and uses the same static bounds as the preview writer.
// No runtime may start before success.
// CHECK_INPUT_SNAPSHOT additionally requires the resolved input to match the
// captured-frame identity sampled at job admission. Missing/mismatched identity
// returns 0x34 before runtime launch; native resolver faults retain priority.
module c1_r1_job_frontend #(
    parameter integer MAX_STAGES      = 22,
    parameter integer COUNT_BITS      = 16,
    parameter integer GENERATION_BITS = 8,
    parameter bit     SYNC_READ       = 1'b1,
    parameter bit     FAST_WIDE       = 1'b0,
    parameter integer SEPARATE_INPUT_GEOMETRY = 0,
    parameter bit CHECK_PREVIEW_LAYOUT = 1'b0,
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

    output logic                         config_loading,
    output logic                         config_commit_pulse,
    output logic                         active_config_bank,
    output logic [COUNT_BITS-1:0]        active_config_count,
    output logic [GENERATION_BITS-1:0]   active_config_generation,
    input  logic                         config_read_enable,
    input  logic [COUNT_BITS-1:0]        config_read_index,
    output logic                         config_read_ready,
    output logic                         config_read_busy,
    output logic                         config_read_valid,
    output logic [511:0]                 config_read_descriptor,
    output logic [GENERATION_BITS-1:0]   config_read_generation,

    input  logic                         input_dma_ready,
    output logic                         input_dma_start,
    input  logic                         input_dma_busy,
    input  logic                         input_dma_done,
    input  logic                         input_dma_error,
    input  logic [7:0]                   input_dma_error_code,
    input  logic [31:0]                  input_dma_error_address,

    input  logic                         output_dma_ready,
    output logic                         output_dma_start,
    input  logic                         output_dma_busy,
    input  logic                         output_dma_done,
    input  logic                         output_dma_error,
    input  logic [7:0]                   output_dma_error_code,
    input  logic [31:0]                  output_dma_error_address,

    input  logic                         descriptor_busy,
    input  logic                         descriptor_done,
    input  logic                         descriptor_error,
    input  logic [7:0]                   descriptor_error_code,
    input  logic [31:0]                  descriptor_error_address,
    output logic                         descriptor_abort_pulse,

    input  logic                         engine_ready,
    output logic                         engine_start,
    input  logic                         engine_busy,
    input  logic                         engine_done,
    input  logic                         engine_error,
    input  logic [7:0]                   engine_error_code,
    input  logic [31:0]                  engine_error_address,
    output logic                         engine_abort_pulse,

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
    // {valid, base[31:0], stride[31:0], width[15:0], height[15:0]}.
    // Captured frame identity, sampled atomically at job admission.
    input logic [96:0] job_expected_input,
    // Level request after local frame validation; metadata is held until
    // response consumption/cancel. Responder holds response until req drops.
    output wire region_request,
    output wire region_cancel,
    input logic region_response,
    input logic [7:0] region_error_code,
    input logic [31:0] region_error_address
);

    localparam logic [7:0] CONFIG_LOAD_ERROR_CODE = 8'h40;

    logic [63:0] input_table_base_q;
    logic [63:0] output_table_base_q;
    logic [1:0] input_buffer_index_q;
    logic [1:0] output_buffer_index_q;
    logic [15:0] width_pixels_q;
    logic [15:0] height_lines_q;
    logic [15:0] input_width_q, input_height_q;
    logic [31:0] descriptor_base_q;
    logic [COUNT_BITS-1:0] descriptor_count_q;

    logic job_start_fire;

    logic pair_start_valid_i;
    logic pair_start_ready_i;
    logic pair_response_valid_i;
    logic pair_response_ready_i;
    logic pair_response_error_i;
    logic [7:0] pair_response_error_code_i;
    logic [31:0] pair_response_error_address_i;
    logic pair_busy_i;
    wire local_pair_response_valid_i,local_pair_response_ready_i;
    wire local_pair_response_error_i,local_pair_busy_i;
    wire [7:0] local_pair_response_error_code_i;
    wire [31:0] local_pair_response_error_address_i;
    logic raw_pair_valid,raw_pair_ready,raw_pair_error,raw_pair_busy;
    logic [7:0] raw_pair_code;
    logic [31:0] raw_pair_address,preview_base_q,preview_stride_q;
    logic resolver_pair_error;
    logic [7:0] resolver_pair_code;
    logic [31:0] resolver_pair_address;
    logic [96:0] expected_input_q;
    always_ff @(posedge clk) begin
        if(rst) expected_input_q<=0;
        else if(job_start_fire) expected_input_q<=job_expected_input;
    end
    wire input_snapshot_mismatch=CHECK_INPUT_SNAPSHOT && raw_pair_valid &&
        (!expected_input_q[96] ||
         {resolved_input_base,resolved_input_stride,resolved_input_width,resolved_input_height}!=expected_input_q[95:0]);
    assign raw_pair_error=resolver_pair_error || input_snapshot_mismatch;
    assign raw_pair_code=resolver_pair_error ? resolver_pair_code :
                         (input_snapshot_mismatch ? 8'h34 : 8'd0);
    assign raw_pair_address=resolver_pair_error ? resolver_pair_address :
                            (input_snapshot_mismatch ? resolved_input_base : 32'd0);
    logic pair_abort_request_pulse;
    logic pair_abort_pending_q;
    logic pair_abort_to_child;

    logic config_start_valid_i;
    logic config_start_ready_i;
    logic config_start_fire_i;
    logic config_response_valid_i;
    logic config_response_ready_i;
    logic config_response_error_q;
    logic [31:0] config_response_address_q;
    logic config_response_pending_q;
    logic config_response_fire_i;
    logic config_inflight_q;
    logic config_busy_i;
    logic config_abort_request_pulse;
    logic config_abort_pending_q;
    logic config_abort_to_child;

    logic loader_start_pulse;
    logic loader_busy;
    logic loader_done_pulse;
    logic loader_error_pulse;
    logic loader_aborted_pulse;

    logic [31:0] pair_axi_araddr;
    logic [7:0] pair_axi_arlen;
    logic [2:0] pair_axi_arsize;
    logic [1:0] pair_axi_arburst;
    logic pair_axi_arvalid;
    logic pair_axi_arready;
    logic [127:0] pair_axi_rdata;
    logic [1:0] pair_axi_rresp;
    logic pair_axi_rlast;
    logic pair_axi_rvalid;
    logic pair_axi_rready;

    logic [31:0] config_axi_araddr;
    logic [7:0] config_axi_arlen;
    logic [2:0] config_axi_arsize;
    logic [1:0] config_axi_arburst;
    logic config_axi_arvalid;
    logic config_axi_arready;
    logic [127:0] config_axi_rdata;
    logic [1:0] config_axi_rresp;
    logic config_axi_rlast;
    logic config_axi_rvalid;
    logic config_axi_rready;

    generate if(CHECK_PREVIEW_LAYOUT) begin: g_preview_layout
        wire layout_cancel=job_abort||pair_abort_request_pulse||pair_abort_pending_q||pair_abort_to_child;
        logic started_q;
        wire check_ready,check_busy,check_valid;
        wire [1:0] check_code,check_index;
        wire check_request=raw_pair_valid&&!raw_pair_error&&!started_q&&!layout_cancel;
        wire check_accept=check_request&&check_ready;
        wire pair_retire=local_pair_response_valid_i&&local_pair_response_ready_i;
        always_ff @(posedge clk) begin
            if(rst||layout_cancel||pair_retire) started_q<=0;
            else if(check_accept) started_q<=1;
        end
        c1_frame_triple_layout_check #(
            .PREVIEW_REGION_BEGIN(PREVIEW_REGION_BEGIN),.PREVIEW_REGION_END(PREVIEW_REGION_END)
        ) u_check (
            .clk(clk),.rst(rst),.cancel(layout_cancel),.req_valid(check_request),.req_ready(check_ready),
            .frame_base({preview_base_q,resolved_output_base,resolved_input_base}),
            .frame_stride({preview_stride_q,resolved_output_stride,resolved_input_stride}),
            .frame_width({resolved_output_width,resolved_output_width,resolved_input_width}),
            .frame_height({resolved_output_height,resolved_output_height,resolved_input_height}),
            .busy(check_busy),.rsp_valid(check_valid),.rsp_ready(pair_retire),
            .error_code(check_code),.error_index(check_index)
        );
        assign local_pair_response_valid_i=raw_pair_valid&&(raw_pair_error||check_valid)&&!layout_cancel;
        assign raw_pair_ready=pair_retire;
        assign local_pair_busy_i=raw_pair_busy||check_busy;
        assign local_pair_response_error_i=raw_pair_error||(check_code!=0);
        assign local_pair_response_error_code_i=raw_pair_error ? raw_pair_code :
                                          ((check_code==0) ? 8'd0 : 8'h30+{6'd0,check_code});
        assign local_pair_response_error_address_i=raw_pair_error ? raw_pair_address :
            ((check_code==0) ? 32'd0 :
             ((check_code==3) ? ((check_index==0) ? resolved_output_base : preview_base_q) :
              ((check_index==0) ? resolved_input_base : ((check_index==1) ? resolved_output_base : preview_base_q))));
    end else begin: g_pair_only
        assign local_pair_response_valid_i=raw_pair_valid;
        assign raw_pair_ready=local_pair_response_ready_i;
        assign local_pair_response_error_i=raw_pair_error;
        assign local_pair_response_error_code_i=raw_pair_code;
        assign local_pair_response_error_address_i=raw_pair_address;
        assign local_pair_busy_i=raw_pair_busy;
    end endgenerate

    assign region_cancel=rst||job_abort||pair_abort_request_pulse||
                         pair_abort_pending_q||pair_abort_to_child;
    assign region_request=CHECK_WRITE_REGIONS && local_pair_response_valid_i &&
                          !local_pair_response_error_i && !region_cancel;
    assign pair_response_valid_i=local_pair_response_valid_i && !region_cancel &&
        (!CHECK_WRITE_REGIONS || local_pair_response_error_i || region_response);
    assign local_pair_response_ready_i=pair_response_ready_i && !region_cancel &&
        (!CHECK_WRITE_REGIONS || local_pair_response_error_i || region_response);
    assign pair_response_error_i=local_pair_response_error_i ||
        (CHECK_WRITE_REGIONS && region_response && region_error_code!=0);
    assign pair_response_error_code_i=local_pair_response_error_i ? local_pair_response_error_code_i :
        (CHECK_WRITE_REGIONS ? region_error_code : 8'd0);
    assign pair_response_error_address_i=local_pair_response_error_i ? local_pair_response_error_address_i :
        (CHECK_WRITE_REGIONS ? region_error_address : 32'd0);
    assign pair_busy_i=local_pair_busy_i;

    always_comb begin
        job_start_fire = job_start_valid && job_start_ready;

        config_start_ready_i = !rst && !config_inflight_q &&
                               !config_response_pending_q && !loader_busy &&
                               !config_abort_pending_q &&
                               !config_axi_arvalid && !config_axi_rready;
        config_start_fire_i = config_start_valid_i && config_start_ready_i;
        loader_start_pulse = config_start_fire_i;

        config_response_valid_i = config_response_pending_q;
        config_response_fire_i = config_response_valid_i &&
                                 config_response_ready_i;

        // Include the reader-facing AXI states because the loader's scheduler
        // can retire its control state before an aborted AXI burst has drained.
        config_busy_i = config_inflight_q || config_response_pending_q ||
                        config_abort_pending_q || loader_busy ||
                        config_axi_arvalid || config_axi_rready;

        // Never cancel a VALID that the serial arbiter has already selected.
        // If READY is high, the same edge commits AR and the child interprets
        // abort as "drain and drop" rather than "cancel before AR".
        pair_abort_to_child =
            (pair_abort_pending_q || pair_abort_request_pulse) &&
            (!pair_axi_arvalid || pair_axi_arready);
        config_abort_to_child =
            (config_abort_pending_q || config_abort_request_pulse) &&
            (!config_axi_arvalid || config_axi_arready);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            preview_base_q<=0;preview_stride_q<=0;
            input_table_base_q <= 64'd0;
            output_table_base_q <= 64'd0;
            input_buffer_index_q <= 2'd0;
            output_buffer_index_q <= 2'd0;
            width_pixels_q <= 16'd0;
            height_lines_q <= 16'd0;
            input_width_q <= 0;
            input_height_q <= 0;
            descriptor_base_q <= 32'd0;
            descriptor_count_q <= '0;
        end else if (job_start_fire) begin
            preview_base_q<=job_preview_base;preview_stride_q<=job_preview_stride;
            input_table_base_q <= job_input_table_base;
            output_table_base_q <= job_output_table_base;
            input_buffer_index_q <= job_input_buffer_index;
            output_buffer_index_q <= job_output_buffer_index;
            width_pixels_q <= job_width_pixels;
            height_lines_q <= job_height_lines;
            input_width_q <= SEPARATE_INPUT_GEOMETRY ? job_input_width_pixels : job_width_pixels;
            input_height_q <= SEPARATE_INPUT_GEOMETRY ? job_input_height_lines : job_height_lines;
            descriptor_base_q <= job_descriptor_base;
            descriptor_count_q <= job_descriptor_count;
        end
    end

    // Stretch controller abort pulses until cancelling the selected child's
    // AXI request is protocol-safe.  A stalled downstream AR therefore delays
    // job_aborted instead of wedging the serial arbiter in its grant state.
    always_ff @(posedge clk) begin
        if (rst) begin
            pair_abort_pending_q <= 1'b0;
            config_abort_pending_q <= 1'b0;
        end else begin
            if (pair_abort_to_child)
                pair_abort_pending_q <= 1'b0;
            else if (pair_abort_request_pulse)
                pair_abort_pending_q <= 1'b1;

            if (config_abort_to_child)
                config_abort_pending_q <= 1'b0;
            else if (config_abort_request_pulse)
                config_abort_pending_q <= 1'b1;
        end
    end

    // Convert the loader's pulse interface into the prerequisite ready/valid
    // response held for the job controller.  Controller-requested abort drops
    // any response and waits for loader/AXI busy indications to drain.
    always_ff @(posedge clk) begin
        if (rst) begin
            config_inflight_q <= 1'b0;
            config_response_pending_q <= 1'b0;
            config_response_error_q <= 1'b0;
            config_response_address_q <= 32'd0;
        end else if (config_abort_to_child) begin
            config_inflight_q <= 1'b0;
            config_response_pending_q <= 1'b0;
            config_response_error_q <= 1'b0;
            config_response_address_q <= 32'd0;
        end else begin
            if (config_start_fire_i) begin
                config_inflight_q <= 1'b1;
                config_response_pending_q <= 1'b0;
                config_response_error_q <= 1'b0;
                config_response_address_q <= descriptor_base_q;
            end

            if (config_inflight_q &&
                (loader_done_pulse || loader_error_pulse)) begin
                config_inflight_q <= 1'b0;
                config_response_pending_q <= 1'b1;
                config_response_error_q <= loader_error_pulse;
                config_response_address_q <= descriptor_base_q;
            end else if (loader_aborted_pulse) begin
                config_inflight_q <= 1'b0;
                config_response_pending_q <= 1'b0;
                config_response_error_q <= 1'b0;
            end else if (config_response_fire_i) begin
                config_response_pending_q <= 1'b0;
            end
        end
    end

    c1_r1_job_controller u_job_controller (
        .clk(clk),
        .rst(rst),
        .start_valid(job_start_valid),
        .start_ready(job_start_ready),
        .cycle_budget(job_cycle_budget),
        .abort(job_abort),
        .busy(busy),
        .job_done(job_done),
        .job_error(job_error),
        .job_aborted(job_aborted),
        .error_code(error_code),
        .error_address(error_address),
        .pair_start_valid(pair_start_valid_i),
        .pair_start_ready(pair_start_ready_i),
        .pair_response_valid(pair_response_valid_i),
        .pair_response_ready(pair_response_ready_i),
        .pair_response_error(pair_response_error_i),
        .pair_response_error_code(pair_response_error_code_i),
        .pair_response_error_address(pair_response_error_address_i),
        .pair_busy(pair_busy_i),
        .pair_abort_pulse(pair_abort_request_pulse),
        .config_start_valid(config_start_valid_i),
        .config_start_ready(config_start_ready_i),
        .config_response_valid(config_response_valid_i),
        .config_response_ready(config_response_ready_i),
        .config_response_error(config_response_error_q),
        .config_response_error_code(CONFIG_LOAD_ERROR_CODE),
        .config_response_error_address(config_response_address_q),
        .config_busy(config_busy_i),
        .config_abort_pulse(config_abort_request_pulse),
        .input_dma_ready(input_dma_ready),
        .input_dma_start(input_dma_start),
        .input_dma_busy(input_dma_busy),
        .input_dma_done(input_dma_done),
        .input_dma_error(input_dma_error),
        .input_dma_error_code(input_dma_error_code),
        .input_dma_error_address(input_dma_error_address),
        .output_dma_ready(output_dma_ready),
        .output_dma_start(output_dma_start),
        .output_dma_busy(output_dma_busy),
        .output_dma_done(output_dma_done),
        .output_dma_error(output_dma_error),
        .output_dma_error_code(output_dma_error_code),
        .output_dma_error_address(output_dma_error_address),
        .descriptor_busy(descriptor_busy),
        .descriptor_done(descriptor_done),
        .descriptor_error(descriptor_error),
        .descriptor_error_code(descriptor_error_code),
        .descriptor_error_address(descriptor_error_address),
        .descriptor_abort_pulse(descriptor_abort_pulse),
        .engine_ready(engine_ready),
        .engine_start(engine_start),
        .engine_busy(engine_busy),
        .engine_done(engine_done),
        .engine_error(engine_error),
        .engine_error_code(engine_error_code),
        .engine_error_address(engine_error_address),
        .engine_abort_pulse(engine_abort_pulse)
    );

    c1_frame_pair_resolver #(.SEPARATE_INPUT_GEOMETRY(SEPARATE_INPUT_GEOMETRY)) u_frame_pair_resolver (
        .expected_input_width_pixels(input_width_q),
        .expected_input_height_lines(input_height_q),
        .clk(clk),
        .rst(rst),
        .abort(pair_abort_to_child),
        .start_valid(pair_start_valid_i),
        .start_ready(pair_start_ready_i),
        .input_table_base(input_table_base_q),
        .output_table_base(output_table_base_q),
        .input_buffer_index(input_buffer_index_q),
        .output_buffer_index(output_buffer_index_q),
        .expected_width_pixels(width_pixels_q),
        .expected_height_lines(height_lines_q),
        .response_valid(raw_pair_valid),
        .response_ready(raw_pair_ready),
        .response_error(resolver_pair_error),
        .response_error_code(resolver_pair_code),
        .response_error_address(resolver_pair_address),
        .resolved_input_base(resolved_input_base),
        .resolved_input_stride(resolved_input_stride),
        .resolved_input_width(resolved_input_width),
        .resolved_input_height(resolved_input_height),
        .resolved_output_base(resolved_output_base),
        .resolved_output_stride(resolved_output_stride),
        .resolved_output_width(resolved_output_width),
        .resolved_output_height(resolved_output_height),
        .busy(raw_pair_busy),
        .m_axi_araddr(pair_axi_araddr),
        .m_axi_arlen(pair_axi_arlen),
        .m_axi_arsize(pair_axi_arsize),
        .m_axi_arburst(pair_axi_arburst),
        .m_axi_arvalid(pair_axi_arvalid),
        .m_axi_arready(pair_axi_arready),
        .m_axi_rdata(pair_axi_rdata),
        .m_axi_rresp(pair_axi_rresp),
        .m_axi_rlast(pair_axi_rlast),
        .m_axi_rvalid(pair_axi_rvalid),
        .m_axi_rready(pair_axi_rready)
    );

    c1_r1_config_loader_subsystem #(
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .SYNC_READ(SYNC_READ),
        .FAST_WIDE(FAST_WIDE)
    ) u_config_loader (
        .clk(clk),
        .rst(rst),
        .start_pulse(loader_start_pulse),
        .abort_pulse(config_abort_to_child),
        .descriptor_count(descriptor_count_q),
        .descriptor_base(descriptor_base_q),
        .command_accept_enable(1'b1),
        .busy(loader_busy),
        .done_pulse(loader_done_pulse),
        .error_pulse(loader_error_pulse),
        .aborted_pulse(loader_aborted_pulse),
        .config_loading(config_loading),
        .config_commit_pulse(config_commit_pulse),
        .active_bank(active_config_bank),
        .active_count(active_config_count),
        .generation(active_config_generation),
        .engine_read_enable(config_read_enable),
        .engine_read_index(config_read_index),
        .engine_read_ready(config_read_ready),
        .engine_read_busy(config_read_busy),
        .engine_read_valid(config_read_valid),
        .engine_read_descriptor(config_read_descriptor),
        .engine_read_generation(config_read_generation),
        .m_axi_araddr(config_axi_araddr),
        .m_axi_arlen(config_axi_arlen),
        .m_axi_arsize(config_axi_arsize),
        .m_axi_arburst(config_axi_arburst),
        .m_axi_arvalid(config_axi_arvalid),
        .m_axi_arready(config_axi_arready),
        .m_axi_rdata(config_axi_rdata),
        .m_axi_rresp(config_axi_rresp),
        .m_axi_rlast(config_axi_rlast),
        .m_axi_rvalid(config_axi_rvalid),
        .m_axi_rready(config_axi_rready)
    );

    c1_axi2_serial_arbiter_128 u_read_arbiter (
        .clk(clk),
        .rst(rst),
        .s0_awaddr(32'd0),
        .s0_awlen(8'd0),
        .s0_awsize(3'd0),
        .s0_awburst(2'd0),
        .s0_awvalid(1'b0),
        .s0_awready(),
        .s0_wdata(128'd0),
        .s0_wstrb(16'd0),
        .s0_wlast(1'b0),
        .s0_wvalid(1'b0),
        .s0_wready(),
        .s0_bresp(),
        .s0_bvalid(),
        .s0_bready(1'b1),
        .s0_araddr(pair_axi_araddr),
        .s0_arlen(pair_axi_arlen),
        .s0_arsize(pair_axi_arsize),
        .s0_arburst(pair_axi_arburst),
        .s0_arvalid(pair_axi_arvalid),
        .s0_arready(pair_axi_arready),
        .s0_rdata(pair_axi_rdata),
        .s0_rresp(pair_axi_rresp),
        .s0_rlast(pair_axi_rlast),
        .s0_rvalid(pair_axi_rvalid),
        .s0_rready(pair_axi_rready),
        .s1_awaddr(32'd0),
        .s1_awlen(8'd0),
        .s1_awsize(3'd0),
        .s1_awburst(2'd0),
        .s1_awvalid(1'b0),
        .s1_awready(),
        .s1_wdata(128'd0),
        .s1_wstrb(16'd0),
        .s1_wlast(1'b0),
        .s1_wvalid(1'b0),
        .s1_wready(),
        .s1_bresp(),
        .s1_bvalid(),
        .s1_bready(1'b1),
        .s1_araddr(config_axi_araddr),
        .s1_arlen(config_axi_arlen),
        .s1_arsize(config_axi_arsize),
        .s1_arburst(config_axi_arburst),
        .s1_arvalid(config_axi_arvalid),
        .s1_arready(config_axi_arready),
        .s1_rdata(config_axi_rdata),
        .s1_rresp(config_axi_rresp),
        .s1_rlast(config_axi_rlast),
        .s1_rvalid(config_axi_rvalid),
        .s1_rready(config_axi_rready),
        .m_awaddr(),
        .m_awlen(),
        .m_awsize(),
        .m_awburst(),
        .m_awvalid(),
        .m_awready(1'b0),
        .m_wdata(),
        .m_wstrb(),
        .m_wlast(),
        .m_wvalid(),
        .m_wready(1'b0),
        .m_bresp(2'b00),
        .m_bvalid(1'b0),
        .m_bready(),
        .m_araddr(m_axi_araddr),
        .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize),
        .m_arburst(m_axi_arburst),
        .m_arvalid(m_axi_arvalid),
        .m_arready(m_axi_arready),
        .m_rdata(m_axi_rdata),
        .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast),
        .m_rvalid(m_axi_rvalid),
        .m_rready(m_axi_rready)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (loader_done_pulse && loader_error_pulse)
                $fatal(1, "config loader asserted done and error together");
            if ((loader_done_pulse || loader_error_pulse) &&
                !config_inflight_q)
                $fatal(1, "config loader terminal pulse without an inflight request");
            if ((input_dma_start != output_dma_start) ||
                (input_dma_start != engine_start))
                $fatal(1, "execution clients did not launch atomically");
            if (job_abort && (input_dma_start || output_dma_start || engine_start))
                $fatal(1, "job launched while abort was asserted");
        end
    end
`endif

endmodule
