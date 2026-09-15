`timescale 1ns/1ps

module tb_c1_r1_config_loader_subsystem;
    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;
    localparam integer MEMORY_DESCRIPTORS = 32;
    localparam integer MEMORY_BEATS = MEMORY_DESCRIPTORS * 4;
    localparam logic [31:0] MEMORY_BASE = 32'h0040_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start_pulse = 1'b0;
    logic abort_pulse = 1'b0;
    logic [COUNT_BITS-1:0] descriptor_count = '0;
    logic [31:0] descriptor_base = MEMORY_BASE;
    logic command_accept_enable;
    logic force_command_block = 1'b0;

    logic busy;
    logic done_pulse;
    logic error_pulse;
    logic aborted_pulse;
    logic config_loading;
    logic config_commit_pulse;
    logic active_bank;
    logic [COUNT_BITS-1:0] active_count;
    logic [GENERATION_BITS-1:0] generation;

    logic engine_read_enable = 1'b0;
    logic [COUNT_BITS-1:0] engine_read_index = '0;
    logic engine_read_ready;
    logic engine_read_busy;
    logic engine_read_valid;
    logic [511:0] engine_read_descriptor;
    logic [GENERATION_BITS-1:0] engine_read_generation;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready = 1'b0;
    logic [127:0] m_axi_rdata = '0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;

    logic [127:0] axi_memory [0:MEMORY_BEATS-1];
    logic [31:0] prng = 32'h69f3_2a17;
    integer inject_axi_error_descriptor = -1;
    integer inject_axi_error_beat = -1;
    logic slave_burst_active = 1'b0;
    integer slave_memory_beat = 0;
    integer slave_descriptor_index = 0;
    integer slave_beat_index = 0;
    integer slave_gap_countdown = 0;

    integer current_phase = 0;
    integer current_run_tag = -1;
    integer run_next_ar_index = 0;
    integer run_next_bank_index = 0;
    logic score_run_active = 1'b0;
    integer cycle_count = 0;
    integer last_commit_cycle = -100;
    integer start_count = 0;
    integer done_count = 0;
    integer error_count = 0;
    integer aborted_count = 0;
    integer commit_count = 0;
    integer ar_count = 0;
    integer rbeat_count = 0;
    integer bank_command_count = 0;
    integer ar_stall_cycles = 0;
    integer r_gap_cycles = 0;
    integer command_stall_cycles = 0;
    integer decoder_hold_checks = 0;
    integer active_read_checks = 0;
    integer pollution_checks = 0;

    logic ar_held = 1'b0;
    logic [31:0] held_araddr = '0;
    logic [7:0] held_arlen = '0;
    logic [2:0] held_arsize = '0;
    logic [1:0] held_arburst = '0;
    logic decoder_held = 1'b0;
    logic [511:0] held_decoder_descriptor = '0;
    logic [COUNT_BITS-1:0] held_decoder_index = '0;
    logic previous_done = 1'b0;
    logic previous_error = 1'b0;
    logic previous_aborted = 1'b0;

    assign command_accept_enable = !force_command_block &&
                                   (prng[2] || prng[11]);

    c1_r1_config_loader_subsystem #(
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .SYNC_READ(1'b1),
        .FAST_WIDE(1'b0)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic [511:0] legal_descriptor(
        input integer batch_tag,
        input integer stage_index
    );
        logic [511:0] descriptor;
        logic [15:0] dimension;
        begin
            descriptor = '0;
            dimension = 16'd8 + (stage_index % 5);
            descriptor[7:0] = 8'd2; // CONV1X1
            descriptor[9:8] = stage_index[0] ? 2'd1 : 2'd0;
            descriptor[15:10] = 6'd0;
            descriptor[23:16] = 8'd1;
            descriptor[31:24] = 8'd16;
            descriptor[47:32] = dimension;
            descriptor[63:48] = dimension + 16'd1;
            descriptor[79:64] = dimension;
            descriptor[95:80] = dimension + 16'd1;
            descriptor[111:96] = 16'd8;
            descriptor[127:112] = 16'd8;
            descriptor[159:128] = 32'h0001_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[191:160] = 32'h0010_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[223:192] = 32'd0;
            descriptor[255:224] = 32'h0020_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[287:256] = 32'h0030_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[319:288] = 32'h0040_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[351:320] = 32'h0050_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[383:352] = 32'd0;
            descriptor[415:384] = 32'd0;
            descriptor[423:416] = 8'd1;
            descriptor[431:424] = 8'd1;
            descriptor[439:432] = 8'd1;
            descriptor[447:440] = 8'd1;
            descriptor[455:448] = 8'd8;
            descriptor[463:456] = 8'd8;
            descriptor[471:464] = 8'd4;
            descriptor[479:472] = 8'd4;
            descriptor[511:480] = 32'd1000 + batch_tag * 32'd100 +
                                   stage_index;
            legal_descriptor = descriptor;
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_R1_CONFIG_LOADER_SUBSYSTEM_FAIL time=%0t phase=%0d: %s",
                     $time, current_phase, message);
            $fatal(1);
            $finish;
        end
    endtask

    task automatic load_memory(
        input integer batch_tag,
        input integer count_value,
        input integer invalid_index
    );
        integer descriptor_index;
        integer beat_index;
        logic [511:0] descriptor;
        begin
            for (descriptor_index = 0; descriptor_index < count_value;
                 descriptor_index = descriptor_index + 1) begin
                descriptor = legal_descriptor(batch_tag, descriptor_index);
                if (descriptor_index == invalid_index)
                    descriptor[23:16] = 8'h7f;
                for (beat_index = 0; beat_index < 4;
                     beat_index = beat_index + 1)
                    axi_memory[descriptor_index*4 + beat_index] =
                        descriptor[beat_index*128 +: 128];
            end
        end
    endtask

    function automatic [511:0] memory_descriptor(input integer index_value);
        begin
            memory_descriptor = {
                axi_memory[index_value*4 + 3],
                axi_memory[index_value*4 + 2],
                axi_memory[index_value*4 + 1],
                axi_memory[index_value*4 + 0]
            };
        end
    endfunction

    task automatic begin_run(
        input integer batch_tag,
        input integer count_value
    );
        begin
            while (busy || slave_burst_active || m_axi_rvalid)
                @(negedge clk);
            @(negedge clk);
            current_run_tag = batch_tag;
            run_next_ar_index = 0;
            run_next_bank_index = 0;
            score_run_active = 1'b1;
            descriptor_count = count_value;
            descriptor_base = MEMORY_BASE;
            start_pulse = 1'b1;
            start_count = start_count + 1;
            @(posedge clk);
            #1;
            if (!busy)
                fail("start did not enter busy state");
            @(negedge clk);
            start_pulse = 1'b0;
        end
    endtask

    task automatic wait_done_target(input integer target);
        integer guard;
        begin
            guard = 0;
            while (done_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("timeout waiting for done");
            end
        end
    endtask

    task automatic wait_error_target(input integer target);
        integer guard;
        begin
            guard = 0;
            while (error_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("timeout waiting for error");
            end
        end
    endtask

    task automatic wait_aborted_target(input integer target);
        integer guard;
        begin
            guard = 0;
            while (aborted_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("timeout waiting for aborted");
            end
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort_pulse = 1'b0;
        end
    endtask

    task automatic wait_pipeline_quiet;
        integer guard;
        begin
            guard = 0;
            while (busy || config_loading || slave_burst_active ||
                   m_axi_rvalid || dut.decoder_command_valid ||
                   dut.bank_result_pending_q) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("timeout waiting for pipeline to become quiet");
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic check_active_descriptor(
        input integer batch_tag,
        input integer stage_index,
        input integer expected_count,
        input integer expected_generation
    );
        logic [511:0] expected_descriptor;
        integer guard;
        begin
            expected_descriptor = legal_descriptor(batch_tag, stage_index);
            while (!engine_read_ready)
                @(negedge clk);
            @(negedge clk);
            engine_read_enable = 1'b1;
            engine_read_index = stage_index;
            @(posedge clk);
            @(negedge clk);
            engine_read_enable = 1'b0;
            guard = 0;
            while (!engine_read_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (engine_read_busy && engine_read_ready)
                    fail("narrow engine read ready asserted while busy");
                if (guard > 40)
                    fail("narrow active descriptor read timed out");
            end
            if (!engine_read_valid ||
                (engine_read_descriptor !== expected_descriptor) ||
                (engine_read_generation !== expected_generation) ||
                (active_count !== expected_count) || engine_read_busy ||
                !engine_read_ready)
                fail("active descriptor/count/generation mismatch");
            active_read_checks = active_read_checks + 1;
            @(posedge clk);
            #1;
            if (engine_read_valid || (engine_read_descriptor != 0))
                fail("disabled engine read remained valid/nonzero");
        end
    endtask

    task automatic check_entire_active_bank(
        input integer batch_tag,
        input integer count_value,
        input integer expected_generation
    );
        integer stage_index;
        begin
            for (stage_index = 0; stage_index < count_value;
                 stage_index = stage_index + 1)
                check_active_descriptor(batch_tag, stage_index,
                                        count_value, expected_generation);
            while (!engine_read_ready)
                @(negedge clk);
            @(negedge clk);
            engine_read_enable = 1'b1;
            engine_read_index = count_value;
            @(posedge clk);
            @(negedge clk);
            engine_read_enable = 1'b0;
            if (engine_read_valid || engine_read_busy ||
                (engine_read_descriptor != 0))
                fail("out-of-active-count engine read was not rejected");
        end
    endtask

    task automatic check_active_unpolluted(
        input integer batch_tag,
        input integer count_value,
        input integer expected_generation,
        input logic expected_bank
    );
        begin
            wait_pipeline_quiet();
            if ((active_bank !== expected_bank) ||
                (active_count !== count_value) ||
                (generation !== expected_generation))
                fail("failed/aborted load changed active metadata");
            check_active_descriptor(batch_tag, 0, count_value,
                                    expected_generation);
            check_active_descriptor(batch_tag, count_value - 1,
                                    count_value, expected_generation);
            pollution_checks = pollution_checks + 1;
        end
    endtask

    // Terminal and end-to-end order scoreboard.  Sampling at negedge observes
    // complete registered pulses without NBA races.
    always @(negedge clk) begin
        if (rst) begin
            cycle_count = 0;
            previous_done = 1'b0;
            previous_error = 1'b0;
            previous_aborted = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;
            if ((done_pulse && error_pulse) ||
                (done_pulse && aborted_pulse) ||
                (error_pulse && aborted_pulse))
                fail("multiple terminal pulses asserted together");
            if ((done_pulse && previous_done) ||
                (error_pulse && previous_error) ||
                (aborted_pulse && previous_aborted))
                fail("terminal output was wider than one cycle");

            if (config_commit_pulse) begin
                if (!score_run_active)
                    fail("configuration commit occurred outside a run");
                commit_count = commit_count + 1;
                last_commit_cycle = cycle_count;
            end
            if (done_pulse) begin
                if (!score_run_active)
                    fail("done occurred outside a run");
                if (last_commit_cycle != cycle_count - 1)
                    fail("scheduler done was not exactly one cycle after commit");
                done_count = done_count + 1;
                score_run_active = 1'b0;
            end
            if (error_pulse) begin
                if (!score_run_active)
                    fail("error occurred outside a run");
                error_count = error_count + 1;
                score_run_active = 1'b0;
            end
            if (aborted_pulse) begin
                if (!score_run_active)
                    fail("aborted occurred outside a run");
                aborted_count = aborted_count + 1;
                score_run_active = 1'b0;
            end
            previous_done = done_pulse;
            previous_error = error_pulse;
            previous_aborted = aborted_pulse;
        end
    end

    // AXI request protocol/order and payload stability under ARREADY stalls.
    always @(posedge clk) begin
        if (rst) begin
            ar_held = 1'b0;
        end else begin
            if (m_axi_arvalid) begin
                if ((m_axi_arlen !== 8'd3) ||
                    (m_axi_arsize !== 3'd4) ||
                    (m_axi_arburst !== 2'b01) ||
                    (m_axi_araddr[5:0] != 0))
                    fail("illegal AXI descriptor read burst");
            end
            if (ar_held) begin
                if (!m_axi_arvalid || (m_axi_araddr !== held_araddr) ||
                    (m_axi_arlen !== held_arlen) ||
                    (m_axi_arsize !== held_arsize) ||
                    (m_axi_arburst !== held_arburst))
                    fail("AR payload changed while stalled");
            end
            if (m_axi_arvalid && !m_axi_arready) begin
                ar_stall_cycles = ar_stall_cycles + 1;
                ar_held = 1'b1;
                held_araddr = m_axi_araddr;
                held_arlen = m_axi_arlen;
                held_arsize = m_axi_arsize;
                held_arburst = m_axi_arburst;
            end else begin
                ar_held = 1'b0;
            end
            if (m_axi_arvalid && m_axi_arready) begin
                if (!score_run_active)
                    fail("AXI request occurred outside active run");
                if (m_axi_araddr !==
                    (MEMORY_BASE + run_next_ar_index * 32'd64))
                    fail("AXI descriptor request address/order mismatch");
                run_next_ar_index = run_next_ar_index + 1;
                ar_count = ar_count + 1;
            end
        end
    end

    // Decoder output must remain stable across the externally generated
    // command gate stalls.  Every bank transfer must preserve index and raw
    // descriptor bytes from AXI memory.
    always @(posedge clk) begin
        if (rst || abort_pulse) begin
            decoder_held = 1'b0;
        end else begin
            if (decoder_held) begin
                decoder_hold_checks = decoder_hold_checks + 1;
                if (!dut.decoder_command_valid ||
                    (dut.decoder_command_descriptor !==
                     held_decoder_descriptor) ||
                    (dut.decoder_index_q !== held_decoder_index))
                    fail("decoded command/index changed while stalled");
            end
            if (dut.decoder_command_valid &&
                !dut.decoder_command_ready) begin
                command_stall_cycles = command_stall_cycles + 1;
                decoder_held = 1'b1;
                held_decoder_descriptor = dut.decoder_command_descriptor;
                held_decoder_index = dut.decoder_index_q;
            end else begin
                decoder_held = 1'b0;
            end

            if (dut.bank_command_fire) begin
                if (!score_run_active)
                    fail("bank command accepted outside active run");
                if (dut.decoder_index_q !==
                    run_next_bank_index[COUNT_BITS-1:0])
                    fail("bank command index/order mismatch");
                if (dut.decoder_command_descriptor !==
                    memory_descriptor(run_next_bank_index))
                    fail("bank command descriptor differs from AXI memory");
                run_next_bank_index = run_next_bank_index + 1;
                bank_command_count = bank_command_count + 1;
            end
        end
    end

    // AXI128 memory BFM: random AR backpressure and random inter-beat gaps.
    // Once AR commits, all four beats are returned even if the loader aborts.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= '0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            slave_burst_active <= 1'b0;
            slave_memory_beat <= 0;
            slave_descriptor_index <= 0;
            slave_beat_index <= 0;
            slave_gap_countdown <= 0;
            rbeat_count <= 0;
            r_gap_cycles <= 0;
        end else begin
            if (slave_burst_active || m_axi_rvalid)
                m_axi_arready <= 1'b0;
            else
                m_axi_arready <= prng[0] || prng[8];

            if (m_axi_arvalid && m_axi_arready) begin
                if (slave_burst_active || m_axi_rvalid)
                    fail("AXI BFM accepted multiple outstanding bursts");
                if ((m_axi_araddr < MEMORY_BASE) ||
                    (((m_axi_araddr - MEMORY_BASE) >> 6) >=
                     MEMORY_DESCRIPTORS))
                    fail("AXI request outside descriptor memory");
                slave_burst_active <= 1'b1;
                slave_memory_beat <= (m_axi_araddr - MEMORY_BASE) >> 4;
                slave_descriptor_index <=
                    (m_axi_araddr - MEMORY_BASE) >> 6;
                slave_beat_index <= 0;
                slave_gap_countdown <= 1 + (prng[4:3] % 3);
            end

            if (m_axi_rvalid) begin
                if (m_axi_rready) begin
                    rbeat_count <= rbeat_count + 1;
                    m_axi_rvalid <= 1'b0;
                    if (slave_beat_index == 3) begin
                        slave_burst_active <= 1'b0;
                        slave_gap_countdown <= 0;
                    end else begin
                        slave_beat_index <= slave_beat_index + 1;
                        slave_gap_countdown <= prng[10:9] % 3;
                    end
                end
            end else if (slave_burst_active) begin
                if (slave_gap_countdown > 0) begin
                    slave_gap_countdown <= slave_gap_countdown - 1;
                    r_gap_cycles <= r_gap_cycles + 1;
                end else begin
                    m_axi_rdata <=
                        axi_memory[slave_memory_beat + slave_beat_index];
                    if ((slave_descriptor_index ==
                         inject_axi_error_descriptor) &&
                        (slave_beat_index == inject_axi_error_beat))
                        m_axi_rresp <= 2'b10;
                    else
                        m_axi_rresp <= 2'b00;
                    m_axi_rlast <= (slave_beat_index == 3);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            prng <= 32'h69f3_2a17;
        else
            prng <= {prng[30:0],
                     prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
    end

    initial begin
        integer start_ar;
        integer start_rbeat;
        integer start_bank_commands;
        integer start_commit;
        integer start_done;
        integer start_error;
        integer start_aborted;
        integer guard;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Full 22-stage load.  Force the first decoded command to wait, then
        // let the random command gate/AXI gaps drive the remainder.
        current_phase = 1;
        load_memory(1, MAX_STAGES, -1);
        force_command_block = 1'b1;
        start_ar = ar_count;
        start_rbeat = rbeat_count;
        start_bank_commands = bank_command_count;
        start_commit = commit_count;
        start_done = done_count;
        begin_run(1, MAX_STAGES);
        guard = 0;
        while (!dut.decoder_command_valid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 10000)
                fail("decoder command did not arrive for forced stall");
        end
        repeat (5) @(posedge clk);
        @(negedge clk);
        force_command_block = 1'b0;
        wait_done_target(start_done + 1);
        wait_pipeline_quiet();
        if (((ar_count - start_ar) != MAX_STAGES) ||
            ((rbeat_count - start_rbeat) != MAX_STAGES * 4) ||
            ((bank_command_count - start_bank_commands) != MAX_STAGES) ||
            ((commit_count - start_commit) != 1) ||
            (active_count != MAX_STAGES) || (generation != 1) ||
            !active_bank)
            fail("first 22-stage success accounting/metadata mismatch");
        check_entire_active_bank(1, MAX_STAGES, 1);

        // Descriptor seven has an invalid ABI version.  Descriptors 0..6 may
        // enter shadow, but the decoder error must abort without a commit.
        current_phase = 2;
        load_memory(2, MAX_STAGES, 7);
        start_ar = ar_count;
        start_bank_commands = bank_command_count;
        start_commit = commit_count;
        start_error = error_count;
        begin_run(2, MAX_STAGES);
        wait_error_target(start_error + 1);
        if (((ar_count - start_ar) != 8) ||
            ((bank_command_count - start_bank_commands) != 7) ||
            (commit_count != start_commit))
            fail("invalid descriptor termination accounting mismatch");
        check_active_unpolluted(1, MAX_STAGES, 1, 1'b1);

        // AXI SLVERR on descriptor five: four earlier descriptors may enter
        // shadow, descriptor five is drained but never decoded/stored.
        current_phase = 3;
        load_memory(3, MAX_STAGES, -1);
        inject_axi_error_descriptor = 5;
        inject_axi_error_beat = 2;
        start_ar = ar_count;
        start_rbeat = rbeat_count;
        start_bank_commands = bank_command_count;
        start_commit = commit_count;
        start_error = error_count;
        begin_run(3, MAX_STAGES);
        wait_error_target(start_error + 1);
        wait_pipeline_quiet();
        if (((ar_count - start_ar) != 6) ||
            ((rbeat_count - start_rbeat) != 24) ||
            ((bank_command_count - start_bank_commands) != 5) ||
            (commit_count != start_commit))
            fail("AXI error termination/drain accounting mismatch");
        inject_axi_error_descriptor = -1;
        inject_axi_error_beat = -1;
        check_active_unpolluted(1, MAX_STAGES, 1, 1'b1);

        // Abort after at least five shadow writes and while the next AXI burst
        // is outstanding.  The reader must drain it, but no command may leak.
        current_phase = 4;
        load_memory(4, MAX_STAGES, -1);
        start_commit = commit_count;
        start_aborted = aborted_count;
        start_rbeat = rbeat_count;
        begin_run(4, MAX_STAGES);
        guard = 0;
        while (!((dut.bank_shadow_count >= 5) && slave_burst_active)) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 100000)
                fail("abort target state was not reached");
        end
        pulse_abort();
        wait_aborted_target(start_aborted + 1);
        wait_pipeline_quiet();
        if ((commit_count != start_commit) ||
            ((rbeat_count - start_rbeat) < 24))
            fail("aborted run committed or failed to drain traffic");
        check_active_unpolluted(1, MAX_STAGES, 1, 1'b1);

        // A second complete 22-stage load proves recovery from every failure
        // and atomically switches back to bank zero/generation two.
        current_phase = 5;
        load_memory(5, MAX_STAGES, -1);
        start_ar = ar_count;
        start_rbeat = rbeat_count;
        start_bank_commands = bank_command_count;
        start_commit = commit_count;
        start_done = done_count;
        begin_run(5, MAX_STAGES);
        wait_done_target(start_done + 1);
        wait_pipeline_quiet();
        if (((ar_count - start_ar) != MAX_STAGES) ||
            ((rbeat_count - start_rbeat) != MAX_STAGES * 4) ||
            ((bank_command_count - start_bank_commands) != MAX_STAGES) ||
            ((commit_count - start_commit) != 1) || active_bank ||
            (active_count != MAX_STAGES) || (generation != 2))
            fail("second successful switch accounting/metadata mismatch");
        check_entire_active_bank(5, MAX_STAGES, 2);

        wait_pipeline_quiet();
        if ((start_count != 5) || (done_count != 2) ||
            (error_count != 2) || (aborted_count != 1) ||
            (commit_count != 2) || (pollution_checks != 3) ||
            (ar_stall_cycles == 0) || (r_gap_cycles == 0) ||
            (command_stall_cycles < 5) || (decoder_hold_checks == 0) ||
            (active_read_checks < 48) ||
            (rbeat_count != ar_count * 4))
            fail("terminal/stall/drain/pollution/read coverage incomplete");

        $display("C1_R1_CONFIG_LOADER_SUBSYSTEM_PASS starts=%0d done=%0d errors=%0d aborted=%0d commits=%0d ar=%0d rbeats=%0d bank_commands=%0d ar_stalls=%0d r_gaps=%0d command_stalls=%0d decoder_holds=%0d reads=%0d pollution=%0d generation=%0d",
                 start_count, done_count, error_count, aborted_count,
                 commit_count, ar_count, rbeat_count, bank_command_count,
                 ar_stall_cycles, r_gap_cycles, command_stall_cycles,
                 decoder_hold_checks, active_read_checks, pollution_checks,
                 generation);
        $finish;
    end

    initial begin
        #20_000_000;
        fail("global timeout/deadlock");
    end

endmodule
