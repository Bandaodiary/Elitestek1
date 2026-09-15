`timescale 1ns/1ps

module tb_c1_layer_command_decoder;
    import c1_descriptor_pkg::*;
    import c1_descriptor_decoder_pkg::*;

    localparam integer TOTAL_VECTORS = 429;
    localparam integer DIRECTED_PREFIX = 29;
`ifdef C1_USE_EXTERNAL_VALIDATION
    localparam integer USE_EXTERNAL_VALIDATION_CFG = 1;
`else
    localparam integer USE_EXTERNAL_VALIDATION_CFG = 0;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;
    logic descriptor_valid = 1'b0;
    logic descriptor_ready;
    logic [511:0] descriptor_data = '0;
    logic command_valid;
    logic command_ready = 1'b0;
    logic [511:0] command_descriptor;
    logic [4:0] descriptor_error_override = '0;
    logic [7:0] command_opcode;
    logic [1:0] command_activation;
    logic [5:0] command_flags;
    logic [7:0] command_version;
    logic [7:0] command_words;
    logic [15:0] command_input_width;
    logic [15:0] command_input_height;
    logic [15:0] command_output_width;
    logic [15:0] command_output_height;
    logic [15:0] command_input_channels;
    logic [15:0] command_output_channels;
    logic [31:0] command_input_offset;
    logic [31:0] command_output_offset;
    logic [31:0] command_residual_offset;
    logic [31:0] command_weight_offset;
    logic [31:0] command_bias_offset;
    logic [31:0] command_multiplier_offset;
    logic [31:0] command_shift_offset;
    logic [31:0] command_input_row_stride;
    logic [31:0] command_output_row_stride;
    logic [7:0] command_kernel_width;
    logic [7:0] command_kernel_height;
    logic [7:0] command_stride_x;
    logic [7:0] command_stride_y;
    logic [7:0] command_channel_block;
    logic [7:0] command_mac_lanes;
    logic [7:0] command_tile_width;
    logic [7:0] command_tile_height;
    logic [31:0] command_cycle_budget;
    logic error_pulse;
    logic [4:0] error_code;

    logic [519:0] vectors [0:TOTAL_VECTORS-1];
    logic [511:0] decoded_view;
    logic [31:0] stimulus_prng = 32'h2026_0824;
    logic [7:0] legal_opcode_seen = '0;
    logic [31:0] error_codes_seen = '0;
    integer current_vector = -1;
    integer valid_commands = 0;
    integer error_events = 0;
    integer random_valid = 0;
    integer random_invalid = 0;
    integer input_hold_checks = 0;
    integer output_hold_checks = 0;
    integer output_stall_cycles = 0;
    integer abort_checks = 0;
    integer restart_checks = 0;
    integer replacement_checks = 0;

    logic held_input = 1'b0;
    logic [511:0] held_input_data = '0;
    logic held_output = 1'b0;
    logic [511:0] held_output_data = '0;
    logic [511:0] held_decoded_view = '0;

    c1_layer_command_decoder #(
        .USE_EXTERNAL_VALIDATION(USE_EXTERNAL_VALIDATION_CFG)
    ) dut (.*);

    always #5 clk = ~clk;

    always_comb begin
        // The named decoded fields must losslessly reconstruct all 16 words.
        decoded_view = {
            command_cycle_budget,
            command_tile_height, command_tile_width,
            command_mac_lanes, command_channel_block,
            command_stride_y, command_stride_x,
            command_kernel_height, command_kernel_width,
            command_output_row_stride, command_input_row_stride,
            command_shift_offset, command_multiplier_offset,
            command_bias_offset, command_weight_offset,
            command_residual_offset, command_output_offset,
            command_input_offset,
            command_output_channels, command_input_channels,
            command_output_height, command_output_width,
            command_input_height, command_input_width,
            command_words, command_version, command_flags,
            command_activation, command_opcode
        };
    end

    function automatic [31:0] prng_next(input [31:0] state);
        logic feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_LAYER_COMMAND_DECODER_FAIL time=%0t vector=%0d: %s",
                     $time, current_vector, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic check_payload(input logic [511:0] expected);
        begin
            if (!command_valid)
                fail("expected decoded command is not valid");
            if (command_descriptor !== expected)
                fail("raw descriptor snapshot mismatch");
            if (decoded_view !== expected)
                fail("one or more named decoded fields mismatch");
            if (error_pulse || (error_code != C1_DESC_ERR_NONE))
                fail("valid command incorrectly reported an error");
        end
    endtask

    task automatic submit_and_check(
        input logic [511:0] descriptor,
        input logic [4:0] expected_error,
        input integer stall_cycles
    );
        logic accepted;
        begin
            @(negedge clk);
            command_ready = 1'b0;
            descriptor_data = descriptor;
            descriptor_error_override = expected_error;
            descriptor_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (descriptor_valid && descriptor_ready)
                    accepted = 1'b1;
            end
            #1;

            if (expected_error != C1_DESC_ERR_NONE) begin
                if (command_valid)
                    fail("invalid descriptor produced a command");
                if (!error_pulse || (error_code !== expected_error))
                    fail("invalid descriptor error code mismatch");
                error_events = error_events + 1;
                error_codes_seen[expected_error] = 1'b1;
                @(negedge clk);
                descriptor_valid = 1'b0;
                @(posedge clk);
                #1;
                if (error_pulse || (error_code != C1_DESC_ERR_NONE))
                    fail("error pulse/code did not clear after one cycle");
            end else begin
                check_payload(descriptor);
                valid_commands = valid_commands + 1;
                legal_opcode_seen[descriptor[7:0]] = 1'b1;
                @(negedge clk);
                descriptor_valid = 1'b0;
                repeat (stall_cycles) begin
                    @(posedge clk);
                    #1;
                    check_payload(descriptor);
                end
                @(negedge clk);
                command_ready = 1'b1;
                @(posedge clk);
                if (!(command_valid && command_ready))
                    fail("expected command handshake did not occur");
                #1;
                if (command_valid)
                    fail("command_valid did not clear after handshake");
                @(negedge clk);
                command_ready = 1'b0;
            end
        end
    endtask

    // Check input holding while blocked and simultaneous output-consume/input-
    // replace behaviour of the one-entry elastic register.
    task automatic check_elastic_replacement;
        logic [511:0] first_descriptor;
        logic [511:0] second_descriptor;
        begin
            current_vector = -2;
            first_descriptor = vectors[0][511:0];
            second_descriptor = vectors[1][511:0];
            @(negedge clk);
            command_ready = 1'b0;
            descriptor_data = first_descriptor;
            descriptor_valid = 1'b1;
            @(posedge clk);
            if (!(descriptor_valid && descriptor_ready))
                fail("first elastic-test descriptor was not accepted");
            #1;
            check_payload(first_descriptor);

            @(negedge clk);
            descriptor_data = second_descriptor;
            repeat (4) begin
                @(posedge clk);
                #1;
                if (descriptor_ready)
                    fail("input was not back-pressured by a stalled command");
                check_payload(first_descriptor);
            end

            @(negedge clk);
            command_ready = 1'b1;
            @(posedge clk);
            if (!(command_valid && command_ready &&
                  descriptor_valid && descriptor_ready))
                fail("elastic consume/replace handshakes were not simultaneous");
            #1;
            check_payload(second_descriptor);
            replacement_checks = replacement_checks + 1;

            @(negedge clk);
            descriptor_valid = 1'b0;
            command_ready = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            command_ready = 1'b1;
            @(posedge clk);
            if (!(command_valid && command_ready))
                fail("replacement command was not accepted by sink");
            #1;
            if (command_valid)
                fail("replacement command did not retire");
            @(negedge clk);
            command_ready = 1'b0;
        end
    endtask

    task automatic check_abort_and_restart;
        logic [511:0] descriptor;
        begin
            current_vector = -3;
            descriptor = vectors[2][511:0];
            @(negedge clk);
            descriptor_data = descriptor;
            descriptor_valid = 1'b1;
            command_ready = 1'b0;
            @(posedge clk);
            if (!(descriptor_valid && descriptor_ready))
                fail("abort-test descriptor was not accepted");
            #1;
            check_payload(descriptor);
            @(negedge clk);
            descriptor_valid = 1'b0;
            repeat (2) @(posedge clk);

            @(negedge clk);
            abort = 1'b1;
            #1;
            if (descriptor_ready)
                fail("descriptor_ready remained asserted during abort");
            @(posedge clk);
            #1;
            if (command_valid || error_pulse ||
                (error_code != C1_DESC_ERR_NONE) ||
                (command_descriptor != 0))
                fail("abort did not clear command/error state");
            abort_checks = abort_checks + 1;
            @(negedge clk);
            abort = 1'b0;

            submit_and_check(vectors[3][511:0], C1_DESC_ERR_NONE, 2);
            restart_checks = restart_checks + 1;
        end
    endtask

    // Protocol monitors run independently from the transaction tasks.
    always @(posedge clk) begin
        if (rst) begin
            held_input = 1'b0;
            held_output = 1'b0;
        end else begin
            if (held_input) begin
                input_hold_checks = input_hold_checks + 1;
                if (!descriptor_valid ||
                    (descriptor_data !== held_input_data))
                    fail("descriptor payload changed while input was stalled");
            end
            if (held_output) begin
                output_hold_checks = output_hold_checks + 1;
                if (!command_valid ||
                    (command_descriptor !== held_output_data) ||
                    (decoded_view !== held_decoded_view))
                    fail("decoded command changed while output was stalled");
            end
            if (command_valid && !command_ready && !abort)
                output_stall_cycles = output_stall_cycles + 1;
            if (command_valid && (decoded_view !== command_descriptor))
                fail("decoded fields do not reconstruct descriptor");
            if (command_valid && error_pulse)
                fail("command_valid and error_pulse asserted together");

            held_input = descriptor_valid && !descriptor_ready && !abort;
            held_input_data = descriptor_data;
            held_output = command_valid && !command_ready && !abort;
            held_output_data = command_descriptor;
            held_decoded_view = decoded_view;
        end
    end

    initial begin
        integer vector_index;
        integer stall_cycles;
        logic [4:0] expected_error;
        logic [511:0] descriptor;

        $readmemh("descriptor_decoder_vectors.mem", vectors);
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!descriptor_ready || command_valid || error_pulse ||
            (error_code != C1_DESC_ERR_NONE))
            fail("reset/idle contract mismatch");

        check_elastic_replacement();
        check_abort_and_restart();

        for (vector_index = 0; vector_index < TOTAL_VECTORS;
             vector_index = vector_index + 1) begin
            current_vector = vector_index;
            if ((^vectors[vector_index]) === 1'bx)
                fail("vector memory contains X/uninitialized data");
            expected_error = vectors[vector_index][516:512];
            descriptor = vectors[vector_index][511:0];
            stimulus_prng = prng_next(stimulus_prng);
            stall_cycles = stimulus_prng[2:0] % 6;
            submit_and_check(descriptor, expected_error, stall_cycles);
            if (vector_index >= DIRECTED_PREFIX) begin
                if (expected_error == C1_DESC_ERR_NONE)
                    random_valid = random_valid + 1;
                else
                    random_invalid = random_invalid + 1;
            end
        end

        if ((legal_opcode_seen & 8'h7e) != 8'h7e)
            fail("not every legal opcode produced a command");
        if ((error_codes_seen & 32'h00ff_fffe) != 32'h00ff_fffe)
            fail("not every validator error code was observed");
        if ((random_valid == 0) || (random_invalid == 0))
            fail("random bit flips did not cover valid and invalid outcomes");
        if ((input_hold_checks == 0) || (output_hold_checks == 0) ||
            (output_stall_cycles == 0) || (abort_checks != 1) ||
            (restart_checks != 1) || (replacement_checks != 1))
            fail("stall/abort/restart/replacement coverage incomplete");

        $display("C1_LAYER_COMMAND_DECODER_PASS vectors=%0d valid=%0d errors=%0d random_valid=%0d random_invalid=%0d input_hold=%0d output_hold=%0d output_stall=%0d",
                 TOTAL_VECTORS, valid_commands, error_events,
                 random_valid, random_invalid, input_hold_checks,
                 output_hold_checks, output_stall_cycles);
        $finish;
    end

    initial begin
        #5_000_000;
        fail("global timeout/deadlock");
    end

endmodule
