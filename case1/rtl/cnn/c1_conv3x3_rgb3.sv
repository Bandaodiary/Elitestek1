`timescale 1ns/1ps

// Three-input/three-output 3x3 convolution diagnostic core.
//
// Five registered stages sustain one input window per clock:
//   product -> 9 sums of 3 -> 3 sums of 3 -> final sum+bias -> requant
// An input sampled on edge N produces out_valid on edge N+4.  Bias and shift
// are snapshotted with every input so later configuration writes cannot alter
// pixels already in flight.
module c1_conv3x3_rgb3 #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT)
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   in_valid,
    input  logic                   in_sof,
    input  logic                   in_eol,
    input  logic                   in_eof,
    input  logic [X_BITS-1:0]      in_x,
    input  logic [Y_BITS-1:0]      in_y,
    input  logic [9*24-1:0]        in_window,
    input  logic                   cfg_we,
    input  logic [6:0]             cfg_addr,
    input  logic [31:0]            cfg_wdata,
    output logic                   out_valid,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic [23:0]            out_rgb
);
    import c1_fixed_pkg::*;

    logic signed [7:0] weights [0:2][0:2][0:2][0:2];
    logic signed [31:0] bias [0:2];
    logic [4:0] shift;

    // Product range is 0..255 multiplied by -128..127: signed 17 bits.
    logic signed [16:0] product_pipe [0:2][0:8][0:2];
    // Three products need 18 signed bits; three such sums need 20 bits.
    logic signed [17:0] sum1_pipe [0:2][0:8];
    logic signed [19:0] sum2_pipe [0:2][0:2];
    logic signed [31:0] accum_pipe [0:2];

    logic signed [31:0] product_bias [0:2];
    logic signed [31:0] sum1_bias [0:2];
    logic signed [31:0] sum2_bias [0:2];
    logic [4:0] product_shift, sum1_shift, sum2_shift, accum_shift;

    logic product_valid, sum1_valid, sum2_valid, accum_valid;
    logic product_sof, product_eol, product_eof;
    logic sum1_sof, sum1_eol, sum1_eof;
    logic sum2_sof, sum2_eol, sum2_eof;
    logic accum_sof, accum_eol, accum_eof;
    logic [X_BITS-1:0] product_x, sum1_x, sum2_x, accum_x;
    logic [Y_BITS-1:0] product_y, sum1_y, sum2_y, accum_y;

    integer oc_pipe, ic_pipe, ky_pipe, kx_pipe, tap_pipe, group_pipe;
    integer oc_reset, ic_reset, ky_reset, kx_reset;
    integer flat_index;

    function automatic logic signed [7:0] default_weight(
        input integer out_channel,
        input integer in_channel,
        input integer row,
        input integer column
    );
        integer kernel_value;
        begin
            kernel_value = 0;
            if (out_channel == in_channel) begin
                case (row*3+column)
                    0, 2, 6, 8: kernel_value = 1;
                    1, 3, 5, 7: kernel_value = 2;
                    4: kernel_value = 4;
                    default: kernel_value = 0;
                endcase
            end
            default_weight = kernel_value;
        end
    endfunction

    function automatic logic [7:0] get_channel(
        input logic [23:0] rgb,
        input integer channel
    );
        begin
            case (channel)
                0: get_channel = rgb[23:16];
                1: get_channel = rgb[15:8];
                default: get_channel = rgb[7:0];
            endcase
        end
    endfunction

    function automatic logic signed [17:0] add3_s17(
        input logic signed [16:0] a,
        input logic signed [16:0] b,
        input logic signed [16:0] c
    );
        begin
            add3_s17 = $signed({a[16], a}) +
                       $signed({b[16], b}) +
                       $signed({c[16], c});
        end
    endfunction

    function automatic logic signed [19:0] add3_s18(
        input logic signed [17:0] a,
        input logic signed [17:0] b,
        input logic signed [17:0] c
    );
        begin
            add3_s18 = $signed({{2{a[17]}}, a}) +
                       $signed({{2{b[17]}}, b}) +
                       $signed({{2{c[17]}}, c});
        end
    endfunction

    function automatic logic [7:0] requant_u8(
        input logic signed [31:0] value,
        input logic [4:0] value_shift
    );
        logic signed [31:0] rounded;
        begin
            rounded = c1_round_shift_s32(value, value_shift);
            requant_u8 = c1_clamp_u8(rounded);
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (oc_reset = 0; oc_reset < 3; oc_reset = oc_reset + 1) begin
                bias[oc_reset] <= 32'sd0;
                for (ic_reset = 0; ic_reset < 3; ic_reset = ic_reset + 1)
                    for (ky_reset = 0; ky_reset < 3; ky_reset = ky_reset + 1)
                        for (kx_reset = 0; kx_reset < 3; kx_reset = kx_reset + 1)
                            weights[oc_reset][ic_reset][ky_reset][kx_reset]
                                <= default_weight(oc_reset, ic_reset, ky_reset, kx_reset);
            end
            shift <= 5'd4;

            product_valid <= 1'b0;
            sum1_valid <= 1'b0;
            sum2_valid <= 1'b0;
            accum_valid <= 1'b0;
            out_valid <= 1'b0;
            product_sof <= 1'b0;
            product_eol <= 1'b0;
            product_eof <= 1'b0;
            sum1_sof <= 1'b0;
            sum1_eol <= 1'b0;
            sum1_eof <= 1'b0;
            sum2_sof <= 1'b0;
            sum2_eol <= 1'b0;
            sum2_eof <= 1'b0;
            accum_sof <= 1'b0;
            accum_eol <= 1'b0;
            accum_eof <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            product_x <= '0;
            product_y <= '0;
            sum1_x <= '0;
            sum1_y <= '0;
            sum2_x <= '0;
            sum2_y <= '0;
            accum_x <= '0;
            accum_y <= '0;
            out_x <= '0;
            out_y <= '0;
            out_rgb <= '0;
        end else begin
            // Stage 0: all products for the current input window.
            product_valid <= in_valid;
            product_sof <= in_valid && in_sof;
            product_eol <= in_valid && in_eol;
            product_eof <= in_valid && in_eof;
            if (in_valid) begin
                product_x <= in_x;
                product_y <= in_y;
                product_shift <= shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    product_bias[oc_pipe] <= bias[oc_pipe];
                    for (ky_pipe = 0; ky_pipe < 3; ky_pipe = ky_pipe + 1) begin
                        for (kx_pipe = 0; kx_pipe < 3; kx_pipe = kx_pipe + 1) begin
                            for (ic_pipe = 0; ic_pipe < 3; ic_pipe = ic_pipe + 1) begin
                                product_pipe[oc_pipe][ky_pipe*3+kx_pipe][ic_pipe] <=
                                    $signed({1'b0, get_channel(
                                        in_window[(ky_pipe*3+kx_pipe)*24 +: 24], ic_pipe)}) *
                                    weights[oc_pipe][ic_pipe][ky_pipe][kx_pipe];
                            end
                        end
                    end
                end
            end

            // Stage 1: sum the three input channels at each of nine taps.
            sum1_valid <= product_valid;
            sum1_sof <= product_valid && product_sof;
            sum1_eol <= product_valid && product_eol;
            sum1_eof <= product_valid && product_eof;
            if (product_valid) begin
                sum1_x <= product_x;
                sum1_y <= product_y;
                sum1_shift <= product_shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    sum1_bias[oc_pipe] <= product_bias[oc_pipe];
                    for (tap_pipe = 0; tap_pipe < 9; tap_pipe = tap_pipe + 1)
                        sum1_pipe[oc_pipe][tap_pipe] <= add3_s17(
                            product_pipe[oc_pipe][tap_pipe][0],
                            product_pipe[oc_pipe][tap_pipe][1],
                            product_pipe[oc_pipe][tap_pipe][2]);
                end
            end

            // Stage 2: reduce nine tap sums to three row/group sums.
            sum2_valid <= sum1_valid;
            sum2_sof <= sum1_valid && sum1_sof;
            sum2_eol <= sum1_valid && sum1_eol;
            sum2_eof <= sum1_valid && sum1_eof;
            if (sum1_valid) begin
                sum2_x <= sum1_x;
                sum2_y <= sum1_y;
                sum2_shift <= sum1_shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    sum2_bias[oc_pipe] <= sum1_bias[oc_pipe];
                    for (group_pipe = 0; group_pipe < 3; group_pipe = group_pipe + 1)
                        sum2_pipe[oc_pipe][group_pipe] <= add3_s18(
                            sum1_pipe[oc_pipe][group_pipe*3],
                            sum1_pipe[oc_pipe][group_pipe*3+1],
                            sum1_pipe[oc_pipe][group_pipe*3+2]);
                end
            end

            // Stage 3: balanced final reduction plus the snapshotted bias.
            accum_valid <= sum2_valid;
            accum_sof <= sum2_valid && sum2_sof;
            accum_eol <= sum2_valid && sum2_eol;
            accum_eof <= sum2_valid && sum2_eof;
            if (sum2_valid) begin
                accum_x <= sum2_x;
                accum_y <= sum2_y;
                accum_shift <= sum2_shift;
                for (oc_pipe = 0; oc_pipe < 3; oc_pipe = oc_pipe + 1) begin
                    accum_pipe[oc_pipe] <=
                        ($signed({{12{sum2_pipe[oc_pipe][0][19]}}, sum2_pipe[oc_pipe][0]}) +
                         $signed({{12{sum2_pipe[oc_pipe][1][19]}}, sum2_pipe[oc_pipe][1]})) +
                        ($signed({{12{sum2_pipe[oc_pipe][2][19]}}, sum2_pipe[oc_pipe][2]}) +
                         sum2_bias[oc_pipe]);
                end
            end

            // Stage 4: project-defined rounding, shifting and unsigned clamp.
            out_valid <= accum_valid;
            out_sof <= accum_valid && accum_sof;
            out_eol <= accum_valid && accum_eol;
            out_eof <= accum_valid && accum_eof;
            if (accum_valid) begin
                out_x <= accum_x;
                out_y <= accum_y;
                out_rgb <= {requant_u8(accum_pipe[0], accum_shift),
                            requant_u8(accum_pipe[1], accum_shift),
                            requant_u8(accum_pipe[2], accum_shift)};
            end

            // Configuration map is unchanged.  Nonblocking assignment means a
            // simultaneous input pixel observes the pre-write configuration.
            if (cfg_we) begin
                if (cfg_addr < 7'd81) begin
                    flat_index = cfg_addr;
                    weights[flat_index/27][(flat_index%27)/9][(flat_index%9)/3][flat_index%3]
                        <= cfg_wdata[7:0];
                end else if (cfg_addr < 7'd84) begin
                    bias[cfg_addr-7'd81] <= cfg_wdata;
                end else if (cfg_addr == 7'd84) begin
                    shift <= cfg_wdata[4:0];
                end
            end
        end
    end

endmodule
