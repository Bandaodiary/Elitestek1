// Board-independent RGB24 raster to AXI4 XRGB8888 frame writer.
//
// Input contract:
//   * start is sampled only while busy=0.  base/width/height/stride are
//     latched on that edge and ignored until the frame completes.
//   * Accepted pixels (s_valid && s_ready) are raster ordered with no gaps in
//     the logical coordinates.  SOF is asserted only on pixel (0,0), EOL only
//     on the final pixel of every row, and EOF only on the final frame pixel.
//     Marker mismatches set the sticky error flag but do not abort the write.
//   * The source must hold data and markers while s_valid && !s_ready.
//   * width must be non-zero and divisible by four; height must be non-zero;
//     base and stride must be 16-byte aligned; stride must be at least
//     width*4 bytes.  Address arithmetic must not overflow 32 bits.
//   * The complete strided frame extent must lie in the static byte interval
//     [DEST_REGION_BEGIN, DEST_REGION_END). END may equal 2^32. An empty,
//     reversed or out-of-address-space region fails preflight without traffic.
//   * A registered four-cycle preflight evaluates those conditions.  An
//     illegal start therefore completes a few clocks after acceptance with
//     done+error, without accepting stream data or issuing AXI traffic.
//
// Four RGB24 pixels are packed into one 128-bit AXI beat.  Each 32-bit pixel
// lane contains 0x00RRGGBB, with lane zero at WDATA[31:0].  Consequently a
// little-endian byte-addressed memory receives BB, GG, RR, 00 for each pixel.
// All beats are complete (WSTRB=16'hffff).
//
// This baseline buffers one burst (at most 16 beats), then sends one AXI
// transaction and waits for its B response before accepting the next burst.
// It therefore provides safe input back-pressure rather than continuous
// throughput.  AW and W handshakes are independent and each payload is held
// stable until accepted.  done pulses only after the final B handshake.
//
// Cancellation contract:
//   * cancel is synchronous and has priority over a simultaneous idle start.
//   * Before AWVALID is presented, cancel discards any partially or completely
//     captured but uncommitted burst and completes immediately with done.
//   * Once AWVALID is presented it is never withdrawn.  A cancelled committed
//     burst sends every buffered W beat, waits for B, then completes without
//     accepting another pixel or starting another burst.  cancel itself never
//     sets error; marker errors already seen and a non-OKAY BRESP remain sticky.

`timescale 1ns/1ps

module c1_axi_xrgb_frame_writer #(
    // Static allowed byte interval [BEGIN, END). Full address space by default.
    // This is an allocation boundary, not a dynamic ownership grant.
    parameter logic [32:0] DEST_REGION_BEGIN = 33'd0,
    parameter logic [32:0] DEST_REGION_END = 33'h1_0000_0000
) (
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

    input  logic          s_valid,
    output logic          s_ready,
    input  logic [23:0]   s_rgb,
    input  logic          s_sof,
    input  logic          s_eol,
    input  logic          s_eof,

    output logic [31:0]   m_axi_awaddr,
    output logic [7:0]    m_axi_awlen,
    output logic [2:0]    m_axi_awsize,
    output logic [1:0]    m_axi_awburst,
    output logic          m_axi_awvalid,
    input  logic          m_axi_awready,

    output logic [127:0]  m_axi_wdata,
    output logic [15:0]   m_axi_wstrb,
    output logic          m_axi_wlast,
    output logic          m_axi_wvalid,
    input  logic          m_axi_wready,

    input  logic [1:0]    m_axi_bresp,
    input  logic          m_axi_bvalid,
    output logic          m_axi_bready
);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_VALIDATE_BASIC,
        ST_VALIDATE_MUL,
        ST_VALIDATE_END,
        ST_VALIDATE_CHECK,
        ST_PREPARE,
        ST_CAPTURE,
        ST_AW,
        ST_B
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

    logic [15:0] input_x;
    logic [15:0] input_y;
    logic [1:0] pixel_in_beat;
    logic [4:0] capture_beat_index;
    logic [4:0] send_beat_index;
    logic [4:0] burst_beats_target;
    logic [127:0] pack_reg;
    logic [127:0] burst_memory [0:15];

    logic [31:0] line_bytes_reg;
    logic [15:0] height_minus_one_reg;
    logic [47:0] last_row_offset_reg;
    logic [63:0] end_exclusive_reg;
    logic        basic_config_legal_reg;
    logic [31:0] burst_byte_count;
    logic [31:0] pixel_word;
    logic s_fire;
    logic cancel_pending;
    logic aw_done;
    logic w_done;

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
        pixel_word = {8'h00, s_rgb};
        s_ready = busy && (state == ST_CAPTURE) && !cancel;
        s_fire = s_valid && s_ready;

        m_axi_awaddr = current_addr;
        m_axi_awlen = (burst_beats_target == 0) ? 8'd0 :
                      {3'd0, burst_beats_target} - 1'b1;
        m_axi_awsize = 3'd4;
        m_axi_awburst = 2'b01;
        m_axi_awvalid = (state == ST_AW) && !aw_done;

        m_axi_wdata = '0;
        if (state == ST_AW)
            m_axi_wdata = burst_memory[send_beat_index[3:0]];
        m_axi_wstrb = 16'hffff;
        m_axi_wlast = (state == ST_AW) &&
                      (send_beat_index == burst_beats_target-1'b1);
        m_axi_wvalid = (state == ST_AW) && !w_done;

        m_axi_bready = (state == ST_B);
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
            input_x <= '0;
            input_y <= '0;
            pixel_in_beat <= '0;
            capture_beat_index <= '0;
            send_beat_index <= '0;
            burst_beats_target <= '0;
            pack_reg <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cancel_pending <= 1'b0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start && !cancel) begin
                        error <= 1'b0;
                        cancel_pending <= 1'b0;
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
                                  64'h0000_0001_0000_0000) ||
                                 (DEST_REGION_BEGIN >= DEST_REGION_END) ||
                                 (DEST_REGION_END > 33'h1_0000_0000) ||
                                 ({1'b0,base_reg} < DEST_REGION_BEGIN) ||
                                 (end_exclusive_reg > {31'd0,DEST_REGION_END})) begin
                        error <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        row_base_addr <= base_reg;
                        current_addr <= base_reg;
                        current_row <= '0;
                        row_beats_remaining <= width_reg >> 2;
                        input_x <= '0;
                        input_y <= '0;
                        pixel_in_beat <= '0;
                        capture_beat_index <= '0;
                        send_beat_index <= '0;
                        burst_beats_target <= '0;
                        pack_reg <= '0;
                        state <= ST_PREPARE;
                    end
                end

                ST_PREPARE: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        burst_beats_target <= choose_burst_beats(
                            current_addr, row_beats_remaining);
                        capture_beat_index <= '0;
                        pixel_in_beat <= '0;
                        pack_reg <= '0;
                        state <= ST_CAPTURE;
                    end
                end

                ST_CAPTURE: begin
                    if (cancel) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else if (s_fire) begin
                        if (s_sof !== ((input_x == 0) && (input_y == 0)))
                            error <= 1'b1;
                        if (s_eol !== (input_x == width_reg-1'b1))
                            error <= 1'b1;
                        if (s_eof !== ((input_x == width_reg-1'b1) &&
                                      (input_y == height_reg-1'b1)))
                            error <= 1'b1;

                        if (input_x == width_reg-1'b1) begin
                            input_x <= '0;
                            if (input_y != height_reg-1'b1)
                                input_y <= input_y + 1'b1;
                        end else begin
                            input_x <= input_x + 1'b1;
                        end

                        case (pixel_in_beat)
                            2'd0: pack_reg[31:0] <= pixel_word;
                            2'd1: pack_reg[63:32] <= pixel_word;
                            2'd2: pack_reg[95:64] <= pixel_word;
                            default: begin
                                burst_memory[capture_beat_index[3:0]] <=
                                    {pixel_word, pack_reg[95:0]};
                                pack_reg <= '0;
                            end
                        endcase

                        if (pixel_in_beat == 2'd3) begin
                            pixel_in_beat <= '0;
                            if (capture_beat_index + 1'b1 == burst_beats_target) begin
                                send_beat_index <= '0;
                                aw_done <= 1'b0;
                                w_done <= 1'b0;
                                state <= ST_AW;
                            end else begin
                                capture_beat_index <= capture_beat_index + 1'b1;
                            end
                        end else begin
                            pixel_in_beat <= pixel_in_beat + 1'b1;
                        end
                    end
                end

                ST_AW: begin
                    if (cancel)
                        cancel_pending <= 1'b1;
                    // A complete burst is buffered before either VALID is
                    // exposed. AW and W may finish in either order; never
                    // wait for AWREADY to present WVALID, even after cancel.
                    if (!aw_done && m_axi_awready)
                        aw_done <= 1'b1;
                    if (!w_done && m_axi_wready) begin
                        if (send_beat_index == burst_beats_target-1'b1)
                            w_done <= 1'b1;
                        else
                            send_beat_index <= send_beat_index + 1'b1;
                    end
                    if ((aw_done || m_axi_awready) &&
                        (w_done || (m_axi_wready &&
                         (send_beat_index == burst_beats_target-1'b1))))
                        state <= ST_B;
                end

                ST_B: begin
                    if (cancel)
                        cancel_pending <= 1'b1;
                    // ST_B implies BREADY=1.
                    if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00)
                            error <= 1'b1;

                        if (cancel_pending || cancel) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else if (row_beats_remaining == burst_beats_target) begin
                            if (current_row == height_reg-1'b1) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                current_row <= current_row + 1'b1;
                                row_base_addr <= row_base_addr + stride_reg;
                                current_addr <= row_base_addr + stride_reg;
                                row_beats_remaining <= width_reg >> 2;
                                state <= ST_PREPARE;
                            end
                        end else begin
                            current_addr <= current_addr + burst_byte_count;
                            row_beats_remaining <=
                                row_beats_remaining - burst_beats_target;
                            state <= ST_PREPARE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ($bits(m_axi_wdata) != 128)
            $fatal(1, "c1_axi_xrgb_frame_writer requires a 128-bit AXI data bus");
    end
`endif

endmodule
