`timescale 1ns/1ps

// Adapter from the generated Soft Sapphire APB-slave port to the
// byte-strobe-aware, board-independent Case-1 APB slave.
//
// Naming in Sapphire is from the CPU's point of view: io_apbSlave_0_* are
// outputs from Sapphire (address/control/write data) and PRDATA/PREADY/
// PSLVERROR are inputs.  The generated interface intentionally has no PSTRB.
// Case-1 registers are only written as complete 32-bit words by the current
// firmware ABI, so the adapter advertises a full-word strobe on writes and
// zero strobe on reads.  If a future BSP adds byte writes, this seam is the
// one place that must be extended.
//
// APB address is a local byte offset in the generated Sapphire slave window.
// The default 12-bit configuration therefore maps 0x000..0x2ff directly to
// c1_r1_portable_soc.  A wider generated window is accepted only when its
// upper address bits are zero; an out-of-range transfer completes with
// PSLVERROR and cannot reach the Case-1 CSR side effects.
module c1_sapphire_apb_master_adapter #(
    parameter integer SAPPHIRE_ADDR_W = 12,
    parameter integer C1_ADDR_W = 12,
    parameter logic [3:0] WRITE_PSTRB = 4'hf,
    parameter integer REJECT_UPPER_ADDR = 1
) (
    // Generated Soft Sapphire APB master-facing signals.
    input  wire                         sapphire_psel,
    input  wire                         sapphire_penable,
    input  wire                         sapphire_pwrite,
    input  wire [SAPPHIRE_ADDR_W-1:0]  sapphire_paddr,
    input  wire [31:0]                  sapphire_pwdata,
    output wire [31:0]                  sapphire_prdata,
    output wire                         sapphire_pready,
    output wire                         sapphire_pslverr,

    // Case-1 APB slave-facing signals.
    output wire                         c1_psel,
    output wire                         c1_penable,
    output wire                         c1_pwrite,
    output wire [C1_ADDR_W-1:0]         c1_paddr,
    output wire [31:0]                  c1_pwdata,
    output wire [3:0]                   c1_pstrb,
    input  wire [31:0]                  c1_prdata,
    input  wire                         c1_pready,
    input  wire                         c1_pslverr
);

    wire upper_addr_nonzero;
    wire address_rejected;

    // Keep the width conversion explicit.  The generate branches avoid
    // zero-width part-selects when a board-specific BSP chooses a smaller or
    // equal APB aperture.
    generate
        if (SAPPHIRE_ADDR_W > C1_ADDR_W) begin : gen_wider_sapphire_addr
            assign c1_paddr = sapphire_paddr[C1_ADDR_W-1:0];
            assign upper_addr_nonzero = |sapphire_paddr[SAPPHIRE_ADDR_W-1:C1_ADDR_W];
        end else if (SAPPHIRE_ADDR_W == C1_ADDR_W) begin : gen_equal_addr
            assign c1_paddr = sapphire_paddr;
            assign upper_addr_nonzero = 1'b0;
        end else begin : gen_narrow_sapphire_addr
            assign c1_paddr = {{(C1_ADDR_W-SAPPHIRE_ADDR_W){1'b0}}, sapphire_paddr};
            assign upper_addr_nonzero = 1'b0;
        end
    endgenerate

    assign address_rejected = (REJECT_UPPER_ADDR != 0) && upper_addr_nonzero;

    assign c1_psel    = sapphire_psel && !address_rejected;
    assign c1_penable = sapphire_penable;
    assign c1_pwrite  = sapphire_pwrite;
    assign c1_pwdata  = sapphire_pwdata;
    assign c1_pstrb   = sapphire_pwrite ? WRITE_PSTRB : 4'b0000;

    // An invalid wide-window access is a locally completed APB error.  Gate
    // PSLVERR to the APB access phase, matching c1_apb_r1_mux semantics.
    assign sapphire_prdata = address_rejected ? 32'd0 : c1_prdata;
    assign sapphire_pready = address_rejected ? 1'b1 : c1_pready;
    assign sapphire_pslverr = sapphire_psel && sapphire_penable &&
                              (address_rejected ||
                               (c1_pready && c1_pslverr));

`ifndef SYNTHESIS
    initial begin
        if ((SAPPHIRE_ADDR_W < 1) || (C1_ADDR_W < 1))
            $fatal(1, "APB address widths must be positive");
        if (WRITE_PSTRB == 4'b0000)
            $display("WARNING: Sapphire APB adapter has no writable byte lane");
    end
`endif

endmodule

