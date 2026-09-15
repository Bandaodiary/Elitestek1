# Boardless structural proxy for the complete Case-1 portable SoC with the
# optional tensor C8 burst refill client enabled.  This is intentionally a
# Xilinx/Vivado proxy (xc7a200t) rather than Ti60/Efinity sign-off.
#
# Usage from the detached PowerShell runner:
#   vivado -mode batch -source this_file -tclargs LOGICAL
#   vivado -mode batch -source this_file -tclargs BEAT_MODE
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PLACE_ROUTE
#   vivado -mode batch -source this_file -tclargs BEAT_MODE RELAXED_DESCRIPTOR
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_ADDRESS
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_DESCRIPTOR_VALIDATION
#   vivado -mode batch -source this_file -tclargs BEAT_MODE NARROW_DESCRIPTOR_SIZE_CHECK
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_DESCRIPTOR_SIZE_ARITH
#   vivado -mode batch -source this_file -tclargs BEAT_MODE FIXED_DESCRIPTOR_SIZE_LIMITS
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_DESCRIPTOR_PIXEL_COUNT
#   vivado -mode batch -source this_file -tclargs BEAT_MODE ITERATIVE_DESCRIPTOR_PIXEL_COUNT
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PRECLAMPED_TAP_COORDS
#   vivado -mode batch -source this_file -tclargs BEAT_MODE KEEP_DESCRIPTOR_SIZE_OPERANDS
#   vivado -mode batch -source this_file -tclargs BEAT_MODE REGISTER_ABORT_RESET
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_DECODER_VALIDATION
#   vivado -mode batch -source this_file -tclargs BEAT_MODE FAST_TENSOR_ADDRESS_ARITH
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_TENSOR_PIXEL_INDEX
#   vivado -mode batch -source this_file -tclargs BEAT_MODE PIPELINED_DOT_TREE_FULL
#   vivado -mode batch -source this_file -tclargs BEAT_MODE REGISTER_FATAL_TICKET
#   vivado -mode batch -source this_file -tclargs BEAT_MODE REPLICATE_ABORT_CONTROL
#
# The default display response FIFO and other experimental boundaries remain
# disabled so the report isolates the tensor burst seam.  Logical mode keeps
# 128 response records; beat mode uses 64, exactly the safe lower bound for
# the current top-level defaults BURST_BEATS*READER_MAX_OUTSTANDING (16*4).
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

set_param general.maxThreads 1
# Keep the Vivado/Oasys helper path enabled even though synthesis itself is
# limited to one worker.  On this full-top design, forcing
# synth.enableParallelHelperSpawn=none enters a broken runtime path in
# Vivado 2023.1 and reports a misleading "couldn't read ... common.tcl" (or
# rt-undefined) error before elaboration.  The detached PowerShell launcher
# owns the process boundary; any helper spawned here is therefore independent
# of the Codex Windows job.  This setting changes scheduling only, not RTL.
set_param synth.maxThreads 1
set_param synth.enableParallelHelperSpawn all
set part xc7a200tsbg484-1
set top c1_r1_portable_soc

set beat_mode 0
if {[lsearch -exact $argv BEAT_MODE] >= 0} {
    set beat_mode 1
}
set place_route 0
if {[lsearch -exact $argv PLACE_ROUTE] >= 0} {
    set place_route 1
}
set relaxed_descriptor 0
if {[lsearch -exact $argv RELAXED_DESCRIPTOR] >= 0} {
    set relaxed_descriptor 1
}
set pipelined_address 0
if {[lsearch -exact $argv PIPELINED_ADDRESS] >= 0} {
    set pipelined_address 1
}
set pipelined_descriptor_validation 0
if {[lsearch -exact $argv PIPELINED_DESCRIPTOR_VALIDATION] >= 0} {
    set pipelined_descriptor_validation 1
}
set narrow_descriptor_size_check 0
if {[lsearch -exact $argv NARROW_DESCRIPTOR_SIZE_CHECK] >= 0} {
    set narrow_descriptor_size_check 1
}
set pipelined_descriptor_size_arith 0
if {[lsearch -exact $argv PIPELINED_DESCRIPTOR_SIZE_ARITH] >= 0} {
    set pipelined_descriptor_size_arith 1
}
set fixed_descriptor_size_limits 0
if {[lsearch -exact $argv FIXED_DESCRIPTOR_SIZE_LIMITS] >= 0} {
    set fixed_descriptor_size_limits 1
}
set pipelined_descriptor_pixel_count 0
    if {[lsearch -exact $argv PIPELINED_DESCRIPTOR_PIXEL_COUNT] >= 0} {
        set pipelined_descriptor_pixel_count 1
    }
    set iterative_descriptor_pixel_count 0
    if {[lsearch -exact $argv ITERATIVE_DESCRIPTOR_PIXEL_COUNT] >= 0} {
        set iterative_descriptor_pixel_count 1
    }
set preclamped_tap_coords 0
if {[lsearch -exact $argv PRECLAMPED_TAP_COORDS] >= 0} {
    set preclamped_tap_coords 1
}
    set keep_descriptor_size_operands 0
if {[lsearch -exact $argv KEEP_DESCRIPTOR_SIZE_OPERANDS] >= 0} {
    set keep_descriptor_size_operands 1
}
set register_abort_reset 0
if {[lsearch -exact $argv REGISTER_ABORT_RESET] >= 0} {
    set register_abort_reset 1
}
set pipelined_decoder_validation 0
if {[lsearch -exact $argv PIPELINED_DECODER_VALIDATION] >= 0} {
    set pipelined_decoder_validation 1
}
set fast_tensor_address_arith 0
if {[lsearch -exact $argv FAST_TENSOR_ADDRESS_ARITH] >= 0} {
    set fast_tensor_address_arith 1
}
set pipelined_tensor_pixel_index 0
if {[lsearch -exact $argv PIPELINED_TENSOR_PIXEL_INDEX] >= 0} {
    set pipelined_tensor_pixel_index 1
}
set pipelined_dot_tree_full 0
if {[lsearch -exact $argv PIPELINED_DOT_TREE_FULL] >= 0} {
    set pipelined_dot_tree_full 1
}
set register_fatal_ticket 0
if {[lsearch -exact $argv REGISTER_FATAL_TICKET] >= 0} {
    set register_fatal_ticket 1
}
set replicate_abort_control 0
if {[lsearch -exact $argv REPLICATE_ABORT_CONTROL] >= 0} {
    set replicate_abort_control 1
}
set mode_name logical
if {$beat_mode} {
    set mode_name beat
}
set timing_suffix synth
if {$place_route} {
    set timing_suffix placed
}
set strict_descriptor_validation 1
if {$relaxed_descriptor} {
    set strict_descriptor_validation 0
}

# Keep the response depth explicit in the report.  Logical mode retains the
# conservative 128-entry default.  Beat mode uses the smallest safe depth
# for the current top-level reader defaults (BURST_BEATS=16,
# MAX_OUTSTANDING=4), namely 64 beat records; the reader has an elaboration
# guard for this lower bound.
set rsp_depth 128
if {$beat_mode} {
    set rsp_depth 64
}

proc collect_sv {dir} {
    set result [list]
    foreach f [glob -nocomplain -types f -directory $dir *.sv] {
        lappend result [file normalize $f]
    }
    foreach d [glob -nocomplain -types d -directory $dir *] {
        set result [concat $result [collect_sv $d]]
    }
    return $result
}

# Packages must precede the recursive module list.  The remaining source
# collection is shared with the existing full-SoC proxy scripts so newly
# added RTL is not silently omitted from this optional build.
set package_sources [list \
    [file join $rtl_root common c1_fixed_pkg.sv] \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_frame_buffer_pkg.sv]]
set sources $package_sources
foreach f [collect_sv $rtl_root] {
    if {[lsearch -exact $package_sources $f] < 0} {
        lappend sources $f
    }
}

create_project -in_memory portable_soc_tensor_burst_proxy -part $part
read_verilog -sv $sources
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -generic [list FRAME_WIDTH=640 FRAME_HEIGHT=480 \
                   ENABLE_TENSOR_WINDOW_CACHE=1 \
                   ENABLE_TENSOR_BURST_REFILL=1 \
                   TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR=0 \
                   TENSOR_BURST_RSP_FIFO_BEAT_MODE=$beat_mode \
                   TENSOR_BURST_RSP_FIFO_DEPTH=$rsp_depth \
                   ENABLE_DISPLAY_RESPONSE_FIFO=0 \
                   DISPLAY_RESPONSE_FIFO_DEPTH=64 \
                   ENABLE_FABRIC_READ_RESPONSE_SKID=0 \
                   ENABLE_TABLE_RESPONSE_FIFO=0 \
                   STRICT_DESCRIPTOR_VALIDATION=$strict_descriptor_validation \
                   PIPELINED_DESCRIPTOR_VALIDATION=$pipelined_descriptor_validation \
                   NARROW_DESCRIPTOR_SIZE_CHECK=$narrow_descriptor_size_check \
                   PIPELINED_DESCRIPTOR_SIZE_ARITH=$pipelined_descriptor_size_arith \
                    FIXED_DESCRIPTOR_SIZE_LIMITS=$fixed_descriptor_size_limits \
                    PIPELINED_DESCRIPTOR_PIXEL_COUNT=$pipelined_descriptor_pixel_count \
                    ITERATIVE_DESCRIPTOR_PIXEL_COUNT=$iterative_descriptor_pixel_count \
                    PRECLAMPED_TAP_COORDS=$preclamped_tap_coords \
                    KEEP_DESCRIPTOR_SIZE_OPERANDS=$keep_descriptor_size_operands \
                      FAST_TENSOR_ADDRESS_ARITH=$fast_tensor_address_arith \
                    PIPELINED_TENSOR_ADDRESS=$pipelined_address \
                    PIPELINED_TENSOR_PIXEL_INDEX=$pipelined_tensor_pixel_index \
                   PIPELINED_START_CONFIG=0 \
                   REGISTER_ABORT_RESET=$register_abort_reset \
                   PIPELINED_DOT_TREE=0 \
                    PIPELINED_DOT_TREE_FULL=$pipelined_dot_tree_full \
                   PIPELINED_DESCRIPTOR_REPLAY=0 \
                   PREVALIDATE_DESCRIPTOR_REPLAY=0 \
                   PIPELINED_DECODER_VALIDATION=$pipelined_decoder_validation \
                   REPLICATE_ABORT_CONTROL=$replicate_abort_control \
                   REGISTER_FATAL_TICKET=$register_fatal_ticket \
                   ENABLE_UNIFIED_OUTPUT_FIFO=0 \
                   ENABLE_UNIFIED_OUTPUT_SKID=0 \
                   ENABLE_SHARED_QOS_MONITOR=0]

create_clock -name core_clk -period 10.000 [get_ports core_clk]
create_clock -name pixel_clk -period 14.000 [get_ports pixel_clk]
create_clock -name camera_clk -period 20.000 [get_ports camera_clk]
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks pixel_clk] \
    -group [get_clocks camera_clk]

# Reports stay below the private worker runRoot.  The PowerShell worker keeps
# only compact marker/tail extracts and removes the complete runRoot in its
# finally block; no checkpoint is written here.
report_utilization -file \
    [file join $report_root tensor_burst_${mode_name}_utilization_summary.rpt]
report_utilization -hierarchical -file \
    [file join $report_root tensor_burst_${mode_name}_utilization.rpt]
report_timing_summary -delay_type max -max_paths 30 -file \
    [file join $report_root tensor_burst_${mode_name}_${timing_suffix}_timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file \
    [file join $report_root tensor_burst_${mode_name}_${timing_suffix}_timing.rpt]

if {$place_route} {
    # Synthesis-only timing reports contain unplaced high-fanout clock nets and
    # can be dominated by pessimistic pre-placement estimates.  This optional
    # sanity gate performs a bounded implementation pass so the clock-network
    # effect is measured separately.  It is still not Ti60/Efinity sign-off.
    opt_design -directive Explore
    place_design -directive Explore
    phys_opt_design -directive AggressiveFanoutOpt
    route_design -directive Explore
    report_utilization -file \
        [file join $report_root tensor_burst_${mode_name}_placed_utilization_summary.rpt]
    report_timing_summary -delay_type max -max_paths 30 -file \
        [file join $report_root tensor_burst_${mode_name}_placed_timing_summary.rpt]
    report_timing -delay_type max -max_paths 20 -file \
        [file join $report_root tensor_burst_${mode_name}_placed_timing.rpt]
}

# Emit a bounded endpoint attribution after timing has already been updated by
# report_timing_summary.  This avoids retaining a full database while allowing
# A/B runs to identify the actual start/end registers of the worst path.
if {[catch {set c1_probe_paths [get_timing_paths -delay_type max -max_paths 8]} c1_probe_error]} {
    puts "C1_TIMING_PATH_PROBE_UNAVAILABLE $c1_probe_error"
} else {
    foreach c1_path $c1_probe_paths {
        set c1_slack [get_property SLACK $c1_path]
        set c1_start [get_property STARTPOINT_PIN $c1_path]
        set c1_end [get_property ENDPOINT_PIN $c1_path]
        set c1_levels [get_property LOGIC_LEVELS $c1_path]
        puts "C1_TIMING_PATH slack=$c1_slack levels=$c1_levels start=$c1_start end=$c1_end"
    }
}

puts "C1_PORTABLE_SOC_TENSOR_BURST_PROXY_PASS mode=$mode_name beat_mode=$beat_mode rsp_depth=$rsp_depth strict_descriptor=$strict_descriptor_validation pipelined_address=$pipelined_address pipelined_tensor_pixel_index=$pipelined_tensor_pixel_index pipelined_descriptor_validation=$pipelined_descriptor_validation pipelined_descriptor_size_arith=$pipelined_descriptor_size_arith fixed_descriptor_size_limits=$fixed_descriptor_size_limits pipelined_descriptor_pixel_count=$pipelined_descriptor_pixel_count iterative_descriptor_pixel_count=$iterative_descriptor_pixel_count preclamped_tap_coords=$preclamped_tap_coords keep_descriptor_size_operands=$keep_descriptor_size_operands pipelined_decoder_validation=$pipelined_decoder_validation pipelined_dot_tree_full=$pipelined_dot_tree_full narrow_descriptor_size=$narrow_descriptor_size_check fast_tensor_address_arith=$fast_tensor_address_arith register_abort_reset=$register_abort_reset register_fatal_ticket=$register_fatal_ticket replicate_abort_control=$replicate_abort_control place_route=$place_route display_fifo=0 sources=[llength $sources]"
close_project
puts "C1_PORTABLE_SOC_TENSOR_BURST_PROXY_SYNTH_PASS mode=$mode_name beat_mode=$beat_mode rsp_depth=$rsp_depth strict_descriptor=$strict_descriptor_validation pipelined_address=$pipelined_address pipelined_tensor_pixel_index=$pipelined_tensor_pixel_index pipelined_descriptor_validation=$pipelined_descriptor_validation pipelined_descriptor_size_arith=$pipelined_descriptor_size_arith fixed_descriptor_size_limits=$fixed_descriptor_size_limits pipelined_descriptor_pixel_count=$pipelined_descriptor_pixel_count iterative_descriptor_pixel_count=$iterative_descriptor_pixel_count preclamped_tap_coords=$preclamped_tap_coords keep_descriptor_size_operands=$keep_descriptor_size_operands pipelined_decoder_validation=$pipelined_decoder_validation pipelined_dot_tree_full=$pipelined_dot_tree_full narrow_descriptor_size=$narrow_descriptor_size_check fast_tensor_address_arith=$fast_tensor_address_arith register_abort_reset=$register_abort_reset register_fatal_ticket=$register_fatal_ticket replicate_abort_control=$replicate_abort_control place_route=$place_route frame=640x480 part=$part"
