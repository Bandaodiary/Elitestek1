`timescale 1ns/1ps

module tb_c1_r1_resize_line_sampler;

    localparam integer MAX_WIDTH = 16;
    localparam integer MAX_CONFIGS = 16;
    localparam integer MAX_SOURCE = 1024;
    localparam integer MAX_OUTPUTS = 2048;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic resize_start = 1'b0;
    wire resize_start_ready;
    wire resize_start_error;
    logic sampler_start = 1'b0;
    wire sampler_start_ready;
    wire sampler_start_error;
    logic [15:0] cfg_win = '0;
    logic [15:0] cfg_hin = '0;
    logic [15:0] cfg_wout = '0;
    logic [15:0] cfg_hout = '0;
    logic signed [31:0] cfg_x_step_q16 = '0;
    logic signed [31:0] cfg_y_step_q16 = '0;
    logic signed [31:0] cfg_x_phase0_q16 = '0;
    logic signed [31:0] cfg_y_phase0_q16 = '0;
    wire resize_busy;
    wire resize_done;
    wire sampler_busy;
    wire sampler_done;
    wire sampler_error;
    wire [3:0] sampler_error_code;

    wire sys_req_valid;
    wire sys_req_ready;
    wire sys_req_last;
    wire [15:0] sys_req_out_x;
    wire [15:0] sys_req_out_y;
    wire [15:0] sys_req_x0;
    wire [15:0] sys_req_x1;
    wire [15:0] sys_req_y0;
    wire [15:0] sys_req_y1;
    wire [12:0] sys_req_wx0;
    wire [12:0] sys_req_wx1;
    wire [12:0] sys_req_wy0;
    wire [12:0] sys_req_wy1;

    wire sys_rsp_valid;
    wire sys_rsp_ready;
    wire [23:0] sys_rsp_y0x0;
    wire [23:0] sys_rsp_y0x1;
    wire [23:0] sys_rsp_y1x0;
    wire [23:0] sys_rsp_y1x1;

    wire out_valid;
    logic out_ready = 1'b0;
    wire out_sof;
    wire out_eol;
    wire out_eof;
    wire [15:0] out_x;
    wire [15:0] out_y;
    wire [23:0] out_rgb888;

    logic manual_mode = 1'b1;
    logic request_gate = 1'b0;
    logic manual_rsp_ready = 1'b1;

    logic manual_req_valid = 1'b0;
    logic manual_req_last = 1'b0;
    logic [15:0] manual_req_out_x = '0;
    logic [15:0] manual_req_out_y = '0;
    logic [15:0] manual_req_x0 = '0;
    logic [15:0] manual_req_x1 = '0;
    logic [15:0] manual_req_y0 = '0;
    logic [15:0] manual_req_y1 = '0;
    logic [12:0] manual_req_wx0 = 13'd4096;
    logic [12:0] manual_req_wx1 = 13'd0;
    logic [12:0] manual_req_wy0 = 13'd4096;
    logic [12:0] manual_req_wy1 = 13'd0;

    wire sampler_req_valid;
    wire sampler_req_ready;
    wire sampler_req_last;
    wire [15:0] sampler_req_out_x;
    wire [15:0] sampler_req_out_y;
    wire [15:0] sampler_req_x0;
    wire [15:0] sampler_req_x1;
    wire [15:0] sampler_req_y0;
    wire [15:0] sampler_req_y1;
    wire [12:0] sampler_req_wx0;
    wire [12:0] sampler_req_wx1;
    wire [12:0] sampler_req_wy0;
    wire [12:0] sampler_req_wy1;
    wire sampler_rsp_ready;

    logic manual_src_valid = 1'b0;
    logic [15:0] manual_src_x = '0;
    logic [15:0] manual_src_y = '0;
    logic manual_src_sof = 1'b0;
    logic manual_src_eol = 1'b0;
    logic manual_src_eof = 1'b0;
    logic [23:0] manual_src_rgb = '0;

    logic auto_src_valid = 1'b0;
    logic auto_source_enable = 1'b0;
    integer auto_source_index = 0;
    integer auto_source_end = 0;
    logic [15:0] auto_src_x = '0;
    logic [15:0] auto_src_y = '0;
    wire [23:0] auto_src_rgb;
    wire auto_src_sof;
    wire auto_src_eol;
    wire auto_src_eof;

    wire sampler_src_valid;
    wire sampler_src_ready;
    wire [15:0] sampler_src_x;
    wire [15:0] sampler_src_y;
    wire sampler_src_sof;
    wire sampler_src_eol;
    wire sampler_src_eof;
    wire [23:0] sampler_src_rgb;

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

    logic [31:0] lfsr = 32'h91e10da5;
    integer cycle_count = 0;
    integer current_job = -1;
    integer observed_outputs = 0;
    integer resize_done_count = 0;
    integer sampler_done_count = 0;
    integer error_checks = 0;
    integer accepted_source_pixels = 0;
    integer request_stall_cycles = 0;
    integer response_stall_cycles = 0;
    integer output_stall_cycles = 0;
    integer source_stall_cycles = 0;
    integer source_gap_cycles = 0;

    logic [148:0] stalled_request;
    logic [95:0] stalled_response;
    logic [58:0] stalled_output;
    logic [58:0] stalled_source;

    always #5 clk = ~clk;

    assign sampler_req_valid = manual_mode ? manual_req_valid :
                               (sys_req_valid && request_gate);
    assign sys_req_ready = !manual_mode && request_gate && sampler_req_ready;
    assign sampler_req_last = manual_mode ? manual_req_last : sys_req_last;
    assign sampler_req_out_x = manual_mode ? manual_req_out_x : sys_req_out_x;
    assign sampler_req_out_y = manual_mode ? manual_req_out_y : sys_req_out_y;
    assign sampler_req_x0 = manual_mode ? manual_req_x0 : sys_req_x0;
    assign sampler_req_x1 = manual_mode ? manual_req_x1 : sys_req_x1;
    assign sampler_req_y0 = manual_mode ? manual_req_y0 : sys_req_y0;
    assign sampler_req_y1 = manual_mode ? manual_req_y1 : sys_req_y1;
    assign sampler_req_wx0 = manual_mode ? manual_req_wx0 : sys_req_wx0;
    assign sampler_req_wx1 = manual_mode ? manual_req_wx1 : sys_req_wx1;
    assign sampler_req_wy0 = manual_mode ? manual_req_wy0 : sys_req_wy0;
    assign sampler_req_wy1 = manual_mode ? manual_req_wy1 : sys_req_wy1;
    assign sampler_rsp_ready = manual_mode ? manual_rsp_ready : sys_rsp_ready;

    assign auto_src_rgb = source_mem[auto_source_index];
    assign auto_src_sof = (auto_src_x == 0) && (auto_src_y == 0);
    assign auto_src_eol = (auto_src_x == cfg_win - 16'd1);
    assign auto_src_eof = auto_src_eol && (auto_src_y == cfg_hin - 16'd1);

    assign sampler_src_valid = manual_mode ? manual_src_valid : auto_src_valid;
    assign sampler_src_x = manual_mode ? manual_src_x : auto_src_x;
    assign sampler_src_y = manual_mode ? manual_src_y : auto_src_y;
    assign sampler_src_sof = manual_mode ? manual_src_sof : auto_src_sof;
    assign sampler_src_eol = manual_mode ? manual_src_eol : auto_src_eol;
    assign sampler_src_eof = manual_mode ? manual_src_eof : auto_src_eof;
    assign sampler_src_rgb = manual_mode ? manual_src_rgb : auto_src_rgb;

    c1_r1_resize_system u_resize (
        .clk,
        .rst,
        .start(resize_start),
        .start_ready(resize_start_ready),
        .start_error(resize_start_error),
        .cfg_win,
        .cfg_hin,
        .cfg_wout,
        .cfg_hout,
        .cfg_x_step_q16,
        .cfg_y_step_q16,
        .cfg_x_phase0_q16,
        .cfg_y_phase0_q16,
        .busy(resize_busy),
        .done(resize_done),
        .sample_req_valid(sys_req_valid),
        .sample_req_ready(sys_req_ready),
        .sample_req_last(sys_req_last),
        .sample_req_out_x(sys_req_out_x),
        .sample_req_out_y(sys_req_out_y),
        .sample_req_x0(sys_req_x0),
        .sample_req_x1(sys_req_x1),
        .sample_req_y0(sys_req_y0),
        .sample_req_y1(sys_req_y1),
        .sample_req_wx0(sys_req_wx0),
        .sample_req_wx1(sys_req_wx1),
        .sample_req_wy0(sys_req_wy0),
        .sample_req_wy1(sys_req_wy1),
        .sample_rsp_valid(sys_rsp_valid),
        .sample_rsp_ready(sys_rsp_ready),
        .sample_rsp_rgb_y0x0(sys_rsp_y0x0),
        .sample_rsp_rgb_y0x1(sys_rsp_y0x1),
        .sample_rsp_rgb_y1x0(sys_rsp_y1x0),
        .sample_rsp_rgb_y1x1(sys_rsp_y1x1),
        .out_valid,
        .out_ready,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .out_rgb888
    );

    c1_r1_resize_line_sampler #(
        .MAX_WIDTH(MAX_WIDTH)
    ) u_sampler (
        .clk,
        .rst,
        .start(sampler_start),
        .start_ready(sampler_start_ready),
        .start_error(sampler_start_error),
        .cfg_win,
        .cfg_hin,
        .busy(sampler_busy),
        .done(sampler_done),
        .error(sampler_error),
        .error_code(sampler_error_code),
        .src_valid(sampler_src_valid),
        .src_ready(sampler_src_ready),
        .src_x(sampler_src_x),
        .src_y(sampler_src_y),
        .src_sof(sampler_src_sof),
        .src_eol(sampler_src_eol),
        .src_eof(sampler_src_eof),
        .src_rgb888(sampler_src_rgb),
        .sample_req_valid(sampler_req_valid),
        .sample_req_ready(sampler_req_ready),
        .sample_req_last(sampler_req_last),
        .sample_req_out_x(sampler_req_out_x),
        .sample_req_out_y(sampler_req_out_y),
        .sample_req_x0(sampler_req_x0),
        .sample_req_x1(sampler_req_x1),
        .sample_req_y0(sampler_req_y0),
        .sample_req_y1(sampler_req_y1),
        .sample_req_wx0(sampler_req_wx0),
        .sample_req_wx1(sampler_req_wx1),
        .sample_req_wy0(sampler_req_wy0),
        .sample_req_wy1(sampler_req_wy1),
        .sample_rsp_valid(sys_rsp_valid),
        .sample_rsp_ready(sampler_rsp_ready),
        .sample_rsp_rgb_y0x0(sys_rsp_y0x0),
        .sample_rsp_rgb_y0x1(sys_rsp_y0x1),
        .sample_rsp_rgb_y1x0(sys_rsp_y1x0),
        .sample_rsp_rgb_y1x1(sys_rsp_y1x1)
    );

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("r1_resize_line_sampler_source.txt", "r");
            if (fd == 0) $fatal(1, "cannot open sampler source vectors");
            status = $fscanf(fd, "%d\n", source_count);
            if (status != 1 || source_count <= 0 || source_count > MAX_SOURCE)
                $fatal(1, "invalid sampler source count");
            for (index = 0; index < source_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", source_mem[index]);
                if (status != 1) $fatal(1, "malformed source pixel %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_configs.txt", "r");
            if (fd == 0) $fatal(1, "cannot open sampler configs");
            status = $fscanf(fd, "%d\n", config_count);
            if (status != 1 || config_count <= 0 || config_count > MAX_CONFIGS)
                $fatal(1, "invalid sampler config count");
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
                    $fatal(1, "malformed sampler config %0d", index);
                if (config_win[index] > MAX_WIDTH)
                    $fatal(1, "Golden width exceeds test cache");
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_expected.txt", "r");
            if (fd == 0) $fatal(1, "cannot open sampler expected vectors");
            status = $fscanf(fd, "%d\n", output_count);
            if (status != 1 || output_count <= 0 || output_count > MAX_OUTPUTS)
                $fatal(1, "invalid sampler expected count");
            for (index = 0; index < output_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", expected_mem[index]);
                if (status != 1) $fatal(1, "malformed expected output %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic reset_design;
        begin
            @(negedge clk);
            rst = 1'b1;
            resize_start = 1'b0;
            sampler_start = 1'b0;
            manual_req_valid = 1'b0;
            manual_src_valid = 1'b0;
            auto_source_enable = 1'b0;
            auto_src_valid = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic sampler_start_only(
        input logic [15:0] width,
        input logic [15:0] height
    );
        begin
            while (!sampler_start_ready) @(negedge clk);
            cfg_win = width;
            cfg_hin = height;
            sampler_start = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            sampler_start = 1'b0;
        end
    endtask

    task automatic run_error_checks;
        begin
            manual_mode = 1'b1;

            // Zero dimensions are rejected without entering busy state.
            sampler_start_only(16'd0, 16'd2);
            if (!sampler_start_error || !sampler_error ||
                sampler_error_code != 4'd1 || sampler_busy)
                $fatal(1, "zero-width configuration was not rejected");
            error_checks = error_checks + 1;

            reset_design();
            sampler_start_only(MAX_WIDTH + 1, 16'd2);
            if (!sampler_start_error || !sampler_error ||
                sampler_error_code != 4'd1 || sampler_busy)
                $fatal(1, "oversize width was not rejected");
            error_checks = error_checks + 1;

            // A malformed first raster sample is accepted only to report the
            // protocol fault; the cache then stops both channels.
            reset_design();
            sampler_start_only(16'd2, 16'd2);
            @(negedge clk);
            manual_src_valid = 1'b1;
            manual_src_x = 16'd1;
            manual_src_y = 16'd0;
            manual_src_sof = 1'b1;
            manual_src_eol = 1'b0;
            manual_src_eof = 1'b0;
            manual_src_rgb = 24'h123456;
            @(posedge clk);
            #1;
            if (!sampler_error || sampler_error_code != 4'd2 ||
                sampler_src_ready)
                $fatal(1, "non-raster source input was not trapped");
            @(negedge clk);
            manual_src_valid = 1'b0;
            error_checks = error_checks + 1;

            // Out-of-range coordinates are detected before any request
            // handshake and never create a sample response.
            reset_design();
            sampler_start_only(16'd2, 16'd2);
            @(negedge clk);
            manual_req_valid = 1'b1;
            manual_req_x0 = 16'd0;
            manual_req_x1 = 16'd2;
            manual_req_y0 = 16'd0;
            manual_req_y1 = 16'd1;
            @(posedge clk);
            #1;
            if (!sampler_error || sampler_error_code != 4'd3 ||
                sampler_req_ready || sys_rsp_valid)
                $fatal(1, "out-of-range request was not trapped");
            @(negedge clk);
            manual_req_valid = 1'b0;
            error_checks = error_checks + 1;

            // The explicit two-line limitation rejects non-adjacent rows.
            reset_design();
            sampler_start_only(16'd2, 16'd3);
            @(negedge clk);
            manual_req_valid = 1'b1;
            manual_req_x0 = 16'd0;
            manual_req_x1 = 16'd1;
            manual_req_y0 = 16'd0;
            manual_req_y1 = 16'd2;
            @(posedge clk);
            #1;
            if (!sampler_error || sampler_error_code != 4'd4 ||
                sampler_req_ready || sys_rsp_valid)
                $fatal(1, "non-adjacent line-pair request was not rejected");
            @(negedge clk);
            manual_req_valid = 1'b0;
            error_checks = error_checks + 1;
        end
    endtask

    task automatic start_job(input integer job_index);
        integer prior_resize_done;
        integer prior_sampler_done;
        begin
            while (!resize_start_ready || !sampler_start_ready)
                @(negedge clk);
            current_job = job_index;
            cfg_win = config_win[job_index];
            cfg_hin = config_hin[job_index];
            cfg_wout = config_wout[job_index];
            cfg_hout = config_hout[job_index];
            cfg_x_step_q16 = config_x_step[job_index];
            cfg_y_step_q16 = config_y_step[job_index];
            cfg_x_phase0_q16 = config_x_phase0[job_index];
            cfg_y_phase0_q16 = config_y_phase0[job_index];
            auto_source_index = config_source_start[job_index];
            auto_source_end = config_source_start[job_index] +
                              config_source_count[job_index];
            auto_src_x = 16'd0;
            auto_src_y = 16'd0;
            auto_src_valid = 1'b0;
            auto_source_enable = 1'b1;
            prior_resize_done = resize_done_count;
            prior_sampler_done = sampler_done_count;

            @(negedge clk);
            resize_start = 1'b1;
            sampler_start = 1'b1;
            @(posedge clk);
            #1;
            if (resize_start_error || sampler_start_error ||
                !resize_busy || !sampler_busy)
                $fatal(1, "valid resize/cache job failed to start job=%0d",
                       job_index);
            @(negedge clk);
            resize_start = 1'b0;
            sampler_start = 1'b0;

            while ((resize_done_count == prior_resize_done) ||
                   (sampler_done_count == prior_sampler_done)) begin
                if (sampler_error)
                    $fatal(1, "sampler error in valid job=%0d code=%0d",
                           job_index, sampler_error_code);
                @(negedge clk);
            end
            if (resize_busy || sampler_busy || auto_source_enable ||
                auto_src_valid)
                $fatal(1, "job did not fully drain job=%0d", job_index);
            if (observed_outputs != config_output_start[job_index] +
                                    config_output_count[job_index])
                $fatal(1, "per-job output count mismatch job=%0d", job_index);
        end
    endtask

    // Random request gating and output backpressure are independent of source
    // gaps.  The deterministic long-low windows guarantee stall coverage.
    always @(negedge clk) begin
        if (rst) begin
            lfsr = 32'h91e10da5;
            request_gate = 1'b0;
            out_ready = 1'b0;
            cycle_count = 0;
        end else begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            request_gate = (lfsr[2:0] != 3'b000) &&
                           ((cycle_count % 61) < 49);
            out_ready = (lfsr[6:4] != 3'b000) &&
                        ((cycle_count % 73) < 55);
            cycle_count = cycle_count + 1;
        end
    end

    // Source stream producer.  The index and payload remain unchanged while
    // valid is stalled; random launch suppression creates source gaps.
    always @(posedge clk) begin
        if (rst || manual_mode || !auto_source_enable) begin
            auto_src_valid <= 1'b0;
        end else if (auto_src_valid) begin
            if (sampler_src_ready) begin
                accepted_source_pixels = accepted_source_pixels + 1;
                if (auto_source_index + 1 >= auto_source_end) begin
                    auto_src_valid <= 1'b0;
                    auto_source_enable <= 1'b0;
                end else begin
                    auto_source_index <= auto_source_index + 1;
                    if (auto_src_x == cfg_win - 16'd1) begin
                        auto_src_x <= 16'd0;
                        auto_src_y <= auto_src_y + 16'd1;
                    end else begin
                        auto_src_x <= auto_src_x + 16'd1;
                    end
                    auto_src_valid <= lfsr[8] || lfsr[12];
                end
            end
        end else if (auto_source_index < auto_source_end &&
                     (lfsr[9] || lfsr[14])) begin
            auto_src_valid <= 1'b1;
        end
    end

    // End-to-end output and coverage scoreboards.
    always @(posedge clk) begin
        if (!rst && !manual_mode) begin
            if (sys_req_valid && !sys_req_ready)
                request_stall_cycles = request_stall_cycles + 1;
            if (sys_rsp_valid && !sys_rsp_ready)
                response_stall_cycles = response_stall_cycles + 1;
            if (out_valid && !out_ready)
                output_stall_cycles = output_stall_cycles + 1;
            if (sampler_src_valid && !sampler_src_ready)
                source_stall_cycles = source_stall_cycles + 1;
            if (auto_source_enable && !auto_src_valid)
                source_gap_cycles = source_gap_cycles + 1;
            if (resize_done)
                resize_done_count = resize_done_count + 1;
            if (sampler_done)
                sampler_done_count = sampler_done_count + 1;

            if (out_valid && out_ready) begin
                if (observed_outputs >= output_count)
                    $fatal(1, "unexpected extra sampler resize output");
                if (out_rgb888 !== expected_mem[observed_outputs][23:0])
                    $fatal(1,
                        "sampler RGB mismatch index=%0d got=%h expected=%h",
                        observed_outputs, out_rgb888,
                        expected_mem[observed_outputs][23:0]);
                if (out_x !== expected_mem[observed_outputs][39:24] ||
                    out_y !== expected_mem[observed_outputs][55:40])
                    $fatal(1, "sampler coordinate mismatch index=%0d",
                           observed_outputs);
                if (out_sof !== expected_mem[observed_outputs][56] ||
                    out_eol !== expected_mem[observed_outputs][57] ||
                    out_eof !== expected_mem[observed_outputs][58])
                    $fatal(1, "sampler frame flag mismatch index=%0d",
                           observed_outputs);
                observed_outputs = observed_outputs + 1;
            end
        end
    end

    // All four ready/valid payloads are required to remain stable on stalls.
    always @(posedge clk) begin
        if (!rst && !manual_mode && sys_req_valid && !sys_req_ready) begin
            stalled_request = {sys_req_out_x, sys_req_out_y,
                               sys_req_x0, sys_req_x1,
                               sys_req_y0, sys_req_y1,
                               sys_req_wx0, sys_req_wx1,
                               sys_req_wy0, sys_req_wy1,
                               sys_req_last};
            #1;
            if (!sys_req_valid ||
                {sys_req_out_x, sys_req_out_y,
                 sys_req_x0, sys_req_x1,
                 sys_req_y0, sys_req_y1,
                 sys_req_wx0, sys_req_wx1,
                 sys_req_wy0, sys_req_wy1,
                 sys_req_last} !== stalled_request)
                $fatal(1, "resize request changed while stalled");
        end
    end

    always @(posedge clk) begin
        if (!rst && !manual_mode && sys_rsp_valid && !sys_rsp_ready) begin
            stalled_response = {sys_rsp_y0x0, sys_rsp_y0x1,
                                sys_rsp_y1x0, sys_rsp_y1x1};
            #1;
            if (!sys_rsp_valid ||
                {sys_rsp_y0x0, sys_rsp_y0x1,
                 sys_rsp_y1x0, sys_rsp_y1x1} !== stalled_response)
                $fatal(1, "sampler response changed while stalled");
        end
    end

    always @(posedge clk) begin
        if (!rst && !manual_mode && out_valid && !out_ready) begin
            stalled_output = {out_eof, out_eol, out_sof,
                              out_y, out_x, out_rgb888};
            #1;
            if (!out_valid ||
                {out_eof, out_eol, out_sof,
                 out_y, out_x, out_rgb888} !== stalled_output)
                $fatal(1, "resize output changed while stalled");
        end
    end

    always @(posedge clk) begin
        if (!rst && !manual_mode && sampler_src_valid && !sampler_src_ready) begin
            stalled_source = {sampler_src_x, sampler_src_y,
                              sampler_src_sof, sampler_src_eol,
                              sampler_src_eof, sampler_src_rgb};
            #1;
            if (!sampler_src_valid ||
                {sampler_src_x, sampler_src_y,
                 sampler_src_sof, sampler_src_eol,
                 sampler_src_eof, sampler_src_rgb} !== stalled_source)
                $fatal(1, "source raster payload changed while stalled");
        end
    end

    integer job;
    initial begin
        load_vectors();
        repeat (6) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        run_error_checks();
        reset_design();
        manual_mode = 1'b0;

        for (job = 0; job < config_count; job = job + 1)
            start_job(job);

        repeat (10) @(posedge clk);
        if (observed_outputs != output_count)
            $fatal(1, "final sampler output count mismatch");
        if (resize_done_count != config_count ||
            sampler_done_count != config_count)
            $fatal(1, "done pulse count mismatch resize=%0d sampler=%0d",
                   resize_done_count, sampler_done_count);
        if (accepted_source_pixels != source_count)
            $fatal(1, "source acceptance count mismatch got=%0d expected=%0d",
                   accepted_source_pixels, source_count);
        if (error_checks != 5)
            $fatal(1, "sampler error coverage mismatch");
        if (request_stall_cycles == 0 || response_stall_cycles == 0 ||
            output_stall_cycles == 0 || source_stall_cycles == 0 ||
            source_gap_cycles == 0)
            $fatal(1,
                "stall coverage missing req=%0d rsp=%0d out=%0d src=%0d gap=%0d",
                request_stall_cycles, response_stall_cycles,
                output_stall_cycles, source_stall_cycles, source_gap_cycles);
        if (resize_busy || sampler_busy || sys_rsp_valid || out_valid ||
            sampler_error)
            $fatal(1, "resize/cache system did not finish cleanly");

        $display(
            "C1_R1_RESIZE_LINE_SAMPLER_PASS configs=%0d outputs=%0d errors=%0d",
            config_count, observed_outputs, error_checks);
        $finish;
    end

    initial begin
        repeat (500000) @(posedge clk);
        $fatal(1, "R1 resize line sampler regression timeout");
    end

endmodule
