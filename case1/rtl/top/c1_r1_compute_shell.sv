`timescale 1ns/1ps

// Board-independent R1 compute shell.
//
// This module is deliberately not a CNN.  It only connects three existing,
// independently verified blocks around an explicit external CNN seam:
//
//   ISP RGB or DMA RGB -> frame-locked source mux
//                      -> bilinear Resize + RGB-to-centered-C8 ingress
//                      -> cnn_in_*  [external CNN]
//   cnn_out_*          -> centered-C8-to-RGB egress -> out_*
//
// One legal start_valid/start_ready handshake starts the source mux, ingress,
// egress, and external CNN on the same edge in the default build.  The optional
// PIPELINED_START_CONFIG mode captures the configuration at that handshake and
// launches the children on the following edge, creating a real register boundary
// between the frame/control resolver and Resize.  start_ready is asserted only
// when all three internal children and cnn_start_ready are high.  Invalid
// Resize dimensions are accepted as a rejected job, set ERR_BAD_CONFIG, and
// do not start any participant; abort clears the error.
//
// abort is an immediate transaction fence: every externally visible ready or
// valid is low while abort is high, and all three children see the same abort
// edge.  A runtime child error similarly freezes every stream until abort.
//
// R1 valid-crop ISP coordinates normally begin at the first complete Debayer
// centre, e.g. (1,1), while the source mux consumes a zero-based logical
// raster.  For an ISP-selected job only, the first accepted SOF coordinate is
// captured as a per-frame origin and subtracted from every ISP coordinate.
// DMA coordinates are unchanged.  No data, coordinate, or SOF/EOL/EOF
// transformation occurs at either CNN seam.
//
// done pulses only after source mux, ingress, and egress have each completed
// their frame.  In the intended pipeline the egress EOF is last, but tracking
// all three completions avoids assuming any unimplemented CNN latency.
module c1_r1_compute_shell #(
    parameter integer MAX_WIDTH = 2048,
    parameter integer PIPELINED_START_CONFIG = 0,
    // Optional registered destructive-flush boundary in the RGB/Resize
    // ingress.  Raw abort still fences every shell interface immediately.
    parameter integer REGISTER_ABORT_RESET = 0
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start_valid,
    output logic                    start_ready,
    input  logic                    abort,
    input  logic                    source_select,

    input  logic [15:0]             cfg_win,
    input  logic [15:0]             cfg_hin,
    input  logic [15:0]             cfg_wout,
    input  logic [15:0]             cfg_hout,
    input  logic signed [31:0]      cfg_x_step_q16,
    input  logic signed [31:0]      cfg_y_step_q16,
    input  logic signed [31:0]      cfg_x_phase0_q16,
    input  logic signed [31:0]      cfg_y_phase0_q16,

    output logic                    busy,
    output logic                    done,
    output logic                    error,
    output logic [7:0]              error_code,

    // External CNN job control participates in the same atomic start/abort.
    output logic                    cnn_start_valid,
    input  logic                    cnn_start_ready,
    output logic                    cnn_abort,
    input  logic                    cnn_error,
    input  logic [7:0]              cnn_error_code,

    input  logic                    isp_valid,
    output logic                    isp_ready,
    input  logic [23:0]             isp_rgb888,
    input  logic [15:0]             isp_x,
    input  logic [15:0]             isp_y,
    input  logic                    isp_sof,
    input  logic                    isp_eol,
    input  logic                    isp_eof,

    input  logic                    dma_valid,
    output logic                    dma_ready,
    input  logic [23:0]             dma_rgb888,
    input  logic [15:0]             dma_x,
    input  logic [15:0]             dma_y,
    input  logic                    dma_sof,
    input  logic                    dma_eol,
    input  logic                    dma_eof,

    // External CNN input: NHWC-C8, lane 0 in bits [7:0].
    output logic                    cnn_in_valid,
    input  logic                    cnn_in_ready,
    output logic [63:0]             cnn_in_data_s8,
    output logic [15:0]             cnn_in_x,
    output logic [15:0]             cnn_in_y,
    output logic                    cnn_in_sof,
    output logic                    cnn_in_eol,
    output logic                    cnn_in_eof,

    // External CNN output.  Lanes 0/1/2 are centered-s8 R/G/B; lanes 3..7
    // must be zero and are checked by the existing egress diagnostic.
    input  logic                    cnn_out_valid,
    output logic                    cnn_out_ready,
    input  logic [63:0]             cnn_out_data_s8,
    input  logic [15:0]             cnn_out_x,
    input  logic [15:0]             cnn_out_y,
    input  logic                    cnn_out_sof,
    input  logic                    cnn_out_eol,
    input  logic                    cnn_out_eof,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic [23:0]             out_rgb888,
    output logic [15:0]             out_x,
    output logic [15:0]             out_y,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof
);

    localparam logic [7:0] ERR_NONE          = 8'h00;
    localparam logic [7:0] ERR_BAD_CONFIG    = 8'h01;
    localparam logic [7:0] ERR_SOURCE_BASE   = 8'h10;
    localparam logic [7:0] ERR_INGRESS_BASE  = 8'h20;
    localparam logic [7:0] ERR_INGRESS_CFG   = 8'h30;
    localparam logic [7:0] ERR_CNN_PADDING   = 8'h40;
    localparam logic [7:0] ERR_CNN_BASE      = 8'h80;

    logic job_active;
    logic error_q;
    logic config_legal;
    logic all_children_ready;
    logic start_fire;
    logic launch_fire;
    logic child_start;
    logic transfer_enable;
    logic runtime_error_now;

    // Optional launch register.  Keeping the default path combinationally
    // identical is important for the legacy ABI; the experimental mode only
    // changes the start/configuration boundary.
    logic start_pending_q;
    logic source_select_q;
    logic config_legal_q;
    logic [15:0] cfg_win_q;
    logic [15:0] cfg_hin_q;
    logic [15:0] cfg_wout_q;
    logic [15:0] cfg_hout_q;
    logic signed [31:0] cfg_x_step_q16_q;
    logic signed [31:0] cfg_y_step_q16_q;
    logic signed [31:0] cfg_x_phase0_q16_q;
    logic signed [31:0] cfg_y_phase0_q16_q;
    logic launch_source_select;
    logic [15:0] launch_cfg_win;
    logic [15:0] launch_cfg_hin;
    logic [15:0] launch_cfg_wout;
    logic [15:0] launch_cfg_hout;
    logic signed [31:0] launch_cfg_x_step_q16;
    logic signed [31:0] launch_cfg_y_step_q16;
    logic signed [31:0] launch_cfg_x_phase0_q16;
    logic signed [31:0] launch_cfg_y_phase0_q16;

    logic source_start_ready;
    logic source_busy;
    logic source_done;
    logic source_error;
    logic [2:0] source_error_code;
    logic [15:0] source_error_x_unused;
    logic [15:0] source_error_y_unused;
    logic source_isp_ready;
    logic source_dma_ready;
    logic isp_origin_valid;
    logic [15:0] isp_origin_x;
    logic [15:0] isp_origin_y;
    logic [15:0] isp_rebased_x;
    logic [15:0] isp_rebased_y;
    logic isp_origin_fire;
    logic source_out_valid;
    logic source_out_ready;
    logic [23:0] source_out_rgb888;
    logic [15:0] source_out_x;
    logic [15:0] source_out_y;
    logic source_out_sof;
    logic source_out_eol;
    logic source_out_eof;

    logic ingress_cfg_ready;
    logic ingress_cfg_error;
    logic ingress_aborted_unused;
    logic ingress_busy;
    logic ingress_done;
    logic ingress_error;
    logic [3:0] ingress_error_code;
    logic ingress_in_ready;
    logic ingress_out_valid;
    logic ingress_out_ready;
    logic [63:0] ingress_out_c8;
    logic [15:0] ingress_out_x;
    logic [15:0] ingress_out_y;
    logic ingress_out_sof;
    logic ingress_out_eol;
    logic ingress_out_eof;

    logic egress_start_ready;
    logic egress_busy;
    logic egress_done;
    logic egress_in_ready;
    logic egress_out_valid;
    logic egress_out_ready;
    logic [23:0] egress_out_rgb888;
    logic [15:0] egress_out_x;
    logic [15:0] egress_out_y;
    logic egress_out_sof;
    logic egress_out_eol;
    logic egress_out_eof;
    logic egress_padding_nonzero;

    logic source_done_seen;
    logic ingress_done_seen;
    logic egress_done_seen;
    logic all_done_now;

    always_comb begin
        config_legal = (cfg_win != 16'd0) &&
                       (cfg_hin != 16'd0) &&
                       (cfg_wout != 16'd0) &&
                       (cfg_hout != 16'd0) &&
                       (cfg_win <= MAX_WIDTH) &&
                       !cfg_y_step_q16[31];

        all_children_ready = source_start_ready && ingress_cfg_ready &&
                             egress_start_ready && cnn_start_ready;
        start_ready = !rst && !abort && !job_active && !error_q &&
                      !start_pending_q && all_children_ready;
        start_fire = start_valid && start_ready;

        launch_source_select = (PIPELINED_START_CONFIG != 0) ?
                               source_select_q : source_select;
        launch_cfg_win = (PIPELINED_START_CONFIG != 0) ? cfg_win_q : cfg_win;
        launch_cfg_hin = (PIPELINED_START_CONFIG != 0) ? cfg_hin_q : cfg_hin;
        launch_cfg_wout = (PIPELINED_START_CONFIG != 0) ? cfg_wout_q : cfg_wout;
        launch_cfg_hout = (PIPELINED_START_CONFIG != 0) ? cfg_hout_q : cfg_hout;
        launch_cfg_x_step_q16 = (PIPELINED_START_CONFIG != 0) ?
                                cfg_x_step_q16_q : cfg_x_step_q16;
        launch_cfg_y_step_q16 = (PIPELINED_START_CONFIG != 0) ?
                                cfg_y_step_q16_q : cfg_y_step_q16;
        launch_cfg_x_phase0_q16 = (PIPELINED_START_CONFIG != 0) ?
                                  cfg_x_phase0_q16_q : cfg_x_phase0_q16;
        launch_cfg_y_phase0_q16 = (PIPELINED_START_CONFIG != 0) ?
                                  cfg_y_phase0_q16_q : cfg_y_phase0_q16;

        if (PIPELINED_START_CONFIG != 0)
            launch_fire = start_pending_q && all_children_ready && config_legal_q;
        else
            launch_fire = start_fire && config_legal;
        child_start = launch_fire;

        runtime_error_now = job_active &&
                            (source_error || ingress_cfg_error ||
                             ingress_error || cnn_error ||
                             egress_padding_nonzero);
        transfer_enable = job_active && !rst && !abort && !error_q &&
                          !source_error && !ingress_cfg_error &&
                          !ingress_error && !cnn_error &&
                          !egress_padding_nonzero;

        busy = job_active;
        error = error_q;
        cnn_start_valid = child_start;
        cnn_abort = abort;

        // Gate both VALID and READY at every external or child boundary.  In
        // particular, abort cannot accept a source/CNN/output beat before its
        // synchronous child-reset edge arrives.
        isp_ready = source_isp_ready && transfer_enable;
        dma_ready = source_dma_ready && transfer_enable;
        source_out_ready = ingress_in_ready && transfer_enable;

        // Before the first selected ISP beat is accepted, present that beat
        // as logical (0,0).  The source mux still validates SOF, so a malformed
        // non-SOF first beat cannot be hidden by the rebase.
        if (isp_origin_valid) begin
            isp_rebased_x = isp_x - isp_origin_x;
            isp_rebased_y = isp_y - isp_origin_y;
        end else begin
            isp_rebased_x = 16'd0;
            isp_rebased_y = 16'd0;
        end
        isp_origin_fire = isp_valid && isp_ready && isp_sof &&
                          !isp_origin_valid;

        cnn_in_valid = ingress_out_valid && transfer_enable;
        ingress_out_ready = cnn_in_ready && transfer_enable;
        cnn_in_data_s8 = ingress_out_c8;
        cnn_in_x = ingress_out_x;
        cnn_in_y = ingress_out_y;
        cnn_in_sof = ingress_out_sof;
        cnn_in_eol = ingress_out_eol;
        cnn_in_eof = ingress_out_eof;

        cnn_out_ready = egress_in_ready && transfer_enable;

        out_valid = egress_out_valid && transfer_enable;
        egress_out_ready = out_ready && transfer_enable;
        out_rgb888 = egress_out_rgb888;
        out_x = egress_out_x;
        out_y = egress_out_y;
        out_sof = egress_out_sof;
        out_eol = egress_out_eol;
        out_eof = egress_out_eof;

        all_done_now = (source_done_seen || source_done) &&
                       (ingress_done_seen || ingress_done) &&
                       (egress_done_seen || egress_done);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            job_active <= 1'b0;
            error_q <= 1'b0;
            error_code <= ERR_NONE;
            done <= 1'b0;
            source_done_seen <= 1'b0;
            ingress_done_seen <= 1'b0;
            egress_done_seen <= 1'b0;
        end else begin
            done <= 1'b0;

            if (abort) begin
                job_active <= 1'b0;
                error_q <= 1'b0;
                error_code <= ERR_NONE;
                source_done_seen <= 1'b0;
                ingress_done_seen <= 1'b0;
                egress_done_seen <= 1'b0;
            end else if (start_fire) begin
                source_done_seen <= 1'b0;
                ingress_done_seen <= 1'b0;
                egress_done_seen <= 1'b0;
                if (!config_legal) begin
                    job_active <= 1'b0;
                    error_q <= 1'b1;
                    error_code <= ERR_BAD_CONFIG;
                end else begin
                    job_active <= 1'b1;
                    error_q <= 1'b0;
                    error_code <= ERR_NONE;
                end
            end else if (job_active) begin
                if (runtime_error_now) begin
                    error_q <= 1'b1;
                    if (source_error)
                        error_code <= ERR_SOURCE_BASE |
                                      {5'd0, source_error_code};
                    else if (ingress_cfg_error)
                        error_code <= ERR_INGRESS_CFG;
                    else if (ingress_error)
                        error_code <= ERR_INGRESS_BASE |
                                      {4'd0, ingress_error_code};
                    else if (cnn_error)
                        // Preserve seven diagnostic bits while reserving the
                        // upper half of the shell namespace for CNN errors.
                        error_code <= ERR_CNN_BASE |
                                      {1'b0, cnn_error_code[6:0]};
                    else
                        error_code <= ERR_CNN_PADDING;
                end else if (!error_q) begin
                    if (source_done)
                        source_done_seen <= 1'b1;
                    if (ingress_done)
                        ingress_done_seen <= 1'b1;
                    if (egress_done)
                        egress_done_seen <= 1'b1;

                    if (all_done_now) begin
                        job_active <= 1'b0;
                        done <= 1'b1;
                        source_done_seen <= 1'b0;
                        ingress_done_seen <= 1'b0;
                        egress_done_seen <= 1'b0;
                    end
                end
            end
        end
    end

    // In the pipelined launch experiment, capture every configuration field
    // together with the accepted start.  The pending bit is intentionally a
    // one-entry elastic launch queue: if the external CNN or a child loses
    // ready on the following cycle, the payload remains stable until launch.
    always_ff @(posedge clk) begin
        if (rst) begin
            start_pending_q     <= 1'b0;
            source_select_q     <= 1'b0;
            config_legal_q      <= 1'b0;
            cfg_win_q           <= 16'd0;
            cfg_hin_q           <= 16'd0;
            cfg_wout_q          <= 16'd0;
            cfg_hout_q          <= 16'd0;
            cfg_x_step_q16_q    <= 32'sd0;
            cfg_y_step_q16_q    <= 32'sd0;
            cfg_x_phase0_q16_q  <= 32'sd0;
            cfg_y_phase0_q16_q  <= 32'sd0;
        end else if (abort) begin
            start_pending_q <= 1'b0;
        end else if (PIPELINED_START_CONFIG != 0) begin
            if (start_fire) begin
                start_pending_q    <= config_legal;
                source_select_q    <= source_select;
                config_legal_q     <= config_legal;
                cfg_win_q          <= cfg_win;
                cfg_hin_q          <= cfg_hin;
                cfg_wout_q         <= cfg_wout;
                cfg_hout_q         <= cfg_hout;
                cfg_x_step_q16_q   <= cfg_x_step_q16;
                cfg_y_step_q16_q   <= cfg_y_step_q16;
                cfg_x_phase0_q16_q <= cfg_x_phase0_q16;
                cfg_y_phase0_q16_q <= cfg_y_phase0_q16;
            end else if (launch_fire) begin
                start_pending_q <= 1'b0;
            end
        end else begin
            start_pending_q <= 1'b0;
        end
    end

    // The origin belongs to exactly one atomically started job.  Capturing it
    // only on the actual ISP ready/valid SOF handshake makes stalls harmless.
    always_ff @(posedge clk) begin
        if (rst || abort || start_fire) begin
            isp_origin_valid <= 1'b0;
            isp_origin_x <= 16'd0;
            isp_origin_y <= 16'd0;
        end else if (isp_origin_fire) begin
            isp_origin_valid <= 1'b1;
            isp_origin_x <= isp_x;
            isp_origin_y <= isp_y;
        end
    end

    c1_r1_rgb_source_mux u_source_mux (
        .clk,
        .rst,
        .abort,
        .start_valid(child_start),
        .start_ready(source_start_ready),
        .source_select(launch_source_select),
        .busy(source_busy),
        .done(source_done),
        .error(source_error),
        .error_code(source_error_code),
        .error_x(source_error_x_unused),
        .error_y(source_error_y_unused),
        .isp_valid(isp_valid && transfer_enable),
        .isp_ready(source_isp_ready),
        .isp_rgb888,
        .isp_x(isp_rebased_x),
        .isp_y(isp_rebased_y),
        .isp_sof,
        .isp_eol,
        .isp_eof,
        .dma_valid(dma_valid && transfer_enable),
        .dma_ready(source_dma_ready),
        .dma_rgb888,
        .dma_x,
        .dma_y,
        .dma_sof,
        .dma_eol,
        .dma_eof,
        .out_valid(source_out_valid),
        .out_ready(source_out_ready),
        .out_rgb888(source_out_rgb888),
        .out_x(source_out_x),
        .out_y(source_out_y),
        .out_sof(source_out_sof),
        .out_eol(source_out_eol),
        .out_eof(source_out_eof)
    );

    c1_r1_compute_ingress #(
        .MAX_WIDTH(MAX_WIDTH),
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET)
    ) u_compute_ingress (
        .clk,
        .rst,
        .cfg_valid(child_start),
        .cfg_ready(ingress_cfg_ready),
        .cfg_error(ingress_cfg_error),
        .cfg_win(launch_cfg_win),
        .cfg_hin(launch_cfg_hin),
        .cfg_wout(launch_cfg_wout),
        .cfg_hout(launch_cfg_hout),
        .cfg_x_step_q16(launch_cfg_x_step_q16),
        .cfg_y_step_q16(launch_cfg_y_step_q16),
        .cfg_x_phase0_q16(launch_cfg_x_phase0_q16),
        .cfg_y_phase0_q16(launch_cfg_y_phase0_q16),
        .abort,
        .aborted(ingress_aborted_unused),
        .busy(ingress_busy),
        .done(ingress_done),
        .error(ingress_error),
        .error_code(ingress_error_code),
        .in_valid(source_out_valid && transfer_enable),
        .in_ready(ingress_in_ready),
        .in_x(source_out_x),
        .in_y(source_out_y),
        .in_sof(source_out_sof),
        .in_eol(source_out_eol),
        .in_eof(source_out_eof),
        .in_rgb888(source_out_rgb888),
        .out_valid(ingress_out_valid),
        .out_ready(ingress_out_ready),
        .out_c8(ingress_out_c8),
        .out_sof(ingress_out_sof),
        .out_eol(ingress_out_eol),
        .out_eof(ingress_out_eof),
        .out_x(ingress_out_x),
        .out_y(ingress_out_y)
    );

    c1_r1_compute_egress #(
        .X_BITS(16),
        .Y_BITS(16),
        .ENABLE_PADDING_DIAGNOSTIC(1'b1)
    ) u_compute_egress (
        .clk,
        .rst,
        .abort,
        .start_valid(child_start),
        .start_ready(egress_start_ready),
        .busy(egress_busy),
        .done(egress_done),
        .in_valid(cnn_out_valid && transfer_enable),
        .in_ready(egress_in_ready),
        .in_data_s8(cnn_out_data_s8),
        .in_x(cnn_out_x),
        .in_y(cnn_out_y),
        .in_sof(cnn_out_sof),
        .in_eol(cnn_out_eol),
        .in_eof(cnn_out_eof),
        .out_valid(egress_out_valid),
        .out_ready(egress_out_ready),
        .out_rgb888(egress_out_rgb888),
        .out_x(egress_out_x),
        .out_y(egress_out_y),
        .out_sof(egress_out_sof),
        .out_eol(egress_out_eol),
        .out_eof(egress_out_eof),
        .padding_nonzero_pulse(egress_padding_nonzero)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (child_start && !all_children_ready)
                $fatal(1, "compute shell started a child that was not ready");
            if (abort && (isp_ready || dma_ready || cnn_start_valid ||
                          cnn_in_valid || cnn_out_ready || out_valid))
                $fatal(1, "compute shell transferred data during abort");
            if (done && (busy || error))
                $fatal(1, "compute shell done overlapped busy/error");
            if (!job_active &&
                (source_done || ingress_done || egress_done))
                $fatal(1, "compute shell observed child done outside a job");
            if (source_busy != ingress_busy && child_start)
                $fatal(1, "compute shell children did not start atomically");
        end
    end
`endif

endmodule
