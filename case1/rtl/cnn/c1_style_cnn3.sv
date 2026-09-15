// Functional, fully streaming board-independent baseline network.
//
// This is the bit-exact RTL counterpart of tiny_style_infer() in the Python
// golden model.  It is intentionally small enough to validate the complete
// image/weight/control contract before the descriptor-driven MicroStyle-24
// accelerator is introduced.

`timescale 1ns/1ps

module c1_style_cnn3 #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   in_valid,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,
    input  logic [23:0]            in_rgb,
    input  logic                   cfg_we,
    input  logic [7:0]             cfg_addr,
    input  logic [31:0]            cfg_wdata,
    output logic                   out_valid,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic [23:0]            out_rgb
);

    logic w1_valid, w1_sof, w1_eol, w1_eof;
    logic [X_BITS-1:0] w1_x;
    logic [Y_BITS-1:0] w1_y;
    logic [9*24-1:0] w1_window;
    logic c1_valid, c1_sof, c1_eol, c1_eof;
    logic [X_BITS-1:0] c1_x;
    logic [Y_BITS-1:0] c1_y;
    logic [23:0] c1_rgb;
    logic w2_valid, w2_sof, w2_eol, w2_eof;
    logic [X_BITS-1:0] w2_x;
    logic [Y_BITS-1:0] w2_y;
    logic [9*24-1:0] w2_window;
    logic dw_valid, dw_sof, dw_eol, dw_eof;
    logic [X_BITS-1:0] dw_x;
    logic [Y_BITS-1:0] dw_y;
    logic [23:0] dw_rgb;

    logic conv_cfg_we;
    logic dw_cfg_we;
    logic pw_cfg_we;
    logic [6:0] conv_cfg_addr;
    logic [5:0] dw_cfg_addr;
    logic [3:0] pw_cfg_addr;

    always_comb begin
        conv_cfg_we = cfg_we && (cfg_addr <= 8'd84);
        conv_cfg_addr = cfg_addr[6:0];
        dw_cfg_we = cfg_we && (cfg_addr >= 8'd128) && (cfg_addr <= 8'd158);
        dw_cfg_addr = cfg_addr - 8'd128;
        pw_cfg_we = cfg_we && (cfg_addr >= 8'd192) && (cfg_addr <= 8'd204);
        pw_cfg_addr = cfg_addr - 8'd192;
    end

    c1_window3x3 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT), .PIXEL_BITS(24),
        .X_MIN(0), .X_MAX(FRAME_WIDTH-1), .Y_MIN(0), .Y_MAX(FRAME_HEIGHT-1)
    ) u_window1 (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_pixel(in_rgb), .out_valid(w1_valid), .out_sof(w1_sof),
        .out_eol(w1_eol), .out_eof(w1_eof), .out_x(w1_x), .out_y(w1_y),
        .out_window(w1_window)
    );

    c1_conv3x3_rgb3 #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)) u_conv1 (
        .clk, .rst, .in_valid(w1_valid), .in_sof(w1_sof), .in_eol(w1_eol),
        .in_eof(w1_eof), .in_x(w1_x), .in_y(w1_y), .in_window(w1_window),
        .cfg_we(conv_cfg_we), .cfg_addr(conv_cfg_addr), .cfg_wdata,
        .out_valid(c1_valid), .out_sof(c1_sof), .out_eol(c1_eol), .out_eof(c1_eof),
        .out_x(c1_x), .out_y(c1_y), .out_rgb(c1_rgb)
    );

    c1_window3x3 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT), .PIXEL_BITS(24),
        .X_MIN(1), .X_MAX(FRAME_WIDTH-2), .Y_MIN(1), .Y_MAX(FRAME_HEIGHT-2)
    ) u_window2 (
        .clk, .rst, .in_valid(c1_valid), .in_sof(c1_sof), .in_eol(c1_eol),
        .in_eof(c1_eof), .in_x(c1_x), .in_y(c1_y), .in_pixel(c1_rgb),
        .out_valid(w2_valid), .out_sof(w2_sof), .out_eol(w2_eol),
        .out_eof(w2_eof), .out_x(w2_x), .out_y(w2_y), .out_window(w2_window)
    );

    c1_dwconv3x3_rgb3 #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)) u_dw (
        .clk, .rst, .in_valid(w2_valid), .in_sof(w2_sof), .in_eol(w2_eol),
        .in_eof(w2_eof), .in_x(w2_x), .in_y(w2_y), .in_window(w2_window),
        .cfg_we(dw_cfg_we), .cfg_addr(dw_cfg_addr), .cfg_wdata,
        .out_valid(dw_valid), .out_sof(dw_sof), .out_eol(dw_eol), .out_eof(dw_eof),
        .out_x(dw_x), .out_y(dw_y), .out_rgb(dw_rgb)
    );

    c1_pwconv1x1_rgb3 #(.FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)) u_pw (
        .clk, .rst, .in_valid(dw_valid), .in_sof(dw_sof), .in_eol(dw_eol),
        .in_eof(dw_eof), .in_x(dw_x), .in_y(dw_y), .in_rgb(dw_rgb),
        .cfg_we(pw_cfg_we), .cfg_addr(pw_cfg_addr), .cfg_wdata,
        .out_valid, .out_sof, .out_eol, .out_eof, .out_x, .out_y, .out_rgb
    );

endmodule

