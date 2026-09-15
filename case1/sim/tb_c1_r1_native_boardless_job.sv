`timescale 1ns/1ps

// Native boardless job preflight.
//
// This bench is deliberately separate from the small boardless regression and
// from the raw native DMA loopback.  It instantiates the real
// c1_r1_boardless_frame_system at 640x480 and closes all of its board-facing
// seams with simulation BFMs: frame tables, 22 descriptors, input/output
// XRGB DMA, a one-entry external-CNN C8 echo, and a single ID-less AXI slave.
// The AXI READY signals are sampled at the falling edge only to remove xsim
// same-delta testbench races; this is a simulation shell, not a synthesized
// pipeline stage.
module tb_c1_r1_native_boardless_job;

    localparam integer MAX_WIDTH = 640;
    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer STRIDE = FRAME_W * 4;
    localparam integer FRAME_BYTES = STRIDE * FRAME_H;
    localparam integer ROW_BEATS = FRAME_W / 4;
    localparam integer FRAME_BEATS = FRAME_H * ROW_BEATS;
    localparam integer FRAME_BURSTS = FRAME_H * ((ROW_BEATS + 15) / 16);
    localparam logic [31:0] INPUT_TABLE_BASE = 32'h0008_0000;
    localparam logic [31:0] OUTPUT_TABLE_BASE = 32'h0009_0000;
    localparam logic [31:0] DESCRIPTOR_BASE = 32'h000a_0000;
    localparam logic [31:0] INPUT_FRAME_BASE = 32'h0010_0000;
    localparam logic [31:0] OUTPUT_FRAME_BASE = 32'h0060_0000;
    // A constant pixel makes the expected output independent of interpolation
    // corner rounding while still exercising every 640x480 source/output beat.
    localparam logic [23:0] PIXEL_RGB = 24'h21_83_d7;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic job_start_valid = 1'b0;
    logic job_start_ready;
    logic job_abort = 1'b0;
    logic [63:0] job_input_table_base = INPUT_TABLE_BASE;
    logic [63:0] job_output_table_base = OUTPUT_TABLE_BASE;
    logic [1:0] job_input_buffer_index = 2'd0;
    logic [1:0] job_output_buffer_index = 2'd0;
    logic [15:0] job_width_pixels = FRAME_W;
    logic [15:0] job_height_lines = FRAME_H;
    logic [31:0] job_descriptor_base = DESCRIPTOR_BASE;
    logic [COUNT_BITS-1:0] job_descriptor_count = MAX_STAGES;
    logic [31:0] job_cycle_budget = 32'd100_000_000;
    logic signed [31:0] job_x_step_q16 = 32'sh0001_0000;
    logic signed [31:0] job_y_step_q16 = 32'sh0001_0000;
    logic signed [31:0] job_x_phase0_q16 = 32'sd0;
    logic signed [31:0] job_y_phase0_q16 = 32'sd0;

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

    c1_r1_boardless_frame_system #(
        .MAX_WIDTH(MAX_WIDTH), .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS), .GENERATION_BITS(GENERATION_BITS),
        .READ_TIMEOUT_CYCLES(256), .SYNC_READ(1'b1), .FAST_WIDE(1'b0)
    ) dut (.job_input_width_pixels(16'd0),.job_input_height_lines(16'd0),.*);

    logic [511:0] descriptor_memory [0:MAX_STAGES-1];
    logic [31:0] prng = 32'h2a91_7e31;
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
    logic [127:0] output_mem [longint unsigned];

    // One-entry external CNN model.  It intentionally introduces independent
    // input/output stalls, but never allows a same-cycle pop/push ambiguity.
    logic cnn_loop_valid_q = 1'b0;
    logic [63:0] cnn_loop_data_q = 64'd0;
    logic [15:0] cnn_loop_x_q = 16'd0;
    logic [15:0] cnn_loop_y_q = 16'd0;
    logic cnn_loop_sof_q = 1'b0;
    logic cnn_loop_eol_q = 1'b0;
    logic cnn_loop_eof_q = 1'b0;

    integer stage_count = 0;
    integer stage_total = 0;
    integer cnn_in_count = 0;
    integer cnn_out_count = 0;
    integer cnn_in_sof_count = 0;
    integer cnn_in_eol_count = 0;
    integer cnn_in_eof_count = 0;
    integer cnn_out_sof_count = 0;
    integer cnn_out_eol_count = 0;
    integer cnn_out_eof_count = 0;
    integer ar_count = 0;
    integer table_ar_count = 0;
    integer descriptor_ar_count = 0;
    integer input_ar_count = 0;
    integer input_r_count = 0;
    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;
    integer ar_stall_count = 0;
    integer r_gap_count = 0;
    integer aw_stall_count = 0;
    integer w_stall_count = 0;
    integer b_delay_count = 0;
    integer stage_stall_count = 0;
    integer cnn_in_stall_count = 0;
    integer cnn_out_stall_count = 0;
    integer output_pixel_count = 0;
    integer job_done_count = 0;
    logic previous_ar_stall = 1'b0;
    logic [44:0] previous_ar_payload = '0;
    logic previous_aw_stall = 1'b0;
    logic [44:0] previous_aw_payload = '0;
    logic previous_w_stall = 1'b0;
    logic [144:0] previous_w_payload = '0;

    function automatic [511:0] legal_descriptor(input integer idx);
        logic [511:0] d;
        begin
            d = '0;
            d[7:0] = 8'd2;
            d[9:8] = idx[0] ? 2'd1 : 2'd0;
            d[23:16] = 8'd1;
            d[31:24] = 8'd16;
            d[47:32] = 16'd8 + (idx % 5);
            d[63:48] = 16'd9 + (idx % 5);
            d[79:64] = d[47:32];
            d[95:80] = d[63:48];
            d[111:96] = 16'd8;
            d[127:112] = 16'd8;
            d[159:128] = 32'h0010_0000 + idx*32'h10;
            d[191:160] = 32'h0020_0000 + idx*32'h10;
            d[223:192] = 32'd0;
            d[255:224] = 32'h0030_0000 + idx*32'h10;
            d[287:256] = 32'h0040_0000 + idx*32'h10;
            d[319:288] = 32'h0050_0000 + idx*32'h10;
            d[351:320] = 32'h0060_0000 + idx*32'h10;
            d[423:416] = 8'd1;
            d[431:424] = 8'd1;
            d[439:432] = 8'd1;
            d[447:440] = 8'd1;
            d[455:448] = 8'd8;
            d[463:456] = 8'd8;
            d[471:464] = 8'd4;
            d[479:472] = 8'd4;
            d[511:480] = 32'd1000 + idx;
            legal_descriptor = d;
        end
    endfunction

    function automatic [127:0] table_entry(input logic [31:0] base_addr);
        table_entry = {16'(FRAME_H), 16'(FRAME_W), 32'(STRIDE),
                       32'd0, base_addr};
    endfunction

    function automatic [127:0] read_lookup(input logic [31:0] address);
        integer index;
        integer beat;
        begin
            read_lookup = 128'd0;
            if (address == INPUT_TABLE_BASE)
                read_lookup = table_entry(INPUT_FRAME_BASE);
            else if (address == OUTPUT_TABLE_BASE)
                read_lookup = table_entry(OUTPUT_FRAME_BASE);
            else if ((address >= DESCRIPTOR_BASE) &&
                     (address < DESCRIPTOR_BASE + MAX_STAGES*64)) begin
                index = (address - DESCRIPTOR_BASE) >> 6;
                beat = ((address - DESCRIPTOR_BASE) >> 4) & 3;
                read_lookup = descriptor_memory[index][beat*128 +: 128];
            end else if ((address >= INPUT_FRAME_BASE) &&
                         (address < INPUT_FRAME_BASE + FRAME_BYTES)) begin
                // Four identical XRGB words per 128-bit line.
                read_lookup = {{4{8'h00, PIXEL_RGB}}};
            end
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_R1_NATIVE_BOARDLESS_JOB_FAIL %s", message);
            $fatal(1, "%s", message);
        end
    endtask

    // READY is stable from one rising edge to the next.  The opposite-edge
    // shell is intentionally limited to the BFM boundary.
    always @(negedge clk) begin
        if (rst) begin
            m_axi_arready <= 1'b0;
            m_axi_awready <= 1'b0;
            m_axi_wready <= 1'b0;
        end else begin
            m_axi_arready <= !rd_active && !m_axi_rvalid &&
                             ((prng[3:0] != 4'h0));
            m_axi_awready <= !wr_active && !b_pending_q && !m_axi_bvalid &&
                             ((prng[7:4] != 4'h0));
            m_axi_wready <= wr_active && (prng[11:8] != 4'h0);
        end
    end

    always_comb begin
        stage_config_ready = (prng[14:12] != 3'b000);
        cnn_in_ready = !cnn_loop_valid_q && (prng[17:15] != 3'b000);
        // cnn_out_ready is driven by the DUT.  Once the echo has a beat,
        // VALID remains asserted until that beat is accepted; this keeps the
        // external CNN model compliant with the ready/valid hold contract.
        cnn_out_valid = cnn_loop_valid_q;
        cnn_out_data_s8 = cnn_loop_data_q;
        cnn_out_x = cnn_loop_x_q;
        cnn_out_y = cnn_loop_y_q;
        cnn_out_sof = cnn_loop_sof_q;
        cnn_out_eol = cnn_loop_eol_q;
        cnn_out_eof = cnn_loop_eof_q;
    end

    always @(posedge clk) begin
        if (rst)
            prng <= 32'h2a91_7e31;
        else
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
    end

    // External CNN echo and metadata scoreboard.
    always @(posedge clk) begin
        if (rst || cnn_abort) begin
            cnn_loop_valid_q <= 1'b0;
            cnn_loop_data_q <= 64'd0;
            cnn_loop_x_q <= 16'd0;
            cnn_loop_y_q <= 16'd0;
            cnn_loop_sof_q <= 1'b0;
            cnn_loop_eol_q <= 1'b0;
            cnn_loop_eof_q <= 1'b0;
        end else begin
            if (cnn_out_valid && cnn_out_ready) begin
                cnn_loop_valid_q <= 1'b0;
                cnn_out_count = cnn_out_count + 1;
                if (cnn_out_sof) cnn_out_sof_count = cnn_out_sof_count + 1;
                if (cnn_out_eol) cnn_out_eol_count = cnn_out_eol_count + 1;
                if (cnn_out_eof) cnn_out_eof_count = cnn_out_eof_count + 1;
            end
            if (cnn_in_valid && cnn_in_ready) begin
                if (cnn_loop_valid_q) fail("CNN echo overflow");
                if (!stage_dispatch_complete || stage_count != MAX_STAGES)
                    fail("CNN input preceded complete descriptor dispatch");
                cnn_loop_valid_q <= 1'b1;
                cnn_loop_data_q <= cnn_in_data_s8;
                cnn_loop_x_q <= cnn_in_x;
                cnn_loop_y_q <= cnn_in_y;
                cnn_loop_sof_q <= cnn_in_sof;
                cnn_loop_eol_q <= cnn_in_eol;
                cnn_loop_eof_q <= cnn_in_eof;
                cnn_in_count = cnn_in_count + 1;
                if (cnn_in_sof) cnn_in_sof_count = cnn_in_sof_count + 1;
                if (cnn_in_eol) cnn_in_eol_count = cnn_in_eol_count + 1;
                if (cnn_in_eof) cnn_in_eof_count = cnn_in_eof_count + 1;
            end
        end
    end

    // Descriptor stream scoreboard and AXI-stability counters.
    always @(posedge clk) begin
        if (rst) begin
            stage_count = 0;
            previous_ar_stall <= 1'b0;
            previous_aw_stall <= 1'b0;
            previous_w_stall <= 1'b0;
        end else begin
            if (stage_config_valid && !stage_config_ready)
                stage_stall_count = stage_stall_count + 1;
            if (cnn_in_valid && !cnn_in_ready)
                cnn_in_stall_count = cnn_in_stall_count + 1;
            if (cnn_out_valid && !cnn_out_ready)
                cnn_out_stall_count = cnn_out_stall_count + 1;
            if (stage_config_valid && stage_config_ready) begin
                if (stage_config_index !== stage_count[COUNT_BITS-1:0])
                    fail("descriptor index ordering mismatch");
                if (stage_config_descriptor !== descriptor_memory[stage_count])
                    fail("descriptor payload mismatch");
                if (stage_config_generation !== active_config_generation)
                    fail("descriptor generation mismatch");
                stage_count = stage_count + 1;
                stage_total = stage_total + 1;
            end
            if (stage_dispatch_complete && stage_count != MAX_STAGES)
                fail("dispatch complete before all descriptors");
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_count = ar_stall_count + 1;
            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_count = aw_stall_count + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_count = w_stall_count + 1;
            if (previous_ar_stall && ({m_axi_araddr,m_axi_arlen,
                                       m_axi_arsize,m_axi_arburst,
                                       m_axi_arvalid} !== previous_ar_payload))
                fail("AR payload changed while stalled");
            if (previous_aw_stall && ({m_axi_awaddr,m_axi_awlen,
                                       m_axi_awsize,m_axi_awburst,
                                       m_axi_awvalid} !== previous_aw_payload))
                fail("AW payload changed while stalled");
            if (previous_w_stall && ({m_axi_wdata,m_axi_wstrb,m_axi_wlast,
                                      m_axi_wvalid} !== previous_w_payload))
                fail("W payload changed while stalled");
            previous_ar_stall <= m_axi_arvalid && !m_axi_arready;
            previous_aw_stall <= m_axi_awvalid && !m_axi_awready;
            previous_w_stall <= m_axi_wvalid && !m_axi_wready;
            previous_ar_payload <= {m_axi_araddr,m_axi_arlen,m_axi_arsize,
                                    m_axi_arburst,m_axi_arvalid};
            previous_aw_payload <= {m_axi_awaddr,m_axi_awlen,m_axi_awsize,
                                    m_axi_awburst,m_axi_awvalid};
            previous_w_payload <= {m_axi_wdata,m_axi_wstrb,m_axi_wlast,
                                   m_axi_wvalid};
        end
    end

    // AXI read slave: table, descriptor and native frame reads share this one
    // outstanding-burst BFM, matching the ID-less arbiter contract.
    always @(posedge clk) begin : read_slave
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
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    fail("invalid AR attributes");
                rd_active <= 1'b1;
                rd_base_q <= m_axi_araddr;
                rd_len_q <= m_axi_arlen;
                rd_beat_q <= 8'd0;
                rd_gap_q <= {2'd0, prng[23:22]};
                ar_count = ar_count + 1;
                if ((m_axi_araddr == INPUT_TABLE_BASE) ||
                    (m_axi_araddr == OUTPUT_TABLE_BASE))
                    table_ar_count = table_ar_count + 1;
                else if ((m_axi_araddr >= DESCRIPTOR_BASE) &&
                         (m_axi_araddr < DESCRIPTOR_BASE + MAX_STAGES*64))
                    descriptor_ar_count = descriptor_ar_count + 1;
                else if ((m_axi_araddr >= INPUT_FRAME_BASE) &&
                         (m_axi_araddr < INPUT_FRAME_BASE + FRAME_BYTES))
                    input_ar_count = input_ar_count + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                if (rd_beat_q == rd_len_q)
                    rd_active <= 1'b0;
                else begin
                    rd_beat_q <= rd_beat_q + 1'b1;
                    rd_gap_q <= {2'd0, prng[25:24]};
                end
                if ((rd_base_q >= INPUT_FRAME_BASE) &&
                    (rd_base_q < INPUT_FRAME_BASE + FRAME_BYTES))
                    input_r_count = input_r_count + 1;
            end else if (rd_active && !m_axi_rvalid) begin
                if (rd_gap_q != 0) begin
                    rd_gap_q <= rd_gap_q - 1'b1;
                    r_gap_count = r_gap_count + 1;
                end else begin
                    m_axi_rdata <= read_lookup(rd_base_q + (rd_beat_q << 4));
                    m_axi_rresp <= 2'b00;
                    m_axi_rlast <= (rd_beat_q == rd_len_q);
                    m_axi_rvalid <= 1'b1;
                end
            end
        end
    end

    // AXI write slave with full-line associative output storage.
    always @(posedge clk) begin : write_slave
        integer lane;
        longint unsigned key;
        logic [127:0] line;
        logic [31:0] pixel_addr;
        begin
            if (rst) begin
                wr_active <= 1'b0;
                wr_base_q <= 32'd0;
                wr_len_q <= 8'd0;
                wr_beat_q <= 8'd0;
                b_pending_q <= 1'b0;
                b_gap_q <= 4'd0;
                m_axi_bvalid <= 1'b0;
                m_axi_bresp <= 2'b00;
            end else begin
                if (m_axi_awvalid && m_axi_awready) begin
                    if (m_axi_awsize != 3'd4 || m_axi_awburst != 2'b01 ||
                        m_axi_awaddr < OUTPUT_FRAME_BASE ||
                        m_axi_awaddr >= OUTPUT_FRAME_BASE + FRAME_BYTES)
                        fail("invalid output AW");
                    wr_active <= 1'b1;
                    wr_base_q <= m_axi_awaddr;
                    wr_len_q <= m_axi_awlen;
                    wr_beat_q <= 8'd0;
                    aw_count = aw_count + 1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    if (!wr_active || m_axi_wstrb != 16'hffff)
                        fail("W without active/full-strb output burst");
                    if (m_axi_wlast != (wr_beat_q == wr_len_q))
                        fail("output WLAST mismatch");
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        pixel_addr = wr_base_q + wr_beat_q*16 + lane*4;
                        if (m_axi_wdata[lane*32 +: 32] !== {8'h00, PIXEL_RGB})
                            fail("native boardless output pixel mismatch");
                        if (pixel_addr < OUTPUT_FRAME_BASE ||
                            pixel_addr >= OUTPUT_FRAME_BASE + FRAME_BYTES)
                            fail("output W outside native frame");
                    end
                    key = (wr_base_q + wr_beat_q*16) >> 4;
                    line = output_mem.exists(key) ? output_mem[key] : 128'd0;
                    for (lane = 0; lane < 16; lane = lane + 1)
                        if (m_axi_wstrb[lane])
                            line[lane*8 +: 8] = m_axi_wdata[lane*8 +: 8];
                    output_mem[key] = line;
                    output_pixel_count = output_pixel_count + 4;
                    w_count = w_count + 1;
                    if (m_axi_wlast) begin
                        wr_active <= 1'b0;
                        b_pending_q <= 1'b1;
                        b_gap_q <= {2'd0, prng[27:26]};
                    end else
                        wr_beat_q <= wr_beat_q + 1'b1;
                end
                if (b_pending_q && !m_axi_bvalid) begin
                    if (b_gap_q != 0) begin
                        b_gap_q <= b_gap_q - 1'b1;
                        b_delay_count = b_delay_count + 1;
                    end else begin
                        m_axi_bvalid <= 1'b1;
                        m_axi_bresp <= 2'b00;
                        b_pending_q <= 1'b0;
                    end
                end
                if (m_axi_bvalid && m_axi_bready) begin
                    m_axi_bvalid <= 1'b0;
                    b_count = b_count + 1;
                end
            end
        end
    end

    task automatic start_job;
        begin
            @(negedge clk);
            job_start_valid <= 1'b1;
            while (!job_start_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            job_start_valid <= 1'b0;
        end
    endtask

    task automatic wait_done;
        integer guard;
        begin
            guard = 0;
            while (!job_done && !job_error && !job_aborted) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 45_000_000)
                    fail("native boardless job timeout");
            end
            if (!job_done || job_error || job_aborted)
                fail("native boardless job did not complete successfully");
            job_done_count = job_done_count + 1;
        end
    endtask

    task automatic verify_output_lines;
        integer x;
        integer y;
        integer lane;
        longint unsigned key;
        logic [127:0] line;
        begin
            for (y = 0; y < FRAME_H; y = y + 1)
                for (x = 0; x < FRAME_W; x = x + 1) begin
                    key = (OUTPUT_FRAME_BASE + y*STRIDE + x*4) >> 4;
                    if (!output_mem.exists(key))
                        fail("missing output associative DDR line");
                    line = output_mem[key];
                    lane = x & 3;
                    if (line[lane*32 +: 32] !== {8'h00, PIXEL_RGB})
                        fail("final output line readback mismatch");
                end
        end
    endtask

    initial begin : main_test
        integer idx;
        for (idx = 0; idx < MAX_STAGES; idx = idx + 1)
            descriptor_memory[idx] = legal_descriptor(idx);
        if (INPUT_FRAME_BASE + FRAME_BYTES >= OUTPUT_FRAME_BASE)
            fail("input/output frame arenas overlap");

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        if (!job_start_ready || busy)
            fail("native boardless top did not reset idle");
        start_job();
        wait_done();
        repeat (8) @(posedge clk);
        if (resolved_input_base !== INPUT_FRAME_BASE ||
            resolved_output_base !== OUTPUT_FRAME_BASE ||
            resolved_input_stride !== STRIDE ||
            resolved_output_stride !== STRIDE ||
            resolved_input_width !== FRAME_W ||
            resolved_output_width !== FRAME_W ||
            resolved_input_height !== FRAME_H ||
            resolved_output_height !== FRAME_H)
            fail("resolved native frame geometry mismatch");
        if (stage_total != MAX_STAGES || cnn_in_count != FRAME_W*FRAME_H ||
            cnn_out_count != FRAME_W*FRAME_H || output_pixel_count != FRAME_W*FRAME_H ||
            cnn_in_sof_count != 1 || cnn_out_sof_count != 1 ||
            cnn_in_eol_count != FRAME_H || cnn_out_eol_count != FRAME_H ||
            cnn_in_eof_count != 1 || cnn_out_eof_count != 1)
            fail("native boardless stream coverage mismatch");
        if (table_ar_count < 2 || descriptor_ar_count == 0 ||
            input_ar_count != FRAME_BURSTS || input_r_count != FRAME_BEATS ||
            aw_count != FRAME_BURSTS || w_count != FRAME_BEATS ||
            b_count != FRAME_BURSTS || ar_stall_count == 0 ||
            r_gap_count == 0 || aw_stall_count == 0 || w_stall_count == 0 ||
            b_delay_count == 0 || stage_stall_count == 0 ||
            cnn_in_stall_count == 0 || cnn_out_stall_count == 0)
            fail("native boardless backpressure/AXI counts incomplete");
        verify_output_lines();
        if (busy || rd_active || wr_active || m_axi_rvalid || m_axi_bvalid)
            fail("native boardless terminal preceded AXI drain");

        $display("C1_R1_NATIVE_BOARDLESS_JOB_PASS frame=%0dx%0d stages=%0d cnn_in=%0d cnn_out=%0d table_ar=%0d descriptor_ar=%0d input_ar=%0d input_r=%0d output_aw=%0d output_w=%0d output_b=%0d ar_stalls=%0d r_gaps=%0d aw_stalls=%0d w_stalls=%0d b_delays=%0d stage_stalls=%0d cnn_in_stalls=%0d cnn_out_stalls=%0d output_pixels=%0d", FRAME_W, FRAME_H, stage_total, cnn_in_count, cnn_out_count, table_ar_count, descriptor_ar_count, input_ar_count, input_r_count, aw_count, w_count, b_count, ar_stall_count, r_gap_count, aw_stall_count, w_stall_count, b_delay_count, stage_stall_count, cnn_in_stall_count, cnn_out_stall_count, output_pixel_count);
        $finish;
    end

    initial begin
        #500_000_000;
        fail("native boardless global timeout");
    end
endmodule
