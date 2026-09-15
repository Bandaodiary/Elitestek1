# Boardless Vivado proxy for the read-only cache-refill scheduler seam.
# The parameters approximate the intended native integration but deliberately
# keep the design independent of the full portable SoC and vendor IP.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_cache_refill_scheduler.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_cache_refill_scheduler_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_cache_refill_scheduler -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {ADDR_W=32 DATA_W=64 EPOCH_W=4 CMD_FIFO_DEPTH=8 MAX_OUTSTANDING=4}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
puts "C1_CACHE_REFILL_SCHEDULER_PROXY_SYNTH_PASS"
close_project
