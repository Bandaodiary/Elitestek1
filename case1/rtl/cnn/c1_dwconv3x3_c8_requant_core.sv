`timescale 1ns/1ps

// Board-independent C8 depthwise 3x3 compute/requant primitive.
//
// One start_valid/start_ready handshake snapshots the complete layer config:
// eight independent 3x3 signed-int8 kernels, eight signed32 biases, eight
// signed18 requant multipliers, eight u6 shifts, and eight activation modes.
// The snapped config remains bound to every accepted window through the EOF
// output handshake; live start_* changes while busy have no effect in the
// default mode. PER_BEAT_CONFIG instead binds these configuration buses to
// each input-window handshake; see its contract below.
//
// Packed layout:
//   in_window_s8[(tap*8 + lane)*8 +: 8]
//       tap is row-major 0..8, lane is channel 0..7.
//   start_weights_s8[(lane*9 + tap)*8 +: 8]
//       each lane owns one contiguous CHW/3x3 kernel.
//   packed per-lane bias/mult/shift/activation buses use lane 0 in the least-
//       significant slice, matching c1_requant_bank8.
//
// For each lane the bias plus nine products is first evaluated exactly in a
// signed 36-bit value.  The accumulator presented to requant is its low 32
// bits, i.e. signed32 addition modulo 2**32.  This is bit-equivalent to
// wrapping after every addition.  overflow_seen becomes sticky when the exact
// final mathematical sum for any accepted beat lies outside signed32; it does
// not alter the wrapped result and clears only on reset or the next start.
// Correct exported models are required to avoid overflow.
//
// A registered product stage, a registered balanced kernel-sum stage and the
// signed32 accumulator stage feed the existing three-stage
// c1_requant_bank8.  The two cuts remove both the multiplier-plus-nine-add
// path and the product-to-sticky-overflow diagnostic path of the original
// baseline.  Once filled, the elastic pipeline still accepts one C8 window
// per clock while the sink remains ready.  All payload and metadata remain
// stable under arbitrary downstream backpressure.  in_eof ends input
// acceptance; busy and done retire only when the corresponding EOF output is
// accepted.
module c1_dwconv3x3_c8_requant_core #(
    parameter integer X_BITS = 16,
    parameter integer Y_BITS = 16,
    // Default: start_* snapshots one configuration for the entire batch.
    // Enabled: start only opens a batch; the start_* CONFIGURATION buses are
    // sampled with EACH in_valid/in_ready handshake. They must then remain
    // stable with a stalled input, not merely with a stalled start. Enables
    // consecutive channel groups with different kernels/affine parameters.
    parameter bit PER_BEAT_CONFIG = 1'b0
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   start_valid,
    output logic                   start_ready,
    input  logic [575:0]           start_weights_s8,
    input  logic [255:0]           start_bias_s32,
    input  logic [143:0]           start_mult_s18,
    input  logic [47:0]            start_shift_u6,
    input  logic [15:0]            start_activation,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [575:0]           in_window_s8,
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
    output logic [Y_BITS-1:0]      out_y,

    output logic                   busy,
    output logic                   done,
    output logic                   overflow_seen
);

    localparam logic [1:0] ACT_NONE = 2'd0;
    localparam logic [1:0] ACT_RELU = 2'd1;
    localparam logic signed [35:0] S32_MAX_EXT =
        {4'b0000, 32'h7fff_ffff};
    localparam logic signed [35:0] S32_MIN_EXT =
        {4'b1111, 32'h8000_0000};

    logic [575:0] weights_q;
    logic [255:0] bias_q;
    logic [143:0] mult_q;
    logic [47:0] shift_q;
    logic [15:0] activation_q;
    logic accepting_input;
    // Only live in per-beat mode. Metadata follows the SAME elastic enables
    // as products/sums/accumulators; no later group can overwrite it.
    logic [255:0] prod_bias_q, sum_bias_q;
    logic [207:0] prod_affine_q, sum_affine_q, acc_affine_q;
    wire [575:0] selected_weights = PER_BEAT_CONFIG ? start_weights_s8 : weights_q;
    wire [255:0] selected_bias = PER_BEAT_CONFIG ? sum_bias_q : bias_q;
    wire [207:0] selected_affine = PER_BEAT_CONFIG ? acc_affine_q :
        {activation_q,shift_q,mult_q};

    logic signed [15:0] product_comb [0:7][0:8];
    logic signed [15:0] product_q [0:7][0:8];
    logic prod_valid_q;
    logic prod_sof_q, prod_eol_q, prod_eof_q;
    logic [X_BITS-1:0] prod_x_q;
    logic [Y_BITS-1:0] prod_y_q;

    logic [255:0] acc_data_q;
    logic acc_valid_q;
    logic acc_sof_q, acc_eol_q, acc_eof_q;
    logic [X_BITS-1:0] acc_x_q;
    logic [Y_BITS-1:0] acc_y_q;
    logic signed [35:0] acc_sum_comb [0:7];
    logic signed [16:0] pair01_comb [0:7];
    logic signed [16:0] pair23_comb [0:7];
    logic signed [16:0] pair45_comb [0:7];
    logic signed [16:0] pair67_comb [0:7];
    logic signed [17:0] quad03_comb [0:7];
    logic signed [17:0] quad47_comb [0:7];
    logic signed [18:0] octet_comb [0:7];
    logic signed [18:0] kernel_sum_comb [0:7];
    logic signed [18:0] kernel_sum_q [0:7];
    logic sum_valid_q;
    logic sum_sof_q, sum_eol_q, sum_eof_q;
    logic [X_BITS-1:0] sum_x_q;
    logic [Y_BITS-1:0] sum_y_q;
    logic [7:0] overflow_comb;
    logic acc_overflow_q;
    logic prod_stage_ready;
    logic sum_stage_ready;
    logic acc_stage_ready;
    logic input_fire;
    logic start_fire;

    logic requant_in_ready;
    logic requant_out_valid;
    logic requant_out_sof, requant_out_eol, requant_out_eof;
    logic [63:0] requant_out_data_s8;
    logic [X_BITS-1:0] requant_out_x;
    logic [Y_BITS-1:0] requant_out_y;
    logic output_fire;

    integer comb_lane;
    integer comb_tap;
    integer seq_lane;

    always_comb begin
        start_ready = !rst && !busy;
        start_fire = start_valid && start_ready;

        acc_stage_ready = !acc_valid_q || requant_in_ready;
        sum_stage_ready = !sum_valid_q || acc_stage_ready;
        prod_stage_ready = !prod_valid_q || sum_stage_ready;
        in_ready = !rst && accepting_input && prod_stage_ready;
        input_fire = in_valid && in_ready;
        output_fire = requant_out_valid && out_ready;

        for (comb_lane = 0; comb_lane < 8;
             comb_lane = comb_lane + 1)
            for (comb_tap = 0; comb_tap < 9;
                 comb_tap = comb_tap + 1)
                product_comb[comb_lane][comb_tap] =
                    $signed(in_window_s8[(comb_tap*64) +
                                         (comb_lane*8) +: 8]) *
                    $signed(selected_weights[(comb_lane*72) +
                                      (comb_tap*8) +: 8]);

        for (comb_lane = 0; comb_lane < 8;
             comb_lane = comb_lane + 1) begin
            pair01_comb[comb_lane] =
                $signed({product_q[comb_lane][0][15],
                         product_q[comb_lane][0]}) +
                $signed({product_q[comb_lane][1][15],
                         product_q[comb_lane][1]});
            pair23_comb[comb_lane] =
                $signed({product_q[comb_lane][2][15],
                         product_q[comb_lane][2]}) +
                $signed({product_q[comb_lane][3][15],
                         product_q[comb_lane][3]});
            pair45_comb[comb_lane] =
                $signed({product_q[comb_lane][4][15],
                         product_q[comb_lane][4]}) +
                $signed({product_q[comb_lane][5][15],
                         product_q[comb_lane][5]});
            pair67_comb[comb_lane] =
                $signed({product_q[comb_lane][6][15],
                         product_q[comb_lane][6]}) +
                $signed({product_q[comb_lane][7][15],
                         product_q[comb_lane][7]});
            quad03_comb[comb_lane] =
                $signed({pair01_comb[comb_lane][16],
                         pair01_comb[comb_lane]}) +
                $signed({pair23_comb[comb_lane][16],
                         pair23_comb[comb_lane]});
            quad47_comb[comb_lane] =
                $signed({pair45_comb[comb_lane][16],
                         pair45_comb[comb_lane]}) +
                $signed({pair67_comb[comb_lane][16],
                         pair67_comb[comb_lane]});
            octet_comb[comb_lane] =
                $signed({quad03_comb[comb_lane][17],
                         quad03_comb[comb_lane]}) +
                $signed({quad47_comb[comb_lane][17],
                         quad47_comb[comb_lane]});
            kernel_sum_comb[comb_lane] = octet_comb[comb_lane] +
                $signed({{3{product_q[comb_lane][8][15]}},
                         product_q[comb_lane][8]});
            acc_sum_comb[comb_lane] =
                $signed({{4{selected_bias[comb_lane*32 + 31]}},
                         selected_bias[comb_lane*32 +: 32]}) +
                $signed({{17{kernel_sum_q[comb_lane][18]}},
                         kernel_sum_q[comb_lane]});
            overflow_comb[comb_lane] =
                ($signed(acc_sum_comb[comb_lane]) > S32_MAX_EXT) ||
                ($signed(acc_sum_comb[comb_lane]) < S32_MIN_EXT);
        end

        out_valid = requant_out_valid;
        out_data_s8 = requant_out_data_s8;
        out_sof = requant_out_sof;
        out_eol = requant_out_eol;
        out_eof = requant_out_eof;
        out_x = requant_out_x;
        out_y = requant_out_y;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            weights_q <= '0;
            bias_q <= '0;
            mult_q <= '0;
            shift_q <= '0;
            activation_q <= '0;
            accepting_input <= 1'b0;
            prod_bias_q <= '0; sum_bias_q <= '0;
            prod_affine_q <= '0; sum_affine_q <= '0; acc_affine_q <= '0;
            prod_valid_q <= 1'b0;
            prod_sof_q <= 1'b0;
            prod_eol_q <= 1'b0;
            prod_eof_q <= 1'b0;
            prod_x_q <= '0;
            prod_y_q <= '0;
            sum_valid_q <= 1'b0;
            sum_sof_q <= 1'b0;
            sum_eol_q <= 1'b0;
            sum_eof_q <= 1'b0;
            sum_x_q <= '0;
            sum_y_q <= '0;
            acc_data_q <= '0;
            acc_valid_q <= 1'b0;
            acc_overflow_q <= 1'b0;
            acc_sof_q <= 1'b0;
            acc_eol_q <= 1'b0;
            acc_eof_q <= 1'b0;
            acc_x_q <= '0;
            acc_y_q <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            overflow_seen <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start_fire) begin
                if (!PER_BEAT_CONFIG) begin
                    weights_q <= start_weights_s8;
                    bias_q <= start_bias_s32;
                    mult_q <= start_mult_s18;
                    shift_q <= start_shift_u6;
                    activation_q <= start_activation;
                end
                accepting_input <= 1'b1;
                busy <= 1'b1;
                overflow_seen <= 1'b0;
            end

            if (prod_stage_ready) begin
                prod_valid_q <= input_fire;
                prod_sof_q <= input_fire && in_sof;
                prod_eol_q <= input_fire && in_eol;
                prod_eof_q <= input_fire && in_eof;
                if (input_fire) begin
                    if (PER_BEAT_CONFIG) begin
                        prod_bias_q <= start_bias_s32;
                        prod_affine_q <= {start_activation,start_shift_u6,start_mult_s18};
                    end
                    for (seq_lane = 0; seq_lane < 8;
                         seq_lane = seq_lane + 1)
                        for (integer seq_tap = 0; seq_tap < 9;
                             seq_tap = seq_tap + 1)
                            product_q[seq_lane][seq_tap] <=
                                product_comb[seq_lane][seq_tap];
                    prod_x_q <= in_x;
                    prod_y_q <= in_y;
                end
            end

            if (sum_stage_ready) begin
                sum_valid_q <= prod_valid_q;
                sum_sof_q <= prod_valid_q && prod_sof_q;
                sum_eol_q <= prod_valid_q && prod_eol_q;
                sum_eof_q <= prod_valid_q && prod_eof_q;
                if (prod_valid_q) begin
                    if (PER_BEAT_CONFIG) begin
                        sum_bias_q <= prod_bias_q;
                        sum_affine_q <= prod_affine_q;
                    end
                    for (seq_lane = 0; seq_lane < 8;
                         seq_lane = seq_lane + 1)
                        kernel_sum_q[seq_lane] <=
                            kernel_sum_comb[seq_lane];
                    sum_x_q <= prod_x_q;
                    sum_y_q <= prod_y_q;
                end
            end

            if (acc_stage_ready) begin
                acc_valid_q <= sum_valid_q;
                acc_sof_q <= sum_valid_q && sum_sof_q;
                acc_eol_q <= sum_valid_q && sum_eol_q;
                acc_eof_q <= sum_valid_q && sum_eof_q;
                acc_overflow_q <= sum_valid_q && (|overflow_comb);
                if (sum_valid_q) begin
                    if (PER_BEAT_CONFIG) acc_affine_q <= sum_affine_q;
                    for (seq_lane = 0; seq_lane < 8;
                         seq_lane = seq_lane + 1)
                        acc_data_q[seq_lane*32 +: 32] <=
                            acc_sum_comb[seq_lane][31:0];
                    acc_x_q <= sum_x_q;
                    acc_y_q <= sum_y_q;
                end
            end

            if (acc_valid_q && requant_in_ready && acc_overflow_q)
                overflow_seen <= 1'b1;

            if (input_fire) begin
                if (in_eof)
                    accepting_input <= 1'b0;
            end

            if (output_fire && requant_out_eof) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    c1_requant_bank8 #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_requant (
        .clk,
        .rst,
        .in_valid(acc_valid_q),
        .in_ready(requant_in_ready),
        .in_acc_s32(acc_data_q),
        .in_mult_s18(selected_affine[143:0]),
        .in_shift_u6(selected_affine[191:144]),
        .in_activation(selected_affine[207:192]),
        .in_sof(acc_sof_q),
        .in_eol(acc_eol_q),
        .in_eof(acc_eof_q),
        .in_x(acc_x_q),
        .in_y(acc_y_q),
        .out_valid(requant_out_valid),
        .out_ready,
        .out_data_s8(requant_out_data_s8),
        .out_sof(requant_out_sof),
        .out_eol(requant_out_eol),
        .out_eof(requant_out_eof),
        .out_x(requant_out_x),
        .out_y(requant_out_y)
    );

`ifndef SYNTHESIS
    integer check_lane;
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (PER_BEAT_CONFIG ? input_fire : start_fire) begin
                for (check_lane = 0; check_lane < 8;
                     check_lane = check_lane + 1) begin
                    if (start_shift_u6[check_lane*6 +: 6] > 6'd47)
                        $fatal(1,
                               "c1_dwconv3x3_c8_requant_core shift[%0d] exceeds 47",
                               check_lane);
                    if ((start_activation[check_lane*2 +: 2] != ACT_NONE) &&
                        (start_activation[check_lane*2 +: 2] != ACT_RELU))
                        $fatal(1,
                               "c1_dwconv3x3_c8_requant_core activation[%0d] unsupported",
                               check_lane);
                end
            end
            if (in_valid && in_ready && in_eof && !in_eol)
                $fatal(1,
                       "c1_dwconv3x3_c8_requant_core EOF must coincide with EOL");
        end
    end
`endif

endmodule
