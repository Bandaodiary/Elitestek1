# Vivado Artix-7 structural/timing proxy for the standalone pipelined C8 DW
# core.  Ti60 sign-off remains an Efinity task.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1

create_project -in_memory c1_dwconv3x3_c8_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dwconv3x3_c8_requant_core.sv]]
synth_design -top c1_dwconv3x3_c8_requant_core \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
create_clock -name core_clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_DWCONV3X3_C8_PROXY_SYNTH_PASS"
close_project
