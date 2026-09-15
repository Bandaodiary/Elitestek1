`timescale 1ns/1ps

module tb_c1_axi_frame_buffer_table_reader;

    localparam integer INDEX_BITS = 16;
    localparam integer MAX_ENTRIES = 32;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;

    logic request_valid = 1'b0;
    wire request_ready;
    logic [63:0] request_table_base = '0;
    logic [INDEX_BITS-1:0] request_entry_index = '0;

    wire response_valid;
    logic response_ready = 1'b0;
    wire response_error;
    wire [127:0] response_raw;
    wire [63:0] response_base_address;
    wire [31:0] response_stride_bytes;
    wire [15:0] response_width_pixels;
    wire [15:0] response_height_lines;

    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid;
    logic m_axi_arready = 1'b0;
    logic [127:0] m_axi_rdata = '0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    wire m_axi_rready;

    logic [31:0] memory_address [0:MAX_ENTRIES-1];
    logic [127:0] memory_raw [0:MAX_ENTRIES-1];
    integer memory_count;

    logic [31:0] prng = 32'h8f70_1c35;
    logic force_ar_block = 1'b0;
    logic force_r_block = 1'b0;
    logic force_response_block = 1'b0;

    logic next_expect_response;
    logic next_expect_error;
    logic next_expect_ar;
    logic [31:0] next_expected_araddr;
    logic [127:0] next_expected_raw;
    logic [1:0] next_rresp;
    logic next_rlast;

    logic captured_expect_response;
    logic captured_expect_error;
    logic captured_expect_ar;
    logic [31:0] captured_expected_araddr;
    logic [127:0] captured_expected_raw;
    logic [1:0] captured_rresp;
    logic captured_rlast;
    logic scheduler_waiting;

    logic slave_active;
    logic [127:0] slave_raw;
    logic [3:0] slave_delay;
    logic [1:0] slave_rresp;
    logic slave_rlast;

    integer accepted_count = 0;
    integer response_count = 0;
    integer ar_count = 0;
    integer r_count = 0;
    integer ar_stall_count = 0;
    integer r_delay_count = 0;
    integer response_stall_count = 0;
    integer abort_before_count = 0;
    integer abort_after_count = 0;
    integer restart_count = 0;

    logic ar_hold_active = 1'b0;
    logic [31:0] held_araddr;
    logic [7:0] held_arlen;
    logic [2:0] held_arsize;
    logic [1:0] held_arburst;

    logic response_hold_active = 1'b0;
    logic held_response_error;
    logic [127:0] held_response_raw;
    logic [63:0] held_response_base;
    logic [31:0] held_response_stride;
    logic [15:0] held_response_width;
    logic [15:0] held_response_height;

    integer random_case;
    integer start_response_count;
    integer start_ar_count;
    integer start_r_count;

    always #5 clk = ~clk;

    c1_axi_frame_buffer_table_reader #(
        .INDEX_BITS(INDEX_BITS)
    ) dut (
        .clk,
        .rst,
        .abort,
        .request_valid,
        .request_ready,
        .request_table_base,
        .request_entry_index,
        .response_valid,
        .response_ready,
        .response_error,
        .response_raw,
        .response_base_address,
        .response_stride_bytes,
        .response_width_pixels,
        .response_height_lines,
        .m_axi_araddr,
        .m_axi_arlen,
        .m_axi_arsize,
        .m_axi_arburst,
        .m_axi_arvalid,
        .m_axi_arready,
        .m_axi_rdata,
        .m_axi_rresp,
        .m_axi_rlast,
        .m_axi_rvalid,
        .m_axi_rready
    );

    function automatic logic address_present(input logic [31:0] address);
        integer index;
        begin
            address_present = 1'b0;
            for (index = 0; index < memory_count; index = index + 1)
                if (memory_address[index] == address)
                    address_present = 1'b1;
        end
    endfunction

    function automatic logic [127:0] lookup_raw(input logic [31:0] address);
        integer index;
        begin
            lookup_raw = 128'd0;
            for (index = 0; index < memory_count; index = index + 1)
                if (memory_address[index] == address)
                    lookup_raw = memory_raw[index];
        end
    endfunction

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("frame_buffer_table_reader_entries.txt", "r");
            if (fd == 0) $fatal(1, "cannot open framebuffer table entries");
            status = $fscanf(fd, "%d\n", memory_count);
            if (status != 1 || memory_count <= 0 || memory_count > MAX_ENTRIES)
                $fatal(1, "invalid framebuffer table entry count");
            for (index = 0; index < memory_count; index = index + 1) begin
                status = $fscanf(fd, "%h %h\n",
                                 memory_address[index], memory_raw[index]);
                if (status != 2)
                    $fatal(1, "malformed framebuffer table entry %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic issue_request(
        input logic [63:0] table_base,
        input logic [INDEX_BITS-1:0] entry_index,
        input logic expect_response,
        input logic expect_error,
        input logic expect_ar,
        input logic [1:0] injected_rresp,
        input logic injected_rlast
    );
        logic [64:0] wide_address;
        integer guard;
        begin
            wide_address = {1'b0, table_base} +
                           ({{(65-INDEX_BITS){1'b0}}, entry_index} << 4);
            @(negedge clk);
            if (scheduler_waiting || request_valid)
                $fatal(1, "driver issued overlapping framebuffer request");

            next_expect_response = expect_response;
            next_expect_error = expect_error;
            next_expect_ar = expect_ar;
            next_expected_araddr = wide_address[31:0];
            next_expected_raw = expect_ar ? lookup_raw(wide_address[31:0]) : 128'd0;
            next_rresp = injected_rresp;
            next_rlast = injected_rlast;
            request_table_base = table_base;
            request_entry_index = entry_index;
            request_valid = 1'b1;

            guard = 0;
            while (!(request_valid && request_ready)) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "framebuffer request handshake timeout");
            end
            @(negedge clk);
            request_valid = 1'b0;
            request_table_base = table_base ^ 64'h55aa_33cc_0ff0_c33c;
            request_entry_index = entry_index ^ 16'h5a3c;
        end
    endtask

    task automatic wait_response(input integer target);
        integer guard;
        begin
            guard = 0;
            while (response_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "framebuffer response timeout");
            end
        end
    endtask

    task automatic wait_ar(input integer target);
        integer guard;
        begin
            guard = 0;
            while (ar_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) $fatal(1, "framebuffer AR timeout");
            end
        end
    endtask

    task automatic wait_r(input integer target);
        integer guard;
        begin
            guard = 0;
            while (r_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) $fatal(1, "framebuffer R drain timeout");
            end
        end
    endtask

    task automatic wait_idle;
        integer guard;
        begin
            guard = 0;
            while (!request_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000) $fatal(1, "framebuffer reader idle timeout");
            end
        end
    endtask

    // Request/response-side scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            scheduler_waiting = 1'b0;
            captured_expect_response = 1'b0;
            captured_expect_error = 1'b0;
            captured_expect_ar = 1'b0;
            captured_expected_araddr = 32'd0;
            captured_expected_raw = 128'd0;
            captured_rresp = 2'b00;
            captured_rlast = 1'b1;
        end else begin
            if (request_valid && request_ready) begin
                if (scheduler_waiting)
                    $fatal(1, "reader accepted more than one request");
                scheduler_waiting = 1'b1;
                accepted_count = accepted_count + 1;
                captured_expect_response = next_expect_response;
                captured_expect_error = next_expect_error;
                captured_expect_ar = next_expect_ar;
                captured_expected_araddr = next_expected_araddr;
                captured_expected_raw = next_expected_raw;
                captured_rresp = next_rresp;
                captured_rlast = next_rlast;
            end

            if (abort)
                scheduler_waiting = 1'b0;

            if (response_valid && response_ready) begin
                if (!scheduler_waiting || !captured_expect_response)
                    $fatal(1, "stale framebuffer response");
                if (response_error !== captured_expect_error)
                    $fatal(1, "framebuffer response error mismatch");
                if (response_raw !== captured_expected_raw)
                    $fatal(1, "framebuffer raw entry mismatch");
                if (response_base_address !== captured_expected_raw[63:0] ||
                    response_stride_bytes !== captured_expected_raw[95:64] ||
                    response_width_pixels !== captured_expected_raw[111:96] ||
                    response_height_lines !== captured_expected_raw[127:112])
                    $fatal(1, "framebuffer entry unpack mismatch");
                scheduler_waiting = 1'b0;
                response_count = response_count + 1;
            end

            if (abort && (request_ready || response_valid))
                $fatal(1, "reader exposed request/response handshake during abort");
        end
    end

    // AXI address-channel attributes and stability.
    always @(posedge clk) begin
        if (rst) begin
            ar_hold_active <= 1'b0;
        end else begin
            if (m_axi_arvalid) begin
                if (m_axi_arlen !== 8'd0 || m_axi_arsize !== 3'd4 ||
                    m_axi_arburst !== 2'b01)
                    $fatal(1, "illegal AXI framebuffer read attributes");
                if (m_axi_araddr[3:0] !== 4'd0)
                    $fatal(1, "framebuffer table AR address is not aligned");
            end
            if (m_axi_arvalid && !m_axi_arready) begin
                ar_stall_count <= ar_stall_count + 1;
                if (ar_hold_active &&
                    (m_axi_araddr !== held_araddr ||
                     m_axi_arlen !== held_arlen ||
                     m_axi_arsize !== held_arsize ||
                     m_axi_arburst !== held_arburst))
                    $fatal(1, "framebuffer AR payload changed while stalled");
                ar_hold_active <= 1'b1;
                held_araddr <= m_axi_araddr;
                held_arlen <= m_axi_arlen;
                held_arsize <= m_axi_arsize;
                held_arburst <= m_axi_arburst;
            end else begin
                ar_hold_active <= 1'b0;
            end
        end
    end

    // Response payload must remain stable under consumer backpressure.
    always @(posedge clk) begin
        if (!rst && response_valid && !response_ready) begin
            response_hold_active = 1'b1;
            held_response_error = response_error;
            held_response_raw = response_raw;
            held_response_base = response_base_address;
            held_response_stride = response_stride_bytes;
            held_response_width = response_width_pixels;
            held_response_height = response_height_lines;
            response_stall_count = response_stall_count + 1;
            #1;
            if (!response_valid || response_error !== held_response_error ||
                response_raw !== held_response_raw ||
                response_base_address !== held_response_base ||
                response_stride_bytes !== held_response_stride ||
                response_width_pixels !== held_response_width ||
                response_height_lines !== held_response_height)
                $fatal(1, "framebuffer response changed while stalled");
        end else begin
            response_hold_active = 1'b0;
        end
    end

    // Pseudo-random AXI slave and response consumer.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            slave_active <= 1'b0;
            slave_raw <= 128'd0;
            slave_delay <= 4'd0;
            slave_rresp <= 2'b00;
            slave_rlast <= 1'b1;
            response_ready <= 1'b0;
        end else begin
            m_axi_arready <= !force_ar_block && (prng[0] || prng[5]);
            response_ready <= !force_response_block &&
                              (prng[2] || prng[9]);

            if (m_axi_arvalid && m_axi_arready) begin
                if (slave_active || m_axi_rvalid)
                    $fatal(1, "multiple AXI framebuffer transactions outstanding");
                if (!captured_expect_ar || m_axi_araddr !== captured_expected_araddr)
                    $fatal(1, "unexpected framebuffer AR address");
                if (!address_present(m_axi_araddr))
                    $fatal(1, "framebuffer AR address absent from memory image");
                ar_count = ar_count + 1;
                slave_active <= 1'b1;
                slave_raw <= lookup_raw(m_axi_araddr);
                slave_delay <= prng[15:12] & 4'h7;
                slave_rresp <= captured_rresp;
                slave_rlast <= captured_rlast;
            end

            if (slave_active && !m_axi_rvalid) begin
                if (force_r_block) begin
                    r_delay_count = r_delay_count + 1;
                end else if (slave_delay != 0) begin
                    slave_delay <= slave_delay - 1'b1;
                    r_delay_count = r_delay_count + 1;
                end else begin
                    m_axi_rdata <= slave_raw;
                    m_axi_rresp <= slave_rresp;
                    m_axi_rlast <= slave_rlast;
                    m_axi_rvalid <= 1'b1;
                end
            end

            if (m_axi_rvalid && m_axi_rready) begin
                r_count = r_count + 1;
                m_axi_rvalid <= 1'b0;
                slave_active <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            prng <= 32'h8f70_1c35;
        else
            prng <= {prng[30:0],
                     prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
    end

    initial begin
        load_vectors();
        next_expect_response = 1'b0;
        next_expect_error = 1'b0;
        next_expect_ar = 1'b0;
        next_expected_araddr = 32'd0;
        next_expected_raw = 128'd0;
        next_rresp = 2'b00;
        next_rlast = 1'b1;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // All fixed input/output table indices and ABI field unpacking.
        for (random_case = 0; random_case < 3; random_case = random_case + 1) begin
            start_response_count = response_count;
            issue_request(64'h0000_0000_0000_1000, random_case[15:0],
                          1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
            wait_response(start_response_count + 1);
        end
        for (random_case = 0; random_case < 2; random_case = random_case + 1) begin
            start_response_count = response_count;
            issue_request(64'h0000_0000_0000_2000, random_case[15:0],
                          1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
            wait_response(start_response_count + 1);
        end

        // Local request validation: no AR may escape.
        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_request(64'h0000_0000_0000_1008, 16'd0,
                      1'b1, 1'b1, 1'b0, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "unaligned table base issued AR");

        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_request(64'h0000_0001_0000_1000, 16'd0,
                      1'b1, 1'b1, 1'b0, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "high table base issued AR");

        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_request(64'h0000_0000_ffff_fff0, 16'd1,
                      1'b1, 1'b1, 1'b0, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "32-bit addition overflow issued AR");

        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_request(64'hffff_ffff_ffff_fff0, 16'd1,
                      1'b1, 1'b1, 1'b0, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "64-bit addition overflow issued AR");

        // Final legal AXI128 window: 0xffff_ffe0 + one entry.
        start_response_count = response_count;
        issue_request(64'h0000_0000_ffff_ffe0, 16'd1,
                      1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Returned framebuffer base high word, RRESP, and RLAST errors.
        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_3000, 16'd0,
                      1'b1, 1'b1, 1'b1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_4000, 16'd0,
                      1'b1, 1'b1, 1'b1, 2'b10, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_5000, 16'd0,
                      1'b1, 1'b1, 1'b1, 2'b00, 1'b0);
        wait_response(start_response_count + 1);

        // Abort before AR: cancel without traffic or response.
        force_ar_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_request(64'h0000_0000_0000_8000, 16'd0,
                      1'b0, 1'b0, 1'b1, 2'b00, 1'b1);
        while (!m_axi_arvalid) @(negedge clk);
        abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        force_ar_block = 1'b0;
        abort_before_count = abort_before_count + 1;
        repeat (8) @(posedge clk);
        if (response_count != start_response_count || ar_count != start_ar_count)
            $fatal(1, "abort-before-AR leaked traffic or response");
        wait_idle();

        // Restart immediately after the canceled request.
        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_8000, 16'd0,
                      1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        restart_count = restart_count + 1;

        // Abort after AR.  R is deliberately held off, then released so the
        // reader must drain the committed beat without emitting a response.
        force_r_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_count;
        start_r_count = r_count;
        issue_request(64'h0000_0000_0000_6000, 16'd0,
                      1'b0, 1'b0, 1'b1, 2'b00, 1'b1);
        wait_ar(start_ar_count + 1);
        @(negedge clk);
        abort = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        force_r_block = 1'b0;
        abort_after_count = abort_after_count + 1;
        wait_r(start_r_count + 1);
        wait_idle();
        if (response_count != start_response_count)
            $fatal(1, "abort-after-AR leaked a response");

        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_1000, 16'd2,
                      1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        restart_count = restart_count + 1;

        // Abort a consumer-stalled response and restart again.
        force_response_block = 1'b1;
        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_7000, 16'd0,
                      1'b0, 1'b0, 1'b1, 2'b00, 1'b1);
        while (!response_valid) @(negedge clk);
        abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        force_response_block = 1'b0;
        wait_idle();
        if (response_count != start_response_count)
            $fatal(1, "aborted stalled response was consumed");

        start_response_count = response_count;
        issue_request(64'h0000_0000_0000_2000, 16'd1,
                      1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        restart_count = restart_count + 1;

        // Randomized AR latency, R latency, and output backpressure sweep.
        for (random_case = 0; random_case < 24; random_case = random_case + 1) begin
            start_response_count = response_count;
            if (random_case[0]) begin
                issue_request(64'h0000_0000_0000_1000,
                              (random_case % 3),
                              1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
            end else begin
                issue_request(64'h0000_0000_0000_2000,
                              (random_case % 2),
                              1'b1, 1'b0, 1'b1, 2'b00, 1'b1);
            end
            wait_response(start_response_count + 1);
        end

        wait_idle();
        repeat (8) @(posedge clk);
        if (scheduler_waiting || slave_active || m_axi_rvalid ||
            response_valid || m_axi_arvalid)
            $fatal(1, "framebuffer reader test ended with outstanding state");
        if (ar_stall_count == 0 || r_delay_count == 0 ||
            response_stall_count == 0)
            $fatal(1, "AXI/response randomized backpressure coverage missing");
        if (abort_before_count != 1 || abort_after_count != 1 ||
            restart_count != 3)
            $fatal(1, "abort/restart coverage counters incomplete");
        if (accepted_count != response_count + 3)
            $fatal(1, "accepted/response accounting mismatch");
        if (ar_count != r_count)
            $fatal(1, "AR/R drain accounting mismatch");

        $display("C1_AXI_FRAME_BUFFER_TABLE_READER_PASS entries=%0d accepted=%0d responses=%0d ar=%0d r=%0d",
                 memory_count, accepted_count, response_count, ar_count, r_count);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "framebuffer table reader regression timeout");
    end

endmodule
