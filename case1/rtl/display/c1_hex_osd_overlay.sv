`timescale 1ns/1ps

// Tiny vendor-independent hexadecimal status OSD.  Eight 8x10 cells render
// a 32-bit word with a seven-segment glyph, requiring no font ROM or CPU-side
// bitmap.  Segment pixels replace the incoming RGB value; all other pixels
// pass through unchanged.  The module is combinational so the caller can
// pipeline coordinates and video together at its preferred boundary.
module c1_hex_osd_overlay #(
    parameter integer ORIGIN_X = 8,
    parameter integer ORIGIN_Y = 8,
    parameter integer DIGITS = 8
) (
    input  logic [10:0] pixel_x,
    input  logic [9:0]  pixel_y,
    input  logic        enable,
    input  logic        alarm,
    input  logic [31:0] status_word,
    input  logic [23:0] in_rgb,
    output logic [23:0] out_rgb
);

    logic in_osd;
    logic [5:0] digit_index;
    logic [2:0] cell_x;
    logic [3:0] cell_y;
    logic [6:0] segments;
    logic [31:0] shifted_status;
    logic glyph_on;
    integer shift_amount;

    function automatic logic [6:0] decode_segments(input logic [3:0] value);
        begin
            // Bit order: a,b,c,d,e,f,g.
            case (value)
                4'h0: decode_segments = 7'b1111110;
                4'h1: decode_segments = 7'b0110000;
                4'h2: decode_segments = 7'b1101101;
                4'h3: decode_segments = 7'b1111001;
                4'h4: decode_segments = 7'b0110011;
                4'h5: decode_segments = 7'b1011011;
                4'h6: decode_segments = 7'b1011111;
                4'h7: decode_segments = 7'b1110000;
                4'h8: decode_segments = 7'b1111111;
                4'h9: decode_segments = 7'b1111011;
                4'ha: decode_segments = 7'b1110111;
                4'hb: decode_segments = 7'b0011111;
                4'hc: decode_segments = 7'b1001110;
                4'hd: decode_segments = 7'b0111101;
                4'he: decode_segments = 7'b1001111;
                default: decode_segments = 7'b1000111;
            endcase
        end
    endfunction

    always_comb begin
        in_osd = enable &&
                 (pixel_x >= ORIGIN_X) &&
                 (pixel_x < ORIGIN_X + DIGITS*8) &&
                 (pixel_y >= ORIGIN_Y) &&
                 (pixel_y < ORIGIN_Y + 10);
        digit_index = '0;
        cell_x = '0;
        cell_y = '0;
        shift_amount = 0;
        shifted_status = status_word;
        segments = 7'd0;
        glyph_on = 1'b0;
        if (in_osd) begin
            digit_index = (pixel_x - ORIGIN_X) >> 3;
            cell_x = (pixel_x - ORIGIN_X) & 3'b111;
            cell_y = pixel_y - ORIGIN_Y;
            shift_amount = (DIGITS - 1 - digit_index) * 4;
            shifted_status = status_word >> shift_amount;
            segments = decode_segments(shifted_status[3:0]);
            glyph_on =
                (segments[6] && (cell_y == 0) &&
                 (cell_x >= 1) && (cell_x <= 4)) ||
                (segments[5] && (cell_x == 5) &&
                 (cell_y >= 1) && (cell_y <= 4)) ||
                (segments[4] && (cell_x == 5) &&
                 (cell_y >= 5) && (cell_y <= 8)) ||
                (segments[3] && (cell_y == 9) &&
                 (cell_x >= 1) && (cell_x <= 4)) ||
                (segments[2] && (cell_x == 0) &&
                 (cell_y >= 5) && (cell_y <= 8)) ||
                (segments[1] && (cell_x == 0) &&
                 (cell_y >= 1) && (cell_y <= 4)) ||
                (segments[0] && (cell_y == 4) &&
                 (cell_x >= 1) && (cell_x <= 4));
        end

        if (glyph_on)
            out_rgb = alarm ? 24'hff3030 : 24'h30ff60;
        else
            out_rgb = in_rgb;
    end

`ifndef SYNTHESIS
    initial begin
        if ((DIGITS < 1) || (DIGITS > 8))
            $fatal(1, "c1_hex_osd_overlay DIGITS must be 1..8");
    end
`endif

endmodule
