`timescale 1ns/1ps

// Vendor-independent CTA-style 1280x720p60 raster timing generator.
//
// A 74.25 MHz pixel clock produces 60 frames/s with the following totals:
//   horizontal: 1280 active + 110 front + 40 sync + 220 back = 1650
//   vertical:    720 active +   5 front +  5 sync +  20 back =  750
//
// HSYNC and VSYNC are active high, as used by the standard 720p60 mode.  The
// counters cover the complete raster, so pixel_x reaches 1649 and pixel_y
// reaches 749.  Consumers must qualify active coordinates with de.
module c1_video_timing_720p (
    input  wire        pixel_clk,
    input  wire        rst_n,

    output reg  [10:0] pixel_x,
    output reg  [9:0]  pixel_y,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire        line_start,
    output wire        frame_start
);

    localparam integer H_ACTIVE = 1280;
    localparam integer H_FRONT  = 110;
    localparam integer H_SYNC   = 40;
    localparam integer H_BACK   = 220;
    localparam integer H_TOTAL  = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;

    localparam integer V_ACTIVE = 720;
    localparam integer V_FRONT  = 5;
    localparam integer V_SYNC   = 5;
    localparam integer V_BACK   = 20;
    localparam integer V_TOTAL  = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 11'd0;
            pixel_y <= 10'd0;
        end else if (pixel_x == H_TOTAL - 1) begin
            pixel_x <= 11'd0;
            if (pixel_y == V_TOTAL - 1)
                pixel_y <= 10'd0;
            else
                pixel_y <= pixel_y + 10'd1;
        end else begin
            pixel_x <= pixel_x + 11'd1;
        end
    end

    assign de = rst_n &&
                (pixel_x < H_ACTIVE) &&
                (pixel_y < V_ACTIVE);

    assign hsync = rst_n &&
                   (pixel_x >= H_ACTIVE + H_FRONT) &&
                   (pixel_x <  H_ACTIVE + H_FRONT + H_SYNC);

    assign vsync = rst_n &&
                   (pixel_y >= V_ACTIVE + V_FRONT) &&
                   (pixel_y <  V_ACTIVE + V_FRONT + V_SYNC);

    assign line_start  = rst_n && (pixel_x == 0);
    assign frame_start = rst_n && (pixel_x == 0) && (pixel_y == 0);

endmodule
