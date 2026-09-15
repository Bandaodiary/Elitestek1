// R1 four-pattern, ROI-phase-aware RAW10 bilinear Debayer.
//
// The input coordinates are the absolute coordinates within the configured
// ROI raster: SOF is (0,0), EOL is x=FRAME_WIDTH-1, and EOF is the lower-right
// sample.  crop_x/y_parity describe the ROI origin in the original sensor
// raster.  The output preserves the centre coordinate and contains only
// centres with a complete 3x3 CFA window, namely x=1..W-2, y=1..H-2.
//
// No Bayer edge replication is performed.  The shared c1_window3x3 block uses
// two vendor-independent line memories plus the current row and can accept one
// input pixel per clock.  Once a valid output row starts, this module emits one
// RGB10 pixel per clock.
//
// cfg_bayer_pattern encoding:
//   2'b00 = RGGB, 2'b01 = BGGR, 2'b10 = GRBG, 2'b11 = GBRG.
// Configuration is sampled at input SOF and is required to remain stable
// through that input frame.

`timescale 1ns/1ps

module c1_r1_debayer_bilinear #(
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

    input  logic [1:0]            cfg_bayer_pattern,
    input  logic                  cfg_crop_x_parity,
    input  logic                  cfg_crop_y_parity,

    output logic                  out_valid,
    output logic                  out_sof,
    output logic                  out_eol,
    output logic                  out_eof,
    output logic [X_BITS-1:0]     out_x,
    output logic [Y_BITS-1:0]     out_y,
    output logic [9:0]            out_r10,
    output logic [9:0]            out_g10,
    output logic [9:0]            out_b10
);

    localparam logic [1:0] CFA_R = 2'd0;
    localparam logic [1:0] CFA_G = 2'd1;
    localparam logic [1:0] CFA_B = 2'd2;

    logic                  w_valid;
    logic                  w_sof;
    logic                  w_eol;
    logic                  w_eof;
    logic [X_BITS-1:0]     w_x;
    logic [Y_BITS-1:0]     w_y;
    logic [89:0]           w;

    logic [9:0] p00, p01, p02;
    logic [9:0] p10, p11, p12;
    logic [9:0] p20, p21, p22;
    logic [11:0] cross_sum;
    logic [11:0] diagonal_sum;
    logic [10:0] horizontal_sum;
    logic [10:0] vertical_sum;
    logic [9:0] r10_next;
    logic [9:0] g10_next;
    logic [9:0] b10_next;

    logic [1:0] pending_pattern;
    logic       pending_crop_x_parity;
    logic       pending_crop_y_parity;
    logic [1:0] active_pattern;
    logic       active_crop_x_parity;
    logic       active_crop_y_parity;
    logic [1:0] selected_pattern;
    logic       selected_crop_x_parity;
    logic       selected_crop_y_parity;
    logic       sensor_row_parity;
    logic       sensor_column_parity;
    logic [1:0] centre_colour;
    logic [1:0] horizontal_colour;

    function automatic logic [1:0] cfa_colour(
        input logic [1:0] pattern,
        input logic       row_parity,
        input logic       column_parity
    );
        begin
            case (pattern)
                2'b00: begin // RGGB
                    if (!row_parity && !column_parity)
                        cfa_colour = CFA_R;
                    else if (row_parity && column_parity)
                        cfa_colour = CFA_B;
                    else
                        cfa_colour = CFA_G;
                end
                2'b01: begin // BGGR
                    if (!row_parity && !column_parity)
                        cfa_colour = CFA_B;
                    else if (row_parity && column_parity)
                        cfa_colour = CFA_R;
                    else
                        cfa_colour = CFA_G;
                end
                2'b10: begin // GRBG
                    if (!row_parity && column_parity)
                        cfa_colour = CFA_R;
                    else if (row_parity && !column_parity)
                        cfa_colour = CFA_B;
                    else
                        cfa_colour = CFA_G;
                end
                default: begin // GBRG
                    if (row_parity && !column_parity)
                        cfa_colour = CFA_R;
                    else if (!row_parity && column_parity)
                        cfa_colour = CFA_B;
                    else
                        cfa_colour = CFA_G;
                end
            endcase
        end
    endfunction

    c1_window3x3 #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .PIXEL_BITS(10),
        .X_MIN(0),
        .X_MAX(FRAME_WIDTH-1),
        .Y_MIN(0),
        .Y_MAX(FRAME_HEIGHT-1)
    ) u_window (
        .clk,
        .rst,
        .in_valid,
        .in_sof,
        .in_eol,
        .in_eof,
        .in_x,
        .in_y,
        .in_pixel(in_raw10),
        .out_valid(w_valid),
        .out_sof(w_sof),
        .out_eol(w_eol),
        .out_eof(w_eof),
        .out_x(w_x),
        .out_y(w_y),
        .out_window(w)
    );

    // At the first Debayer output of a frame, the pending configuration is
    // selected combinationally.  This avoids applying a newly arriving frame's
    // configuration to the final pipelined output of the preceding frame.
    always_comb begin
        selected_pattern       = active_pattern;
        selected_crop_x_parity = active_crop_x_parity;
        selected_crop_y_parity = active_crop_y_parity;
        if (w_sof) begin
            selected_pattern       = pending_pattern;
            selected_crop_x_parity = pending_crop_x_parity;
            selected_crop_y_parity = pending_crop_y_parity;
        end
    end

    always_comb begin
        p00 = w[0*10 +: 10];
        p01 = w[1*10 +: 10];
        p02 = w[2*10 +: 10];
        p10 = w[3*10 +: 10];
        p11 = w[4*10 +: 10];
        p12 = w[5*10 +: 10];
        p20 = w[6*10 +: 10];
        p21 = w[7*10 +: 10];
        p22 = w[8*10 +: 10];

        cross_sum = {2'b00, p01} + {2'b00, p10} +
                    {2'b00, p12} + {2'b00, p21};
        diagonal_sum = {2'b00, p00} + {2'b00, p02} +
                       {2'b00, p20} + {2'b00, p22};
        horizontal_sum = {1'b0, p10} + {1'b0, p12};
        vertical_sum = {1'b0, p01} + {1'b0, p21};

        sensor_row_parity = w_y[0] ^ selected_crop_y_parity;
        sensor_column_parity = w_x[0] ^ selected_crop_x_parity;
        centre_colour = cfa_colour(
            selected_pattern, sensor_row_parity, sensor_column_parity);
        horizontal_colour = cfa_colour(
            selected_pattern, sensor_row_parity, ~sensor_column_parity);

        r10_next = 10'd0;
        g10_next = 10'd0;
        b10_next = 10'd0;
        case (centre_colour)
            CFA_R: begin
                r10_next = p11;
                g10_next = (cross_sum + 12'd2) >> 2;       // avg4 half-up
                b10_next = (diagonal_sum + 12'd2) >> 2;    // avg4 half-up
            end
            CFA_B: begin
                r10_next = (diagonal_sum + 12'd2) >> 2;    // avg4 half-up
                g10_next = (cross_sum + 12'd2) >> 2;       // avg4 half-up
                b10_next = p11;
            end
            default: begin
                g10_next = p11;
                if (horizontal_colour == CFA_R) begin
                    r10_next = (horizontal_sum + 11'd1) >> 1; // avg2 half-up
                    b10_next = (vertical_sum + 11'd1) >> 1;   // avg2 half-up
                end else begin
                    r10_next = (vertical_sum + 11'd1) >> 1;   // avg2 half-up
                    b10_next = (horizontal_sum + 11'd1) >> 1; // avg2 half-up
                end
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_pattern       <= 2'b00;
            pending_crop_x_parity <= 1'b0;
            pending_crop_y_parity <= 1'b0;
            active_pattern        <= 2'b00;
            active_crop_x_parity  <= 1'b0;
            active_crop_y_parity  <= 1'b0;
            out_valid             <= 1'b0;
            out_sof               <= 1'b0;
            out_eol               <= 1'b0;
            out_eof               <= 1'b0;
            out_x                 <= '0;
            out_y                 <= '0;
            out_r10               <= 10'd0;
            out_g10               <= 10'd0;
            out_b10               <= 10'd0;
        end else begin
            if (in_valid && in_sof) begin
                pending_pattern       <= cfg_bayer_pattern;
                pending_crop_x_parity <= cfg_crop_x_parity;
                pending_crop_y_parity <= cfg_crop_y_parity;
            end
            if (w_valid && w_sof) begin
                active_pattern       <= pending_pattern;
                active_crop_x_parity <= pending_crop_x_parity;
                active_crop_y_parity <= pending_crop_y_parity;
            end

            out_valid <= w_valid;
            out_sof   <= w_valid && w_sof;
            out_eol   <= w_valid && w_eol;
            out_eof   <= w_valid && w_eof;
            if (w_valid) begin
                out_x   <= w_x;
                out_y   <= w_y;
                out_r10 <= r10_next;
                out_g10 <= g10_next;
                out_b10 <= b10_next;
            end
        end
    end

`ifndef SYNTHESIS
    logic       sim_in_frame;
    logic [1:0] sim_frame_pattern;
    logic       sim_frame_crop_x_parity;
    logic       sim_frame_crop_y_parity;

    initial begin
        if ((FRAME_WIDTH < 3) || (FRAME_HEIGHT < 3))
            $fatal(1, "c1_r1_debayer_bilinear requires at least a 3x3 frame");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sim_in_frame            <= 1'b0;
            sim_frame_pattern       <= 2'b00;
            sim_frame_crop_x_parity <= 1'b0;
            sim_frame_crop_y_parity <= 1'b0;
        end else if (in_valid) begin
            if (in_sof) begin
                sim_frame_pattern       <= cfg_bayer_pattern;
                sim_frame_crop_x_parity <= cfg_crop_x_parity;
                sim_frame_crop_y_parity <= cfg_crop_y_parity;
                sim_in_frame            <= !in_eof;
            end else if (sim_in_frame) begin
                if ((cfg_bayer_pattern !== sim_frame_pattern) ||
                    (cfg_crop_x_parity !== sim_frame_crop_x_parity) ||
                    (cfg_crop_y_parity !== sim_frame_crop_y_parity))
                    $fatal(1, "R1 Debayer configuration changed within a frame");
                if (in_eof)
                    sim_in_frame <= 1'b0;
            end
        end
    end
`endif

endmodule

