// Board-independent AXI4 XRGB8888 frame reader to an RGB24 raster stream.
//
// Configuration contract:
//   * start is sampled only while busy=0.  base/width/height/stride are
//     latched on that edge and ignored until the frame completes.
//   * width and height must be non-zero; width must be divisible by four;
//     base and stride must be 16-byte aligned; stride must be at least
//     width*4 bytes; the last active byte must fit in the 32-bit address map.
//   * Configuration legality is evaluated by a registered four-cycle
//     preflight.  This keeps (height-1)*stride and the 64-bit end-address
//     comparison out of the launch critical path.  An illegal start therefore
//     completes a few clocks after acceptance with sticky error=1 and issues
//     no AXI request.
//
// AXI contract:
//   * 128-bit, INCR bursts of at most 16 beats, one outstanding burst.
//   * A burst never crosses a 4 KiB boundary or an active row boundary.
//   * Every 32-bit little-endian pixel word is 0x00RRGGBB.  Lane zero is
//     RDATA[31:0], so the output stream is RGB24 {R,G,B}.
//   * Non-OKAY RRESP and an unexpected RLAST position set sticky error.
//     A bad RRESP suppresses further pixels and drains the accepted burst.
//     Early RLAST terminates that burst immediately; missing RLAST terminates
//     at the ARLEN-derived final beat.  All three cases complete with
//     done+error rather than waiting for a beat that cannot legally arrive.
//
// Cancellation contract:
//   * cancel is synchronous and has priority over a simultaneous idle start.
//   * Before ARVALID is presented, cancel completes immediately with done and
//     no new error.  Once ARVALID is presented it is never withdrawn: the AR
//     handshake completes, every expected R beat is drained, no more RGB
//     pixels are emitted, and only then do done/idle assert.  A buffered beat
//     is discarded on cancel; any remaining beats of its burst are drained.
//
// This baseline holds one 128-bit beat and serializes its four pixels.  While
// downstream is stalled, RGB/coordinates/markers remain stable and RREADY is
// deasserted.  The design is correctness-first and does not promise a
// continuous one-pixel-per-clock output.  done pulses only after the final
// pixel is accepted by m_ready, never merely because its AXI beat arrived.

`timescale 1ns/1ps

module c1_axi_xrgb_frame_reader (
    input  logic          clk,
    input  logic          rst,

    input  logic          start,
    input  logic          cancel,
    input  logic [31:0]   cfg_base_addr,
    input  logic [15:0]   cfg_width_pixels,
    input  logic [15:0]   cfg_height_lines,
    input  logic [31:0]   cfg_stride_bytes,
    output logic          busy,
    output logic          done,
    output logic          error,

    output logic          m_valid,
    input  logic          m_ready,
    output logic [23:0]   m_rgb,
    output logic          m_sof,
    output logic          m_eol,
    output logic          m_eof,
    output logic [15:0]   m_x,
    output logic [15:0]   m_y,

    output logic [31:0]   m_axi_araddr,
    output logic [7:0]    m_axi_arlen,
    output logic [2:0]    m_axi_arsize,
    output logic [1:0]    m_axi_arburst,
    output logic          m_axi_arvalid,
    input  logic          m_axi_arready,

    input  logic [127:0]  m_axi_rdata,
    input  logic [1:0]    m_axi_rresp,
    input  logic          m_axi_rlast,
    input  logic          m_axi_rvalid,
    output logic          m_axi_rready,
    // Optional pre-AR admission gate.  The reader may wait in ST_PREPARE
    // while this is low, but once it enters ST_AR m_axi_arvalid remains
    // asserted until the AXI handshake, preserving the VALID stability rule.
    // It is last in the port list so legacy positional users retain ordering.
    input  logic          m_axi_ar_allow
);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_VALIDATE_BASIC,
        ST_VALIDATE_MUL,
        ST_VALIDATE_END,
        ST_VALIDATE_CHECK,
        ST_PREPARE,
        ST_AR,
        ST_R,
        ST_EMIT
    } state_t;

    state_t state;

    logic [31:0] base_reg;
    logic [15:0] width_reg;
    logic [15:0] height_reg;
    logic [31:0] stride_reg;
    logic [31:0] row_base_addr;
    logic [31:0] current_addr;
    logic [15:0] current_row;
    logic [15:0] row_beats_remaining;
    logic [4:0]  burst_beats_target;
    logic [4:0]  burst_beat_index;
    logic [127:0] beat_buffer;
    logic [1:0]  pixel_lane;
    logic [15:0] output_x;
    logic [15:0] output_y;

    logic [31:0] lane_word;
    logic [31:0] burst_byte_count;
    logic [31:0] line_bytes_reg;
    logic [15:0] height_minus_one_reg;
    logic [47:0] last_row_offset_reg;
    logic [63:0] end_exclusive_reg;
    logic        basic_config_legal_reg;
    logic        output_fire;
    logic        final_output_pixel;
    logic        expected_rlast;
    logic        drop_mode;

    function automatic [4:0] choose_burst_beats(
        input logic [31:0] address,
        input logic [15:0] row_beats
    );
        integer beats_to_4k;
        integer selected;
        begin
            beats_to_4k = (4096 - address[11:0]) >> 4;
            selected = 16;
            if (row_beats < selected)
                selected = row_beats;
            if (beats_to_4k < selected)
                selected = beats_to_4k;
            choose_burst_beats = selected[4:0];
        end
    endfunction

    always_comb begin
        burst_byte_count = '0;
        burst_byte_count[4:0] = burst_beats_target;
        burst_byte_count = burst_byte_count << 4;

        m_axi_araddr = current_addr;
        m_axi_arlen = (burst_beats_target == 0) ? 8'd0 :
                      {3'd0, burst_beats_target} - 1'b1;
        m_axi_arsize = 3'd4;
        m_axi_arburst = 2'b01;
        m_axi_arvalid = (state == ST_AR);
        m_axi_rready = (state == ST_R);

        case (pixel_lane)
            2'd0: lane_word = beat_buffer[31:0];
            2'd1: lane_word = beat_buffer[63:32];
            2'd2: lane_word = beat_buffer[95:64];
            default: lane_word = beat_buffer[127:96];
        endcase

        // A synchronous cancel may discard an unaccepted stream beat.  AXI
        // ARVALID, unlike this cancellable local stream, is never withdrawn.
        m_valid = (state == ST_EMIT) && !cancel && !drop_mode;
        m_rgb = lane_word[23:0];
        m_x = output_x;
        m_y = output_y;
        m_sof = m_valid && (output_x == 0) && (output_y == 0);
        m_eol = m_valid && (output_x == width_reg-1'b1);
        m_eof = m_valid && (output_x == width_reg-1'b1) &&
                (output_y == height_reg-1'b1);
        output_fire = m_valid && m_ready;
        final_output_pixel = (output_x == width_reg-1'b1) &&
                             (output_y == height_reg-1'b1);
        expected_rlast = (burst_beat_index == burst_beats_target-1'b1);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            base_reg <= '0;
            width_reg <= '0;
            height_reg <= '0;
            stride_reg <= '0;
            line_bytes_reg <= '0;
            height_minus_one_reg <= '0;
            last_row_offset_reg <= '0;
            end_exclusive_reg <= '0;
            basic_config_legal_reg <= 1'b0;
            row_base_addr <= '0;
            current_addr <= '0;
            current_row <= '0;
            row_beats_remaining <= '0;
            burst_beats_target <= '0;
            burst_beat_index <= '0;
            beat_buffer <= '0;
            pixel_lane <= '0;
            output_x <= '0;
            output_y <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            drop_mode <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start && !cancel) begin
                        error <= 1'b0;
                        drop_mode <= 1'b0;
                        base_reg <= cfg_base_addr;
                        width_reg <= cfg_width_pixels;
                        height_reg <= cfg_height_lines;
                        stride_reg <= cfg_stride_bytes;
                        busy <= 1'b1;
                        state <= ST_VALIDATE_BASIC;
                    end
                end

                ST_VALIDATE_BASIC: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        line_bytes_reg <= {16'd0, width_reg} << 2;
                        height_minus_one_reg <= (height_reg == 0) ? 16'd0 :
                                                height_reg - 1'b1;
                        basic_config_legal_reg <=
                            (width_reg != 0) &&
                            (height_reg != 0) &&
                            (width_reg[1:0] == 2'b00) &&
                            (base_reg[3:0] == 4'b0000) &&
                            (stride_reg[3:0] == 4'b0000) &&
                            (stride_reg >= ({16'd0, width_reg} << 2));
                        state <= ST_VALIDATE_MUL;
                    end
                end

                ST_VALIDATE_MUL: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        // 16x32 -> 48-bit registered product.  Keeping this
                        // multiply on its own clock boundary removes it from
                        // every AR/stream state-enable cone.
                        last_row_offset_reg <= height_minus_one_reg * stride_reg;
                        state <= ST_VALIDATE_END;
                    end
                end

                ST_VALIDATE_END: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        end_exclusive_reg <= {32'd0, base_reg} +
                                             {16'd0, last_row_offset_reg} +
                                             {32'd0, line_bytes_reg};
                        state <= ST_VALIDATE_CHECK;
                    end
                end

                ST_VALIDATE_CHECK: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (!basic_config_legal_reg ||
                                 (end_exclusive_reg >
                                  64'h0000_0001_0000_0000)) begin
                        error <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        row_base_addr <= base_reg;
                        current_addr <= base_reg;
                        current_row <= '0;
                        row_beats_remaining <= width_reg >> 2;
                        burst_beats_target <= '0;
                        burst_beat_index <= '0;
                        beat_buffer <= '0;
                        pixel_lane <= '0;
                        output_x <= '0;
                        output_y <= '0;
                        state <= ST_PREPARE;
                    end
                end

                ST_PREPARE: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (m_axi_ar_allow !== 1'b0) begin
                        burst_beats_target <= choose_burst_beats(
                            current_addr, row_beats_remaining);
                        burst_beat_index <= '0;
                        state <= ST_AR;
                    end
                end

                ST_AR: begin
                    if (cancel)
                        drop_mode <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready)
                        state <= ST_R;
                end

                ST_R: begin
                    if (cancel)
                        drop_mode <= 1'b1;
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (m_axi_rresp !== 2'b00) begin
                            error <= 1'b1;
                            drop_mode <= 1'b1;
                        end
                        if (m_axi_rlast !== expected_rlast)
                            error <= 1'b1;

                        // Early RLAST is the physical end of the malformed
                        // burst.  At the expected final count, missing RLAST
                        // is also terminal: waiting for a nonexistent extra
                        // beat would deadlock the engine.
                        if ((m_axi_rlast && !expected_rlast) ||
                            (expected_rlast &&
                             (drop_mode || cancel ||
                              (m_axi_rresp !== 2'b00) || !m_axi_rlast))) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else if (expected_rlast) begin
                            beat_buffer <= m_axi_rdata;
                            pixel_lane <= 2'd0;
                            state <= ST_EMIT;
                        end else if (drop_mode || cancel ||
                                     (m_axi_rresp !== 2'b00)) begin
                            burst_beat_index <= burst_beat_index + 1'b1;
                            state <= ST_R;
                        end else begin
                            beat_buffer <= m_axi_rdata;
                            pixel_lane <= 2'd0;
                            state <= ST_EMIT;
                        end
                    end
                end

                ST_EMIT: begin
                    if (cancel) begin
                        drop_mode <= 1'b1;
                        if (burst_beat_index + 1'b1 < burst_beats_target) begin
                            burst_beat_index <= burst_beat_index + 1'b1;
                            state <= ST_R;
                        end else begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end else if (output_fire) begin
                        if (final_output_pixel) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            if (output_x == width_reg-1'b1) begin
                                output_x <= '0;
                                output_y <= output_y + 1'b1;
                            end else begin
                                output_x <= output_x + 1'b1;
                            end

                            if (pixel_lane != 2'd3) begin
                                pixel_lane <= pixel_lane + 1'b1;
                            end else if (burst_beat_index + 1'b1 <
                                         burst_beats_target) begin
                                burst_beat_index <= burst_beat_index + 1'b1;
                                state <= ST_R;
                            end else if (row_beats_remaining ==
                                         burst_beats_target) begin
                                current_row <= current_row + 1'b1;
                                row_base_addr <= row_base_addr + stride_reg;
                                current_addr <= row_base_addr + stride_reg;
                                row_beats_remaining <= width_reg >> 2;
                                state <= ST_PREPARE;
                            end else begin
                                current_addr <= current_addr + burst_byte_count;
                                row_beats_remaining <=
                                    row_beats_remaining - burst_beats_target;
                                state <= ST_PREPARE;
                            end
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ($bits(m_axi_rdata) != 128)
            $fatal(1, "c1_axi_xrgb_frame_reader requires a 128-bit AXI data bus");
    end
`endif

endmodule
