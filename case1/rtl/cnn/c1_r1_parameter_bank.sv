`timescale 1ns/1ps

// Board-independent atomic dual-bank parameter arena.
//
// A load_start/load_start_ready handshake selects the inactive bank and
// begins a sequential 128-bit transfer at word zero.  Exactly ARENA_WORDS
// handshakes are required.  load_last must be asserted on the final expected
// beat and on no earlier beat.  Only that exact transaction atomically changes
// active_bank, active_valid, and generation.
//
// An early last or a missing last on the expected final beat terminates the
// transaction with load_error.  In the missing-last case load_ready goes low
// after that beat, so a later/extra beat cannot be accepted.  abort has highest
// priority, suppresses any same-cycle beat, and discards the partial shadow
// transaction without altering the active bank.
//
// Storage is two explicit portable simple-dual-port RAM instances.  RAM
// contents are never reset and no vendor primitive is instantiated.  Default
// storage is two banks * 1056 words * 128 bits = 270336 bits.  Both physical
// RAMs are read on an accepted engine request; a saved active-bank selector
// chooses the response after the synchronous RAM read.  A read accepted on
// the same edge as a successful commit therefore observes the old active
// bank; reads accepted on following edges observe the new generation.
//
// This 128-bit implementation is a portable staging baseline.  Ti60 simple-
// dual-port embedded RAM ports are at most 20 bits wide, so Efinity must split
// each logical 128-bit bank horizontally into several physical RAM blocks.
// A board-specific resource optimization may instead use a single arena bank
// when atomic replacement is unnecessary, or serialize loads/reads over a
// narrower RAM datapath.
//
// READ_PORTS remains in the flattened interface for compatibility, but this
// two-RAM baseline implements exactly one engine read port.  Multiple engine
// read ports require explicit RAM replication or an external arbiter.
module c1_r1_parameter_bank #(
    parameter integer ARENA_BYTES = 16896,
    parameter integer READ_PORTS = 1,
    parameter integer ADDR_W =
        (((ARENA_BYTES / 16) <= 1) ? 1 : $clog2(ARENA_BYTES / 16))
) (
    input  logic                              clk,
    input  logic                              rst,

    input  logic                              load_start,
    output logic                              load_start_ready,
    input  logic                              load_valid,
    output logic                              load_ready,
    input  logic [127:0]                      load_data,
    input  logic                              load_last,
    input  logic                              load_abort,
    output logic                              load_busy,
    output logic                              load_done,
    output logic                              load_aborted,
    output logic                              load_error,
    output logic [2:0]                        load_error_code,

    output logic                              active_valid,
    output logic                              active_bank,
    output logic [31:0]                       generation,

    input  logic [READ_PORTS-1:0]             rd_en,
    input  logic [READ_PORTS*ADDR_W-1:0]      rd_addr,
    output logic [READ_PORTS-1:0]             rd_valid,
    output logic [READ_PORTS-1:0]             rd_error,
    output logic [READ_PORTS*128-1:0]         rd_data
);

    localparam integer ARENA_WORDS = ARENA_BYTES / 16;
    localparam integer COUNT_W =
        ((ARENA_WORDS <= 1) ? 1 : $clog2(ARENA_WORDS));
    localparam integer RAM_ADDR_W =
        ((ARENA_WORDS <= 1) ? 1 : $clog2(ARENA_WORDS));

    localparam logic [2:0] ERR_NONE         = 3'd0;
    localparam logic [2:0] ERR_EARLY_LAST   = 3'd1;
    localparam logic [2:0] ERR_MISSING_LAST = 3'd2;

    logic shadow_bank;
    logic [COUNT_W-1:0] load_word_index;
    logic load_handshake;

    logic                         bank0_wr_en;
    logic                         bank1_wr_en;
    logic [RAM_ADDR_W-1:0]        bank_wr_addr;
    logic                         bank_rd_en;
    logic [RAM_ADDR_W-1:0]        bank_rd_addr;
    logic [127:0]                 bank0_rd_data;
    logic [127:0]                 bank1_rd_data;
    logic [ADDR_W-1:0]            engine_rd_addr;
    logic                         rd_bank_q;

    c1_ram_sdp_read_first #(
        .DATA_WIDTH (128),
        .DEPTH      (ARENA_WORDS),
        .ADDR_WIDTH (RAM_ADDR_W)
    ) u_bank0_ram (
        .clk     (clk),
        .rd_en   (bank_rd_en),
        .rd_addr (bank_rd_addr),
        .rd_data (bank0_rd_data),
        .wr_en   (bank0_wr_en),
        .wr_addr (bank_wr_addr),
        .wr_data (load_data)
    );

    c1_ram_sdp_read_first #(
        .DATA_WIDTH (128),
        .DEPTH      (ARENA_WORDS),
        .ADDR_WIDTH (RAM_ADDR_W)
    ) u_bank1_ram (
        .clk     (clk),
        .rd_en   (bank_rd_en),
        .rd_addr (bank_rd_addr),
        .rd_data (bank1_rd_data),
        .wr_en   (bank1_wr_en),
        .wr_addr (bank_wr_addr),
        .wr_data (load_data)
    );

    always_comb begin
        load_start_ready = !rst && !load_abort && !load_busy;
        load_ready = !rst && !load_abort && load_busy;
        load_handshake = load_valid && load_ready;

        bank0_wr_en = load_handshake && !shadow_bank;
        bank1_wr_en = load_handshake && shadow_bank;
        bank_wr_addr = load_word_index;

        engine_rd_addr = rd_addr[0 +: ADDR_W];
        bank_rd_en = !rst && rd_en[0] && active_valid &&
                     (engine_rd_addr < ARENA_WORDS);
        bank_rd_addr = engine_rd_addr;

        // The RAM outputs are already registered by the portable SDP wrapper.
        // rd_bank_q was sampled with the request, so this mux retains the old
        // active bank on a request concurrent with atomic commit.
        rd_data = '0;
        if (rd_valid[0]) begin
            if (!rd_bank_q)
                rd_data[0 +: 128] = bank0_rd_data;
            else
                rd_data[0 +: 128] = bank1_rd_data;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            load_busy <= 1'b0;
            load_done <= 1'b0;
            load_aborted <= 1'b0;
            load_error <= 1'b0;
            load_error_code <= ERR_NONE;
            active_valid <= 1'b0;
            active_bank <= 1'b0;
            generation <= 32'd0;
            shadow_bank <= 1'b1;
            load_word_index <= '0;
        end else begin
            load_done <= 1'b0;
            load_aborted <= 1'b0;
            load_error <= 1'b0;

            if (load_abort) begin
                if (load_busy)
                    load_aborted <= 1'b1;
                load_busy <= 1'b0;
                load_word_index <= '0;
            end else if (load_start && load_start_ready) begin
                load_busy <= 1'b1;
                shadow_bank <= !active_bank;
                load_word_index <= '0;
                load_error_code <= ERR_NONE;
            end else if (load_handshake) begin
                if (load_last &&
                    (load_word_index != ARENA_WORDS - 1)) begin
                    load_busy <= 1'b0;
                    load_error <= 1'b1;
                    load_error_code <= ERR_EARLY_LAST;
                    load_word_index <= '0;
                end else if (!load_last &&
                             (load_word_index == ARENA_WORDS - 1)) begin
                    load_busy <= 1'b0;
                    load_error <= 1'b1;
                    load_error_code <= ERR_MISSING_LAST;
                    load_word_index <= '0;
                end else if (load_last) begin
                    load_busy <= 1'b0;
                    load_done <= 1'b1;
                    active_valid <= 1'b1;
                    active_bank <= shadow_bank;
                    generation <= generation + 32'd1;
                    load_word_index <= '0;
                end else begin
                    load_word_index <= load_word_index + 1'b1;
                end
            end
        end
    end

    // Engine reads are independent of shadow-bank writes.  rd_valid and the
    // common RAM registered outputs become visible in the cycle immediately
    // following the request edge.  The pre-edge active_bank value is saved so
    // a request concurrent with commit reads the old arena atomically.
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_valid <= '0;
            rd_error <= '0;
            rd_bank_q <= 1'b0;
        end else begin
            rd_valid <= '0;
            rd_error <= '0;
            if (rd_en[0]) begin
                if (!active_valid || (engine_rd_addr >= ARENA_WORDS)) begin
                    rd_error[0] <= 1'b1;
                end else begin
                    rd_valid[0] <= 1'b1;
                    rd_bank_q <= active_bank;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ARENA_BYTES <= 0 || (ARENA_BYTES % 16) != 0)
            $fatal(1, "ARENA_BYTES must be positive and divisible by 16");
        if (READ_PORTS != 1)
            $fatal(1, "portable parameter bank implements READ_PORTS=1");
        if (ADDR_W < RAM_ADDR_W)
            $fatal(1, "ADDR_W is too small for ARENA_WORDS");
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (load_done && load_error)
                $fatal(1, "parameter bank load_done and load_error overlap");
            if (load_done && load_aborted)
                $fatal(1, "parameter bank load_done and load_aborted overlap");
            if (load_handshake && (load_word_index >= ARENA_WORDS))
                $fatal(1, "parameter bank write address overflow");
        end
    end
`endif

endmodule
