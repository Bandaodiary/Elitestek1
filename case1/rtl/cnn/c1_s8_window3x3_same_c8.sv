`timescale 1ns/1ps

// Board-independent 3x3 SAME/replicate window generator for C8 signed-int8
// pixels.  Each input pixel is an opaque 64-bit beat (channel 0 at bits 7:0).
// Window tap order is row-major, with tap 0/top-left at bits [63:0] and tap
// 8/bottom-right at bits [575:512].
//
// start snapshots width, height, and stride (1 or 2).  Input pixels are then
// accepted in raster order without coordinate sidebands.  Output coordinates
// are source-image centre coordinates: stride 1 produces every centre, while
// stride 2 produces (0,0), (2,0), ... and ceil(W/2)*ceil(H/2) windows.
//
// Two portable synchronous read-first line RAMs rotate roles.  While input row
// y is written over the old y-2 bank, that bank and the y-1 bank are read to
// form the top/middle taps; the accepted input beat forms the bottom tap.  The
// final source row is replayed from RAM to replicate the bottom boundary.
// Neither RAM is reset.
//
// This conservative baseline sequences ISSUE -> synchronous READ -> optional
// EMIT.  It therefore does not accept one input pixel per clock: stride-1
// interior pixels have initiation interval 3 with an always-ready sink (2 for
// pixels that do not emit).  The explicit schedule keeps RAM inference and
// arbitrary downstream backpressure portable across FPGA vendors.
module c1_s8_window3x3_same_c8 #(
    parameter integer MAX_WIDTH = 640
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          abort,

    input  logic          start_valid,
    output logic          start_ready,
    input  logic [15:0]   cfg_width,
    input  logic [15:0]   cfg_height,
    input  logic [1:0]    cfg_stride,
    output logic          start_error,
    output logic [1:0]    start_error_code,
    output logic          busy,
    output logic          done,

    input  logic          in_valid,
    output logic          in_ready,
    input  logic [63:0]   in_data_s8,

    output logic          out_valid,
    input  logic          out_ready,
    output logic [575:0]  out_window_s8,
    output logic [15:0]   out_center_x,
    output logic [15:0]   out_center_y,
    output logic          out_sof,
    output logic          out_eol,
    output logic          out_eof
);

    localparam logic [1:0] START_ERR_NONE = 2'd0;
    localparam logic [1:0] START_ERR_ZERO_DIMENSION = 2'd1;
    localparam logic [1:0] START_ERR_WIDTH_EXCEEDS_MAX = 2'd2;
    localparam logic [1:0] START_ERR_STRIDE = 2'd3;
    localparam integer RAM_ADDR_WIDTH =
        (MAX_WIDTH <= 1) ? 1 : $clog2(MAX_WIDTH);

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_FIRST_CAPTURE,
        STATE_ROW_WAIT_INPUT,
        STATE_ROW_READ,
        STATE_ROW_RIGHT_FLUSH,
        STATE_ROW_FINISH,
        STATE_BOTTOM_ISSUE,
        STATE_BOTTOM_READ,
        STATE_BOTTOM_RIGHT_FLUSH,
        STATE_EMIT
    } state_t;

    state_t state;
    state_t after_emit_state;
    logic [15:0] width_q;
    logic [15:0] height_q;
    logic [1:0] stride_q;
    logic [15:0] first_capture_x;
    logic [15:0] input_row_y;
    logic [15:0] input_x;
    logic [15:0] replay_x;
    logic [15:0] pending_x;
    logic [63:0] pending_bottom;
    logic mid_bank;

    logic [63:0] top_left_q, top_center_q, top_right_q;
    logic [63:0] mid_left_q, mid_center_q, mid_right_q;
    logic [63:0] bot_left_q, bot_center_q, bot_right_q;

    logic [575:0] output_window_q;
    logic [15:0] output_x_q, output_y_q;
    logic output_sof_q, output_eol_q, output_eof_q;

    logic ram0_rd_en, ram1_rd_en;
    logic [RAM_ADDR_WIDTH-1:0] ram0_rd_addr, ram1_rd_addr;
    logic [63:0] ram0_rd_data, ram1_rd_data;
    logic ram0_wr_en, ram1_wr_en;
    logic [RAM_ADDR_WIDTH-1:0] ram0_wr_addr, ram1_wr_addr;
    logic [63:0] ram0_wr_data, ram1_wr_data;

    logic input_fire;
    logic output_fire;
    logic [63:0] selected_mid_sample;
    logic [63:0] selected_other_sample;
    logic [63:0] selected_top_sample;
    logic [63:0] selected_bottom_sample;
    logic [63:0] next_top_left, next_top_center, next_top_right;
    logic [63:0] next_mid_left, next_mid_center, next_mid_right;
    logic [63:0] next_bot_left, next_bot_center, next_bot_right;
    logic [15:0] active_center_y;
    logic active_row_selected;
    logic [15:0] candidate_center_x;
    logic candidate_selected;
    logic [15:0] last_center_x;
    logic [15:0] last_center_y;

    function automatic logic [575:0] pack_window(
        input logic [63:0] top_left,
        input logic [63:0] top_center,
        input logic [63:0] top_right,
        input logic [63:0] mid_left,
        input logic [63:0] mid_center,
        input logic [63:0] mid_right,
        input logic [63:0] bot_left,
        input logic [63:0] bot_center,
        input logic [63:0] bot_right
    );
        begin
            pack_window = {
                bot_right, bot_center, bot_left,
                mid_right, mid_center, mid_left,
                top_right, top_center, top_left
            };
        end
    endfunction

    always_comb begin
        start_ready = !rst && !abort && (state == STATE_IDLE);
        busy = (state != STATE_IDLE);
        in_ready = !abort && ((state == STATE_FIRST_CAPTURE) ||
                              (state == STATE_ROW_WAIT_INPUT));
        input_fire = in_valid && in_ready;
        out_valid = !abort && (state == STATE_EMIT);
        output_fire = out_valid && out_ready;
        out_window_s8 = output_window_q;
        out_center_x = output_x_q;
        out_center_y = output_y_q;
        out_sof = out_valid && output_sof_q;
        out_eol = out_valid && output_eol_q;
        out_eof = out_valid && output_eof_q;

        if (stride_q == 2)
            last_center_x = ((width_q - 16'd1) >> 1) << 1;
        else
            last_center_x = width_q - 16'd1;
        if (stride_q == 2)
            last_center_y = ((height_q - 16'd1) >> 1) << 1;
        else
            last_center_y = height_q - 16'd1;

        if ((state == STATE_BOTTOM_READ) ||
            (state == STATE_BOTTOM_RIGHT_FLUSH))
            active_center_y = height_q - 16'd1;
        else
            active_center_y = input_row_y - 16'd1;
        active_row_selected = (stride_q == 1) || !active_center_y[0];
        candidate_center_x = pending_x - 16'd1;
        candidate_selected = (pending_x != 0) && active_row_selected &&
                             ((stride_q == 1) || !candidate_center_x[0]);

        selected_mid_sample = mid_bank ? ram1_rd_data : ram0_rd_data;
        selected_other_sample = mid_bank ? ram0_rd_data : ram1_rd_data;
        if (((state == STATE_ROW_READ) && (input_row_y == 16'd1)) ||
            ((state == STATE_BOTTOM_READ) && (height_q == 16'd1)))
            selected_top_sample = selected_mid_sample;
        else
            selected_top_sample = selected_other_sample;
        if (state == STATE_BOTTOM_READ)
            selected_bottom_sample = selected_mid_sample;
        else
            selected_bottom_sample = pending_bottom;

        if (pending_x == 0) begin
            next_top_left = selected_top_sample;
            next_top_center = selected_top_sample;
            next_top_right = selected_top_sample;
            next_mid_left = selected_mid_sample;
            next_mid_center = selected_mid_sample;
            next_mid_right = selected_mid_sample;
            next_bot_left = selected_bottom_sample;
            next_bot_center = selected_bottom_sample;
            next_bot_right = selected_bottom_sample;
        end else begin
            next_top_left = top_center_q;
            next_top_center = top_right_q;
            next_top_right = selected_top_sample;
            next_mid_left = mid_center_q;
            next_mid_center = mid_right_q;
            next_mid_right = selected_mid_sample;
            next_bot_left = bot_center_q;
            next_bot_center = bot_right_q;
            next_bot_right = selected_bottom_sample;
        end

        ram0_rd_en = 1'b0;
        ram1_rd_en = 1'b0;
        ram0_rd_addr = '0;
        ram1_rd_addr = '0;
        ram0_wr_en = 1'b0;
        ram1_wr_en = 1'b0;
        ram0_wr_addr = '0;
        ram1_wr_addr = '0;
        ram0_wr_data = in_data_s8;
        ram1_wr_data = in_data_s8;

        if ((state == STATE_FIRST_CAPTURE) && input_fire) begin
            ram0_wr_en = 1'b1;
            ram0_wr_addr = first_capture_x[RAM_ADDR_WIDTH-1:0];
        end else if ((state == STATE_ROW_WAIT_INPUT) && input_fire) begin
            ram0_rd_en = 1'b1;
            ram1_rd_en = 1'b1;
            ram0_rd_addr = input_x[RAM_ADDR_WIDTH-1:0];
            ram1_rd_addr = input_x[RAM_ADDR_WIDTH-1:0];
            if (mid_bank) begin
                ram0_wr_en = 1'b1;
                ram0_wr_addr = input_x[RAM_ADDR_WIDTH-1:0];
            end else begin
                ram1_wr_en = 1'b1;
                ram1_wr_addr = input_x[RAM_ADDR_WIDTH-1:0];
            end
        end else if (state == STATE_BOTTOM_ISSUE) begin
            ram0_rd_en = 1'b1;
            ram1_rd_en = 1'b1;
            ram0_rd_addr = replay_x[RAM_ADDR_WIDTH-1:0];
            ram1_rd_addr = replay_x[RAM_ADDR_WIDTH-1:0];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            after_emit_state <= STATE_IDLE;
            width_q <= 16'd0;
            height_q <= 16'd0;
            stride_q <= 2'd1;
            first_capture_x <= 16'd0;
            input_row_y <= 16'd0;
            input_x <= 16'd0;
            replay_x <= 16'd0;
            pending_x <= 16'd0;
            pending_bottom <= 64'd0;
            mid_bank <= 1'b0;
            top_left_q <= 64'd0;
            top_center_q <= 64'd0;
            top_right_q <= 64'd0;
            mid_left_q <= 64'd0;
            mid_center_q <= 64'd0;
            mid_right_q <= 64'd0;
            bot_left_q <= 64'd0;
            bot_center_q <= 64'd0;
            bot_right_q <= 64'd0;
            output_window_q <= '0;
            output_x_q <= 16'd0;
            output_y_q <= 16'd0;
            output_sof_q <= 1'b0;
            output_eol_q <= 1'b0;
            output_eof_q <= 1'b0;
            start_error <= 1'b0;
            start_error_code <= START_ERR_NONE;
            done <= 1'b0;
        end else if (abort) begin
            state <= STATE_IDLE;
            after_emit_state <= STATE_IDLE;
            width_q <= 16'd0;
            height_q <= 16'd0;
            stride_q <= 2'd1;
            first_capture_x <= 16'd0;
            input_row_y <= 16'd0;
            input_x <= 16'd0;
            replay_x <= 16'd0;
            pending_x <= 16'd0;
            pending_bottom <= 64'd0;
            mid_bank <= 1'b0;
            top_left_q <= 64'd0;
            top_center_q <= 64'd0;
            top_right_q <= 64'd0;
            mid_left_q <= 64'd0;
            mid_center_q <= 64'd0;
            mid_right_q <= 64'd0;
            bot_left_q <= 64'd0;
            bot_center_q <= 64'd0;
            bot_right_q <= 64'd0;
            output_window_q <= '0;
            output_x_q <= 16'd0;
            output_y_q <= 16'd0;
            output_sof_q <= 1'b0;
            output_eol_q <= 1'b0;
            output_eof_q <= 1'b0;
            start_error <= 1'b0;
            start_error_code <= START_ERR_NONE;
            done <= 1'b0;
        end else begin
            start_error <= 1'b0;
            start_error_code <= START_ERR_NONE;
            done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (start_valid && start_ready) begin
                        if ((cfg_width == 0) || (cfg_height == 0)) begin
                            start_error <= 1'b1;
                            start_error_code <= START_ERR_ZERO_DIMENSION;
                        end else if (cfg_width > MAX_WIDTH) begin
                            start_error <= 1'b1;
                            start_error_code <= START_ERR_WIDTH_EXCEEDS_MAX;
                        end else if ((cfg_stride != 1) && (cfg_stride != 2)) begin
                            start_error <= 1'b1;
                            start_error_code <= START_ERR_STRIDE;
                        end else begin
                            width_q <= cfg_width;
                            height_q <= cfg_height;
                            stride_q <= cfg_stride;
                            first_capture_x <= 16'd0;
                            input_row_y <= 16'd0;
                            input_x <= 16'd0;
                            replay_x <= 16'd0;
                            mid_bank <= 1'b0;
                            state <= STATE_FIRST_CAPTURE;
                        end
                    end
                end

                STATE_FIRST_CAPTURE: begin
                    if (input_fire) begin
                        if (first_capture_x == width_q - 16'd1) begin
                            first_capture_x <= 16'd0;
                            top_left_q <= 64'd0;
                            top_center_q <= 64'd0;
                            top_right_q <= 64'd0;
                            mid_left_q <= 64'd0;
                            mid_center_q <= 64'd0;
                            mid_right_q <= 64'd0;
                            bot_left_q <= 64'd0;
                            bot_center_q <= 64'd0;
                            bot_right_q <= 64'd0;
                            if (height_q == 16'd1) begin
                                replay_x <= 16'd0;
                                state <= STATE_BOTTOM_ISSUE;
                            end else begin
                                input_row_y <= 16'd1;
                                input_x <= 16'd0;
                                state <= STATE_ROW_WAIT_INPUT;
                            end
                        end else begin
                            first_capture_x <= first_capture_x + 16'd1;
                        end
                    end
                end

                STATE_ROW_WAIT_INPUT: begin
                    if (input_fire) begin
                        pending_x <= input_x;
                        pending_bottom <= in_data_s8;
                        state <= STATE_ROW_READ;
                    end
                end

                STATE_ROW_READ: begin
                    top_left_q <= next_top_left;
                    top_center_q <= next_top_center;
                    top_right_q <= next_top_right;
                    mid_left_q <= next_mid_left;
                    mid_center_q <= next_mid_center;
                    mid_right_q <= next_mid_right;
                    bot_left_q <= next_bot_left;
                    bot_center_q <= next_bot_center;
                    bot_right_q <= next_bot_right;

                    if (pending_x == width_q - 16'd1)
                        after_emit_state <= STATE_ROW_RIGHT_FLUSH;
                    else begin
                        input_x <= pending_x + 16'd1;
                        after_emit_state <= STATE_ROW_WAIT_INPUT;
                    end

                    if (candidate_selected) begin
                        output_window_q <= pack_window(
                            next_top_left, next_top_center, next_top_right,
                            next_mid_left, next_mid_center, next_mid_right,
                            next_bot_left, next_bot_center, next_bot_right);
                        output_x_q <= candidate_center_x;
                        output_y_q <= active_center_y;
                        output_sof_q <= (candidate_center_x == 0) &&
                                        (active_center_y == 0);
                        output_eol_q <= candidate_center_x == last_center_x;
                        output_eof_q <= (candidate_center_x == last_center_x) &&
                                        (active_center_y == last_center_y);
                        state <= STATE_EMIT;
                    end else if (pending_x == width_q - 16'd1) begin
                        state <= STATE_ROW_RIGHT_FLUSH;
                    end else begin
                        state <= STATE_ROW_WAIT_INPUT;
                    end
                end

                STATE_ROW_RIGHT_FLUSH: begin
                    if (active_row_selected &&
                        ((stride_q == 1) || width_q[0])) begin
                        output_window_q <= pack_window(
                            top_center_q, top_right_q, top_right_q,
                            mid_center_q, mid_right_q, mid_right_q,
                            bot_center_q, bot_right_q, bot_right_q);
                        output_x_q <= width_q - 16'd1;
                        output_y_q <= active_center_y;
                        output_sof_q <= (width_q == 16'd1) &&
                                        (active_center_y == 0);
                        output_eol_q <= 1'b1;
                        output_eof_q <= active_center_y == last_center_y;
                        after_emit_state <= STATE_ROW_FINISH;
                        state <= STATE_EMIT;
                    end else begin
                        state <= STATE_ROW_FINISH;
                    end
                end

                STATE_ROW_FINISH: begin
                    if (input_row_y == height_q - 16'd1) begin
                        mid_bank <= ~mid_bank;
                        top_left_q <= 64'd0;
                        top_center_q <= 64'd0;
                        top_right_q <= 64'd0;
                        mid_left_q <= 64'd0;
                        mid_center_q <= 64'd0;
                        mid_right_q <= 64'd0;
                        bot_left_q <= 64'd0;
                        bot_center_q <= 64'd0;
                        bot_right_q <= 64'd0;
                        replay_x <= 16'd0;
                        if ((stride_q == 1) || height_q[0]) begin
                            state <= STATE_BOTTOM_ISSUE;
                        end else begin
                            // Normally the final selected row emitted EOF and
                            // retired directly from STATE_EMIT.  This is a
                            // defensive fallback for an impossible path.
                            state <= STATE_IDLE;
                        end
                    end else begin
                        mid_bank <= ~mid_bank;
                        input_row_y <= input_row_y + 16'd1;
                        input_x <= 16'd0;
                        top_left_q <= 64'd0;
                        top_center_q <= 64'd0;
                        top_right_q <= 64'd0;
                        mid_left_q <= 64'd0;
                        mid_center_q <= 64'd0;
                        mid_right_q <= 64'd0;
                        bot_left_q <= 64'd0;
                        bot_center_q <= 64'd0;
                        bot_right_q <= 64'd0;
                        state <= STATE_ROW_WAIT_INPUT;
                    end
                end

                STATE_BOTTOM_ISSUE: begin
                    pending_x <= replay_x;
                    state <= STATE_BOTTOM_READ;
                end

                STATE_BOTTOM_READ: begin
                    top_left_q <= next_top_left;
                    top_center_q <= next_top_center;
                    top_right_q <= next_top_right;
                    mid_left_q <= next_mid_left;
                    mid_center_q <= next_mid_center;
                    mid_right_q <= next_mid_right;
                    bot_left_q <= next_bot_left;
                    bot_center_q <= next_bot_center;
                    bot_right_q <= next_bot_right;

                    if (pending_x == width_q - 16'd1)
                        after_emit_state <= STATE_BOTTOM_RIGHT_FLUSH;
                    else begin
                        replay_x <= pending_x + 16'd1;
                        after_emit_state <= STATE_BOTTOM_ISSUE;
                    end

                    if (candidate_selected) begin
                        output_window_q <= pack_window(
                            next_top_left, next_top_center, next_top_right,
                            next_mid_left, next_mid_center, next_mid_right,
                            next_bot_left, next_bot_center, next_bot_right);
                        output_x_q <= candidate_center_x;
                        output_y_q <= active_center_y;
                        output_sof_q <= (candidate_center_x == 0) &&
                                        (active_center_y == 0);
                        output_eol_q <= candidate_center_x == last_center_x;
                        output_eof_q <= (candidate_center_x == last_center_x) &&
                                        (active_center_y == last_center_y);
                        state <= STATE_EMIT;
                    end else if (pending_x == width_q - 16'd1) begin
                        state <= STATE_BOTTOM_RIGHT_FLUSH;
                    end else begin
                        state <= STATE_BOTTOM_ISSUE;
                    end
                end

                STATE_BOTTOM_RIGHT_FLUSH: begin
                    if ((stride_q == 1) || width_q[0]) begin
                        output_window_q <= pack_window(
                            top_center_q, top_right_q, top_right_q,
                            mid_center_q, mid_right_q, mid_right_q,
                            bot_center_q, bot_right_q, bot_right_q);
                        output_x_q <= width_q - 16'd1;
                        output_y_q <= height_q - 16'd1;
                        output_sof_q <= (width_q == 16'd1) &&
                                        (height_q == 16'd1);
                        output_eol_q <= 1'b1;
                        output_eof_q <= 1'b1;
                        after_emit_state <= STATE_IDLE;
                        state <= STATE_EMIT;
                    end else begin
                        // For stride 2/even width, centre W-2 was the final
                        // selected output and retired through its EOF handshake.
                        state <= STATE_IDLE;
                    end
                end

                STATE_EMIT: begin
                    if (output_fire) begin
                        if (output_eof_q) begin
                            state <= STATE_IDLE;
                            done <= 1'b1;
                        end else begin
                            state <= after_emit_state;
                        end
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    start_error <= 1'b1;
                    start_error_code <= START_ERR_STRIDE;
                end
            endcase
        end
    end

    c1_ram_sdp_read_first #(
        .DATA_WIDTH(64), .DEPTH(MAX_WIDTH), .ADDR_WIDTH(RAM_ADDR_WIDTH)
    ) u_line_ram0 (
        .clk,
        .rd_en(ram0_rd_en), .rd_addr(ram0_rd_addr), .rd_data(ram0_rd_data),
        .wr_en(ram0_wr_en), .wr_addr(ram0_wr_addr), .wr_data(ram0_wr_data)
    );

    c1_ram_sdp_read_first #(
        .DATA_WIDTH(64), .DEPTH(MAX_WIDTH), .ADDR_WIDTH(RAM_ADDR_WIDTH)
    ) u_line_ram1 (
        .clk,
        .rd_en(ram1_rd_en), .rd_addr(ram1_rd_addr), .rd_data(ram1_rd_data),
        .wr_en(ram1_wr_en), .wr_addr(ram1_wr_addr), .wr_data(ram1_wr_data)
    );

`ifndef SYNTHESIS
    initial begin
        if ((MAX_WIDTH < 1) || (MAX_WIDTH > 65535))
            $fatal(1, "c1_s8_window3x3_same_c8 MAX_WIDTH must be 1..65535");
        if ((1 << RAM_ADDR_WIDTH) < MAX_WIDTH)
            $fatal(1, "c1_s8_window3x3_same_c8 RAM_ADDR_WIDTH too small");
    end

    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (done && busy)
                $fatal(1, "c1_s8_window3x3_same_c8 done while busy");
            if (out_eof && !(out_valid && out_eol &&
                (out_center_x == last_center_x) &&
                (out_center_y == last_center_y)))
                $fatal(1, "c1_s8_window3x3_same_c8 EOF coordinate mismatch");
        end
    end
`endif

endmodule
