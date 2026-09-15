// Core-only resource/timing observation shell, NOT a board pinout.
// Serial host words prevent pruning while reducing package-port count.
module c1_ti60_r2_axi96 (
    input wire clk,rst,host_write,
    input wire [3:0] host_address,observe,
    input wire [31:0] host_data,
    output logic [31:0] observed,
    input wire start_valid,done_ready,
    output wire start_ready,busy,done_valid,done_error,protocol_error,
    output wire m_axi_arvalid,m_axi_rready,m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready,
    input wire m_axi_arready,m_axi_rvalid,m_axi_rlast,m_axi_awready,m_axi_wready,m_axi_bvalid,
    input wire [1:0] m_axi_rresp,m_axi_bresp,
    input wire [3:0] m_axi_rid,m_axi_bid
);
    logic [127:0] m_axi_rdata;
    logic [31:0] input_base,workspace_base,output_base,parameter_base;
    logic [10:0] frame_width;logic [9:0] frame_height;
    wire [31:0] m_axi_araddr,m_axi_awaddr,frame_cycles;
    wire [7:0] m_axi_arlen,m_axi_awlen,read_outstanding,write_outstanding;
    wire [127:0] m_axi_wdata;wire [15:0] m_axi_wstrb;
    wire stage_done;wire [4:0] stage_done_index,active_stage;
    wire [3:0] m_axi_arid,m_axi_awid,m_axi_arcache,m_axi_arqos,m_axi_awcache,m_axi_awqos;
    wire [2:0] m_axi_arsize,m_axi_awsize,m_axi_arprot,m_axi_awprot;
    wire [1:0] m_axi_arburst,m_axi_awburst;wire m_axi_arlock,m_axi_awlock;
    always_ff @(posedge clk) if(host_write) begin
        case(host_address)
            0,1,2,3:m_axi_rdata[host_address[1:0]*32+:32]<=host_data;
            4:input_base<=host_data;5:workspace_base<=host_data;6:output_base<=host_data;7:parameter_base<=host_data;
            8:begin frame_width<=host_data[10:0];frame_height<=host_data[25:16];end
        endcase
    end
    c1_r2_microstyle_axi_graph u_graph(.*);
    always_comb begin
        case(observe)
            0:observed=m_axi_araddr;1:observed=m_axi_awaddr;
            2:observed={m_axi_arlen,m_axi_awlen,read_outstanding,write_outstanding};
            3,4,5,6:observed=m_axi_wdata[(observe-3)*32+:32];7:observed=frame_cycles;
            8:observed={21'd0,stage_done,stage_done_index,active_stage};
            9:observed={16'd0,m_axi_wstrb};
            10:observed={14'd0,m_axi_arid,m_axi_awid,m_axi_arsize,m_axi_awsize,m_axi_arburst,m_axi_awburst};
            11:observed={8'd0,m_axi_arlock,m_axi_arcache,m_axi_arqos,m_axi_arprot,m_axi_awlock,m_axi_awcache,m_axi_awqos,m_axi_awprot};
            default:observed=0;
        endcase
    end
endmodule
