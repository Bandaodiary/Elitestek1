`timescale 1ns/1ps

// Compact wrapper smoke test.  It intentionally exercises only one short
// row: the purpose is to prove that the public wrapper ports elaborate and
// that command -> scheduler -> AXI128 reader -> word completion is wired
// correctly.  The larger protocol/throughput tests remain separate.
module tb_c1_cache_refill_scheduler_read_client_wrapper;
    localparam integer EPOCH_W = 3;
    localparam integer QDEPTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic cmd_valid, cmd_ready;
    logic [31:0] cmd_base_addr, cmd_stride_bytes;
    logic [15:0] cmd_row, cmd_word_count;
    logic [EPOCH_W-1:0] cmd_epoch;
    logic abort_req = 1'b0, abort_done;
    logic flush_req = 1'b0, flush_done;
    logic [EPOCH_W-1:0] current_epoch;
    logic word_valid, word_ready = 1'b1;
    logic [63:0] word_data;
    logic word_error, word_last;
    logic [15:0] word_row, word_index;
    logic [EPOCH_W-1:0] word_epoch;
    logic drain_word_valid;
    logic drain_word_ready = 1'b1;
    logic [63:0] drain_word_data;
    logic drain_word_error, drain_word_last;
    logic [15:0] drain_word_row, drain_word_index;
    logic [EPOCH_W-1:0] drain_word_epoch;
    logic cmd_done, cmd_done_error;
    logic [15:0] cmd_done_row;
    logic [EPOCH_W-1:0] cmd_done_epoch;
    logic busy, quiescent, drain_pending;
    logic [7:0] outstanding, max_outstanding_seen, cmd_occupancy;
    logic [63:0] perf_cmd_accept_count, perf_req_count, perf_rsp_count;
    logic [63:0] perf_word_count, perf_stale_drop_count;
    logic [63:0] perf_orphan_rsp_count, perf_error_count;

    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    logic leaf_perf_busy;
    logic [63:0] leaf_perf_req_accept_count, leaf_perf_axi_burst_count;
    logic [63:0] leaf_perf_axi_beat_count, leaf_perf_rsp_count;
    logic [63:0] leaf_perf_packed_request_count, leaf_perf_error_count;
    logic [7:0] leaf_perf_req_occupancy, leaf_perf_max_req_occupancy;
    logic [7:0] leaf_perf_outstanding, leaf_perf_max_outstanding;

    c1_cache_refill_scheduler_read_client #(
        .EPOCH_W(EPOCH_W),
        .CMD_FIFO_DEPTH(2),
        .SCHED_MAX_OUTSTANDING(4),
        .READER_MAX_OUTSTANDING(2),
        .EMIT_DRAIN_WORDS(0),
        .REQ_FIFO_DEPTH(4),
        .BURST_BEATS(2),
        .RSP_FIFO_DEPTH(8),
        .BUILD_TIMEOUT_CYCLES(2)
    ) dut (
        .clk, .rst,
        .cmd_valid, .cmd_ready, .cmd_base_addr, .cmd_stride_bytes,
        .cmd_row, .cmd_word_count, .cmd_epoch,
        .abort_req, .abort_done, .flush_req, .flush_done, .current_epoch,
        .word_valid, .word_ready, .word_data, .word_error, .word_last,
        .word_row, .word_index, .word_epoch,
        .drain_word_valid, .drain_word_ready, .drain_word_data,
        .drain_word_error, .drain_word_last, .drain_word_row,
        .drain_word_index, .drain_word_epoch,
        .cmd_done, .cmd_done_error, .cmd_done_row, .cmd_done_epoch,
        .busy, .quiescent, .drain_pending, .outstanding,
        .max_outstanding_seen, .cmd_occupancy, .perf_cmd_accept_count,
        .perf_req_count, .perf_rsp_count, .perf_word_count,
        .perf_stale_drop_count, .perf_orphan_rsp_count, .perf_error_count,
        .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
        .m_axi_arvalid, .m_axi_arready, .m_axi_rdata, .m_axi_rresp,
        .m_axi_rlast, .m_axi_rvalid, .m_axi_rready,
        .leaf_perf_busy, .leaf_perf_req_accept_count,
        .leaf_perf_axi_burst_count, .leaf_perf_axi_beat_count,
        .leaf_perf_rsp_count, .leaf_perf_packed_request_count,
        .leaf_perf_error_count, .leaf_perf_req_occupancy,
        .leaf_perf_max_req_occupancy, .leaf_perf_outstanding,
        .leaf_perf_max_outstanding
    );

    // In-order AXI read BFM.  Each AR is queued; one R beat is returned per
    // cycle when the reader is ready.  RDATA encodes the 16-byte beat base so
    // the scoreboard can verify both packed 64-bit lanes.
    logic [31:0] ar_base_mem [0:QDEPTH-1];
    integer ar_beats_mem [0:QDEPTH-1];
    integer ar_head, ar_tail, ar_count, r_beat;
    logic r_active;
    integer cycles, words_seen;
    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;

    always_comb begin
        m_axi_arready = 1'b1;
        m_axi_rvalid = r_active;
        m_axi_rresp = 2'b00;
        m_axi_rlast = r_active && (r_beat == ar_beats_mem[ar_head] - 1);
        m_axi_rdata = {
            64'hB000_0000_0000_0000 | {32'd0, ar_base_mem[ar_head] + r_beat*16 + 8},
            64'hA000_0000_0000_0000 | {32'd0, ar_base_mem[ar_head] + r_beat*16}
        };
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            ar_head <= 0;
            ar_tail <= 0;
            ar_count <= 0;
            r_beat <= 0;
            r_active <= 1'b0;
            cycles <= 0;
            words_seen <= 0;
            for (i = 0; i < QDEPTH; i = i + 1) begin
                ar_base_mem[i] <= 0;
                ar_beats_mem[i] <= 0;
            end
        end else begin
            cycles <= cycles + 1;
            if (ar_fire) begin
                if (ar_count >= QDEPTH)
                    $fatal(1, "wrapper smoke AXI queue overflow");
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "wrapper smoke AXI attributes mismatch");
                ar_base_mem[ar_tail] <= m_axi_araddr;
                ar_beats_mem[ar_tail] <= m_axi_arlen + 1;
                ar_tail <= (ar_tail + 1) % QDEPTH;
                if (!r_active) begin
                    r_active <= 1'b1;
                    r_beat <= 0;
                end
            end
            if (r_fire) begin
                if (m_axi_rlast) begin
                    r_active <= 1'b0;
                    ar_head <= (ar_head + 1) % QDEPTH;
                    if ((ar_count + (ar_fire ? 1 : 0)) > 1) begin
                        r_active <= 1'b1;
                        r_beat <= 0;
                    end
                end else begin
                    r_beat <= r_beat + 1;
                end
            end
            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: ar_count <= ar_count + 1;
                2'b01: ar_count <= ar_count - 1;
                default: ar_count <= ar_count;
            endcase
            if (word_valid && word_ready)
                words_seen <= words_seen + 1;
        end
    end

    initial begin
        cmd_valid = 1'b0;
        cmd_base_addr = 32'h0000_1000;
        cmd_stride_bytes = 32'd8;
        cmd_row = 16'd7;
        cmd_word_count = 16'd3;
        cmd_epoch = '0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        cmd_valid = 1'b1;
        while (!cmd_ready)
            @(posedge clk);
        @(posedge clk);
        cmd_valid = 1'b0;
        wait (cmd_done);
        if (cmd_done_error || cmd_done_row != 16'd7 || words_seen != 3)
            $fatal(1, "wrapper smoke completion mismatch done_error=%0d row=%0d words=%0d",
                   cmd_done_error, cmd_done_row, words_seen);
        if (perf_error_count != 0 || leaf_perf_error_count != 0)
            $fatal(1, "wrapper smoke reported error");
        $display("C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PASS words=%0d bursts=%0d beats=%0d cycles=%0d",
                 words_seen, leaf_perf_axi_burst_count,
                 leaf_perf_axi_beat_count, cycles);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "wrapper smoke timeout");
    end
endmodule
