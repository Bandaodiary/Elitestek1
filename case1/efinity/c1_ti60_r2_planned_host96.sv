// C18 actual host shell: APB3/IRQ + retained C14/C13, observable core probe; NO CPU IP/PHY/CDC.
// Fixed 640x480 allows more constant folding than C10 runtime geometry.
// Host staging registers retain all CPU payload/size/burst and physical data.
module c1_ti60_r2_planned_host96 (
    input wire clk,rst,host_write,platform_ready,
    input wire [5:0] host_address,observe,
    input wire [31:0] host_data,
    input wire psel,penable,pwrite,
    input wire [15:0] paddr,
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
    logic [127:0] m_axi_rdata,host_cpu_wdata;
    logic [31:0] host_cpu_araddr,host_cpu_awaddr;
    logic [7:0] host_cpu_arlen,host_cpu_awlen;
    logic [2:0] host_cpu_arsize,host_cpu_awsize;
    logic [1:0] host_cpu_arburst,host_cpu_awburst;
    logic host_cpu_arvalid,host_cpu_awvalid,host_cpu_wvalid,host_cpu_wlast,host_cpu_rready,host_cpu_bready;
    logic [15:0] host_cpu_wstrb;
    wire host_cpu_arready,host_cpu_awready,host_cpu_wready,host_cpu_rvalid,host_cpu_bvalid,host_cpu_rlast;
    wire [127:0] host_cpu_rdata;
    wire [1:0] host_cpu_rresp,host_cpu_bresp;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_arcache,m_axi_arqos,m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_arprot,m_axi_awprot;
    wire m_axi_arlock,m_axi_awlock;
    wire [31:0] m_axi_araddr,m_axi_awaddr;
    wire [7:0] m_axi_arlen,m_axi_awlen;
    wire [2:0] m_axi_arsize,m_axi_awsize;
    wire [1:0] m_axi_arburst,m_axi_awburst;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    wire [31:0] cpu_araddr,cpu_awaddr;
    wire [7:0] cpu_arlen,cpu_awlen;
    wire [2:0] cpu_arsize,cpu_awsize;
    wire [1:0] cpu_arburst,cpu_awburst,cpu_rresp,cpu_bresp;
    wire [127:0] cpu_wdata,cpu_rdata;
    wire [15:0] cpu_wstrb;
    wire  cpu_arvalid,cpu_arready,cpu_awvalid,cpu_awready,cpu_rvalid,cpu_rready,cpu_rlast,cpu_wvalid,cpu_wready,cpu_wlast,cpu_bvalid,cpu_bready;
    logic [7:0] host_cpu_arid,host_cpu_awid;
    logic host_cpu_arlock,host_cpu_awlock;
    logic [3:0] host_cpu_arregion,host_cpu_awregion;
    wire [7:0] host_cpu_rid,host_cpu_bid;
    wire cpu_adapter_busy,cpu_adapter_fault;
    always_ff @(posedge clk)if(host_write)begin
        case(host_address)
            0:host_cpu_araddr<=host_data;
            1:host_cpu_awaddr<=host_data;
            2:begin host_cpu_arlen<=host_data[7:0];host_cpu_awlen<=host_data[15:8];end
            3:begin
                host_cpu_arvalid<=host_data[0];host_cpu_awvalid<=host_data[1];host_cpu_wvalid<=host_data[2];host_cpu_wlast<=host_data[3];
                host_cpu_rready<=host_data[4];host_cpu_bready<=host_data[5];
                host_cpu_arsize<=host_data[10:8];host_cpu_awsize<=host_data[13:11];host_cpu_arburst<=host_data[15:14];host_cpu_awburst<=host_data[17:16];
            end
            4,5,6,7:host_cpu_wdata[host_address[1:0]*32+:32]<=host_data;
            8:host_cpu_wstrb<=host_data[15:0];
            12,13,14,15:m_axi_rdata[host_address[1:0]*32+:32]<=host_data;
            16:capture_tag<=host_data;
            17:begin host_cpu_arid<=host_data[7:0];host_cpu_awid<=host_data[15:8];host_cpu_arlock<=host_data[16];host_cpu_awlock<=host_data[17];host_cpu_arregion<=host_data[21:18];host_cpu_awregion<=host_data[25:22];end
        endcase
    end
    c1_r2_planned_host_system u_host (
        .clk(clk),
        .rst(rst),
        .platform_ready(platform_ready),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .irq(irq),
        .capture_request(capture_request),
        .capture_tag(capture_tag),
        .capture_request_ready(capture_request_ready),
        .s_valid(s_valid),
        .s_sof(s_sof),
        .s_eol(s_eol),
        .s_eof(s_eof),
        .s_rgb(s_rgb),
        .display_request(display_request),
        .display_request_ready(display_request_ready),
        .p_req(p_req),
        .p_sof(p_sof),
        .p_eol(p_eol),
        .p_eof(p_eof),
        .m_valid(m_valid),
        .m_sof(m_sof),
        .m_eol(m_eol),
        .m_eof(m_eof),
        .m_rgb(m_rgb),
        .front_valid(front_valid),
        .display_frame_armed(display_frame_armed),
        .display_pair_tag(display_pair_tag),
        .nn_complete(nn_complete),
        .nn_failed(nn_failed),
        .nn_result_tag(nn_result_tag),
        .nn_result_cycles(nn_result_cycles),
        .fabric_error(fabric_error),
        .physical_read_outstanding(physical_read_outstanding),
        .physical_write_outstanding(physical_write_outstanding),
        .cpu_araddr(host_cpu_araddr),
        .cpu_arlen(host_cpu_arlen),
        .cpu_arsize(host_cpu_arsize),
        .cpu_arburst(host_cpu_arburst),
        .cpu_arvalid(host_cpu_arvalid),
        .cpu_arready(host_cpu_arready),
        .cpu_rdata(host_cpu_rdata),
        .cpu_rresp(host_cpu_rresp),
        .cpu_rlast(host_cpu_rlast),
        .cpu_rvalid(host_cpu_rvalid),
        .cpu_rready(host_cpu_rready),
        .cpu_awaddr(host_cpu_awaddr),
        .cpu_awlen(host_cpu_awlen),
        .cpu_awsize(host_cpu_awsize),
        .cpu_awburst(host_cpu_awburst),
        .cpu_awvalid(host_cpu_awvalid),
        .cpu_awready(host_cpu_awready),
        .cpu_wdata(host_cpu_wdata),
        .cpu_wstrb(host_cpu_wstrb),
        .cpu_wlast(host_cpu_wlast),
        .cpu_wvalid(host_cpu_wvalid),
        .cpu_wready(host_cpu_wready),
        .cpu_bresp(host_cpu_bresp),
        .cpu_bvalid(host_cpu_bvalid),
        .cpu_bready(host_cpu_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .cpu_arid(host_cpu_arid),
        .cpu_awid(host_cpu_awid),
        .cpu_rid(host_cpu_rid),
        .cpu_bid(host_cpu_bid),
        .cpu_arlock(host_cpu_arlock),
        .cpu_awlock(host_cpu_awlock),
        .cpu_arregion(host_cpu_arregion),
        .cpu_awregion(host_cpu_awregion),
        .cpu_adapter_busy(cpu_adapter_busy),
        .cpu_adapter_fault(cpu_adapter_fault)
    );
    always_comb begin
        observed=0;
        case(observe)
            0,1,2,3:observed=host_cpu_rdata[observe[1:0]*32+:32];
            4:observed={22'd0,host_cpu_rresp,host_cpu_bresp,host_cpu_arready,host_cpu_awready,host_cpu_wready,host_cpu_rvalid,host_cpu_bvalid,host_cpu_rlast};
            23:observed={14'd0,cpu_adapter_fault,cpu_adapter_busy,host_cpu_rid,host_cpu_bid};
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
