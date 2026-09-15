`timescale 1ns/1ps

module tb_c1_r1_microstyle_bridge_fault_boundary;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [15:0] stage_count = 16'd22;
    logic [7:0] config_generation = 8'd7;
    logic parameter_active_valid = 1'b1;
    logic [31:0] parameter_generation = 32'd100;
    logic busy;
    logic done;
    logic aborted;
    logic error;
    logic [7:0] error_code;

    logic stage_config_valid = 1'b0;
    logic stage_config_ready;
    logic [15:0] stage_config_index = 16'd0;
    logic [511:0] stage_config_descriptor = 512'd0;
    logic [7:0] stage_config_generation = 8'd7;

    logic param_rd_en;
    logic [10:0] param_rd_addr;
    logic param_rd_valid = 1'b0;
    logic param_rd_error = 1'b0;
    logic [127:0] param_rd_data = 128'd0;

    logic board_in_valid = 1'b0;
    logic board_in_ready;
    logic [63:0] board_in_data_s8 = 64'd0;
    logic [15:0] board_in_x = 16'd0;
    logic [15:0] board_in_y = 16'd0;
    logic board_in_sof = 1'b0;
    logic board_in_eol = 1'b0;
    logic board_in_eof = 1'b0;
    logic board_out_valid;
    logic board_out_ready = 1'b1;
    logic [63:0] board_out_data_s8;
    logic [15:0] board_out_x;
    logic [15:0] board_out_y;
    logic board_out_sof;
    logic board_out_eol;
    logic board_out_eof;

    logic adapter_start_valid;
    logic adapter_start_ready = 1'b1;
    logic adapter_abort;
    logic adapter_stage_config_valid;
    logic adapter_stage_config_ready = 1'b1;
    logic [15:0] adapter_stage_config_index;
    logic [511:0] adapter_stage_config_descriptor;
    logic [7:0] adapter_stage_config_generation;
    logic adapter_error = 1'b0;
    logic [7:0] adapter_error_code = 8'd0;

    logic adapter_source_valid;
    logic adapter_source_ready = 1'b1;
    logic [63:0] adapter_source_data_s8;
    logic [15:0] adapter_source_x;
    logic [15:0] adapter_source_y;
    logic adapter_source_sof;
    logic adapter_source_eol;
    logic adapter_source_eof;

    logic adapter_engine_valid = 1'b0;
    logic adapter_engine_ready;
    logic [575:0] adapter_engine_window_s8 = 576'd0;
    logic [63:0] adapter_engine_residual_s8 = 64'd0;
    logic [2:0] adapter_engine_group_index = 3'd0;
    logic adapter_engine_group_last = 1'b0;
    logic [15:0] adapter_engine_x = 16'd0;
    logic [15:0] adapter_engine_y = 16'd0;
    logic adapter_engine_sof = 1'b0;
    logic adapter_engine_eol = 1'b0;
    logic adapter_engine_eof = 1'b0;

    logic adapter_result_valid;
    logic adapter_result_ready = 1'b1;
    logic [63:0] adapter_result_data_s8;
    logic [2:0] adapter_result_group_index;
    logic adapter_result_group_last;
    logic [15:0] adapter_result_x;
    logic [15:0] adapter_result_y;
    logic adapter_result_sof;
    logic adapter_result_eol;
    logic adapter_result_eof;

    logic adapter_final_valid = 1'b0;
    logic adapter_final_ready;
    logic [63:0] adapter_final_data_s8 = 64'h0102_0304_0506_0708;
    logic [15:0] adapter_final_x = 16'd3;
    logic [15:0] adapter_final_y = 16'd4;
    logic adapter_final_sof = 1'b0;
    logic adapter_final_eol = 1'b0;
    logic adapter_final_eof = 1'b0;

    logic [4:0] engine_stage_index;
    logic [7:0] engine_stage_opcode;
    logic engine_stage_active;
    logic engine_adapter_required;
    logic engine_stage_done;
    logic engine_overflow_seen;
    logic config_capture_complete;

    integer board_fire_count = 0;
    integer baseline_fire_count;

    always #5 clk = ~clk;

    c1_r1_microstyle_system_bridge #(
        .REQUIRED_STAGES(22),
        .PARAM_ADDR_W(11),
        .PIPELINED_DOT_TREE_FULL(1)
    ) dut (.*);

    always @(posedge clk) begin
        if (board_out_valid && board_out_ready)
            board_fire_count <= board_fire_count + 1;
    end

    task automatic pulse_start;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!start_ready && wait_cycles < 20) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!start_ready)
                $fatal(1, "bridge did not become start-ready");
            start_valid = 1'b1;
            @(negedge clk);
            start_valid = 1'b0;
            wait_cycles = 0;
            while (dut.start_pending_q && wait_cycles < 20) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!busy || dut.start_pending_q)
                $fatal(1, "bridge did not complete two-sink launch");
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(negedge clk);
            abort = 1'b0;
            repeat (2) @(negedge clk);
            if (error || busy)
                $fatal(1, "bridge did not clear sticky fault on abort");
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (3) @(negedge clk);

        // Parameter-generation mutation while a final beat is already
        // present.  The live comparator must detect it immediately, while the
        // public error gate changes only after the sticky verdict is captured.
        pulse_start();
        adapter_final_valid = 1'b1;
        repeat (2) @(negedge clk);
        if (!adapter_final_ready || !board_out_valid || error)
            $fatal(1, "bridge output was not flowing before fault injection");
        baseline_fire_count = board_fire_count;

        parameter_generation = 32'd101;
        #1;
        if (!dut.start_contract_fault)
            $fatal(1, "live parameter-generation fault was not detected");
        if (error || !adapter_final_ready || !board_out_valid)
            $fatal(1, "registered contract-fault boundary leaked combinationally");

        @(posedge clk);
        #1;
        if (!error || error_code !== 8'h04)
            $fatal(1, "registered parameter-generation fault/code missing");
        if(!busy) $fatal(1,"active contract fault unexpectedly cleared job ownership");
        if (adapter_final_ready || board_out_valid)
            $fatal(1, "sticky contract fault did not stop output transfer");
        if (board_fire_count != baseline_fire_count + 1)
            $fatal(1, "fault-capture edge did not retire exactly one in-flight beat");

        repeat (2) @(posedge clk);
        #1;
        if (board_fire_count != baseline_fire_count + 1 || !error)
            $fatal(1, "output advanced after sticky contract fault");
        adapter_final_valid = 1'b0;
        pulse_abort();
        parameter_generation = 32'd100;

        // The stage/config generation comparison shares the same registered
        // boundary but must retain its distinct error code.
        pulse_start();
        config_generation = 8'd8;
        #1;
        if (!dut.start_contract_fault || error)
            $fatal(1, "config-generation fault boundary is not one-cycle");
        @(posedge clk);
        #1;
        if (!error || error_code !== 8'h03)
            $fatal(1, "registered config-generation fault/code missing");
        pulse_abort();
        config_generation = 8'd7;

        // A canceled adapter may drain a late error response AFTER the
        // one-cycle global abort. That diagnostic is still visible, but it
        // must never resurrect bridge job ownership after the abort reset.
        for(integer delay_cycles=0;delay_cycles<=6;delay_cycles+=3) begin
            pulse_start();pulse_abort();
            repeat(delay_cycles) @(negedge clk);
            adapter_error=1;adapter_error_code=7;
            repeat(5) begin
                @(posedge clk);#1;
                // START_READY advertises the existing one-entry launch
                // buffer, not child quiescence; preserve that fanout ABI.
                if(!error || error_code!=8'h67 || busy || dut.active_q || adapter_start_valid || dut.cnn_start_valid)
                    $fatal(1,"late canceled-adapter error lifecycle mismatch delay=%0d error=%b code=%h busy=%b active=%b start_ready=%b cnn_busy=%b",
                        delay_cycles,error,error_code,busy,dut.active_q,start_ready,dut.cnn_busy);
            end
            @(negedge clk);adapter_error=0;adapter_error_code=0;
            @(negedge clk);
            if(busy || error || !start_ready) $fatal(1,"late error release did not permit no-reset restart");
            $display("C1_BRIDGE_LATE_ABORT_ERROR_PASS delay=%0d diagnostic=1 no_reactivation=1 reset=0",delay_cycles);
        end

        repeat (3) @(negedge clk);
        $display("C1_R1_MICROSTYLE_BRIDGE_FAULT_BOUNDARY_PASS fires=%0d",
                 board_fire_count);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $fatal(1, "microstyle bridge fault-boundary timeout");
    end
endmodule
