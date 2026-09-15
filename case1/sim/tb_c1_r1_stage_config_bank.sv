`timescale 1ns/1ps

module tb_c1_r1_stage_config_bank;
    localparam integer MAX_STAGES = 22;
    localparam integer INDEX_BITS = 6;
    localparam integer GENERATION_BITS = 2;

    localparam logic [2:0] ERROR_NONE = 3'd0;
    localparam logic [2:0] ERROR_START_INDEX = 3'd1;
    localparam logic [2:0] ERROR_ORDER = 3'd2;
    localparam logic [2:0] ERROR_INDEX_RANGE = 3'd3;
    localparam logic [2:0] ERROR_COUNT_ZERO = 3'd4;
    localparam logic [2:0] ERROR_COUNT_RANGE = 3'd5;
    localparam logic [2:0] ERROR_COUNT_CHANGED = 3'd6;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic load_abort = 1'b0;
    logic [INDEX_BITS-1:0] load_count = '0;
    logic layer_command_valid = 1'b0;
    logic layer_command_ready;
    logic [INDEX_BITS-1:0] layer_command_index = '0;
    logic [511:0] layer_command_descriptor = '0;
    logic loading;
    logic [INDEX_BITS-1:0] shadow_count;
    logic load_complete_pulse;
    logic error_pulse;
    logic [2:0] error_code;
    logic active_bank;
    logic [INDEX_BITS-1:0] active_count;
    logic [GENERATION_BITS-1:0] generation;
    logic engine_read_enable = 1'b0;
    logic [INDEX_BITS-1:0] engine_read_index = '0;
    logic engine_read_ready;
    logic engine_read_busy;
    logic engine_read_valid;
    logic [511:0] engine_read_descriptor;
    logic [GENERATION_BITS-1:0] engine_read_generation;

    logic [511:0] model_active [0:MAX_STAGES-1];
    integer model_count = 0;
    logic model_bank = 1'b0;
    logic [GENERATION_BITS-1:0] model_generation = '0;
    logic [31:0] prng = 32'h8e61_a745;
    integer current_phase = 0;
    integer accepted_commands = 0;
    integer commit_checks = 0;
    integer error_checks = 0;
    integer abort_checks = 0;
    integer command_stall_cycles = 0;
    integer command_hold_checks = 0;
    integer source_gap_cycles = 0;
    integer read_checks = 0;
    integer read_busy_cycles = 0;
    integer read_ready_stall_checks = 0;
    integer overlap_checks = 0;

    logic held_command = 1'b0;
    logic [511+2*INDEX_BITS:0] held_command_payload = '0;

    // Defaults deliberately select SYNC_READ=1, FAST_WIDE=0.
    c1_r1_stage_config_bank #(
        .MAX_STAGES(MAX_STAGES),
        .INDEX_BITS(INDEX_BITS),
        .GENERATION_BITS(GENERATION_BITS)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic [31:0] prng_next(input [31:0] state);
        logic feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    function automatic [511:0] descriptor_pattern(
        input integer batch_tag,
        input integer stage_index
    );
        integer word_index;
        logic [511:0] value;
        begin
            value = '0;
            for (word_index = 0; word_index < 16;
                 word_index = word_index + 1)
                value[word_index*32 +: 32] = 32'hc100_0000 ^
                    (batch_tag << 16) ^ (stage_index << 8) ^ word_index;
            descriptor_pattern = value;
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_R1_STAGE_CONFIG_BANK_FAIL time=%0t phase=%0d: %s",
                     $time, current_phase, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic check_active_metadata;
        begin
            if ((active_bank !== model_bank) ||
                (active_count !== model_count[INDEX_BITS-1:0]) ||
                (generation !== model_generation))
                fail("active bank/count/generation disagrees with model");
        end
    endtask

    task automatic update_model_after_commit(
        input integer batch_tag,
        input integer count_value
    );
        integer stage_index;
        begin
            model_bank = ~model_bank;
            model_count = count_value;
            model_generation = model_generation + 1'b1;
            for (stage_index = 0; stage_index < count_value;
                 stage_index = stage_index + 1)
                model_active[stage_index] =
                    descriptor_pattern(batch_tag, stage_index);
        end
    endtask

    task automatic send_command(
        input integer batch_tag,
        input integer count_value,
        input integer stage_index,
        input integer gap_cycles,
        input logic [2:0] expected_error,
        input logic expected_commit
    );
        integer gap_index;
        logic accepted;
        begin
            for (gap_index = 0; gap_index < gap_cycles;
                 gap_index = gap_index + 1) begin
                @(negedge clk);
                layer_command_valid = 1'b0;
                source_gap_cycles = source_gap_cycles + 1;
            end
            @(negedge clk);
            load_count = count_value;
            layer_command_index = stage_index;
            layer_command_descriptor =
                descriptor_pattern(batch_tag, stage_index);
            layer_command_valid = 1'b1;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                accepted = layer_command_valid && layer_command_ready;
            end
            accepted_commands = accepted_commands + 1;
            if (expected_commit)
                update_model_after_commit(batch_tag, count_value);
            #1;
            if ((error_pulse !== (expected_error != ERROR_NONE)) ||
                (error_code !== expected_error))
                fail("error pulse/code mismatch after command handshake");
            if (load_complete_pulse !== expected_commit)
                fail("commit pulse mismatch after command handshake");
            if (expected_error != ERROR_NONE) begin
                error_checks = error_checks + 1;
                if (loading || (shadow_count != 0))
                    fail("protocol error did not discard shadow transaction");
            end else if (expected_commit) begin
                commit_checks = commit_checks + 1;
                if (loading || (shadow_count != 0))
                    fail("commit did not return loader to idle");
            end else if (!loading ||
                         (shadow_count !== (stage_index + 1))) begin
                fail("accepted partial descriptor count/state mismatch");
            end
            check_active_metadata();
            @(negedge clk);
            layer_command_valid = 1'b0;
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            load_abort = 1'b1;
            #1;
            if (layer_command_ready)
                fail("load_abort did not suppress command ready");
            @(posedge clk);
            #1;
            if (loading || (shadow_count != 0) || load_complete_pulse ||
                error_pulse)
                fail("load_abort did not quietly discard shadow state");
            check_active_metadata();
            abort_checks = abort_checks + 1;
            @(negedge clk);
            load_abort = 1'b0;
        end
    endtask

    task automatic abort_mid_serialization;
        integer guard;
        begin
            @(negedge clk);
            load_count = 4;
            layer_command_index = 0;
            layer_command_descriptor = descriptor_pattern(80, 0);
            layer_command_valid = 1'b1;
            guard = 0;
            while (!dut.narrow_write_active_q) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    fail("narrow serializer did not start");
            end
            repeat (5) @(posedge clk);
            @(negedge clk);
            load_abort = 1'b1;
            #1;
            if (layer_command_ready)
                fail("abort did not hold ready low during serialization");
            @(posedge clk);
            #1;
            if (dut.narrow_write_active_q ||
                dut.narrow_write_prepared_q || loading ||
                (shadow_count != 0) || (active_count != 0))
                fail("abort did not cancel partial narrow RAM serialization");
            abort_checks = abort_checks + 1;
            @(negedge clk);
            layer_command_valid = 1'b0;
            load_abort = 1'b0;
        end
    endtask

    task automatic abort_commit_boundary(input bit prepared);
        integer guard, responses;
        begin
            @(negedge clk);
            load_count=1;layer_command_index=0;
            layer_command_descriptor=descriptor_pattern(81+prepared,0);
            layer_command_valid=1;
            guard=0;
            while(!(prepared ? dut.narrow_write_prepared_q :
                    (dut.narrow_write_active_q && dut.g_synchronous_narrow.write_word_q==15))) begin
                @(negedge clk);guard++;
                if(guard>100) fail("serializer did not reach cancel/commit boundary");
            end
            if(!engine_read_ready) fail("boundary reader unexpectedly busy");
            engine_read_enable=1;engine_read_index=0;responses=0;
            load_abort=1;
            #1;
            if(layer_command_ready) fail("boundary abort allowed command acceptance");
            @(posedge clk);#1;
            if(dut.narrow_write_active_q || dut.narrow_write_prepared_q ||
               loading || shadow_count!=0 || load_complete_pulse || error_pulse)
                fail("boundary abort did not discard final descriptor");
            check_active_metadata();
            abort_checks++;
            @(negedge clk);layer_command_valid=0;load_abort=0;engine_read_enable=0;
            repeat(20) begin
                @(posedge clk);#1;
                if(load_complete_pulse || error_pulse || loading)
                    fail("canceled final descriptor committed late");
                check_active_metadata();
                if(engine_read_valid) begin
                    if(engine_read_descriptor!==model_active[0] ||
                       engine_read_generation!==model_generation)
                        fail("abort-edge read used canceled bank/generation");
                    responses++;read_checks++;overlap_checks++;
                end
            end
            if(responses!=1 || engine_read_busy)
                fail("abort-edge read was missing/duplicated or stayed busy");
            check_all_active_reads();
            $display("C1_STAGE_ABORT_COMMIT_BOUNDARY_PASS prepared=%0d old_bank_preserved=1 concurrent_read=1",prepared);
        end
    endtask

    task automatic check_read(input integer stage_index);
        logic expect_valid;
        logic [511:0] expect_descriptor;
        integer busy_count;
        integer guard;
        begin
            expect_valid = (stage_index >= 0) &&
                           (stage_index < model_count) &&
                           (stage_index < MAX_STAGES);
            expect_descriptor = expect_valid ? model_active[stage_index] : '0;
            while (!engine_read_ready)
                @(negedge clk);
            @(negedge clk);
            engine_read_index = stage_index;
            engine_read_enable = 1'b1;
            @(posedge clk);
            @(negedge clk);
            engine_read_enable = 1'b0;
            if (!expect_valid) begin
                if (engine_read_busy || engine_read_valid)
                    fail("out-of-range read started a narrow transaction");
                read_checks = read_checks + 1;
            end else begin
                busy_count = 0;
                guard = 0;
                while (!engine_read_valid) begin
                    @(negedge clk);
                    guard = guard + 1;
                    if (engine_read_busy) begin
                        busy_count = busy_count + 1;
                        if (engine_read_ready)
                            fail("engine read ready asserted while busy");
                        read_ready_stall_checks =
                            read_ready_stall_checks + 1;
                    end
                    if (guard > 40)
                        fail("narrow engine read timed out");
                end
                if ((engine_read_descriptor !== expect_descriptor) ||
                    (engine_read_generation !== model_generation) ||
                    engine_read_busy || !engine_read_ready)
                    fail("assembled narrow engine descriptor mismatch");
                if (busy_count < 15)
                    fail("narrow engine read did not exercise 16-word latency");
                read_busy_cycles = read_busy_cycles + busy_count;
                read_checks = read_checks + 1;
                @(posedge clk);
                #1;
                if (engine_read_valid || (engine_read_descriptor != 0))
                    fail("narrow engine read response was not one cycle");
            end
        end
    endtask

    task automatic check_all_active_reads;
        integer stage_index;
        begin
            for (stage_index = 0; stage_index < model_count;
                 stage_index = stage_index + 1)
                check_read(stage_index);
            check_read(model_count);
        end
    endtask

    // Begin a narrow read of the old active bank after word eight of the final
    // shadow descriptor is being written.  Commit occurs before the 16-word
    // read response, which must still carry the old captured generation.
    task automatic commit_with_overlapping_read(
        input integer batch_tag,
        input integer count_value,
        input integer final_index
    );
        logic [511:0] old_descriptor;
        logic [GENERATION_BITS-1:0] old_generation;
        integer guard;
        begin
            old_descriptor = model_active[0];
            old_generation = model_generation;
            @(negedge clk);
            load_count = count_value;
            layer_command_index = final_index;
            layer_command_descriptor =
                descriptor_pattern(batch_tag, final_index);
            layer_command_valid = 1'b1;
            guard = 0;
            while (!(dut.narrow_write_active_q &&
                     (dut.g_synchronous_narrow.write_word_q >= 8))) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    fail("final narrow descriptor did not reach overlap point");
            end
            if (!engine_read_ready)
                fail("engine reader unexpectedly busy before overlap request");
            @(negedge clk);
            engine_read_index = 0;
            engine_read_enable = 1'b1;
            @(posedge clk);
            @(negedge clk);
            engine_read_enable = 1'b0;

            guard = 0;
            while (!(layer_command_valid && layer_command_ready)) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 50)
                    fail("overlap final command did not handshake");
            end
            accepted_commands = accepted_commands + 1;
            update_model_after_commit(batch_tag, count_value);
            #1;
            if (!load_complete_pulse || error_pulse || loading ||
                (shadow_count != 0))
                fail("overlap final command did not commit cleanly");
            commit_checks = commit_checks + 1;
            check_active_metadata();
            @(negedge clk);
            layer_command_valid = 1'b0;

            guard = 0;
            while (!engine_read_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 40)
                    fail("overlapped old-generation read timed out");
            end
            if ((engine_read_descriptor !== old_descriptor) ||
                (engine_read_generation !== old_generation) ||
                engine_read_busy)
                fail("overlapped read did not preserve old bank/generation");
            overlap_checks = overlap_checks + 1;
            read_checks = read_checks + 1;
            @(posedge clk);
            #1;
            if (engine_read_valid || (engine_read_descriptor != 0))
                fail("overlap read response did not clear");
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            held_command = 1'b0;
        end else begin
            if (held_command) begin
                command_hold_checks = command_hold_checks + 1;
                if (!layer_command_valid ||
                    ({load_count, layer_command_index,
                      layer_command_descriptor} !== held_command_payload))
                    fail("command payload changed during 16-word serialization");
            end
            if (layer_command_valid && !layer_command_ready && !load_abort)
                command_stall_cycles = command_stall_cycles + 1;
            if (engine_read_busy && engine_read_ready)
                fail("engine read busy and ready asserted together");
            held_command = layer_command_valid && !layer_command_ready &&
                           !load_abort;
            held_command_payload = {load_count, layer_command_index,
                                    layer_command_descriptor};
        end
    end

    initial begin
        integer stage_index;
        integer gap;
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!layer_command_ready || !engine_read_ready || engine_read_busy ||
            loading || (active_count != 0) || (generation != 0))
            fail("reset/idle contract mismatch");

        current_phase = 1;
        send_command(90, 3, 1, 1, ERROR_START_INDEX, 1'b0);
        send_command(91, 0, 0, 1, ERROR_COUNT_ZERO, 1'b0);
        send_command(92, MAX_STAGES + 1, 0, 1,
                     ERROR_COUNT_RANGE, 1'b0);
        abort_mid_serialization();

        current_phase = 2;
        for (stage_index = 0; stage_index < 4;
             stage_index = stage_index + 1) begin
            prng = prng_next(prng);
            gap = prng[1:0];
            send_command(1, 4, stage_index, gap, ERROR_NONE,
                         stage_index == 3);
        end
        check_all_active_reads();

        current_phase = 3;
        send_command(2, 5, 0, 1, ERROR_NONE, 1'b0);
        send_command(2, 5, 1, 1, ERROR_NONE, 1'b0);
        check_read(0);
        check_read(3);
        pulse_abort();
        check_all_active_reads();

        current_phase = 4;
        send_command(30, 3, 0, 0, ERROR_NONE, 1'b0);
        send_command(30, 3, 2, 0, ERROR_ORDER, 1'b0);
        send_command(31, 3, 0, 0, ERROR_NONE, 1'b0);
        send_command(31, 4, 1, 0, ERROR_COUNT_CHANGED, 1'b0);
        send_command(32, MAX_STAGES, 0, 0, ERROR_NONE, 1'b0);
        send_command(32, MAX_STAGES, MAX_STAGES, 0,
                     ERROR_INDEX_RANGE, 1'b0);
        check_all_active_reads();

        current_phase = 5;
        for (stage_index = 0; stage_index < MAX_STAGES - 1;
             stage_index = stage_index + 1) begin
            prng = prng_next(prng);
            gap = prng[1:0];
            send_command(4, MAX_STAGES, stage_index, gap,
                         ERROR_NONE, 1'b0);
        end
        commit_with_overlapping_read(4, MAX_STAGES, MAX_STAGES - 1);
        if (model_bank != 0 || model_generation != 2)
            fail("second commit did not wrap active bank to zero");
        check_all_active_reads();

        current_phase = 6;
        send_command(5, 1, 0, 1, ERROR_NONE, 1'b1);
        check_all_active_reads();
        send_command(6, 2, 0, 1, ERROR_NONE, 1'b0);
        send_command(6, 2, 1, 1, ERROR_NONE, 1'b1);
        if (model_generation != 0 || generation != 0)
            fail("generation did not wrap modulo two bits");
        check_all_active_reads();

        if ((accepted_commands != 40) || (commit_checks != 4) ||
            (error_checks != 6) || (abort_checks != 2) ||
            (overlap_checks != 1) || (command_stall_cycles < 500) ||
            (command_hold_checks == 0) || (source_gap_cycles == 0) ||
            (read_checks < 40) || (read_busy_cycles < 500) ||
            (read_ready_stall_checks == 0))
            fail("serializer/read/error/abort/commit coverage incomplete");

        abort_commit_boundary(0);
        abort_commit_boundary(1);
        // The discarded final descriptor must not prevent a fresh commit.
        send_command(83,1,0,0,ERROR_NONE,1'b1);
        check_all_active_reads();
        $display("C1_STAGE_ABORT_COMMIT_RESTART_PASS boundaries=2 restart=1");
        $display("C1_R1_STAGE_CONFIG_BANK_PASS commands=%0d commits=%0d errors=%0d aborts=%0d command_stalls=%0d command_holds=%0d gaps=%0d reads=%0d read_busy_cycles=%0d read_ready_stalls=%0d overlap=%0d generation=%0d",
                 accepted_commands, commit_checks, error_checks, abort_checks,
                 command_stall_cycles, command_hold_checks,
                 source_gap_cycles, read_checks, read_busy_cycles,
                 read_ready_stall_checks, overlap_checks, generation);
        $finish;
    end

    initial begin
        #20_000_000;
        fail("global timeout/deadlock");
    end

endmodule
