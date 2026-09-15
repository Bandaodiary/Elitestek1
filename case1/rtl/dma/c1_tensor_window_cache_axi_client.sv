`timescale 1ns/1ps

// Board-independent tensor memory client boundary.
//
// This wrapper is the single owner of the optional window-cache insertion
// point and the 64-bit -> AXI4-128 bridge.  The AXI ports are intended to be
// connected to one slot of c1_axi_n_serial_arbiter_128; the portable SoC uses
// slot 6 (the seventh, zero-based client).  Keeping the seam here makes the
// client contract independently testable and prevents a future cache/bridge
// change from silently bypassing the shared-memory fabric.
//
// ENABLE_CACHE=0 is a wire-level adapter -> bridge bypass.  It is deliberately
// equivalent to the historical portable-SoC default, so enabling this wrapper
// does not alter reset or ready/valid behavior unless the cache is selected.
module c1_tensor_window_cache_axi_client #(
    parameter integer ENABLE_CACHE = 0,
    // Optional contract optimization for the cache-enabled branch.  The
    // seam's registered front end supplies saturated coordinates.
    parameter integer PRECLAMPED_TAP_COORDS = 0
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        stage_start_valid,
    output logic        stage_start_ready,
    input  logic        stage_cache_enable,
    input  logic [31:0] stage_base_addr,
    input  logic [15:0] stage_width,
    input  logic [15:0] stage_height,
    input  logic [3:0]  stage_groups,
    output logic        stage_start_done,
    output logic        stage_cache_active,
    output logic        stage_cache_fallback,
    output logic [3:0]  stage_cache_reason,

    input  logic        abort_req,
    output logic        abort_done,
    input  logic        flush_req,
    output logic        flush_done,

    input  logic        s_req_valid,
    output logic        s_req_ready,
    input  logic        s_req_write,
    input  logic [31:0] s_req_addr,
    input  logic [63:0] s_req_wdata,
    input  logic [7:0]  s_req_wstrb,
    input  logic        s_req_cacheable,
    input  logic signed [16:0] s_req_cache_x,
    input  logic signed [16:0] s_req_cache_y,
    input  logic [2:0]  s_req_cache_group,

    output logic        s_rsp_valid,
    input  logic        s_rsp_ready,
    output logic        s_rsp_error,
    output logic [63:0] s_rsp_rdata,

    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0]  m_axi_wstrb,
    output logic         m_axi_wlast,
    input  logic [1:0]   m_axi_bresp,
    input  logic         m_axi_bvalid,
    output logic         m_axi_bready,
    output logic         m_axi_arvalid,
    input  logic         m_axi_arready,
    output logic [31:0]  m_axi_araddr,
    output logic [7:0]   m_axi_arlen,
    output logic [2:0]   m_axi_arsize,
    output logic [1:0]   m_axi_arburst,
    input  logic [127:0] m_axi_rdata,
    input  logic [1:0]   m_axi_rresp,
    input  logic         m_axi_rlast,
    input  logic         m_axi_rvalid,
    output logic         m_axi_rready,

    output logic        cache_error,
    output logic [2:0]  cache_error_code,
    output logic        busy,
    output logic        quiescent
);

    logic bridge_mem_req_valid, bridge_mem_req_ready;
    logic bridge_mem_req_write;
    logic [31:0] bridge_mem_req_addr;
    logic [63:0] bridge_mem_req_wdata;
    logic [7:0] bridge_mem_req_wstrb;
    logic bridge_mem_rsp_valid, bridge_mem_rsp_ready;
    logic bridge_mem_rsp_error;
    logic [63:0] bridge_mem_rsp_rdata;

    generate
        if (ENABLE_CACHE != 0) begin : g_cache
            c1_tensor_window_cache_seam #(
                .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS)
            ) u_seam (
                .clk(clk),
                .rst(rst),
                .stage_start_valid(stage_start_valid),
                .stage_start_ready(stage_start_ready),
                .stage_cache_enable(stage_cache_enable),
                .stage_base_addr(stage_base_addr),
                .stage_width(stage_width),
                .stage_height(stage_height),
                .stage_groups(stage_groups),
                .stage_start_done(stage_start_done),
                .stage_cache_active(stage_cache_active),
                .stage_cache_fallback(stage_cache_fallback),
                .stage_cache_reason(stage_cache_reason),
                .abort_req(abort_req),
                .abort_done(abort_done),
                .flush_req(flush_req),
                .flush_done(flush_done),
                .s_req_valid(s_req_valid),
                .s_req_ready(s_req_ready),
                .s_req_write(s_req_write),
                .s_req_addr(s_req_addr),
                .s_req_wdata(s_req_wdata),
                .s_req_wstrb(s_req_wstrb),
                .s_req_cacheable(s_req_cacheable),
                .s_req_cache_x(s_req_cache_x),
                .s_req_cache_y(s_req_cache_y),
                .s_req_cache_group(s_req_cache_group),
                .s_rsp_valid(s_rsp_valid),
                .s_rsp_ready(s_rsp_ready),
                .s_rsp_error(s_rsp_error),
                .s_rsp_rdata(s_rsp_rdata),
                .m_req_valid(bridge_mem_req_valid),
                .m_req_ready(bridge_mem_req_ready),
                .m_req_write(bridge_mem_req_write),
                .m_req_addr(bridge_mem_req_addr),
                .m_req_wdata(bridge_mem_req_wdata),
                .m_req_wstrb(bridge_mem_req_wstrb),
                .m_rsp_valid(bridge_mem_rsp_valid),
                .m_rsp_ready(bridge_mem_rsp_ready),
                .m_rsp_error(bridge_mem_rsp_error),
                .m_rsp_rdata(bridge_mem_rsp_rdata),
                .cache_error(cache_error),
                .cache_error_code(cache_error_code),
                .busy(busy),
                .quiescent(quiescent)
            );
        end else begin : g_bypass
            // Keep the disabled build a pure wire-level bypass.  No cache
            // state, handshake, or diagnostic pulse is synthesized here.
            assign stage_start_ready = 1'b1;
            assign stage_start_done = 1'b0;
            assign stage_cache_active = 1'b0;
            assign stage_cache_fallback = 1'b0;
            assign stage_cache_reason = 4'd0;
            assign abort_done = 1'b0;
            assign flush_done = 1'b0;
            assign cache_error = 1'b0;
            assign cache_error_code = 3'd0;
            assign busy = 1'b0;
            assign quiescent = 1'b1;

            assign bridge_mem_req_valid = s_req_valid;
            assign s_req_ready = bridge_mem_req_ready;
            assign bridge_mem_req_write = s_req_write;
            assign bridge_mem_req_addr = s_req_addr;
            assign bridge_mem_req_wdata = s_req_wdata;
            assign bridge_mem_req_wstrb = s_req_wstrb;
            assign s_rsp_valid = bridge_mem_rsp_valid;
            assign bridge_mem_rsp_ready = s_rsp_ready;
            assign s_rsp_error = bridge_mem_rsp_error;
            assign s_rsp_rdata = bridge_mem_rsp_rdata;
        end
    endgenerate

    c1_tensor_mem_axi128_bridge u_bridge (
        .clk(clk),
        .rst(rst),
        .read_cache_invalidate(1'b0),
        .mem_req_valid(bridge_mem_req_valid),
        .mem_req_ready(bridge_mem_req_ready),
        .mem_req_write(bridge_mem_req_write),
        .mem_req_addr(bridge_mem_req_addr),
        .mem_req_wdata(bridge_mem_req_wdata),
        .mem_req_wstrb(bridge_mem_req_wstrb),
        .mem_rsp_valid(bridge_mem_rsp_valid),
        .mem_rsp_ready(bridge_mem_rsp_ready),
        .mem_rsp_error(bridge_mem_rsp_error),
        .mem_rsp_rdata(bridge_mem_rsp_rdata),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
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

`ifndef SYNTHESIS
    // The wrapper must never expose two independent logical directions from
    // the single-outstanding bridge.  The bridge has its own detailed checks;
    // this assertion documents the client-boundary invariant for top-level
    // simulations and catches accidental duplicate wrappers.
    always_ff @(posedge clk) begin
        if (!rst && m_axi_arvalid &&
            (m_axi_awvalid || m_axi_wvalid || m_axi_bready))
            $fatal(1, "tensor client exposed overlapping AXI read/write paths");
    end
`endif

endmodule
