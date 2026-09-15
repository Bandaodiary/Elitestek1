`timescale 1ns/1ps

// Two-client boardless read fabric.
//
// This is the first integration seam that connects the leaf 64-bit
// pack/burst clients to a fabric-level descriptor queue.  Each client keeps
// its own logical request/response ordering and packing metadata; the
// optional ID-less arbiter accepts their AXI AR descriptors, permits several
// descriptors to be in flight, and routes the ordered R stream back to the
// originating leaf.  No legacy portable-SoC top is changed by this module.
//
// The default parameters are deliberately modest for simulation and resource
// estimation.  A board integration can increase LEAF_MAX_OUTSTANDING and
// FABRIC_FIFO_DEPTH after the DDR controller's no-ID/ID ordering contract is
// confirmed.  If an existing serial arbiter is retained downstream, the
// effective outstanding count is still one; the wrapper makes that distinction
// visible through the fabric diagnostics rather than silently claiming MLP.
module c1_tensor_mem_axi128_read_fabric_2c #(
    parameter integer CLIENTS = 2,
    parameter integer LEAF_REQ_FIFO_DEPTH = 32,
    parameter integer LEAF_BURST_BEATS = 16,
    parameter integer LEAF_MAX_OUTSTANDING = 4,
    parameter integer LEAF_RSP_FIFO_DEPTH =
        2 * LEAF_BURST_BEATS * LEAF_MAX_OUTSTANDING,
    parameter integer FABRIC_FIFO_DEPTH = 8,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    // Optional response-record layout forwarded to every leaf.  The default
    // preserves the historical one-logical-response-per-FIFO-slot contract;
    // beat mode stores one complete AXI128 R beat and drains its lanes locally.
    parameter bit LEAF_RSP_FIFO_BEAT_MODE = 1'b0,
    // Optional leaf-level response FIFO pop/refill bypass.  Default remains
    // conservative because it feeds client rsp_ready into AXI RREADY.
    parameter bit LEAF_ALLOW_RSP_POP_REFILL = 1'b0,
    // Optional leaf-level request FIFO pop/refill bypass.  It removes a
    // producer bubble when a leaf request FIFO is full and the builder pops
    // its head in the same cycle.  Appended at the end to preserve existing
    // positional parameter instantiations; default remains conservative.
    parameter bit LEAF_ALLOW_REQ_POP_REFILL = 1'b0,
    // Optional empty-fabric fall-through for the first AR descriptor.  Keep
    // disabled by default because it adds a client AR payload -> downstream
    // AR path; later descriptors still use the registered descriptor queue.
    parameter bit EMPTY_AR_BYPASS = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic [CLIENTS-1:0]           req_valid,
    output logic [CLIENTS-1:0]           req_ready,
    input  logic [CLIENTS-1:0]           req_flush,
    input  logic [CLIENTS-1:0][31:0]     req_addr,

    output logic [CLIENTS-1:0]           rsp_valid,
    input  logic [CLIENTS-1:0]           rsp_ready,
    output logic [CLIENTS-1:0]           rsp_error,
    output logic [CLIENTS-1:0][63:0]     rsp_rdata,

    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    output logic                         protocol_error,
    output logic                         early_rlast_error,
    output logic                         missing_rlast_error,
    output logic                         orphan_r_error,
    output logic [63:0]                  perf_req_accept_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_packed_request_count,
    output logic [63:0]                  perf_error_count,
    output logic [7:0]                   perf_leaf_outstanding,
    output logic [7:0]                   perf_max_leaf_outstanding
);

    initial begin
        if (CLIENTS != 2)
            $fatal(1, "c1_tensor_mem_axi128_read_fabric_2c currently requires CLIENTS=2");
        if (FABRIC_FIFO_DEPTH < 2 || FABRIC_FIFO_DEPTH > 256)
            $fatal(1, "FABRIC_FIFO_DEPTH must be in 2..256");
        if (LEAF_RSP_FIFO_BEAT_MODE &&
            (LEAF_RSP_FIFO_DEPTH < (LEAF_BURST_BEATS * LEAF_MAX_OUTSTANDING)))
            $fatal(1, "beat-mode leaf response FIFO is too shallow");
    end

    logic [CLIENTS-1:0][31:0] leaf_araddr;
    logic [CLIENTS-1:0][7:0] leaf_arlen;
    logic [CLIENTS-1:0][2:0] leaf_arsize;
    logic [CLIENTS-1:0][1:0] leaf_arburst;
    logic [CLIENTS-1:0] leaf_arvalid;
    logic [CLIENTS-1:0] leaf_arready;
    logic [CLIENTS-1:0][127:0] leaf_rdata;
    logic [CLIENTS-1:0][1:0] leaf_rresp;
    logic [CLIENTS-1:0] leaf_rlast;
    logic [CLIENTS-1:0] leaf_rvalid;
    logic [CLIENTS-1:0] leaf_rready;

    logic [CLIENTS-1:0] leaf_busy;
    logic [CLIENTS-1:0][63:0] leaf_req_count;
    logic [CLIENTS-1:0][63:0] leaf_burst_count;
    logic [CLIENTS-1:0][63:0] leaf_beat_count;
    logic [CLIENTS-1:0][63:0] leaf_rsp_count;
    logic [CLIENTS-1:0][63:0] leaf_packed_count;
    logic [CLIENTS-1:0][63:0] leaf_error_count;
    logic [CLIENTS-1:0][7:0] leaf_outstanding;
    logic [CLIENTS-1:0][7:0] leaf_max_outstanding;

    genvar g;
    generate
        for (g = 0; g < CLIENTS; g = g + 1) begin : gen_leaf
            c1_tensor_mem_axi128_read_burst_client #(
                .REQ_FIFO_DEPTH(LEAF_REQ_FIFO_DEPTH),
                .BURST_BEATS(LEAF_BURST_BEATS),
                .MAX_OUTSTANDING(LEAF_MAX_OUTSTANDING),
                .RSP_FIFO_DEPTH(LEAF_RSP_FIFO_DEPTH),
                .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
                .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
                .RSP_FIFO_BEAT_MODE(LEAF_RSP_FIFO_BEAT_MODE),
                .ALLOW_RSP_POP_REFILL(LEAF_ALLOW_RSP_POP_REFILL),
                .ALLOW_REQ_POP_REFILL(LEAF_ALLOW_REQ_POP_REFILL)
            ) u_leaf (
                .clk, .rst,
                .req_valid(req_valid[g]), .req_ready(req_ready[g]),
                .req_flush(req_flush[g]), .req_addr(req_addr[g]),
                .rsp_valid(rsp_valid[g]), .rsp_ready(rsp_ready[g]),
                .rsp_error(rsp_error[g]), .rsp_rdata(rsp_rdata[g]),
                .m_axi_araddr(leaf_araddr[g]),
                .m_axi_arlen(leaf_arlen[g]),
                .m_axi_arsize(leaf_arsize[g]),
                .m_axi_arburst(leaf_arburst[g]),
                .m_axi_arvalid(leaf_arvalid[g]),
                .m_axi_arready(leaf_arready[g]),
                .m_axi_rdata(leaf_rdata[g]),
                .m_axi_rresp(leaf_rresp[g]),
                .m_axi_rlast(leaf_rlast[g]),
                .m_axi_rvalid(leaf_rvalid[g]),
                .m_axi_rready(leaf_rready[g]),
                .perf_busy(leaf_busy[g]),
                .perf_req_accept_count(leaf_req_count[g]),
                .perf_axi_burst_count(leaf_burst_count[g]),
                .perf_axi_beat_count(leaf_beat_count[g]),
                .perf_rsp_count(leaf_rsp_count[g]),
                .perf_packed_request_count(leaf_packed_count[g]),
                .perf_error_count(leaf_error_count[g]),
                .perf_req_occupancy(), .perf_max_req_occupancy(),
                .perf_outstanding(leaf_outstanding[g]),
                .perf_max_outstanding(leaf_max_outstanding[g])
            );
        end
    endgenerate

    c1_axi_n_read_burst_arbiter_128 #(
        .CLIENTS(CLIENTS), .FIFO_DEPTH(FABRIC_FIFO_DEPTH),
        .EMPTY_AR_BYPASS(EMPTY_AR_BYPASS)
    ) u_fabric (
        .clk, .rst,
        .s_araddr(leaf_araddr), .s_arlen(leaf_arlen),
        .s_arsize(leaf_arsize), .s_arburst(leaf_arburst),
        .s_arvalid(leaf_arvalid), .s_arready(leaf_arready),
        .s_rdata(leaf_rdata), .s_rresp(leaf_rresp),
        .s_rlast(leaf_rlast), .s_rvalid(leaf_rvalid),
        .s_rready(leaf_rready),
        .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst),
        .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready),
        .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast), .m_rvalid(m_axi_rvalid),
        .m_rready(m_axi_rready),
        .protocol_error, .early_rlast_error,
        .missing_rlast_error, .orphan_r_error
    );

    integer sum_i;
    logic [64:0] sum_req_w, sum_burst_w, sum_beat_w, sum_rsp_w;
    logic [64:0] sum_pack_w, sum_err_w, sum_out_w;
    logic [7:0] max_leaf_w;
    always_comb begin
        sum_req_w = 65'd0;
        sum_burst_w = 65'd0;
        sum_beat_w = 65'd0;
        sum_rsp_w = 65'd0;
        sum_pack_w = 65'd0;
        sum_err_w = 65'd0;
        sum_out_w = 65'd0;
        max_leaf_w = 8'd0;
        for (sum_i = 0; sum_i < CLIENTS; sum_i = sum_i + 1) begin
            sum_req_w = sum_req_w + {1'b0, leaf_req_count[sum_i]};
            sum_burst_w = sum_burst_w + {1'b0, leaf_burst_count[sum_i]};
            sum_beat_w = sum_beat_w + {1'b0, leaf_beat_count[sum_i]};
            sum_rsp_w = sum_rsp_w + {1'b0, leaf_rsp_count[sum_i]};
            sum_pack_w = sum_pack_w + {1'b0, leaf_packed_count[sum_i]};
            sum_err_w = sum_err_w + {1'b0, leaf_error_count[sum_i]};
            sum_out_w = sum_out_w + {57'd0, leaf_outstanding[sum_i]};
            if (leaf_max_outstanding[sum_i] > max_leaf_w)
                max_leaf_w = leaf_max_outstanding[sum_i];
        end
        perf_req_accept_count = sum_req_w[63:0];
        perf_axi_burst_count = sum_burst_w[63:0];
        perf_axi_beat_count = sum_beat_w[63:0];
        perf_rsp_count = sum_rsp_w[63:0];
        perf_packed_request_count = sum_pack_w[63:0];
        perf_error_count = sum_err_w[63:0];
        perf_leaf_outstanding = (sum_out_w > 65'd255) ? 8'hff : sum_out_w[7:0];
        perf_max_leaf_outstanding = max_leaf_w;
    end

endmodule
