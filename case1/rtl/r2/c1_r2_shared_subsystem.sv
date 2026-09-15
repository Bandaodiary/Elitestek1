`timescale 1ns/1ps
// C10 CPU-controlled CNN + shared ID-less/ID-0 DDR fabric. External ports
// are normalized 128-bit masters, conventionally capture/display/CPU data.
// They are NOT CSI/HDMI pins, width converters, DMA engines or a DDR PHY.
module c1_r2_shared_subsystem #(
    parameter integer EXTERNAL_CLIENTS=3,FIFO_DEPTH=8
) (
    input wire clk,rst,psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    input wire [3:0] pstrb,
    output wire [31:0] prdata,
    output wire pready,pslverr,irq,busy,
    input wire capture_busy,display_busy,
    input wire [31:0] capture_base,display_base,
    output wire publish_valid,
    input wire publish_ready,
    output wire [31:0] publish_base,publish_tag,
    output wire [10:0] publish_width,
    output wire [9:0] publish_height,
    output wire fabric_error,
    output wire [7:0] physical_read_outstanding,physical_write_outstanding,
    input wire [EXTERNAL_CLIENTS-1:0][31:0] x_araddr,
    input wire [EXTERNAL_CLIENTS-1:0][7:0] x_arlen,
    input wire [EXTERNAL_CLIENTS-1:0][2:0] x_arsize,
    input wire [EXTERNAL_CLIENTS-1:0][1:0] x_arburst,
    input wire [EXTERNAL_CLIENTS-1:0] x_arvalid,
    output wire [EXTERNAL_CLIENTS-1:0] x_arready,
    output wire [EXTERNAL_CLIENTS-1:0][127:0] x_rdata,
    output wire [EXTERNAL_CLIENTS-1:0][1:0] x_rresp,
    output wire [EXTERNAL_CLIENTS-1:0] x_rlast,
    output wire [EXTERNAL_CLIENTS-1:0] x_rvalid,
    input wire [EXTERNAL_CLIENTS-1:0] x_rready,
    input wire [EXTERNAL_CLIENTS-1:0][31:0] x_awaddr,
    input wire [EXTERNAL_CLIENTS-1:0][7:0] x_awlen,
    input wire [EXTERNAL_CLIENTS-1:0][2:0] x_awsize,
    input wire [EXTERNAL_CLIENTS-1:0][1:0] x_awburst,
    input wire [EXTERNAL_CLIENTS-1:0] x_awvalid,
    output wire [EXTERNAL_CLIENTS-1:0] x_awready,
    input wire [EXTERNAL_CLIENTS-1:0][127:0] x_wdata,
    input wire [EXTERNAL_CLIENTS-1:0][15:0] x_wstrb,
    input wire [EXTERNAL_CLIENTS-1:0] x_wlast,
    input wire [EXTERNAL_CLIENTS-1:0] x_wvalid,
    output wire [EXTERNAL_CLIENTS-1:0] x_wready,
    output wire [EXTERNAL_CLIENTS-1:0][1:0] x_bresp,
    output wire [EXTERNAL_CLIENTS-1:0] x_bvalid,
    input wire [EXTERNAL_CLIENTS-1:0] x_bready,
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
    wire [EXTERNAL_CLIENTS:0][31:0] s_araddr;
    wire [EXTERNAL_CLIENTS:0][7:0] s_arlen;
    wire [EXTERNAL_CLIENTS:0][2:0] s_arsize;
    wire [EXTERNAL_CLIENTS:0][1:0] s_arburst;
    wire [EXTERNAL_CLIENTS:0] s_arvalid;
    wire [EXTERNAL_CLIENTS:0] s_arready;
    wire [EXTERNAL_CLIENTS:0][127:0] s_rdata;
    wire [EXTERNAL_CLIENTS:0][1:0] s_rresp;
    wire [EXTERNAL_CLIENTS:0] s_rlast;
    wire [EXTERNAL_CLIENTS:0] s_rvalid;
    wire [EXTERNAL_CLIENTS:0] s_rready;
    wire [EXTERNAL_CLIENTS:0][31:0] s_awaddr;
    wire [EXTERNAL_CLIENTS:0][7:0] s_awlen;
    wire [EXTERNAL_CLIENTS:0][2:0] s_awsize;
    wire [EXTERNAL_CLIENTS:0][1:0] s_awburst;
    wire [EXTERNAL_CLIENTS:0] s_awvalid;
    wire [EXTERNAL_CLIENTS:0] s_awready;
    wire [EXTERNAL_CLIENTS:0][127:0] s_wdata;
    wire [EXTERNAL_CLIENTS:0][15:0] s_wstrb;
    wire [EXTERNAL_CLIENTS:0] s_wlast;
    wire [EXTERNAL_CLIENTS:0] s_wvalid;
    wire [EXTERNAL_CLIENTS:0] s_wready;
    wire [EXTERNAL_CLIENTS:0][1:0] s_bresp;
    wire [EXTERNAL_CLIENTS:0] s_bvalid;
    wire [EXTERNAL_CLIENTS:0] s_bready;
    assign s_araddr[EXTERNAL_CLIENTS:1]=x_araddr;
    assign s_arlen[EXTERNAL_CLIENTS:1]=x_arlen;
    assign s_arsize[EXTERNAL_CLIENTS:1]=x_arsize;
    assign s_arburst[EXTERNAL_CLIENTS:1]=x_arburst;
    assign s_arvalid[EXTERNAL_CLIENTS:1]=x_arvalid;
    assign x_arready=s_arready[EXTERNAL_CLIENTS:1];
    assign x_rdata=s_rdata[EXTERNAL_CLIENTS:1];
    assign x_rresp=s_rresp[EXTERNAL_CLIENTS:1];
    assign x_rlast=s_rlast[EXTERNAL_CLIENTS:1];
    assign x_rvalid=s_rvalid[EXTERNAL_CLIENTS:1];
    assign s_rready[EXTERNAL_CLIENTS:1]=x_rready;
    assign s_awaddr[EXTERNAL_CLIENTS:1]=x_awaddr;
    assign s_awlen[EXTERNAL_CLIENTS:1]=x_awlen;
    assign s_awsize[EXTERNAL_CLIENTS:1]=x_awsize;
    assign s_awburst[EXTERNAL_CLIENTS:1]=x_awburst;
    assign s_awvalid[EXTERNAL_CLIENTS:1]=x_awvalid;
    assign x_awready=s_awready[EXTERNAL_CLIENTS:1];
    assign s_wdata[EXTERNAL_CLIENTS:1]=x_wdata;
    assign s_wstrb[EXTERNAL_CLIENTS:1]=x_wstrb;
    assign s_wlast[EXTERNAL_CLIENTS:1]=x_wlast;
    assign s_wvalid[EXTERNAL_CLIENTS:1]=x_wvalid;
    assign x_wready=s_wready[EXTERNAL_CLIENTS:1];
    assign x_bresp=s_bresp[EXTERNAL_CLIENTS:1];
    assign x_bvalid=s_bvalid[EXTERNAL_CLIENTS:1];
    assign s_bready[EXTERNAL_CLIENTS:1]=x_bready;
    wire graph_start_valid,graph_start_ready,graph_done_valid,graph_done_ready,graph_done_error,graph_busy,graph_protocol_error;
    wire [31:0] graph_cycles,input_base,workspace_base,output_base,parameter_base;
    wire [10:0] frame_width;wire [9:0] frame_height;
    wire [7:0] read_outstanding,write_outstanding;
    wire [4:0] active_stage,stage_done_index;wire stage_done;
    wire interconnect_error;
    assign fabric_error=interconnect_error || graph_protocol_error;
    c1_r2_apb_job_control u_control(.*);
    c1_r2_microstyle_axi_graph u_cnn (
        .clk(clk),.rst(rst),.start_valid(graph_start_valid),.start_ready(graph_start_ready),
        .frame_width(frame_width),.frame_height(frame_height),.input_base(input_base),.workspace_base(workspace_base),.output_base(output_base),.parameter_base(parameter_base),
        .busy(graph_busy),.done_valid(graph_done_valid),.done_ready(graph_done_ready),.done_error(graph_done_error),.frame_cycles(graph_cycles),
        .stage_done(stage_done),.stage_done_index(stage_done_index),.active_stage(active_stage),
        .protocol_error(graph_protocol_error),.read_outstanding(read_outstanding),.write_outstanding(write_outstanding),
        .m_axi_arid(),.m_axi_awid(),.m_axi_arlock(),.m_axi_arcache(),.m_axi_arqos(),.m_axi_arprot(),
        .m_axi_awlock(),.m_axi_awcache(),.m_axi_awqos(),.m_axi_awprot(),.m_axi_rid(m_axi_rid),.m_axi_bid(m_axi_bid),
        .m_axi_araddr(s_araddr[0]),
        .m_axi_arlen(s_arlen[0]),
        .m_axi_arsize(s_arsize[0]),
        .m_axi_arburst(s_arburst[0]),
        .m_axi_arvalid(s_arvalid[0]),
        .m_axi_arready(s_arready[0]),
        .m_axi_rdata(s_rdata[0]),
        .m_axi_rresp(s_rresp[0]),
        .m_axi_rlast(s_rlast[0]),
        .m_axi_rvalid(s_rvalid[0]),
        .m_axi_rready(s_rready[0]),
        .m_axi_awaddr(s_awaddr[0]),
        .m_axi_awlen(s_awlen[0]),
        .m_axi_awsize(s_awsize[0]),
        .m_axi_awburst(s_awburst[0]),
        .m_axi_awvalid(s_awvalid[0]),
        .m_axi_awready(s_awready[0]),
        .m_axi_wdata(s_wdata[0]),
        .m_axi_wstrb(s_wstrb[0]),
        .m_axi_wlast(s_wlast[0]),
        .m_axi_wvalid(s_wvalid[0]),
        .m_axi_wready(s_wready[0]),
        .m_axi_bresp(s_bresp[0]),
        .m_axi_bvalid(s_bvalid[0]),
        .m_axi_bready(s_bready[0])
    );
    c1_r2_axi_fabric #(.CLIENTS(EXTERNAL_CLIENTS+1),.FIFO_DEPTH(FIFO_DEPTH)) u_fabric (
        .clk(clk),.rst(rst),.protocol_error(interconnect_error),
        .physical_read_outstanding(physical_read_outstanding),.physical_write_outstanding(physical_write_outstanding),
        .s_araddr(s_araddr),
        .s_arlen(s_arlen),
        .s_arsize(s_arsize),
        .s_arburst(s_arburst),
        .s_arvalid(s_arvalid),
        .s_arready(s_arready),
        .s_rdata(s_rdata),
        .s_rresp(s_rresp),
        .s_rlast(s_rlast),
        .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .s_awaddr(s_awaddr),
        .s_awlen(s_awlen),
        .s_awsize(s_awsize),
        .s_awburst(s_awburst),
        .s_awvalid(s_awvalid),
        .s_awready(s_awready),
        .s_wdata(s_wdata),
        .s_wstrb(s_wstrb),
        .s_wlast(s_wlast),
        .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bresp(s_bresp),
        .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_awid(m_axi_awid),
        .m_axi_rid(m_axi_rid),
        .m_axi_bid(m_axi_bid),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awprot(m_axi_awprot)
    );
endmodule
