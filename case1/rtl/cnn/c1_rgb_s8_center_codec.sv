`timescale 1ns/1ps

// One-entry elastic RGB888 <-> centered-s8x3 codec.
//
// For each channel, u8->s8 is int16(u8)-128 and s8->u8 is
// int16(s8)+128.  In two's-complement both directions have the same packed
// representation: flip bit 7 of every byte.  Instantiate this module once at
// each network boundary; applying it twice restores the original RGB bytes.
module c1_rgb_s8_center_codec #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [23:0]           in_data,
    input  logic                  in_sof,
    input  logic                  in_eol,
    input  logic                  in_eof,
    input  logic [X_BITS-1:0]     in_x,
    input  logic [Y_BITS-1:0]     in_y,

    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [23:0]           out_data,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y
);

    assign in_ready = !out_valid || out_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_data <= '0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
        end else if (in_ready) begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_data <= in_data ^ 24'h80_80_80;
                out_sof <= in_sof;
                out_eol <= in_eol;
                out_eof <= in_eof;
                out_x <= in_x;
                out_y <= in_y;
            end
        end
    end

endmodule
