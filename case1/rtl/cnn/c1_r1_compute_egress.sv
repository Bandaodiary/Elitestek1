`timescale 1ns/1ps

// Board-independent R1 NHWC-C8 compute egress.
//
// The upstream final layer has already performed requantization and hard-tanh
// into signed INT8.  Packed lane 0 is R, lane 1 is G and lane 2 is B; lane 0
// occupies bits [7:0].  This wrapper reorders those three lanes into RGB byte
// order and delegates the exact centered-s8 -> u8 mapping to the existing
// c1_rgb_s8_center_codec (equivalent to adding 128 without saturation).
// Lanes 3..7 never affect output data.
//
// A start_valid/start_ready handshake opens exactly one frame.  done pulses
// only when an output beat carrying EOF is accepted.  Once input EOF is
// accepted, further input is back-pressured until that output EOF retires.
// abort synchronously discards any held codec beat and returns to restartable
// idle without done.
module c1_r1_compute_egress #(
    parameter integer X_BITS = 16,
    parameter integer Y_BITS = 16,
    parameter bit ENABLE_PADDING_DIAGNOSTIC = 1'b1
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    abort,

    input  logic                    start_valid,
    output logic                    start_ready,
    output logic                    busy,
    output logic                    done,

    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic [63:0]             in_data_s8,
    input  logic [X_BITS-1:0]       in_x,
    input  logic [Y_BITS-1:0]       in_y,
    input  logic                    in_sof,
    input  logic                    in_eol,
    input  logic                    in_eof,

    output logic                    out_valid,
    input  logic                    out_ready,
    output logic [23:0]             out_rgb888,
    output logic [X_BITS-1:0]       out_x,
    output logic [Y_BITS-1:0]       out_y,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,

    output logic                    padding_nonzero_pulse
);

    logic input_complete;
    logic codec_rst;
    logic codec_in_valid;
    logic codec_in_ready;
    logic [23:0] codec_in_data;
    logic codec_out_valid;
    logic codec_out_ready;
    logic [23:0] codec_out_data;
    logic codec_out_sof;
    logic codec_out_eol;
    logic codec_out_eof;
    logic [X_BITS-1:0] codec_out_x;
    logic [Y_BITS-1:0] codec_out_y;
    logic input_fire;
    logic output_fire;

    always_comb begin
        codec_rst = rst || abort;

        start_ready = !rst && !abort && !busy && !codec_out_valid;

        codec_in_valid = in_valid && busy && !input_complete && !abort;
        in_ready = busy && !input_complete && !abort && codec_in_ready;
        input_fire = in_valid && in_ready;

        // Codec byte [23:16] becomes RGB R, [15:8] G and [7:0] B.
        codec_in_data = {in_data_s8[7:0],
                         in_data_s8[15:8],
                         in_data_s8[23:16]};

        out_valid = codec_out_valid && busy && !abort;
        codec_out_ready = out_ready && busy && !abort;
        output_fire = out_valid && out_ready;
        out_rgb888 = codec_out_data;
        out_x = codec_out_x;
        out_y = codec_out_y;
        out_sof = codec_out_sof;
        out_eol = codec_out_eol;
        out_eof = codec_out_eof;
    end

    c1_rgb_s8_center_codec #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_center_codec (
        .clk(clk),
        .rst(codec_rst),
        .in_valid(codec_in_valid),
        .in_ready(codec_in_ready),
        .in_data(codec_in_data),
        .in_sof(in_sof),
        .in_eol(in_eol),
        .in_eof(in_eof),
        .in_x(in_x),
        .in_y(in_y),
        .out_valid(codec_out_valid),
        .out_ready(codec_out_ready),
        .out_data(codec_out_data),
        .out_sof(codec_out_sof),
        .out_eol(codec_out_eol),
        .out_eof(codec_out_eof),
        .out_x(codec_out_x),
        .out_y(codec_out_y)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            input_complete <= 1'b0;
            done <= 1'b0;
            padding_nonzero_pulse <= 1'b0;
        end else if (abort) begin
            busy <= 1'b0;
            input_complete <= 1'b0;
            done <= 1'b0;
            padding_nonzero_pulse <= 1'b0;
        end else begin
            done <= 1'b0;
            padding_nonzero_pulse <= 1'b0;

            if (start_valid && start_ready) begin
                busy <= 1'b1;
                input_complete <= 1'b0;
            end

            if (input_fire) begin
                if (in_eof)
                    input_complete <= 1'b1;
                if (ENABLE_PADDING_DIAGNOSTIC && (|in_data_s8[63:24]))
                    padding_nonzero_pulse <= 1'b1;
            end

            if (output_fire && codec_out_eof) begin
                busy <= 1'b0;
                input_complete <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule
