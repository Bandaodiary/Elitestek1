`timescale 1ns/1ps

// Resolve one input/output framebuffer pair from two software tables.
//
// A start handshake atomically snapshots both 64-bit table bases, the fixed
// table indices (input 0..2, output 0..1), and the expected active dimensions.
// One c1_axi_frame_buffer_table_reader is reused sequentially for the input and
// output entries, so only one AXI read can be outstanding.
//
// Successful entries must have a 32-bit, 16-byte-aligned framebuffer base,
// dimensions equal to the expected dimensions, a 16-byte-aligned stride no
// smaller than width*4, and a final active byte inside the 32-bit address map.
// Input/output active pixels must not overlap.  The overlap check merges the
// two monotonically ordered row-interval lists, so it is exact for strided
// images and completes in at most input_height+output_height-1 cycles; padding
// bytes are not incorrectly treated as active pixels.  Frame extents are
// checked by a 16-cycle bit-serial shift/add engine.  This replaces the former
// wide combinational (height-1)*stride multiplier with one 48-bit adder and
// does not require DSP inference.  Forty-eight bits cover the exact maximum
// of a 16-bit (height-1) times a 32-bit stride plus base and line bytes.
//
// Error codes:
//   01 input index, 02 output index, 03 zero expected dimensions
//   10 input table read, 11 output table read
//   20/21 input/output framebuffer base range, 22/23 base alignment
//   24/25 input/output dimension mismatch
//   26/27 input/output stride invalid
//   28/29 input/output 32-bit extent overflow
//   30 active pixel regions overlap
//
// Abort is forwarded to the table reader.  The resolver returns immediately to
// its idle control state, but start_ready remains low until a committed table
// read has drained and the shared reader itself is idle.  No aborted operation
// can produce a response.
//
// SEPARATE_INPUT_GEOMETRY=0 preserves the original shared-dimension command.
// When enabled, the appended expected_input_* ports describe the input frame
// and the original expected_* ports describe the output frame. Both are
// snapshotted at start. Overlap always uses each resolved frame's own row
// width and height, not a common stride envelope or shared row count.
module c1_frame_pair_resolver #(
    parameter integer SEPARATE_INPUT_GEOMETRY = 0
) (
    input  logic           clk,
    input  logic           rst,
    input  logic           abort,

    input  logic           start_valid,
    output logic           start_ready,
    input  logic [63:0]    input_table_base,
    input  logic [63:0]    output_table_base,
    input  logic [1:0]     input_buffer_index,
    input  logic [1:0]     output_buffer_index,
    input  logic [15:0]    expected_width_pixels,
    input  logic [15:0]    expected_height_lines,

    output logic           response_valid,
    input  logic           response_ready,
    output logic           response_error,
    output logic [7:0]     response_error_code,
    output logic [31:0]    response_error_address,

    output logic [31:0]    resolved_input_base,
    output logic [31:0]    resolved_input_stride,
    output logic [15:0]    resolved_input_width,
    output logic [15:0]    resolved_input_height,
    output logic [31:0]    resolved_output_base,
    output logic [31:0]    resolved_output_stride,
    output logic [15:0]    resolved_output_width,
    output logic [15:0]    resolved_output_height,
    output logic           busy,

    output logic [31:0]    m_axi_araddr,
    output logic [7:0]     m_axi_arlen,
    output logic [2:0]     m_axi_arsize,
    output logic [1:0]     m_axi_arburst,
    output logic           m_axi_arvalid,
    input  logic           m_axi_arready,
    input  logic [127:0]   m_axi_rdata,
    input  logic [1:0]     m_axi_rresp,
    input  logic           m_axi_rlast,
    input  logic           m_axi_rvalid,
    output logic           m_axi_rready,
    // Used only when SEPARATE_INPUT_GEOMETRY=1. Existing expected dimensions
    // then describe OUTPUT; default mode ignores these additional inputs.
    input logic [15:0]     expected_input_width_pixels,
    input logic [15:0]     expected_input_height_lines
);

    localparam logic [7:0] ERR_INPUT_INDEX       = 8'h01;
    localparam logic [7:0] ERR_OUTPUT_INDEX      = 8'h02;
    localparam logic [7:0] ERR_ZERO_DIMENSION    = 8'h03;
    localparam logic [7:0] ERR_INPUT_TABLE_READ  = 8'h10;
    localparam logic [7:0] ERR_OUTPUT_TABLE_READ = 8'h11;
    localparam logic [7:0] ERR_INPUT_BASE_RANGE  = 8'h20;
    localparam logic [7:0] ERR_OUTPUT_BASE_RANGE = 8'h21;
    localparam logic [7:0] ERR_INPUT_BASE_ALIGN  = 8'h22;
    localparam logic [7:0] ERR_OUTPUT_BASE_ALIGN = 8'h23;
    localparam logic [7:0] ERR_INPUT_DIMENSION   = 8'h24;
    localparam logic [7:0] ERR_OUTPUT_DIMENSION  = 8'h25;
    localparam logic [7:0] ERR_INPUT_STRIDE      = 8'h26;
    localparam logic [7:0] ERR_OUTPUT_STRIDE     = 8'h27;
    localparam logic [7:0] ERR_INPUT_EXTENT      = 8'h28;
    localparam logic [7:0] ERR_OUTPUT_EXTENT     = 8'h29;
    localparam logic [7:0] ERR_ACTIVE_OVERLAP    = 8'h30;

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_REQUEST_INPUT,
        STATE_WAIT_INPUT,
        STATE_CHECK_INPUT_EXTENT,
        STATE_REQUEST_OUTPUT,
        STATE_WAIT_OUTPUT,
        STATE_CHECK_OUTPUT_EXTENT,
        STATE_CHECK_OVERLAP,
        STATE_RESPONSE
    } state_t;

    state_t state;

    logic [63:0] input_table_base_reg;
    logic [63:0] output_table_base_reg;
    logic [1:0] input_index_reg;
    logic [1:0] output_index_reg;
    logic [15:0] expected_width_reg;
    logic [15:0] expected_height_reg;
    logic [15:0] expected_input_width_reg, expected_input_height_reg;

    logic reader_request_valid;
    logic reader_request_ready;
    logic [63:0] reader_request_table_base;
    logic [1:0] reader_request_entry_index;
    logic reader_response_valid;
    logic reader_response_ready;
    logic reader_response_error;
    logic [127:0] reader_response_raw;
    logic [63:0] reader_response_base;
    logic [31:0] reader_response_stride;
    logic [15:0] reader_response_width;
    logic [15:0] reader_response_height;

    logic [31:0] reader_line_bytes;
    logic reader_dimensions_match;
    logic reader_stride_valid;

    logic [31:0] pending_base;
    logic [31:0] pending_stride;
    logic [15:0] pending_width;
    logic [15:0] pending_height;
    logic [47:0] extent_accum;
    logic [47:0] extent_addend;
    logic [15:0] extent_multiplier;
    logic [4:0]  extent_bit_index;
    logic [47:0] extent_accum_next;

    logic [31:0] input_table_entry_address;
    logic [31:0] output_table_entry_address;

    // Validated row starts are below 2^32 and an exclusive row end may equal
    // 2^32, so 33 bits preserve the full overlap contract without a needless
    // 64-bit add/compare chain.
    logic [32:0] overlap_input_start;
    logic [32:0] overlap_output_start;
    logic [32:0] overlap_input_end;
    logic [32:0] overlap_output_end;
    logic [15:0] overlap_input_row;
    logic [15:0] overlap_output_row;
    logic intervals_overlap;

    logic start_fire;
    logic response_fire;

    always_comb begin
        start_ready = !rst && !abort && (state == STATE_IDLE) &&
                      reader_request_ready;
        response_valid = !abort && (state == STATE_RESPONSE);
        busy = (state != STATE_IDLE) || !reader_request_ready;
        start_fire = start_valid && start_ready;
        response_fire = response_valid && response_ready;

        reader_request_valid = (state == STATE_REQUEST_INPUT) ||
                               (state == STATE_REQUEST_OUTPUT);
        if (state == STATE_REQUEST_OUTPUT) begin
            reader_request_table_base = output_table_base_reg;
            reader_request_entry_index = output_index_reg;
        end else begin
            reader_request_table_base = input_table_base_reg;
            reader_request_entry_index = input_index_reg;
        end
        reader_response_ready = (state == STATE_WAIT_INPUT) ||
                                (state == STATE_WAIT_OUTPUT);

        reader_line_bytes = {14'd0, reader_response_width, 2'b00};
        reader_dimensions_match =
            (reader_response_width == ((state==STATE_WAIT_INPUT) ? expected_input_width_reg : expected_width_reg)) &&
            (reader_response_height == ((state==STATE_WAIT_INPUT) ? expected_input_height_reg : expected_height_reg));
        reader_stride_valid =
            (reader_response_stride[3:0] == 4'd0) &&
            (reader_response_stride >= reader_line_bytes);

        // One multiplier bit is consumed per extent-check cycle.  The current
        // bit's add is included in extent_accum_next so bit 15 is checked on
        // its own cycle without an off-by-one terminal cycle.
        if (extent_multiplier[0])
            extent_accum_next = extent_accum + extent_addend;
        else
            extent_accum_next = extent_accum;

        input_table_entry_address = input_table_base_reg[31:0] +
                                    ({30'd0, input_index_reg} << 4);
        output_table_entry_address = output_table_base_reg[31:0] +
                                     ({30'd0, output_index_reg} << 4);

        overlap_input_end = overlap_input_start + {15'd0,resolved_input_width,2'b00};
        overlap_output_end = overlap_output_start + {15'd0,resolved_output_width,2'b00};
        intervals_overlap = (overlap_input_start < overlap_output_end) &&
                            (overlap_output_start < overlap_input_end);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            input_table_base_reg <= 64'd0;
            output_table_base_reg <= 64'd0;
            input_index_reg <= 2'd0;
            output_index_reg <= 2'd0;
            expected_width_reg <= 16'd0;
            expected_height_reg <= 16'd0;
            expected_input_width_reg <= 0;
            expected_input_height_reg <= 0;
            response_error <= 1'b0;
            response_error_code <= 8'd0;
            response_error_address <= 32'd0;
            resolved_input_base <= 32'd0;
            resolved_input_stride <= 32'd0;
            resolved_input_width <= 16'd0;
            resolved_input_height <= 16'd0;
            resolved_output_base <= 32'd0;
            resolved_output_stride <= 32'd0;
            resolved_output_width <= 16'd0;
            resolved_output_height <= 16'd0;
            overlap_input_start <= 33'd0;
            overlap_output_start <= 33'd0;
            overlap_input_row <= 16'd0;
            overlap_output_row <= 16'd0;
            pending_base <= 32'd0;
            pending_stride <= 32'd0;
            pending_width <= 16'd0;
            pending_height <= 16'd0;
            extent_accum <= 48'd0;
            extent_addend <= 48'd0;
            extent_multiplier <= 16'd0;
            extent_bit_index <= 5'd0;
        end else if (abort) begin
            state <= STATE_IDLE;
            response_error <= 1'b0;
            response_error_code <= 8'd0;
            response_error_address <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start_fire) begin
                        input_table_base_reg <= input_table_base;
                        output_table_base_reg <= output_table_base;
                        input_index_reg <= input_buffer_index;
                        output_index_reg <= output_buffer_index;
                        expected_width_reg <= expected_width_pixels;
                        expected_height_reg <= expected_height_lines;
                        expected_input_width_reg <= SEPARATE_INPUT_GEOMETRY ? expected_input_width_pixels : expected_width_pixels;
                        expected_input_height_reg <= SEPARATE_INPUT_GEOMETRY ? expected_input_height_lines : expected_height_lines;
                        response_error <= 1'b0;
                        response_error_code <= 8'd0;
                        response_error_address <= 32'd0;
                        resolved_input_base <= 32'd0;
                        resolved_input_stride <= 32'd0;
                        resolved_input_width <= 16'd0;
                        resolved_input_height <= 16'd0;
                        resolved_output_base <= 32'd0;
                        resolved_output_stride <= 32'd0;
                        resolved_output_width <= 16'd0;
                        resolved_output_height <= 16'd0;

                        if (input_buffer_index > 2) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_INDEX;
                            response_error_address <= input_table_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if (output_buffer_index > 1) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_INDEX;
                            response_error_address <= output_table_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if ((expected_width_pixels == 0) ||
                                     (expected_height_lines == 0) ||
                                     (SEPARATE_INPUT_GEOMETRY &&
                                      ((expected_input_width_pixels==0) || (expected_input_height_lines==0)))) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_ZERO_DIMENSION;
                            response_error_address <= 32'd0;
                            state <= STATE_RESPONSE;
                        end else begin
                            state <= STATE_REQUEST_INPUT;
                        end
                    end
                end

                STATE_REQUEST_INPUT: begin
                    if (reader_request_valid && reader_request_ready)
                        state <= STATE_WAIT_INPUT;
                end

                STATE_WAIT_INPUT: begin
                    if (reader_response_valid && reader_response_ready) begin
                        if (reader_response_base[63:32] != 32'd0) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_BASE_RANGE;
                            response_error_address <= reader_response_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if (reader_response_error) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_TABLE_READ;
                            response_error_address <= input_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else if (reader_response_base[3:0] != 4'd0) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_BASE_ALIGN;
                            response_error_address <= reader_response_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if (!reader_dimensions_match) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_DIMENSION;
                            response_error_address <= input_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else if (!reader_stride_valid) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_STRIDE;
                            response_error_address <= input_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else begin
                            pending_base <= reader_response_base[31:0];
                            pending_stride <= reader_response_stride;
                            pending_width <= reader_response_width;
                            pending_height <= reader_response_height;
                            // end_exclusive = base + line_bytes +
                            //                 (height-1)*stride
                            extent_accum <=
                                {16'd0, reader_response_base[31:0]} +
                                {16'd0, reader_line_bytes};
                            extent_addend <=
                                {16'd0, reader_response_stride};
                            extent_multiplier <=
                                reader_response_height - 16'd1;
                            extent_bit_index <= 5'd0;
                            state <= STATE_CHECK_INPUT_EXTENT;
                        end
                    end
                end

                STATE_CHECK_INPUT_EXTENT: begin
                    if (extent_bit_index == 5'd15) begin
                        if (extent_accum_next > 48'h0001_0000_0000) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_INPUT_EXTENT;
                            response_error_address <= pending_base;
                            state <= STATE_RESPONSE;
                        end else begin
                            resolved_input_base <= pending_base;
                            resolved_input_stride <= pending_stride;
                            resolved_input_width <= pending_width;
                            resolved_input_height <= pending_height;
                            state <= STATE_REQUEST_OUTPUT;
                        end
                    end else begin
                        extent_accum <= extent_accum_next;
                        extent_addend <= extent_addend << 1;
                        extent_multiplier <= extent_multiplier >> 1;
                        extent_bit_index <= extent_bit_index + 5'd1;
                    end
                end

                STATE_REQUEST_OUTPUT: begin
                    if (reader_request_valid && reader_request_ready)
                        state <= STATE_WAIT_OUTPUT;
                end

                STATE_WAIT_OUTPUT: begin
                    if (reader_response_valid && reader_response_ready) begin
                        if (reader_response_base[63:32] != 32'd0) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_BASE_RANGE;
                            response_error_address <= reader_response_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if (reader_response_error) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_TABLE_READ;
                            response_error_address <= output_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else if (reader_response_base[3:0] != 4'd0) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_BASE_ALIGN;
                            response_error_address <= reader_response_base[31:0];
                            state <= STATE_RESPONSE;
                        end else if (!reader_dimensions_match) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_DIMENSION;
                            response_error_address <= output_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else if (!reader_stride_valid) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_STRIDE;
                            response_error_address <= output_table_entry_address;
                            state <= STATE_RESPONSE;
                        end else begin
                            pending_base <= reader_response_base[31:0];
                            pending_stride <= reader_response_stride;
                            pending_width <= reader_response_width;
                            pending_height <= reader_response_height;
                            extent_accum <=
                                {16'd0, reader_response_base[31:0]} +
                                {16'd0, reader_line_bytes};
                            extent_addend <=
                                {16'd0, reader_response_stride};
                            extent_multiplier <=
                                reader_response_height - 16'd1;
                            extent_bit_index <= 5'd0;
                            state <= STATE_CHECK_OUTPUT_EXTENT;
                        end
                    end
                end

                STATE_CHECK_OUTPUT_EXTENT: begin
                    if (extent_bit_index == 5'd15) begin
                        if (extent_accum_next > 48'h0001_0000_0000) begin
                            response_error <= 1'b1;
                            response_error_code <= ERR_OUTPUT_EXTENT;
                            response_error_address <= pending_base;
                            state <= STATE_RESPONSE;
                        end else begin
                            resolved_output_base <= pending_base;
                            resolved_output_stride <= pending_stride;
                            resolved_output_width <= pending_width;
                            resolved_output_height <= pending_height;
                            overlap_input_start <=
                                {1'b0, resolved_input_base};
                            overlap_output_start <= {1'b0, pending_base};
                            overlap_input_row <= 16'd0;
                            overlap_output_row <= 16'd0;
                            state <= STATE_CHECK_OVERLAP;
                        end
                    end else begin
                        extent_accum <= extent_accum_next;
                        extent_addend <= extent_addend << 1;
                        extent_multiplier <= extent_multiplier >> 1;
                        extent_bit_index <= extent_bit_index + 5'd1;
                    end
                end

                STATE_CHECK_OVERLAP: begin
                    if (intervals_overlap) begin
                        response_error <= 1'b1;
                        response_error_code <= ERR_ACTIVE_OVERLAP;
                        if (overlap_input_start > overlap_output_start)
                            response_error_address <= overlap_input_start[31:0];
                        else
                            response_error_address <= overlap_output_start[31:0];
                        state <= STATE_RESPONSE;
                    end else if (overlap_input_end <= overlap_output_start) begin
                        if (overlap_input_row + 1'b1 >= resolved_input_height) begin
                            response_error <= 1'b0;
                            response_error_code <= 8'd0;
                            response_error_address <= 32'd0;
                            state <= STATE_RESPONSE;
                        end else begin
                            overlap_input_row <= overlap_input_row + 1'b1;
                            overlap_input_start <= overlap_input_start +
                                                   {1'b0, resolved_input_stride};
                        end
                    end else begin
                        if (overlap_output_row + 1'b1 >= resolved_output_height) begin
                            response_error <= 1'b0;
                            response_error_code <= 8'd0;
                            response_error_address <= 32'd0;
                            state <= STATE_RESPONSE;
                        end else begin
                            overlap_output_row <= overlap_output_row + 1'b1;
                            overlap_output_start <= overlap_output_start +
                                                    {1'b0, resolved_output_stride};
                        end
                    end
                end

                STATE_RESPONSE: begin
                    if (response_fire)
                        state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

    c1_axi_frame_buffer_table_reader #(
        .INDEX_BITS(2)
    ) u_table_reader (
        .clk(clk),
        .rst(rst),
        .abort(abort),
        .request_valid(reader_request_valid),
        .request_ready(reader_request_ready),
        .request_table_base(reader_request_table_base),
        .request_entry_index(reader_request_entry_index),
        .response_valid(reader_response_valid),
        .response_ready(reader_response_ready),
        .response_error(reader_response_error),
        .response_raw(reader_response_raw),
        .response_base_address(reader_response_base),
        .response_stride_bytes(reader_response_stride),
        .response_width_pixels(reader_response_width),
        .response_height_lines(reader_response_height),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

endmodule
