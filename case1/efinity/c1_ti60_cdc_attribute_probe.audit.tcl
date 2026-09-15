# Runs only after PNR in the detached worker's private output directory.
set output_dir $::env(C27_AUDIT_OUT)
set source [get_pins {src_q~FF|CLK}]
set first [get_pins {lower_a0~FF|D lower_b0~FF|D upper_a0~FF|D upper_b0~FF|D plain_a0~FF|D}]
set second [get_pins {observed[*]~FF|D}]
puts "C27_MATCH source=[llength $source] first=[llength $first] second=[llength $second]"
if {[llength $source] != 1 || [llength $first] != 5 || [llength $second] != 5} {error "C27 unexpected register/pin mapping"}
report_cdc -details -file $output_dir/c27_cdc.rpt
report_bus_skew -setup -npaths 5 -nworst 1 -file $output_dir/c27_bus_setup.rpt
report_bus_skew -hold -npaths 5 -nworst 1 -file $output_dir/c27_bus_hold.rpt
# report_timing resolves -file relative to --output_dir (unlike report_cdc).
report_timing -setup -npaths 10 -file c27_setup.rpt
report_timing -hold -npaths 10 -file c27_hold.rpt
puts "C27_AUDIT_PASS"
