`timescale 1ns/1ps

// Optional integration shell for the shared ID-less AXI4-128 path.
//
// The shell keeps the existing serial arbiter as the sole AXI data-path
// owner and places c1_axi_shared_owner_epoch_fence in front of its address
// admissions.  It is deliberately not instantiated by the default SoC yet:
// this module is a boardless integration seam used to prove that a fence can
// stop a new owner without withdrawing VALID from an owner already selected
// by the arbiter.
//
// During a fence, a currently selected read/write owner is still allowed to
// present its held address/data/response signals.  All other client VALID
// signals are masked until both arbiter directions quiesce.  The downstream
// AXI interface and the client READY/response interface retain the exact
// c1_axi_n_serial_arbiter_128 ABI.
module c1_axi_shared_owner_epoch_arbiter_128 #(
    parameter integer CLIENTS = 6,
    parameter integer INDEX_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
    parameter integer READ_RESPONSE_SKID = 0,
    parameter integer EPOCH_W = 4,
    parameter bit REQUIRE_CONTEXT = 1'b1,
    parameter bit ALLOW_RESTART = 1'b1
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic [CLIENTS-1:0][31:0]     s_awaddr,
    input  logic [CLIENTS-1:0][7:0]      s_awlen,
    input  logic [CLIENTS-1:0][2:0]      s_awsize,
    input  logic [CLIENTS-1:0][1:0]      s_awburst,
    input  logic [CLIENTS-1:0]           s_awvalid,
    output logic [CLIENTS-1:0]           s_awready,
    input  logic [CLIENTS-1:0][127:0]    s_wdata,
    input  logic [CLIENTS-1:0][15:0]     s_wstrb,
    input  logic [CLIENTS-1:0]           s_wlast,
    input  logic [CLIENTS-1:0]           s_wvalid,
    output logic [CLIENTS-1:0]           s_wready,
    output logic [CLIENTS-1:0][1:0]      s_bresp,
    output logic [CLIENTS-1:0]           s_bvalid,
    input  logic [CLIENTS-1:0]           s_bready,
    input  logic [CLIENTS-1:0][31:0]     s_araddr,
    input  logic [CLIENTS-1:0][7:0]      s_arlen,
    input  logic [CLIENTS-1:0][2:0]      s_arsize,
    input  logic [CLIENTS-1:0][1:0]      s_arburst,
    input  logic [CLIENTS-1:0]           s_arvalid,
    output logic [CLIENTS-1:0]           s_arready,
    output logic [CLIENTS-1:0][127:0]    s_rdata,
    output logic [CLIENTS-1:0][1:0]      s_rresp,
    output logic [CLIENTS-1:0]           s_rlast,
    output logic [CLIENTS-1:0]           s_rvalid,
    input  logic [CLIENTS-1:0]           s_rready,
    output logic [31:0]                  m_awaddr,
    output logic [7:0]                   m_awlen,
    output logic [2:0]                   m_awsize,
    output logic [1:0]                   m_awburst,
    output logic                         m_awvalid,
    input  logic                         m_awready,
    output logic [127:0]                 m_wdata,
    output logic [15:0]                  m_wstrb,
    output logic                         m_wlast,
    output logic                         m_wvalid,
    input  logic                         m_wready,
    input  logic [1:0]                   m_bresp,
    input  logic                         m_bvalid,
    output logic                         m_bready,
    output logic [31:0]                  m_araddr,
    output logic [7:0]                   m_arlen,
    output logic [2:0]                   m_arsize,
    output logic [1:0]                   m_arburst,
    output logic                         m_arvalid,
    input  logic                         m_arready,
    input  logic [127:0]                 m_rdata,
    input  logic [1:0]                   m_rresp,
    input  logic                         m_rlast,
    input  logic                         m_rvalid,
    output logic                         m_rready,

    input  logic                         context_start_valid,
    output logic                         context_start_ready,
    input  logic                         abort_req,
    input  logic                         flush_req,
    output logic                         context_active,
    output logic [EPOCH_W-1:0]           current_epoch,
    output logic                         fence_busy,
    output logic                         abort_done,
    output logic                         flush_done,
    output logic                         epoch_bump,
    output logic                         protocol_error,
    output logic [63:0]                  perf_fence_count,
    output logic [63:0]                  perf_abort_count,
    output logic [63:0]                  perf_flush_count,
    output logic                         read_busy,
    output logic                         read_quiescent,
    output logic                         write_busy,
    output logic                         write_quiescent,
    output logic [INDEX_W-1:0]           read_owner,
    output logic [INDEX_W-1:0]           write_owner,
    // Expose the fence decision and the actual downstream address accepts so
    // a future SoC/CSR wrapper does not need hierarchical probes.
    output logic                         read_admit,
    output logic                         write_admit,
    output logic                         read_fire,
    output logic                         write_fire
);

    logic [CLIENTS-1:0] arb_s_awvalid;
    logic [CLIENTS-1:0] arb_s_wvalid;
    logic [CLIENTS-1:0] arb_s_arvalid;

    // Keep the selected owner alive while it drains.  A client that has not
    // yet been selected is admitted only while the fence is open.
    generate
        for (genvar i = 0; i < CLIENTS; i = i + 1) begin : g_owner_gate
            localparam logic [INDEX_W-1:0] CLIENT_INDEX = i;
            assign arb_s_awvalid[i] = s_awvalid[i] &&
                (write_admit || (write_busy &&
                                 (write_owner == CLIENT_INDEX)));
            assign arb_s_wvalid[i] = s_wvalid[i] &&
                (write_busy && (write_owner == CLIENT_INDEX));
            assign arb_s_arvalid[i] = s_arvalid[i] &&
                (read_admit || (read_busy &&
                                (read_owner == CLIENT_INDEX)));
        end
    endgenerate

    c1_axi_n_serial_arbiter_128 #(
        .CLIENTS(CLIENTS),
        .INDEX_W(INDEX_W),
        .READ_RESPONSE_SKID(READ_RESPONSE_SKID)
    ) u_arbiter (
        .clk(clk),
        .rst(rst),
        .s_awaddr(s_awaddr),
        .s_awlen(s_awlen),
        .s_awsize(s_awsize),
        .s_awburst(s_awburst),
        .s_awvalid(arb_s_awvalid),
        .s_awready(s_awready),
        .s_wdata(s_wdata),
        .s_wstrb(s_wstrb),
        .s_wlast(s_wlast),
        .s_wvalid(arb_s_wvalid),
        .s_wready(s_wready),
        .s_bresp(s_bresp),
        .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr),
        .s_arlen(s_arlen),
        .s_arsize(s_arsize),
        .s_arburst(s_arburst),
        .s_arvalid(arb_s_arvalid),
        .s_arready(s_arready),
        .s_rdata(s_rdata),
        .s_rresp(s_rresp),
        .s_rlast(s_rlast),
        .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .m_awaddr(m_awaddr),
        .m_awlen(m_awlen),
        .m_awsize(m_awsize),
        .m_awburst(m_awburst),
        .m_awvalid(m_awvalid),
        .m_awready(m_awready),
        .m_wdata(m_wdata),
        .m_wstrb(m_wstrb),
        .m_wlast(m_wlast),
        .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bresp(m_bresp),
        .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_araddr(m_araddr),
        .m_arlen(m_arlen),
        .m_arsize(m_arsize),
        .m_arburst(m_arburst),
        .m_arvalid(m_arvalid),
        .m_arready(m_arready),
        .m_rdata(m_rdata),
        .m_rresp(m_rresp),
        .m_rlast(m_rlast),
        .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .read_busy(read_busy),
        .read_quiescent(read_quiescent),
        .write_busy(write_busy),
        .write_quiescent(write_quiescent),
        .read_owner(read_owner),
        .write_owner(write_owner)
    );

    assign read_fire = m_arvalid && m_arready;
    assign write_fire = m_awvalid && m_awready;

    c1_axi_shared_owner_epoch_fence #(
        .EPOCH_W(EPOCH_W),
        .REQUIRE_CONTEXT(REQUIRE_CONTEXT),
        .ALLOW_RESTART(ALLOW_RESTART)
    ) u_fence (
        .clk(clk),
        .rst(rst),
        .context_start_valid(context_start_valid),
        .context_start_ready(context_start_ready),
        .abort_req(abort_req),
        .flush_req(flush_req),
        .read_busy(read_busy),
        .read_quiescent(read_quiescent),
        .write_busy(write_busy),
        .write_quiescent(write_quiescent),
        .read_fire(read_fire),
        .write_fire(write_fire),
        .read_admit(read_admit),
        .write_admit(write_admit),
        .context_active(context_active),
        .current_epoch(current_epoch),
        .fence_busy(fence_busy),
        .abort_done(abort_done),
        .flush_done(flush_done),
        .epoch_bump(epoch_bump),
        .protocol_error(protocol_error),
        .perf_fence_count(perf_fence_count),
        .perf_abort_count(perf_abort_count),
        .perf_flush_count(perf_flush_count)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && fence_busy) begin
            // The wrapper must never expose a new idle-owner address while a
            // fence is draining.  The selected-owner exception is intentional
            // and is checked by the focused composition testbench.
            if (read_fire && !read_busy)
                $fatal(1, "read fire bypassed owner/epoch fence");
            if (write_fire && !write_busy)
                $fatal(1, "write fire bypassed owner/epoch fence");
        end
    end
`endif

endmodule
