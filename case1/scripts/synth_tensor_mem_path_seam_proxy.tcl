# Synthesis proxy for both selectable seam implementations.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set_param synth.maxThreads 1

foreach mode {0 1} {
    create_project -in_memory c1_tensor_mem_path_seam_proxy_$mode -part xc7a200tsbg484-1
    read_verilog -sv [list \
        [file join $rtl_root dma c1_tensor_mem_axi128_bridge.sv] \
        [file join $rtl_root dma c1_tensor_mem_axi128_packer.sv] \
        [file join $rtl_root dma c1_tensor_mem_path_seam.sv]]
    synth_design -top c1_tensor_mem_path_seam -part xc7a200tsbg484-1 \
        -generic [list PERF_MODE=$mode] -flatten_hierarchy rebuilt
    create_clock -name clk -period 10.000 [get_ports clk]
    report_utilization -file [file join $report_root utilization_mode${mode}.rpt]
    report_timing_summary -delay_type max -max_paths 10 \
        -file [file join $report_root timing_mode${mode}.rpt]
    close_project
}
puts "C1_TENSOR_MEM_PATH_SEAM_PROXY_SYNTH_PASS modes=0,1"
