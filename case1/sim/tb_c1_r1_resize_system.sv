`timescale 1ns/1ps

module tb_c1_r1_resize_system;

    localparam integer MAX_CONFIGS = 32;
    localparam integer MAX_SOURCE = 4096;
    localparam integer MAX_REQUESTS = 4096;
    localparam integer MAX_OUTPUTS = 4096;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic start = 1'b0;
    wire start_ready;
    wire start_error;
    logic [15:0] cfg_win = '0;
    logic [15:0] cfg_hin = '0;
    logic [15:0] cfg_wout = '0;
    logic [15:0] cfg_hout = '0;
    logic signed [31:0] cfg_x_step_q16 = '0;
    logic signed [31:0] cfg_y_step_q16 = '0;
    logic signed [31:0] cfg_x_phase0_q16 = '0;
    logic signed [31:0] cfg_y_phase0_q16 = '0;
    wire busy;
    wire done;

    wire sample_req_valid;
    logic sample_req_ready = 1'b0;
    wire sample_req_last;
    wire [15:0] sample_req_out_x;
    wire [15:0] sample_req_out_y;
    wire [15:0] sample_req_x0;
    wire [15:0] sample_req_x1;
    wire [15:0] sample_req_y0;
    wire [15:0] sample_req_y1;
    wire [12:0] sample_req_wx0;
    wire [12:0] sample_req_wx1;
    wire [12:0] sample_req_wy0;
    wire [12:0] sample_req_wy1;

    logic sample_rsp_valid = 1'b0;
    wire sample_rsp_ready;
    logic [23:0] sample_rsp_rgb_y0x0 = '0;
    logic [23:0] sample_rsp_rgb_y0x1 = '0;
    logic [23:0] sample_rsp_rgb_y1x0 = '0;
    logic [23:0] sample_rsp_rgb_y1x1 = '0;

    wire out_valid;
    logic out_ready = 1'b0;
    wire out_sof;
    wire out_eol;
    wire out_eof;
    wire [15:0] out_x;
    wire [15:0] out_y;
    wire [23:0] out_rgb888;

    logic [23:0] source_mem [0:MAX_SOURCE-1];
    logic [148:0] request_mem [0:MAX_REQUESTS-1];
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
    integer config_request_start [0:MAX_CONFIGS-1];
    integer config_request_count [0:MAX_CONFIGS-1];
    integer config_output_start [0:MAX_CONFIGS-1];
    integer config_output_count [0:MAX_CONFIGS-1];

    integer config_count;
    integer source_count;
    integer request_count;
    integer output_count;
    integer current_job = -1;
    integer observed_requests = 0;
    integer observed_outputs = 0;
    integer observed_done = 0;
    integer invalid_start_checks = 0;
    integer request_stall_cycles = 0;
    integer response_stall_cycles = 0;
    integer output_stall_cycles = 0;
    integer delayed_response_count = 0;
    integer zero_delay_count = 0;
    integer ready_cycle = 0;

    logic [31:0] lfsr = 32'h6d2b79f5;
    logic memory_pending = 1'b0;
    logic [3:0] response_delay = '0;

    logic [15:0] stalled_req_out_x;
    logic [15:0] stalled_req_out_y;
    logic [15:0] stalled_req_x0;
    logic [15:0] stalled_req_x1;
    logic [15:0] stalled_req_y0;
    logic [15:0] stalled_req_y1;
    logic [12:0] stalled_req_wx0;
    logic [12:0] stalled_req_wx1;
    logic [12:0] stalled_req_wy0;
    logic [12:0] stalled_req_wy1;
    logic stalled_req_last;
    logic [23:0] stalled_out_rgb;
    logic [15:0] stalled_out_x;
    logic [15:0] stalled_out_y;
    logic stalled_out_sof;
    logic stalled_out_eol;
    logic stalled_out_eof;

    always #5 clk = ~clk;

    c1_r1_resize_system dut (
        .clk,
        .rst,
        .start,
        .start_ready,
        .start_error,
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .busy,
        .done,
        .sample_req_valid,
        .sample_req_ready,
        .sample_req_last,
        .sample_req_out_x,
        .sample_req_out_y,
        .sample_req_x0,
        .sample_req_x1,
        .sample_req_y0,
        .sample_req_y1,
        .sample_req_wx0,
        .sample_req_wx1,
        .sample_req_wy0,
        .sample_req_wy1,
        .sample_rsp_valid,
        .sample_rsp_ready,
        .sample_rsp_rgb_y0x0,
        .sample_rsp_rgb_y0x1,
        .sample_rsp_rgb_y1x0,
        .sample_rsp_rgb_y1x1,
        .out_valid,
        .out_ready,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .out_rgb888
    );

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("r1_resize_system_source.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize source vectors");
            status = $fscanf(fd, "%d\n", source_count);
            if (status != 1 || source_count <= 0 || source_count > MAX_SOURCE)
                $fatal(1, "invalid resize source count");
            for (index = 0; index < source_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", source_mem[index]);
                if (status != 1) $fatal(1, "malformed source pixel %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_system_configs.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize system configs");
            status = $fscanf(fd, "%d\n", config_count);
            if (status != 1 || config_count <= 0 || config_count > MAX_CONFIGS)
                $fatal(1, "invalid resize config count");
            for (index = 0; index < config_count; index = index + 1) begin
                status = $fscanf(
                    fd, "%h %h %h %h %h %h %h %h %d %d %d %d %d %d\n",
                    config_win[index], config_hin[index],
                    config_wout[index], config_hout[index],
                    config_x_step[index], config_y_step[index],
                    config_x_phase0[index], config_y_phase0[index],
                    config_source_start[index], config_source_count[index],
                    config_request_start[index], config_request_count[index],
                    config_output_start[index], config_output_count[index]);
                if (status != 14)
                    $fatal(1, "malformed resize config %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_system_requests.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize request vectors");
            status = $fscanf(fd, "%d\n", request_count);
            if (status != 1 || request_count <= 0 || request_count > MAX_REQUESTS)
                $fatal(1, "invalid resize request count");
            for (index = 0; index < request_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", request_mem[index]);
                if (status != 1) $fatal(1, "malformed resize request %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_system_expected.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize expected vectors");
            status = $fscanf(fd, "%d\n", output_count);
            if (status != 1 || output_count <= 0 || output_count > MAX_OUTPUTS)
                $fatal(1, "invalid resize output count");
            for (index = 0; index < output_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", expected_mem[index]);
                if (status != 1) $fatal(1, "malformed resize output %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic apply_config(input integer index);
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

    task automatic start_job(input integer index);
        begin
            while (!start_ready)
                @(negedge clk);
            current_job = index;
            apply_config(index);
            start = 1'b1;
            @(posedge clk);
            #1;
            if (!busy || start_error || start_ready)
                $fatal(1, "resize job failed to start config=%0d", index);
            @(negedge clk);
            start = 1'b0;

            // Prove both primitives operate from the atomically captured job.
            cfg_win = 16'hffff;
            cfg_hin = 16'hfffe;
            cfg_wout = 16'h0001;
            cfg_hout = 16'h0001;
            cfg_x_step_q16 = -32'sd1;
            cfg_y_step_q16 = -32'sd2;
            cfg_x_phase0_q16 = 32'sh7fffffff;
            cfg_y_phase0_q16 = 32'sh80000000;
        end
    endtask

    // Pseudo-random memory acceptance and downstream backpressure.
    always @(negedge clk) begin
        if (rst) begin
            lfsr = 32'h6d2b79f5;
            ready_cycle = 0;
            sample_req_ready = 1'b0;
            out_ready = 1'b0;
        end else begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            sample_req_ready = !memory_pending &&
                               !(lfsr[2:0] == 3'b000) &&
                               !(lfsr[7:5] == 3'b111);
            out_ready = !(lfsr[11:9] == 3'b000) &&
                        !(lfsr[15:13] == 3'b101) &&
                        !((ready_cycle % 79) >= 50);
            ready_cycle = ready_cycle + 1;
        end
    end

    // Single-entry variable-latency source memory model.
    always @(posedge clk) begin
        if (rst) begin
            memory_pending <= 1'b0;
            response_delay <= '0;
            sample_rsp_valid <= 1'b0;
            sample_rsp_rgb_y0x0 <= '0;
            sample_rsp_rgb_y0x1 <= '0;
            sample_rsp_rgb_y1x0 <= '0;
            sample_rsp_rgb_y1x1 <= '0;
        end else begin
            if (sample_req_valid && sample_req_ready) begin
                if (memory_pending || sample_rsp_valid)
                    $fatal(1, "memory accepted more than one outstanding request");
                memory_pending <= 1'b1;
                response_delay <= lfsr[19:16] & 4'h7;
                if ((lfsr[19:16] & 4'h7) == 0)
                    zero_delay_count = zero_delay_count + 1;
                else
                    delayed_response_count = delayed_response_count + 1;
                sample_rsp_rgb_y0x0 <= source_mem[
                    config_source_start[current_job] +
                    sample_req_y0 * config_win[current_job] + sample_req_x0];
                sample_rsp_rgb_y0x1 <= source_mem[
                    config_source_start[current_job] +
                    sample_req_y0 * config_win[current_job] + sample_req_x1];
                sample_rsp_rgb_y1x0 <= source_mem[
                    config_source_start[current_job] +
                    sample_req_y1 * config_win[current_job] + sample_req_x0];
                sample_rsp_rgb_y1x1 <= source_mem[
                    config_source_start[current_job] +
                    sample_req_y1 * config_win[current_job] + sample_req_x1];
            end

            if (memory_pending && !sample_rsp_valid) begin
                if (response_delay == 0)
                    sample_rsp_valid <= 1'b1;
                else
                    response_delay <= response_delay - 1'b1;
            end

            if (sample_rsp_valid && sample_rsp_ready) begin
                sample_rsp_valid <= 1'b0;
                memory_pending <= 1'b0;
            end
        end
    end

    // Request scoreboard and source-side stall accounting.
    always @(posedge clk) begin
        if (!rst) begin
            if (sample_req_valid && sample_req_ready) begin
                if (observed_requests >= request_count)
                    $fatal(1, "unexpected extra sample request");
                if (sample_req_out_x !== request_mem[observed_requests][148:133] ||
                    sample_req_out_y !== request_mem[observed_requests][132:117] ||
                    sample_req_x0 !== request_mem[observed_requests][116:101] ||
                    sample_req_x1 !== request_mem[observed_requests][100:85] ||
                    sample_req_y0 !== request_mem[observed_requests][84:69] ||
                    sample_req_y1 !== request_mem[observed_requests][68:53] ||
                    sample_req_wx0 !== request_mem[observed_requests][52:40] ||
                    sample_req_wx1 !== request_mem[observed_requests][39:27] ||
                    sample_req_wy0 !== request_mem[observed_requests][26:14] ||
                    sample_req_wy1 !== request_mem[observed_requests][13:1] ||
                    sample_req_last !== request_mem[observed_requests][0])
                    $fatal(1, "sample request mismatch index=%0d", observed_requests);
                observed_requests = observed_requests + 1;
            end
            if (sample_req_valid && !sample_req_ready)
                request_stall_cycles = request_stall_cycles + 1;
            if (sample_rsp_valid && !sample_rsp_ready)
                response_stall_cycles = response_stall_cycles + 1;
        end
    end

    // Keep this delayed request stability check independent of other channels.
    always @(posedge clk) begin
        if (!rst && sample_req_valid && !sample_req_ready) begin
            stalled_req_out_x = sample_req_out_x;
            stalled_req_out_y = sample_req_out_y;
            stalled_req_x0 = sample_req_x0;
            stalled_req_x1 = sample_req_x1;
            stalled_req_y0 = sample_req_y0;
            stalled_req_y1 = sample_req_y1;
            stalled_req_wx0 = sample_req_wx0;
            stalled_req_wx1 = sample_req_wx1;
            stalled_req_wy0 = sample_req_wy0;
            stalled_req_wy1 = sample_req_wy1;
            stalled_req_last = sample_req_last;
            #1;
            if (!sample_req_valid ||
                sample_req_out_x !== stalled_req_out_x ||
                sample_req_out_y !== stalled_req_out_y ||
                sample_req_x0 !== stalled_req_x0 ||
                sample_req_x1 !== stalled_req_x1 ||
                sample_req_y0 !== stalled_req_y0 ||
                sample_req_y1 !== stalled_req_y1 ||
                sample_req_wx0 !== stalled_req_wx0 ||
                sample_req_wx1 !== stalled_req_wx1 ||
                sample_req_wy0 !== stalled_req_wy0 ||
                sample_req_wy1 !== stalled_req_wy1 ||
                sample_req_last !== stalled_req_last)
                $fatal(1, "sample request payload changed while stalled");
        end
    end

    // Output scoreboard samples payload before the elastic stage advances.
    always @(posedge clk) begin
        if (!rst) begin
            if (!out_valid && (out_sof || out_eol || out_eof))
                $fatal(1, "resize output metadata asserted while invalid");
            if (out_valid && out_ready) begin
                if (observed_outputs >= output_count)
                    $fatal(1, "unexpected extra resize output");
                if (out_rgb888 !== expected_mem[observed_outputs][23:0])
                    $fatal(1, "resize RGB mismatch index=%0d got=%h expected=%h",
                           observed_outputs, out_rgb888,
                           expected_mem[observed_outputs][23:0]);
                if (out_x !== expected_mem[observed_outputs][39:24] ||
                    out_y !== expected_mem[observed_outputs][55:40])
                    $fatal(1, "resize coordinate mismatch index=%0d",
                           observed_outputs);
                if (out_sof !== expected_mem[observed_outputs][56] ||
                    out_eol !== expected_mem[observed_outputs][57] ||
                    out_eof !== expected_mem[observed_outputs][58])
                    $fatal(1, "resize frame flag mismatch index=%0d",
                           observed_outputs);
                observed_outputs = observed_outputs + 1;
            end
            if (out_valid && !out_ready)
                output_stall_cycles = output_stall_cycles + 1;
            if (done)
                observed_done = observed_done + 1;
            if (busy && start_ready)
                $fatal(1, "start_ready asserted while resize job busy");
        end
    end

    always @(posedge clk) begin
        if (!rst && out_valid && !out_ready) begin
            stalled_out_rgb = out_rgb888;
            stalled_out_x = out_x;
            stalled_out_y = out_y;
            stalled_out_sof = out_sof;
            stalled_out_eol = out_eol;
            stalled_out_eof = out_eof;
            #1;
            if (!out_valid || out_rgb888 !== stalled_out_rgb ||
                out_x !== stalled_out_x || out_y !== stalled_out_y ||
                out_sof !== stalled_out_sof || out_eol !== stalled_out_eol ||
                out_eof !== stalled_out_eof)
                $fatal(1, "resize output payload changed while stalled");
        end
    end

    integer job_index;
    initial begin
        load_vectors();
        repeat (6) @(negedge clk);
        rst = 1'b0;

        // Zero dimensions are explicitly rejected; one-pixel dimensions in
        // the subsequent Golden jobs are fully supported.
        @(negedge clk);
        cfg_win = 16'd0;
        cfg_hin = 16'd1;
        cfg_wout = 16'd1;
        cfg_hout = 16'd1;
        start = 1'b1;
        @(posedge clk);
        #1;
        if (!start_error || busy)
            $fatal(1, "zero-dimension start was not rejected");
        invalid_start_checks = invalid_start_checks + 1;
        @(negedge clk);
        start = 1'b0;

        for (job_index = 0; job_index < config_count;
             job_index = job_index + 1) begin
            start_job(job_index);
            while (!done) begin
                if (!busy)
                    $fatal(1, "busy dropped before final output handshake");
                @(negedge clk);
            end
            if (busy)
                $fatal(1, "busy remained set with done");
            if (observed_requests != config_request_start[job_index] +
                                     config_request_count[job_index])
                $fatal(1, "per-job request count mismatch job=%0d", job_index);
            if (observed_outputs != config_output_start[job_index] +
                                    config_output_count[job_index])
                $fatal(1, "per-job output count mismatch job=%0d", job_index);
            @(negedge clk);
        end

        repeat (8) @(posedge clk);
        if (observed_requests != request_count || observed_outputs != output_count)
            $fatal(1, "final resize transaction count mismatch");
        if (observed_done != config_count)
            $fatal(1, "resize done pulse count mismatch");
        if (invalid_start_checks != 1)
            $fatal(1, "invalid-start coverage missing");
        if (request_stall_cycles == 0 || response_stall_cycles == 0 ||
            output_stall_cycles == 0)
            $fatal(1,
                   "ready/valid stall coverage missing req=%0d rsp=%0d out=%0d",
                   request_stall_cycles, response_stall_cycles,
                   output_stall_cycles);
        if (delayed_response_count == 0 || zero_delay_count == 0)
            $fatal(1, "variable sample-latency coverage missing");
        if (memory_pending || sample_rsp_valid || out_valid || busy)
            $fatal(1, "resize system failed to drain");

        $display("C1_R1_RESIZE_SYSTEM_PASS configs=%0d requests=%0d outputs=%0d",
                 config_count, observed_requests, observed_outputs);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "R1 resize system regression timeout");
    end

endmodule
