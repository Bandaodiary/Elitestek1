`timescale 1ns/1ps

module tb_c1_r1_isp_primitives;
    localparam integer MAX_VECTORS = 11000;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg blc_in_valid = 1'b0;
    reg blc_in_sof = 1'b0;
    reg blc_in_eol = 1'b0;
    reg blc_in_eof = 1'b0;
    reg [9:0] blc_in_x = 10'd0;
    reg [8:0] blc_in_y = 9'd0;
    reg [9:0] blc_in_raw = 10'd0;
    reg [1:0] blc_pattern = 2'd0;
    reg blc_roi_x = 1'b0;
    reg blc_roi_y = 1'b0;
    reg [9:0] blc_black_r = 10'd0;
    reg [9:0] blc_black_gr = 10'd0;
    reg [9:0] blc_black_gb = 10'd0;
    reg [9:0] blc_black_b = 10'd0;
    wire blc_out_valid;
    wire blc_out_sof;
    wire blc_out_eol;
    wire blc_out_eof;
    wire [9:0] blc_out_x;
    wire [8:0] blc_out_y;
    wire [1:0] blc_out_phase;
    wire [9:0] blc_out_raw;

    reg color_in_valid = 1'b0;
    reg color_in_sof = 1'b0;
    reg color_in_eol = 1'b0;
    reg color_in_eof = 1'b0;
    reg [9:0] color_in_x = 10'd0;
    reg [8:0] color_in_y = 9'd0;
    reg [29:0] color_in_rgb10 = 30'd0;
    reg [15:0] gain_r = 16'd0;
    reg [15:0] gain_g = 16'd0;
    reg [15:0] gain_b = 16'd0;
    reg signed [15:0] ccm_rr = 16'sd0;
    reg signed [15:0] ccm_rg = 16'sd0;
    reg signed [15:0] ccm_rb = 16'sd0;
    reg signed [15:0] ccm_gr = 16'sd0;
    reg signed [15:0] ccm_gg = 16'sd0;
    reg signed [15:0] ccm_gb = 16'sd0;
    reg signed [15:0] ccm_br = 16'sd0;
    reg signed [15:0] ccm_bg = 16'sd0;
    reg signed [15:0] ccm_bb = 16'sd0;
    reg signed [31:0] offset_r = 32'sd0;
    reg signed [31:0] offset_g = 32'sd0;
    reg signed [31:0] offset_b = 32'sd0;
    reg gamma_cfg_we = 1'b0;
    reg [9:0] gamma_cfg_addr = 10'd0;
    reg [7:0] gamma_cfg_data = 8'd0;
    wire gamma_cfg_ready;
    wire color_out_valid;
    wire color_out_sof;
    wire color_out_eol;
    wire color_out_eof;
    wire [9:0] color_out_x;
    wire [8:0] color_out_y;
    wire [23:0] color_out_rgb888;

    reg [84:0] blc_vectors [0:MAX_VECTORS-1];
    reg [29:0] color_rgb_vectors [0:MAX_VECTORS-1];
    reg [287:0] color_config_vectors [0:MAX_VECTORS-1];
    reg [23:0] color_expected_vectors [0:MAX_VECTORS-1];
    reg [7:0] gamma_vectors [0:1023];

    integer blc_vector_count = 0;
    integer color_vector_count = 0;
    integer blc_output_count = 0;
    integer color_output_count = 0;
    reg blc_driver_done = 1'b0;
    reg color_driver_done = 1'b0;
    reg busy_gamma_attempt_done = 1'b0;
    reg [1:0] blc_expected_valid = 2'b00;
    reg [5:0] color_expected_valid = 6'b000000;

    always #5 clk = ~clk;

    r1_blc_bayer4_u10 u_blc (
        .clk(clk), .rst(rst),
        .in_valid(blc_in_valid), .in_sof(blc_in_sof),
        .in_eol(blc_in_eol), .in_eof(blc_in_eof),
        .in_x(blc_in_x), .in_y(blc_in_y), .in_raw_u10(blc_in_raw),
        .cfg_bayer_pattern(blc_pattern),
        .cfg_roi_x_parity(blc_roi_x), .cfg_roi_y_parity(blc_roi_y),
        .cfg_black_r(blc_black_r), .cfg_black_gr(blc_black_gr),
        .cfg_black_gb(blc_black_gb), .cfg_black_b(blc_black_b),
        .out_valid(blc_out_valid), .out_sof(blc_out_sof),
        .out_eol(blc_out_eol), .out_eof(blc_out_eof),
        .out_x(blc_out_x), .out_y(blc_out_y),
        .out_phase(blc_out_phase), .out_raw_u10(blc_out_raw)
    );

    r1_rgb10_color_pipeline u_color (
        .clk(clk), .rst(rst),
        .in_valid(color_in_valid), .in_sof(color_in_sof),
        .in_eol(color_in_eol), .in_eof(color_in_eof),
        .in_x(color_in_x), .in_y(color_in_y), .in_rgb10(color_in_rgb10),
        .cfg_awb_gain_r(gain_r), .cfg_awb_gain_g(gain_g),
        .cfg_awb_gain_b(gain_b),
        .cfg_ccm_rr(ccm_rr), .cfg_ccm_rg(ccm_rg), .cfg_ccm_rb(ccm_rb),
        .cfg_ccm_gr(ccm_gr), .cfg_ccm_gg(ccm_gg), .cfg_ccm_gb(ccm_gb),
        .cfg_ccm_br(ccm_br), .cfg_ccm_bg(ccm_bg), .cfg_ccm_bb(ccm_bb),
        .cfg_ccm_offset_r(offset_r), .cfg_ccm_offset_g(offset_g),
        .cfg_ccm_offset_b(offset_b),
        .gamma_cfg_we(gamma_cfg_we), .gamma_cfg_addr(gamma_cfg_addr),
        .gamma_cfg_data(gamma_cfg_data), .gamma_cfg_ready(gamma_cfg_ready),
        .out_valid(color_out_valid), .out_sof(color_out_sof),
        .out_eol(color_out_eol), .out_eof(color_out_eof),
        .out_x(color_out_x), .out_y(color_out_y),
        .out_rgb888(color_out_rgb888)
    );

    task automatic load_vectors;
        integer fd;
        integer scan_status;
        integer index;
        integer gamma_count;
        begin
            fd = $fopen("c1_r1_blc_vectors.txt", "r");
            if (fd == 0) $fatal(1, "cannot open BLC vectors");
            scan_status = $fscanf(fd, "%d\n", blc_vector_count);
            if (scan_status != 1 || blc_vector_count <= 0 ||
                blc_vector_count > MAX_VECTORS)
                $fatal(1, "invalid BLC vector count %0d", blc_vector_count);
            for (index = 0; index < blc_vector_count; index = index + 1) begin
                scan_status = $fscanf(fd, "%h\n", blc_vectors[index]);
                if (scan_status != 1) $fatal(1, "malformed BLC vector %0d", index);
            end
            $fclose(fd);

            fd = $fopen("c1_r1_color_vectors.txt", "r");
            if (fd == 0) $fatal(1, "cannot open color vectors");
            scan_status = $fscanf(fd, "%d\n", color_vector_count);
            if (scan_status != 1 || color_vector_count <= 0 ||
                color_vector_count > MAX_VECTORS)
                $fatal(1, "invalid color vector count %0d", color_vector_count);
            for (index = 0; index < color_vector_count; index = index + 1) begin
                scan_status = $fscanf(
                    fd, "%h %h %h\n", color_rgb_vectors[index],
                    color_config_vectors[index], color_expected_vectors[index]);
                if (scan_status != 3)
                    $fatal(1, "malformed color vector %0d", index);
            end
            $fclose(fd);

            fd = $fopen("c1_r1_gamma_lut.txt", "r");
            if (fd == 0) $fatal(1, "cannot open Gamma vectors");
            scan_status = $fscanf(fd, "%d\n", gamma_count);
            if (scan_status != 1 || gamma_count != 1024)
                $fatal(1, "invalid Gamma vector count %0d", gamma_count);
            for (index = 0; index < 1024; index = index + 1) begin
                scan_status = $fscanf(fd, "%h\n", gamma_vectors[index]);
                if (scan_status != 1)
                    $fatal(1, "malformed Gamma vector %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic program_gamma;
        integer index;
        begin
            for (index = 0; index < 1024; index = index + 1) begin
                if (!gamma_cfg_ready)
                    $fatal(1, "Gamma not ready during idle programming at %0d", index);
                gamma_cfg_we = 1'b1;
                gamma_cfg_addr = index[9:0];
                gamma_cfg_data = gamma_vectors[index];
                @(negedge clk);
            end
            gamma_cfg_we = 1'b0;
            gamma_cfg_addr = 10'd0;
            gamma_cfg_data = 8'd0;
        end
    endtask

    task automatic drive_blc_vectors;
        integer index;
        integer drive_cycle;
        begin
            index = 0;
            drive_cycle = 0;
            while (index < blc_vector_count) begin
                if (((drive_cycle % 7) == 2) || ((drive_cycle % 29) == 11)) begin
                    blc_in_valid = 1'b0;
                    blc_in_sof = 1'b0;
                    blc_in_eol = 1'b0;
                    blc_in_eof = 1'b0;
                end else begin
                    blc_in_valid = 1'b1;
                    blc_in_sof = (index == 0) || ((index % 809) == 0);
                    blc_in_eol = ((index % 37) == 36);
                    blc_in_eof = (index == blc_vector_count - 1);
                    blc_in_raw = blc_vectors[index][84:75];
                    blc_in_x = blc_vectors[index][74:65];
                    blc_in_y = blc_vectors[index][64:56];
                    blc_pattern = blc_vectors[index][55:54];
                    blc_roi_x = blc_vectors[index][53];
                    blc_roi_y = blc_vectors[index][52];
                    blc_black_r = blc_vectors[index][51:42];
                    blc_black_gr = blc_vectors[index][41:32];
                    blc_black_gb = blc_vectors[index][31:22];
                    blc_black_b = blc_vectors[index][21:12];
                    index = index + 1;
                end
                drive_cycle = drive_cycle + 1;
                @(negedge clk);
            end
            blc_in_valid = 1'b0;
            blc_in_sof = 1'b0;
            blc_in_eol = 1'b0;
            blc_in_eof = 1'b0;
            blc_driver_done = 1'b1;
        end
    endtask

    task automatic drive_color_vectors;
        integer index;
        integer drive_cycle;
        reg [287:0] config_word;
        begin
            index = 0;
            drive_cycle = 0;
            while (index < color_vector_count) begin
                if (((drive_cycle % 9) == 4) || ((drive_cycle % 31) == 7)) begin
                    color_in_valid = 1'b0;
                    color_in_sof = 1'b0;
                    color_in_eol = 1'b0;
                    color_in_eof = 1'b0;
                end else begin
                    config_word = color_config_vectors[index];
                    color_in_valid = 1'b1;
                    color_in_sof = (index == 0) || ((index % 887) == 0);
                    color_in_eol = ((index % 41) == 40);
                    color_in_eof = (index == color_vector_count - 1);
                    color_in_x = (index * 5) % 1024;
                    color_in_y = (index * 13) % 512;
                    color_in_rgb10 = color_rgb_vectors[index];
                    gain_r = config_word[287:272];
                    gain_g = config_word[271:256];
                    gain_b = config_word[255:240];
                    ccm_rr = config_word[239:224];
                    ccm_rg = config_word[223:208];
                    ccm_rb = config_word[207:192];
                    ccm_gr = config_word[191:176];
                    ccm_gg = config_word[175:160];
                    ccm_gb = config_word[159:144];
                    ccm_br = config_word[143:128];
                    ccm_bg = config_word[127:112];
                    ccm_bb = config_word[111:96];
                    offset_r = config_word[95:64];
                    offset_g = config_word[63:32];
                    offset_b = config_word[31:0];
                    index = index + 1;
                end
                drive_cycle = drive_cycle + 1;
                @(negedge clk);
            end
            color_in_valid = 1'b0;
            color_in_sof = 1'b0;
            color_in_eol = 1'b0;
            color_in_eof = 1'b0;
            color_driver_done = 1'b1;
        end
    endtask

    // A write deliberately presented while a pixel is in flight must not be
    // accepted.  Subsequent Golden comparisons also prove LUT[0] is unchanged.
    task automatic attempt_busy_gamma_write;
        begin
            wait (color_in_valid);
            @(posedge clk);
            #1;
            @(negedge clk);
            if (gamma_cfg_ready)
                $fatal(1, "Gamma ready unexpectedly high with pixel in flight");
            gamma_cfg_we = 1'b1;
            gamma_cfg_addr = 10'd0;
            gamma_cfg_data = 8'hee;
            @(negedge clk);
            gamma_cfg_we = 1'b0;
            gamma_cfg_addr = 10'd0;
            gamma_cfg_data = 8'd0;
            busy_gamma_attempt_done = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            blc_expected_valid <= 2'b00;
            color_expected_valid <= 6'b000000;
            blc_output_count = 0;
            color_output_count = 0;
        end else begin
            blc_expected_valid <= {blc_expected_valid[0], blc_in_valid};
            color_expected_valid <= {color_expected_valid[4:0], color_in_valid};
            #1;

            if (blc_out_valid !== blc_expected_valid[1])
                $fatal(1, "BLC valid latency mismatch");
            if (color_out_valid !== color_expected_valid[5])
                $fatal(1, "color valid latency mismatch");

            if (!blc_out_valid) begin
                if (blc_out_sof || blc_out_eol || blc_out_eof)
                    $fatal(1, "BLC metadata asserted while invalid");
            end else begin
                if (blc_output_count >= blc_vector_count)
                    $fatal(1, "unexpected extra BLC output");
                if (blc_out_raw !== blc_vectors[blc_output_count][11:2] ||
                    blc_out_phase !== blc_vectors[blc_output_count][1:0])
                    $fatal(1, "BLC value mismatch index=%0d got=%0d/%0d expected=%0d/%0d",
                           blc_output_count, blc_out_raw, blc_out_phase,
                           blc_vectors[blc_output_count][11:2],
                           blc_vectors[blc_output_count][1:0]);
                if (blc_out_x !== blc_vectors[blc_output_count][74:65] ||
                    blc_out_y !== blc_vectors[blc_output_count][64:56])
                    $fatal(1, "BLC coordinate mismatch index=%0d", blc_output_count);
                if (blc_out_sof !== ((blc_output_count == 0) ||
                                     ((blc_output_count % 809) == 0)))
                    $fatal(1, "BLC SOF mismatch index=%0d", blc_output_count);
                if (blc_out_eol !== ((blc_output_count % 37) == 36))
                    $fatal(1, "BLC EOL mismatch index=%0d", blc_output_count);
                if (blc_out_eof !== (blc_output_count == blc_vector_count - 1))
                    $fatal(1, "BLC EOF mismatch index=%0d", blc_output_count);
                blc_output_count = blc_output_count + 1;
            end

            if (!color_out_valid) begin
                if (color_out_sof || color_out_eol || color_out_eof)
                    $fatal(1, "color metadata asserted while invalid");
            end else begin
                if (color_output_count >= color_vector_count)
                    $fatal(1, "unexpected extra color output");
                if (color_out_rgb888 !== color_expected_vectors[color_output_count])
                    $fatal(1, "color mismatch index=%0d got=%h expected=%h",
                           color_output_count, color_out_rgb888,
                           color_expected_vectors[color_output_count]);
                if (color_out_x !== ((color_output_count * 5) % 1024) ||
                    color_out_y !== ((color_output_count * 13) % 512))
                    $fatal(1, "color coordinate mismatch index=%0d", color_output_count);
                if (color_out_sof !== ((color_output_count == 0) ||
                                       ((color_output_count % 887) == 0)))
                    $fatal(1, "color SOF mismatch index=%0d", color_output_count);
                if (color_out_eol !== ((color_output_count % 41) == 40))
                    $fatal(1, "color EOL mismatch index=%0d", color_output_count);
                if (color_out_eof !==
                    (color_output_count == color_vector_count - 1))
                    $fatal(1, "color EOF mismatch index=%0d", color_output_count);
                color_output_count = color_output_count + 1;
            end
        end
    end

    initial begin
        load_vectors();
        repeat (5) @(negedge clk);
        rst = 1'b0;
        #1;
        program_gamma();

        fork
            drive_blc_vectors();
            drive_color_vectors();
            attempt_busy_gamma_write();
        join

        wait (blc_driver_done && color_driver_done && busy_gamma_attempt_done &&
              blc_output_count == blc_vector_count &&
              color_output_count == color_vector_count);
        repeat (8) @(negedge clk);
        if (blc_out_valid || color_out_valid)
            $fatal(1, "output valid did not drain");

        $display("C1_R1_ISP_PRIMITIVES_PASS blc=%0d color=%0d gamma=%0d",
                 blc_output_count, color_output_count, 1024);
        $finish;
    end

    initial begin
        repeat (60000) @(posedge clk);
        $fatal(1, "R1 ISP primitive test timeout");
    end

endmodule
