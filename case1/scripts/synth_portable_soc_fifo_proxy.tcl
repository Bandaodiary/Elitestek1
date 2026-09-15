# Structural Vivado proxy for the complete board-independent Case-1 SoC.
# This compares the default display wire path with the optional response FIFO
# at the native 640x480 parameterization.  It is deliberately a Xilinx proxy,
# not an Efinity/Ti60 implementation or a board timing sign-off.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1
set part xc7a200tsbg484-1
set top c1_r1_portable_soc

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

set package_sources [list \
    [file join $rtl_root common c1_fixed_pkg.sv] \
    [file join $rtl_root control c1_descriptor_pkg.sv] \
    [file join $rtl_root control c1_descriptor_decoder_pkg.sv] \
    [file join $rtl_root control c1_frame_buffer_pkg.sv]]
set all_sources [collect_sv $rtl_root]
set sources $package_sources
foreach f $all_sources {
    if {[lsearch -exact $package_sources $f] < 0} {
        lappend sources $f
    }
}

foreach variant {bypass fifo128} {
    if {$variant eq "bypass"} {
        set enable 0
        set depth 64
    } else {
        set enable 1
        set depth 128
    }

    set project_name portable_soc_${variant}_proxy
    create_project -in_memory $project_name -part $part
    read_verilog -sv $sources
    synth_design -top $top -part $part -flatten_hierarchy rebuilt \
        -generic [list FRAME_WIDTH=640 FRAME_HEIGHT=480 \
                       ENABLE_TENSOR_WINDOW_CACHE=0 \
                       ENABLE_DISPLAY_RESPONSE_FIFO=$enable \
                       DISPLAY_RESPONSE_FIFO_DEPTH=$depth]

    create_clock -name core_clk -period 10.000 [get_ports core_clk]
    create_clock -name pixel_clk -period 14.000 [get_ports pixel_clk]
    create_clock -name camera_clk -period 20.000 [get_ports camera_clk]
    # CDC is implemented by explicit synchronizers in the portable top.  The
    # proxy reports each domain internally and excludes unrelated phase paths.
    set_clock_groups -asynchronous \
        -group [get_clocks core_clk] \
        -group [get_clocks pixel_clk] \
        -group [get_clocks camera_clk]
    report_utilization -hierarchical -file \
        [file join $report_root ${variant}_utilization.rpt]
    report_timing_summary -delay_type max -max_paths 20 -file \
        [file join $report_root ${variant}_timing.rpt]
    puts "C1_PORTABLE_SOC_FIFO_PROXY_PASS variant=$variant enable=$enable depth=$depth"
    close_project
}

puts "C1_PORTABLE_SOC_FIFO_PROXY_SYNTH_PASS variants=2 part=$part frame=640x480"
