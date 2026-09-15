`timescale 1ns/1ps

module tb_c1_r1_parameter_bank #(parameter bit ABORT_FINAL = 1'b0);

    localparam integer ARENA_BYTES = 16896;
    localparam integer ARENA_WORDS = ARENA_BYTES / 16;
    localparam integer ABORT_INDEX = ABORT_FINAL ? ARENA_WORDS-1 : 73;
    localparam integer ADDR_W = $clog2(ARENA_WORDS);

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic load_start = 1'b0;
    wire load_start_ready;
    logic load_valid = 1'b0;
    wire load_ready;
    logic [127:0] load_data = '0;
    logic load_last = 1'b0;
    logic load_abort = 1'b0;
    wire load_busy;
    wire load_done;
    wire load_aborted;
    wire load_error;
    wire [2:0] load_error_code;

    wire active_valid;
    wire active_bank;
    wire [31:0] generation;

    logic rd_en = 1'b0;
    logic [ADDR_W-1:0] rd_addr = '0;
    wire rd_valid;
    wire rd_error;
    wire [127:0] rd_data;

    logic [31:0] lfsr = 32'h1d872b41;
    integer done_pulses = 0;
    integer error_pulses = 0;
    integer abort_pulses = 0;
    integer successful_reads = 0;
    integer concurrent_reads = 0;
    integer gap_cycles = 0;

    always #5 clk = ~clk;

    c1_r1_parameter_bank #(
        .ARENA_BYTES(ARENA_BYTES),
        .READ_PORTS(1),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk,
        .rst,
        .load_start,
        .load_start_ready,
        .load_valid,
        .load_ready,
        .load_data,
        .load_last,
        .load_abort,
        .load_busy,
        .load_done,
        .load_aborted,
        .load_error,
        .load_error_code,
        .active_valid,
        .active_bank,
        .generation,
        .rd_en,
        .rd_addr,
        .rd_valid,
        .rd_error,
        .rd_data
    );

    function automatic logic [31:0] next_lfsr(input logic [31:0] value);
        begin
            next_lfsr = {value[30:0],
                         value[31] ^ value[21] ^ value[1] ^ value[0]};
        end
    endfunction

    function automatic logic [127:0] arena_word(
        input integer image,
        input integer index
    );
        logic [31:0] a;
        logic [31:0] b;
        logic [31:0] c;
        logic [31:0] d;
        begin
            a = 32'h10203040 ^ (image * 32'h11111111) ^ index;
            b = 32'h89abcdef + image * 32'h01020305 + index * 32'd17;
            c = 32'h55aa33cc ^ (index * 32'h00010001) ^
                (image * 32'h24681357);
            d = 32'hf00dcafe - index * 32'd257 - image * 32'd65537;
            arena_word = {a, b, c, d};
        end
    endfunction

    task automatic start_load;
        logic sampled_ready;
        begin
            while (!load_start_ready) @(negedge clk);
            @(negedge clk);
            load_start = 1'b1;
            @(posedge clk);
            sampled_ready = load_start_ready;
            #1;
            if (!sampled_ready || !load_busy || load_error)
                $fatal(1, "parameter load failed to start");
            @(negedge clk);
            load_start = 1'b0;
        end
    endtask

    task automatic idle_gaps(input integer count);
        integer gap;
        begin
            for (gap = 0; gap < count; gap = gap + 1) begin
                @(negedge clk);
                load_valid = 1'b0;
                load_last = 1'b0;
                rd_en = 1'b0;
                lfsr = next_lfsr(lfsr);
                gap_cycles = gap_cycles + 1;
                @(posedge clk);
                #1;
                if (!load_busy)
                    $fatal(1, "parameter loader left busy during input gap");
            end
        end
    endtask

    task automatic send_beat(
        input integer image,
        input integer index,
        input logic last_value,
        input logic expect_done,
        input logic expect_error,
        input logic [2:0] expected_error_code,
        input logic check_old_active,
        input integer old_active_image
    );
        logic sampled_ready;
        integer read_index;
        begin
            read_index = (index * 37 + 11) % ARENA_WORDS;
            @(negedge clk);
            load_valid = 1'b1;
            load_data = arena_word(image, index);
            load_last = last_value;
            rd_en = check_old_active;
            rd_addr = read_index[ADDR_W-1:0];
            @(posedge clk);
            sampled_ready = load_ready;
            #1;
            if (!sampled_ready)
                $fatal(1, "expected parameter beat was not accepted index=%0d",
                       index);
            if (load_done !== expect_done || load_error !== expect_error)
                $fatal(1, "parameter terminal status mismatch index=%0d",
                       index);
            if (expect_error && load_error_code != expected_error_code)
                $fatal(1, "parameter load error code mismatch index=%0d",
                       index);
            if (check_old_active) begin
                if (!rd_valid || rd_error ||
                    rd_data !== arena_word(old_active_image, read_index))
                    $fatal(1,
                        "active read changed during shadow load index=%0d",
                        read_index);
                concurrent_reads = concurrent_reads + 1;
            end
            @(negedge clk);
            load_valid = 1'b0;
            load_last = 1'b0;
            rd_en = 1'b0;
            lfsr = next_lfsr(lfsr);
        end
    endtask

    task automatic good_load(
        input integer new_image,
        input logic check_old_active,
        input integer old_active_image
    );
        integer index;
        integer random_gaps;
        begin
            start_load();
            for (index = 0; index < ARENA_WORDS; index = index + 1) begin
                random_gaps = lfsr[1:0];
                if (random_gaps != 0)
                    idle_gaps(random_gaps);
                send_beat(new_image, index, index == ARENA_WORDS - 1,
                          index == ARENA_WORDS - 1, 1'b0, 3'd0,
                          check_old_active, old_active_image);
            end
            if (load_busy || !active_valid)
                $fatal(1, "successful parameter load did not commit");
        end
    endtask

    task automatic read_word_checked(
        input integer image,
        input integer index
    );
        begin
            @(negedge clk);
            rd_en = 1'b1;
            rd_addr = index[ADDR_W-1:0];
            @(posedge clk);
            #1;
            if (!rd_valid || rd_error || rd_data !== arena_word(image, index))
                $fatal(1, "parameter readback mismatch index=%0d", index);
            successful_reads = successful_reads + 1;
            @(negedge clk);
            rd_en = 1'b0;
        end
    endtask

    task automatic read_all(input integer image);
        integer index;
        begin
            for (index = 0; index < ARENA_WORDS; index = index + 1)
                read_word_checked(image, index);
        end
    endtask

    task automatic verify_active_identity(
        input logic expected_bank,
        input logic [31:0] expected_generation
    );
        begin
            if (!active_valid || active_bank !== expected_bank ||
                generation !== expected_generation)
                $fatal(1, "active parameter identity changed unexpectedly");
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (load_done)
                done_pulses = done_pulses + 1;
            if (load_error)
                error_pulses = error_pulses + 1;
            if (load_aborted)
                abort_pulses = abort_pulses + 1;
        end
    end

    integer index;
    logic sampled_ready;
    logic [127:0] aborted_payload;
    initial begin
        repeat (6) @(negedge clk);
        rst = 1'b0;

        // Reads are explicitly rejected before the first complete arena.
        @(negedge clk);
        rd_en = 1'b1;
        rd_addr = '0;
        @(posedge clk);
        #1;
        if (rd_valid || !rd_error)
            $fatal(1, "read before first active arena was not rejected");
        @(negedge clk);
        rd_en = 1'b0;

        // First exact load switches from reset-selected bank 0 to bank 1.
        good_load(0, 1'b0, 0);
        verify_active_identity(1'b1, 32'd1);
        read_all(0);

        // Early last terminates a short arena and leaves bank 1 untouched.
        start_load();
        for (index = 0; index < 31; index = index + 1)
            send_beat(2, index, index == 30, 1'b0, index == 30,
                      3'd1, 1'b0, 0);
        verify_active_identity(1'b1, 32'd1);
        read_all(0);

        // Missing last on the exact final word rejects the transaction.  An
        // attempted later last is not accepted because the session is closed.
        start_load();
        for (index = 0; index < ARENA_WORDS; index = index + 1)
            send_beat(2, index, 1'b0, 1'b0,
                      index == ARENA_WORDS - 1,
                      index == ARENA_WORDS - 1 ? 3'd2 : 3'd0,
                      1'b0, 0);
        @(negedge clk);
        load_valid = 1'b1;
        load_data = arena_word(2, 0);
        load_last = 1'b1;
        @(posedge clk);
        sampled_ready = load_ready;
        #1;
        if (sampled_ready || load_done || load_error)
            $fatal(1, "late/extra last beat was incorrectly accepted");
        @(negedge clk);
        load_valid = 1'b0;
        load_last = 1'b0;
        verify_active_identity(1'b1, 32'd1);
        read_all(0);

        // Abort wins over a simultaneously presented beat and keeps the old
        // arena active.  This partial bank is then safely overwritten by the
        // following complete restart.
        start_load();
        for (index = 0; index < ABORT_INDEX; index = index + 1)
            send_beat(1, index, 1'b0, 1'b0, 1'b0, 3'd0,
                      1'b0, 0);
        @(negedge clk);
        aborted_payload = arena_word(1, ABORT_INDEX);
        load_valid = 1'b1;
        load_data = aborted_payload;
        load_last = ABORT_FINAL;
        load_abort = 1'b1;
        @(posedge clk);
        sampled_ready = load_ready;
        #1;
        if (sampled_ready || !load_aborted || load_busy ||
            load_done || load_error)
            $fatal(1, "parameter abort priority/status mismatch");
        if (load_data !== aborted_payload)
            $fatal(1, "stalled abort payload was not stable");
        @(negedge clk);
        load_valid = 1'b0;
        load_abort = 1'b0;
        verify_active_identity(1'b1, 32'd1);
        read_all(0);

        // Complete restart writes bank 0.  Every load beat also reads a
        // pseudo-random word from bank 1, including the atomic commit edge.
        good_load(1, 1'b1, 0);
        verify_active_identity(1'b0, 32'd2);
        read_all(1);

        repeat (8) @(posedge clk);
        if (done_pulses != 2 || error_pulses != 2 || abort_pulses != 1)
            $fatal(1,
                "parameter status pulse counts mismatch done=%0d err=%0d abort=%0d",
                done_pulses, error_pulses, abort_pulses);
        if (concurrent_reads != ARENA_WORDS)
            $fatal(1, "concurrent active-read coverage mismatch");
        if (successful_reads != ARENA_WORDS * 5)
            $fatal(1, "full readback coverage mismatch reads=%0d",
                   successful_reads);
        if (gap_cycles == 0)
            $fatal(1, "random load-gap coverage missing");
        if (load_busy || load_done || load_error || load_aborted ||
            rd_valid || rd_error)
            $fatal(1, "parameter bank failed to return idle");

        $display("C1_PARAMETER_ABORT_BOUNDARY_PASS final=%0d old_arena_preserved=1 restart=1",ABORT_FINAL);

        $display(
            "C1_R1_PARAMETER_BANK_PASS words=%0d switches=%0d errors=%0d aborts=%0d",
            ARENA_WORDS, done_pulses, error_pulses, abort_pulses);
        $finish;
    end

    initial begin
        repeat (1000000) @(posedge clk);
        $fatal(1, "R1 parameter bank regression timeout");
    end

endmodule
