`timescale 1ns/1ps

// Selectable boardless memory seam for the tensor adapter.
//
// PERF_MODE=0 preserves the production correctness bridge exactly: one
// accepted 64-bit request has one response and no request is withdrawn.
// PERF_MODE=1 selects the FIFO/16-byte coalescer prototype.  The local
// request/response ABI is intentionally identical, so an adapter-side
// prefetch/cache can be developed against this seam without changing the
// descriptor format or the legacy bridge tests.
//
// flush_req is a high-level, level-sensitive request.  The seam latches it
// until the selected path becomes quiescent, then emits a one-cycle
// flush_done.  This prevents a one-cycle pulse from being lost while an AXI
// transaction or response is in flight.  Abort remains an adapter-level drain
// contract in this revision: the adapter must not withdraw an accepted
// request, and a future multi-outstanding implementation must add an explicit
// abort-drain state before it is enabled in the SoC.
module c1_tensor_mem_path_seam #(
    parameter bit     PERF_MODE  = 1'b0,
    parameter integer FIFO_DEPTH = 8,
    parameter bit     PACK_ENABLE = 1'b1
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       req_valid,
    output logic                       req_ready,
    input  logic                       flush_req,
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
    output logic [3:0]                 perf_max_queue_occupancy,
    output logic                       flush_done,
    output logic                       quiescent
);

    logic path_busy;
    logic flush_pending_q;
    logic flush_done_q;
    logic packer_flush;

    assign packer_flush = PERF_MODE && (flush_req || flush_pending_q);
    assign flush_done = flush_done_q;
    assign quiescent = !path_busy && !flush_pending_q && !flush_req;

    generate
        if (PERF_MODE) begin : g_perf_path
            c1_tensor_mem_axi128_packer #(
                .FIFO_DEPTH(FIFO_DEPTH),
                .PACK_ENABLE(PACK_ENABLE)
            ) u_packer (
                .clk(clk), .rst(rst),
                .req_valid(req_valid), .req_ready(req_ready),
                .req_flush(packer_flush), .req_write(req_write),
                .req_addr(req_addr), .req_wdata(req_wdata),
                .req_wstrb(req_wstrb),
                .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
                .rsp_error(rsp_error), .rsp_rdata(rsp_rdata),
                .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
                .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
                .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
                .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
                .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
                .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
                .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
                .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
                .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
                .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
                .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
                .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
                .m_axi_rready(m_axi_rready), .perf_busy(path_busy),
                .perf_req_accept_count(perf_req_accept_count),
                .perf_axi_beat_count(perf_axi_beat_count),
                .perf_packed_pair_count(perf_packed_pair_count),
                .perf_rsp_count(perf_rsp_count),
                .perf_error_count(perf_error_count),
                .perf_queue_occupancy(perf_queue_occupancy),
                .perf_max_queue_occupancy(perf_max_queue_occupancy)
            );
        end else begin : g_legacy_path
            c1_tensor_mem_axi128_bridge u_bridge (
                .clk(clk), .rst(rst),
                .read_cache_invalidate(1'b0),
                .mem_req_valid(req_valid), .mem_req_ready(req_ready),
                .mem_req_write(req_write), .mem_req_addr(req_addr),
                .mem_req_wdata(req_wdata), .mem_req_wstrb(req_wstrb),
                .mem_rsp_valid(rsp_valid), .mem_rsp_ready(rsp_ready),
                .mem_rsp_error(rsp_error), .mem_rsp_rdata(rsp_rdata),
                .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
                .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
                .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
                .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
                .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
                .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
                .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
                .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
                .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
                .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
                .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
                .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
                .m_axi_rready(m_axi_rready)
            );

            // The legacy bridge has no performance counters.  Exposing zeros
            // keeps the seam ABI stable and makes software/testbench probing
            // independent of the selected implementation.
            always_comb begin
                path_busy = req_valid || rsp_valid ||
                            m_axi_awvalid || m_axi_wvalid ||
                            m_axi_bready || m_axi_arvalid || m_axi_rready;
                perf_req_accept_count = 64'd0;
                perf_axi_beat_count = 64'd0;
                perf_packed_pair_count = 64'd0;
                perf_rsp_count = 64'd0;
                perf_error_count = 64'd0;
                perf_queue_occupancy = 4'd0;
                perf_max_queue_occupancy = 4'd0;
            end
        end
    endgenerate

    // Flush bookkeeping is deliberately outside the generate branches so the
    // local control ABI is identical in legacy and performance builds.  The
    // legacy bridge is already single-transaction; acknowledging a flush
    // there is therefore just a quiescence observation.
    always_ff @(posedge clk) begin
        if (rst) begin
            flush_pending_q <= 1'b0;
            flush_done_q <= 1'b0;
        end else begin
            flush_done_q <= 1'b0;
            if (flush_req)
                flush_pending_q <= 1'b1;
            if (flush_pending_q && !path_busy && !req_valid) begin
                flush_pending_q <= 1'b0;
                flush_done_q <= 1'b1;
            end
            if (!PERF_MODE && flush_req && !path_busy && !req_valid) begin
                flush_pending_q <= 1'b0;
                flush_done_q <= 1'b1;
            end
        end
    end

    // Keep the public busy output driven from the common path status.  The
    // performance branch supplies path_busy from the packer; the legacy branch
    // computes it locally above.
    always_comb begin
        perf_busy = path_busy;
    end

endmodule
