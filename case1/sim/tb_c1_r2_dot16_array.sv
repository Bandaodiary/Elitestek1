`timescale 1ns/1ps
module tb_c1_r2_dot16_array;
    parameter integer ROWS=8, STALLS=0;
    localparam integer IB=ROWS*289+18, OB=ROWS*33+16;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,in_valid=0,in_first=0,in_last=0,out_ready=0;
    reg [ROWS-1:0] in_mask=0;
    reg [15:0] in_tag=0;
    reg [ROWS*128-1:0] in_a=0,in_b=0;
    reg [ROWS*32-1:0] in_bias=0;
    wire in_ready,out_valid,busy;
    wire [ROWS-1:0] out_mask;
    wire [15:0] out_tag;
    wire [ROWS*32-1:0] out_acc;
    c1_r2_dot16_array #(.ROWS(ROWS)) dut(.*);
    reg [IB-1:0] input_records[0:49999];
    reg [OB-1:0] output_records[0:29999];
    string input_path,output_path;
    integer n_inputs,n_outputs,sent=0,received=0,cycles=0,stalls=0,first_cycle=-1,last_cycle=-1;
    integer busy_idle=0;
    bit enabled=0,took=0;
    reg [31:0] prng=32'h91a723df;

    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("OUTPUTS=%s",output_path) ||
           !$value$plusargs("N=%d",n_inputs) || !$value$plusargs("M=%d",n_outputs))
            $fatal(1,"missing vector arguments");
        if(n_inputs<1 || n_inputs>50000 || n_outputs<1 || n_outputs>30000) $fatal(1,"vector size");
        $readmemh(input_path,input_records,0,n_inputs-1);
        $readmemh(output_path,output_records,0,n_outputs-1);
        repeat(3) @(negedge clk);
        rst=0; in_valid=1; in_first=1; in_last=0; in_mask='1;
        in_a='1; in_b='1; in_bias='1;
        @(negedge clk); in_valid=0;
        repeat(3) @(negedge clk);
        if(!busy) $fatal(1,"partial transaction not busy");
        rst=1;
        repeat(2) @(negedge clk);
        if(busy || out_valid) $fatal(1,"reset failed to flush local array");
        rst=0; enabled=1;
    end
    always @(negedge clk) if(enabled && !rst) begin
        prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
        out_ready=(STALLS==0) || ((cycles%61>=13) && prng[2:0]!=0);
        if(!in_valid || took) begin
            in_valid=(sent<n_inputs) && ((STALLS==0) || prng[5:3]!=0);
            if(in_valid) {in_first,in_last,in_mask,in_tag,in_bias,in_a,in_b}=input_records[sent];
        end
    end
    always @(posedge clk) if(enabled && !rst) begin
        cycles=cycles+1;
        took=in_valid && in_ready;
        if(took) begin
            if(first_cycle<0)first_cycle=cycles;
            last_cycle=cycles; sent=sent+1;
        end
        if(out_valid && !out_ready)stalls=stalls+1;
        if(out_valid && out_ready) begin
            if(received>=n_outputs || {out_mask,out_tag,out_acc}!==output_records[received]) begin
                $display("R2_MISMATCH index=%0d tag=%0d actual=%h expected=%h",received,out_tag,{out_mask,out_tag,out_acc},output_records[received]);
                $fatal(1,"R2 independent golden mismatch");
            end
            received=received+1;
        end
        if(sent==n_inputs && received==n_outputs && !busy) begin
            if(STALLS==0 && last_cycle-first_cycle+1!=n_inputs) $fatal(1,"continuous issue has bubbles");
            if(STALLS!=0 && stalls<20) $fatal(1,"missing meaningful backpressure");
            $display("C1_R2_ARRAY_PASS rows=%0d products=%0d stalls_mode=%0d inputs=%0d outputs=%0d cycles=%0d blocked_output=%0d first=%0d last=%0d reset_partial=1",ROWS,ROWS*16,STALLS,sent,received,cycles,stalls,first_cycle,last_cycle);
            $finish;
        end
        if(cycles>500000) $fatal(1,"R2 watchdog");
    end
endmodule
