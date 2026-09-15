// Tiny syntax/elaboration probe.  It intentionally uses `logic`, which is
// enough to distinguish a current SystemVerilog-capable Icarus from the old
// 0.9.x Windows package.  No Case-1 functionality is exercised here.
module c1_iverilog_sv_probe (
    input  logic       clk,
    input  logic [3:0] din,
    output logic [3:0] dout
);
    always @(posedge clk)
        dout <= din;
endmodule
