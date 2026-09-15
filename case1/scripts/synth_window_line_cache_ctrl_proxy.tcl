# Synthesis proxy for the boardless row-tag/refill control shell.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
# The detached worker may not inherit Vivado's interactive environment.  Set
# the synthesis script roots explicitly so synth_design can load its runtime
# Tcl helpers even when no settings64 shell has been sourced in the parent.
set vivado_root "D:/vivado/vivado/Vivado/2023.1"
set local_rt_root [file normalize [file join $case_root .vivado_rt]]
set ::env(XILINX_VIVADO) $vivado_root
set ::env(RDI_APPROOT) $vivado_root
set ::env(RDI_PATCHROOT) $local_rt_root
set ::env(XILINX_PATH) $local_rt_root
set ::env(RT_LIBPATH) [file join $vivado_root scripts rt data]
set ::env(SYNTH_COMMON) $::env(RT_LIBPATH)
set ::env(RT_TCL_PATH) [file join $vivado_root scripts rt base_tcl tcl]
set_param general.maxThreads 1
set_param synth.maxThreads 1

create_project -in_memory c1_window_line_cache_ctrl_proxy -part xc7a200tsbg484-1
read_verilog -sv [file join $rtl_root cnn c1_window_line_cache_ctrl.sv]
synth_design -top c1_window_line_cache_ctrl -part xc7a200tsbg484-1 \
    -generic {LINE_ROWS=3} -flatten_hierarchy rebuilt
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
close_project
puts "C1_WINDOW_LINE_CACHE_CTRL_PROXY_SYNTH_PASS line_rows=3"
