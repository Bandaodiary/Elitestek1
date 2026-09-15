`timescale 1ns/1ps
// C20 candidate, NOT yet connected to the retained CNN/host graph.
// Six independently addressed full-table replicas serve six compute lanes.
// Existing narrow load format and affine bank interface are unchanged.
// Each lane address = {channel[2:0],channel[5:3],K16[2:0]} (load_addr[10:2]).
// Replication increases logical capacity but fills shallow physical BRAMs.
// PACKED uses 5->20-bit asymmetric slices (last slice 2->8), provisionally
// targeting seven rather than eight blocks per replica; mapping must prove it.
module c1_r2_weight_store6 #(
    parameter integer PACKED=0
) (
    input wire clk,rst,load_valid,
    input wire [1:0] load_kind,
    input wire [10:0] load_addr,
    input wire [31:0] load_data,
    input wire read_en,
    input wire [53:0] lane_addr,
    input wire [47:0] read_addr,
    output wire [767:0] read_weights,
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
    // Flatten indices: supported consistently by Icarus module-port slicing.
    if(PACKED==0) begin : g_word
            for(genvar ram_id=0;ram_id<24;ram_id=ram_id+1) begin : g_ram
                localparam integer LANE=ram_id/4,WORD=ram_id%4;
                c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)) u_ram (
                    .clk(clk),.rd_en(read_en && !rst),.rd_addr(lane_addr[LANE*9+:9]),
                    .rd_data(read_weights[ram_id*32+:32]),
                    .wr_en(!rst && load_valid && load_kind==1 && load_addr[1:0]==WORD),
                    .wr_addr(load_addr[10:2]),.wr_data(load_data)
                );
            end
        end else begin : g_packed
            for(genvar ram_id=0;ram_id<42;ram_id=ram_id+1) begin : g_ram
                localparam integer LANE=ram_id/7,SLICE=ram_id%7;
                localparam integer BITS=SLICE==6 ? 2 : 5;
                wire [4*BITS-1:0] value;
                c1_r2_weight_asym_ram #(.BITS(BITS)) u_ram (
                    .clk(clk),.read_en(read_en && !rst),.read_addr(lane_addr[LANE*9+:9]),
                    .read_data(value),.write_en(!rst && load_valid && load_kind==1),
                    .write_addr(load_addr),.write_data(load_data[SLICE*5+:BITS])
                );
                for(genvar word_id=0;word_id<4;word_id=word_id+1)
                    assign read_weights[LANE*128+word_id*32+SLICE*5+:BITS]=value[word_id*BITS+:BITS];
            end
        end
`ifndef SYNTHESIS
    initial if(PACKED!=0 && PACKED!=1) $fatal(1,"R2 weight replica packing must be 0/1");
    always @(posedge clk) if(!rst) begin
        if(load_valid && read_en) $fatal(1,"R2 shared parameters read/write owner collision");
        if(load_valid && load_kind==1 && load_addr[7:5]>=6) $fatal(1,"R2 invalid weight channel group");
        if(load_valid && load_kind>=2 && load_addr>=48) $fatal(1,"R2 invalid affine channel");
        if(load_valid && load_kind==3 && (load_data[31:25]!=0 || load_data[23:18]>47)) $fatal(1,"R2 invalid affine fields");
        if(read_en) begin
            for(integer b=0;b<8;b=b+1) if(read_addr[b*6+3+:3]>=6) $fatal(1,"R2 invalid parameter read group");
            for(integer l=0;l<6;l=l+1) if(lane_addr[l*9+3+:3]>=6) $fatal(1,"R2 invalid lane read group");
        end
    end
`endif
endmodule
