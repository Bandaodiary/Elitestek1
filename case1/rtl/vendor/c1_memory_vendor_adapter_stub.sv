`timescale 1ns/1ps

// AXI4 memory vendor-boundary placeholder.
//
// This is a transparent, ID-less AXI4 pass-through.  It contains no DDR PHY,
// controller, calibration, clock conversion, arbitration, buffering, or data
// width conversion.  It exists so portable DMA logic can compile against a
// stable interface before the Efinix memory subsystem is available.
module c1_memory_vendor_adapter_stub #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 128
) (
    // Portable core AXI master side.
    input  wire [ADDR_W-1:0]       core_awaddr,
    input  wire [7:0]              core_awlen,
    input  wire [2:0]              core_awsize,
    input  wire [1:0]              core_awburst,
    input  wire                    core_awvalid,
    output wire                    core_awready,
    input  wire [DATA_W-1:0]       core_wdata,
    input  wire [(DATA_W/8)-1:0]   core_wstrb,
    input  wire                    core_wlast,
    input  wire                    core_wvalid,
    output wire                    core_wready,
    output wire [1:0]              core_bresp,
    output wire                    core_bvalid,
    input  wire                    core_bready,
    input  wire [ADDR_W-1:0]       core_araddr,
    input  wire [7:0]              core_arlen,
    input  wire [2:0]              core_arsize,
    input  wire [1:0]              core_arburst,
    input  wire                    core_arvalid,
    output wire                    core_arready,
    output wire [DATA_W-1:0]       core_rdata,
    output wire [1:0]              core_rresp,
    output wire                    core_rlast,
    output wire                    core_rvalid,
    input  wire                    core_rready,

    // Vendor memory-controller AXI slave side.
    output wire [ADDR_W-1:0]       mem_awaddr,
    output wire [7:0]              mem_awlen,
    output wire [2:0]              mem_awsize,
    output wire [1:0]              mem_awburst,
    output wire                    mem_awvalid,
    input  wire                    mem_awready,
    output wire [DATA_W-1:0]       mem_wdata,
    output wire [(DATA_W/8)-1:0]   mem_wstrb,
    output wire                    mem_wlast,
    output wire                    mem_wvalid,
    input  wire                    mem_wready,
    input  wire [1:0]              mem_bresp,
    input  wire                    mem_bvalid,
    output wire                    mem_bready,
    output wire [ADDR_W-1:0]       mem_araddr,
    output wire [7:0]              mem_arlen,
    output wire [2:0]              mem_arsize,
    output wire [1:0]              mem_arburst,
    output wire                    mem_arvalid,
    input  wire                    mem_arready,
    input  wire [DATA_W-1:0]       mem_rdata,
    input  wire [1:0]              mem_rresp,
    input  wire                    mem_rlast,
    input  wire                    mem_rvalid,
    output wire                    mem_rready
);

    assign mem_awaddr   = core_awaddr;
    assign mem_awlen    = core_awlen;
    assign mem_awsize   = core_awsize;
    assign mem_awburst  = core_awburst;
    assign mem_awvalid  = core_awvalid;
    assign core_awready = mem_awready;

    assign mem_wdata    = core_wdata;
    assign mem_wstrb    = core_wstrb;
    assign mem_wlast    = core_wlast;
    assign mem_wvalid   = core_wvalid;
    assign core_wready  = mem_wready;

    assign core_bresp   = mem_bresp;
    assign core_bvalid  = mem_bvalid;
    assign mem_bready   = core_bready;

    assign mem_araddr   = core_araddr;
    assign mem_arlen    = core_arlen;
    assign mem_arsize   = core_arsize;
    assign mem_arburst  = core_arburst;
    assign mem_arvalid  = core_arvalid;
    assign core_arready = mem_arready;

    assign core_rdata   = mem_rdata;
    assign core_rresp   = mem_rresp;
    assign core_rlast   = mem_rlast;
    assign core_rvalid  = mem_rvalid;
    assign mem_rready   = core_rready;

endmodule
