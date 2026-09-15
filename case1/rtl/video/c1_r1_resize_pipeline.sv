`timescale 1ns/1ps

// Complete board-independent streaming R1 RGB888 resize pipeline.
//
// A cfg_valid/cfg_ready handshake atomically starts both c1_r1_resize_system
// and c1_r1_resize_line_sampler.  There is no external four-point sampling
// seam: strict-raster RGB888 input is cached and sampled internally.
//
// Input contract:
//   * After a successful configuration handshake, source pixels start at
//     (0,0) and obey ready/valid plus exact SOF/EOL/EOF raster flags.
//   * win/hin/wout/hout must be non-zero, win <= MAX_WIDTH, and y_step must be
//     non-negative so the two-line sampler sees monotonic vertical requests.
//     The request generator uses signed48 accumulation to prevent signed32
//     phase wrap over the full 16-bit output dimension range.
//   * x coordinates may move in either direction because complete source rows
//     are retained and the sampler permits arbitrary x0/x1 access.
//
// The final output is held until the complete source raster has drained;
// a crop or constant y phase can finish sampling before source EOF arrives.
// done pulses only when the final output pixel is consumed.  error is sticky
// for a running job; a sampler protocol error leaves busy asserted and both
// streams stopped until abort or rst.
//
// abort is a synchronous destructive flush.  On a clock with abort asserted,
// no external input or output transfer is accepted, all coordinate/cache/
// interpolation state is reset, and aborted pulses if a job was active.  The
// next job may start after abort is deasserted, but its source raster must
// restart at (0,0); a partially consumed frame cannot be resumed.
module c1_r1_resize_pipeline #(
    parameter integer MAX_WIDTH = 2048,
    // Optional registered destructive-flush boundary.  The external abort
    // fence remains combinational (so VALID/READY are suppressed immediately),
    // while the child Resize state machines consume a one-cycle registered
    // reset.  This is disabled by default to preserve the reference timing
    // and cycle contract.
    parameter integer REGISTER_ABORT_RESET = 0
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    cfg_valid,
    output logic                    cfg_ready,
    output logic                    cfg_error,
    input  logic [15:0]             cfg_win,
    input  logic [15:0]             cfg_hin,
    input  logic [15:0]             cfg_wout,
    input  logic [15:0]             cfg_hout,
    input  logic signed [31:0]      cfg_x_step_q16,
    input  logic signed [31:0]      cfg_y_step_q16,
    input  logic signed [31:0]      cfg_x_phase0_q16,
    input  logic signed [31:0]      cfg_y_phase0_q16,

    input  logic                    abort,
    output logic                    aborted,
    output logic                    busy,
    output logic                    done,
    output logic                    error,
    output logic [3:0]              error_code,

    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [15:0]             in_x,
    input  logic [15:0]             in_y,
    input  logic                    in_sof,
    input  logic                    in_eol,
    input  logic                    in_eof,
    input  logic [23:0]             in_rgb888,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [15:0]             out_x,
    output logic [15:0]             out_y,
    output logic [23:0]             out_rgb888
);

    localparam logic [3:0] ERR_NONE          = 4'd0;
    localparam logic [3:0] ERR_BAD_DIMENSION = 4'd1;
    localparam logic [3:0] ERR_NEGATIVE_Y    = 4'd7;
    localparam logic [3:0] ERR_ENGINE_START  = 4'd8;

    logic engine_rst;
    logic abort_reset_q;
    logic engine_start;
    logic config_dimensions_valid;
    logic config_valid_for_engine;
    logic job_active;

    logic resize_start_ready;
    logic resize_start_error;
    logic resize_busy;
    logic resize_done_unused;
    logic sampler_start_ready;
    logic sampler_start_error;
    logic sampler_busy;
    logic sampler_done;
    logic sampler_error;
    logic [3:0] sampler_error_code;

    logic sample_req_valid;
    logic sample_req_ready;
    logic sample_req_last;
    logic [15:0] sample_req_out_x;
    logic [15:0] sample_req_out_y;
    logic [15:0] sample_req_x0;
    logic [15:0] sample_req_x1;
    logic [15:0] sample_req_y0;
    logic [15:0] sample_req_y1;
    logic [12:0] sample_req_wx0;
    logic [12:0] sample_req_wx1;
    logic [12:0] sample_req_wy0;
    logic [12:0] sample_req_wy1;

    logic sample_rsp_valid;
    logic sample_rsp_ready;
    logic [23:0] sample_rsp_rgb_y0x0;
    logic [23:0] sample_rsp_rgb_y0x1;
    logic [23:0] sample_rsp_rgb_y1x0;
    logic [23:0] sample_rsp_rgb_y1x1;

    logic sampler_src_ready;
    logic resize_out_valid;
    logic resize_out_ready;
    logic resize_out_sof;
    logic resize_out_eol;
    logic resize_out_eof;
    logic [15:0] resize_out_x;
    logic [15:0] resize_out_y;
    logic [23:0] resize_out_rgb888;
    logic final_output_handshake;

    // A runtime abort is a synchronous level at this module boundary.  In the
    // optional mode, retain it for one additional clock so both child state
    // machines receive a complete synchronous reset edge even when the source
    // pulse is only one cycle wide.  The wrapper-side gates below still use the
    // raw abort level and therefore never accept/expose a beat during that
    // first abort cycle.
    always_ff @(posedge clk) begin
        if (rst)
            abort_reset_q <= 1'b0;
        else if (REGISTER_ABORT_RESET != 0)
            abort_reset_q <= abort;
        else
            abort_reset_q <= 1'b0;
    end

    always_comb begin
        engine_rst = rst || ((REGISTER_ABORT_RESET != 0) ? abort_reset_q : abort);
        config_dimensions_valid = (cfg_win != 16'd0) &&
                                  (cfg_hin != 16'd0) &&
                                  (cfg_wout != 16'd0) &&
                                  (cfg_hout != 16'd0) &&
                                  (cfg_win <= MAX_WIDTH);
        config_valid_for_engine = config_dimensions_valid &&
                                  !cfg_y_step_q16[31];

        cfg_ready = !rst && !abort && !engine_rst && !job_active &&
                    resize_start_ready && sampler_start_ready;
        engine_start = cfg_valid && cfg_ready && config_valid_for_engine;
        busy = job_active;

        // Abort gates both sides before the synchronous engine reset edge, so
        // no pixel can be ambiguously accepted during a flush.
        in_ready = !rst && !abort && !engine_rst && !error && !sampler_error &&
                   sampler_src_ready;
        resize_out_ready = !rst && !abort && !engine_rst && !error && !sampler_error &&
                           out_ready && (!resize_out_eof || !sampler_busy);
        out_valid = !rst && !abort && !engine_rst && !error && !sampler_error &&
                    resize_out_valid && (!resize_out_eof || !sampler_busy);
        out_sof = resize_out_sof;
        out_eol = resize_out_eol;
        out_eof = resize_out_eof;
        out_x = resize_out_x;
        out_y = resize_out_y;
        out_rgb888 = resize_out_rgb888;
        final_output_handshake = resize_out_valid && resize_out_ready &&
                                 resize_out_eof;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            job_active <= 1'b0;
            cfg_error <= 1'b0;
            aborted <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
        end else begin
            cfg_error <= 1'b0;
            aborted <= 1'b0;
            done <= 1'b0;

            if (abort) begin
                aborted <= job_active;
                job_active <= 1'b0;
                error <= 1'b0;
                error_code <= ERR_NONE;
            end else begin
                if (cfg_valid && cfg_ready) begin
                    error <= 1'b0;
                    error_code <= ERR_NONE;
                    if (!config_dimensions_valid) begin
                        cfg_error <= 1'b1;
                        error <= 1'b1;
                        error_code <= ERR_BAD_DIMENSION;
                        job_active <= 1'b0;
                    end else if (cfg_y_step_q16[31]) begin
                        cfg_error <= 1'b1;
                        error <= 1'b1;
                        error_code <= ERR_NEGATIVE_Y;
                        job_active <= 1'b0;
                    end else begin
                        job_active <= 1'b1;
                    end
                end

                if (job_active && sampler_error && !error) begin
                    error <= 1'b1;
                    error_code <= sampler_error_code;
                end
                if (job_active &&
                    (resize_start_error || sampler_start_error) && !error) begin
                    error <= 1'b1;
                    error_code <= ERR_ENGINE_START;
                end

                if (final_output_handshake) begin
                    job_active <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    c1_r1_resize_system u_resize_system (
        .clk,
        .rst(engine_rst),
        .start(engine_start),
        .start_ready(resize_start_ready),
        .start_error(resize_start_error),
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .busy(resize_busy),
        .done(resize_done_unused),
        .sample_req_valid,
        .sample_req_ready,
        .sample_req_last,
        .sample_req_out_x,
        .sample_req_out_y,
        .sample_req_x0,
        .sample_req_x1,
        .sample_req_y0,
        .sample_req_y1,
        .sample_req_wx0,
        .sample_req_wx1,
        .sample_req_wy0,
        .sample_req_wy1,
        .sample_rsp_valid,
        .sample_rsp_ready,
        .sample_rsp_rgb_y0x0,
        .sample_rsp_rgb_y0x1,
        .sample_rsp_rgb_y1x0,
        .sample_rsp_rgb_y1x1,
        .out_valid(resize_out_valid),
        .out_ready(resize_out_ready),
        .out_sof(resize_out_sof),
        .out_eol(resize_out_eol),
        .out_eof(resize_out_eof),
        .out_x(resize_out_x),
        .out_y(resize_out_y),
        .out_rgb888(resize_out_rgb888)
    );

    c1_r1_resize_line_sampler #(
        .MAX_WIDTH(MAX_WIDTH)
    ) u_line_sampler (
        .clk,
        .rst(engine_rst),
        .start(engine_start),
        .start_ready(sampler_start_ready),
        .start_error(sampler_start_error),
        .cfg_win,
        .cfg_hin,
        .busy(sampler_busy),
        .done(sampler_done),
        .error(sampler_error),
        .error_code(sampler_error_code),
        .src_valid(in_valid && !rst && !abort),
        .src_ready(sampler_src_ready),
        .src_x(in_x),
        .src_y(in_y),
        .src_sof(in_sof),
        .src_eol(in_eol),
        .src_eof(in_eof),
        .src_rgb888(in_rgb888),
        .sample_req_valid,
        .sample_req_ready,
        .sample_req_last,
        .sample_req_out_x,
        .sample_req_out_y,
        .sample_req_x0,
        .sample_req_x1,
        .sample_req_y0,
        .sample_req_y1,
        .sample_req_wx0,
        .sample_req_wx1,
        .sample_req_wy0,
        .sample_req_wy1,
        .sample_rsp_valid,
        .sample_rsp_ready,
        .sample_rsp_rgb_y0x0,
        .sample_rsp_rgb_y0x1,
        .sample_rsp_rgb_y1x0,
        .sample_rsp_rgb_y1x1
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (engine_start && (!resize_start_ready || !sampler_start_ready))
                $fatal(1, "resize pipeline started engines while not ready");
            if (done && busy)
                $fatal(1, "resize pipeline done overlapped busy");
            if (job_active && (resize_busy != 1'b1))
                $fatal(1, "resize system busy dropped before wrapper completion");
            if (final_output_handshake && !sampler_done && sampler_busy)
                $fatal(1, "output completed before source sampler drained");
        end
    end
`endif

endmodule
