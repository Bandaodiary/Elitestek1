// C30 independent Resize overlap candidate; retained R1/C23/C29 unchanged.
`timescale 1ns/1ps

// Board-independent system adapter around the R1 resize request generator and
// RGB888 interpolation pipeline.
//
// The external sample transaction contains the four clamped source
// coordinates for one destination pixel.  Exactly one transaction may be
// outstanding.  Its response must contain RGB888 samples in this order:
//   y0x0, y0x1, y1x0, y1x1.
// The responder MUST register its response: no same-cycle combinational
// request->response path. Hold the samples until sample_rsp_ready is high.
// One old response can retire on the same edge as a replacement request;
// metadata for the old response is read before the new metadata is registered.
// Registered, non-flow-through request and response slices isolate coordinate
// clamping / cache-boundary control from the interpolation DSP enable cone.
// The request/response slices remain non-flow-through. Only the redundant
// pending-slot bubble is removed; arbitrary downstream stalls remain legal.
// There is no tag because responses are strictly in order and one-outstanding.
//
// start is accepted on start && start_ready.  All non-zero dimensions,
// Q16.16 steps, and phases are captured atomically.  Source or destination
// dimensions of one pixel are supported; the coordinate generator clamps both
// taps to index zero where appropriate.  Any zero dimension is rejected with
// a one-cycle start_error pulse and does not start a job.
//
// busy remains asserted through request generation, sample latency,
// interpolation, and downstream output stalls.  done pulses only when the
// final RGB output is consumed (out_valid && out_ready && out_eof).
module c1_r2_resize_overlap_system (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start,
    output logic                    start_ready,
    output logic                    start_error,
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

    output logic                    sample_req_valid,
    input  logic                    sample_req_ready,
    output logic                    sample_req_last,
    output logic [15:0]             sample_req_out_x,
    output logic [15:0]             sample_req_out_y,
    output logic [15:0]             sample_req_x0,
    output logic [15:0]             sample_req_x1,
    output logic [15:0]             sample_req_y0,
    output logic [15:0]             sample_req_y1,
    output logic [12:0]             sample_req_wx0,
    output logic [12:0]             sample_req_wx1,
    output logic [12:0]             sample_req_wy0,
    output logic [12:0]             sample_req_wy1,

    input  logic                    sample_rsp_valid,
    output logic                    sample_rsp_ready,
    input  logic [23:0]             sample_rsp_rgb_y0x0,
    input  logic [23:0]             sample_rsp_rgb_y0x1,
    input  logic [23:0]             sample_rsp_rgb_y1x0,
    input  logic [23:0]             sample_rsp_rgb_y1x1,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [15:0]             out_x,
    output logic [15:0]             out_y,
    output logic [23:0]             out_rgb888
);

    logic job_active;
    logic dimensions_valid;
    logic coord_start;
    logic coord_start_ready;
    logic coord_busy;
    logic coord_done_unused;
    logic coord_req_valid;
    logic coord_req_ready;
    logic coord_req_last;
    logic [15:0] coord_out_x;
    logic [15:0] coord_out_y;
    logic [15:0] coord_x0;
    logic [15:0] coord_x1;
    logic [15:0] coord_y0;
    logic [15:0] coord_y1;
    logic [12:0] coord_wx0;
    logic [12:0] coord_wx1;
    logic [12:0] coord_wy0;
    logic [12:0] coord_wy1;

    logic request_buf_valid;
    logic request_buf_last;
    logic [15:0] request_buf_out_x;
    logic [15:0] request_buf_out_y;
    logic [15:0] request_buf_x0;
    logic [15:0] request_buf_x1;
    logic [15:0] request_buf_y0;
    logic [15:0] request_buf_y1;
    logic [12:0] request_buf_wx0;
    logic [12:0] request_buf_wx1;
    logic [12:0] request_buf_wy0;
    logic [12:0] request_buf_wy1;

    logic sample_pending;
    logic [15:0] pending_out_x;
    logic [15:0] pending_out_y;
    logic pending_sof;
    logic pending_eol;
    logic pending_eof;
    logic [12:0] pending_wx0;
    logic [12:0] pending_wx1;
    logic [12:0] pending_wy0;
    logic [12:0] pending_wy1;
    logic [15:0] active_wout;

    logic response_buf_valid;
    logic response_buf_sof;
    logic response_buf_eol;
    logic response_buf_eof;
    logic [15:0] response_buf_x;
    logic [15:0] response_buf_y;
    logic [23:0] response_buf_rgb_y0x0;
    logic [23:0] response_buf_rgb_y0x1;
    logic [23:0] response_buf_rgb_y1x0;
    logic [23:0] response_buf_rgb_y1x1;
    logic [12:0] response_buf_wx0;
    logic [12:0] response_buf_wx1;
    logic [12:0] response_buf_wy0;
    logic [12:0] response_buf_wy1;

    logic interp_in_valid;
    logic interp_in_ready;

    always_comb begin
        dimensions_valid = (cfg_win != 0) && (cfg_hin != 0) &&
                           (cfg_wout != 0) && (cfg_hout != 0);
        start_ready = !rst && !job_active && !request_buf_valid &&
                      !sample_pending && !response_buf_valid &&
                      !out_valid && coord_start_ready;
        coord_start = start && start_ready && dimensions_valid;

        busy = job_active;

        // Deliberately do not make coord_req_ready depend on the sampler.
        // Once captured, every request field remains stable in this slice.
        coord_req_ready = !request_buf_valid;
        // The paired line sampler has a REGISTERED response. Permit the old
        // response to retire while a new request replaces its metadata slot.
        // No dependency on interpolator READY is added to this boundary.
        sample_req_valid = request_buf_valid &&
                           (!sample_pending || (sample_rsp_valid && sample_rsp_ready));
        sample_req_last = request_buf_last;
        sample_req_out_x = request_buf_out_x;
        sample_req_out_y = request_buf_out_y;
        sample_req_x0 = request_buf_x0;
        sample_req_x1 = request_buf_x1;
        sample_req_y0 = request_buf_y0;
        sample_req_y1 = request_buf_y1;
        sample_req_wx0 = request_buf_wx0;
        sample_req_wx1 = request_buf_wx1;
        sample_req_wy0 = request_buf_wy0;
        sample_req_wy1 = request_buf_wy1;

        // Likewise, RAM/cache response control cannot see interp_in_ready.
        // Metadata and samples move together into the response slice.
        sample_rsp_ready = sample_pending && !response_buf_valid;
        interp_in_valid = response_buf_valid;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            job_active <= 1'b0;
            start_error <= 1'b0;
            done <= 1'b0;
            request_buf_valid <= 1'b0;
            request_buf_last <= 1'b0;
            request_buf_out_x <= 16'd0;
            request_buf_out_y <= 16'd0;
            request_buf_x0 <= 16'd0;
            request_buf_x1 <= 16'd0;
            request_buf_y0 <= 16'd0;
            request_buf_y1 <= 16'd0;
            request_buf_wx0 <= 13'd0;
            request_buf_wx1 <= 13'd0;
            request_buf_wy0 <= 13'd0;
            request_buf_wy1 <= 13'd0;
            sample_pending <= 1'b0;
            pending_out_x <= 16'd0;
            pending_out_y <= 16'd0;
            pending_sof <= 1'b0;
            pending_eol <= 1'b0;
            pending_eof <= 1'b0;
            pending_wx0 <= 13'd0;
            pending_wx1 <= 13'd0;
            pending_wy0 <= 13'd0;
            pending_wy1 <= 13'd0;
            active_wout <= 16'd0;
            response_buf_valid <= 1'b0;
            response_buf_sof <= 1'b0;
            response_buf_eol <= 1'b0;
            response_buf_eof <= 1'b0;
            response_buf_x <= 16'd0;
            response_buf_y <= 16'd0;
            response_buf_rgb_y0x0 <= 24'd0;
            response_buf_rgb_y0x1 <= 24'd0;
            response_buf_rgb_y1x0 <= 24'd0;
            response_buf_rgb_y1x1 <= 24'd0;
            response_buf_wx0 <= 13'd0;
            response_buf_wx1 <= 13'd0;
            response_buf_wy0 <= 13'd0;
            response_buf_wy1 <= 13'd0;
        end else begin
            start_error <= 1'b0;
            done <= 1'b0;

            if (start && start_ready) begin
                if (dimensions_valid) begin
                    job_active <= 1'b1;
                    active_wout <= cfg_wout;
                end else begin
                    start_error <= 1'b1;
                end
            end

            if (coord_req_valid && coord_req_ready) begin
                request_buf_valid <= 1'b1;
                request_buf_last <= coord_req_last;
                request_buf_out_x <= coord_out_x;
                request_buf_out_y <= coord_out_y;
                request_buf_x0 <= coord_x0;
                request_buf_x1 <= coord_x1;
                request_buf_y0 <= coord_y0;
                request_buf_y1 <= coord_y1;
                request_buf_wx0 <= coord_wx0;
                request_buf_wx1 <= coord_wx1;
                request_buf_wy0 <= coord_wy0;
                request_buf_wy1 <= coord_wy1;
            end

            if (sample_req_valid && sample_req_ready) begin
                request_buf_valid <= 1'b0;
                sample_pending <= 1'b1;
                pending_out_x <= request_buf_out_x;
                pending_out_y <= request_buf_out_y;
                pending_sof <= (request_buf_out_x == 0) &&
                               (request_buf_out_y == 0);
                pending_eol <= (request_buf_out_x == active_wout - 16'd1);
                pending_eof <= request_buf_last;
                pending_wx0 <= request_buf_wx0;
                pending_wx1 <= request_buf_wx1;
                pending_wy0 <= request_buf_wy0;
                pending_wy1 <= request_buf_wy1;
            end

            if (sample_rsp_valid && sample_rsp_ready) begin
                // RHS metadata below is the OLD slot; concurrent request
                // metadata writes become visible only after this edge.
                sample_pending <= sample_req_valid && sample_req_ready;
                response_buf_valid <= 1'b1;
                response_buf_sof <= pending_sof;
                response_buf_eol <= pending_eol;
                response_buf_eof <= pending_eof;
                response_buf_x <= pending_out_x;
                response_buf_y <= pending_out_y;
                response_buf_rgb_y0x0 <= sample_rsp_rgb_y0x0;
                response_buf_rgb_y0x1 <= sample_rsp_rgb_y0x1;
                response_buf_rgb_y1x0 <= sample_rsp_rgb_y1x0;
                response_buf_rgb_y1x1 <= sample_rsp_rgb_y1x1;
                response_buf_wx0 <= pending_wx0;
                response_buf_wx1 <= pending_wx1;
                response_buf_wy0 <= pending_wy0;
                response_buf_wy1 <= pending_wy1;
            end

            if (response_buf_valid && interp_in_ready)
                response_buf_valid <= 1'b0;

            if (out_valid && out_ready && out_eof) begin
                job_active <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    r1_resize_request_q16 u_request (
        .clk,
        .rst,
        .start(coord_start),
        .start_ready(coord_start_ready),
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .busy(coord_busy),
        .done(coord_done_unused),
        .req_valid(coord_req_valid),
        .req_ready(coord_req_ready),
        .req_last(coord_req_last),
        .req_out_x(coord_out_x),
        .req_out_y(coord_out_y),
        .req_x0(coord_x0),
        .req_x1(coord_x1),
        .req_y0(coord_y0),
        .req_y1(coord_y1),
        .req_wx0(coord_wx0),
        .req_wx1(coord_wx1),
        .req_wy0(coord_wy0),
        .req_wy1(coord_wy1)
    );

    r1_bilinear_interp_rgb888 u_interp (
        .clk,
        .rst,
        .in_valid(interp_in_valid),
        .in_ready(interp_in_ready),
        .in_sof(response_buf_sof),
        .in_eol(response_buf_eol),
        .in_eof(response_buf_eof),
        .in_x(response_buf_x),
        .in_y(response_buf_y),
        .in_rgb_y0x0(response_buf_rgb_y0x0),
        .in_rgb_y0x1(response_buf_rgb_y0x1),
        .in_rgb_y1x0(response_buf_rgb_y1x0),
        .in_rgb_y1x1(response_buf_rgb_y1x1),
        .in_wx0(response_buf_wx0),
        .in_wx1(response_buf_wx1),
        .in_wy0(response_buf_wy0),
        .in_wy1(response_buf_wy1),
        .out_valid,
        .out_ready,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .out_rgb(out_rgb888)
    );

`ifndef SYNTHESIS
    integer sim_requests;
    integer sim_responses;

    always_ff @(posedge clk) begin
        if (rst) begin
            sim_requests <= 0;
            sim_responses <= 0;
        end else begin
            if (sample_req_valid && sample_req_ready)
                sim_requests <= sim_requests + 1;
            if (sample_rsp_valid && sample_rsp_ready)
                sim_responses <= sim_responses + 1;

            if (sample_rsp_valid && !sample_pending &&
                !(sample_req_valid && sample_req_ready))
                $fatal(1, "resize sample response arrived without a request");
            if (sample_pending && (sim_responses >= sim_requests))
                $fatal(1, "resize outstanding accounting underflow");
            if ((sim_requests - sim_responses) > 1)
                $fatal(1, "resize adapter exceeded one outstanding request");
            if (done && busy)
                $fatal(1, "resize done and busy asserted together");
        end
    end
`endif

endmodule
