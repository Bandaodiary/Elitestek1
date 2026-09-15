`timescale 1ns/1ps

// Board-independent parallel write data path for the 15-fps experiment.
//
// The original write-burst leaf is deliberately conservative: it builds one
// descriptor and waits for its W/B completion before starting the next one.
// This wrapper scales that proven leaf horizontally.  A block dispatcher
// feeds contiguous logical writes to one leaf at a time, so pack2 remains
// useful inside each block, while the ID-less write arbiter accepts AW from
// several leaves and hides AW/B latency.  W and B are still ordered by the
// arbiter, and a small tag FIFO restores the original logical response order
// at the wrapper boundary.
//
// This is an optional seam; no legacy portable-SoC top is changed.  It is
// intentionally explicit about the tradeoff: BLOCK_LOGICAL should be an even
// value (and normally a multiple of the expected row/tile run) to avoid
// needlessly cutting packable pairs at a leaf boundary.  The dispatcher does
// not claim to be a general AXI DMA engine; it is a boardless way to measure
// whether two or more independent write descriptors are enough to hide the
// memory response latency.
module c1_tensor_mem_axi128_write_parallel_fabric #(
    parameter integer LANES = 2,
    parameter integer BLOCK_LOGICAL = 16,
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS,
    parameter integer FABRIC_FIFO_DEPTH = LANES + 2,
    parameter integer TAG_FIFO_DEPTH = LANES * REQ_FIFO_DEPTH,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b0,
    // Forward the optional full request-FIFO pop/refill boundary to each
    // proven write leaf.  It is disabled by default, preserving the
    // historical ready timing for existing integrations.
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic                         req_flush,
    input  logic [31:0]                  req_addr,
    input  logic [63:0]                  req_wdata,
    input  logic [7:0]                   req_wstrb,

    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_error,
    output logic [63:0]                  rsp_rdata,

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

    output logic                         protocol_error,
    output logic                         early_wlast_error,
    output logic                         missing_wlast_error,
    output logic                         early_b_error,
    output logic                         orphan_b_error,

    output logic                         perf_busy,
    output logic [63:0]                  perf_req_accept_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_packed_request_count,
    output logic [63:0]                  perf_error_count,
    output logic [7:0]                   perf_req_occupancy,
    output logic [7:0]                   perf_max_req_occupancy,
    output logic [7:0]                   perf_outstanding,
    output logic [7:0]                   perf_max_outstanding
);

    localparam integer LANE_IDX_W = (LANES <= 1) ? 1 : $clog2(LANES);
    localparam integer BLOCK_CNT_W = (BLOCK_LOGICAL <= 1) ? 1 :
                                     $clog2(BLOCK_LOGICAL);
    localparam integer TAG_PTR_W = (TAG_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(TAG_FIFO_DEPTH);
    localparam integer TAG_CNT_W = (TAG_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(TAG_FIFO_DEPTH + 1);

    initial begin
        if (LANES < 2)
            $fatal(1, "parallel write fabric LANES must be at least two");
        if (BLOCK_LOGICAL < 2 || (BLOCK_LOGICAL % 2) != 0)
            $fatal(1, "BLOCK_LOGICAL must be an even value >= 2");
        if (REQ_FIFO_DEPTH < 2 || REQ_FIFO_DEPTH > 255)
            $fatal(1, "REQ_FIFO_DEPTH must be in the range 2..255");
        if (BURST_BEATS < 1 || BURST_BEATS > 256)
            $fatal(1, "BURST_BEATS must be in the range 1..256");
        if (RSP_FIFO_DEPTH < 2 * BURST_BEATS)
            $fatal(1, "RSP_FIFO_DEPTH must cover one leaf descriptor");
        if (FABRIC_FIFO_DEPTH < LANES || FABRIC_FIFO_DEPTH > 255)
            $fatal(1, "FABRIC_FIFO_DEPTH must be LANES..255");
        if (TAG_FIFO_DEPTH < 2 || TAG_FIFO_DEPTH > 255)
            $fatal(1, "TAG_FIFO_DEPTH must be in the range 2..255");
    end

    // ------------------------------------------------------------------
    // Parallel leaf interfaces.
    // ------------------------------------------------------------------
    logic [LANES-1:0]           leaf_req_valid;
    logic [LANES-1:0]           leaf_req_ready;
    logic [LANES-1:0]           leaf_req_flush;
    logic [LANES-1:0][31:0]     leaf_req_addr;
    logic [LANES-1:0][63:0]     leaf_req_wdata;
    logic [LANES-1:0][7:0]      leaf_req_wstrb;

    logic [LANES-1:0]           leaf_rsp_valid;
    logic [LANES-1:0]           leaf_rsp_ready;
    logic [LANES-1:0]           leaf_rsp_error;
    logic [LANES-1:0][63:0]     leaf_rsp_rdata;

    logic [LANES-1:0][31:0]     leaf_awaddr;
    logic [LANES-1:0][7:0]      leaf_awlen;
    logic [LANES-1:0][2:0]      leaf_awsize;
    logic [LANES-1:0][1:0]      leaf_awburst;
    logic [LANES-1:0]           leaf_awvalid;
    logic [LANES-1:0]           leaf_awready;
    logic [LANES-1:0][127:0]    leaf_wdata;
    logic [LANES-1:0][15:0]     leaf_wstrb;
    logic [LANES-1:0]           leaf_wlast;
    logic [LANES-1:0]           leaf_wvalid;
    logic [LANES-1:0]           leaf_wready;
    logic [LANES-1:0][1:0]      leaf_bresp;
    logic [LANES-1:0]           leaf_bvalid;
    logic [LANES-1:0]           leaf_bready;

    logic [LANES-1:0]           leaf_busy;
    logic [LANES-1:0][63:0]     leaf_req_count;
    logic [LANES-1:0][63:0]     leaf_burst_count;
    logic [LANES-1:0][63:0]     leaf_beat_count;
    logic [LANES-1:0][63:0]     leaf_rsp_count;
    logic [LANES-1:0][63:0]     leaf_packed_count;
    logic [LANES-1:0][63:0]     leaf_error_count;
    logic [LANES-1:0][7:0]      leaf_req_occupancy;
    logic [LANES-1:0][7:0]      leaf_max_req_occupancy;
    logic [LANES-1:0][7:0]      leaf_outstanding;
    logic [LANES-1:0][7:0]      leaf_max_outstanding;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : gen_leaf
            c1_tensor_mem_axi128_write_burst_client #(
                .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
                .BURST_BEATS(BURST_BEATS),
                .MAX_OUTSTANDING(1),
                .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
                .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
                .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
                .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL)
            ) u_leaf (
                .clk(clk), .rst(rst),
                .req_valid(leaf_req_valid[g]),
                .req_ready(leaf_req_ready[g]),
                .req_flush(leaf_req_flush[g]),
                .req_addr(leaf_req_addr[g]),
                .req_wdata(leaf_req_wdata[g]),
                .req_wstrb(leaf_req_wstrb[g]),
                .rsp_valid(leaf_rsp_valid[g]),
                .rsp_ready(leaf_rsp_ready[g]),
                .rsp_error(leaf_rsp_error[g]),
                .rsp_rdata(leaf_rsp_rdata[g]),
                .m_axi_awaddr(leaf_awaddr[g]),
                .m_axi_awlen(leaf_awlen[g]),
                .m_axi_awsize(leaf_awsize[g]),
                .m_axi_awburst(leaf_awburst[g]),
                .m_axi_awvalid(leaf_awvalid[g]),
                .m_axi_awready(leaf_awready[g]),
                .m_axi_wdata(leaf_wdata[g]),
                .m_axi_wstrb(leaf_wstrb[g]),
                .m_axi_wlast(leaf_wlast[g]),
                .m_axi_wvalid(leaf_wvalid[g]),
                .m_axi_wready(leaf_wready[g]),
                .m_axi_bresp(leaf_bresp[g]),
                .m_axi_bvalid(leaf_bvalid[g]),
                .m_axi_bready(leaf_bready[g]),
                .perf_busy(leaf_busy[g]),
                .perf_req_accept_count(leaf_req_count[g]),
                .perf_axi_burst_count(leaf_burst_count[g]),
                .perf_axi_beat_count(leaf_beat_count[g]),
                .perf_rsp_count(leaf_rsp_count[g]),
                .perf_packed_request_count(leaf_packed_count[g]),
                .perf_error_count(leaf_error_count[g]),
                .perf_req_occupancy(leaf_req_occupancy[g]),
                .perf_max_req_occupancy(leaf_max_req_occupancy[g]),
                .perf_outstanding(leaf_outstanding[g]),
                .perf_max_outstanding(leaf_max_outstanding[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // AW/W/B fabric.  The arbiter carries the no-ID ordering contract.
    // ------------------------------------------------------------------
    logic fabric_protocol_error;
    logic fabric_early_wlast_error, fabric_missing_wlast_error;
    logic fabric_early_b_error, fabric_orphan_b_error;
    logic [7:0] fabric_outstanding, fabric_max_outstanding;
    logic [63:0] fabric_aw_accept_count, fabric_aw_issue_count;
    logic [63:0] fabric_w_beat_count, fabric_b_count;

    c1_axi_n_write_burst_arbiter_128 #(
        .CLIENTS(LANES),
        .FIFO_DEPTH(FABRIC_FIFO_DEPTH)
    ) u_fabric (
        .clk(clk), .rst(rst),
        .s_awaddr(leaf_awaddr), .s_awlen(leaf_awlen),
        .s_awsize(leaf_awsize), .s_awburst(leaf_awburst),
        .s_awvalid(leaf_awvalid), .s_awready(leaf_awready),
        .s_wdata(leaf_wdata), .s_wstrb(leaf_wstrb),
        .s_wlast(leaf_wlast), .s_wvalid(leaf_wvalid),
        .s_wready(leaf_wready),
        .s_bresp(leaf_bresp), .s_bvalid(leaf_bvalid),
        .s_bready(leaf_bready),
        .m_awaddr(m_axi_awaddr), .m_awlen(m_axi_awlen),
        .m_awsize(m_axi_awsize), .m_awburst(m_axi_awburst),
        .m_awvalid(m_axi_awvalid), .m_awready(m_axi_awready),
        .m_wdata(m_axi_wdata), .m_wstrb(m_axi_wstrb),
        .m_wlast(m_axi_wlast), .m_wvalid(m_axi_wvalid),
        .m_wready(m_axi_wready),
        .m_bresp(m_axi_bresp), .m_bvalid(m_axi_bvalid),
        .m_bready(m_axi_bready),
        .protocol_error(fabric_protocol_error),
        .early_wlast_error(fabric_early_wlast_error),
        .missing_wlast_error(fabric_missing_wlast_error),
        .early_b_error(fabric_early_b_error),
        .orphan_b_error(fabric_orphan_b_error),
        .perf_outstanding(fabric_outstanding),
        .perf_max_outstanding(fabric_max_outstanding),
        .perf_aw_accept_count(fabric_aw_accept_count),
        .perf_aw_issue_count(fabric_aw_issue_count),
        .perf_w_beat_count(fabric_w_beat_count),
        .perf_b_count(fabric_b_count)
    );

    // ------------------------------------------------------------------
    // Contiguous-block dispatcher and response-order tag FIFO.
    // ------------------------------------------------------------------
    logic [LANE_IDX_W-1:0] dispatch_lane_q;
    logic [BLOCK_CNT_W-1:0] dispatch_count_q;
    logic [LANE_IDX_W-1:0] tag_mem [0:TAG_FIFO_DEPTH-1];
    logic [TAG_PTR_W-1:0] tag_head_q, tag_tail_q;
    logic [TAG_CNT_W-1:0] tag_count_q;
    logic tag_space, req_fire, rsp_pop;
    logic [LANE_IDX_W-1:0] rsp_lane;
    logic rsp_lane_valid;
    logic [7:0] perf_max_tag_q;
    integer init_i;

    function automatic [LANE_IDX_W-1:0] lane_inc(
        input [LANE_IDX_W-1:0] value
    );
        begin
            if (value == LANES - 1)
                lane_inc = '0;
            else
                lane_inc = value + 1'b1;
        end
    endfunction

    function automatic [TAG_PTR_W-1:0] tag_ptr_inc(
        input [TAG_PTR_W-1:0] value
    );
        begin
            if (value == TAG_FIFO_DEPTH - 1)
                tag_ptr_inc = '0;
            else
                tag_ptr_inc = value + 1'b1;
        end
    endfunction

    assign tag_space = (tag_count_q < TAG_FIFO_DEPTH);
    assign req_ready = !rst && !req_flush && tag_space &&
                       leaf_req_ready[dispatch_lane_q];
    assign req_fire = req_valid && req_ready;

    always_comb begin
        integer lane_i;
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            leaf_req_valid[lane_i] = 1'b0;
            leaf_req_flush[lane_i] = req_flush;
            leaf_req_addr[lane_i] = req_addr;
            leaf_req_wdata[lane_i] = req_wdata;
            leaf_req_wstrb[lane_i] = req_wstrb;
        end
        if (!rst && !req_flush && tag_space)
            leaf_req_valid[dispatch_lane_q] = req_valid;
    end

    assign rsp_lane_valid = (tag_count_q != 0);
    assign rsp_lane = rsp_lane_valid ? tag_mem[tag_head_q] : '0;

    always_comb begin
        integer lane_i;
        rsp_valid = 1'b0;
        rsp_error = 1'b0;
        rsp_rdata = 64'd0;
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1)
            leaf_rsp_ready[lane_i] = 1'b0;
        if (!rst && rsp_lane_valid) begin
            rsp_valid = leaf_rsp_valid[rsp_lane];
            rsp_error = leaf_rsp_error[rsp_lane];
            rsp_rdata = leaf_rsp_rdata[rsp_lane];
            leaf_rsp_ready[rsp_lane] = rsp_ready;
        end
    end
    assign rsp_pop = rsp_valid && rsp_ready;

    // Aggregate counters are combinational sums of the independently tested
    // leaves.  The tag occupancy is the useful end-to-end request backlog;
    // the fabric occupancy remains available as the descriptor-level MLP.
    logic [64:0] sum_req_w, sum_burst_w, sum_beat_w, sum_rsp_w;
    logic [64:0] sum_pack_w, sum_err_w;
    logic any_leaf_busy;
    integer sum_i;
    always_comb begin
        sum_req_w = 65'd0;
        sum_burst_w = 65'd0;
        sum_beat_w = 65'd0;
        sum_rsp_w = 65'd0;
        sum_pack_w = 65'd0;
        sum_err_w = 65'd0;
        any_leaf_busy = 1'b0;
        for (sum_i = 0; sum_i < LANES; sum_i = sum_i + 1) begin
            sum_req_w = sum_req_w + {1'b0, leaf_req_count[sum_i]};
            sum_burst_w = sum_burst_w + {1'b0, leaf_burst_count[sum_i]};
            sum_beat_w = sum_beat_w + {1'b0, leaf_beat_count[sum_i]};
            sum_rsp_w = sum_rsp_w + {1'b0, leaf_rsp_count[sum_i]};
            sum_pack_w = sum_pack_w + {1'b0, leaf_packed_count[sum_i]};
            sum_err_w = sum_err_w + {1'b0, leaf_error_count[sum_i]};
            if (leaf_busy[sum_i])
                any_leaf_busy = 1'b1;
        end
        perf_req_accept_count = sum_req_w[63:0];
        perf_axi_burst_count = sum_burst_w[63:0];
        perf_axi_beat_count = sum_beat_w[63:0];
        perf_rsp_count = sum_rsp_w[63:0];
        perf_packed_request_count = sum_pack_w[63:0];
        perf_error_count = sum_err_w[63:0];
        // Assignment zero-extends the (possibly narrower) tag counter; the
        // parameter check above keeps it within the public 8-bit range.
        perf_req_occupancy = tag_count_q;
        perf_max_req_occupancy = perf_max_tag_q;
        perf_outstanding = fabric_outstanding;
        perf_max_outstanding = fabric_max_outstanding;
        // The underlying arbiter may keep m_axi_bready high while idle to
        // drain a malformed orphan B.  That defensive drain is not evidence
        // of real work, so do not include it in the end-to-end busy flag.
        perf_busy = any_leaf_busy || (tag_count_q != 0) ||
                    (fabric_outstanding != 0) ||
                    m_axi_awvalid || m_axi_wvalid;
    end

    assign protocol_error = fabric_protocol_error;
    assign early_wlast_error = fabric_early_wlast_error;
    assign missing_wlast_error = fabric_missing_wlast_error;
    assign early_b_error = fabric_early_b_error;
    assign orphan_b_error = fabric_orphan_b_error;

    always_ff @(posedge clk) begin
        if (rst) begin
            dispatch_lane_q <= '0;
            dispatch_count_q <= '0;
            tag_head_q <= '0;
            tag_tail_q <= '0;
            tag_count_q <= '0;
            perf_max_tag_q <= 8'd0;
            for (init_i = 0; init_i < TAG_FIFO_DEPTH; init_i = init_i + 1)
                tag_mem[init_i] <= '0;
        end else begin
            if (req_fire) begin
                tag_mem[tag_tail_q] <= dispatch_lane_q;
                tag_tail_q <= tag_ptr_inc(tag_tail_q);
                if (BLOCK_LOGICAL <= 1 ||
                    dispatch_count_q >= BLOCK_LOGICAL - 1) begin
                    dispatch_lane_q <= lane_inc(dispatch_lane_q);
                    dispatch_count_q <= '0;
                end else begin
                    dispatch_count_q <= dispatch_count_q + 1'b1;
                end
            end
            if (rsp_pop)
                tag_head_q <= tag_ptr_inc(tag_head_q);
            case ({req_fire, rsp_pop})
                2'b10: tag_count_q <= tag_count_q + 1'b1;
                2'b01: tag_count_q <= tag_count_q - 1'b1;
                default: tag_count_q <= tag_count_q;
            endcase
            if (req_fire && ((tag_count_q + 1'b1) > perf_max_tag_q))
                perf_max_tag_q <= tag_count_q + 1'b1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (tag_count_q > TAG_FIFO_DEPTH)
                $fatal(1, "parallel write tag FIFO overflow");
            if (rsp_pop && !rsp_lane_valid)
                $fatal(1, "parallel write response popped without a tag");
        end
    end
`endif

endmodule
