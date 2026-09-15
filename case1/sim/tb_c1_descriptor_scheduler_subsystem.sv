`timescale 1ns/1ps

module tb_c1_descriptor_scheduler_subsystem;

    localparam integer COUNT_BITS = 16;
    localparam integer MEMORY_DESCRIPTORS = 64;
    localparam integer MEMORY_BEATS = MEMORY_DESCRIPTORS * 4;
    localparam logic [31:0] MEMORY_BASE = 32'h0010_0000;

    localparam integer TERMINAL_DONE = 0;
    localparam integer TERMINAL_ERROR = 1;
    localparam integer TERMINAL_ABORTED = 2;

    logic clk;
    logic rst;
    logic start_pulse;
    logic abort_pulse;
    logic [COUNT_BITS-1:0] descriptor_count;
    logic [31:0] descriptor_base;

    logic layer_command_valid;
    logic layer_command_ready;
    logic [COUNT_BITS-1:0] layer_command_index;
    logic [511:0] layer_command_descriptor;
    logic layer_done_pulse;
    logic layer_error_pulse;

    logic busy;
    logic done_pulse;
    logic error_pulse;
    logic aborted_pulse;
    logic [COUNT_BITS-1:0] active_layer_index;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;

    logic [127:0] axi_memory [0:MEMORY_BEATS-1];
    logic [31:0] prng;

    logic force_ar_block;
    logic force_long_initial_r_gap;
    integer inject_rresp_descriptor;
    integer inject_rresp_beat;
    integer inject_layer_error_index;

    logic slave_burst_active;
    integer slave_memory_beat;
    integer slave_descriptor_index;
    logic [1:0] slave_beat_index;
    integer slave_gap_countdown;
    integer slave_error_beat;

    logic consumer_active;
    logic [COUNT_BITS-1:0] consumer_index;
    integer consumer_delay;
    logic consumer_send_error;

    logic score_run_active;
    logic [31:0] score_base;
    integer score_descriptor_count;
    integer score_next_ar_index;
    integer score_next_layer_index;
    integer score_expected_ar_count;
    integer score_expected_launch_count;
    integer score_terminal_kind;

    integer start_count;
    integer command_count;
    integer done_count;
    integer error_count;
    integer aborted_count;
    integer layer_done_count;
    integer layer_error_count;
    integer ar_count;
    integer rbeat_count;
    integer ar_stall_count;
    integer r_gap_count;
    integer layer_stall_count;

    logic previous_done;
    logic previous_error;
    logic previous_aborted;
    logic ar_hold_active;
    logic [31:0] held_araddr;
    logic [7:0] held_arlen;
    logic [2:0] held_arsize;
    logic [1:0] held_arburst;
    logic r_hold_active;
    logic [127:0] held_rdata;
    logic [1:0] held_rresp;
    logic held_rlast;

    integer descriptor_number;
    integer beat_number;
    integer lane_number;
    integer start_done_count;
    integer start_error_count;
    integer start_aborted_count;
    integer start_ar_count;
    integer start_command_count;
    integer start_rbeat_count;

    c1_descriptor_scheduler_subsystem #(
        .COUNT_BITS(COUNT_BITS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_pulse(start_pulse),
        .abort_pulse(abort_pulse),
        .descriptor_count(descriptor_count),
        .descriptor_base(descriptor_base),
        .layer_command_valid(layer_command_valid),
        .layer_command_ready(layer_command_ready),
        .layer_command_index(layer_command_index),
        .layer_command_descriptor(layer_command_descriptor),
        .layer_done_pulse(layer_done_pulse),
        .layer_error_pulse(layer_error_pulse),
        .busy(busy),
        .done_pulse(done_pulse),
        .error_pulse(error_pulse),
        .aborted_pulse(aborted_pulse),
        .active_layer_index(active_layer_index),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic [31:0] descriptor_word(
        input integer descriptor_value,
        input integer word_value
    );
        logic [31:0] descriptor_bits;
        logic [31:0] word_bits;
        begin
            descriptor_bits = descriptor_value;
            word_bits = word_value;
            descriptor_word = 32'h51a7_0000 ^
                              (descriptor_bits * 32'h0001_1021) ^
                              (word_bits * 32'h9e37_79b9);
        end
    endfunction

    function automatic [511:0] loaded_descriptor(
        input integer descriptor_value
    );
        logic [511:0] result;
        integer beat_value;
        begin
            result = 512'd0;
            for (beat_value = 0; beat_value < 4; beat_value = beat_value + 1) begin
                result[beat_value*128 +: 128] =
                    axi_memory[descriptor_value*4 + beat_value];
            end
            loaded_descriptor = result;
        end
    endfunction

    task automatic begin_run(
        input integer count_value,
        input integer terminal_kind_value,
        input integer expected_ar_value,
        input integer expected_launch_value
    );
        begin
            @(negedge clk);
            if (score_run_active) begin
                $fatal(1, "attempted to start while scoreboard run remained active");
            end
            if (busy) begin
                $fatal(1, "attempted to start while scheduler busy");
            end

            score_run_active = 1'b1;
            score_base = MEMORY_BASE;
            score_descriptor_count = count_value;
            score_next_ar_index = 0;
            score_next_layer_index = 0;
            score_expected_ar_count = expected_ar_value;
            score_expected_launch_count = expected_launch_value;
            score_terminal_kind = terminal_kind_value;

            descriptor_base = MEMORY_BASE;
            descriptor_count = count_value;
            start_pulse = 1'b1;
            start_count = start_count + 1;
            @(posedge clk);
            @(negedge clk);
            start_pulse = 1'b0;

            if (!busy) begin
                $fatal(1, "scheduler failed to enter busy after start");
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

    task automatic wait_done_count(input integer target);
        integer guard;
        begin
            guard = 0;
            while (done_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "done timeout target=%0d", target);
            end
        end
    endtask

    task automatic wait_error_count(input integer target);
        integer guard;
        begin
            guard = 0;
            while (error_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "error timeout target=%0d", target);
            end
        end
    endtask

    task automatic wait_aborted_count(input integer target);
        integer guard;
        begin
            guard = 0;
            while (aborted_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "aborted timeout target=%0d", target);
            end
        end
    endtask

    task automatic wait_ar_count(input integer target);
        integer guard;
        begin
            guard = 0;
            while (ar_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "AR timeout target=%0d", target);
            end
        end
    endtask

    // End-to-end scoreboard: AXI descriptor request order, command order and
    // complete 512-bit payload are checked against the loaded AXI memory.
    always @(posedge clk) begin
        if (rst) begin
            score_run_active = 1'b0;
            score_base = 32'd0;
            score_descriptor_count = 0;
            score_next_ar_index = 0;
            score_next_layer_index = 0;
            score_expected_ar_count = 0;
            score_expected_launch_count = 0;
            score_terminal_kind = TERMINAL_DONE;
            command_count = 0;
            done_count = 0;
            error_count = 0;
            aborted_count = 0;
            previous_done = 1'b0;
            previous_error = 1'b0;
            previous_aborted = 1'b0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                if (!score_run_active) begin
                    $fatal(1, "AXI descriptor request occurred without an active run");
                end
                if (m_axi_araddr !==
                    (score_base + score_next_ar_index * 32'd64)) begin
                    $fatal(1, "descriptor AR order/address mismatch index=%0d expected=%08x got=%08x",
                           score_next_ar_index,
                           score_base + score_next_ar_index * 32'd64,
                           m_axi_araddr);
                end
                score_next_ar_index = score_next_ar_index + 1;
            end

            if (layer_command_valid && layer_command_ready) begin
                if (!score_run_active) begin
                    $fatal(1, "layer command occurred without an active run");
                end
                if (layer_command_index !== score_next_layer_index[COUNT_BITS-1:0]) begin
                    $fatal(1, "layer command order mismatch expected=%0d got=%0d",
                           score_next_layer_index, layer_command_index);
                end
                if (layer_command_descriptor !== loaded_descriptor(score_next_layer_index)) begin
                    $fatal(1, "layer descriptor payload mismatch index=%0d",
                           score_next_layer_index);
                end
                if (active_layer_index !== layer_command_index) begin
                    $fatal(1, "active_layer_index disagrees with command index");
                end
                score_next_layer_index = score_next_layer_index + 1;
                command_count = command_count + 1;
            end

            if ((done_pulse && error_pulse) ||
                (done_pulse && aborted_pulse) ||
                (error_pulse && aborted_pulse)) begin
                $fatal(1, "multiple scheduler terminal pulses asserted together");
            end

            if (done_pulse || error_pulse || aborted_pulse) begin
                if (!score_run_active) begin
                    $fatal(1, "terminal pulse occurred without an active run");
                end
                if (score_next_ar_index != score_expected_ar_count) begin
                    $fatal(1, "terminal AR count mismatch expected=%0d got=%0d",
                           score_expected_ar_count, score_next_ar_index);
                end
                if (score_next_layer_index != score_expected_launch_count) begin
                    $fatal(1, "terminal command count mismatch expected=%0d got=%0d",
                           score_expected_launch_count, score_next_layer_index);
                end
            end

            if (done_pulse) begin
                if (score_terminal_kind != TERMINAL_DONE) begin
                    $fatal(1, "unexpected done terminal");
                end
                if (score_expected_launch_count != score_descriptor_count) begin
                    $fatal(1, "successful run did not launch every descriptor");
                end
                done_count = done_count + 1;
                score_run_active = 1'b0;
            end

            if (error_pulse) begin
                if (score_terminal_kind != TERMINAL_ERROR) begin
                    $fatal(1, "unexpected error terminal");
                end
                error_count = error_count + 1;
                score_run_active = 1'b0;
            end

            if (aborted_pulse) begin
                if (score_terminal_kind != TERMINAL_ABORTED) begin
                    $fatal(1, "unexpected aborted terminal");
                end
                aborted_count = aborted_count + 1;
                score_run_active = 1'b0;
            end

            if ((done_pulse && previous_done) ||
                (error_pulse && previous_error) ||
                (aborted_pulse && previous_aborted)) begin
                $fatal(1, "scheduler terminal output was not a one-cycle pulse");
            end
            previous_done = done_pulse;
            previous_error = error_pulse;
            previous_aborted = aborted_pulse;
        end
    end

    // AXI protocol/stability monitor.
    always @(posedge clk) begin
        if (rst) begin
            ar_hold_active <= 1'b0;
            held_araddr <= 32'd0;
            held_arlen <= 8'd0;
            held_arsize <= 3'd0;
            held_arburst <= 2'd0;
            r_hold_active <= 1'b0;
            held_rdata <= 128'd0;
            held_rresp <= 2'd0;
            held_rlast <= 1'b0;
            ar_stall_count <= 0;
        end else begin
            if (m_axi_arvalid) begin
                if ((m_axi_arlen !== 8'd3) ||
                    (m_axi_arsize !== 3'd4) ||
                    (m_axi_arburst !== 2'b01)) begin
                    $fatal(1, "subsystem emitted illegal descriptor burst attributes");
                end
                if ((m_axi_araddr[5:0] !== 6'd0) ||
                    (m_axi_araddr[11:0] > 12'hfc0)) begin
                    $fatal(1, "subsystem emitted misaligned or 4KiB-crossing AR");
                end
            end

            if (m_axi_arvalid && !m_axi_arready) begin
                ar_stall_count <= ar_stall_count + 1;
                if (ar_hold_active &&
                    ((m_axi_araddr !== held_araddr) ||
                     (m_axi_arlen !== held_arlen) ||
                     (m_axi_arsize !== held_arsize) ||
                     (m_axi_arburst !== held_arburst))) begin
                    $fatal(1, "AR payload changed while stalled");
                end
                ar_hold_active <= 1'b1;
                held_araddr <= m_axi_araddr;
                held_arlen <= m_axi_arlen;
                held_arsize <= m_axi_arsize;
                held_arburst <= m_axi_arburst;
            end else begin
                ar_hold_active <= 1'b0;
            end

            if (m_axi_rvalid && !m_axi_rready) begin
                if (r_hold_active &&
                    ((m_axi_rdata !== held_rdata) ||
                     (m_axi_rresp !== held_rresp) ||
                     (m_axi_rlast !== held_rlast))) begin
                    $fatal(1, "AXI memory changed R payload while stalled");
                end
                r_hold_active <= 1'b1;
                held_rdata <= m_axi_rdata;
                held_rresp <= m_axi_rresp;
                held_rlast <= m_axi_rlast;
            end else begin
                r_hold_active <= 1'b0;
            end
        end
    end

    // AXI128 memory model with random AR back-pressure and random gaps between
    // R beats.  A committed burst is always completed, including after abort.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            slave_burst_active <= 1'b0;
            slave_memory_beat <= 0;
            slave_descriptor_index <= 0;
            slave_beat_index <= 2'd0;
            slave_gap_countdown <= 0;
            slave_error_beat <= -1;
            ar_count <= 0;
            rbeat_count <= 0;
            r_gap_count <= 0;
        end else begin
            if (force_ar_block) begin
                m_axi_arready <= 1'b0;
            end else begin
                m_axi_arready <= prng[0] | prng[7];
            end

            if (m_axi_arvalid && m_axi_arready) begin
                if (slave_burst_active || m_axi_rvalid) begin
                    $fatal(1, "AXI memory observed multiple outstanding reads");
                end
                if ((m_axi_araddr < MEMORY_BASE) ||
                    (((m_axi_araddr - MEMORY_BASE) >> 6) >= MEMORY_DESCRIPTORS)) begin
                    $fatal(1, "AXI descriptor address lies outside loaded memory");
                end

                ar_count <= ar_count + 1;
                slave_burst_active <= 1'b1;
                slave_memory_beat <= (m_axi_araddr - MEMORY_BASE) >> 4;
                slave_descriptor_index <= (m_axi_araddr - MEMORY_BASE) >> 6;
                slave_beat_index <= 2'd0;
                if (force_long_initial_r_gap) begin
                    slave_gap_countdown <= 16;
                end else begin
                    slave_gap_countdown <= {1'b0, prng[4:3]};
                end
                if (((m_axi_araddr - MEMORY_BASE) >> 6) == inject_rresp_descriptor) begin
                    slave_error_beat <= inject_rresp_beat;
                end else begin
                    slave_error_beat <= -1;
                end
            end

            if (m_axi_rvalid) begin
                if (m_axi_rready) begin
                    rbeat_count <= rbeat_count + 1;
                    m_axi_rvalid <= 1'b0;
                    if (slave_beat_index == 2'd3) begin
                        slave_burst_active <= 1'b0;
                        slave_gap_countdown <= 0;
                    end else begin
                        slave_beat_index <= slave_beat_index + 2'd1;
                        slave_gap_countdown <= {1'b0, prng[10:9]};
                    end
                end
            end else if (slave_burst_active) begin
                if (slave_gap_countdown > 0) begin
                    slave_gap_countdown <= slave_gap_countdown - 1;
                    r_gap_count <= r_gap_count + 1;
                end else begin
                    m_axi_rdata <= axi_memory[slave_memory_beat + slave_beat_index];
                    if (slave_error_beat == slave_beat_index) begin
                        m_axi_rresp <= 2'b10;
                    end else begin
                        m_axi_rresp <= 2'b00;
                    end
                    m_axi_rlast <= (slave_beat_index == 2'd3);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    // Randomly back-pressured layer consumer.  Every accepted command is held
    // for a random delay before completion (or the selected injected error).
    always @(posedge clk) begin
        if (rst) begin
            layer_command_ready <= 1'b0;
            layer_done_pulse <= 1'b0;
            layer_error_pulse <= 1'b0;
            consumer_active <= 1'b0;
            consumer_index <= '0;
            consumer_delay <= 0;
            consumer_send_error <= 1'b0;
            layer_done_count <= 0;
            layer_error_count <= 0;
            layer_stall_count <= 0;
        end else begin
            layer_done_pulse <= 1'b0;
            layer_error_pulse <= 1'b0;

            if (!consumer_active) begin
                layer_command_ready <= prng[2] | prng[13];
            end else begin
                layer_command_ready <= 1'b0;
            end

            if (layer_command_valid && !layer_command_ready) begin
                layer_stall_count <= layer_stall_count + 1;
            end

            if (layer_command_valid && layer_command_ready) begin
                if (consumer_active) begin
                    $fatal(1, "layer consumer accepted while already active");
                end
                consumer_active <= 1'b1;
                consumer_index <= layer_command_index;
                consumer_delay <= 1 + {1'b0, prng[17:16]};
                consumer_send_error <= (layer_command_index == inject_layer_error_index);
                layer_command_ready <= 1'b0;
            end else if (consumer_active) begin
                if (consumer_delay > 0) begin
                    consumer_delay <= consumer_delay - 1;
                end else begin
                    if (consumer_send_error) begin
                        layer_error_pulse <= 1'b1;
                        layer_error_count <= layer_error_count + 1;
                    end else begin
                        layer_done_pulse <= 1'b1;
                        layer_done_count <= layer_done_count + 1;
                    end
                    consumer_active <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            prng <= 32'h8f70_1d63;
        end else begin
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
        end
    end

    initial begin
        rst = 1'b1;
        start_pulse = 1'b0;
        abort_pulse = 1'b0;
        descriptor_count = '0;
        descriptor_base = MEMORY_BASE;
        force_ar_block = 1'b0;
        force_long_initial_r_gap = 1'b0;
        inject_rresp_descriptor = -1;
        inject_rresp_beat = -1;
        inject_layer_error_index = -1;
        start_count = 0;

        for (descriptor_number = 0;
             descriptor_number < MEMORY_DESCRIPTORS;
             descriptor_number = descriptor_number + 1) begin
            for (beat_number = 0; beat_number < 4; beat_number = beat_number + 1) begin
                axi_memory[descriptor_number*4 + beat_number] = 128'd0;
                for (lane_number = 0; lane_number < 4; lane_number = lane_number + 1) begin
                    axi_memory[descriptor_number*4 + beat_number]
                              [lane_number*32 +: 32] =
                        descriptor_word(descriptor_number, beat_number*4 + lane_number);
                end
            end
        end

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Five descriptors traverse memory -> reader -> scheduler -> consumer.
        start_done_count = done_count;
        begin_run(5, TERMINAL_DONE, 5, 5);
        wait_done_count(start_done_count + 1);

        // Descriptor one returns SLVERR on beat two.  Descriptor zero completes,
        // descriptor one never launches, and the scheduler reports error.
        inject_rresp_descriptor = 1;
        inject_rresp_beat = 2;
        start_error_count = error_count;
        begin_run(4, TERMINAL_ERROR, 2, 1);
        wait_error_count(start_error_count + 1);
        inject_rresp_descriptor = -1;
        inject_rresp_beat = -1;

        // Restart immediately after the AXI error to prove error recovery.
        start_done_count = done_count;
        begin_run(2, TERMINAL_DONE, 2, 2);
        wait_done_count(start_done_count + 1);

        // Abort while ARVALID is blocked before its handshake.  No descriptor
        // traffic or layer command may escape, and a new run must succeed.
        @(negedge clk);
        force_ar_block = 1'b1;
        start_ar_count = ar_count;
        start_command_count = command_count;
        start_aborted_count = aborted_count;
        begin_run(3, TERMINAL_ABORTED, 0, 0);
        while (!m_axi_arvalid) @(negedge clk);
        pulse_abort();
        wait_aborted_count(start_aborted_count + 1);
        force_ar_block = 1'b0;
        repeat (4) @(posedge clk);
        if ((ar_count != start_ar_count) ||
            (command_count != start_command_count) || busy) begin
            $fatal(1, "abort-before-AR left traffic or busy state behind");
        end

        start_done_count = done_count;
        begin_run(2, TERMINAL_DONE, 2, 2);
        wait_done_count(start_done_count + 1);

        // Abort after AR handshake.  A long first-R delay leaves the old burst
        // outstanding while a restart is queued in the scheduler.  The reader
        // must drain/discard four beats before accepting the restarted index 0.
        force_long_initial_r_gap = 1'b1;
        start_ar_count = ar_count;
        start_rbeat_count = rbeat_count;
        start_command_count = command_count;
        start_aborted_count = aborted_count;
        begin_run(3, TERMINAL_ABORTED, 1, 0);
        wait_ar_count(start_ar_count + 1);
        pulse_abort();
        wait_aborted_count(start_aborted_count + 1);
        force_long_initial_r_gap = 1'b0;

        // Start before the old AXI burst has drained.  The scheduler should
        // wait on request_ready and later restart cleanly from descriptor zero.
        start_done_count = done_count;
        begin_run(4, TERMINAL_DONE, 4, 4);
        if (!slave_burst_active || (rbeat_count != start_rbeat_count)) begin
            $fatal(1, "restart was not exercised while aborted AXI burst remained outstanding");
        end
        wait_done_count(start_done_count + 1);
        if ((rbeat_count - start_rbeat_count) != 20) begin
            $fatal(1, "abort-after-AR did not drain exactly 4 old plus 16 new beats");
        end
        if (command_count != start_command_count + 4) begin
            $fatal(1, "aborted descriptor leaked a layer command");
        end

        // Also prove the exposed layer error input terminates a run and that
        // the subsystem remains restartable afterward.
        inject_layer_error_index = 1;
        start_error_count = error_count;
        begin_run(3, TERMINAL_ERROR, 2, 2);
        wait_error_count(start_error_count + 1);
        inject_layer_error_index = -1;

        start_done_count = done_count;
        begin_run(1, TERMINAL_DONE, 1, 1);
        wait_done_count(start_done_count + 1);

        repeat (8) @(posedge clk);
        if (busy || score_run_active || slave_burst_active || m_axi_rvalid ||
            consumer_active || layer_command_valid) begin
            $fatal(1, "subsystem regression ended with outstanding state");
        end
        if ((start_count != 9) || (done_count != 5) ||
            (error_count != 2) || (aborted_count != 2)) begin
            $fatal(1, "terminal coverage mismatch starts=%0d done=%0d error=%0d abort=%0d",
                   start_count, done_count, error_count, aborted_count);
        end
        if ((command_count != 17) || (layer_done_count != 16) ||
            (layer_error_count != 1)) begin
            $fatal(1, "layer coverage mismatch commands=%0d done=%0d error=%0d",
                   command_count, layer_done_count, layer_error_count);
        end
        if ((ar_count != 19) || (rbeat_count != 76)) begin
            $fatal(1, "AXI coverage mismatch ar=%0d rbeats=%0d", ar_count, rbeat_count);
        end
        if ((ar_stall_count == 0) || (r_gap_count == 0) ||
            (layer_stall_count == 0)) begin
            $fatal(1, "randomized stall coverage was incomplete");
        end

        $display("C1_DESCRIPTOR_SCHEDULER_SUBSYSTEM_PASS starts=%0d commands=%0d done=%0d errors=%0d aborted=%0d ar=%0d rbeats=%0d ar_stalls=%0d r_gaps=%0d layer_stalls=%0d",
                 start_count, command_count, done_count, error_count,
                 aborted_count, ar_count, rbeat_count, ar_stall_count,
                 r_gap_count, layer_stall_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "global subsystem testbench timeout");
    end

endmodule
