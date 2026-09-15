`timescale 1ns/1ps
module tb_c1_ram_sdp_contract #(
    parameter integer DEPTH=3, DATA_WIDTH=8,
    ADDR_WIDTH=(DEPTH<=1)?1:$clog2(DEPTH)
);
    localparam integer DW=(DATA_WIDTH>0)?DATA_WIDTH:1;
    localparam integer AW=(ADDR_WIDTH>0)?ADDR_WIDTH:1;
    logic clk=0,rd_en=0,wr_en=0;
    logic [ADDR_WIDTH-1:0] rd_addr=0,wr_addr=0;
    logic [DATA_WIDTH-1:0] rd_data,wr_data=0;
    integer i;
    always #5 clk=~clk;
    c1_ram_sdp_read_first #(.DEPTH(DEPTH),.DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)) dut(.*);
    initial begin
        // Invalid parameters must fail in the DUT before this sentinel.
        if(DEPTH<1 || DATA_WIDTH<1 || ADDR_WIDTH<1 || ADDR_WIDTH<$clog2(DEPTH)) begin
            #20;$display("C1_RAM_INVALID_PARAMETER_UNDETECTED");$finish;
        end
        for(i=0;i<DEPTH;i++) begin
            @(negedge clk);wr_en=1;wr_addr=AW'(i);wr_data=DW'(i+17);
        end
        @(negedge clk);wr_en=0;
        for(i=0;i<DEPTH;i++) begin
            // Read old data on a simultaneous same-address write.
            @(negedge clk);rd_en=1;wr_en=1;
            rd_addr=AW'(i);wr_addr=AW'(i);wr_data=DW'(i+83);
            @(posedge clk);#1;
            if(rd_data!==DW'(i+17)) $fatal(1,"RAM is not read-first");
            @(negedge clk);wr_en=0;
            @(posedge clk);#1;
            if(rd_data!==DW'(i+83)) $fatal(1,"RAM write was not retained");
            @(negedge clk);rd_en=0;rd_addr='1;
            repeat(3) begin
                @(posedge clk);#1;
                if(rd_data!==DW'(i+83)) $fatal(1,"disabled read did not hold output");
            end
        end
        $display("C1_RAM_SDP_CONTRACT_PASS depth=%0d width=%0d read_first=1 hold=1",DEPTH,DATA_WIDTH);
        $finish;
    end
    initial begin #100000;$fatal(1,"RAM test timeout");end
endmodule
