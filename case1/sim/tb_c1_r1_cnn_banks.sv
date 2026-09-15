`timescale 1ns/1ps

module tb_c1_r1_cnn_banks;
    localparam integer MAX_DOT_BEATS = 11000;
    localparam integer MAX_DOT_OUTPUTS = 11000;
    localparam integer MAX_BANK_VECTORS = 11000;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg dot_in_valid = 1'b0;
    wire dot_in_ready;
    reg dot_in_first = 1'b0;
    reg dot_in_last = 1'b0;
    reg [7:0] dot_in_mask = 8'd0;
    reg [63:0] dot_in_activations = 64'd0;
    reg [63:0] dot_in_weights = 64'd0;
    reg signed [31:0] dot_in_bias = 32'sd0;
    reg dot_in_sof = 1'b0;
    reg dot_in_eol = 1'b0;
    reg dot_in_eof = 1'b0;
    reg [9:0] dot_in_x = 10'd0;
    reg [8:0] dot_in_y = 9'd0;
    wire dot_out_valid;
    reg dot_out_ready = 1'b0;
    wire signed [31:0] dot_out_acc;
    wire dot_out_sof;
    wire dot_out_eol;
    wire dot_out_eof;
    wire [9:0] dot_out_x;
    wire [8:0] dot_out_y;
    wire dot_acc_overflow;

    reg bank_in_valid = 1'b0;
    wire bank_in_ready;
    reg [255:0] bank_in_acc = 256'd0;
    reg [143:0] bank_in_mult = 144'd0;
    reg [47:0] bank_in_shift = 48'd0;
    reg [15:0] bank_in_activation = 16'd0;
    reg bank_in_sof = 1'b0;
    reg bank_in_eol = 1'b0;
    reg bank_in_eof = 1'b0;
    reg [9:0] bank_in_x = 10'd0;
    reg [8:0] bank_in_y = 9'd0;
    wire bank_out_valid;
    reg bank_out_ready = 1'b0;
    wire [63:0] bank_out_data;
    wire bank_out_sof;
    wire bank_out_eol;
    wire bank_out_eof;
    wire [9:0] bank_out_x;
    wire [8:0] bank_out_y;

    reg probe_in_valid = 1'b0;
    wire probe_in_ready;
    reg [63:0] probe_activations = 64'd0;
    reg [63:0] probe_weights = 64'd0;
    reg signed [31:0] probe_bias = 32'sd0;
    wire probe_out_valid;
    wire probe_overflow;

    reg [201:0] dot_vectors [0:MAX_DOT_BEATS-1];
    reg [31:0] dot_expected_outputs [0:MAX_DOT_OUTPUTS-1];
    reg [527:0] bank_vectors [0:MAX_BANK_VECTORS-1];
    integer dot_beat_count = 0;
    integer dot_sequence_count = 0;
    integer bank_vector_count = 0;
    integer dot_output_count = 0;
    integer bank_output_count = 0;
    integer dot_ready_cycle = 0;
    integer bank_ready_cycle = 0;
    reg dot_driver_done = 1'b0;
    reg bank_driver_done = 1'b0;
    reg overflow_probe_done = 1'b0;

    reg signed [31:0] stalled_dot_acc;
    reg [9:0] stalled_dot_x;
    reg [8:0] stalled_dot_y;
    reg stalled_dot_sof;
    reg stalled_dot_eol;
    reg stalled_dot_eof;
    reg [63:0] stalled_bank_data;
    reg [9:0] stalled_bank_x;
    reg [8:0] stalled_bank_y;
    reg stalled_bank_sof;
    reg stalled_bank_eol;
    reg stalled_bank_eof;

    always #5 clk = ~clk;

    c1_s8_dot8_accum u_dot (
        .clk(clk), .rst(rst), .in_valid(dot_in_valid), .in_ready(dot_in_ready),
        .in_first(dot_in_first), .in_last(dot_in_last),
        .in_lane_mask(dot_in_mask),
        .in_activations_s8(dot_in_activations), .in_weights_s8(dot_in_weights),
        .in_bias_s32(dot_in_bias), .in_sof(dot_in_sof),
        .in_eol(dot_in_eol), .in_eof(dot_in_eof),
        .in_x(dot_in_x), .in_y(dot_in_y),
        .out_valid(dot_out_valid), .out_ready(dot_out_ready),
        .out_acc_s32(dot_out_acc), .out_sof(dot_out_sof),
        .out_eol(dot_out_eol), .out_eof(dot_out_eof),
        .out_x(dot_out_x), .out_y(dot_out_y),
        .acc_overflow(dot_acc_overflow)
    );

    c1_requant_bank8 u_bank (
        .clk(clk), .rst(rst), .in_valid(bank_in_valid), .in_ready(bank_in_ready),
        .in_acc_s32(bank_in_acc), .in_mult_s18(bank_in_mult),
        .in_shift_u6(bank_in_shift), .in_activation(bank_in_activation),
        .in_sof(bank_in_sof), .in_eol(bank_in_eol), .in_eof(bank_in_eof),
        .in_x(bank_in_x), .in_y(bank_in_y),
        .out_valid(bank_out_valid), .out_ready(bank_out_ready),
        .out_data_s8(bank_out_data), .out_sof(bank_out_sof),
        .out_eol(bank_out_eol), .out_eof(bank_out_eof),
        .out_x(bank_out_x), .out_y(bank_out_y)
    );

    // Detector-only instance proves positive/negative overflow recognition
    // without intentionally firing the main instance's simulation assertion.
    c1_s8_dot8_accum #(
        .ASSERT_ON_OVERFLOW(1'b0),
        .ASSERT_PROTOCOL(1'b1)
    ) u_overflow_probe (
        .clk(clk), .rst(rst),
        .in_valid(probe_in_valid), .in_ready(probe_in_ready),
        .in_first(1'b1), .in_last(1'b1), .in_lane_mask(8'hff),
        .in_activations_s8(probe_activations), .in_weights_s8(probe_weights),
        .in_bias_s32(probe_bias), .in_sof(1'b0), .in_eol(1'b0),
        .in_eof(1'b0), .in_x(10'd0), .in_y(9'd0),
        .out_valid(probe_out_valid), .out_ready(1'b1),
        .out_acc_s32(), .out_sof(), .out_eol(), .out_eof(),
        .out_x(), .out_y(), .acc_overflow(probe_overflow)
    );

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("c1_r1_dot8_vectors.txt", "r");
            if (fd == 0) $fatal(1, "cannot open dot8 vectors");
            status = $fscanf(fd, "%d\n", dot_beat_count);
            if (status != 1 || dot_beat_count <= 0 ||
                dot_beat_count > MAX_DOT_BEATS)
                $fatal(1, "invalid dot8 beat count %0d", dot_beat_count);
            dot_sequence_count = 0;
            for (index = 0; index < dot_beat_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", dot_vectors[index]);
                if (status != 1) $fatal(1, "malformed dot8 vector %0d", index);
                if (dot_vectors[index][64]) begin
                    dot_expected_outputs[dot_sequence_count] = dot_vectors[index][31:0];
                    dot_sequence_count = dot_sequence_count + 1;
                end
            end
            $fclose(fd);

            fd = $fopen("c1_r1_requant_bank8_vectors.txt", "r");
            if (fd == 0) $fatal(1, "cannot open requant-bank vectors");
            status = $fscanf(fd, "%d\n", bank_vector_count);
            if (status != 1 || bank_vector_count <= 0 ||
                bank_vector_count > MAX_BANK_VECTORS)
                $fatal(1, "invalid bank vector count %0d", bank_vector_count);
            for (index = 0; index < bank_vector_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", bank_vectors[index]);
                if (status != 1) $fatal(1, "malformed bank vector %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic load_dot_beat;
        input integer beat_index;
        input integer sequence_index;
        reg [201:0] vector;
        begin
            vector = dot_vectors[beat_index];
            dot_in_valid = 1'b1;
            dot_in_activations = vector[201:138];
            dot_in_weights = vector[137:74];
            dot_in_mask = vector[73:66];
            dot_in_first = vector[65];
            dot_in_last = vector[64];
            dot_in_bias = vector[63:32];
            dot_in_sof = vector[64] &&
                         ((sequence_index == 0) || ((sequence_index % 733) == 0));
            dot_in_eol = vector[64] && ((sequence_index % 31) == 30);
            dot_in_eof = vector[64] && (sequence_index == dot_sequence_count - 1);
            dot_in_x = sequence_index % 1024;
            dot_in_y = (sequence_index * 9) % 512;
        end
    endtask

    task automatic drive_dot;
        integer beat_index;
        integer sequence_index;
        begin
            beat_index = 0;
            sequence_index = 0;
            @(negedge clk);
            load_dot_beat(beat_index, sequence_index);
            while (beat_index < dot_beat_count) begin
                @(posedge clk);
                if (dot_in_valid && dot_in_ready) begin
                    if (dot_in_last)
                        sequence_index = sequence_index + 1;
                    beat_index = beat_index + 1;
                    @(negedge clk);
                    if (beat_index == dot_beat_count) begin
                        dot_in_valid = 1'b0;
                        dot_in_first = 1'b0;
                        dot_in_last = 1'b0;
                        dot_in_sof = 1'b0;
                        dot_in_eol = 1'b0;
                        dot_in_eof = 1'b0;
                    end else begin
                        if (((beat_index % 19) == 7) || ((beat_index % 43) == 12)) begin
                            dot_in_valid = 1'b0;
                            dot_in_sof = 1'b0;
                            dot_in_eol = 1'b0;
                            dot_in_eof = 1'b0;
                            @(negedge clk);
                        end
                        load_dot_beat(beat_index, sequence_index);
                    end
                end
            end
            dot_driver_done = 1'b1;
        end
    endtask

    task automatic load_bank_vector;
        input integer index;
        reg [527:0] vector;
        begin
            vector = bank_vectors[index];
            bank_in_valid = 1'b1;
            bank_in_acc = vector[527:272];
            bank_in_mult = vector[271:128];
            bank_in_shift = vector[127:80];
            bank_in_activation = vector[79:64];
            bank_in_sof = (index == 0) || ((index % 887) == 0);
            bank_in_eol = ((index % 37) == 36);
            bank_in_eof = (index == bank_vector_count - 1);
            bank_in_x = (index * 5) % 1024;
            bank_in_y = (index * 13) % 512;
        end
    endtask

    task automatic drive_bank;
        integer index;
        begin
            index = 0;
            @(negedge clk);
            load_bank_vector(index);
            while (index < bank_vector_count) begin
                @(posedge clk);
                if (bank_in_valid && bank_in_ready) begin
                    index = index + 1;
                    @(negedge clk);
                    if (index == bank_vector_count) begin
                        bank_in_valid = 1'b0;
                        bank_in_sof = 1'b0;
                        bank_in_eol = 1'b0;
                        bank_in_eof = 1'b0;
                    end else begin
                        if (((index % 17) == 3) || ((index % 41) == 15)) begin
                            bank_in_valid = 1'b0;
                            bank_in_sof = 1'b0;
                            bank_in_eol = 1'b0;
                            bank_in_eof = 1'b0;
                            @(negedge clk);
                        end
                        load_bank_vector(index);
                    end
                end
            end
            bank_driver_done = 1'b1;
        end
    endtask

    task automatic test_overflow_detector;
        begin
            @(negedge clk);
            if (!probe_in_ready) $fatal(1, "overflow probe not ready");
            probe_activations = {8{8'h7f}};
            probe_weights = {8{8'h7f}};
            probe_bias = 32'sh7fffffff;
            probe_in_valid = 1'b1;
            @(posedge clk);
            #1;
            if (!probe_overflow)
                $fatal(1, "positive accumulator overflow was not detected");

            @(negedge clk);
            probe_activations = {8{8'h80}};
            probe_weights = {8{8'h7f}};
            probe_bias = 32'sh80000000;
            @(posedge clk);
            #1;
            if (!probe_overflow)
                $fatal(1, "negative accumulator overflow was not detected");
            @(negedge clk);
            probe_in_valid = 1'b0;
            overflow_probe_done = 1'b1;
        end
    endtask

    always @(negedge clk) begin
        if (rst) begin
            dot_ready_cycle = 0;
            bank_ready_cycle = 0;
            dot_out_ready = 1'b0;
            bank_out_ready = 1'b0;
        end else begin
            dot_out_ready = !(((dot_ready_cycle % 11) == 4) ||
                              ((dot_ready_cycle % 11) == 5) ||
                              ((dot_ready_cycle % 29) == 17));
            bank_out_ready = !(((bank_ready_cycle % 13) == 2) ||
                               ((bank_ready_cycle % 13) == 3) ||
                               ((bank_ready_cycle % 31) == 19));
            dot_ready_cycle = dot_ready_cycle + 1;
            bank_ready_cycle = bank_ready_cycle + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && dot_acc_overflow)
            $fatal(1, "unexpected accumulator overflow in legal vectors");
    end

    // Check each output in its own process.  The delayed stability check in one
    // channel must not postpone sampling the other channel past its NBA update.
    always @(posedge clk) begin
        if (!rst) begin
            if (!dot_out_valid && (dot_out_sof || dot_out_eol || dot_out_eof))
                $fatal(1, "dot metadata asserted while invalid");
            if (dot_out_valid && dot_out_ready) begin
                if (dot_output_count >= dot_sequence_count)
                    $fatal(1, "unexpected extra dot output");
                if (dot_out_acc !== dot_expected_outputs[dot_output_count])
                    $fatal(1, "dot mismatch output=%0d got=%h expected=%h",
                           dot_output_count, dot_out_acc,
                           dot_expected_outputs[dot_output_count]);
                if (dot_out_x !== (dot_output_count % 1024) ||
                    dot_out_y !== ((dot_output_count * 9) % 512))
                    $fatal(1, "dot metadata coordinate mismatch output=%0d",
                           dot_output_count);
                if (dot_out_sof !== ((dot_output_count == 0) ||
                                     ((dot_output_count % 733) == 0)) ||
                    dot_out_eol !== ((dot_output_count % 31) == 30) ||
                    dot_out_eof !== (dot_output_count == dot_sequence_count - 1))
                    $fatal(1, "dot frame flag mismatch output=%0d", dot_output_count);
                dot_output_count = dot_output_count + 1;
            end
            if (dot_out_valid && !dot_out_ready) begin
                stalled_dot_acc = dot_out_acc;
                stalled_dot_x = dot_out_x;
                stalled_dot_y = dot_out_y;
                stalled_dot_sof = dot_out_sof;
                stalled_dot_eol = dot_out_eol;
                stalled_dot_eof = dot_out_eof;
                #1;
                if (!dot_out_valid || dot_out_acc !== stalled_dot_acc ||
                    dot_out_x !== stalled_dot_x || dot_out_y !== stalled_dot_y ||
                    dot_out_sof !== stalled_dot_sof ||
                    dot_out_eol !== stalled_dot_eol ||
                    dot_out_eof !== stalled_dot_eof)
                    $fatal(1, "dot output payload changed while stalled");
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (!bank_out_valid && (bank_out_sof || bank_out_eol || bank_out_eof))
                $fatal(1, "bank metadata asserted while invalid");
            if (bank_out_valid && bank_out_ready) begin
                if (bank_output_count >= bank_vector_count)
                    $fatal(1, "unexpected extra bank output");
                if (bank_out_data !== bank_vectors[bank_output_count][63:0])
                    $fatal(1, "bank mismatch output=%0d got=%h expected=%h",
                           bank_output_count, bank_out_data,
                           bank_vectors[bank_output_count][63:0]);
                if (bank_out_x !== ((bank_output_count * 5) % 1024) ||
                    bank_out_y !== ((bank_output_count * 13) % 512))
                    $fatal(1, "bank coordinate mismatch output=%0d", bank_output_count);
                if (bank_out_sof !== ((bank_output_count == 0) ||
                                      ((bank_output_count % 887) == 0)) ||
                    bank_out_eol !== ((bank_output_count % 37) == 36) ||
                    bank_out_eof !== (bank_output_count == bank_vector_count - 1))
                    $fatal(1, "bank frame flag mismatch output=%0d", bank_output_count);
                bank_output_count = bank_output_count + 1;
            end
            if (bank_out_valid && !bank_out_ready) begin
                stalled_bank_data = bank_out_data;
                stalled_bank_x = bank_out_x;
                stalled_bank_y = bank_out_y;
                stalled_bank_sof = bank_out_sof;
                stalled_bank_eol = bank_out_eol;
                stalled_bank_eof = bank_out_eof;
                #1;
                if (!bank_out_valid || bank_out_data !== stalled_bank_data ||
                    bank_out_x !== stalled_bank_x || bank_out_y !== stalled_bank_y ||
                    bank_out_sof !== stalled_bank_sof ||
                    bank_out_eol !== stalled_bank_eol ||
                    bank_out_eof !== stalled_bank_eof)
                    $fatal(1, "bank output payload changed while stalled");
            end
        end
    end

    initial begin
        load_vectors();
        repeat (5) @(negedge clk);
        rst = 1'b0;
        fork
            drive_dot();
            drive_bank();
            test_overflow_detector();
        join

        wait (dot_driver_done && bank_driver_done && overflow_probe_done &&
              dot_output_count == dot_sequence_count &&
              bank_output_count == bank_vector_count);
        repeat (8) @(negedge clk);
        if (dot_out_valid || bank_out_valid)
            $fatal(1, "CNN bank outputs did not drain");
        $display("C1_R1_CNN_BANKS_PASS dot_beats=%0d dot_outputs=%0d bank=%0d",
                 dot_beat_count, dot_output_count, bank_output_count);
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "R1 CNN bank test timeout");
    end

endmodule
