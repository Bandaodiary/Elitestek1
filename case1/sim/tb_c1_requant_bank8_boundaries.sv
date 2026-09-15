`timescale 1ns/1ps
module tb_c1_requant_bank8_boundaries;
    localparam integer DIRECTED=16*8*48, TOTAL=DIRECTED+1024;
    reg clk=0, rst=1, in_valid=0, out_ready=0;
    wire in_ready, out_valid;
    reg [255:0] in_acc_s32=0;
    reg [143:0] in_mult_s18=0;
    reg [47:0] in_shift_u6=0;
    reg [15:0] in_activation=0;
    reg in_sof=0,in_eol=0,in_eof=0;
    reg [9:0] in_x=0;
    reg [8:0] in_y=0;
    wire [63:0] out_data_s8;
    wire out_sof,out_eol,out_eof;
    wire [9:0] out_x;
    wire [8:0] out_y;
    reg [63:0] expected [0:TOTAL-1];
    reg [21:0] metadata [0:TOTAL-1];
    reg held=0;
    reg [85:0] held_payload;
    reg [31:0] random_state=32'h123abcde;
    integer pushed=0,popped=0,cycles=0,stalls=0,n,c;
    always #5 clk=~clk;
    c1_requant_bank8 dut(.*);
    // Independent signed64 reference: quotient/remainder rounding, not the
    // production shift/bias/sign pipeline. All legal 32x18 products fit here.
    function automatic [7:0] reference_value(
        input reg signed [31:0] acc, input reg signed [17:0] mult,
        input reg [5:0] shift, input reg [1:0] activation);
        reg signed [63:0] a,b,product,mag,den,q;
        begin
            a=acc; b=mult; product=a*b;
            mag=product<0 ? -product : product;
            den=64'sd1<<shift;
            q=mag/den;
            if((mag%den)*2>=den) q=q+1;
            if(product<0) q=-q;
            if(q>127) q=127;
            if(q< -128) q=-128;
            if(activation==1 && q<0) q=0;
            reference_value=q[7:0];
        end
    endfunction
    function automatic [31:0] acc_edge(input integer i);
        case(i)
            0:acc_edge=32'h80000000; 1:acc_edge=32'h7fffffff;
            2:acc_edge=-129; 3:acc_edge=-128; 4:acc_edge=-1;
            5:acc_edge=1; 6:acc_edge=127; 7:acc_edge=128;
            8:acc_edge=-257; 9:acc_edge=-256; 10:acc_edge=-255;
            11:acc_edge=254; 12:acc_edge=255; 13:acc_edge=256;
            14:acc_edge=257; default:acc_edge=0;
        endcase
    endfunction
    function automatic [17:0] mult_edge(input integer i);
        case(i)
            0:mult_edge=18'h20000; 1:mult_edge=18'h1ffff;
            2:mult_edge=-3; 3:mult_edge=-1; 4:mult_edge=0;
            5:mult_edge=1; 6:mult_edge=3; default:mult_edge=65536;
        endcase
    endfunction
    always @(negedge clk) begin
        if(!rst) out_ready=(cycles%19>=9);
    end
    always @(posedge clk) begin
        if(!rst) begin
            cycles=cycles+1;
            if(held && (!out_valid ||
                {out_data_s8,out_sof,out_eol,out_eof,out_x,out_y}!==held_payload))
                $fatal(1,"requant output changed under backpressure");
            held=out_valid&&!out_ready;
            held_payload={out_data_s8,out_sof,out_eol,out_eof,out_x,out_y};
            if(held) stalls=stalls+1;
            if(out_valid&&out_ready) begin
                if(popped>=pushed || out_data_s8!==expected[popped] ||
                   {out_sof,out_eol,out_eof,out_x,out_y}!==metadata[popped])
                    $fatal(1,"requant mismatch vector=%0d got=%h expected=%h",popped,out_data_s8,expected[popped]);
                popped=popped+1;
            end
            if(in_valid&&in_ready) begin
                for(integer lane=0;lane<8;lane++)
                    expected[pushed][lane*8+:8]=reference_value(
                        $signed(in_acc_s32[lane*32+:32]),$signed(in_mult_s18[lane*18+:18]),
                        in_shift_u6[lane*6+:6],in_activation[lane*2+:2]);
                metadata[pushed]={in_sof,in_eol,in_eof,in_x,in_y};
                pushed=pushed+1;
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst=0;
        for(n=0;n<TOTAL;n++) begin
            @(negedge clk);
            in_valid=1; in_x=n%1024; in_y=n/1024;
            in_sof=(n%17==0); in_eol=(n%11==0); in_eof=(n%23==0);
            for(c=0;c<8;c++) begin
                random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
                in_acc_s32[c*32+:32]=n<DIRECTED ? acc_edge(n/384) : random_state;
                in_mult_s18[c*18+:18]=n<DIRECTED ? mult_edge((n/48)%8) : random_state[25:8];
                in_shift_u6[c*6+:6]=(n+c)%48;
                in_activation[c*2+:2]=c%2;
            end
            @(posedge clk);
            while(!in_ready) @(posedge clk);
        end
        @(negedge clk); in_valid=0;
        wait(popped==TOTAL);
        repeat(10) @(negedge clk);
        if(stalls==0 || pushed!=TOTAL || out_valid) $fatal(1,"missing coverage or extra output");
        $display("C1_REQUANT_BOUNDARIES_PASS vectors=%0d lanes=%0d shifts=48 stalls=%0d",popped,popped*8,stalls);
        $finish;
    end
    initial begin #1000000; $fatal(1,"requant test timeout"); end
endmodule
