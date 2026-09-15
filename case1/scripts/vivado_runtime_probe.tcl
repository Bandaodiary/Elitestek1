set_param general.maxThreads 1
set_param synth.maxThreads 1
set part xc7a200tsbg484-1
set src [file normalize [file join [file dirname [info script]] vivado_runtime_probe_top.v]]
set rpt [file normalize [file join [pwd] probe_reports]]
file mkdir $rpt
puts "PROBE_PARENT_PWD=[pwd]"
puts "PROBE_PARENT_RT=[file readable D:/vivado/vivado/Vivado/2023.1/scripts/rt/data/unimacro/unimacro_vhdl.tcl]"
puts "PROBE_PARENT_SYNTH_COMMON=$::env(SYNTH_COMMON)"
read_verilog $src
synth_design -top vivado_runtime_probe_top -part $part -flatten_hierarchy rebuilt
report_utilization -file [file join $rpt utilization.rpt]
puts "C1_VIVADO_RUNTIME_PROBE_PASS"
close_design
