`timescale 1ns/1ps
// C15 synchronous APB3 (16-bit LOCAL byte offset) to the retained R2V2
// peripheral. Use 32-bit aligned software accesses: APB3 has no PSTRB and
// this bridge cannot infer the size of an upstream CPU store.
// 0000..00ff: retained CSR, exact decode still done by that peripheral.
// 0100/0104/0108: read-only host ID/version/live status. No address aliasing.
// CPU protocol faults are reset-required levels, not clearable IRQ events.
// CPU, this bridge and the video core share clk/reset; this is NOT a CDC.
module c1_r2_host_control_bridge (
    input wire rst,psel,penable,pwrite,
    input wire [15:0] paddr,
    input wire [31:0] pwdata,
    output logic [31:0] prdata,
    output wire pready,
    output logic pslverr,
    input wire cpu_adapter_busy,cpu_adapter_fault,core_irq,
    output wire irq,
    output wire core_psel,core_penable,core_pwrite,
    output wire [7:0] core_paddr,
    output wire [31:0] core_pwdata,
    output wire [3:0] core_pstrb,
    input wire [31:0] core_prdata,
    input wire core_pready,core_pslverr
);
    wire core_page=paddr[15:8]==0;
    wire [31:0] adapted_prdata;
    wire adapted_pready,adapted_pslverr;
    wire access=!rst && psel && penable;
    logic diag_legal;
    c1_sapphire_apb_master_adapter #(.SAPPHIRE_ADDR_W(16),.C1_ADDR_W(8),
        .WRITE_PSTRB(4'hf),.REJECT_UPPER_ADDR(1)) u_apb (
        .sapphire_psel(psel && core_page && !rst),.sapphire_penable(penable),
        .sapphire_pwrite(pwrite),.sapphire_paddr(paddr),.sapphire_pwdata(pwdata),
        .sapphire_prdata(adapted_prdata),.sapphire_pready(adapted_pready),.sapphire_pslverr(adapted_pslverr),
        .c1_psel(core_psel),.c1_penable(core_penable),.c1_pwrite(core_pwrite),
        .c1_paddr(core_paddr),.c1_pwdata(core_pwdata),.c1_pstrb(core_pstrb),
        .c1_prdata(core_prdata),.c1_pready(core_pready),.c1_pslverr(core_pslverr)
    );
    assign pready=!rst && (core_page ? adapted_pready : 1'b1);
    assign irq=!rst && (core_irq || cpu_adapter_fault);
    always_comb begin
        diag_legal=1;prdata=0;
        case(paddr)
            16'h0100:prdata=32'h52324831; // R2H1, not a replacement R2V2 ID
            16'h0104:prdata=32'h00010000;
            16'h0108:prdata={29'd0,core_irq,cpu_adapter_fault,cpu_adapter_busy};
            default:diag_legal=0;
        endcase
        if(core_page)prdata=adapted_prdata;
        pslverr=access && (core_page ? adapted_pslverr : (!diag_legal || pwrite));
    end
endmodule
