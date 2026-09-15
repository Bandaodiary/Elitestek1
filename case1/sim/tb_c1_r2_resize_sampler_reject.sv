`timescale 1ns/1ps
// Exercise the synthesized sampler ERR_REQUEST_PAIR path, not helper assertions.
module tb_c1_r2_resize_sampler_reject;
    reg clk=0,rst=1,start=0,sv=0,req=0;
    always #5 clk=~clk;
    reg [15:0] sx=0,x0=0,x1=1;
    wire start_ready,busy,done,error,src_ready,req_ready,rsp;
    wire [3:0] code;
    wire [23:0] a,b,c,d;
    integer bad,cycles=0,waited,i;
    c1_r2_resize_line_sampler #(.MAX_WIDTH(4)) dut (
        .clk(clk),.rst(rst),.start(start),.start_ready(start_ready),.start_error(),
        .cfg_win(16'd4),.cfg_hin(16'd1),.busy(busy),.done(done),.error(error),.error_code(code),
        .src_valid(sv),.src_ready(src_ready),.src_x(sx),.src_y(16'd0),
        .src_sof(sx==0),.src_eol(sx==3),.src_eof(sx==3),.src_rgb888(24'h523100+sx),
        .sample_req_valid(req),.sample_req_ready(req_ready),.sample_req_last(1'b1),
        .sample_req_out_x(16'd0),.sample_req_out_y(16'd0),
        .sample_req_x0(x0),.sample_req_x1(x1),.sample_req_y0(16'd0),.sample_req_y1(16'd0),
        .sample_req_wx0(13'd2048),.sample_req_wx1(13'd2048),.sample_req_wy0(13'd4096),.sample_req_wy1(13'd0),
        .sample_rsp_valid(rsp),.sample_rsp_ready(1'b0),
        .sample_rsp_rgb_y0x0(a),.sample_rsp_rgb_y0x1(b),.sample_rsp_rgb_y1x0(c),.sample_rsp_rgb_y1x1(d)
    );
    task launch;
        begin
            @(negedge clk);rst=1;req=0;sv=0;start=0;
            repeat(2)@(negedge clk);rst=0;
            @(negedge clk);
            if(!start_ready)$fatal(1,"sampler restart not ready");
            start=1;@(negedge clk);start=0;
        end
    endtask
    initial begin
        for(bad=1;bad<=2;bad=bad+1)begin
            launch();
            x0=bad==1 ? 0 : 2;x1=bad==1 ? 2 : 1;req=1;
            repeat(3)@(negedge clk);
            if(!error || code!=4 || !busy || done || req_ready || rsp || src_ready)
                $fatal(1,"sampler did not reject horizontal pair in hardware");
            // Reset is required by this standalone seam; parent abort resets it.
            launch();x0=bad==1 ? 0 : 3;x1=bad==1 ? 1 : 3;req=1;
            for(i=0;i<4;i=i+1)begin
                sx=i;sv=1;waited=0;
                @(posedge clk);
                while(!src_ready)begin @(posedge clk);waited=waited+1;if(waited>50)$fatal(1,"sampler source timeout");end
                @(negedge clk);sv=0;
            end
            waited=0;
            while(!req_ready)begin @(negedge clk);waited=waited+1;if(waited>50)$fatal(1,"sampler request timeout");end
            @(negedge clk);req=0;
            waited=0;
            while(!rsp)begin @(negedge clk);waited=waited+1;if(waited>50)$fatal(1,"sampler response timeout");end
            if(error || {a,b,c,d}!=={(24'h523100+x0),(24'h523100+x1),(24'h523100+x0),(24'h523100+x1)})
                $fatal(1,"sampler reset recovery pixel mismatch");
        end
        $display("C1_R2_RESIZE_SAMPLER_REJECT_PASS hardware_pair_errors=2 reset_recoveries=2 adjacent_and_clamped=1");
        $finish;
    end
    initial begin repeat(2000)@(posedge clk);$fatal(1,"sampler reject timeout");end
endmodule
