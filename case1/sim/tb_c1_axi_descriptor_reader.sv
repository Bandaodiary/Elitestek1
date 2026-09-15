`timescale 1ns/1ps

module tb_c1_axi_descriptor_reader;

    localparam integer INDEX_BITS = 16;

    logic clk;
    logic rst;
    logic abort;
    logic [31:0] descriptor_base;
    logic descriptor_request_valid;
    logic descriptor_request_ready;
    logic [INDEX_BITS-1:0] descriptor_request_index;
    logic descriptor_response_valid;
    logic descriptor_response_error;
    logic [511:0] descriptor_response_data;

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

    logic force_ar_block;
    logic [31:0] prng;

    // Per-request expectations are established before request_valid is raised
    // and copied into the in-flight scoreboard on the request handshake.
    logic next_expect_response;
    logic next_expect_error;
    logic next_expect_ar;
    logic [31:0] next_expected_address;
    logic [511:0] next_expected_data;
    integer next_inject_rresp_beat;
    integer next_inject_early_rlast_beat;
    logic next_inject_missing_rlast;

    logic captured_expect_response;
    logic captured_expect_error;
    logic captured_expect_ar;
    logic [31:0] captured_expected_address;
    logic [511:0] captured_expected_data;
    logic [INDEX_BITS-1:0] captured_index;
    integer captured_inject_rresp_beat;
    integer captured_inject_early_rlast_beat;
    logic captured_inject_missing_rlast;

    logic scheduler_waiting;
    logic previous_response_valid;

    integer accepted_count;
    integer response_count;
    integer ar_handshake_count;
    integer r_handshake_count;
    integer ar_stall_count;
    integer r_gap_count;
    integer abort_before_count;
    integer abort_after_count;
    integer early_rlast_count;
    integer missing_rlast_count;

    logic slave_burst_active;
    logic [INDEX_BITS-1:0] slave_active_index;
    logic [1:0] slave_beat_index;
    integer slave_gap_countdown;
    integer slave_inject_rresp_beat;
    integer slave_inject_early_rlast_beat;
    logic slave_inject_missing_rlast;

    logic ar_hold_active;
    logic [31:0] held_araddr;
    logic [7:0] held_arlen;
    logic [2:0] held_arsize;
    logic [1:0] held_arburst;

    logic r_hold_active;
    logic [127:0] held_rdata;
    logic [1:0] held_rresp;
    logic held_rlast;

    integer random_case;
    integer start_response_count;
    integer start_ar_count;
    integer start_r_count;
    logic [31:0] random_base;
    logic [INDEX_BITS-1:0] random_index;

    c1_axi_descriptor_reader #(
        .INDEX_BITS(INDEX_BITS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .abort(abort),
        .descriptor_base(descriptor_base),
        .descriptor_request_valid(descriptor_request_valid),
        .descriptor_request_ready(descriptor_request_ready),
        .descriptor_request_index(descriptor_request_index),
        .descriptor_response_valid(descriptor_response_valid),
        .descriptor_response_error(descriptor_response_error),
        .descriptor_response_data(descriptor_response_data),
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
        input logic [INDEX_BITS-1:0] index_value,
        input integer word_number
    );
        logic [31:0] index_extended;
        logic [31:0] word_extended;
        begin
            index_extended = {{(32-INDEX_BITS){1'b0}}, index_value};
            word_extended = word_number;
            descriptor_word = (32'h9e37_79b9 * (word_extended + 32'd1)) ^
                              {16'hc15d, index_extended[15:0]};
        end
    endfunction

    function automatic [511:0] descriptor_image(
        input logic [INDEX_BITS-1:0] index_value
    );
        logic [511:0] image_value;
        integer word_number;
        begin
            image_value = 512'd0;
            for (word_number = 0; word_number < 16; word_number = word_number + 1) begin
                image_value[word_number*32 +: 32] =
                    descriptor_word(index_value, word_number);
            end
            descriptor_image = image_value;
        end
    endfunction

    function automatic [127:0] descriptor_beat(
        input logic [INDEX_BITS-1:0] index_value,
        input logic [1:0] beat_value
    );
        logic [127:0] beat_data;
        integer lane;
        begin
            beat_data = 128'd0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                beat_data[lane*32 +: 32] =
                    descriptor_word(index_value, beat_value*4 + lane);
            end
            descriptor_beat = beat_data;
        end
    endfunction

    task automatic issue_request(
        input logic [31:0] base_value,
        input logic [INDEX_BITS-1:0] index_value,
        input logic expect_response_value,
        input logic expect_error_value,
        input logic expect_ar_value,
        input integer inject_rresp_beat_value,
        input integer inject_early_rlast_beat_value,
        input logic inject_missing_rlast_value
    );
        integer guard;
        integer expected_beat;
        logic [63:0] wide_address;
        begin
            wide_address = {32'd0, base_value} +
                           ({{(64-INDEX_BITS){1'b0}}, index_value} << 6);

            @(negedge clk);
            if (scheduler_waiting || descriptor_request_valid) begin
                $fatal(1, "driver attempted a request while another request was active");
            end

            next_expect_response = expect_response_value;
            next_expect_error = expect_error_value;
            next_expect_ar = expect_ar_value;
            next_expected_address = wide_address[31:0];
            next_expected_data =
                expect_ar_value ? descriptor_image(index_value) : 512'd0;
            if (expect_ar_value &&
                (inject_early_rlast_beat_value >= 0)) begin
                // The reader terminates on the actual early RLAST, so only
                // physically received beats are defined in the error payload.
                next_expected_data = 512'd0;
                for (expected_beat = 0;
                     expected_beat <= inject_early_rlast_beat_value;
                     expected_beat = expected_beat + 1) begin
                    next_expected_data[expected_beat*128 +: 128] =
                        descriptor_beat(index_value, expected_beat[1:0]);
                end
            end
            next_inject_rresp_beat = inject_rresp_beat_value;
            next_inject_early_rlast_beat = inject_early_rlast_beat_value;
            next_inject_missing_rlast = inject_missing_rlast_value;

            descriptor_base = base_value;
            descriptor_request_index = index_value;
            descriptor_request_valid = 1'b1;

            guard = 0;
            while (!(descriptor_request_valid && descriptor_request_ready)) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1000) begin
                    $fatal(1, "request handshake timeout");
                end
            end

            // Move all live request/configuration inputs immediately after the
            // handshake.  Any later use by the DUT exposes a latching defect.
            @(negedge clk);
            descriptor_request_valid = 1'b0;
            descriptor_base = base_value ^ 32'h55aa_33cc;
            descriptor_request_index = index_value ^ 16'h5a3c;
        end
    endtask

    task automatic wait_for_response_count(
        input integer target_count
    );
        integer guard;
        begin
            guard = 0;
            while (response_count < target_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) begin
                    $fatal(1, "response timeout target=%0d current=%0d",
                           target_count, response_count);
                end
            end
        end
    endtask

    task automatic wait_for_ar_count(
        input integer target_count
    );
        integer guard;
        begin
            guard = 0;
            while (ar_handshake_count < target_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) begin
                    $fatal(1, "AR handshake timeout target=%0d current=%0d",
                           target_count, ar_handshake_count);
                end
            end
        end
    endtask

    task automatic wait_for_r_count(
        input integer target_count
    );
        integer guard;
        begin
            guard = 0;
            while (r_handshake_count < target_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) begin
                    $fatal(1, "R drain timeout target=%0d current=%0d",
                           target_count, r_handshake_count);
                end
            end
        end
    endtask

    task automatic wait_until_reader_idle;
        integer guard;
        begin
            guard = 0;
            while (!descriptor_request_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) begin
                    $fatal(1, "reader failed to return to idle");
                end
            end
        end
    endtask

    // Scheduler-facing scoreboard.  It explicitly models the scheduler's
    // REQUEST -> RESPONSE transition and rejects any premature/stale response.
    always @(posedge clk) begin
        if (rst) begin
            scheduler_waiting = 1'b0;
            previous_response_valid = 1'b0;
            accepted_count = 0;
            response_count = 0;
            captured_expect_response = 1'b0;
            captured_expect_error = 1'b0;
            captured_expect_ar = 1'b0;
            captured_expected_address = 32'd0;
            captured_expected_data = 512'd0;
            captured_index = '0;
            captured_inject_rresp_beat = -1;
            captured_inject_early_rlast_beat = -1;
            captured_inject_missing_rlast = 1'b0;
        end else begin
            if (descriptor_request_valid && descriptor_request_ready) begin
                if (scheduler_waiting) begin
                    $fatal(1, "reader accepted more than one outstanding request");
                end
                scheduler_waiting = 1'b1;
                accepted_count = accepted_count + 1;
                captured_expect_response = next_expect_response;
                captured_expect_error = next_expect_error;
                captured_expect_ar = next_expect_ar;
                captured_expected_address = next_expected_address;
                captured_expected_data = next_expected_data;
                captured_index = descriptor_request_index;
                captured_inject_rresp_beat = next_inject_rresp_beat;
                captured_inject_early_rlast_beat = next_inject_early_rlast_beat;
                captured_inject_missing_rlast = next_inject_missing_rlast;
            end

            // c1_layer_scheduler gives abort priority and leaves RESPONSE state.
            if (abort) begin
                scheduler_waiting = 1'b0;
            end

            if (descriptor_response_valid) begin
                if (abort) begin
                    $fatal(1, "response was not suppressed during abort");
                end
                if (!scheduler_waiting) begin
                    $fatal(1, "response arrived while scheduler was not waiting");
                end
                if (!captured_expect_response) begin
                    $fatal(1, "aborted request produced a stale response");
                end
                if (descriptor_response_error !== captured_expect_error) begin
                    $fatal(1, "response error mismatch expected=%0b got=%0b",
                           captured_expect_error, descriptor_response_error);
                end
                if (descriptor_response_data !== captured_expected_data) begin
                    $fatal(1, "descriptor payload/order mismatch index=%0d",
                           captured_index);
                end
                scheduler_waiting = 1'b0;
                response_count = response_count + 1;
            end

            if (descriptor_response_valid && previous_response_valid) begin
                $fatal(1, "descriptor_response_valid lasted more than one cycle");
            end
            previous_response_valid = descriptor_response_valid;

            if (abort && descriptor_request_ready) begin
                $fatal(1, "request_ready must be low during abort");
            end
        end
    end

    // AXI address stability and protocol checks.
    always @(posedge clk) begin
        if (rst) begin
            ar_hold_active <= 1'b0;
            held_araddr <= 32'd0;
            held_arlen <= 8'd0;
            held_arsize <= 3'd0;
            held_arburst <= 2'd0;
            ar_stall_count <= 0;
        end else begin
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

            if (m_axi_arvalid) begin
                if ((m_axi_arlen !== 8'd3) ||
                    (m_axi_arsize !== 3'd4) ||
                    (m_axi_arburst !== 2'b01)) begin
                    $fatal(1, "illegal AXI descriptor burst attributes");
                end
                if (m_axi_araddr[5:0] !== 6'd0) begin
                    $fatal(1, "descriptor AR address is not 64-byte aligned");
                end
                if (m_axi_araddr[11:0] > 12'hfc0) begin
                    $fatal(1, "descriptor burst crosses a 4KiB boundary");
                end
            end
        end
    end

    // Random-stall AXI slave.  It returns the deterministic descriptor image
    // with random gaps between R beats and holds R payload stable until ready.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            slave_burst_active <= 1'b0;
            slave_active_index <= '0;
            slave_beat_index <= 2'd0;
            slave_gap_countdown <= 0;
            slave_inject_rresp_beat <= -1;
            slave_inject_early_rlast_beat <= -1;
            slave_inject_missing_rlast <= 1'b0;
            ar_handshake_count <= 0;
            r_handshake_count <= 0;
            r_gap_count <= 0;
            early_rlast_count <= 0;
            missing_rlast_count <= 0;
            r_hold_active <= 1'b0;
            held_rdata <= 128'd0;
            held_rresp <= 2'd0;
            held_rlast <= 1'b0;
        end else begin
            if (force_ar_block) begin
                m_axi_arready <= 1'b0;
            end else begin
                m_axi_arready <= prng[0] | prng[5];
            end

            if (m_axi_arvalid && m_axi_arready) begin
                if (slave_burst_active || m_axi_rvalid) begin
                    $fatal(1, "more than one AXI transaction became outstanding");
                end
                if (!captured_expect_ar) begin
                    $fatal(1, "AR issued for a request that should be rejected");
                end
                if (m_axi_araddr !== captured_expected_address) begin
                    $fatal(1, "AR address mismatch expected=%08x got=%08x",
                           captured_expected_address, m_axi_araddr);
                end

                ar_handshake_count <= ar_handshake_count + 1;
                slave_burst_active <= 1'b1;
                slave_active_index <= captured_index;
                slave_beat_index <= 2'd0;
                slave_gap_countdown <= {1'b0, prng[7:6]};
                slave_inject_rresp_beat <= captured_inject_rresp_beat;
                slave_inject_early_rlast_beat <= captured_inject_early_rlast_beat;
                slave_inject_missing_rlast <= captured_inject_missing_rlast;
            end

            if (m_axi_rvalid && !m_axi_rready) begin
                if (r_hold_active &&
                    ((m_axi_rdata !== held_rdata) ||
                     (m_axi_rresp !== held_rresp) ||
                     (m_axi_rlast !== held_rlast))) begin
                    $fatal(1, "R payload changed while stalled");
                end
                r_hold_active <= 1'b1;
                held_rdata <= m_axi_rdata;
                held_rresp <= m_axi_rresp;
                held_rlast <= m_axi_rlast;
            end else begin
                r_hold_active <= 1'b0;
            end

            if (m_axi_rvalid) begin
                if (m_axi_rready) begin
                    r_handshake_count <= r_handshake_count + 1;
                    m_axi_rvalid <= 1'b0;

                    if (m_axi_rlast && (slave_beat_index != 2'd3))
                        early_rlast_count <= early_rlast_count + 1;
                    if (!m_axi_rlast && (slave_beat_index == 2'd3))
                        missing_rlast_count <= missing_rlast_count + 1;

                    if (m_axi_rlast || (slave_beat_index == 2'd3)) begin
                        slave_burst_active <= 1'b0;
                        slave_gap_countdown <= 0;
                    end else begin
                        slave_beat_index <= slave_beat_index + 2'd1;
                        slave_gap_countdown <= {1'b0, prng[11:10]};
                    end
                end
            end else if (slave_burst_active) begin
                if (slave_gap_countdown > 0) begin
                    slave_gap_countdown <= slave_gap_countdown - 1;
                    r_gap_count <= r_gap_count + 1;
                end else begin
                    m_axi_rdata <= descriptor_beat(slave_active_index,
                                                   slave_beat_index);
                    if (slave_inject_rresp_beat == slave_beat_index) begin
                        m_axi_rresp <= 2'b10;
                    end else begin
                        m_axi_rresp <= 2'b00;
                    end
                    m_axi_rlast <=
                        ((slave_beat_index == 2'd3) &&
                         !slave_inject_missing_rlast) ||
                        (slave_inject_early_rlast_beat == slave_beat_index);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            prng <= 32'h6d2b_79f5;
        end else begin
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
        end
    end

    initial begin
        rst = 1'b1;
        abort = 1'b0;
        descriptor_base = 32'd0;
        descriptor_request_valid = 1'b0;
        descriptor_request_index = '0;
        force_ar_block = 1'b0;
        next_expect_response = 1'b0;
        next_expect_error = 1'b0;
        next_expect_ar = 1'b0;
        next_expected_address = 32'd0;
        next_expected_data = 512'd0;
        next_inject_rresp_beat = -1;
        next_inject_early_rlast_beat = -1;
        next_inject_missing_rlast = 1'b0;
        abort_before_count = 0;
        abort_after_count = 0;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Nominal payload/order check.  The driver scrambles live base/index
        // directly after request acceptance to verify both are latched.
        start_response_count = response_count;
        issue_request(32'h0000_1000, 16'd3, 1'b1, 1'b0, 1'b1,
                      -1, -1, 1'b0);
        wait_for_response_count(start_response_count + 1);

        // RRESP must become a sticky per-transaction error without changing
        // descriptor beat/word assembly.
        start_response_count = response_count;
        issue_request(32'h0000_4000, 16'd7, 1'b1, 1'b1, 1'b1,
                      2, -1, 1'b0);
        wait_for_response_count(start_response_count + 1);

        // Early RLAST is the actual malformed-burst end.  It must produce an
        // error response after two accepted beats, without waiting for beats
        // that the slave is no longer required to produce.
        start_response_count = response_count;
        start_r_count = r_handshake_count;
        issue_request(32'h0000_8000, 16'd11, 1'b1, 1'b1, 1'b1,
                      -1, 1, 1'b0);
        wait_for_response_count(start_response_count + 1);
        if (r_handshake_count != start_r_count + 2)
            $fatal(1, "early RLAST did not terminate on its actual beat");

        // Missing RLAST still terminates at the fourth ARLEN-implied beat and
        // reports an error; no fifth beat is required for recovery.
        start_response_count = response_count;
        start_r_count = r_handshake_count;
        issue_request(32'h0000_c000, 16'd12, 1'b1, 1'b1, 1'b1,
                      -1, -1, 1'b1);
        wait_for_response_count(start_response_count + 1);
        if (r_handshake_count != start_r_count + 4)
            $fatal(1, "missing RLAST did not terminate at expected beat count");

        // Unaligned base: accepted by the control-side handshake, rejected
        // locally on the following cycle, and no AXI address is issued.
        start_response_count = response_count;
        start_ar_count = ar_handshake_count;
        issue_request(32'h0000_1004, 16'd2, 1'b1, 1'b1, 1'b0,
                      -1, -1, 1'b0);
        wait_for_response_count(start_response_count + 1);
        if (ar_handshake_count != start_ar_count) begin
            $fatal(1, "unaligned descriptor base issued AR");
        end

        // 0xffff_ffc0 + 1*64 overflows the 32-bit descriptor address space.
        start_response_count = response_count;
        start_ar_count = ar_handshake_count;
        issue_request(32'hffff_ffc0, 16'd1, 1'b1, 1'b1, 1'b0,
                      -1, -1, 1'b0);
        wait_for_response_count(start_response_count + 1);
        if (ar_handshake_count != start_ar_count) begin
            $fatal(1, "overflowing descriptor address issued AR");
        end

        // The final legal 64-byte window in the 32-bit address space.
        start_response_count = response_count;
        issue_request(32'hffff_ffc0, 16'd0, 1'b1, 1'b0, 1'b1,
                      -1, -1, 1'b0);
        wait_for_response_count(start_response_count + 1);

        // Abort while ARVALID is stalled: cancel without an AXI transaction or
        // a response.  This models scheduler abort after request acceptance but
        // strictly before AR acceptance.
        force_ar_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_handshake_count;
        issue_request(32'h0001_0000, 16'd5, 1'b0, 1'b0, 1'b1,
                      -1, -1, 1'b0);
        while (!m_axi_arvalid) @(negedge clk);
        abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        force_ar_block = 1'b0;
        abort_before_count = abort_before_count + 1;
        repeat (12) @(posedge clk);
        if ((response_count != start_response_count) ||
            (ar_handshake_count != start_ar_count)) begin
            $fatal(1, "abort-before-AR generated traffic or response");
        end
        wait_until_reader_idle();

        // Abort after AR acceptance: the reader must accept all four R beats,
        // discard the result, and return idle without a response.
        start_response_count = response_count;
        start_ar_count = ar_handshake_count;
        start_r_count = r_handshake_count;
        issue_request(32'h0001_4000, 16'd9, 1'b0, 1'b0, 1'b1,
                      -1, -1, 1'b0);
        wait_for_ar_count(start_ar_count + 1);
        @(negedge clk);
        abort = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        abort_after_count = abort_after_count + 1;
        wait_for_r_count(start_r_count + 4);
        wait_until_reader_idle();
        repeat (5) @(posedge clk);
        if (response_count != start_response_count) begin
            $fatal(1, "abort-after-AR produced a stale response");
        end

        // Randomized-stall recovery sweep.  All live config inputs are changed
        // after every handshake, and the AXI slave inserts pseudo-random AR
        // stalls and R gaps for each descriptor.
        for (random_case = 0; random_case < 16; random_case = random_case + 1) begin
            random_base = 32'h0002_0000 + random_case * 32'h0000_1000;
            random_index = (random_case * 16'd37 + 16'd13) & 16'h01ff;
            start_response_count = response_count;
            issue_request(random_base, random_index,
                          1'b1, 1'b0, 1'b1, -1, -1, 1'b0);
            wait_for_response_count(start_response_count + 1);
        end

        wait_until_reader_idle();
        repeat (5) @(posedge clk);

        if (scheduler_waiting || slave_burst_active || m_axi_rvalid ||
            descriptor_response_valid) begin
            $fatal(1, "test ended with outstanding state");
        end
        if ((ar_stall_count == 0) || (r_gap_count == 0)) begin
            $fatal(1, "random AXI stress did not cover both AR stalls and R gaps");
        end
        if ((abort_before_count != 1) || (abort_after_count != 1)) begin
            $fatal(1, "abort coverage counters are incomplete");
        end
        if ((early_rlast_count != 1) || (missing_rlast_count != 1)) begin
            $fatal(1, "RLAST recovery coverage counters are incomplete");
        end

        $display("C1_AXI_DESCRIPTOR_READER_PASS accepted=%0d responses=%0d ar=%0d rbeats=%0d ar_stalls=%0d r_gaps=%0d abort_before=%0d abort_after=%0d early_rlast=%0d missing_rlast=%0d",
                 accepted_count, response_count, ar_handshake_count,
                 r_handshake_count, ar_stall_count, r_gap_count,
                 abort_before_count, abort_after_count,
                 early_rlast_count, missing_rlast_count);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "global testbench timeout");
    end

endmodule
