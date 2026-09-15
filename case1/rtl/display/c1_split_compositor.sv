`timescale 1ns/1ps

// Fixed-layout case-1 original/styled/split compositor for a 1280x720 raster.
//
// Active image layout:
//   y = 120..599, x =   0..639  : original 640x480 image
//   y = 120..599, x = 640..1279 : styled   640x480 image
// All other active pixels and all blanking pixels are black.
// In single-image modes the selected 640x480 image is centered at x=320..959.
//
// Source timing contract:
//   * original_request/styled_request and their coordinates describe the
//     source read sampled at the current rising edge.
//   * original_rgb/styled_rgb must be the registered, one-clock response to
//     the preceding sampled request (the normal behavior of a synchronous
//     one-cycle framebuffer/BRAM read port).
//   * rgb/de/hsync/vsync are registered together one clock after that source
//     response becomes available.  The complete output raster is therefore
//     delayed uniformly; pulse widths and frame geometry are unchanged.
//
// A variable-latency DDR reader must prefetch into a deterministic line/FIFO
// buffer before this interface.  The video raster itself cannot be stalled.
module c1_split_compositor (
    input  wire        pixel_clk,
    input  wire        rst_n,

    input  wire [10:0] timing_x,
    input  wire [9:0]  timing_y,
    input  wire        timing_de,
    input  wire        timing_hsync,
    input  wire        timing_vsync,
    input  wire [1:0]  display_mode,

    output wire        original_request,
    output wire [9:0]  original_x,
    output wire [8:0]  original_y,
    input  wire [23:0] original_rgb,

    output wire        styled_request,
    output wire [9:0]  styled_x,
    output wire [8:0]  styled_y,
    input  wire [23:0] styled_rgb,

    output reg  [23:0] rgb,
    output reg         de,
    output reg         hsync,
    output reg         vsync
);

    localparam [1:0] SOURCE_NONE     = 2'd0;
    localparam [1:0] SOURCE_ORIGINAL = 2'd1;
    localparam [1:0] SOURCE_STYLED   = 2'd2;
    localparam [1:0] MODE_STYLED     = 2'd0;
    localparam [1:0] MODE_ORIGINAL   = 2'd1;
    localparam [1:0] MODE_SPLIT      = 2'd2;

    wire in_vertical_window;
    wire in_original_window;
    wire in_styled_window;
    wire in_center_window;

    reg [1:0] source_select_q;
    reg       de_q;
    reg       hsync_q;
    reg       vsync_q;

    assign in_vertical_window = timing_de &&
                                (timing_y >= 10'd120) &&
                                (timing_y <  10'd600);
    assign in_center_window = in_vertical_window &&
                              (timing_x >= 11'd320) &&
                              (timing_x <  11'd960);
    assign in_original_window =
        ((display_mode == MODE_SPLIT) && in_vertical_window &&
         (timing_x < 11'd640)) ||
        ((display_mode == MODE_ORIGINAL) && in_center_window);
    assign in_styled_window =
        ((display_mode == MODE_SPLIT) && in_vertical_window &&
         (timing_x >= 11'd640) && (timing_x < 11'd1280)) ||
        ((display_mode == MODE_STYLED) && in_center_window);

    assign original_request = in_original_window;
    assign original_x = in_original_window ?
        ((display_mode == MODE_SPLIT) ? timing_x[9:0] :
         (timing_x - 11'd320)) : 10'd0;
    assign original_y = in_original_window ? (timing_y - 10'd120) : 9'd0;

    assign styled_request = in_styled_window;
    assign styled_x = in_styled_window ?
        ((display_mode == MODE_SPLIT) ? (timing_x - 11'd640) :
         (timing_x - 11'd320)) : 10'd0;
    assign styled_y = in_styled_window ? (timing_y - 10'd120) : 9'd0;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            source_select_q <= SOURCE_NONE;
            de_q            <= 1'b0;
            hsync_q         <= 1'b0;
            vsync_q         <= 1'b0;
            rgb             <= 24'h000000;
            de              <= 1'b0;
            hsync           <= 1'b0;
            vsync           <= 1'b0;
        end else begin
            if (in_original_window)
                source_select_q <= SOURCE_ORIGINAL;
            else if (in_styled_window)
                source_select_q <= SOURCE_STYLED;
            else
                source_select_q <= SOURCE_NONE;

            de_q    <= timing_de;
            hsync_q <= timing_hsync;
            vsync_q <= timing_vsync;

            case (source_select_q)
                SOURCE_ORIGINAL: rgb <= original_rgb;
                SOURCE_STYLED:   rgb <= styled_rgb;
                default:         rgb <= 24'h000000;
            endcase
            de    <= de_q;
            hsync <= hsync_q;
            vsync <= vsync_q;
        end
    end

endmodule
