// C10 runtime-observable, pin-reduced synthesis probe; NOT board wiring.
module c1_ti60_r2_shared_system96 (
    input wire clk,rst,host_write,
    input wire [5:0] host_address,observe,
    input wire [31:0] host_data,
    input wire psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [3:0] pstrb,
    input wire publish_ready,
    output wire pready,pslverr,irq,busy,publish_valid,fabric_error,
    output logic [31:0] observed,
    output wire m_axi_arvalid,m_axi_rready,m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready,
    input wire m_axi_arready,m_axi_rvalid,m_axi_rlast,m_axi_awready,m_axi_wready,m_axi_bvalid,
    input wire [1:0] m_axi_rresp,m_axi_bresp,
    input wire [3:0] m_axi_rid,m_axi_bid
);
    wire [31:0] pwdata,prdata,publish_base,publish_tag;
    assign pwdata=host_data;
    wire [10:0] publish_width;wire [9:0] publish_height;
    wire [7:0] physical_read_outstanding,physical_write_outstanding;
    logic capture_busy,display_busy;logic [31:0] capture_base,display_base;
    logic [127:0] m_axi_rdata;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_arcache,m_axi_arqos,m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_arprot,m_axi_awprot;wire m_axi_arlock,m_axi_awlock;
    logic [2:0][31:0] x_araddr;
    logic [2:0][7:0] x_arlen;
    logic [2:0][2:0] x_arsize;
    logic [2:0][1:0] x_arburst;
    logic [2:0] x_arvalid;
    wire [2:0] x_arready;
    wire [2:0][127:0] x_rdata;
    wire [2:0][1:0] x_rresp;
    wire [2:0] x_rlast;
    wire [2:0] x_rvalid;
    logic [2:0] x_rready;
    logic [2:0][31:0] x_awaddr;
    logic [2:0][7:0] x_awlen;
    logic [2:0][2:0] x_awsize;
    logic [2:0][1:0] x_awburst;
    logic [2:0] x_awvalid;
    wire [2:0] x_awready;
    logic [2:0][127:0] x_wdata;
    logic [2:0][15:0] x_wstrb;
    logic [2:0] x_wlast;
    logic [2:0] x_wvalid;
    wire [2:0] x_wready;
    wire [2:0][1:0] x_bresp;
    wire [2:0] x_bvalid;
    logic [2:0] x_bready;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    logic [383:0] write_payload;
    wire [383:0] read_payload=x_rdata;
    assign x_wdata=write_payload;
    always_ff @(posedge clk) if(host_write) begin
        if(host_address[5:4]<3) begin
            case(host_address[3:0])
                0:x_araddr[host_address[5:4]]<=host_data;
                1:x_awaddr[host_address[5:4]]<=host_data;
                2:begin x_arlen[host_address[5:4]]<=host_data[7:0];x_awlen[host_address[5:4]]<=host_data[15:8];end
                3:begin
                    x_arvalid[host_address[5:4]]<=host_data[0];x_awvalid[host_address[5:4]]<=host_data[1];
                    x_wvalid[host_address[5:4]]<=host_data[2];x_wlast[host_address[5:4]]<=host_data[3];
                    x_rready[host_address[5:4]]<=host_data[4];x_bready[host_address[5:4]]<=host_data[5];
                end
                4,5,6,7:write_payload[host_address[5:4]*128+host_address[1:0]*32+:32]<=host_data;
                8:x_wstrb[host_address[5:4]]<=host_data[15:0];
            endcase
        end else begin
            case(host_address[3:0])
                0,1,2,3:m_axi_rdata[host_address[1:0]*32+:32]<=host_data;
                4:capture_base<=host_data;5:display_base<=host_data;
                6:begin capture_busy<=host_data[0];display_busy<=host_data[1];end
            endcase
        end
    end
    assign x_arsize={3{3'd4}};assign x_awsize={3{3'd4}};
    assign x_arburst={3{2'b01}};assign x_awburst={3{2'b01}};
    c1_r2_shared_subsystem u_system(.*);
    always_comb begin
        observed=0;
        if(observe[5:4]<3) begin
            case(observe[3:0])
                0,1,2,3:observed=read_payload[observe[5:4]*128+observe[1:0]*32+:32];
                4:observed={23'd0,x_rresp[observe[5:4]],x_bresp[observe[5:4]],x_arready[observe[5:4]],x_awready[observe[5:4]],x_wready[observe[5:4]],x_rvalid[observe[5:4]],x_bvalid[observe[5:4]]};
                5:observed={31'd0,x_rlast[observe[5:4]]};
            endcase
        end else begin
            case(observe[3:0])
                0:observed=prdata;1:observed=m_axi_araddr;2:observed=m_axi_awaddr;
                3:observed={m_axi_arlen,m_axi_awlen,physical_read_outstanding,physical_write_outstanding};
                4,5,6,7:observed=m_axi_wdata[observe[1:0]*32+:32];
                8:observed=publish_base;9:observed=publish_tag;
                10:observed={6'd0,publish_height,5'd0,publish_width};
                11:observed={16'd0,m_axi_wstrb};
                12:observed={14'd0,m_axi_arid,m_axi_awid,m_axi_arsize,m_axi_awsize,m_axi_arburst,m_axi_awburst};
            endcase
        end
    end
endmodule
