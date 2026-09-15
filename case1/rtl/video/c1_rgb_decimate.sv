// Streaming integer-ratio nearest-neighbour decimator. For SC431 2560x1440
// use X/Y offset 1 and steps 4/3; the valid demosaic centres then yield exactly
// 640x480 pixels without a frame-sized buffer.
//
// Selection and output coordinates use phase counters rather than '%' or '/'.
// H_STEP and V_STEP are elaboration constants, and the datapath accepts one
// valid input sample each clock. The stream contract requires monotonically
// increasing raster coordinates and one valid-crop sample for every interior
// x position of each interior row.
`timescale 1ns/1ps

module c1_rgb_decimate #(
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
    input  logic [IN_X_BITS-1:0]       in_x,
    input  logic [IN_Y_BITS-1:0]       in_y,
    input  logic [23:0]                in_rgb,
    output logic                       out_valid,
    output logic                       out_sof,
    output logic                       out_eol,
    output logic                       out_eof,
    output logic [OUT_X_BITS-1:0]      out_x,
    output logic [OUT_Y_BITS-1:0]      out_y,
    output logic [23:0]                out_rgb
);
    localparam integer H_PHASE_BITS = (H_STEP <= 1) ? 1 : $clog2(H_STEP);
    localparam integer V_PHASE_BITS = (V_STEP <= 1) ? 1 : $clog2(V_STEP);

    logic [H_PHASE_BITS-1:0] h_phase;
    logic [V_PHASE_BITS-1:0] v_phase;
    logic row_selected;
    logic [OUT_X_BITS-1:0] output_x_count;
    logic [OUT_Y_BITS-1:0] output_y_count;

    logic first_crop_column;
    logic first_crop_row;
    logic row_select_now;
    logic column_select_now;
    logic selected_now;
    logic [OUT_X_BITS-1:0] selected_x_now;
    logic [OUT_Y_BITS-1:0] selected_y_now;

    always_comb begin
        first_crop_column = (in_x == X_OFFSET);
        first_crop_row = (in_y == Y_OFFSET);

        if (first_crop_column) begin
            row_select_now = first_crop_row || (v_phase == V_STEP-1);
            column_select_now = 1'b1;
            selected_x_now = '0;
            selected_y_now = first_crop_row ? '0 :
                               (row_select_now ? output_y_count + 1'b1 :
                                                 output_y_count);
        end else begin
            row_select_now = row_selected;
            column_select_now = (h_phase == H_STEP-1);
            selected_x_now = column_select_now ? output_x_count + 1'b1 :
                                                 output_x_count;
            selected_y_now = output_y_count;
        end

        selected_now = in_valid && (in_x >= X_OFFSET) && (in_y >= Y_OFFSET) &&
                       row_select_now && column_select_now &&
                       (selected_x_now < OUTPUT_WIDTH) &&
                       (selected_y_now < OUTPUT_HEIGHT);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            h_phase <= '0;
            v_phase <= '0;
            row_selected <= 1'b0;
            output_x_count <= '0;
            output_y_count <= '0;
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            out_valid <= selected_now;
            out_sof <= selected_now && (selected_x_now == 0) &&
                       (selected_y_now == 0);
            out_eol <= selected_now && (selected_x_now == OUTPUT_WIDTH-1);
            out_eof <= selected_now && (selected_x_now == OUTPUT_WIDTH-1) &&
                       (selected_y_now == OUTPUT_HEIGHT-1);
            if (selected_now) begin
                out_x <= selected_x_now;
                out_y <= selected_y_now;
                out_rgb <= in_rgb;
            end

            if (in_valid) begin
                if (first_crop_column) begin
                    h_phase <= '0;
                    row_selected <= row_select_now;
                    output_x_count <= '0;
                    if (first_crop_row) begin
                        v_phase <= '0;
                        output_y_count <= '0;
                    end else begin
                        if (v_phase == V_STEP-1)
                            v_phase <= '0;
                        else
                            v_phase <= v_phase + 1'b1;
                        if (row_select_now)
                            output_y_count <= output_y_count + 1'b1;
                    end
                end else begin
                    if (h_phase == H_STEP-1)
                        h_phase <= '0;
                    else
                        h_phase <= h_phase + 1'b1;
                    if (row_select_now && column_select_now)
                        output_x_count <= output_x_count + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((H_STEP < 1) || (V_STEP < 1))
            $fatal(1, "c1_rgb_decimate steps must be positive");
        if (X_OFFSET + (OUTPUT_WIDTH-1)*H_STEP > INPUT_WIDTH-2)
            $fatal(1, "c1_rgb_decimate horizontal geometry exceeds valid crop");
        if (Y_OFFSET + (OUTPUT_HEIGHT-1)*V_STEP > INPUT_HEIGHT-2)
            $fatal(1, "c1_rgb_decimate vertical geometry exceeds valid crop");
    end
`endif
endmodule
