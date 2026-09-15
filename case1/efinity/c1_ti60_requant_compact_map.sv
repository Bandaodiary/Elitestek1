// C29 independent leaf MAP comparison, NOT a pin-compatible board top.
module c1_ti60_requant_compact_map #(
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
    c1_requant_bank8_compact #(.X_BITS(X_BITS),.Y_BITS(Y_BITS)) u_leaf(.*);
endmodule
