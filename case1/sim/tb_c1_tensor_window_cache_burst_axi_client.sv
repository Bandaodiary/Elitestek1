`timescale 1ns/1ps

// Standalone contract test for the optional tensor client-6 burst seam.
//
// This test intentionally does not instantiate the seven-client fabric.  The
// seam owns one ID-less AXI slot, so a compact in-order BFM is enough to prove
// the boundary that matters here:
//   * a cache miss is reserved before tap_ready and is refilled with packed
//     128-bit bursts;
//   * a same-row hit does not issue another burst;
//   * non-cacheable reads and writes use the legacy one-beat bridge;
//   * AR/R and AW/W/B back-pressure, plus a stalled local response, preserve
//     payload stability;
//   * a flush during a partially drained refill and an abort while a bridge
//     response is held complete only after the corresponding drain.
//
// The BFM returns a deterministic value derived from the byte address.  This
// makes row-base, lane packing, and upper/lower 64-bit bridge selection visible
// without a large memory image.
module tb_c1_tensor_window_cache_burst_axi_client;
`ifdef C1_TEST_PACKED_WRITES
    localparam integer PACKED_WRITES = 1;
`else
    localparam integer PACKED_WRITES = 0;
`endif
    localparam integer W = 4;
    localparam integer H = 2;
    localparam integer G = 2;
    localparam integer ROW_WORDS = W * G;
    localparam integer ROW_BYTES = ROW_WORDS * 8;
    localparam logic [31:0] BASE = 32'h0000_1000;
    localparam integer BFM_DEPTH = 16;
    localparam integer BURST_BEATS = 4;

`ifdef C1_BURST_BEAT_FIFO
    // Beat-record mode stores one AXI128 beat plus lane metadata per FIFO
    // entry.  For this directed test two outstanding four-beat bursts need
    // fewer than sixteen entries; retaining 16 leaves room for the flush /
    // response-hold cases without changing the request contract.
    localparam bit TB_RSP_FIFO_BEAT_MODE = 1'b1;
    localparam integer TB_RSP_FIFO_DEPTH = 16;
`else
    localparam bit TB_RSP_FIFO_BEAT_MODE = 1'b0;
    localparam integer TB_RSP_FIFO_DEPTH = 16;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic stage_start_valid = 1'b0;
    logic stage_start_ready;
    logic stage_cache_enable = 1'b1;
    logic [31:0] stage_base_addr = BASE;
    logic [15:0] stage_width = W;
    logic [15:0] stage_height = H;
    logic [3:0] stage_groups = G;
    logic stage_start_done;
    logic stage_cache_active, stage_cache_fallback;
    logic [3:0] stage_cache_reason;

    logic abort_req = 1'b0;
    logic abort_done;
    logic flush_req = 1'b0;
    logic flush_done;

    logic s_req_valid = 1'b0;
    logic s_req_ready;
    logic s_req_write = 1'b0;
    logic [31:0] s_req_addr = 32'd0;
    logic [63:0] s_req_wdata = 64'd0;
    logic [7:0] s_req_wstrb = 8'd0;
    logic s_req_cacheable = 1'b0;
    logic signed [16:0] s_req_cache_x = 17'sd0;
    logic signed [16:0] s_req_cache_y = 17'sd0;
    logic [2:0] s_req_cache_group = 3'd0;
    logic s_rsp_valid;
    logic s_rsp_ready = 1'b1;
    logic s_rsp_error;
    logic [63:0] s_rsp_rdata;

    logic m_axi_awvalid, m_axi_awready;
    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_wvalid, m_axi_wready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid, m_axi_bready;
    logic m_axi_arvalid, m_axi_arready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    logic cache_error;
    logic [2:0] cache_error_code;
    logic busy, quiescent;

    c1_tensor_window_cache_burst_axi_client #(
        .ENABLE_PACKED_WRITES(PACKED_WRITES),
        .BURST_LINE_ROWS(3),
        .BURST_MAX_ROW_WORDS(ROW_WORDS),
        .BURST_MAX_GROUPS(8),
        .BURST_EPOCH_W(4),
        .BURST_CMD_FIFO_DEPTH(2),
        .BURST_SCHED_MAX_OUTSTANDING(4),
        .BURST_REQ_FIFO_DEPTH(8),
        .BURST_BEATS(BURST_BEATS),
        .BURST_READER_MAX_OUTSTANDING(2),
        .BURST_RSP_FIFO_DEPTH(TB_RSP_FIFO_DEPTH),
        .BURST_RSP_FIFO_BEAT_MODE(TB_RSP_FIFO_BEAT_MODE),
        .BURST_BUILD_TIMEOUT_CYCLES(2),
        .BURST_REFILL_SKID_DEPTH(2)
    ) dut (
        .clk(clk), .rst(rst),
        .stage_start_valid(stage_start_valid),
        .stage_start_ready(stage_start_ready),
        .stage_cache_enable(stage_cache_enable),
        .stage_base_addr(stage_base_addr),
        .stage_width(stage_width), .stage_height(stage_height),
        .stage_groups(stage_groups),
        .stage_start_done(stage_start_done),
        .stage_cache_active(stage_cache_active),
        .stage_cache_fallback(stage_cache_fallback),
        .stage_cache_reason(stage_cache_reason),
        .abort_req(abort_req), .abort_done(abort_done),
        .flush_req(flush_req), .flush_done(flush_done),
        .s_req_valid(s_req_valid), .s_req_ready(s_req_ready),
        .s_req_write(s_req_write), .s_req_addr(s_req_addr),
        .s_req_wdata(s_req_wdata), .s_req_wstrb(s_req_wstrb),
        .s_req_cacheable(s_req_cacheable),
        .s_req_cache_x(s_req_cache_x), .s_req_cache_y(s_req_cache_y),
        .s_req_cache_group(s_req_cache_group),
        .s_rsp_valid(s_rsp_valid), .s_rsp_ready(s_rsp_ready),
        .s_rsp_error(s_rsp_error), .s_rsp_rdata(s_rsp_rdata),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .cache_error(cache_error), .cache_error_code(cache_error_code),
        .busy(busy), .quiescent(quiescent)
    );

    // ------------------------------------------------------------------
    // Deterministic in-order AXI read/write BFM with deliberate gaps.
    // ------------------------------------------------------------------
    integer cycle_count = 0;
    integer read_ar_count = 0;
    integer read_burst_ar_count = 0;
    integer read_single_ar_count = 0;
    integer read_beat_count = 0;
    integer write_aw_count = 0;
    integer write_w_count = 0;
    integer write_b_count = 0;
    integer flush_done_count = 0;
    integer abort_done_count = 0;
    integer ar_stall_count = 0;
    integer r_stall_count = 0;
    integer r_gap_count = 0;
    integer aw_stall_count = 0;
    integer w_stall_count = 0;
    integer local_req_fire_count = 0;
    integer burst_tap_fire_count = 0;

    integer rd_head = 0;
    integer rd_tail = 0;
    integer rd_count = 0;
    integer rd_beat = 0;
    integer rd_start_delay = 0;
    logic rd_active = 1'b0;
    logic rd_hold = 1'b0;
    logic allow_ar = 1'b1;
    logic allow_r = 1'b1;
    logic force_ar_block = 1'b0;
    logic force_aw_block = 1'b0;
    logic force_w_block = 1'b0;
    logic [31:0] rd_base [0:BFM_DEPTH-1];
    integer rd_len [0:BFM_DEPTH-1];

    logic wr_aw_seen = 1'b0;
    logic wr_w_seen = 1'b0;
    logic wr_b_scheduled = 1'b0;
    logic wr_b_valid = 1'b0;
    integer wr_b_delay = 0;
    logic [31:0] wr_addr_q = 32'd0;
    logic [127:0] wr_data_q = 128'd0;
    logic [15:0] wr_strb_q = 16'd0;
    logic [1:0] injected_bresp = 0;

    function automatic [63:0] value_for_addr(input logic [31:0] a);
        begin
            // The lower/upper marker also catches accidental half selection.
            value_for_addr = a[3] ?
                (64'hB000_0000_0000_0000 | {32'd0, {a[31:4], 4'd0}}) :
                (64'hA000_0000_0000_0000 | {32'd0, {a[31:4], 4'd0}});
        end
    endfunction

    function automatic [63:0] expected_tensor_word(
        input integer x, input integer y, input integer g
    );
        logic [31:0] a;
        begin
            a = BASE + ((y * ROW_WORDS + x * G + g) * 8);
            expected_tensor_word = value_for_addr(a);
        end
    endfunction

    always_comb begin
        m_axi_arready = !rst && allow_ar && !force_ar_block &&
                        (rd_count < BFM_DEPTH) &&
                        ((cycle_count % 5) != 1);
        m_axi_rvalid = !rst && allow_r && rd_active &&
                       (rd_hold || ((cycle_count % 4) != 2));
        m_axi_rresp = 2'b00;
        if (rd_active) begin
            m_axi_rdata = {
                value_for_addr(rd_base[rd_head] + rd_beat * 16 + 8),
                value_for_addr(rd_base[rd_head] + rd_beat * 16)
            };
            m_axi_rlast = (rd_beat == (rd_len[rd_head] - 1));
        end else begin
            m_axi_rdata = 128'd0;
            m_axi_rlast = 1'b0;
        end

        m_axi_awready = !rst && !wr_aw_seen && !wr_b_scheduled &&
                        !force_aw_block &&
                        ((cycle_count % 4) != 1);
        m_axi_wready = !rst && !wr_w_seen && !wr_b_scheduled &&
                       !force_w_block &&
                       ((cycle_count % 5) != 2);
        m_axi_bvalid = wr_b_valid;
        m_axi_bresp = injected_bresp;
    end

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

`ifndef SYNTHESIS
    // Keep routine output silent.  The detached runner retains only the PASS
    // marker and the tail of each tool log; the DUT-local assertions and the
    // bounded timeout diagnostics below remain available on a failure.
`endif

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            read_ar_count <= 0;
            read_burst_ar_count <= 0;
            read_single_ar_count <= 0;
            read_beat_count <= 0;
            write_aw_count <= 0;
            write_w_count <= 0;
            write_b_count <= 0;
            flush_done_count <= 0;
            abort_done_count <= 0;
            ar_stall_count <= 0;
            r_stall_count <= 0;
            r_gap_count <= 0;
            aw_stall_count <= 0;
            w_stall_count <= 0;
            local_req_fire_count <= 0;
            burst_tap_fire_count <= 0;
            rd_head <= 0;
            rd_tail <= 0;
            rd_count <= 0;
            rd_beat <= 0;
            rd_start_delay <= 0;
            rd_active <= 1'b0;
            rd_hold <= 1'b0;
            force_ar_block <= 1'b0;
            force_aw_block <= 1'b0;
            force_w_block <= 1'b0;
            wr_aw_seen <= 1'b0;
            wr_w_seen <= 1'b0;
            wr_b_scheduled <= 1'b0;
            wr_b_valid <= 1'b0;
            wr_b_delay <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_count <= ar_stall_count + 1;
            if (m_axi_rvalid && !m_axi_rready)
                r_stall_count <= r_stall_count + 1;
            // A valid-low interval while an accepted read burst is active is
            // the complementary AXI back-pressure/gap case.  It is useful in
            // this compact BFM because the response FIFO is intentionally
            // large enough that a stalled local response need not fill it.
            if (rd_count != 0 && allow_r && !m_axi_rvalid)
                r_gap_count <= r_gap_count + 1;
            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_count <= aw_stall_count + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_count <= w_stall_count + 1;
            if (s_req_valid && s_req_ready)
                local_req_fire_count <= local_req_fire_count + 1;
            if (dut.burst_tap_fire)
                burst_tap_fire_count <= burst_tap_fire_count + 1;

            if (!rd_active && rd_count != 0) begin
                if (rd_start_delay != 0)
                    rd_start_delay <= rd_start_delay - 1;
                else begin
                    rd_active <= 1'b1;
                    rd_beat <= 0;
                    rd_hold <= 1'b0;
                end
            end

            if (ar_fire) begin
                if (m_axi_arsize != 3'd4 || m_axi_arburst != 2'b01)
                    $fatal(1, "burst client emitted invalid AR attributes");
                if ((m_axi_araddr[31:12]) !=
                    ((m_axi_araddr + (m_axi_arlen + 1) * 16 - 1) >> 12))
                    $fatal(1, "burst client crossed a 4-KiB boundary");
                if ((m_axi_arlen + 1) > BURST_BEATS && m_axi_arlen != 0)
                    $fatal(1, "unexpectedly long packed burst len=%0d", m_axi_arlen);
                rd_base[rd_tail] <= m_axi_araddr;
                rd_len[rd_tail] <= m_axi_arlen + 1;
                rd_tail <= (rd_tail + 1) % BFM_DEPTH;
                read_ar_count <= read_ar_count + 1;
                if (m_axi_arlen == 0)
                    read_single_ar_count <= read_single_ar_count + 1;
                else
                    read_burst_ar_count <= read_burst_ar_count + 1;
                if (rd_count == 0 && !rd_active)
                    rd_start_delay <= 2;
            end

            if (r_fire) begin
                read_beat_count <= read_beat_count + 1;
                if (m_axi_rlast) begin
                    rd_active <= 1'b0;
                    rd_head <= (rd_head + 1) % BFM_DEPTH;
                end else
                    rd_beat <= rd_beat + 1;
            end
            if (m_axi_rvalid && !m_axi_rready)
                rd_hold <= 1'b1;
            else if (r_fire || !rd_active)
                rd_hold <= 1'b0;

            case ({ar_fire, (r_fire && m_axi_rlast)})
                2'b10: rd_count <= rd_count + 1;
                2'b01: rd_count <= rd_count - 1;
                default: rd_count <= rd_count;
            endcase

            if (aw_fire) begin
                if (m_axi_awlen != 0 || m_axi_awsize != 3'd4 ||
                    m_axi_awburst != 2'b01 || m_axi_awaddr[3:0] != 0)
                    $fatal(1, "invalid bridge AW attributes");
                write_aw_count <= write_aw_count + 1;
                wr_aw_seen <= 1'b1;
                wr_addr_q <= m_axi_awaddr;
            end
            if (w_fire) begin
                if (!m_axi_wlast || m_axi_wstrb == 0)
                    $fatal(1, "invalid bridge W payload");
                write_w_count <= write_w_count + 1;
                wr_w_seen <= 1'b1;
                wr_data_q <= m_axi_wdata;
                wr_strb_q <= m_axi_wstrb;
            end
            if (!wr_b_scheduled && (wr_aw_seen || aw_fire) &&
                (wr_w_seen || w_fire)) begin
                wr_b_scheduled <= 1'b1;
                wr_b_delay <= 2;
            end
            if (wr_b_scheduled && !wr_b_valid) begin
                if (wr_b_delay == 0)
                    wr_b_valid <= 1'b1;
                else
                    wr_b_delay <= wr_b_delay - 1;
            end
            if (b_fire) begin
                write_b_count <= write_b_count + 1;
                wr_b_valid <= 1'b0;
                wr_b_scheduled <= 1'b0;
                wr_aw_seen <= 1'b0;
                wr_w_seen <= 1'b0;
            end

            if (flush_done)
                flush_done_count <= flush_done_count + 1;
            if (abort_done)
                abort_done_count <= abort_done_count + 1;

            if (m_axi_arvalid && (m_axi_awvalid || m_axi_wvalid))
                $fatal(1, "burst client overlapped AXI read and write owners");
        end
    end

    // ------------------------------------------------------------------
    // Local request helpers.
    // ------------------------------------------------------------------
    task automatic start_stage;
        integer guard;
        begin
            @(negedge clk);
            stage_start_valid = 1'b1;
            guard = 0;
            while (stage_start_ready !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "stage_start_ready timeout");
            end
            @(posedge clk);
            @(negedge clk);
            stage_start_valid = 1'b0;
            guard = 0;
            while (stage_start_done !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "stage_start_done timeout");
            end
            if (!stage_cache_active || stage_cache_fallback ||
                stage_cache_reason != 0)
                $fatal(1, "burst stage did not activate active=%0b fallback=%0b reason=%0d",
                       stage_cache_active, stage_cache_fallback,
                       stage_cache_reason);
        end
    endtask

    task automatic config_while_response_held;
        integer guard;
        begin
            start_stage();
            @(negedge clk);
            s_rsp_ready=0;s_req_write=0;s_req_addr=BASE;s_req_wdata=0;
            s_req_wstrb=0;s_req_cacheable=1;s_req_cache_x=0;
            s_req_cache_y=0;s_req_cache_group=0;s_req_valid=1;
            guard=0;
            do begin
                @(posedge clk);guard++;
                if(guard>5000) $fatal(1,"config fence read acceptance timeout");
            end while(!s_req_ready);
            @(negedge clk);s_req_valid=0;
            guard=0;
            while(!s_rsp_valid) begin
                @(negedge clk);guard++;
                if(guard>5000) $fatal(1,"config fence response timeout");
            end
            stage_start_valid=1;
            repeat(12) begin
                @(posedge clk);#1;
                if(stage_start_ready || stage_start_done || !s_rsp_valid ||
                   s_rsp_error || s_rsp_rdata!==expected_tensor_word(0,0,0))
                    $fatal(1,"new config crossed held old response");
            end
            @(negedge clk);s_rsp_ready=1;
            @(posedge clk);
            @(negedge clk);s_rsp_ready=0;
            guard=0;
            do begin
                @(posedge clk);guard++;
                if(guard>100) $fatal(1,"config fence did not release after response");
            end while(!stage_start_ready);
            @(negedge clk);stage_start_valid=0;
            guard=0;
            while(!stage_start_done) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"new config did not complete");
            end
            if(!stage_cache_active || stage_cache_fallback || stage_cache_reason!=0)
                $fatal(1,"post-response config rejected");
            $display("C1_CACHE_CONFIG_RESPONSE_FENCE_PASS held_cycles=12 config_after_retire=1");
        end
    endtask

    task automatic issue_read(
        input logic [31:0] addr,
        input integer x,
        input integer y,
        input integer g,
        input logic cacheable,
        input logic [63:0] expected,
        input integer response_stalls
    );
        integer guard;
        logic [63:0] held_data;
        logic held_error;
        begin
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = addr;
            s_req_wdata = 64'd0;
            s_req_wstrb = 8'd0;
            s_req_cacheable = cacheable;
            s_req_cache_x = x;
            s_req_cache_y = y;
            s_req_cache_group = g;
            s_req_valid = 1'b1;
            guard = 0;
            // READY can briefly rise when the refill row becomes valid.  Do
            // not withdraw VALID on that observation alone: the wrapper may
            // still be holding a miss tap for the child cache.  The owner
            // register is the testbench-visible proof that the logical
            // request was actually accepted (and pending=0 proves a miss
            // tap was admitted).
            while ((dut.owner_q === 2'd0) ||
                   ((dut.owner_q === 2'd1) &&
                    (dut.burst_tap_pending_q === 1'b1))) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "read request ready timeout x/y/g=%0d/%0d/%0d", x,y,g);
            end
            @(negedge clk);
            s_req_valid = 1'b0;

            s_rsp_ready = 1'b0;
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
                if (guard > 5000)
                    $display("DBG_READ_TIMEOUT owner=%0d pending=%0b route_burst=%0b route_bridge=%0b stage_cfg=%0b tap=%0b/%0b ar=%0b/%0b r=%0b/%0b arcnt=%0d beats=%0d reqfire=%0d tapfire=%0d bq=%0b eq=%0b cstate=%0d exact_out=%0d sk=%0d",
                             dut.owner_q, dut.burst_tap_pending_q,
                             dut.route_burst, dut.route_bridge,
                             dut.burst_config_valid, dut.burst_tap_valid,
                             dut.burst_tap_ready, dut.burst_arvalid,
                             dut.burst_arready, dut.burst_rvalid,
                             dut.burst_rready, read_ar_count,
                             read_beat_count, local_req_fire_count,
                             burst_tap_fire_count, dut.burst_busy,
                             dut.burst_quiescent,
                             dut.u_burst_cache.g_scalar.u_cache.state_q,
                             dut.u_burst_cache.u_exact.core_outstanding,
                             dut.u_burst_cache.skid_count_q);
                if (guard > 5000)
                    $fatal(1, "read response timeout x/y/g=%0d/%0d/%0d", x,y,g);
            end
            held_data = s_rsp_rdata;
            held_error = s_rsp_error;
            repeat (response_stalls) begin
                @(posedge clk);
                if (!s_rsp_valid || s_rsp_rdata !== held_data ||
                    s_rsp_error !== held_error)
                    $fatal(1, "local response changed while stalled");
            end
            if (held_error || held_data !== expected)
                $fatal(1, "read mismatch addr=%h x/y/g=%0d/%0d/%0d got err/data=%0b/%h exp=%h",
                       addr, x,y,g, held_error, held_data, expected);
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "read response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
        end
    endtask

    task automatic issue_write(
        input logic [31:0] addr,
        input logic [63:0] data,
        input integer response_stalls
    );
        integer guard;
        begin
            @(negedge clk);
            s_req_write = 1'b1;
            s_req_addr = addr;
            s_req_wdata = data;
            s_req_wstrb = 8'hA5;
            s_req_cacheable = 1'b0;
            s_req_cache_x = 0;
            s_req_cache_y = 0;
            s_req_cache_group = 0;
            s_req_valid = 1'b1;
            // Hold both write channels closed briefly after the request is
            // presented.  This makes AW/W back-pressure coverage deterministic
            // instead of depending on the modulo phase of a short bridge
            // transaction.
            force_aw_block = 1'b1;
            force_w_block = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "write request ready timeout");
            end while (!s_req_ready);
            @(negedge clk);
            s_req_valid = 1'b0;
            // Count the actual request handshake, not owner residence: a
            // pipelined writer may accept another request on the next edge.
            repeat (16) @(negedge clk);
            force_aw_block = 1'b0;
            force_w_block = 1'b0;
            s_rsp_ready = 1'b0;
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "write response timeout");
            end
            if (s_rsp_error)
                $fatal(1, "bridge write returned an error");
            repeat (response_stalls) begin
                @(posedge clk);
                if (!s_rsp_valid || s_rsp_error)
                    $fatal(1, "write response changed while stalled");
            end
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "write response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
        end
    endtask

    // Fence the cache after a miss has claimed the owner but before the
    // line-cache REFILL_REQ command reaches the exact scheduler.  This is a
    // distinct corner from an already-issued AR: the command bridge must
    // capture the visible request on the fence edge, then let the old-epoch
    // rejection synthesize the exact-count drain so ST_REFILL_REQ cannot
    // strand the child forever.
    task automatic issue_flush_before_ar;
        integer guard;
        integer ar_before;
        logic [63:0] expected;
        begin
            expected = expected_tensor_word(0, 1, 0);
            ar_before = read_burst_ar_count;
            allow_ar = 1'b0;
            allow_r = 1'b1;
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = BASE + ROW_BYTES;
            s_req_wdata = 0;
            s_req_wstrb = 0;
            s_req_cacheable = 1'b1;
            s_req_cache_x = 0;
            s_req_cache_y = 1;
            s_req_cache_group = 0;
            s_req_valid = 1'b1;

            guard = 0;
            while (!((dut.owner_q == 2'd1) &&
                     dut.burst_tap_pending_q &&
                     dut.u_burst_cache.g_scalar.u_cache.refill_req_valid)) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "pre-AR flush did not reach pending refill request");
            end

            @(negedge clk);
            flush_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            flush_req = 1'b0;
            allow_ar = 1'b1;

            s_rsp_ready = 1'b0;
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "pre-AR flush replay response timeout");
            end
            if (s_rsp_error || s_rsp_rdata !== expected)
                $fatal(1, "pre-AR flush replay mismatch err/data=%0b/%h exp=%h",
                       s_rsp_error, s_rsp_rdata, expected);
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "pre-AR flush response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
            s_req_valid = 1'b0;

            guard = 0;
            while (flush_done !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "pre-AR flush_done timeout");
            end
            if (read_burst_ar_count != ar_before)
                $fatal(1, "pre-AR flush leaked a packed AR before command acceptance");
            if (cache_error || !stage_cache_active || stage_cache_fallback)
                $fatal(1, "pre-AR flush left cache poisoned error=%0b active/fallback=%0b/%0b",
                       cache_error, stage_cache_active, stage_cache_fallback);
        end
    endtask

    // Symmetric fence coverage for abort: hold a cache miss after the line
    // cache has presented REFILL_REQ but before the exact reader accepts the
    // command, with AR blocked so no packed transfer can sneak through.  The
    // wrapper must drain the old epoch, replay the still-held request through
    // the bridge, and only then pulse abort_done.  Abort invalidates the
    // cache-stage configuration, so the caller restarts the stage before
    // continuing with the ordinary sequence.
    task automatic issue_abort_before_ar;
        integer guard;
        integer ar_before;
        logic [63:0] expected;
        begin
            expected = expected_tensor_word(0, 1, 0);
            ar_before = read_burst_ar_count;
            allow_ar = 1'b0;
            allow_r = 1'b1;
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = BASE + ROW_BYTES;
            s_req_wdata = 0;
            s_req_wstrb = 0;
            s_req_cacheable = 1'b1;
            s_req_cache_x = 0;
            s_req_cache_y = 1;
            s_req_cache_group = 0;
            s_req_valid = 1'b1;

            guard = 0;
            while (!((dut.owner_q == 2'd1) &&
                     dut.burst_tap_pending_q &&
                     dut.u_burst_cache.g_scalar.u_cache.refill_req_valid)) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "pre-AR abort did not reach pending refill request");
            end

            @(negedge clk);
            abort_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort_req = 1'b0;
            allow_ar = 1'b1;

            // The no-withdrawal request is replayed through the bridge.  As
            // with the flush test, consume that response before waiting for
            // abort_done because the wrapper's fence join includes it.
            s_rsp_ready = 1'b0;
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "pre-AR abort replay response timeout");
            end
            if (s_rsp_error || s_rsp_rdata !== expected)
                $fatal(1, "pre-AR abort replay mismatch err/data=%0b/%h exp=%h",
                       s_rsp_error, s_rsp_rdata, expected);
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "pre-AR abort response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
            s_req_valid = 1'b0;

            guard = 0;
            while (abort_done !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "pre-AR abort_done timeout");
            end
            if (read_burst_ar_count != ar_before)
                $fatal(1, "pre-AR abort leaked a packed AR before command acceptance");
            if (cache_error || stage_cache_fallback)
                $fatal(1, "pre-AR abort left cache poisoned error/fallback=%0b/%0b",
                       cache_error, stage_cache_fallback);
        end
    endtask

    // Hold a cache miss through a flush.  The request is intentionally kept
    // valid across the fence; the cache client must not withdraw it and must
    // retry it after the canceled refill is drained.
    task automatic issue_flush_miss;
        integer guard;
        integer ar_before;
        logic [63:0] expected;
        begin
            expected = expected_tensor_word(0, 1, 0);
            ar_before = read_burst_ar_count;
            allow_r = 1'b1;
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = BASE + ROW_BYTES;
            s_req_wdata = 0;
            s_req_wstrb = 0;
            s_req_cacheable = 1'b1;
            s_req_cache_x = 0;
            s_req_cache_y = 1;
            s_req_cache_group = 0;
            s_req_valid = 1'b1;

            // Force a bounded AR-ready hole once the packed request is
            // visible.  The modulo phase is intentionally not relied upon
            // for coverage because the preceding maintenance tests can shift
            // the transaction onto a ready cycle.
            force_ar_block = 1'b1;
            guard = 0;
            while (!m_axi_arvalid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "flush miss did not present packed AR");
            end
            repeat (2) @(posedge clk);
            force_ar_block = 1'b0;

            guard = 0;
            while (read_burst_ar_count == ar_before) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 2000)
                    $fatal(1, "flush miss did not launch a packed AR");
            end
            // Leave at least one accepted AR outstanding, then close the
            // epoch.  Re-enable R after the one-cycle flush edge so the exact
            // reader can drain its accepted prefix and synthesize its suffix.
            allow_r = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            flush_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            flush_req = 1'b0;
            allow_r = 1'b1;

            // The held request now retries through the compatibility bridge.
            // The client intentionally keeps the fence pending until this
            // no-withdrawal request's response is consumed, so retire the
            // response before waiting for flush_done.
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 5000) begin
                    $display("DBG_FLUSH_TIMEOUT owner=%0d pend=%0b front=%0b replay=%0b abortp=%0b flushp=%0b burstq=%0b busy=%0b cfg=%0b cstate=%0d exout=%0d",
                             dut.owner_q, dut.burst_tap_pending_q,
                             dut.front_drain_q, dut.burst_replay_q,
                             dut.abort_pending_q, dut.flush_pending_q,
                             dut.burst_quiescent, dut.burst_busy,
                             dut.burst_config_valid,
                             dut.u_burst_cache.g_scalar.u_cache.state_q,
                             dut.u_burst_cache.u_exact.core_outstanding);
                    $display("DBG_FLUSH_TIMEOUT_CH ar=%0b/%0b r=%0b/%0b bridge_req=%0b/%0b inflight=%0b req=%0b/%0b rsp=%0b/%0b flush=%0b/%0b child=%0b exact=%0b rd=%0b/%0d/%0d/%0d",
                             dut.burst_arvalid, dut.burst_arready,
                             dut.burst_rvalid, dut.burst_rready,
                             dut.bridge_req_valid, dut.bridge_req_ready,
                             dut.bridge_inflight_q, s_req_valid, s_req_ready,
                             s_rsp_valid, s_rsp_ready, flush_req, flush_done,
                             dut.u_burst_cache.cache_flush_done,
                             dut.u_burst_cache.exact_flush_done,
                             rd_active, rd_count, rd_head, rd_beat);
                    $display("DBG_FLUSH_TIMEOUT_COUNT ar=%0d beats=%0d single=%0d burst=%0d",
                             read_ar_count, read_beat_count,
                             read_single_ar_count, read_burst_ar_count);
                    $fatal(1, "post-flush tap response timeout");
                end
            end
            if (s_rsp_error || s_rsp_rdata !== expected)
                $fatal(1, "post-flush tap mismatch got err/data=%0b/%h exp=%h",
                       s_rsp_error, s_rsp_rdata, expected);
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "post-flush response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
            s_req_valid = 1'b0;

            guard = 0;
            while (flush_done !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "flush_done timeout");
            end
        end
    endtask

    // Abort a cache miss before the line-cache tap is admitted.  This is the
    // corner that previously deadlocked the optional owner reservation: the
    // child must drain the packed refill, release OWNER_BURST, and replay the
    // still-held logical request through the one-beat bridge.
    task automatic issue_abort_pending_miss(input bit also_flush = 1'b0);
        integer guard;
        integer ar_before;
        integer abort_before, flush_before;
        logic [63:0] expected;
        begin
            expected = expected_tensor_word(0, 0, 0);
            ar_before = read_burst_ar_count;
            abort_before = abort_done_count;
            flush_before = flush_done_count;
            allow_r = 1'b1;
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = BASE;
            s_req_wdata = 0;
            s_req_wstrb = 0;
            s_req_cacheable = 1'b1;
            s_req_cache_x = 0;
            s_req_cache_y = 0;
            s_req_cache_group = 0;
            s_req_valid = 1'b1;

            guard = 0;
            while (read_burst_ar_count == ar_before) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 2000) begin
                    $display("DBG_ABORT_AR_TIMEOUT owner=%0d route_burst=%0b route_bridge=%0b stage_en=%0b cfg=%0b reject=%0b berr=%0b active=%0b fallback=%0b front=%0b replay=%0b abortp=%0b flushp=%0b cstate=%0d q=%0b arcount=%0d req=%0b/%0b",
                             dut.owner_q, dut.route_burst, dut.route_bridge,
                             dut.stage_cache_enable_q, dut.burst_config_valid,
                             dut.stage_reject_q, dut.burst_cache_error,
                             stage_cache_active, stage_cache_fallback,
                             dut.front_drain_q, dut.burst_replay_q,
                             dut.abort_pending_q, dut.flush_pending_q,
                             dut.u_burst_cache.g_scalar.u_cache.state_q,
                             dut.burst_quiescent, read_burst_ar_count,
                             s_req_valid, s_req_ready);
                    $fatal(1, "abort miss did not launch a packed AR");
                end
            end
            allow_r = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            abort_req = 1'b1;
            if (also_flush) flush_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort_req = 1'b0;
            if (also_flush) flush_req = 1'b0;
            allow_r = 1'b1;

            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "abort pending-miss response timeout");
            end
            if (s_rsp_error || s_rsp_rdata !== expected)
                $fatal(1, "abort pending-miss response mismatch err/data=%0b/%h exp=%h",
                       s_rsp_error, s_rsp_rdata, expected);
            if (also_flush) begin
                // Both fences must join the replayed front request. Neither
                // completion may escape while its logical response is held.
                repeat (12) begin
                    @(negedge clk);
                    if (!s_rsp_valid || s_rsp_error || s_rsp_rdata !== expected)
                        $fatal(1,"dual fence changed held replay response");
                    if (abort_done || flush_done ||
                        abort_done_count != abort_before ||
                        flush_done_count != flush_before)
                        $fatal(1,"dual fence acknowledged before replay response drained");
                end
            end
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "abort pending-miss response vanished before handshake");
            @(negedge clk);
            s_rsp_ready = 1'b0;
            s_req_valid = 1'b0;

            guard = 0;
            while (abort_done !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 5000)
                    $fatal(1, "abort_done timeout after pending miss");
            end
            if (also_flush) begin
                guard = 0;
                while (abort_done_count == abort_before ||
                       flush_done_count == flush_before) begin
                    @(negedge clk);
                    guard = guard + 1;
                    if (guard > 5000) $fatal(1,"dual fence join timeout");
                end
                repeat (12) @(negedge clk);
                if (abort_done_count != abort_before+1 ||
                    flush_done_count != flush_before+1 || !quiescent)
                    $fatal(1,"dual fence duplicate completion or missing quiescence");
                $display("C1_TENSOR_CACHE_DUAL_FENCE_PASS held_response_cycles=12 abort=1 flush=1");
            end
        end
    endtask

    // Abort is tested with a bridge response deliberately held at the local
    // seam.  The AXI B response may already have arrived, but abort_done must
    // wait until the local response is accepted.
    task automatic issue_abort_while_response_held(input bit use_flush=0);
        integer guard,done_before;
        begin
            // Prior tasks may return on the edge that raises done. Let the
            // registered event counter consume it before taking this baseline.
            repeat(2) @(negedge clk);
            done_before=use_flush ? flush_done_count : abort_done_count;
            @(negedge clk);
            s_req_write = 1'b1;
            s_req_addr = BASE + 32'h508;
            s_req_wdata = 64'h0123_4567_89ab_cdef;
            s_req_wstrb = 8'h3C;
            s_req_cacheable = 1'b0;
            s_req_valid = 1'b1;
            while (s_req_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_req_valid = 1'b0;
            s_rsp_ready = 1'b0;
            guard = 0;
            while (s_rsp_valid !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 500)
                    $fatal(1, "abort write response timeout");
            end
            @(negedge clk);
            if(use_flush) flush_req=1; else abort_req=1;
            @(posedge clk);
            @(negedge clk);
            if(use_flush) flush_req=0; else abort_req=0;
            repeat (40) begin
                @(posedge clk);
                if (use_flush ? flush_done : abort_done)
                    $fatal(1, "abort completed before held response drained");
            end
            // A second cancel while this fence is pending must not discard
            // the child fence acknowledgement already remembered by the join.
            if(use_flush ? (!dut.flush_pending_q || !dut.flush_burst_seen_q) :
                           (!dut.abort_pending_q || !dut.abort_burst_seen_q))
                $fatal(1,"repeated maintenance fixture missed pending parent with acknowledged child");
            @(negedge clk);if(use_flush) flush_req=1; else abort_req=1;
            @(negedge clk);if(use_flush) flush_req=0; else abort_req=0;
            repeat(3) @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid || s_rsp_error)
                $fatal(1, "abort-held write response invalid at release");
            @(negedge clk);
            s_rsp_ready = 1'b0;
            guard = 0;
            while ((use_flush ? flush_done : abort_done) !== 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 100)
                    $fatal(1, "abort_done timeout after response drain");
            end
            repeat(12) @(negedge clk);
            if((use_flush ? flush_done_count : abort_done_count)!=done_before+1 || !quiescent)
                $fatal(1,"repeated maintenance mismatch flush=%b before=%0d after=%0d quiet=%b",use_flush,done_before,
                       use_flush ? flush_done_count : abort_done_count,quiescent);
            $display("C1_TENSOR_CACHE_REPEATED_MAINTENANCE_PASS flush=%0d held_cycles=40 pulses=2 completions=1",use_flush);
        end
    endtask

    task automatic check_packed_pair(input bit fault, input bit fence);
        integer aw_before, w_before, b_before, abort_before, flush_before;
        integer guard, n;
        begin
            aw_before=write_aw_count; w_before=write_w_count; b_before=write_b_count;
            abort_before=abort_done_count; flush_before=flush_done_count;
            injected_bresp=fault ? 2'b10 : 2'b00;
            s_rsp_ready=0;
            for (n=0;n<2;n=n+1) begin
                @(negedge clk);
                s_req_valid=1; s_req_write=1; s_req_cacheable=0;
                s_req_addr=32'h1ff0+n*8;
                s_req_wdata=64'h123456789abc0000+n;
                s_req_wstrb=8'hff;
                guard=0;
                do begin
                    @(posedge clk);
                    guard=guard+1;
                    if(guard>200) $fatal(1,"packed pair admission timeout");
                end while (!s_req_ready);
            end
            @(negedge clk); s_req_valid=0;
            guard=0;
            while (!s_rsp_valid) begin
                @(negedge clk); guard=guard+1;
                if(guard>200) $fatal(1,"packed pair response timeout");
            end
            if (write_aw_count != aw_before+1 || write_w_count != w_before+1 ||
                write_b_count != b_before+1 || wr_addr_q != 32'h1ff0 ||
                wr_strb_q != 16'hffff ||
                wr_data_q !== 128'h123456789abc0001_123456789abc0000)
                $fatal(1,"two logical writes were not committed as one correct AXI beat");
            if(fence) begin
                abort_req=1; flush_req=1;
                @(negedge clk); abort_req=0; flush_req=0;
            end
            repeat (12) begin
                @(negedge clk);
                if (!s_rsp_valid || s_rsp_error != fault || s_rsp_rdata != 0 ||
                    abort_done_count != abort_before || flush_done_count != flush_before)
                    $fatal(1,"packed response changed or maintenance completed before drain");
            end
            for(n=0;n<2;n=n+1) begin
                s_rsp_ready=1;
                guard=0;
                do begin
                    @(posedge clk); guard=guard+1;
                    if(guard>200) $fatal(1,"missing packed logical response");
                end while(!s_rsp_valid);
                if(s_rsp_error != fault || s_rsp_rdata != 0)
                    $fatal(1,"packed response error/data mismatch");
                @(negedge clk); s_rsp_ready=0;
                if(n==0 && (dut.owner_q != 2 || dut.bridge_pending_q != 1 || abort_done || flush_done))
                    $fatal(1,"packed owner released before second logical response");
            end
            guard=0;
            while(!quiescent) begin
                @(negedge clk); guard=guard+1;
                if(guard>200) $fatal(1,"packed pair maintenance drain timeout");
            end
            repeat(4) @(negedge clk);
            if(abort_done_count != abort_before+fence || flush_done_count != flush_before+fence)
                $fatal(1,"packed pair lost or duplicated fence completion");
            injected_bresp=0;
            $display("C1_PACKED_PAIR_OWNER_PASS fault=%0b fence=%0b logical=2 aw=1 w=1 b=1",fault,fence);
        end
    endtask

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;

        start_stage();

        // Exercise the symmetric abort-before-command corner on a fresh
        // stage.  Abort invalidates the line-cache configuration, so restart
        // the stage before the remaining cache-hit/refill checks.
        issue_abort_before_ar();
        start_stage();

        // Exercise the command-not-yet-accepted fence corner before the
        // ordinary refill/hit sequence.
        issue_flush_before_ar();

        // First miss: eight logical words must be packed into two four-beat
        // bursts.  A later same-row access is a hit and adds no burst.
        issue_read(BASE, 0, 0, 0, 1'b1,
                   expected_tensor_word(0, 0, 0), 3);
        if (read_burst_ar_count < 2 || read_beat_count < ROW_WORDS / 2)
            $fatal(1, "packed refill did not issue expected bursts ar=%0d beats=%0d",
                   read_burst_ar_count, read_beat_count);
        begin : hit_count_check
            integer ar_before;
            ar_before = read_burst_ar_count;
            issue_read(BASE, 1, 0, 1, 1'b1,
                       expected_tensor_word(1, 0, 1), 4);
            if (read_burst_ar_count != ar_before)
                $fatal(1, "same-row cache hit issued an unexpected refill");
        end

        // Legacy one-beat bridge bypasses.
        issue_read(BASE + 32'h400, 0, 0, 0, 1'b0,
                   value_for_addr(BASE + 32'h400), 2);
        issue_write(BASE + 32'h508, 64'h0123_4567_89ab_cdef, 3);
        if (read_single_ar_count < 1 || write_aw_count != 1 ||
            write_w_count != 1 || write_b_count != 1)
            $fatal(1, "bridge bypass accounting mismatch single_ar=%0d aw/w/b=%0d/%0d/%0d",
                   read_single_ar_count, write_aw_count, write_w_count,
                   write_b_count);

        issue_flush_miss();
        issue_abort_pending_miss();
        issue_abort_while_response_held();
        issue_abort_while_response_held(1'b1);

        // A fresh stage guarantees a miss. Simultaneous one-cycle abort and
        // flush must each acknowledge exactly once after the shared drain.
        start_stage();
        issue_abort_pending_miss(1'b1);
        if (PACKED_WRITES) begin
            check_packed_pair(0,0);
            check_packed_pair(1,0);
            check_packed_pair(0,1);
            check_packed_pair(1,1);
        end

        config_while_response_held();
        issue_read(BASE,0,0,0,1'b1,expected_tensor_word(0,0,0),3);
        repeat (10) @(posedge clk);
        if (cache_error || !quiescent || busy)
            $fatal(1, "burst client did not quiesce/error=%0b q/busy=%0b/%0b",
                   cache_error, quiescent, busy);
        if (ar_stall_count == 0 ||
            (r_stall_count == 0 && r_gap_count == 0) ||
            aw_stall_count == 0 || w_stall_count == 0)
            $fatal(1, "AXI back-pressure coverage missing ar/r-gap/aw/w=%0d/%0d/%0d/%0d/%0d",
                   ar_stall_count, r_stall_count, r_gap_count,
                   aw_stall_count, w_stall_count);
        $display("C1_TENSOR_CACHE_BURST_AXI_CLIENT_PASS burst_ar=%0d single_ar=%0d beats=%0d aw/w/b=%0d/%0d/%0d flush_done=%0d abort_done=%0d ar_stall=%0d r_stall=%0d r_gap=%0d aw_stall=%0d w_stall=%0d cycles=%0d",
                 read_burst_ar_count, read_single_ar_count, read_beat_count,
                 write_aw_count, write_w_count, write_b_count,
                 flush_done_count, abort_done_count, ar_stall_count,
                 r_stall_count, r_gap_count, aw_stall_count, w_stall_count,
                 cycle_count);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "tensor burst client standalone timeout");
    end
endmodule
