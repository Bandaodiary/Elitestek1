`timescale 1ns/1ps
// Three physical rows x two parity banks, ordinary single-read C8 SRAM.
// Read columns [x-1,x] then [x+1,x+2] in TWO clocks. Assembly plus an output
// holding register prefetch the next window during the five RGB MAC beats.
// This deliberately avoids replicated two-read memories. Refill is idle-only.
module c1_r2_window3x4_c8 #(
    parameter integer X_BITS=10
) (
    input wire clk,rst,
    input wire write_en,
    input wire [X_BITS+2:0] write_addr,
    input wire [31:0] write_data,
    input wire req_valid,
    output wire req_ready,
    input wire [X_BITS-1:0] req_x,
    input wire [X_BITS:0] req_width,
    input wire req_top,req_bottom,
    output logic out_valid,
    input wire out_ready,
    output logic [X_BITS-1:0] out_x,
    output logic [767:0] out_window
);
    localparam integer BANK_BITS=X_BITS-1;
    localparam integer DEPTH=1<<BANK_BITS;
    localparam logic [1:0] IDLE=0,READ_SECOND=1,CAPTURE_SECOND=2,ASSEMBLED=3;
    logic [1:0] phase_q;
    logic [4*X_BITS-1:0] columns_q;
    logic top_q,bottom_q;
    logic [X_BITS-1:0] assembly_x;
    wire [767:0] assembly_data;
    wire output_slot_ready=!out_valid || out_ready;
    assign req_ready=!rst && phase_q==IDLE;
    wire request_fire=req_valid && req_ready;
    wire read_fire=request_fire || (!rst && phase_q==READ_SECOND);
    wire [X_BITS-1:0] column[0:3];
    for(genvar j=0;j<4;j=j+1) begin : g_column
        if(j==0) assign column[j]=req_x==0 ? 0 : req_x-1'b1;
        else begin : g_right
            wire [X_BITS:0] extended={1'b0,req_x}+(j-1);
            assign column[j]=extended>=req_width ? req_width-1'b1 : extended[X_BITS-1:0];
        end
    end
    wire [X_BITS-1:0] read_column0=phase_q==READ_SECOND ? columns_q[2*X_BITS+:X_BITS] : column[0];
    wire [X_BITS-1:0] read_column1=phase_q==READ_SECOND ? columns_q[3*X_BITS+:X_BITS] : column[1];
    wire [383:0] bank_data;
    for(genvar slice_id=0;slice_id<12;slice_id=slice_id+1) begin : g_ram
        localparam integer ROW=slice_id/4;
        localparam integer BANK=(slice_id/2)%2;
        localparam integer WORD=slice_id%2;
        logic [BANK_BITS-1:0] read_addr;
        always @* begin
            read_addr=0;
            if(read_column0[0]==BANK) read_addr=read_column0[X_BITS-1:1];
            if(read_column1[0]==BANK) read_addr=read_column1[X_BITS-1:1];
        end
        c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(DEPTH),.ADDR_WIDTH(BANK_BITS)) u_ram (
            .clk(clk),.rd_en(read_fire),.rd_addr(read_addr),.rd_data(bank_data[slice_id*32+:32]),
            .wr_en(write_en && write_addr[X_BITS+2:X_BITS+1]==ROW && write_addr[1]==BANK && write_addr[0]==WORD),
            .wr_addr(write_addr[X_BITS:2]),.wr_data(write_data)
        );
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            phase_q<=IDLE;out_valid<=0;out_x<=0;columns_q<=0;top_q<=0;bottom_q<=0;assembly_x<=0;
        end else begin
            if(output_slot_ready) begin
                out_valid<=phase_q==ASSEMBLED;
                if(phase_q==ASSEMBLED) begin out_window<=assembly_data;out_x<=assembly_x;end
            end
            case(phase_q)
                IDLE: if(request_fire) begin
                    phase_q<=READ_SECOND;assembly_x<=req_x;top_q<=req_top;bottom_q<=req_bottom;
                    for(integer j=0;j<4;j=j+1) columns_q[j*X_BITS+:X_BITS]<=column[j];
                end
                READ_SECOND: phase_q<=CAPTURE_SECOND;
                CAPTURE_SECOND: phase_q<=ASSEMBLED;
                ASSEMBLED: if(output_slot_ready) phase_q<=IDLE;
                default: phase_q<=IDLE;
            endcase
        end
    end
    for(genvar p=0;p<12;p=p+1) begin : g_assembly
        localparam integer ROW=p/4;
        localparam integer COL=p%4;
        wire [1:0] source_row=ROW==0 ? (top_q ? 2'd1 : 2'd0) :
                                   ROW==2 ? (bottom_q ? 2'd1 : 2'd2) : 2'd1;
        wire [2:0] index={source_row,columns_q[COL*X_BITS]};
        logic [63:0] pixel_q;
        always_ff @(posedge clk) if(!rst && phase_q==(COL<2 ? READ_SECOND : CAPTURE_SECOND))
            pixel_q<=bank_data[index*64+:64];
        assign assembly_data[p*64+:64]=pixel_q;
    end
`ifndef SYNTHESIS
    initial if(X_BITS<3 || X_BITS>12) $fatal(1,"R2 window X_BITS must be 3..12");
    always @(posedge clk) if(!rst) begin
        if(request_fire && (req_width==0 || req_width>(1<<X_BITS) || req_x>=req_width))
            $fatal(1,"R2 window invalid extent/center");
        if(write_en && write_addr[X_BITS+2:X_BITS+1]>=3) $fatal(1,"R2 window invalid physical row");
        if(write_en && (phase_q!=IDLE || out_valid || request_fire)) $fatal(1,"R2 window concurrent refill requires separate ownership");
    end
`endif
endmodule
