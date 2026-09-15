`timescale 1ns/1ps

// Portable camera-clock to core-clock RAW10 capture frontend.
//
// The module deliberately stops at a backpressured RGB888 stream suitable for
// c1_axi_xrgb_frame_writer.  Frame-buffer ownership and address resolution are
// system-level responsibilities.  The async FIFO is bounded ingress elasticity,
// not a frame store: the default 2048 entries hold only about 3.2 lines of a
// 642-pixel sensor frame. Default camera_valid is a non-retryable sample strobe:
// a pulse while !camera_ready is lost. A pausable ready/valid producer must
// explicitly select CAMERA_READY_VALID_SOURCE=1 and hold the entire payload.
// Allocation/table lookup must otherwise fit within the bounded backlog.
// Once begin_frame is
// accepted, the R1 ISP consumes the frame and an elastic output FIFO absorbs
// bounded DDR stalls.  If that FIFO cannot preserve the no-backpressure ISP
// contract, the frame is rejected with an explicit error.
module c1_r1_capture_frontend #(
    parameter integer SENSOR_WIDTH = 642,
    parameter integer SENSOR_HEIGHT = 482,
    parameter integer CAMERA_FIFO_DEPTH = 2048,
    parameter integer OUTPUT_FIFO_DEPTH = 128,
    parameter integer PIPELINE_HEADROOM = 32,
    parameter integer X_BITS = (SENSOR_WIDTH <= 1) ? 1 : $clog2(SENSOR_WIDTH),
    parameter integer Y_BITS = (SENSOR_HEIGHT <= 1) ? 1 : $clog2(SENSOR_HEIGHT),
    // 0: free-running sample strobe; 1: source holds valid/payload until ready.
    parameter bit CAMERA_READY_VALID_SOURCE = 1'b0,
    // Opt-in until system-level error/AXI drain integration is qualified.
    parameter bit CHECK_RAW_RASTER = 1'b0,
    // Core cycles without FIFO input while ISP could accept it. Zero disables.
    // Requires CHECK_RAW_RASTER; timeout rejects a frame, never releases AXI.
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
    input  logic                    camera_clear_error,
    output logic                    camera_overflow,

    input  logic                    core_clk,
    input  logic                    core_rst,
    output logic                    frame_waiting,
    input  logic                    begin_frame,
    output logic                    begin_ready,
    input  logic                    drop_frame,
    // Maintenance mode used while capture admission is closed.  Any queued
    // data is discarded silently through EOF, including a mid-frame head left
    // by reset/disable.  Deassertion never truncates an in-progress cleanup.
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

    output logic                    m_valid,
    input  logic                    m_ready,
    output logic [23:0]             m_rgb,
    output logic                    m_sof,
    output logic                    m_eol,
    output logic                    m_eof,
    // Core-domain recovery command and explicit external safety confirmations.
    // Source stays stopped and admission closed through recovery_done.
    input logic recovery_request,recovery_source_quiescent,recovery_fabric_drained,
    output logic recovery_ready,recovery_busy,recovery_done
);

    localparam integer CAMERA_DATA_W = 3 + X_BITS + Y_BITS + 10;
    localparam integer OUTPUT_DATA_W = 27;
    localparam integer OUTPUT_LEVEL_W = $clog2(OUTPUT_FIFO_DEPTH + 1);
    localparam integer STOP_LEVEL = OUTPUT_FIFO_DEPTH - PIPELINE_HEADROOM;
    localparam logic [OUTPUT_LEVEL_W-1:0] STOP_LEVEL_VALUE = STOP_LEVEL;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_STREAM,
        ST_WAIT_PIPE,
        ST_DRAIN_RAW,
        ST_RECOVER,
        ST_RESYNC
    } state_t;

    state_t state;
    logic [CAMERA_DATA_W-1:0] camera_fifo_in_data;
    logic camera_fifo_valid;
    logic camera_fifo_ready;
    logic [CAMERA_DATA_W-1:0] camera_fifo_out_data;
    logic camera_fifo_out_valid;
    logic camera_fifo_out_ready;
    logic camera_fifo_full;
    logic camera_fifo_empty;

    logic fifo_sof;
    logic fifo_eol;
    logic fifo_eof;
    logic [X_BITS-1:0] fifo_x;
    logic [Y_BITS-1:0] fifo_y;
    logic [9:0] fifo_raw10;
    logic raw_fire;
    logic isp_in_valid;
    logic isp_out_valid;
    logic isp_out_sof;
    logic isp_out_eol;
    logic isp_out_eof;
    logic [X_BITS-1:0] isp_out_x;
    logic [Y_BITS-1:0] isp_out_y;
    logic [23:0] isp_out_rgb;

    logic output_fifo_in_valid;
    logic output_fifo_in_ready;
    logic [OUTPUT_DATA_W-1:0] output_fifo_in_data;
    logic output_fifo_full;
    logic output_fifo_empty;
    logic [OUTPUT_LEVEL_W-1:0] output_fifo_level;
    logic [OUTPUT_DATA_W-1:0] output_fifo_out_data;
    logic output_fifo_clear;
    logic input_has_headroom;

    logic camera_overflow_sync1;
    logic camera_overflow_sync2;
    logic camera_overflow_seen;
    logic drain_through_isp;
    logic guard_ready, guard_valid;
    logic first_raw_q;
    logic silent_drain_seen_q;
    wire recovery_core_reset,recovery_camera_reset;
    generate
        if(ENABLE_EXPLICIT_RECOVERY) begin : gen_explicit_recovery
            c1_capture_recovery_fence u_recovery (
                .core_clk(core_clk),.core_rst(core_rst),
                .camera_clk(camera_clk),.camera_rst(camera_rst),
                .request(recovery_request),.source_quiescent(recovery_source_quiescent),
                .fabric_drained(recovery_fabric_drained),.request_ready(recovery_ready),
                .busy(recovery_busy),.done(recovery_done),
                .core_fifo_reset(recovery_core_reset),.camera_fifo_reset(recovery_camera_reset)
            );
        end else begin : gen_no_explicit_recovery
            assign recovery_ready=1'b0;
            assign recovery_busy=1'b0;
            assign recovery_done=1'b0;
            assign recovery_core_reset=1'b0;
            assign recovery_camera_reset=1'b0;
        end
    endgenerate
    wire checking_raw = (state == ST_STREAM) ||
                        ((state == ST_DRAIN_RAW) && drain_through_isp);
    wire legal_sof_head = fifo_sof && (fifo_x == 0) && (fifo_y == 0);
    wire silent_restart_head = CHECK_RAW_RASTER && (state == ST_DRAIN_RAW) &&
        !drain_through_isp && silent_drain_seen_q && camera_fifo_out_valid && legal_sof_head;
    // The initial SOF belongs to the frame deliberately being discarded.
    // Only a subsequent SOF can terminate a silent drain missing its EOF.
    always_ff @(posedge core_clk) begin
        if(core_rst || state != ST_DRAIN_RAW) silent_drain_seen_q <= 1'b0;
        else if(raw_fire) silent_drain_seen_q <= 1'b1;
    end
    // Do not consume a new frame's first token as the old frame's error token.
    wire restart_head = CHECK_RAW_RASTER && checking_raw && !first_raw_q &&
                        camera_fifo_out_valid && legal_sof_head;
    wire guard_source_valid = checking_raw && !recovery_busy && camera_fifo_out_valid && !restart_head;
    wire raster_fault = CHECK_RAW_RASTER && checking_raw && !recovery_busy &&
        (restart_head || (guard_source_valid && guard_ready && !guard_valid));
    localparam integer IDLE_COUNT_W = (RAW_IDLE_TIMEOUT_CYCLES <= 1) ? 1 :
                                      $clog2(RAW_IDLE_TIMEOUT_CYCLES);
    logic [IDLE_COUNT_W-1:0] raw_idle_count_q;
    // Cancelled frames that have already entered the ISP still need a tail
    // or a local flush. Their discarded RGB needs no output FIFO headroom.
    // Silent maintenance drains never owned ISP pixel state and stay excluded.
    wire raw_idle_wait = checking_raw && !recovery_busy && !camera_fifo_out_valid &&
                         ((state == ST_DRAIN_RAW) || input_has_headroom);
    wire raw_idle_fault = CHECK_RAW_RASTER && (RAW_IDLE_TIMEOUT_CYCLES > 0) &&
                          raw_idle_wait &&
                          (raw_idle_count_q == RAW_IDLE_TIMEOUT_CYCLES-1);
    wire input_frame_fault = raster_fault || raw_idle_fault;
    always_ff @(posedge core_clk) begin
        if(core_rst || !raw_idle_wait || RAW_IDLE_TIMEOUT_CYCLES == 0)
            raw_idle_count_q <= '0;
        else if(!raw_idle_fault) raw_idle_count_q <= raw_idle_count_q + 1'b1;
    end

    always_ff @(posedge core_clk) begin
        if(core_rst) first_raw_q <= 1'b1;
        else if(begin_frame && begin_ready) first_raw_q <= 1'b1;
        else if(checking_raw && raw_fire) first_raw_q <= 1'b0;
    end

    generate
        if(CHECK_RAW_RASTER) begin : gen_raster_guard
            c1_raw_raster_guard #(
                .FRAME_WIDTH(SENSOR_WIDTH), .FRAME_HEIGHT(SENSOR_HEIGHT),
                .X_BITS(X_BITS), .Y_BITS(Y_BITS)
            ) u_guard (
                .clk(core_clk), .rst(core_rst),
                .cancel(recovery_core_reset || (state == ST_RECOVER) || (state == ST_RESYNC) ||
                        ((state == ST_DRAIN_RAW) && !drain_through_isp)),
                .start_valid(begin_frame && begin_ready),
                .start_ready(), .busy(), .done(), .error(), .error_code(),
                .s_valid(guard_source_valid), .s_ready(guard_ready),
                .s_raw10(fifo_raw10), .s_x(fifo_x), .s_y(fifo_y),
                .s_sof(fifo_sof), .s_eol(fifo_eol), .s_eof(fifo_eof),
                .m_valid(guard_valid),
                .m_ready((state == ST_STREAM) ? input_has_headroom : 1'b1),
                .m_raw10(), .m_x(), .m_y(), .m_sof(), .m_eol(), .m_eof()
            );
        end else begin : gen_no_raster_guard
            assign guard_ready = 1'b0;
            assign guard_valid = 1'b0;
        end
    endgenerate

    always_comb begin
        camera_fifo_in_data = {camera_sof, camera_eol, camera_eof,
                               camera_x, camera_y, camera_raw10};
        camera_fifo_valid = camera_valid;
        camera_ready = camera_fifo_ready;

        {fifo_sof, fifo_eol, fifo_eof, fifo_x, fifo_y, fifo_raw10} =
            camera_fifo_out_data;
        frame_waiting = (state == ST_IDLE) && !recovery_busy && !discard_idle && !abort_frame &&
                        camera_fifo_out_valid &&
                        fifo_sof && cfg_ready && !cfg_commit &&
                        !gamma_cfg_we && !capture_error;
        begin_ready = frame_waiting;
        cleanup_busy = recovery_busy || (state == ST_DRAIN_RAW) || (state == ST_RECOVER) ||
                       (state == ST_RESYNC);
        input_has_headroom = (output_fifo_level <= STOP_LEVEL_VALUE);

        camera_fifo_out_ready = 1'b0;
        isp_in_valid = 1'b0;
        if (state == ST_STREAM) begin
            camera_fifo_out_ready = input_has_headroom;
            isp_in_valid = camera_fifo_out_valid && input_has_headroom;
        end else if (state == ST_DRAIN_RAW) begin
            camera_fifo_out_ready = 1'b1;
            // If this frame had already entered the no-backpressure ISP, feed
            // its remaining RAW pixels and EOF while suppressing RGB output.
            // Otherwise the Debayer frame state would never retire.
            isp_in_valid = camera_fifo_out_valid && drain_through_isp;
        end
        if(CHECK_RAW_RASTER && checking_raw) begin
            camera_fifo_out_ready = guard_ready && !restart_head;
            isp_in_valid = guard_valid &&
                ((state == ST_STREAM) ? input_has_headroom : 1'b1);
        end
        if(state == ST_RESYNC)
            camera_fifo_out_ready = !legal_sof_head;
        if(silent_restart_head) camera_fifo_out_ready = 1'b0;
        if(recovery_busy) begin
            camera_fifo_out_ready=1'b0;
            isp_in_valid=1'b0;
        end
        raw_fire = camera_fifo_out_valid && camera_fifo_out_ready;

        output_fifo_in_valid = isp_out_valid &&
            ((state == ST_STREAM) || (state == ST_WAIT_PIPE));
        output_fifo_in_data = {isp_out_sof, isp_out_eol, isp_out_eof,
                               isp_out_rgb};
        {m_sof, m_eol, m_eof, m_rgb} = output_fifo_out_data;
    end

    logic camera_overflow_event;
    generate
        if(CAMERA_READY_VALID_SOURCE) begin : gen_pausable_source
            logic stalled_q;
            logic [CAMERA_DATA_W-1:0] stalled_payload_q;
            // READY returning high does not license replacing a held beat:
            // its original payload must survive through the accepting edge.
            assign camera_overflow_event = stalled_q &&
                (!camera_valid || camera_fifo_in_data != stalled_payload_q);
            always_ff @(posedge camera_clk) begin
                if(camera_rst) begin
                    stalled_q <= 1'b0;
                    stalled_payload_q <= '0;
                end else begin
                    stalled_q <= camera_valid && !camera_fifo_ready;
                    if(camera_valid && !camera_fifo_ready)
                        stalled_payload_q <= camera_fifo_in_data;
                end
            end
        end else begin : gen_sample_strobe_source
            assign camera_overflow_event = camera_valid && !camera_fifo_ready;
        end
    endgenerate

    always_ff @(posedge camera_clk) begin
        if (camera_rst) begin
            camera_overflow <= 1'b0;
        end else if (camera_overflow_event) begin
            // A clear acknowledges the previous fault, not a new sample loss
            // or one-cycle held-payload violation on this same camera edge.
            camera_overflow <= 1'b1;
        end else if (camera_clear_error) begin
            camera_overflow <= 1'b0;
        end
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            camera_overflow_sync1 <= 1'b0;
            camera_overflow_sync2 <= 1'b0;
        end else begin
            camera_overflow_sync1 <= camera_overflow;
            camera_overflow_sync2 <= camera_overflow_sync1;
        end
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            state <= ST_IDLE;
            frame_ingress_done <= 1'b0;
            frame_dropped <= 1'b0;
            frame_aborted <= 1'b0;
            capture_error <= 1'b0;
            capture_error_code <= 8'd0;
            output_fifo_clear <= 1'b0;
            camera_overflow_seen <= 1'b0;
            drain_through_isp <= 1'b0;
        end else begin
            frame_ingress_done <= 1'b0;
            frame_dropped <= 1'b0;
            frame_aborted <= 1'b0;
            output_fifo_clear <= 1'b0;

            if (clear_error) begin
                capture_error <= 1'b0;
                capture_error_code <= 8'd0;
                // The camera-domain clear reaches this synchronizer several
                // cycles later.  Mark the currently asserted level as seen so
                // it is not immediately re-reported, then re-arm only after
                // the synchronized sticky level has actually returned low.
                camera_overflow_seen <= camera_overflow_sync2;
            end else begin
                if (!camera_overflow_sync2)
                    camera_overflow_seen <= 1'b0;
                else if (!camera_overflow_seen) begin
                    camera_overflow_seen <= 1'b1;
                    capture_error <= 1'b1;
                    capture_error_code <= 8'h01;
                end
            end

            if(recovery_core_reset) begin
                state <= ST_IDLE;
                drain_through_isp <= 1'b0;
                output_fifo_clear <= 1'b1;
            end else if(recovery_busy) begin
                // Freeze the old frame until external AXI/source safety is
                // confirmed. In-flight ISP outputs can drain before reset.
            end else if (input_frame_fault) begin
                capture_error <= 1'b1;
                capture_error_code <= raw_idle_fault ? 8'h06 : 8'h05;
                output_fifo_clear <= 1'b1;
                drain_through_isp <= 1'b0;
                state <= ST_RESYNC;
            end else if (state == ST_RESYNC) begin
                // Neither held abort nor clear_error may skip this boundary.
                // The malformed token's EOF is not trusted as a boundary.
                if((camera_fifo_out_valid && legal_sof_head) ||
                   (raw_fire && fifo_eof)) state <= ST_RECOVER;
            end else if (output_fifo_in_valid && !output_fifo_in_ready) begin
                capture_error <= 1'b1;
                capture_error_code <= 8'h03;
                output_fifo_clear <= 1'b1;
                if (state == ST_STREAM) begin
                    drain_through_isp <= !(raw_fire && fifo_eof);
                    if(raw_fire && fifo_eof) state <= ST_RECOVER;
                    else state <= ST_DRAIN_RAW;
                end else begin
                    drain_through_isp <= 1'b0;
                    state <= ST_RECOVER;
                end
            end else if (abort_frame && (state != ST_IDLE)) begin
                // Abort may be a level while AXI/control cleanup completes.
                // Transition and report it once; repeated cycles must not cut
                // short a raw-to-EOF drain or repeatedly pulse frame_aborted.
                output_fifo_clear <= 1'b1;
                if (state == ST_STREAM) begin
                    frame_aborted <= 1'b1;
                    // The terminal RAW beat can handshake on this abort edge.
                    // Do not wait for an EOF that has already entered the ISP.
                    drain_through_isp <= !(raw_fire && fifo_eof);
                    if(raw_fire && fifo_eof) state <= ST_RECOVER;
                    else state <= ST_DRAIN_RAW;
                end else if (state == ST_WAIT_PIPE) begin
                    frame_aborted <= 1'b1;
                    drain_through_isp <= 1'b0;
                    state <= ST_RECOVER;
                end else if ((state == ST_DRAIN_RAW) &&
                             ((raw_fire && fifo_eof) || silent_restart_head)) begin
                    // The FIFO continues popping while abort is held.  Do not
                    // miss the terminal marker merely because the request is
                    // a multi-cycle level.
                    state <= ST_RECOVER;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        if ((discard_idle || abort_frame) &&
                            camera_fifo_out_valid) begin
                            // Maintenance discard is intentionally silent.  It
                            // accepts either SOF or a mid-frame FIFO head and
                            // restores the next admissible boundary at EOF.
                            output_fifo_clear <= 1'b1;
                            drain_through_isp <= 1'b0;
                            state <= ST_DRAIN_RAW;
                        end else if (drop_frame && camera_fifo_out_valid &&
                                     fifo_sof) begin
                            output_fifo_clear <= 1'b1;
                            frame_dropped <= 1'b1;
                            drain_through_isp <= 1'b0;
                            state <= ST_DRAIN_RAW;
                        end else if (begin_frame && begin_ready) begin
                            output_fifo_clear <= 1'b1;
                            drain_through_isp <= 1'b0;
                            state <= ST_STREAM;
                        end else if (camera_fifo_out_valid && !fifo_sof) begin
                            capture_error <= 1'b1;
                            capture_error_code <= 8'h02;
                            output_fifo_clear <= 1'b1;
                            frame_dropped <= 1'b1;
                            drain_through_isp <= 1'b0;
                            state <= ST_DRAIN_RAW;
                        end else if (begin_frame && !begin_ready) begin
                            capture_error <= 1'b1;
                            capture_error_code <= 8'h04;
                        end
                    end

                    ST_STREAM: begin
                        if (raw_fire && fifo_eof)
                            state <= ST_WAIT_PIPE;
                    end

                    ST_WAIT_PIPE: begin
                        if (isp_out_valid && isp_out_eof &&
                            output_fifo_in_ready) begin
                            frame_ingress_done <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end

                    ST_DRAIN_RAW: begin
                        if ((raw_fire && fifo_eof) || silent_restart_head)
                            state <= ST_RECOVER;
                    end

                    ST_RECOVER: begin
                        if (cfg_ready) begin
                            drain_through_isp <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

    c1_async_stream_fifo #(
        .DATA_WIDTH(CAMERA_DATA_W), .DEPTH(CAMERA_FIFO_DEPTH)
    ) u_camera_fifo (
        .wr_clk(camera_clk), .wr_rst(camera_rst || recovery_camera_reset),
        .in_valid(camera_fifo_valid), .in_ready(camera_fifo_ready),
        .in_data(camera_fifo_in_data), .wr_full(camera_fifo_full),
        .rd_clk(core_clk), .rd_rst(core_rst || recovery_core_reset),
        .out_valid(camera_fifo_out_valid), .out_ready(camera_fifo_out_ready),
        .out_data(camera_fifo_out_data), .rd_empty(camera_fifo_empty)
    );

    c1_r1_isp_pipeline #(
        .FRAME_WIDTH(SENSOR_WIDTH), .FRAME_HEIGHT(SENSOR_HEIGHT),
        .X_BITS(X_BITS), .Y_BITS(Y_BITS),
        .ENABLE_FRAME_FLUSH(CHECK_RAW_RASTER || ENABLE_EXPLICIT_RECOVERY)
    ) u_isp (
        .clk(core_clk), .rst(core_rst), .frame_flush(input_frame_fault || recovery_core_reset),
        .in_valid(isp_in_valid), .in_sof(fifo_sof), .in_eol(fifo_eol),
        .in_eof(fifo_eof), .in_x(fifo_x), .in_y(fifo_y),
        .in_raw10(fifo_raw10),
        .cfg_commit(cfg_commit), .cfg_ready(cfg_ready),
        .cfg_bayer_pattern(cfg_bayer_pattern),
        .cfg_roi_x_parity(cfg_roi_x_parity),
        .cfg_roi_y_parity(cfg_roi_y_parity),
        .cfg_black_r(cfg_black_r), .cfg_black_gr(cfg_black_gr),
        .cfg_black_gb(cfg_black_gb), .cfg_black_b(cfg_black_b),
        .cfg_awb_gain_r(cfg_awb_gain_r), .cfg_awb_gain_g(cfg_awb_gain_g),
        .cfg_awb_gain_b(cfg_awb_gain_b),
        .cfg_ccm_rr(cfg_ccm_rr), .cfg_ccm_rg(cfg_ccm_rg),
        .cfg_ccm_rb(cfg_ccm_rb), .cfg_ccm_gr(cfg_ccm_gr),
        .cfg_ccm_gg(cfg_ccm_gg), .cfg_ccm_gb(cfg_ccm_gb),
        .cfg_ccm_br(cfg_ccm_br), .cfg_ccm_bg(cfg_ccm_bg),
        .cfg_ccm_bb(cfg_ccm_bb),
        .cfg_ccm_offset_r(cfg_ccm_offset_r),
        .cfg_ccm_offset_g(cfg_ccm_offset_g),
        .cfg_ccm_offset_b(cfg_ccm_offset_b),
        .gamma_cfg_we(gamma_cfg_we), .gamma_cfg_addr(gamma_cfg_addr),
        .gamma_cfg_data(gamma_cfg_data),
        .gamma_cfg_ready(gamma_cfg_ready),
        .out_valid(isp_out_valid), .out_sof(isp_out_sof),
        .out_eol(isp_out_eol), .out_eof(isp_out_eof),
        .out_x(isp_out_x), .out_y(isp_out_y), .out_rgb888(isp_out_rgb)
    );

    c1_stream_fifo #(
        .DATA_WIDTH(OUTPUT_DATA_W), .DEPTH(OUTPUT_FIFO_DEPTH),
        .LEVEL_WIDTH(OUTPUT_LEVEL_W)
    ) u_output_fifo (
        .clk(core_clk), .rst(core_rst || output_fifo_clear || input_frame_fault || recovery_core_reset),
        .in_valid(output_fifo_in_valid), .in_ready(output_fifo_in_ready),
        .in_data(output_fifo_in_data), .out_valid(m_valid),
        .out_ready(m_ready), .out_data(output_fifo_out_data),
        .full(output_fifo_full), .empty(output_fifo_empty),
        .level(output_fifo_level)
    );

`ifndef SYNTHESIS
    initial begin
        if(RAW_IDLE_TIMEOUT_CYCLES < 0 ||
           (RAW_IDLE_TIMEOUT_CYCLES > 0 && !CHECK_RAW_RASTER))
            $fatal(1,"RAW idle timeout requires nonnegative cycles and raster checking");
        if (CAMERA_FIFO_DEPTH < 16)
            $fatal(1, "capture camera FIFO too small");
        if ((OUTPUT_FIFO_DEPTH < 16) ||
            (PIPELINE_HEADROOM < 8) ||
            (PIPELINE_HEADROOM >= OUTPUT_FIFO_DEPTH))
            $fatal(1, "capture output FIFO/headroom parameters invalid");
    end
`endif

endmodule
