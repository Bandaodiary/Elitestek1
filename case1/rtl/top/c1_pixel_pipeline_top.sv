// End-to-end portable pixel datapath used before the external-memory/DMA shell:
// unpacked RAW10 -> ISP -> deterministic diagnostic CNN.
`timescale 1ns/1ps

module c1_pixel_pipeline_top #(
    parameter integer INPUT_WIDTH   = 2560,
    parameter integer INPUT_HEIGHT  = 1440,
    parameter integer OUTPUT_WIDTH  = 640,
    parameter integer OUTPUT_HEIGHT = 480,
    parameter integer X_OFFSET      = 1,
    parameter integer Y_OFFSET      = 1,
    parameter integer H_STEP        = 4,
    parameter integer V_STEP        = 3,
    parameter integer IN_X_BITS     = (INPUT_WIDTH <= 1) ? 1 : $clog2(INPUT_WIDTH),
    parameter integer IN_Y_BITS     = (INPUT_HEIGHT <= 1) ? 1 : $clog2(INPUT_HEIGHT),
    parameter integer OUT_X_BITS    = (OUTPUT_WIDTH <= 1) ? 1 : $clog2(OUTPUT_WIDTH),
    parameter integer OUT_Y_BITS    = (OUTPUT_HEIGHT <= 1) ? 1 : $clog2(OUTPUT_HEIGHT)
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       in_valid,
    input  logic                       in_sof,
    input  logic                       in_eol,
    input  logic                       in_eof,
    input  logic [IN_X_BITS-1:0]       in_x,
    input  logic [IN_Y_BITS-1:0]       in_y,
    input  logic [9:0]                 in_raw10,
    input  logic                       isp_cfg_we,
    input  logic [7:0]                 isp_cfg_addr,
    input  logic [31:0]                isp_cfg_wdata,
    input  logic                       cnn_cfg_we,
    input  logic [7:0]                 cnn_cfg_addr,
    input  logic [31:0]                cnn_cfg_wdata,
    output logic                       out_valid,
    output logic                       out_sof,
    output logic                       out_eol,
    output logic                       out_eof,
    output logic [OUT_X_BITS-1:0]      out_x,
    output logic [OUT_Y_BITS-1:0]      out_y,
    output logic [23:0]                out_rgb
);
    logic isp_valid, isp_sof, isp_eol, isp_eof;
    logic [OUT_X_BITS-1:0] isp_x;
    logic [OUT_Y_BITS-1:0] isp_y;
    logic [23:0] isp_rgb;

    c1_isp_pipeline #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .OUTPUT_HEIGHT(OUTPUT_HEIGHT),
        .X_OFFSET(X_OFFSET), .Y_OFFSET(Y_OFFSET), .H_STEP(H_STEP), .V_STEP(V_STEP)
    ) u_isp (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_raw10, .cfg_we(isp_cfg_we), .cfg_addr(isp_cfg_addr),
        .cfg_wdata(isp_cfg_wdata), .out_valid(isp_valid), .out_sof(isp_sof),
        .out_eol(isp_eol), .out_eof(isp_eof), .out_x(isp_x), .out_y(isp_y),
        .out_rgb(isp_rgb)
    );

    c1_style_cnn3 #(
        .FRAME_WIDTH(OUTPUT_WIDTH), .FRAME_HEIGHT(OUTPUT_HEIGHT)
    ) u_diagnostic_cnn (
        .clk, .rst, .in_valid(isp_valid), .in_sof(isp_sof), .in_eol(isp_eol),
        .in_eof(isp_eof), .in_x(isp_x), .in_y(isp_y), .in_rgb(isp_rgb),
        .cfg_we(cnn_cfg_we), .cfg_addr(cnn_cfg_addr), .cfg_wdata(cnn_cfg_wdata),
        .out_valid, .out_sof, .out_eol, .out_eof, .out_x, .out_y, .out_rgb
    );
endmodule

