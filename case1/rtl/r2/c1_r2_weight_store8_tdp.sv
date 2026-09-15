// REJECTED C20 paired-bank experiment; not in any production source closure.
// See R2_WEIGHT_MEMORY_BUDGET_20260913.md for inference failure/width limit.
`timescale 1ns/1ps
// One job-owned parameter pool for PW/RGB/DW. Eight banks indexed by Cout%8
// give six consecutive output scalars conflict-free reads (Cout multiple 8).
// Weight load address={bank[2:0],group[2:0],K16[2:0],word32[1:0]}.
// Bias/affine loads use linear output-channel addresses 0..47. Parameters are
// uninitialized after power-up; reset flushes consumers, never clears SRAM.
module c1_r2_weight_store8_tdp (
    input wire clk,rst,load_valid,
    input wire [1:0] load_kind,
    input wire [10:0] load_addr,
    input wire [31:0] load_data,
    input wire read_en,
    input wire [47:0] read_addr,
    output wire [1023:0] read_weights,
    output wire [255:0] read_bias,
    output wire [199:0] read_affine
);
    for(genvar bank=0;bank<8;bank=bank+1) begin : g_bank
        wire [191:0] biases;
        wire [149:0] affine;
        for(genvar group_id=0;group_id<6;group_id=group_id+1) begin : g_parameter
            logic [31:0] bias_q;
            logic [24:0] affine_q;
            always_ff @(posedge clk) if(!rst && load_valid && load_addr==group_id*8+bank) begin
                if(load_kind==2) bias_q<=load_data;
                if(load_kind==3) affine_q<=load_data[24:0];
            end
            assign biases[group_id*32+:32]=bias_q;
            assign affine[group_id*25+:25]=affine_q;
        end
        wire [2:0] read_group=read_addr[bank*6+3+:3];
        logic [31:0] bias_out_q;
        logic [24:0] affine_out_q;
        always_ff @(posedge clk) if(read_en && !rst) begin
            bias_out_q<=biases[read_group*32+:32];
            affine_out_q<=affine[read_group*25+:25];
        end
        assign read_bias[bank*32+:32]=bias_out_q;
        assign read_affine[bank*25+:25]=affine_out_q;
    end
    // Pair logical banks (0,1), (2,3), (4,5), (6,7). Reads use both
    // physical ports; load owns port A exclusively. Word updates retain the
    // existing arbitrary-order 32-bit command/address format and 1-cycle read.
    for(genvar ram_id=0;ram_id<16;ram_id=ram_id+1) begin : g_pair
        localparam integer PAIR=ram_id/4,WORD=ram_id%4,EVEN=PAIR*2,ODD=EVEN+1;
        c1_r2_weight_pair_ram u_ram (
            .clk(clk),.read_en(read_en && !rst),
            .even_addr(read_addr[EVEN*6+:6]),.odd_addr(read_addr[ODD*6+:6]),
            .even_data(read_weights[EVEN*128+WORD*32+:32]),
            .odd_data(read_weights[ODD*128+WORD*32+:32]),
            .write_en(!rst && load_valid && load_kind==1 && load_addr[10:9]==PAIR && load_addr[1:0]==WORD),
            .write_addr(load_addr[8:2]),.write_data(load_data)
        );
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(load_valid && read_en) $fatal(1,"R2 shared parameters read/write owner collision");
        if(load_valid && load_kind==1 && load_addr[7:5]>=6) $fatal(1,"R2 invalid weight channel group");
        if(load_valid && load_kind>=2 && load_addr>=48) $fatal(1,"R2 invalid affine channel");
        if(load_valid && load_kind==3 && (load_data[31:25]!=0 || load_data[23:18]>47)) $fatal(1,"R2 invalid affine fields");
        if(read_en) for(integer b=0;b<8;b=b+1) if(read_addr[b*6+3+:3]>=6) $fatal(1,"R2 invalid parameter read group");
    end
`endif
endmodule
