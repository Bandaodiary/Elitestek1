# Small synthesis-only check for the board-independent read burst client.
# Reports are written in the caller's private run directory.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_tensor_mem_axi128_read_burst_client.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_mem_axi128_read_burst_client_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_tensor_mem_axi128_read_burst_client -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
puts "C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_SYNTH_PASS"
close_project
