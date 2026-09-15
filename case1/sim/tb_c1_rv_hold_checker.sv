`timescale 1ns/1ps
module tb_c1_rv_hold_checker #(parameter integer FAULT=0);
    logic clk=0,rst=1,cancel=0,valid=0,ready=0;
    logic [7:0] payload=0;
    always #5 clk=~clk;
    c1_rv_hold_checker dut(.*);
    initial begin
        repeat(3) @(negedge clk);rst=0;valid=1;payload=8'h53;
        repeat(3) @(negedge clk);
        case(FAULT)
            1:payload=8'h54; // mutation between sampling edges
            2:begin valid=0;ready=1;end // withdrawal at accepting edge
            3:begin payload=8'hd3;ready=1;end // metadata/payload change on ready
            default:ready=1;
        endcase
        @(negedge clk);
        if(FAULT) $fatal(1,"checker missed deliberate protocol violation");
        payload=8'ha1;ready=0;
        repeat(3) @(negedge clk);
        cancel=1;valid=0;payload=0;
        @(negedge clk);cancel=0;valid=1;payload=8'h7e;
        repeat(3) @(negedge clk);
        rst=1;valid=0;payload=0;
        @(negedge clk);rst=0;valid=1;ready=1;payload=8'h18;
        repeat(3) @(negedge clk);
        $display("C1_RV_HOLD_CHECKER_PASS stall=1 accept=1 cancel=1 reset=1");
        $finish;
    end
endmodule
