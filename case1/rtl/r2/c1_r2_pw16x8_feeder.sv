`timescale 1ns/1ps
// Production R2 operand feeder extracted from the retained standalone probe.
// No MAC or quantizer is instantiated here. finish is issued ONLY after the
// final shared-compute result is consumed, keeping parameters/RAM job-owned.
module c1_r2_pw16x8_feeder #(
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
    input wire finish,
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
            if(finish) busy<=0;
            if(rd_slot_ready) begin
                rd_valid_q<=read_fire;
                if(read_fire) begin
                    rd_base_q<=issue_base_q[TAG_BITS-1:0]; issue_base_q<=issue_base_q+6;
                    for(integer r=0;r<6;r=r+1) rd_mask_q[r]<=issue_base_q+r<total_q;
                end
            end
        end
    end


    assign mac_ready=req_ready;
    assign req_valid=rd_valid_q;
    assign req_first=1'b1;assign req_last=1'b1;
    assign req_mask=rd_mask_q;assign req_tag=rd_base_q;
    for(genvar r=0;r<6;r=r+1) begin : g_request
        wire [3:0] channel={1'b0,rd_base_q[2:0]}+r;
        wire pixel_parity=rd_base_q[3]^channel[3];
        wire [24:0] q=affine[channel[2:0]*25+:25];
        assign req_a[r*128+:128]=pixel_parity ? bank_data[255:128] : bank_data[127:0];
        assign req_b[r*128+:128]=weights[channel[2:0]*128+:128];
        assign req_bias[r*32+:32]=biases[channel[2:0]*32+:32];
        assign req_mult[r*18+:18]=q[17:0];
        assign req_shift[r*6+:6]=q[23:18];
        assign req_relu[r]=q[24];
    end
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
