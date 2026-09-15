# Artix-7 proxy synthesis for the optional parallel write fabric.
# This is a structural estimate only; Ti60/Efinity mapping and DDR timing
# remain separate gates.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_mem_axi128_write_parallel_fabric_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root dma c1_tensor_mem_axi128_write_burst_client.sv] \
    [file join $rtl_root dma c1_axi_n_write_burst_arbiter_128.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_write_parallel_fabric.sv]]
synth_design -top c1_tensor_mem_axi128_write_parallel_fabric -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {LANES=2 BLOCK_LOGICAL=16 REQ_FIFO_DEPTH=32 BURST_BEATS=16 \
              RSP_FIFO_DEPTH=32 FABRIC_FIFO_DEPTH=4 TAG_FIFO_DEPTH=64 \
              BUILD_TIMEOUT_CYCLES=4}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 3 -nworst 3 \
    -file [file join $report_root critical.rpt]
puts "C1_TENSOR_MEM_AXI128_WRITE_PARALLEL_FABRIC_PROXY_SYNTH_PASS"
close_project
