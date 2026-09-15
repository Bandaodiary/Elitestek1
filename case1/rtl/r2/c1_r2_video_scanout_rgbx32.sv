`timescale 1ns/1ps
// C12 RGBX32 dual-image ROI scanout: raw row then styled row, width=2*cfg_width.
// Core-clock active-pixel requests cannot wait. Blank/letterbox timing is
// outside this module. Arm in blanking; prefill_ready is diagnostic, not a
// permission to pause the physical display clock. Output is delayed one clk.
// On any underrun/error, the remaining ROI is black and owned ARs are drained.
module c1_r2_video_scanout_rgbx32 #(
    parameter integer FIFO_DEPTH=512,OUTSTANDING=4,
    parameter integer LW=$clog2(FIFO_DEPTH+1)
) (
    input wire clk,rst,cmd_valid,
    output wire cmd_ready,
    input wire [31:0] cfg_raw_base,cfg_style_base,cfg_tag,
    input wire [10:0] cfg_width,
    input wire [9:0] cfg_height,
    input wire cancel,p_req,p_sof,p_eol,p_eof,
    output logic m_valid,m_sof,m_eol,m_eof,
    output logic [23:0] m_rgb,
    output wire busy,prefill_ready,
    output logic done_valid,done_error,done_cancelled,
    input wire done_ready,
    output wire [31:0] done_raw_base,done_style_base,done_tag,
    output logic underflow_pulse,
    output logic [LW-1:0] peak_level,min_active_level,
    output wire protocol_error,
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
    logic owned,started,scan_done,poison,error_q,cancel_q,row_active,plane;
    logic [31:0] raw_base,style_base,raw_row,style_row,tag;
    logic [10:0] width;
    logic [11:0] x;
    logic [9:0] height,y,read_row;
    wire legal=cfg_raw_base[22:0]==0 && cfg_style_base[22:0]==0 && cfg_width>=4 && cfg_width<=640 && cfg_width[1:0]==0 &&
               cfg_height>=4 && cfg_height<=480 && cfg_height[1:0]==0 && cfg_width<=2*FIFO_DEPTH;
    assign cmd_ready=!rst && !owned && !done_valid && !protocol_error && !cancel && legal;
    assign busy=owned || done_valid;assign done_raw_base=raw_base;assign done_style_base=style_base;assign done_tag=tag;
    wire [15:0] quads={7'd0,width[10:2]};
    wire [11:0] roi_width={width,1'b0};
    wire [LW-1:0] level;
    wire fin_ready,fout_valid,fout_ready;
    wire [95:0] fout_data;
    wire dma_busy,dma_ready,dma_valid,dma_last,dma_error;
    wire [127:0] dma_data;
    wire dma_data_ready=poison || fin_ready;
    // Reserve room for the WHOLE row before issuing it. R never waits for a
    // future display pixel; up to four actual bursts then drain into this RAM.
    wire dma_command=owned && !poison && !row_active && !dma_busy && read_row<height && level+quads<=FIFO_DEPTH;
    wire pixel=owned && !scan_done && p_req && (started || p_sof);
    wire marker_good=p_sof==(x==0 && y==0) && p_eol==(x==roi_width-1) && p_eof==(x==roi_width-1 && y==height-1);
    assign fout_ready=poison || (pixel && marker_good && x[1:0]==3 && !cancel);
    assign prefill_ready=owned && !poison && fout_valid && level>=(width>>1);
    function automatic [23:0] rgb(input [31:0] pixel_rgbx);
        rgb={pixel_rgbx[7:0],pixel_rgbx[15:8],pixel_rgbx[23:16]};
    endfunction
    wire [95:0] packed_rgb={rgb(dma_data[127:96]),rgb(dma_data[95:64]),rgb(dma_data[63:32]),rgb(dma_data[31:0])};
    c1_r2_video_bram_fifo #(.WIDTH(96),.DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk),.rst(rst || (!owned && !done_valid)),.in_valid(dma_valid && !poison),.in_ready(fin_ready),
        .in_data(packed_rgb),.out_valid(fout_valid),.out_ready(fout_ready),.out_data(fout_data),.level(level)
    );
    c1_r2_axi_row_read #(.OUTSTANDING(OUTSTANDING)) u_dma (
        .clk(clk),.rst(rst),.cmd_valid(dma_command),.cmd_ready(dma_ready),.cmd_address(plane ? style_row : raw_row),.cmd_beats(quads),
        .data_valid(dma_valid),.data_ready(dma_data_ready),.data(dma_data),.data_last(dma_last),.data_error(dma_error),
        .busy(dma_busy),.protocol_error(protocol_error),.outstanding(outstanding),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            owned<=0;started<=0;scan_done<=0;poison<=0;error_q<=0;cancel_q<=0;row_active<=0;plane<=0;
            raw_base<=0;style_base<=0;raw_row<=0;style_row<=0;tag<=0;width<=0;height<=0;x<=0;y<=0;read_row<=0;
            done_valid<=0;done_error<=0;done_cancelled<=0;underflow_pulse<=0;peak_level<=0;min_active_level<=FIFO_DEPTH;
            m_valid<=0;m_rgb<=0;m_sof<=0;m_eol<=0;m_eof<=0;
        end else begin
            underflow_pulse<=0;
            m_valid<=p_req;m_sof<=p_sof;m_eol<=p_eol;m_eof<=p_eof;m_rgb<=0;
            if(done_valid && done_ready) done_valid<=0;
            if(cmd_valid && cmd_ready) begin
                owned<=1;started<=0;scan_done<=0;poison<=0;error_q<=0;cancel_q<=0;plane<=0;
                raw_base<=cfg_raw_base;style_base<=cfg_style_base;raw_row<=cfg_raw_base;style_row<=cfg_style_base;tag<=cfg_tag;
                width<=cfg_width;height<=cfg_height;x<=0;y<=0;read_row<=0;peak_level<=0;min_active_level<=FIFO_DEPTH;
            end
            if(owned && level>peak_level) peak_level<=level;
            if(owned && cancel) begin poison<=1;cancel_q<=1;scan_done<=1;end
            if(owned && protocol_error) begin poison<=1;error_q<=1;end
            if(pixel) begin
                started<=1;
                if(level<min_active_level) min_active_level<=level;
                if(!marker_good) begin poison<=1;error_q<=1;end
                if(!poison && !cancel && marker_good) begin
                    if(!fout_valid) begin poison<=1;error_q<=1;underflow_pulse<=1;end
                    else m_rgb<=fout_data[x[1:0]*24+:24];
                end
                if(x==roi_width-1) begin x<=0;y<=y+1'b1;if(y==height-1) scan_done<=1;end
                else x<=x+1'b1;
            end
            if(dma_command && dma_ready) row_active<=1;
            if(dma_valid && dma_data_ready) begin
                if(dma_error) begin poison<=1;error_q<=1;end
                if(dma_last) begin
                    row_active<=0;plane<=!plane;
                    if(plane) begin
                        read_row<=read_row+1'b1;raw_row<=raw_row+({21'd0,width}<<2);style_row<=style_row+({21'd0,width}<<2);
                    end
                end
            end
            if(owned && scan_done && !row_active && !dma_busy && !dma_command) begin
                owned<=0;done_valid<=1;done_error<=error_q || protocol_error;done_cancelled<=cancel_q || cancel;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(done_valid && (outstanding!=0 || dma_busy || row_active)) $fatal(1,"scanout done before R drain");
        if(dma_valid && !poison && !fin_ready) $fatal(1,"scanout reserved row overflow");
    end
`endif
endmodule
