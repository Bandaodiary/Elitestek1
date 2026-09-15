// RAW10 black-level subtraction.  The default level is zero for synthetic
// regression; board software programs the calibrated SC431 value at runtime.
`timescale 1ns/1ps

module c1_black_level_raw10 #(
    parameter integer FRAME_WIDTH  = 2560,
    parameter integer FRAME_HEIGHT = 1440,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  in_valid,
    input  logic                  in_sof,
    input  logic                  in_eol,
    input  logic                  in_eof,
    input  logic [X_BITS-1:0]     in_x,
    input  logic [Y_BITS-1:0]     in_y,
    input  logic [9:0]            in_raw10,
    input  logic                  cfg_we,
    input  logic [9:0]            cfg_black_level,
    output logic                  out_valid,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y,
    output logic [9:0]            out_raw10
);
    logic [9:0] black_level;
    logic [9:0] corrected;

    always_comb begin
        corrected = (in_raw10 > black_level) ? (in_raw10 - black_level) : 10'd0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            black_level <= 10'd0;
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            out_raw10 <= '0;
        end else begin
            if (cfg_we)
                black_level <= cfg_black_level;
            out_valid <= in_valid;
            out_sof <= in_valid && in_sof;
            out_eol <= in_valid && in_eol;
            out_eof <= in_valid && in_eof;
            if (in_valid) begin
                out_x <= in_x;
                out_y <= in_y;
                out_raw10 <= corrected;
            end
        end
    end
endmodule

