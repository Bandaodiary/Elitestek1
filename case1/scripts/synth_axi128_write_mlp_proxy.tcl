# Artix-7 proxy synthesis for the optional descriptor-level write MLP seam.
# This is a boardless structural estimate; Ti60/Efinity mapping and DDR
# timing remain separate gates.  The small default generics keep the report
# bounded while retaining four descriptors of sixteen AXI beats each.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_axi128_write_mlp_proxy -part xc7a200tsbg484-1
read_verilog -sv [list [file join $rtl_root dma c1_axi128_write_mlp.sv]]
synth_design -top c1_axi128_write_mlp -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {MAX_OUTSTANDING=4 MAX_BEATS=16 RSP_FIFO_DEPTH=4 TAG_WIDTH=16}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 3 -nworst 3 \
    -file [file join $report_root critical.rpt]
puts "C1_AXI128_WRITE_MLP_PROXY_SYNTH_PASS"
close_project
