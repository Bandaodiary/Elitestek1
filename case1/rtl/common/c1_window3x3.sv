// Portable three-row streaming window generator.
//
// The input is a rectangular valid stream with absolute frame coordinates.
// X_MIN/Y_MIN and X_MAX/Y_MAX describe that rectangle.  This lets a second
// valid convolution consume the cropped output of a first convolution while
// retaining absolute pixel coordinates.
//
// Window packing:
//   out_window[(row*3+col)*PIXEL_BITS +: PIXEL_BITS]
// is p[row][col], top-left first.  Only complete windows are emitted, so the
// output rectangle is reduced by one pixel on every side.

`timescale 1ns/1ps

module c1_window3x3 #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer PIXEL_BITS   = 24,
    parameter integer X_MIN        = 0,
    parameter integer X_MAX        = FRAME_WIDTH-1,
    parameter integer Y_MIN        = 0,
    parameter integer Y_MAX        = FRAME_HEIGHT-1,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
    parameter integer ACTIVE_WIDTH = X_MAX-X_MIN+1
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        in_valid,
    input  logic                        in_sof,
    input  logic                        in_eol,
    input  logic                        in_eof,
    input  logic [X_BITS-1:0]           in_x,
    input  logic [Y_BITS-1:0]           in_y,
    input  logic [PIXEL_BITS-1:0]       in_pixel,
    output logic                        out_valid,
    output logic                        out_sof,
    output logic                        out_eol,
    output logic                        out_eof,
    output logic [X_BITS-1:0]           out_x,
    output logic [Y_BITS-1:0]           out_y,
    output logic [9*PIXEL_BITS-1:0]     out_window
);

    logic cur_bank;
    logic effective_bank;
    logic [X_BITS-1:0] relative_x;
    logic row0_write_en;
    logic row1_write_en;
    logic [PIXEL_BITS-1:0] row0_read;
    logic [PIXEL_BITS-1:0] row1_read;
    logic delayed_valid;
    logic delayed_eof;
    logic [X_BITS-1:0] delayed_x;
    logic [Y_BITS-1:0] delayed_y;
    logic [PIXEL_BITS-1:0] delayed_pixel;
    logic delayed_bank;
    logic delayed_line_start;
    logic delayed_line_end;
    logic delayed_complete_window;
    logic [PIXEL_BITS-1:0] top_at_x;
    logic [PIXEL_BITS-1:0] middle_at_x;
    logic [PIXEL_BITS-1:0] top_d1, top_d0;
    logic [PIXEL_BITS-1:0] middle_d1, middle_d0;
    logic [PIXEL_BITS-1:0] bottom_d1, bottom_d0;
    logic line_start;
    logic line_end;
    logic complete_window;

    always_comb begin
        relative_x = in_x - X_MIN;
        effective_bank = in_sof ? 1'b0 : cur_bank;
        line_start = in_sof || (in_x == X_MIN);
        line_end = in_eol || (in_x == X_MAX);
        complete_window = in_valid &&
                          (in_x >= X_MIN+2) && (in_x <= X_MAX) &&
                          (in_y >= Y_MIN+2) && (in_y <= Y_MAX);

        top_at_x = '0;
        middle_at_x = '0;
        if (delayed_valid) begin
            if (!delayed_bank) begin
                top_at_x = row0_read;
                middle_at_x = row1_read;
            end else begin
                top_at_x = row1_read;
                middle_at_x = row0_read;
            end
        end
    end

    always_comb begin
        row0_write_en = in_valid && !effective_bank &&
                        (in_x >= X_MIN) && (in_x <= X_MAX);
        row1_write_en = in_valid && effective_bank &&
                        (in_x >= X_MIN) && (in_x <= X_MAX);
    end

    c1_ram_sdp_read_first #(
        .DATA_WIDTH(PIXEL_BITS), .DEPTH(ACTIVE_WIDTH),
        .ADDR_WIDTH((ACTIVE_WIDTH <= 1) ? 1 : $clog2(ACTIVE_WIDTH))
    ) u_row0 (
        .clk, .rd_en(in_valid), .rd_addr(relative_x), .rd_data(row0_read),
        .wr_en(row0_write_en), .wr_addr(relative_x), .wr_data(in_pixel)
    );

    c1_ram_sdp_read_first #(
        .DATA_WIDTH(PIXEL_BITS), .DEPTH(ACTIVE_WIDTH),
        .ADDR_WIDTH((ACTIVE_WIDTH <= 1) ? 1 : $clog2(ACTIVE_WIDTH))
    ) u_row1 (
        .clk, .rd_en(in_valid), .rd_addr(relative_x), .rd_data(row1_read),
        .wr_en(row1_write_en), .wr_addr(relative_x), .wr_data(in_pixel)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            cur_bank <= 1'b0;
            delayed_valid <= 1'b0;
            delayed_eof <= 1'b0;
            delayed_x <= '0;
            delayed_y <= '0;
            delayed_pixel <= '0;
            delayed_bank <= 1'b0;
            delayed_line_start <= 1'b0;
            delayed_line_end <= 1'b0;
            delayed_complete_window <= 1'b0;
            top_d1 <= '0;
            top_d0 <= '0;
            middle_d1 <= '0;
            middle_d0 <= '0;
            bottom_d1 <= '0;
            bottom_d0 <= '0;
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            out_window <= '0;
        end else begin
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;

            if (delayed_valid) begin
                if (delayed_complete_window) begin
                    out_valid <= 1'b1;
                    out_sof <= (delayed_x == X_MIN+2) && (delayed_y == Y_MIN+2);
                    out_eol <= delayed_line_end;
                    out_eof <= delayed_line_end &&
                               (delayed_eof || (delayed_y == Y_MAX));
                    out_x <= delayed_x - 1'b1;
                    out_y <= delayed_y - 1'b1;
                    out_window[0*PIXEL_BITS +: PIXEL_BITS] <= top_d1;
                    out_window[1*PIXEL_BITS +: PIXEL_BITS] <= top_d0;
                    out_window[2*PIXEL_BITS +: PIXEL_BITS] <= top_at_x;
                    out_window[3*PIXEL_BITS +: PIXEL_BITS] <= middle_d1;
                    out_window[4*PIXEL_BITS +: PIXEL_BITS] <= middle_d0;
                    out_window[5*PIXEL_BITS +: PIXEL_BITS] <= middle_at_x;
                    out_window[6*PIXEL_BITS +: PIXEL_BITS] <= bottom_d1;
                    out_window[7*PIXEL_BITS +: PIXEL_BITS] <= bottom_d0;
                    out_window[8*PIXEL_BITS +: PIXEL_BITS] <= delayed_pixel;
                end

                if (delayed_line_start) begin
                    top_d1 <= '0;
                    top_d0 <= top_at_x;
                    middle_d1 <= '0;
                    middle_d0 <= middle_at_x;
                    bottom_d1 <= '0;
                    bottom_d0 <= delayed_pixel;
                end else begin
                    top_d1 <= top_d0;
                    top_d0 <= top_at_x;
                    middle_d1 <= middle_d0;
                    middle_d0 <= middle_at_x;
                    bottom_d1 <= bottom_d0;
                    bottom_d0 <= delayed_pixel;
                end
            end

            delayed_valid <= in_valid;
            if (in_valid) begin
                delayed_eof <= in_eof;
                delayed_x <= in_x;
                delayed_y <= in_y;
                delayed_pixel <= in_pixel;
                delayed_bank <= effective_bank;
                delayed_line_start <= line_start;
                delayed_line_end <= line_end;
                delayed_complete_window <= complete_window;

                if (in_sof)
                    cur_bank <= line_end ? 1'b1 : 1'b0;
                else if (line_end)
                    cur_bank <= ~cur_bank;
            end else begin
                delayed_eof <= 1'b0;
                delayed_line_start <= 1'b0;
                delayed_line_end <= 1'b0;
                delayed_complete_window <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ACTIVE_WIDTH < 3)
            $fatal(1, "c1_window3x3 ACTIVE_WIDTH must be at least three");
        if ((X_MIN < 0) || (Y_MIN < 0) || (X_MAX >= FRAME_WIDTH) || (Y_MAX >= FRAME_HEIGHT))
            $fatal(1, "c1_window3x3 rectangle outside frame");
    end
`endif

endmodule
