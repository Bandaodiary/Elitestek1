`timescale 1ns/1ps

// Board-independent R1 RAW10 ISP pipeline:
//   four-phase BLC -> valid-crop bilinear Debayer -> AWB/CCM/Gamma.
//
// Bayer encoding is project-wide:
//   2'b00 RGGB, 2'b01 BGGR, 2'b10 GRBG, 2'b11 GBRG.
// Black levels are ordered R, Gr, Gb, B.  Coordinates are ROI-local; the
// ROI-origin parity inputs map them back to the sensor CFA phase.
//
// Configuration contract:
// * cfg_commit is a ready/valid-style request.  All scalar fields are copied
//   atomically only on cfg_commit && cfg_ready.
// * cfg_ready is asserted only while the complete pixel pipeline is empty and
//   in_valid is low.  A source must complete this handshake before presenting
//   the first pixel of the frame that uses the new configuration.
// * A request may be held while cfg_ready is low.  The live configuration
//   remains unchanged, so a frame can never observe a partial update.
// * Gamma writes use the same empty-pipeline boundary.  gamma_cfg_we is
//   accepted only on gamma_cfg_we && gamma_cfg_ready.
//
// Pixel input has deliberately no backpressure: every cycle with in_valid=1
// is consumed.  Frames must be rectangular, row-major, may contain valid
// gaps, and must not overlap.  After input EOF, wait for cfg_ready before a
// new frame/configuration.  Debayer emits only complete 3x3 centres, hence
// output coordinates are x=1..W-2 and y=1..H-2.
module c1_r1_isp_pipeline #(
    parameter integer FRAME_WIDTH  = 2560,
    parameter integer FRAME_HEIGHT = 1440,
    parameter integer X_BITS       = (FRAME_WIDTH <= 1) ? 1 : $clog2(FRAME_WIDTH),
    parameter integer Y_BITS       = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
    parameter bit ENABLE_FRAME_FLUSH = 1'b0
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    in_valid,
    input  logic                    in_sof,
    input  logic                    in_eol,
    input  logic                    in_eof,
    input  logic [X_BITS-1:0]       in_x,
    input  logic [Y_BITS-1:0]       in_y,
    input  logic [9:0]              in_raw10,

    input  logic                    cfg_commit,
    output logic                    cfg_ready,
    input  logic [1:0]              cfg_bayer_pattern,
    input  logic                    cfg_roi_x_parity,
    input  logic                    cfg_roi_y_parity,
    input  logic [9:0]              cfg_black_r,
    input  logic [9:0]              cfg_black_gr,
    input  logic [9:0]              cfg_black_gb,
    input  logic [9:0]              cfg_black_b,
    input  logic [15:0]             cfg_awb_gain_r,
    input  logic [15:0]             cfg_awb_gain_g,
    input  logic [15:0]             cfg_awb_gain_b,
    input  logic signed [15:0]      cfg_ccm_rr,
    input  logic signed [15:0]      cfg_ccm_rg,
    input  logic signed [15:0]      cfg_ccm_rb,
    input  logic signed [15:0]      cfg_ccm_gr,
    input  logic signed [15:0]      cfg_ccm_gg,
    input  logic signed [15:0]      cfg_ccm_gb,
    input  logic signed [15:0]      cfg_ccm_br,
    input  logic signed [15:0]      cfg_ccm_bg,
    input  logic signed [15:0]      cfg_ccm_bb,
    input  logic signed [31:0]      cfg_ccm_offset_r,
    input  logic signed [31:0]      cfg_ccm_offset_g,
    input  logic signed [31:0]      cfg_ccm_offset_b,

    input  logic                    gamma_cfg_we,
    input  logic [9:0]              gamma_cfg_addr,
    input  logic [7:0]              gamma_cfg_data,
    output logic                    gamma_cfg_ready,

    output logic                    out_valid,
    output logic                    out_sof,
    output logic                    out_eol,
    output logic                    out_eof,
    output logic [X_BITS-1:0]       out_x,
    output logic [Y_BITS-1:0]       out_y,
    output logic [23:0]             out_rgb888,
    // Local destructive pixel flush. Does NOT reset scalar config/Gamma RAM,
    // camera FIFO, or any external writer/AXI transaction. Opt-in for callers.
    input logic                    frame_flush
);

    logic pipeline_busy;
    wire local_flush = ENABLE_FRAME_FLUSH && frame_flush;
    wire pixel_rst = rst || local_flush;
    logic color_out_valid;
    assign out_valid = !pixel_rst && color_out_valid;

    logic [1:0] active_bayer_pattern;
    logic       active_roi_x_parity;
    logic       active_roi_y_parity;
    logic [9:0] active_black_r;
    logic [9:0] active_black_gr;
    logic [9:0] active_black_gb;
    logic [9:0] active_black_b;
    logic [15:0] active_awb_gain_r;
    logic [15:0] active_awb_gain_g;
    logic [15:0] active_awb_gain_b;
    logic signed [15:0] active_ccm_rr;
    logic signed [15:0] active_ccm_rg;
    logic signed [15:0] active_ccm_rb;
    logic signed [15:0] active_ccm_gr;
    logic signed [15:0] active_ccm_gg;
    logic signed [15:0] active_ccm_gb;
    logic signed [15:0] active_ccm_br;
    logic signed [15:0] active_ccm_bg;
    logic signed [15:0] active_ccm_bb;
    logic signed [31:0] active_ccm_offset_r;
    logic signed [31:0] active_ccm_offset_g;
    logic signed [31:0] active_ccm_offset_b;

    logic       blc_valid;
    logic       blc_sof;
    logic       blc_eol;
    logic       blc_eof;
    logic [X_BITS-1:0] blc_x;
    logic [Y_BITS-1:0] blc_y;
    logic [1:0] blc_phase_unused;
    logic [9:0] blc_raw10;

    logic       debayer_valid;
    logic       debayer_sof;
    logic       debayer_eol;
    logic       debayer_eof;
    logic [X_BITS-1:0] debayer_x;
    logic [Y_BITS-1:0] debayer_y;
    logic [9:0] debayer_r10;
    logic [9:0] debayer_g10;
    logic [9:0] debayer_b10;

    logic color_gamma_cfg_ready;
    logic color_gamma_cfg_we;

    always_comb begin
        // in_valid suppresses ready combinationally so commit and the first
        // pixel can never be accepted on the same edge with different views.
        cfg_ready = !pixel_rst && !pipeline_busy && !in_valid;
        gamma_cfg_ready = cfg_ready && color_gamma_cfg_ready;
        color_gamma_cfg_we = gamma_cfg_we && gamma_cfg_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pipeline_busy <= 1'b0;

            active_bayer_pattern <= 2'b00;
            active_roi_x_parity <= 1'b0;
            active_roi_y_parity <= 1'b0;
            active_black_r <= 10'd0;
            active_black_gr <= 10'd0;
            active_black_gb <= 10'd0;
            active_black_b <= 10'd0;
            active_awb_gain_r <= 16'd16384;
            active_awb_gain_g <= 16'd16384;
            active_awb_gain_b <= 16'd16384;
            active_ccm_rr <= 16'sd8192;
            active_ccm_rg <= 16'sd0;
            active_ccm_rb <= 16'sd0;
            active_ccm_gr <= 16'sd0;
            active_ccm_gg <= 16'sd8192;
            active_ccm_gb <= 16'sd0;
            active_ccm_br <= 16'sd0;
            active_ccm_bg <= 16'sd0;
            active_ccm_bb <= 16'sd8192;
            active_ccm_offset_r <= 32'sd0;
            active_ccm_offset_g <= 32'sd0;
            active_ccm_offset_b <= 32'sd0;
        end else begin
            if (local_flush) begin
                pipeline_busy <= 1'b0;
            end else begin
                if (out_valid && out_eof)
                    pipeline_busy <= 1'b0;
                // New input has priority. Overlap is prohibited by contract.
                if (in_valid)
                    pipeline_busy <= 1'b1;
            end

            if (cfg_commit && cfg_ready) begin
                active_bayer_pattern <= cfg_bayer_pattern;
                active_roi_x_parity <= cfg_roi_x_parity;
                active_roi_y_parity <= cfg_roi_y_parity;
                active_black_r <= cfg_black_r;
                active_black_gr <= cfg_black_gr;
                active_black_gb <= cfg_black_gb;
                active_black_b <= cfg_black_b;
                active_awb_gain_r <= cfg_awb_gain_r;
                active_awb_gain_g <= cfg_awb_gain_g;
                active_awb_gain_b <= cfg_awb_gain_b;
                active_ccm_rr <= cfg_ccm_rr;
                active_ccm_rg <= cfg_ccm_rg;
                active_ccm_rb <= cfg_ccm_rb;
                active_ccm_gr <= cfg_ccm_gr;
                active_ccm_gg <= cfg_ccm_gg;
                active_ccm_gb <= cfg_ccm_gb;
                active_ccm_br <= cfg_ccm_br;
                active_ccm_bg <= cfg_ccm_bg;
                active_ccm_bb <= cfg_ccm_bb;
                active_ccm_offset_r <= cfg_ccm_offset_r;
                active_ccm_offset_g <= cfg_ccm_offset_g;
                active_ccm_offset_b <= cfg_ccm_offset_b;
            end
        end
    end

    r1_blc_bayer4_u10 #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_blc (
        .clk,
        .rst(pixel_rst),
        .in_valid,
        .in_sof,
        .in_eol,
        .in_eof,
        .in_x,
        .in_y,
        .in_raw_u10(in_raw10),
        .cfg_bayer_pattern(active_bayer_pattern),
        .cfg_roi_x_parity(active_roi_x_parity),
        .cfg_roi_y_parity(active_roi_y_parity),
        .cfg_black_r(active_black_r),
        .cfg_black_gr(active_black_gr),
        .cfg_black_gb(active_black_gb),
        .cfg_black_b(active_black_b),
        .out_valid(blc_valid),
        .out_sof(blc_sof),
        .out_eol(blc_eol),
        .out_eof(blc_eof),
        .out_x(blc_x),
        .out_y(blc_y),
        .out_phase(blc_phase_unused),
        .out_raw_u10(blc_raw10)
    );

    c1_r1_debayer_bilinear #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_debayer (
        .clk,
        .rst(pixel_rst),
        .in_valid(blc_valid),
        .in_sof(blc_sof),
        .in_eol(blc_eol),
        .in_eof(blc_eof),
        .in_x(blc_x),
        .in_y(blc_y),
        .in_raw10(blc_raw10),
        .cfg_bayer_pattern(active_bayer_pattern),
        .cfg_crop_x_parity(active_roi_x_parity),
        .cfg_crop_y_parity(active_roi_y_parity),
        .out_valid(debayer_valid),
        .out_sof(debayer_sof),
        .out_eol(debayer_eol),
        .out_eof(debayer_eof),
        .out_x(debayer_x),
        .out_y(debayer_y),
        .out_r10(debayer_r10),
        .out_g10(debayer_g10),
        .out_b10(debayer_b10)
    );

    r1_rgb10_color_pipeline #(
        .X_BITS(X_BITS),
        .Y_BITS(Y_BITS)
    ) u_color (
        .clk,
        .rst(pixel_rst),
        .in_valid(debayer_valid),
        .in_sof(debayer_sof),
        .in_eol(debayer_eol),
        .in_eof(debayer_eof),
        .in_x(debayer_x),
        .in_y(debayer_y),
        .in_rgb10({debayer_r10, debayer_g10, debayer_b10}),
        .cfg_awb_gain_r(active_awb_gain_r),
        .cfg_awb_gain_g(active_awb_gain_g),
        .cfg_awb_gain_b(active_awb_gain_b),
        .cfg_ccm_rr(active_ccm_rr),
        .cfg_ccm_rg(active_ccm_rg),
        .cfg_ccm_rb(active_ccm_rb),
        .cfg_ccm_gr(active_ccm_gr),
        .cfg_ccm_gg(active_ccm_gg),
        .cfg_ccm_gb(active_ccm_gb),
        .cfg_ccm_br(active_ccm_br),
        .cfg_ccm_bg(active_ccm_bg),
        .cfg_ccm_bb(active_ccm_bb),
        .cfg_ccm_offset_r(active_ccm_offset_r),
        .cfg_ccm_offset_g(active_ccm_offset_g),
        .cfg_ccm_offset_b(active_ccm_offset_b),
        .gamma_cfg_we(color_gamma_cfg_we),
        .gamma_cfg_addr,
        .gamma_cfg_data,
        .gamma_cfg_ready(color_gamma_cfg_ready),
        .out_valid(color_out_valid),
        .out_sof,
        .out_eol,
        .out_eof,
        .out_x,
        .out_y,
        .out_rgb888
    );

`ifndef SYNTHESIS
    logic sim_in_frame;
    logic [X_BITS-1:0] sim_expected_x;
    logic [Y_BITS-1:0] sim_expected_y;

    initial begin
        if ((FRAME_WIDTH < 3) || (FRAME_HEIGHT < 3))
            $fatal(1, "c1_r1_isp_pipeline requires a frame of at least 3x3");
    end

    always_ff @(posedge clk) begin
        if (pixel_rst) begin
            sim_in_frame <= 1'b0;
            sim_expected_x <= '0;
            sim_expected_y <= '0;
        end else if (in_valid) begin
            if (in_sof) begin
                if (pipeline_busy)
                    $fatal(1, "R1 ISP input frames overlap before pipeline drain");
                if ((in_x != 0) || (in_y != 0))
                    $fatal(1, "R1 ISP SOF must have coordinate (0,0)");
                sim_in_frame <= !in_eof;
                sim_expected_x <= (FRAME_WIDTH == 1) ? '0 : {{(X_BITS-1){1'b0}}, 1'b1};
                sim_expected_y <= '0;
            end else begin
                if (!sim_in_frame)
                    $fatal(1, "R1 ISP valid pixel received outside a frame");
                if ((in_x != sim_expected_x) || (in_y != sim_expected_y))
                    $fatal(1, "R1 ISP input is not a row-major rectangular raster");
                if (in_eof)
                    sim_in_frame <= 1'b0;
                if (in_x == FRAME_WIDTH-1) begin
                    sim_expected_x <= '0;
                    sim_expected_y <= in_y + 1'b1;
                end else begin
                    sim_expected_x <= in_x + 1'b1;
                end
            end
            if (in_eol !== (in_x == FRAME_WIDTH-1))
                $fatal(1, "R1 ISP EOL does not match FRAME_WIDTH");
            if (in_eof !== ((in_x == FRAME_WIDTH-1) &&
                            (in_y == FRAME_HEIGHT-1)))
                $fatal(1, "R1 ISP EOF does not match frame dimensions");
        end
    end
`endif

endmodule
