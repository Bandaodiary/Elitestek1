`timescale 1ns/1ps

module tb_c1_r1_boardless_frame_system;
    logic [96:0] job_expected_input=0;
    wire region_request,region_cancel;
    logic region_response=0;
    logic [7:0] region_error_code=0;
    logic [31:0] region_error_address=0;
    logic clk = 1'b0;
    logic rst = 1'b1;
    parameter bit ENABLE_PREVIEW=0;
    parameter bit PREVIEW_CANCEL_TEST=0;
    parameter bit PREVIEW_ERROR_TEST=0;
    parameter bit PREVIEW_LAYOUT_TEST=0;
    parameter bit SUCCESS_DRAIN_CANCEL=0;
    logic [31:0] preview_request_base=32'h6000,preview_request_stride=32;
    wire layout_check_busy;
    generate if(ENABLE_PREVIEW) begin
        assign layout_check_busy=dut.u_job_frontend.g_preview_layout.check_busy;
    end else begin
        assign layout_check_busy=1'b0;
    end endgenerate
    logic preview_inject_b_error=0;
    logic preview_force_hold=0;
    integer preview_barrier_rearm_count=0;
    logic [31:0] job_preview_base=32'h6000,job_preview_stride=32;
    wire [31:0] preview_axi_awaddr;
    wire [7:0] preview_axi_awlen;wire [2:0] preview_axi_awsize;wire [1:0] preview_axi_awburst;
    wire preview_axi_awvalid,preview_axi_awready,preview_axi_wvalid,preview_axi_wready;
    wire [127:0] preview_axi_wdata;wire [15:0] preview_axi_wstrb;wire preview_axi_wlast;
    wire [1:0] preview_axi_bresp;
    logic preview_axi_bvalid=0;wire preview_axi_bready;
    logic preview_active=0,preview_pending=0;
    integer preview_aw_count=0,preview_w_count=0,preview_b_count=0,preview_delay=0;
    integer preview_beat=0,preview_row=0,preview_hold_cycles=0;
    assign preview_axi_bresp=(preview_inject_b_error&&preview_row==2) ? 2'b10 : 2'b00;
    assign preview_axi_awready=!preview_active&&!preview_pending&&!preview_axi_bvalid;
    assign preview_axi_wready=preview_active;
`ifdef C1_SEPARATE_INPUT_GEOMETRY
    parameter integer SEPARATE_INPUT_GEOMETRY=1;
`else
    parameter integer SEPARATE_INPUT_GEOMETRY=0;
`endif
    localparam logic [15:0] INPUT_HEIGHT=SEPARATE_INPUT_GEOMETRY ? 6 : 3;
    localparam logic [15:0] INPUT_WIDTH=SEPARATE_INPUT_GEOMETRY ? 12 : 8;
    localparam logic [31:0] INPUT_STRIDE=SEPARATE_INPUT_GEOMETRY ? 64 : 32;
    wire [15:0] job_input_width_pixels=INPUT_WIDTH;
    wire [15:0] job_input_height_lines=INPUT_HEIGHT;

    localparam integer MAX_WIDTH = 16;
    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;

    localparam logic [31:0] INPUT_TABLE_BASE  = 32'h0000_1000;
    localparam logic [31:0] OUTPUT_TABLE_BASE = 32'h0000_1100;
    localparam logic [31:0] DESCRIPTOR_BASE   = 32'h0000_2000;
    localparam logic [31:0] INPUT_FRAME_BASE  = 32'h0000_4000;
    localparam logic [31:0] OUTPUT_FRAME_BASE = 32'h0000_5000;
    localparam logic [1:0] INPUT_INDEX = 2'd1;
    localparam logic [1:0] OUTPUT_INDEX = 2'd0;
    localparam logic [15:0] FRAME_WIDTH = 16'd8;
    localparam logic [15:0] FRAME_HEIGHT = 16'd3;
    localparam logic [31:0] FRAME_STRIDE = 32'd32;

    localparam integer TERM_DONE = 0;
    localparam integer TERM_ERROR = 1;
    localparam integer TERM_ABORTED = 2;


    logic job_start_valid = 1'b0;
    logic job_start_ready;
    logic job_abort = 1'b0;
    logic [63:0] job_input_table_base = INPUT_TABLE_BASE;
    logic [63:0] job_output_table_base = OUTPUT_TABLE_BASE;
    logic [1:0] job_input_buffer_index = INPUT_INDEX;
    logic [1:0] job_output_buffer_index = OUTPUT_INDEX;
    logic [15:0] job_width_pixels = FRAME_WIDTH;
    logic [15:0] job_height_lines = FRAME_HEIGHT;
    logic [31:0] job_descriptor_base = DESCRIPTOR_BASE;
    logic [COUNT_BITS-1:0] job_descriptor_count = MAX_STAGES;
    logic [31:0] job_cycle_budget = 32'd200000;
    logic signed [31:0] job_x_step_q16 = SEPARATE_INPUT_GEOMETRY ? 32'sh0001_8000 : 32'sh0001_0000;
    logic signed [31:0] job_y_step_q16 = SEPARATE_INPUT_GEOMETRY ? 32'sh0002_0000 : 32'sh0001_0000;
    logic signed [31:0] job_x_phase0_q16 = SEPARATE_INPUT_GEOMETRY ? 32'sh4000 : 32'sd0;
    logic signed [31:0] job_y_phase0_q16 = SEPARATE_INPUT_GEOMETRY ? 32'sh8000 : 32'sd0;

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
    logic [31:0] resolved_preview_base,resolved_preview_stride;
    logic [15:0] resolved_output_width;
    logic [15:0] resolved_output_height;

    logic active_config_bank;
    logic [COUNT_BITS-1:0] active_config_count;
    logic [GENERATION_BITS-1:0] active_config_generation;
    logic stage_dispatch_complete;
    logic stage_config_valid;
    logic stage_config_ready;
    logic [COUNT_BITS-1:0] stage_config_index;
    logic [511:0] stage_config_descriptor;
    logic [GENERATION_BITS-1:0] stage_config_generation;

    logic cnn_start_valid;
    logic cnn_start_ready = 1'b1;
    logic cnn_abort;
    logic cnn_error = 1'b0;
    logic [7:0] cnn_error_code = 8'h25;
    logic cnn_in_valid;
    logic cnn_in_ready;
    logic [63:0] cnn_in_data_s8;
    logic [15:0] cnn_in_x;
    logic [15:0] cnn_in_y;
    logic cnn_in_sof;
    logic cnn_in_eol;
    logic cnn_in_eof;
    logic cnn_out_valid;
    logic cnn_out_ready;
    logic [63:0] cnn_out_data_s8;
    logic [15:0] cnn_out_x;
    logic [15:0] cnn_out_y;
    logic cnn_out_sof;
    logic cnn_out_eol;
    logic cnn_out_eof;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [1:0] m_axi_bresp = 2'b00;
    logic m_axi_bvalid = 1'b0;
    logic m_axi_bready;
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
    logic [7:0] output_bytes [0:255];

    logic pair_overlap_mode = 1'b0;
    logic inject_input_rresp = 1'b0;
    logic inject_output_bresp = 1'b0;
    logic hold_after_first_input_beat = 1'b0;
    integer corrupt_descriptor_index = -1;

    logic [31:0] prng = 32'h51c0_ffee;
    logic force_stage_stall = 1'b0;

    logic rd_active = 1'b0;
    logic [31:0] rd_base_q = 32'd0;
    logic [7:0] rd_len_q = 8'd0;
    logic [7:0] rd_beat_q = 8'd0;
    logic [3:0] rd_gap_q = 4'd0;

    logic wr_active = 1'b0;
    logic [31:0] wr_base_q = 32'd0;
    logic [7:0] wr_len_q = 8'd0;
    logic [7:0] wr_beat_q = 8'd0;
    logic b_pending_q = 1'b0;
    logic [3:0] b_gap_q = 4'd0;
    logic [1:0] bresp_q = 2'b00;

    logic loop_valid_q = 1'b0;
    logic [63:0] loop_data_q = 64'd0;
    logic [15:0] loop_x_q = 16'd0;
    logic [15:0] loop_y_q = 16'd0;
    logic loop_sof_q = 1'b0;
    logic loop_eol_q = 1'b0;
    logic loop_eof_q = 1'b0;
    logic cnn_job_active_q = 1'b0;
    logic prebarrier_poison_valid;

    integer accepted_jobs = 0;
    integer done_jobs = 0;
    integer error_jobs = 0;
    integer aborted_jobs = 0;
    integer launch_count = 0;
    integer stage_count = 0;
    integer total_stage_count = 0;
    integer cnn_input_count = 0;
    integer cnn_output_count = 0;
    integer ar_count = 0;
    integer input_ar_count = 0;
    integer descriptor_ar_count = 0;
    integer table_ar_count = 0;
    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;
    integer ar_stall_count = 0;
    integer r_gap_count = 0;
    integer aw_stall_count = 0;
    integer w_stall_count = 0;
    integer stage_stall_count = 0;
    integer cnn_stall_count = 0;
    integer config_barrier_checks = 0;
    integer reverse_barrier_checks = 0;
    integer completed_dispatch_count = 0;
    integer cancel_drain_checks = 0;
    integer input_rbeat_count = 0;
    integer mid_read_abort_checks = 0;
    integer rw_overlap_cycles = 0;

    integer i;
    integer j;
    integer target;
    integer launch_snapshot;
    integer aw_snapshot;
    integer runtime_start_count=0,runtime_start_snapshot=0;
    integer input_rbeat_snapshot;
    integer generation_snapshot;

    logic previous_ar_stall = 1'b0;
    logic [44:0] previous_ar_payload = '0;
    logic previous_aw_stall = 1'b0;
    logic [44:0] previous_aw_payload = '0;
    logic previous_w_stall = 1'b0;
    logic [144:0] previous_w_payload = '0;
    logic previous_dispatch_complete = 1'b0;

    always #5 clk = ~clk;
    integer aw_wait_age=0;
    always @(posedge clk) begin
        if(rst || !m_axi_awvalid || (m_axi_awvalid && m_axi_awready)) aw_wait_age<=0;
        else if(aw_wait_age<3) aw_wait_age<=aw_wait_age+1;
    end

    c1_r1_boardless_frame_system #(
        .ENABLE_PREVIEW(ENABLE_PREVIEW),.PREVIEW_REGION_BEGIN(33'h6000),.PREVIEW_REGION_END(33'h6060),
        .SEPARATE_INPUT_GEOMETRY(SEPARATE_INPUT_GEOMETRY),
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .READ_TIMEOUT_CYCLES(64),
        .SYNC_READ(1'b1),
        .FAST_WIDE(1'b0)
    ) dut (.*);

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

    function automatic [31:0] expected_pixel_word(
        input integer x,
        input integer y
    );
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            r = 8'd17 + x * 8'd31 + y * 8'd7;
            g = 8'd29 + x * 8'd13 + y * 8'd19;
            b = 8'd43 + x * 8'd5 + y * 8'd23;
            expected_pixel_word = {8'h00, r, g, b};
        end
    endfunction

    function automatic [127:0] table_entry(
        input logic [31:0] base_address
    );
        begin
            table_entry = {FRAME_HEIGHT, FRAME_WIDTH, FRAME_STRIDE,
                           32'd0, base_address};
        end
    endfunction

    function automatic [127:0] read_lookup(input logic [31:0] address);
        integer descriptor_index;
        integer descriptor_beat;
        integer row;
        integer beat_in_row;
        integer first_x;
        logic [31:0] word0;
        logic [31:0] word1;
        logic [31:0] word2;
        logic [31:0] word3;
        begin
            read_lookup = 128'd0;
            if (address == INPUT_TABLE_BASE + 32'd16) begin
                read_lookup = {INPUT_HEIGHT,INPUT_WIDTH,INPUT_STRIDE,32'd0,INPUT_FRAME_BASE};
            end else if (address == OUTPUT_TABLE_BASE) begin
                read_lookup = table_entry(pair_overlap_mode ?
                                          INPUT_FRAME_BASE :
                                          OUTPUT_FRAME_BASE);
            end else if ((address >= DESCRIPTOR_BASE) &&
                         (address < DESCRIPTOR_BASE + MAX_STAGES*64)) begin
                descriptor_index = (address - DESCRIPTOR_BASE) >> 6;
                descriptor_beat = ((address - DESCRIPTOR_BASE) >> 4) & 3;
                read_lookup = descriptor_memory[descriptor_index]
                              [descriptor_beat*128 +: 128];
            end else if ((address >= INPUT_FRAME_BASE) &&
                         (address < INPUT_FRAME_BASE +
                          INPUT_HEIGHT*INPUT_STRIDE)) begin
                row = (address - INPUT_FRAME_BASE) / INPUT_STRIDE;
                beat_in_row = ((address - INPUT_FRAME_BASE) %
                               INPUT_STRIDE) >> 4;
                first_x = beat_in_row * 4;
                word0 = expected_pixel_word(first_x, row);
                word1 = expected_pixel_word(first_x + 1, row);
                word2 = expected_pixel_word(first_x + 2, row);
                word3 = expected_pixel_word(first_x + 3, row);
                read_lookup = {word3, word2, word1, word0};
                if(first_x>=INPUT_WIDTH) read_lookup={4{32'h00dead55}};
            end
        end
    endfunction

    task automatic load_descriptor_batch(
        input integer batch_tag,
        input integer corrupt_index
    );
        begin
            corrupt_descriptor_index = corrupt_index;
            for (i = 0; i < MAX_STAGES; i = i + 1) begin
                descriptor_memory[i] = legal_descriptor(batch_tag, i);
                if (i == corrupt_index)
                    descriptor_memory[i][7:0] = 8'hff;
            end
        end
    endtask

    task automatic clear_output_memory;
        begin
            for (i = 0; i < 256; i = i + 1)
                output_bytes[i] = 8'hcc;
        end
    endtask

    task automatic start_job;
        begin
            @(negedge clk);
            if(ENABLE_PREVIEW) begin
                if(preview_active||preview_pending||preview_axi_bvalid) $fatal(1,"preview BFM reused before drain");
                job_preview_base=preview_request_base;job_preview_stride=preview_request_stride;
                preview_aw_count=0;preview_w_count=0;preview_b_count=0;
                preview_hold_cycles=0;preview_row=0;preview_beat=0;
            end
            job_start_valid = 1'b1;
            while (!job_start_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            job_start_valid = 1'b0;
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            job_abort = 1'b1;
            @(posedge clk);
            @(negedge clk);
            job_abort = 1'b0;
        end
    endtask

    task automatic pulse_cnn_error;
        begin
            @(negedge clk);
            cnn_error = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cnn_error = 1'b0;
        end
    endtask

    task automatic wait_terminal(
        input integer expected_kind,
        input logic [7:0] expected_code,
        input logic [31:0] expected_address
    );
        integer guard;
        begin
            guard = 0;
            while (!job_done && !job_error && !job_aborted) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard == 10000) begin
                    $display("TERMINAL_PROGRESS busy=%0b state=%0d launch=%0d stage=%0d dispatch=%0b/%0b/%0b dma=%0b/%0b compute=%0b/%0b/%0b cnn=%0d/%0d writer_state=%0d axi=%0b%0b%0b%0b%0b",
                             busy, dut.u_job_frontend.u_job_controller.state,
                             launch_count, stage_count,
                             stage_dispatch_complete, dut.dispatcher_busy,
                             dut.dispatcher_done, dut.input_dma_busy,
                             dut.output_dma_busy, dut.compute_busy,
                             dut.compute_done, dut.compute_error,
                             cnn_input_count, cnn_output_count,
                             dut.u_output_dma.state, m_axi_arvalid,
                             m_axi_rvalid, m_axi_awvalid, m_axi_wvalid,
                             m_axi_bvalid);
                    $display("TERMINAL_PROGRESS source=%0b/%0b ingress=%0b/%0b/%0b egress=%0b/%0b seen=%0b%0b%0b resize=%0b req=%0b%0b rsp=%0b%0b sampler=%0b/%0b/%0b",
                             dut.u_compute_shell.source_busy,
                             dut.u_compute_shell.source_done,
                             dut.u_compute_shell.ingress_busy,
                             dut.u_compute_shell.ingress_done,
                             dut.u_compute_shell.ingress_error,
                             dut.u_compute_shell.egress_busy,
                             dut.u_compute_shell.egress_done,
                             dut.u_compute_shell.source_done_seen,
                             dut.u_compute_shell.ingress_done_seen,
                             dut.u_compute_shell.egress_done_seen,
                             dut.u_compute_shell.u_compute_ingress.resize_busy,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_req_valid,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_req_ready,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_valid,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_ready,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_busy,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_done,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_error);
                    $display("TERMINAL_PROGRESS writer state=%0d aw_vr=%0b%0b w_vr=%0b%0b b_vr=%0b%0b external awready/wready=%0b/%0b wr_active=%0b loop=%0b cnn_out_ready=%0b shell_out_vr=%0b%0b",
                             dut.u_output_dma.state, m_axi_awvalid,
                             m_axi_awready, m_axi_wvalid,
                             m_axi_wready, m_axi_bvalid,
                             m_axi_bready,
                             m_axi_awready, m_axi_wready, wr_active,
                             loop_valid_q, cnn_out_ready,
                             dut.shell_out_valid, dut.shell_out_ready);
                    $display("TERMINAL_PROGRESS resize out_vr=%0b%0b codec_vr=%0b%0b egress in_vr=%0b%0b out_vr=%0b%0b sampler rsp=%h/%h/%h/%h",
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.resize_out_valid,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.resize_out_ready,
                             dut.u_compute_shell.u_compute_ingress.codec_valid,
                             dut.u_compute_shell.u_compute_ingress.codec_ready,
                             dut.u_compute_shell.u_compute_egress.in_valid,
                             dut.u_compute_shell.u_compute_egress.in_ready,
                             dut.u_compute_shell.u_compute_egress.out_valid,
                             dut.u_compute_shell.u_compute_egress.out_ready,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_rgb_y0x0,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_rgb_y0x1,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_rgb_y1x0,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_rgb_y1x1);
                end
                if (guard > 200000) begin
                    $display("TERMINAL_TIMEOUT busy=%0b ready=%0b launch=%0d stage=%0d dispatch=%0b/%0b/%0b",
                             busy, job_start_ready, launch_count, stage_count,
                             stage_dispatch_complete,
                             dut.dispatcher_busy, dut.dispatcher_done);
                    $display("TERMINAL_TIMEOUT dma_in busy/done/err=%0b/%0b/%0b stream_vr=%0b%0b dma_out busy/done/err=%0b/%0b/%0b shell_vr=%0b%0b",
                             dut.input_dma_busy, dut.input_dma_done,
                             dut.input_dma_error_raw, dut.input_stream_valid,
                             dut.input_stream_ready, dut.output_dma_busy,
                             dut.output_dma_done, dut.output_dma_error_raw,
                             dut.shell_out_valid, dut.shell_out_ready);
                    $display("TERMINAL_TIMEOUT compute busy/done/err=%0b/%0b/%0b source=%0b/%0b ingress=%0b/%0b/%0b egress=%0b/%0b seen=%0b%0b%0b",
                             dut.compute_busy, dut.compute_done,
                             dut.compute_error,
                             dut.u_compute_shell.source_busy,
                             dut.u_compute_shell.source_done,
                             dut.u_compute_shell.ingress_busy,
                             dut.u_compute_shell.ingress_done,
                             dut.u_compute_shell.ingress_error,
                             dut.u_compute_shell.egress_busy,
                             dut.u_compute_shell.egress_done,
                             dut.u_compute_shell.source_done_seen,
                             dut.u_compute_shell.ingress_done_seen,
                             dut.u_compute_shell.egress_done_seen);
                    $display("TERMINAL_TIMEOUT cnn in_vr=%0b%0b out_vr=%0b%0b loop=%0b counts=%0d/%0d axi rd/wr=%0b/%0b arv=%0b rv=%0b awv=%0b wv=%0b bv=%0b",
                             cnn_in_valid, cnn_in_ready,
                             cnn_out_valid, cnn_out_ready, loop_valid_q,
                             cnn_input_count, cnn_output_count,
                             rd_active, wr_active, m_axi_arvalid,
                             m_axi_rvalid, m_axi_awvalid, m_axi_wvalid,
                             m_axi_bvalid);
                    $display("TERMINAL_TIMEOUT resize active/busy/err=%0b/%0b/%0b sampler busy/done/err=%0b/%0b/%0b req_vr=%0b%0b rsp_vr=%0b%0b",
                             dut.u_compute_shell.u_compute_ingress.ingress_active,
                             dut.u_compute_shell.u_compute_ingress.resize_busy,
                             dut.u_compute_shell.u_compute_ingress.resize_error,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_busy,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_done,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sampler_error,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_req_valid,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_req_ready,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_valid,
                             dut.u_compute_shell.u_compute_ingress.u_resize_pipeline.sample_rsp_ready);
                    $fatal(1, "job terminal timeout kind=%0d", expected_kind);
                end
            end
            case (expected_kind)
                TERM_DONE: begin
                    if (!job_done || job_error || job_aborted)
                        $fatal(1, "expected job_done");
                end
                TERM_ERROR: begin
                    if (!job_error || job_done || job_aborted)
                        $fatal(1, "expected job_error");
                    if ((error_code !== expected_code) ||
                        (error_address !== expected_address))
                        $fatal(1, "error payload mismatch expected=%02x/%08x got=%02x/%08x",
                               expected_code, expected_address,
                               error_code, error_address);
                end
                TERM_ABORTED: begin
                    if (!job_aborted || job_done || job_error)
                        $fatal(1, "expected job_aborted");
                end
                default: $fatal(1, "bad expected terminal kind");
            endcase
            @(negedge clk);
            if (busy || !job_start_ready || rd_active || wr_active ||
                m_axi_rvalid || m_axi_bvalid)
                $fatal(1, "terminal preceded restartable AXI/client idle");
        end
    endtask

    task automatic wait_launch(input integer expected_launch_count);
        integer guard;
        begin
            guard = 0;
            while (launch_count < expected_launch_count) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    $fatal(1, "launch timeout expected=%0d got=%0d",
                           expected_launch_count, launch_count);
            end
        end
    endtask

    task automatic verify_output_frame;
        logic [31:0] actual;
        logic [31:0] expected;
        logic [31:0] top_pixel,bottom_pixel,top_right,bottom_right;
        integer sample_x,weight_x,top_value,bottom_value;
        integer offset;
        begin
            if(resolved_input_width!==INPUT_WIDTH || resolved_input_height!==INPUT_HEIGHT ||
               resolved_input_stride!==INPUT_STRIDE || resolved_output_width!==FRAME_WIDTH ||
               resolved_output_height!==FRAME_HEIGHT || resolved_output_stride!==FRAME_STRIDE)
                $fatal(1,"resolved DMA geometry/stride mismatch");
            for (j = 0; j < FRAME_HEIGHT; j = j + 1) begin
                for (i = 0; i < FRAME_WIDTH; i = i + 1) begin
                    offset = j * FRAME_STRIDE + i * 4;
                    actual = {output_bytes[offset+3], output_bytes[offset+2],
                              output_bytes[offset+1], output_bytes[offset]};
                    expected = expected_pixel_word(i, j);
                    if(SEPARATE_INPUT_GEOMETRY) begin
                        // Centre aligned x=1.5*i+0.25, y=2*j+0.5.
                        // Independently round horizontal quarters, then vertical halves.
                        sample_x=(6*i+1)/4; weight_x=(6*i+1)%4;
                        top_pixel=expected_pixel_word(sample_x,2*j);
                        bottom_pixel=expected_pixel_word(sample_x,2*j+1);
                        top_right=expected_pixel_word(sample_x+1,2*j);
                        bottom_right=expected_pixel_word(sample_x+1,2*j+1);
                        for(integer channel=0;channel<3;channel=channel+1) begin
                            top_value=((4-weight_x)*int'(top_pixel[channel*8 +: 8])+
                                       weight_x*int'(top_right[channel*8 +: 8])+2)/4;
                            bottom_value=((4-weight_x)*int'(bottom_pixel[channel*8 +: 8])+
                                          weight_x*int'(bottom_right[channel*8 +: 8])+2)/4;
                            expected[channel*8 +: 8]=(top_value+bottom_value+1)/2;
                        end
                    end
                    if (actual !== expected)
                        $fatal(1, "output mismatch x=%0d y=%0d expected=%08x got=%08x",
                               i, j, expected, actual);
                end
            end
            for(integer guard_byte=FRAME_HEIGHT*FRAME_STRIDE;guard_byte<256;guard_byte=guard_byte+1)
                if(output_bytes[guard_byte]!==8'hcc)
                    $fatal(1,"output writer modified frame guard byte %0d",guard_byte);
            $display("C1_NUM_FRAME_GEOMETRY input=%0dx%0d output=%0dx%0d stride=%0d/%0d pixels=%0d guard_bytes=%0d",
                     INPUT_WIDTH,INPUT_HEIGHT,FRAME_WIDTH,FRAME_HEIGHT,INPUT_STRIDE,FRAME_STRIDE,
                     FRAME_WIDTH*FRAME_HEIGHT,256-FRAME_HEIGHT*FRAME_STRIDE);
        end
    endtask

    // Drive AXI READY only on the falling edge.  Besides being a legal AXI
    // slave behaviour, this keeps READY stable for a full setup/hold window
    // around the rising-edge handshakes through both arbiter levels.
    always_ff @(negedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_awready <= 1'b0;
            m_axi_wready <= 1'b0;
        end else begin
            m_axi_arready <= !rd_active && !m_axi_rvalid &&
                             (prng[2:0] != 3'b000);
            m_axi_awready <= (aw_wait_age>=2) && !wr_active && !b_pending_q &&
                             !m_axi_bvalid && (prng[5:3] != 3'b000);
            m_axi_wready <= wr_active && (prng[8:6] != 3'b000);
        end
    end
    assign stage_config_ready = !force_stage_stall &&
                                (prng[11:9] != 3'b000);
    assign cnn_in_ready = !loop_valid_q && (prng[14:12] != 3'b000);
    assign prebarrier_poison_valid = cnn_job_active_q &&
                                     !stage_dispatch_complete;
    assign cnn_out_valid = prebarrier_poison_valid || loop_valid_q;
    assign cnn_out_data_s8 = prebarrier_poison_valid ?
                             64'hde_ad_be_ef_80_80_80_80 : loop_data_q;
    assign cnn_out_x = prebarrier_poison_valid ? 16'hfffe : loop_x_q;
    assign cnn_out_y = prebarrier_poison_valid ? 16'hfffd : loop_y_q;
    assign cnn_out_sof = prebarrier_poison_valid ? 1'b1 : loop_sof_q;
    assign cnn_out_eol = prebarrier_poison_valid ? 1'b1 : loop_eol_q;
    assign cnn_out_eof = prebarrier_poison_valid ? 1'b1 : loop_eof_q;

    always_ff @(posedge clk) begin
        if (rst || cnn_abort) begin
            cnn_job_active_q <= 1'b0;
        end else begin
            if (cnn_start_valid && cnn_start_ready)
                cnn_job_active_q <= 1'b1;
            if (job_done || job_error || job_aborted)
                cnn_job_active_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            prng <= 32'h51c0_ffee;
        end else begin
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
        end
    end

    // ID-less AXI read slave with randomized AR acceptance and R gaps.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_active <= 1'b0;
            rd_base_q <= 32'd0;
            rd_len_q <= 8'd0;
            rd_beat_q <= 8'd0;
            rd_gap_q <= 4'd0;
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= 128'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                if ((m_axi_arsize != 3'd4) ||
                    (m_axi_arburst != 2'b01))
                    $fatal(1, "unexpected AXI read attributes");
                rd_active <= 1'b1;
                rd_base_q <= m_axi_araddr;
                rd_len_q <= m_axi_arlen;
                rd_beat_q <= 8'd0;
                rd_gap_q <= {2'd0, prng[17:16]};
                ar_count = ar_count + 1;
                if ((m_axi_araddr == INPUT_TABLE_BASE + 32'd16) ||
                    (m_axi_araddr == OUTPUT_TABLE_BASE))
                    table_ar_count = table_ar_count + 1;
                else if ((m_axi_araddr >= DESCRIPTOR_BASE) &&
                         (m_axi_araddr < DESCRIPTOR_BASE + MAX_STAGES*64))
                    descriptor_ar_count = descriptor_ar_count + 1;
                else if ((m_axi_araddr >= INPUT_FRAME_BASE) &&
                         (m_axi_araddr < INPUT_FRAME_BASE +
                          INPUT_HEIGHT*INPUT_STRIDE))
                    input_ar_count = input_ar_count + 1;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                if (rd_beat_q == rd_len_q) begin
                    rd_active <= 1'b0;
                end else begin
                    rd_beat_q <= rd_beat_q + 1'b1;
                    if (hold_after_first_input_beat &&
                        (rd_base_q >= INPUT_FRAME_BASE) &&
                        (rd_base_q < INPUT_FRAME_BASE +
                         INPUT_HEIGHT*INPUT_STRIDE) &&
                        (rd_beat_q == 0))
                        rd_gap_q <= 4'd8;
                    else
                        rd_gap_q <= {2'd0, prng[19:18]};
                end
                if ((rd_base_q >= INPUT_FRAME_BASE) &&
                    (rd_base_q < INPUT_FRAME_BASE +
                     INPUT_HEIGHT*INPUT_STRIDE))
                    input_rbeat_count = input_rbeat_count + 1;
            end else if (!m_axi_rvalid && rd_active) begin
                if (rd_gap_q != 0) begin
                    rd_gap_q <= rd_gap_q - 1'b1;
                    r_gap_count = r_gap_count + 1;
                end else begin
                    m_axi_rdata <= read_lookup(rd_base_q +
                                              ({24'd0, rd_beat_q} << 4));
                    if (inject_input_rresp &&
                        (rd_base_q >= INPUT_FRAME_BASE) &&
                        (rd_base_q < INPUT_FRAME_BASE +
                         INPUT_HEIGHT*INPUT_STRIDE))
                        m_axi_rresp <= 2'b10;
                    else
                        m_axi_rresp <= 2'b00;
                    m_axi_rlast <= (rd_beat_q == rd_len_q);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    // ID-less AXI write slave.  It records byte lanes in the output window.
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_active <= 1'b0;
            wr_base_q <= 32'd0;
            wr_len_q <= 8'd0;
            wr_beat_q <= 8'd0;
            b_pending_q <= 1'b0;
            b_gap_q <= 4'd0;
            bresp_q <= 2'b00;
            m_axi_bvalid <= 1'b0;
            m_axi_bresp <= 2'b00;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                if ((m_axi_awsize != 3'd4) ||
                    (m_axi_awburst != 2'b01))
                    $fatal(1, "unexpected AXI write attributes");
                wr_active <= 1'b1;
                wr_base_q <= m_axi_awaddr;
                wr_len_q <= m_axi_awlen;
                wr_beat_q <= 8'd0;
                aw_count = aw_count + 1;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                if (!wr_active)
                    $fatal(1, "W beat without an accepted AW");
                if (m_axi_wlast !== (wr_beat_q == wr_len_q))
                    $fatal(1, "WLAST mismatch");
                for (i = 0; i < 16; i = i + 1) begin
                    if (m_axi_wstrb[i] &&
                        (wr_base_q + wr_beat_q*16 + i >= OUTPUT_FRAME_BASE) &&
                        (wr_base_q + wr_beat_q*16 + i < OUTPUT_FRAME_BASE+256))
                        output_bytes[wr_base_q + wr_beat_q*16 + i -
                                     OUTPUT_FRAME_BASE] = m_axi_wdata[i*8 +: 8];
                end
                w_count = w_count + 1;
                if (wr_beat_q == wr_len_q) begin
                    wr_active <= 1'b0;
                    b_pending_q <= 1'b1;
                    b_gap_q <= {2'd0, prng[22:21]};
                    bresp_q <= inject_output_bresp ? 2'b10 : 2'b00;
                end else begin
                    wr_beat_q <= wr_beat_q + 1'b1;
                end
            end

            if (b_pending_q && !m_axi_bvalid) begin
                if (b_gap_q != 0)
                    b_gap_q <= b_gap_q - 1'b1;
                else begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bresp <= bresp_q;
                    b_pending_q <= 1'b0;
                end
            end
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                b_count = b_count + 1;
            end
        end
    end

    // One-beat elastic external-CNN loopback.
    always_ff @(posedge clk) begin
        if (rst || cnn_abort) begin
            loop_valid_q <= 1'b0;
            loop_data_q <= 64'd0;
            loop_x_q <= 16'd0;
            loop_y_q <= 16'd0;
            loop_sof_q <= 1'b0;
            loop_eol_q <= 1'b0;
            loop_eof_q <= 1'b0;
        end else begin
            if (loop_valid_q && cnn_out_ready) begin
                loop_valid_q <= 1'b0;
                cnn_output_count = cnn_output_count + 1;
            end
            if (cnn_in_valid && cnn_in_ready) begin
                if (loop_valid_q)
                    $fatal(1, "CNN loopback overflow");
                loop_valid_q <= 1'b1;
                loop_data_q <= cnn_in_data_s8;
                loop_x_q <= cnn_in_x;
                loop_y_q <= cnn_in_y;
                loop_sof_q <= cnn_in_sof;
                loop_eol_q <= cnn_in_eol;
                loop_eof_q <= cnn_in_eof;
                cnn_input_count = cnn_input_count + 1;
                if (!stage_dispatch_complete || (stage_count != MAX_STAGES))
                    $fatal(1, "CNN input preceded complete stage dispatch");
                config_barrier_checks = config_barrier_checks + 1;
            end
        end
    end

    // End-to-end scoreboard and protocol-stability checks.
    always_ff @(posedge clk) begin
        if (rst) begin
            accepted_jobs = 0;
            done_jobs = 0;
            error_jobs = 0;
            aborted_jobs = 0;
            launch_count = 0;
            stage_count = 0;
            previous_ar_stall <= 1'b0;
            previous_aw_stall <= 1'b0;
            previous_w_stall <= 1'b0;
            previous_dispatch_complete <= 1'b0;
        end else begin
            if (job_start_valid && job_start_ready)
                accepted_jobs = accepted_jobs + 1;
            if (job_done)
                done_jobs = done_jobs + 1;
            if (job_error)
                error_jobs = error_jobs + 1;
            if (job_aborted)
                aborted_jobs = aborted_jobs + 1;

            if (cnn_start_valid && cnn_start_ready) begin
                launch_count = launch_count + 1;
                stage_count = 0;
            end
            if (stage_config_valid && stage_config_ready) begin
                if (stage_config_index !== stage_count[COUNT_BITS-1:0])
                    $fatal(1, "stage index mismatch expected=%0d got=%0d",
                           stage_count, stage_config_index);
                if (stage_config_descriptor !== descriptor_memory[stage_count])
                    $fatal(1, "stage descriptor mismatch index=%0d", stage_count);
                if (stage_config_generation !== active_config_generation)
                    $fatal(1, "stage generation mismatch");
                stage_count = stage_count + 1;
                total_stage_count = total_stage_count + 1;
            end
            if (stage_dispatch_complete && (stage_count != MAX_STAGES))
                $fatal(1, "dispatch complete before all stage transfers");
            if (stage_dispatch_complete && !previous_dispatch_complete)
                completed_dispatch_count = completed_dispatch_count + 1;
            previous_dispatch_complete <= stage_dispatch_complete;

            // Actively present an invalid external-CNN output before every
            // descriptor batch completes.  The top must keep READY low so
            // the poison beat can never enter compute egress.
            if (prebarrier_poison_valid) begin
                reverse_barrier_checks = reverse_barrier_checks + 1;
                if (cnn_out_ready)
                    $fatal(1, "CNN output poison accepted before config barrier");
            end

            if (rd_active && (wr_active || m_axi_awvalid ||
                              m_axi_wvalid || m_axi_bvalid))
                rw_overlap_cycles = rw_overlap_cycles + 1;

            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_count = ar_stall_count + 1;
            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_count = aw_stall_count + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_count = w_stall_count + 1;
            if (stage_config_valid && !stage_config_ready)
                stage_stall_count = stage_stall_count + 1;
            if (cnn_in_valid && !cnn_in_ready)
                cnn_stall_count = cnn_stall_count + 1;

            if (previous_ar_stall &&
                ({m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,
                  m_axi_arvalid} !== previous_ar_payload))
                $fatal(1, "AR payload changed while stalled");
            if (previous_aw_stall &&
                ({m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,
                  m_axi_awvalid} !== previous_aw_payload))
                $fatal(1, "AW payload changed while stalled");
            if (previous_w_stall &&
                ({m_axi_wdata,m_axi_wstrb,m_axi_wlast,m_axi_wvalid} !==
                 previous_w_payload))
                $fatal(1, "W payload changed while stalled");
            previous_ar_stall <= m_axi_arvalid && !m_axi_arready;
            previous_aw_stall <= m_axi_awvalid && !m_axi_awready;
            previous_w_stall <= m_axi_wvalid && !m_axi_wready;
            previous_ar_payload <= {m_axi_araddr,m_axi_arlen,m_axi_arsize,
                                    m_axi_arburst,m_axi_arvalid};
            previous_aw_payload <= {m_axi_awaddr,m_axi_awlen,m_axi_awsize,
                                    m_axi_awburst,m_axi_awvalid};
            previous_w_payload <= {m_axi_wdata,m_axi_wstrb,m_axi_wlast,
                                   m_axi_wvalid};

            if ((job_done || job_error || job_aborted) &&
                (m_axi_arvalid || m_axi_rvalid || m_axi_awvalid ||
                 m_axi_wvalid || m_axi_bvalid || rd_active || wr_active))
                $fatal(1, "job terminal preceded AXI drain");
        end
    end

    always @(posedge clk) if(!rst&&ENABLE_PREVIEW) begin
        if(dut.input_dma_start||dut.output_dma_start||dut.engine_start)
            runtime_start_count<=runtime_start_count+1;
        if(job_start_valid&&job_start_ready) begin
            if(stage_dispatch_complete) $fatal(1,"previous dispatch barrier open at new admission");
            if(dut.dispatch_complete_q) preview_barrier_rearm_count<=preview_barrier_rearm_count+1;
            job_preview_base<=32'hbad00000;job_preview_stride<=16;
        end
        if(preview_axi_awvalid&&preview_axi_awready) begin
            if(preview_axi_awaddr!==32'(32'h6000+preview_aw_count*32)||preview_axi_awlen!==1||
               preview_axi_awsize!==4||preview_axi_awburst!==1) $fatal(1,"boardless preview AW mismatch");
            preview_active<=1;preview_beat<=0;preview_row<=preview_aw_count;
            preview_aw_count<=preview_aw_count+1;
        end
        if(preview_axi_wvalid&&preview_axi_wready) begin
            if(preview_axi_wstrb!==16'hffff||preview_axi_wlast!==(preview_beat==1)) $fatal(1,"boardless preview W shape");
            for(integer lane=0;lane<4;lane++)
                if(preview_axi_wdata[lane*32+:32]!==expected_pixel_word(preview_beat*4+lane,preview_row))
                    $fatal(1,"boardless preview golden mismatch");
            preview_w_count<=preview_w_count+1;preview_beat<=preview_beat+1;
            if(preview_axi_wlast) begin
                preview_active<=0;preview_pending<=1;preview_delay<=(preview_row==2 ? 64 : 3);
            end
        end
        if(preview_pending) begin
            if(preview_force_hold&&preview_row==2) begin
                if(!busy||job_done||job_error||job_aborted) $fatal(1,"preview terminal before held B");
            end else if(preview_delay>0) begin
                preview_delay<=preview_delay-1;
                if(preview_row==2) begin
                    preview_hold_cycles<=preview_hold_cycles+1;
                    if(job_done||!busy) $fatal(1,"boardless job retired before preview B");
                end
            end else begin preview_pending<=0;preview_axi_bvalid<=1;end
        end
        if(preview_axi_bvalid&&preview_axi_bready) begin
            preview_axi_bvalid<=0;preview_b_count<=preview_b_count+1;
        end
    end
    task automatic check_success_drain_cancel;
        integer guard,generation_before;
        begin
            if(ENABLE_PREVIEW) begin
                if(preview_aw_count!=3 || preview_w_count!=6 || preview_b_count!=3 || preview_hold_cycles!=64)
                    $fatal(1,"initial preview was not physically retired");
                $display("C1_BOARDLESS_PREVIEW_PASS pixels=24 aw=3 w=6 b=3 final_B_hold=64");
            end
            generation_before=active_config_generation;
            load_descriptor_batch(2,-1);clear_output_memory();start_job();guard=0;
            while(!(dut.u_job_frontend.u_job_controller.state==dut.u_job_frontend.u_job_controller.STATE_DRAIN &&
                    dut.u_job_frontend.u_job_controller.drain_for_success)) begin
                @(negedge clk);guard++;
                if(guard>100000)$fatal(1,"real boardless success-drain boundary not reached");
            end
            // Drive the public abort now, not through pulse_abort's next-edge
            // wait: this is the last cancellable edge before job publication.
            job_abort=1;job_start_valid=1;#1;
            if(job_done || job_start_ready || !busy || aw_count!=b_count || wr_active || rd_active)
                $fatal(1,"success-drain cancellation lacked private, retired frame ownership");
            @(posedge clk);#1;
            if(job_done)$fatal(1,"boardless published success on its cancellation edge");
            @(negedge clk);job_abort=0;job_start_valid=0;
            wait_terminal(TERM_ABORTED,0,0);
            if(accepted_jobs!=2 || done_jobs!=1 || aborted_jobs!=1 || error_jobs!=0 ||
               active_config_generation!=generation_before+1 || aw_count!=b_count)
                $fatal(1,"late boardless cancel counted/reallocated a false completed frame");
            load_descriptor_batch(3,-1);clear_output_memory();start_job();
            wait_terminal(TERM_DONE,0,0);verify_output_frame();
            if(accepted_jobs!=3 || done_jobs!=2 || aborted_jobs!=1 || error_jobs!=0 ||
               active_config_generation!=generation_before+2 || aw_count!=b_count)
                $fatal(1,"late boardless cancel no-reset recovery mismatch");
            $display("C1_BOARDLESS_SUCCESS_DRAIN_CANCEL_PASS preview=%0d jobs=3 done=2 aborted=1 errors=0 rejected_restart=1 recovery_pixels=24 reset=0",ENABLE_PREVIEW);
            $display("C1_R1_BOARDLESS_FRAME_SYSTEM_PASS success_drain_cancel=1 preview=%0d jobs=3",ENABLE_PREVIEW);
        end
    endtask

    initial begin
        clear_output_memory();
        load_descriptor_batch(1, -1);
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);
        if (!job_start_ready || busy)
            $fatal(1, "boardless top did not reset idle");

        // 1. Successful end-to-end frame with randomized AXI/stage/CNN stalls.
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        wait_terminal(TERM_DONE, 8'd0, 32'd0);
        if (active_config_generation != generation_snapshot + 1'b1)
            $fatal(1, "successful job did not commit one generation");
        verify_output_frame();

        if(SUCCESS_DRAIN_CANCEL) begin
            check_success_drain_cancel();
            $finish;
        end

        if(ENABLE_PREVIEW) begin
            if(preview_aw_count!=3||preview_w_count!=6||preview_b_count!=3||preview_hold_cycles!=64)
                $fatal(1,"boardless preview coverage incomplete");
            $display("C1_BOARDLESS_PREVIEW_PASS pixels=24 aw=3 w=6 b=3 final_B_hold=64 snapshot=1");
            if(dut.resolved_preview_base!==32'h6000 || dut.resolved_preview_stride!==32'd32)
                $fatal(1,"exported preview metadata followed poisoned live job config");
            $display("C1_BOARDLESS_PREVIEW_METADATA_PASS base=00006000 stride=32 live_poison=1");
            if(PREVIEW_LAYOUT_TEST) begin
                for(integer layout_case=0;layout_case<6;layout_case++) begin
                    preview_request_base=(layout_case==0 ? INPUT_FRAME_BASE :
                                          (layout_case==1 ? OUTPUT_FRAME_BASE :
                                           (layout_case==2 ? 32'h6000 :
                                            (layout_case==3 ? 32'hfffffff0 :
                                             (layout_case==4 ? 32'h5ff0 : 32'h6010)))));
                    preview_request_stride=(layout_case==2 ? 16 : 32);
                    launch_snapshot=launch_count;aw_snapshot=aw_count;
                    runtime_start_snapshot=runtime_start_count;
                    start_job();
                    // Input/output aliases also violate the dedicated preview arena;
                    // extent/arena rejection precedes the pairwise overlap walk.
                    wait_terminal(TERM_ERROR,(layout_case==2 ? 8'h31 : 8'h32),preview_request_base);
                    if(runtime_start_count!=runtime_start_snapshot||launch_count!=launch_snapshot||aw_count!=aw_snapshot||preview_aw_count!=0||preview_w_count!=0)
                        $fatal(1,"layout failure launched runtime clients");
                end
                preview_request_base=32'h6000;preview_request_stride=32;
                start_job();wait(layout_check_busy);pulse_abort();
                wait_terminal(TERM_ABORTED,8'd0,32'd0);
                if(runtime_start_count!=runtime_start_snapshot||launch_count!=launch_snapshot||preview_aw_count!=0)
                    $fatal(1,"layout cancel launched runtime");
                clear_output_memory();start_job();wait_terminal(TERM_DONE,8'd0,32'd0);verify_output_frame();
                if(accepted_jobs!=9||done_jobs!=2||error_jobs!=6||aborted_jobs!=1||
                   runtime_start_count!=2||preview_aw_count!=3||preview_w_count!=6||preview_b_count!=3)
                    $fatal(1,"layout recovery coverage counts");
                $display("C1_BOARDLESS_PREVIEW_LAYOUT_PASS jobs=9 done=2 errors=6 aborted=1 input_alias=1 output_alias=1 stride=1 overflow=1 arena_underflow=1 arena_overrun=1 cancel_in_check=1 no_launch_on_reject=1 no_reset=1");
                $display("C1_R1_BOARDLESS_FRAME_SYSTEM_PASS preview=1 layout_jobs=9");
                $finish;
            end
            if(PREVIEW_CANCEL_TEST || PREVIEW_ERROR_TEST) begin
                clear_output_memory();preview_force_hold=1;
                preview_inject_b_error=PREVIEW_ERROR_TEST;
                start_job();
                wait(preview_pending&&preview_row==2);@(negedge clk);
                if(preview_aw_count!=3||preview_w_count!=6||preview_b_count!=2)
                    $fatal(1,"missing final preview B cancel coverage");
                if(PREVIEW_CANCEL_TEST) pulse_abort();
                job_start_valid=1;
                repeat(24) begin
                    @(negedge clk);
                    if(!busy||job_start_ready||job_done||job_error||job_aborted||preview_b_count!=2)
                        $fatal(1,"preview cancel allowed early retirement or restart");
                end
                job_start_valid=0;preview_force_hold=0;
                if(PREVIEW_ERROR_TEST) wait_terminal(TERM_ERROR,8'h63,32'h6000);
                else wait_terminal(TERM_ABORTED,8'd0,32'd0);
                if(preview_b_count!=3||preview_pending||preview_active||preview_axi_bvalid)
                    $fatal(1,"preview cancellation did not retire every B");
                preview_inject_b_error=0;
                clear_output_memory();start_job();
                wait_terminal(TERM_DONE,8'd0,32'd0);verify_output_frame();
                if(preview_aw_count!=3||preview_w_count!=6||preview_b_count!=3||
                   accepted_jobs!=3||done_jobs!=2||aborted_jobs!=(PREVIEW_CANCEL_TEST ? 1 : 0)||
                   error_jobs!=(PREVIEW_ERROR_TEST ? 1 : 0))
                    $fatal(1,"preview recovery/terminal counts mismatch");
                if(preview_barrier_rearm_count==0) $fatal(1,"old dispatch barrier was not exercised");
                if(PREVIEW_CANCEL_TEST) $display("C1_BOARDLESS_PREVIEW_CANCEL_PASS jobs=3 done=2 aborted=1 held_B=1 held_cycles=24 rejected_restart=1 no_reset=1 recovery_pixels=24");
                if(PREVIEW_ERROR_TEST) $display("C1_BOARDLESS_PREVIEW_ERROR_PASS jobs=3 done=2 errors=1 bresp=2 code=63 address=00006000 held_cycles=24 no_reset=1 recovery_pixels=24");
                $display("C1_BOARDLESS_DISPATCH_REARM_PASS old_complete_at_admission=%0d",preview_barrier_rearm_count);
            end
            $display("C1_R1_BOARDLESS_FRAME_SYSTEM_PASS preview=1 jobs=%0d normal_jobs=%0d aborted=%0d errors=%0d",(PREVIEW_CANCEL_TEST||PREVIEW_ERROR_TEST) ? 3 : 1,(PREVIEW_CANCEL_TEST||PREVIEW_ERROR_TEST) ? 2 : 1,PREVIEW_CANCEL_TEST ? 1 : 0,PREVIEW_ERROR_TEST ? 1 : 0);
            $finish;
        end

        // 2. Pair overlap: no DMA/CNN launch.  A concurrently completed config
        // is a reusable cache, so this test intentionally does not demand a
        // generation rollback.
        load_descriptor_batch(2, -1);
        pair_overlap_mode = 1'b1;
        launch_snapshot = launch_count;
        start_job();
        wait_terminal(TERM_ERROR, 8'h30, INPUT_FRAME_BASE);
        if (launch_count != launch_snapshot)
            $fatal(1, "pair failure launched runtime clients");
        pair_overlap_mode = 1'b0;

        // 3. Semantic config failure: fixed frontend summary, no launch.
        load_descriptor_batch(3, 5);
        launch_snapshot = launch_count;
        start_job();
        wait_terminal(TERM_ERROR, 8'h40, DESCRIPTOR_BASE);
        if (launch_count != launch_snapshot)
            $fatal(1, "config failure launched runtime clients");

        // 4. External CNN/engine error after an output AW is committed.  The
        // cancel-capable writer must complete W/B before job_error.
        load_descriptor_batch(4, -1);
        clear_output_memory();
        launch_snapshot = launch_count;
        aw_snapshot = aw_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        while (aw_count == aw_snapshot)
            @(negedge clk);
        pulse_cnn_error();
        wait_terminal(TERM_ERROR, 8'ha5, 32'd0);
        cancel_drain_checks = cancel_drain_checks + 1;

        // 5. Input frame RRESP failure maps to the portable input-DMA code and
        // cancels a waiting output capture without deadlock.
        load_descriptor_batch(5, -1);
        inject_input_rresp = 1'b1;
        launch_snapshot = launch_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        wait_terminal(TERM_ERROR, 8'h61, INPUT_FRAME_BASE);
        inject_input_rresp = 1'b0;
        cancel_drain_checks = cancel_drain_checks + 1;

        // 6. Output BRESP failure is observed while the writer is still busy;
        // cancel finishes only the committed burst.
        load_descriptor_batch(6, -1);
        inject_output_bresp = 1'b1;
        launch_snapshot = launch_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        wait_terminal(TERM_ERROR, 8'h62, OUTPUT_FRAME_BASE);
        inject_output_bresp = 1'b0;
        cancel_drain_checks = cancel_drain_checks + 1;

        // 7. Explicit abort after a real output AW exercises protocol-safe DMA
        // drain and must retire as aborted, not error.
        load_descriptor_batch(7, -1);
        launch_snapshot = launch_count;
        aw_snapshot = aw_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        while (aw_count == aw_snapshot)
            @(negedge clk);
        pulse_abort();
        wait_terminal(TERM_ABORTED, 8'd0, 32'd0);
        cancel_drain_checks = cancel_drain_checks + 1;

        // 8. Abort after the first beat of a two-beat input burst.  The
        // reader must suppress further pixels yet accept/drain the remaining
        // R beat before the frontend reports the aborted terminal.
        load_descriptor_batch(8, -1);
        hold_after_first_input_beat = 1'b1;
        input_rbeat_snapshot = input_rbeat_count;
        launch_snapshot = launch_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        while (input_rbeat_count == input_rbeat_snapshot)
            @(negedge clk);
        if (!rd_active || (rd_len_q < 1) || (rd_beat_q != 1))
            $fatal(1, "mid-read abort did not catch a committed multi-beat burst");
        mid_read_abort_checks = mid_read_abort_checks + 1;
        job_abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        job_abort = 1'b0;
        hold_after_first_input_beat = 1'b0;
        wait_terminal(TERM_ABORTED, 8'd0, 32'd0);
        cancel_drain_checks = cancel_drain_checks + 1;

        // 9. Clean restart proves generation dispatch and all data paths are
        // reusable after preflight/runtime errors and abort.
        load_descriptor_batch(9, -1);
        clear_output_memory();
        generation_snapshot = active_config_generation;
        launch_snapshot = launch_count;
        start_job();
        wait_launch(launch_snapshot + 1);
        wait_terminal(TERM_DONE, 8'd0, 32'd0);
        if (active_config_generation != generation_snapshot + 1'b1)
            $fatal(1, "restart did not advance config generation");
        verify_output_frame();

        repeat (12) @(posedge clk);
        if ((accepted_jobs != 9) || (launch_count != 7) ||
            (done_jobs != 2) || (error_jobs != 5) ||
            (aborted_jobs != 2) || (cancel_drain_checks != 5) ||
            (completed_dispatch_count != 5) ||
            // Two launches are intentionally aborted before dispatch; the
            // other five each transfer one exact 22-stage batch.
            (total_stage_count != 5*MAX_STAGES) ||
            (config_barrier_checks == 0) || (cnn_input_count == 0) ||
            (cnn_output_count == 0) || (table_ar_count == 0) ||
            (descriptor_ar_count == 0) || (input_ar_count == 0) ||
            (aw_count == 0) || (w_count == 0) || (b_count == 0) ||
            (ar_stall_count == 0) || (r_gap_count == 0) ||
            (aw_stall_count == 0) || (w_stall_count == 0) ||
            (stage_stall_count == 0) || (cnn_stall_count == 0) ||
            (reverse_barrier_checks == 0) ||
            (mid_read_abort_checks != 1) ||
            busy || !job_start_ready || rd_active || wr_active ||
            m_axi_rvalid || m_axi_bvalid)
            $fatal(1, "coverage mismatch jobs=%0d launch=%0d done=%0d error=%0d abort=%0d stages=%0d dispatches=%0d barrier=%0d reverse=%0d cnn_in=%0d cnn_out=%0d ar=%0d input_ar=%0d aw=%0d w=%0d b=%0d arstall=%0d rgap=%0d awstall=%0d wstall=%0d sstall=%0d cstall=%0d drains=%0d midread=%0d rwoverlap=%0d",
                   accepted_jobs, launch_count, done_jobs, error_jobs,
                   aborted_jobs, total_stage_count,
                   completed_dispatch_count, config_barrier_checks,
                   reverse_barrier_checks,
                   cnn_input_count, cnn_output_count, ar_count,
                   input_ar_count, aw_count, w_count, b_count,
                   ar_stall_count, r_gap_count, aw_stall_count,
                   w_stall_count, stage_stall_count, cnn_stall_count,
                   cancel_drain_checks, mid_read_abort_checks,
                   rw_overlap_cycles);

        $display("C1_R1_BOARDLESS_FRAME_SYSTEM_PASS jobs=%0d launches=%0d done=%0d errors=%0d aborted=%0d stages=%0d dispatches=%0d generations=%0d cnn_in=%0d cnn_out=%0d ar=%0d aw=%0d w=%0d b=%0d drains=%0d reverse=%0d midread=%0d rwoverlap=%0d",
                 accepted_jobs, launch_count, done_jobs, error_jobs,
                 aborted_jobs, total_stage_count, completed_dispatch_count,
                 active_config_generation,
                 cnn_input_count, cnn_output_count, ar_count, aw_count,
                 w_count, b_count, cancel_drain_checks,
                 reverse_barrier_checks, mid_read_abort_checks,
                 rw_overlap_cycles);
        $finish;
    end

    initial begin
        #200_000_000;
        $fatal(1, "global boardless frame-system timeout");
    end

endmodule
