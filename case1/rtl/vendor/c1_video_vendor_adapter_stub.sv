`timescale 1ns/1ps

// Parallel-video vendor-boundary placeholder.
//
// Current behavior only forwards pixel clock, RGB, DE and sync.  It does NOT
// implement a PLL, TMDS encoding/serialization, I/O delay, or an HDMI PHY.
module c1_video_vendor_adapter_stub (
    input  wire        core_pixel_clk,
    input  wire [23:0] core_rgb,
    input  wire        core_de,
    input  wire        core_hsync,
    input  wire        core_vsync,

    output wire        vendor_pixel_clk,
    output wire [23:0] vendor_rgb,
    output wire        vendor_de,
    output wire        vendor_hsync,
    output wire        vendor_vsync
);

    assign vendor_pixel_clk = core_pixel_clk;
    assign vendor_rgb       = core_rgb;
    assign vendor_de        = core_de;
    assign vendor_hsync     = core_hsync;
    assign vendor_vsync     = core_vsync;

endmodule
