# C25 MAP-only probe. These clocks do not constitute physical CDC signoff.
# Before PNR: constrain Gray-bus skew/max delay and bundled request/status
# payload paths against synchronizer settling; do not blanket false-path them.
create_clock -name core_clk -period 6.666 [get_ports clk]
create_clock -name camera_clk -period 13.468 [get_ports cam_clk]
