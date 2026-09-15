# Board-independent Vivado proxy for the parallel 8x8 INT8 output-group bank.
#
# This is a structural Artix-7 estimate only; Ti60/Efinity timing and the
# bank's upstream scheduler/AXI bandwidth are intentionally out of scope.
# The detached PowerShell launcher removes the private report tree after it
# extracts a small utilization/timing summary.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1

set part xc7a200tsbg484-1
set lanes 2
if {[llength $argv] >= 1} {
    set lanes [expr {int([lindex $argv 0])}]
}
if {$lanes < 1 || $lanes > 16} {
    error "LANES must be in 1..16"
}

set sources [list \
    [file join $rtl_root cnn c1_s8_dot8_accum.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_pipelined.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_treepipe.sv] \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_core.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_bank.sv]]

create_project -in_memory c1_dot8x8_requant_bank_proxy -part $part
read_verilog -sv $sources
synth_design -top c1_dot8x8_requant_bank -part $part \
    -flatten_hierarchy rebuilt \
    -generic [list LANES=$lanes X_BITS=16 Y_BITS=16 \
                   PIPELINED_DOT_TREE=0 PIPELINED_DOT_TREE_FULL=0]
create_clock -name core_clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_DOT8X8_BANK_PROXY_SYNTH_PASS lanes=$lanes part=$part"
close_project
