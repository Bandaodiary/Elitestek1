`timescale 1ns/1ps

module tb_c1_r1_compute_ingress #(
    parameter logic [31:0] SEED=32'h2b79f5a3,
    parameter integer REGISTER_ABORT_RESET=0);

    localparam integer MAX_WIDTH = 16;
    localparam integer MAX_CONFIGS = 16;
    localparam integer MAX_SOURCE = 1024;
    localparam integer MAX_OUTPUTS = 2048;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic cfg_valid = 1'b0;
    wire cfg_ready;
    wire cfg_error;
    logic [15:0] cfg_win = '0;
    logic [15:0] cfg_hin = '0;
    logic [15:0] cfg_wout = '0;
    logic [15:0] cfg_hout = '0;
    logic signed [31:0] cfg_x_step_q16 = '0;
    logic signed [31:0] cfg_y_step_q16 = '0;
    logic signed [31:0] cfg_x_phase0_q16 = '0;
    logic signed [31:0] cfg_y_phase0_q16 = '0;

    logic abort = 1'b0;
    wire aborted;
    wire busy;
    wire done;
    wire error;
    wire [3:0] error_code;

    logic manual_source_mode = 1'b1;
    logic manual_in_valid = 1'b0;
    logic [15:0] manual_in_x = '0;
    logic [15:0] manual_in_y = '0;
    logic manual_in_sof = 1'b0;
    logic manual_in_eol = 1'b0;
    logic manual_in_eof = 1'b0;
    logic [23:0] manual_in_rgb = '0;

    logic auto_in_valid = 1'b0;
    logic auto_source_enable = 1'b0;
    integer auto_source_index = 0;
    integer auto_source_end = 0;
    logic [15:0] auto_in_x = '0;
    logic [15:0] auto_in_y = '0;
    logic [15:0] source_width_q = '0;
    logic [15:0] source_height_q = '0;

    wire in_valid;
    wire in_ready;
    wire [15:0] in_x;
    wire [15:0] in_y;
    wire in_sof;
    wire in_eol;
    wire in_eof;
    wire [23:0] in_rgb888;

    wire out_valid;
    wire out_ready;
    wire [63:0] out_c8;
    wire out_sof;
    wire out_eol;
    wire out_eof;
    wire [15:0] out_x;
    wire [15:0] out_y;
    logic random_out_ready = 1'b0;
    logic force_output_block = 1'b0;

    logic [23:0] source_mem [0:MAX_SOURCE-1];
    logic [58:0] expected_mem [0:MAX_OUTPUTS-1];
    logic [15:0] config_win [0:MAX_CONFIGS-1];
    logic [15:0] config_hin [0:MAX_CONFIGS-1];
    logic [15:0] config_wout [0:MAX_CONFIGS-1];
    logic [15:0] config_hout [0:MAX_CONFIGS-1];
    logic signed [31:0] config_x_step [0:MAX_CONFIGS-1];
    logic signed [31:0] config_y_step [0:MAX_CONFIGS-1];
    logic signed [31:0] config_x_phase0 [0:MAX_CONFIGS-1];
    logic signed [31:0] config_y_phase0 [0:MAX_CONFIGS-1];
    integer config_source_start [0:MAX_CONFIGS-1];
    integer config_source_count [0:MAX_CONFIGS-1];
    integer config_output_start [0:MAX_CONFIGS-1];
    integer config_output_count [0:MAX_CONFIGS-1];
    integer config_count;
    integer source_count;
    integer output_count;

    logic compare_enable = 1'b0;
    integer expected_index = 0;
    integer expected_end = 0;
    integer compared_outputs = 0;
    integer current_output_handshakes = 0;
    integer accepted_source_job = 0;
    integer completed_jobs = 0;
    integer cfg_error_count = 0;
    integer runtime_error_count = 0;
    integer abort_count = 0;
    integer final_hold_checks = 0;
    integer source_gap_cycles = 0;
    integer source_stall_cycles = 0;
    integer output_stall_cycles = 0;
    logic [31:0] lfsr = SEED;
    integer cycle_count = 0;

    logic [58:0] stalled_input;
    logic [98:0] stalled_output;

    c1_rv_hold_checker #(.WIDTH(59),.CHANNEL(0)) u_input_hold (
        .clk(clk),.rst(rst),.cancel(abort),.valid(in_valid),.ready(in_ready),
        .payload({in_eof,in_eol,in_sof,in_y,in_x,in_rgb888})
    );
    c1_rv_hold_checker #(.WIDTH(99),.CHANNEL(1)) u_output_hold (
        .clk(clk),.rst(rst),.cancel(abort || error),.valid(out_valid),.ready(out_ready),
        .payload({out_eof,out_eol,out_sof,out_y,out_x,out_c8})
    );

    always #5 clk = ~clk;

    assign in_valid = manual_source_mode ? manual_in_valid : auto_in_valid;
    assign in_x = manual_source_mode ? manual_in_x : auto_in_x;
    assign in_y = manual_source_mode ? manual_in_y : auto_in_y;
    assign in_sof = manual_source_mode ? manual_in_sof :
                    ((auto_in_x == 0) && (auto_in_y == 0));
    assign in_eol = manual_source_mode ? manual_in_eol :
                    (auto_in_x == source_width_q - 16'd1);
    assign in_eof = manual_source_mode ? manual_in_eof :
                    ((auto_in_x == source_width_q - 16'd1) &&
                     (auto_in_y == source_height_q - 16'd1));
    assign in_rgb888 = manual_source_mode ? manual_in_rgb :
                       source_mem[auto_source_index];
    assign out_ready = !force_output_block && random_out_ready;

    c1_r1_compute_ingress #(
        .MAX_WIDTH(MAX_WIDTH), .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET)
    ) dut (
        .clk,
        .rst,
        .cfg_valid,
        .cfg_ready,
        .cfg_error,
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .abort,
        .aborted,
        .busy,
        .done,
        .error,
        .error_code,
        .in_valid,
        .in_ready,
        .in_x,
        .in_y,
        .in_sof,
        .in_eol,
        .in_eof,
        .in_rgb888,
        .out_valid,
        .out_ready,
        .out_c8,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y
    );

    function automatic logic [63:0] expected_c8(input logic [23:0] rgb);
        begin
            expected_c8 = {40'd0,
                           rgb[7:0] ^ 8'h80,
                           rgb[15:8] ^ 8'h80,
                           rgb[23:16] ^ 8'h80};
        end
    endfunction

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("r1_resize_line_sampler_source.txt", "r");
            if (fd == 0) $fatal(1, "cannot open ingress source vectors");
            status = $fscanf(fd, "%d\n", source_count);
            if (status != 1 || source_count <= 0 || source_count > MAX_SOURCE)
                $fatal(1, "invalid ingress source count");
            for (index = 0; index < source_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", source_mem[index]);
                if (status != 1) $fatal(1, "malformed ingress source %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_configs.txt", "r");
            if (fd == 0) $fatal(1, "cannot open ingress configs");
            status = $fscanf(fd, "%d\n", config_count);
            if (status != 1 || config_count <= 0 || config_count > MAX_CONFIGS)
                $fatal(1, "invalid ingress config count");
            for (index = 0; index < config_count; index = index + 1) begin
                status = $fscanf(fd,
                    "%h %h %h %h %h %h %h %h %d %d %d %d\n",
                    config_win[index], config_hin[index],
                    config_wout[index], config_hout[index],
                    config_x_step[index], config_y_step[index],
                    config_x_phase0[index], config_y_phase0[index],
                    config_source_start[index], config_source_count[index],
                    config_output_start[index], config_output_count[index]);
                if (status != 12)
                    $fatal(1, "malformed ingress config %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_expected.txt", "r");
            if (fd == 0) $fatal(1, "cannot open ingress expected vectors");
            status = $fscanf(fd, "%d\n", output_count);
            if (status != 1 || output_count <= 0 || output_count > MAX_OUTPUTS)
                $fatal(1, "invalid ingress output count");
            for (index = 0; index < output_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", expected_mem[index]);
                if (status != 1) $fatal(1, "malformed ingress output %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic set_config(input integer index);
        begin
            cfg_win = config_win[index];
            cfg_hin = config_hin[index];
            cfg_wout = config_wout[index];
            cfg_hout = config_hout[index];
            cfg_x_step_q16 = config_x_step[index];
            cfg_y_step_q16 = config_y_step[index];
            cfg_x_phase0_q16 = config_x_phase0[index];
            cfg_y_phase0_q16 = config_y_phase0[index];
        end
    endtask

    task automatic transact_config(input logic expected_error);
        logic sampled_ready;
        begin
            while (!cfg_ready) @(negedge clk);
            @(negedge clk);
            cfg_valid = 1'b1;
            @(posedge clk);
            sampled_ready = cfg_ready;
            #1;
            if (!sampled_ready || cfg_error !== expected_error)
                $fatal(1, "compute ingress configuration response mismatch");
            if (expected_error) begin
                if (!error || busy)
                    $fatal(1, "invalid ingress config status mismatch");
            end else if (error || !busy) begin
                $fatal(1, "valid ingress config did not start");
            end
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task automatic prepare_source(input integer index);
        begin
            source_width_q = config_win[index];
            source_height_q = config_hin[index];
            auto_source_index = config_source_start[index];
            auto_source_end = config_source_start[index] +
                              config_source_count[index];
            auto_in_x = 16'd0;
            auto_in_y = 16'd0;
            auto_in_valid = 1'b0;
            auto_source_enable = 1'b1;
            accepted_source_job = 0;
        end
    endtask

    task automatic abort_job;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(posedge clk);
            #1;
            if (!aborted || busy || done || error || in_ready || out_valid)
                $fatal(1, "compute ingress abort status mismatch");
            abort_count = abort_count + 1;
            @(negedge clk);
            auto_source_enable = 1'b0;
            auto_in_valid = 1'b0;
            manual_in_valid = 1'b0;
            abort = 1'b0;
            force_output_block = 1'b0;
            @(posedge clk);
            #1;
            if (!cfg_ready || aborted)
                $fatal(1, "compute ingress was not restartable after abort");
        end
    endtask

    task automatic run_checked_job(
        input integer index,
        input logic hold_final
    );
        integer prior_completed;
        integer hold_cycle;
        begin
            manual_source_mode = 1'b0;
            set_config(index);
            prepare_source(index);
            compare_enable = 1'b1;
            expected_index = config_output_start[index];
            expected_end = config_output_start[index] +
                           config_output_count[index];
            current_output_handshakes = 0;
            prior_completed = completed_jobs;
            force_output_block = hold_final;
            transact_config(1'b0);

            if (hold_final) begin
                while (!out_valid || !out_eof) @(negedge clk);
                for (hold_cycle = 0; hold_cycle < 8;
                     hold_cycle = hold_cycle + 1) begin
                    @(posedge clk);
                    #1;
                    if (!busy || done || cfg_ready || !out_valid || !out_eof)
                        $fatal(1,
                            "ingress completed before final C8 consumption");
                    final_hold_checks = final_hold_checks + 1;
                end
                @(negedge clk);
                force_output_block = 1'b0;
            end

            while (completed_jobs == prior_completed) begin
                if (error)
                    $fatal(1, "compute ingress runtime error job=%0d code=%0d",
                           index, error_code);
                @(negedge clk);
            end
            if (busy || auto_source_enable || auto_in_valid)
                $fatal(1, "compute ingress did not drain job=%0d", index);
            if (expected_index != expected_end)
                $fatal(1, "compute ingress output count mismatch job=%0d",
                       index);
            if (accepted_source_job != config_source_count[index])
                $fatal(1, "compute ingress source count mismatch job=%0d",
                       index);
            compare_enable = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (rst) begin
            lfsr = SEED;
            random_out_ready = 1'b0;
            cycle_count = 0;
        end else begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            random_out_ready = (lfsr[3:1] != 3'b000) &&
                               ((cycle_count % 71) < 53);
            cycle_count = cycle_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst || manual_source_mode || !auto_source_enable) begin
            auto_in_valid <= 1'b0;
        end else if (auto_in_valid) begin
            if (in_ready) begin
                accepted_source_job = accepted_source_job + 1;
                if (auto_source_index + 1 >= auto_source_end) begin
                    auto_in_valid <= 1'b0;
                    auto_source_enable <= 1'b0;
                end else begin
                    auto_source_index <= auto_source_index + 1;
                    if (auto_in_x == source_width_q - 16'd1) begin
                        auto_in_x <= 16'd0;
                        auto_in_y <= auto_in_y + 16'd1;
                    end else begin
                        auto_in_x <= auto_in_x + 16'd1;
                    end
                    auto_in_valid <= lfsr[8] || lfsr[12];
                end
            end
        end else if (auto_source_index < auto_source_end &&
                     (lfsr[9] || lfsr[14])) begin
            auto_in_valid <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (cfg_error)
                cfg_error_count = cfg_error_count + 1;
            if (!manual_source_mode && auto_source_enable && !auto_in_valid)
                source_gap_cycles = source_gap_cycles + 1;
            if (in_valid && !in_ready)
                source_stall_cycles = source_stall_cycles + 1;
            if (out_valid && !out_ready)
                output_stall_cycles = output_stall_cycles + 1;
            if (done)
                completed_jobs = completed_jobs + 1;

            if (out_valid && out_ready) begin
                current_output_handshakes = current_output_handshakes + 1;
                if (out_c8[63:24] != 40'd0)
                    $fatal(1, "NHWC-C8 padding lanes are not zero");
                if (compare_enable) begin
                    if (expected_index >= expected_end)
                        $fatal(1, "unexpected extra ingress output");
                    if (out_c8 !==
                        expected_c8(expected_mem[expected_index][23:0]))
                        $fatal(1,
                            "C8 data mismatch index=%0d got=%h expected=%h",
                            expected_index, out_c8,
                            expected_c8(expected_mem[expected_index][23:0]));
                    if (out_x !== expected_mem[expected_index][39:24] ||
                        out_y !== expected_mem[expected_index][55:40])
                        $fatal(1, "C8 coordinate mismatch index=%0d",
                               expected_index);
                    if (out_sof !== expected_mem[expected_index][56] ||
                        out_eol !== expected_mem[expected_index][57] ||
                        out_eof !== expected_mem[expected_index][58])
                        $fatal(1, "C8 marker mismatch index=%0d",
                               expected_index);
                    expected_index = expected_index + 1;
                    compared_outputs = compared_outputs + 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && in_valid && !in_ready) begin
            stalled_input = {in_eof, in_eol, in_sof, in_y, in_x, in_rgb888};
            #1;
            if (!in_valid ||
                {in_eof, in_eol, in_sof,
                 in_y, in_x, in_rgb888} !== stalled_input)
                $fatal(1, "compute ingress input changed while stalled");
        end
    end

    always @(posedge clk) begin
        if (!rst && out_valid && !out_ready) begin
            stalled_output = {out_eof, out_eol, out_sof,
                              out_y, out_x, out_c8};
            #1;
            if (!out_valid ||
                {out_eof, out_eol, out_sof,
                 out_y, out_x, out_c8} !== stalled_output)
                $fatal(1, "compute ingress output changed while stalled");
        end
    end

    integer job;
    initial begin
        load_vectors();
        repeat (6) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // Invalid configuration is rejected without starting an ingress job.
        cfg_win = 16'd0;
        cfg_hin = 16'd2;
        cfg_wout = 16'd2;
        cfg_hout = 16'd2;
        cfg_x_step_q16 = 32'sd65536;
        cfg_y_step_q16 = 32'sd65536;
        cfg_x_phase0_q16 = 32'sd0;
        cfg_y_phase0_q16 = 32'sd0;
        transact_config(1'b1);
        if (error_code != 4'd1)
            $fatal(1, "ingress invalid-config error code mismatch");

        // Runtime strict-raster violation freezes the ingress until abort.
        set_config(1);
        manual_source_mode = 1'b1;
        transact_config(1'b0);
        while (!in_ready) @(negedge clk);
        @(negedge clk);
        manual_in_valid = 1'b1;
        manual_in_x = 16'd1;
        manual_in_y = 16'd0;
        manual_in_sof = 1'b1;
        manual_in_eol = 1'b0;
        manual_in_eof = 1'b0;
        manual_in_rgb = 24'h123456;
        @(posedge clk);
        #1;
        @(negedge clk);
        manual_in_valid = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!error || error_code != 4'd2 || !busy || in_ready || out_valid)
            $fatal(1, "ingress did not propagate strict-raster error");
        runtime_error_count = runtime_error_count + 1;
        abort_job();

        // Abort while a C8 output beat is explicitly held.  No stale codec
        // beat may survive into the subsequent restart.
        manual_source_mode = 1'b0;
        set_config(4);
        prepare_source(4);
        compare_enable = 1'b0;
        current_output_handshakes = 0;
        transact_config(1'b0);
        while (current_output_handshakes < 2) @(negedge clk);
        force_output_block = 1'b1;
        while (!out_valid) @(negedge clk);
        if (!busy)
            $fatal(1, "ingress lost busy before pending-beat abort");
        abort_job();

        // Scalar, identity, integer and non-integer resize cases.  The scalar
        // case holds its sole/final C8 beat to prove done cannot follow the
        // earlier RGB-domain completion.
        for (job = 0; job < config_count; job = job + 1)
            run_checked_job(job, job == 0);

        repeat (10) @(posedge clk);
        if (compared_outputs != output_count ||
            completed_jobs != config_count)
            $fatal(1, "compute ingress final output/done count mismatch");
        if (cfg_error_count != 1 || runtime_error_count != 1)
            $fatal(1, "compute ingress error coverage mismatch");
        if (abort_count != 2 || final_hold_checks != 8)
            $fatal(1, "compute ingress abort/final-hold coverage mismatch");
        if (source_gap_cycles == 0 || source_stall_cycles == 0 ||
            output_stall_cycles == 0)
            $fatal(1,
                "compute ingress stall coverage missing gap=%0d src=%0d out=%0d",
                source_gap_cycles, source_stall_cycles, output_stall_cycles);
        if (busy || error || out_valid || auto_source_enable || auto_in_valid)
            $fatal(1, "compute ingress failed to finish idle");

        $display(
            "C1_R1_COMPUTE_INGRESS_PASS configs=%0d outputs=%0d aborts=%0d seed=%h reset_reg=%0d",
            config_count, compared_outputs, abort_count, SEED, REGISTER_ABORT_RESET);
        $finish;
    end

    initial begin
        repeat (700000) @(posedge clk);
        $fatal(1, "R1 compute ingress regression timeout");
    end

endmodule
