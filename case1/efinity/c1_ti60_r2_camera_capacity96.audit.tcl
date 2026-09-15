# Bounded, post-route CDC inventory. PASS means extraction/counts succeeded,
# NOT that timing, CDC, asynchronous reset or external interfaces are signed off.
set output_dir $::env(C27_AUDIT_OUT)
proc check_pins {name pattern count} {
    set pins [get_pins $pattern]
    puts "C27_MATCH $name=[llength $pins] expected=$count"
    if {[llength $pins] != $count} {error "C27 missing/extra mapped pins: $name"}
}
check_pins wr_gray {u_host/u_system/u_ingress/u_fifo/wr_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/wr_bin[9]~FF|CLK} 10
check_pins rd_gray {u_host/u_system/u_ingress/u_fifo/rd_gray[*]~FF|CLK u_host/u_system/u_ingress/u_fifo/rd_bin[9]~FF|CLK} 10
check_pins wr_first {u_host/u_system/u_ingress/u_fifo/wr_sync1[*]~FF|D} 10
check_pins rd_first {u_host/u_system/u_ingress/u_fifo/rd_sync1[*]~FF|D} 10
check_pins wr_second {u_host/u_system/u_ingress/u_fifo/wr_sync2[*]~FF|D} 10
check_pins rd_second {u_host/u_system/u_ingress/u_fifo/rd_sync2[*]~FF|D} 10
check_pins cam_control {u_host/u_system/u_ingress/req_sync1~FF|D u_host/u_system/u_ingress/done_sync1~FF|D u_host/u_system/u_ingress/bad_sync1~FF|D u_host/u_system/u_camera_snapshot/req_sync1_q~FF|D} 4
check_pins core_control {u_host/u_system/u_ingress/ack_sync1~FF|D u_host/u_system/u_ingress/enable_sync1~FF|D u_host/u_system/u_ingress/cancel_sync1~FF|D u_host/u_system/u_camera_snapshot/ack_sync1_q~FF|D} 4
check_pins tag_source {u_host/u_system/u_ingress/source_tag[*]~FF|CLK} 32
check_pins tag_destination {u_host/u_system/capture_tag[*]~FF|D} 32
check_pins code_source {u_host/u_system/u_ingress/source_code[*]~FF|CLK} 3
check_pins code_destination {u_host/u_system/u_ingress/failed_code[*]~FF|D camera_result_code[*]~FF|D} 6
check_pins snapshot_source {u_host/u_system/u_camera_snapshot/payload_q[*]~FF|CLK} 75
check_pins snapshot_destination {camera_seen[*]~FF|D camera_skipped[*]~FF|D camera_fifo_peak[*]~FF|D u_host/u_system/camera_snapshot[*]~FF|D} 75
# Full report_cdc crashes this Efinity build with Internal Assertion IsValid.
# Run it in a SEPARATE optional STA process after mandatory timing extraction;
# its failure must remain visible and is never reported as CDC sign-off.
check_pins source_controls {u_host/u_system/u_ingress/enable_source_q~FF|CLK u_host/u_system/u_ingress/cancel_source_q~FF|CLK} 2
report_bus_skew -setup -npaths 20 -nworst 1 -file $output_dir/c27_bus_setup.rpt
report_bus_skew -hold -npaths 20 -nworst 1 -file $output_dir/c27_bus_hold.rpt
# report_timing -file is relative to Efinity's outflow directory.
report_timing -setup -npaths 20 -nworst 1 -file c27_setup.rpt
report_timing -hold -npaths 20 -nworst 1 -file c27_hold.rpt
report_timing -setup -from_clock core_clk -to_clock core_clk -npaths 10 -nworst 1 -file c27_core_setup.rpt
report_timing -hold -from_clock core_clk -to_clock core_clk -npaths 10 -nworst 1 -file c27_core_hold.rpt
report_timing -setup -from_clock camera_clk -to_clock camera_clk -npaths 10 -nworst 1 -file c27_camera_setup.rpt
report_timing -hold -from_clock camera_clk -to_clock camera_clk -npaths 10 -nworst 1 -file c27_camera_hold.rpt
# Up to 200 unique endpoints per direction; keep data delays and exceptions
# for independent review rather than trusting the two-clock geomean Fmax.
report_timing -setup -from_clock camera_clk -to_clock core_clk -npaths 200 -nworst 1 -file c27_camera_to_core.rpt
report_timing -setup -from_clock core_clk -to_clock camera_clk -npaths 200 -nworst 1 -file c27_core_to_camera.rpt
puts "C27_AUDIT_PASS"
