# Boardless Vivado proxy for the exact-count cache-refill composition.
# This is intentionally a control/data-path boundary estimate only: no DDR,
# line-cache RAM, vendor IP, or board constraints are included.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl dma]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_cache_refill_scheduler_read_client_exact_proxy \
    -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root c1_cache_refill_scheduler.sv] \
    [file join $rtl_root c1_tensor_mem_axi128_read_burst_client.sv] \
    [file join $rtl_root c1_cache_refill_scheduler_read_client.sv] \
    [file join $rtl_root c1_cache_refill_completion_adapter.sv] \
    [file join $rtl_root c1_cache_refill_scheduler_read_client_exact.sv]]

synth_design -top c1_cache_refill_scheduler_read_client_exact \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt \
    -generic [list ADDR_W=32 DATA_W=64 EPOCH_W=4 CMD_FIFO_DEPTH=8 \
        SCHED_MAX_OUTSTANDING=16 REQ_FIFO_DEPTH=32 BURST_BEATS=16 \
        READER_MAX_OUTSTANDING=4 RSP_FIFO_DEPTH=128 \
        BUILD_TIMEOUT_CYCLES=4 ALLOW_SAME_LANE_DUP=1 \
        RSP_FIFO_BEAT_MODE=0 ALLOW_RSP_POP_REFILL=0 \
        ALLOW_REQ_POP_REFILL=0]
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $report_root utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_root timing.rpt]
puts "C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PROXY_SYNTH_PASS"
close_project
