# Artix-7 proxy synthesis for the four-bank MAC scaling point.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1
create_project -in_memory c1_dot8x8_requant_pingpong_banks4_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root cnn c1_s8_dot8_accum.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_pipelined.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_treepipe.sv] \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_core.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_bank.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_pingpong.sv]]
synth_design -top c1_dot8x8_requant_pingpong -part xc7a200tsbg484-1 \
    -flatten_hierarchy rebuilt \
    -generic {BANKS=4 LANES=2 X_BITS=16 Y_BITS=16 \
              PIPELINED_DOT_TREE=1 PIPELINED_DOT_TREE_FULL=1 TAG_FIFO_DEPTH=16}
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
report_timing -delay_type max -max_paths 3 -nworst 3 \
    -file [file join $report_root critical.rpt]
puts "C1_DOT8X8_REQUANT_PINGPONG_BANKS4_PROXY_SYNTH_PASS"
close_project
