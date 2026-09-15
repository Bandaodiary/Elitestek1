`timescale 1ns/1ps

module tb_c1_r1_job_frontend;
    parameter integer SEPARATE_INPUT_GEOMETRY=0;
    parameter integer INPUT_SNAPSHOT_CASE=0;
    parameter bit SNAPSHOT_PREVIEW=0;
    parameter integer REGION_CASE=0;
    logic [96:0] job_expected_input=0;
    wire region_request,region_cancel;
    logic region_response=0;
    logic [7:0] region_error_code=0;
    logic [31:0] region_error_address=0;
    localparam logic [15:0] INPUT_WIDTH=SEPARATE_INPUT_GEOMETRY ? 12 : 8;
    localparam logic [15:0] INPUT_HEIGHT=SEPARATE_INPUT_GEOMETRY ? 6 : 4;
    logic [15:0] job_input_width_pixels=0,job_input_height_lines=0;
    logic [31:0] job_preview_base=0,job_preview_stride=0;

    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;

    localparam logic [31:0] INPUT_TABLE_BASE = 32'h0000_1000;
    localparam logic [31:0] OUTPUT_TABLE_BASE = 32'h0000_2000;
    localparam logic [31:0] DESCRIPTOR_BASE = 32'h0040_0000;
    localparam logic [1:0] INPUT_INDEX = 2'd1;
    localparam logic [1:0] OUTPUT_INDEX = 2'd0;
    localparam logic [31:0] INPUT_ENTRY_ADDRESS =
        INPUT_TABLE_BASE + 32'd16;
    localparam logic [31:0] OUTPUT_ENTRY_ADDRESS = OUTPUT_TABLE_BASE;
    localparam logic [15:0] FRAME_WIDTH = 16'd8;
    localparam logic [15:0] FRAME_HEIGHT = 16'd4;
    localparam logic [31:0] INPUT_FRAME_BASE = 32'h1000_0000;
    localparam logic [31:0] OUTPUT_FRAME_BASE = 32'h2000_0000;
    localparam logic [31:0] INPUT_STRIDE = 32'h0000_0040;
    localparam logic [31:0] OUTPUT_STRIDE = 32'h0000_0050;
    // A deliberately slow overlap case: the config path can finish all 22
    // descriptors before the pair resolver reaches the only overlapping row.
    // This proves that an already committed config is a reusable preloaded
    // cache even when the same job later fails frame-pair validation.
    localparam logic [15:0] LATE_PAIR_HEIGHT = 16'd2048;
    localparam logic [31:0] LATE_PAIR_STRIDE = 32'h0000_0100;
    localparam logic [31:0] LATE_PAIR_OUTPUT_BASE =
        INPUT_FRAME_BASE + (2048-1) * 32'h0000_0100;

    localparam integer RUNTIME_NONE = 0;
    localparam integer RUNTIME_SUCCESS = 1;
    localparam integer RUNTIME_ABORT_DRAIN = 2;
    localparam integer RUNTIME_PRIORITY = 3;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic job_start_valid = 1'b0;
    logic job_start_ready;
    logic job_abort = 1'b0;
    logic [63:0] job_input_table_base = 64'd0;
    logic [63:0] job_output_table_base = 64'd0;
    logic [1:0] job_input_buffer_index = 2'd0;
    logic [1:0] job_output_buffer_index = 2'd0;
    logic [15:0] job_width_pixels = 16'd0;
    logic [15:0] job_height_lines = 16'd0;
    logic [31:0] job_descriptor_base = 32'd0;
    logic [COUNT_BITS-1:0] job_descriptor_count = '0;
    logic [31:0] job_cycle_budget = 32'd0;

    logic busy;
    logic job_done;
    logic job_error;
    logic job_aborted;
    logic [7:0] error_code;
    logic [31:0] error_address;

    logic [31:0] resolved_input_base;
    logic [31:0] resolved_input_stride;
    logic [15:0] resolved_input_width;
    logic [15:0] resolved_input_height;
    logic [31:0] resolved_output_base;
    logic [31:0] resolved_output_stride;
    logic [15:0] resolved_output_width;
    logic [15:0] resolved_output_height;

    logic config_loading;
    logic config_commit_pulse;
    logic active_config_bank;
    logic [COUNT_BITS-1:0] active_config_count;
    logic [GENERATION_BITS-1:0] active_config_generation;
    logic config_read_enable = 1'b0;
    logic [COUNT_BITS-1:0] config_read_index = '0;
    logic config_read_ready;
    logic config_read_busy;
    logic config_read_valid;
    logic [511:0] config_read_descriptor;
    logic [GENERATION_BITS-1:0] config_read_generation;

    logic input_dma_ready;
    logic input_dma_start;
    logic input_dma_busy = 1'b0;
    logic input_dma_done = 1'b0;
    logic input_dma_error = 1'b0;
    logic [7:0] input_dma_error_code = 8'h91;
    logic [31:0] input_dma_error_address = 32'hdead_1000;

    logic output_dma_ready;
    logic output_dma_start;
    logic output_dma_busy = 1'b0;
    logic output_dma_done = 1'b0;
    logic output_dma_error = 1'b0;
    logic [7:0] output_dma_error_code = 8'h92;
    logic [31:0] output_dma_error_address = 32'hdead_2000;

    logic descriptor_busy = 1'b0;
    logic descriptor_done = 1'b0;
    logic descriptor_error = 1'b0;
    logic [7:0] descriptor_error_code = 8'h93;
    logic [31:0] descriptor_error_address = 32'hdead_3000;
    logic descriptor_abort_pulse;

    logic engine_ready;
    logic engine_start;
    logic engine_busy = 1'b0;
    logic engine_done = 1'b0;
    logic engine_error = 1'b0;
    logic [7:0] engine_error_code = 8'ha2;
    logic [31:0] engine_error_address = 32'hdead_4000;
    logic engine_abort_pulse;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [127:0] m_axi_rdata = 128'd0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;

    logic [511:0] descriptor_memory [0:MAX_STAGES-1];
    logic pair_overlap_mode = 1'b0;
    logic late_pair_failure_mode = 1'b0;
    logic inject_axi_error = 1'b0;
    logic [31:0] inject_axi_error_address = 32'd0;
    // 0=normal, 1=early RLAST on beat 1, 2=missing RLAST on beat 3.
    integer descriptor_rlast_mode = 0;
    logic [31:0] descriptor_rlast_target = 32'd0;

    logic [31:0] prng = 32'h73ad_91e5;
    logic force_ar_block = 1'b0;
    logic burst_active = 1'b0;
    logic [31:0] burst_base = 32'd0;
    logic [7:0] burst_length = 8'd0;
    logic [7:0] burst_beat = 8'd0;
    logic [3:0] response_gap = 4'd0;

    integer requested_runtime_mode = RUNTIME_NONE;
    integer active_runtime_mode = RUNTIME_NONE;
    integer runtime_cycle = 0;
    logic runtime_active = 1'b0;

    integer job_start_count = 0;
    integer launch_count = 0;
    integer job_done_count = 0;
    integer job_error_count = 0;
    integer job_aborted_count = 0;
    integer config_commit_count = 0;
    integer config_read_count = 0;
    integer descriptor_abort_count = 0;
    integer engine_abort_count = 0;
    integer table_ar_count = 0;
    integer descriptor_ar_count = 0;
    integer rbeat_count = 0;
    integer ar_stall_cycles = 0;
    integer r_gap_cycles = 0;
    integer preflight_stalled_abort_checks = 0;
    integer safe_dma_drain_checks = 0;
    integer priority_error_injections = 0;
    integer rlast_injection_count = 0;

    logic [7:0] last_job_error_code = 8'd0;
    logic [31:0] last_job_error_address = 32'd0;

    logic previous_ar_stall = 1'b0;
    logic [44:0] previous_ar_payload = '0;
    logic previous_r_stall = 1'b0;
    logic [130:0] previous_r_payload = '0;
    logic previous_job_done = 1'b0;
    logic previous_job_error = 1'b0;
    logic previous_job_aborted = 1'b0;

    integer index;
    integer guard;
    integer target;
    integer snapshot;
    integer generation_snapshot;
    integer launch_snapshot;
    integer ar_snapshot;

    always #5 clk = ~clk;

    assign input_dma_ready = !input_dma_busy;
    assign output_dma_ready = !output_dma_busy;
    assign engine_ready = !engine_busy;
    assign m_axi_arready = !rst && !force_ar_block && !burst_active &&
                           (prng[2:0] != 3'b000) &&
                           (prng[7:5] != 3'b111);

    c1_r1_job_frontend #(
        .CHECK_INPUT_SNAPSHOT(INPUT_SNAPSHOT_CASE!=0),
        .CHECK_WRITE_REGIONS(REGION_CASE!=0),
        .CHECK_PREVIEW_LAYOUT(SNAPSHOT_PREVIEW),
        .SEPARATE_INPUT_GEOMETRY(SEPARATE_INPUT_GEOMETRY),
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .SYNC_READ(1'b1),
        .FAST_WIDE(1'b0)
    ) dut (.*);

    function automatic [127:0] pack_table_entry(
        input logic [31:0] base_address,
        input logic [31:0] stride_bytes,
        input logic [15:0] width_pixels,
        input logic [15:0] height_lines
    );
        begin
            pack_table_entry = {
                height_lines, width_pixels, stride_bytes,
                32'd0, base_address
            };
        end
    endfunction

    function automatic [511:0] legal_descriptor(
        input integer batch_tag,
        input integer stage_index
    );
        logic [511:0] descriptor;
        logic [15:0] dimension;
        begin
            descriptor = '0;
            dimension = 16'd8 + (stage_index % 5);
            descriptor[7:0] = 8'd2;
            descriptor[9:8] = stage_index[0] ? 2'd1 : 2'd0;
            descriptor[15:10] = 6'd0;
            descriptor[23:16] = 8'd1;
            descriptor[31:24] = 8'd16;
            descriptor[47:32] = dimension;
            descriptor[63:48] = dimension + 16'd1;
            descriptor[79:64] = dimension;
            descriptor[95:80] = dimension + 16'd1;
            descriptor[111:96] = 16'd8;
            descriptor[127:112] = 16'd8;
            descriptor[159:128] = 32'h0001_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[191:160] = 32'h0010_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[223:192] = 32'd0;
            descriptor[255:224] = 32'h0020_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[287:256] = 32'h0030_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[319:288] = 32'h0040_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[351:320] = 32'h0050_0000 +
                batch_tag * 32'h0000_1000 + stage_index * 32'h10;
            descriptor[383:352] = 32'd0;
            descriptor[415:384] = 32'd0;
            descriptor[423:416] = 8'd1;
            descriptor[431:424] = 8'd1;
            descriptor[439:432] = 8'd1;
            descriptor[447:440] = 8'd1;
            descriptor[455:448] = 8'd8;
            descriptor[463:456] = 8'd8;
            descriptor[471:464] = 8'd4;
            descriptor[479:472] = 8'd4;
            descriptor[511:480] = 32'd1000 + batch_tag * 32'd100 +
                                   stage_index;
            legal_descriptor = descriptor;
        end
    endfunction

    function automatic [127:0] lookup_memory(input logic [31:0] address);
        integer descriptor_index;
        integer beat_index;
        logic [31:0] offset;
        begin
            lookup_memory = 128'd0;
            if (address == INPUT_ENTRY_ADDRESS) begin
                lookup_memory = pack_table_entry(
                    INPUT_FRAME_BASE,
                    late_pair_failure_mode ? LATE_PAIR_STRIDE : INPUT_STRIDE,
                    INPUT_WIDTH,
                    late_pair_failure_mode ? LATE_PAIR_HEIGHT : INPUT_HEIGHT);
            end else if (address ==
                         OUTPUT_ENTRY_ADDRESS) begin
                lookup_memory = pack_table_entry(
                    late_pair_failure_mode ? LATE_PAIR_OUTPUT_BASE :
                    (pair_overlap_mode ? INPUT_FRAME_BASE : OUTPUT_FRAME_BASE),
                    late_pair_failure_mode ? LATE_PAIR_STRIDE : OUTPUT_STRIDE,
                    FRAME_WIDTH,
                    late_pair_failure_mode ? LATE_PAIR_HEIGHT : FRAME_HEIGHT);
            end else if ((address >= DESCRIPTOR_BASE) &&
                         (address < DESCRIPTOR_BASE + MAX_STAGES * 64)) begin
                offset = address - DESCRIPTOR_BASE;
                descriptor_index = offset >> 6;
                beat_index = (offset >> 4) & 3;
                lookup_memory =
                    descriptor_memory[descriptor_index][beat_index*128 +: 128];
            end
        end
    endfunction

    task automatic load_descriptors(
        input integer batch_tag,
        input integer invalid_index
    );
        integer stage;
        begin
            for (stage = 0; stage < MAX_STAGES; stage = stage + 1) begin
                descriptor_memory[stage] = legal_descriptor(batch_tag, stage);
                if (stage == invalid_index)
                    descriptor_memory[stage][23:16] = 8'h7f;
            end
        end
    endtask

    task automatic drive_job_command(input integer runtime_mode_value);
        integer expected_start_count;
        begin
            requested_runtime_mode = runtime_mode_value;
            job_input_table_base = {32'd0, INPUT_TABLE_BASE};
            job_output_table_base = {32'd0, OUTPUT_TABLE_BASE};
            job_input_buffer_index = INPUT_INDEX;
            job_output_buffer_index = OUTPUT_INDEX;
            job_width_pixels = FRAME_WIDTH;
            job_input_width_pixels=INPUT_WIDTH;
            job_input_height_lines=late_pair_failure_mode ? LATE_PAIR_HEIGHT : INPUT_HEIGHT;
            job_height_lines = late_pair_failure_mode ?
                               LATE_PAIR_HEIGHT : FRAME_HEIGHT;
            job_descriptor_base = DESCRIPTOR_BASE;
            job_descriptor_count = MAX_STAGES;
            job_cycle_budget = REGION_CASE==4 ? 32'd6000 : 32'd0;

            guard = 0;
            while (!job_start_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    $fatal(1, "job frontend did not become start-ready");
            end
            expected_start_count = job_start_count + 1;
            @(negedge clk);
            job_start_valid = 1'b1;
            while (job_start_count < expected_start_count)
                @(negedge clk);
            job_start_valid = 1'b0;

            // Prove the complete command was captured atomically.
            job_input_table_base = 64'hffff_ffff_ffff_fff0;
            job_output_table_base = 64'hffff_ffff_ffff_ffe0;
            job_input_buffer_index = 2'd3;
            job_output_buffer_index = 2'd3;
            job_width_pixels = 16'd0;
            job_input_width_pixels=0;
            job_input_height_lines=0;
            job_height_lines = 16'd0;
            job_descriptor_base = 32'hffff_fff0;
            job_descriptor_count = '0;
            job_cycle_budget = 32'd1;
            if (!busy || job_start_ready)
                $fatal(1, "accepted job did not enter busy state");
        end
    endtask

    task automatic wait_for_launch(input integer expected_launch_count);
        begin
            guard = 0;
            while (launch_count < expected_launch_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "job frontend launch timeout");
            end
            if ((resolved_input_base !== INPUT_FRAME_BASE) ||
                (resolved_input_stride !== INPUT_STRIDE) ||
                (resolved_input_width !== INPUT_WIDTH) ||
                (resolved_input_height !== INPUT_HEIGHT) ||
                (resolved_output_base !== OUTPUT_FRAME_BASE) ||
                (resolved_output_stride !== OUTPUT_STRIDE) ||
                (resolved_output_width !== FRAME_WIDTH) ||
                (resolved_output_height !== FRAME_HEIGHT))
                $fatal(1, "resolved frame parameters mismatch at launch");
            if ((active_config_count != MAX_STAGES) ||
                config_loading || config_read_busy)
                $fatal(1, "stage configuration was not committed at launch");
        end
    endtask

    task automatic wait_for_done(input integer expected_count);
        begin
            guard = 0;
            while (job_done_count < expected_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "job frontend done timeout");
            end
            repeat (2) @(posedge clk);
            #1;
            if (busy || !job_start_ready)
                $fatal(1, "successful job did not retire to idle");
        end
    endtask

    task automatic wait_for_error(
        input integer expected_count,
        input logic [7:0] expected_code,
        input logic [31:0] expected_address
    );
        begin
            guard = 0;
            while (job_error_count < expected_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "job frontend fault retirement timeout");
            end
            if ((last_job_error_code !== expected_code) ||
                (last_job_error_address !== expected_address))
                $fatal(1, "job fault mismatch got=%h/%h expected=%h/%h",
                       last_job_error_code, last_job_error_address,
                       expected_code, expected_address);
            repeat (2) @(posedge clk);
            #1;
            if (busy || !job_start_ready)
                $fatal(1, "faulted job did not retire to idle");
        end
    endtask

    task automatic wait_for_aborted(input integer expected_count);
        begin
            guard = 0;
            while (job_aborted_count < expected_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "job frontend abort retirement timeout");
            end
            repeat (2) @(posedge clk);
            #1;
            if (busy || !job_start_ready)
                $fatal(1, "aborted job did not retire to idle");
        end
    endtask

    task automatic read_config_and_check(
        input integer expected_batch_tag,
        input integer stage_index,
        input integer expected_generation
    );
        begin
            guard = 0;
            while (!config_read_ready) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 1000)
                    $fatal(1, "stage-config read did not become ready");
            end
            @(negedge clk);
            config_read_index = stage_index;
            config_read_enable = 1'b1;
            @(posedge clk);
            @(negedge clk);
            config_read_enable = 1'b0;

            guard = 0;
            while (!config_read_valid) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "stage-config read response timeout");
            end
            if (config_read_descriptor !==
                legal_descriptor(expected_batch_tag, stage_index))
                $fatal(1, "stage-config descriptor mismatch index=%0d",
                       stage_index);
            if (config_read_generation !== expected_generation)
                $fatal(1, "stage-config generation mismatch index=%0d",
                       stage_index);
            config_read_count = config_read_count + 1;
            @(posedge clk);
        end
    endtask

    task automatic pulse_job_abort;
        begin
            @(negedge clk);
            job_abort = 1'b1;
            @(posedge clk);
            @(negedge clk);
            job_abort = 1'b0;
        end
    endtask

    // One-outstanding-burst AXI128 memory with independent random AR and R
    // gaps.  R payload is registered and cannot change under sink stall.
    always_ff @(posedge clk) begin
        logic [31:0] beat_address;
        if (rst) begin
            prng <= 32'h73ad_91e5;
            burst_active <= 1'b0;
            burst_base <= 32'd0;
            burst_length <= 8'd0;
            burst_beat <= 8'd0;
            response_gap <= 4'd0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            m_axi_rvalid <= 1'b0;
            table_ar_count <= 0;
            descriptor_ar_count <= 0;
            rbeat_count <= 0;
            r_gap_cycles <= 0;
            rlast_injection_count <= 0;
        end else begin
            prng <= {prng[30:0],
                     prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};

            if (m_axi_arvalid && m_axi_arready) begin
                if ((m_axi_arsize != 3'd4) ||
                    (m_axi_arburst != 2'b01) || m_axi_araddr[3:0])
                    $fatal(1, "illegal shared AXI AR attributes/address");
                if ((m_axi_araddr ==
                     INPUT_ENTRY_ADDRESS) ||
                    (m_axi_araddr ==
                     OUTPUT_ENTRY_ADDRESS)) begin
                    if (m_axi_arlen != 0)
                        $fatal(1, "frame-table read was not one beat");
                    table_ar_count <= table_ar_count + 1;
                end else if ((m_axi_araddr >= DESCRIPTOR_BASE) &&
                             (m_axi_araddr <
                              DESCRIPTOR_BASE + MAX_STAGES * 64) &&
                             (m_axi_araddr[5:0] == 0)) begin
                    if (m_axi_arlen != 8'd3)
                        $fatal(1, "descriptor read was not four beats");
                    descriptor_ar_count <= descriptor_ar_count + 1;
                end else begin
                    $fatal(1, "unexpected shared AXI AR address %h",
                           m_axi_araddr);
                end
                burst_active <= 1'b1;
                burst_base <= m_axi_araddr;
                burst_length <= m_axi_arlen;
                burst_beat <= 8'd0;
                response_gap <= {2'd0, prng[9:8]};
            end

            if (burst_active && !m_axi_rvalid) begin
                if (response_gap != 0) begin
                    response_gap <= response_gap - 1'b1;
                    r_gap_cycles <= r_gap_cycles + 1;
                end else begin
                    beat_address = burst_base + ({24'd0, burst_beat} << 4);
                    m_axi_rdata <= lookup_memory(beat_address);
                    m_axi_rresp <=
                        (inject_axi_error &&
                         (beat_address == inject_axi_error_address)) ?
                        2'b10 : 2'b00;
                    if ((descriptor_rlast_mode == 1) &&
                        (burst_base == descriptor_rlast_target) &&
                        (burst_beat == 1)) begin
                        m_axi_rlast <= 1'b1;
                        rlast_injection_count <= rlast_injection_count + 1;
                    end else if ((descriptor_rlast_mode == 2) &&
                                 (burst_base == descriptor_rlast_target) &&
                                 (burst_beat == burst_length)) begin
                        m_axi_rlast <= 1'b0;
                        rlast_injection_count <= rlast_injection_count + 1;
                    end else begin
                        m_axi_rlast <= (burst_beat == burst_length);
                    end
                    m_axi_rvalid <= 1'b1;
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                rbeat_count <= rbeat_count + 1;
                m_axi_rvalid <= 1'b0;
                // The slave closes a burst at the ARLEN-implied beat count
                // even when deliberately omitting RLAST.  This lets the DUT
                // prove both protocol-error detection and arbiter recovery.
                if (m_axi_rlast || (burst_beat == burst_length)) begin
                    burst_active <= 1'b0;
                    m_axi_rlast <= 1'b0;
                    m_axi_rresp <= 2'b00;
                end else begin
                    burst_beat <= burst_beat + 1'b1;
                    response_gap <= {2'd0, prng[13:12]};
                end
            end
        end
    end

    // External runtime clients.  Descriptor and engine honor abort; the two
    // DMAs always run to a terminal response once started.
    always_ff @(posedge clk) begin
        if (rst) begin
            active_runtime_mode <= RUNTIME_NONE;
            runtime_cycle <= 0;
            runtime_active <= 1'b0;
            input_dma_busy <= 1'b0;
            input_dma_done <= 1'b0;
            input_dma_error <= 1'b0;
            output_dma_busy <= 1'b0;
            output_dma_done <= 1'b0;
            output_dma_error <= 1'b0;
            descriptor_busy <= 1'b0;
            descriptor_done <= 1'b0;
            descriptor_error <= 1'b0;
            engine_busy <= 1'b0;
            engine_done <= 1'b0;
            engine_error <= 1'b0;
            descriptor_abort_count <= 0;
            engine_abort_count <= 0;
            priority_error_injections <= 0;
        end else begin
            input_dma_done <= 1'b0;
            input_dma_error <= 1'b0;
            output_dma_done <= 1'b0;
            output_dma_error <= 1'b0;
            descriptor_done <= 1'b0;
            descriptor_error <= 1'b0;
            engine_done <= 1'b0;
            engine_error <= 1'b0;

            if (engine_start) begin
                if (runtime_active || input_dma_busy || output_dma_busy ||
                    descriptor_busy || engine_busy ||
                    (requested_runtime_mode == RUNTIME_NONE))
                    $fatal(1, "unexpected/overlapping runtime launch");
                active_runtime_mode <= requested_runtime_mode;
                runtime_cycle <= 0;
                runtime_active <= 1'b1;
                input_dma_busy <= 1'b1;
                output_dma_busy <= 1'b1;
                descriptor_busy <= 1'b1;
                engine_busy <= 1'b1;
            end else if (runtime_active) begin
                runtime_cycle <= runtime_cycle + 1;
                case (active_runtime_mode)
                    RUNTIME_SUCCESS: begin
                        if (runtime_cycle == 6) begin
                            descriptor_busy <= 1'b0;
                            descriptor_done <= 1'b1;
                        end
                        if (runtime_cycle == 9) begin
                            input_dma_busy <= 1'b0;
                            input_dma_done <= 1'b1;
                        end
                        if (runtime_cycle == 13) begin
                            engine_busy <= 1'b0;
                            engine_done <= 1'b1;
                        end
                        if (runtime_cycle == 17) begin
                            output_dma_busy <= 1'b0;
                            output_dma_done <= 1'b1;
                            runtime_active <= 1'b0;
                        end
                    end

                    RUNTIME_ABORT_DRAIN: begin
                        if (runtime_cycle == 15) begin
                            input_dma_busy <= 1'b0;
                            input_dma_done <= 1'b1;
                        end
                        if (runtime_cycle == 23) begin
                            output_dma_busy <= 1'b0;
                            output_dma_done <= 1'b1;
                            runtime_active <= 1'b0;
                        end
                    end

                    RUNTIME_PRIORITY: begin
                        if (runtime_cycle == 5) begin
                            input_dma_busy <= 1'b0;
                            input_dma_error <= 1'b1;
                            engine_busy <= 1'b0;
                            engine_error <= 1'b1;
                            priority_error_injections <=
                                priority_error_injections + 1;
                        end
                        if (runtime_cycle == 19) begin
                            output_dma_busy <= 1'b0;
                            output_dma_done <= 1'b1;
                            runtime_active <= 1'b0;
                        end
                    end

                    default:
                        $fatal(1, "invalid runtime mode");
                endcase
            end

            if (descriptor_abort_pulse) begin
                descriptor_abort_count <= descriptor_abort_count + 1;
                descriptor_busy <= 1'b0;
            end
            if (engine_abort_pulse) begin
                engine_abort_count <= engine_abort_count + 1;
                engine_busy <= 1'b0;
            end
        end
    end

    // Protocol stability, launch/retirement accounting and safety assertions.
    always @(posedge clk) begin
        if (rst) begin
            job_start_count = 0;
            launch_count = 0;
            job_done_count = 0;
            job_error_count = 0;
            job_aborted_count = 0;
            config_commit_count = 0;
            config_read_count = 0;
            last_job_error_code = 8'd0;
            last_job_error_address = 32'd0;
            previous_ar_stall = 1'b0;
            previous_r_stall = 1'b0;
            previous_ar_payload = '0;
            previous_r_payload = '0;
            previous_job_done = 1'b0;
            previous_job_error = 1'b0;
            previous_job_aborted = 1'b0;
        end else begin
            if (previous_ar_stall &&
                ({m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst} !==
                 previous_ar_payload))
                $fatal(1, "shared AXI AR payload changed while stalled");
            if (previous_r_stall &&
                ({m_axi_rdata,m_axi_rresp,m_axi_rlast} !==
                 previous_r_payload))
                $fatal(1, "shared AXI R payload changed while stalled");
            previous_ar_stall = m_axi_arvalid && !m_axi_arready;
            previous_r_stall = m_axi_rvalid && !m_axi_rready;
            previous_ar_payload =
                {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
            previous_r_payload = {m_axi_rdata,m_axi_rresp,m_axi_rlast};

            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_cycles = ar_stall_cycles + 1;
            if (job_start_valid && job_start_ready)
                job_start_count = job_start_count + 1;

            if (input_dma_start || output_dma_start || engine_start) begin
                if (!(input_dma_start && output_dma_start && engine_start))
                    $fatal(1, "three execution starts were not atomic");
                if (requested_runtime_mode == RUNTIME_NONE)
                    $fatal(1, "preflight-failed job reached launch");
                if ((resolved_input_base !== INPUT_FRAME_BASE) ||
                    (resolved_output_base !== OUTPUT_FRAME_BASE))
                    $fatal(1, "launch used unresolved frame bases");
                launch_count = launch_count + 1;
            end

            if (descriptor_busy && !runtime_active)
                $fatal(1, "runtime descriptor_busy asserted before engine_start");

            if (config_commit_pulse)
                config_commit_count = config_commit_count + 1;

            if (job_done) begin
                if (input_dma_busy || output_dma_busy || descriptor_busy ||
                    engine_busy)
                    $fatal(1, "job_done preceded four-client retirement");
                job_done_count = job_done_count + 1;
            end
            if (job_error) begin
                if (input_dma_busy || output_dma_busy || descriptor_busy ||
                    engine_busy)
                    $fatal(1, "job_error preceded safe client drain");
                last_job_error_code = error_code;
                last_job_error_address = error_address;
                job_error_count = job_error_count + 1;
            end
            if (job_aborted) begin
                if (input_dma_busy || output_dma_busy || descriptor_busy ||
                    engine_busy || burst_active || m_axi_rvalid)
                    $fatal(1, "job_aborted preceded DMA/AXI safe drain");
                job_aborted_count = job_aborted_count + 1;
            end

            if ((job_done && previous_job_done) ||
                (job_error && previous_job_error) ||
                (job_aborted && previous_job_aborted))
                $fatal(1, "job terminal output was not a pulse");
            if ((job_done && (job_error || job_aborted)) ||
                (job_error && job_aborted))
                $fatal(1, "job terminal outputs overlapped");
            previous_job_done = job_done;
            previous_job_error = job_error;
            previous_job_aborted = job_aborted;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        if (!job_start_ready || busy || job_done || job_error || job_aborted ||
            (active_config_generation != 0) || (active_config_count != 0))
            $fatal(1, "job frontend reset state mismatch");

        // 1. Full successful preflight, atomic launch and four retirements.
        load_descriptors(1, -1);
        if(REGION_CASE!=0) begin
            job_preview_base=32'h30000000;job_preview_stride=32'd32;
            if(REGION_CASE==5) begin
                inject_axi_error=1;inject_axi_error_address=INPUT_ENTRY_ADDRESS;
            end
            drive_job_command(REGION_CASE==1 ? RUNTIME_SUCCESS : RUNTIME_NONE);
            if(REGION_CASE==5) begin
                wait_for_error(1,8'h10,INPUT_ENTRY_ADDRESS);
                if(region_request) $fatal(1,"native failure reached region admission");
                inject_axi_error=0;
            end else begin
                wait(region_request);
                repeat(37) begin
                    @(negedge clk);
                    if(!region_request||launch_count!=0||job_done_count!=0)
                        $fatal(1,"region wait lost request or launched before approval");
                end
                if(REGION_CASE==4) begin
                    wait_for_error(1,8'hf0,32'd6000);
                end else begin
                    region_response=1;
                    if(REGION_CASE==2) begin
                        region_error_code=8'h35;region_error_address=OUTPUT_FRAME_BASE;
                        wait_for_error(1,8'h35,OUTPUT_FRAME_BASE);
                    end else if(REGION_CASE==3) begin
                        // Same-edge success and abort must never launch.
                        job_abort=1;
                        @(negedge clk);job_abort=0;
                        wait_for_aborted(1);
                    end
                end
            end
            if(REGION_CASE!=1) begin
                if(launch_count!=0||region_request) $fatal(1,"failed admission leaked launch/request");
                region_response=0;region_error_code=0;region_error_address=0;
                drive_job_command(RUNTIME_SUCCESS);
                wait(region_request);
                @(negedge clk);region_response=1;
            end
            wait_for_launch(1);wait_for_done(1);
            if(launch_count!=1) $fatal(1,"admission recovery did not launch exactly once");
            $display("C1_FRONTEND_REGION_PASS mode=%0d geometry=%0d preview=%0d wait=37 recovery=1",
                REGION_CASE,SEPARATE_INPUT_GEOMETRY,SNAPSHOT_PREVIEW);
            $finish;
        end
        if(INPUT_SNAPSHOT_CASE!=0) begin
            job_preview_base=32'h30000000;job_preview_stride=32'd32;
            job_expected_input={1'b1,INPUT_FRAME_BASE,INPUT_STRIDE,INPUT_WIDTH,INPUT_HEIGHT};
            case(INPUT_SNAPSHOT_CASE)
                2: job_expected_input[95:64]=INPUT_FRAME_BASE+16;
                3: job_expected_input[63:32]=INPUT_STRIDE+16;
                4: job_expected_input[31:16]=INPUT_WIDTH+4;
                5: job_expected_input[15:0]=INPUT_HEIGHT+1;
                6: job_expected_input[96]=0;
                7,8: begin
                    job_expected_input[96]=0;
                    inject_axi_error=1;
                    inject_axi_error_address=(INPUT_SNAPSHOT_CASE==7 ? INPUT_ENTRY_ADDRESS : OUTPUT_ENTRY_ADDRESS);
                end
                9: begin job_expected_input[96]=0;force_ar_block=1;end
                default: begin end
            endcase
            drive_job_command(INPUT_SNAPSHOT_CASE==1 ? RUNTIME_SUCCESS : RUNTIME_NONE);
            job_expected_input='0; // Accepted snapshot must survive pin changes.
            if(INPUT_SNAPSHOT_CASE!=1) begin
                if(INPUT_SNAPSHOT_CASE==9) begin
                    wait(m_axi_arvalid);
                    pulse_job_abort();
                    repeat(5) @(negedge clk);
                    if(!m_axi_arvalid || m_axi_arready || job_aborted_count!=0 || job_error_count!=0)
                        $fatal(1,"identity preflight cancel failed stalled-AR drain contract");
                    force_ar_block=0;
                    wait_for_aborted(1);
                    if(job_error_count!=0) $fatal(1,"identity mismatch overrode preflight cancellation");
                end else if(INPUT_SNAPSHOT_CASE==7 || INPUT_SNAPSHOT_CASE==8) begin
                    wait_for_error(1,INPUT_SNAPSHOT_CASE==7 ? 8'h10 : 8'h11,
                        INPUT_SNAPSHOT_CASE==7 ? INPUT_ENTRY_ADDRESS : OUTPUT_ENTRY_ADDRESS);
                    inject_axi_error=0;
                end else wait_for_error(1,8'h34,INPUT_FRAME_BASE);
                if(launch_count!=0 || job_done_count!=0)
                    $fatal(1,"input identity mismatch launched runtime");
                // A rejected table must not poison the next valid job.
                job_expected_input={1'b1,INPUT_FRAME_BASE,INPUT_STRIDE,INPUT_WIDTH,INPUT_HEIGHT};
                drive_job_command(RUNTIME_SUCCESS);
                job_expected_input='0;
            end
            wait_for_launch(1);wait_for_done(1);
            if(launch_count!=1) $fatal(1,"input identity recovery launch count");
            $display("C1_INPUT_SNAPSHOT_PASS mode=%0d geometry=%0d preview=%0d snapshot=1 recovery=1 launches=1",
                INPUT_SNAPSHOT_CASE,SEPARATE_INPUT_GEOMETRY,SNAPSHOT_PREVIEW);
            $finish;
        end
        pair_overlap_mode = 1'b0;
        inject_axi_error = 1'b0;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_SUCCESS);
        wait_for_launch(launch_snapshot + 1);
        if (active_config_generation != 1)
            $fatal(1, "first 22-stage commit did not advance generation");
        target = job_done_count + 1;
        wait_for_done(target);
        read_config_and_check(1, 0, 1);
        read_config_and_check(1, 21, 1);

        // 2. Config finishes first, then the deliberately late frame overlap
        // fails.  The completed config is a valid preloaded cache generation,
        // but the failed job must never launch.
        load_descriptors(2, -1);
        late_pair_failure_mode = 1'b1;
        generation_snapshot = active_config_generation;
        snapshot = config_commit_count;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_NONE);
        target = job_error_count + 1;
        wait_for_error(target, 8'h30, LATE_PAIR_OUTPUT_BASE);
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot + 1) ||
            (config_commit_count != snapshot + 1))
            $fatal(1, "late frame-pair failure cache/launch semantics mismatch");
        generation_snapshot = active_config_generation;
        read_config_and_check(2, 7, generation_snapshot);
        late_pair_failure_mode = 1'b0;

        // 3. Semantic descriptor failure is summarized as 0x40/base.
        load_descriptors(3, 7);
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_NONE);
        target = job_error_count + 1;
        wait_for_error(target, 8'h40, DESCRIPTOR_BASE);
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot))
            $fatal(1, "invalid descriptor launched or polluted config");
        read_config_and_check(2, 7, generation_snapshot);

        // 4. AXI SLVERR in a descriptor burst also cannot commit or launch.
        load_descriptors(4, -1);
        inject_axi_error = 1'b1;
        inject_axi_error_address = DESCRIPTOR_BASE + 5*64 + 2*16;
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_NONE);
        target = job_error_count + 1;
        wait_for_error(target, 8'h40, DESCRIPTOR_BASE);
        inject_axi_error = 1'b0;
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot))
            $fatal(1, "descriptor AXI fault launched or polluted config");

        // 5. An early RLAST is a descriptor protocol fault.  It must retire
        // without launch/commit and release the shared AXI arbiter.
        load_descriptors(5, -1);
        descriptor_rlast_mode = 1;
        descriptor_rlast_target = DESCRIPTOR_BASE + 4*64;
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_NONE);
        target = job_error_count + 1;
        wait_for_error(target, 8'h40, DESCRIPTOR_BASE);
        descriptor_rlast_mode = 0;
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot) ||
            (rlast_injection_count != 1))
            $fatal(1, "early RLAST fault did not retire cleanly");

        // 6. A full legal job immediately after early RLAST proves that the
        // read arbiter and descriptor path returned to service.
        load_descriptors(6, -1);
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_SUCCESS);
        wait_for_launch(launch_snapshot + 1);
        if (active_config_generation != generation_snapshot + 1)
            $fatal(1, "post-early-RLAST recovery config did not commit");
        generation_snapshot = active_config_generation;
        target = job_done_count + 1;
        wait_for_done(target);

        // 7. Missing RLAST on the ARLEN-implied fourth beat is also an error.
        // Both reader and arbiter must terminate by the known burst length.
        load_descriptors(7, -1);
        descriptor_rlast_mode = 2;
        descriptor_rlast_target = DESCRIPTOR_BASE + 4*64;
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_NONE);
        target = job_error_count + 1;
        wait_for_error(target, 8'h40, DESCRIPTOR_BASE);
        descriptor_rlast_mode = 0;
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot) ||
            (rlast_injection_count != 2) || burst_active || m_axi_rvalid)
            $fatal(1, "missing RLAST fault retained AXI ownership/state");

        // 8. The next legal job proves missing-RLAST recovery end-to-end.
        load_descriptors(8, -1);
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_SUCCESS);
        wait_for_launch(launch_snapshot + 1);
        if (active_config_generation != generation_snapshot + 1)
            $fatal(1, "post-missing-RLAST recovery config did not commit");
        generation_snapshot = active_config_generation;
        target = job_done_count + 1;
        wait_for_done(target);
        read_config_and_check(8, 21, generation_snapshot);

        // 9. Abort preflight while the arbiter-selected AR is stalled.  The
        // frontend must hold AR stable, commit it after READY returns, drain,
        // and report aborted without a generation change.
        load_descriptors(9, -1);
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        ar_snapshot = table_ar_count + descriptor_ar_count;
        drive_job_command(RUNTIME_NONE);
        guard = 0;
        while ((table_ar_count + descriptor_ar_count) < ar_snapshot + 2) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 10000)
                $fatal(1, "preflight did not begin AXI reads");
        end
        force_ar_block = 1'b1;
        guard = 0;
        while (!m_axi_arvalid) begin
            @(negedge clk);
            guard = guard + 1;
            if (guard > 10000)
                $fatal(1, "could not create stalled preflight AR");
        end
        pulse_job_abort();
        repeat (5) @(posedge clk);
        if (!m_axi_arvalid || m_axi_arready || job_aborted)
            $fatal(1, "stalled-AR abort did not wait for protocol-safe drain");
        force_ar_block = 1'b0;
        target = job_aborted_count + 1;
        wait_for_aborted(target);
        preflight_stalled_abort_checks = preflight_stalled_abort_checks + 1;
        if ((launch_count != launch_snapshot) ||
            (active_config_generation != generation_snapshot))
            $fatal(1, "preflight abort launched or polluted config");

        // 10. A launched abort cancels descriptor/engine, but both DMAs must
        // reach their delayed done events before job_aborted can pulse.
        load_descriptors(10, -1);
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_ABORT_DRAIN);
        wait_for_launch(launch_snapshot + 1);
        if (active_config_generation != generation_snapshot + 1)
            $fatal(1, "abort-job legal config did not commit");
        generation_snapshot = active_config_generation;
        while (runtime_cycle < 4)
            @(negedge clk);
        snapshot = job_aborted_count;
        pulse_job_abort();
        repeat (5) begin
            @(posedge clk);
            #1;
            if (job_aborted || !input_dma_busy || !output_dma_busy)
                $fatal(1, "post-launch abort retired before DMA drain");
        end
        wait_for_aborted(snapshot + 1);
        safe_dma_drain_checks = safe_dma_drain_checks + 1;
        read_config_and_check(10, 21, generation_snapshot);

        // 11. Simultaneous input-DMA and engine faults prove first-error
        // priority.  Input DMA (0x91) must be reported after output DMA drain.
        load_descriptors(11, -1);
        launch_snapshot = launch_count;
        drive_job_command(RUNTIME_PRIORITY);
        wait_for_launch(launch_snapshot + 1);
        if (active_config_generation != generation_snapshot + 1)
            $fatal(1, "priority-fault legal config did not commit");
        generation_snapshot = active_config_generation;
        target = job_error_count + 1;
        wait_for_error(target, 8'h91, 32'hdead_1000);
        read_config_and_check(11, 0, generation_snapshot);

        repeat (8) @(posedge clk);
        #1;
        if ((job_start_count != 11) || (launch_count != 5) ||
            (job_done_count != 3) || (job_error_count != 6) ||
            (job_aborted_count != 2) || (config_commit_count != 6) ||
            (active_config_generation != 6) ||
            (active_config_count != MAX_STAGES) ||
            (config_read_count != 7) ||
            (preflight_stalled_abort_checks != 1) ||
            (safe_dma_drain_checks != 1) ||
            (priority_error_injections != 1) ||
            (rlast_injection_count != 2) ||
            (descriptor_abort_count < 2) || (engine_abort_count < 2) ||
            (table_ar_count == 0) || (descriptor_ar_count < 150) ||
            (rbeat_count == 0) || (ar_stall_cycles == 0) ||
            (r_gap_cycles == 0) || busy || burst_active || m_axi_rvalid ||
            config_loading || config_read_busy || !job_start_ready)
            $fatal(1, "job frontend coverage mismatch starts=%0d launches=%0d done=%0d faults=%0d aborted=%0d commits=%0d generation=%0d reads=%0d table_ar=%0d desc_ar=%0d rbeats=%0d ar_stall=%0d r_gaps=%0d desc_aborts=%0d engine_aborts=%0d priority=%0d",
                   job_start_count, launch_count, job_done_count,
                   job_error_count, job_aborted_count, config_commit_count,
                   active_config_generation, config_read_count,
                   table_ar_count, descriptor_ar_count, rbeat_count,
                   ar_stall_cycles, r_gap_cycles, descriptor_abort_count,
                   engine_abort_count, priority_error_injections);

        $display("C1_R1_JOB_FRONTEND_PASS starts=%0d launches=%0d done=%0d faults=%0d aborted=%0d commits=%0d generation=%0d reads=%0d table_ar=%0d desc_ar=%0d rbeats=%0d ar_stalls=%0d r_gaps=%0d rlast_faults=%0d desc_aborts=%0d engine_aborts=%0d",
                 job_start_count, launch_count, job_done_count,
                 job_error_count, job_aborted_count, config_commit_count,
                 active_config_generation, config_read_count,
                 table_ar_count, descriptor_ar_count, rbeat_count,
                 ar_stall_cycles, r_gap_cycles, rlast_injection_count,
                 descriptor_abort_count, engine_abort_count);
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "global R1 job-frontend testbench timeout");
    end

endmodule
