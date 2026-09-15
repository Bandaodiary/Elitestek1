`timescale 1ns/1ps
// Simulation-only sampled ready/valid contract. Cancellation is explicit:
// never connect AXI transaction cancellation here to excuse VALID withdrawal.
module c1_rv_hold_checker #(parameter integer WIDTH=8, CHANNEL=0) (
    input logic clk,rst,cancel,valid,ready,
    input logic [WIDTH-1:0] payload
);
    logic pending_q=0;
    logic [WIDTH-1:0] payload_q;
    always @(posedge clk) begin
        if(rst || cancel) pending_q<=0;
        else begin
            // The previously stalled beat must survive through the actual
            // accepting edge, even if READY has returned high by that edge.
            if(pending_q && (valid!==1'b1 || payload!==payload_q))
                $fatal(1,"C1_RV_HOLD_VIOLATION channel=%0d valid=%b ready=%b expected=%h actual=%h",
                    CHANNEL,valid,ready,payload_q,payload);
            pending_q <= valid && !ready;
            if(valid && !ready) payload_q<=payload;
        end
    end
endmodule
