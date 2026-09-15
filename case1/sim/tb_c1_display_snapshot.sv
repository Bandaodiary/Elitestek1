`timescale 1ns/1ps
module tb_c1_display_snapshot #(parameter integer PH=7, EVENT_CASE=0);
    logic core_clk=0,pixel_clk=0,rst=1,frame=0,flush=0;
    logic [7:0] mode=0;
    logic [31:0] status=0;
    logic alarm=0;
    wire flush_busy,flush_done;
    logic [40:0] expected=0;
    integer i,checks=0,pixel_cycles=0,commits=0;
    logic automatic_frames=1;
    logic event_original=0,event_styled=0;
    integer underflows=0;
    always @(posedge core_clk) begin
        #1;
        if(!rst && dut.underflow_event) underflows++;
    end
    always #5 core_clk=~core_clk;
    always #(PH) pixel_clk=~pixel_clk;
    always @(negedge pixel_clk) begin
        pixel_cycles++;
        if(automatic_frames) frame=(pixel_cycles%11==0);
    end
    c1_r1_display_subsystem #(.FRAME_WIDTH(4)) dut (
        .core_clk(core_clk),.pixel_clk(pixel_clk),.core_rst(rst),.pixel_rst(rst),
        .start_valid(1'b0),.abort(1'b0),.flush_request(flush),
        .flush_busy(flush_busy),.flush_done(flush_done),
        .original_width_pixels(16'd4),.original_height_lines(16'd1),
        .width_pixels(16'd4),.height_lines(16'd1),
        .original_base(32'd0),.styled_base(32'd0),
        .original_stride(32'd16),.styled_stride(32'd16),
        .feed_active(1'b0),.hold_requests(1'b1),
        .display_mode(mode),.osd_status_word(status),.osd_alarm(alarm),
        .original_axi_arready(1'b0),.original_axi_rdata(128'd0),
        .original_axi_rresp(2'd0),.original_axi_rlast(1'b0),.original_axi_rvalid(1'b0),
        .styled_axi_arready(1'b0),.styled_axi_rdata(128'd0),
        .styled_axi_rresp(2'd0),.styled_axi_rlast(1'b0),.styled_axi_rvalid(1'b0)
    );
    always @(posedge pixel_clk) begin
        if(dut.pair_pixel_reset) expected=0;
        else if(frame && dut.display_snapshot_valid) begin
            expected=dut.display_snapshot_pixel;
            commits++;
        end
        #1;
        if({dut.mode_frame_q,dut.status_frame_q,dut.alarm_frame_q}!==expected)
            $fatal(1,"display snapshot changed outside frame or was not committed atomically");
        if(!rst && (dut.status_frame_q%12345!=0 ||
            dut.mode_frame_q!==8'(dut.status_frame_q/12345) ||
            dut.alarm_frame_q!==^(32'(dut.status_frame_q/12345))))
            $fatal(1,"display mode/status/alarm were sampled from different source tuples");
        checks++;
    end
    initial begin
        force dut.timing_frame_start=frame;
        if(EVENT_CASE) begin
            automatic_frames=0;
            force dut.original_underflow=event_original;
            force dut.styled_underflow=event_styled;
            repeat(6) @(negedge pixel_clk);rst=0;
            // First frame: ordinary mid-frame starvation, many missing pixels.
            frame=1;
            @(negedge pixel_clk);frame=0;event_original=1;
            repeat(10) @(negedge pixel_clk);event_original=0;
            repeat(80) @(negedge pixel_clk);
            if(underflows!=1) $fatal(1,"underflow aggregation failed first frame count=%0d",underflows);
            // New frame has exactly one missing-pixel pulse at its boundary.
            // It must not consult the previous frame's reported flag.
            frame=1;event_styled=1;
            @(negedge pixel_clk);frame=0;event_styled=0;
            repeat(80) @(negedge pixel_clk);
            if(underflows!=2) $fatal(1,"boundary underflow lost count=%0d expected=2",underflows);
            event_original=1;event_styled=1;
            repeat(10) @(negedge pixel_clk);
            event_original=0;event_styled=0;
            repeat(80) @(negedge pixel_clk);
            if(underflows!=2) $fatal(1,"same-frame underflow duplicated");
            frame=1;event_original=1;event_styled=1;
            @(negedge pixel_clk);frame=0;event_original=0;event_styled=0;
            repeat(80) @(negedge pixel_clk);
            if(underflows!=3) $fatal(1,"dual-source boundary underflow did not coalesce");
            $display("C1_DISPLAY_UNDERFLOW_BOUNDARY_PASS ph=%0d frames=3 events=%0d",PH,underflows);
            $finish;
        end
        repeat(6) @(negedge pixel_clk);rst=0;
        for(i=1;i<=200;i++) begin
            @(negedge core_clk);mode=8'(i);status=32'(i*12345);alarm=^(32'(i));
        end
        automatic_frames=0;
        @(negedge pixel_clk);frame=0;
        wait(dut.display_snapshot_pixel==={mode,status,alarm});
        @(negedge pixel_clk);frame=1;
        @(negedge pixel_clk);frame=0;
        if(expected!=={mode,status,alarm}) $fatal(1,"latest settled value was not displayed");
        @(negedge core_clk);flush=1;
        @(negedge core_clk);flush=0;
        wait(flush_done);
        repeat(5) @(negedge pixel_clk);
        if(!dut.display_snapshot_valid) $fatal(1,"local flush reset snapshot handshake");
        @(negedge pixel_clk);frame=1;
        @(negedge pixel_clk);frame=0;
        if(expected!=={mode,status,alarm}) $fatal(1,"post-flush snapshot did not recover");
        if(commits<3) $fatal(1,"insufficient frame-boundary stress");
        $display("C1_DISPLAY_SNAPSHOT_PASS ph=%0d checks=%0d commits=%0d updates=200 flush_recovery=1",PH,checks,commits);
        $finish;
    end
    initial begin #1000000;$fatal(1,"display snapshot timeout");end
endmodule
