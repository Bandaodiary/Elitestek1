`timescale 1ns/1ps

// Board-independent R1 bilinear-resize coordinate/weight request generator.
//
// This block generates a row-major sequence of four clamped source
// coordinates and Q0.12 weights.  It does NOT contain a line cache, four-point
// sample fetcher, DDR reader, or a complete streaming resize engine.  Those
// layers must consume this ready/valid request stream and return the samples
// to r1_bilinear_interp_rgb888.
//
// start is accepted only while start_ready is high.  All dimensions, signed
// Q16.16 phase values and steps are atomically captured on that edge.  While
// req_valid && !req_ready, every request field remains stable.
// A 16-bit dimension needs at most 65534 increments. Signed 48-bit internal
// phases cover initial32 + index16 * step32 without wrapping, including the
// most negative step. Clamping therefore acts on the true coordinate rather
// than a wrapped signed32 value. The software Q16.16 ports remain unchanged.
module r1_resize_request_q16 (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start,
    output logic                    start_ready,
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
    output logic                    req_valid,
    input  logic                    req_ready,
    output logic                    req_last,
    output logic [15:0]             req_out_x,
    output logic [15:0]             req_out_y,
    output logic [15:0]             req_x0,
    output logic [15:0]             req_x1,
    output logic [15:0]             req_y0,
    output logic [15:0]             req_y1,
    output logic [12:0]             req_wx0,
    output logic [12:0]             req_wx1,
    output logic [12:0]             req_wy0,
    output logic [12:0]             req_wy1
);

    logic [15:0] win_q;
    logic [15:0] hin_q;
    logic [15:0] wout_q;
    logic [15:0] hout_q;
    logic signed [31:0] x_step_q;
    logic signed [31:0] y_step_q;
    logic signed [31:0] x_phase0_q;
    logic signed [31:0] y_phase0_q;
    logic signed [47:0] x_phase_q;
    logic signed [47:0] y_phase_q;
    logic [15:0] out_x_q;
    logic [15:0] out_y_q;

    logic signed [47:0] x_floor;
    logic signed [47:0] y_floor;
    logic [12:0] wx1_comb;
    logic [12:0] wy1_comb;

    function automatic logic [15:0] clamp_source_index (
        input logic signed [47:0] index,
        input logic [15:0]        limit
    );
        logic signed [47:0] limit_extended;
        begin
            limit_extended = $signed({32'd0, limit});
            if (limit == 0)
                clamp_source_index = 16'd0;
            else if (index < 0)
                clamp_source_index = 16'd0;
            else if (index >= limit_extended)
                clamp_source_index = limit - 16'd1;
            else
                clamp_source_index = index[15:0];
        end
    endfunction

    function automatic logic [12:0] fraction_to_weight1 (
        input logic [15:0] fraction
    );
        logic [16:0] rounded_fraction;
        logic [12:0] weight;
        begin
            rounded_fraction = {1'b0, fraction} + 17'd8;
            weight = rounded_fraction >> 4;
            if (weight > 13'd4096)
                fraction_to_weight1 = 13'd4096;
            else
                fraction_to_weight1 = weight;
        end
    endfunction

    always_comb begin
        start_ready = !busy;
        req_valid = busy;
        req_out_x = out_x_q;
        req_out_y = out_y_q;
        req_last = busy && (out_x_q == wout_q - 16'd1) &&
                   (out_y_q == hout_q - 16'd1);

        // Arithmetic right shift implements floor for signed Q16.16.
        x_floor = x_phase_q >>> 16;
        y_floor = y_phase_q >>> 16;
        wx1_comb = fraction_to_weight1(x_phase_q[15:0]);
        wy1_comb = fraction_to_weight1(y_phase_q[15:0]);

        req_x0 = clamp_source_index(x_floor, win_q);
        req_x1 = clamp_source_index(x_floor + 32'sd1, win_q);
        req_y0 = clamp_source_index(y_floor, hin_q);
        req_y1 = clamp_source_index(y_floor + 32'sd1, hin_q);
        req_wx1 = wx1_comb;
        req_wx0 = 13'd4096 - wx1_comb;
        req_wy1 = wy1_comb;
        req_wy0 = 13'd4096 - wy1_comb;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            win_q      <= 16'd0;
            hin_q      <= 16'd0;
            wout_q     <= 16'd0;
            hout_q     <= 16'd0;
            x_step_q   <= 32'sd0;
            y_step_q   <= 32'sd0;
            x_phase0_q <= 32'sd0;
            y_phase0_q <= 32'sd0;
            x_phase_q  <= 32'sd0;
            y_phase_q  <= 32'sd0;
            out_x_q    <= 16'd0;
            out_y_q    <= 16'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && start_ready) begin
                win_q      <= cfg_win;
                hin_q      <= cfg_hin;
                wout_q     <= cfg_wout;
                hout_q     <= cfg_hout;
                x_step_q   <= cfg_x_step_q16;
                y_step_q   <= cfg_y_step_q16;
                x_phase0_q <= cfg_x_phase0_q16;
                y_phase0_q <= cfg_y_phase0_q16;
                x_phase_q  <= cfg_x_phase0_q16;
                y_phase_q  <= cfg_y_phase0_q16;
                out_x_q    <= 16'd0;
                out_y_q    <= 16'd0;
                // Zero dimensions are rejected as an empty job.
                busy       <= (cfg_win != 0) && (cfg_hin != 0) &&
                              (cfg_wout != 0) && (cfg_hout != 0);
            end else if (busy && req_ready) begin
                if (req_last) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else if (out_x_q == wout_q - 16'd1) begin
                    out_x_q   <= 16'd0;
                    out_y_q   <= out_y_q + 16'd1;
                    x_phase_q <= x_phase0_q;
                    y_phase_q <= y_phase_q + y_step_q;
                end else begin
                    out_x_q   <= out_x_q + 16'd1;
                    x_phase_q <= x_phase_q + x_step_q;
                end
            end
        end
    end

endmodule
