`timescale 1ns/1ps

// End-to-end boardless gate for the exact-count composition:
// scheduler -> AXI128 read leaf -> completion adapter.  AXI service is held
// off while the configured request window is filled, then flush is asserted.
// Accepted responses must appear as error/drain words; the never-issued
// suffix must be synthesized as zero/error. Defaults retain the 2/5 case.
module tb_c1_cache_refill_scheduler_read_client_exact #(
    parameter integer SCHED_MAX = 2,
    parameter integer WORDS = 5,
    parameter bit REQ_HANDOFF = 1'b0
);
    localparam integer ADDR_W = 32;
    localparam integer DATA_W = 64;
    localparam integer EPOCH_W = 3;
    localparam integer CMD_DEPTH = 4;
    localparam integer REQ_DEPTH = 8;
    localparam integer BURST_BEATS = 4;
    localparam integer READER_MAX = 2;
    localparam integer RSP_DEPTH = 2 * BURST_BEATS * READER_MAX;
    localparam integer BFM_DEPTH = 8;
    localparam integer MAX_CYCLES = 10000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid, cmd_ready;
    logic [ADDR_W-1:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;
    logic abort_req, abort_done, flush_req, flush_done;
    logic [EPOCH_W-1:0] current_epoch;

    logic refill_word_valid, refill_word_ready;
    logic [DATA_W-1:0] refill_word_data;
    logic refill_word_error, refill_word_last;
    logic [15:0] refill_word_row, refill_word_index;
    logic [EPOCH_W-1:0] refill_word_epoch;
    logic refill_done, refill_done_error, protocol_error;
    logic active, synthetic_active;
    logic [15:0] emitted_count;

    logic cmd_done, cmd_done_error;
    logic [15:0] cmd_done_row;
    logic [EPOCH_W-1:0] cmd_done_epoch;
    logic busy, quiescent, drain_pending;
    logic [7:0] outstanding, max_outstanding, cmd_occupancy;
    logic [63:0] perf_cmd_accept_count, perf_req_count, perf_rsp_count;
    logic [63:0] perf_word_count, perf_stale_count, perf_orphan_count;
    logic [63:0] perf_error_count;

    logic m_arvalid, m_arready;
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic [127:0] m_rdata;
    logic [1:0] m_rresp;
    logic m_rlast, m_rvalid, m_rready;
    logic leaf_busy;
    logic [63:0] leaf_req_count, leaf_burst_count, leaf_beat_count;
    logic [63:0] leaf_rsp_count, leaf_packed_count, leaf_error_count;
    logic [7:0] leaf_req_occ, leaf_max_req_occ, leaf_outstanding;
    logic [7:0] leaf_max_outstanding;

    c1_cache_refill_scheduler_read_client_exact #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(CMD_DEPTH), .SCHED_MAX_OUTSTANDING(SCHED_MAX),
        .REQ_FIFO_DEPTH(REQ_DEPTH), .BURST_BEATS(BURST_BEATS),
        .READER_MAX_OUTSTANDING(READER_MAX), .RSP_FIFO_DEPTH(RSP_DEPTH),
        .BUILD_TIMEOUT_CYCLES(2), .ALLOW_SCHED_REQ_HANDOFF(REQ_HANDOFF)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_base_addr, .cmd_stride_bytes,
        .cmd_row, .cmd_word_count, .cmd_epoch,
        .abort_req, .abort_done, .flush_req, .flush_done, .current_epoch,
        .refill_word_valid, .refill_word_ready, .refill_word_data,
        .refill_word_error, .refill_word_last, .refill_word_row,
        .refill_word_index, .refill_word_epoch, .refill_done,
        .refill_done_error, .protocol_error, .active, .synthetic_active,
        .emitted_count, .cmd_done, .cmd_done_error, .cmd_done_row,
        .cmd_done_epoch, .busy, .quiescent, .drain_pending, .outstanding,
        .max_outstanding_seen(max_outstanding), .cmd_occupancy,
        .perf_cmd_accept_count, .perf_req_count, .perf_rsp_count,
        .perf_word_count, .perf_stale_drop_count(perf_stale_count),
        .perf_orphan_rsp_count(perf_orphan_count), .perf_error_count,
        .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .leaf_perf_busy(leaf_busy),
        .leaf_perf_req_accept_count(leaf_req_count),
        .leaf_perf_axi_burst_count(leaf_burst_count),
        .leaf_perf_axi_beat_count(leaf_beat_count),
        .leaf_perf_rsp_count(leaf_rsp_count),
        .leaf_perf_packed_request_count(leaf_packed_count),
        .leaf_perf_error_count(leaf_error_count),
        .leaf_perf_req_occupancy(leaf_req_occ),
        .leaf_perf_max_req_occupancy(leaf_max_req_occ),
        .leaf_perf_outstanding(leaf_outstanding),
        .leaf_perf_max_outstanding(leaf_max_outstanding)
    );

    logic release_axi;
    logic sink_ready_ctl;
    integer cycle_count, ar_count, axi_beat_count, bfm_head, bfm_tail, bfm_count;
    integer bfm_beat, timeout_count;
    logic bfm_active, bfm_hold;
    logic [31:0] bfm_base_mem [0:BFM_DEPTH-1];
    integer bfm_beats_mem [0:BFM_DEPTH-1];
    wire ar_fire = m_arvalid && m_arready;
    wire r_fire = m_rvalid && m_rready;

    always_comb begin
        m_arready = release_axi && ((cycle_count % 4) != 1);
        m_rvalid = release_axi && bfm_active &&
                   (bfm_hold || ((cycle_count % 6) != 2));
        m_rresp = 2'b00;
        if (bfm_active && (bfm_count != 0)) begin
            m_rlast = (bfm_beat == (bfm_beats_mem[bfm_head] - 1));
            m_rdata = {
                64'hE000_0000_0000_0000 |
                    {32'd0, 32'(bfm_base_mem[bfm_head] + bfm_beat*16 + 32'd8)},
                64'hD000_0000_0000_0000 |
                    {32'd0, 32'(bfm_base_mem[bfm_head] + bfm_beat*16)}
            };
        end else begin
            m_rlast = 1'b0;
            m_rdata = '0;
        end
        refill_word_ready = sink_ready_ctl;
    end

    integer bi;
    always_ff @(posedge clk) begin
        if (rst) begin
            bfm_head <= 0;
            bfm_tail <= 0;
            bfm_count <= 0;
            bfm_active <= 1'b0;
            bfm_hold <= 1'b0;
            bfm_beat <= 0;
            cycle_count <= 0;
            ar_count <= 0;
            axi_beat_count <= 0;
            for (bi = 0; bi < BFM_DEPTH; bi = bi + 1) begin
                bfm_base_mem[bi] <= '0;
                bfm_beats_mem[bi] <= 0;
            end
        end else begin
            cycle_count <= cycle_count + 1;
            if (!bfm_active && (bfm_count != 0)) begin
                bfm_active <= 1'b1;
                bfm_beat <= 0;
                bfm_hold <= 1'b0;
            end
            if (ar_fire) begin
                if (bfm_count >= BFM_DEPTH)
                    $fatal(1, "exact composition BFM AR overflow");
                if (m_arsize != 3'd4 || m_arburst != 2'b01)
                    $fatal(1, "exact composition AXI attributes mismatch");
                if ((m_araddr >> 12) !=
                    ((m_araddr + (m_arlen + 1)*16 - 1) >> 12))
                    $fatal(1, "exact composition AR crossed 4KiB boundary");
                bfm_base_mem[bfm_tail] <= m_araddr;
                bfm_beats_mem[bfm_tail] <= m_arlen + 1;
                bfm_tail <= (bfm_tail + 1) % BFM_DEPTH;
                ar_count <= ar_count + 1;
            end
            if (r_fire) begin
                axi_beat_count <= axi_beat_count + 1;
                if (m_rlast) begin
                    bfm_active <= 1'b0;
                    bfm_head <= (bfm_head + 1) % BFM_DEPTH;
                end else begin
                    bfm_beat <= bfm_beat + 1;
                end
            end
            if (m_rvalid && !m_rready)
                bfm_hold <= 1'b1;
            else if (r_fire || !bfm_active)
                bfm_hold <= 1'b0;
            case ({ar_fire, (r_fire && m_rlast)})
                2'b10: bfm_count <= bfm_count + 1;
                2'b01: bfm_count <= bfm_count - 1;
                default: bfm_count <= bfm_count;
            endcase
        end
    end

    function automatic [63:0] expected_word(input integer index);
        logic [31:0] addr;
        begin
            addr = 32'h0000_4FF0 + 32'(index*8);
            expected_word = (addr[3] ? 64'hE000_0000_0000_0000 :
                                      64'hD000_0000_0000_0000) | {32'd0,addr};
        end
    endfunction
    integer output_count, drain_count, synthetic_count, expected_index;
    integer handoff_count;
    logic saw_done, saw_flush_done, done_error_seen;
    always_ff @(posedge clk) begin
        if (rst) begin
            output_count <= 0;
            handoff_count <= 0;
            drain_count <= 0;
            synthetic_count <= 0;
            expected_index <= 0;
            saw_done <= 1'b0;
            saw_flush_done <= 1'b0;
            done_error_seen <= 1'b0;
        end else begin
            if (dut.u_core.u_scheduler.launch_event && dut.u_core.u_scheduler.req_fire)
                handoff_count <= handoff_count + 1;
            if (refill_word_valid && refill_word_ready) begin
                if (refill_word_row !== 16'd11 ||
                    refill_word_index !== 16'(expected_index) ||
                    refill_word_epoch !== 3'd0 || refill_word_error !== 1'b1 ||
                    refill_word_last !== (expected_index == WORDS-1))
                    $fatal(1, "exact output mismatch idx=%0d row=%0d ep=%0d err=%0d last=%0d data=%h",
                           refill_word_index, refill_word_row, refill_word_epoch,
                           refill_word_error, refill_word_last, refill_word_data);
                if (expected_index < SCHED_MAX) begin
                    if (refill_word_data !== expected_word(expected_index))
                        $fatal(1, "exact drained data mismatch idx=%0d data=%h",
                               expected_index, refill_word_data);
                    drain_count <= drain_count + 1;
                end else begin
                    if (refill_word_data !== 64'd0)
                        $fatal(1, "exact synthetic data not zero idx=%0d",
                               expected_index);
                    synthetic_count <= synthetic_count + 1;
                end
                output_count <= output_count + 1;
                expected_index <= expected_index + 1;
            end
            if (refill_done) begin
                saw_done <= 1'b1;
                done_error_seen <= refill_done_error;
            end
            if (flush_done)
                saw_flush_done <= 1'b1;
        end
    end

    task automatic send_command;
        begin
            @(negedge clk);
            cmd_base_addr = 32'h0000_4FF0;
            cmd_stride_bytes = 32'd8;
            cmd_row = 16'd11;
            cmd_word_count = WORDS;
            cmd_epoch = 3'd0;
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
        cmd_base_addr = '0;
        cmd_stride_bytes = '0;
        cmd_row = '0;
        cmd_word_count = '0;
        cmd_epoch = '0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        release_axi = 1'b0;
        sink_ready_ctl = 1'b0;
        timeout_count = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        send_command();
        while (leaf_req_count < SCHED_MAX) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "exact composition did not fill request window=%0d accepted=%0d",SCHED_MAX,leaf_req_count);
        end

        // Fence while the unified sink is stalled.  Release AXI service only
        // after the edge so the accepted prefix must be drained through the
        // scheduler/adapter handshake rather than disappearing.
        @(negedge clk);
        flush_req = 1'b1;
        @(posedge clk);
        @(negedge clk);
        flush_req = 1'b0;
        repeat (3) @(posedge clk);
        release_axi = 1'b1;
        repeat (5) @(posedge clk);
        sink_ready_ctl = 1'b1;

        timeout_count = 0;
        while (!saw_done || !saw_flush_done) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
            if (timeout_count > MAX_CYCLES)
                $fatal(1, "exact composition timeout out=%0d drain=%0d synth=%0d leaf_busy=%0d active=%0d",
                       output_count, drain_count, synthetic_count,
                       leaf_busy, active);
        end
        @(negedge clk);
        if (output_count != WORDS || drain_count != SCHED_MAX ||
            synthetic_count != (WORDS-SCHED_MAX) ||
            // Expected cancellation poisons the data, not structural state.
            // The exact wrapper defaults CANCEL_IS_PROTOCOL_ERROR to zero.
            !done_error_seen || protocol_error || active ||
            synthetic_active || busy || !quiescent || drain_pending ||
            current_epoch != 3'd1 || perf_stale_count != SCHED_MAX ||
            leaf_req_count != SCHED_MAX || leaf_rsp_count != SCHED_MAX ||
            leaf_busy || ar_count == 0 || axi_beat_count == 0)
            $fatal(1, "exact composition result mismatch out=%0d drain=%0d synth=%0d done_err=%0d prot=%0d active=%0d busy=%0d q=%0d epoch=%0d stale=%0d req=%0d rsp=%0d ar=%0d beats=%0d",
                   output_count, drain_count, synthetic_count,
                   done_error_seen, protocol_error, active, busy,
                   quiescent, current_epoch, perf_stale_count,
                   leaf_req_count, leaf_rsp_count, ar_count, axi_beat_count);

        if (REQ_HANDOFF && SCHED_MAX > 1 && handoff_count == 0)
            $fatal(1, "exact composition did not exercise enabled handoff");
        if ((!REQ_HANDOFF || SCHED_MAX == 1) && handoff_count != 0)
            $fatal(1, "exact composition exercised forbidden handoff");
        $display("C1_EXACT_HANDOFF_COVERAGE enabled=%0d window=%0d handoffs=%0d full64=1",REQ_HANDOFF,SCHED_MAX,handoff_count);
        $display("C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS words=%0d drained=%0d synthetic=%0d req=%0d rsp=%0d ar=%0d beats=%0d flush=%0d cycles=%0d",
                 output_count, drain_count, synthetic_count,
                 leaf_req_count, leaf_rsp_count, ar_count, axi_beat_count,
                 saw_flush_done, cycle_count);
        $finish;
    end

    initial begin
        #120000;
        $fatal(1, "exact composition timeout watchdog");
    end
endmodule
