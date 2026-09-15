# C10 core-only; no external APB/AXI or board IO timing signoff.
create_clock -name core_clk -period 6.666 [get_ports clk]
