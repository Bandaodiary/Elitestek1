`timescale 1ns/1ps

// Board-independent streaming ingress from RGB888 through Resize into one
// NHWC-C8 signed-int8 beat per output pixel.
//
// Lane packing is little-lane-first within out_c8:
//   out_c8[ 7: 0] lane0 = signed8(R) - 128
//   out_c8[15: 8] lane1 = signed8(G) - 128
//   out_c8[23:16] lane2 = signed8(B) - 128
//   out_c8[63:24] lanes3..7 = 0
// c1_rgb_s8_center_codec performs the exact u8-to-centered-s8 bit transform.
//
// cfg_valid/cfg_ready and strict-raster input semantics are inherited from
// c1_r1_resize_pipeline.  busy remains asserted beyond the Resize RGB-domain
// completion until the final C8 beat (out_valid/out_ready/out_eof) is consumed.
// No new configuration can be accepted while the codec holds that final beat.
//
// A runtime Resize error freezes input and C8 output until abort or rst.
// abort is the same synchronous destructive flush as Resize and additionally
// resets the codec.  aborted refers to the complete ingress job, including a
// job whose Resize part has completed but whose final C8 beat is still pending.
// After abort, the next source frame must restart at coordinate (0,0).
module c1_r1_compute_ingress #(
    parameter integer MAX_WIDTH = 2048,
    // Optional registered abort/reset boundary inside the Resize child.  The
    // ingress interface itself still fences raw abort combinationally.
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
    output logic [63:0]             out_c8,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [15:0]             out_x,
    output logic [15:0]             out_y
);

    logic ingress_active;
    logic config_contract_valid;
    logic resize_cfg_valid;
    logic resize_cfg_ready;
    logic resize_cfg_error;
    logic resize_aborted_unused;
    logic resize_busy;
    logic resize_done_unused;
    logic resize_error;
    logic [3:0] resize_error_code;

    logic resize_rgb_valid;
    logic resize_rgb_ready;
    logic resize_rgb_sof;
    logic resize_rgb_eol;
    logic resize_rgb_eof;
    logic [15:0] resize_rgb_x;
    logic [15:0] resize_rgb_y;
    logic [23:0] resize_rgb888;

    logic codec_rst;
    logic codec_valid;
    logic codec_ready;
    logic [23:0] codec_data;
    logic codec_sof;
    logic codec_eol;
    logic codec_eof;
    logic [15:0] codec_x;
    logic [15:0] codec_y;
    logic final_c8_handshake;

    always_comb begin
        config_contract_valid = (cfg_win != 16'd0) &&
                                (cfg_hin != 16'd0) &&
                                (cfg_wout != 16'd0) &&
                                (cfg_hout != 16'd0) &&
                                (cfg_win <= MAX_WIDTH) &&
                                !cfg_y_step_q16[31];

        cfg_ready = !rst && !abort && !ingress_active && resize_cfg_ready;
        resize_cfg_valid = cfg_valid && !ingress_active;
        cfg_error = resize_cfg_error;
        busy = ingress_active;
        error = resize_error;
        error_code = resize_error_code;

        codec_rst = rst || abort;
        codec_ready = !rst && !abort && !resize_error && out_ready;
        out_valid = !rst && !abort && !resize_error && codec_valid;
        out_c8 = {40'd0,
                  codec_data[7:0],
                  codec_data[15:8],
                  codec_data[23:16]};
        out_sof = codec_sof;
        out_eol = codec_eol;
        out_eof = codec_eof;
        out_x = codec_x;
        out_y = codec_y;
        final_c8_handshake = codec_valid && codec_ready && codec_eof;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ingress_active <= 1'b0;
            aborted <= 1'b0;
            done <= 1'b0;
        end else begin
            aborted <= 1'b0;
            done <= 1'b0;
            if (abort) begin
                aborted <= ingress_active;
                ingress_active <= 1'b0;
            end else begin
                if (cfg_valid && cfg_ready && config_contract_valid)
                    ingress_active <= 1'b1;
                if (final_c8_handshake) begin
                    ingress_active <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

    c1_r1_resize_pipeline #(
        .MAX_WIDTH(MAX_WIDTH),
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET)
    ) u_resize_pipeline (
        .clk,
        .rst,
        .cfg_valid(resize_cfg_valid),
        .cfg_ready(resize_cfg_ready),
        .cfg_error(resize_cfg_error),
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .abort,
        .aborted(resize_aborted_unused),
        .busy(resize_busy),
        .done(resize_done_unused),
        .error(resize_error),
        .error_code(resize_error_code),
        .in_valid,
        .in_ready,
        .in_x,
        .in_y,
        .in_sof,
        .in_eol,
        .in_eof,
        .in_rgb888,
        .out_valid(resize_rgb_valid),
        .out_ready(resize_rgb_ready),
        .out_sof(resize_rgb_sof),
        .out_eol(resize_rgb_eol),
        .out_eof(resize_rgb_eof),
        .out_x(resize_rgb_x),
        .out_y(resize_rgb_y),
        .out_rgb888(resize_rgb888)
    );

    c1_rgb_s8_center_codec #(
        .X_BITS(16),
        .Y_BITS(16)
    ) u_center_codec (
        .clk,
        .rst(codec_rst),
        .in_valid(resize_rgb_valid),
        .in_ready(resize_rgb_ready),
        .in_data(resize_rgb888),
        .in_sof(resize_rgb_sof),
        .in_eol(resize_rgb_eol),
        .in_eof(resize_rgb_eof),
        .in_x(resize_rgb_x),
        .in_y(resize_rgb_y),
        .out_valid(codec_valid),
        .out_ready(codec_ready),
        .out_data(codec_data),
        .out_sof(codec_sof),
        .out_eol(codec_eol),
        .out_eof(codec_eof),
        .out_x(codec_x),
        .out_y(codec_y)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (done && busy)
                $fatal(1, "compute ingress done overlapped busy");
            if (resize_done_unused && !ingress_active)
                $fatal(1, "Resize completed outside an ingress job");
            if (final_c8_handshake && !ingress_active)
                $fatal(1, "final C8 handshake occurred outside an ingress job");
            if (out_valid && (out_c8[63:24] != 40'd0))
                $fatal(1, "compute ingress padding lanes are non-zero");
            if (ingress_active && !resize_busy && !codec_valid &&
                !resize_done_unused)
                $fatal(1, "ingress active without Resize or codec work");
        end
    end
`endif

endmodule
