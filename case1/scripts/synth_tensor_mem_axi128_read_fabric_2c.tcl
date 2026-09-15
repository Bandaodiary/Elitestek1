# Artix-7 proxy synthesis for the integrated two-client read fabric.  The
# result is a board-independent structural estimate; Efinity/Ti60 mapping and
# DDR timing remain separate gates.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_mem_axi128_read_fabric_2c_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root dma c1_tensor_mem_axi128_read_burst_client.sv] \
    [file join $rtl_root dma c1_axi_n_read_burst_arbiter_128.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_read_fabric_2c.sv]]
synth_design -top c1_tensor_mem_axi128_read_fabric_2c -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {LEAF_REQ_FIFO_DEPTH=16 LEAF_BURST_BEATS=4 \
              LEAF_MAX_OUTSTANDING=4 LEAF_RSP_FIFO_DEPTH=64 \
              FABRIC_FIFO_DEPTH=8 BUILD_TIMEOUT_CYCLES=3}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_TENSOR_MEM_AXI128_READ_FABRIC_PROXY_SYNTH_PASS"
close_project
