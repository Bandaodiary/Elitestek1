// Vendor-independent dual-clock ready/valid FIFO.
//
// The write and read pointers each have ADDR_WIDTH address bits plus one wrap
// bit.  Only Gray-coded pointers cross clock domains, through two local-clock
// synchronizer registers.  A write-side full condition is reached when the
// *next* write Gray pointer equals the synchronized read Gray pointer with its
// two most-significant bits inverted.  Read-side empty is reached when the
// *next* read Gray pointer equals the synchronized write Gray pointer.
//
// storage is intentionally not reset.  Its contents are observable only when
// rd_empty is false.  The generic asynchronous-read style maps naturally to a
// small LUT/distributed-memory FIFO without any vendor primitive.
//
// wr_rst and rd_rst are synchronous, active-high resets in their respective
// domains.  To flush or restart a live FIFO, system integration must assert
// both resets; independently deasserting them during startup is supported.

`timescale 1ns/1ps

module c1_async_stream_fifo #(
    parameter integer DATA_WIDTH = 24,
    parameter integer DEPTH = 16
) (
    input  logic                  wr_clk,
    input  logic                  wr_rst,
    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [DATA_WIDTH-1:0] in_data,
    output logic                  wr_full,

    input  logic                  rd_clk,
    input  logic                  rd_rst,
    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [DATA_WIDTH-1:0] out_data,
    output logic                  rd_empty
);

    localparam integer ADDR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;
    // Adding DEPTH to a binary pointer toggles these two Gray bits.  DEPTH>=2
    // guarantees PTR_WIDTH>=2; a zero-width replication is legal for DEPTH=2.
    localparam logic [PTR_WIDTH-1:0] FULL_COMPARE_MASK =
        {2'b11, {(PTR_WIDTH-2){1'b0}}};

    logic [DATA_WIDTH-1:0] storage [0:DEPTH-1];

    logic [PTR_WIDTH-1:0] wr_bin;
    logic [PTR_WIDTH-1:0] wr_bin_next;
    logic [PTR_WIDTH-1:0] wr_gray;
    logic [PTR_WIDTH-1:0] wr_gray_next;
    (* ASYNC_REG = "TRUE" *) logic [PTR_WIDTH-1:0] rd_gray_sync1_wr;
    (* ASYNC_REG = "TRUE" *) logic [PTR_WIDTH-1:0] rd_gray_sync2_wr;
    logic                 wr_full_next;
    logic                 push_fire;

    logic [PTR_WIDTH-1:0] rd_bin;
    logic [PTR_WIDTH-1:0] rd_bin_next;
    logic [PTR_WIDTH-1:0] rd_gray;
    logic [PTR_WIDTH-1:0] rd_gray_next;
    (* ASYNC_REG = "TRUE" *) logic [PTR_WIDTH-1:0] wr_gray_sync1_rd;
    (* ASYNC_REG = "TRUE" *) logic [PTR_WIDTH-1:0] wr_gray_sync2_rd;
    logic                 rd_empty_next;
    logic                 pop_fire;

    always_comb begin
        // Qualify the handshake outputs during their local reset intervals so
        // neither endpoint can observe an apparent transfer that reset drops.
        in_ready = !wr_rst && !wr_full;
        push_fire = in_valid && in_ready;
        wr_bin_next = wr_bin + push_fire;
        wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
        wr_full_next =
            (wr_gray_next == (rd_gray_sync2_wr ^ FULL_COMPARE_MASK));

        out_valid = !rd_rst && !rd_empty;
        pop_fire = out_valid && out_ready;
        rd_bin_next = rd_bin + pop_fire;
        rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;
        rd_empty_next = (rd_gray_next == wr_gray_sync2_rd);

        // rd_bin cannot advance while out_valid is stalled, and the write
        // pointer cannot reclaim this address until the read pointer crosses
        // back through its synchronizer.  Thus out_data remains stable for
        // the complete out_valid && !out_ready interval.
        out_data = storage[rd_bin[ADDR_WIDTH-1:0]];
    end

    // Write-domain pointer and memory write port.  The RAM has no reset.
    always_ff @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_bin <= '0;
            wr_gray <= '0;
            wr_full <= 1'b0;
        end else begin
            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
            if (push_fire)
                storage[wr_bin[ADDR_WIDTH-1:0]] <= in_data;
        end
    end

    // Read pointer.  Data itself is read combinationally from the current
    // address, giving first-word fall-through ready/valid behaviour.
    always_ff @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_bin <= '0;
            rd_gray <= '0;
            rd_empty <= 1'b1;
        end else begin
            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    // Synchronize the read Gray pointer into the write clock domain.
    always_ff @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_gray_sync1_wr <= '0;
            rd_gray_sync2_wr <= '0;
        end else begin
            rd_gray_sync1_wr <= rd_gray;
            rd_gray_sync2_wr <= rd_gray_sync1_wr;
        end
    end

    // Synchronize the write Gray pointer into the read clock domain.
    always_ff @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_gray_sync1_rd <= '0;
            wr_gray_sync2_rd <= '0;
        end else begin
            wr_gray_sync1_rd <= wr_gray;
            wr_gray_sync2_rd <= wr_gray_sync1_rd;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "c1_async_stream_fifo DATA_WIDTH must be positive");
        if (DEPTH < 2)
            $fatal(1, "c1_async_stream_fifo DEPTH must be at least two");
        if ((DEPTH & (DEPTH-1)) != 0)
            $fatal(1, "c1_async_stream_fifo DEPTH must be a power of two");
    end
`endif

endmodule
