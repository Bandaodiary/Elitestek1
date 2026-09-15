`timescale 1ns/1ps

// Contract and bit-exact regression for c1_window_line_cache_c8.
//
// Frozen interface assumptions shared with the RTL implementation:
// * One cache word is one C8 vector (8 signed bytes, DATA_W=64).
// * A physical row contains every input group in x-major/group-minor order:
//     word_index = x * frame_groups + group.
// * tap_x/tap_y are signed logical coordinates.  The DUT performs SAME
//   replicate clamping before looking up (row, x, group).
// * group_start_valid is accepted only while quiescent; its configuration
//   remains stable through the handshake.  group_start_done acknowledges
//   cache invalidation/configuration.
// * refill_req_valid and tap_rsp_valid may never be withdrawn while stalled.
// * abort_req and flush_req are pulse requests that must be latched.  An
//   already accepted refill is drained through its declared word count and
//   an already presented tap response is drained before abort_done/flush_done.
//
// Coverage in this test:
// * 8x8 stride-1 and stride-2 3x3 SAME traversals;
// * two input groups interleaved inside every output pixel;
// * negative/right/bottom coordinate clamping and bit-exact C8 data;
// * refill-request backpressure plus refill-word source gaps;
// * tap-response backpressure/stability and tap-request stability while busy;
// * stage invalidation, idle flush invalidation, and abort during rsp stall;
// * invalid tap_group response without an external refill.
module tb_c1_window_line_cache_c8 #(parameter integer BANKED=0);
    localparam integer DATA_W = 64;
    localparam integer FRAME_W = 8;
    localparam integer FRAME_H = 8;
    localparam integer GROUPS = 2;
    localparam integer ROW_WORDS = FRAME_W * GROUPS;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic group_start_valid;
    logic group_start_ready;
    logic [15:0] frame_width;
    logic [15:0] frame_height;
    logic [3:0] frame_groups;
    logic group_start_done;
    logic group_start_error;
    logic [2:0] group_start_error_code;
    logic config_valid;

    logic abort_req;
    logic abort_done;
    logic flush_req;
    logic flush_done;

    logic tap_valid;
    logic tap_ready;
    logic signed [16:0] tap_x;
    logic signed [16:0] tap_y;
    logic [2:0] tap_group;
    logic tap_rsp_valid;
    logic tap_rsp_ready;
    logic [DATA_W-1:0] tap_rsp_data_s8;
    logic tap_rsp_error;

    logic refill_req_valid;
    logic refill_req_ready;
    logic [15:0] refill_req_row;
    logic [15:0] refill_req_word_count;
    logic refill_word_valid;
    logic refill_word_ready;
    logic [DATA_W-1:0] refill_word_data_s8;
    logic refill_word_last;
    logic refill_word_error;

    logic cache_error;
    logic [2:0] cache_error_code;
    logic busy;
    logic quiescent;

    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(3),
        .MAX_ROW_WORDS(ROW_WORDS),
        .MAX_GROUPS(8), .ROW_BANKED_STORAGE(BANKED)
    ) dut (
        .clk(clk),
        .rst(rst),
        .group_start_valid(group_start_valid),
        .group_start_ready(group_start_ready),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .frame_groups(frame_groups),
        .group_start_done(group_start_done),
        .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),
        .config_valid(config_valid),
        .abort_req(abort_req),
        .abort_done(abort_done),
        .flush_req(flush_req),
        .flush_done(flush_done),
        .tap_valid(tap_valid),
        .tap_ready(tap_ready),
        .tap_x(tap_x),
        .tap_y(tap_y),
        .tap_group(tap_group),
        .tap_rsp_valid(tap_rsp_valid),
        .tap_rsp_ready(tap_rsp_ready),
        .tap_rsp_data_s8(tap_rsp_data_s8),
        .tap_rsp_error(tap_rsp_error),
        .refill_req_valid(refill_req_valid),
        .refill_req_ready(refill_req_ready),
        .refill_req_row(refill_req_row),
        .refill_req_word_count(refill_req_word_count),
        .refill_word_valid(refill_word_valid),
        .refill_word_ready(refill_word_ready),
        .refill_word_data_s8(refill_word_data_s8),
        .refill_word_last(refill_word_last),
        .refill_word_error(refill_word_error),
        .cache_error(cache_error),
        .cache_error_code(cache_error_code),
        .busy(busy),
        .quiescent(quiescent)
    );

    integer equivalence_cycles=0;
    generate if(BANKED) begin : g_equivalence
        wire ref_start_ready,ref_start_done,ref_start_error,ref_config;
        wire ref_abort_done,ref_flush_done,ref_tap_ready,ref_rsp_valid,ref_rsp_error;
        wire ref_refill_valid,ref_word_ready,ref_cache_error,ref_busy,ref_quiescent;
        wire [2:0] ref_start_code,ref_cache_code;
        wire [15:0] ref_row,ref_words;
        wire [DATA_W-1:0] ref_data;
        c1_window_line_cache_c8 #(.DATA_W(DATA_W),.LINE_ROWS(3),
            .MAX_ROW_WORDS(ROW_WORDS),.MAX_GROUPS(8),.ROW_BANKED_STORAGE(0)) reference (
            .group_start_ready(ref_start_ready),.group_start_done(ref_start_done),
            .group_start_error(ref_start_error),.group_start_error_code(ref_start_code),
            .config_valid(ref_config),.abort_done(ref_abort_done),.flush_done(ref_flush_done),
            .tap_ready(ref_tap_ready),.tap_rsp_valid(ref_rsp_valid),
            .tap_rsp_error(ref_rsp_error),.tap_rsp_data_s8(ref_data),
            .refill_req_valid(ref_refill_valid),.refill_req_row(ref_row),
            .refill_req_word_count(ref_words),.refill_word_ready(ref_word_ready),
            .cache_error(ref_cache_error),.cache_error_code(ref_cache_code),
            .busy(ref_busy),.quiescent(ref_quiescent),.*
        );
        always @(posedge clk) begin
            #1;
            if(!rst) begin
                equivalence_cycles++;
                if({ref_start_ready,ref_start_done,ref_start_error,ref_start_code,ref_config,
                    ref_abort_done,ref_flush_done,ref_tap_ready,ref_rsp_valid,ref_rsp_error,
                    ref_refill_valid,ref_row,ref_words,ref_word_ready,ref_cache_error,
                    ref_cache_code,ref_busy,ref_quiescent} !==
                   {group_start_ready,group_start_done,group_start_error,group_start_error_code,config_valid,
                    abort_done,flush_done,tap_ready,tap_rsp_valid,tap_rsp_error,
                    refill_req_valid,refill_req_row,refill_req_word_count,refill_word_ready,cache_error,
                    cache_error_code,busy,quiescent})
                    $fatal(1,"banked/flat cache control timing differs");
                if(tap_rsp_valid && tap_rsp_data_s8 !== ref_data)
                    $fatal(1,"banked/flat cache response differs");
            end
        end
    end endgenerate

    integer cycle_count;
    integer memory_generation;
    integer configured_groups;
    integer response_count;
    integer tap_accept_count;
    integer refill_count;
    integer refill_word_count_seen;
    integer refill_req_stall_cycles;
    integer refill_source_gap_cycles;
    integer tap_rsp_stall_cycles;
    integer tap_input_stall_cycles;
    integer group_done_count;
    integer flush_done_count;
    integer abort_done_count;

    logic force_rsp_stall;
    logic expected_pending;
    logic [DATA_W-1:0] expected_rsp_data;
    logic expected_rsp_error;

    logic tap_hold_q;
    logic signed [16:0] tap_hold_x_q;
    logic signed [16:0] tap_hold_y_q;
    logic [2:0] tap_hold_group_q;
    logic rsp_hold_q;
    logic [DATA_W-1:0] rsp_hold_data_q;
    logic rsp_hold_error_q;
    logic refill_req_hold_q;
    logic [15:0] refill_req_hold_row_q;
    logic [15:0] refill_req_hold_words_q;

    function automatic integer clamp_coord(
        input integer value,
        input integer limit
    );
        begin
            if (value < 0)
                clamp_coord = 0;
            else if (value >= limit)
                clamp_coord = limit - 1;
            else
                clamp_coord = value;
        end
    endfunction

    function automatic [DATA_W-1:0] tensor_word(
        input integer generation,
        input integer row,
        input integer column,
        input integer group_index
    );
        integer lane;
        integer byte_value;
        begin
            tensor_word = '0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                // Every address field and every signed-byte lane contributes
                // to the value.  The checker compares the raw two's-complement
                // byte representation, so values above 127 exercise s8 data.
                byte_value = generation * 53 + row * 29 + column * 17 +
                             group_index * 71 + lane * 11 + 3;
                tensor_word[lane*8 +: 8] = byte_value[7:0];
            end
        end
    endfunction

    always_comb begin
        if (force_rsp_stall)
            tap_rsp_ready = 1'b0;
        else
            tap_rsp_ready = (cycle_count[2:0] != 3'b010);
    end

    // Protocol monitors and the single-outstanding response scoreboard.
    // Testbench bookkeeping is also touched by the stimulus tasks (for
    // example, they arm expected_pending before launching a request).  Keep
    // this as an ordinary clocked simulation process rather than always_ff;
    // always_ff deliberately rejects such shared testbench variables even
    // though the accesses are separated onto opposite clock edges.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            response_count <= 0;
            tap_accept_count <= 0;
            tap_rsp_stall_cycles <= 0;
            tap_input_stall_cycles <= 0;
            group_done_count <= 0;
            flush_done_count <= 0;
            abort_done_count <= 0;
            tap_hold_q <= 1'b0;
            rsp_hold_q <= 1'b0;
            refill_req_hold_q <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (tap_valid && tap_ready)
                tap_accept_count <= tap_accept_count + 1;
            if (group_start_done)
                group_done_count <= group_done_count + 1;
            if (flush_done)
                flush_done_count <= flush_done_count + 1;
            if (abort_done)
                abort_done_count <= abort_done_count + 1;

            if (tap_hold_q) begin
                if (!tap_valid || tap_x !== tap_hold_x_q ||
                    tap_y !== tap_hold_y_q || tap_group !== tap_hold_group_q)
                    $fatal(1,
                           "tap request changed while tap_ready=0 cycle=%0d held(v=%0b x=%0d y=%0d g=%0d) now(v=%0b x=%0d y=%0d g=%0d ready=%0b state_busy=%0b)",
                           cycle_count, tap_hold_q, tap_hold_x_q,
                           tap_hold_y_q, tap_hold_group_q, tap_valid, tap_x,
                           tap_y, tap_group, tap_ready, busy);
            end
            if (tap_valid && !tap_ready)
                tap_input_stall_cycles <= tap_input_stall_cycles + 1;
            tap_hold_q <= tap_valid && !tap_ready;
            tap_hold_x_q <= tap_x;
            tap_hold_y_q <= tap_y;
            tap_hold_group_q <= tap_group;

            if (rsp_hold_q) begin
                if (!tap_rsp_valid || tap_rsp_data_s8 !== rsp_hold_data_q ||
                    tap_rsp_error !== rsp_hold_error_q)
                    $fatal(1, "tap response changed while tap_rsp_ready=0");
            end
            if (tap_rsp_valid && !tap_rsp_ready)
                tap_rsp_stall_cycles <= tap_rsp_stall_cycles + 1;
            rsp_hold_q <= tap_rsp_valid && !tap_rsp_ready;
            rsp_hold_data_q <= tap_rsp_data_s8;
            rsp_hold_error_q <= tap_rsp_error;

            if (refill_req_hold_q) begin
                if (!refill_req_valid ||
                    refill_req_row !== refill_req_hold_row_q ||
                    refill_req_word_count !== refill_req_hold_words_q)
                    $fatal(1, "refill request changed while refill_req_ready=0");
            end
            refill_req_hold_q <= refill_req_valid && !refill_req_ready;
            refill_req_hold_row_q <= refill_req_row;
            refill_req_hold_words_q <= refill_req_word_count;

            if (tap_rsp_valid && tap_rsp_ready) begin
                if (!expected_pending)
                    $fatal(1, "unexpected tap response");
                if (tap_rsp_data_s8 !== expected_rsp_data ||
                    tap_rsp_error !== expected_rsp_error)
                    $fatal(1,
                           "tap response mismatch got=%h err=%0b expected=%h err=%0b",
                           tap_rsp_data_s8, tap_rsp_error,
                           expected_rsp_data, expected_rsp_error);
                expected_pending <= 1'b0;
                response_count <= response_count + 1;
            end
        end
    end

    // External tensor-memory model.  Every row request is deliberately held
    // off for two clocks.  Accepted rows are then returned with deterministic
    // bubbles, in x-major/group-minor order.
    initial begin : refill_memory_bfm
        integer held_row;
        integer held_words;
        integer held_generation;
        integer held_groups;
        integer word_index;
        integer word_x;
        integer word_group;

        refill_req_ready = 1'b0;
        refill_word_valid = 1'b0;
        refill_word_data_s8 = '0;
        refill_word_last = 1'b0;
        refill_word_error = 1'b0;
        refill_count = 0;
        refill_word_count_seen = 0;
        refill_req_stall_cycles = 0;
        refill_source_gap_cycles = 0;

        wait (!rst);
        forever begin
            while (!refill_req_valid)
                @(negedge clk);

            held_row = refill_req_row;
            held_words = refill_req_word_count;
            held_generation = memory_generation;
            held_groups = configured_groups;
            if (held_row < 0 || held_row >= FRAME_H)
                $fatal(1, "DUT requested unclamped row %0d", held_row);
            if (held_words != FRAME_W * held_groups)
                $fatal(1, "refill word count mismatch row=%0d got=%0d expected=%0d",
                       held_row, held_words, FRAME_W * held_groups);

            repeat (2) begin
                if (!refill_req_valid || refill_req_row != held_row ||
                    refill_req_word_count != held_words)
                    $fatal(1, "refill request was not stable during BFM stall");
                refill_req_stall_cycles = refill_req_stall_cycles + 1;
                @(negedge clk);
            end

            refill_req_ready = 1'b1;
            @(posedge clk);
            if (!refill_req_valid)
                $fatal(1, "refill request vanished on acceptance edge");
            @(negedge clk);
            refill_req_ready = 1'b0;
            refill_count = refill_count + 1;

            for (word_index = 0; word_index < held_words;
                 word_index = word_index + 1) begin
                if ((word_index % 3) == 1) begin
                    refill_source_gap_cycles = refill_source_gap_cycles + 1;
                    @(negedge clk);
                end
                word_x = word_index / held_groups;
                word_group = word_index % held_groups;
                refill_word_data_s8 = tensor_word(held_generation, held_row,
                                                  word_x, word_group);
                refill_word_last = (word_index == held_words - 1);
                refill_word_valid = 1'b1;

                do begin
                    @(posedge clk);
                end while (!refill_word_ready);

                refill_word_count_seen = refill_word_count_seen + 1;
                @(negedge clk);
                refill_word_valid = 1'b0;
                refill_word_last = 1'b0;
            end
        end
    end

    task automatic start_stage(input integer generation);
        integer done_before;
        begin
            done_before = group_done_count;
            @(negedge clk);
            memory_generation = generation;
            configured_groups = GROUPS;
            frame_width = FRAME_W;
            frame_height = FRAME_H;
            frame_groups = GROUPS;
            group_start_valid = 1'b1;
            while (!group_start_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            group_start_valid = 1'b0;
            while (group_done_count == done_before)
                @(negedge clk);
            if (group_start_error || group_start_error_code != 3'd0)
                $fatal(1, "valid group_start reported error code=%0d",
                       group_start_error_code);
            if (!config_valid)
                $fatal(1, "configuration not valid after group_start_done");
            if (!quiescent || busy)
                $fatal(1, "cache not quiescent after group_start_done");
        end
    endtask

    task automatic launch_tap_no_wait(
        input integer raw_x,
        input integer raw_y,
        input integer group_index,
        input integer generation,
        input logic expect_error
    );
        integer clamped_x;
        integer clamped_y;
        begin
            while (expected_pending)
                @(negedge clk);
            clamped_x = clamp_coord(raw_x, FRAME_W);
            clamped_y = clamp_coord(raw_y, FRAME_H);
            if (expect_error)
                expected_rsp_data = '0;
            else
                expected_rsp_data = tensor_word(generation, clamped_y,
                                                clamped_x, group_index);
            expected_rsp_error = expect_error;
            expected_pending = 1'b1;

            @(negedge clk);
            tap_x = raw_x;
            tap_y = raw_y;
            tap_group = group_index;
            tap_valid = 1'b1;
            // Sample ready only on a rising edge.  Checking it immediately
            // after changing x/y/group at a negedge can observe the previous
            // request's combinational ready for one simulator delta cycle.
            do begin
                @(posedge clk);
            end while (!tap_ready);
            @(negedge clk);
            tap_valid = 1'b0;
        end
    endtask

    task automatic send_tap(
        input integer raw_x,
        input integer raw_y,
        input integer group_index,
        input integer generation,
        input logic expect_error
    );
        begin
            launch_tap_no_wait(raw_x, raw_y, group_index, generation,
                               expect_error);
            while (expected_pending)
                @(negedge clk);
        end
    endtask

    task automatic drive_stage(
        input integer stride,
        input integer generation
    );
        integer output_w;
        integer output_h;
        integer ox;
        integer oy;
        integer group_index;
        integer kx;
        integer ky;
        begin
            output_w = (stride == 1) ? FRAME_W : (FRAME_W / 2);
            output_h = (stride == 1) ? FRAME_H : (FRAME_H / 2);
            for (oy = 0; oy < output_h; oy = oy + 1) begin
                for (ox = 0; ox < output_w; ox = ox + 1) begin
                    // The real adapter traverses pixel then input_group.  A
                    // cache that stores only one group per row fails here.
                    for (group_index = 0; group_index < GROUPS;
                         group_index = group_index + 1) begin
                        for (ky = -1; ky <= 1; ky = ky + 1) begin
                            for (kx = -1; kx <= 1; kx = kx + 1) begin
                                send_tap(ox * stride + kx,
                                         oy * stride + ky,
                                         group_index, generation, 1'b0);
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic pulse_flush;
        integer done_before;
        begin
            done_before = flush_done_count;
            @(negedge clk);
            flush_req = 1'b1;
            @(negedge clk);
            flush_req = 1'b0;
            while (flush_done_count == done_before)
                @(negedge clk);
            if (busy || !quiescent)
                $fatal(1, "cache did not quiesce after flush_done");
        end
    endtask

    initial begin : main_test
        integer accept_before;
        integer abort_before;

        group_start_valid = 1'b0;
        frame_width = FRAME_W;
        frame_height = FRAME_H;
        frame_groups = GROUPS;
        abort_req = 1'b0;
        flush_req = 1'b0;
        tap_valid = 1'b0;
        tap_x = '0;
        tap_y = '0;
        tap_group = '0;
        force_rsp_stall = 1'b0;
        expected_pending = 1'b0;
        expected_rsp_data = '0;
        expected_rsp_error = 1'b0;
        memory_generation = 0;
        configured_groups = GROUPS;

        repeat (5) @(negedge clk);
        rst = 1'b0;

        start_stage(1);
        drive_stage(1, 1);

        // Refill row zero after the raster has moved to the bottom.  The
        // following group_start must invalidate this known-resident old row;
        // otherwise the first stage-2 comparison returns generation-1 data.
        send_tap(0, 0, 0, 1, 1'b0);

        start_stage(2);
        drive_stage(2, 2);

        // Invalid group is a local error response and must not fetch memory.
        send_tap(3, 3, GROUPS, 2, 1'b1);
        if (refill_count != 17)
            $fatal(1, "invalid group unexpectedly changed refill count=%0d",
                   refill_count);

        // Row seven is resident at the end of stride-2.  An idle flush must
        // invalidate it, so the next access causes exactly one new refill.
        pulse_flush();
        if (!config_valid)
            $fatal(1, "flush unexpectedly cleared the active configuration");

        // Hold the post-flush response.  While it is blocked, present a
        // second hit request and prove both output and input remain stable.
        force_rsp_stall = 1'b1;
        launch_tap_no_wait(7, 7, 1, 2, 1'b0);
        while (!tap_rsp_valid)
            @(negedge clk);

        accept_before = tap_accept_count;
        @(negedge clk);
        tap_x = 17'sd6;
        tap_y = 17'sd7;
        tap_group = 3'd0;
        tap_valid = 1'b1;
        repeat (4) begin
            @(posedge clk);
            if (tap_ready)
                $fatal(1, "second tap accepted while response was stalled");
        end
        @(negedge clk);
        force_rsp_stall = 1'b0;
        while (expected_pending)
            @(negedge clk);

        expected_rsp_data = tensor_word(2, 7, 6, 0);
        expected_rsp_error = 1'b0;
        expected_pending = 1'b1;
        while (tap_accept_count == accept_before)
            @(negedge clk);
        tap_valid = 1'b0;
        while (expected_pending)
            @(negedge clk);

        // Abort while a valid response is stalled.  The response cannot be
        // withdrawn; abort_done is expected only after that response drains.
        force_rsp_stall = 1'b1;
        launch_tap_no_wait(5, 7, 0, 2, 1'b0);
        while (!tap_rsp_valid)
            @(negedge clk);
        abort_before = abort_done_count;
        @(negedge clk);
        abort_req = 1'b1;
        @(negedge clk);
        abort_req = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (abort_done)
                $fatal(1, "abort_done asserted before stalled response drained");
        end
        @(negedge clk);
        force_rsp_stall = 1'b0;
        while (expected_pending)
            @(negedge clk);
        while (abort_done_count == abort_before)
            @(negedge clk);

        repeat (3) @(negedge clk);
        if (response_count != 1445)
            $fatal(1, "response count mismatch got=%0d expected=1445",
                   response_count);
        if (tap_accept_count != 1445)
            $fatal(1, "tap acceptance count mismatch got=%0d expected=1445",
                   tap_accept_count);
        if (refill_count != 18 || refill_word_count_seen != 288)
            $fatal(1, "refill totals mismatch rows=%0d words=%0d",
                   refill_count, refill_word_count_seen);
        if (group_done_count != 2 || flush_done_count != 1 ||
            abort_done_count != 1)
            $fatal(1, "control completion mismatch group=%0d flush=%0d abort=%0d",
                   group_done_count, flush_done_count, abort_done_count);
        if (refill_req_stall_cycles < 36 || refill_source_gap_cycles == 0 ||
            tap_rsp_stall_cycles < 4 || tap_input_stall_cycles < 4)
            $fatal(1, "backpressure coverage missing refill_stall=%0d gaps=%0d rsp_stall=%0d tap_stall=%0d",
                   refill_req_stall_cycles, refill_source_gap_cycles,
                   tap_rsp_stall_cycles, tap_input_stall_cycles);
        if (expected_pending || busy || !quiescent)
            $fatal(1, "cache did not reach final quiescent state");
        if (config_valid)
            $fatal(1, "abort did not clear config_valid");
        if (cache_error || cache_error_code != 3'd0)
            $fatal(1, "unexpected sticky cache error code=%0d",
                   cache_error_code);

        $display("C1_WINDOW_LINE_CACHE_C8_PASS responses=%0d refills=%0d refill_words=%0d refill_req_stalls=%0d refill_gaps=%0d rsp_stalls=%0d tap_stalls=%0d group_starts=%0d flushes=%0d aborts=%0d",
                 response_count, refill_count, refill_word_count_seen,
                 refill_req_stall_cycles, refill_source_gap_cycles,
                 tap_rsp_stall_cycles, tap_input_stall_cycles,
                 group_done_count, flush_done_count, abort_done_count);
        if(BANKED) begin
            if(equivalence_cycles<1000) $fatal(1,"cache equivalence coverage missing");
            $display("C1_CACHE_STORAGE_EQUIVALENCE_PASS cycles=%0d",equivalence_cycles);
        end
        $finish;
    end

    initial begin : timeout_watchdog
        repeat (200000) @(posedge clk);
        $fatal(1, "C8 line cache timeout");
    end
endmodule
