`timescale 1ns/1ps

// Portable bridge from the MicroStyle tensor adapter's one-outstanding
// 64-bit request/response seam to a one-beat AXI4 128-bit master.
//
// Local contract
// --------------
// * A request transfers on mem_req_valid && mem_req_ready.
// * The request address must be 8-byte aligned.  Misaligned requests produce
//   one local error response and issue no AXI transfer.
// * Every accepted read OR write produces exactly one later response.  The
//   bridge holds response payload stable until mem_rsp_ready.
// * There is no cancel input: once accepted, a request is completed.  This
//   matches c1_r1_microstyle_tensor_adapter, which drains its outstanding
//   response during abort.
//
// AXI contract
// ------------
// * ARLEN/AWLEN=0, ARSIZE/AWSIZE=4 (one full 16-byte bus beat), INCR.
// * AXI address is aligned down to 16 bytes.  request addr[3] selects the
//   lower or upper 64-bit half of RDATA/WDATA and the matching WSTRB half.
// * AW and W are independent.  Each VALID and payload remains stable until
//   its own READY handshake; BREADY is asserted only after both handshakes.
// * A non-OKAY RRESP/BRESP, or deasserted RLAST on the implied single read
//   beat, is reported through mem_rsp_error.  The selected read half is
//   still returned with an AXI read error for diagnostics.
// Optional one/two-entry fully associative read-beat reuse is for owned
// ordinary RAM, not MMIO. Two entries use invalid-first, then true LRU
// replacement. Accepted misses still have exactly one physical owner.
// By default every accepted write invalidates it. PRECISE_WRITE_INVALIDATION
// retains it only for aligned writes to a different 16-byte line; same-line
// writes (including zero strobes), rejected write misalignment and B errors
// clear all entries. A read bus error also clears both, and never fills.
// The owner must also invalidate at
// stage/job boundaries and before external writers reuse the memory. This
// is NOT a cancellation fence: accepted requests and presented responses
// still retire normally. A fence during a miss prevents its late refill
// from repopulating the cache, even after the fence has deasserted.
// Precise invalidation additionally assumes different AXI line addresses
// denote different RAM cells (no aliased/mirrored address mappings). External
// CPU/DMA writers still need the explicit owner fence after in-flight reads
// have retired; no AXI snoop or hardware cache-coherence protocol is implied.
module c1_tensor_mem_axi128_bridge #(
    parameter bit ENABLE_READ_BEAT_CACHE = 1'b0,
    parameter integer READ_BEAT_CACHE_ENTRIES = 1,
    parameter bit PRECISE_WRITE_INVALIDATION = 1'b0
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          mem_req_valid,
    output logic          mem_req_ready,
    input  logic          mem_req_write,
    input  logic [31:0]   mem_req_addr,
    input  logic [63:0]   mem_req_wdata,
    input  logic [7:0]    mem_req_wstrb,

    output logic          mem_rsp_valid,
    input  logic          mem_rsp_ready,
    output logic          mem_rsp_error,
    output logic [63:0]   mem_rsp_rdata,

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
    output logic          m_axi_bready,

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
    input  logic          read_cache_invalidate,
    // Raw valid/tag match for mem_req_addr, independent of invalidate. This
    // is NOT a safe read-hit indication: it lets an ordered write wrapper
    // snoop an address without forming hit -> invalidate -> hit feedback.
    output logic          read_cache_addr_match
);

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_AR,
        ST_READ_R,
        ST_WRITE_SEND,
        ST_WRITE_B,
        ST_RESPONSE
    } state_t;

    state_t state_q;
    logic [31:0] address_q;
    logic half_select_q;
    logic [63:0] write_data_q;
    logic [7:0] write_strobe_q;
    logic aw_sent_q;
    logic w_sent_q;
    logic response_error_q;
    logic [63:0] response_data_q;

    logic request_fire;
    logic aw_fire, w_fire, b_fire;
    logic ar_fire, r_fire;
    logic aw_complete, w_complete;
    initial begin
        if(READ_BEAT_CACHE_ENTRIES!=1 && READ_BEAT_CACHE_ENTRIES!=2)
            $fatal(1,"read beat cache entries must be 1 or 2");
    end
    logic [READ_BEAT_CACHE_ENTRIES-1:0] read_beat_valid_q;
    logic read_fill_allowed_q, read_fill_way_q, read_lru_q;
    logic [27:0] read_beat_tag_q [0:READ_BEAT_CACHE_ENTRIES-1];
    logic [127:0] read_beat_data_q [0:READ_BEAT_CACHE_ENTRIES-1];
    wire [READ_BEAT_CACHE_ENTRIES-1:0] read_match;
    generate for(genvar way=0;way<READ_BEAT_CACHE_ENTRIES;way++) begin : g_read_match
        assign read_match[way]=read_beat_valid_q[way] &&
                              mem_req_addr[31:4]==read_beat_tag_q[way];
    end endgenerate
    wire read_hit_way=(READ_BEAT_CACHE_ENTRIES==2) && read_match[READ_BEAT_CACHE_ENTRIES-1];
    wire read_replace_way=(READ_BEAT_CACHE_ENTRIES==1 || !read_beat_valid_q[0]) ? 1'b0 :
                          (!read_beat_valid_q[READ_BEAT_CACHE_ENTRIES-1] ? 1'b1 : read_lru_q);
    wire [127:0] read_hit_data=read_beat_data_q[read_hit_way];
    wire invalidate_read_beat = ENABLE_READ_BEAT_CACHE && read_cache_invalidate;
    // Raw OR of both tags, independent of the invalidate input. The ordered
    // packing wrapper uses this query without hit -> invalidate feedback.
    assign read_cache_addr_match = ENABLE_READ_BEAT_CACHE && (|read_match);
    wire read_beat_hit = read_cache_addr_match && !invalidate_read_beat;
    wire local_write_invalidate = request_fire && mem_req_write &&
        (!PRECISE_WRITE_INVALIDATION || mem_req_addr[2:0] != 0 || read_cache_addr_match);

    always_comb begin
        mem_req_ready = (state_q == ST_IDLE) && !rst;
        mem_rsp_valid = (state_q == ST_RESPONSE) && !rst;
        mem_rsp_error = response_error_q;
        mem_rsp_rdata = response_data_q;

        m_axi_awaddr = {address_q[31:4], 4'b0000};
        m_axi_awlen = 8'd0;
        m_axi_awsize = 3'd4;
        m_axi_awburst = AXI_BURST_INCR;
        m_axi_awvalid = (state_q == ST_WRITE_SEND) && !aw_sent_q;

        if (half_select_q) begin
            m_axi_wdata = {write_data_q, 64'd0};
            m_axi_wstrb = {write_strobe_q, 8'd0};
        end else begin
            m_axi_wdata = {64'd0, write_data_q};
            m_axi_wstrb = {8'd0, write_strobe_q};
        end
        m_axi_wlast = 1'b1;
        m_axi_wvalid = (state_q == ST_WRITE_SEND) && !w_sent_q;
        m_axi_bready = (state_q == ST_WRITE_B);

        m_axi_araddr = {address_q[31:4], 4'b0000};
        m_axi_arlen = 8'd0;
        m_axi_arsize = 3'd4;
        m_axi_arburst = AXI_BURST_INCR;
        m_axi_arvalid = (state_q == ST_READ_AR);
        m_axi_rready = (state_q == ST_READ_R);

        request_fire = mem_req_valid && mem_req_ready;
        aw_fire = m_axi_awvalid && m_axi_awready;
        w_fire = m_axi_wvalid && m_axi_wready;
        b_fire = m_axi_bvalid && m_axi_bready;
        ar_fire = m_axi_arvalid && m_axi_arready;
        r_fire = m_axi_rvalid && m_axi_rready;
        aw_complete = aw_sent_q || aw_fire;
        w_complete = w_sent_q || w_fire;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            address_q <= 32'd0;
            half_select_q <= 1'b0;
            write_data_q <= 64'd0;
            write_strobe_q <= 8'd0;
            aw_sent_q <= 1'b0;
            w_sent_q <= 1'b0;
            response_error_q <= 1'b0;
            response_data_q <= 64'd0;
            read_beat_valid_q <= '0;
            read_fill_allowed_q <= 1'b0;
            read_fill_way_q <= 1'b0;
            read_lru_q <= 1'b0;
            for(integer way=0;way<READ_BEAT_CACHE_ENTRIES;way++) begin
                read_beat_tag_q[way] <= '0;
                read_beat_data_q[way] <= '0;
            end
        end else begin
            if (invalidate_read_beat) begin
                read_beat_valid_q <= '0;
                read_fill_allowed_q <= 1'b0;
            end
            if (local_write_invalidate)
                read_beat_valid_q <= '0;
            case (state_q)
                ST_IDLE: begin
                    aw_sent_q <= 1'b0;
                    w_sent_q <= 1'b0;
                    if (request_fire) begin
                        address_q <= mem_req_addr;
                        half_select_q <= mem_req_addr[3];
                        write_data_q <= mem_req_wdata;
                        write_strobe_q <= mem_req_wstrb;
                        response_error_q <= 1'b0;
                        response_data_q <= 64'd0;
                        if (mem_req_addr[2:0] != 3'b000) begin
                            response_error_q <= 1'b1;
                            state_q <= ST_RESPONSE;
                        end else if (mem_req_write) begin
                            state_q <= ST_WRITE_SEND;
                        end else if (read_beat_hit) begin
                            response_data_q <= mem_req_addr[3] ?
                                read_hit_data[127:64] : read_hit_data[63:0];
                            read_lru_q <= (READ_BEAT_CACHE_ENTRIES==2) && !read_hit_way;
                            state_q <= ST_RESPONSE;
                        end else begin
                            read_beat_valid_q[read_replace_way] <= 1'b0;
                            read_fill_way_q <= read_replace_way;
                            read_fill_allowed_q <= ENABLE_READ_BEAT_CACHE && !invalidate_read_beat;
                            state_q <= ST_READ_AR;
                        end
                    end
                end

                ST_READ_AR: begin
                    if (ar_fire)
                        state_q <= ST_READ_R;
                end

                ST_READ_R: begin
                    if (r_fire) begin
                        response_data_q <= half_select_q ?
                                           m_axi_rdata[127:64] :
                                           m_axi_rdata[63:0];
                        response_error_q <=
                            (m_axi_rresp != AXI_RESP_OKAY) || !m_axi_rlast;
                        if (ENABLE_READ_BEAT_CACHE && read_fill_allowed_q &&
                            !invalidate_read_beat &&
                            (m_axi_rresp == AXI_RESP_OKAY) && m_axi_rlast) begin
                            read_beat_valid_q[read_fill_way_q] <= 1'b1;
                            read_beat_tag_q[read_fill_way_q] <= address_q[31:4];
                            read_beat_data_q[read_fill_way_q] <= m_axi_rdata;
                            read_lru_q <= (READ_BEAT_CACHE_ENTRIES==2) && !read_fill_way_q;
                        end
                        if(m_axi_rresp!=AXI_RESP_OKAY || !m_axi_rlast)
                            read_beat_valid_q <= '0;
                        read_fill_allowed_q <= 1'b0;
                        state_q <= ST_RESPONSE;
                    end
                end

                ST_WRITE_SEND: begin
                    if (aw_fire)
                        aw_sent_q <= 1'b1;
                    if (w_fire)
                        w_sent_q <= 1'b1;
                    if (aw_complete && w_complete)
                        state_q <= ST_WRITE_B;
                end

                ST_WRITE_B: begin
                    if (b_fire) begin
                        // Keep bus-error recovery conservative even when the
                        // requested address did not overlap the cached line.
                        if (m_axi_bresp != AXI_RESP_OKAY)
                            read_beat_valid_q <= '0;
                        response_error_q <=
                            (m_axi_bresp != AXI_RESP_OKAY);
                        response_data_q <= 64'd0;
                        state_q <= ST_RESPONSE;
                    end
                end

                ST_RESPONSE: begin
                    if (mem_rsp_valid && mem_rsp_ready)
                        state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                    response_error_q <= 1'b1;
                    response_data_q <= 64'd0;
                    read_beat_valid_q <= '0;
                    read_fill_allowed_q <= 1'b0;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    generate if(READ_BEAT_CACHE_ENTRIES==2) begin : g_read_unique_check
        always @(posedge clk) if(!rst && read_beat_valid_q==2'b11 &&
                                read_beat_tag_q[0]==read_beat_tag_q[1])
            $fatal(1,"read beat cache contains duplicate valid tags");
    end endgenerate
    logic ar_stalled_q, aw_stalled_q, w_stalled_q, rsp_stalled_q;
    logic [44:0] ar_payload_q, aw_payload_q;
    logic [144:0] w_payload_q;
    logic [64:0] rsp_payload_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_stalled_q <= 1'b0;
            aw_stalled_q <= 1'b0;
            w_stalled_q <= 1'b0;
            rsp_stalled_q <= 1'b0;
        end else begin
            if (ENABLE_READ_BEAT_CACHE &&
                (read_cache_invalidate !== 1'b0) && (read_cache_invalidate !== 1'b1))
                $fatal(1, "enabled tensor read cache requires a driven invalidation input");
            if (ar_stalled_q &&
                (!m_axi_arvalid ||
                 ({m_axi_araddr, m_axi_arlen, m_axi_arsize,
                   m_axi_arburst} != ar_payload_q)))
                $fatal(1, "tensor AXI bridge changed stalled AR payload");
            if (aw_stalled_q &&
                (!m_axi_awvalid ||
                 ({m_axi_awaddr, m_axi_awlen, m_axi_awsize,
                   m_axi_awburst} != aw_payload_q)))
                $fatal(1, "tensor AXI bridge changed stalled AW payload");
            if (w_stalled_q &&
                (!m_axi_wvalid ||
                 ({m_axi_wdata, m_axi_wstrb, m_axi_wlast} != w_payload_q)))
                $fatal(1, "tensor AXI bridge changed stalled W payload");
            if (rsp_stalled_q &&
                (!mem_rsp_valid ||
                 ({mem_rsp_error, mem_rsp_rdata} != rsp_payload_q)))
                $fatal(1, "tensor AXI bridge changed stalled response");

            ar_stalled_q <= m_axi_arvalid && !m_axi_arready;
            aw_stalled_q <= m_axi_awvalid && !m_axi_awready;
            w_stalled_q <= m_axi_wvalid && !m_axi_wready;
            rsp_stalled_q <= mem_rsp_valid && !mem_rsp_ready;
            ar_payload_q <= {m_axi_araddr, m_axi_arlen,
                             m_axi_arsize, m_axi_arburst};
            aw_payload_q <= {m_axi_awaddr, m_axi_awlen,
                             m_axi_awsize, m_axi_awburst};
            w_payload_q <= {m_axi_wdata, m_axi_wstrb, m_axi_wlast};
            rsp_payload_q <= {mem_rsp_error, mem_rsp_rdata};

            if ((m_axi_arvalid || m_axi_rready) &&
                (m_axi_awvalid || m_axi_wvalid || m_axi_bready))
                $fatal(1, "tensor AXI bridge overlapped read and write paths");
        end
    end
`endif

endmodule
