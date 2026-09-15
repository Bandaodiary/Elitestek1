`timescale 1ns/1ps

// R1 four-phase Bayer black-level correction.
//
// Project-wide Bayer pattern encoding:
//   2'b00 RGGB, 2'b01 BGGR, 2'b10 GRBG, 2'b11 GBRG.
// Canonical phase IDs are 0=R, 1=Gr, 2=Gb, 3=B.  roi_x/y_parity are XORed
// with the incoming coordinate parity as required after an odd ROI crop.  If
// in_x/in_y are already absolute sensor coordinates, drive both ROI parities
// low.  The selected black level is captured with each pixel.
//
// Two registered stages sustain one pixel per clock.  A pixel accepted on
// edge N appears at the output on edge N+1.
module r1_blc_bayer4_u10 #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   in_valid,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,
    input  logic [9:0]             in_raw_u10,

    input  logic [1:0]             cfg_bayer_pattern,
    input  logic                   cfg_roi_x_parity,
    input  logic                   cfg_roi_y_parity,
    input  logic [9:0]             cfg_black_r,
    input  logic [9:0]             cfg_black_gr,
    input  logic [9:0]             cfg_black_gb,
    input  logic [9:0]             cfg_black_b,

    output logic                   out_valid,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic [1:0]             out_phase,
    output logic [9:0]             out_raw_u10
);

    logic [1:0] phase_comb;
    logic       r_row_parity_comb;
    logic       r_column_parity_comb;
    logic [9:0] selected_black_comb;

    logic signed [10:0] difference_pipe;
    logic [1:0]             phase_pipe;
    logic                   difference_valid;
    logic                   difference_sof;
    logic                   difference_eol;
    logic                   difference_eof;
    logic [X_BITS-1:0]      difference_x;
    logic [Y_BITS-1:0]      difference_y;

    always_comb begin
        // Convert the public enum into the R location of the physical tile,
        // then normalize the ROI-local coordinate to canonical RGGB phase.
        case (cfg_bayer_pattern)
            2'b00: begin // RGGB
                r_row_parity_comb    = 1'b0;
                r_column_parity_comb = 1'b0;
            end
            2'b01: begin // BGGR
                r_row_parity_comb    = 1'b1;
                r_column_parity_comb = 1'b1;
            end
            2'b10: begin // GRBG
                r_row_parity_comb    = 1'b0;
                r_column_parity_comb = 1'b1;
            end
            default: begin // GBRG
                r_row_parity_comb    = 1'b1;
                r_column_parity_comb = 1'b0;
            end
        endcase
        phase_comb[1] = in_y[0] ^ cfg_roi_y_parity ^ r_row_parity_comb;
        phase_comb[0] = in_x[0] ^ cfg_roi_x_parity ^ r_column_parity_comb;
        case (phase_comb)
            2'd0: selected_black_comb = cfg_black_r;
            2'd1: selected_black_comb = cfg_black_gr;
            2'd2: selected_black_comb = cfg_black_gb;
            default: selected_black_comb = cfg_black_b;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            difference_pipe  <= '0;
            phase_pipe       <= 2'd0;
            difference_valid <= 1'b0;
            difference_sof   <= 1'b0;
            difference_eol   <= 1'b0;
            difference_eof   <= 1'b0;
            difference_x     <= '0;
            difference_y     <= '0;

            out_valid        <= 1'b0;
            out_sof          <= 1'b0;
            out_eol          <= 1'b0;
            out_eof          <= 1'b0;
            out_x            <= '0;
            out_y            <= '0;
            out_phase        <= 2'd0;
            out_raw_u10      <= 10'd0;
        end else begin
            // Stage 0: phase/config selection and exact signed11 subtraction.
            difference_valid <= in_valid;
            difference_sof   <= in_valid && in_sof;
            difference_eol   <= in_valid && in_eol;
            difference_eof   <= in_valid && in_eof;
            if (in_valid) begin
                difference_pipe <= $signed({1'b0, in_raw_u10}) -
                                   $signed({1'b0, selected_black_comb});
                phase_pipe      <= phase_comb;
                difference_x    <= in_x;
                difference_y    <= in_y;
            end

            // Stage 1: clamp the signed difference to the u10 sensor domain.
            out_valid <= difference_valid;
            out_sof   <= difference_valid && difference_sof;
            out_eol   <= difference_valid && difference_eol;
            out_eof   <= difference_valid && difference_eof;
            if (difference_valid) begin
                if (difference_pipe < 0)
                    out_raw_u10 <= 10'd0;
                else if (difference_pipe > 11'sd1023)
                    out_raw_u10 <= 10'd1023;
                else
                    out_raw_u10 <= difference_pipe[9:0];
                out_phase <= phase_pipe;
                out_x     <= difference_x;
                out_y     <= difference_y;
            end
        end
    end

endmodule
