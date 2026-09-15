`timescale 1ns/1ps
module tb_c1_sapphire_irq_adapter #(
    parameter integer COUNT = 8,
    parameter integer INDEX = 0
);
    logic irq = 0;
    wire [COUNT-1:0] pins;
    localparam logic [COUNT-1:0] EXPECTED = 8'b1 << INDEX;
    c1_sapphire_irq_adapter #(
        .USER_INTERRUPT_COUNT(COUNT), .USER_INTERRUPT_INDEX(INDEX)
    ) dut (.c1_irq(irq), .sapphire_user_interrupt(pins));
    initial begin
        #1;
        if (pins !== '0) $fatal(1, "IRQ idle mismatch");
        repeat (3) begin
            irq = 1;
            repeat (20) begin
                #1;
                if (pins !== EXPECTED) $fatal(1, "IRQ level/routing mismatch");
            end
            irq = 0;
            #1;
            if (pins !== '0) $fatal(1, "IRQ acknowledgement mismatch");
        end
        $display("C1_SAPPHIRE_IRQ_ADAPTER_PASS count=%0d index=%0d", COUNT, INDEX);
        $finish;
    end
endmodule
