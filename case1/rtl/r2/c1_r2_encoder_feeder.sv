`timescale 1ns/1ps
// No feature/parameter RAM or compute array. Assemble 3x3 Cin3/Cin12 from
// one/two raw C8 windows, then issue Cout12/Cout24 six-lane K16 transactions.
// Two reserved 112-byte slots overlap next-pixel assembly with current MACs.
module c1_r2_encoder_feeder (
    input wire clk,rst,start_valid,wide,
    input wire window_valid,
    output wire window_ready,
    input wire [9:0] window_x,
    input wire [2:0] window_group,
    input wire [767:0] window_data,
    output wire weight_read_en,
    output wire [47:0] weight_read_addr,
    input wire [1023:0] weight_data,
    input wire [255:0] bias_data,
    input wire [199:0] affine_data,
    output wire req_valid,
    input wire req_ready,
    output wire req_first,req_last,
    output wire [5:0] req_mask,
    output wire [15:0] req_tag,
    output wire [767:0] req_a,req_b,
    output wire [191:0] req_bias,
    output wire [107:0] req_mult,
    output wire [35:0] req_shift,
    output wire [5:0] req_relu
);
    logic wide_q,read_ptr,write_ptr,partial_open;
    logic [9:0] partial_x;
    logic [1:0] reserved_count,batch_q;
    logic [2:0] k_q;
    wire [1:0] ready_slots;
    wire [1791:0] payload_slots;
    wire [31:0] tag_slots;
    wire slot_valid=reserved_count!=0 && ready_slots[read_ptr];
    wire [895:0] payload=read_ptr ? payload_slots[1791:896] : payload_slots[895:0];
    wire [15:0] pixel_tag=read_ptr ? tag_slots[31:16] : tag_slots[15:0];
    wire [4:0] channel_base=batch_q==0 ? 0 : batch_q==1 ? 6 : batch_q==2 ? 12 : 18;
    wire [4:0] outputs=wide_q ? 5'd24 : 5'd12;
    wire end_k=wide_q ? k_q==6 : k_q==1;
    wire end_batch=wide_q ? batch_q==3 : batch_q==1;
    logic rd_valid_q,rd_first_q,rd_last_q;
    logic [4:0] rd_channel_q;
    logic [15:0] rd_tag_q;
    logic [127:0] rd_a_q;
    wire read_slot_ready=!rd_valid_q || req_ready;
    wire issue=!rst && slot_valid && read_slot_ready;
    wire pop=issue && end_k && end_batch;
    assign window_ready=!rst && (window_group==0 ? reserved_count<2 || pop : partial_open);
    wire take=window_valid && window_ready;
    wire push=take && window_group==0;
    wire finish_window=take && (!wide_q || window_group==1);
    wire [15:0] x_wide={7'd0,window_x[9:1]};
    wire [15:0] start_tag=wide_q ? (x_wide<<4)+(x_wide<<3) : (x_wide<<3)+(x_wide<<2);
    always_ff @(posedge clk) begin
        if(rst || start_valid) begin
            wide_q<=rst ? 1'b0 : wide;read_ptr<=0;write_ptr<=0;partial_open<=0;partial_x<=0;
            reserved_count<=0;batch_q<=0;k_q<=0;rd_valid_q<=0;rd_first_q<=0;rd_last_q<=0;rd_channel_q<=0;rd_tag_q<=0;
        end else begin
            if(push && wide_q) begin partial_open<=1;partial_x<=window_x;end
            if(finish_window) begin partial_open<=0;write_ptr<=~write_ptr;end
            if(pop) read_ptr<=~read_ptr;
            case({push,pop})
                2'b10:reserved_count<=reserved_count+1'b1;
                2'b01:reserved_count<=reserved_count-1'b1;
                default:begin end
            endcase
            if(read_slot_ready) begin
                rd_valid_q<=issue;
                if(issue) begin
                    rd_first_q<=k_q==0;rd_last_q<=end_k;rd_channel_q<=channel_base;
                    rd_tag_q<=pixel_tag+channel_base;rd_a_q<=payload[k_q*128+:128];
                    if(end_k) begin k_q<=0;batch_q<=end_batch ? 0 : batch_q+1'b1;end
                    else k_q<=k_q+1'b1;
                end
            end
        end
    end
    for(genvar entry=0;entry<2;entry=entry+1) begin : g_slot
        logic ready_q;
        logic [15:0] tag_q;
        always_ff @(posedge clk) begin
            if(rst || start_valid) begin ready_q<=0;tag_q<=0;end
            else begin
                if(pop && read_ptr==entry) ready_q<=0;
                if(push && write_ptr==entry) begin ready_q<=!wide_q;tag_q<=start_tag;end
                if(finish_window && write_ptr==entry) ready_q<=1;
            end
        end
        assign ready_slots[entry]=ready_q;assign tag_slots[entry*16+:16]=tag_q;
        for(genvar term=0;term<112;term=term+1) begin : g_term
            wire [7:0] narrow_value,wide_value;
            if(term<27) begin : g_narrow
                localparam integer TAP=term/3,CHANNEL=term%3;
                assign narrow_value=window_data[((TAP/3)*4+TAP%3)*64+CHANNEL*8+:8];
            end else assign narrow_value=0;
            if(term<108) begin : g_wide
                localparam integer TAP=term/12,CHANNEL=term%12;
                assign wide_value=window_data[((TAP/3)*4+TAP%3)*64+(CHANNEL%8)*8+:8];
            end else assign wide_value=0;
            logic [7:0] byte_q;
            always_ff @(posedge clk) if(!rst && take && write_ptr==entry) begin
                if(!wide_q) byte_q<=narrow_value;
                else if(window_group==(term<108 ? ((term%12)/8) : 0)) byte_q<=wide_value;
            end
            assign payload_slots[entry*896+term*8+:8]=byte_q;
        end
    end
    assign weight_read_en=issue;
    for(genvar bank=0;bank<8;bank=bank+1) begin : g_weight_address
        wire [5:0] candidate={1'b0,channel_base[4:3],3'd0}+bank+(bank<channel_base[2:0] ? 6'd8 : 6'd0);
        wire [5:0] wrapped=candidate>=outputs ? candidate-outputs : candidate;
        assign weight_read_addr[bank*6+:6]={wrapped[5:3],k_q};
    end
    assign req_valid=rd_valid_q;assign req_first=rd_first_q;assign req_last=rd_last_q;
    assign req_tag=rd_tag_q;assign req_mask=6'b111111;
    for(genvar r=0;r<6;r=r+1) begin : g_operand
        wire [2:0] bank=rd_channel_q[2:0]+r;
        wire [24:0] q=affine_data[bank*25+:25];
        assign req_a[r*128+:128]=rd_a_q;
        assign req_b[r*128+:128]=weight_data[bank*128+:128];
        assign req_bias[r*32+:32]=bias_data[bank*32+:32];
        assign req_mult[r*18+:18]=q[17:0];assign req_shift[r*6+:6]=q[23:18];assign req_relu[r]=q[24];
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst && !start_valid) begin
        if(reserved_count>2) $fatal(1,"encoder window slot overflow");
        if(window_valid && (window_x[0] || window_group>(wide_q ? 1 : 0))) $fatal(1,"encoder illegal window token");
        if(take && window_group==0 && partial_open) $fatal(1,"encoder lost partial window owner");
        if(take && window_group==1 && (!partial_open || window_x!=partial_x)) $fatal(1,"encoder C8 fragments do not match");
        if(issue && (k_q>(wide_q ? 6 : 1) || batch_q>(wide_q ? 3 : 1))) $fatal(1,"encoder illegal reduction state");
    end
`endif
endmodule
