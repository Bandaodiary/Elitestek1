`timescale 1ns/1ps
// C9: one 16-byte-aligned logical row -> bounded same-ID AXI INCR bursts.
// Up to OUTSTANDING bursts, ordered R; no full-row or full-burst data RAM.
// RRESP errors are recoverable after the complete row drains. RLAST/RID
// corruption also latches protocol_error and requires SYSTEM reset before
// another command. Missing RLAST uses ARLEN as the boundary; arbitrary extra
// beats / a slave that never responds are outside the recoverable contract.
module c1_r2_axi_row_read #(
    parameter integer BURST_BEATS=16,OUTSTANDING=4
) (
    input wire clk,rst,cmd_valid,
    output wire cmd_ready,
    input wire [31:0] cmd_address,
    input wire [15:0] cmd_beats,
    output logic data_valid,
    input wire data_ready,
    output logic [127:0] data,
    output logic data_last,data_error,
    output logic busy,protocol_error,
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
    localparam PW=OUTSTANDING<=1 ? 1 : $clog2(OUTSTANDING);
    localparam CW=$clog2(OUTSTANDING+1);
    logic [PW-1:0] head,tail;
    logic [CW-1:0] count;
    logic [8:0] lengths[0:OUTSTANDING-1];
    logic [8:0] position,fill_remaining;
    logic [15:0] issue_remaining,emit_remaining;
    logic [31:0] next_address,ar_address;
    logic [8:0] ar_beats;
    logic ar_valid,row_error;
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
    assign m_axi_arid=0;assign m_axi_araddr=ar_address;assign m_axi_arlen=ar_beats-1'b1;
    assign m_axi_arsize=3'd4;assign m_axi_arburst=2'b01;assign m_axi_arvalid=!rst && ar_valid;
    wire ar_take=m_axi_arvalid && m_axi_arready;
    wire slot_ready=!data_valid || data_ready;
    assign m_axi_rready=!rst && busy && count!=0 && fill_remaining==0 && slot_ready;
    wire r_take=m_axi_rvalid && m_axi_rready;
    wire expected_last=position+1==lengths[head];
    wire bad_beat=m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=expected_last;
    wire retire=r_take && (expected_last || m_axi_rlast);
    wire synthesize=busy && fill_remaining!=0 && slot_ready;
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;protocol_error<=0;head<=0;tail<=0;count<=0;position<=0;fill_remaining<=0;
            issue_remaining<=0;emit_remaining<=0;next_address<=0;ar_address<=0;ar_beats<=1;ar_valid<=0;row_error<=0;
            data_valid<=0;data<=0;data_last<=0;data_error<=0;
        end else begin
            if(data_valid && data_ready) begin data_valid<=0;if(data_last) busy<=0;end
            if(cmd_valid && cmd_ready) begin
                busy<=1;row_error<=!legal_command;issue_remaining<=legal_command ? cmd_beats : 0;
                emit_remaining<=legal_command ? cmd_beats : 1;next_address<=cmd_address;
                position<=0;fill_remaining<=legal_command ? 0 : 1;
            end
            // A presented AR is never withdrawn. Even a failing row finishes
            // all its declared bursts, so the row-end is an actual drain fence.
            if(busy && !ar_valid && issue_remaining!=0 && count<OUTSTANDING) begin
                ar_address<=next_address;ar_beats<=next_beats;ar_valid<=1;
            end
            if(ar_take) begin
                lengths[tail]<=ar_beats;tail<=advance(tail);ar_valid<=0;
                issue_remaining<=issue_remaining-ar_beats;next_address<=next_address+({23'd0,ar_beats}<<4);
            end
            case({ar_take,retire})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
            if(r_take) begin
                data_valid<=1;data<=m_axi_rdata;data_last<=emit_remaining==1;data_error<=row_error || bad_beat;
                emit_remaining<=emit_remaining-1'b1;
                if(bad_beat) row_error<=1;
                if(m_axi_rid!=0 || m_axi_rlast!=expected_last) protocol_error<=1;
                if(retire) begin head<=advance(head);position<=0;end else position<=position+1'b1;
                // Early RLAST ends the faulty physical burst. Pad only its
                // missing logical beats before accepting the next burst.
                if(m_axi_rlast && !expected_last) fill_remaining<=lengths[head]-position-1'b1;
            end
            if(synthesize) begin
                data_valid<=1;data<=0;data_last<=emit_remaining==1;data_error<=1;
                emit_remaining<=emit_remaining-1'b1;fill_remaining<=fill_remaining-1'b1;
            end
            if(m_axi_rvalid && !busy) protocol_error<=1;
        end
    end
`ifndef SYNTHESIS
    initial if(BURST_BEATS<1 || BURST_BEATS>256 || OUTSTANDING<1 || OUTSTANDING>16) $fatal(1,"read DMA parameter range");
    always @(posedge clk) if(!rst) begin
        if(count>OUTSTANDING) $fatal(1,"read DMA credit overflow");
        if(data_valid && data_ready && data_last && (count!=0 || ar_valid || issue_remaining!=0 || fill_remaining!=0)) $fatal(1,"read row completed before AXI drain");
        if(ar_take && ({1'b0,m_axi_araddr[11:0]}+((13'(m_axi_arlen)+1)<<4)>4096)) $fatal(1,"read burst crossed 4KiB");
    end
`endif
endmodule
