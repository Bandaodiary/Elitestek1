`timescale 1ns/1ps
// Simulation only. Ordered ID-0 slave with independent AR, AW, W and B
// cursors. Each physical burst pays LATENCY, not just each logical row.
// MEMORY_DIV limits aggregate R production + W acceptance (not two ports).
// Faults deliberately bounded: early RLAST drops that burst's remaining
// words; missing RLAST still returns exactly ARLEN+1. No arbitrary extras.
module c1_r2_axi_memory_bfm #(
    parameter integer BURST_BEATS=16,STALLS=0,MEMORY_DIV=0,LATENCY=20,Q=64,AW_WAIT_W=0
) (
    input wire clk,rst,clear_faults,
    input wire [2:0] inject_r, // 1 RESP, 2 early LAST, 3 missing LAST, 4 wrong ID
    input wire [1:0] inject_b, // 1 RESP, 2 wrong ID
    input wire hold_b,
    output logic fault_r_seen,fault_b_seen,
    input wire [3:0] m_axi_arid,
    input wire [31:0] m_axi_araddr,
    input wire [7:0] m_axi_arlen,
    input wire [2:0] m_axi_arsize,
    input wire [1:0] m_axi_arburst,
    input wire m_axi_arvalid,
    output wire m_axi_arready,
    output logic [3:0] m_axi_rid,
    output logic [127:0] m_axi_rdata,
    output logic [1:0] m_axi_rresp,
    output logic m_axi_rlast,m_axi_rvalid,
    input wire m_axi_rready,
    input wire [3:0] m_axi_awid,
    input wire [31:0] m_axi_awaddr,
    input wire [7:0] m_axi_awlen,
    input wire [2:0] m_axi_awsize,
    input wire [1:0] m_axi_awburst,
    input wire m_axi_awvalid,
    output wire m_axi_awready,
    input wire [127:0] m_axi_wdata,
    input wire [15:0] m_axi_wstrb,
    input wire m_axi_wlast,m_axi_wvalid,
    output wire m_axi_wready,
    output logic [3:0] m_axi_bid,
    output logic [1:0] m_axi_bresp,
    output logic m_axi_bvalid,
    input wire m_axi_bready,
    output wire service_read,
    output wire [31:0] service_read_address,
    input wire [127:0] service_read_data,
    output wire service_write,
    output wire [31:0] service_write_address,
    output wire idle,
    output integer ar_total,aw_total,r_total,w_total,b_total,peak_read,peak_write
);
    integer cycle=0,rhead=0,rtail=0,r_count=0,rpos=0;
    integer bhead=0,whead=0,wtail=0,w_count=0,b_count=0,wpos=0;
    integer rlen[0:Q-1],wlen[0:Q-1],r_due[0:Q-1],b_due[0:Q-1];
    reg [31:0] raddr[0:Q-1],waddr[0:Q-1];
    reg w_complete[0:Q-1];
    reg [31:0] random_q=32'h491716a3;
    reg prefer_write=0,r_end=0;
    // Mode 2 accepts a complete W burst before accepting its offered AW.
    // This adversarial slave uses stable AW payload for its scoreboard only;
    // no AW credit or B response exists until the actual AW handshake.
    integer early_position=0;
    reg early_complete=0;
    wire early_mode=AW_WAIT_W==2 && b_count==0 && w_count==0;
    wire slot=MEMORY_DIV==0 || cycle%(MEMORY_DIV==0 ? 1 : MEMORY_DIV)==0;
    wire r_take=m_axi_rvalid && m_axi_rready;
    wire r_pop=r_take && r_end;
    wire b_take=m_axi_bvalid && m_axi_bready;
    wire aw_take=m_axi_awvalid && m_axi_awready;
    wire ar_take=m_axi_arvalid && m_axi_arready;
    wire can_read=r_count!=0 && (!m_axi_rvalid || m_axi_rready) && !r_pop && cycle>=r_due[rhead];
    assign m_axi_arready=!rst && r_count<Q && (!STALLS || random_q[0]);
    assign m_axi_awready=!rst && b_count<Q && (!STALLS || random_q[1]) &&
                        (AW_WAIT_W==0 || (AW_WAIT_W==1 && m_axi_wvalid) || (AW_WAIT_W==2 && early_complete));
    assign m_axi_wready=!rst && (w_count!=0 || (early_mode && m_axi_awvalid && !early_complete)) && slot && (!STALLS || random_q[2]) &&
                        (MEMORY_DIV==0 || prefer_write || !can_read);
    assign service_write=m_axi_wvalid && m_axi_wready;
    assign service_write_address=early_mode ? m_axi_awaddr+early_position*32'd16 : waddr[whead]+wpos*32'd16;
    assign service_read=!rst && can_read && slot && (!STALLS || random_q[4:3]!=0) &&
                        (MEMORY_DIV==0 || !service_write);
    assign service_read_address=raddr[rhead]+(rpos+(r_take ? 1 : 0))*32'd16;
    assign idle=r_count==0 && w_count==0 && b_count==0 && !m_axi_rvalid && !m_axi_bvalid && early_position==0 && !early_complete;
    wire w_pop=service_write && m_axi_wlast && !early_mode;
    wire aw_w_push=aw_take && !early_complete;
    reg held_ar=0,held_aw=0,held_w=0,held_r=0,held_b=0;
    reg [48:0] old_ar,old_aw;
    reg [144:0] old_w;reg [134:0] old_r;reg [5:0] old_b;
    always @(posedge clk) begin : slave
        integer pos;reg physical_last,early,inject;
        if(rst) begin
            cycle<=0;rhead<=0;rtail<=0;r_count<=0;rpos<=0;bhead<=0;whead<=0;wtail<=0;w_count<=0;b_count<=0;wpos<=0;
            m_axi_rvalid<=0;m_axi_bvalid<=0;m_axi_rdata<=0;m_axi_rresp<=0;m_axi_rid<=0;m_axi_rlast<=0;m_axi_bresp<=0;m_axi_bid<=0;
            fault_r_seen<=0;fault_b_seen<=0;prefer_write<=0;r_end<=0;early_position<=0;early_complete<=0;
            ar_total<=0;aw_total<=0;r_total<=0;w_total<=0;b_total<=0;peak_read<=0;peak_write<=0;
            held_ar<=0;held_aw<=0;held_w<=0;held_r<=0;held_b<=0;
            for(integer i=0;i<Q;i=i+1) w_complete[i]<=0;
        end else begin
            cycle<=cycle+1;random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if(clear_faults) begin
                if(!idle) $fatal(1,"BFM clear faults while active");
                fault_r_seen<=0;fault_b_seen<=0;
            end
            if(held_ar && (!m_axi_arvalid || old_ar!=={m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst})) $fatal(1,"AR not held");
            if(held_aw && (!m_axi_awvalid || old_aw!=={m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst})) $fatal(1,"AW not held");
            if(held_w && (!m_axi_wvalid || old_w!=={m_axi_wlast,m_axi_wstrb,m_axi_wdata})) $fatal(1,"W not held");
            if(held_r && (!m_axi_rvalid || old_r!=={m_axi_rid,m_axi_rresp,m_axi_rlast,m_axi_rdata})) $fatal(1,"BFM R not held");
            if(held_b && (!m_axi_bvalid || old_b!=={m_axi_bid,m_axi_bresp})) $fatal(1,"BFM B not held");
            held_ar<=m_axi_arvalid && !m_axi_arready;old_ar<={m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
            held_aw<=m_axi_awvalid && !m_axi_awready;old_aw<={m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            held_w<=m_axi_wvalid && !m_axi_wready;old_w<={m_axi_wlast,m_axi_wstrb,m_axi_wdata};
            held_r<=m_axi_rvalid && !m_axi_rready;old_r<={m_axi_rid,m_axi_rresp,m_axi_rlast,m_axi_rdata};
            held_b<=m_axi_bvalid && !m_axi_bready;old_b<={m_axi_bid,m_axi_bresp};
            if(ar_take) begin
                if(m_axi_arid!=0 || m_axi_arsize!=4 || m_axi_arburst!=1 || m_axi_araddr[3:0]!=0 || int'(m_axi_arlen)+1>BURST_BEATS || int'(m_axi_araddr[11:0])+(int'(m_axi_arlen)+1)*16>4096) $fatal(1,"illegal AR burst");
                raddr[rtail]<=m_axi_araddr;rlen[rtail]<=int'(m_axi_arlen)+1;r_due[rtail]<=cycle+LATENCY;
                rtail<=(rtail+1)%Q;ar_total<=ar_total+1;
            end
            case({ar_take,r_pop}) 2'b10:r_count<=r_count+1;2'b01:r_count<=r_count-1;default:begin end endcase
            if(r_count+int'(ar_take)-int'(r_pop)>peak_read) peak_read<=r_count+int'(ar_take)-int'(r_pop);
            if(r_take) begin
                m_axi_rvalid<=0;r_total<=r_total+1;
                if(r_pop) begin rhead<=(rhead+1)%Q;rpos<=0;end else rpos<=rpos+1;
            end
            if(service_read) begin
                pos=rpos+int'(r_take);physical_last=pos==rlen[rhead]-1;
                early=inject_r==2 && !fault_r_seen && rlen[rhead]>1 && pos==0;
                inject=!fault_r_seen && ((inject_r==1 || inject_r==4) || early || (inject_r==3 && physical_last));
                m_axi_rdata<=service_read_data;m_axi_rvalid<=1;m_axi_rresp<=inject && inject_r==1 ? 2 : 0;
                m_axi_rid<=inject && inject_r==4 ? 1 : 0;
                m_axi_rlast<=early || (physical_last && !(inject && inject_r==3));r_end<=early || physical_last;
                if(inject) fault_r_seen<=1;
                prefer_write<=1;
            end
            if(aw_take) begin
                if(m_axi_awid!=0 || m_axi_awsize!=4 || m_axi_awburst!=1 || m_axi_awaddr[3:0]!=0 || int'(m_axi_awlen)+1>BURST_BEATS || int'(m_axi_awaddr[11:0])+(int'(m_axi_awlen)+1)*16>4096) $fatal(1,"illegal AW burst");
                waddr[wtail]<=m_axi_awaddr;wlen[wtail]<=int'(m_axi_awlen)+1;w_complete[wtail]<=early_complete;
                if(early_complete) begin
                    b_due[wtail]<=cycle+LATENCY;whead<=(whead+1)%Q;early_position<=0;early_complete<=0;
                end
                wtail<=(wtail+1)%Q;aw_total<=aw_total+1;
            end
            case({aw_take,b_take}) 2'b10:b_count<=b_count+1;2'b01:b_count<=b_count-1;default:begin end endcase
            case({aw_w_push,w_pop}) 2'b10:w_count<=w_count+1;2'b01:w_count<=w_count-1;default:begin end endcase
            if(b_count+int'(aw_take)-int'(b_take)>peak_write) peak_write<=b_count+int'(aw_take)-int'(b_take);
            if(service_write) begin
                if(m_axi_wlast!==(early_mode ? early_position==int'(m_axi_awlen) : wpos==wlen[whead]-1)) $fatal(1,"WLAST != AWLEN boundary");
                w_total<=w_total+1;prefer_write<=0;
                if(early_mode) begin
                    early_position<=early_position+1;if(m_axi_wlast) early_complete<=1;
                end else if(w_pop) begin w_complete[whead]<=1;b_due[whead]<=cycle+LATENCY;whead<=(whead+1)%Q;wpos<=0;end else wpos<=wpos+1;
            end
            if(b_take) begin m_axi_bvalid<=0;bhead<=(bhead+1)%Q;b_total<=b_total+1;end
            if(!m_axi_bvalid && b_count!=0 && w_complete[bhead] && cycle>=b_due[bhead] && !hold_b && (!STALLS || random_q[5])) begin
                m_axi_bvalid<=1;m_axi_bresp<=!fault_b_seen && inject_b==1 ? 2 : 0;
                m_axi_bid<=!fault_b_seen && inject_b==2 ? 1 : 0;
                if(inject_b!=0 && !fault_b_seen) fault_b_seen<=1;
            end
            if(r_count<0 || r_count>Q || b_count<0 || b_count>Q || w_count<0 || w_count>b_count) $fatal(1,"BFM queue divergence");
            if(MEMORY_DIV!=0 && service_read && service_write) $fatal(1,"BFM double spent shared bandwidth");
        end
    end
endmodule
