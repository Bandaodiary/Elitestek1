// Vendor-independent synchronous ready/valid elastic FIFO.
//
// A transfer occurs only on valid && ready.  While the downstream interface
// is stalled (out_valid && !out_ready), out_valid and out_data remain stable.
// The memory array is intentionally not reset, which keeps the template
// synthesis-friendly; its contents are ignored whenever empty is asserted.
//
// full describes occupancy, not back-pressure by itself.  When full and the
// current output is accepted, in_ready remains asserted so a replacement word
// can be pushed in the same cycle without creating a bubble.
// rst is a synchronous local flush. Handshake outputs are suppressed while
// it is asserted, so peers cannot mistake discarded reset-edge data for a
// transfer. Occupancy flags/level reflect the registers cleared on that edge.

`timescale 1ns/1ps

module c1_stream_fifo #(
    parameter integer DATA_WIDTH  = 24,
    parameter integer DEPTH       = 4,
    parameter integer LEVEL_WIDTH = (DEPTH < 2) ? 1 : $clog2(DEPTH + 1)
) (
    input  logic                   clk,
    input  logic                   rst,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [DATA_WIDTH-1:0]  in_data,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [DATA_WIDTH-1:0]  out_data,

    output logic                   full,
    output logic                   empty,
    output logic [LEVEL_WIDTH-1:0] level
);

    localparam integer PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam [PTR_WIDTH-1:0] LAST_ADDR = DEPTH - 1;
    localparam [LEVEL_WIDTH-1:0] FULL_LEVEL = DEPTH;

    logic [DATA_WIDTH-1:0] storage [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] write_ptr;
    logic [PTR_WIDTH-1:0] read_ptr;
    logic push_fire;
    logic pop_fire;

    always_comb begin
        empty = (level == '0);
        full = (level == FULL_LEVEL);
        out_valid = !rst && !empty;
        out_data = empty ? '0 : storage[read_ptr];

        pop_fire = out_valid && out_ready;
        // Accept a replacement word on the same cycle that a full FIFO pops.
        in_ready = !rst && (!full || pop_fire);
        push_fire = in_valid && in_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            write_ptr <= '0;
            read_ptr <= '0;
            level <= '0;
        end else begin
            if (push_fire) begin
                storage[write_ptr] <= in_data;
                if (write_ptr == LAST_ADDR)
                    write_ptr <= '0;
                else
                    write_ptr <= write_ptr + 1'b1;
            end

            if (pop_fire) begin
                if (read_ptr == LAST_ADDR)
                    read_ptr <= '0;
                else
                    read_ptr <= read_ptr + 1'b1;
            end

            case ({push_fire, pop_fire})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "c1_stream_fifo DATA_WIDTH must be positive");
        if (DEPTH < 2)
            $fatal(1, "c1_stream_fifo DEPTH must be at least two");
        if (LEVEL_WIDTH < $clog2(DEPTH + 1))
            $fatal(1, "c1_stream_fifo LEVEL_WIDTH is too small for DEPTH");
    end
`endif

endmodule
