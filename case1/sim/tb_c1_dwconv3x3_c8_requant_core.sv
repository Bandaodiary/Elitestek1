`timescale 1ns/1ps

module tb_c1_dwconv3x3_c8_requant_core;

    localparam integer X_BITS = 16;
    localparam integer Y_BITS = 16;
    localparam integer MAX_EXPECTED = 512;
    localparam integer EXPECTED_JOBS = 8;
    localparam integer EXPECTED_BEATS = 280;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [575:0] start_weights_s8 = '0;
    logic [255:0] start_bias_s32 = '0;
    logic [143:0] start_mult_s18 = '0;
    logic [47:0] start_shift_u6 = '0;
    logic [15:0] start_activation = '0;

    logic in_valid = 1'b0;
    logic in_ready;
    logic [575:0] in_window_s8 = '0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;
    logic [X_BITS-1:0] in_x = '0;
    logic [Y_BITS-1:0] in_y = '0;

    logic out_valid;
    logic out_ready;
    logic [63:0] out_data_s8;
    logic out_sof;
    logic out_eol;
    logic out_eof;
    logic [X_BITS-1:0] out_x;
    logic [Y_BITS-1:0] out_y;
    logic busy;
    logic done;
    logic overflow_seen;

    logic signed [7:0] cfg_weight [0:7][0:8];
    logic signed [31:0] cfg_bias [0:7];
    logic signed [17:0] cfg_mult [0:7];
    logic [5:0] cfg_shift [0:7];
    logic [1:0] cfg_activation [0:7];

    logic [63:0] expected_data [0:MAX_EXPECTED-1];
    logic expected_sof [0:MAX_EXPECTED-1];
    logic expected_eol [0:MAX_EXPECTED-1];
    logic expected_eof [0:MAX_EXPECTED-1];
    logic [X_BITS-1:0] expected_x [0:MAX_EXPECTED-1];
    logic [Y_BITS-1:0] expected_y [0:MAX_EXPECTED-1];
    integer expected_write_index = 0;
    integer expected_read_index = 0;

    logic [31:0] stimulus_prng = 32'hc8d3_2026;
    logic [31:0] ready_prng = 32'h59a7_104d;
    logic sink_ready_random = 1'b0;
    logic force_output_block = 1'b0;
    logic current_job_overflow = 1'b0;

    logic previous_start_stall = 1'b0;
    logic [1039:0] previous_start_payload = '0;
    logic previous_input_stall = 1'b0;
    logic [610:0] previous_input_payload = '0;
    logic previous_output_stall = 1'b0;
    logic [98:0] previous_output_payload = '0;
    logic previous_eof_fire = 1'b0;
    logic previous_done = 1'b0;

    integer start_count = 0;
    integer input_count = 0;
    integer output_count = 0;
    integer done_count = 0;
    integer overflow_job_count = 0;
    integer input_stall_count = 0;
    integer output_stall_count = 0;
    integer input_hold_checks = 0;
    integer output_hold_checks = 0;
    integer start_hold_checks = 0;
    integer source_gap_count = 0;
    integer metadata_checks = 0;
    integer saturation_checks = 0;
    integer relu_zero_checks = 0;
    integer positive_input_checks = 0;
    integer negative_input_checks = 0;
    integer config_mutation_count = 0;
    integer eof_stall_count = 0;

    integer lane;
    integer tap;
    integer item;
    integer job;
    integer guard;
    integer target;
    integer pixel_count;
    integer line_width;
    logic [575:0] generated_window;

    always #5 clk = ~clk;
    assign out_ready = !force_output_block && sink_ready_random;

    c1_dwconv3x3_c8_requant_core #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) dut (.*);

    function automatic logic [31:0] prng_step(input logic [31:0] value);
        logic [31:0] work;
        begin
            work = value;
            work = work ^ (work << 13);
            work = work ^ (work >> 17);
            work = work ^ (work << 5);
            prng_step = work;
        end
    endfunction

    function automatic longint signed exact_lane_sum(
        input logic [575:0] window_bus,
        input integer lane_index
    );
        integer model_tap;
        longint signed sum_value;
        longint signed product_value;
        logic signed [7:0] activation_value;
        begin
            sum_value = cfg_bias[lane_index];
            for (model_tap = 0; model_tap < 9;
                 model_tap = model_tap + 1) begin
                activation_value =
                    window_bus[(model_tap*64) + (lane_index*8) +: 8];
                product_value = activation_value *
                                cfg_weight[lane_index][model_tap];
                sum_value = sum_value + product_value;
            end
            exact_lane_sum = sum_value;
        end
    endfunction

    function automatic logic [7:0] model_lane_output(
        input logic [575:0] window_bus,
        input integer lane_index
    );
        longint signed exact_sum;
        longint signed wrapped_acc;
        longint signed product_value;
        longint signed magnitude;
        longint signed round_bias;
        longint signed rounded_value;
        logic [31:0] wrapped_bits;
        logic [7:0] saturated;
        integer shift_value;
        begin
            exact_sum = exact_lane_sum(window_bus, lane_index);
            wrapped_bits = exact_sum[31:0];
            wrapped_acc = $signed(wrapped_bits);
            product_value = wrapped_acc * cfg_mult[lane_index];
            shift_value = cfg_shift[lane_index];

            if (shift_value == 0) begin
                rounded_value = product_value;
            end else if (product_value < 0) begin
                magnitude = -product_value;
                round_bias = 64'sd1 <<< (shift_value - 1);
                rounded_value = -((magnitude + round_bias) >>> shift_value);
            end else begin
                round_bias = 64'sd1 <<< (shift_value - 1);
                rounded_value = (product_value + round_bias) >>> shift_value;
            end

            if (rounded_value > 127)
                saturated = 8'h7f;
            else if (rounded_value < -128)
                saturated = 8'h80;
            else
                saturated = rounded_value[7:0];

            if ((cfg_activation[lane_index] == 2'd1) && saturated[7])
                model_lane_output = 8'h00;
            else
                model_lane_output = saturated;
        end
    endfunction

    task automatic pack_config;
        integer pack_lane;
        integer pack_tap;
        begin
            start_weights_s8 = '0;
            start_bias_s32 = '0;
            start_mult_s18 = '0;
            start_shift_u6 = '0;
            start_activation = '0;
            for (pack_lane = 0; pack_lane < 8;
                 pack_lane = pack_lane + 1) begin
                for (pack_tap = 0; pack_tap < 9;
                     pack_tap = pack_tap + 1)
                    start_weights_s8[
                        (pack_lane*72) + (pack_tap*8) +: 8] =
                            cfg_weight[pack_lane][pack_tap];
                start_bias_s32[pack_lane*32 +: 32] =
                    cfg_bias[pack_lane];
                start_mult_s18[pack_lane*18 +: 18] =
                    cfg_mult[pack_lane];
                start_shift_u6[pack_lane*6 +: 6] =
                    cfg_shift[pack_lane];
                start_activation[pack_lane*2 +: 2] =
                    cfg_activation[pack_lane];
            end
        end
    endtask

    task automatic configure_job(input integer job_index);
        integer config_lane;
        integer config_tap;
        logic signed [31:0] random_bias;
        logic signed [17:0] random_mult;
        begin
            current_job_overflow = 1'b0;
            for (config_lane = 0; config_lane < 8;
                 config_lane = config_lane + 1) begin
                cfg_bias[config_lane] = 32'sd0;
                cfg_mult[config_lane] = 18'sd1;
                cfg_shift[config_lane] = 6'd0;
                cfg_activation[config_lane] = 2'd0;
                for (config_tap = 0; config_tap < 9;
                     config_tap = config_tap + 1)
                    cfg_weight[config_lane][config_tap] = 8'sd0;
            end

            if (job_index == 0) begin
                cfg_weight[0][4] = 8'sd1;
                for (config_tap = 0; config_tap < 9;
                     config_tap = config_tap + 1) begin
                    cfg_weight[1][config_tap] = 8'sd1;
                    cfg_weight[2][config_tap] = -8'sd1;
                end
                cfg_weight[3][4] = 8'sd1;
                cfg_shift[3] = 6'd1;
                cfg_bias[4] = 32'sd1000;
                cfg_bias[5] = -32'sd1000;
                cfg_weight[6][4] = 8'sd1;
                cfg_bias[6] = -32'sd20;
                cfg_activation[6] = 2'd1;
                cfg_weight[7][4] = 8'sd1;
                cfg_bias[7] = 32'sh7fff_ffff;
            end else if (job_index == 1) begin
                for (config_lane = 0; config_lane < 8;
                     config_lane = config_lane + 1)
                    cfg_weight[config_lane][4] = 8'sd1;
                cfg_mult[0] = 18'sh1ffff;
                cfg_shift[0] = 6'd47;
                cfg_weight[7][4] = -8'sd1;
                cfg_bias[7] = 32'sh8000_0000;
                cfg_activation[2] = 2'd1;
            end else begin
                for (config_lane = 0; config_lane < 8;
                     config_lane = config_lane + 1) begin
                    for (config_tap = 0; config_tap < 9;
                         config_tap = config_tap + 1) begin
                        stimulus_prng = prng_step(stimulus_prng);
                        cfg_weight[config_lane][config_tap] =
                            stimulus_prng[7:0];
                    end
                    stimulus_prng = prng_step(stimulus_prng);
                    random_bias = $signed({16'd0, stimulus_prng[15:0]}) -
                                  32'sd32768;
                    cfg_bias[config_lane] = random_bias;
                    stimulus_prng = prng_step(stimulus_prng);
                    random_mult = $signed({12'd0, stimulus_prng[5:0]}) -
                                  18'sd32;
                    if (random_mult == 0)
                        random_mult = 18'sd1;
                    cfg_mult[config_lane] = random_mult;
                    stimulus_prng = prng_step(stimulus_prng);
                    cfg_shift[config_lane] = stimulus_prng[3:0];
                    cfg_activation[config_lane] =
                        stimulus_prng[4] ? 2'd1 : 2'd0;
                end
            end
            pack_config();
        end
    endtask

    task automatic generate_window(
        input integer job_index,
        input integer beat_index,
        output logic [575:0] window_bus
    );
        integer window_lane;
        integer window_tap;
        logic signed [7:0] sample_value;
        begin
            window_bus = '0;
            for (window_tap = 0; window_tap < 9;
                 window_tap = window_tap + 1) begin
                for (window_lane = 0; window_lane < 8;
                     window_lane = window_lane + 1) begin
                    if (job_index < 2) begin
                        sample_value =
                            ((beat_index*29 + window_tap*17 +
                              window_lane*41) & 8'hff);
                    end else begin
                        stimulus_prng = prng_step(stimulus_prng);
                        sample_value = stimulus_prng[7:0];
                    end
                    window_bus[(window_tap*64) +
                               (window_lane*8) +: 8] = sample_value;
                    if (sample_value < 0)
                        negative_input_checks = negative_input_checks + 1;
                    else
                        positive_input_checks = positive_input_checks + 1;
                end
            end

            if (job_index == 0) begin
                window_bus[(4*64) + (3*8) +: 8] =
                    beat_index[0] ? -8'sd3 : 8'sd3;
                window_bus[(4*64) + (6*8) +: 8] = -8'sd7;
                window_bus[(4*64) + (7*8) +: 8] = 8'sd1;
            end else if (job_index == 1) begin
                window_bus[(4*64) + (7*8) +: 8] = 8'sd1;
            end
        end
    endtask

    task automatic enqueue_expected(
        input logic [575:0] window_bus,
        input logic [X_BITS-1:0] x_value,
        input logic [Y_BITS-1:0] y_value,
        input logic sof_value,
        input logic eol_value,
        input logic eof_value
    );
        integer model_lane;
        longint signed exact_sum;
        logic [7:0] lane_result;
        begin
            if (expected_write_index >= MAX_EXPECTED)
                $fatal(1, "depthwise expected queue overflow");
            expected_data[expected_write_index] = '0;
            for (model_lane = 0; model_lane < 8;
                 model_lane = model_lane + 1) begin
                exact_sum = exact_lane_sum(window_bus, model_lane);
                if ((exact_sum > 64'sd2147483647) ||
                    (exact_sum < -64'sd2147483648))
                    current_job_overflow = 1'b1;
                lane_result = model_lane_output(window_bus, model_lane);
                expected_data[expected_write_index]
                    [model_lane*8 +: 8] = lane_result;
                if ((lane_result == 8'h7f) || (lane_result == 8'h80))
                    saturation_checks = saturation_checks + 1;
                if ((cfg_activation[model_lane] == 2'd1) &&
                    (lane_result == 8'h00))
                    relu_zero_checks = relu_zero_checks + 1;
            end
            expected_sof[expected_write_index] = sof_value;
            expected_eol[expected_write_index] = eol_value;
            expected_eof[expected_write_index] = eof_value;
            expected_x[expected_write_index] = x_value;
            expected_y[expected_write_index] = y_value;
            expected_write_index = expected_write_index + 1;
        end
    endtask

    task automatic start_job;
        integer start_target;
        begin
            start_target = start_count + 1;
            @(negedge clk);
            start_valid = 1'b1;
            guard = 0;
            while (start_count < start_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "depthwise start handshake timeout");
            end
            start_valid = 1'b0;
            if (!busy || start_ready)
                $fatal(1, "depthwise core failed to lock start config");

            // The external config bus is deliberately corrupted after the
            // handshake.  Expected data still uses cfg_* and therefore proves
            // the core uses its snapped config for the complete frame.
            start_weights_s8 = ~start_weights_s8;
            start_bias_s32 = ~start_bias_s32;
            start_mult_s18 = ~start_mult_s18;
            start_shift_u6 = '0;
            start_activation = '0;
            config_mutation_count = config_mutation_count + 1;
        end
    endtask

    task automatic send_window(
        input integer job_index,
        input integer beat_index,
        input integer frame_pixels,
        input integer frame_width,
        input integer gap_cycles
    );
        integer accept_target;
        logic [575:0] window_value;
        logic [X_BITS-1:0] x_value;
        logic [Y_BITS-1:0] y_value;
        logic sof_value, eol_value, eof_value;
        begin
            repeat (gap_cycles) begin
                @(posedge clk);
                source_gap_count = source_gap_count + 1;
            end

            generate_window(job_index, beat_index, window_value);
            x_value = beat_index % frame_width;
            y_value = beat_index / frame_width;
            sof_value = (beat_index == 0);
            eol_value = ((beat_index % frame_width) == frame_width-1);
            eof_value = (beat_index == frame_pixels-1);
            enqueue_expected(window_value, x_value, y_value,
                             sof_value, eol_value, eof_value);

            accept_target = input_count + 1;
            @(negedge clk);
            in_valid = 1'b1;
            in_window_s8 = window_value;
            in_x = x_value;
            in_y = y_value;
            in_sof = sof_value;
            in_eol = eol_value;
            in_eof = eof_value;
            guard = 0;
            while (input_count < accept_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "depthwise input handshake timeout");
            end
            in_valid = 1'b0;
            in_window_s8 = '0;
            in_x = '0;
            in_y = '0;
            in_sof = 1'b0;
            in_eol = 1'b0;
            in_eof = 1'b0;
        end
    endtask

    task automatic wait_job_done(
        input integer done_target,
        input logic expected_overflow_value
    );
        begin
            guard = 0;
            while (done_count < done_target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 4000)
                    $fatal(1, "depthwise completion timeout");
            end
            #1;
            if (busy || !start_ready ||
                (overflow_seen !== expected_overflow_value))
                $fatal(1,
                       "depthwise retirement mismatch overflow=%0d expected=%0d",
                       overflow_seen, expected_overflow_value);
            if (expected_overflow_value)
                overflow_job_count = overflow_job_count + 1;
            @(posedge clk);
            #1;
            if (done)
                $fatal(1, "depthwise done was not a one-cycle pulse");
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            ready_prng <= 32'h59a7_104d;
            sink_ready_random <= 1'b0;
        end else begin
            ready_prng <= prng_step(ready_prng);
            sink_ready_random <= ready_prng[0] || ready_prng[5];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            start_count = 0;
            input_count = 0;
            output_count = 0;
            done_count = 0;
            previous_start_stall = 1'b0;
            previous_input_stall = 1'b0;
            previous_output_stall = 1'b0;
            previous_eof_fire = 1'b0;
            previous_done = 1'b0;
            previous_start_payload = '0;
            previous_input_payload = '0;
            previous_output_payload = '0;
        end else begin
            if (previous_start_stall &&
                ({start_activation,start_shift_u6,start_mult_s18,
                  start_bias_s32,start_weights_s8} !==
                 previous_start_payload)) begin
                $fatal(1, "depthwise start config changed while stalled");
            end
            if (previous_input_stall &&
                ({in_eof,in_eol,in_sof,in_y,in_x,in_window_s8} !==
                 previous_input_payload)) begin
                $fatal(1, "depthwise input payload changed while stalled");
            end
            if (previous_output_stall &&
                ({out_eof,out_eol,out_sof,out_y,out_x,out_data_s8} !==
                 previous_output_payload)) begin
                $fatal(1, "depthwise output payload changed while stalled");
            end

            previous_start_stall = start_valid && !start_ready;
            previous_input_stall = in_valid && !in_ready;
            previous_output_stall = out_valid && !out_ready;
            previous_start_payload =
                {start_activation,start_shift_u6,start_mult_s18,
                 start_bias_s32,start_weights_s8};
            previous_input_payload =
                {in_eof,in_eol,in_sof,in_y,in_x,in_window_s8};
            previous_output_payload =
                {out_eof,out_eol,out_sof,out_y,out_x,out_data_s8};

            if (previous_start_stall)
                start_hold_checks = start_hold_checks + 1;
            if (previous_input_stall) begin
                input_stall_count = input_stall_count + 1;
                input_hold_checks = input_hold_checks + 1;
            end
            if (previous_output_stall) begin
                output_stall_count = output_stall_count + 1;
                output_hold_checks = output_hold_checks + 1;
            end

            if (start_valid && start_ready)
                start_count = start_count + 1;
            if (in_valid && in_ready)
                input_count = input_count + 1;

            if (out_valid && out_ready) begin
                if (expected_read_index >= expected_write_index)
                    $fatal(1, "unexpected depthwise output beat");
                if ((out_data_s8 !== expected_data[expected_read_index]) ||
                    (out_x !== expected_x[expected_read_index]) ||
                    (out_y !== expected_y[expected_read_index]) ||
                    ({out_sof,out_eol,out_eof} !==
                     {expected_sof[expected_read_index],
                      expected_eol[expected_read_index],
                      expected_eof[expected_read_index]})) begin
                    $fatal(1,
                           "depthwise data/metadata mismatch output=%0d got=%h expected=%h",
                           expected_read_index, out_data_s8,
                           expected_data[expected_read_index]);
                end
                expected_read_index = expected_read_index + 1;
                output_count = output_count + 1;
                metadata_checks = metadata_checks + 1;
            end

            if (done) begin
                if (!previous_eof_fire || busy)
                    $fatal(1,
                           "depthwise done did not follow accepted EOF output");
                done_count = done_count + 1;
            end
            if (done && previous_done)
                $fatal(1, "depthwise done remained asserted");
            previous_done = done;
            previous_eof_fire = out_valid && out_ready && out_eof;

            if (busy && start_ready)
                $fatal(1, "depthwise start_ready asserted while busy");
            if (!busy && in_ready)
                $fatal(1, "depthwise accepted input outside a job");
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        if (!start_ready || busy || done || overflow_seen ||
            in_ready || out_valid)
            $fatal(1, "depthwise reset state mismatch");

        // Boundary/config-lock job.  Force a long sink stall while source
        // windows continue, guaranteeing both internal and external hold.
        configure_job(0);
        start_job();
        force_output_block = 1'b1;
        fork
            begin
                repeat (18) @(posedge clk);
                @(negedge clk);
                force_output_block = 1'b0;
            end
            begin
                for (item = 0; item < 16; item = item + 1)
                    send_window(0, item, 16, 4, 0);
            end
        join
        target = done_count + 1;
        wait_job_done(target, current_job_overflow);

        // Negative signed32 overflow, maximum shift, and EOF backpressure.
        configure_job(1);
        start_job();
        for (item = 0; item < 12; item = item + 1)
            send_window(1, item, 12, 3, item % 2);
        // Drain every preceding beat first.  On the edge that consumes the
        // penultimate beat the elastic pipeline may promote EOF into the
        // output slot; fencing at the following negedge stalls EOF itself,
        // rather than an older beat in front of it.
        guard = 0;
        while (output_count < expected_write_index - 1) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 200)
                $fatal(1, "depthwise pre-EOF drain timeout");
        end
        force_output_block = 1'b1;
        guard = 0;
        while (!(out_valid && out_eof)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 100)
                $fatal(1,
                       "depthwise EOF did not reach stalled output busy=%0d done=%0d in=%0d out=%0d out_valid=%0d out_eof=%0d acc_valid=%0d rq_valid=%0d",
                       busy, done_count, input_count, output_count,
                       out_valid, out_eof, dut.acc_valid_q,
                       dut.requant_out_valid);
        end
        target = done_count;
        repeat (8) begin
            @(posedge clk);
            eof_stall_count = eof_stall_count + 1;
            #1;
            if (!busy || done || !out_valid || !out_eof ||
                (done_count != target))
                $fatal(1, "depthwise retired a stalled EOF early");
        end
        @(negedge clk);
        force_output_block = 1'b0;
        target = done_count + 1;
        wait_job_done(target, current_job_overflow);

        // Six deterministic-seed randomized jobs cover every lane/tap with
        // signed weights, signed activations, mixed shifts and per-lane ReLU.
        for (job = 2; job < EXPECTED_JOBS; job = job + 1) begin
            configure_job(job);
            start_job();
            pixel_count = 24 + job*4;
            line_width = 4;
            for (item = 0; item < pixel_count; item = item + 1) begin
                stimulus_prng = prng_step(stimulus_prng);
                send_window(job, item, pixel_count, line_width,
                            stimulus_prng[1:0]);
            end
            target = done_count + 1;
            wait_job_done(target, current_job_overflow);
        end

        repeat (6) @(posedge clk);
        if ((start_count != EXPECTED_JOBS) ||
            (done_count != EXPECTED_JOBS) ||
            (input_count != EXPECTED_BEATS) ||
            (output_count != EXPECTED_BEATS) ||
            (expected_write_index != EXPECTED_BEATS) ||
            (expected_read_index != EXPECTED_BEATS) ||
            (overflow_job_count != 2) ||
            (input_stall_count == 0) ||
            (output_stall_count == 0) ||
            (input_hold_checks == 0) ||
            (output_hold_checks == 0) ||
            (source_gap_count == 0) ||
            (metadata_checks != EXPECTED_BEATS) ||
            (saturation_checks == 0) ||
            (relu_zero_checks == 0) ||
            (positive_input_checks == 0) ||
            (negative_input_checks == 0) ||
            (config_mutation_count != EXPECTED_JOBS) ||
            (eof_stall_count != 8) || busy || done || in_ready || out_valid) begin
            $fatal(1,
                   "depthwise coverage mismatch starts=%0d done=%0d in=%0d out=%0d overflow_jobs=%0d in_stall=%0d out_stall=%0d gaps=%0d metadata=%0d sat=%0d relu0=%0d mutations=%0d eof_stall=%0d",
                   start_count, done_count, input_count, output_count,
                   overflow_job_count, input_stall_count,
                   output_stall_count, source_gap_count, metadata_checks,
                   saturation_checks, relu_zero_checks,
                   config_mutation_count, eof_stall_count);
        end

        $display("C1_DWCONV3X3_C8_REQUANT_CORE_PASS jobs=%0d beats=%0d overflow_jobs=%0d input_stalls=%0d output_stalls=%0d input_holds=%0d output_holds=%0d gaps=%0d metadata=%0d saturation=%0d relu_zero=%0d config_mutations=%0d eof_stalls=%0d",
                 start_count, output_count, overflow_job_count,
                 input_stall_count, output_stall_count,
                 input_hold_checks, output_hold_checks,
                 source_gap_count, metadata_checks, saturation_checks,
                 relu_zero_checks, config_mutation_count, eof_stall_count);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "global depthwise C8 core testbench timeout");
    end

endmodule
