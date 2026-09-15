`timescale 1ns/1ps
// C10 normalized ID-0 fabric; reuse R1 arbiters unchanged. A future CPU AXI
// port with multiple IDs needs an ID-preserving adapter, not silent ID loss.
module c1_r2_axi_fabric #(
    parameter integer CLIENTS=4,FIFO_DEPTH=8
) (
    input wire clk,rst,
    input wire [CLIENTS-1:0][31:0] s_araddr,
    input wire [CLIENTS-1:0][7:0] s_arlen,
    input wire [CLIENTS-1:0][2:0] s_arsize,
    input wire [CLIENTS-1:0][1:0] s_arburst,
    input wire [CLIENTS-1:0] s_arvalid,
    output wire [CLIENTS-1:0] s_arready,
    output wire [CLIENTS-1:0][127:0] s_rdata,
    output wire [CLIENTS-1:0][1:0] s_rresp,
    output wire [CLIENTS-1:0] s_rlast,
    output wire [CLIENTS-1:0] s_rvalid,
    input wire [CLIENTS-1:0] s_rready,
    input wire [CLIENTS-1:0][31:0] s_awaddr,
    input wire [CLIENTS-1:0][7:0] s_awlen,
    input wire [CLIENTS-1:0][2:0] s_awsize,
    input wire [CLIENTS-1:0][1:0] s_awburst,
    input wire [CLIENTS-1:0] s_awvalid,
    output wire [CLIENTS-1:0] s_awready,
    input wire [CLIENTS-1:0][127:0] s_wdata,
    input wire [CLIENTS-1:0][15:0] s_wstrb,
    input wire [CLIENTS-1:0] s_wlast,
    input wire [CLIENTS-1:0] s_wvalid,
    output wire [CLIENTS-1:0] s_wready,
    output wire [CLIENTS-1:0][1:0] s_bresp,
    output wire [CLIENTS-1:0] s_bvalid,
    input wire [CLIENTS-1:0] s_bready,
    output wire protocol_error,
    output wire [7:0] physical_read_outstanding,physical_write_outstanding,
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
    wire read_error,write_error;
    logic id_error;
    assign protocol_error=read_error || write_error || id_error;
    assign m_axi_arid=0;assign m_axi_awid=0;
    assign m_axi_arlock=0;assign m_axi_arcache=0;assign m_axi_arqos=0;assign m_axi_arprot=0;
    assign m_axi_awlock=0;assign m_axi_awcache=0;assign m_axi_awqos=0;assign m_axi_awprot=0;
    // Track physical debt using independent handshakes and a tiny ARLEN ring.
    // Do not export the legacy write perf_outstanding (local descriptors) as
    // a physical count. Missing/early LAST uses the same bounded boundary.
    localparam PW=$clog2(FIFO_DEPTH),CW=$clog2(FIFO_DEPTH+1);
    logic [CW-1:0] reads,writes;
    logic [PW-1:0] rh,rt;
    logic [7:0] lengths[0:FIFO_DEPTH-1],rpos;
    wire ar_fire=m_axi_arvalid && m_axi_arready,aw_fire=m_axi_awvalid && m_axi_awready;
    wire r_fire=m_axi_rvalid && m_axi_rready;
    wire r_retire=r_fire && reads!=0 && (m_axi_rlast || rpos==lengths[rh]);
    wire b_retire=m_axi_bvalid && m_axi_bready && writes!=0;
    assign physical_read_outstanding=reads;assign physical_write_outstanding=writes;
    function automatic [PW-1:0] advance(input [PW-1:0] p);
        advance=p==FIFO_DEPTH-1 ? 0 : p+1'b1;
    endfunction
    always_ff @(posedge clk) begin
        if(rst) begin reads<=0;writes<=0;rh<=0;rt<=0;rpos<=0;id_error<=0;end
        else begin
            if(ar_fire) begin lengths[rt]<=m_axi_arlen;rt<=advance(rt);end
            if(r_retire) begin rh<=advance(rh);rpos<=0;end
            else if(r_fire && reads!=0) rpos<=rpos+1'b1;
            case({ar_fire,r_retire}) 2'b10:reads<=reads+1'b1;2'b01:reads<=reads-1'b1;default:begin end endcase
            case({aw_fire,b_retire}) 2'b10:writes<=writes+1'b1;2'b01:writes<=writes-1'b1;default:begin end endcase
            if(m_axi_rvalid && m_axi_rid!=0 || m_axi_bvalid && m_axi_bid!=0) id_error<=1;
        end
    end
    c1_axi_n_read_burst_arbiter_128 #(.CLIENTS(CLIENTS),.FIFO_DEPTH(FIFO_DEPTH),.EMPTY_AR_BYPASS(1)) u_read (
        .clk(clk),.rst(rst),
        .s_araddr(s_araddr),.m_araddr(m_axi_araddr),
        .s_arlen(s_arlen),.m_arlen(m_axi_arlen),
        .s_arsize(s_arsize),.m_arsize(m_axi_arsize),
        .s_arburst(s_arburst),.m_arburst(m_axi_arburst),
        .s_arvalid(s_arvalid),.m_arvalid(m_axi_arvalid),
        .s_arready(s_arready),.m_arready(m_axi_arready),
        .s_rdata(s_rdata),.m_rdata(m_axi_rdata),
        .s_rresp(s_rresp),.m_rresp(m_axi_rresp),
        .s_rlast(s_rlast),.m_rlast(m_axi_rlast),
        .s_rvalid(s_rvalid),.m_rvalid(m_axi_rvalid),
        .s_rready(s_rready),.m_rready(m_axi_rready),
        .protocol_error(read_error),.early_rlast_error(),.missing_rlast_error(),.orphan_r_error()
    );
    c1_axi_n_write_burst_arbiter_128 #(.CLIENTS(CLIENTS),.FIFO_DEPTH(FIFO_DEPTH),.EMPTY_AW_BYPASS(1),.W_AHEAD_OF_B(1)) u_write (
        .clk(clk),.rst(rst),
        .s_awaddr(s_awaddr),.m_awaddr(m_axi_awaddr),
        .s_awlen(s_awlen),.m_awlen(m_axi_awlen),
        .s_awsize(s_awsize),.m_awsize(m_axi_awsize),
        .s_awburst(s_awburst),.m_awburst(m_axi_awburst),
        .s_awvalid(s_awvalid),.m_awvalid(m_axi_awvalid),
        .s_awready(s_awready),.m_awready(m_axi_awready),
        .s_wdata(s_wdata),.m_wdata(m_axi_wdata),
        .s_wstrb(s_wstrb),.m_wstrb(m_axi_wstrb),
        .s_wlast(s_wlast),.m_wlast(m_axi_wlast),
        .s_wvalid(s_wvalid),.m_wvalid(m_axi_wvalid),
        .s_wready(s_wready),.m_wready(m_axi_wready),
        .s_bresp(s_bresp),.m_bresp(m_axi_bresp),
        .s_bvalid(s_bvalid),.m_bvalid(m_axi_bvalid),
        .s_bready(s_bready),.m_bready(m_axi_bready),
        .protocol_error(write_error),.early_wlast_error(),.missing_wlast_error(),.early_b_error(),.orphan_b_error(),
        .perf_outstanding(),.perf_max_outstanding(),.perf_aw_accept_count(),.perf_aw_issue_count(),.perf_w_beat_count(),.perf_b_count(),
        .write_busy(),.write_quiescent(),.write_owner(),.write_data_busy(),.write_data_owner()
    );
`ifndef SYNTHESIS
    initial if(CLIENTS<2 || FIFO_DEPTH<2 || FIFO_DEPTH>16) $fatal(1,"R2 fabric parameter range");
    always @(posedge clk) if(!rst && (reads>FIFO_DEPTH || writes>FIFO_DEPTH)) $fatal(1,"fabric physical debt overflow");
`endif
endmodule
