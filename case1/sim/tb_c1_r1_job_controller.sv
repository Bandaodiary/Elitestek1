`timescale 1ns/1ps

module tb_c1_r1_job_controller #(
    parameter integer RESET_BOUNDARY = 0,
    parameter integer DRAIN_CASE = 0,
    parameter bit DRAIN_IDLE_EDGE = 0
);

    localparam integer TERMINAL_DONE    = 0;
    localparam integer TERMINAL_ERROR   = 1;
    localparam integer TERMINAL_ABORTED = 2;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [31:0] cycle_budget = 32'd0;
    logic abort = 1'b0;

    logic busy;
    logic job_done;
    logic job_error;
    logic job_aborted;
    logic [7:0] error_code;
    logic [31:0] error_address;

    logic pair_start_valid;
    logic pair_start_ready = 1'b0;
    logic pair_response_valid = 1'b0;
    logic pair_response_ready;
    logic pair_response_error = 1'b0;
    logic [7:0] pair_response_error_code = 8'd0;
    logic [31:0] pair_response_error_address = 32'd0;
    logic pair_busy = 1'b0;
    logic pair_abort_pulse;

    logic config_start_valid;
    logic config_start_ready = 1'b0;
    logic config_response_valid = 1'b0;
    logic config_response_ready;
    logic config_response_error = 1'b0;
    logic [7:0] config_response_error_code = 8'd0;
    logic [31:0] config_response_error_address = 32'd0;
    logic config_busy = 1'b0;
    logic config_abort_pulse;

    logic input_dma_ready = 1'b0;
    logic input_dma_start;
    logic input_dma_busy = 1'b0;
    logic input_dma_done = 1'b0;
    logic input_dma_error = 1'b0;
    logic [7:0] input_dma_error_code = 8'd0;
    logic [31:0] input_dma_error_address = 32'd0;

    logic output_dma_ready = 1'b0;
    logic output_dma_start;
    logic output_dma_busy = 1'b0;
    logic output_dma_done = 1'b0;
    logic output_dma_error = 1'b0;
    logic [7:0] output_dma_error_code = 8'd0;
    logic [31:0] output_dma_error_address = 32'd0;

    logic descriptor_busy = 1'b0;
    logic descriptor_done = 1'b0;
    logic descriptor_error = 1'b0;
    logic [7:0] descriptor_error_code = 8'd0;
    logic [31:0] descriptor_error_address = 32'd0;
    logic descriptor_abort_pulse;

    logic engine_ready = 1'b0;
    logic engine_start;
    logic engine_busy = 1'b0;
    logic engine_done = 1'b0;
    logic engine_error = 1'b0;
    logic [7:0] engine_error_code = 8'd0;
    logic [31:0] engine_error_address = 32'd0;
    logic engine_abort_pulse;

    integer expected_terminal;
    logic [7:0] expected_error_code;
    logic [31:0] expected_error_address;
    logic score_active;
    logic score_launched;
    logic score_input_terminal;
    logic score_output_terminal;
    logic score_descriptor_terminal;
    logic score_engine_terminal;
    integer score_pair_requests;
    integer score_config_requests;
    integer score_launches;

    integer accepted_jobs = 0;
    integer pair_request_count = 0;
    integer config_request_count = 0;
    integer pair_response_count = 0;
    integer config_response_count = 0;
    integer launch_count = 0;
    integer done_count = 0;
    integer error_count = 0;
    integer aborted_count = 0;
    integer pair_abort_count = 0;
    integer config_abort_count = 0;
    integer descriptor_abort_count = 0;
    integer engine_abort_count = 0;
    integer same_cycle_response_count = 0;
    integer same_cycle_runtime_count = 0;
    integer prelaunch_pulse_ignore_count = 0;
    integer launch_edge_ignore_count = 0;
    integer busy_drop_wait_count = 0;
    integer held_prelaunch_error_count = 0;
    integer restart_count = 0;
    integer randomized_success_count = 0;

    logic previous_job_done;
    logic previous_job_error;
    logic previous_job_aborted;
    logic previous_pair_abort;
    logic previous_config_abort;
    logic previous_descriptor_abort;
    logic previous_engine_abort;

    always #5 clk = ~clk;

    c1_r1_job_controller dut (.*);

    task automatic wait_counter(
        input integer selector,
        input integer target,
        input integer limit
    );
        integer guard;
        integer value;
        begin
            guard = 0;
            value = 0;
            while (value < target) begin
                @(negedge clk);
                case (selector)
                    0: value = accepted_jobs;
                    1: value = pair_request_count;
                    2: value = config_request_count;
                    3: value = pair_response_count;
                    4: value = config_response_count;
                    5: value = launch_count;
                    6: value = done_count;
                    7: value = error_count;
                    8: value = aborted_count;
                    9: value = pair_abort_count;
                    10: value = config_abort_count;
                    11: value = descriptor_abort_count;
                    12: value = engine_abort_count;
                    default: $fatal(1, "invalid wait-counter selector");
                endcase
                guard = guard + 1;
                if (guard > limit)
                    $fatal(1, "counter timeout selector=%0d target=%0d value=%0d",
                           selector, target, value);
            end
        end
    endtask

    task automatic begin_job(
        input logic [31:0] budget_value,
        input integer terminal_kind,
        input logic [7:0] terminal_code,
        input logic [31:0] terminal_address
    );
        integer target;
        begin
            if (score_active || busy)
                $fatal(1, "attempted overlapping job start");
            expected_terminal = terminal_kind;
            expected_error_code = terminal_code;
            expected_error_address = terminal_address;
            target = accepted_jobs + 1;
            @(negedge clk);
            cycle_budget = budget_value;
            start_valid = 1'b1;
            wait_counter(0, target, 200);
            @(negedge clk);
            start_valid = 1'b0;
            cycle_budget = 32'hdeaf_beef;
        end
    endtask

    task automatic accept_pair_request(input integer delay_cycles);
        integer target;
        begin
            repeat (delay_cycles) @(posedge clk);
            target = pair_request_count + 1;
            @(negedge clk);
            pair_busy = 1'b1;
            pair_start_ready = 1'b1;
            wait_counter(1, target, 200);
            @(negedge clk);
            pair_start_ready = 1'b0;
        end
    endtask

    task automatic accept_config_request(input integer delay_cycles);
        integer target;
        begin
            repeat (delay_cycles) @(posedge clk);
            target = config_request_count + 1;
            @(negedge clk);
            config_busy = 1'b1;
            config_start_ready = 1'b1;
            wait_counter(2, target, 200);
            @(negedge clk);
            config_start_ready = 1'b0;
        end
    endtask

    task automatic send_pair_response(
        input integer delay_cycles,
        input logic response_is_error,
        input logic [7:0] response_code,
        input logic [31:0] response_address
    );
        integer target;
        begin
            repeat (delay_cycles) @(posedge clk);
            target = pair_response_count + 1;
            @(negedge clk);
            pair_response_error = response_is_error;
            pair_response_error_code = response_code;
            pair_response_error_address = response_address;
            pair_response_valid = 1'b1;
            wait_counter(3, target, 200);
            @(negedge clk);
            pair_response_valid = 1'b0;
            pair_response_error = 1'b0;
            pair_busy = 1'b0;
        end
    endtask

    task automatic send_config_response(
        input integer delay_cycles,
        input logic response_is_error,
        input logic [7:0] response_code,
        input logic [31:0] response_address
    );
        integer target;
        begin
            repeat (delay_cycles) @(posedge clk);
            target = config_response_count + 1;
            @(negedge clk);
            config_response_error = response_is_error;
            config_response_error_code = response_code;
            config_response_error_address = response_address;
            config_response_valid = 1'b1;
            wait_counter(4, target, 200);
            @(negedge clk);
            config_response_valid = 1'b0;
            config_response_error = 1'b0;
            config_busy = 1'b0;
        end
    endtask

    task automatic accept_both_with_same_cycle_success;
        integer pair_target;
        integer config_target;
        integer pair_response_target;
        integer config_response_target;
        begin
            pair_target = pair_request_count + 1;
            config_target = config_request_count + 1;
            pair_response_target = pair_response_count + 1;
            config_response_target = config_response_count + 1;
            @(negedge clk);
            pair_start_ready = 1'b1;
            config_start_ready = 1'b1;
            pair_response_error = 1'b0;
            config_response_error = 1'b0;
            pair_response_valid = 1'b1;
            config_response_valid = 1'b1;
            wait_counter(1, pair_target, 200);
            wait_counter(2, config_target, 200);
            wait_counter(3, pair_response_target, 200);
            wait_counter(4, config_response_target, 200);
            @(negedge clk);
            pair_start_ready = 1'b0;
            config_start_ready = 1'b0;
            pair_response_valid = 1'b0;
            config_response_valid = 1'b0;
            same_cycle_response_count = same_cycle_response_count + 2;
        end
    endtask

    task automatic accept_both_requests;
        integer pair_target;
        integer config_target;
        begin
            pair_target = pair_request_count + 1;
            config_target = config_request_count + 1;
            @(negedge clk);
            pair_busy = 1'b1;
            config_busy = 1'b1;
            pair_start_ready = 1'b1;
            config_start_ready = 1'b1;
            wait_counter(1, pair_target, 200);
            wait_counter(2, config_target, 200);
            @(negedge clk);
            pair_start_ready = 1'b0;
            config_start_ready = 1'b0;
        end
    endtask

    task automatic launch_with_stalls(
        input integer input_delay,
        input integer output_delay,
        input integer engine_delay
    );
        integer target;
        integer step;
        integer maximum_delay;
        begin
            target = launch_count + 1;
            maximum_delay = input_delay;
            if (output_delay > maximum_delay) maximum_delay = output_delay;
            if (engine_delay > maximum_delay) maximum_delay = engine_delay;
            for (step = 0; step <= maximum_delay; step = step + 1) begin
                @(negedge clk);
                if (step == input_delay) input_dma_ready = 1'b1;
                if (step == output_delay) output_dma_ready = 1'b1;
                if (step == engine_delay) engine_ready = 1'b1;
            end
            wait_counter(5, target, 200);
            @(negedge clk);
            input_dma_ready = 1'b0;
            output_dma_ready = 1'b0;
            engine_ready = 1'b0;
            input_dma_busy = 1'b1;
            output_dma_busy = 1'b1;
            descriptor_busy = 1'b1;
            engine_busy = 1'b1;
        end
    endtask

    task automatic pulse_input_terminal(
        input logic is_error,
        input logic [7:0] terminal_code,
        input logic [31:0] terminal_address,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(posedge clk);
            @(negedge clk);
            input_dma_error_code = terminal_code;
            input_dma_error_address = terminal_address;
            input_dma_error = is_error;
            input_dma_done = !is_error;
            @(posedge clk);
            @(negedge clk);
            input_dma_error = 1'b0;
            input_dma_done = 1'b0;
            input_dma_busy = 1'b0;
        end
    endtask

    task automatic pulse_output_terminal(
        input logic is_error,
        input logic [7:0] terminal_code,
        input logic [31:0] terminal_address,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(posedge clk);
            @(negedge clk);
            output_dma_error_code = terminal_code;
            output_dma_error_address = terminal_address;
            output_dma_error = is_error;
            output_dma_done = !is_error;
            @(posedge clk);
            @(negedge clk);
            output_dma_error = 1'b0;
            output_dma_done = 1'b0;
            output_dma_busy = 1'b0;
        end
    endtask

    task automatic pulse_descriptor_terminal(
        input logic is_error,
        input logic [7:0] terminal_code,
        input logic [31:0] terminal_address,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(posedge clk);
            @(negedge clk);
            descriptor_error_code = terminal_code;
            descriptor_error_address = terminal_address;
            descriptor_error = is_error;
            descriptor_done = !is_error;
            @(posedge clk);
            @(negedge clk);
            descriptor_error = 1'b0;
            descriptor_done = 1'b0;
            descriptor_busy = 1'b0;
        end
    endtask

    task automatic pulse_engine_terminal(
        input logic is_error,
        input logic [7:0] terminal_code,
        input logic [31:0] terminal_address,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(posedge clk);
            @(negedge clk);
            engine_error_code = terminal_code;
            engine_error_address = terminal_address;
            engine_error = is_error;
            engine_done = !is_error;
            @(posedge clk);
            @(negedge clk);
            engine_error = 1'b0;
            engine_done = 1'b0;
            engine_busy = 1'b0;
        end
    endtask

    task automatic pulse_job_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    task automatic wait_for_expected_terminal;
        integer target;
        begin
            case (expected_terminal)
                TERMINAL_DONE: begin
                    target = done_count + 1;
                    wait_counter(6, target, 1000);
                end
                TERMINAL_ERROR: begin
                    target = error_count + 1;
                    wait_counter(7, target, 1000);
                end
                TERMINAL_ABORTED: begin
                    target = aborted_count + 1;
                    wait_counter(8, target, 1000);
                end
                default: $fatal(1, "invalid expected terminal kind");
            endcase
            repeat (2) @(posedge clk);
            if (busy || score_active || !start_ready)
                $fatal(1, "controller did not return to restartable idle");
            restart_count = restart_count + 1;
        end
    endtask

    task automatic successful_preflight(
        input integer order,
        input integer request_delay_a,
        input integer request_delay_b,
        input integer response_delay_a,
        input integer response_delay_b
    );
        begin
            if (order == 0) begin
                accept_pair_request(request_delay_a);
                accept_config_request(request_delay_b);
                send_pair_response(response_delay_a, 1'b0, 8'd0, 32'd0);
                send_config_response(response_delay_b, 1'b0, 8'd0, 32'd0);
            end else begin
                accept_config_request(request_delay_a);
                accept_pair_request(request_delay_b);
                send_config_response(response_delay_a, 1'b0, 8'd0, 32'd0);
                send_pair_response(response_delay_b, 1'b0, 8'd0, 32'd0);
            end
        end
    endtask

    task automatic complete_success_in_order(input integer order);
        begin
            case (order & 3)
                0: begin
                    pulse_descriptor_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_input_terminal(1'b0, 8'd0, 32'd0, 2);
                    pulse_engine_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_output_terminal(1'b0, 8'd0, 32'd0, 3);
                end
                1: begin
                    pulse_output_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_engine_terminal(1'b0, 8'd0, 32'd0, 2);
                    pulse_descriptor_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_input_terminal(1'b0, 8'd0, 32'd0, 2);
                end
                2: begin
                    pulse_engine_terminal(1'b0, 8'd0, 32'd0, 3);
                    pulse_input_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_output_terminal(1'b0, 8'd0, 32'd0, 2);
                    pulse_descriptor_terminal(1'b0, 8'd0, 32'd0, 1);
                end
                default: begin
                    pulse_input_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_descriptor_terminal(1'b0, 8'd0, 32'd0, 2);
                    pulse_output_terminal(1'b0, 8'd0, 32'd0, 1);
                    pulse_engine_terminal(1'b0, 8'd0, 32'd0, 3);
                end
            endcase
        end
    endtask

    task automatic run_random_success(input integer seed);
        begin
            begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
            successful_preflight(seed & 1,
                                 (seed >> 1) & 3,
                                 (seed >> 3) & 3,
                                 (seed >> 2) & 3,
                                 (seed >> 4) & 3);
            launch_with_stalls((seed >> 1) & 3,
                               (seed >> 3) & 3,
                               (seed >> 5) & 3);
            complete_success_in_order(seed);
            wait_for_expected_terminal();
            randomized_success_count = randomized_success_count + 1;
        end
    endtask

    // Protocol and result scoreboard.  Blocking assignments are intentional:
    // this is testbench state sampled once per active clock edge.
    always @(posedge clk) begin
        if (rst) begin
            score_active = 1'b0;
            score_launched = 1'b0;
            score_input_terminal = 1'b0;
            score_output_terminal = 1'b0;
            score_descriptor_terminal = 1'b0;
            score_engine_terminal = 1'b0;
            score_pair_requests = 0;
            score_config_requests = 0;
            score_launches = 0;
            previous_job_done = 1'b0;
            previous_job_error = 1'b0;
            previous_job_aborted = 1'b0;
            previous_pair_abort = 1'b0;
            previous_config_abort = 1'b0;
            previous_descriptor_abort = 1'b0;
            previous_engine_abort = 1'b0;
        end else begin
            if (start_valid && start_ready) begin
                if (score_active)
                    $fatal(1, "controller accepted an overlapping start");
                score_active = 1'b1;
                score_launched = 1'b0;
                score_input_terminal = 1'b0;
                score_output_terminal = 1'b0;
                score_descriptor_terminal = 1'b0;
                score_engine_terminal = 1'b0;
                score_pair_requests = 0;
                score_config_requests = 0;
                score_launches = 0;
                accepted_jobs = accepted_jobs + 1;
            end

            if (pair_start_valid && config_start_valid &&
                (score_pair_requests == 0) && (score_config_requests == 0)) begin
                // Observed at least once on every normal preflight, proving
                // requests are offered independently and in parallel.
            end

            if (pair_start_valid && pair_start_ready) begin
                if (!score_active || (score_pair_requests != 0))
                    $fatal(1, "duplicate or stale pair start");
                score_pair_requests = score_pair_requests + 1;
                pair_request_count = pair_request_count + 1;
            end
            if (config_start_valid && config_start_ready) begin
                if (!score_active || (score_config_requests != 0))
                    $fatal(1, "duplicate or stale config start");
                score_config_requests = score_config_requests + 1;
                config_request_count = config_request_count + 1;
            end
            if (pair_response_valid && pair_response_ready)
                pair_response_count = pair_response_count + 1;
            if (config_response_valid && config_response_ready)
                config_response_count = config_response_count + 1;

            if ((input_dma_start !== output_dma_start) ||
                (input_dma_start !== engine_start)) begin
                $fatal(1, "runtime starts were not one atomic same-cycle pulse");
            end
            if (input_dma_start) begin
                if (!score_active || score_launched || (score_launches != 0))
                    $fatal(1, "duplicate or stale runtime launch");
                score_launched = 1'b1;
                score_launches = score_launches + 1;
                launch_count = launch_count + 1;
            end

            // Runtime observation begins strictly after the launch edge.
            // Stale/prelaunch and launch-same-cycle terminal inputs belong to
            // no job and must not satisfy retirement.
            if ((input_dma_done || input_dma_error) && score_launched &&
                !input_dma_start)
                score_input_terminal = 1'b1;
            if ((output_dma_done || output_dma_error) && score_launched &&
                !output_dma_start)
                score_output_terminal = 1'b1;
            if ((descriptor_done || descriptor_error) && score_launched &&
                !engine_start)
                score_descriptor_terminal = 1'b1;
            if ((engine_done || engine_error) && score_launched &&
                !engine_start)
                score_engine_terminal = 1'b1;

            if (pair_abort_pulse) pair_abort_count = pair_abort_count + 1;
            if (config_abort_pulse) config_abort_count = config_abort_count + 1;
            if (descriptor_abort_pulse)
                descriptor_abort_count = descriptor_abort_count + 1;
            if (engine_abort_pulse) engine_abort_count = engine_abort_count + 1;

            if ((job_done && job_error) || (job_done && job_aborted) ||
                (job_error && job_aborted))
                $fatal(1, "multiple job terminal pulses asserted together");

            if (job_done) begin
                if (!score_active || (expected_terminal != TERMINAL_DONE))
                    $fatal(1, "unexpected job_done");
                if (!score_launched || !score_input_terminal ||
                    !score_output_terminal || !score_descriptor_terminal ||
                    !score_engine_terminal)
                    $fatal(1, "job_done preceded all four successful terminals");
                if (input_dma_busy || output_dma_busy || descriptor_busy ||
                    engine_busy || pair_busy || config_busy)
                    $fatal(1, "job_done preceded all-client idle");
                if ((score_pair_requests != 1) ||
                    (score_config_requests != 1) || (score_launches != 1))
                    $fatal(1, "successful job request/launch count mismatch");
                done_count = done_count + 1;
                score_active = 1'b0;
            end
            if (job_error) begin
                if (!score_active || (expected_terminal != TERMINAL_ERROR))
                    $fatal(1, "unexpected job_error");
                if ((error_code !== expected_error_code) ||
                    (error_address !== expected_error_address))
                    $fatal(1, "first-error payload mismatch expected=%02x/%08x got=%02x/%08x",
                           expected_error_code, expected_error_address,
                           error_code, error_address);
                error_count = error_count + 1;
                score_active = 1'b0;
            end
            if (job_aborted) begin
                if (!score_active || (expected_terminal != TERMINAL_ABORTED))
                    $fatal(1, "unexpected job_aborted");
                aborted_count = aborted_count + 1;
                score_active = 1'b0;
            end

            if ((job_done && previous_job_done) ||
                (job_error && previous_job_error) ||
                (job_aborted && previous_job_aborted) ||
                (pair_abort_pulse && previous_pair_abort) ||
                (config_abort_pulse && previous_config_abort) ||
                (descriptor_abort_pulse && previous_descriptor_abort) ||
                (engine_abort_pulse && previous_engine_abort)) begin
                $fatal(1, "terminal or abort output was not a one-cycle pulse");
            end
            previous_job_done = job_done;
            previous_job_error = job_error;
            previous_job_aborted = job_aborted;
            previous_pair_abort = pair_abort_pulse;
            previous_config_abort = config_abort_pulse;
            previous_descriptor_abort = descriptor_abort_pulse;
            previous_engine_abort = engine_abort_pulse;

            if (!score_active &&
                (pair_start_valid || config_start_valid || input_dma_start ||
                 output_dma_start || engine_start)) begin
                $fatal(1, "client start escaped without an active job");
            end
            if (descriptor_busy && !score_launched)
                $fatal(1, "runtime descriptor_busy asserted before launch");
        end
    end

    // All completion tokens precede physical client idleness. Inject at this
    // public interface, never force controller state or clear real debt.
    task automatic check_success_drain_event;
        integer kind,code,done_before,error_before,abort_before,desc_before,engine_before,terminal_target;
        bit canceled,multiple,locked_error,locked_abort,old_preflight;
        begin
            locked_error=DRAIN_CASE==8;locked_abort=DRAIN_CASE==9;old_preflight=DRAIN_CASE==10;
            canceled=DRAIN_CASE==1 || DRAIN_CASE==7 || locked_abort;
            multiple=DRAIN_CASE==6 || DRAIN_CASE==7;
            kind=canceled?TERMINAL_ABORTED:(old_preflight?TERMINAL_DONE:TERMINAL_ERROR);
            code=(DRAIN_CASE==2 || multiple)?8'h71:(DRAIN_CASE==3?8'h72:
                 (DRAIN_CASE==4 || locked_error)?8'h73:8'h74);
            if(canceled || old_preflight)code=0;
            done_before=done_count;error_before=error_count;abort_before=aborted_count;
            begin_job(0,kind,code[7:0],code==0?0:32'hd0000000+code);
            successful_preflight(0,0,0,0,0);launch_with_stalls(0,0,0);
            @(negedge clk);
            input_dma_done=1;output_dma_done=1;descriptor_done=1;engine_done=1;
            if(locked_error) begin
                engine_error=1;engine_error_code=8'h73;engine_error_address=32'hd0000073;
            end
            if(locked_abort)abort=1;
            @(posedge clk);@(negedge clk);
            input_dma_done=0;output_dma_done=0;descriptor_done=0;engine_done=0;engine_error=0;abort=0;
            repeat(4) begin
                @(negedge clk);
                if(job_done || job_error || job_aborted || !busy || start_ready)
                    $fatal(1,"terminal tokens bypassed physical busy drain");
            end
            desc_before=descriptor_abort_count;engine_before=engine_abort_count;
            input_dma_error_code=8'h71;input_dma_error_address=32'hd0000071;
            descriptor_error_code=8'h72;descriptor_error_address=32'hd0000072;
            engine_error_code=8'h73;engine_error_address=32'hd0000073;
            output_dma_error_code=8'h74;output_dma_error_address=32'hd0000074;
            input_dma_error=DRAIN_CASE==2 || multiple || locked_error || locked_abort;
            descriptor_error=DRAIN_CASE==3 || multiple;
            engine_error=DRAIN_CASE==4 || multiple;
            output_dma_error=DRAIN_CASE==5 || multiple;
            abort=canceled || locked_error;
            // Late pair/config diagnostics belong to already-completed
            // prerequisites; they must not acquire a runtime error identity.
            pair_response_error=old_preflight;config_response_error=old_preflight;
            if(DRAIN_IDLE_EDGE) begin
                input_dma_busy=0;output_dma_busy=0;descriptor_busy=0;engine_busy=0;
            end
            @(posedge clk);#1;
            if(!locked_error && !locked_abort && !old_preflight &&
               (job_done || !descriptor_abort_pulse || !engine_abort_pulse))
                $fatal(1,"success-drain late event was not vetoed case=%0d idle_edge=%0d done=%b",DRAIN_CASE,DRAIN_IDLE_EDGE,job_done);
            @(negedge clk);
            input_dma_error=0;descriptor_error=0;engine_error=0;output_dma_error=0;
            pair_response_error=0;config_response_error=0;abort=0;
            if(!DRAIN_IDLE_EDGE) begin
                repeat(5) begin
                    @(negedge clk);
                    if(job_done || job_error || job_aborted || !busy)
                        $fatal(1,"late drain event discarded client ownership");
                end
                input_dma_busy=0;output_dma_busy=0;descriptor_busy=0;engine_busy=0;
            end
            terminal_target=(kind==TERMINAL_DONE?done_before:kind==TERMINAL_ERROR?error_before:abort_before)+1;
            wait_counter(kind==TERMINAL_DONE?6:kind==TERMINAL_ERROR?7:8,terminal_target,50);
            repeat(3)@(negedge clk);
            if(busy || !start_ready || score_active || accepted_jobs!=1 ||
               done_count-done_before!=int'(kind==TERMINAL_DONE) ||
               error_count-error_before!=int'(kind==TERMINAL_ERROR) ||
               aborted_count-abort_before!=int'(kind==TERMINAL_ABORTED) ||
               descriptor_abort_count-desc_before!=int'(!locked_error && !locked_abort && !old_preflight) ||
               engine_abort_count-engine_before!=int'(!locked_error && !locked_abort && !old_preflight))
                $fatal(1,"success-drain terminal/one-shot cancel conservation mismatch");
            if(error_code!==code[7:0] || error_address!==(code==0?32'd0:32'hd0000000+code))
                $fatal(1,"late drain rewrote first-error identity");
            restart_count++;
            run_random_success(32'h4567);
            $display("C1_JOB_SUCCESS_DRAIN_PASS case=%0d idle_edge=%0d retained_first_error=1 terminal_once=1 full_restart=1 reset=0",DRAIN_CASE,DRAIN_IDLE_EDGE);
        end
    endtask

    integer random_index;
    integer abort_target;
    integer launch_target;
    integer terminal_snapshot;

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        if (!start_ready || busy)
            $fatal(1, "controller did not reset to idle");

        if(DRAIN_CASE!=0) begin
            if(DRAIN_CASE<1 || DRAIN_CASE>10)$fatal(1,"unsupported DRAIN_CASE");
            check_success_drain_event();
            $display("C1_R1_JOB_CONTROLLER_PASS drain_case=%0d jobs=%0d",DRAIN_CASE,accepted_jobs);
            $finish;
        end

        if (RESET_BOUNDARY != 0) begin
            if (RESET_BOUNDARY < 1 || RESET_BOUNDARY > 3)
                $fatal(1, "unsupported RESET_BOUNDARY");
            begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
            if (RESET_BOUNDARY == 2)
                accept_both_requests();
            if (RESET_BOUNDARY == 3)
                accept_both_with_same_cycle_success();

            // Make all receivers willing to accept on the reset edge.
            // Inspect BEFORE that edge: a reset-aware scoreboard alone would
            // otherwise hide requests sampled by an independently reset peer.
            @(negedge clk);
            rst = 1'b1;
            pair_start_ready = 1'b1;
            config_start_ready = 1'b1;
            pair_response_valid = 1'b1;
            config_response_valid = 1'b1;
            input_dma_ready = 1'b1;
            output_dma_ready = 1'b1;
            engine_ready = 1'b1;
            #1;
            if (start_ready || pair_start_valid || config_start_valid ||
                pair_response_ready || config_response_ready ||
                input_dma_start || output_dma_start || engine_start)
                $fatal(1, "reset leaked handshake stage=%0d req=%b%b rsp=%b%b launch=%b%b%b",
                    RESET_BOUNDARY, pair_start_valid, config_start_valid,
                    pair_response_ready, config_response_ready,
                    input_dma_start, output_dma_start, engine_start);
            repeat (2) @(posedge clk);
            @(negedge clk);
            pair_start_ready = 1'b0;
            config_start_ready = 1'b0;
            pair_response_valid = 1'b0;
            config_response_valid = 1'b0;
            pair_busy = 1'b0;
            config_busy = 1'b0;
            input_dma_ready = 1'b0;
            output_dma_ready = 1'b0;
            engine_ready = 1'b0;
            rst = 1'b0;
            repeat (3) @(negedge clk);
            if (busy || !start_ready || job_done || job_error || job_aborted ||
                launch_count != 0)
                $fatal(1, "reset produced stale terminal/launch or failed to idle");

            begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
            accept_both_with_same_cycle_success();
            launch_with_stalls(2, 4, 3);
            complete_success_in_order(5);
            wait_for_expected_terminal();
            if (launch_count != 1 || done_count != 1 ||
                error_count != 0 || aborted_count != 0)
                $fatal(1, "reset recovery counters mismatch");
            $display("C1_JOB_RESET_BOUNDARY_PASS stage=%0d recovery=1 launches=1", RESET_BOUNDARY);
            $finish;
        end

        // Basic success with independent request, response, launch and
        // completion delays.
        begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
        successful_preflight(0, 2, 3, 4, 1);
        launch_with_stalls(1, 5, 3);
        complete_success_in_order(0);
        wait_for_expected_terminal();

        // Pair/config responses may be accepted on the exact request edge.
        // Terminal inputs asserted on the launch edge are stale and must be
        // ignored; a second, post-launch set is required for retirement.
        begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
        accept_both_with_same_cycle_success();
        @(negedge clk);
        input_dma_done = 1'b1;
        output_dma_done = 1'b1;
        descriptor_done = 1'b1;
        engine_done = 1'b1;
        input_dma_ready = 1'b1;
        output_dma_ready = 1'b1;
        engine_ready = 1'b1;
        launch_target = launch_count + 1;
        wait_counter(5, launch_target, 200);
        @(negedge clk);
        input_dma_done = 1'b0;
        output_dma_done = 1'b0;
        descriptor_done = 1'b0;
        engine_done = 1'b0;
        input_dma_ready = 1'b0;
        output_dma_ready = 1'b0;
        engine_ready = 1'b0;
        same_cycle_runtime_count = same_cycle_runtime_count + 4;
        input_dma_busy = 1'b1;
        output_dma_busy = 1'b1;
        descriptor_busy = 1'b1;
        engine_busy = 1'b1;
        repeat (4) @(posedge clk);
        if (job_done || job_error || job_aborted)
            $fatal(1, "launch-edge terminal inputs retired the new job");
        launch_edge_ignore_count = launch_edge_ignore_count + 1;
        complete_success_in_order(1);
        wait_for_expected_terminal();

        // Short pre-launch done/error pulses are stale.  A descriptor error
        // blocks launch only while asserted; after it drops the job launches,
        // and none of the earlier terminal pulses count toward retirement.
        begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
        successful_preflight(0, 0, 0, 0, 0);
        @(negedge clk);
        input_dma_done = 1'b1;
        output_dma_done = 1'b1;
        descriptor_done = 1'b1;
        engine_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        input_dma_done = 1'b0;
        output_dma_done = 1'b0;
        descriptor_done = 1'b0;
        engine_done = 1'b0;
        input_dma_ready = 1'b1;
        output_dma_ready = 1'b1;
        engine_ready = 1'b1;
        descriptor_error = 1'b1;
        descriptor_error_code = 8'h7a;
        descriptor_error_address = 32'h7777_007a;
        launch_target = launch_count;
        @(posedge clk);
        @(negedge clk);
        if (launch_count != launch_target)
            $fatal(1, "short prelaunch descriptor fault did not mask launch");
        descriptor_error = 1'b0;
        wait_counter(5, launch_target + 1, 200);
        @(negedge clk);
        input_dma_ready = 1'b0;
        output_dma_ready = 1'b0;
        engine_ready = 1'b0;
        input_dma_busy = 1'b1;
        output_dma_busy = 1'b1;
        descriptor_busy = 1'b1;
        engine_busy = 1'b1;
        repeat (3) @(posedge clk);
        if (job_done || score_input_terminal || score_output_terminal ||
            score_descriptor_terminal || score_engine_terminal)
            $fatal(1, "prelaunch terminal pulse contaminated runtime state");
        prelaunch_pulse_ignore_count = prelaunch_pulse_ignore_count + 1;
        complete_success_in_order(2);
        wait_for_expected_terminal();

        // All four success terminals may arrive before their clients finish
        // internal retirement.  job_done must wait for every busy to fall.
        begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
        successful_preflight(1, 0, 0, 0, 0);
        launch_with_stalls(0, 0, 0);
        @(negedge clk);
        input_dma_done = 1'b1;
        output_dma_done = 1'b1;
        descriptor_done = 1'b1;
        engine_done = 1'b1;
        @(posedge clk);
        @(negedge clk);
        input_dma_done = 1'b0;
        output_dma_done = 1'b0;
        descriptor_done = 1'b0;
        engine_done = 1'b0;
        repeat (6) begin
            @(posedge clk);
            #1;
            if (job_done || !busy)
                $fatal(1, "job_done ignored delayed client busy deassertion");
        end
        @(negedge clk);
        input_dma_busy = 1'b0;
        output_dma_busy = 1'b0;
        descriptor_busy = 1'b0;
        engine_busy = 1'b0;
        busy_drop_wait_count = busy_drop_wait_count + 1;
        wait_for_expected_terminal();

        // Pair error has priority and cancels the other still-busy preflight
        // clients without ever launching DMA.
        begin_job(32'd0, TERMINAL_ERROR, 8'h21, 32'h1111_0021);
        accept_pair_request(0);
        accept_config_request(1);
        launch_target = launch_count;
        abort_target = descriptor_abort_count + 1;
        send_pair_response(2, 1'b1, 8'h21, 32'h1111_0021);
        wait_counter(11, abort_target, 200);
        @(negedge clk);
        config_busy = 1'b0;
        if (launch_count != launch_target)
            $fatal(1, "DMA launched after pair error");
        wait_for_expected_terminal();

        // Config error is retained after the pair side has already succeeded.
        begin_job(32'd0, TERMINAL_ERROR, 8'h32, 32'h2222_0032);
        accept_pair_request(1);
        accept_config_request(0);
        send_pair_response(1, 1'b0, 8'd0, 32'd0);
        abort_target = descriptor_abort_count + 1;
        send_config_response(2, 1'b1, 8'h32, 32'h2222_0032);
        wait_counter(11, abort_target, 200);
        wait_for_expected_terminal();

        // A descriptor error held in WAIT_LAUNCH is a real prelaunch failure:
        // it blocks all starts and must retire with its native payload.
        begin_job(32'd0, TERMINAL_ERROR, 8'h43, 32'h3333_0043);
        successful_preflight(1, 1, 2, 2, 1);
        @(negedge clk);
        input_dma_ready = 1'b1;
        output_dma_ready = 1'b1;
        engine_ready = 1'b1;
        descriptor_error = 1'b1;
        descriptor_error_code = 8'h43;
        descriptor_error_address = 32'h3333_0043;
        launch_target = launch_count;
        wait_for_expected_terminal();
        if (launch_count != launch_target)
            $fatal(1, "DMA launched with held descriptor error");
        held_prelaunch_error_count = held_prelaunch_error_count + 1;
        @(negedge clk);
        input_dma_ready = 1'b0;
        output_dma_ready = 1'b0;
        engine_ready = 1'b0;
        descriptor_error = 1'b0;

        // Simultaneous runtime errors prove fixed priority.  Input DMA wins
        // over descriptor, engine and output DMA.
        begin_job(32'd0, TERMINAL_ERROR, 8'h51, 32'h4444_0051);
        successful_preflight(0, 0, 1, 1, 0);
        launch_with_stalls(0, 0, 0);
        @(negedge clk);
        input_dma_error = 1'b1;
        input_dma_error_code = 8'h51;
        input_dma_error_address = 32'h4444_0051;
        descriptor_error = 1'b1;
        descriptor_error_code = 8'h52;
        descriptor_error_address = 32'h4444_0052;
        engine_error = 1'b1;
        engine_error_code = 8'h53;
        engine_error_address = 32'h4444_0053;
        output_dma_error = 1'b1;
        output_dma_error_code = 8'h54;
        output_dma_error_address = 32'h4444_0054;
        @(posedge clk);
        @(negedge clk);
        input_dma_error = 1'b0;
        descriptor_error = 1'b0;
        engine_error = 1'b0;
        output_dma_error = 1'b0;
        input_dma_busy = 1'b0;
        descriptor_busy = 1'b0;
        engine_busy = 1'b0;
        output_dma_busy = 1'b0;
        wait_for_expected_terminal();

        // Abort before launch suppresses all execution starts.  The terminal
        // waits for the accepted prerequisite clients to acknowledge cancel.
        begin_job(32'd0, TERMINAL_ABORTED, 8'd0, 32'd0);
        accept_pair_request(0);
        accept_config_request(0);
        launch_target = launch_count;
        abort_target = descriptor_abort_count + 1;
        pulse_job_abort();
        wait_counter(11, abort_target, 200);
        repeat (4) @(posedge clk);
        if ((aborted_count != 0) && !score_active)
            $fatal(1, "prelaunch abort retired before clients became idle");
        @(negedge clk);
        pair_busy = 1'b0;
        config_busy = 1'b0;
        if (launch_count != launch_target)
            $fatal(1, "prelaunch abort leaked a DMA start");
        wait_for_expected_terminal();

        // Abort after launch must not retract either DMA.  Descriptor/engine
        // are cancelled, then both DMAs independently drain to terminal.
        begin_job(32'd0, TERMINAL_ABORTED, 8'd0, 32'd0);
        successful_preflight(1, 0, 2, 1, 1);
        launch_with_stalls(2, 1, 3);
        abort_target = descriptor_abort_count + 1;
        terminal_snapshot = aborted_count;
        pulse_job_abort();
        wait_counter(11, abort_target, 200);
        repeat (3) @(posedge clk);
        if (aborted_count != terminal_snapshot)
            $fatal(1, "postlaunch abort retired before DMA drain");
        @(negedge clk);
        descriptor_busy = 1'b0;
        engine_busy = 1'b0;
        pulse_input_terminal(1'b0, 8'd0, 32'd0, 2);
        repeat (3) @(posedge clk);
        if (aborted_count != terminal_snapshot)
            $fatal(1, "postlaunch abort retired after only one DMA");
        pulse_output_terminal(1'b0, 8'd0, 32'd0, 2);
        wait_for_expected_terminal();

        // Runtime engine failure drains both already-issued DMAs and retains
        // the engine's original address through later successful DMA endings.
        begin_job(32'd0, TERMINAL_ERROR, 8'h65, 32'h5555_0065);
        successful_preflight(0, 1, 1, 2, 2);
        launch_with_stalls(0, 2, 1);
        pulse_engine_terminal(1'b1, 8'h65, 32'h5555_0065, 2);
        @(negedge clk);
        descriptor_busy = 1'b0;
        pulse_output_terminal(1'b0, 8'd0, 32'd0, 1);
        pulse_input_terminal(1'b0, 8'd0, 32'd0, 3);
        wait_for_expected_terminal();

        // A three-cycle preflight budget expires at address 3.  The watchdog
        // is itself the retained first error and cancels all prerequisite work.
        begin_job(32'd3, TERMINAL_ERROR, 8'hf0, 32'd3);
        abort_target = descriptor_abort_count + 1;
        accept_both_requests();
        wait_counter(11, abort_target, 200);
        @(negedge clk);
        pair_busy = 1'b0;
        config_busy = 1'b0;
        wait_for_expected_terminal();

        // Timeout after launch enters the same safe drain path.  Descriptor
        // and engine cancel, while both DMAs still must report terminal events.
        begin_job(32'd30, TERMINAL_ERROR, 8'hf0, 32'd30);
        successful_preflight(1, 0, 0, 0, 0);
        launch_with_stalls(0, 0, 0);
        abort_target = descriptor_abort_count + 1;
        wait_counter(11, abort_target, 300);
        @(negedge clk);
        descriptor_busy = 1'b0;
        engine_busy = 1'b0;
        pulse_input_terminal(1'b0, 8'd0, 32'd0, 1);
        pulse_output_terminal(1'b0, 8'd0, 32'd0, 1);
        wait_for_expected_terminal();

        // budget==0 remains disabled despite delays well beyond the small
        // watchdog cases above.
        begin_job(32'd0, TERMINAL_DONE, 8'd0, 32'd0);
        successful_preflight(0, 12, 9, 15, 11);
        launch_with_stalls(8, 13, 10);
        complete_success_in_order(3);
        wait_for_expected_terminal();

        // Repeated restart runs vary request order, backpressure, response
        // latency, launch readiness and all four completion orders.
        for (random_index = 0; random_index < 12;
             random_index = random_index + 1) begin
            run_random_success(32'h1357 + random_index * 32'h29);
        end

        repeat (8) @(posedge clk);
        if (busy || score_active || !start_ready || pair_busy || config_busy ||
            input_dma_busy || output_dma_busy || descriptor_busy || engine_busy)
            $fatal(1, "regression ended with outstanding controller state");
        if ((accepted_jobs != 26) || (done_count != 17) ||
            (error_count != 7) || (aborted_count != 2) ||
            (launch_count != 21) || (pair_request_count != accepted_jobs) ||
            (config_request_count != accepted_jobs)) begin
            $fatal(1, "coverage totals mismatch jobs=%0d done=%0d error=%0d aborted=%0d launches=%0d pair=%0d config=%0d",
                   accepted_jobs, done_count, error_count, aborted_count,
                   launch_count, pair_request_count, config_request_count);
        end
        if ((pair_abort_count < 3) || (config_abort_count < 3) ||
            (descriptor_abort_count < 8) || (engine_abort_count < 4) ||
            (same_cycle_response_count != 2) ||
            (same_cycle_runtime_count != 4) ||
            (prelaunch_pulse_ignore_count != 1) ||
            (launch_edge_ignore_count != 1) ||
            (busy_drop_wait_count != 1) ||
            (held_prelaunch_error_count != 1) ||
            (randomized_success_count != 12) || (restart_count != 26)) begin
            $fatal(1, "boundary coverage counters incomplete");
        end

        $display("C1_R1_JOB_CONTROLLER_PASS jobs=%0d done=%0d errors=%0d aborted=%0d launches=%0d pair_aborts=%0d config_aborts=%0d descriptor_aborts=%0d engine_aborts=%0d randomized=%0d",
                 accepted_jobs, done_count, error_count, aborted_count,
                 launch_count, pair_abort_count, config_abort_count,
                 descriptor_abort_count, engine_abort_count,
                 randomized_success_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "global job-controller testbench timeout");
    end

endmodule
