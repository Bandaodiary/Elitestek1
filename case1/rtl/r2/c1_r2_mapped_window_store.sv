`timescale 1ns/1ps
// Shared spatial store: raw/stride2 centers or virtual-nearest2x coordinates.
// HWC address in bank = (x/2)*groups + group. Each request reads two column
// pairs in consecutive clocks. Two reserved output slots permit II=2 without
// overwriting either a held window or an in-flight synchronous RAM response.
module c1_r2_mapped_window_store (
    input wire clk,rst,write_en,
    input wire [13:0] write_addr, // {row[1:0],parity,bank_word[9:0],word32}
    input wire [31:0] write_data,
    input wire req_valid,
    output wire req_ready,
    input wire [9:0] req_x,
    input wire [10:0] req_width,
    input wire [2:0] req_group,req_groups,
    input wire req_top,req_bottom,
    input wire req_up2,req_row_phase,
    output wire out_valid,
    input wire out_ready,
    output wire [9:0] out_x,
    output wire [2:0] out_group,
    output wire [767:0] out_window
);
    function automatic [9:0] address_of(input [9:0] x,input [2:0] groups,input [2:0] group_id);
        logic [12:0] p,v;
        begin
            p={4'd0,x[9:1]};
            case(groups)
                1:v=p;2:v=p<<1;3:v=(p<<1)+p;6:v=(p<<2)+(p<<1);default:v=0;
            endcase
            address_of=v+group_id;
        end
    endfunction
    logic read_ptr,write_ptr,second_q,second_slot;
    logic [1:0] reserved_count;
    wire [1:0] slot_ready;
    wire [1535:0] slot_data;
    wire [25:0] slot_tags;
    assign out_valid=reserved_count!=0 && slot_ready[read_ptr];
    assign out_window=read_ptr ? slot_data[1535:768] : slot_data[767:0];
    assign {out_x,out_group}=read_ptr ? slot_tags[25:13] : slot_tags[12:0];
    wire pop=out_valid && out_ready;
    assign req_ready=!rst && !second_q && (reserved_count<2 || pop);
    wire push=req_valid && req_ready;
    wire read_fire=!rst && (push || second_q);
    wire [9:0] column[0:3],logical_column[0:3];
    wire [10:0] physical_width=req_up2 ? req_width>>1 : req_width;
    wire mapped_top=req_top || (req_up2 && req_row_phase);
    wire mapped_bottom=req_bottom || (req_up2 && !req_row_phase);
    for(genvar j=0;j<4;j=j+1) begin : g_column
        if(j==0) assign logical_column[j]=req_x==0 ? 10'd0 : req_x-1'b1;
        else begin : g_right
            wire [10:0] xx={1'b0,req_x}+(j-1);
            assign logical_column[j]=xx>=req_width ? req_width-1'b1 : xx[9:0];
        end
    end
    for(genvar j=0;j<4;j=j+1) begin : g_physical
        assign column[j]=req_up2 ? logical_column[j]>>1 : logical_column[j];
    end
    logic [19:0] second_columns;
    logic [2:0] second_groups,second_group;
    logic second_top,second_bottom;
    wire [9:0] col0=second_q ? second_columns[9:0] : column[0];
    wire [9:0] col1=second_q ? second_columns[19:10] : column[1];
    wire [2:0] groups=second_q ? second_groups : req_groups;
    wire [2:0] group_id=second_q ? second_group : req_group;
    wire [383:0] bank_data;
    for(genvar slice_id=0;slice_id<12;slice_id=slice_id+1) begin : g_ram
        localparam integer ROW=slice_id/4;
        localparam integer BANK=(slice_id/2)%2;
        localparam integer WORD=slice_id%2;
        wire [9:0] chosen_col=col1[0]==BANK ? col1 : col0;
        c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(1024),.ADDR_WIDTH(10)) u_ram (
            .clk(clk),.rd_en(read_fire),.rd_addr(address_of(chosen_col,groups,group_id)),
            .rd_data(bank_data[slice_id*32+:32]),
            .wr_en(write_en && write_addr[13:12]==ROW && write_addr[11]==BANK && write_addr[0]==WORD),
            .wr_addr(write_addr[10:1]),.wr_data(write_data)
        );
    end
    logic pending_valid,pending_half,pending_slot,pending_top,pending_bottom;
    logic [1:0] pending_parity;
    always_ff @(posedge clk) begin
        if(rst) begin
            read_ptr<=0;write_ptr<=0;second_q<=0;second_slot<=0;reserved_count<=0;pending_valid<=0;
            second_columns<=0;second_groups<=1;second_group<=0;second_top<=0;second_bottom<=0;
            pending_half<=0;pending_slot<=0;pending_top<=0;pending_bottom<=0;pending_parity<=0;
        end else begin
            if(push) begin
                write_ptr<=~write_ptr;second_q<=1;second_slot<=write_ptr;
                second_columns<={column[3],column[2]};second_groups<=req_groups;second_group<=req_group;
                second_top<=mapped_top;second_bottom<=mapped_bottom;
            end else if(second_q) second_q<=0;
            if(pop) read_ptr<=~read_ptr;
            case({push,pop})
                2'b10:reserved_count<=reserved_count+1'b1;
                2'b01:reserved_count<=reserved_count-1'b1;
                default:begin end
            endcase
            pending_valid<=read_fire;
            if(read_fire) begin
                pending_half<=second_q;pending_slot<=second_q ? second_slot : write_ptr;
                pending_top<=second_q ? second_top : mapped_top;pending_bottom<=second_q ? second_bottom : mapped_bottom;
                pending_parity<={col1[0],col0[0]};
            end
        end
    end
    for(genvar entry=0;entry<2;entry=entry+1) begin : g_slot
        logic ready_q;
        logic [12:0] tag_q;
        always_ff @(posedge clk) begin
            if(rst) begin ready_q<=0;tag_q<=0;end
            else begin
                if(pop && read_ptr==entry) ready_q<=0;
                if(push && write_ptr==entry) begin ready_q<=0;tag_q<={req_x,req_group};end
                if(pending_valid && pending_half && pending_slot==entry) ready_q<=1;
            end
        end
        assign slot_ready[entry]=ready_q;assign slot_tags[entry*13+:13]=tag_q;
        for(genvar p=0;p<12;p=p+1) begin : g_pixel
            localparam integer ROW=p/4,COL=p%4;
            wire [1:0] row_id=ROW==0 ? (pending_top ? 2'd1 : 2'd0) : ROW==2 ? (pending_bottom ? 2'd1 : 2'd2) : 2'd1;
            wire [2:0] index={row_id,pending_parity[COL%2]};
            logic [63:0] pixel_q;
            always_ff @(posedge clk) if(!rst && pending_valid && pending_slot==entry && pending_half==(COL>=2))
                pixel_q<=bank_data[index*64+:64];
            assign slot_data[entry*768+p*64+:64]=pixel_q;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(reserved_count>2) $fatal(1,"group-window slot overflow");
        if(push && (req_width==0 || req_width>1024 || req_x>=req_width || req_group>=req_groups ||
          !(req_groups==1 || req_groups==2 || req_groups==3 || req_groups==6) || ((physical_width+1)/2)*req_groups>1024 || (req_up2 && req_width[0])))
            $fatal(1,"group-window invalid extent/group");
        if(write_en && (write_addr[13:12]>=3 || reserved_count!=0 || second_q || pending_valid || push))
            $fatal(1,"group-window illegal refill ownership");
    end
`endif
endmodule
