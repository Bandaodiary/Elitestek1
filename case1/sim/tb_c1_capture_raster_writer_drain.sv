`timescale 1ns/1ps
// Actual capture subsystem and ISP -> real AXI writer. The controller below
// models the documented cancel/drain contract; it is NOT the SoC controller.
module tb_c1_capture_raster_writer_drain #(
    parameter integer STALL=0, CAMERA_HALF=3, COORD_BITS=3, FAULT_AXIS=0,
    EXPLICIT_RECOVERY=0, TABLE_INFLIGHT=0, TABLE_FIFO=0
);
    logic clk=0, camera_clk=0, rst=1;
    always #5 clk=~clk;
    always #(CAMERA_HALF) camera_clk=~camera_clk;
    logic cv=0,cr,cs=0,cl=0,ce=0,overflow;
    logic [9:0] raw=0;
    logic [COORD_BITS-1:0] cx=0,cy=0;
    logic begin_frame=0,begin_ready,clear_error=0,cleanup,ingress,cap_error;
    logic [7:0] cap_code;
    logic commit=0,cfg_ready,gamma_we=0,gamma_ready;
    logic [9:0] gamma_addr=0;
    logic [7:0] gamma_data=0;
    logic start=0,cancel=0,busy,done,writer_error;
    logic [31:0] base=32'h1000,awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic av,ar,wv,wr,wl,bv,br;
    logic [127:0] wd;
    logic [15:0] ws;
    logic release_bus=0,release_source=0;
    logic recovery_request=0,source_stopped=0;
    wire recovery_ready,recovery_busy,recovery_done;
    logic table_request=0,table_arready=0,table_rvalid=0;
    wire table_arvalid,table_rready,table_response_valid;
    integer cycles=0,aws=0,wsent=0,bs=0,dones=0,ingresses=0;
    logic aw_saved=0,w_saved=0;
    logic [31:0] saved_addr;
    logic [127:0] saved_data;
    logic [127:0] good_memory [0:4];

    c1_r1_capture_subsystem #(
        .SENSOR_WIDTH(6),.SENSOR_HEIGHT(7),.CAMERA_FIFO_DEPTH(128),
        .OUTPUT_FIFO_DEPTH(64),.X_BITS(COORD_BITS),.Y_BITS(COORD_BITS),
        .CAMERA_READY_VALID_SOURCE(1),.CHECK_RAW_RASTER(1),
        .ENABLE_EXPLICIT_RECOVERY(EXPLICIT_RECOVERY),
        .ENABLE_TABLE_RESPONSE_FIFO(TABLE_FIFO)
    ) dut (
        .recovery_request(recovery_request),.recovery_source_quiescent(source_stopped),
        // Intentionally optimistic external hint: internal leaf gates must win.
        .recovery_fabric_drained(1'b1),.recovery_ready(recovery_ready),
        .recovery_busy(recovery_busy),.recovery_done(recovery_done),
        .camera_clk(camera_clk),.camera_rst(rst),.camera_valid(cv),.camera_ready(cr),
        .camera_raw10(raw),.camera_x(cx),.camera_y(cy),
        .camera_sof(cs),.camera_eol(cl),.camera_eof(ce),.camera_overflow(overflow),
        .core_clk(clk),.core_rst(rst),.frame_waiting(),
        .begin_frame(begin_frame),.begin_ready(begin_ready),.drop_frame(1'b0),
        .discard_idle(1'b0),.abort_frame(1'b0),.clear_error(clear_error),
        .cleanup_busy(cleanup),.frame_ingress_done(ingress),
        .frame_dropped(),.frame_aborted(),.capture_error(cap_error),.capture_error_code(cap_code),
        .cfg_commit(commit),.cfg_ready(cfg_ready),.cfg_bayer_pattern(2'b00),
        .cfg_roi_x_parity(1'b0),.cfg_roi_y_parity(1'b0),
        .cfg_black_r(10'd0),.cfg_black_gr(10'd0),.cfg_black_gb(10'd0),.cfg_black_b(10'd0),
        .cfg_awb_gain_r(16'd16384),.cfg_awb_gain_g(16'd16384),.cfg_awb_gain_b(16'd16384),
        .cfg_ccm_rr(16'sd8192),.cfg_ccm_rg(16'sd0),.cfg_ccm_rb(16'sd0),
        .cfg_ccm_gr(16'sd0),.cfg_ccm_gg(16'sd8192),.cfg_ccm_gb(16'sd0),
        .cfg_ccm_br(16'sd0),.cfg_ccm_bg(16'sd0),.cfg_ccm_bb(16'sd8192),
        .cfg_ccm_offset_r(32'sd0),.cfg_ccm_offset_g(32'sd0),.cfg_ccm_offset_b(32'sd0),
        .gamma_cfg_we(gamma_we),.gamma_cfg_addr(gamma_addr),.gamma_cfg_data(gamma_data),
        .gamma_cfg_ready(gamma_ready),
        .table_request_valid(table_request),.table_request_base(64'h4000),.table_request_index(2'd0),
        .table_response_valid(table_response_valid),.table_axi_arvalid(table_arvalid),
        .table_response_ready(TABLE_INFLIGHT!=2),.table_abort_request(1'b0),
        .table_axi_arready(table_arready),.table_axi_rdata(128'd0),.table_axi_rresp(2'b00),
        .table_axi_rlast(1'b1),.table_axi_rvalid(table_rvalid),.table_axi_rready(table_rready),
        .writer_start(start),.writer_cancel(cancel),.writer_base(base),
        .writer_stride(32'd16),.writer_width(16'd4),.writer_height(16'd5),
        .writer_busy(busy),.writer_done(done),.writer_error(writer_error),
        .writer_axi_awaddr(awaddr),.writer_axi_awlen(awlen),.writer_axi_awsize(awsize),
        .writer_axi_awburst(awburst),.writer_axi_awvalid(av),.writer_axi_awready(ar),
        .writer_axi_wdata(wd),.writer_axi_wstrb(ws),.writer_axi_wlast(wl),
        .writer_axi_wvalid(wv),.writer_axi_wready(wr),
        .writer_axi_bresp(2'b00),.writer_axi_bvalid(bv),.writer_axi_bready(br)
    );

    assign ar=!aw_saved && (release_bus || STALL!=0) && cycles%5!=1;
    assign wr=!w_saved && (release_bus || STALL!=1) && cycles%7!=2;
    assign bv=aw_saved && w_saved && (release_bus || STALL!=2);
    c1_rv_hold_checker #(.WIDTH(45),.CHANNEL(90)) aw_check (
        .clk(clk),.rst(rst),.cancel(1'b0),.valid(av),.ready(ar),
        .payload({awaddr,awlen,awsize,awburst}));
    c1_rv_hold_checker #(.WIDTH(145),.CHANNEL(91)) w_check (
        .clk(clk),.rst(rst),.cancel(1'b0),.valid(wv),.ready(wr),.payload({wd,ws,wl}));

    always @(posedge clk) if(!rst) begin
        cycles<=cycles+1;
        if(done) dones<=dones+1;
        if(ingress) ingresses<=ingresses+1;
        if(av && ar) begin
            if(awlen!=0 || awsize!=4 || awburst!=1 ||
               awaddr!==(aws==0 ? 32'h1000 : 32'h2000+16*(aws-1)))
                $fatal(1,"capture drain AW shape/address mismatch index=%0d",aws);
            saved_addr<=awaddr;aw_saved<=1;aws<=aws+1;
        end
        if(wv && wr) begin
            if(ws!==16'hffff || !wl) $fatal(1,"capture drain W shape mismatch");
            saved_data<=wd;w_saved<=1;wsent<=wsent+1;
        end
        if(bv && br) begin
            if(saved_addr>=32'h2000) good_memory[(saved_addr-32'h2000)/16]<=saved_data;
            aw_saved<=0;w_saved<=0;bs<=bs+1;
        end
    end

    task automatic send_frame(input integer tone,input bit bad);
        for(integer p=0;p<42;p++) begin
            @(negedge camera_clk);
            if(bad && p==30) begin
                cv=0;
                while(!release_source) @(negedge camera_clk);
            end
            cv=1;cx=COORD_BITS'(p%6);cy=COORD_BITS'(p/6);
            raw=10'(tone+(p/6)*37+(p%6)*11);
            cs=p==0;cl=p%6==5;ce=p==41;
            if(bad && p==30) begin
                if(FAULT_AXIS==0) cx=cx ^ COORD_BITS'(1<<(COORD_BITS-1));
                else cy=cy ^ COORD_BITS'(1<<(COORD_BITS-1));
            end
            @(posedge camera_clk);
            while(!cr) @(posedge camera_clk);
        end
        @(negedge camera_clk);cv=0;cs=0;cl=0;ce=0;
    endtask

    task automatic launch;
        wait(begin_ready);
        @(negedge clk);start=1;begin_frame=1;
        @(negedge clk);start=0;begin_frame=0;
    endtask

    initial begin
        repeat(8) @(negedge clk);rst=0;
        for(integer k=0;k<1024;k++) begin
            @(negedge clk);gamma_we=1;gamma_addr=10'(k);gamma_data=8'(k>>2);
            @(posedge clk);if(!gamma_ready) $fatal(1,"Gamma write not accepted");
        end
        @(negedge clk);gamma_we=0;commit=1;
        @(negedge clk);commit=0;
        fork
            begin
                send_frame(128,1);
                if(EXPLICIT_RECOVERY) begin
                    source_stopped=1;
                    wait(recovery_done);
                    @(negedge camera_clk);source_stopped=0;
                end
                send_frame(256,0);
            end
            begin
                launch();
                // First row has already crossed the real ISP/writer seam.
                if(STALL==0) wait(av && wsent==1);
                else if(STALL==1) wait(wv && aws==1);
                else wait(aws==1 && wsent==1 && br);
                if(TABLE_INFLIGHT) begin
                    @(negedge clk);table_request=1;
                    @(negedge clk);table_request=0;
                    wait(table_arvalid);
                    if(TABLE_INFLIGHT==2) begin
                        @(negedge clk);table_arready=1;
                        @(posedge clk);
                        @(negedge clk);table_arready=0;table_rvalid=1;
                        @(posedge clk);while(!table_rready) @(posedge clk);
                        @(negedge clk);table_rvalid=0;
                        wait(table_response_valid);
                        repeat(8) begin
                            @(negedge clk);
                            if(!table_response_valid)
                                $fatal(1,"table response did not remain pending before recovery");
                        end
                    end
                end
                @(negedge camera_clk);release_source=1;
                wait(cap_error);
                @(negedge clk);
                if(EXPLICIT_RECOVERY) recovery_request=1;
                else cancel=1;
                if(cap_code!==8'h05) $fatal(1,"RAW error did not reach subsystem");
                repeat(24) begin
                    @(negedge clk);
                    if(EXPLICIT_RECOVERY && (!recovery_busy || recovery_done ||
                       dut.u_frontend.recovery_core_reset || dut.u_frontend.recovery_camera_reset ||
                       begin_ready || dut.table_request_ready))
                        $fatal(1,"explicit recovery reset/admission preceded writer drain");
                    if(!busy || done || dones!=0 || bs!=0 || ingresses!=0)
                        $fatal(1,"writer released committed transaction before B");
                end
                release_bus=1;
                if(TABLE_INFLIGHT==1) begin
                    wait(!busy);
                    repeat(12) begin
                        @(negedge clk);
                        if(!recovery_busy || !table_arvalid || recovery_done ||
                           dut.u_frontend.recovery_core_reset)
                            $fatal(1,"recovery retracted stalled table AR or reset before drain");
                    end
                    table_arready=1;
                    @(posedge clk);
                    @(negedge clk);table_arready=0;
                    repeat(12) begin
                        @(negedge clk);
                        if(!recovery_busy || recovery_done || dut.u_frontend.recovery_core_reset)
                            $fatal(1,"recovery completed before committed table R");
                    end
                    table_rvalid=1;
                    @(posedge clk);while(!table_rready) @(posedge clk);
                    @(negedge clk);table_rvalid=0;
                    if(table_response_valid) $fatal(1,"cancelled table response leaked");
                end
                wait(dones==1 && !busy && !cleanup);
            end
        join
        @(negedge clk);
        if(aws!=1 || wsent!=1 || bs!=1 || overflow || writer_error || ingresses!=0 || table_response_valid)
            $fatal(1,"cancelled frame transaction counts mismatch");
        cancel=0;clear_error=1;base=32'h2000;
        @(negedge clk);clear_error=0;
        launch();
        wait(dones==2 && !busy);
        repeat(10) @(negedge clk);
        if(aws!=6 || wsent!=6 || bs!=6 || ingresses!=1 || cap_error || writer_error)
            $fatal(1,"recovered frame completion/count mismatch");
        for(integer y=0;y<5;y++) for(integer x=0;x<4;x++) begin
            logic [7:0] gray;
            gray=8'((256+(y+1)*37+(x+1)*11)>>2);
            if(good_memory[y][x*32+:32]!=={8'd0,gray,gray,gray})
                $fatal(1,"recovered DDR pixel mismatch y=%0d x=%0d",y,x);
        end
        if(EXPLICIT_RECOVERY) begin
            if(cancel || recovery_ready || recovery_busy || recovery_done)
                $fatal(1,"held explicit recovery repeated or required external cancel");
            $display("C1_CAPTURE_SUBSYSTEM_RECOVERY_PASS stall=%0d half=%0d table_inflight=%0d table_fifo=%0d auto_cancel=1 premature_safe_blocked=1 pixels=20",STALL,CAMERA_HALF,TABLE_INFLIGHT,TABLE_FIFO);
        end
        $display("C1_CAPTURE_RASTER_WRITER_DRAIN_PASS stall=%0d camera_half=%0d coord_bits=%0d axis=%0d aw=6 w=6 b=6 checked_pixels=20",STALL,CAMERA_HALF,COORD_BITS,FAULT_AXIS);
        $finish;
    end
    initial begin #200000; $fatal(1,"capture raster writer drain timeout");end
endmodule
