`timescale 1ns/1ps

// Board-independent, frame-locked RGB888 source selector for R1 compute.
//
// source_select is snapshotted only by start_valid/start_ready:
//   0 -> ISP RGB stream
//   1 -> XRGB frame-DMA RGB stream
// The unselected source always sees ready=0 and cannot influence output.
//
// A one-beat elastic output register both preserves ready/valid stall behavior
// and prevents a malformed input beat from reaching Resize/compute.  The first
// accepted beat must be SOF at (0,0).  Coordinates then advance in raster
// order.  The first EOL establishes line width; every later line must use the
// same EOL x coordinate.  SOF is forbidden after the first beat and EOF must
// coincide with EOL.  A violation consumes/discards the bad source beat,
// clears pending output, and freezes busy/error until abort.
module c1_r1_rgb_source_mux (
    input  logic          clk,
    input  logic          rst,
    input  logic          abort,

    input  logic          start_valid,
    output logic          start_ready,
    input  logic          source_select,
    output logic          busy,
    output logic          done,
    output logic          error,
    output logic [2:0]    error_code,
    output logic [15:0]   error_x,
    output logic [15:0]   error_y,

    input  logic          isp_valid,
    output logic          isp_ready,
    input  logic [23:0]   isp_rgb888,
    input  logic [15:0]   isp_x,
    input  logic [15:0]   isp_y,
    input  logic          isp_sof,
    input  logic          isp_eol,
    input  logic          isp_eof,

    input  logic          dma_valid,
    output logic          dma_ready,
    input  logic [23:0]   dma_rgb888,
    input  logic [15:0]   dma_x,
    input  logic [15:0]   dma_y,
    input  logic          dma_sof,
    input  logic          dma_eol,
    input  logic          dma_eof,

    output logic          out_valid,
    input  logic          out_ready,
    output logic [23:0]   out_rgb888,
    output logic [15:0]   out_x,
    output logic [15:0]   out_y,
    output logic          out_sof,
    output logic          out_eol,
    output logic          out_eof
);

    localparam logic [2:0] ERROR_NONE       = 3'd0;
    localparam logic [2:0] ERROR_FIRST_BEAT = 3'd1;
    localparam logic [2:0] ERROR_COORDINATE = 3'd2;
    localparam logic [2:0] ERROR_SOF        = 3'd3;
    localparam logic [2:0] ERROR_EOL        = 3'd4;
    localparam logic [2:0] ERROR_EOF        = 3'd5;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_RUN,
        STATE_ERROR
    } state_t;

    state_t state;
    logic source_select_q;
    logic first_beat;
    logic input_complete;
    logic previous_eol;
    logic [15:0] previous_x;
    logic [15:0] previous_y;
    logic line_width_known;
    logic [15:0] line_last_x;

    logic selected_valid;
    logic [23:0] selected_rgb888;
    logic [15:0] selected_x;
    logic [15:0] selected_y;
    logic selected_sof;
    logic selected_eol;
    logic selected_eof;
    logic selected_ready;
    logic out_valid_q;
    logic output_slot_ready;
    logic input_fire;
    logic output_fire;
    logic protocol_valid;
    logic [2:0] protocol_error_code;
    logic coordinate_valid;
    logic eol_valid;

    always_comb begin
        if (source_select_q) begin
            selected_valid = dma_valid;
            selected_rgb888 = dma_rgb888;
            selected_x = dma_x;
            selected_y = dma_y;
            selected_sof = dma_sof;
            selected_eol = dma_eol;
            selected_eof = dma_eof;
        end else begin
            selected_valid = isp_valid;
            selected_rgb888 = isp_rgb888;
            selected_x = isp_x;
            selected_y = isp_y;
            selected_sof = isp_sof;
            selected_eol = isp_eol;
            selected_eof = isp_eof;
        end

        // abort is an immediate transaction fence.  The registered pending
        // beat is retained only until the aborting edge clears it, but is
        // never exposed as a valid transfer while abort is asserted.
        out_valid = out_valid_q && !abort;
        output_slot_ready = !out_valid_q || out_ready;
        selected_ready = (state == STATE_RUN) && !abort &&
                         !input_complete && output_slot_ready;
        isp_ready = selected_ready && !source_select_q;
        dma_ready = selected_ready && source_select_q;
        input_fire = selected_valid && selected_ready;
        output_fire = out_valid && out_ready;

        start_ready = !rst && !abort && (state == STATE_IDLE) && !out_valid_q;
        busy = (state != STATE_IDLE);
        error = (state == STATE_ERROR);

        coordinate_valid = 1'b1;
        eol_valid = 1'b1;
        protocol_valid = 1'b1;
        protocol_error_code = ERROR_NONE;

        if (first_beat) begin
            if (!selected_sof || (selected_x != 0) || (selected_y != 0)) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_FIRST_BEAT;
            end else if (selected_eof && !selected_eol) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_EOF;
            end
        end else begin
            if (previous_eol) begin
                coordinate_valid = (previous_y != 16'hffff) &&
                                   (selected_x == 0) &&
                                   (selected_y == previous_y + 16'd1);
            end else begin
                coordinate_valid = (previous_x != 16'hffff) &&
                                   (selected_x == previous_x + 16'd1) &&
                                   (selected_y == previous_y);
            end

            if (line_width_known) begin
                eol_valid = (selected_x <= line_last_x) &&
                            (selected_eol == (selected_x == line_last_x));
            end

            if (!coordinate_valid) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_COORDINATE;
            end else if (selected_sof) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_SOF;
            end else if (!eol_valid) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_EOL;
            end else if (selected_eof && !selected_eol) begin
                protocol_valid = 1'b0;
                protocol_error_code = ERROR_EOF;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            source_select_q <= 1'b0;
            first_beat <= 1'b1;
            input_complete <= 1'b0;
            previous_eol <= 1'b0;
            previous_x <= 16'd0;
            previous_y <= 16'd0;
            line_width_known <= 1'b0;
            line_last_x <= 16'd0;
            out_valid_q <= 1'b0;
            out_rgb888 <= 24'd0;
            out_x <= 16'd0;
            out_y <= 16'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            done <= 1'b0;
            error_code <= ERROR_NONE;
            error_x <= 16'd0;
            error_y <= 16'd0;
        end else if (abort) begin
            state <= STATE_IDLE;
            source_select_q <= 1'b0;
            first_beat <= 1'b1;
            input_complete <= 1'b0;
            previous_eol <= 1'b0;
            previous_x <= 16'd0;
            previous_y <= 16'd0;
            line_width_known <= 1'b0;
            line_last_x <= 16'd0;
            out_valid_q <= 1'b0;
            out_rgb888 <= 24'd0;
            out_x <= 16'd0;
            out_y <= 16'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            done <= 1'b0;
            error_code <= ERROR_NONE;
            error_x <= 16'd0;
            error_y <= 16'd0;
        end else begin
            done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    out_valid_q <= 1'b0;
                    if (start_valid && start_ready) begin
                        state <= STATE_RUN;
                        source_select_q <= source_select;
                        first_beat <= 1'b1;
                        input_complete <= 1'b0;
                        previous_eol <= 1'b0;
                        previous_x <= 16'd0;
                        previous_y <= 16'd0;
                        line_width_known <= 1'b0;
                        line_last_x <= 16'd0;
                        error_code <= ERROR_NONE;
                        error_x <= 16'd0;
                        error_y <= 16'd0;
                    end
                end

                STATE_RUN: begin
                    if (output_fire && out_eof) begin
                        state <= STATE_IDLE;
                        out_valid_q <= 1'b0;
                        input_complete <= 1'b0;
                        done <= 1'b1;
                    end else if (input_fire) begin
                        if (!protocol_valid) begin
                            state <= STATE_ERROR;
                            out_valid_q <= 1'b0;
                            input_complete <= 1'b0;
                            error_code <= protocol_error_code;
                            error_x <= selected_x;
                            error_y <= selected_y;
                        end else begin
                            out_valid_q <= 1'b1;
                            out_rgb888 <= selected_rgb888;
                            out_x <= selected_x;
                            out_y <= selected_y;
                            out_sof <= selected_sof;
                            out_eol <= selected_eol;
                            out_eof <= selected_eof;

                            first_beat <= 1'b0;
                            previous_x <= selected_x;
                            previous_y <= selected_y;
                            previous_eol <= selected_eol;
                            if (!line_width_known && selected_eol) begin
                                line_width_known <= 1'b1;
                                line_last_x <= selected_x;
                            end
                            if (selected_eof)
                                input_complete <= 1'b1;
                        end
                    end else if (output_fire) begin
                        out_valid_q <= 1'b0;
                    end
                end

                STATE_ERROR: begin
                    // Frozen until abort.  Neither source receives ready and
                    // no malformed or pending beat can reach compute.
                    out_valid_q <= 1'b0;
                end

                default: begin
                    state <= STATE_IDLE;
                    out_valid_q <= 1'b0;
                end
            endcase
        end
    end

endmodule
