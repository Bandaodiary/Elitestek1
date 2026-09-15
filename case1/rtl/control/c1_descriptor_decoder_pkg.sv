`timescale 1ns/1ps

// Validation result ABI for c1_layer_command_decoder.  Values are stable and
// intentionally independent from simulator assertions so firmware/status
// logic can report the first rejected descriptor condition.
package c1_descriptor_decoder_pkg;
    import c1_descriptor_pkg::*;

    localparam logic [4:0] C1_DESC_ERR_NONE                 = 5'd0;
    localparam logic [4:0] C1_DESC_ERR_VERSION              = 5'd1;
    localparam logic [4:0] C1_DESC_ERR_WORDS                = 5'd2;
    localparam logic [4:0] C1_DESC_ERR_OPCODE               = 5'd3;
    localparam logic [4:0] C1_DESC_ERR_ACTIVATION           = 5'd4;
    localparam logic [4:0] C1_DESC_ERR_RESERVED_FLAGS       = 5'd5;
    localparam logic [4:0] C1_DESC_ERR_ZERO_SIZE            = 5'd6;
    localparam logic [4:0] C1_DESC_ERR_ZERO_CHANNELS        = 5'd7;
    localparam logic [4:0] C1_DESC_ERR_ZERO_GEOMETRY        = 5'd8;
    localparam logic [4:0] C1_DESC_ERR_ZERO_SCHEDULE        = 5'd9;
    localparam logic [4:0] C1_DESC_ERR_ADDRESS_ALIGNMENT    = 5'd10;
    localparam logic [4:0] C1_DESC_ERR_RESIDUAL_OFFSET      = 5'd11;
    localparam logic [4:0] C1_DESC_ERR_ROW_ALIGNMENT        = 5'd12;
    localparam logic [4:0] C1_DESC_ERR_ROW_STRIDE_RANGE     = 5'd13;
    localparam logic [4:0] C1_DESC_ERR_CONV3_GEOMETRY       = 5'd14;
    localparam logic [4:0] C1_DESC_ERR_CONV3_FLAGS          = 5'd15;
    localparam logic [4:0] C1_DESC_ERR_CONV1_GEOMETRY       = 5'd16;
    localparam logic [4:0] C1_DESC_ERR_DWCONV_GEOMETRY      = 5'd17;
    localparam logic [4:0] C1_DESC_ERR_DWCONV_FLAGS         = 5'd18;
    localparam logic [4:0] C1_DESC_ERR_UPSAMPLE_GEOMETRY    = 5'd19;
    localparam logic [4:0] C1_DESC_ERR_RESIDUAL_GEOMETRY    = 5'd20;
    localparam logic [4:0] C1_DESC_ERR_RESIDUAL_FLAGS       = 5'd21;
    localparam logic [4:0] C1_DESC_ERR_OUTPUT_GEOMETRY      = 5'd22;
    localparam logic [4:0] C1_DESC_ERR_OUTPUT_ACTIVATION    = 5'd23;

    // Shared combinational validator.  Keeping this in the ABI package lets
    // the wrapper optionally validate descriptors while they are captured,
    // then replay only a five-bit result to the runtime decoder.  The
    // default decoder path still calls the same function directly, so there
    // is one source of truth for error priority and geometry rules.
    function automatic logic [4:0] c1_validate_descriptor(
        input logic [511:0] descriptor
    );
        localparam integer AXI_ALIGN_LSB = 4;
        localparam integer FLAG_SAME_REPLICATE = 0;
        localparam integer FLAG_RESIDUAL_VALID = 1;
        logic [7:0] opcode;
        logic [1:0] activation;
        logic [5:0] flags;
        logic [7:0] version;
        logic [7:0] words;
        logic [15:0] input_width, input_height;
        logic [15:0] output_width, output_height;
        logic [15:0] input_channels, output_channels;
        logic [31:0] input_offset, output_offset, residual_offset;
        logic [31:0] weight_offset, bias_offset, multiplier_offset;
        logic [31:0] shift_offset;
        logic [31:0] input_row_stride, output_row_stride;
        logic [7:0] kernel_width, kernel_height, stride_x, stride_y;
        logic [7:0] channel_block, mac_lanes, tile_width, tile_height;
        logic [31:0] input_row_bytes, output_row_bytes;
        logic [16:0] expected_width, expected_height;
        begin
            opcode = descriptor[7:0];
            activation = descriptor[9:8];
            flags = descriptor[15:10];
            version = descriptor[23:16];
            words = descriptor[31:24];
            input_width = descriptor[47:32];
            input_height = descriptor[63:48];
            output_width = descriptor[79:64];
            output_height = descriptor[95:80];
            input_channels = descriptor[111:96];
            output_channels = descriptor[127:112];
            input_offset = descriptor[159:128];
            output_offset = descriptor[191:160];
            residual_offset = descriptor[223:192];
            weight_offset = descriptor[255:224];
            bias_offset = descriptor[287:256];
            multiplier_offset = descriptor[319:288];
            shift_offset = descriptor[351:320];
            input_row_stride = descriptor[383:352];
            output_row_stride = descriptor[415:384];
            kernel_width = descriptor[423:416];
            kernel_height = descriptor[431:424];
            stride_x = descriptor[439:432];
            stride_y = descriptor[447:440];
            channel_block = descriptor[455:448];
            mac_lanes = descriptor[463:456];
            tile_width = descriptor[471:464];
            tile_height = descriptor[479:472];
            input_row_bytes = {16'd0, input_width} *
                              {16'd0, input_channels};
            output_row_bytes = {16'd0, output_width} *
                               {16'd0, output_channels};
            expected_width = {1'b0, input_width};
            expected_height = {1'b0, input_height};

            c1_validate_descriptor = C1_DESC_ERR_NONE;
            if (version != C1_DESC_VERSION)
                c1_validate_descriptor = C1_DESC_ERR_VERSION;
            else if (words != C1_DESC_WORDS)
                c1_validate_descriptor = C1_DESC_ERR_WORDS;
            else if ((opcode < C1_OP_CONV3X3) ||
                     (opcode > C1_OP_OUTPUT_RGB))
                c1_validate_descriptor = C1_DESC_ERR_OPCODE;
            else if (activation > C1_ACT_RELU)
                c1_validate_descriptor = C1_DESC_ERR_ACTIVATION;
            else if (flags[5])
                c1_validate_descriptor = C1_DESC_ERR_RESERVED_FLAGS;
            else if ((input_width == 0) || (input_height == 0) ||
                     (output_width == 0) || (output_height == 0))
                c1_validate_descriptor = C1_DESC_ERR_ZERO_SIZE;
            else if ((input_channels == 0) || (output_channels == 0))
                c1_validate_descriptor = C1_DESC_ERR_ZERO_CHANNELS;
            else if ((kernel_width == 0) || (kernel_height == 0) ||
                     (stride_x == 0) || (stride_y == 0))
                c1_validate_descriptor = C1_DESC_ERR_ZERO_GEOMETRY;
            else if ((channel_block == 0) || (mac_lanes == 0) ||
                     (tile_width == 0) || (tile_height == 0))
                c1_validate_descriptor = C1_DESC_ERR_ZERO_SCHEDULE;
            else if ((input_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (output_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (residual_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (weight_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (bias_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (multiplier_offset[AXI_ALIGN_LSB-1:0] != 0) ||
                     (shift_offset[AXI_ALIGN_LSB-1:0] != 0))
                c1_validate_descriptor = C1_DESC_ERR_ADDRESS_ALIGNMENT;
            else if (!flags[FLAG_RESIDUAL_VALID] &&
                     (residual_offset != 0))
                c1_validate_descriptor = C1_DESC_ERR_RESIDUAL_OFFSET;
            else if (((input_row_stride != 0) &&
                      (input_row_stride[AXI_ALIGN_LSB-1:0] != 0)) ||
                     ((output_row_stride != 0) &&
                      (output_row_stride[AXI_ALIGN_LSB-1:0] != 0)))
                c1_validate_descriptor = C1_DESC_ERR_ROW_ALIGNMENT;
            else if (((input_row_stride != 0) &&
                      (input_row_stride < input_row_bytes)) ||
                     ((output_row_stride != 0) &&
                      (output_row_stride < output_row_bytes)))
                c1_validate_descriptor = C1_DESC_ERR_ROW_STRIDE_RANGE;
            else begin
                case (opcode)
                    C1_OP_CONV3X3: begin
                        if (stride_x == 8'd2) begin
                            expected_width = ({1'b0, input_width} + 17'd1) >> 1;
                            expected_height = ({1'b0, input_height} + 17'd1) >> 1;
                        end
                        if ((kernel_width != 8'd3) ||
                            (kernel_height != 8'd3) ||
                            (stride_x != stride_y) ||
                            ((stride_x != 8'd1) && (stride_x != 8'd2)) ||
                            ({1'b0, output_width} != expected_width) ||
                            ({1'b0, output_height} != expected_height))
                            c1_validate_descriptor = C1_DESC_ERR_CONV3_GEOMETRY;
                        else if (!flags[FLAG_SAME_REPLICATE])
                            c1_validate_descriptor = C1_DESC_ERR_CONV3_FLAGS;
                    end

                    C1_OP_CONV1X1: begin
                        if ((kernel_width != 8'd1) ||
                            (kernel_height != 8'd1) ||
                            (stride_x != 8'd1) || (stride_y != 8'd1) ||
                            (output_width != input_width) ||
                            (output_height != input_height))
                            c1_validate_descriptor = C1_DESC_ERR_CONV1_GEOMETRY;
                    end

                    C1_OP_DWCONV3X3: begin
                        if ((kernel_width != 8'd3) ||
                            (kernel_height != 8'd3) ||
                            (stride_x != 8'd1) || (stride_y != 8'd1) ||
                            (output_width != input_width) ||
                            (output_height != input_height) ||
                            (output_channels != input_channels))
                            c1_validate_descriptor = C1_DESC_ERR_DWCONV_GEOMETRY;
                        else if (!flags[FLAG_SAME_REPLICATE])
                            c1_validate_descriptor = C1_DESC_ERR_DWCONV_FLAGS;
                    end

                    C1_OP_UPSAMPLE2: begin
                        if ((kernel_width != 8'd1) ||
                            (kernel_height != 8'd1) ||
                            (stride_x != 8'd2) || (stride_y != 8'd2) ||
                            ({1'b0, output_width} !=
                             ({1'b0, input_width} << 1)) ||
                            ({1'b0, output_height} !=
                             ({1'b0, input_height} << 1)) ||
                            (output_channels != input_channels))
                            c1_validate_descriptor = C1_DESC_ERR_UPSAMPLE_GEOMETRY;
                    end

                    C1_OP_RESIDUAL_ADD: begin
                        if ((kernel_width != 8'd1) ||
                            (kernel_height != 8'd1) ||
                            (stride_x != 8'd1) || (stride_y != 8'd1) ||
                            (output_width != input_width) ||
                            (output_height != input_height) ||
                            (output_channels != input_channels))
                            c1_validate_descriptor = C1_DESC_ERR_RESIDUAL_GEOMETRY;
                        else if (!flags[FLAG_RESIDUAL_VALID])
                            c1_validate_descriptor = C1_DESC_ERR_RESIDUAL_FLAGS;
                    end

                    C1_OP_OUTPUT_RGB: begin
                        if ((kernel_width != 8'd1) ||
                            (kernel_height != 8'd1) ||
                            (stride_x != 8'd1) || (stride_y != 8'd1) ||
                            (output_width != input_width) ||
                            (output_height != input_height) ||
                            (input_channels != 16'd3) ||
                            (output_channels != 16'd3))
                            c1_validate_descriptor = C1_DESC_ERR_OUTPUT_GEOMETRY;
                        else if (activation != C1_ACT_NONE)
                            c1_validate_descriptor = C1_DESC_ERR_OUTPUT_ACTIVATION;
                    end

                    default:
                        c1_validate_descriptor = C1_DESC_ERR_OPCODE;
                endcase
            end
        end
    endfunction
endpackage
