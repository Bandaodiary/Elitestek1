# Structural Vivado proxy for the boardless display prefetch pair.
# This is intentionally not a Ti60/Efinity sign-off flow.  It compares the
# historical wire-level bypass with the optional 59-bit response FIFOs on an
# Artix-7 proxy part so that the storage/timing trade-off is visible before
# the vendor toolchain and board are available.
set case_root [file normalize [file join [file dirname [info script]] ..]]
set rtl_root [file join $case_root rtl]
set report_root [file normalize [file join [pwd] reports]]
file mkdir $report_root
set_param general.maxThreads 1

set part xc7a200tsbg484-1
set top c1_display_prefetch_pair
set sources [list \
    [file join $rtl_root common c1_stream_fifo.sv] \
    [file join $rtl_root display c1_display_line_store_cdc.sv] \
    [file join $rtl_root dma c1_axi_xrgb_frame_reader.sv] \
    [file join $rtl_root display c1_display_prefetch_pair.sv]]

foreach variant {bypass fifo128} {
    if {$variant eq "bypass"} {
        set enable 0
        set depth 64
    } else {
        set enable 1
        set depth 128
    }

    set project_name display_prefetch_${variant}_proxy
    create_project -in_memory $project_name -part $part
    read_verilog -sv $sources
    synth_design -top $top -part $part -flatten_hierarchy rebuilt \
        -generic [list MAX_WIDTH=640 X_BITS=10 Y_BITS=16 \
                       ENABLE_RESPONSE_FIFO=$enable \
                       RESPONSE_FIFO_DEPTH=$depth]

    # The core clock is the primary timing reference.  The pixel clock is
    # constrained separately; CDC paths are intentionally left to the RTL
    # synchronizer structure and are not treated as a board timing claim.
    create_clock -name core_clk -period 10.000 [get_ports core_clk]
    create_clock -name pixel_clk -period 14.000 [get_ports pixel_clk]
    # The line-store uses explicit toggle synchronizers for this CDC.  Do not
    # turn an unrelated phase relationship into a false timing failure in the
    # proxy report; the synchronizer RTL remains present and is checked by
    # the xsim preflight.
    set_clock_groups -asynchronous \
        -group [get_clocks core_clk] -group [get_clocks pixel_clk]
    report_utilization -hierarchical -file \
        [file join $report_root ${variant}_utilization.rpt]
    report_timing_summary -delay_type max -max_paths 20 -file \
        [file join $report_root ${variant}_timing.rpt]
    puts "C1_DISPLAY_FIFO_PROXY_PASS variant=$variant enable=$enable depth=$depth"
    close_project
}

puts "C1_DISPLAY_FIFO_PROXY_SYNTH_PASS variants=2 part=$part"
