`timescale 1ns/1ps

// R1 signed-INT8 affine requantization primitive.
//
// Arithmetic contract:
//   product = signed32(acc) * signed18(mult), retained in signed51
//   q       = round-to-nearest-away-from-zero(product / 2**shift)
//   output  = sat_s8(q), followed optionally by ReLU
//
// Three registered stages (multiply, round, activate/saturate) sustain one
// sample per clock.  A sample accepted on edge N produces out_valid on N+2.
module c1_requant_s8 #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    in_valid,
    input  logic                    in_sof,
    input  logic                    in_eol,
    input  logic                    in_eof,
    input  logic [X_BITS-1:0]       in_x,
    input  logic [Y_BITS-1:0]       in_y,
    input  logic signed [31:0]      in_acc,
    input  logic signed [17:0]      in_mult,
    input  logic [5:0]              in_shift,
    input  logic [1:0]              in_activation,

    output logic                    out_valid,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [X_BITS-1:0]       out_x,
    output logic [Y_BITS-1:0]       out_y,
    output logic signed [7:0]       out_data
);

    localparam logic [1:0] ACT_NONE = 2'd0;
    localparam logic [1:0] ACT_RELU = 2'd1;

    // A 32x18 signed multiply has a 50-bit mathematical result.  Retaining
    // one additional sign/guard bit satisfies the R1 signed51 requirement.
    wire logic signed [49:0] product_full;
    assign product_full = $signed(in_acc) * $signed(in_mult);

    logic signed [50:0] product_pipe;
    logic [5:0]         product_shift;
    logic [1:0]         product_activation;
    logic               product_valid;
    logic               product_sof;
    logic               product_eol;
    logic               product_eof;
    logic [X_BITS-1:0]  product_x;
    logic [Y_BITS-1:0]  product_y;

    logic signed [51:0] rounded_pipe;
    logic [1:0]         rounded_activation;
    logic               rounded_valid;
    logic               rounded_sof;
    logic               rounded_eol;
    logic               rounded_eof;
    logic [X_BITS-1:0]  rounded_x;
    logic [Y_BITS-1:0]  rounded_y;

    // The extra sign bit makes abs(minimum signed51) representable.  Legal
    // shifts are 0..47, so the rounding bias also fits comfortably in 52 bits.
    function automatic logic signed [51:0] round_shift_away_s51 (
        input logic signed [50:0] value,
        input logic [5:0]         shift
    );
        logic signed [51:0] extended;
        logic        [51:0] magnitude;
        logic        [51:0] round_bias;
        logic        [51:0] rounded_magnitude;
        begin
            extended = {value[50], value};
            if (shift == 0) begin
                round_shift_away_s51 = extended;
            end else begin
                if (extended < 0)
                    magnitude = $unsigned(-extended);
                else
                    magnitude = $unsigned(extended);
                round_bias = 52'd1 << (shift - 6'd1);
                rounded_magnitude = (magnitude + round_bias) >> shift;
                if (extended < 0)
                    round_shift_away_s51 = -$signed(rounded_magnitude);
                else
                    round_shift_away_s51 = $signed(rounded_magnitude);
            end
        end
    endfunction

    function automatic logic signed [7:0] saturate_activate_s8 (
        input logic signed [51:0] value,
        input logic [1:0]         activation
    );
        logic signed [7:0] saturated;
        begin
            if (value > 52'sd127)
                saturated = 8'sh7f;
            else if (value < -52'sd128)
                saturated = 8'sh80;
            else
                saturated = value[7:0];

            if ((activation == ACT_RELU) && saturated[7])
                saturate_activate_s8 = 8'sd0;
            else
                saturate_activate_s8 = saturated;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            product_pipe       <= '0;
            product_shift      <= '0;
            product_activation <= ACT_NONE;
            product_valid      <= 1'b0;
            product_sof        <= 1'b0;
            product_eol        <= 1'b0;
            product_eof        <= 1'b0;
            product_x          <= '0;
            product_y          <= '0;

            rounded_pipe       <= '0;
            rounded_activation <= ACT_NONE;
            rounded_valid      <= 1'b0;
            rounded_sof        <= 1'b0;
            rounded_eol        <= 1'b0;
            rounded_eof        <= 1'b0;
            rounded_x          <= '0;
            rounded_y          <= '0;

            out_valid          <= 1'b0;
            out_sof            <= 1'b0;
            out_eol            <= 1'b0;
            out_eof            <= 1'b0;
            out_x              <= '0;
            out_y              <= '0;
            out_data           <= '0;
        end else begin
            // Stage 0: full-precision signed multiply and per-sample snapshot.
            product_valid <= in_valid;
            product_sof   <= in_valid && in_sof;
            product_eol   <= in_valid && in_eol;
            product_eof   <= in_valid && in_eof;
            if (in_valid) begin
                product_pipe       <= {product_full[49], product_full};
                product_shift      <= in_shift;
                product_activation <= in_activation;
                product_x          <= in_x;
                product_y          <= in_y;
            end

            // Stage 1: signed round-to-nearest, with ties away from zero.
            rounded_valid <= product_valid;
            rounded_sof   <= product_valid && product_sof;
            rounded_eol   <= product_valid && product_eol;
            rounded_eof   <= product_valid && product_eof;
            if (product_valid) begin
                rounded_pipe       <= round_shift_away_s51(product_pipe,
                                                           product_shift);
                rounded_activation <= product_activation;
                rounded_x          <= product_x;
                rounded_y          <= product_y;
            end

            // Stage 2: signed8 saturation, then the selected activation.
            out_valid <= rounded_valid;
            out_sof   <= rounded_valid && rounded_sof;
            out_eol   <= rounded_valid && rounded_eol;
            out_eof   <= rounded_valid && rounded_eof;
            if (rounded_valid) begin
                out_data <= saturate_activate_s8(rounded_pipe,
                                                 rounded_activation);
                out_x    <= rounded_x;
                out_y    <= rounded_y;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && in_valid) begin
            if (in_shift > 6'd47)
                $fatal(1, "c1_requant_s8 shift must be in 0..47");
            if ((in_activation != ACT_NONE) && (in_activation != ACT_RELU))
                $fatal(1, "c1_requant_s8 unsupported activation %0d", in_activation);
        end
    end
`endif

endmodule
