`timescale 1ns/1ps

module tb_c1_axi_parameter_loader;

    localparam integer ARENA_BYTES = 16896;
    localparam integer ARENA_WORDS = ARENA_BYTES / 16;
    localparam integer ADDR_W = $clog2(ARENA_WORDS);

    localparam logic [3:0] ERR_BASE_ALIGN    = 4'd1;
    localparam logic [3:0] ERR_ADDR_OVERFLOW = 4'd2;
    localparam logic [3:0] ERR_RRESP         = 4'd3;
    localparam logic [3:0] ERR_RLAST         = 4'd4;

    logic clk;
    logic rst;

    logic start_valid;
    logic start_ready;
    logic [31:0] start_base_addr;
    logic abort;
    logic busy;
    logic done;
    logic error;
    logic aborted;
    logic [3:0] error_code;
    logic [31:0] error_address;

    logic loader_bank_load_start;
    logic bank_load_start_ready;
    logic loader_bank_load_valid;
    logic loader_bank_load_ready;
    logic [127:0] loader_bank_load_data;
    logic loader_bank_load_last;
    logic loader_bank_load_abort;
    logic bank_load_ready_raw;
    logic bank_load_busy;
    logic bank_load_done;
    logic bank_load_aborted;
    logic bank_load_error;
    logic [2:0] bank_load_error_code;

    logic active_valid;
    logic active_bank;
    logic [31:0] generation;
    logic [0:0] rd_en;
    logic [ADDR_W-1:0] rd_addr;
    logic [0:0] rd_valid;
    logic [0:0] rd_error;
    logic [127:0] rd_data;

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

    logic bank_ready_gate;
    logic actual_bank_load_valid;

    logic [31:0] lfsr;
    logic force_ar_stall;
    logic mem_active;
    logic [31:0] mem_burst_addr;
    integer mem_burst_beats;
    integer mem_beat_index;
    integer mem_gap;
    logic mem_rvalid_q;
    logic [127:0] mem_rdata_q;
    logic [1:0] mem_rresp_q;
    logic mem_rlast_q;

    logic [31:0] transaction_base;
    integer transaction_image;
    integer inject_rresp_index;
    integer inject_rlast_index;
    integer inject_rlast_mode; // 0=none, 1=early high, 2=missing low

    integer done_count;
    integer error_count;
    integer aborted_count;
    integer bank_done_count;
    integer bank_aborted_count;
    integer ar_count;
    integer r_count;
    integer bank_word_count;
    integer current_bank_word_count;
    integer early_rlast_seen;
    integer missing_rlast_seen;

    logic prev_ar_stall;
    logic [31:0] prev_araddr;
    logic [7:0] prev_arlen;
    logic prev_abort;
    logic prev_bank_stall;
    logic [127:0] prev_bank_data;
    logic prev_bank_last;

    function automatic [127:0] arena_word(
        input integer image,
        input integer index
    );
        logic [31:0] a;
        logic [31:0] b;
        logic [31:0] c;
        logic [31:0] d;
        begin
            a = 32'h1020_3040 ^ (image * 32'h1111_1111) ^ index;
            b = 32'h89ab_cdef + (image * 32'h0102_0305) + index * 17;
            c = 32'h55aa_33cc ^ (index * 32'h0001_0001) ^
                (image * 32'h2468_1357);
            d = 32'hf00d_cafe - index * 257 - image * 65537;
            arena_word = {a, b, c, d};
        end
    endfunction

    c1_axi_parameter_loader #(
        .ARENA_BYTES (ARENA_BYTES)
    ) u_loader (
        .clk                   (clk),
        .rst                   (rst),
        .start_valid           (start_valid),
        .start_ready           (start_ready),
        .start_base_addr       (start_base_addr),
        .abort                 (abort),
        .busy                  (busy),
        .done                  (done),
        .error                 (error),
        .aborted               (aborted),
        .error_code            (error_code),
        .error_address         (error_address),
        .bank_load_start       (loader_bank_load_start),
        .bank_load_start_ready (bank_load_start_ready),
        .bank_load_valid       (loader_bank_load_valid),
        .bank_load_ready       (loader_bank_load_ready),
        .bank_load_data        (loader_bank_load_data),
        .bank_load_last        (loader_bank_load_last),
        .bank_load_abort       (loader_bank_load_abort),
        .bank_load_busy        (bank_load_busy),
        .bank_load_done        (bank_load_done),
        .bank_load_aborted     (bank_load_aborted),
        .bank_load_error       (bank_load_error),
        .m_axi_araddr          (m_axi_araddr),
        .m_axi_arlen           (m_axi_arlen),
        .m_axi_arsize          (m_axi_arsize),
        .m_axi_arburst         (m_axi_arburst),
        .m_axi_arvalid         (m_axi_arvalid),
        .m_axi_arready         (m_axi_arready),
        .m_axi_rdata           (m_axi_rdata),
        .m_axi_rresp           (m_axi_rresp),
        .m_axi_rlast           (m_axi_rlast),
        .m_axi_rvalid          (m_axi_rvalid),
        .m_axi_rready          (m_axi_rready)
    );

    assign loader_bank_load_ready = bank_load_ready_raw && bank_ready_gate;
    assign actual_bank_load_valid = loader_bank_load_valid && bank_ready_gate;

    c1_r1_parameter_bank #(
        .ARENA_BYTES (ARENA_BYTES),
        .READ_PORTS  (1)
    ) u_bank (
        .clk             (clk),
        .rst             (rst),
        .load_start      (loader_bank_load_start),
        .load_start_ready(bank_load_start_ready),
        .load_valid      (actual_bank_load_valid),
        .load_ready      (bank_load_ready_raw),
        .load_data       (loader_bank_load_data),
        .load_last       (loader_bank_load_last),
        .load_abort      (loader_bank_load_abort),
        .load_busy       (bank_load_busy),
        .load_done       (bank_load_done),
        .load_aborted    (bank_load_aborted),
        .load_error      (bank_load_error),
        .load_error_code (bank_load_error_code),
        .active_valid    (active_valid),
        .active_bank     (active_bank),
        .generation      (generation),
        .rd_en           (rd_en),
        .rd_addr         (rd_addr),
        .rd_valid        (rd_valid),
        .rd_error        (rd_error),
        .rd_data         (rd_data)
    );

    // The real bank is continuously ready while loading.  bank_ready_gate is
    // a test-only interposer that gives the loader genuine downstream stalls;
    // the same gate suppresses valid into the bank, preserving handshakes.
    assign m_axi_rdata  = mem_rdata_q;
    assign m_axi_rresp  = mem_rresp_q;
    assign m_axi_rlast  = mem_rlast_q;
    assign m_axi_rvalid = mem_rvalid_q;

    always #5 clk = ~clk;

    // Deterministic randomized AXI slave.  It ends an injected early-RLAST
    // burst on that actual RLAST handshake, while a missing-RLAST injection
    // ends after the ARLEN-implied final beat.
    always_ff @(posedge clk) begin : axi_memory_model
        integer global_index;
        integer burst_bytes;
        if (rst) begin
            lfsr <= 32'h1ace_b00c;
            m_axi_arready <= 1'b0;
            bank_ready_gate <= 1'b0;
            mem_active <= 1'b0;
            mem_burst_addr <= 32'd0;
            mem_burst_beats <= 0;
            mem_beat_index <= 0;
            mem_gap <= 0;
            mem_rvalid_q <= 1'b0;
            mem_rdata_q <= 128'd0;
            mem_rresp_q <= 2'b00;
            mem_rlast_q <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            bank_ready_gate <= lfsr[1] || lfsr[7] || lfsr[13];

            if (force_ar_stall || mem_active)
                m_axi_arready <= 1'b0;
            else
                m_axi_arready <= lfsr[0] || lfsr[5];

            if (m_axi_arvalid && m_axi_arready) begin
                if (mem_active)
                    $fatal(1, "more than one AXI burst outstanding");
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "invalid AXI ARSIZE/ARBURST");
                if (m_axi_arlen > 8'd15)
                    $fatal(1, "AXI burst exceeds 16 beats");
                burst_bytes = (m_axi_arlen + 1) * 16;
                if ((m_axi_araddr[11:0] + burst_bytes) > 4096)
                    $fatal(1, "AXI burst crosses 4 KiB");
                if (m_axi_araddr[3:0] != 4'd0)
                    $fatal(1, "AXI address is not 16-byte aligned");

                mem_active <= 1'b1;
                mem_burst_addr <= m_axi_araddr;
                mem_burst_beats <= m_axi_arlen + 1;
                mem_beat_index <= 0;
                mem_gap <= lfsr[10:9];
                mem_rvalid_q <= 1'b0;
            end

            if (mem_active) begin
                if (mem_rvalid_q) begin
                    if (m_axi_rready) begin
                        mem_rvalid_q <= 1'b0;
                        if (mem_rlast_q ||
                            (mem_beat_index == mem_burst_beats - 1)) begin
                            mem_active <= 1'b0;
                        end else begin
                            mem_beat_index <= mem_beat_index + 1;
                            mem_gap <= lfsr[4:3];
                        end
                    end
                end else if (mem_gap != 0) begin
                    mem_gap <= mem_gap - 1;
                end else if (lfsr[2] || lfsr[8]) begin
                    global_index = ((mem_burst_addr - transaction_base) >> 4)
                                   + mem_beat_index;
                    mem_rvalid_q <= 1'b1;
                    mem_rdata_q <= arena_word(transaction_image,
                                                global_index);
                    mem_rresp_q <=
                        (global_index == inject_rresp_index) ? 2'b10 : 2'b00;
                    mem_rlast_q <=
                        (mem_beat_index == mem_burst_beats - 1);
                    if (global_index == inject_rlast_index) begin
                        if (inject_rlast_mode == 1)
                            mem_rlast_q <= 1'b1;
                        else if (inject_rlast_mode == 2)
                            mem_rlast_q <= 1'b0;
                    end
                end
            end
        end
    end

    // Scoreboards and protocol stability checks.
    always @(posedge clk) begin
        if (rst) begin
            done_count = 0;
            error_count = 0;
            aborted_count = 0;
            bank_done_count = 0;
            bank_aborted_count = 0;
            ar_count = 0;
            r_count = 0;
            bank_word_count = 0;
            current_bank_word_count = 0;
            early_rlast_seen = 0;
            missing_rlast_seen = 0;
            prev_ar_stall = 1'b0;
            prev_araddr = 32'd0;
            prev_arlen = 8'd0;
            prev_abort = 1'b0;
            prev_bank_stall = 1'b0;
            prev_bank_data = 128'd0;
            prev_bank_last = 1'b0;
        end else begin
            if (done)
                done_count = done_count + 1;
            if (error)
                error_count = error_count + 1;
            if (aborted)
                aborted_count = aborted_count + 1;
            if (bank_load_done)
                bank_done_count = bank_done_count + 1;
            if (bank_load_aborted)
                bank_aborted_count = bank_aborted_count + 1;

            if (m_axi_arvalid && m_axi_arready)
                ar_count = ar_count + 1;
            if (m_axi_rvalid && m_axi_rready) begin
                r_count = r_count + 1;
                if (m_axi_rlast &&
                    (mem_beat_index != mem_burst_beats - 1))
                    early_rlast_seen = early_rlast_seen + 1;
                if (!m_axi_rlast &&
                    (mem_beat_index == mem_burst_beats - 1))
                    missing_rlast_seen = missing_rlast_seen + 1;
            end

            if (loader_bank_load_start)
                current_bank_word_count = 0;
            if (actual_bank_load_valid && bank_load_ready_raw) begin
                if (loader_bank_load_last !=
                    (current_bank_word_count == ARENA_WORDS - 1))
                    $fatal(1, "bank load_last position mismatch");
                current_bank_word_count = current_bank_word_count + 1;
                bank_word_count = bank_word_count + 1;
            end

            if (prev_ar_stall && !prev_abort && !abort) begin
                if (!m_axi_arvalid || m_axi_araddr != prev_araddr ||
                    m_axi_arlen != prev_arlen)
                    $fatal(1, "AR payload changed under normal stall");
            end
            prev_ar_stall = m_axi_arvalid && !m_axi_arready;
            prev_araddr = m_axi_araddr;
            prev_arlen = m_axi_arlen;

            if (prev_bank_stall && !prev_abort && !abort) begin
                if (!loader_bank_load_valid ||
                    loader_bank_load_data != prev_bank_data ||
                    loader_bank_load_last != prev_bank_last)
                    $fatal(1, "bank payload changed under stall");
            end
            prev_bank_stall = loader_bank_load_valid &&
                              !loader_bank_load_ready;
            prev_bank_data = loader_bank_load_data;
            prev_bank_last = loader_bank_load_last;
            prev_abort = abort;
        end
    end

    task automatic launch_load(
        input logic [31:0] base,
        input integer image,
        input integer rresp_index,
        input integer rlast_index,
        input integer rlast_mode
    );
        integer guard;
        begin
            @(negedge clk);
            transaction_base = base;
            transaction_image = image;
            inject_rresp_index = rresp_index;
            inject_rlast_index = rlast_index;
            inject_rlast_mode = rlast_mode;
            start_base_addr = base;
            start_valid = 1'b1;
            guard = 0;
            while (!start_ready && guard < 1000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!start_ready)
                $fatal(1, "start handshake timeout");
            @(posedge clk);
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task automatic wait_terminal(
        input integer done_before,
        input integer error_before,
        input integer aborted_before,
        input integer expected_kind // 0 done, 1 error, 2 aborted
    );
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && cycles < 200000) begin
                @(posedge clk);
                #1;
                if (expected_kind == 0)
                    seen = (done_count == done_before + 1);
                else if (expected_kind == 1)
                    seen = (error_count == error_before + 1);
                else
                    seen = (aborted_count == aborted_before + 1);
                cycles = cycles + 1;
            end
            if (!seen)
                $fatal(1, "terminal pulse timeout kind=%0d", expected_kind);
            if ((done_count != done_before + (expected_kind == 0)) ||
                (error_count != error_before + (expected_kind == 1)) ||
                (aborted_count != aborted_before +
                                  (expected_kind == 2)))
                $fatal(1, "unexpected terminal pulse overlap");
        end
    endtask

    task automatic check_active_word(
        input integer index,
        input integer image
    );
        logic [127:0] expected;
        begin
            expected = arena_word(image, index);
            @(negedge clk);
            rd_addr = index[ADDR_W-1:0];
            rd_en[0] = 1'b1;
            @(posedge clk);
            #1;
            if (!rd_valid[0] || rd_error[0])
                $fatal(1, "active-bank read failed at word %0d", index);
            if (rd_data !== expected)
                $fatal(1, "active-bank data mismatch at word %0d", index);
            @(negedge clk);
            rd_en[0] = 1'b0;
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

    initial begin : test_sequence
        integer d0;
        integer e0;
        integer a0;
        integer bd0;
        integer ba0;
        integer ar0;
        integer r0;
        integer bw0;

        clk = 1'b0;
        rst = 1'b1;
        start_valid = 1'b0;
        start_base_addr = 32'd0;
        abort = 1'b0;
        force_ar_stall = 1'b0;
        transaction_base = 32'd0;
        transaction_image = 0;
        inject_rresp_index = -1;
        inject_rlast_index = -1;
        inject_rlast_mode = 0;
        rd_en = '0;
        rd_addr = '0;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Full successful load.  Offset 0xff0 forces a one-beat burst before
        // the first 4 KiB boundary; every accepted bank word is counted.
        d0 = done_count;
        e0 = error_count;
        a0 = aborted_count;
        bd0 = bank_done_count;
        bw0 = bank_word_count;
        ar0 = ar_count;
        launch_load(32'h0000_0ff0, 0, -1, -1, 0);
        wait_terminal(d0, e0, a0, 0);
        if (!active_valid || generation != 32'd1 || !active_bank)
            $fatal(1, "first successful load did not commit bank 1");
        if (bank_done_count != bd0 + 1 ||
            bank_word_count != bw0 + ARENA_WORDS)
            $fatal(1, "first full image word/commit count mismatch");
        if (ar_count != ar0 + 67)
            $fatal(1, "unexpected burst count for 0xff0-aligned image");
        check_active_word(0, 0);
        check_active_word(1, 0);
        check_active_word(511, 0);
        check_active_word(1024, 0);
        check_active_word(1055, 0);

        // Illegal starts neither open AXI nor disturb the active generation.
        e0 = error_count;
        ar0 = ar_count;
        launch_load(32'h0000_0123, 1, -1, -1, 0);
        wait_terminal(done_count, e0, aborted_count, 1);
        if (error_code != ERR_BASE_ALIGN || error_address != 32'h0000_0123)
            $fatal(1, "misaligned-base diagnostic mismatch");
        if (ar_count != ar0 || generation != 32'd1)
            $fatal(1, "misaligned request touched AXI or active bank");

        e0 = error_count;
        ar0 = ar_count;
        launch_load(32'hffff_be10, 1, -1, -1, 0);
        wait_terminal(done_count, e0, aborted_count, 1);
        if (error_code != ERR_ADDR_OVERFLOW ||
            error_address != 32'hffff_be10)
            $fatal(1, "overflow diagnostic mismatch");
        if (ar_count != ar0 || generation != 32'd1)
            $fatal(1, "overflow request touched AXI or active bank");

        // RRESP failure drains the remainder of its already accepted burst,
        // stops issuing AR, and aborts the shadow bank.
        e0 = error_count;
        ba0 = bank_aborted_count;
        ar0 = ar_count;
        launch_load(32'h0020_0ff0, 1, 9, -1, 0);
        wait_terminal(done_count, e0, aborted_count, 1);
        if (error_code != ERR_RRESP ||
            error_address != 32'h0020_1080)
            $fatal(1, "RRESP diagnostic mismatch");
        if (ar_count != ar0 + 2 || bank_aborted_count != ba0 + 1 ||
            generation != 32'd1 || !active_bank)
            $fatal(1, "RRESP failure did not safely abort shadow load");
        check_active_word(511, 0);

        // Early RLAST is itself the physical end of the malformed burst.  The
        // loader must not wait for impossible trailing beats.
        e0 = error_count;
        ba0 = bank_aborted_count;
        ar0 = ar_count;
        launch_load(32'h0030_0000, 1, -1, 5, 1);
        wait_terminal(done_count, e0, aborted_count, 1);
        if (error_code != ERR_RLAST ||
            error_address != 32'h0030_0050)
            $fatal(1, "early-RLAST diagnostic mismatch");
        if (ar_count != ar0 + 1 || bank_aborted_count != ba0 + 1 ||
            generation != 32'd1)
            $fatal(1, "early RLAST did not terminate safely");

        // Missing RLAST terminates at the ARLEN-implied beat count and also
        // aborts without waiting for an extra, undefined beat.
        e0 = error_count;
        ba0 = bank_aborted_count;
        ar0 = ar_count;
        launch_load(32'h0031_0000, 1, -1, 15, 2);
        wait_terminal(done_count, e0, aborted_count, 1);
        if (error_code != ERR_RLAST ||
            error_address != 32'h0031_00f0)
            $fatal(1, "missing-RLAST diagnostic mismatch");
        if (ar_count != ar0 + 1 || bank_aborted_count != ba0 + 1 ||
            generation != 32'd1)
            $fatal(1, "missing RLAST did not terminate safely");

        // Abort before AR acceptance: no AXI transaction exists to drain.
        force_ar_stall = 1'b1;
        a0 = aborted_count;
        ba0 = bank_aborted_count;
        ar0 = ar_count;
        launch_load(32'h0040_0000, 1, -1, -1, 0);
        wait (m_axi_arvalid);
        pulse_abort();
        wait_terminal(done_count, error_count, a0, 2);
        force_ar_stall = 1'b0;
        if (ar_count != ar0 || bank_aborted_count != ba0 + 1 ||
            generation != 32'd1)
            $fatal(1, "pre-AR abort contract mismatch");

        // Abort after AR and several R beats.  The slave continues the burst;
        // the loader holds RREADY high, drains it, and issues no next AR.
        a0 = aborted_count;
        ba0 = bank_aborted_count;
        ar0 = ar_count;
        r0 = r_count;
        launch_load(32'h0041_0000, 1, -1, -1, 0);
        while (r_count < r0 + 3)
            @(posedge clk);
        pulse_abort();
        wait_terminal(done_count, error_count, a0, 2);
        if (ar_count != ar0 + 1 || bank_aborted_count != ba0 + 1 ||
            generation != 32'd1 || !active_bank)
            $fatal(1, "post-AR abort did not drain exactly one burst");
        check_active_word(1024, 0);

        // A full restart after all failure modes must atomically replace the
        // previous generation and expose only the new complete image.
        d0 = done_count;
        bd0 = bank_done_count;
        bw0 = bank_word_count;
        ar0 = ar_count;
        launch_load(32'h0100_0000, 2, -1, -1, 0);
        wait_terminal(d0, error_count, aborted_count, 0);
        if (!active_valid || generation != 32'd2 || active_bank)
            $fatal(1, "restart did not commit bank 0 generation 2");
        if (bank_done_count != bd0 + 1 ||
            bank_word_count != bw0 + ARENA_WORDS)
            $fatal(1, "restart full-image word/commit count mismatch");
        if (ar_count != ar0 + 66)
            $fatal(1, "unexpected aligned-image burst count");
        check_active_word(0, 2);
        check_active_word(17, 2);
        check_active_word(511, 2);
        check_active_word(1024, 2);
        check_active_word(1055, 2);

        if (done_count != 2 || error_count != 5 || aborted_count != 2 ||
            bank_done_count != 2 || bank_aborted_count != 5)
            $fatal(1, "final terminal counters mismatch");
        if (early_rlast_seen != 1 || missing_rlast_seen != 1)
            $fatal(1, "RLAST fault coverage counters mismatch");
        if (busy || bank_load_busy || mem_active || mem_rvalid_q)
            $fatal(1, "subsystem not idle at end of regression");

        $display("C1_AXI_PARAMETER_LOADER_PASS words=1056 successes=2 errors=5 aborts=2 early_rlast=1 missing_rlast=1");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "global simulation timeout");
    end

endmodule
