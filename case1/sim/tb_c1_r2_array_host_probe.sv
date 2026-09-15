`timescale 1ns/1ps
module tb_c1_r2_array_host_probe;
    parameter integer ROWS=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,load_valid=0,issue_valid=0,issue_first=0,issue_last=0,result_ready=0;
    reg [6:0] load_addr=0;
    reg [31:0] load_data=0;
    reg [ROWS-1:0] issue_mask=0;
    reg [7:0] issue_tag=0;
    reg [2:0] result_row=0;
    wire issue_ready,result_valid,busy;
    wire [31:0] result_data;
    wire [ROWS-1:0] result_mask;
    wire [7:0] result_tag;
    c1_r2_array_host_probe #(.ROWS(ROWS)) dut(.*);
    integer expected[0:ROWS-1],dot[0:ROWS-1];
    integer aa,bb,trial,r,k,j,n,checks=0;
    reg [31:0] aw,bw;
    task automatic load(input integer addr,input reg [31:0] data);
        @(negedge clk);load_valid=1;load_addr=addr;load_data=data;
        @(negedge clk);load_valid=0;
    endtask
    task automatic issue(input bit first,input bit last);
        @(negedge clk);issue_valid=1;issue_first=first;issue_last=last;
        @(posedge clk);while(!issue_ready)@(posedge clk);
        @(negedge clk);issue_valid=0;
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;issue_mask='1;
        for(trial=0;trial<4;trial=trial+1) begin
            for(r=0;r<ROWS;r=r+1) begin
                expected[r]=(trial[0] ? 32'h7ffffff0 : 32'h80000020)+r*131;
                dot[r]=0;
                load(64+r,expected[r]);
                for(k=0;k<4;k=k+1) begin
                    aw=0;bw=0;
                    for(j=0;j<4;j=j+1) begin
                        aa=((r*17+k*23+j*53+trial*71)&255)-128;
                        bb=((r*43+k*11+j*37+trial*97)&255)-128;
                        aw[j*8+:8]=aa;bw[j*8+:8]=bb;
                        dot[r]=dot[r]+aa*bb;
                    end
                    load(r*4+k,aw);load(32+r*4+k,bw);
                end
                expected[r]=expected[r]+dot[r]*(trial<2 ? 1 : 2);
            end
            issue_tag=trial+27;
            if(trial<2)issue(1,1);
            else begin issue(1,0);repeat(3)@(negedge clk);issue(0,1);end
            n=0;while(!result_valid)begin @(negedge clk);n=n+1;if(n>30)$fatal(1,"host result timeout");end
            for(r=0;r<ROWS;r=r+1)begin
                @(negedge clk);result_row=r;#1;
                if(result_data!==expected[r] || result_tag!==trial+27 || result_mask!=={ROWS{1'b1}})
                    $fatal(1,"host lane not independently observable row=%0d actual=%h expected=%h",r,result_data,expected[r]);
                checks=checks+1;
            end
            @(negedge clk);result_ready=1;
            @(negedge clk);result_ready=0;
            if(busy || result_valid)$fatal(1,"host result did not retire");
        end
        $display("C1_R2_ARRAY_HOST_PASS rows=%0d products=%0d loaded_independently=1 observable_rows=%0d checks=%0d",ROWS,ROWS*16,ROWS,checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"host watchdog");end
endmodule
