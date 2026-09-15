`timescale 1ns/1ps

// Vendor-independent AXI4 descriptor reader for c1_layer_scheduler.
//
// Each descriptor is 64 bytes (512 bits).  A scheduler request maps to one
// four-beat AXI4 INCR read on a 128-bit data bus:
//
//   byte_address = descriptor_base + descriptor_request_index * 64
//
// descriptor_base is sampled on the request handshake and must be 64-byte
// aligned.  Address arithmetic is checked in 64 bits; a descriptor whose last
// byte would exceed the 32-bit address space is rejected without issuing AR.
// Beat zero occupies descriptor_response_data[127:0], so word zero is always
// descriptor_response_data[31:0] on a little-endian AXI memory map.
//
// Only one request may be outstanding.  A response is emitted for exactly one
// clock after the accepted request has advanced the scheduler to its response
// state.  Invalid requests therefore receive their error response on the clock
// after the request handshake, never combinationally with that handshake.
//
// Abort contract:
//   * before AR handshake: cancel the request and issue no response;
//   * on/after AR handshake: keep RREADY asserted until all four beats have
//     been drained, then discard the transaction and issue no response;
//   * while abort is asserted in the response cycle: suppress the response.
//
// The AXI slave is expected to return exactly four beats.  Early or missing
// RLAST is reported through descriptor_response_error.  Early RLAST is the
// actual end of that malformed burst and terminates immediately; missing RLAST
// terminates at the fourth, ARLEN-implied beat.  This matches a shared
// interconnect that releases ownership on either physical or expected end.
module c1_axi_descriptor_reader #(
    parameter integer INDEX_BITS = 16
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    abort,
    input  logic [31:0]             descriptor_base,

    input  logic                    descriptor_request_valid,
    output logic                    descriptor_request_ready,
    input  logic [INDEX_BITS-1:0]   descriptor_request_index,

    output logic                    descriptor_response_valid,
    output logic                    descriptor_response_error,
    output logic [511:0]            descriptor_response_data,

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

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_AR,
        STATE_R,
        STATE_RESPONSE
    } state_t;

    state_t state;

    logic [31:0] latched_base;
    logic [INDEX_BITS-1:0] latched_index;
    logic [31:0] latched_address;
    logic [1:0] beat_index;
    logic transaction_error;
    logic drop_response;

    logic [63:0] index_wide;
    logic [63:0] request_address_wide;
    logic request_is_legal;
    logic request_fire;
    logic ar_fire;
    logic r_fire;

    always_comb begin
        index_wide = 64'd0;
        index_wide[INDEX_BITS-1:0] = descriptor_request_index;
        request_address_wide = {32'd0, descriptor_base} +
                               (index_wide << 6);
        request_is_legal = (descriptor_base[5:0] == 6'd0) &&
                           (request_address_wide <= 64'h0000_0000_ffff_ffc0);
    end

    always_comb begin
        descriptor_request_ready = (state == STATE_IDLE) && !abort;
        descriptor_response_valid = (state == STATE_RESPONSE) && !abort;
        descriptor_response_error = transaction_error;

        m_axi_araddr  = latched_address;
        m_axi_arlen   = 8'd3;
        m_axi_arsize  = 3'd4; // 2**4 = 16 bytes per beat
        m_axi_arburst = AXI_BURST_INCR;
        m_axi_arvalid = (state == STATE_AR);

        // Once AR has committed, always accept R so abort can safely drain.
        m_axi_rready = (state == STATE_R);

        request_fire = descriptor_request_valid && descriptor_request_ready;
        ar_fire = m_axi_arvalid && m_axi_arready;
        r_fire = m_axi_rvalid && m_axi_rready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            latched_base <= 32'd0;
            latched_index <= '0;
            latched_address <= 32'd0;
            beat_index <= 2'd0;
            transaction_error <= 1'b0;
            drop_response <= 1'b0;
            descriptor_response_data <= 512'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    beat_index <= 2'd0;
                    drop_response <= 1'b0;

                    if (request_fire) begin
                        latched_base <= descriptor_base;
                        latched_index <= descriptor_request_index;
                        latched_address <= request_address_wide[31:0];
                        descriptor_response_data <= 512'd0;
                        transaction_error <= !request_is_legal;

                        if (request_is_legal) begin
                            state <= STATE_AR;
                        end else begin
                            // Delayed by one state so the scheduler is already
                            // waiting for the response when this pulse appears.
                            state <= STATE_RESPONSE;
                        end
                    end
                end

                STATE_AR: begin
                    // An AR handshake has priority over abort because the AXI
                    // transaction is committed on that same edge and must drain.
                    if (ar_fire) begin
                        beat_index <= 2'd0;
                        drop_response <= abort;
                        state <= STATE_R;
                    end else if (abort) begin
                        state <= STATE_IDLE;
                    end
                end

                STATE_R: begin
                    if (abort) begin
                        drop_response <= 1'b1;
                    end

                    if (r_fire) begin
                        case (beat_index)
                            2'd0: descriptor_response_data[127:0]   <= m_axi_rdata;
                            2'd1: descriptor_response_data[255:128] <= m_axi_rdata;
                            2'd2: descriptor_response_data[383:256] <= m_axi_rdata;
                            2'd3: descriptor_response_data[511:384] <= m_axi_rdata;
                            default: descriptor_response_data <= descriptor_response_data;
                        endcase

                        if ((m_axi_rresp !== AXI_RESP_OKAY) ||
                            (m_axi_rlast !== (beat_index == 2'd3))) begin
                            transaction_error <= 1'b1;
                        end

                        if (m_axi_rlast || (beat_index == 2'd3)) begin
                            if (drop_response || abort) begin
                                state <= STATE_IDLE;
                            end else begin
                                state <= STATE_RESPONSE;
                            end
                        end else begin
                            beat_index <= beat_index + 2'd1;
                        end
                    end
                end

                STATE_RESPONSE: begin
                    // descriptor_response_valid is combinationally suppressed
                    // by abort.  Either way, this is a one-cycle terminal state.
                    state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

    initial begin
        if ((INDEX_BITS < 1) || (INDEX_BITS > 32)) begin
            $error("INDEX_BITS must be in the range 1..32");
        end
    end

endmodule
