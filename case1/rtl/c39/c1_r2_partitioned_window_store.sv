// C37 independent resource candidate; compile INSTEAD OF the same-named baseline.
// C35 independent partition-control passthrough; retained scheduling unchanged.
// C29 row-bank packing candidate; retained C22/C28 storage unchanged.
// C22 independent feature-overlay branch; retained C21 sources unchanged.
// C7 derivative; retained C5/C6 source remains unchanged.
`timescale 1ns/1ps
// Shared spatial store: raw/stride2 centers or virtual-nearest2x coordinates.
// HWC address in bank = (x/2)*groups + group. Each request reads two column
// pairs in consecutive clocks. Two reserved output slots permit II=2 without
// overwriting either a held window or an in-flight synchronous RAM response.
module c1_r2_partitioned_window_store #(
    parameter integer ROW_WORDS=512
) (
    input wire partition_en,
    input wire [8:0] partition_base,
    input wire [9:0] partition_end,
    input wire clk,rst,write_en,
    input wire [13:0] write_addr, // {row[1:0],parity,bank_word[9:0],word32}
    input wire [31:0] write_data,
    input wire bulk_en,
    input wire [1:0] bulk_row,
    input wire [9:0] bulk_pair,
    input wire [2:0] bulk_group,bulk_groups,
    input wire [127:0] bulk_data,
    input wire linear_rd_en,
    input wire [17:0] linear_rd_addr,
    output wire [255:0] linear_rd_data,
    input wire [7:0] linear_wr_en,
    input wire [71:0] linear_wr_addr,
    input wire [255:0] linear_wr_data,
    input wire req_valid,
    output wire req_ready,
    input wire [9:0] req_x,
    input wire [10:0] req_width,
    input wire [2:0] req_group,req_groups,
    input wire req_top,req_bottom,
    input wire req_up2,req_row_phase,
    input wire [5:0] req_row_map,
    output wire out_valid,
    input wire out_ready,
    output wire [9:0] out_x,
    output wire [2:0] out_group,
    output wire [767:0] out_window
);
    localparam integer ROW_AW=$clog2(ROW_WORDS);
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
    wire [5:0] mapped_rows={mapped_bottom ? req_row_map[3:2] : req_row_map[5:4],req_row_map[3:2],mapped_top ? req_row_map[3:2] : req_row_map[1:0]};
    wire [9:0] bulk_address=(bulk_groups==1 ? bulk_pair : bulk_groups==2 ? bulk_pair<<1 : bulk_groups==3 ? (bulk_pair<<1)+bulk_pair : (bulk_pair<<2)+(bulk_pair<<1))+bulk_group;
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
    logic [5:0] second_rows,pending_rows;
    wire [9:0] col0=second_q ? second_columns[9:0] : column[0];
    wire [9:0] col1=second_q ? second_columns[19:10] : column[1];
    wire [2:0] groups=second_q ? second_groups : req_groups;
    wire [2:0] group_id=second_q ? second_group : req_group;
    wire [383:0] bank_data;
    wire [19:0] shared_read_addr;
    wire [5:0] active_rows=second_q ? second_rows : mapped_rows;
    wire row0_needed=active_rows[1:0]==0 || active_rows[3:2]==0 || active_rows[5:4]==0;
    for(genvar bank=0;bank<2;bank=bank+1)begin : g_shared_address
        wire [9:0] chosen=col1[0]==bank ? col1 : col0;
        assign shared_read_addr[bank*10+:10]=address_of(chosen,groups,group_id);
    end
    c1_r2_partitioned_feature_ram u_overlay (
        .partition_en(partition_en),.partition_base(partition_base),.partition_end(partition_end),
        .clk(clk),.rst(rst),
        .linear_rd_en(linear_rd_en),.linear_rd_addr(linear_rd_addr),.linear_rd_data(linear_rd_data),
        .linear_wr_en(linear_wr_en),.linear_wr_addr(linear_wr_addr),.linear_wr_data(linear_wr_data),
        .spatial_rd_en(read_fire && row0_needed),.spatial_rd_addr(shared_read_addr),.spatial_rd_data(bank_data[127:0]),
        .spatial_wr_en(bulk_en && bulk_row==0),.spatial_wr_addr(bulk_address),.spatial_wr_data(bulk_data)
    );
    // C29: row1/2 have full 64-bit writes per parity bank. Group their former
    // two 32-bit slices without changing depth, addresses or cycle latency.
    // Efinity physical block savings must be measured, not inferred from bits.
    for(genvar bank_id=2;bank_id<6;bank_id=bank_id+1) begin : g_ram
        localparam integer ROW=bank_id/2;
        localparam integer BANK=bank_id%2;
        wire [9:0] chosen_col=col1[0]==BANK ? col1 : col0;
        wire [9:0] read_address=address_of(chosen_col,groups,group_id);
        c1_ram_sdp_read_first #(.DATA_WIDTH(64),.DEPTH(ROW_WORDS),.ADDR_WIDTH(ROW_AW)) u_ram (
            .clk(clk),.rd_en(read_fire),.rd_addr(read_address[ROW_AW-1:0]),
            .rd_data(bank_data[bank_id*64+:64]),
            .wr_en(bulk_en && bulk_row==ROW),
            .wr_addr(bulk_address[ROW_AW-1:0]),.wr_data(bulk_data[BANK*64+:64])
        );
    end
    logic pending_valid,pending_half,pending_slot,pending_top,pending_bottom;
    logic [1:0] pending_parity;
    always_ff @(posedge clk) begin
        if(rst) begin
            read_ptr<=0;write_ptr<=0;second_q<=0;second_slot<=0;reserved_count<=0;pending_valid<=0;
            second_columns<=0;second_groups<=1;second_group<=0;second_top<=0;second_bottom<=0;
            pending_half<=0;pending_slot<=0;pending_top<=0;pending_bottom<=0;pending_parity<=0;
            second_rows<=6'b10_01_00;pending_rows<=6'b10_01_00;
        end else begin
            if(push) begin
                write_ptr<=~write_ptr;second_q<=1;second_slot<=write_ptr;
                second_columns<={column[3],column[2]};second_groups<=req_groups;second_group<=req_group;
                second_top<=mapped_top;second_bottom<=mapped_bottom;
                second_rows<=mapped_rows;
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
                pending_rows<=second_q ? second_rows : mapped_rows;
            end
        end
    end
    // Shared decode per logical row / parity, followed by static bit planes.
    // No stage removal: both reservation slots and half-read ownership remain.
    wire [383:0] selected_bank_data;
    for(genvar view=0;view<6;view=view+1)begin : g_bank_view
        wire [2:0] index={pending_rows[(view/2)*2+:2],pending_parity[view%2]};
        wire [5:0] select_bank;
        for(genvar bank=0;bank<6;bank=bank+1)begin : g_decode
            assign select_bank[bank]=index==bank;
        end
        for(genvar bit_id=0;bit_id<64;bit_id=bit_id+1)begin : g_bit
            wire [5:0] plane;
            for(genvar bank=0;bank<6;bank=bank+1)begin : g_bank
                assign plane[bank]=select_bank[bank] && bank_data[bank*64+bit_id];
            end
            assign selected_bank_data[view*64+bit_id]=|plane;
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
            wire [1:0] row_id=pending_rows[ROW*2+:2];
            wire [2:0] index={row_id,pending_parity[COL%2]};
            logic [63:0] pixel_q;
            always_ff @(posedge clk) if(!rst && pending_valid && pending_slot==entry && pending_half==(COL>=2))
                pixel_q<=selected_bank_data[(ROW*2+COL%2)*64+:64];
            assign slot_data[entry*768+p*64+:64]=pixel_q;
        end
    end
`ifndef SYNTHESIS
    initial if(ROW_WORDS!=512 && ROW_WORDS!=1024) $fatal(1,"C37 row capacity must be 512/1024");
    always @(posedge clk) if(!rst && bulk_en && bulk_row!=0 && bulk_address>=ROW_WORDS)
        $fatal(1,"C37 spatial refill exceeds row capacity");
    always @(posedge clk) if(!rst) begin
        // PW reads still require a full spatial drain. Only a bounded
        // shadow WRITE may overlap active DW windows, using the SDP write
        // ports in the disjoint upper partition. The leaf RAM checks each
        // read/write address and retains its physical port collision checks.
        if(linear_rd_en && (reserved_count!=0 || second_q || pending_valid || push || bulk_en))
            $fatal(1,"partition window linear reader before spatial drain");
        if(|linear_wr_en && ((!partition_en && (reserved_count!=0 || second_q || pending_valid || push || bulk_en)) ||
                              (partition_en && (bulk_en || write_en))))
            $fatal(1,"partition window illegal linear write ownership");
        if(reserved_count>2) $fatal(1,"group-window slot overflow");
        if(push && (req_width==0 || req_width>1024 || req_x>=req_width || req_group>=req_groups ||
          !(req_groups==1 || req_groups==2 || req_groups==3 || req_groups==6) || ((physical_width+1)/2)*req_groups>ROW_WORDS || (req_up2 && req_width[0])))
            $fatal(1,"group-window invalid extent/group");
        if(write_en && (write_addr[13:12]>=3 || reserved_count!=0 || second_q || pending_valid || push))
            $fatal(1,"group-window illegal refill ownership");
        if(bulk_en && (write_en || bulk_row>=3 || reserved_count!=0 || second_q || pending_valid || push)) $fatal(1,"bulk-window illegal refill ownership");
        if(push && (req_row_map[1:0]>=3 || req_row_map[3:2]>=3 || req_row_map[5:4]>=3)) $fatal(1,"bulk-window invalid row mapping");
    end
`endif
endmodule
