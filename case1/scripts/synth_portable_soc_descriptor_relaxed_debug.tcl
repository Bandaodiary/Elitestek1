# Debug-only structural proxy for isolating the Vivado failure point in the
# relaxed descriptor-validation configuration.  This intentionally stops
# after synthesis and utilization; the production proxy remains in
# synth_portable_soc_descriptor_relaxed_proxy.tcl.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set part xc7a200tsbg484-1
set top c1_r1_portable_soc

proc collect_sv {dir} {
    set result [list]
    foreach f [glob -nocomplain -types f -directory $dir *.sv] { lappend result [file normalize $f] }
    foreach d [glob -nocomplain -types d -directory $dir *] { set result [concat $result [collect_sv $d]] }
    return $result
}
set package_sources [list \
    [file join $rtl_root common c1_fixed_pkg.sv] \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_frame_buffer_pkg.sv]]
set sources $package_sources
foreach f [collect_sv $rtl_root] {
    if {[lsearch -exact $package_sources $f] < 0} { lappend sources $f }
}

puts "RELAXED_DEBUG_BEFORE_PROJECT"
create_project -in_memory portable_soc_descriptor_relaxed_debug -part $part
read_verilog -sv $sources
puts "RELAXED_DEBUG_BEFORE_SYNTH"
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -generic [list FRAME_WIDTH=640 FRAME_HEIGHT=480 \
                   ENABLE_TENSOR_WINDOW_CACHE=0 \
                   ENABLE_DISPLAY_RESPONSE_FIFO=1 \
                   DISPLAY_RESPONSE_FIFO_DEPTH=128 \
                   STRICT_DESCRIPTOR_VALIDATION=0]
puts "RELAXED_DEBUG_AFTER_SYNTH"
create_clock -name core_clk -period 10.000 [get_ports core_clk]
create_clock -name pixel_clk -period 14.000 [get_ports pixel_clk]
create_clock -name camera_clk -period 20.000 [get_ports camera_clk]
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks pixel_clk] \
    -group [get_clocks camera_clk]
puts "RELAXED_DEBUG_BEFORE_UTIL"
report_utilization -hierarchical -file [file join $report_root relaxed_debug_utilization.rpt]
puts "RELAXED_DEBUG_AFTER_UTIL"
puts "RELAXED_DEBUG_BEFORE_TIMING"
# report_timing is intentionally used here instead of report_timing_summary:
# Vivado 2023.1 can terminate abnormally while summarizing this relaxed
# netlist, whereas the direct path report is sufficient for the proxy delta.
report_timing -delay_type max -max_paths 20 -file [file join $report_root relaxed_debug_timing.rpt]
puts "RELAXED_DEBUG_AFTER_TIMING"
close_project
puts "RELAXED_DEBUG_PASS"
