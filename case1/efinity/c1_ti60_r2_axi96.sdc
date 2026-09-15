# Core-only 150MHz; physical AXI I/O/DDR/video constraints remain integration work.
create_clock -name core_clk -period 6.666 [get_ports clk]
