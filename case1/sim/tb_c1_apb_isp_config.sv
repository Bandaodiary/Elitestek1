`timescale 1ns/1ps

module tb_c1_apb_isp_config;

    localparam logic [11:0] A_CONTROL       = 12'h200;
    localparam logic [11:0] A_STATUS        = 12'h204;
    localparam logic [11:0] A_ERROR         = 12'h208;
    localparam logic [11:0] A_BAYER         = 12'h210;
    localparam logic [11:0] A_BLACK_R       = 12'h214;
    localparam logic [11:0] A_BLACK_GR      = 12'h218;
    localparam logic [11:0] A_BLACK_GB      = 12'h21c;
    localparam logic [11:0] A_BLACK_B       = 12'h220;
    localparam logic [11:0] A_AWB_R         = 12'h224;
    localparam logic [11:0] A_AWB_G         = 12'h228;
    localparam logic [11:0] A_AWB_B         = 12'h22c;
    localparam logic [11:0] A_CCM_RR        = 12'h230;
    localparam logic [11:0] A_CCM_RG        = 12'h234;
    localparam logic [11:0] A_CCM_RB        = 12'h238;
    localparam logic [11:0] A_CCM_GR        = 12'h23c;
    localparam logic [11:0] A_CCM_GG        = 12'h240;
    localparam logic [11:0] A_CCM_GB        = 12'h244;
    localparam logic [11:0] A_CCM_BR        = 12'h248;
    localparam logic [11:0] A_CCM_BG        = 12'h24c;
    localparam logic [11:0] A_CCM_BB        = 12'h250;
    localparam logic [11:0] A_OFFSET_R      = 12'h254;
    localparam logic [11:0] A_OFFSET_G      = 12'h258;
    localparam logic [11:0] A_OFFSET_B      = 12'h25c;
    localparam logic [11:0] A_GAMMA_ADDR    = 12'h260;
    localparam logic [11:0] A_GAMMA_DATA    = 12'h264;
    localparam logic [11:0] A_GAMMA_COMMAND = 12'h268;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [11:0] paddr = '0;
    logic [31:0] pwdata = '0;
    logic [3:0] pstrb = '0;
    wire [31:0] prdata;
    wire pready;
    wire pslverr;

    wire cfg_valid;
    logic cfg_ready = 1'b0;
    wire [1:0] cfg_bayer_pattern;
    wire cfg_roi_x_parity;
    wire cfg_roi_y_parity;
    wire [9:0] cfg_black_r, cfg_black_gr, cfg_black_gb, cfg_black_b;
    wire [15:0] cfg_awb_gain_r, cfg_awb_gain_g, cfg_awb_gain_b;
    wire signed [15:0] cfg_ccm_rr, cfg_ccm_rg, cfg_ccm_rb;
    wire signed [15:0] cfg_ccm_gr, cfg_ccm_gg, cfg_ccm_gb;
    wire signed [15:0] cfg_ccm_br, cfg_ccm_bg, cfg_ccm_bb;
    wire signed [31:0] cfg_ccm_offset_r, cfg_ccm_offset_g, cfg_ccm_offset_b;
    wire gamma_valid;
    logic gamma_cfg_ready = 1'b0;
    wire [9:0] gamma_cfg_addr;
    wire [7:0] gamma_cfg_data;
    wire abort_pulse;

    logic force_cfg_block = 1'b0;
    logic force_gamma_block = 1'b0;
    logic [31:0] lfsr = 32'h1357_9bdf;

    logic [1:0] model_bayer;
    logic model_roi_x, model_roi_y;
    logic [9:0] model_black_r, model_black_gr, model_black_gb, model_black_b;
    logic [15:0] model_awb_r, model_awb_g, model_awb_b;
    logic signed [15:0] model_ccm_rr, model_ccm_rg, model_ccm_rb;
    logic signed [15:0] model_ccm_gr, model_ccm_gg, model_ccm_gb;
    logic signed [15:0] model_ccm_br, model_ccm_bg, model_ccm_bb;
    logic signed [31:0] model_offset_r, model_offset_g, model_offset_b;

    logic [331:0] expected_cfg_bundle;
    logic expected_cfg_pending = 1'b0;
    logic [9:0] expected_gamma_addr;
    logic [7:0] expected_gamma_data;
    logic expected_gamma_pending = 1'b0;
    wire [331:0] cfg_bundle;

    integer cfg_handshakes = 0;
    integer gamma_handshakes = 0;
    integer cfg_stall_cycles = 0;
    integer gamma_stall_cycles = 0;
    integer abort_pulses = 0;
    integer iteration;
    integer start_count;

    assign cfg_bundle = {
        cfg_ccm_offset_b, cfg_ccm_offset_g, cfg_ccm_offset_r,
        cfg_ccm_bb, cfg_ccm_bg, cfg_ccm_br,
        cfg_ccm_gb, cfg_ccm_gg, cfg_ccm_gr,
        cfg_ccm_rb, cfg_ccm_rg, cfg_ccm_rr,
        cfg_awb_gain_b, cfg_awb_gain_g, cfg_awb_gain_r,
        cfg_black_b, cfg_black_gb, cfg_black_gr, cfg_black_r,
        cfg_roi_y_parity, cfg_roi_x_parity, cfg_bayer_pattern
    };

    always #5 clk = ~clk;

    c1_apb_isp_config dut (
        .clk,
        .rst_n,
        .psel,
        .penable,
        .pwrite,
        .paddr,
        .pwdata,
        .pstrb,
        .prdata,
        .pready,
        .pslverr,
        .cfg_valid,
        .cfg_ready,
        .cfg_bayer_pattern,
        .cfg_roi_x_parity,
        .cfg_roi_y_parity,
        .cfg_black_r,
        .cfg_black_gr,
        .cfg_black_gb,
        .cfg_black_b,
        .cfg_awb_gain_r,
        .cfg_awb_gain_g,
        .cfg_awb_gain_b,
        .cfg_ccm_rr,
        .cfg_ccm_rg,
        .cfg_ccm_rb,
        .cfg_ccm_gr,
        .cfg_ccm_gg,
        .cfg_ccm_gb,
        .cfg_ccm_br,
        .cfg_ccm_bg,
        .cfg_ccm_bb,
        .cfg_ccm_offset_r,
        .cfg_ccm_offset_g,
        .cfg_ccm_offset_b,
        .gamma_valid,
        .gamma_cfg_ready,
        .gamma_cfg_addr,
        .gamma_cfg_data,
        .abort_pulse
    );

    task automatic apb_write(
        input logic [11:0] address,
        input logic [31:0] data,
        input logic [3:0] strobes,
        input logic expected_error
    );
        logic sampled_ready;
        logic sampled_error;
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b1;
            paddr = address;
            pwdata = data;
            pstrb = strobes;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            // APB response is sampled on the transfer edge.  The DUT may
            // update its pending state in the NBA region at this same edge;
            // sampling PSLVERR after that update would incorrectly attribute
            // the newly-created busy state to the transaction just accepted.
            sampled_ready = pready;
            sampled_error = pslverr;
            #1;
            if (!sampled_ready || sampled_error !== expected_error)
                $fatal(1, "APB write response mismatch addr=%h err=%0b expected=%0b",
                       address, sampled_error, expected_error);
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = '0;
            pwdata = '0;
            pstrb = '0;
        end
    endtask

    task automatic apb_read(
        input logic [11:0] address,
        input logic [31:0] expected_data,
        input logic expected_error
    );
        logic sampled_ready;
        logic sampled_error;
        logic [31:0] sampled_data;
        begin
            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = address;
            pwdata = '0;
            pstrb = '0;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            sampled_ready = pready;
            sampled_error = pslverr;
            sampled_data = prdata;
            #1;
            if (!sampled_ready || sampled_error !== expected_error)
                $fatal(1, "APB read response mismatch addr=%h", address);
            if (sampled_data !== expected_data)
                $fatal(1, "APB read data mismatch addr=%h got=%h expected=%h",
                       address, sampled_data, expected_data);
            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            paddr = '0;
        end
    endtask

    task automatic snapshot_model;
        begin
            expected_cfg_bundle = {
                model_offset_b, model_offset_g, model_offset_r,
                model_ccm_bb, model_ccm_bg, model_ccm_br,
                model_ccm_gb, model_ccm_gg, model_ccm_gr,
                model_ccm_rb, model_ccm_rg, model_ccm_rr,
                model_awb_b, model_awb_g, model_awb_r,
                model_black_b, model_black_gb,
                model_black_gr, model_black_r,
                model_roi_y, model_roi_x, model_bayer
            };
        end
    endtask

    task automatic program_model(input integer value);
        begin
            model_bayer = value[1:0];
            model_roi_x = value[2];
            model_roi_y = value[3];
            model_black_r = (value * 37 + 3) & 10'h3ff;
            model_black_gr = (value * 53 + 7) & 10'h3ff;
            model_black_gb = (value * 71 + 11) & 10'h3ff;
            model_black_b = (value * 89 + 13) & 10'h3ff;
            model_awb_r = 16'h2000 + value * 16'h0311;
            model_awb_g = 16'h4000 ^ (value * 16'h1249);
            model_awb_b = 16'hffff - value * 16'h0217;
            model_ccm_rr = 16'h2000 + value * 17;
            model_ccm_rg = -(value * 31 + 1);
            model_ccm_rb = value * 43 + 2;
            model_ccm_gr = -(value * 47 + 3);
            model_ccm_gg = 16'h2000 + value * 59;
            model_ccm_gb = value * 61 + 4;
            model_ccm_br = value * 67 + 5;
            model_ccm_bg = -(value * 71 + 6);
            model_ccm_bb = 16'h2000 + value * 73;
            model_offset_r = 32'h1020_3040 ^ (value * 32'h0101_0101);
            model_offset_g = -32'sd1048576 + value * 32'sd12345;
            model_offset_b = 32'h7fff_0000 - value * 32'h0001_1101;

            apb_write(A_BAYER,
                      {28'd0, model_roi_y, model_roi_x, model_bayer}, 4'hf, 1'b0);
            apb_write(A_BLACK_R, model_black_r, 4'hf, 1'b0);
            apb_write(A_BLACK_GR, model_black_gr, 4'hf, 1'b0);
            apb_write(A_BLACK_GB, model_black_gb, 4'hf, 1'b0);
            apb_write(A_BLACK_B, model_black_b, 4'hf, 1'b0);
            apb_write(A_AWB_R, model_awb_r, 4'hf, 1'b0);
            apb_write(A_AWB_G, model_awb_g, 4'hf, 1'b0);
            apb_write(A_AWB_B, model_awb_b, 4'hf, 1'b0);
            apb_write(A_CCM_RR, model_ccm_rr, 4'hf, 1'b0);
            apb_write(A_CCM_RG, model_ccm_rg, 4'hf, 1'b0);
            apb_write(A_CCM_RB, model_ccm_rb, 4'hf, 1'b0);
            apb_write(A_CCM_GR, model_ccm_gr, 4'hf, 1'b0);
            apb_write(A_CCM_GG, model_ccm_gg, 4'hf, 1'b0);
            apb_write(A_CCM_GB, model_ccm_gb, 4'hf, 1'b0);
            apb_write(A_CCM_BR, model_ccm_br, 4'hf, 1'b0);
            apb_write(A_CCM_BG, model_ccm_bg, 4'hf, 1'b0);
            apb_write(A_CCM_BB, model_ccm_bb, 4'hf, 1'b0);
            apb_write(A_OFFSET_R, model_offset_r, 4'hf, 1'b0);
            apb_write(A_OFFSET_G, model_offset_g, 4'hf, 1'b0);
            apb_write(A_OFFSET_B, model_offset_b, 4'hf, 1'b0);
        end
    endtask

    // Random target readiness.  Force flags create guaranteed long stalls.
    always @(negedge clk) begin
        if (!rst_n) begin
            lfsr = 32'h1357_9bdf;
            cfg_ready = 1'b0;
            gamma_cfg_ready = 1'b0;
        end else begin
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            cfg_ready = !force_cfg_block && (lfsr[0] || lfsr[5]);
            gamma_cfg_ready = !force_gamma_block && (lfsr[2] || lfsr[9]);
        end
    end

    // Target-side atomicity and handshake scoreboard.
    always @(posedge clk) begin
        if (rst_n) begin
            if (cfg_valid && cfg_ready) begin
                if (!expected_cfg_pending || cfg_bundle !== expected_cfg_bundle)
                    $fatal(1, "ISP config handshake snapshot mismatch");
                expected_cfg_pending = 1'b0;
                cfg_handshakes = cfg_handshakes + 1;
            end
            if (gamma_valid && gamma_cfg_ready) begin
                if (!expected_gamma_pending ||
                    gamma_cfg_addr !== expected_gamma_addr ||
                    gamma_cfg_data !== expected_gamma_data)
                    $fatal(1, "Gamma handshake snapshot mismatch");
                expected_gamma_pending = 1'b0;
                gamma_handshakes = gamma_handshakes + 1;
            end
            if (cfg_valid && !cfg_ready)
                cfg_stall_cycles = cfg_stall_cycles + 1;
            if (gamma_valid && !gamma_cfg_ready)
                gamma_stall_cycles = gamma_stall_cycles + 1;
            if (abort_pulse)
                abort_pulses = abort_pulses + 1;
        end
    end

    logic [331:0] stalled_cfg_bundle;
    logic [17:0] stalled_gamma_bundle;
    always @(posedge clk) begin
        if (rst_n && cfg_valid && !cfg_ready &&
            !(psel && penable && pwrite && paddr == A_CONTROL &&
              pstrb[0] && pwdata[1] && !pwdata[0])) begin
            stalled_cfg_bundle = cfg_bundle;
            #1;
            if (!cfg_valid || cfg_bundle !== stalled_cfg_bundle)
                $fatal(1, "pending ISP config changed while stalled");
        end
    end
    always @(posedge clk) begin
        if (rst_n && gamma_valid && !gamma_cfg_ready &&
            !(psel && penable && pwrite && paddr == A_CONTROL &&
              pstrb[0] && pwdata[1] && !pwdata[0])) begin
            stalled_gamma_bundle = {gamma_cfg_addr, gamma_cfg_data};
            #1;
            if (!gamma_valid ||
                {gamma_cfg_addr, gamma_cfg_data} !== stalled_gamma_bundle)
                $fatal(1, "pending Gamma command changed while stalled");
        end
    end

    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1'b1;

        // Reset defaults and signed readback.
        apb_read(A_BAYER, 32'd0, 1'b0);
        apb_read(A_AWB_R, 32'd16384, 1'b0);
        apb_read(A_CCM_RR, 32'd8192, 1'b0);
        apb_read(A_CCM_GG, 32'd8192, 1'b0);
        apb_read(A_CCM_BB, 32'd8192, 1'b0);
        apb_read(A_STATUS, 32'd0 | (cfg_ready << 3) |
                 (gamma_cfg_ready << 4), 1'b0);

        // Byte-strobe behavior on a 10-bit field.
        apb_write(A_BLACK_R, 32'h0000_03aa, 4'hf, 1'b0);
        apb_write(A_BLACK_R, 32'h0000_0055, 4'b0001, 1'b0);
        apb_read(A_BLACK_R, 32'h0000_0355, 1'b0);
        apb_write(A_BLACK_R, 32'h0000_0200, 4'b0010, 1'b0);
        apb_read(A_BLACK_R, 32'h0000_0255, 1'b0);
        apb_write(A_BLACK_R, 32'hffff_0000, 4'b1100, 1'b0);
        apb_read(A_BLACK_R, 32'h0000_0255, 1'b0);
        apb_write(A_CCM_RG, 32'h0000_8001, 4'hf, 1'b0);
        apb_read(A_CCM_RG, 32'hffff_8001, 1'b0);

        // W1P outside byte lane zero is ignored without an error.
        force_cfg_block = 1'b1;
        apb_write(A_CONTROL, 32'h0000_0001, 4'b0010, 1'b0);
        if (cfg_valid) $fatal(1, "masked COMMIT was not ignored");
        force_gamma_block = 1'b1;
        apb_write(A_GAMMA_COMMAND, 32'h0000_0001, 4'b0010, 1'b0);
        if (gamma_valid) $fatal(1, "masked Gamma WRITE was not ignored");

        // Repeated random scalar commits.  Shadow writes after COMMIT must not
        // alter the waiting snapshot.
        for (iteration = 1; iteration <= 8; iteration = iteration + 1) begin
            program_model(iteration);
            snapshot_model();
            expected_cfg_pending = 1'b1;
            force_cfg_block = 1'b1;
            apb_write(A_CONTROL, 32'h0000_0001, 4'b0001, 1'b0);
            if (!cfg_valid || cfg_bundle !== expected_cfg_bundle)
                $fatal(1, "COMMIT did not create expected pending snapshot");

            // Poison a representative field from every scalar group.
            apb_write(A_BAYER, 32'h0000_000f ^ iteration, 4'hf, 1'b0);
            apb_write(A_BLACK_R, 32'h0000_03ff ^ iteration, 4'hf, 1'b0);
            apb_write(A_AWB_R, 32'h0000_ffff ^ iteration, 4'hf, 1'b0);
            apb_write(A_CCM_RR, 32'h0000_8000 ^ iteration, 4'hf, 1'b0);
            apb_write(A_OFFSET_R, 32'hdead_0000 ^ iteration, 4'hf, 1'b0);
            if (cfg_bundle !== expected_cfg_bundle)
                $fatal(1, "post-COMMIT shadow write polluted snapshot");

            // Busy rewrite is explicitly rejected and ignored.
            apb_write(A_CONTROL, 32'h0000_0001, 4'b0001, 1'b1);
            start_count = cfg_handshakes;
            force_cfg_block = 1'b0;
            while (cfg_handshakes == start_count) @(negedge clk);
            if (expected_cfg_pending || cfg_valid)
                $fatal(1, "config request failed to retire");
        end

        // Independent Gamma ready/valid snapshots and busy error behavior.
        for (iteration = 0; iteration < 16; iteration = iteration + 1) begin
            force_gamma_block = 1'b1;
            apb_write(A_GAMMA_ADDR, iteration * 37, 4'hf, 1'b0);
            apb_write(A_GAMMA_DATA, iteration * 19 + 7, 4'hf, 1'b0);
            expected_gamma_addr = (iteration * 37) & 10'h3ff;
            expected_gamma_data = (iteration * 19 + 7) & 8'hff;
            expected_gamma_pending = 1'b1;
            apb_write(A_GAMMA_COMMAND, 32'h1, 4'b0001, 1'b0);
            apb_write(A_GAMMA_ADDR, 32'h3ff - iteration, 4'hf, 1'b0);
            apb_write(A_GAMMA_DATA, 32'hff - iteration, 4'hf, 1'b0);
            if ({gamma_cfg_addr, gamma_cfg_data} !==
                {expected_gamma_addr, expected_gamma_data})
                $fatal(1, "Gamma shadow writes polluted pending command");
            apb_write(A_GAMMA_COMMAND, 32'h1, 4'b0001, 1'b1);
            start_count = gamma_handshakes;
            force_gamma_block = 1'b0;
            while (gamma_handshakes == start_count) @(negedge clk);
            if (expected_gamma_pending || gamma_valid)
                $fatal(1, "Gamma command failed to retire");
        end

        // Create both pending channels, then cancel them atomically.
        force_cfg_block = 1'b1;
        force_gamma_block = 1'b1;
        program_model(23);
        snapshot_model();
        expected_cfg_pending = 1'b1;
        apb_write(A_CONTROL, 32'h1, 4'b0001, 1'b0);
        apb_write(A_GAMMA_ADDR, 32'h155, 4'hf, 1'b0);
        apb_write(A_GAMMA_DATA, 32'ha6, 4'hf, 1'b0);
        expected_gamma_addr = 10'h155;
        expected_gamma_data = 8'ha6;
        expected_gamma_pending = 1'b1;
        apb_write(A_GAMMA_COMMAND, 32'h1, 4'b0001, 1'b0);
        apb_read(A_STATUS, 32'h0000_0307, 1'b0);
        expected_cfg_pending = 1'b0;
        expected_gamma_pending = 1'b0;
        apb_write(A_CONTROL, 32'h2, 4'b0001, 1'b0);
        repeat (2) @(posedge clk);
        if (cfg_valid || gamma_valid)
            $fatal(1, "ABORT_PENDING failed to cancel requests");

        // Conflicting COMMIT+ABORT is rejected and does neither operation.
        apb_write(A_CONTROL, 32'h3, 4'b0001, 1'b1);
        if (cfg_valid || gamma_valid || abort_pulse)
            $fatal(1, "conflicting control command had side effects");

        // Invalid word/unaligned addresses produce PSLVERR and sticky status.
        apb_read(12'h20c, 32'd0, 1'b1);
        apb_write(12'h211, 32'hffff_ffff, 4'hf, 1'b1);
        apb_read(A_ERROR, 32'h0000_000f, 1'b0);
        apb_write(A_ERROR, 32'h0000_0005, 4'b0001, 1'b0);
        apb_read(A_ERROR, 32'h0000_000a, 1'b0);
        apb_write(A_ERROR, 32'h0000_000a, 4'b0010, 1'b0);
        apb_read(A_ERROR, 32'h0000_000a, 1'b0);
        apb_write(A_ERROR, 32'h0000_000a, 4'b0001, 1'b0);
        apb_read(A_ERROR, 32'd0, 1'b0);

        // Asynchronous reset while requests are pending must leave no stale
        // valid and must restore the identity defaults.
        expected_cfg_pending = 1'b1;
        expected_gamma_pending = 1'b1;
        apb_write(A_CONTROL, 32'h1, 4'b0001, 1'b0);
        apb_write(A_GAMMA_COMMAND, 32'h1, 4'b0001, 1'b0);
        @(negedge clk);
        expected_cfg_pending = 1'b0;
        expected_gamma_pending = 1'b0;
        rst_n = 1'b0;
        #1;
        if (cfg_valid || gamma_valid || abort_pulse)
            $fatal(1, "reset did not clear pending control requests");
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        force_cfg_block = 1'b0;
        force_gamma_block = 1'b0;
        apb_read(A_BAYER, 32'd0, 1'b0);
        apb_read(A_AWB_R, 32'd16384, 1'b0);
        apb_read(A_ERROR, 32'd0, 1'b0);

        repeat (8) @(posedge clk);
        if (cfg_handshakes != 8 || gamma_handshakes != 16)
            $fatal(1, "ready/valid handshake counts mismatch cfg=%0d gamma=%0d",
                   cfg_handshakes, gamma_handshakes);
        if (cfg_stall_cycles == 0 || gamma_stall_cycles == 0)
            $fatal(1, "ready stall coverage missing");
        if (abort_pulses != 1)
            $fatal(1, "abort pulse count mismatch");

        $display("C1_APB_ISP_CONFIG_PASS cfg=%0d gamma=%0d cfg_stalls=%0d gamma_stalls=%0d aborts=%0d",
                 cfg_handshakes, gamma_handshakes,
                 cfg_stall_cycles, gamma_stall_cycles, abort_pulses);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "APB ISP configuration regression timeout");
    end

endmodule
