`timescale 1ns/1ps
module tb_c1_stream_fifo_reset #(parameter integer DEPTH=5);
    reg clk=0, rst=1, in_valid=0, out_ready=0;
    reg [15:0] in_data=0;
    wire in_ready, out_valid, full, empty;
    wire [15:0] out_data;
    wire [$clog2(DEPTH+1)-1:0] level;
    integer occupancy, n;
    always #5 clk=~clk;
    c1_stream_fifo #(.DATA_WIDTH(16),.DEPTH(DEPTH)) dut (.*);
    task push(input reg [15:0] value);
        begin
            @(negedge clk); in_valid=1; in_data=value;
            #1; if(!in_ready) $fatal(1,"unexpected input stall");
            @(negedge clk); in_valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        for(occupancy=0; occupancy<=DEPTH; occupancy++) begin
            for(n=0; n<occupancy; n++) push(16'(n+1));
            if(level!=occupancy) $fatal(1,"fill level mismatch");
            // Both endpoints may remain active during a LOCAL reset. A
            // visible ready/valid handshake must not be silently discarded.
            @(negedge clk); rst=1; in_valid=1; out_ready=1; in_data=16'hdead;
            #1;
            if(in_ready || out_valid)
                $fatal(1,"phantom reset handshake depth=%0d occupancy=%0d in_ready=%b out_valid=%b",
                    DEPTH,occupancy,in_ready,out_valid);
            repeat(2) @(negedge clk);
            if(level!=0 || !empty || full) $fatal(1,"reset did not clear occupancy");
            in_valid=0; out_ready=0; rst=0;
            push(16'hbeef);
            if(!out_valid || out_data!=16'hbeef || level!=1)
                $fatal(1,"stale data after reset");
            @(negedge clk); out_ready=1;
            @(negedge clk); out_ready=0;
            if(!empty || level!=0) $fatal(1,"post-reset drain failed");
        end
        $display("C1_STREAM_FIFO_RESET_PASS depth=%0d occupancies=%0d",DEPTH,DEPTH+1);
        $finish;
    end
    initial begin #1000000; $fatal(1,"reset test timeout"); end
endmodule
