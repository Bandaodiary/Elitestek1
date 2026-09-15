`timescale 1ns/1ps
// C33 RGBX32 packing and logical/physical publication-credit conversion.
// C12 packing registers and its response/poisoning semantics are retained.
module c1_r2_rgbx_credit_row_write #(
    parameter integer BURST_BEATS=16,OUTSTANDING=4
) (
    input wire clk,rst,cmd_valid,cmd_rgbx,
    input wire issue_enable,
    input wire [15:0] published_beats,
    output wire [15:0] granted_beats,
    output wire cmd_ready,
    input wire [31:0] cmd_address,
    input wire [15:0] cmd_beats,
    input wire data_valid,
    output wire data_ready,
    input wire [127:0] data,
    input wire data_last,
    output wire response_valid,response_error,
    input wire response_ready,
    output wire busy,protocol_error,
    output wire [7:0] outstanding,
    output wire [3:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast,m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready
);
    // Only RGB input/output frames use RGBX32. Feature/parameter rows remain
    // exact P2C8. Two logical words become one physical word, with one 64-bit
    // half register and one elastic 128-bit register; no full-row extra RAM.
    // A malformed logical LAST poisons the row and locks new requests.
    // Already-owned physical writes drain (missing RGB tail is zero padded);
    // the caller must discard the whole row/frame and coordinate system reset.
    logic owned,rgbx_q,reject,half_valid,packed_valid,packed_last,padding,local_protocol,row_error;
    logic [15:0] remaining,physical_row_beats_q;
    wire [15:0] physical_granted;
    wire [15:0] physical_published=!owned || reject ? 16'd0 : padding ? physical_row_beats_q :
                                   rgbx_q ? {1'b0,published_beats[15:1]} : published_beats;
    assign granted_beats=!rst && owned && !reject ? (rgbx_q ? physical_granted<<1 : physical_granted) : 16'd0;
    logic [63:0] half_data;
    logic [127:0] packed_data;
    wire dma_busy,dma_protocol,dma_cmd_ready,dma_ready,dma_response,dma_error;
    wire [23:0] logical_end={1'b0,cmd_address[22:0]}+({8'd0,cmd_beats}<<4);
    wire rgbx_legal=cmd_address[4:0]==0 && cmd_beats!=0 && !cmd_beats[0] && logical_end<=24'h800000;
    wire reject_command=cmd_rgbx && !rgbx_legal;
    wire [31:0] physical_address=cmd_rgbx ? {cmd_address[31:23],1'b0,cmd_address[22:1]} : cmd_address;
    wire [15:0] physical_beats=cmd_rgbx ? {1'b0,cmd_beats[15:1]} : cmd_beats;
    assign protocol_error=dma_protocol || local_protocol;
    assign cmd_ready=!rst && !owned && !protocol_error && dma_cmd_ready;
    assign busy=owned || dma_busy;
    assign response_valid=!rst && owned && (reject || dma_response);
    assign response_error=reject || dma_error || row_error;
    wire pack_slot=!packed_valid || dma_ready;
    wire logical_slot=!half_valid || pack_slot;
    assign data_ready=!rst && owned && !reject &&
                      (rgbx_q ? remaining!=0 && !padding && logical_slot : dma_ready);
    wire pack_take=!rst && owned && !reject && rgbx_q && remaining!=0 && logical_slot && (padding || data_valid);
    wire [63:0] pair_data=padding ? 64'd0 : {8'd0,data[87:64],8'd0,data[23:0]};
    c1_r2_axi_credit_row_write #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_dma (
        .issue_enable(issue_enable || padding),.published_beats(physical_published),.granted_beats(physical_granted),
        .clk(clk),.rst(rst),.cmd_valid(cmd_valid && cmd_ready && !reject_command),.cmd_ready(dma_cmd_ready),
        .cmd_address(physical_address),.cmd_beats(physical_beats),
        .data_valid(owned && !reject && (rgbx_q ? packed_valid : data_valid)),.data_ready(dma_ready),
        .data(rgbx_q ? packed_data : data),.data_last(rgbx_q ? packed_last : data_last),
        .response_valid(dma_response),.response_ready(owned && !reject && response_ready),.response_error(dma_error),
        .busy(dma_busy),.protocol_error(dma_protocol),.outstanding(outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
    always_ff @(posedge clk)begin
        if(rst)begin
            owned<=0;rgbx_q<=0;reject<=0;half_valid<=0;packed_valid<=0;packed_last<=0;padding<=0;local_protocol<=0;row_error<=0;
            remaining<=0;half_data<=0;packed_data<=0;physical_row_beats_q<=0;
        end else begin
            if(packed_valid&&dma_ready)packed_valid<=0;
            if(cmd_valid&&cmd_ready)begin
                owned<=1;rgbx_q<=cmd_rgbx;reject<=reject_command;half_valid<=0;packed_valid<=0;padding<=0;row_error<=0;
                remaining<=cmd_beats;physical_row_beats_q<=physical_beats;
            end
            if(pack_take)begin
                remaining<=remaining-1'b1;
                if(!half_valid)begin half_data<=pair_data;half_valid<=1;end
                else begin packed_data<={pair_data,half_data};packed_valid<=1;packed_last<=remaining==1;half_valid<=0;end
                if(!padding && data_last!=(remaining==1))begin
                    local_protocol<=1;row_error<=1;
                    if(data_last)padding<=1;
                end
            end
            if(response_valid&&response_ready)begin owned<=0;reject<=0;end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(!rst)begin
        if(response_valid && (outstanding!=0 || packed_valid || half_valid))$fatal(1,"RGBX writer completed before physical drain");
        if(pack_take && remaining==1 && !half_valid)$fatal(1,"RGBX incomplete logical pixel quad");
    end
`endif
endmodule
