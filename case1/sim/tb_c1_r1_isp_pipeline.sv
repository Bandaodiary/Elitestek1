`timescale 1ns/1ps

module tb_c1_r1_isp_pipeline;

    localparam integer FRAME_WIDTH = 10;
    localparam integer FRAME_HEIGHT = 8;
    localparam integer X_BITS = 4;
    localparam integer Y_BITS = 3;
    localparam integer FRAME_COUNT = 16;
    localparam integer INPUT_COUNT = 1280;
    localparam integer OUTPUT_COUNT = 768;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic in_valid = 1'b0;
    logic in_sof = 1'b0;
    logic in_eol = 1'b0;
    logic in_eof = 1'b0;
    logic [X_BITS-1:0] in_x = '0;
    logic [Y_BITS-1:0] in_y = '0;
    logic [9:0] in_raw10 = '0;

    logic cfg_commit = 1'b0;
    wire cfg_ready;
    logic [1:0] cfg_bayer_pattern = 2'b00;
    logic cfg_roi_x_parity = 1'b0;
    logic cfg_roi_y_parity = 1'b0;
    logic [9:0] cfg_black_r = '0;
    logic [9:0] cfg_black_gr = '0;
    logic [9:0] cfg_black_gb = '0;
    logic [9:0] cfg_black_b = '0;
    logic [15:0] cfg_awb_gain_r = 16'd16384;
    logic [15:0] cfg_awb_gain_g = 16'd16384;
    logic [15:0] cfg_awb_gain_b = 16'd16384;
    logic signed [15:0] cfg_ccm_rr = 16'sd8192;
    logic signed [15:0] cfg_ccm_rg = 16'sd0;
    logic signed [15:0] cfg_ccm_rb = 16'sd0;
    logic signed [15:0] cfg_ccm_gr = 16'sd0;
    logic signed [15:0] cfg_ccm_gg = 16'sd8192;
    logic signed [15:0] cfg_ccm_gb = 16'sd0;
    logic signed [15:0] cfg_ccm_br = 16'sd0;
    logic signed [15:0] cfg_ccm_bg = 16'sd0;
    logic signed [15:0] cfg_ccm_bb = 16'sd8192;
    logic signed [31:0] cfg_ccm_offset_r = 32'sd0;
    logic signed [31:0] cfg_ccm_offset_g = 32'sd0;
    logic signed [31:0] cfg_ccm_offset_b = 32'sd0;

    logic gamma_cfg_we = 1'b0;
    logic [9:0] gamma_cfg_addr = '0;
    logic [7:0] gamma_cfg_data = '0;
    wire gamma_cfg_ready;

    wire out_valid;
    wire out_sof;
    wire out_eol;
    wire out_eof;
    wire [X_BITS-1:0] out_x;
    wire [Y_BITS-1:0] out_y;
    wire [23:0] out_rgb888;

    logic [7:0] gamma_mem [0:1023];
    logic [9:0] raw_mem [0:INPUT_COUNT-1];
    logic [331:0] config_mem [0:FRAME_COUNT-1];
    logic [33:0] expected_mem [0:OUTPUT_COUNT-1];

    integer observed_outputs = 0;
    integer observed_frames = 0;
    integer cfg_accepts = 0;
    integer cfg_wait_cycles = 0;
    integer gamma_reject_checks = 0;

    always #5 clk = ~clk;

    c1_r1_isp_pipeline #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) dut (
        .clk,
        .rst,
        .in_valid,
        .in_sof,
        .in_eol,
        .in_eof,
        .in_x,
        .in_y,
        .in_raw10,
        .cfg_commit,
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
        .gamma_cfg_we,
        .gamma_cfg_addr,
        .gamma_cfg_data,
        .gamma_cfg_ready,
        .out_valid,
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .out_rgb888
    );

    task automatic load_config(input integer frame_index);
        logic [331:0] word;
        begin
            word = config_mem[frame_index];
            cfg_bayer_pattern = word[1:0];
            cfg_roi_x_parity = word[2];
            cfg_roi_y_parity = word[3];
            cfg_black_r = word[13:4];
            cfg_black_gr = word[23:14];
            cfg_black_gb = word[33:24];
            cfg_black_b = word[43:34];
            cfg_awb_gain_r = word[59:44];
            cfg_awb_gain_g = word[75:60];
            cfg_awb_gain_b = word[91:76];
            cfg_ccm_rr = word[107:92];
            cfg_ccm_rg = word[123:108];
            cfg_ccm_rb = word[139:124];
            cfg_ccm_gr = word[155:140];
            cfg_ccm_gg = word[171:156];
            cfg_ccm_gb = word[187:172];
            cfg_ccm_br = word[203:188];
            cfg_ccm_bg = word[219:204];
            cfg_ccm_bb = word[235:220];
            cfg_ccm_offset_r = word[267:236];
            cfg_ccm_offset_g = word[299:268];
            cfg_ccm_offset_b = word[331:300];
        end
    endtask

    task automatic commit_loaded_config(input logic must_wait);
        integer local_wait;
        begin
            local_wait = 0;
            cfg_commit = 1'b1;
            while (!cfg_ready) begin
                local_wait = local_wait + 1;
                cfg_wait_cycles = cfg_wait_cycles + 1;
                @(negedge clk);
            end
            if (must_wait && (local_wait == 0))
                $fatal(1, "configuration unexpectedly accepted before drain");
            // cfg_commit remains asserted across the following rising edge,
            // where the single atomic acceptance occurs.
            @(negedge clk);
            cfg_commit = 1'b0;
        end
    endtask

    task automatic program_gamma;
        integer address;
        begin
            @(negedge clk);
            for (address = 0; address < 1024; address = address + 1) begin
                while (!gamma_cfg_ready)
                    @(negedge clk);
                gamma_cfg_we = 1'b1;
                gamma_cfg_addr = address[9:0];
                gamma_cfg_data = gamma_mem[address];
                @(negedge clk);
            end
            gamma_cfg_we = 1'b0;
            gamma_cfg_addr = '0;
            gamma_cfg_data = '0;
        end
    endtask

    task automatic drive_frame(input integer frame_index);
        integer x;
        integer y;
        integer input_index;
        begin
            input_index = frame_index * FRAME_WIDTH * FRAME_HEIGHT;
            for (y = 0; y < FRAME_HEIGHT; y = y + 1) begin
                for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                    // Valid gaps prove that the contract is clock-enable based,
                    // not dependent on an uninterrupted raster clock.
                    if (((x + 3*y + frame_index) % 13) == 7) begin
                        in_valid = 1'b0;
                        in_sof = 1'b0;
                        in_eol = 1'b0;
                        in_eof = 1'b0;
                        @(negedge clk);
                    end
                    in_valid = 1'b1;
                    in_sof = (x == 0) && (y == 0);
                    in_eol = (x == FRAME_WIDTH-1);
                    in_eof = (x == FRAME_WIDTH-1) &&
                             (y == FRAME_HEIGHT-1);
                    in_x = x[X_BITS-1:0];
                    in_y = y[Y_BITS-1:0];
                    in_raw10 = raw_mem[input_index];
                    input_index = input_index + 1;
                    @(negedge clk);
                end
            end
            in_valid = 1'b0;
            in_sof = 1'b0;
            in_eol = 1'b0;
            in_eof = 1'b0;
            in_x = '0;
            in_y = '0;
            in_raw10 = '0;
        end
    endtask

    // Scoreboard samples the pre-NBA output payload accepted on this edge.
    always @(posedge clk) begin
        if (!rst) begin
            if (cfg_commit && cfg_ready)
                cfg_accepts = cfg_accepts + 1;

            if (!out_valid && (out_sof || out_eol || out_eof))
                $fatal(1, "output frame flag asserted while out_valid is low");
            if (out_valid) begin
                if (observed_outputs >= OUTPUT_COUNT)
                    $fatal(1, "unexpected extra ISP output");
                if (out_rgb888 !== expected_mem[observed_outputs][23:0])
                    $fatal(1,
                           "RGB mismatch index=%0d got=%h expected=%h",
                           observed_outputs, out_rgb888,
                           expected_mem[observed_outputs][23:0]);
                if (out_x !== expected_mem[observed_outputs][27:24] ||
                    out_y !== expected_mem[observed_outputs][30:28])
                    $fatal(1, "coordinate mismatch index=%0d", observed_outputs);
                if (out_sof !== expected_mem[observed_outputs][31] ||
                    out_eol !== expected_mem[observed_outputs][32] ||
                    out_eof !== expected_mem[observed_outputs][33])
                    $fatal(1, "frame flag mismatch index=%0d", observed_outputs);
                if (out_eof)
                    observed_frames = observed_frames + 1;
                observed_outputs = observed_outputs + 1;
            end
        end
    end

    integer frame_index;
    initial begin
        $readmemh("r1_isp_pipeline_gamma.hex", gamma_mem);
        $readmemh("r1_isp_pipeline_raw.hex", raw_mem);
        $readmemh("r1_isp_pipeline_config.hex", config_mem);
        $readmemh("r1_isp_pipeline_expected.hex", expected_mem);

        repeat (6) @(negedge clk);
        rst = 1'b0;

        program_gamma();
        load_config(0);
        commit_loaded_config(1'b0);

        for (frame_index = 0; frame_index < FRAME_COUNT;
             frame_index = frame_index + 1) begin
            drive_frame(frame_index);

            if (frame_index == 0) begin
                // A write attempted while line buffers/output stages are live
                // must be rejected and must not corrupt address zero.
                if (gamma_cfg_ready !== 1'b0)
                    $fatal(1, "Gamma programming became ready before drain");
                gamma_cfg_we = 1'b1;
                gamma_cfg_addr = 10'd0;
                gamma_cfg_data = ~gamma_mem[0];
                @(negedge clk);
                if (gamma_cfg_ready !== 1'b0)
                    $fatal(1, "Gamma busy-write test missed the busy interval");
                gamma_cfg_we = 1'b0;
                gamma_cfg_addr = '0;
                gamma_cfg_data = '0;
                gamma_reject_checks = gamma_reject_checks + 1;
            end

            if (frame_index != FRAME_COUNT-1) begin
                // Present the next frame's entire configuration while the
                // prior frame is still draining.  Holding commit exercises
                // both rejection and eventual ready/valid acceptance.
                load_config(frame_index + 1);
                commit_loaded_config(1'b1);
            end
        end

        wait (observed_outputs == OUTPUT_COUNT);
        while (!cfg_ready)
            @(negedge clk);
        repeat (5) @(posedge clk);

        if (observed_outputs != OUTPUT_COUNT)
            $fatal(1, "final output count mismatch");
        if (observed_frames != FRAME_COUNT)
            $fatal(1, "final output-frame count mismatch");
        if (cfg_accepts != FRAME_COUNT)
            $fatal(1, "configuration acceptance count mismatch");
        if (cfg_wait_cycles < FRAME_COUNT-1)
            $fatal(1, "configuration busy/wait coverage is insufficient");
        if (gamma_reject_checks != 1)
            $fatal(1, "Gamma busy-write rejection was not tested");

        $display("C1_R1_ISP_PIPELINE_PASS frames=%0d input=%0d output=%0d",
                 FRAME_COUNT, INPUT_COUNT, OUTPUT_COUNT);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "R1 ISP pipeline regression timeout");
    end

endmodule
