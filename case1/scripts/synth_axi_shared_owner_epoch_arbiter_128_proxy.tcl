# Compact Artix-7 proxy for the optional shared owner/epoch arbiter shell.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl dma]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set proxy_clients 2
set proxy_read_skid 0
if {[info exists ::env(C1_PROXY_CLIENTS)]} {
    set proxy_clients [expr {int($::env(C1_PROXY_CLIENTS))}]
}
if {[info exists ::env(C1_PROXY_READ_SKID)]} {
    set proxy_read_skid [expr {int($::env(C1_PROXY_READ_SKID))}]
}
set proxy_index_w [expr {($proxy_clients <= 1) ? 1 : int(ceil(log($proxy_clients)/log(2.0)))}]
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_axi_shared_owner_epoch_arbiter_128_proxy -part xc7a200tsbg484-1
read_verilog -sv \
    [file join $rtl_root c1_axi_shared_owner_epoch_fence.sv] \
    [file join $rtl_root c1_axi_n_serial_arbiter_128.sv] \
    [file join $rtl_root c1_axi_shared_owner_epoch_arbiter_128.sv]
synth_design -top c1_axi_shared_owner_epoch_arbiter_128 -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic [list CLIENTS=$proxy_clients INDEX_W=$proxy_index_w \
        READ_RESPONSE_SKID=$proxy_read_skid EPOCH_W=4 REQUIRE_CONTEXT=1 ALLOW_RESTART=1]
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $report_root timing.rpt]
puts "C1_AXI_SHARED_OWNER_EPOCH_ARBITER_128_PROXY_SYNTH_PASS"
close_project
