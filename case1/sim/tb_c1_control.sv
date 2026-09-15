`timescale 1ns/1ps

module tb_c1_control;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [11:0] paddr = '0;
    logic [31:0] pwdata = '0;
    logic [3:0] pstrb = 4'hf;
    wire [31:0] prdata;
    wire pready, pslverr, irq;
    logic busy = 1'b0;
    logic done_event = 1'b0;
    logic error_event = 1'b0;
    logic capture_drop_event = 1'b0;
    logic display_swap_event = 1'b0;
    logic display_underflow_event = 1'b0;
    wire system_enable, continuous_mode, drop_oldest_mode;
    wire start_pulse, abort_pulse, clear_stats_pulse;
    wire [15:0] frame_width, frame_height;
    wire [31:0] input_stride_bytes, output_stride_bytes;
    wire [31:0] geometry_shadow[5];
    wire [3:0] input_pixel_format, output_pixel_format;
    wire [63:0] input_buffer_table_base, output_buffer_table_base;
    wire [63:0] descriptor_base, weight_base;
    wire [31:0] tensor_base_addr;
    wire [15:0] descriptor_count;
    wire [7:0] style_id, display_mode;

    logic abort = 1'b0;
    logic cap_frame_start = 1'b0;
    logic cap_frame_done = 1'b0;
    wire cap_accept_pulse, cap_drop_pulse;
    wire [1:0] cap_input_index;
    wire [31:0] cap_frame_id;
    logic nn_job_request = 1'b0;
    logic nn_done = 1'b0;
    wire nn_job_grant;
    wire [1:0] nn_input_index;
    wire nn_output_index;
    wire [31:0] nn_frame_id;
    logic display_vsync = 1'b0;
    wire fm_display_swap;
    wire [1:0] display_input_index;
    wire display_output_index;
    wire [31:0] display_frame_id;
    wire display_active;
    wire [2:0] input_ready_count;
    wire [1:0] output_ready_count;
    wire capture_active_out, nn_active_out;
    wire [31:0] dropped_frame_count;
    logic [31:0] read_value;

    always #5 clk = ~clk;

    c1_apb_csr u_csr (
        .input_frame_size(geometry_shadow[0]), .resize_x_step_q16(geometry_shadow[1]),
        .resize_y_step_q16(geometry_shadow[2]), .resize_x_phase0_q16(geometry_shadow[3]),
        .resize_y_phase0_q16(geometry_shadow[4]),
        .clk, .rst_n, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb,
        .prdata, .pready, .pslverr, .busy, .done_event, .error_event,
        .error_code_in(8'h00), .error_address_in(32'h0),
        .capture_drop_event, .display_swap_event, .display_underflow_event,
        .input_ready_count, .output_ready_count, .system_enable,
        .continuous_mode, .drop_oldest_mode, .start_pulse, .abort_pulse,
        .clear_stats_pulse, .frame_width, .frame_height, .input_stride_bytes,
        .output_stride_bytes, .input_pixel_format, .output_pixel_format,
        .input_buffer_table_base, .output_buffer_table_base, .descriptor_base,
        .descriptor_count, .style_id, .weight_base, .tensor_base_addr,
        .display_mode, .irq
    );

    c1_frame_manager u_frame_manager (
        .clk, .rst_n, .abort, .drop_oldest_mode, .cap_frame_start,
        .cap_frame_done, .cap_accept_pulse, .cap_drop_pulse, .cap_input_index,
        .cap_frame_id, .nn_job_request, .nn_done, .nn_job_grant,
        .nn_input_index, .nn_output_index, .nn_frame_id, .display_vsync,
        .display_swap_pulse(fm_display_swap), .display_input_index,
        .display_output_index, .display_frame_id, .display_active,
        .input_ready_count, .output_ready_count, .capture_active_out,
        .nn_active_out, .dropped_frame_count
    );

    task automatic apb_write(input logic [11:0] address, input logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1; paddr = address; pwdata = data;
            @(negedge clk);
            penable = 1'b1;
            #1;
            if (!pready || pslverr) $fatal(1,"unexpected APB write failure addr=%h",address);
            @(negedge clk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task automatic apb_read(input logic [11:0] address, output logic [31:0] data);
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = address;
            @(negedge clk);
            penable = 1'b1;
            #1 data = prdata;
            if (!pready || pslverr) $fatal(1,"unexpected APB read failure addr=%h",address);
            @(negedge clk);
            psel = 1'b0; penable = 1'b0;
        end
    endtask

    task automatic apb_write_expect_error(
        input logic [11:0] address,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            paddr = address; pwdata = data;
            @(negedge clk);
            penable = 1'b1;
            #1;
            if (!pready || !pslverr)
                $fatal(1, "expected APB write error was not reported");
            @(negedge clk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task automatic pulse_capture_start;
        begin
            @(negedge clk); cap_frame_start = 1'b1;
            @(negedge clk); cap_frame_start = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        begin : geometry_registers
            integer r, mask, b;
            logic [31:0] expected, payload;
            for (r=0;r<5;r++) begin
                expected=(r==1 || r==2) ? 32'h00010000 : 0;
                apb_read(12'h060+r*4,read_value);
                if(read_value!==expected || geometry_shadow[r]!==expected)
                    $fatal(1,"geometry reset mismatch r=%0d",r);
                busy=1;
                for(mask=0;mask<16;mask++) begin
                    payload=32'hfedcba98 ^ (mask*32'h01020304);
                    pstrb=mask;
                    apb_write(12'h060+r*4,payload);
                    for(b=0;b<4;b++) if(mask & (1<<b)) expected[b*8+:8]=payload[b*8+:8];
                    apb_read(12'h060+r*4,read_value);
                    if(read_value!==expected || geometry_shadow[r]!==expected || start_pulse || abort_pulse)
                        $fatal(1,"geometry shadow mask mismatch r=%0d mask=%h",r,mask);
                end
                pstrb=15;
                apb_write_expect_error(12'h061+r*4,32'h12345678);
                apb_read(12'h060+r*4,read_value);
                if(read_value!==expected) $fatal(1,"unaligned write modified geometry");
                busy=0;
            end
            @(negedge clk);rst_n=0;
            repeat(3) @(negedge clk);
            rst_n=1;
            for(r=0;r<5;r++) begin
                apb_read(12'h060+r*4,read_value);
                if(read_value!==((r==1 || r==2) ? 32'h00010000 : 0))
                    $fatal(1,"geometry reset after programming failed");
            end
            $display("C1_CSR_GEOMETRY_SHADOW_PASS registers=5 masks=80 busy_write=1 unaligned=5 reset=1");
        end
        apb_read(12'h000, read_value);
        if (read_value !== 32'h4331_5254) $fatal(1, "CSR ID mismatch");
        apb_write(12'h050, 32'h01e0_0280);
        if (frame_width !== 16'd640 || frame_height !== 16'd480)
            $fatal(1, "CSR frame size write failed");
        apb_write(12'h098, 32'h0200_0000);
        apb_read(12'h098, read_value);
        if ((read_value !== 32'h0200_0000) ||
            (tensor_base_addr !== 32'h0200_0000))
            $fatal(1, "CSR tensor arena write/read failed");
        apb_write(12'h010, 32'h0000_001b);
        if (!system_enable || !continuous_mode || !drop_oldest_mode || !start_pulse)
            $fatal(1, "CSR control write/pulse failed");

        // A second START while foreground busy must fail atomically.  In
        // particular, the rejected transfer must not overwrite persistent
        // enable/mode bits or emit another start pulse.
        busy = 1'b1;
        apb_write_expect_error(12'h010, 32'h0000_0002);
        if (!system_enable || !continuous_mode || !drop_oldest_mode ||
            start_pulse)
            $fatal(1, "busy START changed CSR control state");
        busy = 1'b0;

        @(negedge clk); done_event = 1'b1;
        @(negedge clk); done_event = 1'b0;
        apb_read(12'h01c, read_value);
        if ((read_value & 32'h1) == 0) $fatal(1, "CSR done IRQ did not latch");
        apb_read(12'h100, read_value);
        if (read_value !== 32'd1) $fatal(1, "CSR frame counter mismatch");
        apb_write(12'h01c, 32'h1);
        apb_read(12'h01c, read_value);
        if ((read_value & 32'h1) != 0) $fatal(1, "CSR W1C failed");

        pulse_capture_start();
        if (!cap_accept_pulse || cap_input_index !== 2'd0 || cap_frame_id !== 32'd0)
            $fatal(1, "frame manager capture allocation failed");
        @(negedge clk); cap_frame_done = 1'b1;
        @(negedge clk); cap_frame_done = 1'b0;
        if (input_ready_count !== 3'd1) $fatal(1, "capture completion not queued");

        @(negedge clk); nn_job_request = 1'b1;
        @(negedge clk); nn_job_request = 1'b0;
        if (!nn_job_grant || nn_input_index !== 2'd0 || nn_output_index !== 1'b0 ||
            nn_frame_id !== 32'd0)
            $fatal(1, "frame manager NN grant failed");
        @(negedge clk); nn_done = 1'b1;
        @(negedge clk); nn_done = 1'b0;
        if (output_ready_count !== 2'd1) $fatal(1, "NN completion not queued");

        @(negedge clk); display_vsync = 1'b1;
        @(negedge clk); display_vsync = 1'b0;
        if (!fm_display_swap || !display_active || display_input_index !== 2'd0 ||
            display_output_index !== 1'b0 || display_frame_id !== 32'd0)
            $fatal(1, "frame manager display swap failed");

        repeat (3) @(negedge clk);
        $display("C1_CONTROL_PASS frame_id=%0d drops=%0d", display_frame_id, dropped_frame_count);
        $finish;
    end

    initial begin
        repeat (2000) @(negedge clk);
        $fatal(1, "control test timeout");
    end
endmodule
