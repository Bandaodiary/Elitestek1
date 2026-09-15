// Board-independent preprocessing chain used before the CNN accelerator.
// The MIPI/CSI-2 shell supplies an already unpacked RAW10 sample stream.
`timescale 1ns/1ps

module c1_isp_pipeline #(
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
    input  logic                       cfg_we,
    input  logic [7:0]                 cfg_addr,
    input  logic [31:0]                cfg_wdata,
    output logic                       out_valid,
    output logic                       out_sof,
    output logic                       out_eol,
    output logic                       out_eof,
    output logic [OUT_X_BITS-1:0]      out_x,
    output logic [OUT_Y_BITS-1:0]      out_y,
    output logic [23:0]                out_rgb
);
    logic bl_valid, bl_sof, bl_eol, bl_eof;
    logic [IN_X_BITS-1:0] bl_x;
    logic [IN_Y_BITS-1:0] bl_y;
    logic [9:0] bl_raw;
    logic db_valid, db_sof, db_eol, db_eof;
    logic [IN_X_BITS-1:0] db_x;
    logic [IN_Y_BITS-1:0] db_y;
    logic [23:0] db_rgb;
    logic cc_valid, cc_sof, cc_eol, cc_eof;
    logic [IN_X_BITS-1:0] cc_x;
    logic [IN_Y_BITS-1:0] cc_y;
    logic [23:0] cc_rgb;
    logic gm_valid, gm_sof, gm_eol, gm_eof;
    logic [IN_X_BITS-1:0] gm_x;
    logic [IN_Y_BITS-1:0] gm_y;
    logic [23:0] gm_rgb;
    logic [5:0] cc_cfg_addr;
    logic [4:0] gamma_cfg_addr;

    always_comb begin
        cc_cfg_addr = cfg_addr[5:0] - 6'h10;
        gamma_cfg_addr = cfg_addr[4:0] - 5'h10;
    end

    c1_black_level_raw10 #(.FRAME_WIDTH(INPUT_WIDTH), .FRAME_HEIGHT(INPUT_HEIGHT)) u_bl (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_raw10, .cfg_we(cfg_we && (cfg_addr == 8'h00)),
        .cfg_black_level(cfg_wdata[9:0]), .out_valid(bl_valid), .out_sof(bl_sof),
        .out_eol(bl_eol), .out_eof(bl_eof), .out_x(bl_x), .out_y(bl_y),
        .out_raw10(bl_raw)
    );

    c1_debayer_rggb10_valid #(.FRAME_WIDTH(INPUT_WIDTH), .FRAME_HEIGHT(INPUT_HEIGHT)) u_db (
        .clk, .rst, .in_valid(bl_valid), .in_sof(bl_sof), .in_eol(bl_eol),
        .in_eof(bl_eof), .in_x(bl_x), .in_y(bl_y), .in_raw10(bl_raw),
        .out_valid(db_valid), .out_sof(db_sof), .out_eol(db_eol), .out_eof(db_eof),
        .out_x(db_x), .out_y(db_y), .out_rgb(db_rgb)
    );

    c1_color_correct #(.FRAME_WIDTH(INPUT_WIDTH), .FRAME_HEIGHT(INPUT_HEIGHT)) u_cc (
        .clk, .rst, .in_valid(db_valid), .in_sof(db_sof), .in_eol(db_eol),
        .in_eof(db_eof), .in_x(db_x), .in_y(db_y), .in_rgb(db_rgb),
        .cfg_we(cfg_we && (cfg_addr >= 8'h10) && (cfg_addr < 8'h40)),
        .cfg_addr(cc_cfg_addr), .cfg_wdata,
        .out_valid(cc_valid), .out_sof(cc_sof), .out_eol(cc_eol), .out_eof(cc_eof),
        .out_x(cc_x), .out_y(cc_y), .out_rgb(cc_rgb)
    );

    c1_gamma_lut16 #(.FRAME_WIDTH(INPUT_WIDTH), .FRAME_HEIGHT(INPUT_HEIGHT)) u_gamma (
        .clk, .rst, .in_valid(cc_valid), .in_sof(cc_sof), .in_eol(cc_eol),
        .in_eof(cc_eof), .in_x(cc_x), .in_y(cc_y), .in_rgb(cc_rgb),
        .cfg_we(cfg_we && (cfg_addr >= 8'h50) && (cfg_addr <= 8'h60)),
        .cfg_addr(gamma_cfg_addr), .cfg_wdata(cfg_wdata[8:0]),
        .out_valid(gm_valid), .out_sof(gm_sof), .out_eol(gm_eol), .out_eof(gm_eof),
        .out_x(gm_x), .out_y(gm_y), .out_rgb(gm_rgb)
    );

    c1_rgb_decimate #(
        .INPUT_WIDTH(INPUT_WIDTH), .INPUT_HEIGHT(INPUT_HEIGHT),
        .OUTPUT_WIDTH(OUTPUT_WIDTH), .OUTPUT_HEIGHT(OUTPUT_HEIGHT),
        .X_OFFSET(X_OFFSET), .Y_OFFSET(Y_OFFSET), .H_STEP(H_STEP), .V_STEP(V_STEP)
    ) u_resize (
        .clk, .rst, .in_valid(gm_valid), .in_x(gm_x), .in_y(gm_y), .in_rgb(gm_rgb),
        .out_valid, .out_sof, .out_eol, .out_eof, .out_x, .out_y, .out_rgb
    );
endmodule
