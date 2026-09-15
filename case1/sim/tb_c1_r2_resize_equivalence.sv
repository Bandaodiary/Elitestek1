`timescale 1ns/1ps
// Actual old/new pipelines driven in lockstep, plus independent Python pixels.
// The source honors ready; this does not model a non-backpressurable camera.
module tb_c1_r2_resize_equivalence;
    reg clk=0,rst=1,start=0,iv=0,oready=0;
    always #5 clk=~clk;
    reg [15:0] win,hin,wout,hout,ix=0,iy=0;
    reg signed [31:0] xs,ys,xp,yp;
    reg [23:0] source[0:2211839],golden[0:307199];
    wire [1:0] ready,cr,ce,ov,busy,done,err,aborted;
    wire [47:0] rgb;
    wire [31:0] ox,oy;
    wire [1:0] sof,eol,eof;
    wire [7:0] ec;
    integer W,H,OW,OH,STALLS,negative,si=0,oi=0,cycles=0,start_cycle=0,source_stall=0,out_stall=0,max_source_pause=0,pause_now=0;
    reg [31:0] random_state=32'h96173fab;
    wire isof=ix==0 && iy==0;
    wire ieol=ix==win-1;
    wire ieof=ieol && iy==hin-1;
    wire [23:0] pixel=source[si];
    for(genvar b=0;b<2;b=b+1)begin : g_pipeline
        if(b==0)begin : g_old
            c1_r1_resize_pipeline #(.MAX_WIDTH(2048),.REGISTER_ABORT_RESET(1)) dut (
                .clk(clk),.rst(rst),.cfg_valid(start),.cfg_ready(cr[b]),.cfg_error(ce[b]),
                .cfg_win(win),.cfg_hin(hin),.cfg_wout(wout),.cfg_hout(hout),
                .cfg_x_step_q16(xs),.cfg_y_step_q16(ys),.cfg_x_phase0_q16(xp),.cfg_y_phase0_q16(yp),
                .abort(1'b0),.aborted(aborted[b]),.busy(busy[b]),.done(done[b]),.error(err[b]),.error_code(ec[b*4+:4]),
                .in_valid(iv),.in_ready(ready[b]),.in_x(ix),.in_y(iy),.in_sof(isof),.in_eol(ieol),.in_eof(ieof),.in_rgb888(pixel),
                .out_valid(ov[b]),.out_ready(oready),.out_sof(sof[b]),.out_eol(eol[b]),.out_eof(eof[b]),
                .out_x(ox[b*16+:16]),.out_y(oy[b*16+:16]),.out_rgb888(rgb[b*24+:24])
            );
        end else begin : g_new
            c1_r2_resize_pipeline #(.MAX_WIDTH(2048),.REGISTER_ABORT_RESET(1)) dut (
                .clk(clk),.rst(rst),.cfg_valid(start),.cfg_ready(cr[b]),.cfg_error(ce[b]),
                .cfg_win(win),.cfg_hin(hin),.cfg_wout(wout),.cfg_hout(hout),
                .cfg_x_step_q16(xs),.cfg_y_step_q16(ys),.cfg_x_phase0_q16(xp),.cfg_y_phase0_q16(yp),
                .abort(1'b0),.aborted(aborted[b]),.busy(busy[b]),.done(done[b]),.error(err[b]),.error_code(ec[b*4+:4]),
                .in_valid(iv),.in_ready(ready[b]),.in_x(ix),.in_y(iy),.in_sof(isof),.in_eol(ieol),.in_eof(ieof),.in_rgb888(pixel),
                .out_valid(ov[b]),.out_ready(oready),.out_sof(sof[b]),.out_eol(eol[b]),.out_eof(eof[b]),
                .out_x(ox[b*16+:16]),.out_y(oy[b*16+:16]),.out_rgb888(rgb[b*24+:24])
            );
        end
    end
    always @(negedge clk)if(!rst && !start)begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        oready=STALLS==0 || random_state[2:0]!=0;
        if(!iv)iv=si<W*H && (STALLS==0 || random_state[5:3]!=0);
    end
    always @(posedge clk)begin
        cycles=cycles+1;
        if(cycles>20000000)$fatal(1,"resize miter timeout");
        if(!rst)begin
            if(ready[0]!==ready[1] || cr[0]!==cr[1] || ov[0]!==ov[1] ||
               busy[0]!==busy[1] || done[0]!==done[1] || err!==0 || ce!==0 || aborted!==0)
                $fatal(1,"resize interface/cycle equivalence failed cycle=%0d",cycles);
            if(ov[0] && {rgb[23:0],ox[15:0],oy[15:0],sof[0],eol[0],eof[0]} !==
                         {rgb[47:24],ox[31:16],oy[31:16],sof[1],eol[1],eof[1]})
                $fatal(1,"resize old/new pixel mismatch");
            if(iv && !ready[1])begin
                source_stall=source_stall+1;pause_now=pause_now+1;
                if(pause_now>max_source_pause)max_source_pause=pause_now;
            end else pause_now=0;
            if(ov[1] && !oready)out_stall=out_stall+1;
            if(iv && ready[1])begin
                si<=si+1;iv<=0;
                if(ix==win-1)begin ix<=0;iy<=iy+1;end else ix<=ix+1;
            end
            if(ov[1] && oready)begin
                if(oi>=OW*OH || rgb[47:24]!==golden[oi] || ox[31:16]!==oi%OW || oy[31:16]!==oi/OW ||
                   sof[1]!== (oi==0) || eol[1]!== (oi%OW==OW-1) || eof[1]!== (oi==OW*OH-1))
                    $fatal(1,"resize independent golden mismatch pixel=%0d",oi);
                oi=oi+1;
            end
            if(done[1])begin
                if(si!=W*H || oi!=OW*OH || busy[1])$fatal(1,"resize finished before source/output drain");
                $display("C1_R2_RESIZE_EQUIVALENCE_PASS width=%0d height=%0d out_width=%0d out_height=%0d stalls=%0d inputs=%0d outputs=%0d cycles=%0d source_stalls=%0d max_source_pause=%0d output_stalls=%0d cycle_exact=1 independent_golden=1 camera_backpressure_allowed=1",W,H,OW,OH,STALLS,si,oi,cycles-start_cycle,source_stall,max_source_pause,out_stall);
                $finish;
            end
        end
    end
    initial begin
        if(!$value$plusargs("W=%d",W) || !$value$plusargs("H=%d",H) || !$value$plusargs("OW=%d",OW) || !$value$plusargs("OH=%d",OH) ||
           !$value$plusargs("XS=%d",xs) || !$value$plusargs("YS=%d",ys) || !$value$plusargs("XP=%d",xp) || !$value$plusargs("YP=%d",yp) || !$value$plusargs("STALLS=%d",STALLS))
            $fatal(1,"missing resize dimensions");
        if(W*H>2211840 || OW*OH>307200)$fatal(1,"resize fixture capacity");
        win=W;hin=H;wout=OW;hout=OH;
        $readmemh("source.hex",source,0,W*H-1);$readmemh("golden.hex",golden,0,OW*OH-1);
        if($value$plusargs("NEGATIVE=%d",negative) && negative)golden[OW*OH/2]=golden[OW*OH/2]^1;
        repeat(5)@(negedge clk);rst=0;
        while(cr!==2'b11)@(negedge clk);
        start=1;start_cycle=cycles;
        @(negedge clk);start=0;
    end
endmodule
