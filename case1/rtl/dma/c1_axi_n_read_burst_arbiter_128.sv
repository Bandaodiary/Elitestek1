`timescale 1ns/1ps

// Optional ID-less AXI4-128 read-only multi-burst arbiter.
//
// This module is deliberately separate from c1_axi_n_serial_arbiter_128.  It
// is a small seam for systems that want more than one read burst in flight
// while retaining the ID-less AXI subset used by case 1.  Accepted client AR
// descriptors are first put in an arbitration FIFO.  Once an AR handshake is
// made on the downstream port, a second FIFO records the owner and ARLEN.  R
// beats are routed only to the head descriptor of that second FIFO, which is
// the ordering rule required when all requests use one AXI ID (or no explicit
// ID at all).
//
// The implementation intentionally derives a terminal response from ARLEN as
// well as m_rlast.  An early RLAST retires the head descriptor and sets the
// sticky early_rlast_error flag.  If the expected final beat arrives without
// RLAST, the module preserves the actual RLAST, retires the descriptor, and
// sets missing_rlast_error. Either length mismatch upgrades OKAY/EXOKAY to
// SLVERR; an existing SLVERR/DECERR is preserved. Internal owner retirement
// is separate from the client-visible end marker. This is containment, not
// a claim that a
// malformed AXI slave is legal; after a missing RLAST, any extra physical beat
// cannot be disambiguated from the next ID-less burst.  The queue nevertheless
// continues under the existing bounded-response contract, not a guarantee
// of recovery from arbitrary extra beats. Stop admission and coordinate
// reset if the physical transaction boundary cannot be established.
//
// RVALID/RREADY are passed through with registered descriptor state.  When a
// client deasserts s_rready, m_rready is deasserted and the AXI slave must hold
// m_rvalid, data, response and RLAST according to the AXI protocol.  No legacy
// arbiter or SoC wiring is changed by this standalone module.
module c1_axi_n_read_burst_arbiter_128 #(
    parameter integer CLIENTS = 2,
    parameter integer FIFO_DEPTH = 4,
    parameter integer INDEX_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
    parameter integer PTR_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    parameter integer COUNT_W = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1),
    // Optional one-cycle empty-queue latency bypass.  When enabled, the
    // selected client may present the first AR directly to the downstream
    // master while both descriptor rings are empty.  A stalled downstream
    // handshake is captured in a one-entry hold register on that edge.  The
    // default keeps the original enqueue-then-issue timing.
    parameter bit EMPTY_AR_BYPASS = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

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

    // Sticky diagnostics.  These are intentionally outputs so a board-level
    // wrapper can expose malformed-slave containment without peeking into the
    // implementation hierarchy.
    output logic                         protocol_error,
    output logic                         early_rlast_error,
    output logic                         missing_rlast_error,
    output logic                         orphan_r_error
);

    initial begin
        if (CLIENTS < 1)
            $fatal(1, "c1_axi_n_read_burst_arbiter_128 CLIENTS must be positive");
        if (FIFO_DEPTH < 1)
            $fatal(1, "c1_axi_n_read_burst_arbiter_128 FIFO_DEPTH must be positive");
        if (FIFO_DEPTH > 256)
            $fatal(1, "c1_axi_n_read_burst_arbiter_128 FIFO_DEPTH must be <= 256");
    end

    // Accepted-but-not-yet-issued descriptors.  The ring is deliberately
    // separate from the response ring: a slow AXI AR channel must not prevent
    // already-issued bursts from being tracked and routed.
    logic [INDEX_W-1:0] pending_owner_mem [0:FIFO_DEPTH-1];
    logic [31:0]        pending_addr_mem  [0:FIFO_DEPTH-1];
    logic [7:0]         pending_len_mem   [0:FIFO_DEPTH-1];
    logic [2:0]         pending_size_mem  [0:FIFO_DEPTH-1];
    logic [1:0]         pending_burst_mem [0:FIFO_DEPTH-1];

    logic [INDEX_W-1:0] response_owner_mem [0:FIFO_DEPTH-1];
    logic [7:0]         response_len_mem   [0:FIFO_DEPTH-1];

    logic [PTR_W-1:0] pending_head_q, pending_tail_q;
    logic [PTR_W-1:0] response_head_q, response_tail_q;
    logic [COUNT_W-1:0] pending_count_q, response_count_q;
    logic [INDEX_W-1:0] rr_q;
    logic [7:0] response_beat_q;

    logic early_rlast_error_q;
    logic missing_rlast_error_q;
    logic orphan_r_error_q;

    logic [COUNT_W:0] total_count_comb;
    logic [INDEX_W-1:0] grant_idx_comb;
    logic grant_valid_comb;
    integer arb_offset;
    integer arb_scan_index;

    logic [INDEX_W-1:0] active_owner_comb;
    logic [7:0] active_len_comb;
    logic terminal_comb;
    logic ar_accept;
    logic ar_issue_fire;
    logic r_fire;
    logic pending_push, pending_pop;
    logic response_push, response_pop;
    logic empty_ar_bypass_comb;
    logic empty_ar_bypass_fire;
    // If the downstream AR channel is stalled while the fabric is empty, do
    // not rely on an asynchronous pending-memory read on the next cycle.
    // Capture the live descriptor in this one-entry register and issue it
    // later.  This keeps the optional path portable to synchronous EBRs.
    logic empty_ar_hold_valid_q;
    logic [INDEX_W-1:0] empty_ar_hold_owner_q;
    logic [31:0] empty_ar_hold_addr_q;
    logic [7:0] empty_ar_hold_len_q;
    logic [2:0] empty_ar_hold_size_q;
    logic [1:0] empty_ar_hold_burst_q;
    logic empty_ar_capture_fire;
    logic empty_ar_hold_issue_fire;

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

    // AR arbitration, downstream AR presentation, and response routing are
    // combinational around registered FIFO state.  A descriptor remains at
    // pending_head_q while m_arvalid is stalled, satisfying AXI payload hold.
    always_comb begin
        // Explicitly widen both operands before adding.  Without the
        // extensions the SystemVerilog expression width is COUNT_W, so a
        // pending+response total above 2**COUNT_W-1 could wrap and admit
        // descriptors past the aggregate FIFO capacity.
        total_count_comb = {1'b0, pending_count_q} +
                           {1'b0, response_count_q};

        grant_valid_comb = 1'b0;
        grant_idx_comb = rr_q;
        if (!rst && (total_count_comb < FIFO_DEPTH)) begin
            for (arb_offset = 0; arb_offset < CLIENTS;
                 arb_offset = arb_offset + 1) begin
                arb_scan_index = rr_q + arb_offset;
                if (arb_scan_index >= CLIENTS)
                    arb_scan_index = arb_scan_index - CLIENTS;
                if (!grant_valid_comb && s_arvalid[arb_scan_index]) begin
                    grant_valid_comb = 1'b1;
                    grant_idx_comb = arb_scan_index[INDEX_W-1:0];
                end
            end
        end

        s_arready = '0;
        if (grant_valid_comb && !empty_ar_hold_valid_q)
            s_arready[grant_idx_comb] = 1'b1;

        m_araddr = 32'd0;
        m_arlen = 8'd0;
        m_arsize = 3'd0;
        m_arburst = 2'd0;
        m_arvalid = 1'b0;
        empty_ar_bypass_comb = !rst && EMPTY_AR_BYPASS &&
                               (pending_count_q == 0) &&
                               (response_count_q == 0) &&
                               !empty_ar_hold_valid_q &&
                               grant_valid_comb;
        if (!rst && (pending_count_q != 0) &&
            (response_count_q < FIFO_DEPTH)) begin
            m_araddr = pending_addr_mem[pending_head_q];
            m_arlen = pending_len_mem[pending_head_q];
            m_arsize = pending_size_mem[pending_head_q];
            m_arburst = pending_burst_mem[pending_head_q];
            m_arvalid = 1'b1;
        end else if (!rst && empty_ar_hold_valid_q) begin
            m_araddr = empty_ar_hold_addr_q;
            m_arlen = empty_ar_hold_len_q;
            m_arsize = empty_ar_hold_size_q;
            m_arburst = empty_ar_hold_burst_q;
            m_arvalid = 1'b1;
        end else if (empty_ar_bypass_comb) begin
            // Fall-through is restricted to a completely empty fabric.  If
            // m_arready is low, the live descriptor is captured in the
            // one-entry hold register below and the same payload is issued
            // later; no asynchronous EBR read is needed on the bypass path.
            m_araddr = s_araddr[grant_idx_comb];
            m_arlen = s_arlen[grant_idx_comb];
            m_arsize = s_arsize[grant_idx_comb];
            m_arburst = s_arburst[grant_idx_comb];
            m_arvalid = 1'b1;
        end

        active_owner_comb = '0;
        active_len_comb = 8'd0;
        terminal_comb = 1'b0;
        s_rdata = '0;
        s_rresp = '0;
        s_rlast = '0;
        s_rvalid = '0;
        m_rready = 1'b0;
        if (!rst && (response_count_q != 0)) begin
            active_owner_comb = response_owner_mem[response_head_q];
            active_len_comb = response_len_mem[response_head_q];
            terminal_comb = m_rlast ||
                (response_beat_q == active_len_comb);
            s_rdata[active_owner_comb] = m_rdata;
            s_rresp[active_owner_comb] = m_rresp;
            if ((m_rlast != (response_beat_q == active_len_comb)) && !m_rresp[1])
                s_rresp[active_owner_comb] = 2'b10;
            s_rlast[active_owner_comb] = m_rlast;
            s_rvalid[active_owner_comb] = m_rvalid;
            // Backpressure is applied to the single ID-less response stream;
            // only the head owner's readiness may consume a beat.
            m_rready = s_rready[active_owner_comb];
        end else if (!rst) begin
            // Drain an unsolicited response rather than wedging the bus.  It
            // is flagged below; no client-visible valid is generated.
            m_rready = 1'b1;
        end
    end

    assign ar_accept = grant_valid_comb &&
                       s_arvalid[grant_idx_comb] &&
                       s_arready[grant_idx_comb];
    assign ar_issue_fire = m_arvalid && m_arready;
    assign empty_ar_bypass_fire = empty_ar_bypass_comb && ar_issue_fire;
    assign empty_ar_capture_fire = empty_ar_bypass_comb && ar_accept &&
                                   !ar_issue_fire;
    assign empty_ar_hold_issue_fire = empty_ar_hold_valid_q && ar_issue_fire;
    assign r_fire = m_rvalid && m_rready;
    // A direct/held empty-queue descriptor never occupies pending_mem.  The
    // old unconditional pending_pop was harmless for the count (push/pop
    // netted to zero) but advanced pending_head on a direct AR, which could
    // corrupt the next wrapped normal descriptor.
    assign pending_push = ar_accept && !empty_ar_bypass_comb;
    assign pending_pop = ar_issue_fire && (pending_count_q != 0);
    assign response_push = ar_issue_fire;
    assign response_pop = r_fire && (response_count_q != 0) && terminal_comb;

    assign early_rlast_error = early_rlast_error_q;
    assign missing_rlast_error = missing_rlast_error_q;
    assign orphan_r_error = orphan_r_error_q;
    assign protocol_error = early_rlast_error_q ||
                            missing_rlast_error_q || orphan_r_error_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_head_q <= '0;
            pending_tail_q <= '0;
            response_head_q <= '0;
            response_tail_q <= '0;
            pending_count_q <= '0;
            response_count_q <= '0;
            rr_q <= '0;
            response_beat_q <= 8'd0;
            empty_ar_hold_valid_q <= 1'b0;
            empty_ar_hold_owner_q <= '0;
            empty_ar_hold_addr_q <= 32'd0;
            empty_ar_hold_len_q <= 8'd0;
            empty_ar_hold_size_q <= 3'd0;
            empty_ar_hold_burst_q <= 2'd0;
            early_rlast_error_q <= 1'b0;
            missing_rlast_error_q <= 1'b0;
            orphan_r_error_q <= 1'b0;
        end else begin
            if (empty_ar_capture_fire) begin
                empty_ar_hold_valid_q <= 1'b1;
                empty_ar_hold_owner_q <= grant_idx_comb;
                empty_ar_hold_addr_q <= s_araddr[grant_idx_comb];
                empty_ar_hold_len_q <= s_arlen[grant_idx_comb];
                empty_ar_hold_size_q <= s_arsize[grant_idx_comb];
                empty_ar_hold_burst_q <= s_arburst[grant_idx_comb];
            end else if (empty_ar_hold_issue_fire) begin
                empty_ar_hold_valid_q <= 1'b0;
            end
            if (pending_push) begin
                pending_owner_mem[pending_tail_q] <= grant_idx_comb;
                pending_addr_mem[pending_tail_q] <= s_araddr[grant_idx_comb];
                pending_len_mem[pending_tail_q] <= s_arlen[grant_idx_comb];
                pending_size_mem[pending_tail_q] <= s_arsize[grant_idx_comb];
                pending_burst_mem[pending_tail_q] <= s_arburst[grant_idx_comb];
                pending_tail_q <= ptr_inc(pending_tail_q);
            end
            // Advance round-robin state for normal queued ARs and for a
            // direct/held empty-queue handshake alike.  Without this update
            // a stream of direct bypasses could repeatedly select client 0.
            if (ar_accept)
                rr_q <= next_client(grant_idx_comb);
            if (pending_pop)
                pending_head_q <= ptr_inc(pending_head_q);

            case ({pending_push, pending_pop})
                2'b10: pending_count_q <= pending_count_q + 1'b1;
                2'b01: pending_count_q <= pending_count_q - 1'b1;
                default: pending_count_q <= pending_count_q;
            endcase

            if (response_push) begin
                // The fall-through case writes pending_mem and issues the
                // same descriptor on one edge.  Use the live client payload
                // instead of the pre-edge (empty) memory slot for response
                // routing metadata.
                if (empty_ar_bypass_fire) begin
                    response_owner_mem[response_tail_q] <= grant_idx_comb;
                    response_len_mem[response_tail_q] <=
                        s_arlen[grant_idx_comb];
                end else if (empty_ar_hold_issue_fire) begin
                    response_owner_mem[response_tail_q] <=
                        empty_ar_hold_owner_q;
                    response_len_mem[response_tail_q] <=
                        empty_ar_hold_len_q;
                end else begin
                    // RHS is the pre-edge pending head, so simultaneous AR
                    // acceptance into the tail and AR issue from the head
                    // remain safe for the normal path.
                    response_owner_mem[response_tail_q] <=
                        pending_owner_mem[pending_head_q];
                    response_len_mem[response_tail_q] <=
                        pending_len_mem[pending_head_q];
                end
                response_tail_q <= ptr_inc(response_tail_q);
            end
            if (response_pop) begin
                response_head_q <= ptr_inc(response_head_q);
                response_beat_q <= 8'd0;
            end else if (r_fire && (response_count_q != 0)) begin
                response_beat_q <= response_beat_q + 1'b1;
            end

            case ({response_push, response_pop})
                2'b10: response_count_q <= response_count_q + 1'b1;
                2'b01: response_count_q <= response_count_q - 1'b1;
                default: response_count_q <= response_count_q;
            endcase

            if (r_fire && (response_count_q == 0)) begin
                orphan_r_error_q <= 1'b1;
            end else if (r_fire && (response_count_q != 0)) begin
                if (m_rlast && (response_beat_q != active_len_comb))
                    early_rlast_error_q <= 1'b1;
                if (!m_rlast && (response_beat_q == active_len_comb))
                    missing_rlast_error_q <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // Assertions are intentionally lightweight and do not require a protocol
    // checker package.  They catch accidental descriptor overrun and ensure a
    // client never observes two owners' valid responses simultaneously.
    integer check_client;
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (pending_count_q > FIFO_DEPTH)
                $fatal(1, "read arbiter pending FIFO count overflow");
            if (response_count_q > FIFO_DEPTH)
                $fatal(1, "read arbiter response FIFO count overflow");
            if (response_count_q != 0 &&
                ((s_rvalid & (s_rvalid - 1'b1)) != '0))
                $fatal(1, "read arbiter routed RVALID to multiple clients");
            for (check_client = 0; check_client < CLIENTS;
                 check_client = check_client + 1) begin
                if (s_rvalid[check_client] && !s_rready[check_client] &&
                    (!m_rvalid || m_rready))
                    $fatal(1, "read arbiter violated RVALID/RREADY hold");
            end
        end
    end
`endif

endmodule
