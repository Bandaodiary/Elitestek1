`timescale 1ns/1ps

// MicroStyle C8 parameter/read scheduler.
//
// The descriptor ABI stores weights in signed-int8 OIHW order, bias and
// multiplier values as little-endian signed32 entries, and shifts as u8.  A
// layer start converts those byte regions into a serialized sequence of
// aligned 128-bit parameter-arena reads.  The consumer receives every word
// together with its region and region-local word index and can therefore
// build a small layer-local cache without knowing the arena layout.
//
// Only one parameter request is outstanding.  This deliberately matches the
// single portable read port in c1_r1_parameter_bank and makes abort/error
// recovery unambiguous.  param_rd_error may be returned without rd_valid, as
// specified by that bank.  No vendor primitive is used here.
module c1_r1_c8_parameter_scheduler #(
    parameter integer PARAM_ADDR_W = 11,
    parameter integer PARAM_ARENA_BYTES = 16896,
    parameter integer MAX_CHANNELS = 48,
    // Frozen MicroStyle maximum is encoder2: 12*24*3*3 = 2592 bytes.
    parameter integer MAX_WEIGHT_BYTES = 2592
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       abort,

    input  logic                       start_valid,
    output logic                       start_ready,
    input  logic [7:0]                 cfg_opcode,
    input  logic [15:0]                cfg_input_channels,
    input  logic [15:0]                cfg_output_channels,
    input  logic [31:0]                cfg_weight_offset,
    input  logic [31:0]                cfg_bias_offset,
    input  logic [31:0]                cfg_multiplier_offset,
    input  logic [31:0]                cfg_shift_offset,

    output logic                       param_rd_en,
    output logic [PARAM_ADDR_W-1:0]    param_rd_addr,
    input  logic                       param_rd_valid,
    input  logic                       param_rd_error,
    input  logic [127:0]               param_rd_data,

    output logic                       cache_write_valid,
    output logic [1:0]                 cache_write_region,
    output logic [15:0]                cache_write_word_index,
    output logic [4:0]                 cache_write_byte_count,
    output logic [127:0]               cache_write_data,

    output logic                       busy,
    output logic                       done,
    output logic                       error,
    output logic [3:0]                 error_code,
    output logic [3:0]                 input_group_count,
    output logic [3:0]                 output_group_count,
    output logic [7:0]                 input_tail_mask,
    output logic [7:0]                 output_tail_mask,
    output logic [3:0]                 kernel_taps,
    output logic [15:0]                weight_bytes
);

    localparam logic [7:0] OP_CONV3X3      = 8'd1;
    localparam logic [7:0] OP_CONV1X1      = 8'd2;
    localparam logic [7:0] OP_DWCONV3X3    = 8'd3;
    localparam logic [7:0] OP_UPSAMPLE2    = 8'd4;
    localparam logic [7:0] OP_RESIDUAL_ADD = 8'd5;
    localparam logic [7:0] OP_OUTPUT_RGB   = 8'd6;

    localparam logic [1:0] REGION_WEIGHT = 2'd0;
    localparam logic [1:0] REGION_BIAS   = 2'd1;
    localparam logic [1:0] REGION_MULT   = 2'd2;
    localparam logic [1:0] REGION_SHIFT  = 2'd3;

    localparam logic [3:0] ERR_NONE         = 4'd0;
    localparam logic [3:0] ERR_OPCODE       = 4'd1;
    localparam logic [3:0] ERR_CHANNELS     = 4'd2;
    localparam logic [3:0] ERR_DW_CHANNELS  = 4'd3;
    localparam logic [3:0] ERR_ALIGNMENT    = 4'd4;
    localparam logic [3:0] ERR_WEIGHT_SIZE  = 4'd5;
    localparam logic [3:0] ERR_ARENA_RANGE  = 4'd6;
    localparam logic [3:0] ERR_READ         = 4'd7;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_VALIDATE,
        ST_REQUEST,
        ST_WAIT,
        ST_DONE,
        ST_ERROR
    } state_t;

    state_t state_q;
    logic [1:0] region_q;
    logic [31:0] region_base_q;
    logic [31:0] region_bytes_q;
    logic [15:0] region_word_q;
    logic [15:0] region_word_count_q;
    logic [4:0] region_last_byte_count_q;
    logic region_last_word_q;
    logic config_uses_parameters_q;
    logic config_precheck_valid_q;
    logic [3:0] config_precheck_error_q;
    logic [31:0] bias_base_cfg_q;
    logic [31:0] multiplier_base_cfg_q;
    logic [31:0] shift_base_cfg_q;
    logic [31:0] affine_bytes_cfg_q;
    logic [31:0] shift_bytes_cfg_q;
    logic [3:0] input_group_count_q;
    logic [3:0] output_group_count_q;
    logic [7:0] input_tail_mask_q;
    logic [7:0] output_tail_mask_q;
    logic [3:0] kernel_taps_q;
    logic [15:0] weight_bytes_q;

    logic [31:0] weight_bytes_calc;
    logic [31:0] bias_bytes_calc;
    logic [31:0] shift_bytes_calc;
    logic config_uses_parameters;
    logic config_precheck_valid;
    logic [3:0] config_precheck_error;
    logic [3:0] in_groups_calc, out_groups_calc;
    logic [7:0] in_tail_calc, out_tail_calc;
    logic [3:0] taps_calc;
    logic [31:0] current_byte_offset;

    function automatic logic [7:0] tail_mask(
        input logic [15:0] channels
    );
        logic [3:0] remainder;
        begin
            remainder = channels[3:0] & 4'h7;
            if (remainder == 0)
                tail_mask = 8'hff;
            else
                tail_mask = (8'h01 << remainder) - 1'b1;
        end
    endfunction

    always_comb begin
        config_uses_parameters = (cfg_opcode == OP_CONV3X3) ||
                                 (cfg_opcode == OP_CONV1X1) ||
                                 (cfg_opcode == OP_DWCONV3X3);
        taps_calc = ((cfg_opcode == OP_CONV3X3) ||
                     (cfg_opcode == OP_DWCONV3X3)) ? 4'd9 : 4'd1;

        weight_bytes_calc = 32'd0;
        if (cfg_opcode == OP_CONV3X3)
            weight_bytes_calc = cfg_input_channels *
                                cfg_output_channels * 32'd9;
        else if (cfg_opcode == OP_CONV1X1)
            weight_bytes_calc = cfg_input_channels *
                                cfg_output_channels;
        else if (cfg_opcode == OP_DWCONV3X3)
            weight_bytes_calc = cfg_input_channels * 32'd9;
        bias_bytes_calc = config_uses_parameters ?
                          (cfg_output_channels * 32'd4) : 32'd0;
        shift_bytes_calc = config_uses_parameters ?
                           cfg_output_channels : 32'd0;

        in_groups_calc = (cfg_input_channels + 16'd7) >> 3;
        out_groups_calc = (cfg_output_channels + 16'd7) >> 3;
        in_tail_calc = tail_mask(cfg_input_channels);
        out_tail_calc = tail_mask(cfg_output_channels);

        // Stage one checks only fields that do not depend on the weight-size
        // multiplier.  Weight-size and arena-end validation use the captured
        // byte counts in ST_VALIDATE on the following cycle.
        config_precheck_valid = 1'b1;
        config_precheck_error = ERR_NONE;
        if ((cfg_opcode < OP_CONV3X3) || (cfg_opcode > OP_OUTPUT_RGB)) begin
            config_precheck_valid = 1'b0;
            config_precheck_error = ERR_OPCODE;
        end else if ((cfg_input_channels == 0) ||
                     (cfg_output_channels == 0) ||
                     (cfg_input_channels > MAX_CHANNELS) ||
                     (cfg_output_channels > MAX_CHANNELS)) begin
            config_precheck_valid = 1'b0;
            config_precheck_error = ERR_CHANNELS;
        end else if ((cfg_opcode == OP_DWCONV3X3) &&
                     (cfg_input_channels != cfg_output_channels)) begin
            config_precheck_valid = 1'b0;
            config_precheck_error = ERR_DW_CHANNELS;
        end else if (config_uses_parameters &&
                     ((cfg_weight_offset[3:0] != 0) ||
                      (cfg_bias_offset[3:0] != 0) ||
                      (cfg_multiplier_offset[3:0] != 0) ||
                      (cfg_shift_offset[3:0] != 0))) begin
            config_precheck_valid = 1'b0;
            config_precheck_error = ERR_ALIGNMENT;
        end

        current_byte_offset = region_base_q +
                              ({16'd0, region_word_q} << 4);
        start_ready = (state_q == ST_IDLE);
        busy = (state_q == ST_VALIDATE) ||
               (state_q == ST_REQUEST) || (state_q == ST_WAIT);
        param_rd_en = (state_q == ST_REQUEST);
        param_rd_addr = current_byte_offset[PARAM_ADDR_W+3:4];

        cache_write_valid = (state_q == ST_WAIT) && param_rd_valid;
        cache_write_region = region_q;
        cache_write_word_index = region_word_q;
        // Every non-terminal word is full.  The terminal byte count is
        // captured when the region starts, avoiding a 32-bit subtract/compare
        // on the cache-write control path for every returned parameter word.
        cache_write_byte_count = region_last_word_q ?
                                 region_last_byte_count_q : 5'd16;
        cache_write_data = param_rd_data;

        input_group_count = input_group_count_q;
        output_group_count = output_group_count_q;
        input_tail_mask = input_tail_mask_q;
        output_tail_mask = output_tail_mask_q;
        kernel_taps = kernel_taps_q;
        weight_bytes = weight_bytes_q;
    end

    task automatic begin_region(
        input logic [1:0] selected_region,
        input logic [31:0] selected_base,
        input logic [31:0] selected_bytes
    );
        begin
            region_q <= selected_region;
            region_base_q <= selected_base;
            region_bytes_q <= selected_bytes;
            region_word_q <= 16'd0;
            region_word_count_q <= (selected_bytes + 32'd15) >> 4;
            region_last_byte_count_q <=
                (selected_bytes[3:0] == 0) ?
                5'd16 : {1'b0, selected_bytes[3:0]};
            region_last_word_q <=
                (((selected_bytes + 32'd15) >> 4) == 32'd1);
            state_q <= ST_REQUEST;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            region_q <= REGION_WEIGHT;
            region_base_q <= 32'd0;
            region_bytes_q <= 32'd0;
            region_word_q <= 16'd0;
            region_word_count_q <= 16'd0;
            region_last_byte_count_q <= 5'd0;
            region_last_word_q <= 1'b0;
            config_uses_parameters_q <= 1'b0;
            config_precheck_valid_q <= 1'b0;
            config_precheck_error_q <= ERR_NONE;
            bias_base_cfg_q <= 32'd0;
            multiplier_base_cfg_q <= 32'd0;
            shift_base_cfg_q <= 32'd0;
            affine_bytes_cfg_q <= 32'd0;
            shift_bytes_cfg_q <= 32'd0;
            input_group_count_q <= 4'd0;
            output_group_count_q <= 4'd0;
            input_tail_mask_q <= 8'd0;
            output_tail_mask_q <= 8'd0;
            kernel_taps_q <= 4'd0;
            weight_bytes_q <= 16'd0;
            done <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
        end else if (abort) begin
            state_q <= ST_IDLE;
            region_q <= REGION_WEIGHT;
            region_base_q <= 32'd0;
            region_bytes_q <= 32'd0;
            region_word_q <= 16'd0;
            region_word_count_q <= 16'd0;
            region_last_byte_count_q <= 5'd0;
            region_last_word_q <= 1'b0;
            config_uses_parameters_q <= 1'b0;
            config_precheck_valid_q <= 1'b0;
            config_precheck_error_q <= ERR_NONE;
            bias_base_cfg_q <= 32'd0;
            multiplier_base_cfg_q <= 32'd0;
            shift_base_cfg_q <= 32'd0;
            affine_bytes_cfg_q <= 32'd0;
            shift_bytes_cfg_q <= 32'd0;
            input_group_count_q <= 4'd0;
            output_group_count_q <= 4'd0;
            input_tail_mask_q <= 8'd0;
            output_tail_mask_q <= 8'd0;
            kernel_taps_q <= 4'd0;
            weight_bytes_q <= 16'd0;
            done <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
        end else begin
            done <= 1'b0;
            error <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_valid) begin
                        // Stage one captures the multiplier result, the cheap
                        // precheck and every value needed after the handshake.
                        // ST_VALIDATE performs size/range checks from these
                        // registers one cycle later, splitting the DSP from the
                        // error/control cone and making cfg_* free to change.
                        region_q <= REGION_WEIGHT;
                        region_base_q <= cfg_weight_offset;
                        region_bytes_q <= weight_bytes_calc;
                        region_word_q <= 16'd0;
                        region_word_count_q <=
                            (weight_bytes_calc + 32'd15) >> 4;
                        region_last_byte_count_q <=
                            (weight_bytes_calc[3:0] == 0) ?
                            5'd16 : {1'b0, weight_bytes_calc[3:0]};
                        region_last_word_q <= 1'b0;
                        config_uses_parameters_q <= config_uses_parameters;
                        config_precheck_valid_q <= config_precheck_valid;
                        config_precheck_error_q <= config_precheck_error;
                        bias_base_cfg_q <= cfg_bias_offset;
                        multiplier_base_cfg_q <= cfg_multiplier_offset;
                        shift_base_cfg_q <= cfg_shift_offset;
                        affine_bytes_cfg_q <= bias_bytes_calc;
                        shift_bytes_cfg_q <= shift_bytes_calc;
                        input_group_count_q <= in_groups_calc;
                        output_group_count_q <= out_groups_calc;
                        input_tail_mask_q <= in_tail_calc;
                        output_tail_mask_q <= out_tail_calc;
                        kernel_taps_q <= taps_calc;
                        weight_bytes_q <= weight_bytes_calc[15:0];
                        error_code <= ERR_NONE;
                        state_q <= ST_VALIDATE;
                    end
                end

                ST_VALIDATE: begin
                    if (!config_precheck_valid_q) begin
                        error <= 1'b1;
                        error_code <= config_precheck_error_q;
                        state_q <= ST_ERROR;
                    end else if (region_bytes_q > MAX_WEIGHT_BYTES) begin
                        error <= 1'b1;
                        error_code <= ERR_WEIGHT_SIZE;
                        state_q <= ST_ERROR;
                    end else if (config_uses_parameters_q &&
                                 (({1'b0, region_base_q} +
                                   {1'b0, region_bytes_q} > PARAM_ARENA_BYTES) ||
                                  ({1'b0, bias_base_cfg_q} +
                                   {1'b0, affine_bytes_cfg_q} > PARAM_ARENA_BYTES) ||
                                  ({1'b0, multiplier_base_cfg_q} +
                                   {1'b0, affine_bytes_cfg_q} > PARAM_ARENA_BYTES) ||
                                  ({1'b0, shift_base_cfg_q} +
                                   {1'b0, shift_bytes_cfg_q} > PARAM_ARENA_BYTES))) begin
                        error <= 1'b1;
                        error_code <= ERR_ARENA_RANGE;
                        state_q <= ST_ERROR;
                    end else if (!config_uses_parameters_q) begin
                        state_q <= ST_DONE;
                    end else begin
                        region_last_word_q <=
                            (region_word_count_q == 16'd1);
                        state_q <= ST_REQUEST;
                    end
                end

                ST_REQUEST: begin
                    // The bank has no request-ready signal.  One assertion of
                    // rd_en is therefore one accepted request.
                    state_q <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (param_rd_error) begin
                        error <= 1'b1;
                        error_code <= ERR_READ;
                        state_q <= ST_ERROR;
                    end else if (param_rd_valid) begin
                        if (!region_last_word_q) begin
                            region_word_q <= region_word_q + 1'b1;
                            // Register whether the *next* request is terminal.
                            // The 16-bit count comparison now ends here rather
                            // than continuing through cache-write/affine logic
                            // on the following response cycle.
                            region_last_word_q <=
                                ({1'b0, region_word_q} + 17'd2 >=
                                 {1'b0, region_word_count_q});
                            state_q <= ST_REQUEST;
                        end else begin
                            case (region_q)
                                REGION_WEIGHT:
                                    begin_region(REGION_BIAS,
                                                 bias_base_cfg_q,
                                                 affine_bytes_cfg_q);
                                REGION_BIAS:
                                    begin_region(REGION_MULT,
                                                 multiplier_base_cfg_q,
                                                 affine_bytes_cfg_q);
                                REGION_MULT:
                                    begin_region(REGION_SHIFT,
                                                 shift_base_cfg_q,
                                                 shift_bytes_cfg_q);
                                default:
                                    state_q <= ST_DONE;
                            endcase
                        end
                    end
                end

                ST_DONE: begin
                    done <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: begin
                    // ST_ERROR is sticky until abort.  This avoids accepting a
                    // new layer after a potentially torn parameter snapshot.
                    state_q <= ST_ERROR;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (PARAM_ARENA_BYTES <= 0 || (PARAM_ARENA_BYTES % 16) != 0)
            $fatal(1, "PARAM_ARENA_BYTES must be positive and 16-byte aligned");
        if (MAX_CHANNELS < 8 || MAX_CHANNELS > 120)
            $fatal(1, "MAX_CHANNELS must be in 8..120");
        if (MAX_WEIGHT_BYTES <= 0)
            $fatal(1, "MAX_WEIGHT_BYTES must be positive");
    end

    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (param_rd_valid && (state_q != ST_WAIT))
                $fatal(1, "parameter response arrived without an outstanding read");
            if (cache_write_valid && (cache_write_byte_count == 0))
                $fatal(1, "parameter scheduler emitted an empty cache write");
        end
    end
`endif

endmodule
