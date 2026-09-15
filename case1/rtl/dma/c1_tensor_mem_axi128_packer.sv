`timescale 1ns/1ps

// Boardless performance prototype for the tensor memory path.
//
// The production correctness seam (c1_tensor_mem_axi128_bridge) deliberately
// accepts one 64-bit request at a time.  That is useful for bringing up the
// descriptor scheduler, but it cannot exploit the fact that two adjacent
// C8 beats share one 128-bit AXI beat.  This standalone block adds a small
// in-order request FIFO and coalesces the lower/upper halves of one aligned
// AXI beat.  It is intentionally not wired into the portable SoC yet:
// software-visible behaviour and all existing correctness tests therefore
// remain unchanged.
//
// Local interface
// ---------------
// Requests are accepted in order.  A request response is returned in the
// same order, one cycle or more after acceptance.  `req_flush` asks the
// scheduler to issue a lone FIFO head immediately; this is needed when a
// stream ends with one unpaired request.  Both reads and writes may be packed,
// but only when the two requests have the same aligned 16-byte address, are
// 8-byte aligned, have opposite addr[3] lane bits, and have the same write
// direction.  AXI remains a one-beat, ID-less subset, so no AXI IDs are
// required.  AXI errors are replicated to both responses of a packed pair.
//
// `PACK_ENABLE=0` is a useful A/B mode: the FIFO remains active but every
// request is issued as one AXI beat.  The default is enabled for the new
// performance prototype; this module is not instantiated by the legacy path.
module c1_tensor_mem_axi128_packer #(
    parameter integer FIFO_DEPTH = 8,
    parameter bit PACK_ENABLE = 1'b1
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       req_valid,
    output logic                       req_ready,
    input  logic                       req_flush,
    input  logic                       req_write,
    input  logic [31:0]                req_addr,
    input  logic [63:0]                req_wdata,
    input  logic [7:0]                 req_wstrb,

    output logic                       rsp_valid,
    input  logic                       rsp_ready,
    output logic                       rsp_error,
    output logic [63:0]                rsp_rdata,

    output logic [31:0]                m_axi_awaddr,
    output logic [7:0]                 m_axi_awlen,
    output logic [2:0]                 m_axi_awsize,
    output logic [1:0]                 m_axi_awburst,
    output logic                       m_axi_awvalid,
    input  logic                       m_axi_awready,

    output logic [127:0]               m_axi_wdata,
    output logic [15:0]                m_axi_wstrb,
    output logic                       m_axi_wlast,
    output logic                       m_axi_wvalid,
    input  logic                       m_axi_wready,

    input  logic [1:0]                 m_axi_bresp,
    input  logic                       m_axi_bvalid,
    output logic                       m_axi_bready,

    output logic [31:0]                m_axi_araddr,
    output logic [7:0]                 m_axi_arlen,
    output logic [2:0]                 m_axi_arsize,
    output logic [1:0]                 m_axi_arburst,
    output logic                       m_axi_arvalid,
    input  logic                       m_axi_arready,

    input  logic [127:0]               m_axi_rdata,
    input  logic [1:0]                 m_axi_rresp,
    input  logic                       m_axi_rlast,
    input  logic                       m_axi_rvalid,
    output logic                       m_axi_rready,

    output logic                       perf_busy,
    output logic [63:0]                perf_req_accept_count,
    output logic [63:0]                perf_axi_beat_count,
    output logic [63:0]                perf_packed_pair_count,
    output logic [63:0]                perf_rsp_count,
    output logic [63:0]                perf_error_count,
    output logic [3:0]                 perf_queue_occupancy,
    output logic [3:0]                 perf_max_queue_occupancy
);

    localparam integer PTR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer CNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_AR,
        ST_READ_R,
        ST_WRITE,
        ST_RESP
    } state_t;

    state_t state_q;

    logic                 q_write [0:FIFO_DEPTH-1];
    logic [31:0]          q_addr  [0:FIFO_DEPTH-1];
    logic [63:0]          q_data  [0:FIFO_DEPTH-1];
    logic [7:0]           q_strb  [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0]     q_head_q, q_tail_q;
    logic [CNT_W-1:0]     q_count_q;

    logic                 tx_write_q;
    logic [31:0]          tx_base_addr_q;
    logic [1:0]           tx_count_q;
    logic                 tx_lane_first_q;
    logic                 tx_lane_second_q;
    logic [127:0]         tx_wdata_q;
    logic [15:0]          tx_wstrb_q;
    logic                 tx_local_error_q;
    logic                 tx_aw_done_q, tx_w_done_q;

    logic [1:0]           rsp_count_q;
    logic                 rsp_first_lane_q;
    logic                 rsp_second_lane_q;
    logic [127:0]         rsp_data_q;
    logic                 rsp_error_q;

    logic                 pair_candidate;
    logic                 start_tx;
    logic [1:0]           start_count;
    logic                 enqueue_fire;
    logic [1:0]           dequeue_count;
    logic                 dequeue_fire;
    logic [PTR_W-1:0]     q_next_index;

    function automatic logic [PTR_W-1:0] ptr_add(
        input logic [PTR_W-1:0] ptr,
        input integer step
    );
        integer tmp;
        begin
            tmp = ptr + step;
            // The only callers advance by one (enqueue) or two (a packed
            // dequeue).  Keep the wrap bounded so synthesis can prove the
            // loop-free hardware; the previous unbounded while form made
            // Vivado report a non-convergent synthesis loop.
            if (tmp >= FIFO_DEPTH)
                tmp = tmp - FIFO_DEPTH;
            if (tmp >= FIFO_DEPTH)
                tmp = tmp - FIFO_DEPTH;
            ptr_add = tmp[PTR_W-1:0];
        end
    endfunction

    assign q_next_index = ptr_add(q_head_q, 1);

    // A pair can be issued as one AXI beat only if both entries are complete
    // 64-bit halves of the same aligned 16-byte location.
    always_comb begin
        pair_candidate = 1'b0;
        if (PACK_ENABLE && (q_count_q >= 2)) begin
            pair_candidate =
                (q_addr[q_head_q][2:0] == 3'b000) &&
                (q_addr[q_next_index][2:0] == 3'b000) &&
                (q_addr[q_head_q][31:4] == q_addr[q_next_index][31:4]) &&
                (q_addr[q_head_q][3] != q_addr[q_next_index][3]) &&
                (q_write[q_head_q] == q_write[q_next_index]);
        end

        // With one entry we wait for a possible partner unless the producer
        // explicitly flushes the stream.  With two or more non-pairable
        // entries, issue the head so a bad/mismatched request cannot block the
        // FIFO indefinitely.
        start_tx = (state_q == ST_IDLE) && (rsp_count_q == 0) &&
                   (q_count_q != 0) &&
                   (pair_candidate || (q_count_q >= 2) || req_flush);
        start_count = pair_candidate ? 2'd2 : 2'd1;
        dequeue_count = start_tx ? start_count : 2'd0;
        dequeue_fire = start_tx;
    end

    assign req_ready = (q_count_q < FIFO_DEPTH);
    assign enqueue_fire = req_valid && req_ready;

    always_comb begin
        m_axi_awaddr  = tx_base_addr_q;
        m_axi_awlen   = 8'd0;
        m_axi_awsize  = 3'd4;
        m_axi_awburst = 2'b01;
        m_axi_wdata   = tx_wdata_q;
        m_axi_wstrb   = tx_wstrb_q;
        m_axi_wlast   = 1'b1;
        m_axi_araddr  = tx_base_addr_q;
        m_axi_arlen   = 8'd0;
        m_axi_arsize  = 3'd4;
        m_axi_arburst = 2'b01;

        m_axi_awvalid = (state_q == ST_WRITE) && !tx_local_error_q &&
                        !tx_aw_done_q;
        m_axi_wvalid  = (state_q == ST_WRITE) && !tx_local_error_q &&
                        !tx_w_done_q;
        m_axi_bready  = (state_q == ST_WRITE) && !tx_local_error_q &&
                        tx_aw_done_q && tx_w_done_q;
        m_axi_arvalid = (state_q == ST_READ_AR) && !tx_local_error_q;
        m_axi_rready  = (state_q == ST_READ_R) && !tx_local_error_q;

        rsp_valid = (rsp_count_q != 0);
        rsp_error = rsp_error_q;
        if (rsp_count_q == 2) begin
            rsp_rdata = rsp_first_lane_q ? rsp_data_q[127:64] :
                                             rsp_data_q[63:0];
        end else begin
            rsp_rdata = rsp_first_lane_q ? rsp_data_q[127:64] :
                                             rsp_data_q[63:0];
        end

        perf_busy = (state_q != ST_IDLE) || (rsp_count_q != 0) ||
                    (q_count_q != 0);
        perf_queue_occupancy = q_count_q[3:0];
    end

    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire  = m_axi_wvalid  && m_axi_wready;
    wire b_fire  = m_axi_bvalid  && m_axi_bready;
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire  = m_axi_rvalid  && m_axi_rready;
    wire rsp_fire = rsp_valid && rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            q_head_q <= '0;
            q_tail_q <= '0;
            q_count_q <= '0;
            tx_write_q <= 1'b0;
            tx_base_addr_q <= 32'd0;
            tx_count_q <= 2'd0;
            tx_lane_first_q <= 1'b0;
            tx_lane_second_q <= 1'b0;
            tx_wdata_q <= 128'd0;
            tx_wstrb_q <= 16'd0;
            tx_local_error_q <= 1'b0;
            tx_aw_done_q <= 1'b0;
            tx_w_done_q <= 1'b0;
            rsp_count_q <= 2'd0;
            rsp_first_lane_q <= 1'b0;
            rsp_second_lane_q <= 1'b0;
            rsp_data_q <= 128'd0;
            rsp_error_q <= 1'b0;
            perf_req_accept_count <= 64'd0;
            perf_axi_beat_count <= 64'd0;
            perf_packed_pair_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_error_count <= 64'd0;
            perf_max_queue_occupancy <= 4'd0;
        end else begin
            // FIFO enqueue.  A full FIFO deliberately backpressures; this
            // avoids a simultaneous enqueue/dequeue corner case and keeps the
            // prototype easy to insert behind an eventual stream FIFO.
            if (enqueue_fire) begin
                q_write[q_tail_q] <= req_write;
                q_addr[q_tail_q]  <= req_addr;
                q_data[q_tail_q]  <= req_wdata;
                q_strb[q_tail_q]  <= req_wstrb;
                q_tail_q <= ptr_add(q_tail_q, 1);
                perf_req_accept_count <= perf_req_accept_count + 1'b1;
            end

            if (dequeue_fire) begin
                q_head_q <= ptr_add(q_head_q, dequeue_count);
            end

            case ({enqueue_fire, dequeue_fire})
                2'b10: q_count_q <= q_count_q + 1'b1;
                2'b01: q_count_q <= q_count_q - dequeue_count;
                2'b11: q_count_q <= q_count_q + 1'b1 - dequeue_count;
                default: q_count_q <= q_count_q;
            endcase

            if (enqueue_fire &&
                ((q_count_q + 1'b1) > perf_max_queue_occupancy))
                perf_max_queue_occupancy <= q_count_q + 1'b1;

            if (start_tx) begin
                tx_write_q <= q_write[q_head_q];
                tx_base_addr_q <= {q_addr[q_head_q][31:4], 4'b0000};
                tx_count_q <= start_count;
                tx_local_error_q <= (q_addr[q_head_q][2:0] != 3'b000);
                tx_aw_done_q <= 1'b0;
                tx_w_done_q <= 1'b0;
                tx_lane_first_q <= q_addr[q_head_q][3];
                tx_lane_second_q <= q_addr[q_head_q][3];
                tx_wdata_q <= 128'd0;
                tx_wstrb_q <= 16'd0;

                if (q_addr[q_head_q][3] == 1'b0) begin
                    tx_wdata_q[63:0] <= q_data[q_head_q];
                    tx_wstrb_q[7:0] <= q_strb[q_head_q];
                end else begin
                    tx_wdata_q[127:64] <= q_data[q_head_q];
                    tx_wstrb_q[15:8] <= q_strb[q_head_q];
                end

                if (pair_candidate) begin
                    tx_lane_second_q <= q_addr[q_next_index][3];
                    if (q_addr[q_next_index][3] == 1'b0) begin
                        tx_wdata_q[63:0] <= q_data[q_next_index];
                        tx_wstrb_q[7:0] <= q_strb[q_next_index];
                    end else begin
                        tx_wdata_q[127:64] <= q_data[q_next_index];
                        tx_wstrb_q[15:8] <= q_strb[q_next_index];
                    end
                end

                if (pair_candidate)
                    perf_packed_pair_count <= perf_packed_pair_count + 1'b1;

                if ((q_addr[q_head_q][2:0] != 3'b000) ||
                    (pair_candidate &&
                     (q_addr[q_next_index][2:0] != 3'b000))) begin
                    // Misaligned local requests are completed locally.  A
                    // malformed second entry cannot pass pair_candidate, so
                    // this branch normally applies only to the head.
                    rsp_count_q <= start_count;
                    rsp_first_lane_q <= q_addr[q_head_q][3];
                    rsp_second_lane_q <= pair_candidate ?
                                         q_addr[q_next_index][3] :
                                         q_addr[q_head_q][3];
                    rsp_data_q <= 128'd0;
                    rsp_error_q <= 1'b1;
                    state_q <= ST_RESP;
                    perf_error_count <= perf_error_count + 1'b1;
                end else if (q_write[q_head_q]) begin
                    state_q <= ST_WRITE;
                    perf_axi_beat_count <= perf_axi_beat_count + 1'b1;
                end else begin
                    state_q <= ST_READ_AR;
                    perf_axi_beat_count <= perf_axi_beat_count + 1'b1;
                end
            end

            if (aw_fire)
                tx_aw_done_q <= 1'b1;
            if (w_fire)
                tx_w_done_q <= 1'b1;

            if (ar_fire)
                state_q <= ST_READ_R;

            if (r_fire) begin
                rsp_count_q <= tx_count_q;
                rsp_first_lane_q <= tx_lane_first_q;
                rsp_second_lane_q <= tx_lane_second_q;
                rsp_data_q <= m_axi_rdata;
                rsp_error_q <= (m_axi_rresp != 2'b00) || !m_axi_rlast;
                if ((m_axi_rresp != 2'b00) || !m_axi_rlast)
                    perf_error_count <= perf_error_count + 1'b1;
                state_q <= ST_RESP;
            end

            if (b_fire) begin
                rsp_count_q <= tx_count_q;
                rsp_first_lane_q <= tx_lane_first_q;
                rsp_second_lane_q <= tx_lane_second_q;
                rsp_data_q <= 128'd0;
                rsp_error_q <= (m_axi_bresp != 2'b00);
                if (m_axi_bresp != 2'b00)
                    perf_error_count <= perf_error_count + 1'b1;
                state_q <= ST_RESP;
            end

            if (rsp_fire) begin
                perf_rsp_count <= perf_rsp_count + 1'b1;
                if (rsp_count_q == 2) begin
                    rsp_count_q <= 1;
                    rsp_first_lane_q <= rsp_second_lane_q;
                end else begin
                    rsp_count_q <= 0;
                    state_q <= ST_IDLE;
                end
            end
        end
    end

endmodule
