`timescale 1ns/1ps

// Deliberately Verilog-2005-only smoke DUT.  This is not a replacement for
// the Case-1 SystemVerilog RTL; it only checks that an Icarus installation can
// compile, run and emit a small VCD in an isolated working directory.
module c1_iverilog_compat_dut (
    input wire       clk,
    input wire       rst,
    input wire [7:0] din,
    output reg [7:0] dout
);
    always @(posedge clk) begin
        if (rst)
            dout <= 8'h00;
        else
            dout <= din + 8'h01;
    end
endmodule
