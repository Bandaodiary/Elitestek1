`timescale 1ns/1ps

// Self-checking boardless test for c1_tensor_mem_axi128_packer.
// It drives a mixed stream of adjacent reads/writes, mismatched requests and
// one misaligned request.  The AXI BFM deliberately inserts address/data and
// response gaps, while the local response monitor checks ordering and lane
// extraction.  The final marker reports the measured 64-bit-request to
// 128-bit-AXI-beat reduction.
module tb_c1_tensor_mem_axi128_packer;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic req_valid, req_ready, req_flush, req_write;
    logic [31:0] req_addr;
    logic [63:0] req_wdata;
    logic [7:0] req_wstrb;
    logic rsp_valid, rsp_ready, rsp_error;
    logic [63:0] rsp_rdata;

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

    logic perf_busy;
    logic [63:0] perf_req_accept_count;
    logic [63:0] perf_axi_beat_count;
    logic [63:0] perf_packed_pair_count;
    logic [63:0] perf_rsp_count;
    logic [63:0] perf_error_count;
    logic [3:0] perf_queue_occupancy;
    logic [3:0] perf_max_queue_occupancy;

    c1_tensor_mem_axi128_packer #(.FIFO_DEPTH(8), .PACK_ENABLE(1'b1)) dut (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready), .req_flush(req_flush),
        .req_write(req_write), .req_addr(req_addr), .req_wdata(req_wdata),
        .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_error(rsp_error), .rsp_rdata(rsp_rdata),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .perf_busy(perf_busy),
        .perf_req_accept_count(perf_req_accept_count),
        .perf_axi_beat_count(perf_axi_beat_count),
        .perf_packed_pair_count(perf_packed_pair_count),
        .perf_rsp_count(perf_rsp_count),
        .perf_error_count(perf_error_count),
        .perf_queue_occupancy(perf_queue_occupancy),
        .perf_max_queue_occupancy(perf_max_queue_occupancy)
    );

    integer cycle_count;
    integer ar_count, r_count, aw_count, w_count, b_count;
    integer response_stall_count;
    // Producer-side tail is updated only by the stimulus process; consumer
    // head is updated only by the response monitor.  Keeping the two cursors
    // separate avoids multiple procedural drivers during xelab elaboration.
    integer expected_head = 0, expected_tail = 0;
    logic expected_error [0:255];
    logic [63:0] expected_data [0:255];

    logic [127:0] write_expected_data [0:255];
    logic [15:0] write_expected_strb [0:255];
    logic write_expected_valid [0:255];

    logic read_pending_q, read_valid_q;
    logic [2:0] read_delay_q;
    logic [31:0] read_base_q;
    logic aw_seen_q, w_seen_q, b_pending_q, b_valid_q;
    logic [2:0] b_delay_q;
    logic [31:0] write_base_q;
    logic [127:0] write_data_q;
    logic [15:0] write_strb_q;
    logic [127:0] observed_write_data;
    logic [15:0] observed_write_strb;
    logic [31:0] observed_write_base;

    function automatic logic [127:0] model_read_data(
        input logic [31:0] base
    );
        begin
            model_read_data = {
                32'hca11_0000 ^ base,
                32'hca11_1000 + base,
                32'hbeef_2000 ^ (base << 1),
                32'hbeef_3000 + (base >> 1)
            };
        end
    endfunction

    function automatic integer model_index(input logic [31:0] base);
        begin
            model_index = (base[11:4] & 8'hff);
        end
    endfunction

    assign m_axi_arready = !read_pending_q && !read_valid_q &&
                           ((cycle_count % 5) != 1);
    assign m_axi_rvalid = read_valid_q;
    assign m_axi_rdata = model_read_data(read_base_q);
    assign m_axi_rresp = 2'b00;
    assign m_axi_rlast = 1'b1;

    assign m_axi_awready = !aw_seen_q && !b_pending_q &&
                           ((cycle_count % 4) != 2);
    assign m_axi_wready = !w_seen_q && !b_pending_q &&
                          ((cycle_count % 6) != 3);
    assign m_axi_bvalid = b_valid_q;
    assign m_axi_bresp = 2'b00;

    wire ar_fire = m_axi_arvalid && m_axi_arready;
    wire r_fire = m_axi_rvalid && m_axi_rready;
    wire aw_fire = m_axi_awvalid && m_axi_awready;
    wire w_fire = m_axi_wvalid && m_axi_wready;
    wire b_fire = m_axi_bvalid && m_axi_bready;
    wire local_req_fire = req_valid && req_ready;
    wire local_rsp_fire = rsp_valid && rsp_ready;

    always_comb begin
        // Periodic local response stalls prove that a packed response remains
        // stable while the consumer is backpressured.
        rsp_ready = ((cycle_count % 7) != 4);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            ar_count <= 0;
            r_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            response_stall_count <= 0;
            read_pending_q <= 1'b0;
            read_valid_q <= 1'b0;
            read_delay_q <= 0;
            read_base_q <= 0;
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            b_pending_q <= 1'b0;
            b_valid_q <= 1'b0;
            b_delay_q <= 0;
            write_base_q <= 0;
            write_data_q <= 0;
            write_strb_q <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (rsp_valid && !rsp_ready)
                response_stall_count <= response_stall_count + 1;

            if (ar_fire) begin
                if (m_axi_arlen != 0 || m_axi_arsize != 3'd4 ||
                    m_axi_arburst != 2'b01 || m_axi_araddr[3:0] != 0)
                    $fatal(1, "packed read AXI control mismatch");
                ar_count <= ar_count + 1;
                read_pending_q <= 1'b1;
                read_base_q <= m_axi_araddr;
                read_delay_q <= 3'd2;
            end
            if (read_pending_q && !read_valid_q) begin
                if (read_delay_q == 0)
                    read_valid_q <= 1'b1;
                else
                    read_delay_q <= read_delay_q - 1'b1;
            end
            if (r_fire) begin
                r_count <= r_count + 1;
                read_pending_q <= 1'b0;
                read_valid_q <= 1'b0;
            end

            if (aw_fire) begin
                if (m_axi_awlen != 0 || m_axi_awsize != 3'd4 ||
                    m_axi_awburst != 2'b01 || m_axi_awaddr[3:0] != 0)
                    $fatal(1, "packed write AW control mismatch");
                aw_count <= aw_count + 1;
                aw_seen_q <= 1'b1;
                write_base_q <= m_axi_awaddr;
            end
            if (w_fire) begin
                if (!m_axi_wlast)
                    $fatal(1, "packed write missing WLAST");
                w_count <= w_count + 1;
                w_seen_q <= 1'b1;
                write_data_q <= m_axi_wdata;
                write_strb_q <= m_axi_wstrb;
            end
            if (!b_pending_q &&
                (aw_seen_q || aw_fire) && (w_seen_q || w_fire)) begin
                // Check the packed write against the two local requests that
                // the producer registered before issuing the AXI transaction.
                observed_write_base = aw_seen_q ? write_base_q : m_axi_awaddr;
                observed_write_data = w_fire ? m_axi_wdata : write_data_q;
                observed_write_strb = w_fire ? m_axi_wstrb : write_strb_q;
                if (write_expected_valid[model_index(observed_write_base)]) begin
                    if ((observed_write_data !== write_expected_data[
                            model_index(observed_write_base)]) ||
                        (observed_write_strb !== write_expected_strb[
                            model_index(observed_write_base)]))
                        $fatal(1, "packed write lane/strobe mismatch");
                    write_expected_valid[model_index(observed_write_base)] <= 1'b0;
                end
                b_pending_q <= 1'b1;
                b_delay_q <= 3'd1;
            end
            if (b_pending_q && !b_valid_q) begin
                if (b_delay_q == 0)
                    b_valid_q <= 1'b1;
                else
                    b_delay_q <= b_delay_q - 1'b1;
            end
            if (b_fire) begin
                b_count <= b_count + 1;
                b_valid_q <= 1'b0;
                b_pending_q <= 1'b0;
                aw_seen_q <= 1'b0;
                w_seen_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            expected_head <= 0;
        end else if (local_rsp_fire) begin
            if (expected_head == expected_tail)
                $fatal(1, "spurious packed local response");
            if (rsp_error !== expected_error[expected_head] ||
                rsp_rdata !== expected_data[expected_head])
                $fatal(1, "packed response mismatch got err/data=%0d/%h exp=%0d/%h",
                       rsp_error, rsp_rdata, expected_error[expected_head],
                       expected_data[expected_head]);
            expected_head <= (expected_head == 255) ? 0 : expected_head + 1;
        end
    end

    task automatic send_request(
        input logic request_write,
        input logic [31:0] request_addr,
        input logic [63:0] request_data,
        input logic [7:0] request_strb
    );
        integer idx;
        logic [31:0] base;
        logic [127:0] model_word;
        begin
            @(negedge clk);
            req_write = request_write;
            req_addr = request_addr;
            req_wdata = request_data;
            req_wstrb = request_strb;
            req_valid = 1'b1;
            do @(posedge clk); while (!req_ready);
            @(negedge clk);
            req_valid = 1'b0;

            expected_error[expected_tail] = (request_addr[2:0] != 0);
            if (!request_write && !expected_error[expected_tail]) begin
                base = {request_addr[31:4], 4'b0};
                model_word = model_read_data(base);
                expected_data[expected_tail] = request_addr[3] ?
                    model_word[127:64] : model_word[63:0];
            end else begin
                expected_data[expected_tail] = 64'd0;
            end
            expected_tail = (expected_tail == 255) ? 0 : expected_tail + 1;

            if (request_write && !request_addr[2:0]) begin
                idx = model_index({request_addr[31:4],4'b0});
                if (!write_expected_valid[idx]) begin
                    write_expected_data[idx] = 128'd0;
                    write_expected_strb[idx] = 16'd0;
                end
                if (request_addr[3]) begin
                    write_expected_data[idx][127:64] = request_data;
                    write_expected_strb[idx][15:8] = request_strb;
                end else begin
                    write_expected_data[idx][63:0] = request_data;
                    write_expected_strb[idx][7:0] = request_strb;
                end
                write_expected_valid[idx] = 1'b1;
            end
        end
    endtask

    integer i;
    integer idx_init;
    initial begin
        req_valid = 1'b0;
        req_flush = 1'b0;
        req_write = 1'b0;
        req_addr = 0;
        req_wdata = 0;
        req_wstrb = 0;
        expected_tail = 0;
        for (i = 0; i < 256; i = i + 1) begin
            expected_error[i] = 1'b0;
            expected_data[i] = 64'd0;
            write_expected_data[i] = 128'd0;
            write_expected_strb[i] = 16'd0;
            write_expected_valid[i] = 1'b0;
        end

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Thirty-two adjacent read pairs.  The FIFO sees both halves before
        // scheduling and should issue exactly one AXI read per pair.
        for (i = 0; i < 32; i = i + 1) begin
            send_request(1'b0, 32'h0000_1000 + (i * 32'h20), 0, 0);
            send_request(1'b0, 32'h0000_1008 + (i * 32'h20), 0, 0);
        end

        // Sixteen adjacent write pairs with distinct lane data/strobes.
        for (i = 0; i < 16; i = i + 1) begin
            send_request(1'b1, 32'h0000_2000 + (i * 32'h20),
                         64'h1111_0000_0000_0000 + i, 8'h3c ^ i);
            send_request(1'b1, 32'h0000_2008 + (i * 32'h20),
                         64'h2222_0000_0000_0000 + i, 8'ha5 ^ i);
        end

        // A mismatched pair must not be merged; the FIFO should issue the
        // first request and then retain the second until its partner arrives.
        send_request(1'b0, 32'h0000_3000, 0, 0);
        send_request(1'b0, 32'h0000_3010, 0, 0);
        // One local misalignment error and one final unpaired request require
        // the explicit flush pulse.
        send_request(1'b0, 32'h0000_4004, 0, 0);
        send_request(1'b0, 32'h0000_5000, 0, 0);
        @(negedge clk);
        // Keep flush asserted until both the misaligned head and the final
        // unpaired aligned request have been retired.  A single pulse only
        // guarantees one local FIFO head is issued.
        req_flush = 1'b1;
        repeat (80) @(posedge clk);
        @(negedge clk);
        req_flush = 1'b0;

        wait ((expected_head == expected_tail) && !perf_busy);
        if (perf_req_accept_count != 100)
            $fatal(1, "request count mismatch %0d", perf_req_accept_count);
        if (perf_rsp_count != 100 || expected_head != expected_tail)
            $fatal(1, "response accounting mismatch req/rsp/pending=%0d/%0d/%0d",
                   perf_req_accept_count, perf_rsp_count,
                   expected_tail - expected_head);
        if (perf_packed_pair_count < 48)
            $fatal(1, "insufficient pair packing: %0d",
                   perf_packed_pair_count);
        if (perf_axi_beat_count >= perf_req_accept_count)
            $fatal(1, "no AXI beat reduction req/beat=%0d/%0d",
                   perf_req_accept_count, perf_axi_beat_count);
        if (perf_axi_beat_count + perf_packed_pair_count + perf_error_count !=
            perf_req_accept_count)
            $fatal(1, "request/beat/pair/error conservation mismatch");
        if (ar_count != r_count || aw_count != w_count || aw_count != b_count)
            $fatal(1, "AXI accounting mismatch ar/r/aw/w/b=%0d/%0d/%0d/%0d/%0d",
                   ar_count, r_count, aw_count, w_count, b_count);
        if (response_stall_count == 0 || perf_max_queue_occupancy < 2)
            $fatal(1, "backpressure/queue coverage missing");

        $display("C1_TENSOR_MEM_AXI128_PACKER_PASS requests=%0d axi_beats=%0d packed_pairs=%0d responses=%0d local_or_axi_errors=%0d ar=%0d aw=%0d rsp_stalls=%0d maxq=%0d reduction_pct=%0f",
                 perf_req_accept_count, perf_axi_beat_count,
                 perf_packed_pair_count, perf_rsp_count, perf_error_count,
                 ar_count, aw_count, response_stall_count,
                 perf_max_queue_occupancy,
                 100.0 * (perf_req_accept_count - perf_axi_beat_count) /
                 perf_req_accept_count);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "global tensor AXI128 packer timeout");
    end
endmodule
