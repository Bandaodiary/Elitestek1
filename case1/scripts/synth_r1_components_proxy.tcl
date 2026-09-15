# Vivado is only a structural proxy.  Ti60 resource/timing sign-off must use
# Efinity.  Each component is synthesized in a fresh in-memory project so one
# implementation cannot contaminate another component's utilization report.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

# This Windows installation intermittently fails to open its own Tcl files
# when synthesis launches the parallel helper.  Keep the proxy deterministic
# and single-threaded; functional xsim remains independent of this setting.
set_param general.maxThreads 1

set component_sources [dict create]
dict set component_sources c1_r1_isp_pipeline [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root common c1_window3x3.sv] \
    [file join $rtl_root video r1_blc_bayer4_u10.sv] \
    [file join $rtl_root video c1_r1_debayer_bilinear.sv] \
    [file join $rtl_root video r1_rgb10_color_pipeline.sv] \
    [file join $rtl_root video c1_r1_isp_pipeline.sv]]
dict set component_sources c1_r1_resize_pipeline [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root video r1_resize_request_q16.sv] \
    [file join $rtl_root video r1_bilinear_interp_rgb888.sv] \
    [file join $rtl_root video c1_r1_resize_system.sv] \
    [file join $rtl_root video c1_r1_resize_line_sampler.sv] \
    [file join $rtl_root video c1_r1_resize_pipeline.sv]]
dict set component_sources c1_dot8x8_requant_core [list \
    [file join $rtl_root cnn c1_requant_s8.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_pipelined.sv] \
    [file join $rtl_root cnn c1_s8_dot8_accum_treepipe.sv] \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dot8x8_requant_core.sv]]
dict set component_sources c1_dwconv3x3_c8_requant_core [list \
    [file join $rtl_root cnn c1_requant_bank8.sv] \
    [file join $rtl_root cnn c1_dwconv3x3_c8_requant_core.sv]]
dict set component_sources c1_s8_window3x3_same_c8 [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root cnn c1_s8_window3x3_same_c8.sv]]
dict set component_sources c1_s8_upsample2_c8 [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root cnn c1_s8_upsample2_c8.sv]]
dict set component_sources c1_residual_add_c8 [list \
    [file join $rtl_root cnn c1_residual_add_c8.sv]]
dict set component_sources c1_r1_parameter_bank [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root cnn c1_r1_parameter_bank.sv]]
dict set component_sources c1_r1_stage_config_bank [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root control c1_r1_stage_config_bank.sv]]
dict set component_sources c1_r1_compute_shell [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root video r1_resize_request_q16.sv] \
    [file join $rtl_root video r1_bilinear_interp_rgb888.sv] \
    [file join $rtl_root video c1_r1_resize_system.sv] \
    [file join $rtl_root video c1_r1_resize_line_sampler.sv] \
    [file join $rtl_root video c1_r1_resize_pipeline.sv] \
    [file join $rtl_root cnn c1_rgb_s8_center_codec.sv] \
    [file join $rtl_root cnn c1_r1_compute_ingress.sv] \
    [file join $rtl_root cnn c1_r1_compute_egress.sv] \
    [file join $rtl_root top c1_r1_rgb_source_mux.sv] \
    [file join $rtl_root top c1_r1_compute_shell.sv]]
dict set component_sources c1_axi_parameter_loader [list \
    [file join $rtl_root dma c1_axi_parameter_loader.sv]]
dict set component_sources c1_r1_config_dispatcher [list \
    [file join $rtl_root control c1_r1_config_dispatcher.sv]]
dict set component_sources c1_r1_job_frontend [list \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_frame_buffer_pkg.sv] \
    [file join $rtl_root dma c1_axi_descriptor_reader.sv] \
    [file join $rtl_root dma c1_axi_frame_buffer_table_reader.sv] \
    [file join $rtl_root dma c1_axi2_serial_arbiter_128.sv] \
    [file join $rtl_root control c1_layer_scheduler.sv] \
    [file join $rtl_root control c1_descriptor_scheduler_subsystem.sv] \
    [file join $rtl_root control c1_layer_command_decoder.sv] \
    [file join $rtl_root control c1_r1_stage_config_bank.sv] \
    [file join $rtl_root control c1_r1_config_loader_subsystem.sv] \
    [file join $rtl_root control c1_frame_pair_resolver.sv] \
    [file join $rtl_root control c1_r1_job_controller.sv] \
    [file join $rtl_root control c1_r1_job_frontend.sv]]
dict set component_sources c1_r1_boardless_frame_system [list \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_layer_scheduler.sv] \
    [file join $rtl_root dma c1_axi_descriptor_reader.sv] \
    [file join $rtl_root control c1_descriptor_scheduler_subsystem.sv] \
    [file join $rtl_root control c1_layer_command_decoder.sv] \
    [file join $rtl_root common c1_ram_sdp_read_first.sv] \
    [file join $rtl_root control c1_r1_stage_config_bank.sv] \
    [file join $rtl_root control c1_r1_config_loader_subsystem.sv] \
    [file join $rtl_root dma c1_axi_frame_buffer_table_reader.sv] \
    [file join $rtl_root control c1_frame_pair_resolver.sv] \
    [file join $rtl_root control c1_r1_job_controller.sv] \
    [file join $rtl_root dma c1_axi2_serial_arbiter_128.sv] \
    [file join $rtl_root control c1_r1_job_frontend.sv] \
    [file join $rtl_root control c1_r1_config_dispatcher.sv] \
    [file join $rtl_root dma c1_axi_xrgb_frame_reader.sv] \
    [file join $rtl_root dma c1_axi_xrgb_frame_writer.sv] \
    [file join $rtl_root video r1_resize_request_q16.sv] \
    [file join $rtl_root video r1_bilinear_interp_rgb888.sv] \
    [file join $rtl_root video c1_r1_resize_system.sv] \
    [file join $rtl_root video c1_r1_resize_line_sampler.sv] \
    [file join $rtl_root video c1_r1_resize_pipeline.sv] \
    [file join $rtl_root cnn c1_rgb_s8_center_codec.sv] \
    [file join $rtl_root cnn c1_r1_compute_ingress.sv] \
    [file join $rtl_root cnn c1_r1_compute_egress.sv] \
    [file join $rtl_root top c1_r1_rgb_source_mux.sv] \
    [file join $rtl_root top c1_r1_compute_shell.sv] \
    [file join $rtl_root top c1_r1_boardless_frame_system.sv]]

foreach top [dict keys $component_sources] {
    create_project -in_memory ${top}_proxy -part xc7a200tsbg484-1
    read_verilog -sv [dict get $component_sources $top]
    if {$top eq "c1_r1_stage_config_bank"} {
        synth_design -top $top -part xc7a200tsbg484-1 \
            -flatten_hierarchy rebuilt -generic {SYNC_READ=1}
    } else {
        synth_design -top $top -part xc7a200tsbg484-1 -flatten_hierarchy rebuilt
    }
    create_clock -name core_clk -period 10.000 [get_ports clk]
    report_utilization -file [file join $report_root ${top}_utilization.rpt]
    report_timing_summary -delay_type max -max_paths 10 \
        -file [file join $report_root ${top}_timing.rpt]
    puts "C1_R1_PROXY_COMPONENT_PASS $top"
    close_project
}

puts "C1_R1_PROXY_SYNTH_PASS components=[dict size $component_sources]"
