# C27 small syntax/attribute/STA experiment, not full camera sign-off.
create_clock -name source_clock -period 13.468 [get_ports clk_src]
create_clock -name destination_clock -period 6.666 [get_ports clk_dst]
set_max_delay -from [get_pins {src_q~FF|CLK}] -to [get_pins {lower_a0~FF|D lower_b0~FF|D upper_a0~FF|D upper_b0~FF|D plain_a0~FF|D}] 5.000
set_false_path -hold -from [get_pins {src_q~FF|CLK}] -to [get_pins {lower_a0~FF|D lower_b0~FF|D upper_a0~FF|D upper_b0~FF|D plain_a0~FF|D}]
set_bus_skew -from [get_pins {src_q~FF|CLK}] -to [get_pins {lower_a0~FF|D lower_b0~FF|D upper_a0~FF|D upper_b0~FF|D plain_a0~FF|D}] 1.000
