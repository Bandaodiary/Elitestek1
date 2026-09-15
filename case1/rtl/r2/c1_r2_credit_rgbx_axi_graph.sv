// C33 credit conversion at the physical write boundary. Read path and fences retained.
// C29 capacity candidate; retained C28 baseline unchanged.
// C22 independent feature-overlay branch; retained C21 sources unchanged.
// C21 independent six-lane weight branch; retained C18 sources unchanged.
// C18 independent generated-plan integration. Retained C12/C14/C15 RTL is unchanged.
`timescale 1ns/1ps
// C18 RGBX32 frame boundary around the generated-plan row executor.
// The C12 row DMA and its response/reset ownership contract are retained.
// Single ID (0), ordered responses, 128-bit full beats, no cache snooping.
// Tie into a system arbiter that preserves ID ownership; this is not an
// arbiter for CPU/camera/display and has no vendor DDR PHY or board pinout.
module c1_r2_credit_rgbx_axi_graph #(
    parameter integer BURST_BEATS=16,OUTSTANDING=4
) (
    input wire clk,rst,start_valid,
    output wire start_ready,
    input wire [10:0] frame_width,
    input wire [9:0] frame_height,
    input wire [31:0] input_base,workspace_base,output_base,parameter_base,
    output wire busy,done_valid,
    input wire done_ready,
    output wire done_error,
    output wire [31:0] frame_cycles,
    output wire stage_done,
    output wire [4:0] stage_done_index,active_stage,
    output wire protocol_error,
    output wire [7:0] read_outstanding,write_outstanding,
    output wire [3:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,m_axi_arqos,
    output wire [2:0] m_axi_arprot,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,m_axi_rvalid,
    output wire m_axi_rready,
    output wire [3:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,m_axi_awqos,
    output wire [2:0] m_axi_awprot,
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
    wire graph_ready,graph_busy,read_busy,write_busy,read_protocol_error,write_protocol_error;
    wire graph_start=start_valid && !protocol_error && !read_busy && !write_busy;
    assign start_ready=graph_ready && !protocol_error && !read_busy && !write_busy;
    assign protocol_error=read_protocol_error || write_protocol_error;
    assign m_axi_arlock=0;assign m_axi_arcache=0;assign m_axi_arqos=0;assign m_axi_arprot=0;
    assign m_axi_awlock=0;assign m_axi_awcache=0;assign m_axi_awqos=0;assign m_axi_awprot=0;
    wire rd_cmd_valid,rd_cmd_ready,rd_valid,rd_ready,rd_last,rd_error;
    wire wr_cmd_valid,wr_cmd_ready,wr_valid,wr_ready,wr_last,wr_response_valid,wr_response_ready,wr_response_error;
    wire [31:0] rd_cmd_address,wr_cmd_address;
    wire [15:0] rd_cmd_beats,wr_cmd_beats;
    wire wr_issue_enable;
    wire [15:0] wr_published_beats,wr_granted_beats;
    wire [127:0] rd_data,wr_data;
    // Snapshot slots with the job. Parameters/workspace bypass compression;
    // runtime CPU configuration changes cannot retarget the active frame.
    logic [8:0] input_slot_q,output_slot_q;
    always_ff @(posedge clk)begin
        if(rst)begin input_slot_q<=0;output_slot_q<=0;end
        else if(start_valid&&start_ready)begin input_slot_q<=input_base[31:23];output_slot_q<=output_base[31:23];end
    end
    // A malformed physical response locks the bus until SYSTEM reset, but
    // The row executor may already own another unsent writer page. Retire those LOCAL
    // rows with an error, never by issuing more traffic on a poisoned bus.
    // Rows already owned by a DMA still finish all accepted AXI obligations.
    logic reject_read;
    logic [1:0] reject_write; // 0 idle, 1 consume local row, 2 error response
    assign busy=graph_busy || read_busy || write_busy || reject_read || reject_write!=0;
    wire dma_rd_cmd_ready,dma_rd_valid,dma_rd_last,dma_rd_error;
    wire [127:0] dma_rd_data;
    wire dma_wr_cmd_ready,dma_wr_ready,dma_wr_response_valid,dma_wr_response_error;
    wire reject_read_ready=protocol_error && !read_busy && !reject_read;
    wire reject_write_ready=protocol_error && !write_busy && reject_write==0;
    assign rd_cmd_ready=protocol_error ? reject_read_ready : dma_rd_cmd_ready;
    assign rd_valid=reject_read || dma_rd_valid;
    assign rd_data=reject_read ? 128'd0 : dma_rd_data;
    assign rd_last=reject_read || dma_rd_last;
    assign rd_error=reject_read || dma_rd_error;
    assign wr_cmd_ready=protocol_error ? reject_write_ready : dma_wr_cmd_ready;
    assign wr_ready=reject_write==1 || (reject_write==0 && dma_wr_ready);
    assign wr_response_valid=reject_write==2 || dma_wr_response_valid;
    assign wr_response_error=reject_write==2 || dma_wr_response_error;
    always_ff @(posedge clk) begin
        if(rst) begin reject_read<=0;reject_write<=0;end
        else begin
            if(rd_cmd_valid && reject_read_ready) reject_read<=1;
            if(reject_read && rd_ready) reject_read<=0;
            if(wr_cmd_valid && reject_write_ready) reject_write<=1;
            if(reject_write==1 && wr_valid && wr_last) reject_write<=2;
            if(reject_write==2 && wr_response_ready) reject_write<=0;
        end
    end
    c1_r2_credit_pingpong_graph u_graph (
        .wr_issue_enable(wr_issue_enable),.wr_published_beats(wr_published_beats),
        .wr_granted_beats(wr_granted_beats),
        .clk(clk),.rst(rst),.start_valid(graph_start),.start_ready(graph_ready),
        .frame_width(frame_width),.frame_height(frame_height),.input_base(input_base),.workspace_base(workspace_base),.output_base(output_base),.parameter_base(parameter_base),
        .busy(graph_busy),.done_valid(done_valid),.done_ready(done_ready),.done_error(done_error),.frame_cycles(frame_cycles),
        .stage_done(stage_done),.stage_done_index(stage_done_index),.active_stage(active_stage),
        .rd_cmd_valid(rd_cmd_valid),.rd_cmd_ready(rd_cmd_ready),.rd_cmd_address(rd_cmd_address),.rd_cmd_beats(rd_cmd_beats),
        .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_data(rd_data),.rd_last(rd_last),.rd_error(rd_error),
        .wr_cmd_valid(wr_cmd_valid),.wr_cmd_ready(wr_cmd_ready),.wr_cmd_address(wr_cmd_address),.wr_cmd_beats(wr_cmd_beats),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),.wr_last(wr_last),
        .wr_response_valid(wr_response_valid),.wr_response_ready(wr_response_ready),.wr_response_error(wr_response_error)
    );
    c1_r2_rgbx_row_read #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_read (
        .clk(clk),.rst(rst),.cmd_valid(rd_cmd_valid && !protocol_error),.cmd_ready(dma_rd_cmd_ready),.cmd_address(rd_cmd_address),.cmd_beats(rd_cmd_beats),.cmd_rgbx(rd_cmd_address[31:23]==input_slot_q),
        .data_valid(dma_rd_valid),.data_ready(rd_ready && !reject_read),.data(dma_rd_data),.data_last(dma_rd_last),.data_error(dma_rd_error),
        .busy(read_busy),.protocol_error(read_protocol_error),.outstanding(read_outstanding),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready)
    );
    c1_r2_rgbx_credit_row_write #(.BURST_BEATS(BURST_BEATS),.OUTSTANDING(OUTSTANDING)) u_write (
        .issue_enable(wr_issue_enable),.published_beats(wr_published_beats),.granted_beats(wr_granted_beats),
        .clk(clk),.rst(rst),.cmd_valid(wr_cmd_valid && !protocol_error),.cmd_ready(dma_wr_cmd_ready),.cmd_address(wr_cmd_address),.cmd_beats(wr_cmd_beats),.cmd_rgbx(wr_cmd_address[31:23]==output_slot_q),
        .data_valid(wr_valid && reject_write==0),.data_ready(dma_wr_ready),.data(wr_data),.data_last(wr_last),
        .response_valid(dma_wr_response_valid),.response_ready(wr_response_ready && reject_write==0),.response_error(dma_wr_response_error),
        .busy(write_busy),.protocol_error(write_protocol_error),.outstanding(write_outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst && (done_valid || stage_done) && (read_busy || write_busy || reject_read || reject_write!=0)) $fatal(1,"AXI graph published before row DMA drain");
`endif
endmodule
