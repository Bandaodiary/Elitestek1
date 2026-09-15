`timescale 1ns/1ps

// Minimal fabric-boundary proof for the tensor/cache client.  The wrapper is
// connected to slot 6 of the real N-way arbiter; the other six slots are tied
// off.  A tiny AXI128 BFM returns single-beat data and deliberately inserts
// address/data/response gaps, proving that cache refills and direct requests
// survive the shared-fabric lock/route boundary.
module tb_c1_tensor_window_cache_axi_client;
    localparam integer CLIENTS = 7;
    localparam integer TENSOR_CLIENT = 6;
    localparam logic [31:0] BASE = 32'h0000_1000;
    localparam integer ROW_WORDS = 4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic stage_start_valid = 1'b0, stage_start_ready;
    logic stage_cache_enable = 1'b1;
    logic [31:0] stage_base_addr = BASE;
    logic [15:0] stage_width = 16'd4, stage_height = 16'd4;
    logic [3:0] stage_groups = 4'd1;
    logic stage_start_done, stage_cache_active, stage_cache_fallback;
    logic [3:0] stage_cache_reason;
    logic abort_req = 1'b0, abort_done;
    logic flush_req = 1'b0, flush_done;

    logic s_req_valid = 1'b0, s_req_ready, s_req_write = 1'b0;
    logic [31:0] s_req_addr = 32'd0;
    logic [63:0] s_req_wdata = 64'd0;
    logic [7:0] s_req_wstrb = 8'd0;
    logic s_req_cacheable = 1'b0;
    logic signed [16:0] s_req_cache_x = 17'sd0;
    logic signed [16:0] s_req_cache_y = 17'sd0;
    logic [2:0] s_req_cache_group = 3'd0;
    logic s_rsp_valid, s_rsp_ready = 1'b0, s_rsp_error;
    logic [63:0] s_rsp_rdata;
    logic cache_error;
    logic [2:0] cache_error_code;
    logic cache_busy, cache_quiescent;

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

    c1_tensor_window_cache_axi_client #(.ENABLE_CACHE(1)) dut (
        .clk(clk), .rst(rst),
        .stage_start_valid(stage_start_valid),
        .stage_start_ready(stage_start_ready),
        .stage_cache_enable(stage_cache_enable),
        .stage_base_addr(stage_base_addr),
        .stage_width(stage_width), .stage_height(stage_height),
        .stage_groups(stage_groups), .stage_start_done(stage_start_done),
        .stage_cache_active(stage_cache_active),
        .stage_cache_fallback(stage_cache_fallback),
        .stage_cache_reason(stage_cache_reason),
        .abort_req(abort_req), .abort_done(abort_done),
        .flush_req(flush_req), .flush_done(flush_done),
        .s_req_valid(s_req_valid), .s_req_ready(s_req_ready),
        .s_req_write(s_req_write), .s_req_addr(s_req_addr),
        .s_req_wdata(s_req_wdata), .s_req_wstrb(s_req_wstrb),
        .s_req_cacheable(s_req_cacheable), .s_req_cache_x(s_req_cache_x),
        .s_req_cache_y(s_req_cache_y), .s_req_cache_group(s_req_cache_group),
        .s_rsp_valid(s_rsp_valid), .s_rsp_ready(s_rsp_ready),
        .s_rsp_error(s_rsp_error), .s_rsp_rdata(s_rsp_rdata),
        .m_axi_awvalid(s_awvalid[TENSOR_CLIENT]),
        .m_axi_awready(s_awready[TENSOR_CLIENT]),
        .m_axi_awaddr(s_awaddr[TENSOR_CLIENT]),
        .m_axi_awlen(s_awlen[TENSOR_CLIENT]),
        .m_axi_awsize(s_awsize[TENSOR_CLIENT]),
        .m_axi_awburst(s_awburst[TENSOR_CLIENT]),
        .m_axi_wvalid(s_wvalid[TENSOR_CLIENT]),
        .m_axi_wready(s_wready[TENSOR_CLIENT]),
        .m_axi_wdata(s_wdata[TENSOR_CLIENT]),
        .m_axi_wstrb(s_wstrb[TENSOR_CLIENT]),
        .m_axi_wlast(s_wlast[TENSOR_CLIENT]),
        .m_axi_bresp(s_bresp[TENSOR_CLIENT]),
        .m_axi_bvalid(s_bvalid[TENSOR_CLIENT]),
        .m_axi_bready(s_bready[TENSOR_CLIENT]),
        .m_axi_arvalid(s_arvalid[TENSOR_CLIENT]),
        .m_axi_arready(s_arready[TENSOR_CLIENT]),
        .m_axi_araddr(s_araddr[TENSOR_CLIENT]),
        .m_axi_arlen(s_arlen[TENSOR_CLIENT]),
        .m_axi_arsize(s_arsize[TENSOR_CLIENT]),
        .m_axi_arburst(s_arburst[TENSOR_CLIENT]),
        .m_axi_rdata(s_rdata[TENSOR_CLIENT]),
        .m_axi_rresp(s_rresp[TENSOR_CLIENT]),
        .m_axi_rlast(s_rlast[TENSOR_CLIENT]),
        .m_axi_rvalid(s_rvalid[TENSOR_CLIENT]),
        .m_axi_rready(s_rready[TENSOR_CLIENT]),
        .cache_error(cache_error), .cache_error_code(cache_error_code),
        .busy(cache_busy), .quiescent(cache_quiescent)
    );

    c1_axi_n_serial_arbiter_128 #(.CLIENTS(CLIENTS)) u_fabric (
        .clk(clk), .rst(rst),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready), .s_bresp(s_bresp),
        .s_bvalid(s_bvalid), .s_bready(s_bready), .s_araddr(s_araddr),
        .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(s_arvalid), .s_arready(s_arready), .s_rdata(s_rdata),
        .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid),
        .s_rready(s_rready), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awvalid(m_awvalid),
        .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb),
        .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    // No other client may accidentally issue traffic in this minimal proof.
    genvar g;
    generate for (g = 0; g < TENSOR_CLIENT; g = g + 1) begin : TIE_OFF
        assign s_awaddr[g] = 32'd0;
        assign s_awlen[g] = 8'd0;
        assign s_awsize[g] = 3'd0;
        assign s_awburst[g] = 2'd0;
        assign s_awvalid[g] = 1'b0;
        assign s_wdata[g] = 128'd0;
        assign s_wstrb[g] = 16'd0;
        assign s_wlast[g] = 1'b0;
        assign s_wvalid[g] = 1'b0;
        assign s_bready[g] = 1'b0;
        assign s_araddr[g] = 32'd0;
        assign s_arlen[g] = 8'd0;
        assign s_arsize[g] = 3'd0;
        assign s_arburst[g] = 2'd0;
        assign s_arvalid[g] = 1'b0;
        assign s_rready[g] = 1'b0;
    end endgenerate

    integer cycle_q;
    integer ar_count, r_count, aw_count, w_count, b_count;
    logic rd_pending_q;
    integer rd_delay_q;
    logic wr_aw_seen_q, wr_w_seen_q;
    integer wr_b_delay_q;
    logic [31:0] wr_addr_q;
    logic [127:0] wr_data_q;
    logic [15:0] wr_strb_q;

    function automatic [63:0] word_value(input logic [31:0] a);
        word_value = 64'hc100_0000_0000_0000 | {32'd0, a};
    endfunction

    assign m_awready = !rst && ((cycle_q % 4) != 1);
    assign m_wready = !rst && ((cycle_q % 5) != 2);
    assign m_arready = !rst && ((cycle_q % 3) != 0);

    always @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0;
            ar_count <= 0; r_count <= 0; aw_count <= 0;
            w_count <= 0; b_count <= 0;
            rd_pending_q <= 1'b0; rd_delay_q <= 0;
            m_rvalid <= 1'b0; m_rlast <= 1'b0; m_rresp <= 2'b00;
            m_rdata <= 128'd0;
            wr_aw_seen_q <= 1'b0; wr_w_seen_q <= 1'b0;
            wr_b_delay_q <= 0; m_bvalid <= 1'b0; m_bresp <= 2'b00;
        end else begin
            cycle_q <= cycle_q + 1;

            if (m_arvalid && m_arready) begin
                ar_count <= ar_count + 1;
                rd_pending_q <= 1'b1;
                rd_delay_q <= 1 + (cycle_q % 2);
                m_rdata <= {word_value(m_araddr + 32'd8),
                            word_value(m_araddr)};
                m_rresp <= 2'b00;
                m_rlast <= 1'b1;
            end
            if (rd_pending_q && !m_rvalid) begin
                if (rd_delay_q == 0) begin
                    m_rvalid <= 1'b1;
                    rd_pending_q <= 1'b0;
                end else
                    rd_delay_q <= rd_delay_q - 1;
            end
            if (m_rvalid && m_rready) begin
                m_rvalid <= 1'b0;
                r_count <= r_count + 1;
            end

            if (m_awvalid && m_awready) begin
                aw_count <= aw_count + 1;
                wr_aw_seen_q <= 1'b1;
                wr_addr_q <= m_awaddr;
            end
            if (m_wvalid && m_wready) begin
                w_count <= w_count + 1;
                wr_w_seen_q <= 1'b1;
                wr_data_q <= m_wdata;
                wr_strb_q <= m_wstrb;
            end
            if (wr_aw_seen_q && wr_w_seen_q && !m_bvalid) begin
                if (wr_b_delay_q == 0) begin
                    m_bvalid <= 1'b1;
                    m_bresp <= 2'b00;
                    wr_aw_seen_q <= 1'b0;
                    wr_w_seen_q <= 1'b0;
                end else
                    wr_b_delay_q <= wr_b_delay_q - 1;
            end
            if (m_awvalid && m_awready && m_wvalid && m_wready)
                wr_b_delay_q <= 1;
            if (m_bvalid && m_bready) begin
                m_bvalid <= 1'b0;
                b_count <= b_count + 1;
            end

            if (s_awvalid[TENSOR_CLIENT] || s_wvalid[TENSOR_CLIENT] ||
                s_arvalid[TENSOR_CLIENT] || s_rvalid[TENSOR_CLIENT]) begin
                if (s_awvalid[TENSOR_CLIENT] && s_arvalid[TENSOR_CLIENT])
                    $fatal(1, "client-6 presented read/write address together");
            end
        end
    end

    task automatic stage_start;
        begin
            @(negedge clk);
            stage_start_valid = 1'b1;
            while (!stage_start_ready)
                @(posedge clk);
            @(negedge clk);
            stage_start_valid = 1'b0;
            while (!stage_start_done)
                @(posedge clk);
            if (!stage_cache_active || stage_cache_fallback ||
                stage_cache_reason != 4'd0)
                $fatal(1, "client-6 cache stage did not activate");
        end
    endtask

    task automatic read_req(
        input logic [31:0] addr,
        input integer x,
        input integer y,
        input logic cacheable,
        input logic [63:0] expected
    );
        begin
            @(negedge clk);
            s_req_write = 1'b0;
            s_req_addr = addr;
            s_req_wdata = 64'd0;
            s_req_wstrb = 8'd0;
            s_req_cacheable = cacheable;
            s_req_cache_x = x;
            s_req_cache_y = y;
            s_req_cache_group = 3'd0;
            s_req_valid = 1'b1;
            while (!s_req_ready)
                @(posedge clk);
            @(negedge clk);
            s_req_valid = 1'b0;
            while (!s_rsp_valid)
                @(posedge clk);
            if (s_rsp_error || s_rsp_rdata !== expected)
                $fatal(1, "client-6 read mismatch addr=%h got=%h exp=%h",
                       addr, s_rsp_rdata, expected);
            repeat (2) @(posedge clk);
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "client-6 response vanished at acceptance");
            @(negedge clk);
            s_rsp_ready = 1'b0;
        end
    endtask

    task automatic write_req(input logic [31:0] addr, input logic [63:0] data);
        begin
            @(negedge clk);
            s_req_write = 1'b1;
            s_req_addr = addr;
            s_req_wdata = data;
            s_req_wstrb = 8'hff;
            s_req_cacheable = 1'b0;
            s_req_cache_x = 17'sd0;
            s_req_cache_y = 17'sd0;
            s_req_cache_group = 3'd0;
            s_req_valid = 1'b1;
            while (!s_req_ready)
                @(posedge clk);
            @(negedge clk);
            s_req_valid = 1'b0;
            while (!s_rsp_valid)
                @(posedge clk);
            if (s_rsp_error)
                $fatal(1, "client-6 write returned error");
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "client-6 write response vanished at acceptance");
            @(negedge clk);
            s_rsp_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;
        stage_start();

        // First access misses and refills four 64-bit words.  The second
        // access is a same-row hit and must not reach AXI.
        read_req(BASE, 0, 0, 1'b1, word_value(BASE));
        read_req(BASE + 32'd8, 1, 0, 1'b1, word_value(BASE + 32'd8));
        read_req(BASE + 32'h100, 0, 0, 1'b0,
                 word_value(BASE + 32'h100));
        write_req(BASE + 32'h200, 64'h0123_4567_89ab_cdef);

        repeat (8) @(posedge clk);
        if (ar_count != ROW_WORDS + 1 || r_count != ar_count ||
            aw_count != 1 || w_count != 1 || b_count != 1)
            $fatal(1, "client-6 AXI counts mismatch ar/r=%0d/%0d aw/w/b=%0d/%0d/%0d",
                   ar_count, r_count, aw_count, w_count, b_count);
        if (!cache_quiescent || cache_busy || cache_error)
            $fatal(1, "client-6 cache did not return quiescent");
        $display("C1_TENSOR_CACHE_AXI_CLIENT6_PASS client=%0d refill_ar=%0d direct_ar=1 writes=%0d responses=%0d", TENSOR_CLIENT, ROW_WORDS, aw_count, r_count + b_count);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "tensor cache AXI client-6 timeout");
    end
endmodule
