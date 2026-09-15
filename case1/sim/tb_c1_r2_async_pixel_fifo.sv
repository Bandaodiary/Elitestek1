`timescale 1ns/1ps
module tb_c1_r2_async_pixel_fifo;
    parameter integer DEPTH=32,WH=7,RH=5;
    localparam N=DEPTH*3+137;
    reg wr_clk=0,rd_clk=0;always #(WH)wr_clk=~wr_clk;initial begin #2;forever #(RH)rd_clk=~rd_clk;end
    reg wr_rst=1,rd_rst=1,in_valid=0,out_ready=0;
    reg [31:0] in_data;
    wire in_ready,out_valid,rd_empty;wire [31:0] out_data;wire [$clog2(DEPTH):0] wr_level;
    c1_r2_async_pixel_fifo #(.DATA_WIDTH(32),.DEPTH(DEPTH)) dut(.*);
    integer pushed=0,popped=0,epoch=0,wr_cycles=0,rd_cycles=0,held=0,fulls=0,total=0;
    reg run=0,drain=0,was_held=0;reg [31:0] held_data;
    function automatic [31:0] value(input integer i,e);value=(i*32'h1f034c71)^32'h8123a456^(e*32'h35a0c749);endfunction
    always @(negedge wr_clk)begin
        wr_cycles=wr_cycles+1;in_valid=run && pushed<N && wr_cycles%7!=0;
        in_data=value(pushed,epoch);
    end
    always @(negedge rd_clk)begin
        rd_cycles=rd_cycles+1;out_ready=run && drain && rd_cycles%5!=0 && rd_cycles%11!=0;
    end
    always @(posedge wr_clk)if(!wr_rst)begin
        if(in_valid && in_ready)pushed=pushed+1;
        if(in_valid && !in_ready)fulls=fulls+1;
    end
    always @(posedge rd_clk)begin
        if(rd_rst)was_held=0;
        else begin
            if(was_held && (!out_valid || out_data!==held_data))$fatal(1,"FIFO held output changed");
            was_held=out_valid && !out_ready;held_data=out_data;
            if(was_held)held=held+1;
            if(out_valid && out_ready)begin
                if(popped>=pushed || out_data!==value(popped,epoch))$fatal(1,"FIFO data/order failure epoch=%0d word=%0d",epoch,popped);
                popped=popped+1;
            end
        end
    end
    initial begin
        for(epoch=0;epoch<3;epoch=epoch+1)begin
            wr_rst=1;rd_rst=1;run=0;drain=0;
            repeat(8)@(negedge wr_clk);repeat(8)@(negedge rd_clk);
            pushed=0;popped=0;wr_rst=0;repeat(3)@(negedge rd_clk);rd_rst=0;run=1;
            repeat(DEPTH*3+24)@(negedge wr_clk);
            if(pushed!=DEPTH+1 || in_ready || !out_valid)$fatal(1,"FIFO effective capacity wrong got=%0d depth=%0d",pushed,DEPTH);
            drain=1;wait(popped==N);repeat(8)@(negedge rd_clk);
            if(!rd_empty || out_valid || pushed!=popped)$fatal(1,"FIFO final drain mismatch");
            total=total+popped;run=0;
        end
        if(held==0 || fulls==0)$fatal(1,"FIFO no stalls/full coverage");
        $display("C1_R2_ASYNC_PIXEL_FIFO_PASS depth=%0d wh=%0d rh=%0d words=%0d epochs=3 held=%0d full_cycles=%0d capacity=%0d",DEPTH,WH,RH,total,held,fulls,DEPTH+1);
        $finish;
    end
    initial begin #100000000;$fatal(1,"FIFO timeout");end
endmodule
