`timescale 1ns/1ps

// Vendor-independent R1 descriptor decoder and validator.
//
// One elastic output register bridges the scheduler's 512-bit descriptor
// stream to layer engines.  A valid descriptor is snapshotted and every ABI
// field is exposed as a named output.  Output payload remains stable while
// command_valid && !command_ready.  An invalid descriptor is consumed but is
// never presented as a command; it produces a one-cycle error_pulse with the
// first failing condition in ABI/error-priority order.
//
// Address validation is deliberately limited to facts present in the
// descriptor.  All byte offsets and nonzero row strides must be 16-byte
// aligned for the common AXI128 datapath.  Relative offsets cannot prove that
// the external arena/weight base is aligned or that an access is in range.
// Actual packed u6 shift values are not in this descriptor, so their 0..47
// check remains the responsibility of the parameter loader/requant block.
module c1_layer_command_decoder #(
    // When set, the wrapper has already validated this descriptor while it
    // was captured.  The decoder consumes the compact external result and
    // does not place the wide validation tree on the replay timing path.
    parameter integer USE_EXTERNAL_VALIDATION = 0,
    // Optional timing-oriented decision pipeline.  The input descriptor is
    // first captured without making its 512-bit register enable depend on the
    // validation tree.  Internal validation then runs from that local
    // register into a compact five-bit result register before command/error
    // publication.  It adds two clocks per descriptor but changes neither
    // validation priority nor the ready/valid contract.
    parameter integer PIPELINED_VALIDATION = 0
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          abort,

    input  logic          descriptor_valid,
    output logic          descriptor_ready,
    input  logic [511:0]  descriptor_data,

    output logic          command_valid,
    input  logic          command_ready,
    output logic [511:0]  command_descriptor,
    input  logic [4:0]    descriptor_error_override,

    output logic [7:0]    command_opcode,
    output logic [1:0]    command_activation,
    output logic [5:0]    command_flags,
    output logic [7:0]    command_version,
    output logic [7:0]    command_words,
    output logic [15:0]   command_input_width,
    output logic [15:0]   command_input_height,
    output logic [15:0]   command_output_width,
    output logic [15:0]   command_output_height,
    output logic [15:0]   command_input_channels,
    output logic [15:0]   command_output_channels,
    output logic [31:0]   command_input_offset,
    output logic [31:0]   command_output_offset,
    output logic [31:0]   command_residual_offset,
    output logic [31:0]   command_weight_offset,
    output logic [31:0]   command_bias_offset,
    output logic [31:0]   command_multiplier_offset,
    output logic [31:0]   command_shift_offset,
    output logic [31:0]   command_input_row_stride,
    output logic [31:0]   command_output_row_stride,
    output logic [7:0]    command_kernel_width,
    output logic [7:0]    command_kernel_height,
    output logic [7:0]    command_stride_x,
    output logic [7:0]    command_stride_y,
    output logic [7:0]    command_channel_block,
    output logic [7:0]    command_mac_lanes,
    output logic [7:0]    command_tile_width,
    output logic [7:0]    command_tile_height,
    output logic [31:0]   command_cycle_budget,

    output logic          error_pulse,
    output logic [4:0]    error_code
);

    import c1_descriptor_pkg::*;
    import c1_descriptor_decoder_pkg::*;

    logic [511:0] descriptor_q;
    logic [4:0] descriptor_error;
    logic [4:0] descriptor_error_q;
    logic validation_pending_q;
    logic validation_result_pending_q;

    always_comb begin
        descriptor_ready = !abort &&
                           ((PIPELINED_VALIDATION == 0) ||
                            (!validation_pending_q &&
                             !validation_result_pending_q)) &&
                           (!command_valid || command_ready);
        if (USE_EXTERNAL_VALIDATION != 0)
            descriptor_error = descriptor_error_override;
        else
            descriptor_error = c1_validate_descriptor(descriptor_data);

        command_descriptor = descriptor_q;
        command_opcode = descriptor_q[7:0];
        command_activation = descriptor_q[9:8];
        command_flags = descriptor_q[15:10];
        command_version = descriptor_q[23:16];
        command_words = descriptor_q[31:24];
        command_input_width = descriptor_q[47:32];
        command_input_height = descriptor_q[63:48];
        command_output_width = descriptor_q[79:64];
        command_output_height = descriptor_q[95:80];
        command_input_channels = descriptor_q[111:96];
        command_output_channels = descriptor_q[127:112];
        command_input_offset = descriptor_q[159:128];
        command_output_offset = descriptor_q[191:160];
        command_residual_offset = descriptor_q[223:192];
        command_weight_offset = descriptor_q[255:224];
        command_bias_offset = descriptor_q[287:256];
        command_multiplier_offset = descriptor_q[319:288];
        command_shift_offset = descriptor_q[351:320];
        command_input_row_stride = descriptor_q[383:352];
        command_output_row_stride = descriptor_q[415:384];
        command_kernel_width = descriptor_q[423:416];
        command_kernel_height = descriptor_q[431:424];
        command_stride_x = descriptor_q[439:432];
        command_stride_y = descriptor_q[447:440];
        command_channel_block = descriptor_q[455:448];
        command_mac_lanes = descriptor_q[463:456];
        command_tile_width = descriptor_q[471:464];
        command_tile_height = descriptor_q[479:472];
        command_cycle_budget = descriptor_q[511:480];
    end

    generate
        if (PIPELINED_VALIDATION != 0) begin : g_pipelined_validation
            always_ff @(posedge clk) begin
                if (rst) begin
                    descriptor_q <= '0;
                    descriptor_error_q <= C1_DESC_ERR_NONE;
                    validation_pending_q <= 1'b0;
                    validation_result_pending_q <= 1'b0;
                    command_valid <= 1'b0;
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;
                end else if (abort) begin
                    descriptor_q <= '0;
                    descriptor_error_q <= C1_DESC_ERR_NONE;
                    validation_pending_q <= 1'b0;
                    validation_result_pending_q <= 1'b0;
                    command_valid <= 1'b0;
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;
                end else begin
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;

                    if (command_valid && command_ready)
                        command_valid <= 1'b0;

                    if (validation_result_pending_q) begin
                        validation_result_pending_q <= 1'b0;
                        if (descriptor_error_q == C1_DESC_ERR_NONE)
                            command_valid <= 1'b1;
                        else begin
                            command_valid <= 1'b0;
                            error_pulse <= 1'b1;
                            error_code <= descriptor_error_q;
                        end
                    end

                    if (validation_pending_q) begin
                        descriptor_error_q <=
                            c1_validate_descriptor(descriptor_q);
                        validation_pending_q <= 1'b0;
                        validation_result_pending_q <= 1'b1;
                    end

                    if (descriptor_valid && descriptor_ready) begin
                        descriptor_q <= descriptor_data;
                        if (USE_EXTERNAL_VALIDATION != 0) begin
                            descriptor_error_q <= descriptor_error_override;
                            validation_result_pending_q <= 1'b1;
                        end else begin
                            validation_pending_q <= 1'b1;
                        end
                    end
                end
            end
        end else begin : g_direct_validation
            always_ff @(posedge clk) begin
                if (rst) begin
                    descriptor_q <= '0;
                    descriptor_error_q <= C1_DESC_ERR_NONE;
                    validation_pending_q <= 1'b0;
                    validation_result_pending_q <= 1'b0;
                    command_valid <= 1'b0;
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;
                end else if (abort) begin
                    descriptor_q <= '0;
                    descriptor_error_q <= C1_DESC_ERR_NONE;
                    validation_pending_q <= 1'b0;
                    validation_result_pending_q <= 1'b0;
                    command_valid <= 1'b0;
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;
                end else begin
                    error_pulse <= 1'b0;
                    error_code <= C1_DESC_ERR_NONE;

                    if (command_valid && command_ready)
                        command_valid <= 1'b0;

                    if (descriptor_valid && descriptor_ready) begin
                        if (descriptor_error == C1_DESC_ERR_NONE) begin
                            descriptor_q <= descriptor_data;
                            command_valid <= 1'b1;
                        end else begin
                            command_valid <= 1'b0;
                            error_pulse <= 1'b1;
                            error_code <= descriptor_error;
                        end
                    end
                end
            end
        end
    endgenerate

endmodule
