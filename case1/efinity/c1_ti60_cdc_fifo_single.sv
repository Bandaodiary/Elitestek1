// Independent MAP roots prevent common-cone sharing between control/treatment.
module c27_fifo_single_common #(parameter GUARDED=0) (input wire cam_clk,clk,cam_rst,rst,in_valid,out_ready,
    input wire [23:0] in_data,
    output wire in_ready,out_valid,rd_empty,
    output wire [23:0] out_data,
    output wire [9:0] wr_level,
    output logic [9:0] peak);
    generate if(GUARDED) begin:g_keep
        c27_fifo_keep #(.DEPTH(512)) u_ingress (.wr_clk(cam_clk),.wr_rst(cam_rst),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.wr_level(wr_level),.rd_clk(clk),.rd_rst(rst),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.rd_empty(rd_empty));
    end else begin:g_plain
        c1_r2_async_pixel_fifo #(.DEPTH(512)) u_ingress (.wr_clk(cam_clk),.wr_rst(cam_rst),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.wr_level(wr_level),.rd_clk(clk),.rd_rst(rst),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.rd_empty(rd_empty));
    end endgenerate
    always @(posedge cam_clk)begin
        if(cam_rst)peak<=0;
        else if(wr_level>peak)peak<=wr_level;
    end
endmodule
module c1_ti60_cdc_fifo_single_plain (input wire cam_clk,clk,cam_rst,rst,in_valid,out_ready,
    input wire [23:0] in_data,
    output wire in_ready,out_valid,rd_empty,
    output wire [23:0] out_data,
    output wire [9:0] wr_level,
    output logic [9:0] peak);
    c27_fifo_single_common #(.GUARDED(0)) u_probe (.cam_clk(cam_clk),.clk(clk),.cam_rst(cam_rst),.rst(rst),.in_valid(in_valid),.out_ready(out_ready),.in_data(in_data),.in_ready(in_ready),.out_valid(out_valid),.rd_empty(rd_empty),.out_data(out_data),.wr_level(wr_level),.peak(peak));
endmodule
module c1_ti60_cdc_fifo_single_keep (input wire cam_clk,clk,cam_rst,rst,in_valid,out_ready,
    input wire [23:0] in_data,
    output wire in_ready,out_valid,rd_empty,
    output wire [23:0] out_data,
    output wire [9:0] wr_level,
    output logic [9:0] peak);
    c27_fifo_single_common #(.GUARDED(1)) u_probe (.cam_clk(cam_clk),.clk(clk),.cam_rst(cam_rst),.rst(rst),.in_valid(in_valid),.out_ready(out_ready),.in_data(in_data),.in_ready(in_ready),.out_valid(out_valid),.rd_empty(rd_empty),.out_data(out_data),.wr_level(wr_level),.peak(peak));
endmodule
