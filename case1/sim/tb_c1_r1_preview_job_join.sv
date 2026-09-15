`timescale 1ns/1ps
// Real job controller + runtime join + preview DMA. Only compute completion
// and unrelated preflight/runtime clients are behavioral, not a full CNN SoC.
module tb_c1_r1_preview_job_join #(parameter bit USE_RUNTIME=0);
    logic clk=0,rst=1; always #5 clk=~clk;
    logic start_valid=0,start_ready,abort=0;
    logic [31:0] cycle_budget=0;
    wire busy,job_done,job_error,job_aborted;
    wire [7:0] error_code;wire [31:0] error_address;
    wire pair_start_valid,config_start_valid;
    wire engine_start,engine_abort_pulse,engine_ready,engine_busy,engine_done,engine_error;
    wire [7:0] engine_error_code;wire [31:0] engine_error_address;
    wire child_start,cancel;
    logic other_done=0,compute_busy=0,compute_done=0,compute_error=0;
    logic finish_compute=0,fail_compute=0;
    logic allow_compute_start=1,allow_preview_start=1;
    wire preview_ready,preview_busy,preview_done,preview_error,preview_aborted;
    wire in_ready,cnn_valid;wire [63:0] cnn_data_s8;
    wire [15:0] cnn_x,cnn_y;wire cnn_sof,cnn_eol,cnn_eof;
    wire [31:0] awaddr;wire [7:0] awlen;wire [2:0] awsize;wire [1:0] awburst;
    wire awvalid,wlast,wvalid,bready;wire [127:0] wdata;wire [15:0] wstrb;
    logic permit_b=0;logic [1:0] bresp=0;
    logic [31:0] preview_config_base=32'h1000;
    wire bvalid;
    integer sent=0,received=0,aws=0,beats=0,bs=0,mode=0;
    integer done_count=0,error_count=0,abort_count=0,launch_count=0;
    integer terminal_before=0,expected_kind=0;
    integer done_fault_collision=0,both_fault_collision=0,cancel_done_collision=0;
    logic [7:0] expected_code=0;
    logic [31:0] expected_address=0;
    assign cancel=abort||engine_abort_pulse;
    assign bvalid=permit_b && aws==1 && beats==2 && bs==0;
    c1_r1_job_controller u_controller (
        .clk(clk),.rst(rst),.start_valid(start_valid),.start_ready(start_ready),
        .cycle_budget(cycle_budget),.abort(abort),.busy(busy),
        .job_done(job_done),.job_error(job_error),.job_aborted(job_aborted),
        .error_code(error_code),.error_address(error_address),
        .pair_start_valid(pair_start_valid),.pair_start_ready(1'b1),
        .pair_response_valid(pair_start_valid),.pair_response_ready(),
        .pair_response_error(1'b0),.pair_response_error_code(8'd0),
        .pair_response_error_address(32'd0),.pair_busy(1'b0),.pair_abort_pulse(),
        .config_start_valid(config_start_valid),.config_start_ready(1'b1),
        .config_response_valid(config_start_valid),.config_response_ready(),
        .config_response_error(1'b0),.config_response_error_code(8'd0),
        .config_response_error_address(32'd0),.config_busy(1'b0),.config_abort_pulse(),
        .input_dma_ready(1'b1),.input_dma_start(),.input_dma_busy(1'b0),
        .input_dma_done(other_done),.input_dma_error(1'b0),
        .input_dma_error_code(8'd0),.input_dma_error_address(32'd0),
        .output_dma_ready(1'b1),.output_dma_start(),.output_dma_busy(1'b0),
        .output_dma_done(other_done),.output_dma_error(1'b0),
        .output_dma_error_code(8'd0),.output_dma_error_address(32'd0),
        .descriptor_busy(1'b0),.descriptor_done(other_done),.descriptor_error(1'b0),
        .descriptor_error_code(8'd0),.descriptor_error_address(32'd0),.descriptor_abort_pulse(),
        .engine_ready(engine_ready),.engine_start(engine_start),.engine_busy(engine_busy),
        .engine_done(engine_done),.engine_error(engine_error),
        .engine_error_code(engine_error_code),.engine_error_address(engine_error_address),
        .engine_abort_pulse(engine_abort_pulse)
    );
    generate if(!USE_RUNTIME) begin: g_legacy
    c1_r1_runtime_join u_join (
        .clk(clk),.rst(rst),.start_valid(engine_start),.start_ready(engine_ready),
        .cancel(cancel),.child_start(child_start),
        .left_ready(!compute_busy && allow_compute_start),.right_ready(preview_ready && allow_preview_start),
        .left_busy(compute_busy),.left_done(compute_done),.left_error(compute_error),
        .left_error_code(8'h91),.left_error_address(32'habc0),
        .right_busy(preview_busy),.right_done(preview_done),.right_error(preview_error),
        .right_error_code(8'h63),.right_error_address(32'h1000),
        .busy(engine_busy),.done(engine_done),.error(engine_error),
        .error_code(engine_error_code),.error_address(engine_error_address)
    );
    c1_r1_preview_dma u_preview (
        .clk(clk),.rst(rst),.start_valid(child_start),.start_ready(preview_ready),.cancel(cancel),
        .base_addr(preview_config_base),.stride_bytes(32'd32),.width_pixels(16'd8),.height_lines(16'd1),
        .busy(preview_busy),.done(preview_done),.error(preview_error),.aborted(preview_aborted),
        .in_valid(sent<8),.in_ready(in_ready),.in_data_s8({40'd0,8'(sent+3),8'(sent+2),8'(sent+1)}),
        .in_x(16'(sent)),.in_y(16'd0),.in_sof(sent==0),.in_eol(sent==7),.in_eof(sent==7),
        .cnn_valid(cnn_valid),.cnn_ready(1'b1),.cnn_data_s8(cnn_data_s8),
        .cnn_x(cnn_x),.cnn_y(cnn_y),.cnn_sof(cnn_sof),.cnn_eol(cnn_eol),.cnn_eof(cnn_eof),
        .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid),.m_axi_awready(1'b1),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(1'b1),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready)
    );
    end else begin: g_runtime
        c1_r1_preview_runtime u_runtime (
            .clk(clk),.rst(rst),.start_valid(engine_start),.start_ready(engine_ready),.cancel(cancel),
            .compute_start(child_start),.compute_ready(!compute_busy&&allow_compute_start&&allow_preview_start),
            .compute_busy(compute_busy),.compute_done(compute_done),.compute_error(compute_error),
            .compute_error_code(8'h91),.compute_error_address(32'habc0),
            .base_addr(preview_config_base),.stride_bytes(32'd32),.width_pixels(16'd8),.height_lines(16'd1),
            .busy(engine_busy),.done(engine_done),.error(engine_error),
            .error_code(engine_error_code),.error_address(engine_error_address),
            .preview_ready(preview_ready),.preview_busy(preview_busy),.preview_done(preview_done),
            .preview_error(preview_error),.preview_aborted(preview_aborted),
            .in_valid(sent<8),.in_ready(in_ready),.in_data_s8({40'd0,8'(sent+3),8'(sent+2),8'(sent+1)}),
            .in_x(16'(sent)),.in_y(16'd0),.in_sof(sent==0),.in_eol(sent==7),.in_eof(sent==7),
            .cnn_valid(cnn_valid),.cnn_ready(1'b1),.cnn_data_s8(cnn_data_s8),
            .cnn_x(cnn_x),.cnn_y(cnn_y),.cnn_sof(cnn_sof),.cnn_eol(cnn_eol),.cnn_eof(cnn_eof),
            .m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),
            .m_axi_awvalid(awvalid),.m_axi_awready(1'b1),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),
            .m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(1'b1),
            .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready)
        );
    end endgenerate
    always @(posedge clk) begin
        if(rst) begin other_done<=0;compute_busy<=0;compute_done<=0;compute_error<=0;end
        else begin
            if(engine_start!==child_start) $fatal(1,"non-atomic runtime start");
            other_done<=engine_start;compute_done<=0;compute_error<=0;
            if(child_start) begin
                compute_busy<=1;launch_count<=launch_count+1;
                preview_config_base<=32'hbad00000;
            end
            else if(cancel) compute_busy<=0;
            else if(compute_busy) begin
                if(finish_compute) begin compute_busy<=0;compute_done<=1;end
                if(fail_compute) compute_error<=1;
            end
            if(sent<8 && in_ready) sent<=sent+1;
            if(cnn_valid) begin
                if(cnn_x!==16'(received) || cnn_y!==0 ||
                   cnn_data_s8!=={40'd0,8'(received+3),8'(received+2),8'(received+1)})
                    $fatal(1,"CNN input mismatch");
                received<=received+1;
            end
            if(awvalid) begin
                if(aws!=0 || awaddr!==32'h1000 || awlen!==1 || awsize!==4 || awburst!==1)
                    $fatal(1,"unexpected AW");
                aws<=aws+1;
            end
            if(wvalid) begin
                if(beats>=2 || wstrb!==16'hffff || wlast!==(beats==1)) $fatal(1,"unexpected W framing");
                for(integer n=0;n<4;n++)
                    if(wdata[n*32+:32]!=={8'd0,8'((beats*4+n+1)^128),8'((beats*4+n+2)^128),8'((beats*4+n+3)^128)})
                        $fatal(1,"preview XRGB mismatch");
                beats<=beats+1;
            end
            if(bvalid&&bready) bs<=bs+1;
            if(engine_done && (compute_busy || preview_busy || cancel)) $fatal(1,"early joint done");
            if(mode==7 && compute_done && preview_error) begin
                done_fault_collision<=done_fault_collision+1;
                if(engine_done || !engine_error || engine_error_code!==8'h63)
                    $fatal(1,"preview error lost against compute done");
            end
            if(mode==8 && compute_error && preview_error) begin
                both_fault_collision<=both_fault_collision+1;
                if(engine_done || !engine_error || engine_error_code!==8'h91 || engine_error_address!==32'habc0)
                    $fatal(1,"simultaneous error priority changed");
            end
            if(mode==9 && cancel && compute_done && !compute_busy && !preview_busy) begin
                cancel_done_collision<=cancel_done_collision+1;
                if(engine_done) $fatal(1,"cancel lost to joint completion");
            end
            if(job_done||job_error||job_aborted) begin
                if(engine_busy || compute_busy || preview_busy || bs!=1)
                    $fatal(1,"job retired before preview B mode=%0d",mode);
                if(job_done!==(expected_kind==0) || job_error!==(expected_kind==1) || job_aborted!==(expected_kind==2))
                    $fatal(1,"wrong job terminal mode=%0d",mode);
                if(job_error && (error_code!==expected_code || error_address!==expected_address))
                    $fatal(1,"wrong error code/address mode=%0d code=%h address=%h",mode,error_code,error_address);
                if(job_done) done_count<=done_count+1;
                if(job_error) error_count<=error_count+1;
                if(job_aborted) abort_count<=abort_count+1;
            end
        end
    end
    task automatic complete_compute;
        finish_compute=1;@(negedge clk);finish_compute=0;
    endtask
    task automatic hold_pending;
        repeat(10) begin
            @(negedge clk);
            if(!busy || job_done || job_error || job_aborted || engine_done)
                $fatal(1,"premature job completion mode=%0d",mode);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(mode=0;mode<10;mode++) begin
            wait(start_ready);@(negedge clk);
            sent=0;received=0;aws=0;beats=0;bs=0;permit_b=0;bresp=0;
            preview_config_base=32'h1000;
            terminal_before=done_count+error_count+abort_count;
            expected_kind=((mode==3 || mode==9) ? 2 : ((mode==2 || mode==4 || mode==5 || mode==7 || mode==8) ? 1 : 0));
            expected_code=(mode==2 ? 8'hf0 : ((mode==4 || mode==7) ? 8'h63 : 8'h91));
            expected_address=(mode==2 ? 32'd64 : ((mode==4 || mode==7) ? 32'h1000 : 32'habc0));
            cycle_budget=(mode==2 ? 64 : 0);
            allow_compute_start=(mode!=0);allow_preview_start=(mode!=0);
            start_valid=1;@(negedge clk);start_valid=0;
            if(mode==0) begin
                repeat(10) begin
                    @(negedge clk);
                    if(child_start || launch_count!=0 || sent!=0 || aws!=0 || beats!=0)
                        $fatal(1,"launch before both participants ready");
                end
                allow_compute_start=1;
                repeat(6) begin
                    @(negedge clk);
                    if(child_start || launch_count!=0 || sent!=0 || aws!=0 || beats!=0)
                        $fatal(1,"launch while preview not ready");
                end
                allow_preview_start=1;
            end
            wait(beats==2 && aws==1);@(negedge clk);
            case(mode)
                0,6: begin complete_compute();hold_pending();permit_b=1;end
                1: begin
                    permit_b=1;wait(preview_done);@(negedge clk);
                    hold_pending();complete_compute();
                end
                2: begin
                    complete_compute();wait(engine_abort_pulse);@(negedge clk);
                    if(error_code!==8'hf0) $fatal(1,"watchdog not active while waiting for preview");
                    hold_pending();permit_b=1;
                end
                3: begin
                    complete_compute();abort=1;@(negedge clk);abort=0;
                    hold_pending();permit_b=1;
                end
                4: begin bresp=2;permit_b=1;end
                5: begin
                    fail_compute=1;@(negedge clk);fail_compute=0;
                    wait(engine_abort_pulse);@(negedge clk);hold_pending();permit_b=1;
                end
                7: begin // Compute DONE and real bad B are generated on one edge.
                    bresp=2;permit_b=1;complete_compute();
                end
                8: begin // Both participants report their first error together.
                    bresp=2;permit_b=1;fail_compute=1;
                    @(negedge clk);fail_compute=0;
                end
                9: begin // Preview already done; cancel overlaps compute DONE.
                    permit_b=1;wait(preview_done);@(negedge clk);
                    complete_compute();abort=1;@(negedge clk);abort=0;
                end
            endcase
            wait(done_count+error_count+abort_count>terminal_before);
            repeat(4) @(negedge clk);
            if(done_count+error_count+abort_count!=terminal_before+1) $fatal(1,"duplicate job terminal");
            if(sent!=8 || received!=8) $fatal(1,"lost preview/CNN pixels");
        end
        if(done_count!=3 || error_count!=5 || abort_count!=2 || launch_count!=10) $fatal(1,"coverage counts");
        if(done_fault_collision==0 || both_fault_collision==0 || cancel_done_collision==0)
            $fatal(1,"missing actual joint completion collision coverage");
        $display("C1_PREVIEW_JOIN_COLLISION_PASS done_fault=%0d both_fault=%0d cancel_done=%0d",done_fault_collision,both_fault_collision,cancel_done_collision);
        $display("C1_PREVIEW_JOB_JOIN_PASS jobs=10 success=3 error=5 abort=2 watchdog=1 late_B=5 no_reset=1 pixels=80 ready_barrier=16");
        if(USE_RUNTIME) $display("C1_PREVIEW_RUNTIME_PASS real_wrapper=1 controller=1 jobs=10 collisions=3");
        $finish;
    end
    initial begin #200000;$fatal(1,"preview job join timeout mode=%0d",mode);end
endmodule
