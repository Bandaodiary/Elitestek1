`timescale 1ns/1ps
module tb_c1_r2_compute6;
    parameter integer STALLS=0,DEPTH=8;
    logic clk=0;always #5 clk=~clk;
    logic rst=1,in_valid=0,out_ready=0,in_first=0,in_last=0;
    logic [5:0] in_mask=0,in_relu=0;
    logic [15:0] in_tag=0;
    logic [767:0] in_a=0,in_b=0;
    logic [191:0] in_bias=0;
    logic [107:0] in_mult=0;
    logic [35:0] in_shift=0;
    wire in_ready,out_valid,busy;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [15:0] out_tag;
    c1_r2_compute6 #(.PARAM_DEPTH(DEPTH)) dut(.*);
    logic [1901:0] inputs[0:40000];
    logic [69:0] expected[0:25000];
    string ip,op;
    integer n,m,sent=0,received=0,cycles=0,first_accept=0,last_accept=0,max_params=0,full_pop_push=0,blocked=0;
    bit checking=0,held=0;
    logic [69:0] held_data;
    always @(negedge clk) out_ready=!rst && (!STALLS || (cycles%83>=37 && cycles%11!=0));
    always @(posedge clk) begin
        cycles=cycles+1;if(cycles>250000) $fatal(1,"compute watchdog");
        if(rst) held=0;
        else begin
            if(held && (!out_valid || {out_tag,out_mask,out_data}!==held_data)) $fatal(1,"compute held output changed");
            held=out_valid && !out_ready;held_data={out_tag,out_mask,out_data};
            if(checking) begin
                if(dut.param_count>max_params) max_params=dut.param_count;
                if(dut.param_count==DEPTH && dut.push && dut.pop) full_pop_push=full_pop_push+1;
                if(out_valid && !out_ready) blocked=blocked+1;
                if(in_valid && in_ready) begin sent=sent+1;if(first_accept==0) first_accept=cycles;last_accept=cycles;end
                if(out_valid && out_ready) begin
                    if(received>=m || {out_tag,out_mask,out_data}!==expected[received]) $fatal(1,"compute mismatch index=%0d got=%h expected=%h",received,{out_tag,out_mask,out_data},expected[received]);
                    received=received+1;
                end
            end
        end
    end
    initial begin
        if(!$value$plusargs("INPUTS=%s",ip) || !$value$plusargs("OUTPUTS=%s",op) || !$value$plusargs("N=%d",n) || !$value$plusargs("M=%d",m)) $fatal(1,"missing compute vectors");
        $readmemh(ip,inputs,0,n-1);$readmemh(op,expected,0,m-1);
        repeat(4) @(negedge clk);rst=0;in_valid=1;in_first=1;in_last=0;in_mask=63;
        @(posedge clk);if(!in_ready) $fatal(1,"compute preflight refused");
        @(negedge clk);in_valid=0;repeat(10) @(negedge clk);
        if(!busy || out_valid) $fatal(1,"incomplete compute transaction not owned");
        rst=1;repeat(3) @(negedge clk);rst=0;repeat(15) @(negedge clk);
        if(busy || out_valid) $fatal(1,"compute reset failed");
        checking=1;
        for(integer i=0;i<n;i=i+1) begin
            // Adjacent beats have no mandatory driver bubble.
            {in_first,in_last,in_mask,in_tag,in_bias,in_a,in_b,in_mult,in_shift,in_relu}=inputs[i];in_valid=1;
            @(posedge clk);while(!in_ready) @(posedge clk);
            @(negedge clk);
            if(STALLS && i%17==0) begin in_valid=0;repeat(2) @(negedge clk);end
        end
        in_valid=0;
        while(received<m) @(negedge clk);
        repeat(15) @(negedge clk);
        if(sent!=n || busy || out_valid || max_params<2 || (STALLS && blocked<20)) $fatal(1,"compute incomplete");
        if(!STALLS && DEPTH==8 && last_accept-first_accept+1!=n) $fatal(1,"compute lost II=1");
        if(DEPTH==2 && (max_params!=2 || full_pop_push<1)) $fatal(1,"compute full FIFO replacement untested");
        $display("C1_R2_COMPUTE_PASS stalls=%0d depth=%0d inputs=%0d outputs=%0d accept_span=%0d max_params=%0d full_pop_push=%0d blocked=%0d reset_partial=1",STALLS,DEPTH,sent,received,last_accept-first_accept+1,max_params,full_pop_push,blocked);
        $finish;
    end
endmodule
