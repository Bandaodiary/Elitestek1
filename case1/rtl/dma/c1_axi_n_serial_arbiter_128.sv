`timescale 1ns/1ps

// Portable N-master to one-slave arbiter for the ID-less AXI4-128 subset used
// by case 1. Read and write directions arbitrate independently, so one read
// burst and one write burst may be active at the same time. A selected
// transaction is locked from address presentation through its terminal
// response; upstream VALID is never withdrawn or re-routed while stalled.
// WRITE_FIFO_DEPTH != 0 replaces only the write path with the queued writer;
// its B-head owner status can differ from the oldest W-pending owner.
module c1_axi_n_serial_arbiter_128 #(
    parameter integer CLIENTS = 6,
    parameter integer INDEX_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
    // Optional one-entry read response boundary.  The legacy direct path
    // remains the default so existing cycle-accurate users are unchanged.
    // When enabled, the downstream R beat is captured before it is exposed
    // to the selected client.  This removes the direct client-RREADY ->
    // fabric-RREADY combinational path and gives a stalled client one beat of
    // elasticity without changing the ID-less ownership contract.
    parameter integer READ_RESPONSE_SKID = 0,
    // Zero retains the original serial write path. Values 2..255 select the
    // existing queued write arbiter without changing the read path.
    parameter integer WRITE_FIFO_DEPTH = 0,
    parameter bit WRITE_W_AHEAD_OF_B = 1'b0,
    parameter bit WRITE_EMPTY_AW_BYPASS = 1'b0
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

    // Read-only owner status for a shared maintenance/epoch controller.
    // These outputs do not alter the legacy arbitration or handshake path;
    // they make it possible for an outer fence to distinguish an idle fabric
    // from a selected owner whose stalled VALID must continue to drain.
    output logic                         read_busy,
    output logic                         read_quiescent,
    output logic                         write_busy,
    output logic                         write_quiescent,
    output logic [INDEX_W-1:0]           read_owner,
    output logic [INDEX_W-1:0]           write_owner,
    // Queued mode: oldest unretired B owner, not a unique active writer.
    // Protocol diagnostics are sticky until global reset, not cancel.
    output logic                         write_protocol_error,
    output logic                         write_data_busy,
    output logic [INDEX_W-1:0]           write_data_owner
);

    typedef enum logic [1:0] {
        WR_IDLE, WR_ADDRESS, WR_DATA, WR_RESPONSE
    } wr_state_t;
    typedef enum logic [1:0] {
        RD_IDLE, RD_ADDRESS, RD_DATA
    } rd_state_t;

    wr_state_t wr_state_q;
    rd_state_t rd_state_q;
    logic [INDEX_W-1:0] wr_owner_q, rd_owner_q;
    logic [INDEX_W-1:0] wr_rr_q, rd_rr_q;
    logic [7:0] rd_expected_last_index_q;
    logic [7:0] rd_beat_index_q;
    logic        rd_skid_valid_q;
    logic [127:0] rd_skid_data_q;
    logic [1:0]   rd_skid_resp_q;
    logic         rd_skid_last_q;
    logic         rd_skid_terminal_q;
    logic         wr_aw_done_q, wr_w_done_q;
    logic wr_candidate_valid, rd_candidate_valid;
    logic [INDEX_W-1:0] wr_candidate, rd_candidate;
    integer wr_offset, rd_offset;
    integer wr_scan_index, rd_scan_index;

    assign read_busy = (rd_state_q != RD_IDLE) || rd_skid_valid_q;
    assign read_quiescent = !read_busy;
    assign write_quiescent = !write_busy;
    assign read_owner = rd_owner_q;
    initial begin
        if (WRITE_FIFO_DEPTH != 0 && (WRITE_FIFO_DEPTH < 2 || WRITE_FIFO_DEPTH > 255))
            $fatal(1,"shared fabric WRITE_FIFO_DEPTH must be zero or 2..255");
        if (WRITE_FIFO_DEPTH == 0 && (WRITE_W_AHEAD_OF_B || WRITE_EMPTY_AW_BYPASS))
            $fatal(1,"queued write options require nonzero WRITE_FIFO_DEPTH");
    end

    function automatic logic [INDEX_W-1:0] next_client(
        input logic [INDEX_W-1:0] current
    );
        begin
            if (current == CLIENTS - 1)
                next_client = '0;
            else
                next_client = current + 1'b1;
        end
    endfunction

    always_comb begin
        wr_candidate_valid = 1'b0;
        wr_candidate = wr_rr_q;
        for (wr_offset = 0; wr_offset < CLIENTS; wr_offset = wr_offset + 1) begin
            wr_scan_index = wr_rr_q + wr_offset;
            if (wr_scan_index >= CLIENTS)
                wr_scan_index = wr_scan_index - CLIENTS;
            if (!wr_candidate_valid && s_awvalid[wr_scan_index]) begin
                wr_candidate_valid = 1'b1;
                wr_candidate = wr_scan_index[INDEX_W-1:0];
            end
        end

        rd_candidate_valid = 1'b0;
        rd_candidate = rd_rr_q;
        for (rd_offset = 0; rd_offset < CLIENTS; rd_offset = rd_offset + 1) begin
            rd_scan_index = rd_rr_q + rd_offset;
            if (rd_scan_index >= CLIENTS)
                rd_scan_index = rd_scan_index - CLIENTS;
            if (!rd_candidate_valid && s_arvalid[rd_scan_index]) begin
                rd_candidate_valid = 1'b1;
                rd_candidate = rd_scan_index[INDEX_W-1:0];
            end
        end
    end

    generate if (WRITE_FIFO_DEPTH == 0) begin : g_serial_write
    assign write_busy = (wr_state_q != WR_IDLE);
    assign write_owner = wr_owner_q;
    assign write_protocol_error = 1'b0;
    assign write_data_busy = (wr_state_q == WR_ADDRESS) && !wr_w_done_q;
    assign write_data_owner = write_data_busy ? wr_owner_q : '0;
    always_comb begin
        s_awready = '0;
        s_wready = '0;
        s_bresp = '0;
        s_bvalid = '0;
        m_awaddr = 32'd0;
        m_awlen = 8'd0;
        m_awsize = 3'd0;
        m_awburst = 2'd0;
        m_awvalid = 1'b0;
        m_wdata = 128'd0;
        m_wstrb = 16'd0;
        m_wlast = 1'b0;
        m_wvalid = 1'b0;
        m_bready = 1'b0;

        case (wr_state_q)
            WR_ADDRESS: begin
              if (!wr_aw_done_q) begin
                m_awaddr = s_awaddr[wr_owner_q];
                m_awlen = s_awlen[wr_owner_q];
                m_awsize = s_awsize[wr_owner_q];
                m_awburst = s_awburst[wr_owner_q];
                m_awvalid = s_awvalid[wr_owner_q];
                s_awready[wr_owner_q] = m_awready;
              end
              // W must be presented independently of downstream AWREADY.
              // Both channels retain the same owner until the B response.
              if (!wr_w_done_q) begin
                m_wdata = s_wdata[wr_owner_q];
                m_wstrb = s_wstrb[wr_owner_q];
                m_wlast = s_wlast[wr_owner_q];
                m_wvalid = s_wvalid[wr_owner_q];
                s_wready[wr_owner_q] = m_wready;
              end
            end
            WR_RESPONSE: begin
                s_bresp[wr_owner_q] = m_bresp;
                s_bvalid[wr_owner_q] = m_bvalid;
                m_bready = s_bready[wr_owner_q];
            end
            default: begin end
        endcase
    end

    end else begin : g_queued_write
        // Legacy-only registers have no owner in this elaborated branch.
        assign wr_state_q = WR_IDLE;
        assign wr_owner_q = '0;
        assign wr_rr_q = '0;
        assign wr_aw_done_q = 1'b0;
        assign wr_w_done_q = 1'b0;
        c1_axi_n_write_burst_arbiter_128 #(
            .CLIENTS(CLIENTS),.INDEX_W(INDEX_W),.FIFO_DEPTH(WRITE_FIFO_DEPTH),
            .W_AHEAD_OF_B(WRITE_W_AHEAD_OF_B),.EMPTY_AW_BYPASS(WRITE_EMPTY_AW_BYPASS)
        ) u_writer (
            .clk(clk),.rst(rst),.s_awaddr(s_awaddr),.s_awlen(s_awlen),.s_awsize(s_awsize),
            .s_awburst(s_awburst),.s_awvalid(s_awvalid),.s_awready(s_awready),
            .s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wlast(s_wlast),.s_wvalid(s_wvalid),.s_wready(s_wready),
            .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),
            .m_awaddr(m_awaddr),.m_awlen(m_awlen),.m_awsize(m_awsize),.m_awburst(m_awburst),
            .m_awvalid(m_awvalid),.m_awready(m_awready),.m_wdata(m_wdata),.m_wstrb(m_wstrb),
            .m_wlast(m_wlast),.m_wvalid(m_wvalid),.m_wready(m_wready),
            .m_bresp(m_bresp),.m_bvalid(m_bvalid),.m_bready(m_bready),
            .protocol_error(write_protocol_error),.early_wlast_error(),.missing_wlast_error(),
            .early_b_error(),.orphan_b_error(),.perf_outstanding(),.perf_max_outstanding(),
            .perf_aw_accept_count(),.perf_aw_issue_count(),.perf_w_beat_count(),.perf_b_count(),
            .write_busy(write_busy),.write_quiescent(),.write_owner(write_owner),
            .write_data_busy(write_data_busy),.write_data_owner(write_data_owner)
        );
    end endgenerate

    always_comb begin
        s_arready = '0;
        s_rdata = '0;
        s_rresp = '0;
        s_rlast = '0;
        s_rvalid = '0;
        m_araddr = 32'd0;
        m_arlen = 8'd0;
        m_arsize = 3'd0;
        m_arburst = 2'd0;
        m_arvalid = 1'b0;
        m_rready = 1'b0;

        case (rd_state_q)
            RD_ADDRESS: begin
                m_araddr = s_araddr[rd_owner_q];
                m_arlen = s_arlen[rd_owner_q];
                m_arsize = s_arsize[rd_owner_q];
                m_arburst = s_arburst[rd_owner_q];
                m_arvalid = s_arvalid[rd_owner_q];
                s_arready[rd_owner_q] = m_arready;
            end
            RD_DATA: begin
                if (READ_RESPONSE_SKID != 0) begin
                    // The skid entry is deliberately non-fall-through.  A
                    // response is therefore stable for the whole cycle in
                    // which the client observes VALID, and m_rready is
                    // independent of client readiness while the entry is
                    // empty.
                    s_rdata[rd_owner_q] = rd_skid_data_q;
                    s_rresp[rd_owner_q] = rd_skid_resp_q;
                    s_rlast[rd_owner_q] = rd_skid_last_q;
                    s_rvalid[rd_owner_q] = rd_skid_valid_q;
                    // Do not acknowledge an extra downstream beat while a
                    // terminal (actual RLAST or ARLEN-derived) beat is held.
                    // This preserves the legacy missing-RLAST containment:
                    // the expected final beat releases ownership without
                    // silently consuming a protocol-violating extra beat.
                    m_rready = !rd_skid_valid_q ||
                               (s_rready[rd_owner_q] && !rd_skid_terminal_q);
                end else begin
                    s_rdata[rd_owner_q] = m_rdata;
                    s_rresp[rd_owner_q] = m_rresp;
                    if ((m_rlast != (rd_beat_index_q == rd_expected_last_index_q)) &&
                        !m_rresp[1])
                        s_rresp[rd_owner_q] = 2'b10;
                    s_rlast[rd_owner_q] = m_rlast;
                    s_rvalid[rd_owner_q] = m_rvalid;
                    m_rready = s_rready[rd_owner_q];
                end
            end
            default: begin end
        endcase
    end

    generate if (WRITE_FIFO_DEPTH == 0) begin : g_serial_write_state
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_state_q <= WR_IDLE;
            wr_owner_q <= '0;
            wr_rr_q <= '0;
            wr_aw_done_q <= 1'b0;
            wr_w_done_q <= 1'b0;
        end else begin
            case (wr_state_q)
                WR_IDLE: if (wr_candidate_valid) begin
                    wr_owner_q <= wr_candidate;
                    wr_state_q <= WR_ADDRESS;
                    wr_aw_done_q <= 1'b0;
                    wr_w_done_q <= 1'b0;
                end
                WR_ADDRESS: begin
                    if (m_awvalid && m_awready) wr_aw_done_q <= 1'b1;
                    if (m_wvalid && m_wready && m_wlast) wr_w_done_q <= 1'b1;
                    if ((wr_aw_done_q || (m_awvalid && m_awready)) &&
                        (wr_w_done_q || (m_wvalid && m_wready && m_wlast)))
                        wr_state_q <= WR_RESPONSE;
                end
                WR_RESPONSE: if (m_bvalid && m_bready) begin
                    wr_rr_q <= next_client(wr_owner_q);
                    wr_state_q <= WR_IDLE;
                end
                default: wr_state_q <= WR_IDLE;
            endcase
        end
    end

    end endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_state_q <= RD_IDLE;
            rd_owner_q <= '0;
            rd_rr_q <= '0;
            rd_expected_last_index_q <= 8'd0;
            rd_beat_index_q <= 8'd0;
            rd_skid_valid_q <= 1'b0;
            rd_skid_data_q <= 128'd0;
            rd_skid_resp_q <= 2'd0;
            rd_skid_last_q <= 1'b0;
            rd_skid_terminal_q <= 1'b0;
        end else begin
            case (rd_state_q)
                RD_IDLE: if (rd_candidate_valid) begin
                    rd_owner_q <= rd_candidate;
                    rd_state_q <= RD_ADDRESS;
                end
                RD_ADDRESS: if (m_arvalid && m_arready) begin
                    // ARLEN is the zero-based index of the expected final
                    // response beat.  Retaining it here prevents a malformed
                    // missing-RLAST burst from permanently owning the outer
                    // N-way arbiter after the leaf reader has retired error.
                    rd_expected_last_index_q <= m_arlen;
                    rd_beat_index_q <= 8'd0;
                    rd_skid_valid_q <= 1'b0;
                    rd_state_q <= RD_DATA;
                end
                RD_DATA: begin
                    if (READ_RESPONSE_SKID != 0) begin
                        // Retire the transaction only after the selected
                        // client consumes the held terminal beat.  A final R
                        // beat may therefore be captured one cycle before
                        // ownership is released.
                        if (rd_skid_valid_q && s_rready[rd_owner_q] &&
                            rd_skid_terminal_q) begin
                            rd_skid_valid_q <= 1'b0;
                            rd_rr_q <= next_client(rd_owner_q);
                            rd_state_q <= RD_IDLE;
                        end else if (m_rvalid && m_rready) begin
                            // Early RLAST terminates malformed bursts at the
                            // actual bus boundary; the ARLEN-derived guard
                            // prevents a missing RLAST from extending a
                            // transaction forever.
                            rd_skid_valid_q <= 1'b1;
                            rd_skid_data_q <= m_rdata;
                            rd_skid_resp_q <= m_rresp;
                            if ((m_rlast != (rd_beat_index_q == rd_expected_last_index_q)) &&
                                !m_rresp[1])
                                rd_skid_resp_q <= 2'b10;
                            // Preserve wire RLAST. Ownership termination is
                            // separate, so a malformed final beat stays bad.
                            rd_skid_last_q <= m_rlast;
                            rd_skid_terminal_q <= m_rlast ||
                                (rd_beat_index_q == rd_expected_last_index_q);
                            if (m_rlast ||
                                (rd_beat_index_q == rd_expected_last_index_q)) begin
                                rd_beat_index_q <= rd_beat_index_q;
                            end else begin
                                rd_beat_index_q <= rd_beat_index_q + 8'd1;
                            end
                        end else if (rd_skid_valid_q && s_rready[rd_owner_q]) begin
                            rd_skid_valid_q <= 1'b0;
                        end
                    end else if (m_rvalid && m_rready) begin
                        // Legacy direct response path.
                        if (m_rlast ||
                            (rd_beat_index_q == rd_expected_last_index_q)) begin
                            rd_rr_q <= next_client(rd_owner_q);
                            rd_state_q <= RD_IDLE;
                        end else begin
                            rd_beat_index_q <= rd_beat_index_q + 8'd1;
                        end
                    end
                end
                default: rd_state_q <= RD_IDLE;
            endcase
        end
    end

endmodule
