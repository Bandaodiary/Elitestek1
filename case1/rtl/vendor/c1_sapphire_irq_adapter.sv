`timescale 1ns/1ps

// Map the Case-1 level IRQ to an explicitly sized integration interface.
// The supplied 08 demo exposes scalar userInterruptA: instantiate with
// USER_INTERRUPT_COUNT=1 and USER_INTERRUPT_INDEX=0 for that interface.
// The default eight-bit output preserves existing vector-wrapper users;
// it does not imply that every Sapphire configuration has eight IRQ pins.
// Sapphire's PLIC expects a level, and c1_apb_csr keeps IRQ asserted
// until software acknowledges the corresponding IRQ_STATUS bit; no pulse
// stretcher is needed here.
module c1_sapphire_irq_adapter #(
    parameter integer USER_INTERRUPT_INDEX = 0,
    parameter integer USER_INTERRUPT_COUNT = 8
) (
    input  wire       c1_irq,
    output wire [USER_INTERRUPT_COUNT-1:0] sapphire_user_interrupt
);

    assign sapphire_user_interrupt =
        ({USER_INTERRUPT_COUNT{c1_irq}} & (8'b00000001 << USER_INTERRUPT_INDEX));

`ifndef SYNTHESIS
    initial begin
        if ((USER_INTERRUPT_COUNT < 1) || (USER_INTERRUPT_COUNT > 8))
            $fatal(1, "USER_INTERRUPT_COUNT must be in the range 1..8");
        if ((USER_INTERRUPT_INDEX < 0) ||
            (USER_INTERRUPT_INDEX >= USER_INTERRUPT_COUNT))
            $fatal(1, "USER_INTERRUPT_INDEX must fit USER_INTERRUPT_COUNT");
    end
`endif

endmodule
