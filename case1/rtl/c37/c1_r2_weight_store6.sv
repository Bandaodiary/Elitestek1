// C37 independent resource candidate; baseline files are unchanged.
`timescale 1ns/1ps
// C20 candidate, NOT yet connected to the retained CNN/host graph.
// Six independently addressed full-table replicas serve six compute lanes.
// Existing narrow load format and affine bank interface are unchanged.
// Each lane address = {channel[2:0],channel[5:3],K16[2:0]} (load_addr[10:2]).
// Replication increases logical capacity but fills shallow physical BRAMs.
// PACKED uses 5->20-bit asymmetric slices (last slice 2->8), provisionally
// targeting seven rather than eight blocks per replica; mapping must prove it.
module c1_r2_weight_store6 #(
    parameter integer PACKED=1,
    parameter integer MAX_CHANNELS=24
) (
    input wire clk,rst,load_valid,
    input wire [1:0] load_kind,
    input wire [10:0] load_addr,
    input wire [31:0] load_data,
    input wire read_en,
    input wire [53:0] lane_addr,
    output wire [767:0] read_weights,
    output wire [MAX_CHANNELS*32-1:0] bias_table,
    output wire [MAX_CHANNELS*25-1:0] affine_table
);
    // One per-layer table, not a copy per request. The engine owns the
    // write lease and forbids any load until requests AND results drain.
    for(genvar channel=0;channel<MAX_CHANNELS;channel=channel+1) begin : g_parameter
        logic [31:0] bias_q;
        logic [24:0] affine_q;
        always_ff @(posedge clk) if(!rst && load_valid && load_addr==channel) begin
            if(load_kind==2) bias_q<=load_data;
            if(load_kind==3) affine_q<=load_data[24:0];
        end
        assign bias_table[channel*32+:32]=bias_q;
        assign affine_table[channel*25+:25]=affine_q;
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
    initial if(MAX_CHANNELS!=24 && MAX_CHANNELS!=48) $fatal(1,"C37 capacity must be 24/48 channels");
    initial if(PACKED!=0 && PACKED!=1) $fatal(1,"R2 weight replica packing must be 0/1");
    always @(posedge clk) if(!rst) begin
        if(load_valid && read_en) $fatal(1,"R2 shared parameters read/write owner collision");
        if(load_valid && load_kind==1 && {load_addr[7:5],load_addr[10:8]}>=MAX_CHANNELS) $fatal(1,"R2 invalid weight channel group");
        if(load_valid && load_kind>=2 && load_addr>=MAX_CHANNELS) $fatal(1,"R2 invalid affine channel");
        if(load_valid && load_kind==3 && (load_data[31:25]!=0 || load_data[23:18]>47)) $fatal(1,"R2 invalid affine fields");
        if(read_en) begin
            for(integer l=0;l<6;l=l+1) if({lane_addr[l*9+3+:3],lane_addr[l*9+6+:3]}>=MAX_CHANNELS) $fatal(1,"R2 invalid lane read group");
        end
    end
`endif
endmodule
