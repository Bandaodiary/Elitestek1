# Vivado is used only as a vendor-neutral proxy synthesis sanity check.
# The final resource/timing sign-off must come from Efinity targeting Ti60.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set sources [list \
    [file join $rtl_root common c1_fixed_pkg.sv] \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root common c1_window3x3.sv] \
    [file join $rtl_root video c1_black_level_raw10.sv] \
    [file join $rtl_root video c1_debayer_rggb10_valid.sv] \
    [file join $rtl_root video c1_color_correct.sv] \
    [file join $rtl_root video c1_gamma_lut16.sv] \
    [file join $rtl_root video c1_rgb_decimate.sv] \
    [file join $rtl_root video c1_isp_pipeline.sv] \
    [file join $rtl_root cnn c1_conv3x3_rgb3.sv] \
    [file join $rtl_root cnn c1_dwconv3x3_rgb3.sv] \
    [file join $rtl_root cnn c1_pwconv1x1_rgb3.sv] \
    [file join $rtl_root cnn c1_style_cnn3.sv] \
    [file join $rtl_root top c1_pixel_pipeline_top.sv]]

read_verilog -sv $sources
synth_design -top c1_pixel_pipeline_top -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
create_clock -name core_clk -period 10.000 [get_ports clk]
report_utilization -file [file join $case_root logs vivado_proxy_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $case_root logs vivado_proxy_timing.rpt]
write_checkpoint -force [file join $case_root sim c1_pixel_pipeline_proxy.dcp]
puts "C1_PROXY_SYNTH_PASS"
