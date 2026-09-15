`timescale 1ns/1ps
// Run the independent 22-stage operand/result scoreboard with the production
// column cache, including column-specific cancellation and error recovery.
module tb_c1_adapter_column_cache #(
    parameter integer REUSE=1,
    parameter integer WIDTH=8,
    parameter integer HEIGHT=4,
    parameter integer PIPE_WRITES=0,
    parameter integer PREFETCH=0,
    parameter integer PRECLAMPED=0,
    parameter integer OWNER=0
);
    tb_c1_r1_microstyle_tensor_adapter #(
        .COLUMN_READS(1), .COLUMN_OWNER(OWNER), .HORIZONTAL_REUSE(REUSE),
        .FRAME_W(WIDTH), .FRAME_H(HEIGHT),
        .PIPELINED_WRITES(PIPE_WRITES),
        .RESPONSE_DEPTH(PIPE_WRITES?2:1),
        .PREFETCH_TAP_ADDRESS(PREFETCH),
        .PRECLAMPED_SCALAR_TAPS(PRECLAMPED)
    ) base();
endmodule
