`timescale 1ns/1ps

// Sapphire/APB vendor-boundary placeholder.
//
// The portable control block speaks ordinary APB3.  This transparent adapter
// marks the seam where the generated Sapphire master or an AXI-to-APB bridge
// will be connected later.
module c1_sapphire_vendor_adapter_stub #(
    parameter integer APB_ADDR_W = 12
) (
    input  wire                    vendor_psel,
    input  wire                    vendor_penable,
    input  wire                    vendor_pwrite,
    input  wire [APB_ADDR_W-1:0]   vendor_paddr,
    input  wire [31:0]             vendor_pwdata,
    input  wire [3:0]              vendor_pstrb,
    output wire [31:0]             vendor_prdata,
    output wire                    vendor_pready,
    output wire                    vendor_pslverr,

    output wire                    core_psel,
    output wire                    core_penable,
    output wire                    core_pwrite,
    output wire [APB_ADDR_W-1:0]   core_paddr,
    output wire [31:0]             core_pwdata,
    output wire [3:0]              core_pstrb,
    input  wire [31:0]             core_prdata,
    input  wire                    core_pready,
    input  wire                    core_pslverr
);

    assign core_psel       = vendor_psel;
    assign core_penable    = vendor_penable;
    assign core_pwrite     = vendor_pwrite;
    assign core_paddr      = vendor_paddr;
    assign core_pwdata     = vendor_pwdata;
    assign core_pstrb      = vendor_pstrb;
    assign vendor_prdata   = core_prdata;
    assign vendor_pready   = core_pready;
    assign vendor_pslverr  = core_pslverr;

endmodule
