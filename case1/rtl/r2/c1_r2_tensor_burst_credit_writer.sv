`timescale 1ns/1ps
// C33 candidate: published row-word credit plus guaranteed granted drain.
// Prior C32 and C31 implementations remain separate, unchanged baselines.
// Retained C8/C31 writer is untouched. Same two P2C8 pages and byte RAMs.
// A word is publishable only after its final valid byte has been written.
// The ordered CNN producer must not revisit any published word.
// A page releases ONLY after BOTH collection completion and real response.
// Candidate only: full RTL simulation/PNR/integration still require validation.
module c1_r2_tensor_burst_credit_writer (
    input wire clk,rst,start_valid,
    input wire stream_enable,
    input wire [15:0] granted_beats,
    output wire [15:0] published_beats,
    output wire start_ready,
    input wire [2:0] start_mode,
    input wire [10:0] start_width,
    input wire [5:0] start_channels,
    input wire start_rgb,
    input wire [31:0] start_address,
    input wire in_valid,
    output wire in_ready,
    input wire [47:0] in_data,
    input wire [5:0] in_mask,
    input wire [15:0] in_index,
    input wire in_last,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire [31:0] cmd_address,
    output wire [15:0] cmd_beats,
    output wire data_valid,
    input wire data_ready,
    output wire [127:0] data,
    output wire data_last,
    input wire response_valid,response_error,
    output wire response_ready,
    output logic done,error
);
    localparam IDLE=0,COMMAND=1,STREAM=2,RESPONSE=3;
    logic [1:0] state,allocated,completed;
    logic [10:0] ready_words[0:1];
    logic allocating_page,collect_page,send_page,collecting;
    logic [2:0] mode_q,groups_q;
    logic [10:0] width_q,pixel_q;
    logic [5:0] channels_q,channel_q;
    logic [15:0] scalar_q;
    logic rgb_q;
    logic [10:0] page_width[0:1],page_words[0:1];
    logic [5:0] page_channels[0:1];
    logic [2:0] page_groups[0:1];
    logic [31:0] page_address[0:1];
    logic [10:0] send_width,send_words,read_index,held_index;
    logic [5:0] send_channels;
    logic [2:0] send_groups,read_group,held_group;
    logic [10:0] read_pixel,held_pixel;
    logic [31:0] send_address;
    logic held_valid;
    wire reserve=start_valid && start_ready;
    wire take=in_valid && in_ready;
    wire retire=response_valid && response_ready;
    assign start_ready=!rst && !collecting && !allocated[allocating_page];
    assign in_ready=!rst && collecting;
    assign cmd_valid=!rst && state==COMMAND;
    assign cmd_address=send_address;assign cmd_beats={5'd0,send_words};
    assign data_valid=!rst && state==STREAM && held_valid;
    assign data_last=held_index+1==send_words;
    // In an odd-width DW tail, all valid bytes may precede its final packet.
    // Do not acknowledge/release that page until in_last has also arrived.
    assign response_ready=!rst && state==RESPONSE && completed[send_page];
    // Pause only before fetching a NEW word. A held data_valid is never
    // withdrawn, even when the graph changes to refill priority under stall.
    // Credits are cumulative LOGICAL P2C8 words in this row-command epoch.
    // Refill may stop speculative fetching, never an already granted burst.
    assign published_beats=!rst && state!=IDLE ? {5'd0,ready_words[send_page]} : 16'd0;
    wire drain_granted={5'd0,read_index}<granted_beats;
    wire read_fire=state==STREAM && (stream_enable || drain_granted) &&
                   read_index<send_words && read_index<ready_words[send_page] && (!held_valid || data_ready);
    wire [127:0] ram_data;
    wire [10:0] lane_x[0:5];
    wire [5:0] lane_c[0:5];
    wire [3:0] lane_bank[0:5];
    wire [9:0] lane_address[0:5];
    function automatic [10:0] times_groups(input [10:0] x,input [2:0] g);
        case(g)
            1:times_groups=x;2:times_groups=x<<1;3:times_groups=(x<<1)+x;
            6:times_groups=(x<<2)+(x<<1);default:times_groups=0;
        endcase
    endfunction
    for(genvar l=0;l<6;l=l+1) begin : g_mapping
        wire [6:0] c={1'b0,channel_q}+l;
        wire [4:0] local_c={in_index[1:0],2'b00}+{1'b0,in_index[1:0],1'b0}+l;
        assign lane_x[l]=mode_q==1 ? in_index+(l/3) :
                         mode_q==2 ? {1'b0,in_index[14:5]}+local_c[4:3] : pixel_q+(c>=channels_q);
        assign lane_c[l]=mode_q==1 ? l%3 : mode_q==2 ? {in_index[4:2],3'd0}+{3'd0,local_c[2:0]} :
                         c>=channels_q ? c-channels_q : c;
        assign lane_bank[l]={lane_x[l][0],lane_c[l][2:0]};
        assign lane_address[l]=times_groups(lane_x[l]>>1,groups_q)+{7'd0,lane_c[l][5:3]};
    end
    // In all supported ordered producer modes, the last valid channel of
    // each eight-channel group on the second (or odd tail) pixel completes
    // one consecutive P2C8 word. Padding bytes are masked to zero on output.
    wire [5:0] word_finished;
    wire [2:0] publish_count;
    for(genvar l=0;l<6;l=l+1) begin : g_publish
        assign word_finished[l]=take && in_mask[l] &&
            (lane_x[l][0] || lane_x[l]+1==width_q) &&
            (lane_c[l][2:0]==7 || lane_c[l]+1==channels_q);
    end
    assign publish_count={2'd0,word_finished[0]}+{2'd0,word_finished[1]}+
                         {2'd0,word_finished[2]}+{2'd0,word_finished[3]}+
                         {2'd0,word_finished[4]}+{2'd0,word_finished[5]};
    for(genvar b=0;b<16;b=b+1) begin : g_byte_bank
        logic wr;
        logic [9:0] addr;
        logic [7:0] value;
        always_comb begin
            wr=0;addr=0;value=0;
            for(integer l=0;l<6;l=l+1) if(take && in_mask[l] && lane_bank[l]==b) begin
                wr=1;addr=lane_address[l];value=in_data[l*8+:8]^(rgb_q ? 8'h80 : 8'h00);
            end
        end
        c1_ram_sdp_read_first #(.DATA_WIDTH(8),.DEPTH(2048),.ADDR_WIDTH(11)) u_ram (
            .clk(clk),.wr_en(wr),.wr_addr({collect_page,addr}),.wr_data(value),
            .rd_en(read_fire),.rd_addr({send_page,read_index[9:0]}),.rd_data(ram_data[b*8+:8])
        );
        wire valid_byte=({held_group,3'd0}+(b%8)<send_channels) && (held_pixel+(b/8)<send_width);
        assign data[b*8+:8]=valid_byte ? ram_data[b*8+:8] : 8'd0;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;allocated<=0;completed<=0;allocating_page<=0;collect_page<=0;send_page<=0;collecting<=0;
            mode_q<=0;groups_q<=1;width_q<=0;pixel_q<=0;channels_q<=8;channel_q<=0;scalar_q<=0;rgb_q<=0;
            send_width<=0;send_words<=0;send_channels<=8;send_groups<=1;send_address<=0;
            read_index<=0;held_index<=0;held_valid<=0;read_group<=0;held_group<=0;read_pixel<=0;held_pixel<=0;
            done<=0;error<=0;
            for(integer p=0;p<2;p=p+1) begin ready_words[p]<=0;page_width[p]<=0;page_words[p]<=0;page_channels[p]<=0;page_groups[p]<=0;page_address[p]<=0;end
        end else begin
            done<=0;error<=0;
            if(reserve) begin
                allocated[allocating_page]<=1;completed[allocating_page]<=0;ready_words[allocating_page]<=0;
                collect_page<=allocating_page;allocating_page<=~allocating_page;collecting<=1;
                page_width[allocating_page]<=start_width;page_words[allocating_page]<=times_groups((start_width+1)>>1,(start_channels+7)>>3);
                page_channels[allocating_page]<=start_channels;page_groups[allocating_page]<=(start_channels+7)>>3;page_address[allocating_page]<=start_address;
                mode_q<=start_mode;width_q<=start_width;channels_q<=start_channels;groups_q<=(start_channels+7)>>3;
                rgb_q<=start_rgb;channel_q<=0;pixel_q<=0;scalar_q<=0;
            end
            if(take) begin
                ready_words[collect_page]<=ready_words[collect_page]+publish_count;
                scalar_q<=scalar_q+6;
                if(channel_q+7'd6>=channels_q) begin channel_q<=channel_q+7'd6-channels_q;pixel_q<=pixel_q+1'b1;end
                else channel_q<=channel_q+6;
                if(in_last) begin collecting<=0;completed[collect_page]<=1;end
            end
            case(state)
                IDLE:if(allocated[send_page] && stream_enable) begin
                    send_width<=page_width[send_page];send_words<=page_words[send_page];send_channels<=page_channels[send_page];
                    send_groups<=page_groups[send_page];send_address<=page_address[send_page];
                    read_index<=0;held_valid<=0;read_group<=0;read_pixel<=0;state<=COMMAND;
                end
                COMMAND:if(cmd_ready) state<=STREAM;
                STREAM:begin
                    if(!held_valid || data_ready) begin
                        held_valid<=read_fire;
                        if(read_fire) begin
                            held_index<=read_index;read_index<=read_index+1'b1;held_group<=read_group;held_pixel<=read_pixel;
                            if(read_group+1==send_groups) begin read_group<=0;read_pixel<=read_pixel+2;end
                            else read_group<=read_group+1'b1;
                        end
                    end
                    if(data_valid && data_ready && data_last) state<=RESPONSE;
                end
                RESPONSE:if(retire) begin
                    allocated[send_page]<=0;completed[send_page]<=0;send_page<=~send_page;
                    state<=IDLE;done<=1;error<=response_error;
                end
                default:state<=IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(reserve && (start_width==0 || start_width>1024 || start_channels==0 || start_channels>48 ||
            ((int'(start_width)+1)/2)*((int'(start_channels)+7)/8)>1024 || start_address[3:0]!=0)) $fatal(1,"cutthrough writer illegal shape");
        if((completed & ~allocated)!=0 || (collecting && !allocated[collect_page])) $fatal(1,"pingpong page ownership");
        if(read_fire && read_index>=ready_words[send_page]) $fatal(1,"cutthrough unpublished RAM read");
        if(read_fire && !allocated[send_page]) $fatal(1,"cutthrough read unowned page");
        if((state==STREAM || state==RESPONSE) && granted_beats>published_beats)
            $fatal(1,"C33 grant exceeds published logical words");
        if(read_fire && !stream_enable && {5'd0,read_index}>=granted_beats)
            $fatal(1,"C33 refill fetched beyond granted range");
        for(integer p=0;p<2;p=p+1) if(allocated[p] && ready_words[p]>page_words[p]) $fatal(1,"cutthrough prefix exceeds page");
        if(retire && (!allocated[send_page] || !completed[send_page])) $fatal(1,"pingpong premature retirement");
        if(take) begin : check_publish
            integer next_word;
            next_word=ready_words[collect_page];
            if(in_last && ready_words[collect_page]+publish_count!=page_words[collect_page])
                $fatal(1,"cutthrough incomplete last packet");
            for(integer l=0;l<6;l=l+1) if(word_finished[l]) begin
                if(lane_address[l]!=next_word)$fatal(1,"cutthrough nonconsecutive word publication");
                next_word=next_word+1;
            end
            if(mode_q!=1 && mode_q!=2 && in_index!=scalar_q) $fatal(1,"writer nonsequential scalar tag");
            for(integer l=0;l<6;l=l+1) if(in_mask[l]) begin
                if(lane_x[l]>=width_q || lane_c[l]>=channels_q) $fatal(1,"writer invalid lane coordinates");
                if(lane_address[l]<ready_words[collect_page]) $fatal(1,"cutthrough rewrote published word");
                for(integer k=l+1;k<6;k=k+1) if(in_mask[k] && lane_bank[l]==lane_bank[k]) $fatal(1,"writer bank collision");
            end
        end
    end
`endif
endmodule
