`timescale 1ns/1ps
module tb_c1_r2_demo_rgb2_capture;
    parameter integer SW=20,SH=20,RX=2,RY=2,RW=16,RH=16,OW=8,OH=8,
        FD=64,STALLS=0,VENDOR_SOURCE=0,FAULTS=1,EXPECT_OVERFLOW=0,HBLANK=4,VBLANK=4,FRAME_TIMEOUT=(SW/2+HBLANK)*(SH+VBLANK)*3;
    parameter real CORE_HALF=5.0,CAM_HALF=11.0;
    reg clk=0,cam_clk=0;always #(CORE_HALF)clk=~clk;
    initial begin #1.7;forever #(CAM_HALF)cam_clk=~cam_clk;end
    reg rst=1,cam_rst=1,enable=1,cancel=0;
    wire cam_valid,cam_sof,cam_eol,cam_eof,cam_error;
    wire [47:0] cam_rgb,video_rgb;
    reg raw_vs=0,raw_de=0,raw_valid=0;
    reg [47:0] raw_rgb=0;
    reg [15:0] raw_bayer=0;
    wire video_vs,video_de,video_valid;
    if(VENDOR_SOURCE)begin : g_vendor
        debayer_top_2to1 u_official(.in_pclk(cam_clk),.in_rstn(!cam_rst),
            .raw_vs_i(raw_vs),.raw_hs_i(1'b0),.raw_de_i(raw_de),.raw_valid_i(raw_valid),
            .raw_datax4_i(raw_bayer),.rgb_vs_o(video_vs),.rgb_hs_o(),.rgb_de_o(video_de),
            .rgb_valid_o(video_valid),.rgb_datax2_o(video_rgb));
    end else begin : g_rgb
        assign video_vs=raw_vs;assign video_de=raw_de;assign video_valid=raw_valid;assign video_rgb=raw_rgb;
    end
    c1_r2_rgb2_raster_source #(.SOURCE_WIDTH(SW),.SOURCE_HEIGHT(SH)) u_raster (
        .clk(cam_clk),.rst(cam_rst),.in_vs(video_vs),.in_de(video_de),.in_valid(video_valid),.in_rgb(video_rgb),
        .pair_valid(cam_valid),.pair_sof(cam_sof),.pair_eol(cam_eol),.pair_eof(cam_eof),.pair_error(cam_error),.pair_rgb(cam_rgb));
    wire cam_busy;wire [31:0] cam_seen,cam_skipped;wire [$clog2(FD):0] cam_peak;
    wire job_valid,job_ready,job_cancel,job_done,job_failed,busy,config_error;
    wire [31:0] job_tag,result_tag;wire result_valid,result_failed,result_admitted;wire [3:0] result_code;
    wire s_valid,s_ready,s_sof,s_eol,s_eof;wire [23:0] s_rgb;wire [15:0] s_x,s_y;
    c1_r2_camera_pair_ingress #(.SOURCE_WIDTH(SW),.SOURCE_HEIGHT(SH),.ROI_X(RX),.ROI_Y(RY),
        .ROI_WIDTH(RW),.ROI_HEIGHT(RH),.FIFO_DEPTH(FD),.FRAME_TIMEOUT(FRAME_TIMEOUT)) ingress(.*);
    reg admit=1,freeze_feed=0,cap_ack=1;
    wire cap_ready,cap_busy,cap_done,cap_error,cap_drop,cap_overflow,cap_protocol,cap_source_ready,cap_source_error;
    wire [3:0] cap_source_code;wire [7:0] cap_outstanding;
    wire [31:0] cap_done_base,cap_done_tag;wire [8:0] cap_peak;
    integer xs,ys,xp,yp;
    assign job_ready=cap_ready && admit;
    assign job_done=cap_done && cap_ack;
    assign job_failed=cap_error || cap_drop;
    assign s_ready=cap_source_ready && !freeze_feed;
    reg clear_faults=0,hold_b=0;reg [2:0] inject_r=0;reg [1:0] inject_b=0;
    wire fault_r_seen,fault_b_seen,service_read,service_write,idle;
    wire [31:0] service_read_address,service_write_address;wire [127:0] service_read_data=0;
    integer ar_total,aw_total,r_total,w_total,b_total,peak_read,peak_write;
    wire [3:0] m_axi_arid=0;wire [3:0] m_axi_awid,m_axi_rid,m_axi_bid;
    wire [31:0] m_axi_araddr=0;wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_arlen=0;wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_arsize=4;wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_arburst=1;wire [1:0] m_axi_awburst,m_axi_rresp,m_axi_bresp;
    wire m_axi_arvalid=0,m_axi_rready=1;wire m_axi_arready,m_axi_rvalid,m_axi_rlast;
    wire m_axi_awvalid,m_axi_awready,m_axi_wvalid,m_axi_wready,m_axi_wlast,m_axi_bvalid,m_axi_bready;
    wire [127:0] m_axi_wdata,m_axi_rdata;wire [15:0] m_axi_wstrb;
    c1_r2_axi_memory_bfm #(.STALLS(STALLS),.MEMORY_DIV(2),.LATENCY(20),.AW_WAIT_W(2)) mem(.*);
    // Independent implementation selection; kept at the same monitor path.
`ifdef C30_RESIZE_OVERLAP
    c1_r2_resize_overlap_capture
`else
    c1_r2_resize_capture_rgbx32
`endif
    #(.FIFO_DEPTH(256)) capture (
        .clk(clk),.rst(rst),.cmd_valid(job_valid && admit),.cmd_ready(cap_ready),.cfg_base(32'd0),.cfg_tag(job_tag),
        .cfg_width(11'(OW)),.cfg_height(10'(OH)),.cfg_source_width(16'(RW)),.cfg_source_height(16'(RH)),
        .cfg_x_step_q16(xs),.cfg_y_step_q16(ys),.cfg_x_phase0_q16(xp),.cfg_y_phase0_q16(yp),
        .s_x(s_x),.s_y(s_y),.s_ready(cap_source_ready),.source_error(cap_source_error),.source_error_code(cap_source_code),
        .cancel(job_cancel),.s_valid(s_valid && !freeze_feed),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),.s_rgb(s_rgb),
        .busy(cap_busy),.done_valid(cap_done),.done_ready(cap_ack),.done_error(cap_error),.done_dropped(cap_drop),
        .done_base(cap_done_base),.done_tag(cap_done_tag),.overflow_pulse(cap_overflow),.peak_level(cap_peak),
        .protocol_error(cap_protocol),.outstanding(cap_outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready));
    reg [23:0] image[0:SW*SH-1];reg [127:0] expected[0:OW*OH/4-1];
    integer cycles=0,results=0,good=0,bad=0,starts=0,source_eofs=0,roi_pixels=0,checked_words=0;
    integer expect_code=0,source_done_before=0,start_words=0,start_jobs=0,last_roi_cycle=-1,tail_checks=0;
    integer stream_words=0,held_b_checks=0,mode=0,phase_hold_checks=0;
    integer cam_cycles=0,first_sof=-1,second_sof=-1;
    // Keep file paths packed for Icarus and xsim; 512 chars avoids truncation.
    reg [4095:0] dir;
    integer source_file,expected_file;
    reg last_failed;integer last_code;
    reg held_stream=0;reg [58:0] held_payload;
    always @(posedge cam_clk)begin
        cam_cycles=cam_cycles+1;
        if(!cam_rst && cam_valid && cam_eof)source_eofs=source_eofs+1;
        if(!cam_rst && cam_valid && cam_sof)begin
            if(first_sof<0)first_sof=cam_cycles;
            else if(second_sof<0)second_sof=cam_cycles;
        end
    end
    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles%1000000==0)$display("C1_R2_DEMO_RGB2_CAPTURE_PROGRESS cycle=%0d results=%0d words=%0d source_peak=%0d",cycles,results,checked_words,cam_peak);
        if(cycles>100000000)$fatal(1,"camera capture watchdog");
        if(!rst)begin
            if(cap_protocol || cap_overflow || cap_source_error)$fatal(1,"unexpected downstream protocol/overflow/source error");
            if(job_valid && job_ready)begin starts=starts+1;stream_words=0;end
            if(held_stream && !job_cancel && (!s_valid || {s_rgb,s_x,s_y,s_sof,s_eol,s_eof}!==held_payload))$fatal(1,"camera held stream changed");
            held_stream=s_valid && !s_ready && !job_cancel;
            held_payload={s_rgb,s_x,s_y,s_sof,s_eol,s_eof};
            if(s_valid && s_ready)begin
                if(s_x!==16'(stream_words%RW) || s_y!==16'(stream_words/RW) ||
                   s_sof!==(stream_words==0) || s_eol!==(stream_words%RW==RW-1) || s_eof!==(stream_words==RW*RH-1) ||
                   s_rgb!==image[(s_y+RY)*SW+s_x+RX])$fatal(1,"camera actual ROI data/coordinate mismatch");
                if(s_eof && source_eofs<=source_done_before)$fatal(1,"ROI EOF escaped before full source validated");
                stream_words=stream_words+1;roi_pixels=roi_pixels+1;
            end
            if(service_write)begin
                if(service_write_address>=OW*OH*4 || service_write_address[3:0]!=0 ||
                   m_axi_wdata!==expected[service_write_address>>4] || m_axi_wstrb!==16'hffff)
                    $fatal(1,"camera Resize RGBX memory golden mismatch address=%h",service_write_address);
                checked_words=checked_words+1;
            end
            if(result_valid)begin
                results=results+1;last_failed=result_failed;last_code=result_code;
                if(result_admitted!==(mode!=7 && mode!=9))$fatal(1,"camera result admission provenance mismatch");
                if(cap_outstanding!=0 || !idle || !ingress.fifo_empty)$fatal(1,"camera result before actual drain");
                if(result_failed)bad=bad+1;
                else begin
                    good=good+1;
                    if(stream_words!=RW*RH || checked_words-start_words!=OW*OH/4)$fatal(1,"successful camera frame incomplete");
                end
                $display("C1_R2_DEMO_RGB2_CAPTURE_RESULT mode=%0d tag=%0d failed=%b code=%0d admitted=%b roi_pixels=%0d words=%0d cycle=%0d",mode,result_tag,result_failed,result_code,result_admitted,stream_words,checked_words-start_words,cycles);
            end
        end else held_stream=0;
    end
    task blank(input integer n);
        begin
            @(negedge cam_clk);raw_de=0;raw_valid=0;raw_rgb=0;raw_bayer=0;
            repeat(n>0 ? n-1 : 0)@(negedge cam_clk);
        end
    endtask
    function automatic [7:0] cfa(input integer x,y);
        cfa=y%2 ? (x%2 ? 8'd32 : 8'd96) : (x%2 ? 8'd96 : 8'd160);
    endfunction
    task native_frame;
        integer x,y;
        begin
            // Active v1 constants: H sync/back/active/front = 2/44/960/60;
            // V active/front/sync/back = 1080/20/2/20. No per-frame busy wait.
            for(y=0;y<SH;y=y+1)begin
                blank(46);
                for(x=0;x<SW;x=x+2)begin
                    @(negedge cam_clk);raw_de=1;raw_valid=1;
                    raw_rgb={image[y*SW+x+1],image[y*SW+x]};
                end
                blank(60);
            end
            blank(20*(SW/2+HBLANK));
            raw_vs=1;blank(2*(SW/2+HBLANK));
            raw_vs=0;blank(20*(SW/2+HBLANK));
        end
    endtask
    task frame(input integer fault);
        integer y,x,limit,rows;
        begin
          if(SW==1920 && SH==1080 && !FAULTS)native_frame();
          else begin
            @(negedge cam_clk);raw_vs=1;raw_de=0;raw_valid=0;
            repeat(3)@(negedge cam_clk);raw_vs=0;
            repeat(6)@(negedge cam_clk);
            rows=fault==12 ? RY+2 : fault==13 ? SH+1 : SH;
            for(y=0;y<rows;y=y+1)begin
                limit=SW;
                if(fault==1 && y==RY+1)limit=SW-2;
                if(fault==2 && y==SH-1)limit=SW+2;
                for(x=0;x<limit;x=x+2)begin
                    @(negedge cam_clk);raw_de=1;raw_valid=1;
                    raw_rgb=(y<SH && x<SW) ? {image[y*SW+x+1],image[y*SW+x]} : 48'h123456abcdef;
                    raw_bayer={cfa(x,y),cfa(x+1,y)};
                    if(fault==3 && y==RY+1 && x==((RX+1)&~1))raw_valid=0;
                    if(fault==7 && y==0 && x==2)raw_valid=0;
                end
                if(fault==14 && y==SH-1)begin
                    @(negedge cam_clk);raw_vs=1; // Deliberate DE/VS overlap.
                end
                blank(HBLANK);
            end
            if(fault==6)begin
                blank(FRAME_TIMEOUT+8); // Last pair MUST NOT become EOF.
            end else begin
                @(negedge cam_clk);raw_vs=1;
                repeat(3)@(negedge cam_clk);raw_vs=0;
            end
            blank((SW/2+HBLANK)*VBLANK+16);
          end
        end
    endtask
    task settle;
        begin wait(!cam_busy && !busy && !cap_busy && idle);repeat(8)@(negedge cam_clk);end
    endtask
    task run_frame(input integer fault,input integer code);
        integer before_results;
        begin
            settle();mode=fault;expect_code=code;before_results=results;source_done_before=source_eofs;
            start_words=checked_words;start_jobs=starts;stream_words=0;
            if(fault==4)freeze_feed=1;
            if(fault==8)begin clear_faults=1;@(negedge clk);clear_faults=0;inject_b=1;end
            if(fault==7 || fault==9)admit=0;
            if(fault==5)hold_b=1;
            fork
                frame(fault);
                begin
                    if(fault==5)begin
                        wait(cap_outstanding>0 && mem.b_count>0);
                        @(negedge clk);cancel=1;@(negedge clk);cancel=0;
                        repeat(64)begin
                            @(negedge clk);held_b_checks=held_b_checks+1;
                            if(job_done || results!=before_results || cap_outstanding==0)$fatal(1,"camera canceled before held B drained");
                        end
                        hold_b=0;
                    end
                    if(fault==11)begin
                        wait(s_valid && ingress.high_pixel);
                        @(negedge clk);freeze_feed=1;
                        repeat(4)begin
                            @(negedge clk);phase_hold_checks=phase_hold_checks+1;
                            if(!ingress.high_pixel || !s_valid)$fatal(1,"pair high-pixel hold not exercised");
                        end
                        cancel=1;@(negedge clk);cancel=0;freeze_feed=0;
                    end
                    if(fault==10)begin
                        wait(ingress.state==ingress.DRAIN && ingress.done_seen && ingress.done_settled && ingress.fifo_empty);
                        @(negedge clk);cancel=1;@(negedge clk);cancel=0;
                    end
                end
            join
            wait(results==before_results+1);settle();
            if(last_failed!=(code!=0) || last_code!=code)$fatal(1,"camera wrong completion fault=%0d got=%0d expected=%0d",fault,last_code,code);
            if(fault==2 || fault==13 || fault==14)begin
                if(stream_words>=RW*RH)$fatal(1,"tail fault did not fence final ROI pixel");
                tail_checks=tail_checks+1;
            end
            if((fault==7 || fault==9) && (starts!=start_jobs || checked_words!=start_words))$fatal(1,"rejected source launched downstream");
            freeze_feed=0;admit=1;inject_b=0;@(negedge clk);clear_faults=1;@(negedge clk);clear_faults=0;
        end
    endtask
    initial begin
`ifdef C30_RESIZE_OVERLAP
        $display("C30_RESIZE_SELECTION overlap=1");
`else
        $display("C30_RESIZE_SELECTION overlap=0");
`endif
        if(!$value$plusargs("DIR=%s",dir) || !$value$plusargs("XS=%d",xs) || !$value$plusargs("YS=%d",ys) ||
           !$value$plusargs("XP=%d",xp) || !$value$plusargs("YP=%d",yp))$fatal(1,"camera missing vectors/config");
        source_file=$fopen({dir,"/source.mem"},"r");expected_file=$fopen({dir,"/expected.mem"},"r");
        if(source_file==0 || expected_file==0)$fatal(1,"camera vector path missing (must fail before simulation)");
        $fclose(source_file);$fclose(expected_file);
        $readmemh({dir,"/source.mem"},image);$readmemh({dir,"/expected.mem"},expected);
        for(integer i=0;i<SW*SH;i=i+1)if(^image[i]===1'bx)$fatal(1,"camera source fixture has unknown pixels");
        for(integer i=0;i<OW*OH/4;i=i+1)if(^expected[i]===1'bx)$fatal(1,"camera expected fixture has unknown pixels");
        repeat(10)@(negedge cam_clk);repeat(10)@(negedge clk);rst=0;cam_rst=0;repeat(10)@(negedge cam_clk);
        if(SW==1920 && SH==1080 && !FAULTS)begin
            raw_vs=1;blank(2*(SW/2+HBLANK));
            raw_vs=0;blank(20*(SW/2+HBLANK));
        end
        if(FAULTS)begin
            run_frame(0,0);
            run_frame(1,5);run_frame(0,0);
            run_frame(2,5);run_frame(0,0);
            run_frame(3,5);run_frame(0,0);
            run_frame(4,2);run_frame(0,0);
            run_frame(5,4);run_frame(0,0);
            run_frame(6,3);run_frame(0,0);
            run_frame(7,5);run_frame(0,0);
            run_frame(8,6);run_frame(0,0);
            run_frame(9,2);run_frame(0,0);
            run_frame(10,4);run_frame(0,0);
            run_frame(11,4);run_frame(0,0);
            run_frame(12,5);run_frame(0,0);
            run_frame(13,5);run_frame(0,0);
            run_frame(14,5);run_frame(0,0);
        end else begin
            // No ready/busy wait between complete fixed-cadence source frames.
            mode=0;source_done_before=source_eofs;start_words=checked_words;frame(0);
            if(results!=1 || cam_busy || busy || cap_busy)$fatal(1,"camera job missed next source frame boundary");
            source_done_before=source_eofs;start_words=checked_words;frame(0);
            wait(results==2);settle();
        end
        if(FAULTS && (bad!=14 || good!=15 || held_b_checks!=64 || tail_checks!=3 || phase_hold_checks!=4))$fatal(1,"camera fault coverage missing");
        if(!FAULTS && !EXPECT_OVERFLOW && (bad!=0 || good!=2))$fatal(1,"camera continuous source failed");
        if(EXPECT_OVERFLOW)begin
            if(FAULTS || bad!=2 || good!=0 || last_code!=2)$fatal(1,"undersized camera FIFO did not report expected whole-frame overflow");
            $display("C1_R2_DEMO_RGB2_CAPTURE_EXPECTED_OVERFLOW frames=2 whole_frame_drop=1 no_reset=1 fifo=%0d",FD);
        end
        $display("C30_RASTER_PRODUCER vendor_rtl=%0d final_pair_waits_for_vs=1 no_ready=1",VENDOR_SOURCE);
        if(FAULTS)$display("C1_R2_DEMO_RGB2_PHASE_PASS held_high_cycles=%0d canceled_with_half_word=1 no_reset=1",phase_hold_checks);
        $display("C1_R2_DEMO_RGB2_SOURCE_PROFILE core_half_ns=%0.3f camera_half_ns=%0.3f hblank=%0d vblank=%0d sof_interval_camera_cycles=%0d faults=%0d",CORE_HALF,CAM_HALF,HBLANK,VBLANK,second_sof-first_sof,FAULTS);
        $display("C1_R2_DEMO_RGB2_CAPTURE_PASS sw=%0d sh=%0d rw=%0d rh=%0d ow=%0d oh=%0d fifo=%0d stalls=%0d results=%0d good=%0d bad=%0d roi_pixels=%0d checked_words=%0d peak=%0d held_b=%0d tail_errors=%0d aw=%0d b=%0d no_reset_recovery=1 unstoppable_source=1",SW,SH,RW,RH,OW,OH,FD,STALLS,results,good,bad,roi_pixels,checked_words,cam_peak,held_b_checks,tail_checks,aw_total,b_total);
        $finish;
    end
endmodule
