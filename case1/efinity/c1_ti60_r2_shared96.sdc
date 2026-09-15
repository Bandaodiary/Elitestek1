# C2 arithmetic probe, core-only 150MHz; no board IO timing signoff.
create_clock -name core_clk -period 6.666 [get_ports clk]
