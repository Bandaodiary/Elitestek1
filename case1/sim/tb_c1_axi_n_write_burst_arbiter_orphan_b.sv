`timescale 1ns/1ps

// Minimal regression for the malformed-slave drain path.  When no descriptor
// is active the arbiter deliberately accepts an unsolicited B, but that
// handshake must not retire a FIFO entry or increment perf_b_count.
module tb_c1_axi_n_write_burst_arbiter_orphan_b;
    localparam integer CLIENTS = 2;
    localparam integer FIFO_DEPTH = 2;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [CLIENTS-1:0][31:0] s_awaddr = '0;
    logic [CLIENTS-1:0][7:0] s_awlen = '0;
    logic [CLIENTS-1:0][2:0] s_awsize = '0;
    logic [CLIENTS-1:0][1:0] s_awburst = '0;
    logic [CLIENTS-1:0] s_awvalid = '0;
    logic [CLIENTS-1:0] s_awready;
    logic [CLIENTS-1:0][127:0] s_wdata = '0;
    logic [CLIENTS-1:0][15:0] s_wstrb = '0;
    logic [CLIENTS-1:0] s_wlast = '0;
    logic [CLIENTS-1:0] s_wvalid = '0;
    logic [CLIENTS-1:0] s_wready;
    logic [CLIENTS-1:0][1:0] s_bresp;
    logic [CLIENTS-1:0] s_bvalid;
    logic [CLIENTS-1:0] s_bready = '1;

    logic [31:0] m_awaddr;
    logic [7:0] m_awlen;
    logic [2:0] m_awsize;
    logic [1:0] m_awburst;
    logic m_awvalid;
    logic m_awready = 1'b1;
    logic [127:0] m_wdata;
    logic [15:0] m_wstrb;
    logic m_wlast;
    logic m_wvalid;
    logic m_wready = 1'b1;
    logic [1:0] m_bresp = 2'b11;
    logic m_bvalid = 1'b0;
    logic m_bready;

    logic protocol_error, early_wlast_error, missing_wlast_error;
    logic early_b_error, orphan_b_error;
    logic [7:0] perf_outstanding, perf_max_outstanding;
    logic [63:0] perf_aw_accept_count, perf_aw_issue_count;
    logic [63:0] perf_w_beat_count, perf_b_count;

    c1_axi_n_write_burst_arbiter_128 #(
        .CLIENTS(CLIENTS), .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk, .rst,
        .s_awaddr, .s_awlen, .s_awsize, .s_awburst,
        .s_awvalid, .s_awready,
        .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
        .s_bresp, .s_bvalid, .s_bready,
        .m_awaddr, .m_awlen, .m_awsize, .m_awburst,
        .m_awvalid, .m_awready,
        .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready,
        .protocol_error, .early_wlast_error, .missing_wlast_error,
        .early_b_error, .orphan_b_error,
        .perf_outstanding, .perf_max_outstanding,
        .perf_aw_accept_count, .perf_aw_issue_count,
        .perf_w_beat_count, .perf_b_count
    );

    task automatic fail(input string message);
        begin
            $display("C1_AXI_N_WRITE_BURST_ARBITER_ORPHAN_FAIL t=%0t: %s",
                     $time, message);
            $fatal(1);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        // Drive an unsolicited B for exactly one full cycle.  The arbiter
        // should drain it (m_bready=1) and set only the sticky orphan flag.
        @(negedge clk); #1;
        m_bvalid = 1'b1;
        @(posedge clk); #1;
        if (!m_bready)
            fail("orphan B was not drained");
        if (!orphan_b_error || !protocol_error)
            fail("orphan diagnostic flag was not set");
        if (perf_outstanding != 0 || perf_aw_accept_count != 0 ||
            perf_aw_issue_count != 0 || perf_w_beat_count != 0 ||
            perf_b_count != 0)
            fail("orphan B changed descriptor/performance state");
        @(negedge clk); #1;
        m_bvalid = 1'b0;
        repeat (2) @(posedge clk);
        $display("C1_AXI_N_WRITE_BURST_ARBITER_ORPHAN_PASS orphan=%0d count=%0d b=%0d",
                 orphan_b_error, perf_outstanding, perf_b_count);
        $finish;
    end
endmodule
