# Compact Artix-7 proxy for the observation-only seven-client QoS monitor.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_axi_shared_qos_monitor.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
# This proxy is intentionally single-process.  Disabling Vivado's helper
# spawn avoids an unnecessary runtime-package dependency and keeps the short
# measurement deterministic on hosts where the installed Tcl tree is lazy.
set_param synth.enableParallelHelperSpawn none
create_project -in_memory c1_axi_shared_qos_monitor_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_axi_shared_qos_monitor -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {CLIENTS=7 INDEX_W=3 COUNTER_W=24}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 10 -file [file join $report_root timing_paths.rpt]
puts "C1_AXI_SHARED_QOS_MONITOR_PROXY_SYNTH_PASS"
close_project
