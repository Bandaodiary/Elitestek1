# Vivado structural proxy for the dispatcher-compatible MicroStyle CNN top.
# Ti60 resource/timing sign-off remains an Efinity task.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
create_project -in_memory c1_microstyle_cnn_proxy -part xc7a200tsbg484-1
read_verilog -sv [list \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_layer_command_decoder.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_pipelined.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_treepipe.sv] \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_core.sv] \
    [file join $rtl_root cnn c1_dwconv3x3_c8_requant_core.sv] \
    [file join $rtl_root cnn c1_r1_c8_parameter_scheduler.sv] \
    [file join $rtl_root cnn c1_r1_microstyle_engine.sv] \
    [file join $rtl_root cnn c1_r1_microstyle_cnn_top.sv]]
synth_design -top c1_r1_microstyle_cnn_top \
    -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
create_clock -name core_clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_MICROSTYLE_CNN_TOP_PROXY_SYNTH_PASS"
close_project
