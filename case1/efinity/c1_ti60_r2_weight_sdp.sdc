# C20 weight store only. Common 150MHz target, no board I/O claim.
create_clock -name core_clk -period 6.666 [get_ports clk]
