# Boardless Artix-7 synthesis proxy for the complete three-row C8 cache.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

# Win32_Process workers do not inherit a settings64 shell.  The matching
# PowerShell runner stages Vivado's runtime Tcl beneath the workspace so that
# synthesis helpers do not depend on cloud-placeholder files in the install.
set vivado_root "D:/vivado/vivado/Vivado/2023.1"
set local_rt_root [file normalize [file join $case_root .vivado_rt]]
set staged_rt_root [file join $local_rt_root scripts rt]
set ::env(XILINX_VIVADO) $vivado_root
set ::env(RDI_APPROOT) $vivado_root
set ::env(RDI_PATCHROOT) $local_rt_root
set ::env(XILINX_PATH) $local_rt_root
set ::env(RT_LIBPATH) [file join $staged_rt_root data]
set ::env(SYNTH_COMMON) $::env(RT_LIBPATH)
set ::env(RT_TCL_PATH) [file join $staged_rt_root base_tcl tcl]

foreach required_file [list \
    [file join $::env(RT_LIBPATH) unimacro unimacro_verilog.tcl] \
    [file join $::env(RT_LIBPATH) unimacro unimacro_vhdl.tcl]] {
    if {![file readable $required_file]} {
        error "staged Vivado runtime file is not readable: $required_file"
    }
}

set_param general.maxThreads 1
set_param synth.maxThreads 1

create_project -in_memory c1_window_line_cache_c8_proxy \
    -part xc7a200tsbg484-1
read_verilog -sv [file join $rtl_root cnn c1_window_line_cache_c8.sv]
synth_design -top c1_window_line_cache_c8 -part xc7a200tsbg484-1 \
    -generic [list DATA_W=64 LINE_ROWS=3 MAX_ROW_WORDS=1280 MAX_GROUPS=8] \
    -flatten_hierarchy rebuilt
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
close_project
puts "C1_WINDOW_LINE_CACHE_C8_PROXY_SYNTH_PASS data_w=64 line_rows=3 max_row_words=1280 max_groups=8 clock_mhz=100"

