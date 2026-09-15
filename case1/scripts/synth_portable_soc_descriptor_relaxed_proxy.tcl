# Timing experiment for the optional relaxed descriptor-validation build.
# The strict/default correctness path is measured in
# synth_portable_soc_fifo_proxy.tcl; this run only measures the explicitly
# opted-in performance configuration on the same native full SoC.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set part xc7a200tsbg484-1
set top c1_r1_portable_soc
set disable_parallel_helper 0
if {[lsearch -exact $argv DISABLE_PARALLEL_HELPER] >= 0} {
    set disable_parallel_helper 1
    # Vivado's synthesis runtime uses this parameter to decide whether to
    # spawn the helper that sources the detached runtime Tcl tree.  Keeping
    # the default unchanged, the opt-in value "none" makes a single-process
    # proxy retryable when the helper sees intermittent cloud-file errors.
    set_param synth.enableParallelHelperSpawn none
}
set pipelined_address 0
if {[lsearch -exact $argv PIPELINED_ADDRESS] >= 0} {
    set pipelined_address 1
}
set pipelined_start_config 0
if {[lsearch -exact $argv PIPELINED_START_CONFIG] >= 0} {
    set pipelined_start_config 1
}
set pipelined_dot_tree 0
if {[lsearch -exact $argv PIPELINED_DOT_TREE] >= 0} {
    set pipelined_dot_tree 1
}
set pipelined_dot_tree_full 0
if {[lsearch -exact $argv PIPELINED_DOT_TREE_FULL] >= 0} {
    set pipelined_dot_tree_full 1
}
set pipelined_descriptor_replay 0
if {[lsearch -exact $argv PIPELINED_DESCRIPTOR_REPLAY] >= 0} {
    set pipelined_descriptor_replay 1
}
set prevalidate_descriptor_replay 0
if {[lsearch -exact $argv PREVALIDATE_DESCRIPTOR_REPLAY] >= 0} {
    set prevalidate_descriptor_replay 1
}
set replicate_abort_control 0
if {[lsearch -exact $argv REPLICATE_ABORT_CONTROL] >= 0} {
    set replicate_abort_control 1
}
set table_response_fifo 0
if {[lsearch -exact $argv TABLE_RESPONSE_FIFO] >= 0} {
    set table_response_fifo 1
}
set unified_output_fifo 0
if {[lsearch -exact $argv UNIFIED_OUTPUT_FIFO] >= 0} {
    set unified_output_fifo 1
}
set unified_output_skid 0
if {[lsearch -exact $argv UNIFIED_OUTPUT_SKID] >= 0} {
    set unified_output_skid 1
}
set fabric_read_response_skid 0
if {[lsearch -exact $argv FABRIC_READ_RESPONSE_SKID] >= 0} {
    set fabric_read_response_skid 1
}
set register_fatal_ticket 0
if {[lsearch -exact $argv REGISTER_FATAL_TICKET] >= 0} {
    set register_fatal_ticket 1
}
set fast_address 0
if {[lsearch -exact $argv FAST_ADDRESS] >= 0} {
    set fast_address 1
}

proc collect_sv {dir} {
    set result [list]
    foreach f [glob -nocomplain -types f -directory $dir *.sv] { lappend result [file normalize $f] }
    foreach d [glob -nocomplain -types d -directory $dir *] { set result [concat $result [collect_sv $d]] }
    return $result
}
set package_sources [list \
    [file join $rtl_root common c1_fixed_pkg.sv] \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_frame_buffer_pkg.sv]]
set sources $package_sources
foreach f [collect_sv $rtl_root] {
    if {[lsearch -exact $package_sources $f] < 0} { lappend sources $f }
}

create_project -in_memory portable_soc_descriptor_relaxed_proxy -part $part
read_verilog -sv $sources
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -generic [list FRAME_WIDTH=640 FRAME_HEIGHT=480 \
                   ENABLE_TENSOR_WINDOW_CACHE=0 \
                   ENABLE_DISPLAY_RESPONSE_FIFO=1 \
                   DISPLAY_RESPONSE_FIFO_DEPTH=128 \
                   STRICT_DESCRIPTOR_VALIDATION=0 \
                   FAST_TENSOR_ADDRESS_ARITH=$fast_address \
                   PIPELINED_TENSOR_ADDRESS=$pipelined_address \
                   PIPELINED_START_CONFIG=$pipelined_start_config \
                   PIPELINED_DOT_TREE=$pipelined_dot_tree \
                   PIPELINED_DOT_TREE_FULL=$pipelined_dot_tree_full \
                   PIPELINED_DESCRIPTOR_REPLAY=$pipelined_descriptor_replay \
                   PREVALIDATE_DESCRIPTOR_REPLAY=$prevalidate_descriptor_replay \
                   REPLICATE_ABORT_CONTROL=$replicate_abort_control \
                   REGISTER_FATAL_TICKET=$register_fatal_ticket \
                   ENABLE_FABRIC_READ_RESPONSE_SKID=$fabric_read_response_skid \
                   ENABLE_TABLE_RESPONSE_FIFO=$table_response_fifo \
                   ENABLE_UNIFIED_OUTPUT_FIFO=$unified_output_fifo \
                   ENABLE_UNIFIED_OUTPUT_SKID=$unified_output_skid]
create_clock -name core_clk -period 10.000 [get_ports core_clk]
create_clock -name pixel_clk -period 14.000 [get_ports pixel_clk]
create_clock -name camera_clk -period 20.000 [get_ports camera_clk]
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks pixel_clk] \
    -group [get_clocks camera_clk]
report_utilization -hierarchical -file [file join $report_root relaxed_utilization.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $report_root relaxed_timing.rpt]
set data_from_pins [get_pins -hierarchical -filter {REF_PIN_NAME == Q}]
set data_to_pins [get_pins -hierarchical -filter {REF_PIN_NAME == D}]
puts "C1_DATA_TIMING_PINS from=[llength $data_from_pins] to=[llength $data_to_pins]"
if {[llength $data_from_pins] > 0 && [llength $data_to_pins] > 0} {
    report_timing -from $data_from_pins -to $data_to_pins \
        -delay_type max -max_paths 20 \
        -file [file join $report_root relaxed_data_timing.rpt]
}
puts "C1_PORTABLE_SOC_DESCRIPTOR_RELAXED_PROXY_PASS strict=0 fast_addr=$fast_address pipeline=$pipelined_address start_cfg=$pipelined_start_config dot_tree=$pipelined_dot_tree dot_tree_full=$pipelined_dot_tree_full descriptor_replay=$pipelined_descriptor_replay prevalidate_replay=$prevalidate_descriptor_replay replicate_abort=$replicate_abort_control fatal_ticket=$register_fatal_ticket fabric_read_skid=$fabric_read_response_skid table_rsp_fifo=$table_response_fifo unified_out_fifo=$unified_output_fifo unified_out_skid=$unified_output_skid helper_disabled=$disable_parallel_helper fifo=128 frame=640x480"
close_project
puts "C1_PORTABLE_SOC_DESCRIPTOR_RELAXED_PROXY_SYNTH_PASS frame=640x480"
