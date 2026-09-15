`timescale 1ns/1ps

// Optional ID-less AXI4-128 write-burst arbiter.
//
// The legacy c1_axi_n_serial_arbiter_128 locks one client from AW through B.
// That is simple and safe, but it also means that a high-latency DDR B
// response prevents another writer from even presenting AW.  This seam keeps
// the same no-ID ordering contract while allowing several AW descriptors to
// be accepted and issued ahead of the current W/B transaction.
//
// The downstream W stream is strictly ordered, with no beat interleaving.
// Default mode holds its owner through B. W_AHEAD_OF_B uses a separate W
// cursor so the next burst can send data as soon as the current W completes,
// even while its B is pending. B responses still retire in descriptor order.
// Thus the module does not require AXI IDs. It is intended for several independent
// writers (capture, tensor, display); it does not change the legacy top.
//
// A malformed slave/client is contained and reported through sticky flags:
// an unsolicited B, B before the current W burst has completed, an early
// WLAST, or a missing WLAST at the AWLEN-derived terminal beat.  The AXI
// protocol itself requires well-formed W/B traffic; the flags are diagnostics,
// not a promise to recover arbitrary corruption.
module c1_axi_n_write_burst_arbiter_128 #(
    parameter integer CLIENTS = 3,
    parameter integer FIFO_DEPTH = 4,
    parameter integer INDEX_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
    parameter integer PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    parameter integer COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1),
    // Optional one-cycle empty-queue latency bypass.  When enabled, a
    // selected client may handshake AW directly with the downstream master
    // while the descriptor FIFO is empty.  If downstream AWREADY is low, the
    // same AW is still accepted into the empty descriptor slot and becomes a
    // registered FIFO output on the following cycle.  This is the usual
    // fall-through FIFO pattern: it avoids a ready-dependent upstream
    // handshake while preserving a stable downstream VALID payload.  Default
    // zero keeps the original enqueue-then-issue timing for existing
    // integrations.
    parameter bit EMPTY_AW_BYPASS = 1'b0,
    // Optional independent W cursor: a completed burst releases the data
    // channel to the next descriptor without waiting for its B response.
    // AW and W remain strictly ordered; B still retires the oldest slot.
    // Default zero preserves the legacy W-through-B serialization.
    parameter bit W_AHEAD_OF_B = 1'b0
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

    output logic                         protocol_error,
    output logic                         early_wlast_error,
    output logic                         missing_wlast_error,
    output logic                         early_b_error,
    output logic                         orphan_b_error,
    output logic [7:0]                   perf_outstanding,
    output logic [7:0]                   perf_max_outstanding,
    output logic [63:0]                  perf_aw_accept_count,
    output logic [63:0]                  perf_aw_issue_count,
    output logic [63:0]                  perf_w_beat_count,
    output logic [63:0]                  perf_b_count,
    // Accepted-descriptor status, not a fence on unaccepted upstream VALID.
    // write_owner is the oldest unretired B owner, NOT the only active writer.
    // W may already belong to a later descriptor; use write_data_owner for
    // the oldest W-pending descriptor (which may be temporarily ineligible).
    output logic                         write_busy,
    output logic                         write_quiescent,
    output logic [INDEX_W-1:0]           write_owner,
    output logic                         write_data_busy,
    output logic [INDEX_W-1:0]           write_data_owner
);

    initial begin
        if (CLIENTS < 1)
            $fatal(1, "write arbiter CLIENTS must be positive");
        if (FIFO_DEPTH < 2)
            $fatal(1, "write arbiter FIFO_DEPTH must be at least two");
        // The public occupancy/perf ports are 8 bits.  Keep the descriptor
        // count in that representable range rather than silently wrapping a
        // depth-256 queue to zero at its peak.
        if (FIFO_DEPTH > 255)
            $fatal(1, "write arbiter FIFO_DEPTH must be <= 255");
    end

    logic [INDEX_W-1:0] owner_mem [0:FIFO_DEPTH-1];
    logic [31:0]        addr_mem  [0:FIFO_DEPTH-1];
    logic [7:0]         len_mem   [0:FIFO_DEPTH-1];
    logic [2:0]         size_mem  [0:FIFO_DEPTH-1];
    logic [1:0]         burst_mem [0:FIFO_DEPTH-1];
    logic               aw_issued_mem [0:FIFO_DEPTH-1];
    logic               w_done_mem    [0:FIFO_DEPTH-1];

    logic [PTR_W-1:0] head_q, tail_q, issue_q;
    logic [PTR_W-1:0] w_issue_q, w_slot_comb;
    logic [COUNT_W-1:0] w_pending_count_q;
    logic [COUNT_W-1:0] count_q;
    logic [COUNT_W-1:0] issued_count_q;
    logic [INDEX_W-1:0] rr_q;
    logic [7:0] w_beat_q;

    logic [INDEX_W-1:0] grant_idx_comb;
    logic grant_valid_comb;
    integer arb_offset;
    integer arb_scan_index;

    logic aw_accept, aw_issue_fire, w_fire, b_fire, retire_b_fire;
    logic w_active_comb, b_active_comb;
    logic expected_wlast_comb, terminal_w_comb;
    logic [INDEX_W-1:0] w_owner_comb, b_owner_comb;
    logic slot_space_comb;

    logic early_wlast_error_q, missing_wlast_error_q;
    logic early_b_error_q, orphan_b_error_q;

    function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] value);
        begin
            if (value == FIFO_DEPTH - 1)
                ptr_inc = '0;
            else
                ptr_inc = value + 1'b1;
        end
    endfunction

    function automatic [INDEX_W-1:0] next_client(
        input [INDEX_W-1:0] current
    );
        begin
            if (current == CLIENTS - 1)
                next_client = '0;
            else
                next_client = current + 1'b1;
        end
    endfunction

    // Round-robin AW admission.  The selected client owns the upstream VALID
    // hold contract.  In bypass mode a stalled direct AW is captured on the
    // first handshake; subsequent cycles use the memory-backed descriptor,
    // so the downstream payload remains stable while VALID is stalled.
    always_comb begin
        slot_space_comb = (count_q < FIFO_DEPTH);
        grant_valid_comb = 1'b0;
        grant_idx_comb = rr_q;
        if (!rst && slot_space_comb) begin
            for (arb_offset = 0; arb_offset < CLIENTS;
                 arb_offset = arb_offset + 1) begin
                arb_scan_index = rr_q + arb_offset;
                if (arb_scan_index >= CLIENTS)
                    arb_scan_index = arb_scan_index - CLIENTS;
                if (!grant_valid_comb && s_awvalid[arb_scan_index]) begin
                    grant_valid_comb = 1'b1;
                    grant_idx_comb = arb_scan_index[INDEX_W-1:0];
                end
            end
        end
    end

    // Downstream AW is issued in acceptance order.  issued_count_q counts
    // descriptors which have crossed AW but not yet crossed B, so AW may run
    // ahead of the current W/B head until the descriptor FIFO is full.
    always_comb begin
        s_awready = '0;
        if (grant_valid_comb)
            // Even in bypass mode, capture a stalled AW into the empty FIFO.
            // The descriptor memory then holds the payload while downstream
            // READY is low; no combinational READY path is needed.
            s_awready[grant_idx_comb] = 1'b1;
        aw_accept = grant_valid_comb && s_awvalid[grant_idx_comb] &&
                    s_awready[grant_idx_comb];

        m_awaddr = 32'd0;
        m_awlen = 8'd0;
        m_awsize = 3'd0;
        m_awburst = 2'd0;
        m_awvalid = 1'b0;
        if (!rst && (issued_count_q < count_q)) begin
            m_awaddr = addr_mem[issue_q];
            m_awlen = len_mem[issue_q];
            m_awsize = size_mem[issue_q];
            m_awburst = burst_mem[issue_q];
            m_awvalid = 1'b1;
        end else if (!rst && EMPTY_AW_BYPASS && (count_q == 0) &&
                     (issued_count_q == 0) && grant_valid_comb) begin
            // If AWREADY is low this payload is captured by the empty FIFO at
            // the same edge as the upstream handshake.  On the next cycle the
            // memory-backed path above takes over and freezes the payload.
            m_awaddr = s_awaddr[grant_idx_comb];
            m_awlen = s_awlen[grant_idx_comb];
            m_awsize = s_awsize[grant_idx_comb];
            m_awburst = s_awburst[grant_idx_comb];
            m_awvalid = 1'b1;
        end
        aw_issue_fire = m_awvalid && m_awready;

        w_owner_comb = '0;
        w_active_comb = 1'b0;
        expected_wlast_comb = 1'b0;
        w_slot_comb = W_AHEAD_OF_B ? w_issue_q : head_q;
        // Descriptor acceptance fixes the W owner, even while the
        // downstream address is stalled. Waiting for AW issue here would
        // deadlock against a subordinate that waits for WVALID.
        if (!rst && (W_AHEAD_OF_B ? (w_pending_count_q != 0) :
                     ((count_q != 0) && !w_done_mem[head_q]))) begin
            w_owner_comb = owner_mem[w_slot_comb];
            w_active_comb = 1'b1;
            expected_wlast_comb = (w_beat_q == len_mem[w_slot_comb]);
        end
        s_wready = '0;
        m_wdata = 128'd0;
        m_wstrb = 16'd0;
        m_wlast = 1'b0;
        m_wvalid = 1'b0;
        if (w_active_comb) begin
            m_wdata = s_wdata[w_owner_comb];
            m_wstrb = s_wstrb[w_owner_comb];
            m_wlast = s_wlast[w_owner_comb];
            m_wvalid = s_wvalid[w_owner_comb];
            s_wready[w_owner_comb] = m_wready;
        end
        w_fire = m_wvalid && m_wready;
        terminal_w_comb = w_fire && (m_wlast || expected_wlast_comb);

        b_owner_comb = owner_mem[head_q];
        b_active_comb = !rst && (issued_count_q != 0) &&
                        w_done_mem[head_q];
        s_bresp = '0;
        s_bvalid = '0;
        m_bready = 1'b0;
        if (b_active_comb) begin
            s_bresp[b_owner_comb] = m_bresp;
            s_bvalid[b_owner_comb] = m_bvalid;
            m_bready = s_bready[b_owner_comb];
        end else if (!rst && (issued_count_q == 0)) begin
            // Drain an unsolicited B so a malformed slave cannot wedge the
            // shared bus.  It is still reported through orphan_b_error.
            m_bready = 1'b1;
        end
        b_fire = m_bvalid && m_bready;
        // m_bready is intentionally asserted for an orphan B when no
        // descriptor is active, so a malformed slave cannot wedge the bus.
        // That drain handshake must never mutate FIFO/retirement state.
        retire_b_fire = b_active_comb && b_fire;
    end

    // This public counter intentionally reports descriptor occupancy
    // (accepted AW descriptors which have not retired), not only the subset
    // which has already crossed the downstream AW channel.  The distinction
    // is useful when sizing the upstream payload FIFOs; issued_count_q remains
    // the internal true AXI-B outstanding count.
    assign perf_outstanding = count_q;
    assign write_busy = (count_q != 0);
    assign write_quiescent = !write_busy;
    assign write_owner = write_busy ? owner_mem[head_q] : '0;
    assign write_data_busy = (w_pending_count_q != 0);
    assign write_data_owner = write_data_busy ? owner_mem[w_issue_q] : '0;
    assign protocol_error = early_wlast_error_q || missing_wlast_error_q ||
                            early_b_error_q || orphan_b_error_q;
    assign early_wlast_error = early_wlast_error_q;
    assign missing_wlast_error = missing_wlast_error_q;
    assign early_b_error = early_b_error_q;
    assign orphan_b_error = orphan_b_error_q;

    integer init_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            issue_q <= '0;
            w_issue_q <= '0;
            w_pending_count_q <= '0;
            count_q <= '0;
            issued_count_q <= '0;
            rr_q <= '0;
            w_beat_q <= 8'd0;
            early_wlast_error_q <= 1'b0;
            missing_wlast_error_q <= 1'b0;
            early_b_error_q <= 1'b0;
            orphan_b_error_q <= 1'b0;
            perf_max_outstanding <= 8'd0;
            perf_aw_accept_count <= 64'd0;
            perf_aw_issue_count <= 64'd0;
            perf_w_beat_count <= 64'd0;
            perf_b_count <= 64'd0;
            for (init_i = 0; init_i < FIFO_DEPTH; init_i = init_i + 1) begin
                owner_mem[init_i] <= '0;
                addr_mem[init_i] <= 32'd0;
                len_mem[init_i] <= 8'd0;
                size_mem[init_i] <= 3'd0;
                burst_mem[init_i] <= 2'd0;
                aw_issued_mem[init_i] <= 1'b0;
                w_done_mem[init_i] <= 1'b0;
            end
        end else begin
            if (aw_accept) begin
                owner_mem[tail_q] <= grant_idx_comb;
                addr_mem[tail_q] <= s_awaddr[grant_idx_comb];
                len_mem[tail_q] <= s_awlen[grant_idx_comb];
                size_mem[tail_q] <= s_awsize[grant_idx_comb];
                burst_mem[tail_q] <= s_awburst[grant_idx_comb];
                aw_issued_mem[tail_q] <= 1'b0;
                w_done_mem[tail_q] <= 1'b0;
                tail_q <= ptr_inc(tail_q);
                rr_q <= next_client(grant_idx_comb);
                perf_aw_accept_count <= perf_aw_accept_count + 1'b1;
            end
            if (aw_issue_fire) begin
                aw_issued_mem[issue_q] <= 1'b1;
                issue_q <= ptr_inc(issue_q);
                perf_aw_issue_count <= perf_aw_issue_count + 1'b1;
            end

            // Descriptor FIFO count and AW-issued count are updated with
            // explicit two-bit cases so simultaneous events cannot overwrite
            // one another through nonblocking assignment ordering.
            case ({aw_accept, retire_b_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
            case ({aw_issue_fire, retire_b_fire})
                2'b10: issued_count_q <= issued_count_q + 1'b1;
                2'b01: issued_count_q <= issued_count_q - 1'b1;
                default: issued_count_q <= issued_count_q;
            endcase
            // Separate accepted-but-not-W-complete occupancy is necessary
            // when the W cursor wraps onto the B head of a full FIFO.
            case ({aw_accept, terminal_w_comb})
                2'b10: w_pending_count_q <= w_pending_count_q + 1'b1;
                2'b01: w_pending_count_q <= w_pending_count_q - 1'b1;
                default: w_pending_count_q <= w_pending_count_q;
            endcase
            if (count_q + (aw_accept ? 1 : 0) > perf_max_outstanding)
                perf_max_outstanding <= count_q + 1'b1;

            if (w_fire) begin
                perf_w_beat_count <= perf_w_beat_count + 1'b1;
                if (m_wlast && !expected_wlast_comb)
                    early_wlast_error_q <= 1'b1;
                if (!m_wlast && expected_wlast_comb)
                    missing_wlast_error_q <= 1'b1;
                if (terminal_w_comb) begin
                    w_done_mem[w_slot_comb] <= 1'b1;
                    w_issue_q <= ptr_inc(w_issue_q);
                    w_beat_q <= 8'd0;
                end else begin
                    w_beat_q <= w_beat_q + 1'b1;
                end
            end

            if (retire_b_fire) begin
                head_q <= ptr_inc(head_q);
                perf_b_count <= perf_b_count + 1'b1;
                // The slot is immediately reusable after retirement.  A
                // simultaneous AW accept cannot target the old head unless
                // FIFO_DEPTH==1 (which is disallowed above).
                aw_issued_mem[head_q] <= 1'b0;
                w_done_mem[head_q] <= 1'b0;
            end
            if (m_bvalid && !b_active_comb && (issued_count_q != 0))
                early_b_error_q <= 1'b1;
            if (m_bvalid && (issued_count_q == 0))
                orphan_b_error_q <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    // Lightweight VALID hold checks.  They are intentionally local to the
    // optional seam and do not require an external AXI protocol checker.
    logic aw_stalled_q, w_stalled_q, b_stalled_q;
    logic [44:0] aw_payload_q;
    logic [144:0] w_payload_q;
    logic [1:0] b_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_stalled_q <= 1'b0;
            w_stalled_q <= 1'b0;
            b_stalled_q <= 1'b0;
        end else begin
            if (aw_stalled_q &&
                (!m_awvalid ||
                 ({m_awaddr,m_awlen,m_awsize,m_awburst} !== aw_payload_q)))
                $fatal(1, "write arbiter changed stalled AW payload");
            if (w_stalled_q &&
                (!m_wvalid || ({m_wdata,m_wstrb,m_wlast} !== w_payload_q)))
                $fatal(1, "write arbiter changed stalled W payload");
            if (b_stalled_q &&
                (!m_bvalid || (m_bresp !== b_payload_q)))
                $fatal(1, "write arbiter withdrew stalled B payload");
            aw_stalled_q <= m_awvalid && !m_awready;
            aw_payload_q <= {m_awaddr,m_awlen,m_awsize,m_awburst};
            w_stalled_q <= m_wvalid && !m_wready;
            w_payload_q <= {m_wdata,m_wstrb,m_wlast};
            b_stalled_q <= m_bvalid && !m_bready;
            b_payload_q <= m_bresp;
        end
    end
`endif

endmodule
