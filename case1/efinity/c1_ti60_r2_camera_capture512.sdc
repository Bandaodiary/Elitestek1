# MAP/resource comparison only. Physical Gray/bundled-data CDC constraints pending.
create_clock -name core_clk -period 6.666 [get_ports clk]
create_clock -name camera_clk -period 13.468 [get_ports cam_clk]
