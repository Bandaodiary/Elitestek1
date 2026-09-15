# Small proxy synthesis for the optional beat-record response FIFO.
# Reports are emitted under the detached worker's private run directory.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_tensor_mem_axi128_read_burst_client.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_mem_axi128_read_burst_client_beatfifo_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_tensor_mem_axi128_read_burst_client -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {REQ_FIFO_DEPTH=16 BURST_BEATS=16 MAX_OUTSTANDING=4 RSP_FIFO_DEPTH=64 BUILD_TIMEOUT_CYCLES=4 ALLOW_SAME_LANE_DUP=1 RSP_FIFO_BEAT_MODE=1}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
puts "C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_SYNTH_PASS"
close_project
