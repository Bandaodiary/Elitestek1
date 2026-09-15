`timescale 1ns/1ps
module tb_c1_r2_video_bram_fifo;
    parameter integer DEPTH=7;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,in_valid=0,out_ready=0;reg [47:0] in_data=0;
    wire in_ready,out_valid;wire [47:0] out_data;wire [$clog2(DEPTH+1)-1:0] level;
    c1_r2_video_bram_fifo #(.DEPTH(DEPTH)) dut(.*);
    reg [47:0] expected[0:40000],held_data;reg held=0;
    integer head=0,tail=0,pushed=0,popped=0,full_replace=0,blocked=0,cycles=0;
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>100000)$fatal(1,"FIFO watchdog");
        if(rst) begin head=0;tail=0;held=0;end
        else begin
            if(level!=tail-head)$fatal(1,"FIFO external occupancy");
            if(held && (!out_valid || out_data!==held_data))$fatal(1,"FIFO held word changed");
            held=out_valid&&!out_ready;held_data=out_data;
            if(in_valid&&in_ready)begin expected[tail]=in_data;tail=tail+1;pushed=pushed+1;end
            if(out_valid&&out_ready)begin if(head>=tail || out_data!==expected[head])$fatal(1,"FIFO wrong order");head=head+1;popped=popped+1;end
            if(level==DEPTH && in_valid&&in_ready&&out_valid&&out_ready)full_replace=full_replace+1;
            if(out_valid&&!out_ready)blocked=blocked+1;
        end
    end
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(integer i=0;i<12000;i=i+1)begin
            @(negedge clk);out_ready=i%109>=67;in_valid=1;in_data={16'(i),32'(i*7789)};
            // Legal source: do not replace a held unaccepted word.
            @(posedge clk);
            while(!in_ready)begin @(negedge clk);out_ready=cycles%109>=67;@(posedge clk);end
        end
        @(negedge clk);in_valid=0;out_ready=1;while(level!=0)@(negedge clk);
        repeat(4)@(negedge clk);out_ready=0;in_valid=1;in_data=48'hbaad00;
        repeat(3)@(negedge clk);in_valid=0;repeat(4)@(negedge clk);
        rst=1;repeat(3)@(negedge clk);rst=0;repeat(4)@(negedge clk);
        if(level!=0||out_valid||blocked<20||full_replace==0)$fatal(1,"FIFO missing coverage");
        $display("C1_R2_VIDEO_FIFO_PASS depth=%0d pushed=%0d popped=%0d full_replace=%0d blocked=%0d reset_held=1",DEPTH,pushed,popped,full_replace,blocked);$finish;
    end
endmodule
