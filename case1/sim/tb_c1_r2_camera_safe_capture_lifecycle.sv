`timescale 1ns/1ps
module tb_c1_r2_camera_safe_capture_lifecycle;
    parameter integer SW=20,SH=20,RX=2,RY=2,RW=16,RH=16,OW=8,OH=8,
        FD=64,STALLS=0,FAULTS=1,HBLANK=4,VBLANK=4,FRAME_TIMEOUT=(SW+HBLANK)*(SH+VBLANK)*3;
    parameter real CORE_HALF=5.0,CAM_HALF=11.0;
    reg clk=0,cam_clk=0;always #(CORE_HALF)clk=~clk;
    initial begin #1.7;forever #(CAM_HALF)cam_clk=~cam_clk;end
    reg rst=1,cam_rst=1,enable=1,cancel=0;
    reg cam_valid=0,cam_sof=0,cam_eol=0,cam_eof=0,cam_error=0;
    reg [23:0] cam_rgb=0;
    wire cam_busy;wire [31:0] cam_seen,cam_skipped;wire [$clog2(FD):0] cam_peak;
    wire job_valid,job_ready,job_cancel,job_done,job_failed,busy,config_error;
    wire [31:0] job_tag,result_tag;wire result_valid,result_failed,result_admitted;wire [3:0] result_code;
    wire s_valid,s_ready,s_sof,s_eol,s_eof;wire [23:0] s_rgb;wire [15:0] s_x,s_y;
    c1_r2_camera_ingress_guarded #(.SOURCE_WIDTH(SW),.SOURCE_HEIGHT(SH),.ROI_X(RX),.ROI_Y(RY),
        .ROI_WIDTH(RW),.ROI_HEIGHT(RH),.FIFO_DEPTH(FD),.FRAME_TIMEOUT(FRAME_TIMEOUT)) ingress(.*);
    // Independently observe source launch flops: sample the pre-NBA control,
    // then check the actual register after NBA, and reject any off-clock update.
    realtime last_core_edge=-1.0;
    reg launch_enable_expect,launch_cancel_expect;
    integer launch_checks=0,launch_edges=0;
    always @(posedge clk)begin
        last_core_edge=$realtime;
        launch_enable_expect=enable;launch_cancel_expect=ingress.source_cancel;
        #0.001;
        if(!rst)begin
            if(ingress.enable_source_q!==launch_enable_expect ||
               ingress.cancel_source_q!==launch_cancel_expect)
                $fatal(1,"C28 source control register did not sample core input");
            launch_checks=launch_checks+1;
        end
    end
    always @(ingress.enable_source_q or ingress.cancel_source_q)if(!rst)begin
        if($realtime!=last_core_edge)$fatal(1,"C28 source control changed off core clock");
        launch_edges=launch_edges+1;
    end
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
    c1_r2_resize_capture_rgbx32 #(.FIFO_DEPTH(256)) capture (
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
    integer stream_words=0,held_b_checks=0,mode=0;
    integer cam_cycles=0,first_sof=-1,second_sof=-1;
    reg [1023:0] dir;
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
        if(cycles%1000000==0)$display("C1_R2_CAMERA_SAFE_LIFECYCLE_PROGRESS cycle=%0d results=%0d words=%0d source_peak=%0d",cycles,results,checked_words,cam_peak);
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
                $display("C1_R2_CAMERA_SAFE_LIFECYCLE_RESULT mode=%0d tag=%0d failed=%b code=%0d admitted=%b roi_pixels=%0d words=%0d cycle=%0d",mode,result_tag,result_failed,result_code,result_admitted,stream_words,checked_words-start_words,cycles);
            end
        end else held_stream=0;
    end
    task blank(input integer n);
        begin
            @(negedge cam_clk);cam_valid=0;cam_sof=0;cam_eol=0;cam_eof=0;cam_error=0;
            repeat(n>0 ? n-1 : 0)@(negedge cam_clk);
        end
    endtask
    task frame(input integer fault);
        integer y,x;
        begin
            for(y=0;y<SH;y=y+1)begin
                for(x=0;x<SW;x=x+1)begin
                    @(negedge cam_clk);cam_valid=1;cam_sof=x==0 && y==0;cam_eol=x==SW-1;cam_eof=x==SW-1 && y==SH-1;
                    cam_rgb=image[y*SW+x];cam_error=0;
                    if(fault==1 && y==RY+1 && x==RX+1)cam_eol=1;
                    if(fault==2 && y==SH-1 && x==SW-1)cam_eof=0;
                    if(fault==3 && y==SH-1 && x==SW-1)cam_error=1;
                    if(fault==7 && y==0 && x==0)cam_error=1;
                    if(fault==6 && y==RY+1 && x==SW-1)begin blank(FRAME_TIMEOUT+8);return;end
                end
                blank(HBLANK);
            end
            blank((SW+HBLANK)*VBLANK);
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
            if(fault==9)admit=0;
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
                    if(fault==10)begin
                        wait(ingress.state==ingress.DRAIN && ingress.done_seen && ingress.done_settled && ingress.fifo_empty);
                        @(negedge clk);cancel=1;@(negedge clk);cancel=0;
                    end
                end
            join
            wait(results==before_results+1);settle();
            if(last_failed!=(code!=0) || last_code!=code)$fatal(1,"camera wrong completion fault=%0d got=%0d expected=%0d",fault,last_code,code);
            if(fault==2 || fault==3)begin
                if(stream_words>=RW*RH)$fatal(1,"tail fault did not fence final ROI pixel");
                tail_checks=tail_checks+1;
            end
            if((fault==7 || fault==9) && (starts!=start_jobs || checked_words!=start_words))$fatal(1,"rejected source launched downstream");
            freeze_feed=0;admit=1;inject_b=0;@(negedge clk);clear_faults=1;@(negedge clk);clear_faults=0;
        end
    endtask
    integer before_results,before_starts,before_skips;
    initial begin
        if(!$value$plusargs("DIR=%s",dir) || !$value$plusargs("XS=%d",xs) || !$value$plusargs("YS=%d",ys) ||
           !$value$plusargs("XP=%d",xp) || !$value$plusargs("YP=%d",yp))$fatal(1,"camera missing vectors/config");
        $readmemh({dir,"/source.mem"},image);$readmemh({dir,"/expected.mem"},expected);
        repeat(10)@(negedge cam_clk);repeat(10)@(negedge clk);rst=0;cam_rst=0;repeat(10)@(negedge cam_clk);
        // Hold a REAL successful Capture completion. The next full source
        // frame is unconditionally transmitted but must be skipped in source
        // domain; it cannot overwrite or append to the previous frame.
        settle();mode=0;source_done_before=source_eofs;start_words=checked_words;cap_ack=0;
        frame(0);wait(cap_done);before_results=results;before_starts=starts;before_skips=cam_skipped;
        frame(0);
        if(results!=before_results || starts!=before_starts || cam_skipped!=before_skips+1 ||
           stream_words!=RW*RH || !cam_busy)$fatal(1,"busy camera frame spliced/lost completion fence");
        @(negedge clk);cap_ack=1;wait(results==before_results+1);settle();
        // Disable only new frames, not a currently accepted stream.
        before_results=results;
        fork
            run_frame(0,0);
            begin
                wait(ingress.source_active && ingress.y_q==RY+1);
                @(negedge clk);enable=0;
            end
        join
        if(results!=before_results+1 || last_failed)$fatal(1,"disable canceled owned frame");
        before_results=results;before_starts=starts;before_skips=cam_skipped;
        frame(0);settle();
        if(results!=before_results || starts!=before_starts || cam_skipped!=before_skips+1)$fatal(1,"disabled source admitted");
        enable=1;repeat(8)@(negedge cam_clk);run_frame(0,0);
        // A new SOF truncates the old source before ROI starts. That SOF is
        // part of the discarded stream, not an opportunity to splice frames.
        settle();mode=12;source_done_before=source_eofs;start_words=checked_words;stream_words=0;
        before_results=results;before_skips=cam_skipped;
        for(integer y=0;y<2;y=y+1)begin
            for(integer x=0;x<SW;x=x+1)begin
                @(negedge cam_clk);cam_valid=1;cam_sof=x==0 && y==0;cam_eol=x==SW-1;cam_eof=0;cam_rgb=image[y*SW+x];
            end
            blank(HBLANK);
        end
        frame(0);wait(results==before_results+1);settle();
        if(!last_failed || last_code!=1 || cam_skipped!=before_skips+1)$fatal(1,"unexpected SOF did not discard/re-sync");
        run_frame(0,0);
        if(good!=4 || bad!=1 || results!=5 || cam_seen!=8 || cam_skipped!=3 || aw_total!=b_total)$fatal(1,"camera lifecycle accounting");
        if(launch_checks<100 || launch_edges<4)$fatal(1,"C28 control launch coverage missing");
        $display("C1_R2_CAMERA_SAFE_CONTROL_PASS stalls=%0d checks=%0d edges=%0d off_clock_updates=0",STALLS,launch_checks,launch_edges);
        $display("C1_R2_CAMERA_SAFE_LIFECYCLE_PASS stalls=%0d good=%0d bad=%0d source_frames=%0d skipped=%0d held_completion_frame_skip=1 disable_owned_continues=1 unexpected_sof_recovery=1 no_reset=1 aw=%0d b=%0d",STALLS,good,bad,cam_seen,cam_skipped,aw_total,b_total);
        $finish;
    end
endmodule
