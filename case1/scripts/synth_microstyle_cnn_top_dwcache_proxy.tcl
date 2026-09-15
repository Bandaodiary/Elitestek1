# Board-independent Artix-7 proxy for the optional MicroStyle DW weight tile
# cache.  This is a structural estimate only; Ti60/EBR mapping and final
# timing must be checked with Efinity after the target board is available.
#
# The default generic enables one cached 8-lane x 9-tap tile per output group.
# Additional top-level generics may be overridden without editing this file:
#
#   vivado -mode batch -source synth_microstyle_cnn_top_dwcache_proxy.tcl \
#       -tclargs CACHE_DW_WEIGHT_TILES=1 PIPELINED_DOT_TREE=0
#
# Only the parameters exported by c1_r1_microstyle_cnn_top are accepted.  The
# detached PowerShell runner supplies the same defaults and extracts compact
# utilization/timing data before removing its private Vivado tree.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root

# This local Vivado installation has intermittently failed while a parallel
# helper opens its runtime Tcl tree.  A single synthesis thread makes this
# proxy deterministic and keeps the run light enough for a boardless check.
set_param general.maxThreads 1
set_param synth.maxThreads 1

set part xc7a200tsbg484-1
set top c1_r1_microstyle_cnn_top

# Values mirror the RTL defaults.  CACHE_DW_WEIGHT_TILES is deliberately 1
# for this run; all values remain explicit synth_design -generic overrides so
# the same script can be used for an A/B comparison against the legacy cache=0
# implementation.
set generic_defaults [dict create \
    REQUIRED_STAGES 22 \
    PARAM_ADDR_W 11 \
    PARAM_ARENA_BYTES 16896 \
    MAX_CHANNELS 48 \
    MAX_WEIGHT_BYTES 2592 \
    PIPELINED_DOT_TREE 0 \
    PIPELINED_DOT_TREE_FULL 0 \
    PIPELINED_DESCRIPTOR_REPLAY 0 \
    PREVALIDATE_DESCRIPTOR_REPLAY 0 \
    CACHE_DW_WEIGHT_TILES 1 \
    MAC_PREFETCH_OVERLAP 0 \
    PACKED_AFFINE_CACHE 0]

set arg_index 0
while {$arg_index < [llength $argv]} {
    set arg [lindex $argv $arg_index]
    if {[regexp {^([A-Za-z_][A-Za-z0-9_]*)=([-+]?[0-9]+)$} $arg -> key value]} {
        # Normal Tcl invocation: NAME=INTEGER arrives as one token.
    } elseif {[regexp {^([A-Za-z_][A-Za-z0-9_]*)$} $arg -> key] &&
              ($arg_index + 1) < [llength $argv] &&
              [regexp {^[-+]?[0-9]+$} [lindex $argv [expr {$arg_index + 1}]] value]} {
        # Vivado's Windows command-line parser may split NAME=INTEGER into
        # two argv tokens; accept that equivalent form as well.
        incr arg_index
    } else {
        error "generic override must be NAME=INTEGER: $arg"
    }
    if {![dict exists $generic_defaults $key]} {
        error "unsupported c1_r1_microstyle_cnn_top generic: $key"
    }
    dict set generic_defaults $key $value
    incr arg_index
}
if {[dict get $generic_defaults CACHE_DW_WEIGHT_TILES] != 1} {
    # This file is the cache-enabled proxy; cache=0 can still be measured by
    # passing the override, but make the selected value visible in the marker.
    puts "INFO: CACHE_DW_WEIGHT_TILES override=[dict get $generic_defaults CACHE_DW_WEIGHT_TILES]"
}

set sources [list \
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

create_project -in_memory c1_microstyle_cnn_dwcache_proxy -part $part
read_verilog -sv $sources
set generic_list [list]
dict for {key value} $generic_defaults {
    lappend generic_list "${key}=${value}"
}
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -generic $generic_list
create_clock -name core_clk -period 10.000 [get_ports clk]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 \
    -file [file join $report_root timing.rpt]
puts "C1_R1_MICROSTYLE_CNN_TOP_DWCACHE_PROXY_SYNTH_PASS CACHE_DW_WEIGHT_TILES=[dict get $generic_defaults CACHE_DW_WEIGHT_TILES] PACKED_AFFINE_CACHE=[dict get $generic_defaults PACKED_AFFINE_CACHE] PART=$part"
close_project
