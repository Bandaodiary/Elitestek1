`timescale 1ns/1ps

module tb_c1_dot8x8_requant_core;

    localparam integer X_BITS = 10;
    localparam integer Y_BITS = 9;
    localparam integer TOTAL_CASES = 160;
`ifdef C1_PIPELINED_DOT_TREE
    localparam integer PIPELINED_DOT_TREE_CFG = 1;
`else
    localparam integer PIPELINED_DOT_TREE_CFG = 0;
`endif
`ifdef C1_PIPELINED_DOT_TREE_FULL
    localparam integer PIPELINED_DOT_TREE_FULL_CFG = 1;
`else
    localparam integer PIPELINED_DOT_TREE_FULL_CFG = 0;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [255:0] start_bias_s32 = '0;
    logic [143:0] start_mult_s18 = '0;
    logic [47:0] start_shift_u6 = '0;
    logic start_relu = 1'b0;
    logic start_sof = 1'b0;
    logic start_eol = 1'b0;
    logic start_eof = 1'b0;
    logic [X_BITS-1:0] start_x = '0;
    logic [Y_BITS-1:0] start_y = '0;

    logic in_valid = 1'b0;
    logic in_ready;
    logic in_last = 1'b0;
    logic [7:0] in_lane_mask = '0;
    logic [63:0] in_activations_s8 = '0;
    logic [511:0] in_weights_s8 = '0;

    logic out_valid;
    logic out_ready = 1'b0;
    logic [63:0] out_data_s8;
    logic out_sof;
    logic out_eol;
    logic out_eof;
    logic [X_BITS-1:0] out_x;
    logic [Y_BITS-1:0] out_y;
    logic busy;
    logic overflow_seen;

    logic signed [31:0] golden_acc [0:7];
    logic signed [17:0] golden_mult [0:7];
    logic [5:0] golden_shift [0:7];
    logic [63:0] expected_output;
    logic expected_overflow;
    logic expected_relu;
    logic expected_sof;
    logic expected_eol;
    logic expected_eof;
    logic [X_BITS-1:0] expected_x;
    logic [Y_BITS-1:0] expected_y;

    logic [31:0] stimulus_prng = 32'h2026_0824;
    logic [31:0] ready_prng = 32'h8f31_6ad7;
    integer input_hold_checks = 0;
    integer output_hold_checks = 0;
    integer output_stall_cycles = 0;
    integer source_gap_cycles = 0;
    integer tail_mask_cases = 0;
    integer full_mask_cases = 0;
    integer overflow_cases = 0;
    integer relu_cases = 0;

    logic held_start = 1'b0;
    logic [255:0] held_start_bias = '0;
    logic [143:0] held_start_mult = '0;
    logic [47:0] held_start_shift = '0;
    logic held_start_relu = 1'b0;
    logic held_input = 1'b0;
    logic held_input_last = 1'b0;
    logic [7:0] held_input_mask = '0;
    logic [63:0] held_input_activations = '0;
    logic [511:0] held_input_weights = '0;
    logic held_output = 1'b0;
    logic [63:0] held_output_data = '0;
    logic held_output_sof = 1'b0;
    logic held_output_eol = 1'b0;
    logic held_output_eof = 1'b0;
    logic [X_BITS-1:0] held_output_x = '0;
    logic [Y_BITS-1:0] held_output_y = '0;
    logic held_output_overflow = 1'b0;

    integer current_case = 0;
    integer current_k = 0;
    integer accepted_groups = 0;
    integer total_accepted_groups = 0;

    c1_dot8x8_requant_core #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE_CFG),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL_CFG)
    ) dut (
        .clk,
        .rst,
        .start_valid,
        .start_ready,
        .start_bias_s32,
        .start_mult_s18,
        .start_shift_u6,
        .start_relu,
        .start_sof,
        .start_eol,
        .start_eof,
        .start_x,
        .start_y,
        .in_valid,
        .in_ready,
        .in_last,
        .in_lane_mask,
        .in_activations_s8,
        .in_weights_s8,
        .out_valid,
        .out_ready,
        .out_data_s8,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .busy,
        .overflow_seen
    );

    function automatic [31:0] prng_next(input [31:0] state);
        reg feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    function automatic logic signed [7:0] golden_requant(
        input logic signed [31:0] accumulator,
        input logic signed [17:0] multiplier,
        input logic [5:0] shift,
        input logic relu
    );
        longint signed product;
        longint signed magnitude;
        longint signed rounded;
        longint signed saturated;
        begin
            product = $signed(accumulator) * $signed(multiplier);
            if (shift == 0) begin
                rounded = product;
            end else if (product < 0) begin
                magnitude = -product;
                rounded = -((magnitude + (64'sd1 << (shift-1))) >>> shift);
            end else begin
                rounded = (product + (64'sd1 << (shift-1))) >>> shift;
            end

            if (rounded > 127)
                saturated = 127;
            else if (rounded < -128)
                saturated = -128;
            else
                saturated = rounded;
            if (relu && (saturated < 0))
                saturated = 0;
            golden_requant = saturated[7:0];
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_DOT8X8_REQUANT_CORE_FAIL time=%0t case=%0d K=%0d groups=%0d: %s",
                     $time, current_case, current_k, accepted_groups, message);
            $fatal(1);
            $finish;
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
    end

    // Independent random result consumer.  Low acceptance probability makes
    // output payload hold behaviour observable on many transactions.
    always @(negedge clk) begin
        if (rst) begin
            ready_prng <= 32'h8f31_6ad7;
            out_ready <= 1'b0;
        end else begin
            ready_prng <= prng_next(ready_prng);
            out_ready <= ready_prng[0] && ready_prng[3];
        end
    end

    // Ready/valid stability monitors on command, input, and result channels.
    always @(posedge clk) begin
        if (rst) begin
            held_start = 1'b0;
            held_input = 1'b0;
            held_output = 1'b0;
            input_hold_checks = 0;
            output_hold_checks = 0;
            output_stall_cycles = 0;
        end else begin
            if (held_start && (!start_valid ||
                               (start_bias_s32 !== held_start_bias) ||
                               (start_mult_s18 !== held_start_mult) ||
                               (start_shift_u6 !== held_start_shift) ||
                               (start_relu !== held_start_relu)))
                fail("start payload changed while stalled");

            if (held_input) begin
                input_hold_checks = input_hold_checks + 1;
                if (!in_valid || (in_last !== held_input_last) ||
                    (in_lane_mask !== held_input_mask) ||
                    (in_activations_s8 !== held_input_activations) ||
                    (in_weights_s8 !== held_input_weights))
                    fail("input group changed while stalled");
            end

            if (held_output) begin
                output_hold_checks = output_hold_checks + 1;
                if (!out_valid || (out_data_s8 !== held_output_data) ||
                    (out_sof !== held_output_sof) ||
                    (out_eol !== held_output_eol) ||
                    (out_eof !== held_output_eof) ||
                    (out_x !== held_output_x) ||
                    (out_y !== held_output_y) ||
                    (overflow_seen !== held_output_overflow))
                    fail("result payload/status changed while stalled");
            end
            if (out_valid && !out_ready) begin
                output_stall_cycles = output_stall_cycles + 1;
                if (!busy)
                    fail("busy cleared before a stalled result was accepted");
            end

            held_start = start_valid && !start_ready;
            held_start_bias = start_bias_s32;
            held_start_mult = start_mult_s18;
            held_start_shift = start_shift_u6;
            held_start_relu = start_relu;
            held_input = in_valid && !in_ready;
            held_input_last = in_last;
            held_input_mask = in_lane_mask;
            held_input_activations = in_activations_s8;
            held_input_weights = in_weights_s8;
            held_output = out_valid && !out_ready;
            held_output_data = out_data_s8;
            held_output_sof = out_sof;
            held_output_eol = out_eol;
            held_output_eof = out_eof;
            held_output_x = out_x;
            held_output_y = out_y;
            held_output_overflow = overflow_seen;
        end
    end

    task automatic prepare_case(input integer case_index, output integer k_value);
        integer channel;
        logic signed [31:0] bias_value;
        logic signed [17:0] mult_value;
        logic [5:0] shift_value;
        begin
            case (case_index)
                0: k_value = 17;
                1: k_value = 19;
                2: k_value = 1;
                3: k_value = 8;
                4: k_value = 9;
                default: begin
                    stimulus_prng = prng_next(stimulus_prng);
                    k_value = 1 + (stimulus_prng % 73);
                end
            endcase

            expected_relu = case_index[0];
            expected_sof = (case_index == 0);
            expected_eol = ((case_index % 7) == 6);
            expected_eof = (case_index == TOTAL_CASES-1);
            expected_x = (case_index*13 + 7) & ((1 << X_BITS)-1);
            expected_y = (case_index*5 + 3) & ((1 << Y_BITS)-1);
            expected_overflow = 1'b0;

            start_bias_s32 = '0;
            start_mult_s18 = '0;
            start_shift_u6 = '0;
            for (channel = 0; channel < 8; channel = channel + 1) begin
                if (case_index == 0)
                    bias_value = 32'sh7fff_f000 + channel;
                else if (case_index == 1)
                    bias_value = 32'sh8000_1000 - channel;
                else begin
                    stimulus_prng = prng_next(stimulus_prng);
                    bias_value = $signed(stimulus_prng);
                end

                if ((case_index == 0) || (case_index == 1)) begin
                    mult_value = 18'sd1;
                    shift_value = 6'd0;
                end else begin
                    stimulus_prng = prng_next(stimulus_prng);
                    mult_value = $signed(stimulus_prng[17:0]);
                    if (mult_value == 0)
                        mult_value = 18'sd1;
                    stimulus_prng = prng_next(stimulus_prng);
                    if (((case_index + channel) % 17) == 0)
                        shift_value = 6'd47;
                    else
                        shift_value = stimulus_prng % 16;
                end

                golden_acc[channel] = bias_value;
                golden_mult[channel] = mult_value;
                golden_shift[channel] = shift_value;
                start_bias_s32[channel*32 +: 32] = bias_value;
                start_mult_s18[channel*18 +: 18] = mult_value;
                start_shift_u6[channel*6 +: 6] = shift_value;
            end
            start_relu = expected_relu;
            start_sof = expected_sof;
            start_eol = expected_eol;
            start_eof = expected_eof;
            start_x = expected_x;
            start_y = expected_y;
        end
    endtask

    task automatic prepare_group(
        input integer case_index,
        input integer group_index,
        input integer total_groups,
        input integer k_value
    );
        integer channel;
        integer lane;
        integer remaining;
        logic signed [7:0] activation_value;
        logic signed [7:0] weight_value;
        begin
            remaining = k_value - group_index*8;
            if (remaining >= 8)
                in_lane_mask = 8'hff;
            else
                in_lane_mask = (1 << remaining) - 1;
            in_last = (group_index == total_groups-1);
            in_activations_s8 = '0;
            in_weights_s8 = '0;

            for (lane = 0; lane < 8; lane = lane + 1) begin
                if (case_index == 0)
                    activation_value = 8'sd127;
                else if (case_index == 1)
                    activation_value = 8'sh80;
                else begin
                    stimulus_prng = prng_next(stimulus_prng);
                    activation_value = $signed(stimulus_prng[7:0]);
                end
                in_activations_s8[lane*8 +: 8] = activation_value;

                for (channel = 0; channel < 8; channel = channel + 1) begin
                    if ((case_index == 0) || (case_index == 1))
                        weight_value = 8'sd127;
                    else begin
                        stimulus_prng = prng_next(stimulus_prng);
                        weight_value = $signed(stimulus_prng[7:0]);
                    end
                    in_weights_s8[channel*64 + lane*8 +: 8] = weight_value;
                end
            end
        end
    endtask

    task automatic update_golden_from_group;
        integer channel;
        integer lane;
        integer signed activation_int;
        integer signed weight_int;
        integer signed dot_sum;
        longint signed extended_sum;
        begin
            for (channel = 0; channel < 8; channel = channel + 1) begin
                dot_sum = 0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (in_lane_mask[lane]) begin
                        activation_int = $signed(
                            in_activations_s8[lane*8 +: 8]);
                        weight_int = $signed(
                            in_weights_s8[channel*64 + lane*8 +: 8]);
                        dot_sum = dot_sum + activation_int*weight_int;
                    end
                end
                extended_sum = $signed(golden_acc[channel]) + dot_sum;
                if ((extended_sum > 64'sd2147483647) ||
                    (extended_sum < -64'sd2147483648))
                    expected_overflow = 1'b1;
                // Assignment truncation implements the required modulo-2**32
                // two's-complement accumulator semantics.
                golden_acc[channel] = extended_sum;
            end
        end
    endtask

    task automatic wait_input_handshake;
        logic accepted;
        begin
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (in_valid && in_ready)
                    accepted = 1'b1;
            end
            accepted_groups = accepted_groups + 1;
            total_accepted_groups = total_accepted_groups + 1;
            update_golden_from_group();
        end
    endtask

    task automatic finish_expected_output;
        integer channel;
        begin
            expected_output = '0;
            for (channel = 0; channel < 8; channel = channel + 1)
                expected_output[channel*8 +: 8] = golden_requant(
                    golden_acc[channel], golden_mult[channel],
                    golden_shift[channel], expected_relu);
        end
    endtask

    task automatic wait_and_check_output;
        logic accepted;
        logic [63:0] observed_data;
        logic observed_sof, observed_eol, observed_eof;
        logic [X_BITS-1:0] observed_x;
        logic [Y_BITS-1:0] observed_y;
        logic observed_overflow;
        begin
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (out_valid && out_ready) begin
                    observed_data = out_data_s8;
                    observed_sof = out_sof;
                    observed_eol = out_eol;
                    observed_eof = out_eof;
                    observed_x = out_x;
                    observed_y = out_y;
                    observed_overflow = overflow_seen;
                    accepted = 1'b1;
                end
            end
            if ((observed_data !== expected_output) ||
                (observed_sof !== expected_sof) ||
                (observed_eol !== expected_eol) ||
                (observed_eof !== expected_eof) ||
                (observed_x !== expected_x) ||
                (observed_y !== expected_y))
                fail("requantized output data/metadata mismatch");
            if (observed_overflow !== expected_overflow)
                fail("signed32 overflow/wrap status mismatch");
            if (observed_overflow)
                overflow_cases = overflow_cases + 1;
            if (expected_relu)
                relu_cases = relu_cases + 1;
            #0.1;
            if (busy || !start_ready)
                fail("core did not return idle after output handshake");
        end
    endtask

    initial begin
        integer groups;
        integer group_index;
        integer gap;
        logic command_accepted;

        wait (!rst);
        repeat (2) @(posedge clk);
        if (busy || !start_ready || in_ready || out_valid)
            fail("core reset/idle contract mismatch");

        for (current_case = 0; current_case < TOTAL_CASES;
             current_case = current_case + 1) begin
            prepare_case(current_case, current_k);
            groups = (current_k + 7) / 8;
            accepted_groups = 0;
            prepare_group(current_case, 0, groups, current_k);

            // Present the first input group together with start.  Input must
            // remain back-pressured until the command has been accepted and
            // its bias/config snapshot is active.
            @(negedge clk);
            start_valid = 1'b1;
            in_valid = 1'b1;
            command_accepted = 1'b0;
            while (!command_accepted) begin
                @(posedge clk);
                if (start_valid && start_ready)
                    command_accepted = 1'b1;
            end
            @(negedge clk);
            start_valid = 1'b0;
            // Prove all command fields were actually snapshotted.
            start_bias_s32 = {8{32'h5a5a_a5a5}};
            start_mult_s18 = '0;
            start_shift_u6 = {8{6'd47}};
            start_relu = ~expected_relu;
            start_sof = ~expected_sof;
            start_eol = ~expected_eol;
            start_eof = ~expected_eof;
            start_x = '1;
            start_y = '1;

            wait_input_handshake();
            @(negedge clk);
            in_valid = 1'b0;

            for (group_index = 1; group_index < groups;
                 group_index = group_index + 1) begin
                stimulus_prng = prng_next(stimulus_prng);
                gap = stimulus_prng[2:0] % 4;
                repeat (gap) begin
                    @(posedge clk);
                    source_gap_cycles = source_gap_cycles + 1;
                end
                prepare_group(current_case, group_index, groups, current_k);
                @(negedge clk);
                in_valid = 1'b1;
                wait_input_handshake();
                @(negedge clk);
                in_valid = 1'b0;
            end

            if (in_lane_mask != 8'hff)
                tail_mask_cases = tail_mask_cases + 1;
            else
                full_mask_cases = full_mask_cases + 1;
            in_last = 1'b0;
            finish_expected_output();
            wait_and_check_output();
        end

        if (total_accepted_groups == 0)
            fail("no input groups were accepted");
        if ((tail_mask_cases == 0) || (full_mask_cases == 0))
            fail("tail/full lane-mask coverage was not observed");
        if (overflow_cases < 2)
            fail("directed signed32 wrap coverage was not observed");
        if ((relu_cases == 0) || (source_gap_cycles == 0) ||
            (input_hold_checks == 0) || (output_hold_checks == 0) ||
            (output_stall_cycles == 0))
            fail("ReLU/random-gap/ready-valid stall coverage was incomplete");

        $display("C1_DOT8X8_REQUANT_CORE_PASS cases=%0d groups=%0d tail_masks=%0d full_masks=%0d overflow_cases=%0d input_hold=%0d output_hold=%0d output_stall=%0d source_gaps=%0d",
                 TOTAL_CASES, total_accepted_groups, tail_mask_cases, full_mask_cases,
                 overflow_cases, input_hold_checks, output_hold_checks,
                 output_stall_cycles, source_gap_cycles);
        $finish;
    end

    initial begin
        #5_000_000;
        fail("global timeout/deadlock");
    end

endmodule
