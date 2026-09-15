`timescale 1ns/1ps

// Contract test for c1_tensor_mem_path_seam.
// Both generate branches are elaborated in one simulation: the legacy bridge
// must keep its one-request/one-response behaviour, while the performance
// branch must coalesce two adjacent half-beats and honor an explicit flush for
// a lone tail request.
module tb_c1_tensor_mem_path_seam;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    localparam logic [63:0] LEGACY_DATA = 64'h1111_2222_3333_4444;
    localparam logic [63:0] PERF_LOWER  = 64'haaaa_bbbb_cccc_dddd;
    localparam logic [63:0] PERF_UPPER  = 64'h1234_5678_9abc_def0;
    localparam logic [63:0] PERF_TAIL   = 64'h0bad_f00d_cafe_beef;

    // Each seam instance has an independent tiny AXI read BFM.
    logic l_req_valid, l_req_ready, l_req_flush, l_req_write;
    logic [31:0] l_req_addr;
    logic [63:0] l_req_wdata;
    logic [7:0] l_req_wstrb;
    logic l_rsp_valid, l_rsp_ready, l_rsp_error;
    logic [63:0] l_rsp_rdata;
    logic [31:0] l_awaddr, l_araddr;
    logic [7:0] l_awlen, l_arlen;
    logic [2:0] l_awsize, l_arsize;
    logic [1:0] l_awburst, l_arburst;
    logic l_awvalid, l_awready, l_wlast, l_wvalid, l_wready;
    logic [127:0] l_wdata;
    logic [15:0] l_wstrb;
    logic [1:0] l_bresp;
    logic l_bvalid, l_bready;
    logic l_arvalid, l_arready;
    logic [127:0] l_rdata;
    logic [1:0] l_rresp;
    logic l_rlast, l_rvalid, l_rready;
    logic l_busy;
    logic [63:0] l_req_count, l_beat_count, l_pair_count, l_rsp_count,
                 l_err_count;
    logic [3:0] l_qocc, l_qmax;
    logic l_flush_done, l_quiescent;

    logic p_req_valid, p_req_ready, p_req_flush, p_req_write;
    logic [31:0] p_req_addr;
    logic [63:0] p_req_wdata;
    logic [7:0] p_req_wstrb;
    logic p_rsp_valid, p_rsp_ready, p_rsp_error;
    logic [63:0] p_rsp_rdata;
    logic [31:0] p_awaddr, p_araddr;
    logic [7:0] p_awlen, p_arlen;
    logic [2:0] p_awsize, p_arsize;
    logic [1:0] p_awburst, p_arburst;
    logic p_awvalid, p_awready, p_wlast, p_wvalid, p_wready;
    logic [127:0] p_wdata;
    logic [15:0] p_wstrb;
    logic [1:0] p_bresp;
    logic p_bvalid, p_bready;
    logic p_arvalid, p_arready;
    logic [127:0] p_rdata;
    logic [1:0] p_rresp;
    logic p_rlast, p_rvalid, p_rready;
    logic p_busy;
    logic [63:0] p_req_count, p_beat_count, p_pair_count, p_rsp_count,
                 p_err_count;
    logic [3:0] p_qocc, p_qmax;
    logic p_flush_done, p_quiescent;

    c1_tensor_mem_path_seam #(.PERF_MODE(1'b0)) u_legacy (
        .clk(clk), .rst(rst),
        .req_valid(l_req_valid), .req_ready(l_req_ready),
        .flush_req(l_req_flush), .req_write(l_req_write),
        .req_addr(l_req_addr), .req_wdata(l_req_wdata),
        .req_wstrb(l_req_wstrb), .rsp_valid(l_rsp_valid),
        .rsp_ready(l_rsp_ready), .rsp_error(l_rsp_error),
        .rsp_rdata(l_rsp_rdata), .m_axi_awaddr(l_awaddr),
        .m_axi_awlen(l_awlen), .m_axi_awsize(l_awsize),
        .m_axi_awburst(l_awburst), .m_axi_awvalid(l_awvalid),
        .m_axi_awready(l_awready), .m_axi_wdata(l_wdata),
        .m_axi_wstrb(l_wstrb), .m_axi_wlast(l_wlast),
        .m_axi_wvalid(l_wvalid), .m_axi_wready(l_wready),
        .m_axi_bresp(l_bresp), .m_axi_bvalid(l_bvalid),
        .m_axi_bready(l_bready), .m_axi_araddr(l_araddr),
        .m_axi_arlen(l_arlen), .m_axi_arsize(l_arsize),
        .m_axi_arburst(l_arburst), .m_axi_arvalid(l_arvalid),
        .m_axi_arready(l_arready), .m_axi_rdata(l_rdata),
        .m_axi_rresp(l_rresp), .m_axi_rlast(l_rlast),
        .m_axi_rvalid(l_rvalid), .m_axi_rready(l_rready),
        .perf_busy(l_busy), .perf_req_accept_count(l_req_count),
        .perf_axi_beat_count(l_beat_count),
        .perf_packed_pair_count(l_pair_count), .perf_rsp_count(l_rsp_count),
        .perf_error_count(l_err_count), .perf_queue_occupancy(l_qocc),
        .perf_max_queue_occupancy(l_qmax), .flush_done(l_flush_done),
        .quiescent(l_quiescent)
    );

    c1_tensor_mem_path_seam #(.PERF_MODE(1'b1), .FIFO_DEPTH(8)) u_perf (
        .clk(clk), .rst(rst),
        .req_valid(p_req_valid), .req_ready(p_req_ready),
        .flush_req(p_req_flush), .req_write(p_req_write),
        .req_addr(p_req_addr), .req_wdata(p_req_wdata),
        .req_wstrb(p_req_wstrb), .rsp_valid(p_rsp_valid),
        .rsp_ready(p_rsp_ready), .rsp_error(p_rsp_error),
        .rsp_rdata(p_rsp_rdata), .m_axi_awaddr(p_awaddr),
        .m_axi_awlen(p_awlen), .m_axi_awsize(p_awsize),
        .m_axi_awburst(p_awburst), .m_axi_awvalid(p_awvalid),
        .m_axi_awready(p_awready), .m_axi_wdata(p_wdata),
        .m_axi_wstrb(p_wstrb), .m_axi_wlast(p_wlast),
        .m_axi_wvalid(p_wvalid), .m_axi_wready(p_wready),
        .m_axi_bresp(p_bresp), .m_axi_bvalid(p_bvalid),
        .m_axi_bready(p_bready), .m_axi_araddr(p_araddr),
        .m_axi_arlen(p_arlen), .m_axi_arsize(p_arsize),
        .m_axi_arburst(p_arburst), .m_axi_arvalid(p_arvalid),
        .m_axi_arready(p_arready), .m_axi_rdata(p_rdata),
        .m_axi_rresp(p_rresp), .m_axi_rlast(p_rlast),
        .m_axi_rvalid(p_rvalid), .m_axi_rready(p_rready),
        .perf_busy(p_busy), .perf_req_accept_count(p_req_count),
        .perf_axi_beat_count(p_beat_count),
        .perf_packed_pair_count(p_pair_count), .perf_rsp_count(p_rsp_count),
        .perf_error_count(p_err_count), .perf_queue_occupancy(p_qocc),
        .perf_max_queue_occupancy(p_qmax), .flush_done(p_flush_done),
        .quiescent(p_quiescent)
    );

    logic l_read_pending, l_read_valid;
    logic [31:0] l_read_base;
    logic p_read_pending, p_read_valid;
    logic [31:0] p_read_base;
    integer cycles;
    integer l_responses, p_responses;

    function automatic logic [127:0] read_word(input logic [31:0] base);
        case (base)
            32'h0000_1000: read_word = {64'd0, LEGACY_DATA};
            32'h0000_2000: read_word = {PERF_UPPER, PERF_LOWER};
            32'h0000_3000: read_word = {64'd0, PERF_TAIL};
            default:       read_word = 128'h0;
        endcase
    endfunction

    assign l_awready = 1'b1;
    assign l_wready = 1'b1;
    assign l_bvalid = 1'b0;
    assign l_bresp = 2'b00;
    assign l_arready = !l_read_pending && !l_read_valid;
    assign l_rvalid = l_read_valid;
    assign l_rdata = read_word(l_read_base);
    assign l_rresp = 2'b00;
    assign l_rlast = 1'b1;

    assign p_awready = 1'b1;
    assign p_wready = 1'b1;
    assign p_bvalid = 1'b0;
    assign p_bresp = 2'b00;
    assign p_arready = !p_read_pending && !p_read_valid;
    assign p_rvalid = p_read_valid;
    assign p_rdata = read_word(p_read_base);
    assign p_rresp = 2'b00;
    assign p_rlast = 1'b1;
    assign l_rsp_ready = 1'b1;
    assign p_rsp_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            l_read_pending <= 1'b0;
            l_read_valid <= 1'b0;
            l_read_base <= 0;
            p_read_pending <= 1'b0;
            p_read_valid <= 1'b0;
            p_read_base <= 0;
            l_responses <= 0;
            p_responses <= 0;
        end else begin
            cycles <= cycles + 1;
            if (l_arvalid && l_arready) begin
                if (l_arlen != 0 || l_arsize != 3'd4 ||
                    l_arburst != 2'b01 || l_araddr[3:0] != 0)
                    $fatal(1, "legacy AXI read control mismatch");
                l_read_pending <= 1'b1;
                l_read_base <= l_araddr;
            end
            if (l_read_pending) begin
                l_read_pending <= 1'b0;
                l_read_valid <= 1'b1;
            end
            if (l_rvalid && l_rready)
                l_read_valid <= 1'b0;

            if (p_arvalid && p_arready) begin
                if (p_arlen != 0 || p_arsize != 3'd4 ||
                    p_arburst != 2'b01 || p_araddr[3:0] != 0)
                    $fatal(1, "perf AXI read control mismatch");
                p_read_pending <= 1'b1;
                p_read_base <= p_araddr;
            end
            if (p_read_pending) begin
                p_read_pending <= 1'b0;
                p_read_valid <= 1'b1;
            end
            if (p_rvalid && p_rready)
                p_read_valid <= 1'b0;

            if (l_rsp_valid && l_rsp_ready) begin
                if (l_rsp_error || l_rsp_rdata !== LEGACY_DATA)
                    $fatal(1, "legacy seam response mismatch");
                l_responses <= l_responses + 1;
            end
            if (p_rsp_valid && p_rsp_ready) begin
                if (p_rsp_error)
                    $fatal(1, "perf seam unexpected response error");
                if (p_responses == 0 && p_rsp_rdata !== PERF_LOWER)
                    $fatal(1, "perf seam lower lane mismatch");
                if (p_responses == 1 && p_rsp_rdata !== PERF_UPPER)
                    $fatal(1, "perf seam upper lane mismatch");
                if (p_responses == 2 && p_rsp_rdata !== PERF_TAIL)
                    $fatal(1, "perf seam tail mismatch");
                p_responses <= p_responses + 1;
            end
        end
    end

    task automatic send_legacy_read(input logic [31:0] addr);
        begin
            @(negedge clk);
            l_req_addr <= addr;
            l_req_write <= 1'b0;
            l_req_wdata <= 0;
            l_req_wstrb <= 0;
            l_req_flush <= 1'b0;
            l_req_valid <= 1'b1;
            while (!l_req_ready) @(negedge clk);
            @(negedge clk);
            l_req_valid <= 1'b0;
        end
    endtask

    task automatic send_perf_read(input logic [31:0] addr, input logic flush);
        begin
            @(negedge clk);
            p_req_addr <= addr;
            p_req_write <= 1'b0;
            p_req_wdata <= 0;
            p_req_wstrb <= 0;
            p_req_flush <= flush;
            p_req_valid <= 1'b1;
            while (!p_req_ready) @(negedge clk);
            @(negedge clk);
            p_req_valid <= 1'b0;
            // Keep flush asserted until the tail response retires.  The pair
            // transaction may still be in flight when the tail is accepted;
            // a one-cycle pulse could disappear before the packer returns to
            // ST_IDLE and would leave the lone FIFO entry parked forever.
            if (flush) begin
                wait (p_flush_done);
                p_req_flush <= 1'b0;
            end
        end
    endtask

    initial begin
        l_req_valid = 0; l_req_flush = 0; l_req_write = 0;
        l_req_addr = 0; l_req_wdata = 0; l_req_wstrb = 0;
        p_req_valid = 0; p_req_flush = 0; p_req_write = 0;
        p_req_addr = 0; p_req_wdata = 0; p_req_wstrb = 0;
        repeat (4) @(negedge clk);
        rst <= 1'b0;

        send_legacy_read(32'h0000_1000);
        send_perf_read(32'h0000_2000, 1'b0);
        send_perf_read(32'h0000_2008, 1'b0);
        wait (p_pair_count == 1);
        send_perf_read(32'h0000_3000, 1'b1);

        repeat (20) @(negedge clk);
        if (l_responses != 1 || p_responses != 3)
            $fatal(1, "seam response count mismatch legacy=%0d perf=%0d",
                   l_responses, p_responses);
        if (p_req_count != 3 || p_beat_count != 2 || p_pair_count != 1 ||
            p_rsp_count != 3 || p_err_count != 0)
            $fatal(1, "seam performance counters mismatch req=%0d beats=%0d pairs=%0d rsp=%0d err=%0d",
                   p_req_count, p_beat_count, p_pair_count, p_rsp_count,
                   p_err_count);
        if (p_busy || l_busy || !p_quiescent || !l_quiescent)
            $fatal(1, "seam did not quiesce");
        $display("C1_TENSOR_MEM_PATH_SEAM_PASS legacy_responses=%0d perf_requests=%0d perf_beats=%0d packed_pairs=%0d perf_responses=%0d", 
                 l_responses, p_req_count, p_beat_count, p_pair_count,
                 p_rsp_count);
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "seam timeout");
    end
endmodule
