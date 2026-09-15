# Structural proxy for the standalone tensor packing prototype.
# This is an Artix-7 trend only; Ti60/Efinity sign-off remains separate.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_perf_packer_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root dma c1_tensor_mem_axi128_packer.sv]]
synth_design -top c1_tensor_mem_axi128_packer \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_TENSOR_PERF_PACKER_PROXY_SYNTH_PASS"
close_project
