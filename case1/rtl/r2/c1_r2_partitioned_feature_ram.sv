`timescale 1ns/1ps
// C35 candidate. Same 8 x 512 x 32 SDP memories as the retained overlay.
// Spatial half=address[0], slot=address[9:1]; linear interpretation unchanged.
// Partitioned mode: spatial addresses map below partition_base, and linear
// accesses lie in [partition_base, partition_end). The single read port is
// still exclusive. A read and an OTHER-view write may coexist in disjoint
// partitions; two writers or same-view read/refill remain forbidden.
// Configuration is stable for a partition_en lease. Leaving this mode
// requires an ordinary refill before a fallback view can be read.
module c1_r2_partitioned_feature_ram (
    input wire clk,rst,
    input wire partition_en,
    input wire [8:0] partition_base,
    input wire [9:0] partition_end,
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
    always_ff @(posedge clk) if(!rst && spatial_rd_en)
        spatial_half_q<={spatial_rd_addr[10],spatial_rd_addr[0]};
    assign linear_rd_data=data;
    for(genvar bank=0;bank<2;bank=bank+1)begin : g_view
        assign spatial_rd_data[bank*64+:64]=spatial_half_q[bank] ? data[bank*128+64+:64] : data[bank*128+:64];
    end
    for(genvar id=0;id<8;id=id+1)begin : g_ram
        localparam integer BANK=id/4,HALF=(id/2)%2,WORD=id%2;
        wire spatial_we=spatial_wr_en && spatial_wr_addr[0]==HALF;
        c1_ram_sdp_read_first #(.DATA_WIDTH(32),.DEPTH(512),.ADDR_WIDTH(9)) u_ram (
            .clk(clk),.rd_en(!rst && (linear_rd_en || spatial_rd_en)),
            .rd_addr(linear_rd_en ? linear_rd_addr[BANK*9+:9] : spatial_rd_addr[BANK*10+1+:9]),
            .rd_data(data[id*32+:32]),
            .wr_en(!rst && (linear_wr_en[id] || spatial_we)),
            .wr_addr(linear_wr_en[id] ? linear_wr_addr[id*9+:9] : spatial_wr_addr[9:1]),
            .wr_data(linear_wr_en[id] ? linear_wr_data[id*32+:32] : spatial_wr_data[BANK*64+WORD*32+:32])
        );
    end
`ifndef SYNTHESIS
    // These are contract checks, not hardware access protection or cache
    // valid bits. The row controller must prove refill/publication ownership.
    // Like the retained RAM, contents and debug ownership survive warm reset.
    bit owner_known=0,owner_linear=0,partition_dirty=0,lease_known=0;
    reg [8:0] lease_base;
    reg [9:0] lease_end;
    always @(posedge clk)if(!rst)begin
        if(linear_rd_en && spatial_rd_en)$fatal(1,"partition RAM two readers");
        if(|linear_wr_en && spatial_wr_en)$fatal(1,"partition RAM two writers");
        if((linear_rd_en && |linear_wr_en) || (spatial_rd_en && spatial_wr_en))
            $fatal(1,"partition RAM same-view read/refill");
        if(partition_en)begin
            if(partition_base==0 || partition_end<=partition_base || partition_end>512)
                $fatal(1,"partition RAM invalid bounds");
            if(lease_known && (lease_base!=partition_base || lease_end!=partition_end))
                $fatal(1,"partition RAM changed active lease");
            lease_known=1;lease_base=partition_base;lease_end=partition_end;
            for(integer b=0;b<2;b=b+1)begin
                if(linear_rd_en && (linear_rd_addr[b*9+:9]<partition_base || {1'b0,linear_rd_addr[b*9+:9]}>=partition_end))
                    $fatal(1,"partition RAM linear read outside shadow");
                if(spatial_rd_en && spatial_rd_addr[b*10+1+:9]>=partition_base)
                    $fatal(1,"partition RAM spatial read outside source");
            end
            for(integer id=0;id<8;id=id+1)
                if(linear_wr_en[id] && (linear_wr_addr[id*9+:9]<partition_base || {1'b0,linear_wr_addr[id*9+:9]}>=partition_end))
                    $fatal(1,"partition RAM linear write outside shadow");
            if(spatial_wr_en && spatial_wr_addr[9:1]>=partition_base)
                $fatal(1,"partition RAM spatial write outside source");
            if(linear_rd_en || spatial_rd_en || |linear_wr_en || spatial_wr_en)partition_dirty=1;
        end else begin
            lease_known=0;
            if((linear_rd_en || |linear_wr_en) && (spatial_rd_en || spatial_wr_en))
                $fatal(1,"partition RAM fallback ownership collision");
            if(linear_rd_en && (partition_dirty || (owner_known && !owner_linear)))
                $fatal(1,"partition RAM linear view needs refill");
            if(spatial_rd_en && (partition_dirty || (owner_known && owner_linear)))
                $fatal(1,"partition RAM spatial view needs refill");
            if(|linear_wr_en)begin owner_known=1;owner_linear=1;partition_dirty=0;end
            if(spatial_wr_en)begin owner_known=1;owner_linear=0;partition_dirty=0;end
        end
    end
`endif
endmodule
