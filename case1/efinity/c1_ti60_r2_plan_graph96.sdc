# Core-only 150MHz; no board/DDR/video I/O timing claims.
create_clock -name core_clk -period 6.666 [get_ports clk]
