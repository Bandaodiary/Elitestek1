`timescale 1ns/1ps
module tb_c1_display_outer_flush #(
    parameter integer FIFO=0, WIDTH=4, BASE_SKEW=0);
    reg core_clk=0, pixel_clk=0, core_rst=1, pixel_rst=1;
    always #5 core_clk=~core_clk;
    always #7 pixel_clk=~pixel_clk;
    reg start_valid=0, abort=0, flush_request=0, delay_r=0, fault_r=0;
    wire start_ready, busy, done, aborted, error, primed, flush_busy, flush_done;
    wire [31:0] oa, sa;
    wire [7:0] ol, sl;
    wire ov, sv, orr, srr;
    reg op=0, sp=0, orv=0, srv=0;
    reg [1:0] sr=0;
    reg orlast=0, srlast=0;
    integer oremaining=0, sremaining=0, oindex=0, sindex=0;
    integer expected_r=0, cycles=0, long_bursts=0, injected_errors=0;
    wire ordy=!op&&!orv, srdy=!sp&&!srv;
    integer ar_count=0, r_count=0, done_count=0, abort_count=0, flush_count=0;
    integer mode, old_done, old_abort, old_flush, old_ar, watchdog;
    c1_r1_display_subsystem #(.FRAME_WIDTH(WIDTH), .ENABLE_RESPONSE_FIFO(FIFO)) dut (
        .original_width_pixels(16'd0), .original_height_lines(16'd0),
        .core_clk(core_clk), .core_rst(core_rst),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
        .start_valid(start_valid), .start_ready(start_ready), .abort(abort),
        .flush_request(flush_request), .flush_busy(flush_busy), .flush_done(flush_done),
        .original_base(32'h1000-BASE_SKEW), .original_stride(WIDTH*4),
        .styled_base(32'h2000-BASE_SKEW), .styled_stride(WIDTH*4),
        .width_pixels(16'(WIDTH)), .height_lines(16'd3),
        .busy(busy), .done(done), .aborted(aborted), .error(error), .primed(primed),
        // Deliberately no pixel consumption: recovery cannot rely on raster.
        .feed_active(1'b0), .hold_requests(1'b1),
        .display_mode(8'd2), .osd_status_word(32'd0), .osd_alarm(1'b0),
        .original_axi_araddr(oa), .original_axi_arlen(ol),
        .original_axi_arvalid(ov), .original_axi_arready(ordy),
        .original_axi_rdata({4{32'h00123456}}), .original_axi_rresp(2'b00),
        .original_axi_rlast(orlast), .original_axi_rvalid(orv), .original_axi_rready(orr),
        .styled_axi_araddr(sa), .styled_axi_arlen(sl),
        .styled_axi_arvalid(sv), .styled_axi_arready(srdy),
        .styled_axi_rdata({4{32'h00abcdef}}), .styled_axi_rresp(sr),
        .styled_axi_rlast(srlast), .styled_axi_rvalid(srv), .styled_axi_rready(srr)
    );
    always @(posedge core_clk) begin
        if (!core_rst) begin
            cycles<=cycles+1;
            if (ov && ordy) begin
                if (ol>15 || oa[11:0]+(int'(ol)+1)*16>4096)
                    $fatal(1,"original burst crosses 4KB or exceeds 16 beats");
                op<=1; oremaining<=int'(ol)+1; oindex<=0;
            end
            if (sv && srdy) begin
                if (sl>15 || sa[11:0]+(int'(sl)+1)*16>4096)
                    $fatal(1,"styled burst crosses 4KB or exceeds 16 beats");
                sp<=1; sremaining<=int'(sl)+1; sindex<=0;
            end
            expected_r<=expected_r+(ov&&ordy ? int'(ol)+1 : 0)+
                                   (sv&&srdy ? int'(sl)+1 : 0);
            long_bursts<=long_bursts+(ov&&ordy&&ol==15)+(sv&&srdy&&sl==15);
            ar_count<=ar_count+(ov&&ordy)+(sv&&srdy);
            r_count<=r_count+(orv&&orr)+(srv&&srr);
            if (op && !orv && !delay_r && cycles%5!=0) begin
                orv<=1; orlast<=oremaining==1;
            end
            if (sp && !srv && !delay_r && cycles%7!=0) begin
                srv<=1; srlast<=sremaining==1;
                sr<=(fault_r && sindex==(WIDTH>4 ? 7 : 0)) ? 2'b10 : 2'b00;
            end
            if (orv&&orr) begin
                orv<=0; oremaining<=oremaining-1; oindex<=oindex+1;
                if(orlast) op<=0;
            end
            if (srv&&srr) begin
                srv<=0; sremaining<=sremaining-1; sindex<=sindex+1;
                if(srlast) sp<=0;
                if(sr!=0) injected_errors<=injected_errors+1;
            end
            if (done) done_count<=done_count+1;
            if (aborted) abort_count<=abort_count+1;
            if (flush_done) flush_count<=flush_count+1;
            if (dut.pair_core_soft_reset && (op||sp||orv||srv||busy))
                $fatal(1,"outer reset before pair retirement");
        end
    end
    task launch;
        begin
            @(negedge core_clk);
            if (!start_ready) $fatal(1,"cannot restart after flush");
            start_valid=1;
            @(negedge core_clk); start_valid=0;
        end
    endtask
    initial begin
        repeat(8) @(negedge core_clk); core_rst=0; pixel_rst=0;
        repeat(8) @(negedge core_clk);
        for(mode=0; mode<(WIDTH>4 ? 5 : 4); mode++) begin
            old_done=done_count; old_abort=abort_count; old_flush=flush_count;
            delay_r=(mode==2); fault_r=(mode==3);
            launch();
            if(mode==2) wait(op&&sp);
            else if(mode==3) wait(error);
            else if(mode==4) begin
                // Seven beats have retired, with at least two still owed.
                // Pause generation, not an already presented RVALID beat.
                wait(sindex==7 && sp && sremaining>1);
                @(negedge core_clk); delay_r=1;
            end
            else begin
                wait(primed);
                repeat(40) @(negedge core_clk);
            end
            @(negedge core_clk); flush_request=1; abort=(mode==1);
            @(negedge core_clk); flush_request=0; abort=0;
            if(mode==2 || mode==4) begin
                repeat(20) @(negedge core_clk);
                if(!busy || !flush_busy || done_count!=old_done)
                    $fatal(1,"flush retired before delayed R");
                delay_r=0;
            end
            watchdog=0;
            while((flush_count==old_flush || busy || flush_busy) && watchdog<400) begin
                @(negedge core_clk); watchdog++;
            end
            repeat(5) @(negedge core_clk);
            if(flush_count!=old_flush+1 || done_count!=old_done+1 ||
               abort_count!=old_abort+1 || !start_ready || error || expected_r!=r_count)
                $fatal(1,"outer flush failed mode=%0d busy=%b flush=%b done=%0d aborted=%0d",
                    mode,busy,flush_busy,done_count,abort_count);
        end
        // Flush has admission priority over simultaneous START while idle.
        old_ar=ar_count; old_flush=flush_count;
        @(negedge core_clk); start_valid=1; flush_request=1;
        #1;
        if(start_ready) $fatal(1,"START admitted on flush request edge");
        @(negedge core_clk); start_valid=0; flush_request=0;
        wait(flush_count==old_flush+1);
        repeat(5) @(negedge core_clk);
        if(ar_count!=old_ar || busy || !start_ready)
            $fatal(1,"idle flush launched a reader");
        if(injected_errors!=1 || (WIDTH>4 && long_bursts==0))
            $fatal(1,"missing long-burst or error-injection coverage");
        $display("C1_DISPLAY_OUTER_FLUSH_PASS fifo=%0d width=%0d skew=%0d scenarios=%0d ar=%0d r=%0d long=%0d errors=%0d",
            FIFO,WIDTH,BASE_SKEW,WIDTH>4 ? 6 : 5,ar_count,r_count,long_bursts,injected_errors);
        $finish;
    end
    initial begin #200000; $fatal(1,"outer flush watchdog"); end
endmodule
