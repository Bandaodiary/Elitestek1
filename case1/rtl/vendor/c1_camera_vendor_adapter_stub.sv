`timescale 1ns/1ps

// Camera vendor-boundary placeholder.
//
// Current behavior is a transparent ready/valid pass-through.  It does NOT
// implement MIPI D-PHY, CSI-2 packet decoding, RAW packing, lane alignment, or
// clock-domain crossing.  Replace this module (or wrap it) at Efinix bring-up.
module c1_camera_vendor_adapter_stub #(
    parameter integer PIXEL_W = 16
) (
    input  wire                 vendor_pixel_clk,
    input  wire [PIXEL_W-1:0]   vendor_pixel_data,
    input  wire                 vendor_pixel_valid,
    input  wire                 vendor_pixel_sof,
    input  wire                 vendor_pixel_eol,
    input  wire                 vendor_pixel_eof,
    output wire                 vendor_pixel_ready,

    output wire                 core_pixel_clk,
    output wire [PIXEL_W-1:0]   core_pixel_data,
    output wire                 core_pixel_valid,
    output wire                 core_pixel_sof,
    output wire                 core_pixel_eol,
    output wire                 core_pixel_eof,
    input  wire                 core_pixel_ready
);

    assign core_pixel_clk     = vendor_pixel_clk;
    assign core_pixel_data    = vendor_pixel_data;
    assign core_pixel_valid   = vendor_pixel_valid;
    assign core_pixel_sof     = vendor_pixel_sof;
    assign core_pixel_eol     = vendor_pixel_eol;
    assign core_pixel_eof     = vendor_pixel_eof;
    assign vendor_pixel_ready = core_pixel_ready;

endmodule
