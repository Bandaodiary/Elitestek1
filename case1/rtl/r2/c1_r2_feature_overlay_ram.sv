`timescale 1ns/1ps
// C22: one physical 16KiB region, two mutually exclusive interpretations.
// Linear: two parity banks of 512x128. Spatial row0: two banks of 1024x64.
// Each 1024-depth spatial bank is split into two 512-depth halves; linear
// reads both halves as one 128-bit record. Refill before using a clobbered
// view. Outputs have a one-cycle RAM response and are only meaningful for
// the selected owner; the inactive view's payload need not remain stable.
module c1_r2_feature_overlay_ram (
    input wire clk,rst,
    input wire linear_rd_en,
    input wire [17:0] linear_rd_addr,
    output wire [255:0] linear_rd_data,
    input wire [7:0] linear_wr_en,
    input wire [71:0] linear_wr_addr,
    input wire [255:0] linear_wr_data,
    input wire spatial_rd_en,
    input wire [19:0] spatial_rd_addr,
    output wire [127:0] spatial_rd_data,
    input wire spatial_wr_en,
    input wire [9:0] spatial_wr_addr,
    input wire [127:0] spatial_wr_data
);
    wire [255:0] data;
    logic [1:0] spatial_half_q;
    always_ff @(posedge clk)if(!rst && spatial_rd_en)
        spatial_half_q<={spatial_rd_addr[19],spatial_rd_addr[9]};
    assign linear_rd_data=data;
    for(genvar bank=0;bank<2;bank=bank+1)begin : g_view
        assign spatial_rd_data[bank*64+:64]=spatial_half_q[bank] ? data[bank*128+64+:64] : data[bank*128+:64];
    end
    // Flattened indices for portable module-port slicing.
    for(genvar id=0;id<8;id=id+1)begin : g_ram
        localparam integer BANK=id/4,HALF=(id/2)%2,WORD=id%2;
        wire spatial_we=spatial_wr_en && spatial_wr_addr[9]==HALF;
        c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)) u_ram (
            .clk(clk),.rd_en(!rst && (linear_rd_en || spatial_rd_en)),
            .rd_addr(linear_rd_en ? linear_rd_addr[BANK*9+:9] : spatial_rd_addr[BANK*10+:9]),
            .rd_data(data[id*32+:32]),
            .wr_en(!rst && (linear_wr_en[id] || spatial_we)),
            .wr_addr(linear_wr_en[id] ? linear_wr_addr[id*9+:9] : spatial_wr_addr[8:0]),
            .wr_data(linear_wr_en[id] ? linear_wr_data[id*32+:32] : spatial_wr_data[BANK*64+WORD*32+:32])
        );
    end
`ifndef SYNTHESIS
    // Debug ownership follows retained SRAM contents through warm reset.
    bit owner_known=0,owner_linear=0;
    always @(posedge clk)if(!rst)begin
        if((linear_rd_en || |linear_wr_en) && (spatial_rd_en || spatial_wr_en))
            $fatal(1,"overlay linear/spatial ownership collision");
        if((linear_rd_en && |linear_wr_en) || (spatial_rd_en && spatial_wr_en))
            $fatal(1,"overlay read/refill overlap");
        if(linear_rd_en && owner_known && !owner_linear)$fatal(1,"overlay linear view needs refill");
        if(spatial_rd_en && owner_known && owner_linear)$fatal(1,"overlay spatial view needs refill");
        if(|linear_wr_en)begin owner_known=1;owner_linear=1;end
        if(spatial_wr_en)begin owner_known=1;owner_linear=0;end
    end
`endif
endmodule
