`timescale 1ns/1ps

module tb_c1_frame_pair_resolver;

    localparam integer MAX_MEMORY_ENTRIES = 64;

    localparam logic [7:0] ERR_INPUT_INDEX       = 8'h01;
    localparam logic [7:0] ERR_OUTPUT_INDEX      = 8'h02;
    localparam logic [7:0] ERR_ZERO_DIMENSION    = 8'h03;
    localparam logic [7:0] ERR_INPUT_TABLE_READ  = 8'h10;
    localparam logic [7:0] ERR_OUTPUT_TABLE_READ = 8'h11;
    localparam logic [7:0] ERR_INPUT_BASE_RANGE  = 8'h20;
    localparam logic [7:0] ERR_OUTPUT_BASE_RANGE = 8'h21;
    localparam logic [7:0] ERR_INPUT_BASE_ALIGN  = 8'h22;
    localparam logic [7:0] ERR_OUTPUT_BASE_ALIGN = 8'h23;
    localparam logic [7:0] ERR_INPUT_DIMENSION   = 8'h24;
    localparam logic [7:0] ERR_OUTPUT_DIMENSION  = 8'h25;
    localparam logic [7:0] ERR_INPUT_STRIDE      = 8'h26;
    localparam logic [7:0] ERR_OUTPUT_STRIDE     = 8'h27;
    localparam logic [7:0] ERR_INPUT_EXTENT      = 8'h28;
    localparam logic [7:0] ERR_OUTPUT_EXTENT     = 8'h29;
    localparam logic [7:0] ERR_ACTIVE_OVERLAP    = 8'h30;

    localparam logic [63:0] TABLE_INPUT_GOOD = 64'h0000_0000_0000_1000;
    localparam logic [63:0] TABLE_OUTPUT_GOOD = 64'h0000_0000_0000_2000;
    localparam logic [63:0] TABLE_OUTPUT_TOUCH = 64'h0000_0000_0000_3000;
    localparam logic [63:0] TABLE_OUTPUT_OVERLAP = 64'h0000_0000_0000_3100;
    localparam logic [63:0] TABLE_OUTPUT_CROSS = 64'h0000_0000_0000_3200;
    localparam logic [63:0] TABLE_HIGH_BASE = 64'h0000_0000_0000_4000;
    localparam logic [63:0] TABLE_ALIGN_BASE = 64'h0000_0000_0000_4100;
    localparam logic [63:0] TABLE_DIMENSION = 64'h0000_0000_0000_4200;
    localparam logic [63:0] TABLE_STRIDE_SMALL = 64'h0000_0000_0000_4300;
    localparam logic [63:0] TABLE_STRIDE_UNALIGNED = 64'h0000_0000_0000_4400;
    localparam logic [63:0] TABLE_EXTENT = 64'h0000_0000_0000_4500;
    localparam logic [63:0] TABLE_HEIGHT2_LEGAL = 64'h0000_0000_0000_4600;
    localparam logic [63:0] TABLE_EXTENT_BOUNDARY = 64'h0000_0000_0000_4700;
    localparam logic [63:0] TABLE_EXTENT_HIGH_BIT = 64'h0000_0000_0000_4800;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic abort = 1'b0;

    logic start_valid = 1'b0;
    logic start_ready;
    logic [63:0] input_table_base = '0;
    logic [63:0] output_table_base = '0;
    logic [1:0] input_buffer_index = '0;
    logic [1:0] output_buffer_index = '0;
    logic [15:0] expected_width_pixels = '0;
    logic [15:0] expected_height_lines = '0;
    wire [15:0] expected_input_width_pixels=16'd0;
    wire [15:0] expected_input_height_lines=16'd0;

    logic response_valid;
    logic response_ready = 1'b0;
    logic response_error;
    logic [7:0] response_error_code;
    logic [31:0] response_error_address;
    logic [31:0] resolved_input_base;
    logic [31:0] resolved_input_stride;
    logic [15:0] resolved_input_width;
    logic [15:0] resolved_input_height;
    logic [31:0] resolved_output_base;
    logic [31:0] resolved_output_stride;
    logic [15:0] resolved_output_width;
    logic [15:0] resolved_output_height;
    logic busy;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready = 1'b0;
    logic [127:0] m_axi_rdata = '0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;

    logic [31:0] memory_address [0:MAX_MEMORY_ENTRIES-1];
    logic [127:0] memory_raw [0:MAX_MEMORY_ENTRIES-1];
    integer memory_count = 0;

    logic [31:0] prng = 32'h73ad_91e5;
    logic force_ar_block = 1'b0;
    logic force_r_block = 1'b0;
    logic force_response_block = 1'b0;

    logic next_expect_response;
    logic next_expect_error;
    logic [7:0] next_error_code;
    logic [31:0] next_error_address;
    logic [31:0] next_input_base;
    logic [31:0] next_input_stride;
    logic [15:0] next_input_width;
    logic [15:0] next_input_height;
    logic [31:0] next_output_base;
    logic [31:0] next_output_stride;
    logic [15:0] next_output_width;
    logic [15:0] next_output_height;
    integer next_inject_stage;
    logic [1:0] next_inject_rresp;
    logic next_inject_rlast;
    logic [31:0] next_input_araddr;
    logic [31:0] next_output_araddr;

    logic captured_expect_response;
    logic captured_expect_error;
    logic [7:0] captured_error_code;
    logic [31:0] captured_error_address;
    logic [31:0] captured_input_base;
    logic [31:0] captured_input_stride;
    logic [15:0] captured_input_width;
    logic [15:0] captured_input_height;
    logic [31:0] captured_output_base;
    logic [31:0] captured_output_stride;
    logic [15:0] captured_output_width;
    logic [15:0] captured_output_height;
    integer captured_inject_stage;
    logic [1:0] captured_inject_rresp;
    logic captured_inject_rlast;
    logic [31:0] captured_input_araddr;
    logic [31:0] captured_output_araddr;
    logic operation_waiting;
    integer operation_ar_stage;

    logic slave_active;
    logic [127:0] slave_raw;
    logic [3:0] slave_delay;
    logic [1:0] slave_rresp;
    logic slave_rlast;

    logic response_hold_active;
    logic held_response_error;
    logic [7:0] held_error_code;
    logic [31:0] held_error_address;
    logic [191:0] held_resolved_payload;
    logic ar_hold_active;
    logic [31:0] held_araddr;
    logic [7:0] held_arlen;
    logic [2:0] held_arsize;
    logic [1:0] held_arburst;

    integer accepted_count = 0;
    integer response_count = 0;
    integer success_count = 0;
    integer error_count = 0;
    integer abort_count = 0;
    integer restart_count = 0;
    integer ar_count = 0;
    integer r_count = 0;
    integer ar_stall_count = 0;
    integer r_delay_count = 0;
    integer response_stall_count = 0;
    integer overlap_error_count = 0;
    integer random_case;
    integer start_response_count;
    integer start_ar_count;
    integer start_r_count;

    always #5 clk = ~clk;

    c1_frame_pair_resolver dut (.*);

    function automatic [127:0] pack_entry(
        input logic [63:0] base_address,
        input logic [31:0] stride_bytes,
        input logic [15:0] width_pixels,
        input logic [15:0] height_lines
    );
        begin
            pack_entry = {height_lines, width_pixels, stride_bytes, base_address};
        end
    endfunction

    function automatic logic address_present(input logic [31:0] address);
        integer index;
        begin
            address_present = 1'b0;
            for (index = 0; index < memory_count; index = index + 1)
                if (memory_address[index] == address)
                    address_present = 1'b1;
        end
    endfunction

    function automatic [127:0] lookup_raw(input logic [31:0] address);
        integer index;
        begin
            lookup_raw = 128'd0;
            for (index = 0; index < memory_count; index = index + 1)
                if (memory_address[index] == address)
                    lookup_raw = memory_raw[index];
        end
    endfunction

    task automatic add_entry(
        input logic [31:0] address,
        input logic [127:0] raw
    );
        begin
            if (memory_count >= MAX_MEMORY_ENTRIES)
                $fatal(1, "frame-pair test memory overflow");
            memory_address[memory_count] = address;
            memory_raw[memory_count] = raw;
            memory_count = memory_count + 1;
        end
    endtask

    task automatic issue_pair(
        input logic [63:0] input_table,
        input logic [63:0] output_table,
        input logic [1:0] input_index,
        input logic [1:0] output_index,
        input logic [15:0] width_value,
        input logic [15:0] height_value,
        input logic expect_response_value,
        input logic expect_error_value,
        input logic [7:0] error_code_value,
        input logic [31:0] error_address_value,
        input logic [31:0] input_base_value,
        input logic [31:0] input_stride_value,
        input logic [31:0] output_base_value,
        input logic [31:0] output_stride_value,
        input integer inject_stage_value,
        input logic [1:0] inject_rresp_value,
        input logic inject_rlast_value
    );
        integer guard;
        begin
            @(negedge clk);
            if (operation_waiting || start_valid)
                $fatal(1, "overlapping frame-pair operation");

            next_expect_response = expect_response_value;
            next_expect_error = expect_error_value;
            next_error_code = error_code_value;
            next_error_address = error_address_value;
            next_input_base = input_base_value;
            next_input_stride = input_stride_value;
            next_input_width = width_value;
            next_input_height = height_value;
            next_output_base = output_base_value;
            next_output_stride = output_stride_value;
            next_output_width = width_value;
            next_output_height = height_value;
            next_inject_stage = inject_stage_value;
            next_inject_rresp = inject_rresp_value;
            next_inject_rlast = inject_rlast_value;
            next_input_araddr = input_table[31:0] +
                                ({30'd0, input_index} << 4);
            next_output_araddr = output_table[31:0] +
                                 ({30'd0, output_index} << 4);

            input_table_base = input_table;
            output_table_base = output_table;
            input_buffer_index = input_index;
            output_buffer_index = output_index;
            expected_width_pixels = width_value;
            expected_height_lines = height_value;
            start_valid = 1'b1;

            guard = 0;
            while (!(start_valid && start_ready)) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 5000) $fatal(1, "frame-pair start timeout");
            end

            @(negedge clk);
            start_valid = 1'b0;
            input_table_base = input_table ^ 64'h55aa_0000_0ff0_00f0;
            output_table_base = output_table ^ 64'haa55_0000_f00f_0f00;
            input_buffer_index = input_index ^ 2'b11;
            output_buffer_index = output_index ^ 2'b11;
            expected_width_pixels = width_value ^ 16'h55aa;
            expected_height_lines = height_value ^ 16'haa55;
        end
    endtask

    task automatic wait_response(input integer target);
        integer guard;
        begin
            guard = 0;
            while (response_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000) $fatal(1, "frame-pair response timeout");
            end
        end
    endtask

    task automatic wait_ar(input integer target);
        integer guard;
        begin
            guard = 0;
            while (ar_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "frame-pair AR timeout");
            end
        end
    endtask

    task automatic wait_r(input integer target);
        integer guard;
        begin
            guard = 0;
            while (r_count < target) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000) $fatal(1, "frame-pair R timeout");
            end
        end
    endtask

    task automatic wait_idle;
        integer guard;
        begin
            guard = 0;
            while (!start_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000) $fatal(1, "frame-pair idle timeout");
            end
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort = 1'b0;
            abort_count = abort_count + 1;
        end
    endtask

    // Operation-side scoreboard and response stability.
    always @(posedge clk) begin
        if (rst) begin
            operation_waiting = 1'b0;
            operation_ar_stage = 0;
            response_hold_active = 1'b0;
        end else begin
            if (start_valid && start_ready) begin
                if (operation_waiting)
                    $fatal(1, "resolver accepted more than one operation");
                operation_waiting = 1'b1;
                operation_ar_stage = 0;
                accepted_count = accepted_count + 1;
                captured_expect_response = next_expect_response;
                captured_expect_error = next_expect_error;
                captured_error_code = next_error_code;
                captured_error_address = next_error_address;
                captured_input_base = next_input_base;
                captured_input_stride = next_input_stride;
                captured_input_width = next_input_width;
                captured_input_height = next_input_height;
                captured_output_base = next_output_base;
                captured_output_stride = next_output_stride;
                captured_output_width = next_output_width;
                captured_output_height = next_output_height;
                captured_inject_stage = next_inject_stage;
                captured_inject_rresp = next_inject_rresp;
                captured_inject_rlast = next_inject_rlast;
                captured_input_araddr = next_input_araddr;
                captured_output_araddr = next_output_araddr;
            end

            if (abort)
                operation_waiting = 1'b0;

            if (response_valid && response_ready) begin
                if (!operation_waiting || !captured_expect_response)
                    $fatal(1, "stale frame-pair response");
                if ((response_error !== captured_expect_error) ||
                    (response_error_code !== captured_error_code) ||
                    (response_error_address !== captured_error_address)) begin
                    $fatal(1, "frame-pair error result mismatch expected=%02x/%08x got=%02x/%08x",
                           captured_error_code, captured_error_address,
                           response_error_code, response_error_address);
                end
                if (!captured_expect_error) begin
                    if ((resolved_input_base !== captured_input_base) ||
                        (resolved_input_stride !== captured_input_stride) ||
                        (resolved_input_width !== captured_input_width) ||
                        (resolved_input_height !== captured_input_height) ||
                        (resolved_output_base !== captured_output_base) ||
                        (resolved_output_stride !== captured_output_stride) ||
                        (resolved_output_width !== captured_output_width) ||
                        (resolved_output_height !== captured_output_height)) begin
                        $fatal(1, "resolved frame-pair payload mismatch");
                    end
                    success_count = success_count + 1;
                end else begin
                    error_count = error_count + 1;
                    if (response_error_code == ERR_ACTIVE_OVERLAP)
                        overlap_error_count = overlap_error_count + 1;
                end
                response_count = response_count + 1;
                operation_waiting = 1'b0;
            end

            if (response_valid && !response_ready) begin
                if (response_hold_active) begin
                    if ((response_error !== held_response_error) ||
                        (response_error_code !== held_error_code) ||
                        (response_error_address !== held_error_address) ||
                        ({resolved_input_base, resolved_input_stride,
                          resolved_input_width, resolved_input_height,
                          resolved_output_base, resolved_output_stride,
                          resolved_output_width, resolved_output_height} !==
                         held_resolved_payload)) begin
                        $fatal(1, "frame-pair response changed under backpressure");
                    end
                end
                response_hold_active = 1'b1;
                held_response_error = response_error;
                held_error_code = response_error_code;
                held_error_address = response_error_address;
                held_resolved_payload =
                    {resolved_input_base, resolved_input_stride,
                     resolved_input_width, resolved_input_height,
                     resolved_output_base, resolved_output_stride,
                     resolved_output_width, resolved_output_height};
                response_stall_count = response_stall_count + 1;
            end else begin
                response_hold_active = 1'b0;
            end

            if (abort && (start_ready || response_valid))
                $fatal(1, "resolver exposed a handshake during abort");
        end
    end

    // AXI attribute/stability monitor.
    always @(posedge clk) begin
        if (rst) begin
            ar_hold_active <= 1'b0;
        end else begin
            if (m_axi_arvalid) begin
                if ((m_axi_arlen !== 8'd0) || (m_axi_arsize !== 3'd4) ||
                    (m_axi_arburst !== 2'b01) || (m_axi_araddr[3:0] !== 4'd0))
                    $fatal(1, "resolver emitted illegal AXI table read");
            end
            if (m_axi_arvalid && !m_axi_arready) begin
                ar_stall_count <= ar_stall_count + 1;
                if (ar_hold_active &&
                    ((m_axi_araddr !== held_araddr) ||
                     (m_axi_arlen !== held_arlen) ||
                     (m_axi_arsize !== held_arsize) ||
                     (m_axi_arburst !== held_arburst))) begin
                    $fatal(1, "resolver AR changed while stalled");
                end
                ar_hold_active <= 1'b1;
                held_araddr <= m_axi_araddr;
                held_arlen <= m_axi_arlen;
                held_arsize <= m_axi_arsize;
                held_arburst <= m_axi_arburst;
            end else begin
                ar_hold_active <= 1'b0;
            end
        end
    end

    // Random-stall single-beat AXI table memory and random response consumer.
    always @(posedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            slave_active <= 1'b0;
            slave_raw <= 128'd0;
            slave_delay <= 4'd0;
            slave_rresp <= 2'b00;
            slave_rlast <= 1'b1;
            response_ready <= 1'b0;
        end else begin
            m_axi_arready <= !force_ar_block && (prng[0] || prng[5]);
            response_ready <= !force_response_block && (prng[2] || prng[9]);

            if (m_axi_arvalid && m_axi_arready) begin
                if (slave_active || m_axi_rvalid)
                    $fatal(1, "multiple table reads outstanding");
                if (!operation_waiting || !address_present(m_axi_araddr))
                    $fatal(1, "unexpected resolver table address %08x", m_axi_araddr);
                if (((operation_ar_stage == 0) &&
                     (m_axi_araddr !== captured_input_araddr)) ||
                    ((operation_ar_stage == 1) &&
                     (m_axi_araddr !== captured_output_araddr)) ||
                    (operation_ar_stage > 1)) begin
                    $fatal(1, "resolver table order/address mismatch stage=%0d",
                           operation_ar_stage);
                end
                ar_count = ar_count + 1;
                slave_active <= 1'b1;
                slave_raw <= lookup_raw(m_axi_araddr);
                slave_delay <= prng[15:12] & 4'h7;
                if (operation_ar_stage == captured_inject_stage) begin
                    slave_rresp <= captured_inject_rresp;
                    slave_rlast <= captured_inject_rlast;
                end else begin
                    slave_rresp <= 2'b00;
                    slave_rlast <= 1'b1;
                end
                operation_ar_stage = operation_ar_stage + 1;
            end

            if (slave_active && !m_axi_rvalid) begin
                if (force_r_block) begin
                    r_delay_count = r_delay_count + 1;
                end else if (slave_delay != 0) begin
                    slave_delay <= slave_delay - 1'b1;
                    r_delay_count = r_delay_count + 1;
                end else begin
                    m_axi_rdata <= slave_raw;
                    m_axi_rresp <= slave_rresp;
                    m_axi_rlast <= slave_rlast;
                    m_axi_rvalid <= 1'b1;
                end
            end

            if (m_axi_rvalid && m_axi_rready) begin
                r_count = r_count + 1;
                m_axi_rvalid <= 1'b0;
                slave_active <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            prng <= 32'h73ad_91e5;
        else
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
    end

    initial begin
        // Good input table: three legal entries.
        add_entry(32'h0000_1000, pack_entry(64'h0000_0000_0001_0000,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_1010, pack_entry(64'h0000_0000_0003_0000,
                                           32'h30, 16'd8, 16'd4));
        add_entry(32'h0000_1020, pack_entry(64'h0000_0000_0005_0000,
                                           32'h50, 16'd8, 16'd4));
        // Good output table: two legal, disjoint entries.
        add_entry(32'h0000_2000, pack_entry(64'h0000_0000_0002_0000,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_2010, pack_entry(64'h0000_0000_0004_0000,
                                           32'h30, 16'd8, 16'd4));
        // Exact overlap cases and a boundary-touching non-overlap case.
        add_entry(32'h0000_3000, pack_entry(64'h0000_0000_0001_0020,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_3100, pack_entry(64'h0000_0000_0001_0010,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_3200, pack_entry(64'h0000_0000_0001_0030,
                                           32'h40, 16'd8, 16'd4));
        // Field-validation entries.
        add_entry(32'h0000_4000, pack_entry(64'h0000_0001_0000_1000,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_4100, pack_entry(64'h0000_0000_0001_0003,
                                           32'h40, 16'd8, 16'd4));
        add_entry(32'h0000_4200, pack_entry(64'h0000_0000_0006_0000,
                                           32'h40, 16'd7, 16'd4));
        add_entry(32'h0000_4300, pack_entry(64'h0000_0000_0006_0000,
                                           32'h10, 16'd8, 16'd4));
        add_entry(32'h0000_4400, pack_entry(64'h0000_0000_0006_0000,
                                           32'h28, 16'd8, 16'd4));
        add_entry(32'h0000_4500, pack_entry(64'h0000_0000_ffff_ffe0,
                                           32'h20, 16'd8, 16'd2));
        // Extent shift/add boundary vectors.  The first is a normal height-two
        // input.  The second ends exactly at 2^32 and is therefore legal.
        // The third exercises multiplier bit 15 and must overflow.
        add_entry(32'h0000_4600, pack_entry(64'h0000_0000_0007_0000,
                                           32'h20, 16'd8, 16'd2));
        add_entry(32'h0000_4700, pack_entry(64'h0000_0000_ffff_ffc0,
                                           32'h20, 16'd8, 16'd2));
        add_entry(32'h0000_4800, pack_entry(64'h0000_0000_0000_8000,
                                           32'h0002_0000, 16'd8,
                                           16'h8001));

        next_expect_response = 1'b0;
        next_expect_error = 1'b0;
        next_error_code = 8'd0;
        next_error_address = 32'd0;
        next_input_base = 32'd0;
        next_input_stride = 32'd0;
        next_input_width = 16'd0;
        next_input_height = 16'd0;
        next_output_base = 32'd0;
        next_output_stride = 32'd0;
        next_output_width = 16'd0;
        next_output_height = 16'd0;
        next_inject_stage = -1;
        next_inject_rresp = 2'b00;
        next_inject_rlast = 1'b1;
        next_input_araddr = 32'd0;
        next_output_araddr = 32'd0;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Nominal pair and atomic input/config latching.
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                   32'h0001_0000, 32'h40, 32'h0002_0000, 32'h40,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Boundary touching is legal; padding is not treated as active pixels.
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_TOUCH, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                   32'h0001_0000, 32'h40, 32'h0001_0020, 32'h40,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Same-row and cross-row active overlap.  The latter specifically
        // proves this is not a same-row-only comparison.
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_OVERLAP, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_ACTIVE_OVERLAP,
                   32'h0001_0010, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_CROSS, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_ACTIVE_OVERLAP,
                   32'h0001_0040, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Local index/dimension validation must issue no AXI traffic.
        start_ar_count = ar_count;
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd3, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_INDEX,
                   32'h0000_1000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "invalid input index issued AR");

        start_ar_count = ar_count;
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd2,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_INDEX,
                   32'h0000_2000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "invalid output index issued AR");

        start_ar_count = ar_count;
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd0, 16'd4, 1'b1, 1'b1, ERR_ZERO_DIMENSION,
                   32'd0, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        if (ar_count != start_ar_count) $fatal(1, "zero dimensions issued AR");

        // Reader-side local address rejection and injected AXI response errors.
        start_response_count = response_count;
        issue_pair(64'h0000_0001_0000_1000, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_TABLE_READ,
                   32'h0000_1000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, 64'h0000_0001_0000_2000, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_TABLE_READ,
                   32'h0000_2000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_TABLE_READ,
                   32'h0000_1000, 32'd0, 32'd0, 32'd0, 32'd0,
                   0, 2'b10, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_TABLE_READ,
                   32'h0000_2000, 32'd0, 32'd0, 32'd0, 32'd0,
                   1, 2'b00, 1'b0);
        wait_response(start_response_count + 1);

        // Entry field validation on both input and output sides.
        start_response_count = response_count;
        issue_pair(TABLE_HIGH_BASE, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_BASE_RANGE,
                   32'h0000_1000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_HIGH_BASE, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_BASE_RANGE,
                   32'h0000_1000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_ALIGN_BASE, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_BASE_ALIGN,
                   32'h0001_0003, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_ALIGN_BASE, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_BASE_ALIGN,
                   32'h0001_0003, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_DIMENSION, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_DIMENSION,
                   32'h0000_4200, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_DIMENSION, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_DIMENSION,
                   32'h0000_4200, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_STRIDE_SMALL, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_INPUT_STRIDE,
                   32'h0000_4300, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_STRIDE_UNALIGNED, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b1, ERR_OUTPUT_STRIDE,
                   32'h0000_4400, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        start_response_count = response_count;
        issue_pair(TABLE_EXTENT, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd2, 1'b1, 1'b1, ERR_INPUT_EXTENT,
                   32'hffff_ffe0, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Output extent uses a legal input entry with matching height two.
        start_response_count = response_count;
        issue_pair(TABLE_HEIGHT2_LEGAL, TABLE_EXTENT, 2'd0, 2'd0,
                   16'd8, 16'd2, 1'b1, 1'b1, ERR_OUTPUT_EXTENT,
                   32'hffff_ffe0, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // end_exclusive == 2^32 is legal (the last active byte is still in
        // the 32-bit map).  This catches a terminal-cycle >= versus > error.
        start_response_count = response_count;
        issue_pair(TABLE_HEIGHT2_LEGAL, TABLE_EXTENT_BOUNDARY, 2'd0, 2'd0,
                   16'd8, 16'd2, 1'b1, 1'b0, 8'd0, 32'd0,
                   32'h0007_0000, 32'h20, 32'hffff_ffc0, 32'h20,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // height-1 == 0x8000 selects the last serial multiplier bit.  A
        // missed bit-15 add would incorrectly accept this entry.
        start_response_count = response_count;
        issue_pair(TABLE_EXTENT_HIGH_BIT, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'h8001, 1'b1, 1'b1, ERR_INPUT_EXTENT,
                   32'h0000_8000, 32'd0, 32'd0, 32'd0, 32'd0,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);

        // Abort before any AR handshake.
        force_ar_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b0, 1'b0, 8'd0, 32'd0,
                   32'd0, 32'd0, 32'd0, 32'd0, -1, 2'b00, 1'b1);
        while (!m_axi_arvalid) @(negedge clk);
        pulse_abort();
        force_ar_block = 1'b0;
        wait_idle();
        if ((response_count != start_response_count) || (ar_count != start_ar_count))
            $fatal(1, "abort-before-AR leaked traffic/response");

        // Restart after cancellation.
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd1, 2'd1,
                   16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                   32'h0003_0000, 32'h30, 32'h0004_0000, 32'h30,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        restart_count = restart_count + 1;

        // Abort after first AR; the committed beat must drain without output.
        force_r_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_count;
        start_r_count = r_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b0, 1'b0, 8'd0, 32'd0,
                   32'd0, 32'd0, 32'd0, 32'd0, -1, 2'b00, 1'b1);
        wait_ar(start_ar_count + 1);
        pulse_abort();
        force_r_block = 1'b0;
        wait_r(start_r_count + 1);
        wait_idle();
        if (response_count != start_response_count)
            $fatal(1, "abort-after-AR leaked response");

        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd2, 2'd0,
                   16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                   32'h0005_0000, 32'h50, 32'h0002_0000, 32'h40,
                   -1, 2'b00, 1'b1);
        wait_response(start_response_count + 1);
        restart_count = restart_count + 1;

        // Abort between the input and output table requests.
        force_r_block = 1'b1;
        start_response_count = response_count;
        start_ar_count = ar_count;
        start_r_count = r_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b0, 1'b0, 8'd0, 32'd0,
                   32'd0, 32'd0, 32'd0, 32'd0, -1, 2'b00, 1'b1);
        wait_ar(start_ar_count + 1);
        @(negedge clk);
        force_ar_block = 1'b1;
        force_r_block = 1'b0;
        wait_r(start_r_count + 1);
        while (!m_axi_arvalid) @(negedge clk);
        pulse_abort();
        force_ar_block = 1'b0;
        wait_idle();
        if (response_count != start_response_count)
            $fatal(1, "abort-between-entries leaked response");

        // Abort a consumer-stalled successful response.
        force_response_block = 1'b1;
        start_response_count = response_count;
        issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                   16'd8, 16'd4, 1'b0, 1'b0, 8'd0, 32'd0,
                   32'd0, 32'd0, 32'd0, 32'd0, -1, 2'b00, 1'b1);
        while (!response_valid) @(negedge clk);
        pulse_abort();
        force_response_block = 1'b0;
        wait_idle();
        if (response_count != start_response_count)
            $fatal(1, "abort-stalled-response was consumed");

        // Randomized successful restart sweep across all fixed table indices.
        for (random_case = 0; random_case < 18; random_case = random_case + 1) begin
            start_response_count = response_count;
            if (random_case % 3 == 0) begin
                issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd0, 2'd0,
                           16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                           32'h0001_0000, 32'h40, 32'h0002_0000, 32'h40,
                           -1, 2'b00, 1'b1);
            end else if (random_case % 3 == 1) begin
                issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd1, 2'd1,
                           16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                           32'h0003_0000, 32'h30, 32'h0004_0000, 32'h30,
                           -1, 2'b00, 1'b1);
            end else begin
                issue_pair(TABLE_INPUT_GOOD, TABLE_OUTPUT_GOOD, 2'd2, 2'd0,
                           16'd8, 16'd4, 1'b1, 1'b0, 8'd0, 32'd0,
                           32'h0005_0000, 32'h50, 32'h0002_0000, 32'h40,
                           -1, 2'b00, 1'b1);
            end
            wait_response(start_response_count + 1);
        end
        restart_count = restart_count + 1;

        wait_idle();
        repeat (8) @(posedge clk);
        if (busy || operation_waiting || slave_active || m_axi_rvalid ||
            m_axi_arvalid || response_valid)
            $fatal(1, "frame-pair regression ended with outstanding state");
        if (accepted_count != response_count + abort_count)
            $fatal(1, "accepted/response/abort accounting mismatch");
        if (ar_count != r_count)
            $fatal(1, "committed table reads were not fully drained");
        if ((ar_stall_count == 0) || (r_delay_count == 0) ||
            (response_stall_count == 0))
            $fatal(1, "randomized stall coverage missing");
        if ((overlap_error_count != 2) || (abort_count != 4) ||
            (restart_count != 3))
            $fatal(1, "overlap/abort/restart coverage counters incomplete");

        $display("C1_FRAME_PAIR_RESOLVER_PASS accepted=%0d responses=%0d success=%0d errors=%0d overlap=%0d aborts=%0d restarts=%0d ar=%0d r=%0d ar_stalls=%0d r_delays=%0d response_stalls=%0d",
                 accepted_count, response_count, success_count, error_count,
                 overlap_error_count, abort_count, restart_count, ar_count,
                 r_count, ar_stall_count, r_delay_count, response_stall_count);
        $finish;
    end

    initial begin
        repeat (500000) @(posedge clk);
        $fatal(1, "frame-pair resolver regression timeout");
    end

endmodule
