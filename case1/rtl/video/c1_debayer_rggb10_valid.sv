// Integer bilinear RGGB demosaic.  Only pixels with a complete 3x3 window are
// emitted; the output rectangle is x=1..W-2, y=1..H-2.  This deliberate valid
// crop makes the streaming implementation bit-exact and vendor independent.
`timescale 1ns/1ps

module c1_debayer_rggb10_valid #(
    parameter integer FRAME_WIDTH  = 2560,
    parameter integer FRAME_HEIGHT = 1440,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  in_valid,
    input  logic                  in_sof,
    input  logic                  in_eol,
    input  logic                  in_eof,
    input  logic [X_BITS-1:0]     in_x,
    input  logic [Y_BITS-1:0]     in_y,
    input  logic [9:0]            in_raw10,
    output logic                  out_valid,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y,
    output logic [23:0]           out_rgb
);
    logic w_valid, w_sof, w_eol, w_eof;
    logic [X_BITS-1:0] w_x;
    logic [Y_BITS-1:0] w_y;
    logic [89:0] w;
    logic [9:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    logic [9:0] r10, g10, b10;
    logic [11:0] cross_sum;
    logic [11:0] diagonal_sum;
    logic [10:0] horizontal_sum;
    logic [10:0] vertical_sum;
    logic [7:0] r8, g8, b8;

    function automatic logic [7:0] raw10_to_u8(input logic [9:0] value);
        logic [10:0] rounded;
        begin
            rounded = {1'b0, value} + 11'd2;
            raw10_to_u8 = (rounded >= 11'd1024) ? 8'hff : rounded[9:2];
        end
    endfunction

    c1_window3x3 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT), .PIXEL_BITS(10),
        .X_MIN(0), .X_MAX(FRAME_WIDTH-1), .Y_MIN(0), .Y_MAX(FRAME_HEIGHT-1)
    ) u_window (
        .clk, .rst, .in_valid, .in_sof, .in_eol, .in_eof, .in_x, .in_y,
        .in_pixel(in_raw10), .out_valid(w_valid), .out_sof(w_sof),
        .out_eol(w_eol), .out_eof(w_eof), .out_x(w_x), .out_y(w_y),
        .out_window(w)
    );

    always_comb begin
        p00 = w[0*10 +: 10]; p01 = w[1*10 +: 10]; p02 = w[2*10 +: 10];
        p10 = w[3*10 +: 10]; p11 = w[4*10 +: 10]; p12 = w[5*10 +: 10];
        p20 = w[6*10 +: 10]; p21 = w[7*10 +: 10]; p22 = w[8*10 +: 10];
        cross_sum = {2'b0, p01} + {2'b0, p10} + {2'b0, p12} + {2'b0, p21};
        diagonal_sum = {2'b0, p00} + {2'b0, p02} + {2'b0, p20} + {2'b0, p22};
        horizontal_sum = {1'b0, p10} + {1'b0, p12};
        vertical_sum = {1'b0, p01} + {1'b0, p21};

        r10 = 10'd0;
        g10 = 10'd0;
        b10 = 10'd0;
        case ({w_y[0], w_x[0]})
            2'b00: begin // R site
                r10 = p11;
                g10 = (cross_sum + 12'd2) >> 2;
                b10 = (diagonal_sum + 12'd2) >> 2;
            end
            2'b01: begin // G site on R row
                r10 = (horizontal_sum + 11'd1) >> 1;
                g10 = p11;
                b10 = (vertical_sum + 11'd1) >> 1;
            end
            2'b10: begin // G site on B row
                r10 = (vertical_sum + 11'd1) >> 1;
                g10 = p11;
                b10 = (horizontal_sum + 11'd1) >> 1;
            end
            default: begin // B site
                r10 = (diagonal_sum + 12'd2) >> 2;
                g10 = (cross_sum + 12'd2) >> 2;
                b10 = p11;
            end
        endcase
        r8 = raw10_to_u8(r10);
        g8 = raw10_to_u8(g10);
        b8 = raw10_to_u8(b10);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            out_valid <= w_valid;
            out_sof <= w_valid && w_sof;
            out_eol <= w_valid && w_eol;
            out_eof <= w_valid && w_eof;
            if (w_valid) begin
                out_x <= w_x;
                out_y <= w_y;
                out_rgb <= {r8, g8, b8};
            end
        end
    end
endmodule

