`timescale 1ns/1ps

module tb_c1_iverilog_compat;
    reg clk;
    reg rst;
    reg [7:0] din;
    wire [7:0] dout;
    integer errors;

    c1_iverilog_compat_dut dut (
        .clk(clk), .rst(rst), .din(din), .dout(dout)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("c1_iverilog_compat.vcd");
        $dumpvars(0, tb_c1_iverilog_compat);
        clk = 1'b0;
        rst = 1'b1;
        din = 8'h00;
        errors = 0;
        #12;
        if (dout !== 8'h00) errors = errors + 1;
        rst = 1'b0;
        din = 8'h12;
        @(posedge clk);
        #1;
        if (dout !== 8'h13) errors = errors + 1;
        din = 8'hfe;
        @(posedge clk);
        #1;
        if (dout !== 8'hff) errors = errors + 1;
        if (errors != 0) begin
            $display("C1_IVERILOG_VERILOG2005_FAIL errors=%0d", errors);
            $finish;
        end
        $display("C1_IVERILOG_VERILOG2005_PASS dout=%02h", dout);
        $finish;
    end
endmodule
