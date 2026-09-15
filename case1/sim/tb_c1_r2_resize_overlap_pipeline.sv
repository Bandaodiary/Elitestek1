// C23 independent banked Resize derivative; R1 baseline unchanged.
`timescale 1ns/1ps

module tb_c1_r2_resize_overlap_pipeline;

    localparam integer MAX_WIDTH = 16;
    localparam integer MAX_CONFIGS = 16;
    localparam integer MAX_SOURCE = 1024;
    localparam integer MAX_OUTPUTS = 2048;
`ifdef C1_REGISTER_ABORT_RESET
    localparam integer REGISTER_ABORT_RESET_CFG = 1;
`else
    localparam integer REGISTER_ABORT_RESET_CFG = 0;
`endif

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
    logic out_ready = 1'b0;
    wire out_sof;
    wire out_eol;
    wire out_eof;
    wire [15:0] out_x;
    wire [15:0] out_y;
    wire [23:0] out_rgb888;

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
    integer abort_count = 0;
    integer runtime_error_count = 0;
    integer config_stall_cycles = 0;
    integer source_gap_cycles = 0;
    integer source_stall_cycles = 0;
    integer output_stall_cycles = 0;
    logic [31:0] lfsr = 32'h54f3c91d;
    integer cycle_count = 0;

    logic [58:0] stalled_input;
    logic [58:0] stalled_output;

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

    c1_r2_resize_overlap_pipeline #(
        .MAX_WIDTH(MAX_WIDTH),
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET_CFG)
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
            fd = $fopen("r1_resize_line_sampler_source.txt", "r");
            if (fd == 0) $fatal(1, "cannot open pipeline source vectors");
            status = $fscanf(fd, "%d\n", source_count);
            if (status != 1 || source_count <= 0 || source_count > MAX_SOURCE)
                $fatal(1, "invalid pipeline source count");
            for (index = 0; index < source_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", source_mem[index]);
                if (status != 1) $fatal(1, "malformed source pixel %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_configs.txt", "r");
            if (fd == 0) $fatal(1, "cannot open pipeline configs");
            status = $fscanf(fd, "%d\n", config_count);
            if (status != 1 || config_count <= 0 || config_count > MAX_CONFIGS)
                $fatal(1, "invalid pipeline config count");
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
                    $fatal(1, "malformed pipeline config %0d", index);
            end
            $fclose(fd);

            fd = $fopen("r1_resize_line_sampler_expected.txt", "r");
            if (fd == 0) $fatal(1, "cannot open pipeline expected vectors");
            status = $fscanf(fd, "%d\n", output_count);
            if (status != 1 || output_count <= 0 || output_count > MAX_OUTPUTS)
                $fatal(1, "invalid pipeline output count");
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
            abort = 1'b0;
            cfg_valid = 1'b0;
            manual_in_valid = 1'b0;
            auto_source_enable = 1'b0;
            auto_in_valid = 1'b0;
            compare_enable = 1'b0;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
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

    task automatic transact_config(
        input logic expected_cfg_error,
        input logic [3:0] expected_error_code
    );
        logic sampled_ready;
        begin
            while (!cfg_ready) @(negedge clk);
            @(negedge clk);
            cfg_valid = 1'b1;
            @(posedge clk);
            sampled_ready = cfg_ready;
            #1;
            if (!sampled_ready)
                $fatal(1, "pipeline configuration was not accepted");
            if (cfg_error !== expected_cfg_error)
                $fatal(1, "pipeline cfg_error mismatch");
            if (expected_cfg_error) begin
                if (!error || error_code != expected_error_code || busy)
                    $fatal(1, "invalid pipeline config status mismatch");
            end else if (error || !busy) begin
                $fatal(1, "valid pipeline config failed to start");
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

    task automatic start_checked_job(input integer index);
        integer prior_completed;
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
            transact_config(1'b0, 4'd0);
            while (completed_jobs == prior_completed) begin
                if (error)
                    $fatal(1, "pipeline runtime error code=%0d job=%0d",
                           error_code, index);
                @(negedge clk);
            end
            if (busy || auto_source_enable || auto_in_valid)
                $fatal(1, "pipeline job did not fully drain job=%0d", index);
            if (expected_index != expected_end)
                $fatal(1, "pipeline per-job output count mismatch job=%0d",
                       index);
            if (accepted_source_job != config_source_count[index])
                $fatal(1, "pipeline source count mismatch job=%0d", index);
            compare_enable = 1'b0;
        end
    endtask

    task automatic abort_active_job;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(posedge clk);
            #1;
            if (!aborted || busy || done || error || in_ready || out_valid)
                $fatal(1, "pipeline abort flush status mismatch");
            abort_count = abort_count + 1;
            @(negedge clk);
            auto_source_enable = 1'b0;
            auto_in_valid = 1'b0;
            manual_in_valid = 1'b0;
            abort = 1'b0;
            @(posedge clk);
            #1;
            if (!cfg_ready || aborted)
                $fatal(1, "pipeline did not become restartable after abort");
        end
    endtask

    integer pause_after_rows=0;
    // Independent random source gaps and output stalls.
    always @(negedge clk) begin
        if (rst) begin
            lfsr = 32'h54f3c91d;
            out_ready = 1'b0;
            cycle_count = 0;
        end else begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            out_ready = (lfsr[3:1] != 3'b000) &&
                        ((cycle_count % 67) < 49);
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
                    auto_in_valid <= (lfsr[7] || lfsr[11]) &&
                        !(pause_after_rows!=0 && auto_in_x==source_width_q-1 &&
                          auto_in_y+1>=pause_after_rows);
                end
            end
        end else if (auto_source_index < auto_source_end &&
                     (pause_after_rows==0 || auto_in_y<pause_after_rows) &&
                     (lfsr[8] || lfsr[13])) begin
            auto_in_valid <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (cfg_error)
                cfg_error_count = cfg_error_count + 1;
            if (cfg_valid && !cfg_ready)
                config_stall_cycles = config_stall_cycles + 1;
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
                if (compare_enable) begin
                    if (expected_index >= expected_end)
                        $fatal(1, "unexpected extra pipeline output");
                    if (out_rgb888 !== expected_mem[expected_index][23:0])
                        $fatal(1,
                            "pipeline RGB mismatch index=%0d got=%h expected=%h",
                            expected_index, out_rgb888,
                            expected_mem[expected_index][23:0]);
                    if (out_x !== expected_mem[expected_index][39:24] ||
                        out_y !== expected_mem[expected_index][55:40])
                        $fatal(1, "pipeline coordinate mismatch index=%0d",
                               expected_index);
                    if (out_sof !== expected_mem[expected_index][56] ||
                        out_eol !== expected_mem[expected_index][57] ||
                        out_eof !== expected_mem[expected_index][58])
                        $fatal(1, "pipeline flag mismatch index=%0d",
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
                $fatal(1, "pipeline input changed while stalled");
        end
    end

    always @(posedge clk) begin
        if (!rst && out_valid && !out_ready) begin
            stalled_output = {out_eof, out_eol, out_sof,
                              out_y, out_x, out_rgb888};
            #1;
            if (!out_valid ||
                {out_eof, out_eol, out_sof,
                 out_y, out_x, out_rgb888} !== stalled_output)
                $fatal(1, "pipeline output changed while stalled");
        end
    end

    integer tail_drain_cycles=0,overlap_samples=0;
    always @(posedge clk)if(!rst && !abort && !dut.engine_rst &&
        dut.sample_req_valid && dut.sample_req_ready && dut.sample_rsp_valid && dut.sample_rsp_ready)
        overlap_samples=overlap_samples+1;
    always @(posedge clk) begin
        if(!rst && !abort && dut.engine_rst) begin
            if(in_ready || out_valid || cfg_ready || done || busy)
                $fatal(1,"registered abort reset did not isolate external interfaces");
        end
        if(!rst && !abort && !dut.engine_rst && dut.resize_out_valid && dut.resize_out_eof && dut.sampler_busy) begin
            tail_drain_cycles=tail_drain_cycles+1;
            if(out_valid || dut.resize_out_ready || done || !busy || cfg_ready)
                $fatal(1,"final pixel escaped source-tail drain fence");
        end
    end
    task automatic enter_tail_wait;
        integer tail_wait;
        begin
            manual_source_mode=0;
            set_config(config_count-1); // Last vector has constant y=1.5.
            if(cfg_y_step_q16!==0 || cfg_y_phase0_q16!==32'sh18000 || cfg_hin<=3)
                $fatal(1,"tail recovery fixture must sample fixed y=1.5 with unread trailing rows");
            prepare_source(config_count-1);
            pause_after_rows=3;
            compare_enable=0;
            current_output_handshakes=0;
            transact_config(0,0);
            tail_wait=0;
            while(!(dut.resize_out_valid && dut.resize_out_eof && dut.sampler_busy) && tail_wait<2000) begin
                @(negedge clk); tail_wait=tail_wait+1;
            end
            if(tail_wait==2000 || accepted_source_job!=3*source_width_q || auto_in_valid ||
               current_output_handshakes!=config_output_count[config_count-1]-1)
                $fatal(1,"could not isolate EOF waiting for source tail");
            repeat(8) begin
                @(negedge clk);
                if(!busy || done || out_valid || cfg_ready || error)
                    $fatal(1,"EOF wait did not remain stable while source paused");
            end
        end
    endtask
    integer job;
    initial begin
        load_vectors();
        repeat (6) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // Configuration handshake rejection paths remain restartable.
        cfg_win = 16'd0;
        cfg_hin = 16'd2;
        cfg_wout = 16'd2;
        cfg_hout = 16'd2;
        cfg_x_step_q16 = 32'sd65536;
        cfg_y_step_q16 = 32'sd65536;
        cfg_x_phase0_q16 = 32'sd0;
        cfg_y_phase0_q16 = 32'sd0;
        transact_config(1'b1, 4'd1);

        cfg_win = MAX_WIDTH + 1;
        transact_config(1'b1, 4'd1);

        cfg_win = 16'd2;
        cfg_y_step_q16 = -32'sd65536;
        transact_config(1'b1, 4'd7);

        // Runtime raster violation propagates through the wrapper.  Abort is
        // the specified recovery mechanism for an active faulted frame.
        set_config(1);
        manual_source_mode = 1'b1;
        transact_config(1'b0, 4'd0);
        while (!in_ready) @(negedge clk);
        @(negedge clk);
        manual_in_valid = 1'b1;
        manual_in_x = 16'd1;
        manual_in_y = 16'd0;
        manual_in_sof = 1'b1;
        manual_in_eol = 1'b0;
        manual_in_eof = 1'b0;
        manual_in_rgb = 24'habcdef;
        @(posedge clk);
        #1;
        @(negedge clk);
        manual_in_valid = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!error || error_code != 4'd2 || !busy || in_ready)
            $fatal(1, "pipeline did not propagate raster error");
        runtime_error_count = runtime_error_count + 1;
        abort_active_job();

        // Abort a live upsample after output has begun, while also proving a
        // second configuration is backpressured and cannot perturb the job.
        manual_source_mode = 1'b0;
        set_config(4);
        prepare_source(4);
        compare_enable = 1'b0;
        current_output_handshakes = 0;
        transact_config(1'b0, 4'd0);
        cfg_win = 16'd2;
        cfg_hin = 16'd2;
        cfg_wout = 16'd2;
        cfg_hout = 16'd2;
        cfg_x_step_q16 = 32'sd1;
        cfg_y_step_q16 = 32'sd1;
        cfg_x_phase0_q16 = 32'sd0;
        cfg_y_phase0_q16 = 32'sd0;
        cfg_valid = 1'b1;
        repeat (5) begin
            @(posedge clk);
            if (cfg_ready)
                $fatal(1, "pipeline accepted configuration while busy");
        end
        @(negedge clk);
        cfg_valid = 1'b0;
        while (current_output_handshakes < 3) @(negedge clk);
        abort_active_job();

        // Cancel specifically while the final RGB is held for unread rows.
        enter_tail_wait();
        abort_active_job();
        pause_after_rows=0;
        repeat(4) begin
            @(negedge clk);
            if(done || out_valid || busy) $fatal(1,"cancelled EOF leaked into next job");
        end
        // A malformed tail must not turn an already-computed EOF into success.
        enter_tail_wait();
        manual_source_mode=1;
        auto_source_enable=0;
        @(negedge clk);
        manual_in_x=1; manual_in_y=3; // Expected next pixel is (0,3).
        manual_in_sof=0; manual_in_eol=0; manual_in_eof=0;
        manual_in_rgb=24'h123456; manual_in_valid=1;
        do @(posedge clk); while(!in_ready);
        @(negedge clk); manual_in_valid=0;
        repeat(3) @(negedge clk);
        if(!error || error_code!=4'd2 || !busy || done || out_valid || in_ready || cfg_ready)
            $fatal(1,"malformed source tail escaped EOF error fence");
        runtime_error_count=runtime_error_count+1;
        abort_active_job();
        pause_after_rows=0;
        $display("C1_RESIZE_TAIL_RECOVERY_PASS cancel=1 malformed_tail=1");

        // Full restart from source coordinate (0,0), followed by every Golden
        // configuration under random input gaps and output backpressure.
        for (job = 0; job < config_count; job = job + 1)
            start_checked_job(job);

        repeat (10) @(posedge clk);
        if (compared_outputs != output_count)
            $fatal(1, "pipeline final output count mismatch");
        if (completed_jobs != config_count)
            $fatal(1, "pipeline done count mismatch");
        if (cfg_error_count != 3 || runtime_error_count != 2)
            $fatal(1, "pipeline error coverage mismatch cfg=%0d runtime=%0d",
                   cfg_error_count, runtime_error_count);
        if (abort_count != 4)
            $fatal(1, "pipeline abort coverage mismatch");
        if (config_stall_cycles == 0 || source_gap_cycles == 0 ||
            source_stall_cycles == 0 || output_stall_cycles == 0)
            $fatal(1,
                "pipeline stall coverage missing cfg=%0d gap=%0d src=%0d out=%0d",
                config_stall_cycles, source_gap_cycles,
                source_stall_cycles, output_stall_cycles);
        if (busy || error || out_valid || auto_source_enable || auto_in_valid)
            $fatal(1, "pipeline did not finish cleanly");
        if(overlap_samples==0)$fatal(1,"Resize overlap never occurred");
        $display("C30_RESIZE_OVERLAP_HANDSHAKE_PASS replacements=%0d old_metadata_retired=1",overlap_samples);
        if(tail_drain_cycles==0) $fatal(1,"source-tail drain scenario not exercised");
        $display("C1_RESIZE_SOURCE_TAIL_DRAIN_PASS cycles=%0d",tail_drain_cycles);

        $display(
            "C30_RESIZE_OVERLAP_PIPELINE_PASS configs=%0d outputs=%0d cfg_errors=%0d aborts=%0d",
            config_count, compared_outputs, cfg_error_count, abort_count);
        $finish;
    end

    initial begin
        repeat (600000) @(posedge clk);
        $fatal(1, "R1 resize pipeline regression timeout");
    end

endmodule
