`timescale 1ns/1ps

package c1_descriptor_pkg;
    localparam int C1_DESC_VERSION = 1;
    localparam int C1_DESC_WORDS = 16;
    localparam int C1_DESC_BITS = 512;

    localparam logic [7:0] C1_OP_NOP          = 8'd0;
    localparam logic [7:0] C1_OP_CONV3X3      = 8'd1;
    localparam logic [7:0] C1_OP_CONV1X1      = 8'd2;
    localparam logic [7:0] C1_OP_DWCONV3X3    = 8'd3;
    localparam logic [7:0] C1_OP_UPSAMPLE2    = 8'd4;
    localparam logic [7:0] C1_OP_RESIDUAL_ADD = 8'd5;
    localparam logic [7:0] C1_OP_OUTPUT_RGB   = 8'd6;

    localparam logic [1:0] C1_ACT_NONE = 2'd0;
    localparam logic [1:0] C1_ACT_RELU = 2'd1;

    typedef logic [C1_DESC_BITS-1:0] c1_descriptor_t;

    function automatic logic [31:0] c1_descriptor_word(
        input c1_descriptor_t descriptor,
        input logic [3:0] word_index
    );
        c1_descriptor_word = descriptor[word_index*32 +: 32];
    endfunction

    function automatic logic c1_descriptor_header_valid(
        input c1_descriptor_t descriptor
    );
        logic [31:0] control;
        begin
            control = descriptor[31:0];
            c1_descriptor_header_valid =
                (control[23:16] == C1_DESC_VERSION) &&
                (control[31:24] == C1_DESC_WORDS) &&
                (control[7:0] >= C1_OP_CONV3X3) &&
                (control[7:0] <= C1_OP_OUTPUT_RGB) &&
                (control[9:8] <= C1_ACT_RELU) &&
                (control[15] == 1'b0);
        end
    endfunction
endpackage
