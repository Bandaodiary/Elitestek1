`timescale 1ns/1ps
// C35 candidate: ordered DW16 six-byte packets -> PW linear row shadow.
// For each two-pixel/group pair: phases 0/1/2 have masks 3f/3f/0f.
// At most two distinct 32-bit RAM slices are written per accepted packet.
// No RAM read/modify/write and no additional feature memory are required.
// write_enable grants the shared linear write port for this cycle. A bad
// packet suppresses all further writes and drains through producer LAST.
// abort requires the enclosing controller to cancel/drain the old producer
// before starting another row; this local sink has no external AXI debt.
module c1_r2_dw16_row_shadow_writer (
    input wire clk,rst,abort,
    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_width,
    input wire [8:0] start_base,
    input wire write_enable,
    input wire in_valid,
    output wire in_ready,
    input wire [47:0] in_data,
    input wire [5:0] in_mask,
    input wire [15:0] in_index,
    input wire in_last,
    output logic [7:0] linear_wr_en,
    output logic [71:0] linear_wr_addr,
    output logic [255:0] linear_wr_data,
    output logic busy,done,error,row_valid
);
    logic [10:0] width_q,pixel_q;
    logic [8:0] address_q;
    logic group_q;
    logic [1:0] phase_q;
    logic [15:0] carry_q;
    wire [15:0] expected_index={pixel_q,2'b00,group_q,phase_q};
    wire expected_last=(pixel_q+11'd2==width_q) && group_q && phase_q==2;
    wire packet_good=(in_index==expected_index) &&
        (in_mask==(phase_q==2 ? 6'h0f : 6'h3f)) && (in_last==expected_last);
    wire [11:0] start_end={3'b0,start_base}+{2'b0,start_width[10:1]};
    wire start_good=start_width>=4 && start_width<=640 && start_width[1:0]==0 &&
        {2'b0,start_base}>=(start_width>>2) && start_end<=512;
    assign start_ready=!rst && !abort && !busy;
    assign in_ready=!rst && !abort && busy && (write_enable || error);
    wire take=in_valid && in_ready;
    always_comb begin
        linear_wr_en=0;linear_wr_addr=0;linear_wr_data=0;
        for(integer id=0;id<8;id=id+1)linear_wr_addr[id*9+:9]=address_q;
        if(take && packet_good && !error)begin
            if(phase_q==0)begin
                linear_wr_en[group_q ? 2 : 0]=1;
                if(group_q)linear_wr_data[64+:32]=in_data[31:0];
                else linear_wr_data[0+:32]=in_data[31:0];
            end else if(phase_q==1)begin
                linear_wr_en[group_q ? 3 : 1]=1;
                linear_wr_en[group_q ? 6 : 4]=1;
                if(group_q)begin
                    linear_wr_data[96+:32]={in_data[15:0],carry_q};
                    linear_wr_data[192+:32]=in_data[47:16];
                end else begin
                    linear_wr_data[32+:32]={in_data[15:0],carry_q};
                    linear_wr_data[128+:32]=in_data[47:16];
                end
            end else begin
                linear_wr_en[group_q ? 7 : 5]=1;
                if(group_q)linear_wr_data[224+:32]=in_data[31:0];
                else linear_wr_data[160+:32]=in_data[31:0];
            end
        end
    end
    always_ff @(posedge clk)begin
        if(rst || abort)begin
            busy<=0;done<=0;error<=0;row_valid<=0;
            width_q<=0;pixel_q<=0;address_q<=0;group_q<=0;phase_q<=0;carry_q<=0;
        end else begin
            done<=0;
            if(start_valid && start_ready)begin
                width_q<=start_width;pixel_q<=0;address_q<=start_base;group_q<=0;phase_q<=0;carry_q<=0;
                row_valid<=0;error<=!start_good;busy<=start_good;done<=!start_good;
            end
            if(take)begin
                if(!packet_good)error<=1;
                if(in_last)begin
                    busy<=0;done<=1;row_valid<=!error && packet_good;
                end else if(!error && packet_good)begin
                    if(phase_q==0)carry_q<=in_data[47:32];
                    if(phase_q==2)begin
                        phase_q<=0;group_q<=!group_q;
                        if(group_q)begin pixel_q<=pixel_q+11'd2;address_q<=address_q+1'b1;end
                    end else phase_q<=phase_q+1'b1;
                end
            end
        end
    end
endmodule
