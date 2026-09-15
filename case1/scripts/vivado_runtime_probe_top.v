module vivado_runtime_probe_top(
    input  wire clk,
    input  wire a,
    output wire y
);
  assign y = a ^ clk;
endmodule
