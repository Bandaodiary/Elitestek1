`timescale 1ns/1ps
// R2-B bounded pointwise tile engine: Cin=16, Cout=8, six scalar outputs/cycle.
// Actual HWC features are stored ONCE, split by even/odd pixel into synchronous
// RAMs. Flattened output groups of six touch at most two adjacent pixels.
// Weights/affine parameters are small, runtime-loaded registers (not RAM).
// No DMA, window gather, ping-pong overlap, CPU ABI or external AXI cancellation.
module c1_r2_pw16x8_tile #(
    parameter integer PIXEL_BITS=10
) (
    input wire clk, rst,
    input wire load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [PIXEL_BITS+1:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [PIXEL_BITS:0] pixel_count,
    output logic busy,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [PIXEL_BITS+2:0] out_base,
    output wire out_last
);
    localparam integer TAG_BITS=PIXEL_BITS+3;
    localparam integer BANK_BITS=PIXEL_BITS-1;
    localparam integer BANK_DEPTH=1<<BANK_BITS;
    localparam integer MAX_PIXELS=1<<PIXEL_BITS;
    // kind 0: {pixel, word[1:0]}, four little-endian words/pixel.
    // kind 1: {channel[2:0], word[1:0]}, four words/weight vector.
    // kind 2: channel[2:0], signed32 bias.
    // kind 3: channel[2:0], {reserved[6:0], relu, shift[5:0], signed mult[17:0]}.
    // Load accepted only while idle and start_valid is low. All bytes/params
    // used by a job must be initialized by the caller; reset preserves RAM.
    assign load_ready=!rst && !busy && !start_valid;
    assign start_ready=!rst && !busy && pixel_count!=0 && pixel_count<=MAX_PIXELS;
    wire load_fire=load_valid && load_ready;
    wire start_fire=start_valid && start_ready;
    // Keep tiny multi-read parameters in explicit registers. Changing weights
    // alone did NOT save the extra 12 Efinity RAMs: the extracted bias/affine
    // arrays were the remaining candidates, so all parameters are explicit.
    // Features still use inferred block RAMs.
    wire [1023:0] weights;
    for(genvar word_id=0;word_id<32;word_id=word_id+1) begin : g_weight
        logic [31:0] word_q;
        always_ff @(posedge clk)
            if(load_fire && load_kind==1 && load_addr[4:0]==word_id) word_q<=load_data;
        assign weights[word_id*32+:32]=word_q;
    end
    wire [255:0] biases;
    wire [199:0] affine;
    for(genvar c=0;c<8;c=c+1) begin : g_parameter
        logic [31:0] bias_q;
        logic [24:0] affine_q;
        always_ff @(posedge clk) if(load_fire && load_addr[2:0]==c) begin
            if(load_kind==2) bias_q<=load_data;
            if(load_kind==3) affine_q<=load_data[24:0];
        end
        assign biases[c*32+:32]=bias_q;
        assign affine[c*25+:25]=affine_q;
    end

    logic [TAG_BITS:0] total_q, issue_base_q;
    logic rd_valid_q;
    logic [TAG_BITS-1:0] rd_base_q;
    logic [5:0] rd_mask_q;
    wire mac_ready;
    wire rd_slot_ready=!rd_valid_q || mac_ready;
    wire read_fire=busy && issue_base_q<total_q && rd_slot_ready && !rst;
    wire [PIXEL_BITS-1:0] issue_pixel=issue_base_q[PIXEL_BITS+2:3];
    // At the last odd pixel, the unused next-even read may wrap to address 0.
    // No valid lane consumes it; the final scalar mask excludes that pixel.
    wire [BANK_BITS-1:0] even_addr=issue_pixel[PIXEL_BITS-1:1]+issue_pixel[0];
    wire [BANK_BITS-1:0] odd_addr=issue_pixel[PIXEL_BITS-1:1];
    wire [255:0] bank_data;
    for(genvar ram_id=0;ram_id<8;ram_id=ram_id+1) begin : g_ram
            localparam integer BANK=ram_id/4;
            localparam integer WORD_ID=ram_id%4;
            c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(BANK_DEPTH),.ADDR_WIDTH(BANK_BITS)) u_ram (
                .clk(clk),.rd_en(read_fire),.rd_addr(BANK==0 ? even_addr : odd_addr),
                .rd_data(bank_data[ram_id*32+:32]),
                .wr_en(load_fire && load_kind==0 && load_addr[2]==BANK && load_addr[1:0]==WORD_ID),
                .wr_addr(load_addr[PIXEL_BITS+1:3]),.wr_data(load_data)
            );
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0; total_q<=0; issue_base_q<=0; rd_valid_q<=0; rd_base_q<=0; rd_mask_q<=0;
        end else begin
            if(start_fire) begin
                busy<=1; total_q<={pixel_count,3'b000}; issue_base_q<=0;
            end
            if(out_valid && out_ready && out_last) busy<=0;
            if(rd_slot_ready) begin
                rd_valid_q<=read_fire;
                if(read_fire) begin
                    rd_base_q<=issue_base_q[TAG_BITS-1:0]; issue_base_q<=issue_base_q+6;
                    for(integer r=0;r<6;r=r+1) rd_mask_q[r]<=issue_base_q+r<total_q;
                end
            end
        end
    end

    wire [767:0] mac_a, mac_b;
    wire [191:0] mac_bias, mac_acc;
    wire mac_valid, quant_ready;
    wire [5:0] mac_mask;
    wire [TAG_BITS-1:0] mac_base;
    wire [143:0] quant_mult;
    wire [47:0] quant_shift;
    wire [15:0] quant_act;
    for(genvar r=0;r<6;r=r+1) begin : g_lane
        wire [3:0] input_channel={1'b0,rd_base_q[2:0]}+r;
        wire pixel_parity=rd_base_q[3]^input_channel[3];
        assign mac_a[r*128+:128]=pixel_parity ? bank_data[255:128] : bank_data[127:0];
        assign mac_b[r*128+:128]=weights[input_channel[2:0]*128+:128];
        assign mac_bias[r*32+:32]=biases[input_channel[2:0]*32+:32];
        wire [2:0] output_channel=mac_base[2:0]+r;
        wire [24:0] channel_affine=affine[output_channel*25+:25];
        // Job-scoped ownership: affine registers cannot change until the LAST
        // quantized result is consumed, even if all RAM reads already issued.
        assign quant_mult[r*18+:18]=channel_affine[17:0];
        assign quant_shift[r*6+:6]=channel_affine[23:18];
        assign quant_act[r*2+:2]={1'b0,channel_affine[24]};
    end
    assign quant_mult[143:108]=0;
    assign quant_shift[47:36]=0;
    assign quant_act[15:12]=0;
    c1_r2_dot16_array #(.ROWS(6),.TAG_BITS(TAG_BITS)) u_mac (
        .clk(clk),.rst(rst),.in_valid(rd_valid_q),.in_ready(mac_ready),
        .in_first(1'b1),.in_last(1'b1),.in_mask(rd_mask_q),.in_tag(rd_base_q),
        .in_a(mac_a),.in_b(mac_b),.in_bias(mac_bias),.out_valid(mac_valid),
        .out_ready(quant_ready),.out_mask(mac_mask),.out_tag(mac_base),.out_acc(mac_acc),.busy()
    );
    wire [63:0] quant_data;
    // Reuse the verified R1 elastic arithmetic without modifying the R1 file.
    // Constant lanes 6/7 are unused; physical pruning must be checked in EDA.
    c1_requant_bank8 #(.X_BITS(TAG_BITS),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(mac_valid),.in_ready(quant_ready),
        .in_acc_s32({64'd0,mac_acc}),.in_mult_s18(quant_mult),.in_shift_u6(quant_shift),
        .in_activation(quant_act),.in_sof(1'b0),.in_eol(1'b0),.in_eof(1'b0),
        .in_x(mac_base),.in_y(mac_mask),.out_valid(out_valid),.out_ready(out_ready),
        .out_data_s8(quant_data),.out_sof(),.out_eol(),.out_eof(),.out_x(out_base),.out_y(out_mask)
    );
    for(genvar r=0;r<6;r=r+1) begin : g_mask
        assign out_data[r*8+:8]=out_mask[r] ? quant_data[r*8+:8] : 8'd0;
    end
    assign out_last=({1'b0,out_base}+6>=total_q);
`ifndef SYNTHESIS
    initial if(PIXEL_BITS<3 || PIXEL_BITS>12) $fatal(1,"R2 PW PIXEL_BITS must be 3..12");
    always @(posedge clk) if(!rst && load_fire) begin
        if(load_kind==1 && load_addr>=32) $fatal(1,"R2 PW invalid weight address");
        if(load_kind>=2 && load_addr>=8) $fatal(1,"R2 PW invalid affine address");
        if(load_kind==3 && (load_data[23:18]>47 || load_data[31:25]!=0))
            $fatal(1,"R2 PW invalid affine configuration");
    end
`endif
endmodule
