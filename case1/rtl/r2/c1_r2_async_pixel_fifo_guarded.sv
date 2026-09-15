// C28 independent CDC-hardened candidate; retained C26 source is unchanged.
`timescale 1ns/1ps
// Dual-clock SDP RAM plus one read-domain output register. Capacity is DEPTH
// RAM words + one prefetched word. Read pointer releases a RAM location only
// when its data has been captured in that register. RAM contents are not reset.
// Coordinated reset of BOTH domains is mandatory; per-frame flush uses reads,
// never unilateral pointer reset. Gray buses require physical skew/delay bounds.
module c1_r2_async_pixel_fifo_guarded #(
    parameter integer DATA_WIDTH=24,DEPTH=1024,AW=$clog2(DEPTH)
) (
    input wire wr_clk,wr_rst,in_valid,
    output wire in_ready,
    input wire [DATA_WIDTH-1:0] in_data,
    output wire [AW:0] wr_level,
    input wire rd_clk,rd_rst,
    output logic out_valid,
    input wire out_ready,
    output logic [DATA_WIDTH-1:0] out_data,
    output wire rd_empty
);
    logic [DATA_WIDTH-1:0] memory[0:DEPTH-1];
    logic [AW:0] wr_bin,wr_gray,rd_bin,rd_gray;
    (* async_reg="true", syn_keep="true" *) logic [AW:0] rd_sync1,rd_sync2,wr_sync1,wr_sync2;
    logic full;
    wire push=in_valid && in_ready;
    wire [AW:0] wb_next=wr_bin+push;
    wire [AW:0] wg_next=(wb_next>>1)^wb_next;
    localparam [AW:0] FULL_MASK={2'b11,{(AW-1){1'b0}}};
    wire ram_empty=rd_gray==wr_sync2;
    wire load=!rd_rst && (!out_valid || out_ready) && !ram_empty;
    wire [AW:0] rb_next=rd_bin+load;
    wire [AW:0] rg_next=(rb_next>>1)^rb_next;
    function automatic [AW:0] binary(input [AW:0] gray);
        integer i;
        begin binary[AW]=gray[AW];for(i=AW-1;i>=0;i=i-1)binary[i]=binary[i+1]^gray[i];end
    endfunction
    assign in_ready=!wr_rst && !full;
    assign wr_level=wr_bin-binary(rd_sync2);
    // Includes pending RAM data and the elastic register; safe for drain ACK.
    assign rd_empty=!out_valid && ram_empty;
    always_ff @(posedge wr_clk)begin
        if(push)memory[wr_bin[AW-1:0]]<=in_data;
        if(wr_rst)begin wr_bin<=0;wr_gray<=0;full<=0;rd_sync1<=0;rd_sync2<=0;end
        else begin
            wr_bin<=wb_next;wr_gray<=wg_next;full<=wg_next==(rd_sync2^FULL_MASK);
            rd_sync1<=rd_gray;rd_sync2<=rd_sync1;
        end
    end
    // Data register has only an enable, not reset, allowing native SDP mapping.
    always_ff @(posedge rd_clk)if(load)out_data<=memory[rd_bin[AW-1:0]];
    always_ff @(posedge rd_clk)begin
        if(rd_rst)begin rd_bin<=0;rd_gray<=0;out_valid<=0;wr_sync1<=0;wr_sync2<=0;end
        else begin
            rd_bin<=rb_next;rd_gray<=rg_next;
            wr_sync1<=wr_gray;wr_sync2<=wr_sync1;
            if(load)out_valid<=1;
            else if(out_valid && out_ready)out_valid<=0;
        end
    end
`ifndef SYNTHESIS
    initial if(DATA_WIDTH<1 || DEPTH<2 || (DEPTH&(DEPTH-1))!=0 || AW!=$clog2(DEPTH))
        $fatal(1,"async pixel FIFO requires a power-of-two depth >= 2");
    always @(posedge wr_clk)if(!wr_rst && wr_level>DEPTH)$fatal(1,"async FIFO pointer overrun");
`endif
endmodule
