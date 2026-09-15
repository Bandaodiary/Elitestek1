`timescale 1ns/1ps

// Optional boardless integration seam for the logical write MLP adapter.
//
// Client 0 is the 64-bit logical stream front end:
//
//   logical descriptor/words -> pack2 -> c1_axi128_write_mlp -> AXI128
//
// Client 1 is a raw, already-packed AXI128 writer.  Both clients share the
// ID-less c1_axi_n_write_burst_arbiter_128.  AW descriptors may therefore be
// accepted and issued ahead of the current W/B head, while W and B remain in
// descriptor order.  This is deliberately a seam rather than a change to the
// portable SoC: it makes the missing integration contract measurable before
// the real tensor client, seven-client QoS and Ti60 DDR are available.
module c1_tensor_mem_axi128_write_mlp_fabric_2c #(
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer MAX_BEATS = 16,
    parameter integer ADAPTER_RSP_FIFO_DEPTH = MAX_OUTSTANDING,
    parameter integer TAG_WIDTH = 16,
    parameter integer FABRIC_FIFO_DEPTH = MAX_OUTSTANDING + 2,
    // Optional end-to-end adapter/backend AW-ahead mode.  The default keeps
    // the adapter's conservative command/payload boundary.
    parameter bit ISSUE_AW_BEFORE_PAYLOAD = 1'b0,
    // Optional response-FIFO pop/refill forwarding.  Default zero preserves
    // the registered-space timing contract at the adapter/backend seam.
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Client 0: logical 64-bit descriptor and payload stream.
    input  logic                         adapter_cmd_valid,
    output logic                         adapter_cmd_ready,
    input  logic [31:0]                  adapter_cmd_addr,
    input  logic [9:0]                   adapter_cmd_logical_count,
    input  logic                         adapter_req_valid,
    output logic                         adapter_req_ready,
    input  logic                         adapter_req_last,
    input  logic                         adapter_req_flush,
    input  logic [31:0]                  adapter_req_addr,
    input  logic [63:0]                  adapter_req_wdata,
    input  logic [7:0]                   adapter_req_wstrb,
    output logic                         adapter_rsp_valid,
    input  logic                         adapter_rsp_ready,
    output logic                         adapter_rsp_error,
    output logic [63:0]                  adapter_rsp_rdata,
    output logic [TAG_WIDTH-1:0]         adapter_rsp_tag,

    // Client 1: raw AXI128 writer.  The peer must obey the AXI VALID hold
    // contract; the arbiter supplies peer_awready/peer_wready and routes B.
    input  logic [31:0]                  peer_awaddr,
    input  logic [7:0]                   peer_awlen,
    input  logic [2:0]                   peer_awsize,
    input  logic [1:0]                   peer_awburst,
    input  logic                         peer_awvalid,
    output logic                         peer_awready,
    input  logic [127:0]                 peer_wdata,
    input  logic [15:0]                  peer_wstrb,
    input  logic                         peer_wlast,
    input  logic                         peer_wvalid,
    output logic                         peer_wready,
    output logic [1:0]                   peer_bresp,
    output logic                         peer_bvalid,
    input  logic                         peer_bready,

    // Shared AXI128 master.
    output logic [31:0]                  m_axi_awaddr,
    output logic [7:0]                   m_axi_awlen,
    output logic [2:0]                   m_axi_awsize,
    output logic [1:0]                   m_axi_awburst,
    output logic                         m_axi_awvalid,
    input  logic                         m_axi_awready,
    output logic [127:0]                 m_axi_wdata,
    output logic [15:0]                  m_axi_wstrb,
    output logic                         m_axi_wlast,
    output logic                         m_axi_wvalid,
    input  logic                         m_axi_wready,
    input  logic [1:0]                   m_axi_bresp,
    input  logic                         m_axi_bvalid,
    output logic                         m_axi_bready,

    // Adapter diagnostics are exposed separately from fabric diagnostics so
    // a boardless scoreboard can distinguish local framing errors from a
    // shared-bus protocol fault.
    output logic                         adapter_protocol_error,
    output logic                         adapter_early_req_last_error,
    output logic                         adapter_late_req_last_error,
    output logic                         adapter_req_flush_error,
    output logic                         adapter_orphan_req_error,
    output logic                         adapter_request_address_error,
    output logic                         fabric_protocol_error,
    output logic                         fabric_early_wlast_error,
    output logic                         fabric_missing_wlast_error,
    output logic                         fabric_early_b_error,
    output logic                         fabric_orphan_b_error,
    output logic                         protocol_error,

    // Compact performance counters.  Adapter counters count logical/packed
    // work; fabric counters count shared-bus descriptor/beat events.
    output logic [63:0]                  perf_adapter_cmd_count,
    output logic [63:0]                  perf_adapter_logical_req_count,
    output logic [63:0]                  perf_adapter_burst_count,
    output logic [63:0]                  perf_adapter_axi_beat_count,
    output logic [63:0]                  perf_adapter_rsp_count,
    output logic [63:0]                  perf_adapter_packed_pair_count,
    output logic [7:0]                   perf_adapter_max_outstanding,
    output logic [7:0]                   perf_fabric_outstanding,
    output logic [7:0]                   perf_fabric_max_outstanding,
    output logic [63:0]                  perf_fabric_aw_accept_count,
    output logic [63:0]                  perf_fabric_aw_issue_count,
    output logic [63:0]                  perf_fabric_w_beat_count,
    output logic [63:0]                  perf_fabric_b_count
);

    localparam integer CLIENTS = 2;
    localparam integer INDEX_W = 1;

    logic [31:0] adapter_awaddr;
    logic [7:0] adapter_awlen;
    logic [2:0] adapter_awsize;
    logic [1:0] adapter_awburst;
    logic adapter_awvalid, adapter_awready;
    logic [127:0] adapter_wdata;
    logic [15:0] adapter_wstrb;
    logic adapter_wlast, adapter_wvalid, adapter_wready;
    logic [1:0] adapter_bresp;
    logic adapter_bvalid, adapter_bready;

    logic [1:0][31:0]  s_awaddr;
    logic [1:0][7:0]   s_awlen;
    logic [1:0][2:0]   s_awsize;
    logic [1:0][1:0]   s_awburst;
    logic [1:0]        s_awvalid, s_awready;
    logic [1:0][127:0] s_wdata;
    logic [1:0][15:0]  s_wstrb;
    logic [1:0]        s_wlast, s_wvalid, s_wready;
    logic [1:0][1:0]   s_bresp;
    logic [1:0]        s_bvalid, s_bready;

    logic arb_protocol_error;
    logic arb_early_wlast_error, arb_missing_wlast_error;
    logic arb_early_b_error, arb_orphan_b_error;

    // The packed adapter is client 0.
    c1_tensor_mem_axi128_write_mlp_adapter #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .MAX_BEATS(MAX_BEATS),
        .RSP_FIFO_DEPTH(ADAPTER_RSP_FIFO_DEPTH),
        .TAG_WIDTH(TAG_WIDTH),
        .ISSUE_AW_BEFORE_PAYLOAD(ISSUE_AW_BEFORE_PAYLOAD),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL)
    ) u_adapter (
        .clk(clk), .rst(rst),
        .cmd_valid(adapter_cmd_valid), .cmd_ready(adapter_cmd_ready),
        .cmd_addr(adapter_cmd_addr),
        .cmd_logical_count(adapter_cmd_logical_count),
        .req_valid(adapter_req_valid), .req_ready(adapter_req_ready),
        .req_last(adapter_req_last), .req_flush(adapter_req_flush),
        .req_addr(adapter_req_addr), .req_wdata(adapter_req_wdata),
        .req_wstrb(adapter_req_wstrb),
        .rsp_valid(adapter_rsp_valid), .rsp_ready(adapter_rsp_ready),
        .rsp_error(adapter_rsp_error), .rsp_rdata(adapter_rsp_rdata),
        .rsp_tag(adapter_rsp_tag),
        .m_axi_awaddr(adapter_awaddr), .m_axi_awlen(adapter_awlen),
        .m_axi_awsize(adapter_awsize), .m_axi_awburst(adapter_awburst),
        .m_axi_awvalid(adapter_awvalid), .m_axi_awready(adapter_awready),
        .m_axi_wdata(adapter_wdata), .m_axi_wstrb(adapter_wstrb),
        .m_axi_wlast(adapter_wlast), .m_axi_wvalid(adapter_wvalid),
        .m_axi_wready(adapter_wready), .m_axi_bresp(adapter_bresp),
        .m_axi_bvalid(adapter_bvalid), .m_axi_bready(adapter_bready),
        .protocol_error(adapter_protocol_error),
        .early_req_last_error(adapter_early_req_last_error),
        .late_req_last_error(adapter_late_req_last_error),
        .req_flush_error(adapter_req_flush_error),
        .orphan_req_error(adapter_orphan_req_error),
        .request_address_error(adapter_request_address_error),
        .perf_busy(), .perf_cmd_accept_count(perf_adapter_cmd_count),
        .perf_logical_req_count(perf_adapter_logical_req_count),
        .perf_axi_burst_count(perf_adapter_burst_count),
        .perf_axi_beat_count(perf_adapter_axi_beat_count),
        .perf_rsp_count(perf_adapter_rsp_count),
        .perf_packed_pair_count(perf_adapter_packed_pair_count),
        .perf_error_count(), .perf_cmd_occupancy(),
        .perf_max_cmd_occupancy(),
        .perf_outstanding(),
        .perf_max_outstanding(perf_adapter_max_outstanding)
    );

    // Client 1 is intentionally a transparent raw AXI writer.
    assign s_awaddr[0] = adapter_awaddr;
    assign s_awlen[0] = adapter_awlen;
    assign s_awsize[0] = adapter_awsize;
    assign s_awburst[0] = adapter_awburst;
    assign s_awvalid[0] = adapter_awvalid;
    assign adapter_awready = s_awready[0];
    assign s_wdata[0] = adapter_wdata;
    assign s_wstrb[0] = adapter_wstrb;
    assign s_wlast[0] = adapter_wlast;
    assign s_wvalid[0] = adapter_wvalid;
    assign adapter_wready = s_wready[0];
    assign adapter_bresp = s_bresp[0];
    assign adapter_bvalid = s_bvalid[0];
    assign s_bready[0] = adapter_bready;

    assign s_awaddr[1] = peer_awaddr;
    assign s_awlen[1] = peer_awlen;
    assign s_awsize[1] = peer_awsize;
    assign s_awburst[1] = peer_awburst;
    assign s_awvalid[1] = peer_awvalid;
    assign peer_awready = s_awready[1];
    assign s_wdata[1] = peer_wdata;
    assign s_wstrb[1] = peer_wstrb;
    assign s_wlast[1] = peer_wlast;
    assign s_wvalid[1] = peer_wvalid;
    assign peer_wready = s_wready[1];
    assign peer_bresp = s_bresp[1];
    assign peer_bvalid = s_bvalid[1];
    assign s_bready[1] = peer_bready;

    c1_axi_n_write_burst_arbiter_128 #(
        .CLIENTS(CLIENTS),
        .FIFO_DEPTH(FABRIC_FIFO_DEPTH),
        .INDEX_W(INDEX_W)
    ) u_fabric (
        .clk(clk), .rst(rst),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .m_awaddr(m_axi_awaddr), .m_awlen(m_axi_awlen),
        .m_awsize(m_axi_awsize), .m_awburst(m_axi_awburst),
        .m_awvalid(m_axi_awvalid), .m_awready(m_axi_awready),
        .m_wdata(m_axi_wdata), .m_wstrb(m_axi_wstrb),
        .m_wlast(m_axi_wlast), .m_wvalid(m_axi_wvalid),
        .m_wready(m_axi_wready), .m_bresp(m_axi_bresp),
        .m_bvalid(m_axi_bvalid), .m_bready(m_axi_bready),
        .protocol_error(arb_protocol_error),
        .early_wlast_error(arb_early_wlast_error),
        .missing_wlast_error(arb_missing_wlast_error),
        .early_b_error(arb_early_b_error),
        .orphan_b_error(arb_orphan_b_error),
        .perf_outstanding(perf_fabric_outstanding),
        .perf_max_outstanding(perf_fabric_max_outstanding),
        .perf_aw_accept_count(perf_fabric_aw_accept_count),
        .perf_aw_issue_count(perf_fabric_aw_issue_count),
        .perf_w_beat_count(perf_fabric_w_beat_count),
        .perf_b_count(perf_fabric_b_count)
    );

    assign fabric_protocol_error = arb_protocol_error;
    assign fabric_early_wlast_error = arb_early_wlast_error;
    assign fabric_missing_wlast_error = arb_missing_wlast_error;
    assign fabric_early_b_error = arb_early_b_error;
    assign fabric_orphan_b_error = arb_orphan_b_error;
    assign protocol_error = adapter_protocol_error || arb_protocol_error;

endmodule
