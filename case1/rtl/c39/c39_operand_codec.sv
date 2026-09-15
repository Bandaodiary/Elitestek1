`timescale 1ns/1ps
// Lossless for the six existing feeder modes, NOT arbitrary six-vector data.
// PW can cross an output-channel group within one beat: retain TWO vectors.
module c39_operand_pack (
    input wire [2:0] mode,
    input wire [767:0] expanded,
    output wire [431:0] packed_a
);
    wire [431:0] dw;
    wire [95:0] residual;
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_lane
        assign dw[lane*72+:72]=expanded[lane*128+:72];
        assign residual[lane*16+:16]=expanded[lane*128+:16];
    end
    assign packed_a=mode==2 ? dw : mode==3 ? {336'd0,residual} :
        (mode==0 || mode==1) ? {176'd0,expanded[640+:128],expanded[0+:128]} :
        {304'd0,expanded[0+:128]};
endmodule

module c39_operand_unpack (
    input wire [2:0] mode,
    input wire [35:0] channels,
    input wire [431:0] packed_a,
    output wire [767:0] expanded
);
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_lane
        wire pw_second=channels[lane*6+:6]<channels[0+:6];
        wire select_second=mode==0 ? pw_second : (lane>=3);
        assign expanded[lane*128+:128]=mode==2 ? {56'd0,packed_a[lane*72+:72]} :
            mode==3 ? {112'd0,packed_a[lane*16+:16]} :
            (mode==0 || mode==1) ? (select_second ? packed_a[128+:128] : packed_a[0+:128]) :
            packed_a[0+:128];
    end
endmodule
