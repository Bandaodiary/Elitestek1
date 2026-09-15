`timescale 1ns/1ps

module tb_c1_stream_fifo #(parameter integer DEPTH=5);

    localparam integer DATA_WIDTH = 17;
    // A non-power-of-two depth exercises explicit pointer wrap logic.
    localparam integer LEVEL_WIDTH = $clog2(DEPTH + 1);
    localparam integer TOTAL_ITEMS = 300;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam integer PHASE_FILL      = 0;
    localparam integer PHASE_FULL_SWAP = 1;
    localparam integer PHASE_RANDOM    = 2;
    localparam integer PHASE_DRAIN     = 3;
    localparam integer PHASE_FULL_HOLD = 4;

    logic clk;
    logic rst;
    logic in_valid;
    logic in_ready;
    logic [DATA_WIDTH-1:0] in_data;
    logic out_valid;
    logic out_ready;
    logic [DATA_WIDTH-1:0] out_data;
    logic full;
    logic empty;
    logic [LEVEL_WIDTH-1:0] level;

    integer phase;
    integer push_count;
    integer pop_count;
    integer model_level;
    integer cycle_count;
    logic [31:0] prng_state;
    logic held_input;
    logic [DATA_WIDTH-1:0] held_input_data;
    logic held_output;
    logic [DATA_WIDTH-1:0] held_output_data;
    logic saw_input_stall;
    logic saw_output_stall;
    logic saw_simultaneous;
    logic saw_full_simultaneous;
    logic saw_full;
    logic previous_push_accepted;

    wire push_fire = in_valid && in_ready;
    wire pop_fire = out_valid && out_ready;

    c1_stream_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk,
        .rst,
        .in_valid,
        .in_ready,
        .in_data,
        .out_valid,
        .out_ready,
        .out_data,
        .full,
        .empty,
        .level
    );

    function automatic [DATA_WIDTH-1:0] item_value(input integer index);
        reg [31:0] mixed;
        begin
            mixed = (index * 32'h0001_9e37) ^ (index << 7) ^ 32'h0001_2b4d;
            item_value = mixed[DATA_WIDTH-1:0];
        end
    endfunction

    function automatic [31:0] prng_next(input [31:0] state);
        reg feedback;
        begin
            // x^32 + x^22 + x^2 + x + 1, fixed non-zero seed below.
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("FIFO_TB_FAIL cycle=%0d push=%0d pop=%0d level=%0d: %s",
                     cycle_count, push_count, pop_count, model_level, message);
            $fatal(1);
            $finish;
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        in_valid = 1'b0;
        in_data = '0;
        out_ready = 1'b0;
        phase = PHASE_FILL;
        prng_state = 32'h6d2b_79f5;
        repeat (5) @(posedge clk);
        #1 rst = 1'b0;
    end

    // Source and sink controls change only on the falling edge.  A source word
    // is explicitly held whenever valid is asserted without a handshake.
    always @(negedge clk) begin
        if (rst) begin
            in_valid <= 1'b0;
            in_data <= '0;
            out_ready <= 1'b0;
            phase <= PHASE_FILL;
            prng_state <= 32'h6d2b_79f5;
        end else begin
            prng_state <= prng_next(prng_state);

            case (phase)
                PHASE_FILL: begin
                    out_ready <= 1'b0;
                    if (push_count < DEPTH) begin
                        if (!(in_valid && !previous_push_accepted)) begin
                            in_valid <= 1'b1;
                            in_data <= item_value(push_count);
                        end
                    end else begin
                        // Force one blocked write before replacement, even
                        // when a large FIFO never refills in the random phase.
                        phase <= PHASE_FULL_HOLD;
                        in_valid <= 1'b1;
                        in_data <= item_value(push_count);
                        out_ready <= 1'b0;
                    end
                end

                PHASE_FULL_HOLD: begin
                    phase <= PHASE_FULL_SWAP;
                    out_ready <= 1'b1;
                end

                PHASE_FULL_SWAP: begin
                    phase <= PHASE_RANDOM;
                    in_valid <= 1'b0;
                    out_ready <= 1'b0;
                end

                PHASE_RANDOM: begin
                    out_ready <= prng_state[5] | prng_state[9];
                    if (push_count >= TOTAL_ITEMS) begin
                        phase <= PHASE_DRAIN;
                        in_valid <= 1'b0;
                        out_ready <= 1'b1;
                    end else if (in_valid && !previous_push_accepted) begin
                        in_valid <= in_valid;
                        in_data <= in_data;
                    end else if (prng_state[2] | prng_state[7]) begin
                        in_valid <= 1'b1;
                        in_data <= item_value(push_count);
                    end else begin
                        in_valid <= 1'b0;
                    end
                end

                default: begin
                    in_valid <= 1'b0;
                    out_ready <= 1'b1;
                end
            endcase
        end
    end

    // Scoreboard samples the pre-edge ready/valid state, matching synchronous
    // transfer semantics. Blocking assignments are intentional in testbench
    // bookkeeping so the model occupancy reflects both transfers immediately.
    always @(posedge clk) begin
        if (rst) begin
            push_count = 0;
            pop_count = 0;
            model_level = 0;
            cycle_count = 0;
            held_input = 1'b0;
            held_input_data = '0;
            held_output = 1'b0;
            held_output_data = '0;
            saw_input_stall = 1'b0;
            saw_output_stall = 1'b0;
            saw_simultaneous = 1'b0;
            saw_full_simultaneous = 1'b0;
            saw_full = 1'b0;
            previous_push_accepted = 1'b0;
        end else begin
            cycle_count = cycle_count + 1;
            if (cycle_count > TIMEOUT_CYCLES)
                fail("timeout");

            if (level !== model_level)
                fail("level disagrees with scoreboard");
            if (empty !== (model_level == 0))
                fail("empty flag disagrees with level");
            if (full !== (model_level == DEPTH))
                fail("full flag disagrees with level");
            if (out_valid !== (model_level != 0))
                fail("out_valid disagrees with occupancy");
            if (in_ready !== (!full || (out_valid && out_ready)))
                fail("in_ready does not implement elastic full replacement");

            if (held_input && (!in_valid || (in_data !== held_input_data)))
                fail("source input changed while stalled");
            if (held_output && (!out_valid || (out_data !== held_output_data)))
                fail("FIFO output changed while stalled");

            if (push_fire) begin
                if (push_count >= TOTAL_ITEMS)
                    fail("accepted more input words than requested");
                if (in_data !== item_value(push_count))
                    fail("accepted source word has unexpected value");
                push_count = push_count + 1;
            end

            if (pop_fire) begin
                if (pop_count >= push_count)
                    fail("output duplicated or appeared before input");
                if (out_data !== item_value(pop_count))
                    fail("output order/data mismatch");
                pop_count = pop_count + 1;
            end

            case ({push_fire, pop_fire})
                2'b10: model_level = model_level + 1;
                2'b01: model_level = model_level - 1;
                default: model_level = model_level;
            endcase
            if ((model_level < 0) || (model_level > DEPTH))
                fail("scoreboard occupancy outside FIFO bounds");

            if (in_valid && !in_ready)
                saw_input_stall = 1'b1;
            if (out_valid && !out_ready)
                saw_output_stall = 1'b1;
            if (push_fire && pop_fire)
                saw_simultaneous = 1'b1;
            if (full)
                saw_full = 1'b1;
            if (full && push_fire && pop_fire)
                saw_full_simultaneous = 1'b1;

            held_input = in_valid && !in_ready;
            held_input_data = in_data;
            held_output = out_valid && !out_ready;
            held_output_data = out_data;
            previous_push_accepted = push_fire;
        end
    end

    initial begin
        wait (!rst);
        wait (pop_count == TOTAL_ITEMS);
        @(negedge clk);
        if (!empty || full || (level != 0) || out_valid)
            fail("FIFO did not return to empty after drain");
        if (push_count != TOTAL_ITEMS)
            fail("not all source words were accepted");
        if (!saw_input_stall || !saw_output_stall || !saw_simultaneous ||
            !saw_full || !saw_full_simultaneous)
            fail("required stall/full/simultaneous coverage was not observed");
        $display("FIFO_RANDOM_STALL_PASS items=%0d cycles=%0d depth=%0d",
                 TOTAL_ITEMS, cycle_count, DEPTH);
        $finish;
    end

endmodule
