`timescale 1ns/1ps

module tb_c1_frame_manager_ready_fifo;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic abort = 1'b0;
    logic drop_oldest_mode = 1'b1;
    logic cap_frame_start = 1'b0;
    logic cap_frame_done = 1'b0;
    logic nn_job_request = 1'b0;
    logic nn_done = 1'b0;
    logic display_vsync = 1'b0;

    wire        cap_accept_pulse;
    wire        cap_drop_pulse;
    wire [1:0]  cap_input_index;
    wire [31:0] cap_frame_id;
    wire        nn_job_grant;
    wire [1:0]  nn_input_index;
    wire        nn_output_index;
    wire [31:0] nn_frame_id;
    wire        display_swap_pulse;
    wire [1:0]  display_input_index;
    wire        display_output_index;
    wire [31:0] display_frame_id;
    wire        display_active;
    wire [2:0]  input_ready_count;
    wire [1:0]  output_ready_count;
    wire        capture_active_out;
    wire        nn_active_out;
    wire [31:0] dropped_frame_count;

    always #5 clk = ~clk;

    c1_frame_manager dut (
        .clk,
        .rst_n,
        .abort,
        .drop_oldest_mode,
        .cap_frame_start,
        .cap_frame_done,
        .cap_accept_pulse,
        .cap_drop_pulse,
        .cap_input_index,
        .cap_frame_id,
        .nn_job_request,
        .nn_done,
        .nn_job_grant,
        .nn_input_index,
        .nn_output_index,
        .nn_frame_id,
        .display_vsync,
        .display_swap_pulse,
        .display_input_index,
        .display_output_index,
        .display_frame_id,
        .display_active,
        .input_ready_count,
        .output_ready_count,
        .capture_active_out,
        .nn_active_out,
        .dropped_frame_count
    );

    task automatic allocate_capture(
        input logic [1:0] expected_index,
        input logic [31:0] expected_id,
        input logic expected_drop
    );
        begin
            @(negedge clk);
            cap_frame_start = 1'b1;
            @(negedge clk);
            cap_frame_start = 1'b0;
            if (!cap_accept_pulse || cap_input_index !== expected_index ||
                cap_frame_id !== expected_id || cap_drop_pulse !== expected_drop)
                $fatal(1, "capture allocation mismatch idx=%0d id=%0d drop=%0b",
                       cap_input_index, cap_frame_id, cap_drop_pulse);
        end
    endtask

    task automatic complete_capture;
        begin
            @(negedge clk);
            cap_frame_done = 1'b1;
            @(negedge clk);
            cap_frame_done = 1'b0;
        end
    endtask

    task automatic request_nn(
        input logic [1:0] expected_input,
        input logic expected_output,
        input logic [31:0] expected_id
    );
        begin
            @(negedge clk);
            nn_job_request = 1'b1;
            @(negedge clk);
            nn_job_request = 1'b0;
            if (!nn_job_grant || nn_input_index !== expected_input ||
                nn_output_index !== expected_output || nn_frame_id !== expected_id)
                $fatal(1, "NN grant mismatch in=%0d out=%0d id=%0d",
                       nn_input_index, nn_output_index, nn_frame_id);
        end
    endtask

    task automatic complete_nn;
        begin
            @(negedge clk);
            nn_done = 1'b1;
            @(negedge clk);
            nn_done = 1'b0;
        end
    endtask

    task automatic swap_display(
        input logic [1:0] expected_input,
        input logic expected_output,
        input logic [31:0] expected_id
    );
        begin
            @(negedge clk);
            display_vsync = 1'b1;
            @(negedge clk);
            display_vsync = 1'b0;
            if (!display_swap_pulse || display_input_index !== expected_input ||
                display_output_index !== expected_output ||
                display_frame_id !== expected_id)
                $fatal(1, "display swap mismatch in=%0d out=%0d id=%0d",
                       display_input_index, display_output_index, display_frame_id);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Fill all three READY input slots in capture/frame order.
        allocate_capture(2'd0, 32'd0, 1'b0);
        complete_capture();
        allocate_capture(2'd1, 32'd1, 1'b0);
        complete_capture();
        allocate_capture(2'd2, 32'd2, 1'b0);
        complete_capture();
        if (input_ready_count !== 3'd3)
            $fatal(1, "three input READY slots were not queued");

        // No slot is free: frame 0 must be dropped and slot 0 recycled.
        allocate_capture(2'd0, 32'd3, 1'b1);
        if (input_ready_count !== 3'd2 || dropped_frame_count !== 32'd1)
            $fatal(1, "drop-oldest did not pop exactly one READY slot");
        complete_capture();
        if (input_ready_count !== 3'd3)
            $fatal(1, "recycled capture was not appended");

        // FIFO order after replacement is frame 1, frame 2, frame 3.
        request_nn(2'd1, 1'b0, 32'd1);
        if (input_ready_count !== 3'd2)
            $fatal(1, "NN grant did not pop input READY head");

        // While frame 1 executes, recycle frame 2 for frame 4.
        allocate_capture(2'd2, 32'd4, 1'b1);
        if (input_ready_count !== 3'd1 || dropped_frame_count !== 32'd2)
            $fatal(1, "second drop-oldest sequence failed");
        complete_nn();
        if (output_ready_count !== 2'd1)
            $fatal(1, "frame 1 output was not queued");

        // Complete frame 4 capture while granting frame 3: input pop+push.
        @(negedge clk);
        cap_frame_done = 1'b1;
        nn_job_request = 1'b1;
        @(negedge clk);
        cap_frame_done = 1'b0;
        nn_job_request = 1'b0;
        if (!nn_job_grant || nn_input_index !== 2'd0 ||
            nn_output_index !== 1'b1 || nn_frame_id !== 32'd3)
            $fatal(1, "simultaneous input READY pop/push grant mismatch");
        if (input_ready_count !== 3'd1 || dut.input_ready_q0 !== 2'd2)
            $fatal(1, "simultaneous input READY pop/push queue mismatch");

        // Complete frame 3 while displaying frame 1: output pop+push.
        @(negedge clk);
        nn_done = 1'b1;
        display_vsync = 1'b1;
        @(negedge clk);
        nn_done = 1'b0;
        display_vsync = 1'b0;
        if (!display_swap_pulse || display_input_index !== 2'd1 ||
            display_output_index !== 1'b0 || display_frame_id !== 32'd1)
            $fatal(1, "simultaneous output READY pop/push display mismatch");
        if (output_ready_count !== 2'd1 || dut.output_ready_q0 !== 1'b1)
            $fatal(1, "simultaneous output READY pop/push queue mismatch");

        swap_display(2'd0, 1'b1, 32'd3);
        if (output_ready_count !== 2'd0 || input_ready_count !== 3'd1)
            $fatal(1, "frame 3 display did not release prior ownership");

        request_nn(2'd2, 1'b0, 32'd4);
        complete_nn();
        swap_display(2'd2, 1'b0, 32'd4);

        // Abort must discard queued/non-display ownership while preserving the
        // frame currently referenced by display.
        allocate_capture(2'd0, 32'd5, 1'b0);
        complete_capture();
        if (input_ready_count !== 3'd1)
            $fatal(1, "abort setup capture was not queued");
        @(negedge clk);
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        if (input_ready_count !== 3'd0 || output_ready_count !== 2'd0 ||
            capture_active_out || nn_active_out || !display_active ||
            display_input_index !== 2'd2 || display_output_index !== 1'b0 ||
            display_frame_id !== 32'd4)
            $fatal(1, "abort did not clear queues while preserving display");

        repeat (3) @(negedge clk);
        $display("C1_FRAME_MANAGER_READY_FIFO_PASS drops=%0d display_id=%0d",
                 dropped_frame_count, display_frame_id);
        $finish;
    end

    initial begin
        repeat (1000) @(negedge clk);
        $fatal(1, "frame-manager READY FIFO test timeout");
    end
endmodule

