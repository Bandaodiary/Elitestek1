# Boardless Vivado synthesis proxy for the composed cache-refill path.
#
# The top is intentionally only the scheduler + AXI128 read leaf wrapper;
# no SoC, DDR controller, vendor IP, or board constraints are pulled in.
# Parameters are chosen to represent the next integration point:
#   scheduler credit 16 logical words, reader credit 4 AXI bursts,
#   32-entry logical request FIFO, and 16-beat maximum AXI bursts.
# EMIT_DRAIN_WORDS=1 keeps the canceled-response drain path in the resource
# estimate; set it to zero in a later compatibility build if the sink can
# discard stale responses itself.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set scheduler_file [file join $case_root rtl dma c1_cache_refill_scheduler.sv]
set reader_file [file join $case_root rtl dma c1_tensor_mem_axi128_read_burst_client.sv]
set wrapper_file [file join $case_root rtl dma c1_cache_refill_scheduler_read_client.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_cache_refill_scheduler_read_client_proxy -part xc7a200tsbg484-1
read_verilog -sv $scheduler_file
read_verilog -sv $reader_file
read_verilog -sv $wrapper_file

synth_design -top c1_cache_refill_scheduler_read_client -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {ADDR_W=32 DATA_W=64 EPOCH_W=4 CMD_FIFO_DEPTH=8 \
              SCHED_MAX_OUTSTANDING=16 EMIT_DRAIN_WORDS=1 \
              REQ_FIFO_DEPTH=32 BURST_BEATS=16 READER_MAX_OUTSTANDING=4 \
              RSP_FIFO_DEPTH=128 BUILD_TIMEOUT_CYCLES=4 \
              ALLOW_SAME_LANE_DUP=1 RSP_FIFO_BEAT_MODE=0 \
              ALLOW_RSP_POP_REFILL=0 ALLOW_REQ_POP_REFILL=0}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $report_root timing.rpt]
puts "C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PROXY_SYNTH_PASS"
close_project
