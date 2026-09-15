// Resize C8 -> independent CNN consumer + RGB preview AXI writer.
// done retires BOTH fork consumers and the writer's final B response.
// cancel flushes only local stream state; the writer drains presented AXI.
// On error the parent must cancel the job, including the CNN consumer. Until
// cancellation, an already presented CNN token remains stable under stall.
// A coordinate/marker-mismatched input is consumed once for error reporting, but
// never enters either fork consumer. Parent cancellation is then required.
module c1_r1_preview_dma #(
    parameter logic [32:0] DEST_REGION_BEGIN = 33'd0,
    parameter logic [32:0] DEST_REGION_END = 33'h1_0000_0000
) (
    input logic clk, rst,
    input logic start_valid, output logic start_ready,
    input logic cancel,
    input logic [31:0] base_addr, stride_bytes,
    input logic [15:0] width_pixels, height_lines,
    output logic busy, done, error, aborted,
    input logic in_valid, output logic in_ready,
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
    // EOF closes source admission immediately; AXI B and the independent CNN
    // consumer may retire later. A pulse cancel also stays latched until done.
    logic active_q, armed_q, terminal_q, cancel_q, error_q, source_eof_q;
    logic writer_busy,writer_done,writer_error,writer_ready;
    logic fork_busy,fork_ready,preview_valid;
    logic [23:0] preview_rgb;
    logic preview_sof,preview_eol,preview_eof;
    logic start_fire,admit;
    logic [15:0] width_q,height_q,expected_x_q,expected_y_q;
    logic coordinate_bad,marker_bad,raster_bad;
    always_comb begin
        busy=active_q || writer_busy || fork_busy;
        start_ready=!rst && !cancel && !busy;
        start_fire=start_valid && start_ready;
        error=error_q || (active_q && writer_error);
        admit=active_q && armed_q && !source_eof_q && !cancel && !cancel_q && !error && !rst;
        in_ready=admit && fork_ready;
        coordinate_bad=(in_x != expected_x_q) || (in_y != expected_y_q) ||
                       (expected_x_q >= width_q) || (expected_y_q >= height_q);
        marker_bad=(in_sof != ((expected_x_q==0) && (expected_y_q==0))) ||
                   (in_eol != (expected_x_q==width_q-1'b1)) ||
                   (in_eof != ((expected_x_q==width_q-1'b1) &&
                               (expected_y_q==height_q-1'b1)));
        raster_bad=coordinate_bad || marker_bad;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            active_q<=0;armed_q<=0;terminal_q<=0;cancel_q<=0;error_q<=0;
            source_eof_q<=0;
            width_q<=0;height_q<=0;expected_x_q<=0;expected_y_q<=0;
            done<=0;aborted<=0;
        end else begin
            done<=0;aborted<=0;
            if(start_fire) begin
                active_q<=1;armed_q<=0;terminal_q<=0;cancel_q<=0;error_q<=0;
                source_eof_q<=0;
                width_q<=width_pixels;height_q<=height_lines;
                expected_x_q<=0;expected_y_q<=0;
            end else if(active_q) begin
                if(in_valid && in_ready) begin
                    if(raster_bad) error_q<=1;
                    else begin
                        if(in_eof) source_eof_q<=1;
                        if(expected_x_q == width_q-1'b1) begin
                            expected_x_q<=0;expected_y_q<=expected_y_q+1'b1;
                        end else expected_x_q<=expected_x_q+1'b1;
                    end
                end
                // Do not expose pixels to either consumer before preflight.
                if(writer_ready) armed_q<=1;
                if(writer_done) terminal_q<=1;
                if(writer_error) error_q<=1;
                if(cancel) cancel_q<=1;
                if((terminal_q || writer_done) && !writer_busy && !fork_busy) begin
                    active_q<=0;armed_q<=0;done<=1;aborted<=cancel_q||cancel;
                end
            end
        end
    end
    c1_r1_preview_fork u_fork (
        .clk(clk),.rst(rst||cancel),.in_valid(in_valid&&admit&&!raster_bad),.in_ready(fork_ready),
        .in_data_s8(in_data_s8),.in_x(in_x),.in_y(in_y),.in_sof(in_sof),.in_eol(in_eol),.in_eof(in_eof),
        .cnn_valid(cnn_valid),.cnn_ready(cnn_ready),.cnn_data_s8(cnn_data_s8),
        .cnn_x(cnn_x),.cnn_y(cnn_y),.cnn_sof(cnn_sof),.cnn_eol(cnn_eol),.cnn_eof(cnn_eof),
        .preview_valid(preview_valid),.preview_ready(writer_ready),.preview_rgb(preview_rgb),
        .preview_x(),.preview_y(),.preview_sof(preview_sof),.preview_eol(preview_eol),.preview_eof(preview_eof),
        .busy(fork_busy)
    );
    c1_axi_xrgb_frame_writer #(
        .DEST_REGION_BEGIN(DEST_REGION_BEGIN), .DEST_REGION_END(DEST_REGION_END)
    ) u_writer (
        .clk(clk),.rst(rst),.start(start_fire),.cancel(cancel),
        .cfg_base_addr(base_addr),.cfg_width_pixels(width_pixels),.cfg_height_lines(height_lines),
        .cfg_stride_bytes(stride_bytes),.busy(writer_busy),.done(writer_done),.error(writer_error),
        .s_valid(preview_valid),.s_ready(writer_ready),.s_rgb(preview_rgb),
        .s_sof(preview_sof),.s_eol(preview_eol),.s_eof(preview_eof),
        .m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready)
    );
endmodule
