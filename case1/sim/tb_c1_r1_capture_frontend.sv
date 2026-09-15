`timescale 1ns/1ps

module tb_c1_r1_capture_frontend #(parameter integer BACKPRESSURE_CASE=0,
    FLOW_CASE=0, FLOW_FIFO_DEPTH=16, CAMERA_HALF=4, FLOW_RAMP=0, RECOVERY_CASE=0,
    VERIFY_UNKNOWN=0, RASTER_CASE=0, CHECK_RASTER=0, RASTER_ABORT=0,
    MAINTENANCE_MODE=0, IDLE_TIMEOUT=0);
    localparam integer SENSOR_W = 6;
    localparam integer SENSOR_H = FLOW_CASE ? 7 : 5;
    localparam integer OUT_PIXELS = (SENSOR_W-2)*(SENSOR_H-2);

    logic camera_clk = 1'b0;
    logic core_clk = 1'b0;
    logic camera_run=1;
    logic recovery_request=0,recovery_source_quiescent=0,recovery_fabric_drained=0;
    wire recovery_ready,recovery_busy,recovery_done;
    logic camera_rst = 1'b1;
    logic core_rst = 1'b1;
    logic camera_valid;
    logic camera_ready;
    logic [9:0] camera_raw10;
    logic [2:0] camera_x;
    logic [2:0] camera_y;
    logic camera_sof;
    logic camera_eol;
    logic camera_eof;
    logic camera_clear_error;
    logic camera_overflow;
    logic gamma_write=0;
    logic [9:0] gamma_address=0;
    logic [7:0] gamma_data=0;

    logic frame_waiting;
    logic begin_frame;
    logic begin_ready;
    logic drop_frame;
    logic discard_idle;
    logic abort_frame;
    logic clear_error;
    logic cleanup_busy;
    logic frame_ingress_done;
    logic frame_dropped;
    logic frame_aborted;
    logic capture_error;
    logic [7:0] capture_error_code;

    logic cfg_commit;
    logic cfg_ready;
    logic gamma_cfg_ready;
    logic m_valid;
    logic m_ready;
    logic [23:0] m_rgb;
    logic m_sof;
    logic m_eol;
    logic m_eof;

    integer output_pixels;
    integer sof_count;
    integer eol_count;
    integer eof_count;
    integer ingress_done_count;
    integer dropped_count;
    integer aborted_count;
    integer frames_sent;
    integer ready_stalls;
    integer cleanup_cycles;
    integer cleanup_entries;
    logic cleanup_busy_q;
    integer core_cycle;
    integer camera_accepts=0,camera_stalls=0,flow_checked=0,flow_job;
    logic [7:0] flow_gray=0;
    logic [7:0] expected_gray;
    logic inject_source_fault=0,source_fault_injected=0;
    integer flow_input_offset=0;
    logic hold_capture_output=0;
    logic source_paused=0,release_source_pause=0;
    integer idle_wait_cycles=0;
    always @(posedge core_clk) begin
        if(core_rst || !dut.raw_idle_wait) idle_wait_cycles=0;
        else if(IDLE_TIMEOUT>0) begin
            idle_wait_cycles++;
            if(dut.raw_idle_fault !== (idle_wait_cycles==IDLE_TIMEOUT))
                $fatal(1,"RAW inactivity threshold off-by-one count=%0d threshold=%0d",idle_wait_cycles,IDLE_TIMEOUT);
        end
    end
    always @(posedge camera_clk) begin
        if(!camera_rst) begin
            if(camera_valid && camera_ready) camera_accepts++;
            if(camera_valid && !camera_ready) camera_stalls++;
        end
    end
    always @(posedge core_clk) begin
        if(FLOW_CASE && !core_rst && m_valid && m_ready) begin
            // An affine achromatic Bayer plane is preserved by bilinear
            // Debayer at each interior center. Identity color + LUT x>>2
            // therefore has a direct analytic expected value (no RTL copy).
            expected_gray=FLOW_RAMP ? 8'((int'(flow_gray)*4 +
                (flow_checked/(SENSOR_W-2)+1)*37 +
                (flow_checked%(SENSOR_W-2)+1)*11)>>2) : flow_gray;
            if(m_rgb!=={expected_gray,expected_gray,expected_gray} ||
               m_sof!==(flow_checked==0) ||
               m_eol!==((flow_checked% (SENSOR_W-2))==SENSOR_W-3) ||
               m_eof!==(flow_checked==OUT_PIXELS-1) || flow_checked>=OUT_PIXELS)
                $fatal(1,"pausable capture pixel/marker mismatch pixel=%0d rgb=%h gray=%h",flow_checked,m_rgb,expected_gray);
            flow_checked++;
        end
    end

    always #(CAMERA_HALF) if(camera_run) camera_clk = ~camera_clk;
    always #5 core_clk = ~core_clk;

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            core_cycle <= 0;
            m_ready <= 1'b0;
            output_pixels <= 0;
            sof_count <= 0;
            eol_count <= 0;
            eof_count <= 0;
            ingress_done_count <= 0;
            dropped_count <= 0;
            aborted_count <= 0;
            ready_stalls <= 0;
            cleanup_cycles <= 0;
            cleanup_entries <= 0;
            cleanup_busy_q <= 1'b0;
        end else begin
            core_cycle <= core_cycle + 1;
            m_ready <= !hold_capture_output && ((core_cycle % 5) != 2);
            if (m_valid && !m_ready)
                ready_stalls <= ready_stalls + 1;
            if (m_valid && m_ready) begin
                output_pixels <= output_pixels + 1;
                if (m_sof) sof_count <= sof_count + 1;
                if (m_eol) eol_count <= eol_count + 1;
                if (m_eof) eof_count <= eof_count + 1;
            end
            if (frame_ingress_done)
                ingress_done_count <= ingress_done_count + 1;
            if (frame_dropped)
                dropped_count <= dropped_count + 1;
            if (frame_aborted)
                aborted_count <= aborted_count + 1;
            if (cleanup_busy)
                cleanup_cycles <= cleanup_cycles + 1;
            if (cleanup_busy && !cleanup_busy_q)
                cleanup_entries <= cleanup_entries + 1;
            cleanup_busy_q <= cleanup_busy;
        end
    end

    c1_r1_capture_frontend #(
        .SENSOR_WIDTH(SENSOR_W), .SENSOR_HEIGHT(SENSOR_H),
        .CAMERA_FIFO_DEPTH(FLOW_CASE ? FLOW_FIFO_DEPTH : 64), .OUTPUT_FIFO_DEPTH(32),
        .PIPELINE_HEADROOM(12), .X_BITS(3), .Y_BITS(3),
        .CAMERA_READY_VALID_SOURCE(FLOW_CASE || (BACKPRESSURE_CASE>0 && BACKPRESSURE_CASE<4) || BACKPRESSURE_CASE==5),
        .CHECK_RAW_RASTER(CHECK_RASTER || RASTER_CASE!=0),
        .RAW_IDLE_TIMEOUT_CYCLES(IDLE_TIMEOUT),
        .ENABLE_EXPLICIT_RECOVERY(RASTER_CASE==8)
    ) dut (
        .recovery_request(recovery_request),.recovery_source_quiescent(recovery_source_quiescent),
        .recovery_fabric_drained(recovery_fabric_drained),.recovery_ready(recovery_ready),
        .recovery_busy(recovery_busy),.recovery_done(recovery_done),
        .camera_clk(camera_clk), .camera_rst(camera_rst),
        .camera_valid(camera_valid), .camera_ready(camera_ready),
        .camera_raw10(camera_raw10), .camera_x(camera_x), .camera_y(camera_y),
        .camera_sof(camera_sof), .camera_eol(camera_eol),
        .camera_eof(camera_eof), .camera_clear_error(camera_clear_error),
        .camera_overflow(camera_overflow),
        .core_clk(core_clk), .core_rst(core_rst),
        .frame_waiting(frame_waiting), .begin_frame(begin_frame),
        .begin_ready(begin_ready), .drop_frame(drop_frame),
        .discard_idle(discard_idle), .abort_frame(abort_frame),
        .clear_error(clear_error), .cleanup_busy(cleanup_busy),
        .frame_ingress_done(frame_ingress_done),
        .frame_dropped(frame_dropped), .frame_aborted(frame_aborted),
        .capture_error(capture_error),
        .capture_error_code(capture_error_code),
        .cfg_commit(cfg_commit), .cfg_ready(cfg_ready),
        .cfg_bayer_pattern(2'b00), .cfg_roi_x_parity(1'b0),
        .cfg_roi_y_parity(1'b0), .cfg_black_r(10'd0),
        .cfg_black_gr(10'd0), .cfg_black_gb(10'd0), .cfg_black_b(10'd0),
        .cfg_awb_gain_r(16'd16384), .cfg_awb_gain_g(16'd16384),
        .cfg_awb_gain_b(16'd16384),
        .cfg_ccm_rr(16'sd8192), .cfg_ccm_rg(16'sd0),
        .cfg_ccm_rb(16'sd0), .cfg_ccm_gr(16'sd0),
        .cfg_ccm_gg(16'sd8192), .cfg_ccm_gb(16'sd0),
        .cfg_ccm_br(16'sd0), .cfg_ccm_bg(16'sd0),
        .cfg_ccm_bb(16'sd8192), .cfg_ccm_offset_r(32'sd0),
        .cfg_ccm_offset_g(32'sd0), .cfg_ccm_offset_b(32'sd0),
        .gamma_cfg_we(gamma_write), .gamma_cfg_addr(gamma_address),
        .gamma_cfg_data(gamma_data), .gamma_cfg_ready(gamma_cfg_ready),
        .m_valid(m_valid), .m_ready(m_ready), .m_rgb(m_rgb),
        .m_sof(m_sof), .m_eol(m_eol), .m_eof(m_eof)
    );

    task automatic send_raw_frame(input integer seed);
        integer x;
        integer y;
        logic accepted;
        begin
            begin : raster_pixels
            for (y = 0; y < SENSOR_H; y = y + 1) begin
                for (x = 0; x < SENSOR_W; x = x + 1) begin
                    if((RASTER_CASE==5 || RASTER_CASE==6 || RASTER_CASE==7 || RASTER_CASE==8) && seed==128 && y*SENSOR_W+x==20)
                        disable raster_pixels;
                    @(negedge camera_clk);
                    if(RECOVERY_CASE==5 && seed==128 && y==3 && x==2) begin
                        camera_valid=0;
                        source_paused=1;
                        while(!release_source_pause) @(negedge camera_clk);
                    end
                    camera_valid = 1'b1;
                    camera_raw10 = (FLOW_CASE && !FLOW_RAMP) ? 10'(seed) : (seed + y*37 + x*11) & 10'h3ff;
                    if(VERIFY_UNKNOWN==1) camera_raw10='x;
                    camera_x = x[2:0];
                    camera_y = y[2:0];
                    camera_sof = (x == 0) && (y == 0);
                    camera_eol = (x == SENSOR_W-1);
                    camera_eof = (x == SENSOR_W-1) && (y == SENSOR_H-1);
                    if(VERIFY_UNKNOWN==3) camera_eof=0;
                    if(VERIFY_UNKNOWN==4) camera_eof=(x==0 && y==0);
                    if(seed==128) begin
                        if(RASTER_CASE==1 && y*SENSOR_W+x==20) camera_x=x+1;
                        if(RASTER_CASE==2 && y*SENSOR_W+x==20) camera_eol=1;
                        if(RASTER_CASE==3 && y*SENSOR_W+x==20) camera_eof=1;
                        if(RASTER_CASE==4) camera_eof=0;
                    end
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge camera_clk);
                        accepted = camera_ready;
                        if(inject_source_fault && !accepted && !source_fault_injected) begin
                            @(negedge camera_clk);
                            camera_raw10=camera_raw10 ^ 10'd1;
                            source_fault_injected=1;
                        end
                    end
                end
            end
            end
            @(negedge camera_clk);
            camera_valid = 1'b0;
            camera_sof = 1'b0;
            camera_eol = 1'b0;
            camera_eof = 1'b0;
            frames_sent = frames_sent + 1;
        end
    endtask

    // Deliberately begins without SOF to prove maintenance discard can
    // re-synchronize a FIFO whose head is in the middle of a sensor frame.
    task automatic send_raw_tail(input integer seed);
        integer x;
        integer y;
        logic accepted;
        begin
            for (y = 2; y < SENSOR_H; y = y + 1) begin
                for (x = 0; x < SENSOR_W; x = x + 1) begin
                    @(negedge camera_clk);
                    camera_valid = 1'b1;
                    camera_raw10 = (seed + y*37 + x*11) & 10'h3ff;
                    camera_x = x[2:0];
                    camera_y = y[2:0];
                    camera_sof = 1'b0;
                    camera_eol = (x == SENSOR_W-1);
                    camera_eof = (x == SENSOR_W-1) && (y == SENSOR_H-1);
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge camera_clk);
                        accepted = camera_ready;
                    end
                end
            end
            @(negedge camera_clk);
            camera_valid = 1'b0;
            camera_eol = 1'b0;
            camera_eof = 1'b0;
        end
    endtask

    task automatic pulse_begin;
        begin
            wait (begin_ready);
            @(negedge core_clk);
            begin_frame = 1'b1;
            @(posedge core_clk);
            @(negedge core_clk);
            begin_frame = 1'b0;
        end
    endtask

    task automatic pulse_drop;
        begin
            wait (frame_waiting);
            @(negedge core_clk);
            drop_frame = 1'b1;
            @(posedge core_clk);
            @(negedge core_clk);
            drop_frame = 1'b0;
        end
    endtask

    initial begin
        camera_valid = 1'b0;
        camera_raw10 = '0;
        camera_x = '0;
        camera_y = '0;
        camera_sof = 1'b0;
        camera_eol = 1'b0;
        camera_eof = 1'b0;
        camera_clear_error = 1'b0;
        begin_frame = 1'b0;
        drop_frame = 1'b0;
        discard_idle = 1'b0;
        abort_frame = 1'b0;
        clear_error = 1'b0;
        cfg_commit = 1'b0;
        frames_sent = 0;

        repeat (6) @(posedge camera_clk);
        repeat (6) @(posedge core_clk);
        @(negedge camera_clk);
        camera_rst = 1'b0;
        @(negedge core_clk);
        core_rst = 1'b0;

        if(BACKPRESSURE_CASE) begin
            // Fill without starting ISP: isolate the camera port contract,
            // not the raster parser. The queued synthetic tokens are not a frame.
            @(negedge camera_clk);camera_valid=1;camera_raw10=10'h123;camera_sof=1;
            wait(!camera_ready);
            repeat(8) @(negedge camera_clk);
            if((BACKPRESSURE_CASE<4 || BACKPRESSURE_CASE==5) && camera_overflow)
                $fatal(1,"legal camera ready/valid stall reported overflow");
            if(BACKPRESSURE_CASE==2) camera_raw10=10'h124;
            if(BACKPRESSURE_CASE==3) camera_valid=0;
            if(BACKPRESSURE_CASE==5 || BACKPRESSURE_CASE==6) begin
                // Case 5: one-time held-payload violation exactly on clear.
                // Case 6: a free-running lost sample while clearing overflow.
                camera_clear_error=1;
                if(BACKPRESSURE_CASE==5) camera_raw10=10'h124;
                @(posedge camera_clk);#1;
                if(!camera_overflow)
                    $fatal(1,"fresh camera fault lost to simultaneous clear case=%0d",BACKPRESSURE_CASE);
                @(negedge camera_clk);camera_clear_error=0;
            end
            repeat(8) @(negedge camera_clk);
            if(camera_overflow !== (BACKPRESSURE_CASE!=1))
                $fatal(1,"camera source contract violation not classified case=%0d",BACKPRESSURE_CASE);
            repeat(6) @(negedge core_clk);
            if(capture_error !== (BACKPRESSURE_CASE!=1) ||
               (capture_error && capture_error_code!=8'h01))
                $fatal(1,"camera source error did not reach core diagnostic");
            if(BACKPRESSURE_CASE==1) begin
                @(negedge core_clk);discard_idle=1;
                wait(camera_ready);
                @(posedge camera_clk);
                #1;
                if(camera_overflow) $fatal(1,"held beat failed on READY recovery");
                @(negedge camera_clk);camera_valid=0;
                repeat(8) @(negedge camera_clk);
                if(camera_overflow) $fatal(1,"accepted beat withdrawal falsely reported");
            end
            if(BACKPRESSURE_CASE==5 || BACKPRESSURE_CASE==6) begin
                @(negedge camera_clk);camera_valid=0;
                repeat(3) @(negedge camera_clk);
                camera_clear_error=1;
                @(posedge camera_clk);#1;
                if(camera_overflow) $fatal(1,"camera clear without fresh fault failed");
                @(negedge camera_clk);camera_clear_error=0;
                repeat(8) @(negedge core_clk);
                clear_error=1;
                @(negedge core_clk);clear_error=0;
                repeat(4) @(negedge core_clk);
                if(capture_error || camera_overflow)
                    $fatal(1,"camera clear collision recovery retained stale error");
                $display("C1_CAMERA_CLEAR_COLLISION_PASS case=%0d half=%0d fault_wins=1 clean_clear=1",BACKPRESSURE_CASE,CAMERA_HALF);
            end
            $display("C1_CAPTURE_SOURCE_CONTRACT_PASS case=%0d overflow=%b",BACKPRESSURE_CASE,camera_overflow);
            $finish;
        end

        // Match the software-programmed LUT contract; do not rely on FPGA
        // power-up RAM values or disable the uninitialized-read assertion.
        for(integer lut=0;lut<(VERIFY_UNKNOWN==2 ? 0 : 1024);lut++) begin
            @(negedge core_clk);gamma_write=1;gamma_address=10'(lut);gamma_data=8'(lut>>2);
            @(posedge core_clk);
            if(!gamma_cfg_ready) $fatal(1,"capture gamma initialization not accepted");
        end
        @(negedge core_clk);gamma_write=0;
        wait (cfg_ready);
        @(negedge core_clk);
        cfg_commit = 1'b1;
        @(posedge core_clk);
        @(negedge core_clk);
        cfg_commit = 1'b0;

        if(RASTER_CASE==8) begin
            hold_capture_output=1;
            fork send_raw_frame(128); pulse_begin(); join
            wait(capture_error);
            if(capture_error_code!==8'h06) $fatal(1,"explicit recovery fixture missing timeout");
            @(negedge core_clk);recovery_request=1;
            // Queued stale tail is frozen, not consumed as a recovery EOF.
            send_raw_tail(181);
            repeat(8) @(negedge core_clk);
            if(!recovery_busy || !cleanup_busy || !dut.camera_fifo_out_valid ||
               dut.raw_fire || dut.isp_in_valid || dut.recovery_core_reset)
                $fatal(1,"recovery failed to freeze stale RAW before safe conditions");
            recovery_source_quiescent=1;
            repeat(12) @(negedge core_clk);
            if(dut.recovery_core_reset || !recovery_busy)
                $fatal(1,"recovery flushed before fabric drain");
            if(MAINTENANCE_MODE==1) begin @(negedge camera_clk);camera_run=0;end
            @(negedge core_clk);recovery_fabric_drained=1;
            wait(dut.recovery_core_reset);
            if(MAINTENANCE_MODE==2) begin
                wait(dut.recovery_camera_reset);
                @(negedge camera_clk);camera_run=0;
            end
            if(MAINTENANCE_MODE!=0) begin
                repeat(31) begin
                    @(negedge core_clk);
                    if(!recovery_busy || recovery_done || !cleanup_busy)
                        $fatal(1,"capture recovery completed without camera clock");
                end
                camera_run=1;
            end
            wait(recovery_done);
            repeat(12) @(negedge core_clk);
            if(recovery_busy || recovery_ready || cleanup_busy || dut.camera_fifo_out_valid ||
               m_valid || output_pixels!=0 || ingress_done_count!=0 || !capture_error)
                $fatal(1,"capture recovery did not flush stale frame exactly once");
            clear_error=1;
            @(negedge core_clk);clear_error=0;
            recovery_source_quiescent=0;
            send_raw_frame(256);
            flow_checked=0;flow_gray=64;hold_capture_output=0;
            pulse_begin();
            wait(ingress_done_count==1 && eof_count==1);
            repeat(12) @(negedge core_clk);
            if(flow_checked!=OUT_PIXELS || capture_error || camera_overflow || recovery_busy)
                $fatal(1,"explicit recovery new frame mismatch");
            $display("C1_CAPTURE_EXPLICIT_RECOVERY_PASS mode=%0d half=%0d stale_tail=30 pixels=20 no_reset=1 retained_gamma=1",MAINTENANCE_MODE,CAMERA_HALF);
            $finish;
        end
        if(RASTER_CASE==6) begin
            // Maintenance discards a truncated frame while admission is shut.
            // Once maintenance ends, the following SOF is the new boundary;
            // do not sacrifice that entire good frame waiting for old EOF.
            hold_capture_output=1;discard_idle=1;
            send_raw_frame(128);
            repeat(20) @(negedge core_clk);
            if(!cleanup_busy || capture_error || camera_accepts!=20)
                $fatal(1,"maintenance truncated-frame fixture mismatch");
            if(MAINTENANCE_MODE==1) abort_frame=1;
            if(MAINTENANCE_MODE!=2) discard_idle=0;
            send_raw_frame(256);
            if(MAINTENANCE_MODE==1) begin
                repeat(12) @(negedge core_clk);
                if(!cleanup_busy || !dut.camera_fifo_out_valid || !dut.fifo_sof ||
                   dut.camera_fifo_out_ready)
                    $fatal(1,"held abort lost silent-drain SOF boundary");
                abort_frame=0;
            end
            if(MAINTENANCE_MODE==2) begin
                repeat(100) @(negedge core_clk);
                if(cleanup_busy || dut.camera_fifo_out_valid || begin_ready)
                    $fatal(1,"continuous maintenance failed to discard complete next frame");
                discard_idle=0;
                send_raw_frame(512);
            end
            wait(!cleanup_busy);
            repeat(8) @(negedge core_clk);
            if(!begin_ready || !dut.camera_fifo_out_valid || !dut.fifo_sof ||
               output_pixels!=0 || ingress_done_count!=0 || dropped_count!=0 || aborted_count!=0)
                $fatal(1,"maintenance missing EOF consumed next clean frame");
            flow_checked=0;flow_gray=(MAINTENANCE_MODE==2 ? 128 : 64);hold_capture_output=0;
            pulse_begin();
            wait(ingress_done_count==1 && eof_count==1);
            repeat(12) @(negedge core_clk);
            if(flow_checked!=OUT_PIXELS || camera_accepts!=20+(MAINTENANCE_MODE==2 ? 2 : 1)*SENSOR_W*SENSOR_H ||
               capture_error || camera_overflow || cleanup_busy)
                $fatal(1,"maintenance SOF recovery pixel/count mismatch");
            $display("C1_CAPTURE_MAINTENANCE_SOF_PASS half=%0d mode=%0d prefix=20 rgb=%0d no_reset=1",CAMERA_HALF,MAINTENANCE_MODE,flow_checked);
            $finish;
        end
        if(RASTER_CASE!=0) begin
            hold_capture_output=1;
            fork
                begin
                    send_raw_frame(128);
                    if(RASTER_CASE==7) begin
                        wait(capture_error);
                        repeat(64) begin
                            @(negedge core_clk);
                            if(!cleanup_busy || begin_ready || m_valid || frame_ingress_done)
                                $fatal(1,"idle timeout released frame before source boundary");
                        end
                        $display("C1_RAW_IDLE_TIMEOUT_HOLD_PASS cycles=64 threshold=%0d",IDLE_TIMEOUT);
                    end
                    // Queue a complete clean frame before acknowledging the
                    // fault; its SOF must survive resynchronization unpopped.
                    send_raw_frame(256);
                end
                begin
                    pulse_begin();
                    if(RASTER_ABORT) begin
                        @(negedge core_clk);
                        while(!(dut.raw_fire && dut.fifo_x==1 && dut.fifo_y==3))
                            @(negedge core_clk);
                        abort_frame=1;
                    end
                    wait(capture_error);
                    if(capture_error_code!==(RASTER_CASE==7 ? 8'h06 : 8'h05))
                        $fatal(1,"raster hardware fault code mismatch");
                    if(RASTER_ABORT) begin
                        repeat(12) @(negedge core_clk);
                        if(!cleanup_busy || begin_ready || ingress_done_count!=0)
                            $fatal(1,"held abort escaped raster cleanup");
                        abort_frame=0;
                    end
                    wait(!cleanup_busy);
                end
            join
            repeat(8) @(negedge core_clk);
            if(output_pixels!=0 || ingress_done_count!=0 || m_valid ||
               !capture_error || capture_error_code!==(RASTER_CASE==7 ? 8'h06 : 8'h05) || camera_overflow ||
               !dut.camera_fifo_out_valid || !dut.fifo_sof || dut.fifo_x!=0 || dut.fifo_y!=0)
                $fatal(1,"raster recovery leaked output or lost next SOF");
            // No reset, no scalar configuration reload, no Gamma reload.
            clear_error=1;
            @(negedge core_clk);clear_error=0;
            flow_checked=0;flow_gray=64;hold_capture_output=0;
            pulse_begin();
            wait(ingress_done_count==1 && eof_count==1);
            repeat(12) @(negedge core_clk);
            if(flow_checked!=OUT_PIXELS || output_pixels!=OUT_PIXELS || capture_error ||
               cleanup_busy || aborted_count!=RASTER_ABORT ||
               camera_accepts!=(((RASTER_CASE==5 || RASTER_CASE==7) ? 20 : SENSOR_W*SENSOR_H)+SENSOR_W*SENSOR_H))
                $fatal(1,"raster clean recovery frame/count mismatch");
            $display("C1_CAPTURE_RASTER_RECOVERY_PASS fault=%0d camera_half=%0d abort=%0d rgb=%0d preserved_sof=1 retained_config=1 retained_gamma=1",RASTER_CASE,CAMERA_HALF,RASTER_ABORT,flow_checked);
            $finish;
        end

        if(FLOW_CASE) begin
            if(RECOVERY_CASE==4) begin
                hold_capture_output=1;
                fork
                    send_raw_frame(128);
                    begin
                        pulse_begin();
                        @(negedge core_clk);
                        while(!(dut.raw_fire && dut.fifo_eof)) @(negedge core_clk);
                        if(dut.state!=dut.ST_STREAM || m_ready)
                            $fatal(1,"overflow EOF fixture missed active terminal RAW beat");
                        // Fault injection at the ISP/FIFO admission seam, not
                        // a claim that legal headroom settings naturally overflow.
                        force dut.output_fifo_in_valid=1'b1;
                        force dut.output_fifo_in_ready=1'b0;
                        @(posedge core_clk);
                        if(!dut.raw_fire || !dut.fifo_eof)
                            $fatal(1,"overflow injection missed EOF accepting edge");
                        #1;
                        if(!capture_error || capture_error_code!=8'h03 || !cleanup_busy)
                            $fatal(1,"overflow EOF did not enter error cleanup");
                        @(negedge core_clk);
                        release dut.output_fifo_in_valid;
                        release dut.output_fifo_in_ready;
                        wait(!cleanup_busy);
                    end
                join
                repeat(8) @(negedge core_clk);
                if(output_pixels || ingress_done_count || eof_count || dropped_count ||
                   aborted_count || m_valid || !capture_error || capture_error_code!=8'h03 ||
                   camera_overflow || camera_accepts!=SENSOR_W*SENSOR_H)
                    $fatal(1,"overflow EOF recovery leaked data or wrong terminal status");
                clear_error=1;
                @(negedge core_clk);clear_error=0;
                repeat(4) @(negedge core_clk);
                if(capture_error || cleanup_busy) $fatal(1,"overflow clear did not rearm");
                flow_input_offset=camera_accepts;
                hold_capture_output=0;
                $display("C1_CAPTURE_OVERFLOW_EOF_PASS raw=%0d error=03 no_rgb=1 no_reset=1 injected_seam=1",flow_input_offset);
            end
            if(RECOVERY_CASE==2 || RECOVERY_CASE==3 || RECOVERY_CASE==5) begin
                hold_capture_output=1;
                fork
                    send_raw_frame(128);
                    begin
                        pulse_begin();
                        if(RECOVERY_CASE==5) begin
                            wait(source_paused);
                            @(negedge core_clk);
                        end else if(RECOVERY_CASE==3) begin
                            @(negedge core_clk);
                            while(!(dut.raw_fire && dut.fifo_eof)) @(negedge core_clk);
                        end else begin
                            wait(m_valid);
                            @(negedge core_clk);
                        end
                        if(dut.state!=dut.ST_STREAM || m_ready)
                            $fatal(1,"active abort fixture missed in-flight RAW/RGB overlap");
                        abort_frame=1;
                        wait(cleanup_busy);
                        if(RECOVERY_CASE==5) begin
                            repeat(128) begin
                                @(negedge core_clk);
                                if(!cleanup_busy || begin_ready || frame_ingress_done ||
                                   output_pixels || capture_error)
                                    $fatal(1,"missing EOF released ownership/admission early");
                            end
                            if(camera_accepts!=20)
                                $fatal(1,"source pause fixture did not stop at expected prefix");
                            $display("C1_CAPTURE_EOF_WAIT_PASS paused_raw=20 wait_cycles=128 admission_closed=1");
                        end
                        repeat(12) @(negedge core_clk);
                        abort_frame=0;
                        if(RECOVERY_CASE==5) release_source_pause=1;
                        wait(!cleanup_busy);
                    end
                join
                repeat(8) @(negedge core_clk);
                if(output_pixels || ingress_done_count || eof_count || dropped_count ||
                   aborted_count!=1 || m_valid || capture_error || camera_overflow ||
                   camera_accepts!=SENSOR_W*SENSOR_H)
                    $fatal(1,"active abort failed to retire RAW/ISP/output buffers");
                flow_input_offset=camera_accepts;
                hold_capture_output=0;
                $display("C1_CAPTURE_ACTIVE_ABORT_PASS boundary=%0d drained_raw=%0d aborted=1 no_rgb=1 no_reset=1",RECOVERY_CASE,flow_input_offset);
            end
            if(RECOVERY_CASE==1) begin
                inject_source_fault=1;
                fork
                    send_raw_frame(128);
                    begin
                        wait(capture_error);
                        if(!source_fault_injected || capture_error_code!=8'h01)
                            $fatal(1,"wrong source-fault diagnostic during recovery");
                        @(negedge core_clk);discard_idle=1;
                        wait(cleanup_busy);
                        wait(!cleanup_busy);
                    end
                join
                @(negedge core_clk);discard_idle=0;inject_source_fault=0;
                repeat(8) @(negedge core_clk);
                if(output_pixels!=0 || ingress_done_count!=0 || dropped_count!=0 ||
                   camera_accepts!=SENSOR_W*SENSOR_H || !capture_error)
                    $fatal(1,"failed input frame leaked output or did not drain");
                // Core acknowledges first; camera sticky clear crosses back
                // before admitting a new frame. No domain reset is used.
                clear_error=1;
                @(negedge core_clk);clear_error=0;
                @(negedge camera_clk);camera_clear_error=1;
                @(negedge camera_clk);camera_clear_error=0;
                repeat(8) @(negedge core_clk);
                if(camera_overflow || capture_error || cleanup_busy)
                    $fatal(1,"source fault failed to clear/rearm");
                flow_input_offset=camera_accepts;
                $display("C1_CAPTURE_SOURCE_RECOVERY_PASS discarded_raw=%0d no_rgb=1 no_reset=1",flow_input_offset);
            end
            for(flow_job=0;flow_job<2;flow_job++) begin
                flow_checked=0;flow_gray=8'(64*(flow_job+1));
                fork
                    send_raw_frame(256*(flow_job+1));
                    begin
                        wait(!camera_ready);
                        repeat(13) @(negedge camera_clk);
                        if(camera_overflow || capture_error)
                            $fatal(1,"legal frame backlog falsely reported overflow");
                        pulse_begin();
                    end
                join
                wait(ingress_done_count==flow_job+1 && eof_count==flow_job+1);
                repeat(12) @(negedge core_clk);
                if(flow_checked!=OUT_PIXELS || camera_accepts!=flow_input_offset+(flow_job+1)*SENSOR_W*SENSOR_H ||
                   output_pixels!=(flow_job+1)*OUT_PIXELS || camera_overflow || capture_error)
                    $fatal(1,"pausable frame conservation/recovery failed");
            end
            if(camera_stalls<26 || ready_stalls==0)
                $fatal(1,"pausable test lacked input/output backpressure");
            $display("C1_CAPTURE_PAUSABLE_FRAMES_PASS depth=%0d half=%0d ramp=%0d frames=2 raw=%0d rgb=%0d camera_stalls=%0d output_stalls=%0d",
                FLOW_FIFO_DEPTH,CAMERA_HALF,FLOW_RAMP,camera_accepts,output_pixels,camera_stalls,ready_stalls);
            $finish;
        end

        // Normal frame: allocation may happen after the complete raw frame is
        // already buffered.  The valid-crop ISP emits exactly 4x3 pixels.
        send_raw_frame(7);
        pulse_begin();
        wait (ingress_done_count >= 1);
        wait (eof_count >= 1);
        if ((output_pixels != OUT_PIXELS) || (sof_count != 1) ||
            (eol_count != SENSOR_H-2) || (eof_count != 1))
            $fatal(1, "capture normal-frame geometry mismatch pixels=%0d sof=%0d eol=%0d eof=%0d",
                   output_pixels, sof_count, eol_count, eof_count);

        // Drop a complete queued frame before enabling the ISP.
        send_raw_frame(101);
        pulse_drop();
        wait (dropped_count >= 1);
        repeat (40) @(posedge core_clk);
        if (output_pixels != OUT_PIXELS)
            $fatal(1, "dropped raw frame leaked RGB pixels");

        // Maintenance discard consumes a complete queued frame without an
        // output beat, capture error, or software-visible drop notification.
        begin : silent_discard_checks
            integer output_before;
            integer drops_before;
            integer cleanups_before;
            output_before = output_pixels;
            drops_before = dropped_count;
            cleanups_before = cleanup_entries;
            @(negedge core_clk);
            discard_idle = 1'b1;
            fork
                send_raw_frame(151);
                begin
                    wait (cleanup_busy);
                    wait (!cleanup_busy);
                end
            join
            repeat (4) @(posedge core_clk);
            if ((output_pixels != output_before) ||
                (dropped_count != drops_before) || capture_error ||
                (cleanup_entries != cleanups_before + 1))
                $fatal(1, "silent full-frame discard was not silent/complete");

            // Repeat from a non-SOF FIFO head and clear a pre-existing local
            // command error while cleanup is active.  Cleanup must still run
            // through EOF and leave the frontend restartable.
            @(negedge core_clk);
            discard_idle = 1'b0;
            begin_frame = 1'b1;
            @(posedge core_clk);
            @(negedge core_clk);
            begin_frame = 1'b0;
            wait (capture_error && (capture_error_code == 8'h04));

            discard_idle = 1'b1;
            fork
                send_raw_tail(181);
                begin
                    wait (cleanup_busy);
                    @(negedge core_clk);
                    clear_error = 1'b1;
                    @(posedge core_clk);
                    @(negedge core_clk);
                    clear_error = 1'b0;
                    wait (!cleanup_busy);
                end
            join
            repeat (4) @(posedge core_clk);
            discard_idle = 1'b0;
            if (capture_error || (output_pixels != output_before) ||
                (dropped_count != drops_before) ||
                (cleanup_entries != cleanups_before + 2))
                $fatal(1, "mid-frame discard/clear did not recover silently");
        end

        // Hold abort as a level after streaming starts.  Cleanup must drain to
        // EOF, pulse aborted exactly once, then accept a restart without reset.
        send_raw_frame(203);
        pulse_begin();
        repeat (8) @(posedge core_clk);
        @(negedge core_clk);
        abort_frame = 1'b1;
        repeat (12) @(posedge core_clk);
        @(negedge core_clk);
        abort_frame = 1'b0;
        wait (aborted_count >= 1);
        wait (!cleanup_busy);
        repeat (8) @(posedge core_clk);
        if (aborted_count != 1)
            $fatal(1, "level abort produced %0d aborted pulses", aborted_count);

        send_raw_frame(307);
        pulse_begin();
        wait (ingress_done_count >= 2);
        wait (eof_count >= 2);

        if (camera_overflow || capture_error)
            $fatal(1, "capture frontend ended with error code=%02x", capture_error_code);
        $display("C1_CAPTURE_FRONTEND_PASS frames=%0d ingress=%0d dropped=%0d aborted=%0d output=%0d stalls=%0d cleanup_entries=%0d cleanup_cycles=%0d",
                 frames_sent, ingress_done_count, dropped_count,
                 aborted_count, output_pixels, ready_stalls,
                 cleanup_entries, cleanup_cycles);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "capture frontend test timeout");
    end
endmodule
