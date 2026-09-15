`timescale 1ns/1ps

module tb_c1_r1_soc_infrastructure;
    localparam integer CLIENTS = 3;

    logic clk = 1'b0;
    logic pixel_clk = 1'b0;
    logic rst = 1'b1;
    logic pixel_rst = 1'b1;
    always #5 clk = ~clk;
    always #7 pixel_clk = ~pixel_clk;

    logic [CLIENTS-1:0][31:0] s_awaddr;
    logic [CLIENTS-1:0][7:0] s_awlen;
    logic [CLIENTS-1:0][2:0] s_awsize;
    logic [CLIENTS-1:0][1:0] s_awburst;
    logic [CLIENTS-1:0] s_awvalid, s_awready;
    logic [CLIENTS-1:0][127:0] s_wdata;
    logic [CLIENTS-1:0][15:0] s_wstrb;
    logic [CLIENTS-1:0] s_wlast, s_wvalid, s_wready;
    logic [CLIENTS-1:0][1:0] s_bresp;
    logic [CLIENTS-1:0] s_bvalid, s_bready;
    logic [CLIENTS-1:0][31:0] s_araddr;
    logic [CLIENTS-1:0][7:0] s_arlen;
    logic [CLIENTS-1:0][2:0] s_arsize;
    logic [CLIENTS-1:0][1:0] s_arburst;
    logic [CLIENTS-1:0] s_arvalid, s_arready;
    logic [CLIENTS-1:0][127:0] s_rdata;
    logic [CLIENTS-1:0][1:0] s_rresp;
    logic [CLIENTS-1:0] s_rlast, s_rvalid, s_rready;
    logic [31:0] m_awaddr;
    logic [7:0] m_awlen;
    logic [2:0] m_awsize;
    logic [1:0] m_awburst;
    logic m_awvalid, m_awready;
    logic [127:0] m_wdata;
    logic [15:0] m_wstrb;
    logic m_wlast, m_wvalid, m_wready;
    logic [1:0] m_bresp;
    logic m_bvalid, m_bready;
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_arvalid, m_arready;
    logic [127:0] m_rdata;
    logic [1:0] m_rresp;
    logic m_rlast, m_rvalid, m_rready;

    logic abort_request, leaf_arvalid, leaf_arready;
    logic abort_pending, abort_to_leaf;
    logic flush_request, safe_to_flush;
    logic flush_busy, flush_done, core_soft_reset, pixel_soft_reset;

    integer read_responses;
    integer write_responses;
    integer flush_core_cycles;
    integer flush_pixel_cycles;
    integer flush_wait_cycles;

    always @(posedge clk)
        if (!rst && core_soft_reset)
            flush_core_cycles = flush_core_cycles + 1;

    always @(posedge pixel_clk)
        if (!pixel_rst && pixel_soft_reset)
            flush_pixel_cycles = flush_pixel_cycles + 1;

    c1_axi_n_serial_arbiter_128 #(.CLIENTS(CLIENTS)) u_arbiter (
        .clk, .rst,
        .s_awaddr, .s_awlen, .s_awsize, .s_awburst,
        .s_awvalid, .s_awready,
        .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
        .s_bresp, .s_bvalid, .s_bready,
        .s_araddr, .s_arlen, .s_arsize, .s_arburst,
        .s_arvalid, .s_arready,
        .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
        .m_awaddr, .m_awlen, .m_awsize, .m_awburst,
        .m_awvalid, .m_awready,
        .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready,
        .m_araddr, .m_arlen, .m_arsize, .m_arburst,
        .m_arvalid, .m_arready,
        .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
    );

    c1_axi_read_abort_fence u_abort_fence (
        .clk, .rst, .abort_request, .leaf_arvalid, .leaf_arready,
        .abort_pending, .abort_to_leaf
    );

    c1_display_flush_reset u_flush (
        .core_clk(clk), .core_rst(rst), .request(flush_request),
        .safe_to_flush, .busy(flush_busy), .done(flush_done),
        .core_soft_reset, .pixel_clk, .pixel_rst, .pixel_soft_reset
    );

    task automatic check_condition(input logic condition, input string message);
        if (!condition) $fatal(1, "%s", message);
    endtask

    task automatic wait_cycles(input integer count);
        repeat (count) @(posedge clk);
    endtask

    task automatic finish_read(
        input integer owner,
        input logic [127:0] payload
    );
        begin
            s_rready[owner] = 1'b0;
            m_rdata = payload;
            m_rresp = 2'b00;
            m_rlast = 1'b1;
            m_rvalid = 1'b1;
            @(posedge clk);
            #1;
            check_condition(!m_rready, "read response ignored selected backpressure");
            check_condition(s_rvalid[owner], "read response not routed to owner");
            check_condition(s_rdata[owner] == payload, "read payload mismatch");
            check_condition((s_rvalid & ~(3'b001 << owner)) == '0,
                   "read response leaked to another client");
            s_rready[owner] = 1'b1;
            @(posedge clk);
            #1;
            m_rvalid = 1'b0;
            s_rready[owner] = 1'b0;
            read_responses = read_responses + 1;
        end
    endtask

    initial begin
        s_awaddr = '0; s_awlen = '0; s_awsize = '0; s_awburst = '0;
        s_awvalid = '0; s_wdata = '0; s_wstrb = '0; s_wlast = '0;
        s_wvalid = '0; s_bready = '0;
        s_araddr = '0; s_arlen = '0; s_arsize = '0; s_arburst = '0;
        s_arvalid = '0; s_rready = '0;
        m_awready = 1'b0; m_wready = 1'b0;
        m_bresp = 2'b00; m_bvalid = 1'b0;
        m_arready = 1'b0; m_rdata = '0; m_rresp = 2'b00;
        m_rlast = 1'b0; m_rvalid = 1'b0;
        abort_request = 1'b0; leaf_arvalid = 1'b0;
        leaf_arready = 1'b0;
        flush_request = 1'b0; safe_to_flush = 1'b0;
        read_responses = 0; write_responses = 0;
        flush_core_cycles = 0; flush_pixel_cycles = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge pixel_clk);
        pixel_rst = 1'b0;
        wait_cycles(2);

        // Simultaneous read clients 0/1 and write client 2 prove that read
        // and write directions lock independently.  Round-robin starts at 0.
        s_araddr[0] = 32'h1000_0000;
        s_araddr[1] = 32'h2000_0000;
        s_arlen[0] = 8'd0; s_arlen[1] = 8'd0;
        s_arsize[0] = 3'd4; s_arsize[1] = 3'd4;
        s_arburst[0] = 2'b01; s_arburst[1] = 2'b01;
        s_arvalid[0] = 1'b1; s_arvalid[1] = 1'b1;
        s_awaddr[2] = 32'h3000_0000;
        s_awlen[2] = 8'd0; s_awsize[2] = 3'd4;
        s_awburst[2] = 2'b01; s_awvalid[2] = 1'b1;
        wait_cycles(2);
        #1;
        check_condition(m_arvalid && (m_araddr == 32'h1000_0000),
               "read round-robin did not select client 0");
        check_condition(m_awvalid && (m_awaddr == 32'h3000_0000),
               "write direction did not independently select client 2");

        // Hold addresses stalled and prove the selected owners remain stable.
        wait_cycles(2);
        #1;
        check_condition(m_araddr == 32'h1000_0000,
               "read owner changed while ARREADY was low");
        check_condition(m_awaddr == 32'h3000_0000,
               "write owner changed while AWREADY was low");
        m_arready = 1'b1; m_awready = 1'b1;
        @(posedge clk);
        #1;
        m_arready = 1'b0; m_awready = 1'b0;
        s_arvalid[0] = 1'b0; s_awvalid[2] = 1'b0;

        s_wdata[2] = 128'hfeed_face_cafe_beef_0123_4567_89ab_cdef;
        s_wstrb[2] = 16'hffff; s_wlast[2] = 1'b1;
        s_wvalid[2] = 1'b1; m_wready = 1'b1;
        #1;
        check_condition(m_wvalid && (m_wdata == s_wdata[2]),
                        "write data payload mismatch");
        @(posedge clk);
        #1;
        s_wvalid[2] = 1'b0; m_wready = 1'b0;
        s_bready[2] = 1'b1; m_bvalid = 1'b1; m_bresp = 2'b00;
        #1;
        check_condition(s_bvalid[2] && (s_bresp[2] == 2'b00),
                        "write response not routed to client 2");
        @(posedge clk);
        #1;
        m_bvalid = 1'b0; s_bready[2] = 1'b0;
        write_responses = write_responses + 1;

        finish_read(0, 128'h0000_0000_0000_0000_1111_2222_3333_4444);

        // Client 1 remained asserted and must receive the next read grant.
        wait_cycles(2);
        #1;
        check_condition(m_arvalid && (m_araddr == 32'h2000_0000),
               "second read grant did not advance to client 1");
        m_arready = 1'b1;
        @(posedge clk);
        #1;
        m_arready = 1'b0; s_arvalid[1] = 1'b0;
        finish_read(1, 128'h5555_6666_7777_8888_9999_aaaa_bbbb_cccc);

        // With RR pointer now at 2, simultaneous clients 0/2 select client 2.
        s_araddr[0] = 32'h4000_0000;
        s_araddr[2] = 32'h5000_0000;
        s_arvalid[0] = 1'b1; s_arvalid[2] = 1'b1;
        wait_cycles(2);
        #1;
        check_condition(m_arvalid && (m_araddr == 32'h5000_0000),
               "wrapped read round-robin did not select client 2");
        m_arready = 1'b1;
        @(posedge clk);
        #1;
        m_arready = 1'b0; s_arvalid[2] = 1'b0;
        finish_read(2, 128'hd00d_d00d_d00d_d00d_d00d_d00d_d00d_d00d);
        s_arvalid[0] = 1'b0;

        // A malformed two-beat response with no RLAST must still release the
        // outer owner at the ARLEN-implied boundary.  This is the condition
        // under which a leaf reader reports missing-RLAST and returns idle.
        s_araddr[0] = 32'h6000_0000;
        s_arlen[0] = 8'd1;
        s_arvalid[0] = 1'b1;
        wait_cycles(2);
        #1;
        check_condition(m_arvalid && (m_araddr == 32'h6000_0000),
                        "missing-RLAST setup did not grant client 0");
        m_arready = 1'b1;
        @(posedge clk);
        #1;
        m_arready = 1'b0; s_arvalid[0] = 1'b0;
        s_rready[0] = 1'b1;
        m_rvalid = 1'b1; m_rlast = 1'b0; m_rresp = 2'b00;
        m_rdata = 128'h0101_0101_0101_0101_0101_0101_0101_0101;
        @(posedge clk);
        #1;
        check_condition(s_rvalid[0],
                        "missing-RLAST first beat was not routed");
        m_rdata = 128'h0202_0202_0202_0202_0202_0202_0202_0202;
        @(posedge clk);
        #1;
        m_rvalid = 1'b0; s_rready[0] = 1'b0;
        read_responses = read_responses + 1;

        s_araddr[1] = 32'h7000_0000;
        s_arlen[1] = 8'd0;
        s_arvalid[1] = 1'b1;
        wait_cycles(2);
        #1;
        check_condition(m_arvalid && (m_araddr == 32'h7000_0000),
                        "missing RLAST retained read owner");
        m_arready = 1'b1;
        @(posedge clk);
        #1;
        m_arready = 1'b0; s_arvalid[1] = 1'b0;
        finish_read(1, 128'h0303_0303_0303_0303_0303_0303_0303_0303);

        // Abort fence must retain a cancel request behind stalled ARVALID.
        leaf_arvalid = 1'b1; leaf_arready = 1'b0;
        abort_request = 1'b1;
        @(posedge clk);
        #1;
        abort_request = 1'b0;
        check_condition(abort_pending && !abort_to_leaf,
               "abort fence cancelled a stalled address");
        wait_cycles(2);
        check_condition(abort_pending && !abort_to_leaf,
               "abort fence lost pending request");
        leaf_arready = 1'b1;
        #1;
        check_condition(abort_to_leaf, "abort fence did not cancel on AR handshake");
        @(posedge clk);
        #1;
        leaf_arvalid = 1'b0; leaf_arready = 1'b0;
        check_condition(!abort_pending, "abort fence did not retire request");

        // A safe (no ARVALID) abort is delivered immediately once.
        abort_request = 1'b1;
        #1;
        check_condition(abort_to_leaf, "safe abort was not delivered immediately");
        @(posedge clk);
        #1;
        check_condition(!abort_to_leaf, "level abort was delivered more than once");
        abort_request = 1'b0;

        // Flush waits for AXI drain, then resets both domains and returns only
        // after the pixel-domain acknowledgement is released.
        @(negedge clk);
        flush_request = 1'b1;
        @(negedge clk);
        flush_request = 1'b0;
        wait_cycles(3);
        check_condition(flush_busy && !core_soft_reset,
               "flush did not wait in the safe barrier");
        safe_to_flush = 1'b1;
        flush_wait_cycles = 0;
        while (!flush_done && (flush_wait_cycles < 40)) begin
            @(posedge clk);
            #1;
            flush_wait_cycles = flush_wait_cycles + 1;
        end
        #1;
        check_condition(flush_done, "flush handshake timed out");
        check_condition(flush_core_cycles > 0, "core soft reset never asserted");
        check_condition(flush_pixel_cycles > 0, "pixel soft reset never asserted");
        check_condition(!flush_busy && !core_soft_reset,
               "flush did not release core side");
        repeat (3) @(posedge pixel_clk);
        check_condition(!pixel_soft_reset, "flush did not release pixel side");

        check_condition(read_responses == 5, "unexpected read response count");
        check_condition(write_responses == 1, "unexpected write response count");
        $display("C1_R1_SOC_INFRA_PASS reads=%0d writes=%0d core_reset=%0d pixel_reset=%0d",
                 read_responses, write_responses,
                 flush_core_cycles, flush_pixel_cycles);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "C1_R1_SOC_INFRA_TIMEOUT");
    end
endmodule
