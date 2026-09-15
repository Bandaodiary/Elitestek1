`timescale 1ns/1ps
// C39 candidate: same five elastic stages and arithmetic contract as C29.
// Stage 3 stores quotient low8/overflow/guard instead of a biased 52-bit value.
module c39_requant_bank8_narrow #(
    parameter integer X_BITS=10, Y_BITS=9
) (
    input wire clk,rst,in_valid,
    output wire in_ready,
    input wire [255:0] in_acc_s32,
    input wire [143:0] in_mult_s18,
    input wire [47:0] in_shift_u6,
    input wire [15:0] in_activation,
    input wire in_sof,in_eol,in_eof,
    input wire [X_BITS-1:0] in_x,
    input wire [Y_BITS-1:0] in_y,
    output wire out_valid,
    input wire out_ready,
    output wire [63:0] out_data_s8,
    output wire out_sof,out_eol,out_eof,
    output wire [X_BITS-1:0] out_x,
    output wire [Y_BITS-1:0] out_y
);
    localparam integer META=X_BITS+Y_BITS+3;
    logic [4:0] valid_q;
    wire [4:0] ready;
    logic [META-1:0] meta_q[0:4];
    wire [META-1:0] input_meta={in_sof,in_eol,in_eof,in_x,in_y};
    assign ready[4]=!valid_q[4] || out_ready;
    for(genvar p=0;p<4;p=p+1)begin : g_ready
        assign ready[p]=!valid_q[p] || ready[p+1];
    end
    assign in_ready=ready[0];
    assign out_valid=valid_q[4];
    assign {out_sof,out_eol,out_eof,out_x,out_y}=meta_q[4];
    always_ff @(posedge clk)begin
        if(rst)begin
            valid_q<=0;
            for(integer p=0;p<5;p=p+1)meta_q[p]<=0;
        end else begin
            if(ready[0])begin
                valid_q[0]<=in_valid;
                if(in_valid)meta_q[0]<=input_meta;
            end
            for(integer p=1;p<5;p=p+1)if(ready[p])begin
                valid_q[p]<=valid_q[p-1];
                if(valid_q[p-1])meta_q[p]<=meta_q[p-1];
            end
        end
    end
    for(genvar c=0;c<8;c=c+1)begin : g_channel
        logic signed [50:0] product_q;
        logic [51:0] magnitude_q;
        logic negative_q;
        logic [5:0] product_shift_q,magnitude_shift_q;
        logic [1:0] act_q[0:3];
        logic [10:0] quotient_q; // {negative, high_nonzero, guard, low8}
        logic [9:0] rounded_q; // {negative, overflow, low8}
        logic [7:0] result_q;
        wire signed [51:0] extended={product_q[50],product_q};
        wire [51:0] shifted=magnitude_q >> magnitude_shift_q;
        wire guard_bit=magnitude_shift_q!=0 &&
            ((magnitude_q >> (magnitude_shift_q-1'b1)) & 52'd1)!=0;
        wire [8:0] low_sum={1'b0,quotient_q[7:0]}+{8'd0,quotient_q[8]};
        wire [9:0] rounded={quotient_q[10],quotient_q[9] | low_sum[8],low_sum[7:0]};
        wire negative=rounded_q[9],overflow=rounded_q[8];
        wire [7:0] low=rounded_q[7:0];
        wire [7:0] saturated=negative && act_q[3]==1 ? 8'd0 :
            overflow || (negative ? low>128 : low>127) ?
                (negative ? 8'h80 : 8'h7f) : negative ? 8'd0-low : low;
        assign out_data_s8[c*8+:8]=result_q;
        always_ff @(posedge clk)begin
            if(rst)result_q<=0;
            else begin
                if(ready[0] && in_valid)begin
                    product_q<=$signed(in_acc_s32[c*32+:32])*$signed(in_mult_s18[c*18+:18]);
                    product_shift_q<=in_shift_u6[c*6+:6];act_q[0]<=in_activation[c*2+:2];
                end
                if(ready[1] && valid_q[0])begin
                    magnitude_q<=product_q[50] ? $unsigned(-extended) : $unsigned(extended);
                    negative_q<=product_q[50];magnitude_shift_q<=product_shift_q;act_q[1]<=act_q[0];
                end
                if(ready[2] && valid_q[1])begin
                    quotient_q<={negative_q,|shifted[51:8],guard_bit,shifted[7:0]};act_q[2]<=act_q[1];
                end
                if(ready[3] && valid_q[2])begin
                    rounded_q<=rounded;act_q[3]<=act_q[2];
                end
                if(ready[4] && valid_q[3])result_q<=saturated;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(!rst && in_valid && in_ready)
        for(integer c=0;c<8;c=c+1)begin
            if(in_shift_u6[c*6+:6]>47)$fatal(1,"C39 shift outside contract");
            if(in_activation[c*2+:2]>1)$fatal(1,"C39 activation outside contract");
        end
`endif
endmodule
