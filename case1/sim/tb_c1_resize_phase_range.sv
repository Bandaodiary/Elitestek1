`timescale 1ns/1ps
module tb_c1_resize_phase_range;
    logic clk=0,rst=1,start=0,ready=0;
    always #5 clk=~clk;
    logic [15:0] wi=8,hi=7,wo=1,ho=1;
    logic signed [31:0] sx=0,sy=0,px=0,py=0;
    wire busy,done,valid,last,start_ready;
    wire [15:0] ox,oy,x0,x1,y0,y1;
    wire [12:0] wx0,wx1,wy0,wy1;
    r1_resize_request_q16 dut(.clk(clk),.rst(rst),.start(start),.start_ready(start_ready),
        .cfg_win(wi),.cfg_hin(hi),.cfg_wout(wo),.cfg_hout(ho),
        .cfg_x_step_q16(sx),.cfg_y_step_q16(sy),.cfg_x_phase0_q16(px),.cfg_y_phase0_q16(py),
        .busy(busy),.done(done),.req_valid(valid),.req_ready(ready),.req_last(last),
        .req_out_x(ox),.req_out_y(oy),.req_x0(x0),.req_x1(x1),.req_y0(y0),.req_y1(y1),
        .req_wx0(wx0),.req_wx1(wx1),.req_wy0(wy0),.req_wy1(wy1));
    function automatic integer clamp(input longint signed v,input integer limit);
        if(v<0) clamp=0; else if(v>=limit) clamp=limit-1; else clamp=v;
    endfunction
    task automatic run_case(input integer w,h,input logic signed[31:0] xs,ys,xp,yp);
        longint signed ax,ay;
        integer n,tick,ex,ey,fx,fy;
        logic [148:0] held;
        logic stalled;
        begin
            @(negedge clk); wo=w; ho=h; sx=xs; sy=ys; px=xp; py=yp; start=1; ready=0;
            @(negedge clk); start=0;
            n=0; tick=0; stalled=0;
            while(n<w*h) begin
                ready=(tick%5)!=2 && (tick%5)!=3;
                @(posedge clk);
                if(!valid) $fatal(1,"missing resize request");
                if(stalled && {ox,oy,x0,x1,y0,y1,wx0,wx1,wy0,wy1,last}!==held)
                    $fatal(1,"resize request changed under backpressure");
                ex=n%w; ey=n/w;
                ax=$signed(xp)+longint'(ex)*$signed(xs);
                ay=$signed(yp)+longint'(ey)*$signed(ys);
                fx=((ax & 65535)+8)>>4; fy=((ay & 65535)+8)>>4;
                if(ox!==ex || oy!==ey || x0!==clamp(ax>>>16,wi) ||
                   x1!==clamp((ax>>>16)+1,wi) || y0!==clamp(ay>>>16,hi) ||
                   y1!==clamp((ay>>>16)+1,hi) || wx1!==fx || wy1!==fy ||
                   wx0!==4096-fx || wy0!==4096-fy || last!==(n==w*h-1))
                    $fatal(1,"resize phase mismatch n=%0d phase=%0d/%0d coords=%0d/%0d/%0d/%0d",n,ax,ay,x0,x1,y0,y1);
                held={ox,oy,x0,x1,y0,y1,wx0,wx1,wy0,wy1,last};
                stalled=!ready;
                if(ready) n=n+1;
                tick=tick+1;
                @(negedge clk);
            end
            if(busy!==0 || done!==1) $fatal(1,"resize completion mismatch");
            ready=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        run_case(4,3,32'sh7fffffff,32'sh7fffffff,32'sh7fffffff,32'sh7fffffff);
        run_case(4,3,32'sh80000000,32'sh80000000,32'sh80000000,32'sh80000000);
        run_case(65535,1,32'sh7fffffff,0,32'sh7fffffff,0);
        run_case(65535,1,32'sh80000000,0,32'sh80000000,0);
        run_case(1,65535,0,32'sh7fffffff,0,32'sh7fffffff);
        run_case(1,65535,0,32'sh80000000,0,32'sh80000000);
        run_case(13,9,32'sh18000,32'sh0aaaa,-32'sh8000,-32'sh5555);
        run_case(13,9,-32'sh08000,32'sh14000,32'sh50000,-32'sh8000);
        $display("C1_RESIZE_PHASE_RANGE_PASS cases=8 max_axis=65535"); $finish;
    end
    initial begin #10000000; $fatal(1,"resize range test timeout"); end
endmodule
