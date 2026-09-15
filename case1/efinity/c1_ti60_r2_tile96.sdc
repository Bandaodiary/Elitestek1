# Register-to-register core timing only; no physical board interface claims.
create_clock -name core_clk -period 6.666 [get_ports clk]
