// C35 independent shadow-read candidate. Retained feeder is unchanged.
// start_shadow=0 preserves its address/operand schedule, including tails.
// start_shadow=1 selects an already-published DW16 row; no feature refill.
// C22 independent feature-overlay branch; retained C21 sources unchanged.
// C21 independent six-lane weight branch; retained C18 sources unchanged.
// C7 derivative; retained C5/C6 source remains unchanged.
`timescale 1ns/1ps
// SRAM-backed PW with Cin16/24/48 and Cout8/16/24/48; also same-scale add+ReLU.
// Only supplies operands; weights/affine and compute are shared externally.
// Feature load address={pixel_parity,bank_word[8:0],word32[1:0]}, where
// bank_word=(pixel/2)*ceil(Cin/16)+K16. Residual uses one 128-bit A8/B8 record.
module c1_r2_pw_shadow_feeder (
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [11:0] load_addr,
    input wire [31:0] load_data,
    input wire bulk_en,bulk_residual,bulk_residual_b,
    input wire [9:0] bulk_pair,
    input wire [2:0] bulk_group,bulk_groups,
    input wire [127:0] bulk_data,
    input wire start_valid,
    output wire start_ready,
    input wire [13:0] start_count,
    input wire [5:0] start_channels,start_outputs,
    input wire start_linear,finish,
    input wire start_shadow,
    input wire [8:0] start_shadow_base,
    output logic busy,
    output wire feature_rd_en,
    output wire [17:0] feature_rd_addr,
    input wire [255:0] feature_data,
    output wire [7:0] feature_wr_en,
    output wire [71:0] feature_wr_addr,
    output wire [255:0] feature_wr_data,
    output wire weight_read_en,
    output wire [47:0] weight_read_addr,
    output wire [53:0] weight_lane_addr,
    input wire [767:0] weight_data,
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
    function automatic [8:0] feature_address(input [9:0] pixel,input [1:0] chunks,input [1:0] beat);
        logic [10:0] pair_index,value;
        begin
            pair_index={2'd0,pixel[9:1]};
            case(chunks)
                1:value=pair_index;2:value=pair_index<<1;3:value=(pair_index<<1)+pair_index;default:value=0;
            endcase
            feature_address=value+beat;
        end
    endfunction
    function automatic [15:0] output_count(input [13:0] pixels,input [5:0] channels);
        logic [15:0] p;
        begin
            p={2'd0,pixels};
            case(channels)
                8:output_count=p<<3;16:output_count=p<<4;
                24:output_count=(p<<4)+(p<<3);48:output_count=(p<<5)+(p<<4);
                default:output_count=0;
            endcase
        end
    endfunction
    wire legal_channels=(start_channels==16 || start_channels==24 || start_channels==48) &&
                        (start_outputs==8 || start_outputs==16 || start_outputs==24 || start_outputs==48);
    wire legal_size=start_channels==16 ? start_count<=1024 : start_channels==24 ? start_count<=512 : start_count<=340;
    wire [14:0] shadow_end={6'd0,start_shadow_base}+{2'd0,start_count[13:1]};
    wire legal_shadow=!start_linear && start_channels==16 && start_outputs==8 &&
        start_count>=4 && start_count<=640 && start_count[1:0]==0 &&
        {5'd0,start_shadow_base}>=(start_count>>2) && shadow_end<=512;
    assign start_ready=!rst && !busy && start_count!=0 && (!start_shadow || legal_shadow) &&
        (start_linear ? start_count<=8192 : legal_channels && legal_size);
    assign load_ready=!rst && !busy && !start_valid;
    wire load_fire=load_valid && load_ready;
    wire start_fire=start_valid && start_ready;
    logic linear_q,tail8_q,shadow_q;
    logic [8:0] shadow_base_q;
    logic [9:0] shadow_width_q;
    logic [5:0] cout_q,issue_channel;
    logic [1:0] chunks_q,issue_k;
    logic [9:0] issue_pixel;
    logic [15:0] total_q,issue_base;
    logic rd_valid_q,rd_first_q,rd_last_q;
    logic [5:0] rd_mask_q,rd_channel_q;
    logic [15:0] rd_base_q;
    logic rd_parity_q,rd_tail8_q;
    wire slot_ready=!rd_valid_q || req_ready;
    wire read_fire=!rst && busy && issue_base<total_q && slot_ready;
    assign weight_read_en=read_fire && !linear_q;
    wire [6:0] next_channel={1'b0,issue_channel}+7'd6;
    wire end_k=issue_k+1==chunks_q;
    for(genvar bank=0;bank<8;bank=bank+1) begin : g_parameter_address
        wire [6:0] channel_candidate={1'b0,issue_channel[5:3],3'd0}+bank+(bank<issue_channel[2:0] ? 7'd8 : 7'd0);
        wire [6:0] channel_wrapped=channel_candidate>=cout_q ? channel_candidate-cout_q : channel_candidate;
        assign weight_read_addr[bank*6+:6]={channel_wrapped[5:3],1'b0,issue_k};
    end
    for(genvar lane=0;lane<6;lane=lane+1) begin : g_lane_address
        wire [6:0] candidate={1'b0,issue_channel}+lane;
        wire [6:0] channel=candidate>=cout_q ? candidate-cout_q : candidate;
        assign weight_lane_addr[lane*9+:9]={channel[2:0],channel[5:3],1'b0,issue_k};
    end
    wire [9:0] even_pixel_raw=issue_pixel+issue_pixel[0];
    // Cout8's last request may read an unused even bank beyond the row.
    // Clamp only in shadow mode; valid lanes retain their original address.
    wire [9:0] even_pixel=shadow_q && even_pixel_raw>=shadow_width_q ? shadow_width_q-1'b1 : even_pixel_raw;
    wire [9:0] odd_pixel=issue_pixel;
    assign feature_rd_en=read_fire;
    wire [8:0] odd_address=shadow_base_q+feature_address(odd_pixel,chunks_q,issue_k);
    wire [8:0] even_address=shadow_base_q+feature_address(even_pixel,chunks_q,issue_k);
    assign feature_rd_addr={odd_address,even_address};
    wire [10:0] bulk_pw_address=(bulk_groups==2 ? {1'b0,bulk_pair} : bulk_groups==3 ? {bulk_pair,1'b0} : ({1'b0,bulk_pair}<<1)+bulk_pair)+(bulk_group>>1);
    for(genvar ram_id=0;ram_id<8;ram_id=ram_id+1) begin : g_feature
        localparam integer BANK=ram_id/4,WORD=ram_id%4;
        wire bulk_parity=BANK^bulk_group[0];
        wire [3:0] residual_local=(bulk_parity ? 4'd3 : 4'd0)+bulk_group;
        wire [10:0] residual_address=({1'b0,bulk_pair}<<1)+bulk_pair+(residual_local>>1);
        wire [10:0] bulk_address=bulk_residual ? residual_address : bulk_pw_address;
        wire bulk_word=bulk_residual ? WORD/2==bulk_residual_b : WORD/2==bulk_group[0];
        wire [31:0] bulk_value=bulk_residual ? bulk_data[bulk_parity*64+(WORD%2)*32+:32] : bulk_data[BANK*64+(WORD%2)*32+:32];
        assign feature_wr_en[ram_id]=bulk_en && bulk_word && bulk_address<512;
        assign feature_wr_addr[ram_id*9+:9]=bulk_address[8:0];
        assign feature_wr_data[ram_id*32+:32]=bulk_value;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            shadow_q<=0;shadow_base_q<=0;shadow_width_q<=0;
            busy<=0;linear_q<=0;tail8_q<=0;cout_q<=8;chunks_q<=1;issue_channel<=0;issue_k<=0;issue_pixel<=0;total_q<=0;issue_base<=0;
            rd_valid_q<=0;rd_first_q<=0;rd_last_q<=0;rd_mask_q<=0;rd_channel_q<=0;rd_base_q<=0;rd_parity_q<=0;rd_tail8_q<=0;
        end else begin
            if(start_fire) begin
                shadow_q<=start_shadow;shadow_base_q<=start_shadow ? start_shadow_base : 9'd0;
                shadow_width_q<=start_count[9:0];
                busy<=1;linear_q<=start_linear;tail8_q<=!start_linear && start_channels==24;
                cout_q<=start_linear ? 6'd8 : start_outputs;
                chunks_q<=start_linear || start_channels==16 ? 2'd1 : start_channels==24 ? 2'd2 : 2'd3;
                total_q<=start_linear ? {2'd0,start_count} : output_count(start_count,start_outputs);
                issue_channel<=0;issue_k<=0;issue_pixel<=0;issue_base<=0;
            end
            if(finish) busy<=0;
            if(slot_ready) begin
                rd_valid_q<=read_fire;
                if(read_fire) begin
                    rd_first_q<=issue_k==0;rd_last_q<=end_k;rd_channel_q<=issue_channel;rd_base_q<=issue_base;
                    rd_parity_q<=issue_pixel[0];rd_tail8_q<=tail8_q && issue_k==1;
                    for(integer r=0;r<6;r=r+1) rd_mask_q[r]<=({1'b0,issue_base}+r)<total_q;
                    if(end_k) begin
                        issue_k<=0;issue_base<=issue_base+6;
                        if(next_channel>=cout_q) begin issue_channel<=next_channel-cout_q;issue_pixel<=issue_pixel+1'b1;end
                        else issue_channel<=next_channel[5:0];
                    end else issue_k<=issue_k+1'b1;
                end
            end
        end
    end
    assign req_valid=rd_valid_q;assign req_first=rd_first_q;assign req_last=rd_last_q;
    assign req_mask=rd_mask_q;assign req_tag=rd_base_q;
    for(genvar r=0;r<6;r=r+1) begin : g_operand
        wire [6:0] channel={1'b0,rd_channel_q}+r;
        wire [2:0] bank=channel[2:0];
        wire parity=rd_parity_q^(channel>=cout_q);
        wire [127:0] feature=parity ? feature_data[255:128] : feature_data[127:0];
        wire [24:0] q=affine_data[bank*25+:25];
        wire [7:0] aa=feature[bank*8+:8],bb=feature[64+bank*8+:8];
        assign req_a[r*128+:128]=linear_q ? {112'd0,bb,aa} : rd_tail8_q ? {64'd0,feature[63:0]} : feature;
        assign req_b[r*128+:128]=linear_q ? 128'h0101 : weight_data[r*128+:128];
        assign req_bias[r*32+:32]=linear_q ? 32'd0 : bias_data[bank*32+:32];
        assign req_mult[r*18+:18]=linear_q ? 18'd1 : q[17:0];
        assign req_shift[r*6+:6]=linear_q ? 6'd0 : q[23:18];
        assign req_relu[r]=linear_q ? 1'b1 : q[24];
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(bulk_en && (busy || start_valid || load_valid || (bulk_residual && bulk_groups!=3))) $fatal(1,"PW bulk refill ownership/groups");
        if(read_fire && (issue_channel>=cout_q || issue_k>=chunks_q)) $fatal(1,"PW bank scheduler invalid state");
        if(weight_read_en) begin
            for(integer r=0;r<6;r=r+1) for(integer s=r+1;s<6;s=s+1)
                if(((issue_channel+r)%8)==((issue_channel+s)%8)) $fatal(1,"PW weight bank collision");
        end
    end
`endif
endmodule
