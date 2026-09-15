`timescale 1ns/1ps

// Ordered tensor seam: optional packed writes, unchanged single-beat reads.
// No posted acknowledgements or cancellation. Every accepted write receives
// a response only after its real B (or local alignment rejection). Reads may
// start only after every preceding write response has been consumed.
module c1_tensor_mem_axi128_packing_bridge #(
    parameter integer ENABLE_PACKED_WRITES = 0,
    parameter integer USE_WRITE_END = 0,
    parameter bit ENABLE_READ_BEAT_CACHE = 1'b0,
    parameter integer READ_BEAT_CACHE_ENTRIES = 1,
    parameter bit PRECISE_WRITE_INVALIDATION = 1'b0,
    parameter integer WRITE_OUTSTANDING = 1,
    parameter integer WRITE_BUILD_TIMEOUT = 8
) (
    input logic clk, rst,
    input logic mem_req_valid,
    output logic mem_req_ready,
    input logic mem_req_write,
    input logic [31:0] mem_req_addr,
    input logic [63:0] mem_req_wdata,
    input logic [7:0] mem_req_wstrb,
    output logic mem_rsp_valid,
    input logic mem_rsp_ready,
    output logic mem_rsp_error,
    output logic [63:0] mem_rsp_rdata,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0] m_axi_wstrb,
    output logic m_axi_wlast, m_axi_wvalid,
    input logic m_axi_wready,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready,
    output logic [31:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input logic m_axi_arready,
    input logic [127:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast, m_axi_rvalid,
    output logic m_axi_rready,
    input logic mem_req_end,
    input logic read_cache_invalidate
);
    initial begin
        if(WRITE_OUTSTANDING!=1 && WRITE_OUTSTANDING!=2 && WRITE_OUTSTANDING!=4)
            $fatal(1,"packing write outstanding must be 1, 2 or 4");
        if(WRITE_OUTSTANDING!=1 && !ENABLE_PACKED_WRITES)
            $fatal(1,"multiple tensor writes require packing");
        if(WRITE_BUILD_TIMEOUT<1 || WRITE_BUILD_TIMEOUT>255)
            $fatal(1,"packing write build timeout must be 1..255");
        if(WRITE_BUILD_TIMEOUT!=8 && !ENABLE_PACKED_WRITES)
            $fatal(1,"nondefault write build timeout requires packing");
    end
    generate if (ENABLE_PACKED_WRITES == 0) begin : g_legacy
        c1_tensor_mem_axi128_bridge #(
            .READ_BEAT_CACHE_ENTRIES(READ_BEAT_CACHE_ENTRIES),
            .ENABLE_READ_BEAT_CACHE(ENABLE_READ_BEAT_CACHE),
            .PRECISE_WRITE_INVALIDATION(PRECISE_WRITE_INVALIDATION)
        ) u_bridge (.read_cache_addr_match(), .*);
    end else begin : g_packed
        logic read_owned;
        logic [5:0] writes_pending;
        wire rd_req_ready, rd_rsp_valid, rd_rsp_error;
        wire [63:0] rd_rsp_data;
        wire rd_cache_addr_match;
        wire wr_req_ready, wr_rsp_valid, wr_rsp_error, wr_busy;
        wire read_admit = !rst && !read_owned && writes_pending == 0 && !wr_busy;
        wire write_admit = !rst && !read_owned;
        wire write_fire = mem_req_valid && mem_req_ready && mem_req_write;
        // No write can be accepted while a read is owned (including its
        // held response). Therefore this snoop cannot race a pending fill.
        // It uses the raw tag query, never the invalidate-qualified read hit.
        wire write_cache_invalidate = write_fire &&
            (!PRECISE_WRITE_INVALIDATION || mem_req_addr[2:0] != 0 || rd_cache_addr_match);
        wire write_bus_error = m_axi_bvalid && m_axi_bready && (m_axi_bresp != 2'b00);
        wire write_retire = !read_owned && writes_pending != 0 &&
                            wr_rsp_valid && mem_rsp_ready && !rst;
        assign mem_req_ready = mem_req_write ? (write_admit && wr_req_ready) :
                                               (read_admit && rd_req_ready);
        assign mem_rsp_valid = !rst && (read_owned ? rd_rsp_valid :
                                         (writes_pending != 0 && wr_rsp_valid));
        assign mem_rsp_error = read_owned ? rd_rsp_error : wr_rsp_error;
        // Match the legacy bridge: write acknowledgements carry zero data.
        assign mem_rsp_rdata = read_owned ? rd_rsp_data : 64'd0;
        always_ff @(posedge clk) begin
            if (rst) begin
                read_owned <= 0;
                writes_pending <= 0;
            end else begin
                if (mem_req_valid && mem_req_ready && !mem_req_write) read_owned <= 1;
                if (read_owned && rd_rsp_valid && mem_rsp_ready) read_owned <= 0;
                case ({write_fire,write_retire})
                    2'b10: writes_pending <= writes_pending + 1'b1;
                    2'b01: writes_pending <= writes_pending - 1'b1;
                    default: ;
                endcase
            end
        end
        c1_tensor_mem_axi128_bridge #(
            .READ_BEAT_CACHE_ENTRIES(READ_BEAT_CACHE_ENTRIES),
            .ENABLE_READ_BEAT_CACHE(ENABLE_READ_BEAT_CACHE),
            .PRECISE_WRITE_INVALIDATION(PRECISE_WRITE_INVALIDATION)
        ) u_read (
            .clk(clk), .rst(rst),
            .read_cache_invalidate(read_cache_invalidate || write_cache_invalidate || write_bus_error),
            .read_cache_addr_match(rd_cache_addr_match),
            .mem_req_valid(mem_req_valid && !mem_req_write && read_admit),
            .mem_req_ready(rd_req_ready), .mem_req_write(1'b0),
            .mem_req_addr(mem_req_addr), .mem_req_wdata(64'd0), .mem_req_wstrb(8'd0),
            .mem_rsp_valid(rd_rsp_valid), .mem_rsp_ready(read_owned && mem_rsp_ready),
            .mem_rsp_error(rd_rsp_error), .mem_rsp_rdata(rd_rsp_data),
            .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(),
            .m_axi_awvalid(), .m_axi_awready(1'b0),
            .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wlast(), .m_axi_wvalid(),
            .m_axi_wready(1'b0), .m_axi_bresp(2'd0), .m_axi_bvalid(1'b0), .m_axi_bready(),
            .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
            .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
            .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
            .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
            .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
        );
        if(WRITE_OUTSTANDING>1) begin : g_mlp
            c1_tensor_mem_axi128_ordered_write_client #(
                .MAX_OUTSTANDING(WRITE_OUTSTANDING),.BURST_BEATS(4),
                .BUILD_TIMEOUT_CYCLES(WRITE_BUILD_TIMEOUT),.USE_REQUEST_END(USE_WRITE_END)
            ) u_write (
                .clk,.rst,.req_valid(mem_req_valid && mem_req_write && write_admit),
                .req_ready(wr_req_ready),.req_flush(1'b0),.req_end(mem_req_end),
                .req_addr(mem_req_addr),.req_wdata(mem_req_wdata),.req_wstrb(mem_req_wstrb),
                .rsp_valid(wr_rsp_valid),.rsp_ready(!read_owned && writes_pending!=0 && mem_rsp_ready && !rst),
                .rsp_error(wr_rsp_error),.rsp_rdata(),
                .m_axi_awaddr,.m_axi_awlen,.m_axi_awsize,.m_axi_awburst,.m_axi_awvalid,.m_axi_awready,
                .m_axi_wdata,.m_axi_wstrb,.m_axi_wlast,.m_axi_wvalid,.m_axi_wready,
                .m_axi_bresp,.m_axi_bvalid,.m_axi_bready,.perf_busy(wr_busy),
                .perf_outstanding(),.perf_max_outstanding()
            );
        end else begin : g_serial
        c1_tensor_mem_axi128_write_burst_client #(
            .REQ_FIFO_DEPTH(8), .BURST_BEATS(4), .RSP_FIFO_DEPTH(8),
            .BUILD_TIMEOUT_CYCLES(WRITE_BUILD_TIMEOUT), .USE_REQUEST_END(USE_WRITE_END)
        ) u_write (
            .clk(clk), .rst(rst),
            .req_valid(mem_req_valid && mem_req_write && write_admit),
            .req_ready(wr_req_ready), .req_flush(1'b0),
            .req_end(mem_req_end),
            .req_addr(mem_req_addr), .req_wdata(mem_req_wdata), .req_wstrb(mem_req_wstrb),
            .rsp_valid(wr_rsp_valid), .rsp_ready(!read_owned && writes_pending != 0 && mem_rsp_ready && !rst),
            .rsp_error(wr_rsp_error), .rsp_rdata(),
            .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
            .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
            .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
            .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
            .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
            .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
            .perf_busy(wr_busy), .perf_req_accept_count(), .perf_axi_burst_count(),
            .perf_axi_beat_count(), .perf_rsp_count(), .perf_packed_request_count(),
            .perf_error_count(), .perf_req_occupancy(), .perf_max_req_occupancy()
        );
        end
`ifndef SYNTHESIS
        always @(posedge clk) if (!rst) begin
            if(write_fire && read_owned)
                $fatal(1,"packed write snoop overlapped an owned read");
            if (writes_pending > (WRITE_OUTSTANDING==1 ? 24 : WRITE_OUTSTANDING*8) ||
                (read_owned && writes_pending != 0))
                $fatal(1,"packing bridge ownership/count invariant");
        end
`endif
    end endgenerate
endmodule
