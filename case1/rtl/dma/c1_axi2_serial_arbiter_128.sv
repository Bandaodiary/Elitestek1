// Vendor-independent, ID-less, two-master AXI4-128 serial arbiter.
//
// Write and read directions arbitrate independently, so one write burst and
// one read burst may progress concurrently.  Within a direction, a selected
// master remains locked for the complete transaction:
//   write: AW handshake -> all W beats through WLAST -> B handshake
//   read : AR handshake -> actual early RLAST or the ARLEN-implied final beat
//
// Arbitration is round-robin at transaction boundaries.  A grant is latched
// before presenting AWVALID/ARVALID downstream, preventing a stalled payload
// from changing if the other request changes.  Address, length, size, burst,
// data, strobe, last, and response fields are passed through without editing.
// Upstream masters must obey the normal AXI rule that payload remains stable
// while VALID is asserted without READY.

`timescale 1ns/1ps

module c1_axi2_serial_arbiter_128 (
    input  logic          clk,
    input  logic          rst,

    input  logic [31:0]   s0_awaddr,
    input  logic [7:0]    s0_awlen,
    input  logic [2:0]    s0_awsize,
    input  logic [1:0]    s0_awburst,
    input  logic          s0_awvalid,
    output logic          s0_awready,
    input  logic [127:0]  s0_wdata,
    input  logic [15:0]   s0_wstrb,
    input  logic          s0_wlast,
    input  logic          s0_wvalid,
    output logic          s0_wready,
    output logic [1:0]    s0_bresp,
    output logic          s0_bvalid,
    input  logic          s0_bready,
    input  logic [31:0]   s0_araddr,
    input  logic [7:0]    s0_arlen,
    input  logic [2:0]    s0_arsize,
    input  logic [1:0]    s0_arburst,
    input  logic          s0_arvalid,
    output logic          s0_arready,
    output logic [127:0]  s0_rdata,
    output logic [1:0]    s0_rresp,
    output logic          s0_rlast,
    output logic          s0_rvalid,
    input  logic          s0_rready,

    input  logic [31:0]   s1_awaddr,
    input  logic [7:0]    s1_awlen,
    input  logic [2:0]    s1_awsize,
    input  logic [1:0]    s1_awburst,
    input  logic          s1_awvalid,
    output logic          s1_awready,
    input  logic [127:0]  s1_wdata,
    input  logic [15:0]   s1_wstrb,
    input  logic          s1_wlast,
    input  logic          s1_wvalid,
    output logic          s1_wready,
    output logic [1:0]    s1_bresp,
    output logic          s1_bvalid,
    input  logic          s1_bready,
    input  logic [31:0]   s1_araddr,
    input  logic [7:0]    s1_arlen,
    input  logic [2:0]    s1_arsize,
    input  logic [1:0]    s1_arburst,
    input  logic          s1_arvalid,
    output logic          s1_arready,
    output logic [127:0]  s1_rdata,
    output logic [1:0]    s1_rresp,
    output logic          s1_rlast,
    output logic          s1_rvalid,
    input  logic          s1_rready,

    output logic [31:0]   m_awaddr,
    output logic [7:0]    m_awlen,
    output logic [2:0]    m_awsize,
    output logic [1:0]    m_awburst,
    output logic          m_awvalid,
    input  logic          m_awready,
    output logic [127:0]  m_wdata,
    output logic [15:0]   m_wstrb,
    output logic          m_wlast,
    output logic          m_wvalid,
    input  logic          m_wready,
    input  logic [1:0]    m_bresp,
    input  logic          m_bvalid,
    output logic          m_bready,
    output logic [31:0]   m_araddr,
    output logic [7:0]    m_arlen,
    output logic [2:0]    m_arsize,
    output logic [1:0]    m_arburst,
    output logic          m_arvalid,
    input  logic          m_arready,
    input  logic [127:0]  m_rdata,
    input  logic [1:0]    m_rresp,
    input  logic          m_rlast,
    input  logic          m_rvalid,
    output logic          m_rready
);

    typedef enum logic [1:0] {
        WR_IDLE,
        WR_AW,
        WR_DATA,
        WR_RESP
    } wr_state_t;

    typedef enum logic [1:0] {
        RD_IDLE,
        RD_AR,
        RD_DATA
    } rd_state_t;

    wr_state_t wr_state;
    rd_state_t rd_state;
    logic wr_grant;
    logic rd_grant;
    logic wr_rr_prefer;
    logic rd_rr_prefer;
    logic wr_aw_seen;
    logic wr_wlast_seen;
    logic [7:0] rd_expected_last_index;
    logic [7:0] rd_beat_index;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_state <= WR_IDLE;
            wr_grant <= 1'b0;
            wr_rr_prefer <= 1'b0;
            wr_aw_seen <= 1'b0;
            wr_wlast_seen <= 1'b0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    wr_aw_seen <= 1'b0;
                    wr_wlast_seen <= 1'b0;
                    if (s0_awvalid || s1_awvalid) begin
                        if (s0_awvalid && s1_awvalid)
                            wr_grant <= wr_rr_prefer;
                        else
                            wr_grant <= s1_awvalid;
                        wr_state <= WR_AW;
                    end
                end
                WR_AW: begin
                    if (m_awvalid && m_awready)
                        wr_aw_seen <= 1'b1;
                    if (m_wvalid && m_wready && m_wlast)
                        wr_wlast_seen <= 1'b1;
                    if ((wr_aw_seen || (m_awvalid && m_awready)) &&
                        (wr_wlast_seen || (m_wvalid && m_wready && m_wlast)))
                        wr_state <= WR_RESP;
                end
                WR_RESP: begin
                    if (m_bvalid && m_bready) begin
                        wr_rr_prefer <= ~wr_grant;
                        wr_state <= WR_IDLE;
                    end
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_state <= RD_IDLE;
            rd_grant <= 1'b0;
            rd_rr_prefer <= 1'b0;
            rd_expected_last_index <= 8'd0;
            rd_beat_index <= 8'd0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (s0_arvalid || s1_arvalid) begin
                        if (s0_arvalid && s1_arvalid)
                            rd_grant <= rd_rr_prefer;
                        else
                            rd_grant <= s1_arvalid;
                        rd_state <= RD_AR;
                    end
                end
                RD_AR: begin
                    if (m_arvalid && m_arready) begin
                        // ARLEN is the zero-based expected final R-beat index.
                        // The first accepted beat therefore uses index zero.
                        rd_expected_last_index <= m_arlen;
                        rd_beat_index <= 8'd0;
                        rd_state <= RD_DATA;
                    end
                end
                RD_DATA: begin
                    if (m_rvalid && m_rready) begin
                        // Early RLAST is the actual end of a malformed burst;
                        // missing RLAST cannot retain the grant beyond the
                        // ARLEN-implied beat count.  A normal final beat meets
                        // both conditions and releases exactly once.
                        if (m_rlast ||
                            (rd_beat_index == rd_expected_last_index)) begin
                            rd_rr_prefer <= ~rd_grant;
                            rd_state <= RD_IDLE;
                        end else begin
                            rd_beat_index <= rd_beat_index + 8'd1;
                        end
                    end
                end
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    always_comb begin
        s0_awready = 1'b0;
        s0_wready = 1'b0;
        s0_bresp = m_bresp;
        s0_bvalid = 1'b0;
        s1_awready = 1'b0;
        s1_wready = 1'b0;
        s1_bresp = m_bresp;
        s1_bvalid = 1'b0;

        m_awaddr = '0;
        m_awlen = '0;
        m_awsize = '0;
        m_awburst = '0;
        m_awvalid = 1'b0;
        m_wdata = '0;
        m_wstrb = '0;
        m_wlast = 1'b0;
        m_wvalid = 1'b0;
        m_bready = 1'b0;

        case (wr_state)
            WR_AW: begin
              if (!wr_aw_seen) begin
                if (!wr_grant) begin
                    m_awaddr = s0_awaddr;
                    m_awlen = s0_awlen;
                    m_awsize = s0_awsize;
                    m_awburst = s0_awburst;
                    m_awvalid = s0_awvalid;
                    s0_awready = m_awready;
                end else begin
                    m_awaddr = s1_awaddr;
                    m_awlen = s1_awlen;
                    m_awsize = s1_awsize;
                    m_awburst = s1_awburst;
                    m_awvalid = s1_awvalid;
                    s1_awready = m_awready;
                end
              end
              if (!wr_wlast_seen) begin
                if (!wr_grant) begin
                    m_wdata = s0_wdata;
                    m_wstrb = s0_wstrb;
                    m_wlast = s0_wlast;
                    m_wvalid = s0_wvalid;
                    s0_wready = m_wready;
                end else begin
                    m_wdata = s1_wdata;
                    m_wstrb = s1_wstrb;
                    m_wlast = s1_wlast;
                    m_wvalid = s1_wvalid;
                    s1_wready = m_wready;
                end
              end
            end
            WR_RESP: begin
                if (!wr_grant) begin
                    s0_bvalid = m_bvalid;
                    s0_bresp = m_bresp;
                    m_bready = s0_bready;
                end else begin
                    s1_bvalid = m_bvalid;
                    s1_bresp = m_bresp;
                    m_bready = s1_bready;
                end
            end
            default: begin end
        endcase

        s0_arready = 1'b0;
        s0_rdata = m_rdata;
        s0_rresp = m_rresp;
        s0_rlast = m_rlast;
        s0_rvalid = 1'b0;
        s1_arready = 1'b0;
        s1_rdata = m_rdata;
        s1_rresp = m_rresp;
        s1_rlast = m_rlast;
        s1_rvalid = 1'b0;

        m_araddr = '0;
        m_arlen = '0;
        m_arsize = '0;
        m_arburst = '0;
        m_arvalid = 1'b0;
        m_rready = 1'b0;

        case (rd_state)
            RD_AR: begin
                if (!rd_grant) begin
                    m_araddr = s0_araddr;
                    m_arlen = s0_arlen;
                    m_arsize = s0_arsize;
                    m_arburst = s0_arburst;
                    m_arvalid = s0_arvalid;
                    s0_arready = m_arready;
                end else begin
                    m_araddr = s1_araddr;
                    m_arlen = s1_arlen;
                    m_arsize = s1_arsize;
                    m_arburst = s1_arburst;
                    m_arvalid = s1_arvalid;
                    s1_arready = m_arready;
                end
            end
            RD_DATA: begin
                if (!rd_grant) begin
                    s0_rvalid = m_rvalid;
                    s0_rdata = m_rdata;
                    s0_rresp = m_rresp;
                    s0_rlast = m_rlast;
                    m_rready = s0_rready;
                end else begin
                    s1_rvalid = m_rvalid;
                    s1_rdata = m_rdata;
                    s1_rresp = m_rresp;
                    s1_rlast = m_rlast;
                    m_rready = s1_rready;
                end
            end
            default: begin end
        endcase
    end

endmodule
