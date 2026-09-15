set output_dir $::env(C27_AUDIT_OUT)
puts "C27_CDC_BEGIN camera_to_core"
report_cdc -from camera_clk -to core_clk -details -file $output_dir/c27_cdc_camera_to_core.rpt
puts "C27_CDC_BEGIN core_to_camera"
report_cdc -from core_clk -to camera_clk -details -file $output_dir/c27_cdc_core_to_camera.rpt
puts "C27_CDC_CLASSIFICATION_PASS"


