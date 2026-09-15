`timescale 1ns/1ps
module tb_c1_frame_triple_layout_check #(parameter integer REGION_MODE=0,
    parameter bit FAST_ENVELOPE=1, parameter bit PERF_MODE=0,
    parameter bit WRITE_VS_READERS=0);
    logic clk=0,rst=1,cancel=0;always #5 clk=~clk;
    logic req_valid=0,req_ready,busy,rsp_valid,rsp_ready=0;
    logic [2:0][31:0] frame_base,frame_stride;
    logic [2:0][15:0] frame_width,frame_height;
    wire [1:0] error_code,error_index;
    integer checks=0;
    integer cycles=0,request_cycle=0,response_latency=0;
    always @(posedge clk) cycles=cycles+1;
    logic [31:0] random_state=32'h5317cafe;
    logic [1:0] oracle_code,oracle_index;
    integer pair_index;
    integer random_legal=0,random_overlap=0;
    function automatic [31:0] next_random;
        random_state=random_state*32'd1664525+32'd1013904223;
        next_random=random_state^(random_state>>16);
    endfunction
    c1_frame_triple_layout_check #(
        .FAST_DISJOINT_ENVELOPE(FAST_ENVELOPE),
        .CHECK_PAIR_MASK(WRITE_VS_READERS ? 3'b011 : 3'b111),
        .PREVIEW_REGION_BEGIN(REGION_MODE==0 ? 33'd0 : 33'h3000),
        .PREVIEW_REGION_END(REGION_MODE==0 ? 33'h1_0000_0000 :
                           REGION_MODE==1 ? 33'h3040 :
                           REGION_MODE==2 ? 33'h3000 :
                           REGION_MODE==3 ? 33'h2ff0 : 33'h1_0000_0010)
    ) dut(.*);
    task automatic defaults;
        frame_base={32'h3000,32'h2000,32'h1000};
        frame_stride={3{32'd32}};frame_width={3{16'd8}};frame_height={3{16'd2}};
    endtask
    task automatic launch;
        @(negedge clk);req_valid=1;
        if(!req_ready) $fatal(1,"layout not ready");
        @(negedge clk);req_valid=0;
        request_cycle=cycles;
        // A new layout at the pins must not mutate the active check.
        frame_base='1;frame_stride='0;frame_width='0;frame_height='0;
    endtask
    task automatic check(input logic [1:0] code,index);
        launch();wait(rsp_valid);response_latency=cycles-request_cycle;@(negedge clk);
        repeat(8) begin
            if(error_code!==code||error_index!==index||!rsp_valid||req_ready||busy)
                $fatal(1,"layout response mismatch expected=%0d/%0d got=%0d/%0d",code,index,error_code,error_index);
            @(negedge clk);
        end
        rsp_ready=1;@(negedge clk);rsp_ready=0;checks++;
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        if(PERF_MODE) begin
            for(integer fixture=0;fixture<2;fixture++) begin
                frame_base={32'h700000,32'h400000,32'h100000};
                frame_stride={3{fixture==0 ? 32'd2560 : 32'd16}};
                frame_width={3{fixture==0 ? 16'd640 : 16'd4}};
                frame_height={3{fixture==0 ? 16'd480 : 16'd65535}};
                check(0,0);
                if(response_latency!=(FAST_ENVELOPE ? 54 : 51+3*(1+(fixture==0 ? 480 : 65535))))
                    $fatal(1,"unexpected envelope preflight latency %0d",response_latency);
                $display("C1_FRAME_LAYOUT_PERF_PASS fast=%0d height=%0d cycles=%0d",FAST_ENVELOPE,fixture==0 ? 480 : 65535,response_latency);
            end
            $finish;
        end
        if(REGION_MODE!=0) begin
            if(REGION_MODE==1) begin
                defaults();check(0,0); // Exclusive end exactly equals arena end.
                defaults();frame_base[2]=32'h2ff0;check(2,2);
                defaults();frame_base[2]=32'h3010;check(2,2);
                defaults();frame_stride[2]=48;check(2,2); // Padding increases extent.
                defaults();frame_height[2]=1;check(0,0);
                defaults();check(0,0); // No-reset recovery.
            end else begin
                defaults();check(2,2); // Empty, reversed, or above 4 GiB.
                defaults();check(2,2);
            end
            $display("C1_FRAME_LAYOUT_REGION_PASS mode=%0d checks=%0d",REGION_MODE,checks);
            $finish;
        end
        defaults();check(0,0);
        defaults();frame_base[1]=32'h1000;check(3,0);
        defaults();frame_base[2]=32'h1010;check(3,1);
        defaults();frame_base[2]=32'h2010;check(WRITE_VS_READERS ? 0 : 3,WRITE_VS_READERS ? 0 : 2);
        defaults();frame_width[2]=0;check(1,2);
        defaults();frame_stride[1]=16;check(1,1);
        defaults();frame_base[0]=32'h1004;check(1,0);
        defaults();frame_base[2]=32'hfffffff0;frame_width[2]=4;frame_height[2]=1;frame_stride[2]=16;check(0,0);
        defaults();frame_base[2]=32'hfffffff0;frame_width[2]=4;frame_stride[2]=16;check(2,2);
        defaults();frame_height[2]=16'hffff;frame_stride[2]=32'hfffffff0;check(2,2);
        // Bounding envelopes intersect, but three interleaved row lists do not.
        defaults();frame_base={32'h1020,32'h1010,32'h1000};
        frame_stride={3{32'd64}};frame_width={3{16'd4}};frame_height={3{16'd3}};check(0,0);
        defaults();frame_base[2]=32'h1020;frame_width[2]=4;frame_stride[2]=64;check(3,1);
        defaults();launch();repeat(5) @(negedge clk);cancel=1;@(negedge clk);cancel=0;
        repeat(70) begin @(negedge clk);if(busy||rsp_valid) $fatal(1,"canceled layout leaked result");end
        defaults();check(0,0);
        // Independent exhaustive row-pair oracle, not the DUT's merge walk.
        // A 4-GiB exclusive end must not truncate to zero in the shortcut.
        defaults();frame_base[1]=32'hffffffe0;frame_base[2]=32'hfffffff0;
        frame_height[1]=1;frame_height[2]=1;frame_width[2]=4;
        check(WRITE_VS_READERS ? 0 : 3,WRITE_VS_READERS ? 0 : 2);
        // Adjacent half-open envelopes are legal, including the top of memory.
        frame_base={32'hfffffff0,32'hffffffe0,32'hffffffd0};
        frame_stride={3{32'd16}};frame_width={3{16'd4}};frame_height={3{16'd1}};check(0,0);
        for(integer test=0;test<200;test++) begin
            for(integer f=0;f<3;f++) begin
                frame_base[f]=32'h1000+16*(next_random()%32);
                frame_width[f]=16'(4*(1+next_random()%4));
                frame_height[f]=16'(1+next_random()%6);
                frame_stride[f]=4*frame_width[f]+16*(next_random()%5);
            end
            oracle_code=0;oracle_index=0;pair_index=0;
            for(integer a=0;a<2;a++) begin
                for(integer b=a+1;b<3;b++) begin
                    for(integer ra=0;ra<frame_height[a];ra++) begin
                        for(integer rb=0;rb<frame_height[b];rb++) begin
                            if(oracle_code==0 && (!WRITE_VS_READERS || a==0) &&
                               frame_base[a]+ra*frame_stride[a]<frame_base[b]+rb*frame_stride[b]+4*frame_width[b] &&
                               frame_base[b]+rb*frame_stride[b]<frame_base[a]+ra*frame_stride[a]+4*frame_width[a]) begin
                                oracle_code=3;oracle_index=2'(pair_index);
                            end
                        end
                    end
                    pair_index++;
                end
            end
            if(oracle_code==0) random_legal++;else random_overlap++;
            check(oracle_code,oracle_index);
        end
        if(checks!=215) $fatal(1,"coverage count");
        if(random_legal==0||random_overlap==0) $fatal(1,"random oracle did not cover both outcomes");
        if(WRITE_VS_READERS)
            $display("C1_FRAME_WRITE_READERS_PASS checks=215 randomized=200 read_alias_allowed=1 write_alias_rejected=1 fast=%0d",FAST_ENVELOPE);
        $display("C1_FRAME_LAYOUT_ORACLE_PASS legal=%0d overlap=%0d",random_legal,random_overlap);
        if(!WRITE_VS_READERS)
            $display("C1_FRAME_TRIPLE_LAYOUT_PASS checks=215 randomized=200 pairs=3 padding_shared=1 end_4GiB=1 overlap_4GiB=1 adjacent=1 overflow_wide=1 snapshot=1 stall=8 cancel_restart=1");
        $finish;
    end
    initial begin #10000000;$fatal(1,"triple layout timeout");end
endmodule
