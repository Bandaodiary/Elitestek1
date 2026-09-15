`timescale 1ns/1ps

// Combinational, vendor-independent APB3 one-master/two-slave interconnect.
//
// Address contract (12-bit byte addresses):
//   0x000..0x1ff -> main control/status register block
//   0x200..0x2ff -> ISP configuration register block
//   0x300..0xfff -> locally completed with PSLVERR
//
// The complete byte address is forwarded unchanged because both existing
// slaves decode absolute addresses.  Register holes inside either window are
// therefore rejected by that selected slave and its PSLVERR is propagated.
// Only PSEL is decoded; all other request signals are simple fan-out.  APB
// requires address/control to remain stable from setup through every access
// wait cycle, so no state or clock is required in this interconnect.
module c1_apb_r1_mux #(
    parameter integer APB_ADDR_W = 12
) (
    // Upstream APB master side.
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic [APB_ADDR_W-1:0]   paddr,
    input  logic [31:0]             pwdata,
    input  logic [3:0]              pstrb,
    output logic [31:0]             prdata,
    output logic                    pready,
    output logic                    pslverr,

    // Main CSR slave side.
    output logic                    csr_psel,
    output logic                    csr_penable,
    output logic                    csr_pwrite,
    output logic [APB_ADDR_W-1:0]   csr_paddr,
    output logic [31:0]             csr_pwdata,
    output logic [3:0]              csr_pstrb,
    input  logic [31:0]             csr_prdata,
    input  logic                    csr_pready,
    input  logic                    csr_pslverr,

    // ISP configuration slave side.
    output logic                    isp_psel,
    output logic                    isp_penable,
    output logic                    isp_pwrite,
    output logic [APB_ADDR_W-1:0]   isp_paddr,
    output logic [31:0]             isp_pwdata,
    output logic [3:0]              isp_pstrb,
    input  logic [31:0]             isp_prdata,
    input  logic                    isp_pready,
    input  logic                    isp_pslverr
);

    localparam logic [APB_ADDR_W-1:0] CSR_LAST  = 12'h1ff;
    localparam logic [APB_ADDR_W-1:0] ISP_FIRST = 12'h200;
    localparam logic [APB_ADDR_W-1:0] ISP_LAST  = 12'h2ff;

    logic csr_hit;
    logic isp_hit;

    always_comb begin
        csr_hit = (paddr <= CSR_LAST);
        isp_hit = (paddr >= ISP_FIRST) && (paddr <= ISP_LAST);

        // The request payload is fanned out unchanged.  Inactive slaves never
        // observe PSEL, so their PENABLE and payload values have no meaning.
        csr_psel = psel && csr_hit;
        csr_penable = penable;
        csr_pwrite = pwrite;
        csr_paddr = paddr;
        csr_pwdata = pwdata;
        csr_pstrb = pstrb;

        isp_psel = psel && isp_hit;
        isp_penable = penable;
        isp_pwrite = pwrite;
        isp_paddr = paddr;
        isp_pwdata = pwdata;
        isp_pstrb = pstrb;

        // Idle and locally-unmapped transfers have deterministic data/ready.
        // PSLVERR is asserted only on a completing APB access phase.
        prdata = 32'd0;
        pready = 1'b1;
        pslverr = 1'b0;

        if (psel && csr_hit) begin
            prdata = csr_prdata;
            pready = csr_pready;
            pslverr = penable && csr_pready && csr_pslverr;
        end else if (psel && isp_hit) begin
            prdata = isp_prdata;
            pready = isp_pready;
            pslverr = penable && isp_pready && isp_pslverr;
        end else if (psel) begin
            // No downstream slave is selected.  Complete locally in one
            // access clock and return zero data plus a precise decode error.
            prdata = 32'd0;
            pready = 1'b1;
            pslverr = penable;
        end
    end

endmodule
