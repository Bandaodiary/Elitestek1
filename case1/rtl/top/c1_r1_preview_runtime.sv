// One-clock-domain compute + preview lifecycle composition.
// start is accepted atomically by the compute participant and preview DMA.
// The parent must distribute cancel to compute too; this module only cancels
// its own preview child. Success waits for both children including preview B.
module c1_r1_preview_runtime #(
    parameter logic [32:0] DEST_REGION_BEGIN=33'd0,
    parameter logic [32:0] DEST_REGION_END=33'h1_0000_0000,
    parameter logic [7:0] PREVIEW_ERROR_CODE=8'h63
) (
    input logic clk,rst,start_valid,cancel,
    output logic start_ready,compute_start,
    input logic compute_ready,compute_busy,compute_done,compute_error,
    input logic [7:0] compute_error_code,
    input logic [31:0] compute_error_address,
    input logic [31:0] base_addr,stride_bytes,
    input logic [15:0] width_pixels,height_lines,
    output logic busy,done,error,
    output logic [7:0] error_code,
    output logic [31:0] error_address,
    output logic preview_ready,preview_busy,preview_done,preview_error,preview_aborted,
    input logic in_valid,output logic in_ready,
    input logic [63:0] in_data_s8,
    input logic [15:0] in_x,in_y,
    input logic in_sof,in_eol,in_eof,
    output logic cnn_valid,input logic cnn_ready,
    output logic [63:0] cnn_data_s8,
    output logic [15:0] cnn_x,cnn_y,
    output logic cnn_sof,cnn_eol,cnn_eof,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,input logic m_axi_awready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0] m_axi_wstrb,
    output logic m_axi_wlast,m_axi_wvalid,input logic m_axi_wready,
    input logic [1:0] m_axi_bresp,input logic m_axi_bvalid,output logic m_axi_bready
);
    logic [31:0] preview_base_q;
    always_ff @(posedge clk) begin
        if(rst) preview_base_q<=0;
        else if(compute_start) preview_base_q<=base_addr;
    end
    c1_r1_runtime_join u_join (
        .clk(clk),.rst(rst),.start_valid(start_valid),.start_ready(start_ready),
        .cancel(cancel),.child_start(compute_start),
        .left_ready(compute_ready),.right_ready(preview_ready),
        .left_busy(compute_busy),.left_done(compute_done),.left_error(compute_error),
        .left_error_code(compute_error_code),.left_error_address(compute_error_address),
        .right_busy(preview_busy),.right_done(preview_done),.right_error(preview_error),
        .right_error_code(PREVIEW_ERROR_CODE),.right_error_address(preview_base_q),
        .busy(busy),.done(done),.error(error),.error_code(error_code),.error_address(error_address)
    );
    c1_r1_preview_dma #(
        .DEST_REGION_BEGIN(DEST_REGION_BEGIN),.DEST_REGION_END(DEST_REGION_END)
    ) u_preview (
        .clk(clk),.rst(rst),.start_valid(compute_start),.start_ready(preview_ready),.cancel(cancel),
        .base_addr(base_addr),.stride_bytes(stride_bytes),.width_pixels(width_pixels),.height_lines(height_lines),
        .busy(preview_busy),.done(preview_done),.error(preview_error),.aborted(preview_aborted),
        .in_valid(in_valid),.in_ready(in_ready),.in_data_s8(in_data_s8),.in_x(in_x),.in_y(in_y),
        .in_sof(in_sof),.in_eol(in_eol),.in_eof(in_eof),
        .cnn_valid(cnn_valid),.cnn_ready(cnn_ready),.cnn_data_s8(cnn_data_s8),.cnn_x(cnn_x),.cnn_y(cnn_y),
        .cnn_sof(cnn_sof),.cnn_eol(cnn_eol),.cnn_eof(cnn_eof),
        .m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),.m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
endmodule
