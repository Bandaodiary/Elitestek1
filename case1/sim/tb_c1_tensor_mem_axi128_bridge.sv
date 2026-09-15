`timescale 1ns/1ps

module tb_c1_tensor_mem_axi128_bridge;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [31:0] mem_req_addr;
    logic [63:0] mem_req_wdata;
    logic [7:0] mem_req_wstrb;
    logic mem_rsp_valid, mem_rsp_ready, mem_rsp_error;
    logic [63:0] mem_rsp_rdata;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid, m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid, m_axi_bready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    c1_tensor_mem_axi128_bridge dut (
        .clk(clk), .rst(rst),
        .read_cache_invalidate(1'b0),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_error(mem_rsp_error),
        .mem_rsp_rdata(mem_rsp_rdata),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    logic [31:0] lfsr_q;
    logic force_ar_block, force_aw_block, force_w_block;
    logic force_ar_ready, force_aw_ready, force_w_ready;

    logic expected_write_q;
    logic [31:0] expected_addr_q;
    logic [63:0] expected_wdata_q;
    logic [7:0] expected_wstrb_q;
    logic [127:0] expected_rdata_q;
    logic [1:0] expected_axi_resp_q;
    logic expected_rlast_q;

    logic read_scheduled_q, read_valid_q;
    logic [2:0] read_delay_q;
    logic aw_seen_q, w_seen_q, b_scheduled_q, b_valid_q;
    logic [2:0] b_delay_q;

    integer ar_count, r_count, aw_count, w_count, b_count;
    integer ar_stall_count, aw_stall_count, w_stall_count;
    integer read_gap_count, write_gap_count, response_stall_count;
    integer lower_count, upper_count, local_error_count;
    integer axi_error_count, missing_rlast_count;
    integer aw_first_count, w_first_count, same_aw_w_count;
    integer request_accept_count, response_accept_count;

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;

    assign m_axi_arready = !read_scheduled_q && !read_valid_q &&
                           !force_ar_block &&
                           (force_ar_ready || lfsr_q[0]);
    assign m_axi_rvalid = read_valid_q;
    assign m_axi_rdata = expected_rdata_q;
    assign m_axi_rresp = expected_axi_resp_q;
    assign m_axi_rlast = expected_rlast_q;

    assign m_axi_awready = !aw_seen_q && !b_scheduled_q &&
                           !force_aw_block &&
                           (force_aw_ready || lfsr_q[1]);
    assign m_axi_wready = !w_seen_q && !b_scheduled_q &&
                          !force_w_block &&
                          (force_w_ready || lfsr_q[2]);
    assign m_axi_bvalid = b_valid_q;
    assign m_axi_bresp = expected_axi_resp_q;

    integer bfm_lane;
    logic [127:0] expected_axi_wdata;
    logic [15:0] expected_axi_wstrb;
    always_comb begin
        if (expected_addr_q[3]) begin
            expected_axi_wdata = {expected_wdata_q, 64'd0};
            expected_axi_wstrb = {expected_wstrb_q, 8'd0};
        end else begin
            expected_axi_wdata = {64'd0, expected_wdata_q};
            expected_axi_wstrb = {8'd0, expected_wstrb_q};
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr_q <= 32'hc731_5a9d;
            read_scheduled_q <= 1'b0;
            read_valid_q <= 1'b0;
            read_delay_q <= 3'd0;
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            b_scheduled_q <= 1'b0;
            b_valid_q <= 1'b0;
            b_delay_q <= 3'd0;
            ar_count <= 0;
            r_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            ar_stall_count <= 0;
            aw_stall_count <= 0;
            w_stall_count <= 0;
            read_gap_count <= 0;
            write_gap_count <= 0;
            aw_first_count <= 0;
            w_first_count <= 0;
            same_aw_w_count <= 0;
            request_accept_count <= 0;
            response_accept_count <= 0;
        end else begin
            lfsr_q <= {lfsr_q[30:0],
                       lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_count <= ar_stall_count + 1;
            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_count <= aw_stall_count + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_count <= w_stall_count + 1;
            if (read_scheduled_q && !read_valid_q)
                read_gap_count <= read_gap_count + 1;
            if (b_scheduled_q && !b_valid_q)
                write_gap_count <= write_gap_count + 1;
            if (mem_req_valid && mem_req_ready) begin
                request_accept_count <= request_accept_count + 1;
                if (mem_rsp_valid)
                    $fatal(1, "request produced a combinational response");
            end
            if (mem_rsp_valid && mem_rsp_ready)
                response_accept_count <= response_accept_count + 1;
            if (response_accept_count > request_accept_count)
                $fatal(1, "spurious or duplicate local response");
            if (m_axi_rready && !read_scheduled_q)
                $fatal(1, "RREADY asserted before an AR handshake");
            if (m_axi_bready && !(aw_seen_q && w_seen_q))
                $fatal(1, "BREADY asserted before AW and W completed");

            if (ar_fire) begin
                if (expected_write_q)
                    $fatal(1, "read address issued for a write request");
                if (m_axi_araddr !== {expected_addr_q[31:4], 4'b0000} ||
                    m_axi_arlen !== 0 || m_axi_arsize !== 3'd4 ||
                    m_axi_arburst !== 2'b01)
                    $fatal(1, "read address/control mismatch");
                ar_count <= ar_count + 1;
                read_scheduled_q <= 1'b1;
                read_delay_q <= {1'b0, lfsr_q[4:3]};
            end
            if (read_scheduled_q && !read_valid_q) begin
                if (read_delay_q == 0)
                    read_valid_q <= 1'b1;
                else
                    read_delay_q <= read_delay_q - 1'b1;
            end
            if (r_fire) begin
                r_count <= r_count + 1;
                read_valid_q <= 1'b0;
                read_scheduled_q <= 1'b0;
            end

            if (aw_fire) begin
                if (!expected_write_q)
                    $fatal(1, "write address issued for a read request");
                if (m_axi_awaddr !== {expected_addr_q[31:4], 4'b0000} ||
                    m_axi_awlen !== 0 || m_axi_awsize !== 3'd4 ||
                    m_axi_awburst !== 2'b01)
                    $fatal(1, "write address/control mismatch");
                aw_count <= aw_count + 1;
                aw_seen_q <= 1'b1;
            end
            if (w_fire) begin
                if (!expected_write_q || m_axi_wdata !== expected_axi_wdata ||
                    m_axi_wstrb !== expected_axi_wstrb || !m_axi_wlast)
                    $fatal(1, "write data/lane mapping mismatch");
                w_count <= w_count + 1;
                w_seen_q <= 1'b1;
            end
            if (aw_fire && w_fire)
                same_aw_w_count <= same_aw_w_count + 1;
            else if (aw_fire && !w_seen_q)
                aw_first_count <= aw_first_count + 1;
            else if (w_fire && !aw_seen_q)
                w_first_count <= w_first_count + 1;

            if (!b_scheduled_q &&
                (aw_seen_q || aw_fire) && (w_seen_q || w_fire)) begin
                b_scheduled_q <= 1'b1;
                b_delay_q <= {1'b0, lfsr_q[6:5]};
            end
            if (b_scheduled_q && !b_valid_q) begin
                if (b_delay_q == 0)
                    b_valid_q <= 1'b1;
                else
                    b_delay_q <= b_delay_q - 1'b1;
            end
            if (b_fire) begin
                b_count <= b_count + 1;
                b_valid_q <= 1'b0;
                b_scheduled_q <= 1'b0;
                aw_seen_q <= 1'b0;
                w_seen_q <= 1'b0;
            end
        end
    end

    task automatic issue_transaction(
        input logic request_write,
        input logic [31:0] request_addr,
        input logic [63:0] request_wdata,
        input logic [7:0] request_wstrb,
        input logic [127:0] axi_rdata,
        input logic [1:0] axi_response,
        input logic axi_rlast,
        input integer response_stalls
    );
        logic expected_error;
        logic [63:0] expected_data;
        logic held_error;
        logic [63:0] held_data;
        integer ar_before, r_before, aw_before, w_before, b_before;
        integer stall_index;
        begin
            expected_error = (request_addr[2:0] != 0) ||
                ((request_addr[2:0] == 0) &&
                 (request_write ? (axi_response != 0) :
                  ((axi_response != 0) || !axi_rlast)));
            if (!request_write && (request_addr[2:0] == 0))
                expected_data = request_addr[3] ?
                                axi_rdata[127:64] : axi_rdata[63:0];
            else
                expected_data = 64'd0;

            ar_before = ar_count;
            r_before = r_count;
            aw_before = aw_count;
            w_before = w_count;
            b_before = b_count;

            @(negedge clk);
            expected_write_q = request_write;
            expected_addr_q = request_addr;
            expected_wdata_q = request_wdata;
            expected_wstrb_q = request_wstrb;
            expected_rdata_q = axi_rdata;
            expected_axi_resp_q = axi_response;
            expected_rlast_q = axi_rlast;
            mem_req_write = request_write;
            mem_req_addr = request_addr;
            mem_req_wdata = request_wdata;
            mem_req_wstrb = request_wstrb;
            mem_req_valid = 1'b1;
            do @(posedge clk); while (!mem_req_ready);
            @(negedge clk);
            mem_req_valid = 1'b0;

            while (!mem_rsp_valid) begin
                @(posedge clk);
                if (mem_req_ready)
                    $fatal(1, "bridge accepted another request while busy");
            end
            held_error = mem_rsp_error;
            held_data = mem_rsp_rdata;
            for (stall_index = 0; stall_index < response_stalls;
                 stall_index = stall_index + 1) begin
                @(posedge clk);
                response_stall_count = response_stall_count + 1;
                if (!mem_rsp_valid || mem_rsp_error !== held_error ||
                    mem_rsp_rdata !== held_data || mem_req_ready)
                    $fatal(1, "local response changed while stalled");
            end
            if (held_error !== expected_error || held_data !== expected_data)
                $fatal(1, "response mismatch write=%0d addr=%h got err/data=%0d/%h exp=%0d/%h",
                       request_write, request_addr, held_error, held_data,
                       expected_error, expected_data);

            @(negedge clk);
            mem_rsp_ready = 1'b1;
            @(posedge clk);
            if (!mem_rsp_valid)
                $fatal(1, "response disappeared before ready handshake");
            @(negedge clk);
            mem_rsp_ready = 1'b0;

            if (request_addr[2:0] != 0) begin
                local_error_count = local_error_count + 1;
                if (ar_count != ar_before || r_count != r_before ||
                    aw_count != aw_before || w_count != w_before ||
                    b_count != b_before)
                    $fatal(1, "misaligned request leaked to AXI");
            end else if (request_write) begin
                if ((aw_count != aw_before + 1) ||
                    (w_count != w_before + 1) ||
                    (b_count != b_before + 1) ||
                    (ar_count != ar_before) || (r_count != r_before))
                    $fatal(1, "write transaction count mismatch");
            end else begin
                if ((ar_count != ar_before + 1) ||
                    (r_count != r_before + 1) ||
                    (aw_count != aw_before) || (w_count != w_before) ||
                    (b_count != b_before))
                    $fatal(1, "read transaction count mismatch");
            end

            if (request_addr[3])
                upper_count = upper_count + 1;
            else
                lower_count = lower_count + 1;
            if ((request_addr[2:0] == 0) && (axi_response != 0))
                axi_error_count = axi_error_count + 1;
            if ((request_addr[2:0] == 0) && !request_write && !axi_rlast)
                missing_rlast_count = missing_rlast_count + 1;
        end
    endtask

    integer i;
    logic random_write;
    logic [31:0] random_addr;
    logic [63:0] random_wdata;
    logic [7:0] random_wstrb;
    logic [127:0] random_rdata;
    logic [1:0] random_resp;
    logic random_rlast;
    initial begin
        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = 32'd0;
        mem_req_wdata = 64'd0;
        mem_req_wstrb = 8'd0;
        mem_rsp_ready = 1'b0;
        expected_write_q = 1'b0;
        expected_addr_q = 32'd0;
        expected_wdata_q = 64'd0;
        expected_wstrb_q = 8'd0;
        expected_rdata_q = 128'd0;
        expected_axi_resp_q = 2'd0;
        expected_rlast_q = 1'b1;
        force_ar_block = 1'b0;
        force_aw_block = 1'b0;
        force_w_block = 1'b0;
        force_ar_ready = 1'b0;
        force_aw_ready = 1'b0;
        force_w_ready = 1'b0;
        response_stall_count = 0;
        lower_count = 0;
        upper_count = 0;
        local_error_count = 0;
        axi_error_count = 0;
        missing_rlast_count = 0;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Local rejects: neither read nor write may reach AXI.
        issue_transaction(1'b0, 32'h0000_1004, 64'd0, 8'd0,
                          128'h1111, 2'b00, 1'b1, 3);
        issue_transaction(1'b1, 32'h0000_2002,
                          64'h0123_4567_89ab_cdef, 8'h5a,
                          128'd0, 2'b00, 1'b1, 2);

        // Directed lower/upper reads, AR stall, RRESP and missing RLAST.
        force_ar_block = 1'b1;
        fork
            issue_transaction(1'b0, 32'h0000_3000, 64'd0, 8'd0,
                128'hfedc_ba98_7654_3210_0123_4567_89ab_cdef,
                2'b00, 1'b1, 5);
            begin
                wait (m_axi_arvalid);
                repeat (4) @(posedge clk);
                force_ar_block = 1'b0;
                force_ar_ready = 1'b1;
            end
        join
        force_ar_ready = 1'b0;
        issue_transaction(1'b0, 32'h0000_3008, 64'd0, 8'd0,
            128'h8899_aabb_ccdd_eeff_0011_2233_4455_6677,
            2'b10, 1'b1, 1);
        issue_transaction(1'b0, 32'h0000_3018, 64'd0, 8'd0,
            128'h1357_9bdf_2468_ace0_0f1e_2d3c_4b5a_6978,
            2'b00, 1'b0, 2);
        // Full 128-bit beat aligned down to 0x...ff0: this touches both the
        // addr[3] upper-half case and the final beat before a 4 KiB boundary.
        issue_transaction(1'b0, 32'h0000_0ff8, 64'd0, 8'd0,
            128'h1020_3040_5060_7080_90a0_b0c0_d0e0_f000,
            2'b01, 1'b1, 2);

        // Directed W-first then AW-first writes prove independent channels.
        force_aw_block = 1'b1;
        force_w_ready = 1'b1;
        fork
            issue_transaction(1'b1, 32'h0000_4008,
                64'hdead_beef_0123_4567, 8'ha5,
                128'd0, 2'b00, 1'b1, 4);
            begin
                wait (w_seen_q);
                repeat (3) @(posedge clk);
                force_aw_block = 1'b0;
                force_aw_ready = 1'b1;
            end
        join
        force_aw_ready = 1'b0;
        force_w_ready = 1'b0;

        // Highest legal 8-byte tensor address maps to the final aligned
        // 128-bit AXI beat without 32-bit address overflow.
        issue_transaction(1'b1, 32'hffff_fff8,
            64'hffff_0000_a55a_3cc3, 8'h81,
            128'd0, 2'b00, 1'b1, 1);

        force_w_block = 1'b1;
        force_aw_ready = 1'b1;
        fork
            issue_transaction(1'b1, 32'h0000_5000,
                64'h55aa_00ff_c33c_6996, 8'h3c,
                128'd0, 2'b11, 1'b1, 3);
            begin
                wait (aw_seen_q);
                repeat (3) @(posedge clk);
                force_w_block = 1'b0;
                force_w_ready = 1'b1;
            end
        join
        force_aw_ready = 1'b0;
        force_w_ready = 1'b0;

        // 1200 deterministic-random transactions.  They cover both halves,
        // arbitrary byte enables, all AXI response encodings, missing RLAST,
        // independent AW/W ordering, response stalls and AXI latency gaps.
        for (i = 0; i < 1200; i = i + 1) begin
            random_write = ((i * 17 + 3) % 5) < 3;
            random_addr = 32'h0010_0000 + ((i * 37) << 4) +
                          (((i * 13) & 1) ? 8 : 0);
            random_wdata = {32'h9e37_79b9 ^ (i * 32'h1021),
                            32'h7f4a_7c15 + (i * 32'h45d9)};
            random_wstrb = ((i * 8'h5d) ^ (i >> 3) ^ 8'ha6);
            random_rdata = {
                32'h8000_0000 ^ (i * 32'h1f12_3bb5),
                32'h2468_ace0 + (i * 32'h0001_0101),
                32'h1357_9bdf ^ (i * 32'h0102_0408),
                32'h0000_0001 + (i * 32'h9e37_79b9)
            };
            if ((i % 53) == 0)
                random_resp = 2'b01;
            else if ((i % 47) == 0)
                random_resp = 2'b10;
            else if ((i % 43) == 0)
                random_resp = 2'b11;
            else
                random_resp = 2'b00;
            random_rlast = random_write || ((i % 41) != 0);
            issue_transaction(random_write, random_addr,
                              random_wdata, random_wstrb,
                              random_rdata, random_resp,
                              random_rlast, (i * 7) % 5);
        end

        if (ar_stall_count == 0 || aw_stall_count == 0 ||
            w_stall_count == 0 || read_gap_count == 0 ||
            write_gap_count == 0 || response_stall_count == 0)
            $fatal(1, "backpressure/latency coverage missing");
        if (lower_count == 0 || upper_count == 0 || local_error_count != 2 ||
            axi_error_count == 0 || missing_rlast_count == 0)
            $fatal(1, "lane/error coverage missing");
        if (aw_first_count == 0 || w_first_count == 0 ||
            same_aw_w_count == 0)
            $fatal(1, "independent AW/W order coverage missing");
        if (ar_count != r_count || aw_count != w_count || aw_count != b_count)
            $fatal(1, "final AXI transaction accounting mismatch");
        if (request_accept_count != response_accept_count ||
            request_accept_count != ar_count + aw_count + local_error_count)
            $fatal(1, "local request/response accounting mismatch");

        $display("C1_TENSOR_MEM_AXI128_BRIDGE_PASS transactions=%0d ar=%0d aw=%0d lower=%0d upper=%0d localerr=%0d axierr=%0d missing_rlast=%0d arstall=%0d awstall=%0d wstall=%0d rspstall=%0d awfirst=%0d wfirst=%0d same=%0d",
                 ar_count + aw_count + local_error_count,
                 ar_count, aw_count, lower_count, upper_count,
                 local_error_count, axi_error_count, missing_rlast_count,
                 ar_stall_count, aw_stall_count, w_stall_count,
                 response_stall_count, aw_first_count, w_first_count,
                 same_aw_w_count);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "global tensor AXI bridge timeout");
    end

endmodule
