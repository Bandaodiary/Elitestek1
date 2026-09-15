# C15 core only. No IO/PHY/CDC timing signoff. Fixed 640x480 geometry.
create_clock -name core_clk -period 6.666 [get_ports clk]
