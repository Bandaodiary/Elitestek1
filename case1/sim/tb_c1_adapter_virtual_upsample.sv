`timescale 1ns/1ps
// Independent logical producer scoreboard + real column cache/owner. The
// virtual and materialized builds use identical logical upsample results.
module tb_c1_adapter_virtual_upsample #(
    parameter integer WIDTH=4, HEIGHT=4, REUSE=1, PIPE_WRITES=0, WRITE_DEPTH=2,
    parameter bit VIRTUAL=1, OVERLAP=0, POINTWISE=0,
    parameter bit RESPONSE_BYPASS=0, LOOKUP_READS=0, PIXEL_PREFETCH=0, SOURCE_PIPELINE=0,
    parameter bit ALL_PIXEL_GROUPS=0
);
    tb_c1_r1_microstyle_tensor_adapter #(
        .COLUMN_READS(1), .COLUMN_OWNER(1), .VIRTUAL_UPSAMPLE(VIRTUAL),
        .HORIZONTAL_REUSE(REUSE), .FRAME_W(WIDTH), .FRAME_H(HEIGHT),
        .PIPELINED_WRITES(PIPE_WRITES), .RESPONSE_DEPTH((PIPE_WRITES||SOURCE_PIPELINE)?WRITE_DEPTH:1),
        .SOURCE_PIPELINE(SOURCE_PIPELINE),
        .COLUMN_WRITE_OVERLAP(OVERLAP),
        .POINTWISE_COLUMNS(POINTWISE),
        .COLUMN_RESPONSE_BYPASS(RESPONSE_BYPASS),.COLUMN_LOOKUP_READS(LOOKUP_READS),
        .PIXEL_COLUMN_PREFETCH(PIXEL_PREFETCH),
        .ALL_PIXEL_GROUPS(ALL_PIXEL_GROUPS),
        .PREFETCH_TAP_ADDRESS(1), .PRECLAMPED_SCALAR_TAPS(1)
    ) base();
endmodule
