`timescale 1ns/1ps

module tb_c1_r1_config_dispatcher;

    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;
    localparam integer READ_TIMEOUT_CYCLES = 12;

    localparam logic [7:0] ERR_COUNT_ZERO          = 8'h51;
    localparam logic [7:0] ERR_COUNT_RANGE         = 8'h52;
    localparam logic [7:0] ERR_GENERATION_CHANGED  = 8'h53;
    localparam logic [7:0] ERR_RESPONSE_GENERATION = 8'h54;
    localparam logic [7:0] ERR_READ_TIMEOUT        = 8'h55;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start = 1'b0;
    logic start_ready;
    logic abort = 1'b0;
    logic [COUNT_BITS-1:0] active_count = '0;
    logic [GENERATION_BITS-1:0] active_generation = '0;

    logic config_read_enable;
    logic [COUNT_BITS-1:0] config_read_index;
    logic config_read_ready;
    logic config_read_busy = 1'b0;
    logic config_read_valid;
    logic [511:0] config_read_descriptor;
    logic [GENERATION_BITS-1:0] config_read_generation;

    logic stage_config_valid;
    logic stage_config_ready;
    logic [COUNT_BITS-1:0] stage_config_index;
    logic [511:0] stage_config_descriptor;
    logic [GENERATION_BITS-1:0] stage_config_generation;

    logic busy;
    logic done;
    logic error;
    logic aborted;
    logic [7:0] error_code;
    logic [31:0] error_address;

    logic [31:0] prng = 32'h4f2a_918d;
    logic random_ready = 1'b1;
    logic force_read_not_ready = 1'b0;
    logic force_stage_stall = 1'b0;
    logic bfm_pending = 1'b0;
    logic bfm_wrong_generation_next = 1'b0;
    logic bfm_suppress_response_next = 1'b0;
    logic bfm_zero_latency = 1'b0;
    logic bfm_response_valid_q = 1'b0;
    logic [511:0] bfm_response_descriptor_q = '0;
    logic [GENERATION_BITS-1:0] bfm_response_generation_q = '0;
    logic [COUNT_BITS-1:0] bfm_index_q = '0;
    logic [GENERATION_BITS-1:0] bfm_generation_q = '0;
    integer bfm_delay_setting = 2;
    integer bfm_delay_q = 0;

    integer accepted_starts = 0;
    integer read_requests = 0;
    integer read_responses = 0;
    integer stage_transfers = 0;
    integer done_count = 0;
    integer error_count = 0;
    integer aborted_count = 0;
    integer read_stall_cycles = 0;
    integer stage_stall_cycles = 0;
    integer hold_checks = 0;
    integer restart_checks = 0;
    integer generation_fault_checks = 0;
    integer timeout_checks = 0;
    integer zero_latency_checks = 0;

    integer expected_stage_index = 0;
    logic [GENERATION_BITS-1:0] expected_stage_generation = '0;
    logic score_dispatch = 1'b0;

    logic previous_stage_stall = 1'b0;
    logic [COUNT_BITS+GENERATION_BITS+511:0] previous_stage_payload = '0;

    always #5 clk = ~clk;

    function automatic [511:0] make_descriptor(
        input logic [COUNT_BITS-1:0] descriptor_index,
        input logic [GENERATION_BITS-1:0] descriptor_generation
    );
        integer word_index;
        logic [511:0] value;
        begin
            value = '0;
            for (word_index = 0; word_index < 16; word_index = word_index + 1)
                value[word_index*32 +: 32] =
                    32'hc100_0000 ^ (descriptor_index * 32'h0001_0101) ^
                    (descriptor_generation * 32'h0010_0001) ^ word_index;
            value[15:0] = descriptor_index;
            value[23:16] = descriptor_generation;
            make_descriptor = value;
        end
    endfunction

    assign config_read_ready = !rst && !bfm_pending &&
                               !force_read_not_ready &&
                               (!random_ready || (prng[2:0] != 3'b000));
    assign config_read_valid = bfm_zero_latency ?
                               (config_read_enable && config_read_ready) :
                               bfm_response_valid_q;
    assign config_read_descriptor = bfm_zero_latency ?
        make_descriptor(config_read_index, active_generation) :
        bfm_response_descriptor_q;
    assign config_read_generation = bfm_zero_latency ?
        (bfm_wrong_generation_next ? active_generation + 1'b1 :
                                     active_generation) :
        bfm_response_generation_q;
    assign stage_config_ready = !rst && !force_stage_stall &&
                                (!random_ready || (prng[6:4] != 3'b000));

    c1_r1_config_dispatcher #(
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES)
    ) dut (.*);

    // Config-bank behavioral model.  It deliberately supports response gaps,
    // a mismatched response generation, and a dropped response used to prove
    // timeout/drain/restart behavior.
    // Plain procedural block is intentional: fault-injection controls such as
    // bfm_wrong_generation_next are also written by the stimulus process.
    always @(posedge clk) begin
        if (rst) begin
            bfm_pending <= 1'b0;
            config_read_busy <= 1'b0;
            bfm_response_valid_q <= 1'b0;
            bfm_response_descriptor_q <= '0;
            bfm_response_generation_q <= '0;
            bfm_delay_q <= 0;
        end else begin
            bfm_response_valid_q <= 1'b0;
            bfm_response_descriptor_q <= '0;

            if (config_read_enable && config_read_ready) begin
                read_requests <= read_requests + 1;
                if (bfm_zero_latency) begin
                    read_responses <= read_responses + 1;
                    bfm_wrong_generation_next <= 1'b0;
                end else begin
                    bfm_pending <= 1'b1;
                    config_read_busy <= 1'b1;
                    bfm_index_q <= config_read_index;
                    bfm_generation_q <= active_generation;
                    bfm_delay_q <= bfm_delay_setting;
                end
            end else if (bfm_pending) begin
                if (bfm_delay_q == 0) begin
                    bfm_pending <= 1'b0;
                    config_read_busy <= 1'b0;
                    if (!bfm_suppress_response_next) begin
                        bfm_response_valid_q <= 1'b1;
                        bfm_response_descriptor_q <=
                            make_descriptor(bfm_index_q, bfm_generation_q);
                        if (bfm_wrong_generation_next)
                            bfm_response_generation_q <=
                                bfm_generation_q + 1'b1;
                        else
                            bfm_response_generation_q <= bfm_generation_q;
                        read_responses <= read_responses + 1;
                    end
                    bfm_wrong_generation_next <= 1'b0;
                    bfm_suppress_response_next <= 1'b0;
                end else begin
                    bfm_delay_q <= bfm_delay_q - 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            prng <= 32'h4f2a_918d;
            accepted_starts <= 0;
            stage_transfers <= 0;
            done_count <= 0;
            error_count <= 0;
            aborted_count <= 0;
            read_stall_cycles <= 0;
            stage_stall_cycles <= 0;
            hold_checks <= 0;
            previous_stage_stall <= 1'b0;
        end else begin
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};

            if (start && start_ready)
                accepted_starts <= accepted_starts + 1;
            if (done)
                done_count <= done_count + 1;
            if (error)
                error_count <= error_count + 1;
            if (aborted)
                aborted_count <= aborted_count + 1;
            if (busy && !config_read_ready && !config_read_busy &&
                !stage_config_valid)
                read_stall_cycles <= read_stall_cycles + 1;
            if (stage_config_valid && !stage_config_ready)
                stage_stall_cycles <= stage_stall_cycles + 1;

            if (stage_config_valid && stage_config_ready) begin
                if (score_dispatch) begin
                    if (stage_config_index !== expected_stage_index[COUNT_BITS-1:0])
                        $fatal(1, "stage index mismatch expected=%0d actual=%0d",
                               expected_stage_index, stage_config_index);
                    if (stage_config_generation !== expected_stage_generation)
                        $fatal(1, "stage generation mismatch");
                    if (stage_config_descriptor !==
                        make_descriptor(expected_stage_index[COUNT_BITS-1:0],
                                        expected_stage_generation))
                        $fatal(1, "stage descriptor mismatch at index %0d",
                               expected_stage_index);
                    expected_stage_index <= expected_stage_index + 1;
                end
                stage_transfers <= stage_transfers + 1;
            end

            if (previous_stage_stall && !abort) begin
                if (!stage_config_valid)
                    $fatal(1, "stage VALID retracted under backpressure");
                if ({stage_config_index, stage_config_generation,
                     stage_config_descriptor} !== previous_stage_payload)
                    $fatal(1, "stage payload changed under backpressure");
                hold_checks <= hold_checks + 1;
            end
            if ((done && error) || (done && aborted) || (error && aborted))
                $fatal(1, "multiple terminal pulses in one cycle");

            previous_stage_stall <= stage_config_valid &&
                                    !stage_config_ready && !abort;
            previous_stage_payload <= {stage_config_index,
                                       stage_config_generation,
                                       stage_config_descriptor};
        end
    end

    task automatic launch_job(
        input integer descriptor_count,
        input logic [GENERATION_BITS-1:0] generation_value,
        input logic enable_score
    );
        integer guard;
        begin
            guard = 0;
            while (!start_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 200)
                    $fatal(1, "start_ready timeout");
            end
            @(negedge clk);
            active_count = descriptor_count[COUNT_BITS-1:0];
            active_generation = generation_value;
            expected_stage_index = 0;
            expected_stage_generation = generation_value;
            score_dispatch = enable_score;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_terminal(
        input integer terminal_kind,
        input logic [7:0] expected_code,
        input integer limit
    );
        integer guard;
        begin
            guard = 0;
            while (!done && !error && !aborted) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > limit)
                    $fatal(1, "terminal timeout kind=%0d state_busy=%0b",
                           terminal_kind, busy);
            end
            case (terminal_kind)
                0: if (!done || error || aborted)
                       $fatal(1, "expected done terminal");
                1: begin
                    if (!error || done || aborted)
                        $fatal(1, "expected error terminal");
                    if (error_code !== expected_code)
                        $fatal(1, "error code mismatch expected=%02x actual=%02x",
                               expected_code, error_code);
                end
                2: if (!aborted || done || error)
                       $fatal(1, "expected aborted terminal");
                default: $fatal(1, "invalid terminal kind");
            endcase
            @(negedge clk);
            if (done || error || aborted || busy)
                $fatal(1, "terminal was not a one-cycle idle retirement");
            score_dispatch = 1'b0;
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    integer reads_before;
    integer stages_before;
    integer guard;

    initial begin
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
        repeat (3) @(posedge clk);

        // SYNC_READ=0 banks return VALID combinationally with ENABLE.  Prove
        // the dispatcher consumes that response on the request edge instead
        // of entering WAIT_READ and losing it.
        random_ready = 1'b0;
        bfm_zero_latency = 1'b1;
        launch_job(3, 8'h11, 1'b1);
        wait_terminal(0, 8'h00, 100);
        if (expected_stage_index != 3)
            $fatal(1, "zero-latency dispatch count mismatch");
        zero_latency_checks = zero_latency_checks + 1;
        bfm_zero_latency = 1'b0;

        // Random read and stage stalls over a seven-stage and one-stage job.
        random_ready = 1'b1;
        bfm_delay_setting = 3;
        launch_job(7, 8'h12, 1'b1);
        wait_terminal(0, 8'h00, 1000);
        if (expected_stage_index != 7)
            $fatal(1, "seven-stage dispatch count mismatch");

        launch_job(1, 8'h13, 1'b1);
        wait_terminal(0, 8'h00, 300);
        if (expected_stage_index != 1)
            $fatal(1, "single-stage dispatch count mismatch");
        restart_checks = restart_checks + 1;

        // Illegal active counts terminate locally without issuing a bank read.
        reads_before = read_requests;
        launch_job(0, 8'h20, 1'b0);
        wait_terminal(1, ERR_COUNT_ZERO, 20);
        if (read_requests != reads_before)
            $fatal(1, "zero-count job issued a config read");

        launch_job(MAX_STAGES + 1, 8'h21, 1'b0);
        wait_terminal(1, ERR_COUNT_RANGE, 20);
        if (read_requests != reads_before)
            $fatal(1, "range-error job issued a config read");

        // Returned-generation mismatch is distinguished from a live commit.
        bfm_wrong_generation_next = 1'b1;
        launch_job(2, 8'h30, 1'b0);
        wait_terminal(1, ERR_RESPONSE_GENERATION, 200);
        generation_fault_checks = generation_fault_checks + 1;

        // A generation mutation while the request is waiting for READY must
        // stop before any read is accepted.
        random_ready = 1'b0;
        force_read_not_ready = 1'b1;
        reads_before = read_requests;
        launch_job(2, 8'h31, 1'b0);
        repeat (3) @(negedge clk);
        active_generation = 8'h32;
        wait_terminal(1, ERR_GENERATION_CHANGED, 50);
        if (read_requests != reads_before)
            $fatal(1, "generation-change ISSUE test accepted a read");
        force_read_not_ready = 1'b0;
        generation_fault_checks = generation_fault_checks + 1;

        // Exact race: READY remains high when generation changes in ISSUE.
        // ENABLE must be suppressed, otherwise the bank would accept a read
        // that the generation-error path immediately hides.
        reads_before = read_requests;
        launch_job(2, 8'h33, 1'b0);
        active_generation = 8'h34;
        wait_terminal(1, ERR_GENERATION_CHANGED, 50);
        if (read_requests != reads_before)
            $fatal(1, "generation/READY race leaked a config read enable");
        generation_fault_checks = generation_fault_checks + 1;

        // Mutation with a read in flight drains its eventual response before
        // the error pulse and allows the following job to restart cleanly.
        bfm_delay_setting = 8;
        launch_job(2, 8'h40, 1'b0);
        guard = 0;
        while (!config_read_busy) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 40)
                $fatal(1, "generation WAIT test never started a read");
        end
        active_generation = 8'h41;
        wait_terminal(1, ERR_GENERATION_CHANGED, 100);
        if (config_read_busy || config_read_valid)
            $fatal(1, "generation WAIT test did not drain bank response");
        generation_fault_checks = generation_fault_checks + 1;

        // A stalled stage payload remains valid and stable after a live
        // generation mutation; the accepted stale transfer is followed by an
        // error so the enclosing controller can abort all runtime clients.
        bfm_delay_setting = 1;
        force_stage_stall = 1'b1;
        stages_before = stage_transfers;
        launch_job(2, 8'h50, 1'b1);
        guard = 0;
        while (!stage_config_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 80)
                $fatal(1, "generation SEND test never produced VALID");
        end
        active_generation = 8'h51;
        repeat (4) @(negedge clk);
        force_stage_stall = 1'b0;
        wait_terminal(1, ERR_GENERATION_CHANGED, 40);
        if (stage_transfers != stages_before + 1)
            $fatal(1, "generation SEND test transfer count mismatch");
        generation_fault_checks = generation_fault_checks + 1;

        // Timeout before AR/read acceptance.
        force_read_not_ready = 1'b1;
        reads_before = read_requests;
        launch_job(1, 8'h60, 1'b0);
        wait_terminal(1, ERR_READ_TIMEOUT, 80);
        if (read_requests != reads_before)
            $fatal(1, "ISSUE timeout unexpectedly accepted a read");
        force_read_not_ready = 1'b0;
        timeout_checks = timeout_checks + 1;

        // Timeout after acceptance; the deliberately late response is drained.
        bfm_delay_setting = READ_TIMEOUT_CYCLES + 5;
        launch_job(1, 8'h61, 1'b0);
        wait_terminal(1, ERR_READ_TIMEOUT, 100);
        if (config_read_busy || config_read_valid)
            $fatal(1, "WAIT timeout did not drain late response");
        timeout_checks = timeout_checks + 1;

        // Abort in ISSUE, WAIT_READ, and a stalled SEND; each must restart.
        force_read_not_ready = 1'b1;
        launch_job(3, 8'h70, 1'b0);
        repeat (2) @(negedge clk);
        pulse_abort();
        wait_terminal(2, 8'h00, 40);
        force_read_not_ready = 1'b0;

        bfm_delay_setting = 8;
        launch_job(3, 8'h71, 1'b0);
        while (!config_read_busy)
            @(negedge clk);
        pulse_abort();
        wait_terminal(2, 8'h00, 100);

        bfm_delay_setting = 1;
        force_stage_stall = 1'b1;
        stages_before = stage_transfers;
        launch_job(3, 8'h72, 1'b0);
        while (!stage_config_valid)
            @(negedge clk);
        pulse_abort();
        wait_terminal(2, 8'h00, 40);
        if (stage_transfers != stages_before)
            $fatal(1, "aborted stalled descriptor reached stage sink");
        force_stage_stall = 1'b0;

        // Final randomized success proves clean restart after every fault class.
        random_ready = 1'b1;
        bfm_delay_setting = 2;
        launch_job(5, 8'h7f, 1'b1);
        wait_terminal(0, 8'h00, 800);
        if (expected_stage_index != 5)
            $fatal(1, "final restart dispatch count mismatch");
        restart_checks = restart_checks + 1;

        if ((accepted_starts != 16) || (done_count != 4) ||
            (error_count != 9) || (aborted_count != 3) ||
            (generation_fault_checks != 5) || (timeout_checks != 2) ||
            (zero_latency_checks != 1) ||
            (read_requests < 18) || (stage_transfers != 17) ||
            (read_stall_cycles == 0) || (stage_stall_cycles == 0) ||
            (hold_checks == 0) || (restart_checks != 2))
            $fatal(1, "config dispatcher coverage/count mismatch starts=%0d done=%0d errors=%0d aborts=%0d reads=%0d stages=%0d",
                   accepted_starts, done_count, error_count, aborted_count,
                   read_requests, stage_transfers);

        $display("C1_R1_CONFIG_DISPATCHER_PASS starts=%0d done=%0d errors=%0d aborts=%0d reads=%0d responses=%0d stages=%0d read_stalls=%0d stage_stalls=%0d holds=%0d generation_faults=%0d timeouts=%0d zero_latency=%0d restarts=%0d",
                 accepted_starts, done_count, error_count, aborted_count,
                 read_requests, read_responses, stage_transfers,
                 read_stall_cycles, stage_stall_cycles, hold_checks,
                 generation_fault_checks, timeout_checks,
                 zero_latency_checks, restart_checks);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "config dispatcher global timeout/deadlock");
    end

endmodule
