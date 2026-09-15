`timescale 1ns/1ps
// C23: two retained RGB888 rows, each split by x parity instead of replicated.
// Two synchronous adjacent/clamped taps per row. Arbitrary same-parity pairs
// are NOT supported. SRAM is retained across reset; caller owns row validity.
module c1_r2_resize_pair_ram #(
    parameter integer MAX_WIDTH=2048
)(
    input wire clk,rst,rd_en,
    input wire [15:0] rd_x0,rd_x1,
    output wire [23:0] row0_x0,row0_x1,row1_x0,row1_x1,
    input wire wr_row0,wr_row1,
    input wire [15:0] wr_x,
    input wire [23:0] wr_rgb
);
    localparam integer DEPTH=(MAX_WIDTH+1)/2;
    localparam integer AW=DEPTH<=1 ? 1 : $clog2(DEPTH);
    wire [95:0] data;
    logic x0_odd_q,x1_odd_q;
    always_ff @(posedge clk)if(!rst && rd_en)begin
        x0_odd_q<=rd_x0[0];x1_odd_q<=rd_x1[0];
    end
    for(genvar id=0;id<4;id=id+1)begin : g_ram
        localparam integer ROW=id/2,PARITY=id%2;
        wire [15:0] selected_x=(rd_x0[0]==PARITY) ? rd_x0 : rd_x1;
        wire [AW-1:0] rd_addr=selected_x>>1;
        wire [AW-1:0] wr_addr=wr_x>>1;
        c1_ram_sdp_read_first #(.DATA_WIDTH(24),.DEPTH(DEPTH),.ADDR_WIDTH(AW)) u_ram (
            .clk(clk),.rd_en(!rst && rd_en),.rd_addr(rd_addr),.rd_data(data[id*24+:24]),
            .wr_en(!rst && (ROW==0 ? wr_row0 : wr_row1) && wr_x[0]==PARITY),
            .wr_addr(wr_addr),.wr_data(wr_rgb)
        );
    end
    assign row0_x0=x0_odd_q ? data[24+:24] : data[0+:24];
    assign row0_x1=x1_odd_q ? data[24+:24] : data[0+:24];
    assign row1_x0=x0_odd_q ? data[72+:24] : data[48+:24];
    assign row1_x1=x1_odd_q ? data[72+:24] : data[48+:24];
`ifndef SYNTHESIS
    initial if(MAX_WIDTH<1 || MAX_WIDTH>65535)$fatal(1,"resize RAM width out of range");
    always @(posedge clk)if(!rst)begin
        if(rd_en && (rd_x0>=MAX_WIDTH || rd_x1>=MAX_WIDTH ||
           (rd_x1!=rd_x0 && {1'b0,rd_x1}!={1'b0,rd_x0}+17'd1)))
            $fatal(1,"resize RAM requires adjacent/clamped bounded taps");
        if((wr_row0 || wr_row1) && wr_x>=MAX_WIDTH)$fatal(1,"resize RAM write out of range");
    end
`endif
endmodule
