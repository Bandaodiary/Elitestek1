# Boardless Vivado proxy for the optional tensor client-6 burst/refill seam.
#
# The top is the real client wrapper.  No DDR controller, seven-client
# arbiter, camera, video or board-specific primitive is included; this report
# is only a structural LUT/FF/BRAM/timing reference for the staged seam.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_tensor_window_cache_burst_client_proxy \
    -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root cnn c1_window_line_cache_c8.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_read_burst_client.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler_read_client.sv] \
    [file join $rtl_root dma c1_cache_refill_completion_adapter.sv] \
    [file join $rtl_root dma c1_cache_refill_scheduler_read_client_exact.sv] \
    [file join $rtl_root dma c1_window_line_cache_c8_exact_burst_shell.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_bridge.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_write_burst_client.sv] \
    [file join $rtl_root dma c1_tensor_mem_axi128_packing_bridge.sv] \
    [file join $rtl_root dma c1_tensor_window_cache_burst_axi_client.sv]]

# Keep the storage-format A/B explicit.  Beat mode stores one AXI128 beat plus
# lane metadata per response record; the default logical mode stores a full
# logical refill record.  The environment knob is set only by the detached
# runner, so the historical baseline remains deterministic.
set rsp_fifo_beat_mode 0
set rsp_fifo_depth 128
if {[info exists ::env(C1_PROXY_BEAT_MODE)] &&
    $::env(C1_PROXY_BEAT_MODE) ne "" &&
    $::env(C1_PROXY_BEAT_MODE) ne "0"} {
    set rsp_fifo_beat_mode 1
    set rsp_fifo_depth 64
}
if {[info exists ::env(C1_PROXY_RSP_FIFO_DEPTH)] &&
    $::env(C1_PROXY_RSP_FIFO_DEPTH) ne ""} {
    set rsp_fifo_depth [expr {int($::env(C1_PROXY_RSP_FIFO_DEPTH))}]
}

set synth_args [list synth_design -top c1_tensor_window_cache_burst_axi_client \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt \
    -generic [list BURST_LINE_ROWS=3 BURST_MAX_ROW_WORDS=1280 \
        BURST_MAX_GROUPS=8 BURST_EPOCH_W=8 BURST_CMD_FIFO_DEPTH=2 \
        BURST_SCHED_MAX_OUTSTANDING=16 BURST_REQ_FIFO_DEPTH=32 \
        BURST_BEATS=16 BURST_READER_MAX_OUTSTANDING=4 \
        BURST_RSP_FIFO_DEPTH=$rsp_fifo_depth BURST_BUILD_TIMEOUT_CYCLES=4 \
        BURST_ALLOW_SAME_LANE_DUP=1 BURST_RSP_FIFO_BEAT_MODE=$rsp_fifo_beat_mode \
        BURST_ALLOW_RSP_POP_REFILL=0 BURST_ALLOW_REQ_POP_REFILL=0 \
        BURST_CANCEL_IS_PROTOCOL_ERROR=0 BURST_REFILL_SKID_DEPTH=2]]
# Optional A/B knob.  It is intentionally absent in the default run, so the
# baseline report remains comparable.  Vivado may replicate high-fanout
# control cones when this limit is supplied; this is a timing experiment, not
# a functional configuration.
if {[info exists ::env(C1_PROXY_FANOUT_LIMIT)] &&
    $::env(C1_PROXY_FANOUT_LIMIT) ne "" &&
    $::env(C1_PROXY_FANOUT_LIMIT) ne "0"} {
    lappend synth_args -fanout_limit $::env(C1_PROXY_FANOUT_LIMIT)
}
eval $synth_args
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 5 \
    -file [file join $report_root utilization_hierarchical.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 10 \
    -file [file join $report_root timing_paths.rpt]
puts "C1_TENSOR_WINDOW_CACHE_BURST_CLIENT_PROXY_SYNTH_PASS beat_mode=$rsp_fifo_beat_mode rsp_fifo_depth=$rsp_fifo_depth"
close_project
