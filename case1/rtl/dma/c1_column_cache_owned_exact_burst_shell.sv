`timescale 1ns/1ps
// Portable read-only column endpoint. Owns request/response retirement and
// fences around the real column cache + exact AXI reader. No DDR PHY or mux.
// Reset this entire endpoint only after its external AXI domain is drained.
// ENABLE_OWNER=0 is a verification/legacy direct-column control, not scalar ABI.
module c1_column_cache_owned_exact_burst_shell #(
    parameter bit ENABLE_OWNER=1'b1,
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    parameter integer EPOCH_W = 8,
    parameter integer CMD_FIFO_DEPTH = 2,
    parameter integer SCHED_MAX_OUTSTANDING = 16,
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer READER_MAX_OUTSTANDING = 4,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS * READER_MAX_OUTSTANDING,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    parameter bit RSP_FIFO_BEAT_MODE = 1'b0,
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0,
    parameter bit CANCEL_IS_PROTOCOL_ERROR = 1'b0,
    parameter integer REFILL_SKID_DEPTH = 2,
    parameter bit ALLOW_SCHED_REQ_HANDOFF = 1'b0,
    parameter bit COLUMN_READ_ON_LOOKUP = 1'b0,
    parameter bit COLUMN_RESPONSE_BYPASS = 1'b0,
    parameter bit COLUMN_REUSE_ROW_MAP = 1'b0
) (
input  logic                         clk,
    input  logic                         rst,

    
    
    
    input  logic                         stage_base_valid,
    input  logic [31:0]                  stage_base_addr,

    input  logic                         group_start_valid,
    output logic                         group_start_ready,
    input  logic [15:0]                  frame_width,
    input  logic [15:0]                  frame_height,
    input  logic [3:0]                   frame_groups,
    output logic                         group_start_done,
    output logic                         group_start_error,
    output logic [2:0]                   group_start_error_code,
    output logic                         config_valid,

    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,

    input  logic                         tap_valid,
    output logic                         tap_ready,
    input  logic signed [16:0]           tap_x,
    input  logic signed [16:0]           tap_y,
    input  logic [2:0]                   tap_group,
    output logic                         tap_rsp_valid,
    input  logic                         tap_rsp_ready,
    output logic [3*DATA_W-1:0] tap_rsp_data_s8,
    output logic                         tap_rsp_error,

    
    
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    
    output logic                         cache_error,
    output logic [2:0]                   cache_error_code,
    output logic                         refill_protocol_error,
    output logic                         refill_done,
    output logic                         refill_done_error,
    output logic                         busy,
    output logic                         quiescent,
    output logic [63:0]                  perf_refill_count,
    output logic [63:0]                  perf_refill_word_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_cache_rsp_count,
    output logic [7:0]                   perf_max_outstanding,

    
    
    output logic [EPOCH_W-1:0]            current_epoch,
    output logic                         drain_pending,
    output logic [7:0]                   outstanding,
    output logic [7:0]                   max_outstanding_seen,
    output logic [7:0]                   cmd_occupancy,
    output logic [63:0]                  perf_cmd_accept_count,
    output logic [63:0]                  perf_req_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_word_count,
    output logic [63:0]                  perf_stale_drop_count,
    output logic [63:0]                  perf_orphan_rsp_count,
    output logic [63:0]                  perf_scheduler_error_count,
    output logic [63:0]                  leaf_perf_req_accept_count,
    output logic [63:0]                  leaf_perf_axi_burst_count,
    output logic [63:0]                  leaf_perf_axi_beat_count,
    output logic [63:0]                  leaf_perf_rsp_count,
    output logic [63:0]                  leaf_perf_packed_request_count,
    output logic [63:0]                  leaf_perf_error_count,
    output logic [7:0]                   leaf_perf_req_occupancy,
    output logic [7:0]                   leaf_perf_max_req_occupancy,
    output logic [7:0]                   leaf_perf_outstanding,
    output logic [7:0]                   leaf_perf_max_outstanding
);
    wire child_req_valid,child_req_ready,child_rsp_valid,child_rsp_ready,child_rsp_error;
    wire signed [16:0] child_x,child_y;
    wire [2:0] child_group;
    wire [191:0] child_data;
    wire child_abort,child_flush,child_abort_done,child_flush_done;
    wire child_busy,child_idle,child_config_ready,config_permit;
    assign group_start_ready=child_config_ready && config_permit;
    generate if(ENABLE_OWNER) begin : g_owner
        c1_column_transaction_owner owner (
            .clk(clk),.rst(rst),.s_req_valid(tap_valid),.s_req_ready(tap_ready),
            .s_req_x(tap_x),.s_req_center_y(tap_y),.s_req_group(tap_group),
            .s_rsp_valid(tap_rsp_valid),.s_rsp_ready(tap_rsp_ready),
            .s_rsp_data(tap_rsp_data_s8),.s_rsp_error(tap_rsp_error),
            .m_req_valid(child_req_valid),.m_req_ready(child_req_ready),
            .m_req_x(child_x),.m_req_center_y(child_y),.m_req_group(child_group),
            .m_rsp_valid(child_rsp_valid),.m_rsp_ready(child_rsp_ready),
            .m_rsp_data(child_data),.m_rsp_error(child_rsp_error),
            .abort_req(abort_req),.flush_req(flush_req),.abort_done(abort_done),.flush_done(flush_done),
            .m_abort_req(child_abort),.m_flush_req(child_flush),
            .m_abort_done(child_abort_done),.m_flush_done(child_flush_done),
            .backend_config_valid(config_valid),.backend_quiescent(child_idle),
            .config_pending(group_start_valid),.config_permit(config_permit),.busy(busy),.quiescent(quiescent)
        );
    end else begin : g_direct
        assign child_req_valid=tap_valid;assign tap_ready=child_req_ready;
        assign {child_x,child_y,child_group}={tap_x,tap_y,tap_group};
        assign tap_rsp_valid=child_rsp_valid;assign child_rsp_ready=tap_rsp_ready;
        assign tap_rsp_data_s8=child_data;assign tap_rsp_error=child_rsp_error;
        assign child_abort=abort_req;assign child_flush=flush_req;
        assign abort_done=child_abort_done;assign flush_done=child_flush_done;
        assign busy=child_busy;assign quiescent=child_idle;assign config_permit=1;
    end endgenerate
    c1_window_line_cache_c8_exact_burst_shell #(
        .COLUMN_MODE(1'b1),.PRECLAMPED_TAP_COORDS(0),
        .COLUMN_READ_ON_LOOKUP(COLUMN_READ_ON_LOOKUP),
        .COLUMN_RESPONSE_BYPASS(COLUMN_RESPONSE_BYPASS),
        .COLUMN_REUSE_ROW_MAP(COLUMN_REUSE_ROW_MAP),
        .DATA_W(DATA_W),
        .LINE_ROWS(LINE_ROWS),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(MAX_GROUPS),
        .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_FIFO_DEPTH),
        .SCHED_MAX_OUTSTANDING(SCHED_MAX_OUTSTANDING),
        .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .READER_MAX_OUTSTANDING(READER_MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL),
        .CANCEL_IS_PROTOCOL_ERROR(CANCEL_IS_PROTOCOL_ERROR),
        .REFILL_SKID_DEPTH(REFILL_SKID_DEPTH),
        .ALLOW_SCHED_REQ_HANDOFF(ALLOW_SCHED_REQ_HANDOFF)
    ) u_backend (
        .clk(clk),
        .rst(rst),
        .stage_base_valid(stage_base_valid),
        .stage_base_addr(stage_base_addr),
        .group_start_valid(group_start_valid && config_permit),
        .group_start_ready(child_config_ready),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .frame_groups(frame_groups),
        .group_start_done(group_start_done),
        .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),
        .config_valid(config_valid),
        .abort_req(child_abort),
        .abort_done(child_abort_done),
        .flush_req(child_flush),
        .flush_done(child_flush_done),
        .tap_valid(child_req_valid),
        .tap_ready(child_req_ready),
        .tap_x(child_x),
        .tap_y(child_y),
        .tap_group(child_group),
        .tap_rsp_valid(child_rsp_valid),
        .tap_rsp_ready(child_rsp_ready),
        .tap_rsp_data_s8(child_data),
        .tap_rsp_error(child_rsp_error),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .cache_error(cache_error),
        .cache_error_code(cache_error_code),
        .refill_protocol_error(refill_protocol_error),
        .refill_done(refill_done),
        .refill_done_error(refill_done_error),
        .busy(child_busy),
        .quiescent(child_idle),
        .perf_refill_count(perf_refill_count),
        .perf_refill_word_count(perf_refill_word_count),
        .perf_axi_burst_count(perf_axi_burst_count),
        .perf_axi_beat_count(perf_axi_beat_count),
        .perf_cache_rsp_count(perf_cache_rsp_count),
        .perf_max_outstanding(perf_max_outstanding),
        .current_epoch(current_epoch),
        .drain_pending(drain_pending),
        .outstanding(outstanding),
        .max_outstanding_seen(max_outstanding_seen),
        .cmd_occupancy(cmd_occupancy),
        .perf_cmd_accept_count(perf_cmd_accept_count),
        .perf_req_count(perf_req_count),
        .perf_rsp_count(perf_rsp_count),
        .perf_word_count(perf_word_count),
        .perf_stale_drop_count(perf_stale_drop_count),
        .perf_orphan_rsp_count(perf_orphan_rsp_count),
        .perf_scheduler_error_count(perf_scheduler_error_count),
        .leaf_perf_req_accept_count(leaf_perf_req_accept_count),
        .leaf_perf_axi_burst_count(leaf_perf_axi_burst_count),
        .leaf_perf_axi_beat_count(leaf_perf_axi_beat_count),
        .leaf_perf_rsp_count(leaf_perf_rsp_count),
        .leaf_perf_packed_request_count(leaf_perf_packed_request_count),
        .leaf_perf_error_count(leaf_perf_error_count),
        .leaf_perf_req_occupancy(leaf_perf_req_occupancy),
        .leaf_perf_max_req_occupancy(leaf_perf_max_req_occupancy),
        .leaf_perf_outstanding(leaf_perf_outstanding),
        .leaf_perf_max_outstanding(leaf_perf_max_outstanding)
    );
endmodule
