`timescale 1ns/1ps

// Small integration gate for the cache-refill scheduler and the existing
// ID-less AXI128 read burst client. Defaults use two short rows; parameters
// also support controlled long-row/window comparisons. The test includes
// a base crossing 0x1000 so the scheduler's occupancy/quiescent/flush wiring,
// reader burst splitting, response order and word sideband are all exercised
// without a native-frame simulation.
module tb_c1_cache_refill_scheduler_read_client #(
    parameter integer SCH_MAX_OUT = 2,
    parameter integer LEAF_REQ_DEPTH = 8,
    parameter integer LEAF_BURST_BEATS = 4,
    parameter integer LEAF_MAX_OUT = SCH_MAX_OUT,
    parameter integer CMD0_WORDS = 20,
    parameter integer CMD1_WORDS = 5,
    parameter bit REQ_HANDOFF = 0
);
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer SCH_CMD_DEPTH = 4;
    localparam integer LEAF_RSP_DEPTH = 2 * LEAF_BURST_BEATS * LEAF_MAX_OUT;
    localparam integer BFM_Q_DEPTH = 16;
    localparam integer MAX_CYCLES = 100000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid, cmd_ready;
    logic [31:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;
    logic abort_req, abort_done, flush_req, flush_done;
    logic [EPOCH_W-1:0] current_epoch;

    logic sch_req_valid, sch_req_ready;
    logic [31:0] sch_req_addr;
    logic [EPOCH_W-1:0] sch_req_epoch;
    logic sch_req_flush;
    logic [7:0] sch_req_occupancy;
    logic sch_leaf_quiescent;
    logic sch_rsp_valid, sch_rsp_ready;
    logic [63:0] sch_rsp_data;
    logic sch_rsp_error;
    logic word_valid, word_ready;
    logic [63:0] word_data;
    logic word_error, word_last;
    logic [15:0] word_row, word_index;
    logic [EPOCH_W-1:0] word_epoch;
    logic cmd_done, cmd_done_error;
    logic [15:0] cmd_done_row;
    logic [EPOCH_W-1:0] cmd_done_epoch;
    logic scheduler_busy, scheduler_quiescent, drain_pending;
    logic [7:0] scheduler_outstanding, scheduler_max_outstanding;
    logic [7:0] scheduler_cmd_occupancy;
    logic [63:0] scheduler_cmd_accept_count, scheduler_req_count;
    logic [63:0] scheduler_rsp_count, scheduler_word_count;
    logic [63:0] scheduler_stale_count, scheduler_orphan_count;
    logic [63:0] scheduler_error_count;

    logic leaf_rsp_error;
    logic leaf_busy;
    logic [7:0] leaf_req_occ;

    // AXI leaf signals.
    logic m_arvalid, m_arready;
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_rvalid, m_rready, m_rlast;
    logic [127:0] m_rdata;
    logic [1:0] m_rresp;
    c1_cache_refill_scheduler #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(SCH_CMD_DEPTH), .MAX_OUTSTANDING(SCH_MAX_OUT),
        .ALLOW_REQ_HANDOFF(REQ_HANDOFF)
    ) u_scheduler (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_base_addr, .cmd_stride_bytes,
        .cmd_row, .cmd_word_count, .cmd_epoch,
        .abort_req, .abort_done, .flush_req, .flush_done, .current_epoch,
        .leaf_req_valid(sch_req_valid), .leaf_req_ready(sch_req_ready),
        .leaf_req_addr(sch_req_addr), .leaf_req_epoch(sch_req_epoch),
        .leaf_req_flush(sch_req_flush), .leaf_req_occupancy(sch_req_occupancy),
        .leaf_quiescent(sch_leaf_quiescent),
        .leaf_rsp_valid(sch_rsp_valid), .leaf_rsp_ready(sch_rsp_ready),
        .leaf_rsp_data(sch_rsp_data), .leaf_rsp_error(sch_rsp_error),
        .word_valid, .word_ready, .word_data, .word_error, .word_last,
        .word_row, .word_index, .word_epoch,
        .drain_word_ready(1'b1),
        .cmd_done, .cmd_done_error, .cmd_done_row, .cmd_done_epoch,
        .busy(scheduler_busy), .quiescent(scheduler_quiescent),
        .drain_pending, .outstanding(scheduler_outstanding),
        .max_outstanding_seen(scheduler_max_outstanding),
        .cmd_occupancy(scheduler_cmd_occupancy),
        .perf_cmd_accept_count(scheduler_cmd_accept_count),
        .perf_req_count(scheduler_req_count),
        .perf_rsp_count(scheduler_rsp_count),
        .perf_word_count(scheduler_word_count),
        .perf_stale_drop_count(scheduler_stale_count),
        .perf_orphan_rsp_count(scheduler_orphan_count),
        .perf_error_count(scheduler_error_count)
    );

    logic leaf_rsp_valid, leaf_rsp_ready;
    logic [63:0] leaf_rsp_rdata;
    logic leaf_rsp_err;
    logic leaf_perf_busy;
    logic [63:0] leaf_perf_req_count, leaf_perf_burst_count;
    logic [63:0] leaf_perf_beat_count, leaf_perf_rsp_count;
    logic [63:0] leaf_perf_packed_count, leaf_perf_error_count;
    logic [7:0] leaf_perf_req_occ, leaf_perf_max_req_occ;
    logic [7:0] leaf_perf_outstanding, leaf_perf_max_outstanding;
    logic leaf_req_ready_int;

    // The scheduler is the sole producer/consumer around the leaf client.
    assign sch_req_occupancy = leaf_perf_req_occ;
    assign sch_leaf_quiescent = !leaf_perf_busy;
    assign sch_rsp_valid = leaf_rsp_valid;
    assign leaf_rsp_ready = sch_rsp_ready;
    assign sch_rsp_data = leaf_rsp_rdata;
    assign sch_rsp_error = leaf_rsp_err;

    assign sch_req_ready = leaf_req_ready_int;

    c1_tensor_mem_axi128_read_burst_client #(
        .REQ_FIFO_DEPTH(LEAF_REQ_DEPTH),
        .BURST_BEATS(LEAF_BURST_BEATS),
        .MAX_OUTSTANDING(LEAF_MAX_OUT),
        .RSP_FIFO_DEPTH(LEAF_RSP_DEPTH),
        .BUILD_TIMEOUT_CYCLES(2),
        .RSP_FIFO_BEAT_MODE(1'b0),
        .ALLOW_RSP_POP_REFILL(1'b0),
        .ALLOW_REQ_POP_REFILL(1'b0)
    ) u_leaf (
        .clk, .rst,
        .req_valid(sch_req_valid), .req_ready(leaf_req_ready_int),
        .req_flush(sch_req_flush), .req_addr(sch_req_addr),
        .rsp_valid(leaf_rsp_valid), .rsp_ready(leaf_rsp_ready),
        .rsp_error(leaf_rsp_err), .rsp_rdata(leaf_rsp_rdata),
        .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid),
        .m_axi_rready(m_rready),
        .perf_busy(leaf_perf_busy),
        .perf_req_accept_count(leaf_perf_req_count),
        .perf_axi_burst_count(leaf_perf_burst_count),
        .perf_axi_beat_count(leaf_perf_beat_count),
        .perf_rsp_count(leaf_perf_rsp_count),
        .perf_packed_request_count(leaf_perf_packed_count),
        .perf_error_count(leaf_perf_error_count),
        .perf_req_occupancy(leaf_perf_req_occ),
        .perf_max_req_occupancy(leaf_perf_max_req_occ),
        .perf_outstanding(leaf_perf_outstanding),
        .perf_max_outstanding(leaf_perf_max_outstanding)
    );

    // ------------------------------------------------------------------
    // Compact in-order AXI BFM.
    // ------------------------------------------------------------------
    logic [31:0] bfm_base_mem [0:BFM_Q_DEPTH-1];
    integer bfm_beats_mem [0:BFM_Q_DEPTH-1];
    integer bfm_head, bfm_tail, bfm_count;
    logic bfm_r_active, bfm_r_hold;
    integer bfm_r_beat;
    integer cycle_count, ar_count, axi_beat_count;
    integer page_split_count;
    integer max_burst_seen;
    wire ar_fire = m_arvalid && m_arready;
    wire r_fire = m_rvalid && m_rready;

    always_comb begin
        m_arready = ((cycle_count % 5) != 1);
        m_rvalid = bfm_r_active &&
                   (bfm_r_hold || ((cycle_count % 7) != 3));
        m_rresp = 2'b00;
        m_rlast = bfm_r_active &&
                  (bfm_r_beat == (bfm_beats_mem[bfm_head] - 1));
        m_rdata = {
            64'hB000_0000_0000_0000 |
                {32'd0, 32'(bfm_base_mem[bfm_head] + bfm_r_beat*16 + 32'd8)},
                64'hA000_0000_0000_0000 |
                {32'd0, 32'(bfm_base_mem[bfm_head] + bfm_r_beat*16)}
        };
        // Deterministic downstream backpressure exercises the scheduler's
        // response hold while the leaf remains ID-less and in order.
        word_ready = ((cycle_count % 4) != 2);
    end

    integer bfm_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_r_active <= 1'b0;
            bfm_r_hold <= 1'b0;
            bfm_r_beat <= 0;
            cycle_count <= 0;
            ar_count <= 0;
            axi_beat_count <= 0;
            page_split_count <= 0;
            max_burst_seen <= 0;
            for (bfm_i = 0; bfm_i < BFM_Q_DEPTH; bfm_i = bfm_i + 1)
                bfm_beats_mem[bfm_i] <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (!bfm_r_active && (bfm_count != 0)) begin
                bfm_r_active <= 1'b1;
                bfm_r_beat <= 0;
                bfm_r_hold <= 1'b0;
            end
            if (ar_fire) begin
                if(m_arlen+1>max_burst_seen) max_burst_seen <= m_arlen+1;
                if (bfm_count >= BFM_Q_DEPTH)
                    $fatal(1, "integration BFM AR queue overflow");
                if (m_arsize != 3'd4 || m_arburst != 2'b01)
                    $fatal(1, "integration AXI attributes mismatch");
                if ((m_araddr >> 12) !=
                    ((m_araddr + (m_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "integration AR crossed 4KiB boundary");
                if (m_araddr[11:0] == 12'h000)
                    page_split_count <= page_split_count + 1;
                bfm_base_mem[bfm_tail] <= m_araddr;
                bfm_beats_mem[bfm_tail] <= m_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_Q_DEPTH;
                ar_count <= ar_count + 1;
            end
            if (r_fire) begin
                axi_beat_count <= axi_beat_count + 1;
                if (m_rlast) begin
                    bfm_r_active <= 1'b0;
                    bfm_head <= (bfm_head + 1) % BFM_Q_DEPTH;
                end else begin
                    bfm_r_beat <= bfm_r_beat + 1;
                end
            end
            if (m_rvalid && !m_rready)
                bfm_r_hold <= 1'b1;
            else if (r_fire || !bfm_r_active)
                bfm_r_hold <= 1'b0;
            case ({ar_fire, (r_fire && m_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Scoreboard/stimulus.
    // ------------------------------------------------------------------
    integer cmd_done_count, word_count_tb, timeout_count;
    integer expected_phase;
    integer expected_index;
    logic saw_flush;
    function automatic logic [63:0] expected_word(input logic [31:0] address);
        expected_word=(address[3] ? 64'hB000_0000_0000_0000 : 64'hA000_0000_0000_0000) |
                      {32'd0,address};
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            cmd_done_count <= 0;
            word_count_tb <= 0;
            expected_phase <= 0;
            expected_index <= 0;
            saw_flush <= 1'b0;
        end else begin
            if (sch_req_flush)
                saw_flush <= 1'b1;
            if (word_valid && word_ready) begin
                if (word_error !== 1'b0 || word_epoch !== 3'd0)
                    $fatal(1, "integration word error/epoch mismatch");
                if (expected_phase == 0) begin
                    if (word_row !== 16'd3 || word_index !== expected_index ||
                        word_data !== expected_word(32'h0000_0FF0 + expected_index * 32'd8) ||
                        word_last !== (expected_index == CMD0_WORDS-1))
                        $fatal(1, "integration row0 word mismatch idx=%0d",
                               expected_index);
                end else begin
                    if (word_row !== 16'd8 || word_index !== expected_index ||
                        word_data !== expected_word(32'h0000_5000 + expected_index * 32'd8) ||
                        word_last !== (expected_index == CMD1_WORDS-1))
                        $fatal(1, "integration row1 word mismatch idx=%0d",
                               expected_index);
                end
                word_count_tb <= word_count_tb + 1;
                expected_index <= expected_index + 1;
            end
            if (cmd_done) begin
                if (cmd_done_error)
                    $fatal(1, "integration command completed with error");
                cmd_done_count <= cmd_done_count + 1;
                expected_phase <= expected_phase + 1;
                expected_index <= 0;
            end
        end
    end

    task automatic send_command(
        input logic [31:0] base,
        input logic [31:0] stride,
        input logic [15:0] row,
        input logic [15:0] words,
        input logic [EPOCH_W-1:0] ep
    );
        begin
            @(negedge clk);
            cmd_base_addr = base;
            cmd_stride_bytes = stride;
            cmd_row = row;
            cmd_word_count = words;
            cmd_epoch = ep;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    initial begin
        cmd_valid = 1'b0;
        cmd_base_addr = 0;
        cmd_stride_bytes = 0;
        cmd_row = 0;
        cmd_word_count = 0;
        cmd_epoch = 0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        timeout_count = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        // Queue a second row while row0 is active.  The first base crosses a
        // 4-KiB boundary after the first two logical words.
        send_command(32'h0000_0FF0, 32'd8, 16'd3, CMD0_WORDS, 3'd0);
        send_command(32'h0000_5000, 32'd8, 16'd8, CMD1_WORDS, 3'd0);

        while (cmd_done_count < 2) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if ((timeout_count % 1000) == 0)
                $display("INTEGRATION_PROGRESS t=%0d cmdq=%0d active_out=%0d leaf_busy=%0d leaf_req_occ=%0d sch_busy=%0d pending=%0d ar=%0d",
                         timeout_count, scheduler_cmd_occupancy,
                         scheduler_outstanding, leaf_perf_busy,
                         leaf_perf_req_occ, scheduler_busy,
                         drain_pending, ar_count);
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "integration timeout done=%0d words=%0d ar=%0d",
                       cmd_done_count, word_count_tb, ar_count);
        end
        @(negedge clk);
        if (word_count_tb != CMD0_WORDS + CMD1_WORDS)
            $fatal(1, "integration word count mismatch: %0d", word_count_tb);
        if (scheduler_req_count != CMD0_WORDS + CMD1_WORDS ||
            scheduler_word_count != CMD0_WORDS + CMD1_WORDS)
            $fatal(1, "integration scheduler counters mismatch req=%0d words=%0d",
                   scheduler_req_count, scheduler_word_count);
        if (scheduler_error_count != 0 || leaf_perf_error_count != 0)
            $fatal(1, "integration unexpected leaf/scheduler error");
        if (!saw_flush || (ar_count < 2) || (page_split_count == 0))
            $fatal(1, "integration did not exercise leaf close/burst split page=%0d",
                   page_split_count);
        if (scheduler_max_outstanding != SCH_MAX_OUT)
            $fatal(1, "integration scheduler credit mismatch: %0d",
                   scheduler_max_outstanding);
        if (!scheduler_quiescent || leaf_perf_busy)
            $fatal(1, "integration remains busy after command completion");

        $display("C1_REFILL_LONGROW_CONFIG words0=%0d words1=%0d window=%0d burst_limit=%0d leaf_max=%0d req_depth=%0d rsp_depth=%0d max_burst=%0d",CMD0_WORDS,CMD1_WORDS,SCH_MAX_OUT,LEAF_BURST_BEATS,LEAF_MAX_OUT,LEAF_REQ_DEPTH,LEAF_RSP_DEPTH,max_burst_seen);
        $display("C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS commands=%0d words=%0d req=%0d rsp=%0d ar=%0d axi_beats=%0d max_outstanding=%0d flush=%0d cycles=%0d",
                 cmd_done_count, word_count_tb, scheduler_req_count,
                 scheduler_rsp_count, ar_count, axi_beat_count,
                 scheduler_max_outstanding, saw_flush, cycle_count);
        $finish;
    end
endmodule
