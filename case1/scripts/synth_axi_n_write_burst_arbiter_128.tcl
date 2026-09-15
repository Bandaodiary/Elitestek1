# Synthesis-only Artix-7 proxy for the optional multi-descriptor write
# arbiter.  This is a structural estimate; Ti60/Efinity mapping is still
# required before making a board resource claim.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_axi_n_write_burst_arbiter_128.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_axi_n_write_burst_arbiter_128_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_axi_n_write_burst_arbiter_128 -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt -generic {CLIENTS=3 FIFO_DEPTH=4}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_AXI_N_WRITE_BURST_ARBITER_PROXY_SYNTH_PASS"
close_project
