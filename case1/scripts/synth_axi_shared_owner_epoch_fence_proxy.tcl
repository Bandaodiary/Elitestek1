# Compact Artix-7 proxy for the shared read/write owner/epoch fence.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_file [file join $case_root rtl dma c1_axi_shared_owner_epoch_fence.sv]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_axi_shared_owner_epoch_fence_proxy -part xc7a200tsbg484-1
read_verilog -sv $rtl_file
synth_design -top c1_axi_shared_owner_epoch_fence -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {EPOCH_W=4 REQUIRE_CONTEXT=1 ALLOW_RESTART=1}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
puts "C1_AXI_SHARED_OWNER_EPOCH_FENCE_PROXY_SYNTH_PASS"
close_project
