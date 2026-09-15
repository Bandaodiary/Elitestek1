`timescale 1ns/1ps

// Eight-channel elastic R1 affine requantization bank.
//
// Channel 0 occupies the least-significant slice of every packed bus.  Each
// output channel independently applies signed32*signed18, a 0..47
// nearest/ties-away shift, signed8 saturation, and ACT_NONE or ACT_RELU.
//
// Timing-oriented elastic pipeline:
//   1. signed 32x18 product
//   2. sign/magnitude conversion
//   3. rounding-bias addition
//   4. variable shift and sign restore
//   5. signed8 saturation/activation
//
// The earlier baseline combined stages 2..4 and produced a 30-level carry /
// variable-shift path.  These cuts preserve the exact arithmetic while still
// sustaining one C8 vector per clock.  Input N reaches the output on N+4
// without stalls.  Every stage is elastic, so data and metadata remain stable
// under arbitrary downstream backpressure.
module c1_requant_bank8 #(
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [255:0]           in_acc_s32,
    input  logic [143:0]           in_mult_s18,
    input  logic [47:0]            in_shift_u6,
    input  logic [15:0]            in_activation,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [63:0]            out_data_s8,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y
);

    localparam logic [1:0] ACT_NONE = 2'd0;
    localparam logic [1:0] ACT_RELU = 2'd1;

    logic signed [50:0] product_pipe [0:7];
    logic [5:0] product_shift [0:7];
    logic [1:0] product_activation [0:7];
    logic product_valid;
    logic product_sof, product_eol, product_eof;
    logic [X_BITS-1:0] product_x;
    logic [Y_BITS-1:0] product_y;

    logic [51:0] magnitude_pipe [0:7];
    logic magnitude_negative [0:7];
    logic [5:0] magnitude_shift [0:7];
    logic [1:0] magnitude_activation [0:7];
    logic magnitude_valid;
    logic magnitude_sof, magnitude_eol, magnitude_eof;
    logic [X_BITS-1:0] magnitude_x;
    logic [Y_BITS-1:0] magnitude_y;

    logic [51:0] biased_pipe [0:7];
    logic biased_negative [0:7];
    logic [5:0] biased_shift [0:7];
    logic [1:0] biased_activation [0:7];
    logic biased_valid;
    logic biased_sof, biased_eol, biased_eof;
    logic [X_BITS-1:0] biased_x;
    logic [Y_BITS-1:0] biased_y;

    logic signed [51:0] rounded_pipe [0:7];
    logic [1:0] rounded_activation [0:7];
    logic rounded_valid;
    logic rounded_sof, rounded_eol, rounded_eof;
    logic [X_BITS-1:0] rounded_x;
    logic [Y_BITS-1:0] rounded_y;

    logic output_stage_ready;
    logic rounded_stage_ready;
    logic biased_stage_ready;
    logic magnitude_stage_ready;
    logic product_stage_ready;
    integer channel;

    function automatic logic [51:0] magnitude_s51(
        input logic signed [50:0] value
    );
        logic signed [51:0] extended;
        begin
            extended = {value[50], value};
            if (extended < 0)
                magnitude_s51 = $unsigned(-extended);
            else
                magnitude_s51 = $unsigned(extended);
        end
    endfunction

    function automatic logic [51:0] add_round_bias(
        input logic [51:0] magnitude,
        input logic [5:0] shift
    );
        logic [51:0] bias;
        begin
            if (shift == 0)
                add_round_bias = magnitude;
            else begin
                bias = 52'd1 << (shift - 1'b1);
                add_round_bias = magnitude + bias;
            end
        end
    endfunction

    function automatic logic signed [51:0] restore_shifted_sign(
        input logic [51:0] biased_magnitude,
        input logic [5:0] shift,
        input logic negative
    );
        logic [51:0] shifted_magnitude;
        begin
            shifted_magnitude = biased_magnitude >> shift;
            if (negative)
                restore_shifted_sign = -$signed(shifted_magnitude);
            else
                restore_shifted_sign = $signed(shifted_magnitude);
        end
    endfunction

    function automatic logic signed [7:0] saturate_activate_s8(
        input logic signed [51:0] value,
        input logic [1:0] activation
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

    always_comb begin
        output_stage_ready = !out_valid || out_ready;
        rounded_stage_ready = !rounded_valid || output_stage_ready;
        biased_stage_ready = !biased_valid || rounded_stage_ready;
        magnitude_stage_ready = !magnitude_valid || biased_stage_ready;
        product_stage_ready = !product_valid || magnitude_stage_ready;
        in_ready = product_stage_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            product_valid <= 1'b0;
            product_sof <= 1'b0;
            product_eol <= 1'b0;
            product_eof <= 1'b0;
            product_x <= '0;
            product_y <= '0;
            magnitude_valid <= 1'b0;
            magnitude_sof <= 1'b0;
            magnitude_eol <= 1'b0;
            magnitude_eof <= 1'b0;
            magnitude_x <= '0;
            magnitude_y <= '0;
            biased_valid <= 1'b0;
            biased_sof <= 1'b0;
            biased_eol <= 1'b0;
            biased_eof <= 1'b0;
            biased_x <= '0;
            biased_y <= '0;
            rounded_valid <= 1'b0;
            rounded_sof <= 1'b0;
            rounded_eol <= 1'b0;
            rounded_eof <= 1'b0;
            rounded_x <= '0;
            rounded_y <= '0;
            out_valid <= 1'b0;
            out_data_s8 <= 64'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            out_x <= '0;
            out_y <= '0;
        end else begin
            if (output_stage_ready) begin
                out_valid <= rounded_valid;
                out_sof <= rounded_valid && rounded_sof;
                out_eol <= rounded_valid && rounded_eol;
                out_eof <= rounded_valid && rounded_eof;
                if (rounded_valid) begin
                    for (channel = 0; channel < 8; channel = channel + 1)
                        out_data_s8[channel*8 +: 8] <=
                            saturate_activate_s8(rounded_pipe[channel],
                                                 rounded_activation[channel]);
                    out_x <= rounded_x;
                    out_y <= rounded_y;
                end
            end

            if (rounded_stage_ready) begin
                rounded_valid <= biased_valid;
                rounded_sof <= biased_valid && biased_sof;
                rounded_eol <= biased_valid && biased_eol;
                rounded_eof <= biased_valid && biased_eof;
                if (biased_valid) begin
                    for (channel = 0; channel < 8; channel = channel + 1) begin
                        rounded_pipe[channel] <= restore_shifted_sign(
                            biased_pipe[channel], biased_shift[channel],
                            biased_negative[channel]);
                        rounded_activation[channel] <=
                            biased_activation[channel];
                    end
                    rounded_x <= biased_x;
                    rounded_y <= biased_y;
                end
            end

            if (biased_stage_ready) begin
                biased_valid <= magnitude_valid;
                biased_sof <= magnitude_valid && magnitude_sof;
                biased_eol <= magnitude_valid && magnitude_eol;
                biased_eof <= magnitude_valid && magnitude_eof;
                if (magnitude_valid) begin
                    for (channel = 0; channel < 8; channel = channel + 1) begin
                        biased_pipe[channel] <= add_round_bias(
                            magnitude_pipe[channel], magnitude_shift[channel]);
                        biased_negative[channel] <=
                            magnitude_negative[channel];
                        biased_shift[channel] <= magnitude_shift[channel];
                        biased_activation[channel] <=
                            magnitude_activation[channel];
                    end
                    biased_x <= magnitude_x;
                    biased_y <= magnitude_y;
                end
            end

            if (magnitude_stage_ready) begin
                magnitude_valid <= product_valid;
                magnitude_sof <= product_valid && product_sof;
                magnitude_eol <= product_valid && product_eol;
                magnitude_eof <= product_valid && product_eof;
                if (product_valid) begin
                    for (channel = 0; channel < 8; channel = channel + 1) begin
                        magnitude_pipe[channel] <=
                            magnitude_s51(product_pipe[channel]);
                        magnitude_negative[channel] <=
                            product_pipe[channel][50];
                        magnitude_shift[channel] <= product_shift[channel];
                        magnitude_activation[channel] <=
                            product_activation[channel];
                    end
                    magnitude_x <= product_x;
                    magnitude_y <= product_y;
                end
            end

            if (product_stage_ready) begin
                product_valid <= in_valid;
                product_sof <= in_valid && in_sof;
                product_eol <= in_valid && in_eol;
                product_eof <= in_valid && in_eof;
                if (in_valid) begin
                    for (channel = 0; channel < 8; channel = channel + 1) begin
                        product_pipe[channel] <=
                            $signed(in_acc_s32[channel*32 +: 32]) *
                            $signed(in_mult_s18[channel*18 +: 18]);
                        product_shift[channel] <=
                            in_shift_u6[channel*6 +: 6];
                        product_activation[channel] <=
                            in_activation[channel*2 +: 2];
                    end
                    product_x <= in_x;
                    product_y <= in_y;
                end
            end
        end
    end

`ifndef SYNTHESIS
    integer assert_channel;
    always_ff @(posedge clk) begin
        if (!rst && in_valid && in_ready) begin
            for (assert_channel = 0; assert_channel < 8;
                 assert_channel = assert_channel + 1) begin
                if (in_shift_u6[assert_channel*6 +: 6] > 6'd47)
                    $fatal(1,
                           "c1_requant_bank8 channel %0d shift must be in 0..47",
                           assert_channel);
                if ((in_activation[assert_channel*2 +: 2] != ACT_NONE) &&
                    (in_activation[assert_channel*2 +: 2] != ACT_RELU))
                    $fatal(1,
                           "c1_requant_bank8 channel %0d unsupported activation %0d",
                           assert_channel,
                           in_activation[assert_channel*2 +: 2]);
            end
        end
    end
`endif

endmodule
