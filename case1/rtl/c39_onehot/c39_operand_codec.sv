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
    // Mutually exclusive decodes are shared across all data bits and lanes.
    // Reserved modes 6/7 retain the original default behavior (first vector).
    wire is_pw=mode==0, is_rgb=mode==1, is_dw=mode==2, is_res=mode==3;
    wire is_pair=is_pw || is_rgb;
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_lane
        wire pw_second=channels[lane*6+:6]<channels[0+:6];
        wire second=(is_pw && pw_second) || (is_rgb && (lane>=3));
        wire first=!(is_dw || is_res) && (!is_pair || !second);
        assign expanded[lane*128+:128]=
            ({128{first}} & packed_a[0+:128]) |
            ({128{second}} & packed_a[128+:128]) |
            ({128{is_dw}} & {56'd0,packed_a[lane*72+:72]}) |
            ({128{is_res}} & {112'd0,packed_a[lane*16+:16]});
    end
endmodule
