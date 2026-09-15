`timescale 1ns/1ps
// C11 post-ISP/Resize RGB888 capture, one core-clock pixel/event, NO ready.
// Arm before SOF. Complete rows are buffered before AXI submission; overflow,
// malformed markers or cancel poison the frame, while owned rows still drain.
// A result is a lease fence: every emitted AW/W has its real B before done.
module c1_r2_video_capture_p2c8 #(
    parameter integer FIFO_DEPTH=512,OUTSTANDING=4,
    parameter integer LW=$clog2(FIFO_DEPTH+1)
) (
    input wire clk,rst,cmd_valid,
    output wire cmd_ready,
    input wire [31:0] cfg_base,cfg_tag,
    input wire [10:0] cfg_width,
    input wire [9:0] cfg_height,
    input wire cancel,s_valid,s_sof,s_eol,s_eof,
    input wire [23:0] s_rgb,
    output wire busy,
    output logic done_valid,done_error,done_dropped,
    input wire done_ready,
    output wire [31:0] done_base,done_tag,
    output logic overflow_pulse,
    output logic [LW-1:0] peak_level,
    output wire protocol_error,
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
    logic owned,started,input_done,poison,error_q,row_active;
    logic [31:0] base,tag,row_address;
    logic [10:0] width,x;
    logic [9:0] height,y,write_row;
    logic [15:0] sent;
    logic [23:0] first_rgb;
    wire legal=cfg_base[22:0]==0 && cfg_width>=4 && cfg_width<=640 && cfg_width[1:0]==0 &&
               cfg_height>=4 && cfg_height<=480 && cfg_height[1:0]==0 && (cfg_width>>1)<=FIFO_DEPTH;
    assign cmd_ready=!rst && !owned && !done_valid && !protocol_error && !cancel && legal;
    assign busy=owned || done_valid;assign done_base=base;assign done_tag=tag;
    wire [15:0] pairs={6'd0,width[10:1]};
    wire [LW-1:0] level;
    wire fin_ready,fout_valid,fout_ready;
    wire [47:0] fout_data;
    wire marker_good=s_sof==(x==0 && y==0) && s_eol==(x==width-1) && s_eof==(x==width-1 && y==height-1);
    wire pixel=owned && !poison && !input_done && !cancel && s_valid && (started || s_sof);
    wire pair_valid=pixel && marker_good && x[0];
    // Stored RGB words keep conventional R at bits[23:16]. AXI byte0 is R.
    c1_r2_video_bram_fifo #(.WIDTH(48),.DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk),.rst(rst || (!owned && !done_valid)),.in_valid(pair_valid),.in_ready(fin_ready),
        .in_data({s_rgb,first_rgb}),.out_valid(fout_valid),.out_ready(fout_ready),.out_data(fout_data),.level(level)
    );
    wire dma_busy,dma_ready,dma_response,dma_error,dma_data_ready;
    wire dma_command=owned && !poison && !row_active && !dma_busy && write_row<height && level>=pairs;
    wire [127:0] dma_data={40'd0,fout_data[31:24],fout_data[39:32],fout_data[47:40],
                           40'd0,fout_data[7:0],fout_data[15:8],fout_data[23:16]};
    assign fout_ready=row_active && dma_data_ready;
    c1_r2_axi_row_write #(.OUTSTANDING(OUTSTANDING)) u_dma (
        .clk(clk),.rst(rst),.cmd_valid(dma_command),.cmd_ready(dma_ready),.cmd_address(row_address),.cmd_beats(pairs),
        .data_valid(row_active && fout_valid),.data_ready(dma_data_ready),.data(dma_data),.data_last(sent==pairs-1),
        .response_valid(dma_response),.response_error(dma_error),.response_ready(1'b1),
        .busy(dma_busy),.protocol_error(protocol_error),.outstanding(outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            owned<=0;started<=0;input_done<=0;poison<=0;error_q<=0;row_active<=0;
            base<=0;tag<=0;row_address<=0;width<=0;height<=0;x<=0;y<=0;write_row<=0;sent<=0;first_rgb<=0;
            done_valid<=0;done_error<=0;done_dropped<=0;overflow_pulse<=0;peak_level<=0;
        end else begin
            overflow_pulse<=0;
            if(done_valid && done_ready) done_valid<=0;
            if(cmd_valid && cmd_ready) begin
                owned<=1;started<=0;input_done<=0;poison<=0;error_q<=0;
                base<=cfg_base;tag<=cfg_tag;row_address<=cfg_base;width<=cfg_width;height<=cfg_height;
                x<=0;y<=0;write_row<=0;sent<=0;peak_level<=0;
            end
            if(owned && level>peak_level) peak_level<=level;
            if(owned && cancel) poison<=1;
            if(owned && protocol_error) begin poison<=1;error_q<=1;end
            if(pixel) begin
                started<=1;
                if(!marker_good) begin poison<=1;error_q<=1;end
                else if(x[0] && !fin_ready) begin poison<=1;error_q<=1;overflow_pulse<=1;end
                else begin
                    if(!x[0]) first_rgb<=s_rgb;
                    if(x==width-1) begin x<=0;y<=y+1'b1;if(y==height-1) input_done<=1;end
                    else x<=x+1'b1;
                end
            end
            if(dma_command && dma_ready) begin row_active<=1;sent<=0;end
            if(fout_valid && fout_ready) sent<=sent+1'b1;
            if(dma_response) begin
                row_active<=0;write_row<=write_row+1'b1;row_address<=row_address+({21'd0,width}<<3);
                if(dma_error) begin poison<=1;error_q<=1;end
            end
            if(owned && !row_active && !dma_busy && !dma_command &&
               (poison || (input_done && write_row==height))) begin
                owned<=0;done_valid<=1;done_error<=error_q || protocol_error;done_dropped<=poison || cancel || protocol_error;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(done_valid && (outstanding!=0 || dma_busy || row_active)) $fatal(1,"capture completed before write drain");
        if(dma_command && dma_ready && level<pairs) $fatal(1,"unbuffered capture row issued");
    end
`endif
endmodule
