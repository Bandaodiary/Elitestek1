`timescale 1ns/1ps

// AXI4 128-bit reader for one FRAME_BUFFER_FORMAT.md table entry.
//
// Each request reads exactly one 16-byte entry at:
//   byte_address = table_base + entry_index * 16
//
// table_base is 64 bit at the software boundary, but this implementation has
// a 32-bit AXI address channel.  A non-zero table_base high word, an unaligned
// base, 64-bit addition carry, or a result outside the final legal 16-byte
// window (0xffff_fff0) is rejected locally without issuing AR.
//
// Entry layout, little-endian AXI byte order:
//   [ 63:  0] framebuffer base_address
//   [ 95: 64] stride_bytes
//   [111: 96] width_pixels
//   [127:112] height_lines
// The raw beat is always returned as received.  response_error is asserted for
// a local request error, non-OKAY RRESP, missing RLAST on the single expected
// beat, or a framebuffer base_address whose high 32 bits are non-zero.
//
// Abort contract:
// * before the AR handshake: cancel immediately, issue no response;
// * on or after the AR handshake: keep RREADY asserted until the one implied
//   beat is drained, then discard it and issue no response;
// * while an output response is stalled: suppress/drop that response.
// Only one request/AXI transaction may be outstanding.
module c1_axi_frame_buffer_table_reader #(
    parameter integer INDEX_BITS = 16
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    abort,
    input  logic                    request_valid,
    output logic                    request_ready,
    input  logic [63:0]             request_table_base,
    input  logic [INDEX_BITS-1:0]   request_entry_index,

    output logic                    response_valid,
    input  logic                    response_ready,
    output logic                    response_error,
    output logic [127:0]            response_raw,
    output logic [63:0]             response_base_address,
    output logic [31:0]             response_stride_bytes,
    output logic [15:0]             response_width_pixels,
    output logic [15:0]             response_height_lines,

    output logic [31:0]             m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,

    input  logic [127:0]            m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_AR,
        STATE_R,
        STATE_RESPONSE
    } state_t;

    state_t state;
    logic [31:0] latched_araddr;
    logic drop_response;

    logic [64:0] index_extended;
    logic [64:0] index_offset;
    logic [64:0] request_address_wide;
    logic request_is_legal;
    logic request_fire;
    logic ar_fire;
    logic r_fire;

    always_comb begin
        index_extended = 65'd0;
        index_extended[INDEX_BITS-1:0] = request_entry_index;
        index_offset = index_extended << 4;
        request_address_wide = {1'b0, request_table_base} + index_offset;

        request_is_legal =
            (request_table_base[63:32] == 32'd0) &&
            (request_table_base[3:0] == 4'd0) &&
            !request_address_wide[64] &&
            (request_address_wide[63:32] == 32'd0) &&
            (request_address_wide[31:0] <= 32'hffff_fff0) &&
            (request_address_wide[3:0] == 4'd0);
    end

    always_comb begin
        request_ready = (state == STATE_IDLE) && !abort;
        response_valid = (state == STATE_RESPONSE) && !abort;

        response_base_address = response_raw[63:0];
        response_stride_bytes = response_raw[95:64];
        response_width_pixels = response_raw[111:96];
        response_height_lines = response_raw[127:112];

        m_axi_araddr = latched_araddr;
        m_axi_arlen = 8'd0;
        m_axi_arsize = 3'd4; // 16 bytes
        m_axi_arburst = AXI_BURST_INCR;
        m_axi_arvalid = (state == STATE_AR);

        // Once AR commits, the single expected R beat is always drained,
        // including while abort is asserted.
        m_axi_rready = (state == STATE_R);

        request_fire = request_valid && request_ready;
        ar_fire = m_axi_arvalid && m_axi_arready;
        r_fire = m_axi_rvalid && m_axi_rready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            latched_araddr <= 32'd0;
            drop_response <= 1'b0;
            response_error <= 1'b0;
            response_raw <= 128'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    drop_response <= 1'b0;
                    if (request_fire) begin
                        latched_araddr <= request_address_wide[31:0];
                        response_raw <= 128'd0;
                        response_error <= !request_is_legal;
                        if (request_is_legal)
                            state <= STATE_AR;
                        else
                            state <= STATE_RESPONSE;
                    end
                end

                STATE_AR: begin
                    // A simultaneous handshake commits the AXI transaction;
                    // therefore it has priority over the abort cancellation.
                    if (ar_fire) begin
                        drop_response <= abort;
                        state <= STATE_R;
                    end else if (abort) begin
                        state <= STATE_IDLE;
                    end
                end

                STATE_R: begin
                    if (abort)
                        drop_response <= 1'b1;

                    if (r_fire) begin
                        response_raw <= m_axi_rdata;
                        response_error <=
                            (m_axi_rresp != AXI_RESP_OKAY) ||
                            !m_axi_rlast ||
                            (m_axi_rdata[63:32] != 32'd0);
                        if (drop_response || abort)
                            state <= STATE_IDLE;
                        else
                            state <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (abort || (response_valid && response_ready))
                        state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((INDEX_BITS < 1) || (INDEX_BITS > 32))
            $fatal(1, "c1_axi_frame_buffer_table_reader INDEX_BITS must be 1..32");
    end
`endif

endmodule
