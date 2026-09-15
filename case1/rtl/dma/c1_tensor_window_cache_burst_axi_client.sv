`timescale 1ns/1ps

// Optional client-6 bridge for the next tensor-memory phase.
//
// The production c1_tensor_window_cache_axi_client keeps one 64-bit request
// in flight and uses c1_tensor_window_cache_seam for both cacheable taps and
// ordinary bypass traffic.  That is the safest compatibility point, but it
// also means that a cache-line refill waits for one AXI response per word.
// This companion client changes only the refill side:
//
//   cacheable 3x3 tap -> exact line-cache burst shell -> read bursts/
//   multi-outstanding scheduler
//   all other reads/writes -> legacy one-beat bridge
//
// The two paths share one ID-less AXI slot.  A small owner register prevents
// their channels from overlapping, while the local response owner preserves
// request order.  Consequently this module is a drop-in *experimental seam*
// rather than an implicit change to the default SoC.  It is enabled by an
// explicit top-level parameter and remains disabled unless its abort/flush,
// ordering, resource and native-long-frame gates pass.
//
// The adapter currently emits one logical request at a time.  The measurable
// gain in this phase is therefore refill-side burst service and hiding DDR
// latency behind the cache line fill; a future tile scheduler is still needed
// to expose several independent logical requests to the scheduler.
module c1_tensor_window_cache_burst_axi_client #(
    parameter integer BURST_LINE_ROWS = 3,
    parameter integer BURST_MAX_ROW_WORDS = 1280,
    parameter integer BURST_MAX_GROUPS = 8,
    parameter integer BURST_EPOCH_W = 8,
    parameter integer BURST_CMD_FIFO_DEPTH = 2,
    parameter integer BURST_SCHED_MAX_OUTSTANDING = 16,
    parameter integer BURST_REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer BURST_READER_MAX_OUTSTANDING = 4,
    parameter integer BURST_RSP_FIFO_DEPTH =
        2 * BURST_BEATS * BURST_READER_MAX_OUTSTANDING,
    parameter integer BURST_BUILD_TIMEOUT_CYCLES = 4,
    parameter bit BURST_ALLOW_SAME_LANE_DUP = 1'b1,
    parameter bit BURST_RSP_FIFO_BEAT_MODE = 1'b0,
    parameter bit BURST_ALLOW_RSP_POP_REFILL = 1'b0,
    parameter bit BURST_ALLOW_REQ_POP_REFILL = 1'b0,
    // Set only when an integration wants cancellation to remain a sticky
    // protocol fault.  The default treats an expected frame fence as a
    // recoverable refill-data event while retaining structural fault status.
    parameter bit BURST_CANCEL_IS_PROTOCOL_ERROR = 1'b0,
    parameter integer BURST_REFILL_SKID_DEPTH = 2,
    // The adapter/seam clamps cache tap coordinates before admission.  Keep
    // the child check enabled by default; set this only for the measured
    // timing candidate that uses the preclamped contract.
    parameter integer BURST_PRECLAMPED_TAP_COORDS = 0,
    parameter integer ENABLE_PACKED_WRITES = 0,
    parameter integer USE_WRITE_END = 0,
    parameter bit BURST_ALLOW_SCHED_REQ_HANDOFF = 1'b0
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
    output logic [15:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    input  logic [127:0] m_axi_rdata,
    input  logic [1:0]   m_axi_rresp,
    input  logic         m_axi_rlast,
    input  logic         m_axi_rvalid,
    output logic         m_axi_rready,

    output logic        cache_error,
    output logic [2:0]  cache_error_code,
    output logic        busy,
    output logic        quiescent,
    input logic         s_req_end
);

    localparam logic [1:0] OWNER_NONE   = 2'd0;
    localparam logic [1:0] OWNER_BURST  = 2'd1;
    localparam logic [1:0] OWNER_BRIDGE = 2'd2;

    logic [1:0] owner_q;
    logic bridge_inflight_q;
    localparam integer BRIDGE_COUNT_W = ENABLE_PACKED_WRITES ? 6 : 1;
    logic [BRIDGE_COUNT_W-1:0] bridge_pending_q;
    logic bridge_batch_write_q;
    logic bridge_admission_window;
    assign bridge_inflight_q = bridge_pending_q != 0;
    // A line-cache miss deliberately reports tap_ready=0 while it launches
    // the refill.  Reserve the AXI owner as soon as the upstream tap is
    // presented, but retain tap_valid until the cache eventually accepts it.
    // Without this pending bit the owner would remain NONE, so the refill's
    // ARREADY would be masked forever (a deterministic miss deadlock).
    logic burst_tap_pending_q;
    // A maintenance edge may arrive while the upstream adapter is holding
    // an unaccepted request.  The legacy seam deliberately drains that
    // front request instead of withdrawing READY; retain the same contract
    // here and send it through the one-beat compatibility bridge after the
    // burst child has quiesced.
    logic front_drain_q;
    // A cache miss has already claimed OWNER_BURST before the line cache can
    // accept its tap.  If a fence arrives in that window, the tap cannot be
    // accepted while the child is in maintenance, so replay the still-held
    // logical request through the bridge after the child drain.
    logic burst_replay_q;
    logic stage_cache_enable_q;
    logic stage_reject_q;

    logic burst_group_start_ready;
    logic burst_group_start_done;
    logic burst_group_start_error;
    logic [2:0] burst_group_start_error_code;
    logic burst_config_valid;
    logic burst_abort_done;
    logic burst_flush_done;
    logic burst_tap_valid, burst_tap_ready;
    logic burst_tap_rsp_valid, burst_tap_rsp_ready;
    logic burst_tap_rsp_error;
    logic [63:0] burst_tap_rsp_data;
    logic burst_cache_error;
    logic [2:0] burst_cache_error_code;
    logic burst_busy, burst_quiescent;

    logic burst_arvalid, burst_arready;
    logic [31:0] burst_araddr;
    logic [7:0] burst_arlen;
    logic [2:0] burst_arsize;
    logic [1:0] burst_arburst;
    logic [127:0] burst_rdata;
    logic [1:0] burst_rresp;
    logic burst_rlast, burst_rvalid, burst_rready;

    logic bridge_req_valid, bridge_req_ready;
    logic bridge_req_write;
    logic [31:0] bridge_req_addr;
    logic [63:0] bridge_req_wdata;
    logic [7:0] bridge_req_wstrb;
    logic bridge_rsp_valid, bridge_rsp_ready;
    logic bridge_rsp_error;
    logic [63:0] bridge_rsp_rdata;

    logic bridge_awvalid, bridge_awready;
    logic [31:0] bridge_awaddr;
    logic [7:0] bridge_awlen;
    logic [2:0] bridge_awsize;
    logic [1:0] bridge_awburst;
    logic bridge_wvalid, bridge_wready;
    logic [127:0] bridge_wdata;
    logic [15:0] bridge_wstrb;
    logic bridge_wlast;
    logic [1:0] bridge_bresp;
    logic bridge_bvalid, bridge_bready;
    logic bridge_arvalid, bridge_arready;
    logic [31:0] bridge_araddr;
    logic [7:0] bridge_arlen;
    logic [2:0] bridge_arsize;
    logic [1:0] bridge_arburst;
    logic [127:0] bridge_rdata;
    logic [1:0] bridge_rresp;
    logic bridge_rlast, bridge_rvalid, bridge_rready;

    logic route_burst;
    logic route_bridge;
    logic burst_request_active;
    logic burst_claim;
    logic stage_start_fire;
    logic burst_tap_fire;
    logic bridge_req_fire;
    logic burst_rsp_fire;
    logic bridge_rsp_fire;
    logic bridge_active;
    logic maintenance_block;
    logic drain_front_active;
    logic abort_seen_q, flush_seen_q;
    logic abort_pending_q, flush_pending_q;
    logic abort_burst_seen_q, flush_burst_seen_q;
    logic new_abort_event, new_flush_event;
    logic burst_maintenance_done;

    // A not-yet-accepted request is represented only by the upstream valid
    // signal; including bridge_req_valid here would make route_bridge depend
    // on itself.  The registered in-flight bit and the bridge response state
    // are sufficient to exclude a live legacy transaction.
    assign bridge_active = bridge_inflight_q || bridge_rsp_valid;
    assign maintenance_block = abort_req || flush_req || abort_pending_q ||
                               flush_pending_q;
    assign bridge_admission_window =
        ((owner_q == OWNER_NONE) && !bridge_active) ||
        ((ENABLE_PACKED_WRITES != 0) && (owner_q == OWNER_BRIDGE) &&
         bridge_batch_write_q && s_req_write);
    assign drain_front_active = front_drain_q &&
                                bridge_admission_window && s_req_valid &&
                                maintenance_block;

    assign new_abort_event = abort_req && !abort_seen_q;
    assign new_flush_event = flush_req && !flush_seen_q;
    // A pending cache tap is replayed only after either relevant child fence
    // has drained the refill.  The outer join below still waits for every
    // requested fence before acknowledging it to the caller.
    assign burst_maintenance_done =
        ((abort_pending_q || new_abort_event) && burst_abort_done) ||
        ((flush_pending_q || new_flush_event) && burst_flush_done);

    // A cacheable request is routed to the burst shell only after the current
    // stage has been accepted and its geometry has passed the shell's config.
    // Before that point it follows the compatibility bridge, exactly like the
    // original cache seam's fallback behavior.
    assign route_burst = (owner_q == OWNER_NONE) && !bridge_active &&
                         !maintenance_block && !stage_start_valid &&
                         stage_cache_enable_q && burst_config_valid &&
                         !stage_reject_q && !burst_cache_error &&
                         s_req_cacheable && !s_req_write &&
                         (s_req_wstrb == 8'h00);
    // During a fence, only the one request that was already visible at the
    // maintenance edge may be admitted.  This is the no-withdrawal drain
    // path; no later request can pass while maintenance_block is asserted.
    assign route_bridge = bridge_admission_window &&
                          !stage_start_valid && burst_quiescent &&
                          (drain_front_active ||
                           (!maintenance_block && !route_burst));

    assign stage_start_ready = !rst && !maintenance_block &&
                               (owner_q == OWNER_NONE) && !bridge_active &&
                               burst_group_start_ready;
    assign stage_start_fire = stage_start_valid && stage_start_ready;

    assign burst_request_active = (owner_q == OWNER_BURST) &&
                                  burst_tap_pending_q;
    // Never admit a not-yet-accepted tap after a fence edge.  The upstream
    // producer keeps s_req_valid asserted, but the wrapper must replay that
    // logical request through the bridge once the burst child has drained;
    // allowing tap_valid to remain high here could let the cache start a new
    // refill in the one-cycle gap between child flush_done and owner release.
    assign burst_tap_valid = s_req_valid && !maintenance_block &&
                             (route_burst || burst_request_active);
    assign burst_tap_rsp_ready = (owner_q == OWNER_BURST) && s_rsp_ready;
    assign burst_tap_fire = burst_tap_valid && burst_tap_ready;
    assign burst_claim = s_req_valid && route_burst;

    assign bridge_req_valid = s_req_valid && route_bridge;
    assign bridge_req_write = s_req_write;
    assign bridge_req_addr = s_req_addr;
    assign bridge_req_wdata = s_req_wdata;
    assign bridge_req_wstrb = s_req_wstrb;
    assign bridge_rsp_ready = (owner_q == OWNER_BRIDGE) && s_rsp_ready;
    assign bridge_req_fire = bridge_req_valid && bridge_req_ready;
    assign bridge_rsp_fire = bridge_rsp_valid && bridge_rsp_ready;
    // A pending tap remains owned by the burst child until the requested
    // fence has drained.  Do not expose READY during that maintenance
    // interval: tap_valid is intentionally suppressed so the held logical
    // request can be replayed through the bridge without violating the
    // ready/valid contract.  Without this gate an upstream producer could
    // observe READY while VALID is low and withdraw the request before the
    // replay path takes ownership.
    assign s_req_ready = (route_burst || burst_request_active) ?
                         ((!maintenance_block) ? burst_tap_ready : 1'b0) :
                         (route_bridge ? bridge_req_ready : 1'b0);

    assign s_rsp_valid = (owner_q == OWNER_BURST) ? burst_tap_rsp_valid :
                         (owner_q == OWNER_BRIDGE) ? bridge_rsp_valid : 1'b0;
    assign s_rsp_error = (owner_q == OWNER_BURST) ? burst_tap_rsp_error :
                         (owner_q == OWNER_BRIDGE) ? bridge_rsp_error : 1'b0;
    assign s_rsp_rdata = (owner_q == OWNER_BURST) ? burst_tap_rsp_data :
                         (owner_q == OWNER_BRIDGE) ? bridge_rsp_rdata : 64'd0;
    assign burst_rsp_fire = burst_tap_rsp_valid && burst_tap_rsp_ready;

    assign burst_arready = (owner_q == OWNER_BURST) ? m_axi_arready : 1'b0;
    assign burst_rdata = m_axi_rdata;
    assign burst_rresp = m_axi_rresp;
    assign burst_rlast = m_axi_rlast;
    assign burst_rvalid = (owner_q == OWNER_BURST) ? m_axi_rvalid : 1'b0;

    assign bridge_awready = (owner_q == OWNER_BRIDGE) ? m_axi_awready : 1'b0;
    assign bridge_wready = (owner_q == OWNER_BRIDGE) ? m_axi_wready : 1'b0;
    assign bridge_bresp = m_axi_bresp;
    assign bridge_bvalid = (owner_q == OWNER_BRIDGE) ? m_axi_bvalid : 1'b0;
    assign bridge_arready = (owner_q == OWNER_BRIDGE) ? m_axi_arready : 1'b0;
    assign bridge_rdata = m_axi_rdata;
    assign bridge_rresp = m_axi_rresp;
    assign bridge_rlast = m_axi_rlast;
    assign bridge_rvalid = (owner_q == OWNER_BRIDGE) ? m_axi_rvalid : 1'b0;

    // One external ID-less AXI slot.  The owner is registered before either
    // child can issue a transfer, so no channel can be driven by both paths.
    always_comb begin
        m_axi_awvalid = (owner_q == OWNER_BRIDGE) && bridge_awvalid;
        m_axi_awaddr  = bridge_awaddr;
        m_axi_awlen   = bridge_awlen;
        m_axi_awsize  = bridge_awsize;
        m_axi_awburst = bridge_awburst;
        m_axi_wvalid  = (owner_q == OWNER_BRIDGE) && bridge_wvalid;
        m_axi_wdata   = bridge_wdata;
        m_axi_wstrb   = bridge_wstrb;
        m_axi_wlast   = bridge_wlast;
        m_axi_bready  = (owner_q == OWNER_BRIDGE) && bridge_bready;

        m_axi_arvalid = (owner_q == OWNER_BURST) ? burst_arvalid :
                        (owner_q == OWNER_BRIDGE) ? bridge_arvalid : 1'b0;
        m_axi_araddr  = (owner_q == OWNER_BURST) ? burst_araddr :
                        bridge_araddr;
        m_axi_arlen   = (owner_q == OWNER_BURST) ? burst_arlen :
                        bridge_arlen;
        m_axi_arsize  = (owner_q == OWNER_BURST) ? burst_arsize :
                        bridge_arsize;
        m_axi_arburst = (owner_q == OWNER_BURST) ? burst_arburst :
                        bridge_arburst;
        m_axi_rready  = (owner_q == OWNER_BURST) ? burst_rready :
                        (owner_q == OWNER_BRIDGE) ? bridge_rready : 1'b0;
    end

    // The exact shell has its own edge detectors, so a level held in our
    // pending register is safe to forward.  Forwarding the held level is
    // essential when a one-cycle fence arrives during a cache miss: the line
    // cache intentionally deasserts tap_ready while refilling and therefore
    // can never "admit the tap first".
    wire burst_abort_req = abort_req || abort_pending_q;
    wire burst_flush_req = flush_req || flush_pending_q;

    c1_window_line_cache_c8_exact_burst_shell #(
        .DATA_W(64),
        .LINE_ROWS(BURST_LINE_ROWS),
        .MAX_ROW_WORDS(BURST_MAX_ROW_WORDS),
        .MAX_GROUPS(BURST_MAX_GROUPS),
        .EPOCH_W(BURST_EPOCH_W),
        .CMD_FIFO_DEPTH(BURST_CMD_FIFO_DEPTH),
        .SCHED_MAX_OUTSTANDING(BURST_SCHED_MAX_OUTSTANDING),
        .ALLOW_SCHED_REQ_HANDOFF(BURST_ALLOW_SCHED_REQ_HANDOFF),
        .REQ_FIFO_DEPTH(BURST_REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .READER_MAX_OUTSTANDING(BURST_READER_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(BURST_RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BURST_BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(BURST_ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(BURST_RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(BURST_ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(BURST_ALLOW_REQ_POP_REFILL),
        .CANCEL_IS_PROTOCOL_ERROR(BURST_CANCEL_IS_PROTOCOL_ERROR),
        .REFILL_SKID_DEPTH(BURST_REFILL_SKID_DEPTH),
        .PRECLAMPED_TAP_COORDS(BURST_PRECLAMPED_TAP_COORDS)
    ) u_burst_cache (
        .clk(clk), .rst(rst),
        // The exact shell uses stage_base_valid as an independent admission
        // guard.  Keep it asserted with the producer's valid; gating it by
        // stage_start_ready would form a combinational ready loop and strand
        // the adapter in ST_CACHE_CONFIG.
        .stage_base_valid(stage_start_valid),
        .stage_base_addr(stage_base_addr),
        .group_start_valid(stage_start_valid && stage_start_ready),
        .group_start_ready(burst_group_start_ready),
        .frame_width(stage_width), .frame_height(stage_height),
        .frame_groups(stage_groups),
        .group_start_done(burst_group_start_done),
        .group_start_error(burst_group_start_error),
        .group_start_error_code(burst_group_start_error_code),
        .config_valid(burst_config_valid),
        .abort_req(burst_abort_req), .abort_done(burst_abort_done),
        .flush_req(burst_flush_req), .flush_done(burst_flush_done),
        .tap_valid(burst_tap_valid), .tap_ready(burst_tap_ready),
        .tap_x(s_req_cache_x), .tap_y(s_req_cache_y),
        .tap_group(s_req_cache_group),
        .tap_rsp_valid(burst_tap_rsp_valid),
        .tap_rsp_ready(burst_tap_rsp_ready),
        .tap_rsp_data_s8(burst_tap_rsp_data),
        .tap_rsp_error(burst_tap_rsp_error),
        .m_axi_arvalid(burst_arvalid), .m_axi_arready(burst_arready),
        .m_axi_araddr(burst_araddr), .m_axi_arlen(burst_arlen),
        .m_axi_arsize(burst_arsize), .m_axi_arburst(burst_arburst),
        .m_axi_rdata(burst_rdata), .m_axi_rresp(burst_rresp),
        .m_axi_rlast(burst_rlast), .m_axi_rvalid(burst_rvalid),
        .m_axi_rready(burst_rready),
        .cache_error(burst_cache_error),
        .cache_error_code(burst_cache_error_code),
        .refill_protocol_error(), .refill_done(), .refill_done_error(),
        .busy(burst_busy), .quiescent(burst_quiescent),
        .perf_refill_count(), .perf_refill_word_count(),
        .perf_axi_burst_count(), .perf_axi_beat_count(),
        .perf_cache_rsp_count(), .perf_max_outstanding(),
        .current_epoch(), .drain_pending(), .outstanding(),
        .max_outstanding_seen(), .cmd_occupancy(),
        .perf_cmd_accept_count(), .perf_req_count(), .perf_rsp_count(),
        .perf_word_count(), .perf_stale_drop_count(),
        .perf_orphan_rsp_count(), .perf_scheduler_error_count(),
        .leaf_perf_req_accept_count(), .leaf_perf_axi_burst_count(),
        .leaf_perf_axi_beat_count(), .leaf_perf_rsp_count(),
        .leaf_perf_packed_request_count(), .leaf_perf_error_count(),
        .leaf_perf_req_occupancy(), .leaf_perf_max_req_occupancy(),
        .leaf_perf_outstanding(), .leaf_perf_max_outstanding()
    );

    c1_tensor_mem_axi128_packing_bridge #(
        .ENABLE_PACKED_WRITES(ENABLE_PACKED_WRITES), .USE_WRITE_END(USE_WRITE_END)
    ) u_legacy_bridge (
        .clk(clk), .rst(rst),
        .read_cache_invalidate(1'b0),
        .mem_req_valid(bridge_req_valid), .mem_req_ready(bridge_req_ready),
        .mem_req_write(bridge_req_write), .mem_req_addr(bridge_req_addr),
        .mem_req_wdata(bridge_req_wdata), .mem_req_wstrb(bridge_req_wstrb),
        .mem_req_end(s_req_end),
        .mem_rsp_valid(bridge_rsp_valid), .mem_rsp_ready(bridge_rsp_ready),
        .mem_rsp_error(bridge_rsp_error), .mem_rsp_rdata(bridge_rsp_rdata),
        .m_axi_awaddr(bridge_awaddr), .m_axi_awlen(bridge_awlen),
        .m_axi_awsize(bridge_awsize), .m_axi_awburst(bridge_awburst),
        .m_axi_awvalid(bridge_awvalid), .m_axi_awready(bridge_awready),
        .m_axi_wdata(bridge_wdata), .m_axi_wstrb(bridge_wstrb),
        .m_axi_wlast(bridge_wlast), .m_axi_wvalid(bridge_wvalid),
        .m_axi_wready(bridge_wready), .m_axi_bresp(bridge_bresp),
        .m_axi_bvalid(bridge_bvalid), .m_axi_bready(bridge_bready),
        .m_axi_araddr(bridge_araddr), .m_axi_arlen(bridge_arlen),
        .m_axi_arsize(bridge_arsize), .m_axi_arburst(bridge_arburst),
        .m_axi_arvalid(bridge_arvalid), .m_axi_arready(bridge_arready),
        .m_axi_rdata(bridge_rdata), .m_axi_rresp(bridge_rresp),
        .m_axi_rlast(bridge_rlast), .m_axi_rvalid(bridge_rvalid),
        .m_axi_rready(bridge_rready)
    );

    // Mirror the exact shell's one-cycle group-start completion pulse at the
    // client boundary.  The legacy cache client exposes this pulse and the
    // portable SoC keeps it as a stage-level diagnostic; leaving the optional
    // burst seam undriven would turn the signal into X/Z in standalone
    // simulations and make software-side stage sequencing ambiguous.
    assign stage_start_done = burst_group_start_done;
    assign stage_cache_active = stage_cache_enable_q && burst_config_valid &&
                                !stage_reject_q && !burst_cache_error;
    assign stage_cache_fallback = stage_cache_enable_q &&
                                  (stage_reject_q || burst_cache_error);
    assign stage_cache_reason = stage_reject_q ?
                                {1'b0, burst_group_start_error_code} :
                                (burst_cache_error ? 4'd7 : 4'd0);
    assign cache_error = burst_cache_error;
    assign cache_error_code = burst_cache_error_code;

    assign busy = !quiescent;
    assign quiescent = (owner_q == OWNER_NONE) && !bridge_active &&
                       burst_quiescent && !abort_pending_q &&
                       !flush_pending_q && !abort_req && !flush_req &&
                       !stage_start_valid && !s_req_valid &&
                       !front_drain_q && !burst_replay_q;

    // Maintenance completion is a join of the burst shell's epoch drain and
    // the legacy bridge's single accepted transaction.  The bridge has no
    // cancel input by design, so a response is always consumed before the
    // fence is acknowledged to the adapter.
    always_ff @(posedge clk) begin
        if (rst) begin
            owner_q <= OWNER_NONE;
            bridge_pending_q <= 0;
            bridge_batch_write_q <= 0;
            burst_tap_pending_q <= 1'b0;
            front_drain_q <= 1'b0;
            burst_replay_q <= 1'b0;
            stage_cache_enable_q <= 1'b0;
            stage_reject_q <= 1'b0;
            abort_seen_q <= 1'b0;
            flush_seen_q <= 1'b0;
            abort_pending_q <= 1'b0;
            flush_pending_q <= 1'b0;
            abort_burst_seen_q <= 1'b0;
            flush_burst_seen_q <= 1'b0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
        end else begin
            case ({bridge_req_fire,bridge_rsp_fire})
                2'b10: bridge_pending_q <= bridge_pending_q + 1'b1;
                2'b01: bridge_pending_q <= bridge_pending_q - 1'b1;
                default: ;
            endcase
            abort_done <= 1'b0;
            flush_done <= 1'b0;

            if (!abort_req)
                abort_seen_q <= 1'b0;
            if (!flush_req)
                flush_seen_q <= 1'b0;

            if (stage_start_fire) begin
                stage_cache_enable_q <= stage_cache_enable;
                stage_reject_q <= 1'b0;
            end
            if (burst_group_start_done && burst_group_start_error)
                stage_reject_q <= 1'b1;

            if (burst_claim) begin
                owner_q <= OWNER_BURST;
                burst_tap_pending_q <= !burst_tap_fire;
            end
            if (burst_tap_fire)
                burst_tap_pending_q <= 1'b0;
            if (bridge_req_fire) begin
                owner_q <= OWNER_BRIDGE;
                if (owner_q == OWNER_NONE) bridge_batch_write_q <= s_req_write;
                front_drain_q <= 1'b0;
            end
            if (burst_rsp_fire) begin
                owner_q <= OWNER_NONE;
                burst_tap_pending_q <= 1'b0;
            end
            if (bridge_rsp_fire) begin
                if (bridge_pending_q == 1 && !bridge_req_fire)
                    owner_q <= OWNER_NONE;
            end

            if (new_abort_event) begin
                abort_seen_q <= 1'b1;
                abort_pending_q <= 1'b1;
                // Repeated cancellation joins the current fence. The child
                // sees a continuously asserted request while pending and will
                // not issue a second ACK; preserve its already observed ACK.
                if(!abort_pending_q) abort_burst_seen_q <= 1'b0;
                if ((owner_q == OWNER_NONE) && !stage_start_valid &&
                    s_req_valid)
                    front_drain_q <= 1'b1;
                else if (ENABLE_PACKED_WRITES != 0 && owner_q == OWNER_BRIDGE &&
                         s_req_valid && !bridge_req_fire)
                    front_drain_q <= 1'b1;
                else if ((owner_q == OWNER_BURST) &&
                         burst_tap_pending_q)
                    burst_replay_q <= 1'b1;
            end
            if (new_flush_event) begin
                flush_seen_q <= 1'b1;
                flush_pending_q <= 1'b1;
                if(!flush_pending_q) flush_burst_seen_q <= 1'b0;
                if ((owner_q == OWNER_NONE) && !stage_start_valid &&
                    s_req_valid)
                    front_drain_q <= 1'b1;
                else if (ENABLE_PACKED_WRITES != 0 && owner_q == OWNER_BRIDGE &&
                         s_req_valid && !bridge_req_fire)
                    front_drain_q <= 1'b1;
                else if ((owner_q == OWNER_BURST) &&
                         burst_tap_pending_q)
                    burst_replay_q <= 1'b1;
            end

            // A miss reserves OWNER_BURST before the line cache can accept
            // its tap.  Once the child fence reports a drained refill, hand
            // that still-held request to the legacy bridge.  This preserves
            // ready/valid no-withdrawal without inventing a response.
            if ((burst_replay_q ||
                 ((new_abort_event || new_flush_event) &&
                  (owner_q == OWNER_BURST) && burst_tap_pending_q)) &&
                burst_maintenance_done) begin
                owner_q <= OWNER_NONE;
                burst_tap_pending_q <= 1'b0;
                burst_replay_q <= 1'b0;
                front_drain_q <= s_req_valid;
            end

            if ((abort_pending_q || new_abort_event) && burst_abort_done)
                abort_burst_seen_q <= 1'b1;
            if ((flush_pending_q || new_flush_event) && burst_flush_done)
                flush_burst_seen_q <= 1'b1;

            if (abort_pending_q &&
                (abort_burst_seen_q || burst_abort_done) &&
                (owner_q == OWNER_NONE) && !bridge_inflight_q &&
                !bridge_rsp_valid && !bridge_req_fire && !front_drain_q) begin
                abort_pending_q <= 1'b0;
                abort_burst_seen_q <= 1'b0;
                abort_done <= 1'b1;
            end
            if (flush_pending_q &&
                (flush_burst_seen_q || burst_flush_done) &&
                (owner_q == OWNER_NONE) && !bridge_inflight_q &&
                !bridge_rsp_valid && !bridge_req_fire && !front_drain_q) begin
                flush_pending_q <= 1'b0;
                flush_burst_seen_q <= 1'b0;
                flush_done <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // These checks are intentionally local to the optional seam.  They catch
    // an accidental channel overlap or a fence acknowledged before the
    // bridge response has drained without adding any synthesis logic.
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (bridge_rsp_fire && bridge_pending_q == 0)
                $fatal(1,"tensor bridge retired an unowned response");
            if (ENABLE_PACKED_WRITES != 0 && bridge_pending_q > 24)
                $fatal(1,"tensor bridge pending count overflow");
            if ((owner_q == OWNER_BURST) &&
                (m_axi_awvalid || m_axi_wvalid || m_axi_bready))
                $fatal(1, "burst cache client overlapped AXI write channel");
            if (maintenance_block && burst_request_active && s_req_ready)
                $fatal(1, "burst cache client exposed READY during pending fence");
            if ((owner_q == OWNER_BRIDGE) && m_axi_arvalid &&
                burst_arvalid)
                $fatal(1, "burst cache client drove two AXI read owners");
            if (abort_done && (owner_q != OWNER_NONE || bridge_inflight_q))
                $fatal(1, "burst cache client acknowledged abort before drain");
            if (flush_done && (owner_q != OWNER_NONE || bridge_inflight_q))
                $fatal(1, "burst cache client acknowledged flush before drain");
        end
    end
`endif

endmodule
