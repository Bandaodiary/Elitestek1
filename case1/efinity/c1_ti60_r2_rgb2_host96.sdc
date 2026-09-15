# C28 pin-reduced physical experiment, NOT board/IO/reset/PHY sign-off.
# No asynchronous clock groups: crossing setup/max-delay remains visible.
# Source Gray MSB aliases binary MSB after MAP. Verify ALL pin counts in audit.
create_clock -name core_clk -period 6.666 [get_ports clk]
create_clock -name camera_clk -period 14.286 [get_ports cam_clk]

# FIFO Gray buses: bound flight time and inter-bit skew separately.
set_max_delay -from [get_pins {u_host/u_system/u_ingress/u_fifo/wr_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/wr_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/wr_sync1[*]~FF|D}] 5.000
set_false_path -hold -from [get_pins {u_host/u_system/u_ingress/u_fifo/wr_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/wr_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/wr_sync1[*]~FF|D}]
set_bus_skew -from [get_pins {u_host/u_system/u_ingress/u_fifo/wr_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/wr_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/wr_sync1[*]~FF|D}] 1.000
set_max_delay -from [get_pins {u_host/u_system/u_ingress/u_fifo/rd_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/rd_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/rd_sync1[*]~FF|D}] 5.000
set_false_path -hold -from [get_pins {u_host/u_system/u_ingress/u_fifo/rd_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/rd_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/rd_sync1[*]~FF|D}]
set_bus_skew -from [get_pins {u_host/u_system/u_ingress/u_fifo/rd_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/rd_bin[9]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/u_fifo/rd_sync1[*]~FF|D}] 1.000

# Only first-stage CDC endpoints. Stage 1 -> 2 stays normally timed.
# enable/cancel now launch from protected source-domain registers.
# Board IO/reset timing and the complete CDC inventory still require review.
set_max_delay -from [get_clocks camera_clk] -to [get_pins {u_host/u_system/u_ingress/req_sync1~FF|D u_host/u_system/u_ingress/done_sync1~FF|D u_host/u_system/u_ingress/bad_sync1~FF|D u_host/u_system/u_camera_snapshot/req_sync1_q~FF|D}] 5.000
set_false_path -hold -from [get_clocks camera_clk] -to [get_pins {u_host/u_system/u_ingress/req_sync1~FF|D u_host/u_system/u_ingress/done_sync1~FF|D u_host/u_system/u_ingress/bad_sync1~FF|D u_host/u_system/u_camera_snapshot/req_sync1_q~FF|D}]
set_max_delay -from [get_clocks core_clk] -to [get_pins {u_host/u_system/u_ingress/ack_sync1~FF|D u_host/u_system/u_ingress/enable_sync1~FF|D u_host/u_system/u_ingress/cancel_sync1~FF|D u_host/u_system/u_camera_snapshot/ack_sync1_q~FF|D}] 5.000
set_false_path -hold -from [get_clocks core_clk] -to [get_pins {u_host/u_system/u_ingress/ack_sync1~FF|D u_host/u_system/u_ingress/enable_sync1~FF|D u_host/u_system/u_ingress/cancel_sync1~FF|D u_host/u_system/u_camera_snapshot/ack_sync1_q~FF|D}]

# Held bundles: tag follows request; error code follows source_bad; latest
# snapshot follows request. Each is held until the returned ACK. 5 ns is
# deliberately below even one destination cycle; validate actual data delay
# too because Efinity set_max_delay includes launch/capture clock latency.
set_max_delay -from [get_pins {u_host/u_system/u_ingress/source_tag[*]~FF|CLK}] -to [get_pins {u_host/u_system/capture_tag[*]~FF|D}] 5.000
set_false_path -hold -from [get_pins {u_host/u_system/u_ingress/source_tag[*]~FF|CLK}] -to [get_pins {u_host/u_system/capture_tag[*]~FF|D}]
set_max_delay -from [get_pins {u_host/u_system/u_ingress/source_code[*]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/failed_code[*]~FF|D camera_result_code[*]~FF|D}] 5.000
set_false_path -hold -from [get_pins {u_host/u_system/u_ingress/source_code[*]~FF|CLK}] -to [get_pins {u_host/u_system/u_ingress/failed_code[*]~FF|D camera_result_code[*]~FF|D}]
set_max_delay -from [get_pins {u_host/u_system/u_camera_snapshot/payload_q[*]~FF|CLK}] -to [get_pins {camera_seen[*]~FF|D camera_skipped[*]~FF|D camera_fifo_peak[*]~FF|D u_host/u_system/camera_snapshot[*]~FF|D}] 5.000
set_false_path -hold -from [get_pins {u_host/u_system/u_camera_snapshot/payload_q[*]~FF|CLK}] -to [get_pins {camera_seen[*]~FF|D camera_skipped[*]~FF|D camera_fifo_peak[*]~FF|D u_host/u_system/camera_snapshot[*]~FF|D}]


