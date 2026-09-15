`timescale 1ns/1ps
// C12 reversible RGB frame packing boundary; C9 DMA remains unchanged.
module c1_r2_rgbx_row_read #(
    parameter integer BURST_BEATS=16,OUTSTANDING=4
) (
    input wire clk,rst,cmd_valid,cmd_rgbx,
    output wire cmd_ready,
    input wire [31:0] cmd_address,
    input wire [15:0] cmd_beats,
    output wire data_valid,
    input wire data_ready,
    output wire [127:0] data,
    output wire data_last,data_error,
    output wire busy,protocol_error,
    output wire [7:0] outstanding,
    output wire [3:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,m_axi_rvalid,
    output wire m_axi_rready
);
    // Logical RGB commands use the retained P2C8 address/beat convention.
    // Physical DDR holds RGBX32: four little-endian {0,B,G,R} pixels/128b.
    // Feature/parameter rows bypass the conversion without changing the ABI.
    logic owned,rgbx_q,upper,reject;
    wire dma_busy,dma_protocol,dma_cmd_ready,dma_valid,dma_last,dma_error;
    wire [127:0] dma_data;
    wire [23:0] logical_end={1'b0,cmd_address[22:0]}+({8'd0,cmd_beats}<<4);
    wire rgbx_legal=cmd_address[4:0]==0 && cmd_beats!=0 && !cmd_beats[0] && logical_end<=24'h800000;
    wire reject_command=cmd_rgbx && !rgbx_legal;
    wire [31:0] physical_address=cmd_rgbx ? {cmd_address[31:23],1'b0,cmd_address[22:1]} : cmd_address;
    wire [15:0] physical_beats=cmd_rgbx ? {1'b0,cmd_beats[15:1]} : cmd_beats;
    assign cmd_ready=!rst && !owned && !dma_protocol && dma_cmd_ready;
    assign busy=owned || dma_busy;assign protocol_error=dma_protocol;
    assign data_valid=!rst && owned && (reject || dma_valid);
    wire [63:0] pixel_pair=upper ? dma_data[127:64] : dma_data[63:0];
    assign data=reject ? 128'd0 : rgbx_q ? {40'd0,pixel_pair[55:32],40'd0,pixel_pair[23:0]} : dma_data;
    assign data_last=reject || (dma_last && (!rgbx_q || upper));
    assign data_error=reject || dma_error;
    wire physical_ready=owned && !reject && data_ready && (!rgbx_q || upper);
    c1_r2_axi_row_read #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_dma (
        .clk(clk),.rst(rst),.cmd_valid(cmd_valid && cmd_ready && !reject_command),.cmd_ready(dma_cmd_ready),
        .cmd_address(physical_address),.cmd_beats(physical_beats),
        .data_valid(dma_valid),.data_ready(physical_ready),.data(dma_data),.data_last(dma_last),.data_error(dma_error),
        .busy(dma_busy),.protocol_error(dma_protocol),.outstanding(outstanding),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready)
    );
    always_ff @(posedge clk)begin
        if(rst)begin owned<=0;rgbx_q<=0;upper<=0;reject<=0;end
        else begin
            if(cmd_valid&&cmd_ready)begin owned<=1;rgbx_q<=cmd_rgbx;upper<=0;reject<=reject_command;end
            if(data_valid&&data_ready)begin
                if(rgbx_q)upper<=!upper;
                if(data_last)begin owned<=0;reject<=0;end
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(!rst && data_valid&&data_ready&&data_last&&outstanding!=0)$fatal(1,"RGBX reader published before physical R drain");
`endif
endmodule
