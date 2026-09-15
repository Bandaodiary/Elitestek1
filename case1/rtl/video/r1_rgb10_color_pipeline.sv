`timescale 1ns/1ps

// R1 post-Debayer color pipeline:
//   RGB u10 -> AWB Q2.14 -> RGB u12 -> CCM Q3.13 + signed32 offset
//   -> RGB u10 -> 1024x8 Gamma -> RGB888
//
// in_rgb10 packing is {R[9:0], G[9:0], B[9:0]}.  Scalar AWB/CCM parameters
// are snapshotted with every accepted pixel, so changing their input ports
// cannot make one pixel mix configurations.  Gamma uses three replicated
// 1024x8 synchronous-read banks, one read per color per clock.  A common
// write programs all banks.  Writes are accepted only while gamma_cfg_ready
// is high, after the pixel pipeline has drained; this removes read/write and
// mid-flight configuration ambiguity without any vendor RAM primitive.
// Gamma RAM has no reset contents. Software must program all addresses that
// will be read before sending pixels (normally all 1024 entries). Resetting
// control does not erase the LUT. Simulation rejects undefined reads instead
// of allowing X values to masquerade as a completed image-processing job.
//
// Six registered stages sustain one pixel per clock:
//   AWB multiply -> AWB requant -> CCM products -> CCM sum -> CCM requant
//   -> Gamma read/output
// Input edge N produces out_valid on edge N+5.
module r1_rgb10_color_pipeline #(
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
    input  logic [29:0]             in_rgb10,

    input  logic [15:0]             cfg_awb_gain_r,
    input  logic [15:0]             cfg_awb_gain_g,
    input  logic [15:0]             cfg_awb_gain_b,

    input  logic signed [15:0]      cfg_ccm_rr,
    input  logic signed [15:0]      cfg_ccm_rg,
    input  logic signed [15:0]      cfg_ccm_rb,
    input  logic signed [15:0]      cfg_ccm_gr,
    input  logic signed [15:0]      cfg_ccm_gg,
    input  logic signed [15:0]      cfg_ccm_gb,
    input  logic signed [15:0]      cfg_ccm_br,
    input  logic signed [15:0]      cfg_ccm_bg,
    input  logic signed [15:0]      cfg_ccm_bb,
    input  logic signed [31:0]      cfg_ccm_offset_r,
    input  logic signed [31:0]      cfg_ccm_offset_g,
    input  logic signed [31:0]      cfg_ccm_offset_b,

    input  logic                    gamma_cfg_we,
    input  logic [9:0]              gamma_cfg_addr,
    input  logic [7:0]              gamma_cfg_data,
    output logic                    gamma_cfg_ready,

    output logic                    out_valid,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [X_BITS-1:0]       out_x,
    output logic [Y_BITS-1:0]       out_y,
    output logic [23:0]             out_rgb888
);

    logic [7:0] gamma_r_mem [0:1023];
    logic [7:0] gamma_g_mem [0:1023];
    logic [7:0] gamma_b_mem [0:1023];

    wire [25:0] awb_product_r_comb;
    wire [25:0] awb_product_g_comb;
    wire [25:0] awb_product_b_comb;
    assign awb_product_r_comb = in_rgb10[29:20] * cfg_awb_gain_r;
    assign awb_product_g_comb = in_rgb10[19:10] * cfg_awb_gain_g;
    assign awb_product_b_comb = in_rgb10[9:0]   * cfg_awb_gain_b;

    logic [25:0] awb_product_pipe [0:2];
    logic signed [15:0] product_ccm [0:2][0:2];
    logic signed [31:0] product_offset [0:2];

    logic [11:0] awb_value_pipe [0:2];
    logic signed [15:0] awb_ccm [0:2][0:2];
    logic signed [31:0] awb_offset [0:2];

    logic signed [28:0] ccm_product_pipe [0:2][0:2];
    logic signed [31:0] ccm_product_offset [0:2];
    logic signed [34:0] ccm_sum_pipe [0:2];
    logic [9:0] linear_u10_pipe [0:2];

    logic [4:0] meta_valid;
    logic [4:0] meta_sof;
    logic [4:0] meta_eol;
    logic [4:0] meta_eof;
    logic [X_BITS-1:0] meta_x [0:4];
    logic [Y_BITS-1:0] meta_y [0:4];

    integer channel;
    integer out_channel;
    integer in_channel;
    integer meta_index;

    function automatic logic [11:0] awb_requant_u12 (
        input logic [25:0] product
    );
        logic [26:0] rounded;
        logic [12:0] shifted;
        begin
            rounded = {1'b0, product} + 27'd8192;
            shifted = rounded >> 14;
            if (shifted > 13'd4095)
                awb_requant_u12 = 12'd4095;
            else
                awb_requant_u12 = shifted[11:0];
        end
    endfunction

    function automatic logic signed [28:0] multiply_u12_s16 (
        input logic [11:0]        pixel,
        input logic signed [15:0] coefficient
    );
        begin
            multiply_u12_s16 = $signed({1'b0, pixel}) * coefficient;
        end
    endfunction

    function automatic logic [9:0] ccm_requant_u10 (
        input logic signed [34:0] value
    );
        logic signed [35:0] extended;
        logic        [35:0] magnitude;
        logic        [35:0] rounded_magnitude;
        logic signed [35:0] quantized;
        begin
            extended = {value[34], value};
            if (extended < 0) begin
                magnitude = $unsigned(-extended);
                rounded_magnitude = (magnitude + 36'd4096) >> 13;
                quantized = -$signed(rounded_magnitude);
            end else begin
                magnitude = $unsigned(extended);
                rounded_magnitude = (magnitude + 36'd4096) >> 13;
                quantized = $signed(rounded_magnitude);
            end

            if (quantized < 0)
                ccm_requant_u10 = 10'd0;
            else if (quantized > 36'sd1023)
                ccm_requant_u10 = 10'd1023;
            else
                ccm_requant_u10 = quantized[9:0];
        end
    endfunction

    always_comb begin
        gamma_cfg_ready = !rst && !in_valid && !(|meta_valid);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            meta_valid <= 5'b00000;
            meta_sof   <= 5'b00000;
            meta_eol   <= 5'b00000;
            meta_eof   <= 5'b00000;
            for (meta_index = 0; meta_index < 5; meta_index = meta_index + 1) begin
                meta_x[meta_index] <= '0;
                meta_y[meta_index] <= '0;
            end

            out_valid  <= 1'b0;
            out_sof    <= 1'b0;
            out_eol    <= 1'b0;
            out_eof    <= 1'b0;
            out_x      <= '0;
            out_y      <= '0;
            out_rgb888 <= 24'h000000;
        end else begin
            // Metadata pipeline mirrors the five data registers preceding
            // the final Gamma output register.
            meta_valid[0] <= in_valid;
            meta_sof[0]   <= in_valid && in_sof;
            meta_eol[0]   <= in_valid && in_eol;
            meta_eof[0]   <= in_valid && in_eof;
            if (in_valid) begin
                meta_x[0] <= in_x;
                meta_y[0] <= in_y;
            end
            for (meta_index = 1; meta_index < 5; meta_index = meta_index + 1) begin
                meta_valid[meta_index] <= meta_valid[meta_index-1];
                meta_sof[meta_index]   <= meta_valid[meta_index-1] &&
                                          meta_sof[meta_index-1];
                meta_eol[meta_index]   <= meta_valid[meta_index-1] &&
                                          meta_eol[meta_index-1];
                meta_eof[meta_index]   <= meta_valid[meta_index-1] &&
                                          meta_eof[meta_index-1];
                if (meta_valid[meta_index-1]) begin
                    meta_x[meta_index] <= meta_x[meta_index-1];
                    meta_y[meta_index] <= meta_y[meta_index-1];
                end
            end

            // Stage 0: AWB products and atomic scalar-config snapshot.
            if (in_valid) begin
                awb_product_pipe[0] <= awb_product_r_comb;
                awb_product_pipe[1] <= awb_product_g_comb;
                awb_product_pipe[2] <= awb_product_b_comb;

                product_ccm[0][0] <= cfg_ccm_rr;
                product_ccm[0][1] <= cfg_ccm_rg;
                product_ccm[0][2] <= cfg_ccm_rb;
                product_ccm[1][0] <= cfg_ccm_gr;
                product_ccm[1][1] <= cfg_ccm_gg;
                product_ccm[1][2] <= cfg_ccm_gb;
                product_ccm[2][0] <= cfg_ccm_br;
                product_ccm[2][1] <= cfg_ccm_bg;
                product_ccm[2][2] <= cfg_ccm_bb;
                product_offset[0] <= cfg_ccm_offset_r;
                product_offset[1] <= cfg_ccm_offset_g;
                product_offset[2] <= cfg_ccm_offset_b;
            end

            // Stage 1: AWB half-up requant/clamp and config propagation.
            if (meta_valid[0]) begin
                for (channel = 0; channel < 3; channel = channel + 1)
                    awb_value_pipe[channel] <=
                        awb_requant_u12(awb_product_pipe[channel]);
                for (out_channel = 0; out_channel < 3;
                     out_channel = out_channel + 1) begin
                    awb_offset[out_channel] <= product_offset[out_channel];
                    for (in_channel = 0; in_channel < 3;
                         in_channel = in_channel + 1)
                        awb_ccm[out_channel][in_channel] <=
                            product_ccm[out_channel][in_channel];
                end
            end

            // Stage 2: nine parallel unsigned12 x signed16 CCM products.
            if (meta_valid[1]) begin
                for (out_channel = 0; out_channel < 3;
                     out_channel = out_channel + 1) begin
                    ccm_product_offset[out_channel] <= awb_offset[out_channel];
                    for (in_channel = 0; in_channel < 3;
                         in_channel = in_channel + 1)
                        ccm_product_pipe[out_channel][in_channel] <=
                            multiply_u12_s16(awb_value_pipe[in_channel],
                                             awb_ccm[out_channel][in_channel]);
                end
            end

            // Stage 3: 35-bit balanced accumulation of three products+offset.
            if (meta_valid[2]) begin
                for (out_channel = 0; out_channel < 3;
                     out_channel = out_channel + 1) begin
                    ccm_sum_pipe[out_channel] <=
                        ($signed({{6{ccm_product_pipe[out_channel][0][28]}},
                                   ccm_product_pipe[out_channel][0]}) +
                         $signed({{6{ccm_product_pipe[out_channel][1][28]}},
                                   ccm_product_pipe[out_channel][1]})) +
                        ($signed({{6{ccm_product_pipe[out_channel][2][28]}},
                                   ccm_product_pipe[out_channel][2]}) +
                         $signed({{3{ccm_product_offset[out_channel][31]}},
                                   ccm_product_offset[out_channel]}));
                end
            end

            // Stage 4: signed ties-away Q13 rounding and u10 saturation.
            if (meta_valid[3]) begin
                for (channel = 0; channel < 3; channel = channel + 1)
                    linear_u10_pipe[channel] <=
                        ccm_requant_u10(ccm_sum_pipe[channel]);
            end

            // Stage 5: three independent synchronous Gamma reads.
            out_valid <= meta_valid[4];
            out_sof   <= meta_valid[4] && meta_sof[4];
            out_eol   <= meta_valid[4] && meta_eol[4];
            out_eof   <= meta_valid[4] && meta_eof[4];
            if (meta_valid[4]) begin
                out_rgb888 <= {gamma_r_mem[linear_u10_pipe[0]],
                               gamma_g_mem[linear_u10_pipe[1]],
                               gamma_b_mem[linear_u10_pipe[2]]};
                out_x <= meta_x[4];
                out_y <= meta_y[4];
            end

            // Common write port replicates one logical LUT into three banks.
            if (gamma_cfg_we && gamma_cfg_ready) begin
                gamma_r_mem[gamma_cfg_addr] <= gamma_cfg_data;
                gamma_g_mem[gamma_cfg_addr] <= gamma_cfg_data;
                gamma_b_mem[gamma_cfg_addr] <= gamma_cfg_data;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && meta_valid[4]) begin
            // Reduction + case equality retains X/Z detection without the
            // observed Icarus false positive on $isunknown(array concat).
            if ((^{linear_u10_pipe[0], linear_u10_pipe[1], linear_u10_pipe[2]}) === 1'bx)
                $fatal(1, "R1 color pipeline: unknown CCM output at Gamma input r=%h g=%h b=%h reduction=%b",
                    linear_u10_pipe[0],linear_u10_pipe[1],linear_u10_pipe[2],
                    ^{linear_u10_pipe[0],linear_u10_pipe[1],linear_u10_pipe[2]});
            if ((^{gamma_r_mem[linear_u10_pipe[0]],
                            gamma_g_mem[linear_u10_pipe[1]],
                            gamma_b_mem[linear_u10_pipe[2]]}) === 1'bx)
                $fatal(1, "R1 Gamma LUT read before initialization: program LUT before capture");
        end
    end
`endif
endmodule
