`timescale 1ns/1ps
// C27 MAP diagnostic only: distinguish supported attribute spelling from
// unprotected equivalent registers. This is not a camera or CDC sign-off.
module c1_ti60_cdc_attribute_probe (
    input wire clk_src,clk_dst,rst_src,rst_dst,d,
    output wire [5:0] observed
);
    logic src_q;
    always_ff @(posedge clk_src)if(rst_src)src_q<=0;else src_q<=d;
    (* async_reg="true" *) logic lower_a0,lower_a1,lower_b0,lower_b1;
    (* ASYNC_REG="TRUE" *) logic upper_a0,upper_a1,upper_b0,upper_b1;
    logic plain_a0,plain_a1,plain_b0,plain_b1;
    always_ff @(posedge clk_dst)begin
        if(rst_dst)begin
            lower_a0<=0;lower_a1<=0;lower_b0<=0;lower_b1<=0;
            upper_a0<=0;upper_a1<=0;upper_b0<=0;upper_b1<=0;
            plain_a0<=0;plain_a1<=0;plain_b0<=0;plain_b1<=0;
        end else begin
            lower_a0<=src_q;lower_a1<=lower_a0;lower_b0<=src_q;lower_b1<=lower_b0;
            upper_a0<=src_q;upper_a1<=upper_a0;upper_b0<=src_q;upper_b1<=upper_b0;
            plain_a0<=src_q;plain_a1<=plain_a0;plain_b0<=src_q;plain_b1<=plain_b0;
        end
    end
    assign observed={lower_a1,lower_b1,upper_a1,upper_b1,plain_a1,plain_b1};
endmodule
