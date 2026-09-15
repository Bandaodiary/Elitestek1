`timescale 1ns/1ps
// C13 normal-DDR CPU seam. One read and one write transaction independently
// outstanding; restore the complete upstream ID over the ordered ID-0 port.
// 128-bit data is NOT narrowed/repacked. Aligned INCR sizes 1..16 bytes,
// arbitrary byte strobes inside the addressed lanes, <=256 beats, one 4KiB
// page and the configured DDR window are supported. No exclusive/atomic or
// nonzero REGION semantics. Such commands receive local DECERR, not fake OKAY.
// CACHE/PROT/QOS are deliberately absent: connect only to the normal,
// noncoherent DDR path without protection/firewall side effects. This adapter
// is not a transparent arbitrary-AXI bridge or a cache-maintenance engine.
module c1_r2_cpu_axi_adapter #(
    parameter integer ID_WIDTH=8,
    parameter logic [31:0] DDR_BASE=0,DDR_LIMIT=32'h10000000
) (
    input wire clk,rst,
    input wire [ID_WIDTH-1:0] s_arid,s_awid,
    input wire [31:0] s_araddr,s_awaddr,
    input wire [7:0] s_arlen,s_awlen,
    input wire [2:0] s_arsize,s_awsize,
    input wire [1:0] s_arburst,s_awburst,
    input wire s_arlock,s_awlock,
    input wire [3:0] s_arregion,s_awregion,
    input wire s_arvalid,s_awvalid,
    output wire s_arready,s_awready,
    output wire [ID_WIDTH-1:0] s_rid,s_bid,
    output wire [127:0] s_rdata,
    output wire [1:0] s_rresp,s_bresp,
    output wire s_rlast,s_rvalid,s_bvalid,
    input wire s_rready,s_bready,
    input wire [127:0] s_wdata,
    input wire [15:0] s_wstrb,
    input wire s_wlast,s_wvalid,
    output wire s_wready,
    output wire [31:0] m_araddr,m_awaddr,
    output wire [7:0] m_arlen,m_awlen,
    output wire [2:0] m_arsize,m_awsize,
    output wire [1:0] m_arburst,m_awburst,
    output wire m_arvalid,m_awvalid,
    input wire m_arready,m_awready,
    input wire [127:0] m_rdata,
    input wire [1:0] m_rresp,m_bresp,
    input wire m_rlast,m_rvalid,m_bvalid,
    output wire m_rready,m_bready,
    output wire [127:0] m_wdata,
    output wire [15:0] m_wstrb,
    output wire m_wlast,m_wvalid,
    input wire m_wready,
    output wire busy,
    output logic protocol_error
);
    logic r_owned,r_sent,r_reject,r_pad,r_bad;
    logic w_owned,w_sent,w_reject,w_pad,w_bad;
    logic [ID_WIDTH-1:0] rid_q,wid_q;
    logic [31:0] raddr_q,waddr_q,wbeat_addr;
    logic [7:0] rlen_q,wlen_q;
    logic [2:0] rsize_q,wsize_q;
    logic [8:0] rleft,wleft;
    // A read beat is staged: upstream READY cannot disturb the physical
    // owner's retirement, and R payload/ID/LAST stay stable during a stall.
    logic rout_valid,rout_last;
    logic [127:0] rout_data;
    logic [1:0] rout_resp;
    wire rout_slot=!rout_valid || s_rready;
    function automatic valid_command(input [31:0] address,input [7:0] length,
                                     input [2:0] size,input [1:0] burst,
                                     input lock,input [3:0] region);
        reg [32:0] bytes,total_end;
        reg [31:0] align_mask;
        begin
            bytes=({25'd0,length}+33'd1)<<size;
            total_end={1'b0,address}+bytes;align_mask=(32'd1<<size)-1'b1;
            valid_command=size<=4 && burst==1 && !lock && region==0 &&
                          (address&align_mask)==0 && address>=DDR_BASE &&
                          total_end<={1'b0,DDR_LIMIT} &&
                          ({21'd0,address[11:0]}+bytes)<=33'd4096;
        end
    endfunction
    wire ar_take=s_arvalid&&s_arready,aw_take=s_awvalid&&s_awready;
    assign s_arready=!rst && !protocol_error && !r_owned;
    assign s_awready=!rst && !protocol_error && !w_owned;
    assign busy=r_owned || w_owned;
    assign m_araddr=raddr_q;assign m_arlen=rlen_q;assign m_arsize=rsize_q;assign m_arburst=1;
    assign m_awaddr=waddr_q;assign m_awlen=wlen_q;assign m_awsize=wsize_q;assign m_awburst=1;
    // Do not withdraw an offered AR/AW if a different channel reports a
    // fault. Owned traffic drains; protocol_error blocks only new admission.
    assign m_arvalid=!rst && r_owned && !r_reject && !r_sent;
    assign m_awvalid=!rst && w_owned && !w_reject && !w_sent;
    assign m_rready=!rst && r_owned && r_sent && !r_pad && rleft!=0 && rout_slot;
    wire r_take=m_rvalid&&m_rready;
    wire r_fill=!rst && r_owned && rleft!=0 && rout_slot && (r_reject || r_pad || r_take);
    assign s_rid=rid_q;assign s_rdata=rout_data;assign s_rresp=rout_resp;
    assign s_rlast=rout_last;assign s_rvalid=!rst && rout_valid;
    // W may precede downstream AW acceptance. Waiting for AWREADY here would
    // deadlock with a legal slave that first waits for WVALID (or all W data).
    function automatic [15:0] byte_lanes(input [2:0] size);
        case(size)0:byte_lanes=16'h1;1:byte_lanes=16'h3;2:byte_lanes=16'hf;
                   3:byte_lanes=16'hff;4:byte_lanes=16'hffff;default:byte_lanes=0;endcase
    endfunction
    wire [15:0] lane_mask=byte_lanes(wsize_q)<<wbeat_addr[3:0];
    assign m_wvalid=!rst && w_owned && !w_reject && wleft!=0 && (w_pad || s_wvalid);
    assign m_wdata=w_pad ? 128'd0 : s_wdata;
    assign m_wstrb=w_pad ? 16'd0 : s_wstrb&lane_mask;
    assign m_wlast=wleft==1;
    assign s_wready=!rst && w_owned && wleft!=0 && !w_pad && (w_reject || m_wready);
    wire w_take=!rst && w_owned && wleft!=0 &&
                (w_reject ? (w_pad || s_wvalid) : m_wvalid&&m_wready);
    assign s_bid=wid_q;
    assign s_bvalid=!rst && w_owned && wleft==0 && (w_reject || (w_sent&&m_bvalid));
    assign s_bresp=w_reject ? 2'b11 : (w_bad||m_bresp==2'b01) ? 2'b10 : m_bresp;
    assign m_bready=!rst && w_owned && !w_reject && w_sent && wleft==0 && s_bready;
    always_ff @(posedge clk)begin
        if(rst)begin
            r_owned<=0;r_sent<=0;r_reject<=0;r_pad<=0;r_bad<=0;
            w_owned<=0;w_sent<=0;w_reject<=0;w_pad<=0;w_bad<=0;
            rid_q<=0;wid_q<=0;raddr_q<=0;waddr_q<=0;wbeat_addr<=0;
            rlen_q<=0;wlen_q<=0;rsize_q<=0;wsize_q<=0;rleft<=0;wleft<=0;
            rout_valid<=0;rout_last<=0;rout_data<=0;rout_resp<=0;protocol_error<=0;
        end else begin
            if(rout_valid&&s_rready)begin
                rout_valid<=0;if(rout_last)r_owned<=0;
            end
            if(ar_take)begin
                r_owned<=1;r_sent<=0;r_pad<=0;r_bad<=0;
                r_reject<=!valid_command(s_araddr,s_arlen,s_arsize,s_arburst,s_arlock,s_arregion);
                rid_q<=s_arid;raddr_q<=s_araddr;rlen_q<=s_arlen;rsize_q<=s_arsize;
                rleft<={1'b0,s_arlen}+9'd1;
            end
            if(m_arvalid&&m_arready)r_sent<=1;
            if(r_fill)begin
                rout_valid<=1;rout_last<=rleft==1;rleft<=rleft-1'b1;
                rout_data<=(r_reject||r_pad) ? 128'd0 : m_rdata;
                rout_resp<=r_reject ? 2'b11 : (r_pad||r_bad||m_rlast!=(rleft==1)||m_rresp==2'b01) ? 2'b10 : m_rresp;
                if(r_take&&m_rlast!=(rleft==1))begin
                    r_bad<=1;protocol_error<=1;
                    if(m_rlast)r_pad<=1;
                end
                if(r_take&&m_rresp==2'b01)begin r_bad<=1;protocol_error<=1;end
            end
            if(aw_take)begin
                w_owned<=1;w_sent<=0;w_pad<=0;w_bad<=0;
                w_reject<=!valid_command(s_awaddr,s_awlen,s_awsize,s_awburst,s_awlock,s_awregion);
                wid_q<=s_awid;waddr_q<=s_awaddr;wbeat_addr<=s_awaddr;
                wlen_q<=s_awlen;wsize_q<=s_awsize;wleft<={1'b0,s_awlen}+9'd1;
            end
            if(m_awvalid&&m_awready)w_sent<=1;
            if(w_take)begin
                wleft<=wleft-1'b1;wbeat_addr<=wbeat_addr+(32'd1<<wsize_q);
                if(!w_pad && s_wlast!=(wleft==1))begin
                    w_bad<=1;protocol_error<=1;if(s_wlast)w_pad<=1;
                end
                if(!w_pad && !w_reject && (s_wstrb&~lane_mask)!=0)begin w_bad<=1;protocol_error<=1;end
            end
            if(s_bvalid&&s_bready)w_owned<=0;
            if(m_rvalid&&(!r_owned||r_reject||(!r_sent&&!(m_arvalid&&m_arready))||r_pad||rleft==0))protocol_error<=1;
            if(m_bvalid&&(!w_owned||w_reject||(!w_sent&&!(m_awvalid&&m_awready))||
                          (wleft!=0&&!(wleft==1&&w_take))))begin
                protocol_error<=1;if(w_owned)w_bad<=1;
            end
            if(m_bvalid&&m_bresp==2'b01)begin protocol_error<=1;if(w_owned)w_bad<=1;end
        end
    end
`ifndef SYNTHESIS
    initial if(ID_WIDTH<1||ID_WIDTH>16||DDR_BASE>=DDR_LIMIT)$fatal(1,"CPU adapter parameter range");
    always @(posedge clk)if(!rst)begin
        if(s_bvalid&&wleft!=0)$fatal(1,"CPU B before W drain");
        if(s_rvalid&&s_rready&&s_rlast&&rleft!=0)$fatal(1,"CPU read completed before owned row drain");
    end
`endif
endmodule
