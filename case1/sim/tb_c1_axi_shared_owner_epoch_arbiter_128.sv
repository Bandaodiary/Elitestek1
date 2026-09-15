`timescale 1ns/1ps

// Focused boardless smoke test for the reusable owner/epoch arbiter shell.
// The test intentionally stalls one selected AXI response while a fence is
// asserted, then checks that the selected owner drains and a second idle
// owner remains blocked.
module tb_c1_axi_shared_owner_epoch_arbiter_128;
    localparam integer CLIENTS = 2;
    localparam integer INDEX_W = 1;
`ifdef C1_READ_RESPONSE_SKID
    localparam integer TEST_READ_RESPONSE_SKID = 1;
`else
    localparam integer TEST_READ_RESPONSE_SKID = 0;
`endif

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [CLIENTS-1:0][31:0] s_awaddr = '0;
    logic [CLIENTS-1:0][7:0] s_awlen = '0;
    logic [CLIENTS-1:0][2:0] s_awsize = '0;
    logic [CLIENTS-1:0][1:0] s_awburst = '0;
    logic [CLIENTS-1:0] s_awvalid = '0, s_awready;
    logic [CLIENTS-1:0][127:0] s_wdata = '0;
    logic [CLIENTS-1:0][15:0] s_wstrb = '0;
    logic [CLIENTS-1:0] s_wlast = '0, s_wvalid = '0, s_wready;
    logic [CLIENTS-1:0][1:0] s_bresp;
    logic [CLIENTS-1:0] s_bvalid, s_bready = '0;
    logic [CLIENTS-1:0][31:0] s_araddr = '0;
    logic [CLIENTS-1:0][7:0] s_arlen = '0;
    logic [CLIENTS-1:0][2:0] s_arsize = '0;
    logic [CLIENTS-1:0][1:0] s_arburst = '0;
    logic [CLIENTS-1:0] s_arvalid = '0, s_arready;
    logic [CLIENTS-1:0][127:0] s_rdata;
    logic [CLIENTS-1:0][1:0] s_rresp;
    logic [CLIENTS-1:0] s_rlast, s_rvalid, s_rready = '0;

    logic [31:0] m_awaddr;
    logic [7:0] m_awlen;
    logic [2:0] m_awsize;
    logic [1:0] m_awburst;
    logic m_awvalid, m_awready = 1'b1;
    logic [127:0] m_wdata;
    logic [15:0] m_wstrb;
    logic m_wlast, m_wvalid, m_wready = 1'b1;
    logic [1:0] m_bresp = 2'b00;
    logic m_bvalid = 1'b0, m_bready;
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_arvalid, m_arready = 1'b1;
    logic [127:0] m_rdata = 128'hcafe_0000_0000_0000_0000_0000_0000_0001;
    logic [1:0] m_rresp = 2'b00;
    logic m_rlast = 1'b1, m_rvalid = 1'b0, m_rready;

    logic context_start_valid = 1'b0, context_start_ready;
    logic abort_req = 1'b0, flush_req = 1'b0;
    logic context_active;
    logic [3:0] current_epoch;
    logic fence_busy, abort_done, flush_done, epoch_bump;
    logic protocol_error;
    logic [63:0] perf_fence_count, perf_abort_count, perf_flush_count;
    logic read_busy, read_quiescent, write_busy, write_quiescent;
    logic [INDEX_W-1:0] read_owner, write_owner;
    logic read_admit, write_admit, read_fire, write_fire;

    logic r_pending_q = 1'b0;
    logic b_pending_q = 1'b0;
    integer cycles = 0;
    integer ar_accepts = 0, aw_accepts = 0, r_accepts = 0, b_accepts = 0;

    c1_axi_shared_owner_epoch_arbiter_128 #(
        .CLIENTS(CLIENTS), .INDEX_W(INDEX_W),
        .READ_RESPONSE_SKID(TEST_READ_RESPONSE_SKID),
        .EPOCH_W(4), .REQUIRE_CONTEXT(1'b1), .ALLOW_RESTART(1'b1)
    ) dut (
        .clk(clk), .rst(rst),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bresp(s_bresp),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize),
        .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
        .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready), .m_bresp(m_bresp),
        .m_bvalid(m_bvalid), .m_bready(m_bready), .m_araddr(m_araddr),
        .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata),
        .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .context_start_valid(context_start_valid),
        .context_start_ready(context_start_ready), .abort_req(abort_req),
        .flush_req(flush_req), .context_active(context_active),
        .current_epoch(current_epoch), .fence_busy(fence_busy),
        .abort_done(abort_done), .flush_done(flush_done),
        .epoch_bump(epoch_bump), .protocol_error(protocol_error),
        .perf_fence_count(perf_fence_count),
        .perf_abort_count(perf_abort_count),
        .perf_flush_count(perf_flush_count), .read_busy(read_busy),
        .read_quiescent(read_quiescent), .write_busy(write_busy),
        .write_quiescent(write_quiescent), .read_owner(read_owner),
        .write_owner(write_owner), .read_admit(read_admit),
        .write_admit(write_admit), .read_fire(read_fire),
        .write_fire(write_fire)
    );

    wire axi_ar_fire = m_arvalid && m_arready;
    wire axi_r_fire = m_rvalid && m_rready;
    wire axi_aw_fire = m_awvalid && m_awready;
    wire axi_w_fire = m_wvalid && m_wready;
    wire axi_b_fire = m_bvalid && m_bready;

    // Registered one-beat downstream model.  Responses are held until the
    // client explicitly raises READY, which makes the fence drain visible.
    always_ff @(posedge clk) begin
        if (rst) begin
            r_pending_q <= 1'b0;
            m_rvalid <= 1'b0;
            b_pending_q <= 1'b0;
            m_bvalid <= 1'b0;
            cycles <= 0;
            ar_accepts <= 0;
            aw_accepts <= 0;
            r_accepts <= 0;
            b_accepts <= 0;
        end else begin
            cycles <= cycles + 1;
            if (axi_ar_fire) begin
                r_pending_q <= 1'b1;
                ar_accepts <= ar_accepts + 1;
            end
            if (r_pending_q && !m_rvalid)
                m_rvalid <= 1'b1;
            if (axi_r_fire) begin
                m_rvalid <= 1'b0;
                r_pending_q <= 1'b0;
                r_accepts <= r_accepts + 1;
            end
            if (axi_w_fire && m_wlast)
                b_pending_q <= 1'b1;
            if (b_pending_q && !m_bvalid)
                m_bvalid <= 1'b1;
            if (axi_b_fire) begin
                m_bvalid <= 1'b0;
                b_pending_q <= 1'b0;
                b_accepts <= b_accepts + 1;
            end
            if (axi_aw_fire)
                aw_accepts <= aw_accepts + 1;
        end
    end

    task automatic fail(input string message);
        begin
            $display("C1_AXI_SHARED_OWNER_EPOCH_ARBITER_FAIL %s", message);
            $fatal(1, "%s", message);
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            context_start_valid <= 1'b1;
            #1;
            while (!context_start_ready) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            context_start_valid <= 1'b0;
        end
    endtask

    task automatic issue_read0;
        begin
            @(negedge clk);
            s_arvalid[0] <= 1'b1;
            #1;
            while (!s_arready[0]) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            s_arvalid[0] <= 1'b0;
        end
    endtask

    task automatic issue_write0;
        begin
            @(negedge clk);
            s_awvalid[0] <= 1'b1;
            #1;
            while (!s_awready[0]) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            s_awvalid[0] <= 1'b0;
            s_wvalid[0] <= 1'b1;
            #1;
            while (!s_wready[0]) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            s_wvalid[0] <= 1'b0;
        end
    endtask

    initial begin
        s_araddr[0] = 32'h0000_1000;
        s_arlen[0] = 8'd0;
        s_arsize[0] = 3'd4;
        s_arburst[0] = 2'b01;
        s_araddr[1] = 32'h0000_2000;
        s_arlen[1] = 8'd0;
        s_arsize[1] = 3'd4;
        s_arburst[1] = 2'b01;
        s_awaddr[0] = 32'h0000_3000;
        s_awlen[0] = 8'd0;
        s_awsize[0] = 3'd4;
        s_awburst[0] = 2'b01;
        s_wdata[0] = 128'h1234;
        s_wstrb[0] = 16'hffff;
        s_wlast[0] = 1'b1;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);
        pulse_start();
        if (!context_active || current_epoch !== 4'd0 ||
            !read_admit || !write_admit)
            fail("context start did not open wrapper admissions");

        // Read owner 0 is accepted, then its response is deliberately held.
        issue_read0();
        repeat (3) @(posedge clk);
        if (!read_busy || read_quiescent || read_owner !== 1'd0)
            fail("wrapper did not expose active read owner");
        @(negedge clk);
        s_arvalid[1] <= 1'b1;
        abort_req <= 1'b1;
        #1;
        if (read_admit || write_admit || s_arready[1])
            fail("abort did not block a new idle read owner");
        @(posedge clk);
        #1;
        if (!fence_busy || !read_busy)
            fail("abort fence lost selected read owner");
        @(negedge clk);
        s_rready[0] <= 1'b1;
        s_arvalid[1] <= 1'b0;
        for (integer k = 0; k < 10; k = k + 1) begin
            @(posedge clk);
            #1;
            if (abort_done)
                k = 10;
        end
        if (current_epoch !== 4'd1 || context_active || protocol_error ||
            ar_accepts != 1 || r_accepts != 1 || perf_abort_count != 1)
            fail("abort did not drain wrapper read owner atomically");
        @(negedge clk);
        abort_req <= 1'b0;

        pulse_start();
        if (!context_active || current_epoch !== 4'd1)
            fail("restart after wrapper read abort failed");

        // Write owner 0 is held at the B response while a flush is asserted.
        issue_write0();
        repeat (2) @(posedge clk);
        if (!write_busy || write_quiescent || write_owner !== 1'd0)
            fail("wrapper did not expose active write owner");
        @(negedge clk);
        s_bready[0] <= 1'b0;
        s_awvalid[1] <= 1'b1;
        flush_req <= 1'b1;
        #1;
        if (read_admit || write_admit || s_awready[1])
            fail("flush did not block a new idle write owner");
        @(posedge clk);
        #1;
        if (!fence_busy || !write_busy)
            fail("flush fence lost selected write owner");
        @(negedge clk);
        s_bready[0] <= 1'b1;
        s_awvalid[1] <= 1'b0;
        flush_req <= 1'b0;
        for (integer j = 0; j < 10; j = j + 1) begin
            @(posedge clk);
            #1;
            if (flush_done)
                j = 10;
        end
        if (current_epoch !== 4'd2 || !context_active || protocol_error ||
            aw_accepts != 1 || b_accepts != 1 || perf_flush_count != 1)
            fail("flush did not drain wrapper write owner atomically");

        $display("C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS ar=%0d r=%0d aw=%0d b=%0d epoch=%0d cycles=%0d",
                 ar_accepts, r_accepts, aw_accepts, b_accepts,
                 current_epoch, cycles);
        $finish;
    end

    initial begin
        #50000;
        fail("timeout");
    end
endmodule
