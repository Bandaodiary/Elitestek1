# Bounded post-route audit; all reports are from this run's routed database.
# Physical IO delays/reset/PLL/PHY still require the board integration project.
report_timing -setup -npaths 20 -nworst 1 -file c40_setup.rpt
report_timing -hold -npaths 20 -nworst 1 -file c40_hold.rpt
report_timing -setup -from_clock core_clk -to_clock core_clk -npaths 10 -nworst 1 -file c40_core_setup.rpt
report_timing -hold -from_clock core_clk -to_clock core_clk -npaths 10 -nworst 1 -file c40_core_hold.rpt
report_timing -setup -from_clock camera_clk -to_clock camera_clk -npaths 10 -nworst 1 -file c40_camera_setup.rpt
report_timing -hold -from_clock camera_clk -to_clock camera_clk -npaths 10 -nworst 1 -file c40_camera_hold.rpt
report_timing -setup -from_clock camera_clk -to_clock core_clk -npaths 100 -nworst 1 -file c40_camera_to_core.rpt
report_timing -setup -from_clock core_clk -to_clock camera_clk -npaths 100 -nworst 1 -file c40_core_to_camera.rpt
report_bus_skew -setup -npaths 20 -nworst 1 -file $::env(C40_TIMING_OUT)/c40_bus_setup.rpt
report_bus_skew -hold -npaths 20 -nworst 1 -file $::env(C40_TIMING_OUT)/c40_bus_hold.rpt
puts "C40_TIMING_AUDIT_PASS"
