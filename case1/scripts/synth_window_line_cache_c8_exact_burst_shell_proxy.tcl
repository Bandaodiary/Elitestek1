# Boardless Vivado proxy for the exact-count C8 line-cache shell.
#
# This deliberately synthesizes the real line-cache RAM plus the read-only
# scheduler/AXI128/ completion path, but no DDR controller, write channel,
# SoC interconnect, or board constraints.  The report is a structural upper
# bound for the staged seam, not a Ti60/Efinity sign-off.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_window_line_cache_c8_exact_burst_shell_proxy \
    -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root cnn c1_window_line_cache_c8.sv] \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root common c1_row_banked_ram.sv] \
    [file join $rtl_root cnn c1_column_line_cache_c8.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_read_burst_client.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler_read_client.sv] \
    [file join $rtl_root dma c1_cache_refill_completion_adapter.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler_read_client_exact.sv] \
    [file join $rtl_root dma c1_window_line_cache_c8_exact_burst_shell.sv]]

synth_design -top c1_window_line_cache_c8_exact_burst_shell \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt \
    -generic [list DATA_W=64 LINE_ROWS=3 MAX_ROW_WORDS=1280 MAX_GROUPS=8 \
        EPOCH_W=4 CMD_FIFO_DEPTH=8 SCHED_MAX_OUTSTANDING=16 \
        REQ_FIFO_DEPTH=32 BURST_BEATS=16 READER_MAX_OUTSTANDING=4 \
        RSP_FIFO_DEPTH=128 BUILD_TIMEOUT_CYCLES=4 \
        ALLOW_SAME_LANE_DUP=1 RSP_FIFO_BEAT_MODE=0 \
        ALLOW_RSP_POP_REFILL=0 ALLOW_REQ_POP_REFILL=0 REFILL_SKID_DEPTH=2]
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 5 \
    -file [file join $report_root utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 10 \
    -file [file join $report_root timing_paths.rpt]
puts "C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PROXY_SYNTH_PASS"
close_project
