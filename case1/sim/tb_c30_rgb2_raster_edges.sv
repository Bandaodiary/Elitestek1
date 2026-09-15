`timescale 1ns/1ps
// Cycle-by-cycle external oracle; no DUT internals, images or vendor models.
module tb_c30_rgb2_raster_edges;
    parameter integer SW=6,SH=3,POLARITY=1;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,in_vs=POLARITY ? 0:1,in_de=0,in_valid=0;
    reg [47:0] in_rgb=0;
    wire pair_valid,pair_sof,pair_eol,pair_eof,pair_error;
    wire [47:0] pair_rgb;
    c1_r2_rgb2_raster_source #(.SOURCE_WIDTH(SW),.SOURCE_HEIGHT(SH),.VS_ACTIVE_HIGH(POLARITY)) dut(.*);
    integer checks=0,frames=0,errors=0,pairs=0;
    // ev[4:0]={valid,sof,eol,eof,error}. 'sync' is logical, not electrical polarity.
    task tick(input bit sync,de,v,input [47:0] rgb,input [4:0] ev,input [47:0] ergb);
        begin
            @(negedge clk);in_vs=POLARITY ? sync : !sync;in_de=de;in_valid=v;in_rgb=rgb;
            @(posedge clk);#0.1;checks=checks+1;
            if({pair_valid,pair_sof,pair_eol,pair_eof,pair_error}!==ev)
                $fatal(1,"raster flags sw=%0d sh=%0d polarity=%0d check=%0d actual=%b expected=%b",SW,SH,POLARITY,checks,{pair_valid,pair_sof,pair_eol,pair_eof,pair_error},ev);
            if(ev[4] && pair_rgb!==ergb)$fatal(1,"raster payload mismatch");
            if(pair_valid)pairs=pairs+1;
            if(pair_eof)frames=frames+1;
            if(pair_error)errors=errors+1;
        end
    endtask
    function automatic [47:0] data_at(input integer x,y);
        data_at={24'(32'hA08040+y*SW+x*2+1),24'(32'h123456+y*SW+x*2)};
    endfunction
    task arm;
        begin tick(1,0,0,0,0,0);tick(1,0,0,0,0,0);tick(0,0,0,0,0,0);end
    endtask
    task body;
        integer x,y;reg final_pair;reg [4:0] flags;
        begin
            for(y=0;y<SH;y=y+1)begin
                for(x=0;x<SW/2;x=x+1)begin
                    final_pair=(x==SW/2-1 && y==SH-1);
                    flags=final_pair ? 0 : {1'b1,(x==0 && y==0),(x==SW/2-1),2'b00};
                    tick(0,1,1,data_at(x,y),flags,data_at(x,y));
                end
                if(y<SH-1)begin tick(0,0,0,0,0,0);tick(0,0,0,0,0,0);end
            end
        end
    endtask
    task good(input bit coincident);
        begin
            arm();body();
            // Withheld final pair must survive arbitrary blanking. In the other
            // mode, last DE fall and next VS assertion share the SAME edge.
            if(!coincident)repeat(7)tick(0,0,0,0,0,0);
            tick(1,0,0,0,{1'b1,(SW==2 && SH==1),3'b110},data_at(SW/2-1,SH-1));
            repeat(3)tick(1,0,0,0,0,0);
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        // Startup in the middle of an active raster is ignored until sync.
        repeat(4)tick(0,1,1,48'h998877665544,0,0);
        tick(0,0,0,0,0,0);
        good(0);good(1);
        // DE and VALID mismatch before first pair; error once, no splicing.
        arm();tick(0,1,0,0,5'b00001,0);
        repeat(4)tick(0,1,1,1,0,0);good(0);
        // Exact complete raster followed by an extra pair must NOT commit EOF.
        arm();body();tick(0,1,1,48'hFF,5'b00001,0);
        tick(0,0,0,0,0,0);good(1);
        // Full raster followed by overlapping active DE and VS is rejected.
        arm();body();tick(1,1,1,0,5'b00001,0);
        tick(1,0,0,0,0,0);good(0);
        // Reset pending final pair; it must never emerge in the next frame.
        arm();body();@(negedge clk);rst=1;
        tick(0,0,0,0,0,0);@(negedge clk);rst=0;
        tick(1,0,0,0,0,0);good(1);
        if(frames!=6 || errors!=3)$fatal(1,"edge test coverage");
        $display("C30_RASTER_EDGES_PASS sw=%0d sh=%0d polarity=%0d frames=%0d errors=%0d pairs=%0d checks=%0d coincident_close=1 startup_partial=1 reset_pending=1",SW,SH,POLARITY,frames,errors,pairs,checks);
        $finish;
    end
endmodule
