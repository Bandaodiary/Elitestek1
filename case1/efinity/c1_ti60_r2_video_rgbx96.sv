// C12 RGBX32 runtime-observable, pin-reduced CORE synthesis probe; NOT board wiring.
// Fixed 640x480 allows more constant folding than C10 runtime geometry.
// Host staging registers retain all CPU payload/size/burst and physical data.
module c1_ti60_r2_video_rgbx96 (
    input wire clk,rst,host_write,platform_ready,
    input wire [5:0] host_address,observe,
    input wire [31:0] host_data,
    input wire psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [3:0] pstrb,
    input wire capture_request,s_valid,s_sof,s_eol,s_eof,
    input wire display_request,p_req,p_sof,p_eol,p_eof,
    output wire pready,pslverr,irq,capture_request_ready,display_request_ready,
    output wire m_valid,m_sof,m_eol,m_eof,front_valid,display_frame_armed,nn_complete,nn_failed,fabric_error,
    output logic [31:0] observed,
    output wire m_axi_arvalid,m_axi_rready,m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready,
    input wire m_axi_arready,m_axi_rvalid,m_axi_rlast,m_axi_awready,m_axi_wready,m_axi_bvalid,
    input wire [1:0] m_axi_rresp,m_axi_bresp,
    input wire [3:0] m_axi_rid,m_axi_bid
);
    wire [31:0] pwdata,prdata,display_pair_tag,nn_result_tag,nn_result_cycles;
    assign pwdata=host_data;
    logic [31:0] capture_tag;
    wire [23:0] s_rgb,m_rgb;
    assign s_rgb=host_data[23:0];
    wire [7:0] physical_read_outstanding,physical_write_outstanding;
    logic [127:0] m_axi_rdata,cpu_wdata;
    logic [31:0] cpu_araddr,cpu_awaddr;
    logic [7:0] cpu_arlen,cpu_awlen;
    logic [2:0] cpu_arsize,cpu_awsize;
    logic [1:0] cpu_arburst,cpu_awburst;
    logic cpu_arvalid,cpu_awvalid,cpu_wvalid,cpu_wlast,cpu_rready,cpu_bready;
    logic [15:0] cpu_wstrb;
    wire cpu_arready,cpu_awready,cpu_wready,cpu_rvalid,cpu_bvalid,cpu_rlast;
    wire [127:0] cpu_rdata;
    wire [1:0] cpu_rresp,cpu_bresp;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_arcache,m_axi_arqos,m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_arprot,m_axi_awprot;
    wire m_axi_arlock,m_axi_awlock;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    wire [2:0] m_axi_arsize,m_axi_awsize;
    wire [1:0] m_axi_arburst,m_axi_awburst;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    always_ff @(posedge clk)if(host_write)begin
        case(host_address)
            0:cpu_araddr<=host_data;
            1:cpu_awaddr<=host_data;
            2:begin cpu_arlen<=host_data[7:0];cpu_awlen<=host_data[15:8];end
            3:begin
                cpu_arvalid<=host_data[0];cpu_awvalid<=host_data[1];cpu_wvalid<=host_data[2];cpu_wlast<=host_data[3];
                cpu_rready<=host_data[4];cpu_bready<=host_data[5];
                cpu_arsize<=host_data[10:8];cpu_awsize<=host_data[13:11];cpu_arburst<=host_data[15:14];cpu_awburst<=host_data[17:16];
            end
            4,5,6,7:cpu_wdata[host_address[1:0]*32+:32]<=host_data;
            8:cpu_wstrb<=host_data[15:0];
            12,13,14,15:m_axi_rdata[host_address[1:0]*32+:32]<=host_data;
            16:capture_tag<=host_data;
        endcase
    end
    c1_r2_video_rgbx_system u_system(.*);
    always_comb begin
        observed=0;
        case(observe)
            0,1,2,3:observed=cpu_rdata[observe[1:0]*32+:32];
            4:observed={22'd0,cpu_rresp,cpu_bresp,cpu_arready,cpu_awready,cpu_wready,cpu_rvalid,cpu_bvalid,cpu_rlast};
            8:observed=prdata;
            9:observed=m_axi_araddr;
            10:observed=m_axi_awaddr;
            11:observed={m_axi_arlen,m_axi_awlen,physical_read_outstanding,physical_write_outstanding};
            12,13,14,15:observed=m_axi_wdata[observe[1:0]*32+:32];
            16:observed={8'd0,m_rgb};
            17:observed=display_pair_tag;
            18:observed=nn_result_tag;
            19:observed=nn_result_cycles;
            20:observed={16'd0,m_axi_wstrb};
            21:observed={14'd0,m_axi_arid,m_axi_awid,m_axi_arsize,m_axi_awsize,m_axi_arburst,m_axi_awburst};
            22:observed={8'd0,m_axi_arcache,m_axi_arqos,m_axi_arprot,m_axi_arlock,m_axi_awcache,m_axi_awqos,m_axi_awprot,m_axi_awlock};
        endcase
    end
endmodule
