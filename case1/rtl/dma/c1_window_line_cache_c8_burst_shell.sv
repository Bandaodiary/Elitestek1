`timescale 1ns/1ps

// Boardless cache-refill burst shell.
//
// The existing line cache deliberately exposes a simple 64-bit refill stream.
// This shell keeps that logical contract intact, but replaces the external
// one-word-at-a-time source with c1_tensor_mem_axi128_read_burst_client:
// complete rows are queued as contiguous addresses, packed two C8 words per
// AXI128 beat, split at 4-KiB boundaries, and several read bursts may be in
// flight.  The cache still commits a row only after all declared words arrive,
// so tap ordering and SAME/replicate semantics are unchanged.
//
// This is intentionally a separate integration seam.  It is read-only and
// intended for 3x3 window-cache refills; ordinary tensor writes/bypass traffic
// remains on the legacy c1_tensor_mem_axi128_bridge until an AXI mux with
// abort/epoch handling is selected for the final SoC build.
module c1_window_line_cache_c8_burst_shell #(
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    parameter integer REQ_FIFO_DEPTH = 32,
    parameter integer BURST_BEATS = 16,
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer RSP_FIFO_DEPTH = 2 * BURST_BEATS * MAX_OUTSTANDING,
    parameter integer BUILD_TIMEOUT_CYCLES = 4,
    parameter bit ALLOW_SAME_LANE_DUP = 1'b1,
    // Forward the optional beat-record response FIFO to the burst reader.
    // Keep the default logical-entry layout for compatibility with the
    // existing cache/client contract.
    parameter bit RSP_FIFO_BEAT_MODE = 1'b0,
    // The shell knows exactly when the final word of a row has entered the
    // reader.  Fast-tail mode asks the reader to close the descriptor as soon
    // as its logical request FIFO drains, instead of waiting the generic
    // BUILD_TIMEOUT_CYCLES.  The request is held off until the FIFO is empty,
    // so a final opposite 64-bit lane can still be packed.  Zero preserves
    // the compatibility/default behavior.  Appended at the end to keep
    // positional parameter instantiations source-compatible.
    parameter bit REFILL_TAIL_FLUSH = 1'b0,
    // Optional reader FIFO pop/refill bypass.  It removes a conservative
    // R-channel bubble at a full response FIFO, but creates an rsp_ready to
    // AXI RREADY timing path, so the boardless/default configuration is off.
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    // Optional reader request FIFO pop/refill bypass.  It removes a producer
    // bubble only when the logical request FIFO is full and the burst builder
    // consumes its head in the same cycle.  Keep disabled by default because
    // the builder's adjacency path is then present on client req_ready.
    // Appended at the end to preserve positional parameter compatibility.
    parameter bit ALLOW_REQ_POP_REFILL = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         stage_base_valid,
    input  logic [31:0]                  stage_base_addr,

    input  logic                         group_start_valid,
    output logic                         group_start_ready,
    input  logic [15:0]                  frame_width,
    input  logic [15:0]                  frame_height,
    input  logic [3:0]                   frame_groups,
    output logic                         group_start_done,
    output logic                         group_start_error,
    output logic [2:0]                   group_start_error_code,
    output logic                         config_valid,

    input  logic                         abort_req,
    output logic                         abort_done,
    input  logic                         flush_req,
    output logic                         flush_done,

    input  logic                         tap_valid,
    output logic                         tap_ready,
    input  logic signed [16:0]           tap_x,
    input  logic signed [16:0]           tap_y,
    input  logic [2:0]                   tap_group,
    output logic                         tap_rsp_valid,
    input  logic                         tap_rsp_ready,
    output logic [DATA_W-1:0]            tap_rsp_data_s8,
    output logic                         tap_rsp_error,

    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,

    output logic                         cache_error,
    output logic [2:0]                   cache_error_code,
    output logic                         busy,
    output logic                         quiescent,
    output logic [63:0]                  perf_refill_count,
    output logic [63:0]                  perf_refill_word_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_cache_rsp_count,
    output logic [7:0]                   perf_max_outstanding
);

    initial begin
        if (DATA_W != 64)
            $fatal(1, "burst shell currently requires DATA_W=64");
        if (MAX_ROW_WORDS < 1)
            $fatal(1, "MAX_ROW_WORDS must be positive");
    end

    logic [31:0] stage_base_q;
    logic [15:0] row_words_q;
    logic [31:0] row_stride_bytes_q;
    logic [31:0] refill_base_q;
    logic [15:0] refill_words_q;
    logic [15:0] feed_index_q;
    logic [15:0] rsp_index_q;
    logic refill_active_q;
    logic flush_pending_q;
    logic refill_last_fire;
    logic stage_base_fire;
    logic refill_start_fire;
    logic req_fire;
    logic rsp_fire;

    logic cache_refill_req_valid;
    logic cache_refill_req_ready;
    logic [15:0] cache_refill_req_row;
    logic [15:0] cache_refill_req_word_count;
    logic cache_refill_word_valid;
    logic cache_refill_word_ready;
    logic [63:0] cache_refill_word_data;
    logic cache_refill_word_last;

    logic client_req_valid, client_req_ready, client_req_flush;
    logic [31:0] client_req_addr;
    logic client_rsp_valid, client_rsp_ready, client_rsp_error;
    logic [63:0] client_rsp_rdata;
    logic client_busy;
    logic [63:0] client_req_count;
    logic [63:0] client_burst_count;
    logic [63:0] client_beat_count;
    logic [63:0] client_rsp_count;
    logic [63:0] client_packed_count;
    logic [63:0] client_error_count;
    logic [7:0] client_req_occ, client_max_req_occ;
    logic [7:0] client_outstanding, client_max_outstanding;

    // Keep the shell's row geometry in the same narrow shift/add domain as
    // the payload cache.  A bare `frame_width * frame_groups` expression is
    // context-sized by some SV front ends (and the following <<3 can then
    // truncate at 16 bits for wider legal geometries).  The explicit 20-bit
    // shift/add product is both width-safe and avoids introducing a DSP into
    // the cache address/control path.
    logic [19:0] row_words_full_comb;
    function automatic logic [19:0] shell_width_times_groups(
        input logic [15:0] width_value,
        input logic [3:0] group_value
    );
        logic [19:0] product;
        begin
            product = 20'd0;
            if (group_value[0])
                product = product + {4'd0, width_value};
            if (group_value[1])
                product = product + ({4'd0, width_value} << 1);
            if (group_value[2])
                product = product + ({4'd0, width_value} << 2);
            if (group_value[3])
                product = product + ({4'd0, width_value} << 3);
            shell_width_times_groups = product;
        end
    endfunction

    always_comb begin
        row_words_full_comb = shell_width_times_groups(frame_width, frame_groups);
    end

    // Multiplication by the row number is implemented as a bounded shift/add
    // tree.  This keeps the shell's address-generation proxy DSP-free.
    function automatic logic [31:0] row_offset_bytes(
        input logic [15:0] row,
        input logic [31:0] stride
    );
        logic [31:0] acc;
        integer k;
        begin
            acc = 32'd0;
            for (k = 0; k < 16; k = k + 1)
                if (row[k])
                    acc = acc + (stride << k);
            row_offset_bytes = acc;
        end
    endfunction

    // The line cache's own geometry checker remains authoritative.  The base
    // address is snapped at the same stage-start handshake used by the cache.
    assign stage_base_fire = stage_base_valid && group_start_valid &&
                             group_start_ready;
    assign refill_start_fire = cache_refill_req_valid &&
                               cache_refill_req_ready;
    assign req_fire = client_req_valid && client_req_ready;
    assign rsp_fire = client_rsp_valid && client_rsp_ready;
    assign refill_last_fire = rsp_fire &&
                              (rsp_index_q == refill_words_q - 1'b1);

    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(LINE_ROWS),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(MAX_GROUPS)
    ) u_cache (
        .clk(clk), .rst(rst),
        .group_start_valid(group_start_valid),
        .group_start_ready(group_start_ready),
        .frame_width(frame_width), .frame_height(frame_height),
        .frame_groups(frame_groups),
        .group_start_done(group_start_done),
        .group_start_error(group_start_error),
        .group_start_error_code(group_start_error_code),
        .config_valid(config_valid),
        .abort_req(abort_req), .abort_done(abort_done),
        .flush_req(flush_req), .flush_done(flush_done),
        .tap_valid(tap_valid), .tap_ready(tap_ready),
        .tap_x(tap_x), .tap_y(tap_y), .tap_group(tap_group),
        .tap_rsp_valid(tap_rsp_valid), .tap_rsp_ready(tap_rsp_ready),
        .tap_rsp_data_s8(tap_rsp_data_s8), .tap_rsp_error(tap_rsp_error),
        .refill_req_valid(cache_refill_req_valid),
        .refill_req_ready(cache_refill_req_ready),
        .refill_req_row(cache_refill_req_row),
        .refill_req_word_count(cache_refill_req_word_count),
        .refill_word_valid(cache_refill_word_valid),
        .refill_word_ready(cache_refill_word_ready),
        .refill_word_data_s8(cache_refill_word_data),
        .refill_word_last(cache_refill_word_last),
        .refill_word_error(client_rsp_error),
        .cache_error(cache_error), .cache_error_code(cache_error_code),
        .busy(), .quiescent()
    );

    c1_tensor_mem_axi128_read_burst_client #(
        .REQ_FIFO_DEPTH(REQ_FIFO_DEPTH),
        .BURST_BEATS(BURST_BEATS),
        .MAX_OUTSTANDING(MAX_OUTSTANDING),
        .RSP_FIFO_DEPTH(RSP_FIFO_DEPTH),
        .BUILD_TIMEOUT_CYCLES(BUILD_TIMEOUT_CYCLES),
        .ALLOW_SAME_LANE_DUP(ALLOW_SAME_LANE_DUP),
        .RSP_FIFO_BEAT_MODE(RSP_FIFO_BEAT_MODE),
        .ALLOW_RSP_POP_REFILL(ALLOW_RSP_POP_REFILL),
        .ALLOW_REQ_POP_REFILL(ALLOW_REQ_POP_REFILL)
    ) u_reader (
        .clk(clk), .rst(rst),
        .req_valid(client_req_valid), .req_ready(client_req_ready),
        .req_flush(client_req_flush), .req_addr(client_req_addr),
        .rsp_valid(client_rsp_valid), .rsp_ready(client_rsp_ready),
        .rsp_error(client_rsp_error), .rsp_rdata(client_rsp_rdata),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .perf_busy(client_busy),
        .perf_req_accept_count(client_req_count),
        .perf_axi_burst_count(client_burst_count),
        .perf_axi_beat_count(client_beat_count),
        .perf_rsp_count(client_rsp_count),
        .perf_packed_request_count(client_packed_count),
        .perf_error_count(client_error_count),
        .perf_req_occupancy(client_req_occ),
        .perf_max_req_occupancy(client_max_req_occ),
        .perf_outstanding(client_outstanding),
        .perf_max_outstanding(client_max_outstanding)
    );

    // A refill is accepted only when the reader has no older descriptors.
    // Once accepted, addresses are streamed into the request FIFO.  Optional
    // tail flushing is generated only after the final request has drained
    // from that FIFO, preserving a possible opposite-lane pack2 append.
    assign cache_refill_req_ready = !refill_active_q && !client_busy;
    assign client_req_valid = refill_active_q &&
                              (feed_index_q < refill_words_q);
    assign client_req_addr = refill_base_q + {14'd0, feed_index_q, 3'b000};
    // The reader has a bounded BUILD_TIMEOUT_CYCLES close policy.  Do not
    // assert req_flush in the same cycle as the final word: doing so would
    // deliberately suppress a possible opposite-lane append still sitting in
    // the reader FIFO.  In fast-tail mode, remember that the row is complete
    // and pulse req_flush only after the FIFO reports empty.  This removes
    // the generic timeout from known row tails without changing the reader's
    // ready/valid or AXI ordering contract.
    assign client_req_flush = (REFILL_TAIL_FLUSH != 0) &&
                              flush_pending_q &&
                              (client_req_occ == 0);
    assign client_rsp_ready = refill_active_q && cache_refill_word_ready;
    assign cache_refill_word_valid = refill_active_q && client_rsp_valid;
    assign cache_refill_word_data = client_rsp_rdata;
    assign cache_refill_word_last = refill_active_q &&
                                    (rsp_index_q == refill_words_q - 1'b1);

    assign busy = client_busy || refill_active_q;
    assign quiescent = !busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            stage_base_q <= 32'd0;
            row_words_q <= 16'd0;
            row_stride_bytes_q <= 32'd0;
            refill_base_q <= 32'd0;
            refill_words_q <= 16'd0;
            feed_index_q <= 16'd0;
            rsp_index_q <= 16'd0;
            refill_active_q <= 1'b0;
            flush_pending_q <= 1'b0;
            perf_refill_count <= 64'd0;
            perf_refill_word_count <= 64'd0;
            perf_axi_burst_count <= 64'd0;
            perf_axi_beat_count <= 64'd0;
            perf_cache_rsp_count <= 64'd0;
            perf_max_outstanding <= 8'd0;
        end else begin
            if (stage_base_fire) begin
                stage_base_q <= stage_base_addr;
                row_words_q <= row_words_full_comb[15:0];
                row_stride_bytes_q <= {12'd0, row_words_full_comb} << 3;
            end

            if (refill_start_fire) begin
                refill_active_q <= 1'b1;
                refill_words_q <= cache_refill_req_word_count;
                feed_index_q <= 16'd0;
                rsp_index_q <= 16'd0;
                flush_pending_q <= 1'b0;
                refill_base_q <= stage_base_q +
                    row_offset_bytes(cache_refill_req_row,
                                     row_stride_bytes_q);
                perf_refill_count <= perf_refill_count + 1'b1;
            end

            if (req_fire) begin
                feed_index_q <= feed_index_q + 1'b1;
                if (feed_index_q == refill_words_q - 1'b1)
                    flush_pending_q <= (REFILL_TAIL_FLUSH != 0);
            end

            // req_flush is a one-cycle pulse once the final request has
            // drained.  The reader samples it on this edge and publishes the
            // short/partial descriptor immediately.
            if (client_req_flush)
                flush_pending_q <= 1'b0;

            if (rsp_fire) begin
                rsp_index_q <= rsp_index_q + 1'b1;
                perf_refill_word_count <= perf_refill_word_count + 1'b1;
                perf_cache_rsp_count <= perf_cache_rsp_count + 1'b1;
                if (refill_last_fire)
                    refill_active_q <= 1'b0;
            end

            if (client_burst_count > perf_axi_burst_count)
                perf_axi_burst_count <= client_burst_count;
            if (client_beat_count > perf_axi_beat_count)
                perf_axi_beat_count <= client_beat_count;
            if (client_max_outstanding > perf_max_outstanding)
                perf_max_outstanding <= client_max_outstanding;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (refill_active_q && (refill_words_q == 0))
                $fatal(1, "burst shell accepted a zero-length refill");
            if (cache_refill_word_valid && !refill_active_q)
                $fatal(1, "refill word presented outside active refill");
            if (cache_refill_word_valid && cache_refill_word_last &&
                (rsp_index_q != refill_words_q - 1'b1))
                $fatal(1, "refill last marker/count mismatch");
        end
    end
`endif
endmodule
