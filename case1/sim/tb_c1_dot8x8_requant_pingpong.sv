`timescale 1ns/1ps

// Boardless inter-pixel overlap smoke.  Six one-group transactions are sent
// back-to-back.  The test checks that the second transaction can be launched
// before the first result retires, while the output tag FIFO still preserves
// transaction order under periodic output backpressure.
module tb_c1_dot8x8_requant_pingpong;
`ifdef C1_PINGPONG_BANKS4_TB
    localparam integer BANKS = 4;
`else
    localparam integer BANKS = 2;
`endif
`ifdef C1_PINGPONG_TAG_POP_PUSH_TB
    // Deliberately fill the ordered tag FIFO.  This exposes the optional
    // full pop+push admission path; the normal smoke keeps the historical
    // over-provisioned depth.
    localparam integer NTRANS = BANKS * 4;
    localparam integer TAG_FIFO_DEPTH = BANKS;
    localparam bit TAG_POP_PUSH_MODE = 1'b1;
`else
`ifdef C1_PINGPONG_BANKS4_TB
    localparam integer NTRANS = 12;
    localparam integer TAG_FIFO_DEPTH = 16;
`else
    localparam integer NTRANS = 6;
    localparam integer TAG_FIFO_DEPTH = 8;
`endif
    localparam bit TAG_POP_PUSH_MODE = 1'b0;
`endif
`ifdef C1_PINGPONG_FIRST_BEAT_TB
    localparam bit FIRST_BEAT_MODE = 1'b1;
`else
    localparam bit FIRST_BEAT_MODE = 1'b0;
`endif
`ifdef C1_PINGPONG_OUTPUT_RESTART_TB
    localparam bit OUTPUT_RESTART_MODE = 1'b1;
`else
    localparam bit OUTPUT_RESTART_MODE = 1'b0;
`endif
    localparam integer LANES = 2;
    localparam integer X_BITS = 8;
    localparam integer Y_BITS = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [LANES*256-1:0] start_bias_s32 = '0;
    logic [LANES*144-1:0] start_mult_s18 = '0;
    logic [LANES*48-1:0] start_shift_u6 = '0;
    logic [LANES-1:0] start_relu = '0;
    logic [LANES-1:0] start_sof = '0;
    logic [LANES-1:0] start_eol = '0;
    logic [LANES-1:0] start_eof = '0;
    logic [LANES*X_BITS-1:0] start_x = '0;
    logic [LANES*Y_BITS-1:0] start_y = '0;
    logic in_valid = 1'b0;
    logic in_ready;
    logic in_last = 1'b0;
    logic [7:0] in_lane_mask = 8'hff;
    logic [63:0] in_activations_s8 = '0;
    logic [LANES*512-1:0] in_weights_s8 = '0;
    logic out_valid;
    logic out_ready;
    logic [LANES*64-1:0] out_data_s8;
    logic [LANES-1:0] out_sof, out_eol, out_eof;
    logic [LANES*X_BITS-1:0] out_x;
    logic [LANES*Y_BITS-1:0] out_y;
    logic busy;
    logic [LANES-1:0] overflow_seen;

    c1_dot8x8_requant_pingpong #(
        .BANKS(BANKS), .LANES(LANES), .X_BITS(X_BITS), .Y_BITS(Y_BITS),
         .PIPELINED_DOT_TREE(1), .PIPELINED_DOT_TREE_FULL(1),
         .TAG_FIFO_DEPTH(TAG_FIFO_DEPTH),
         .ACCEPT_FIRST_BEAT_ON_START(FIRST_BEAT_MODE),
         .ALLOW_OUTPUT_RESTART(OUTPUT_RESTART_MODE),
         .ALLOW_TAG_POP_PUSH(TAG_POP_PUSH_MODE)
    ) dut (
        .clk, .rst,
        .start_valid, .start_ready,
        .start_bias_s32, .start_mult_s18, .start_shift_u6,
        .start_relu, .start_sof, .start_eol, .start_eof, .start_x, .start_y,
        .in_valid, .in_ready, .in_last, .in_lane_mask,
        .in_activations_s8, .in_weights_s8,
        .out_valid, .out_ready, .out_data_s8,
        .out_sof, .out_eol, .out_eof, .out_x, .out_y,
        .busy, .overflow_seen
    );

    integer cycle_count = 0;
    integer started = 0;
    integer produced = 0;
    integer inflight = 0;
    integer max_inflight = 0;
    integer simultaneous_first_beats = 0;
    integer same_bank_restarts = 0;
    integer full_tag_pop_push = 0;
    integer start_cycle [0:NTRANS-1];
    integer out_cycle [0:NTRANS-1];
    integer expected_lane0 [0:NTRANS-1];
    integer expected_lane1 [0:NTRANS-1];
    integer expected_x [0:NTRANS-1];
    integer expected_y [0:NTRANS-1];
    integer i;

    function automatic integer sat_s8(input integer value);
        begin
            if (value > 127)
                sat_s8 = 127;
            else if (value < -128)
                sat_s8 = -128;
            else
                sat_s8 = value;
        end
    endfunction

    always_comb begin
        // Deliberate, deterministic output stalls exercise the ordered tag
        // FIFO without holding the whole test indefinitely.
        out_ready = (cycle_count % 7) != 3;
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            started <= 0;
            produced <= 0;
            inflight <= 0;
            max_inflight <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (start_valid && start_ready) begin
                if (started >= NTRANS)
                    $fatal(1, "too many starts");
                start_cycle[started] = cycle_count;
                started = started + 1;
                inflight = inflight + 1;
                if (inflight > max_inflight)
                    max_inflight = inflight;
            end
            if (start_valid && start_ready && in_valid && in_ready)
                simultaneous_first_beats = simultaneous_first_beats + 1;
            // A same-bank restart is the useful MAC throughput event: the
            // retiring result and the next START are accepted on one edge.
            if (start_valid && start_ready && out_valid && out_ready &&
                dut.tag_valid && (dut.selected_bank == dut.tag_head_bank))
                same_bank_restarts = same_bank_restarts + 1;
            if (start_valid && start_ready && out_valid && out_ready &&
                (dut.tag_count_q == TAG_FIFO_DEPTH))
                full_tag_pop_push = full_tag_pop_push + 1;
            if (out_valid && out_ready) begin
                if (produced >= NTRANS)
                    $fatal(1, "too many outputs");
                if (out_data_s8[7:0] !== expected_lane0[produced][7:0] ||
                    out_data_s8[LANES*64/2 +: 8] !== expected_lane1[produced][7:0])
                    $fatal(1, "ordered data mismatch idx=%0d got=%h exp=%0d/%0d",
                           produced, out_data_s8,
                           expected_lane0[produced], expected_lane1[produced]);
                if (out_x[0 +: X_BITS] !== expected_x[produced][X_BITS-1:0] ||
                    out_y[0 +: Y_BITS] !== expected_y[produced][Y_BITS-1:0])
                    $fatal(1, "metadata/order mismatch idx=%0d x/y=%0d/%0d",
                           produced, out_x[0 +: X_BITS], out_y[0 +: Y_BITS]);
                out_cycle[produced] = cycle_count;
                produced = produced + 1;
                inflight = inflight - 1;
            end
        end
    end

    task automatic send_transaction(input integer id);
        integer ch;
        begin
            // Requant output is signed-8 saturated; clamp the expected
            // integers so the 4-bank/full-FIFO stress can use >15 IDs.
            expected_lane0[id] = sat_s8(8 * (2 + id));
            expected_lane1[id] = sat_s8(8 * (3 + id));
            expected_x[id] = 16 + id;
            expected_y[id] = 32 + id;
            start_bias_s32 = '0;
            start_mult_s18 = '0;
            start_shift_u6 = '0;
            start_relu = '0;
            start_sof = {LANES{1'b1}};
            start_eol = {LANES{1'b1}};
            start_eof = {LANES{1'b1}};
            start_x = '0;
            start_y = '0;
            in_weights_s8 = '0;
            in_activations_s8 = {8{8'sd1}};
            for (ch = 0; ch < 8; ch = ch + 1) begin
                start_mult_s18[ch*18 +: 18] = 18'sd1;
                start_mult_s18[LANES*144/2 + ch*18 +: 18] = 18'sd1;
                in_weights_s8[ch*8 +: 8] = 8'(2 + id);
                in_weights_s8[512 + ch*8 +: 8] = 8'(3 + id);
            end
            start_x[0 +: X_BITS] = expected_x[id][X_BITS-1:0];
            start_x[X_BITS +: X_BITS] = expected_x[id][X_BITS-1:0];
            start_y[0 +: Y_BITS] = expected_y[id][Y_BITS-1:0];
            start_y[Y_BITS +: Y_BITS] = expected_y[id][Y_BITS-1:0];

            if (FIRST_BEAT_MODE) begin
                // Optional one-entry skid accepts the first beat in the
                // same cycle as START.  The beat is held internally while
                // the selected bank enters its input-ready state.
                @(negedge clk);
                start_valid = 1'b1;
                in_last = 1'b1;
                in_valid = 1'b1;
                do @(posedge clk); while (!(start_ready && in_ready));
                @(negedge clk);
                start_valid = 1'b0;
                in_valid = 1'b0;
                in_last = 1'b0;
            end else begin
                @(negedge clk);
                start_valid = 1'b1;
                do @(posedge clk); while (!start_ready);
                @(negedge clk);
                start_valid = 1'b0;
                in_last = 1'b1;
                in_valid = 1'b1;
                do @(posedge clk); while (!in_ready);
                @(negedge clk);
                in_valid = 1'b0;
                in_last = 1'b0;
            end
        end
    endtask

    initial begin
        repeat (6) @(posedge clk);
        rst = 1'b0;
        for (i = 0; i < NTRANS; i = i + 1)
            send_transaction(i);

        while ((produced < NTRANS || busy) && cycle_count < 100000)
            @(posedge clk);
        if (cycle_count >= 100000)
            $fatal(1, "pingpong timeout");
        if (started != NTRANS || produced != NTRANS)
            $fatal(1, "transaction count mismatch started=%0d produced=%0d",
                   started, produced);
        if (max_inflight < BANKS)
            $fatal(1, "insufficient bank overlap observed banks=%0d max_inflight=%0d",
                   BANKS, max_inflight);
        if (start_cycle[1] >= out_cycle[0])
            $fatal(1, "second transaction did not overlap first: start1=%0d out0=%0d",
                   start_cycle[1], out_cycle[0]);
        if (|overflow_seen)
            $fatal(1, "unexpected accumulator overflow");
        if (FIRST_BEAT_MODE && (simultaneous_first_beats != NTRANS))
            $fatal(1, "first-beat skid did not accept all START+IN pairs got=%0d",
                   simultaneous_first_beats);
        if (!FIRST_BEAT_MODE && (simultaneous_first_beats != 0))
            $fatal(1, "default mode unexpectedly accepted START+IN pairs");
        if (OUTPUT_RESTART_MODE && (same_bank_restarts == 0))
            $fatal(1, "output restart mode did not observe a same-bank restart");
        if (!OUTPUT_RESTART_MODE && (same_bank_restarts != 0))
            $fatal(1, "default mode unexpectedly observed same-bank restart");
        if (TAG_POP_PUSH_MODE && OUTPUT_RESTART_MODE &&
            (full_tag_pop_push == 0))
            $fatal(1, "tag pop+push mode did not observe a full-FIFO replacement");
        $display("C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=%0d output_restart=%0d tag_pop_push=%0d banks=%0d lanes=%0d transactions=%0d max_inflight=%0d same_bank_restart=%0d full_tag_pop_push=%0d first_overlap=%0d cycles=%0d",
                 FIRST_BEAT_MODE,
                 OUTPUT_RESTART_MODE, TAG_POP_PUSH_MODE, BANKS, LANES, NTRANS, max_inflight,
                 same_bank_restarts,
                 full_tag_pop_push,
                 (out_cycle[0] - start_cycle[1]), cycle_count);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "pingpong smoke timeout started=%0d produced=%0d active=%0d pending=%0d tags=%0d banks_busy=%b",
               started, produced, dut.input_active_q,
               dut.first_beat_pending_q, dut.tag_count_q, dut.bank_busy);
    end
endmodule
