`timescale 1ns/1ps
// C33 physical-burst credit gate; retained C9 DMA is untouched.
// Credits describe all complete words in the current physical row, including
// prefetched words in elastic registers. No additional payload RAM is used.
// W follows AW order but does NOT wait for earlier B. The sole payload skid
// respects upstream pauses; no second full burst/row copy is allocated here.
// Row response waits for every B. AXI ID/framing violations are sticky and
// require system reset; ordinary BRESP errors drain and allow the next row.
module c1_r2_axi_credit_row_write #(
    parameter integer BURST_BEATS=16,OUTSTANDING=4
) (
    input wire clk,rst,cmd_valid,
    input wire issue_enable,
    input wire [15:0] published_beats,
    output logic [15:0] granted_beats,
    output wire cmd_ready,
    input wire [31:0] cmd_address,
    input wire [15:0] cmd_beats,
    input wire data_valid,
    output wire data_ready,
    input wire [127:0] data,
    input wire data_last,
    output logic response_valid,response_error,
    input wire response_ready,
    output logic busy,protocol_error,
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
    localparam PW=OUTSTANDING<=1 ? 1 : $clog2(OUTSTANDING);
    localparam CW=$clog2(OUTSTANDING+1);
    logic [PW-1:0] tail,whead,bhead;
    logic [CW-1:0] count,wcount;
    logic [OUTSTANDING-1:0] w_complete;
    logic [8:0] lengths[0:OUTSTANDING-1];
    logic [8:0] position,aw_beats;
    logic [15:0] issue_remaining,input_remaining;
    logic [15:0] row_beats_q;
    logic [31:0] next_address,aw_address;
    logic aw_valid,row_error,padding,invalid_command;
    logic held_valid;
    logic [127:0] held_data;
    logic [15:0] held_strb;
    function automatic [PW-1:0] advance(input [PW-1:0] p);
        advance=p==OUTSTANDING-1 ? 0 : p+1'b1;
    endfunction
    wire [8:0] page_beats=9'd256-{1'b0,next_address[11:4]};
    wire [15:0] capped=issue_remaining>BURST_BEATS ? BURST_BEATS : issue_remaining;
    wire [8:0] next_beats=capped>page_beats ? page_beats : capped[8:0];
    wire [32:0] command_end={1'b0,cmd_address}+({17'd0,cmd_beats}<<4);
    wire legal_command=cmd_address[3:0]==0 && cmd_beats!=0 && command_end<=33'h100000000;
    assign cmd_ready=!rst && !busy && !protocol_error;
    assign outstanding=count;
    assign m_axi_awid=0;assign m_axi_awaddr=aw_address;assign m_axi_awlen=aw_beats-1'b1;
    assign m_axi_awsize=3'd4;assign m_axi_awburst=2'b01;assign m_axi_awvalid=!rst && aw_valid;
    wire aw_take=m_axi_awvalid && m_axi_awready;
    wire [16:0] next_grant_end={1'b0,granted_beats}+{8'd0,next_beats};
    wire full_burst_ready=!next_grant_end[16] && next_grant_end<={1'b0,published_beats};
    // Gate PRESENTATION, not only acceptance. Once offered, AW/W remain
    // valid under backpressure and W can still complete before AWREADY.
    // Existing early-LAST zero padding is autonomous error draining.
    wire aw_offer=busy && !aw_valid && issue_remaining!=0 && count<OUTSTANDING &&
                  (issue_enable || padding) && (full_burst_ready || padding);
    assign m_axi_wvalid=!rst && busy && held_valid && wcount!=0;
    assign m_axi_wdata=held_data;assign m_axi_wstrb=held_strb;assign m_axi_wlast=position+1==lengths[whead];
    wire w_take=m_axi_wvalid && m_axi_wready;
    wire w_retire=w_take && m_axi_wlast;
    assign m_axi_bready=!rst && busy && count!=0 && w_complete[bhead];
    wire b_take=m_axi_bvalid && m_axi_bready;
    wire slot_ready=!held_valid || w_take;
    assign data_ready=!rst && busy && !invalid_command && !padding && input_remaining!=0 && slot_ready;
    wire capture=busy && !invalid_command && input_remaining!=0 && slot_ready && (padding || data_valid);
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;protocol_error<=0;response_valid<=0;response_error<=0;count<=0;wcount<=0;
            granted_beats<=0;row_beats_q<=0;
            tail<=0;whead<=0;bhead<=0;w_complete<=0;position<=0;aw_beats<=1;issue_remaining<=0;input_remaining<=0;
            next_address<=0;aw_address<=0;aw_valid<=0;row_error<=0;padding<=0;invalid_command<=0;held_valid<=0;held_data<=0;held_strb<=0;
        end else begin
            if(response_valid && response_ready) begin response_valid<=0;busy<=0;granted_beats<=0;end
            if(cmd_valid && cmd_ready) begin
                busy<=1;row_error<=!legal_command;invalid_command<=!legal_command;padding<=0;
                granted_beats<=0;row_beats_q<=legal_command ? cmd_beats : 0;
                issue_remaining<=legal_command ? cmd_beats : 0;input_remaining<=legal_command ? cmd_beats : 0;
                next_address<=cmd_address;position<=0;
            end
            // WVALID must not depend on AWREADY. Allocate the W descriptor
            // when presenting AW, not only when AW is accepted. This also
            // permits an entire W burst to precede its AW handshake.
            if(aw_offer) begin
                granted_beats<=next_grant_end[15:0];
                aw_address<=next_address;aw_beats<=next_beats;aw_valid<=1;
                lengths[tail]<=next_beats;w_complete[tail]<=0;
            end
            if(aw_take) begin
                tail<=advance(tail);aw_valid<=0;
                issue_remaining<=issue_remaining-aw_beats;next_address<=next_address+({23'd0,aw_beats}<<4);
            end
            case({aw_take,b_take})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
            case({aw_offer,w_retire})
                2'b10:wcount<=wcount+1'b1;
                2'b01:wcount<=wcount-1'b1;
                default:begin end
            endcase
            if(w_take) begin
                held_valid<=0;
                if(w_retire) begin position<=0;w_complete[whead]<=1;whead<=advance(whead);end
                else position<=position+1'b1;
            end
            if(capture) begin
                held_valid<=1;held_data<=padding ? 128'd0 : data;held_strb<=padding ? 16'd0 : 16'hffff;
                input_remaining<=input_remaining-1'b1;
                if(!padding && data_last!=(input_remaining==1)) begin
                    row_error<=1;protocol_error<=1;
                    if(data_last) padding<=1;
                end
            end
            if(b_take) begin
                bhead<=advance(bhead);
                if(m_axi_bresp!=0 || m_axi_bid!=0) row_error<=1;
                if(m_axi_bid!=0) protocol_error<=1;
            end
            if(m_axi_bvalid && (!busy || count==0 || (!w_complete[bhead] && !(w_retire && whead==bhead)))) begin
                protocol_error<=1;row_error<=1;
            end
            if(busy && !response_valid && issue_remaining==0 && !aw_valid && count==0 && wcount==0 && input_remaining==0 && !held_valid) begin
                response_valid<=1;response_error<=row_error;
            end
        end
    end
`ifndef SYNTHESIS
    initial if(BURST_BEATS<1 || BURST_BEATS>256 || OUTSTANDING<1 || OUTSTANDING>16) $fatal(1,"write DMA parameter range");
    always @(posedge clk) if(!rst) begin
        if(count>OUTSTANDING || wcount>count+int'(aw_valid)) $fatal(1,"write DMA credit divergence");
        if(busy && !invalid_command && (granted_beats>row_beats_q || published_beats>row_beats_q))
            $fatal(1,"C33 physical credit outside row");
        if(aw_offer && (!padding && (!issue_enable || !full_burst_ready)))
            $fatal(1,"C33 burst granted before publication or during refill");
        if(aw_offer && (next_grant_end[16] || next_grant_end>{1'b0,row_beats_q}))
            $fatal(1,"C33 physical grant wraps/exceeds row");
        if(response_valid && (count!=0 || wcount!=0 || aw_valid || held_valid)) $fatal(1,"write row acknowledged before drain");
        if(aw_take && ({1'b0,m_axi_awaddr[11:0]}+((13'(m_axi_awlen)+1)<<4)>4096)) $fatal(1,"write burst crossed 4KiB");
    end
`endif
endmodule
