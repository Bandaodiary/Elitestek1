`timescale 1ns/1ps
module tb_c1_frames_arena_check;
    logic clk=0,rst=1,cancel=0,req_valid=0,rsp_ready=0;
    wire req_ready,busy,rsp_valid;
    logic [32:0] arena_begin,arena_end;
    logic [2:0] frame_valid;
    logic [2:0][31:0] frame_base,frame_stride;
    logic [2:0][15:0] frame_width,frame_height;
    wire [1:0] error_code,error_index;
    integer checks=0,seed=314159,discard;
    always #5 clk=~clk;
    c1_frames_arena_check #(.FRAMES(3)) dut(.*);
    task automatic defaults;
        arena_begin=33'h02000000;arena_end=33'h03800000;
        frame_valid=7;frame_base={32'h08000000,32'h04000000,32'h00100000};
        frame_stride={3{32'd64}};frame_width={3{16'd8}};frame_height={3{16'd3}};
    endtask
    task automatic check;
        integer expected,expected_index,cycles;
        logic [63:0] last_end,row_start,row_end;
        expected=0;expected_index=0;
        if(arena_begin>=arena_end||arena_end>33'h100000000) expected=2;
        // Independent oracle uses wide multiplication and brute-force rows,
        // not the DUT's serial multiplier or envelope/scan state machine.
        for(integer i=0;i<3;i=i+1) begin
            if(expected==0&&frame_valid[i]) begin
                expected_index=i;
                if(frame_width[i]==0||frame_height[i]==0||frame_width[i]%4!=0||
                   frame_base[i]%16!=0||frame_stride[i]%16!=0||frame_stride[i]<frame_width[i]*4)
                    expected=1;
                else begin
                    last_end=64'(frame_base[i])+64'(frame_stride[i])*(64'(frame_height[i])-1)+64'(frame_width[i])*4;
                    if(last_end>64'h100000000) expected=2;
                    else for(integer row=0;row<frame_height[i];row=row+1) begin
                        row_start=64'(frame_base[i])+64'(frame_stride[i])*row;
                        row_end=row_start+64'(frame_width[i])*4;
                        if(row_start<arena_end&&arena_begin<row_end) expected=3;
                    end
                end
            end
        end
        @(negedge clk);req_valid=1;
        if(!req_ready) $fatal(1,"checker not ready for next request");
        @(negedge clk);req_valid=0;
        arena_begin=0;arena_end=0;frame_valid=0;frame_base='1;frame_stride='1;frame_width='0;frame_height='0;
        cycles=0;
        while(!rsp_valid&&cycles<1000) begin @(negedge clk);cycles++;end
        if(!rsp_valid||error_code!==2'(expected)||(expected!=0&&error_index!==2'(expected_index)))
            $fatal(1,"arena oracle mismatch expected=%0d/%0d got=%0d/%0d",expected,expected_index,error_code,error_index);
        repeat(4) begin
            @(negedge clk);
            if(!rsp_valid||req_ready||error_code!==2'(expected)) $fatal(1,"stalled arena response changed");
        end
        rsp_ready=1;@(negedge clk);rsp_ready=0;checks++;
    endtask
    initial begin
        defaults();repeat(4) @(negedge clk);rst=0;discard=$urandom(seed);
        check();
        // One interval wholly within row padding, then crossing an active row.
        defaults();frame_valid=1;frame_base[0]=32'h1000;arena_begin=33'h1020;arena_end=33'h1040;check();
        defaults();frame_valid=1;frame_base[0]=32'h1000;arena_begin=33'h1030;arena_end=33'h1050;check();
        // Half-open equality, final legal byte, and genuine 32-bit overflow.
        defaults();frame_valid=1;frame_base[0]=32'hfffffff0;frame_width[0]=4;frame_height[0]=1;
        arena_begin=33'hffffffe0;arena_end=33'hfffffff0;check();
        defaults();frame_valid=1;frame_base[0]=32'hfffffff0;frame_width[0]=4;frame_height[0]=1;
        arena_begin=33'hfffffff0;arena_end=33'h100000000;check();
        defaults();frame_valid=1;frame_base[0]=32'hfffffff0;frame_height[0]=1;check();
        defaults();frame_valid=1;frame_stride[0]=32'hfffffff0;frame_height[0]=65535;check();
        defaults();arena_end=33'h100000001;check();
        defaults();arena_begin=arena_end;check();
        defaults();frame_width[1]=0;check();
        defaults();frame_valid=1;frame_width[1]=0;check();
        for(integer n=0;n<180;n=n+1) begin
            defaults();frame_valid=$urandom_range(0,7);
            arena_begin=$urandom_range(0,63)*16;arena_end=arena_begin+$urandom_range(1,10)*16;
            for(integer i=0;i<3;i=i+1) begin
                frame_base[i]=$urandom_range(0,63)*16;
                frame_width[i]=$urandom_range(1,4)*4;
                frame_stride[i]=frame_width[i]*4+$urandom_range(0,5)*16;
                frame_height[i]=$urandom_range(1,8);
            end
            check();
        end
        defaults();@(negedge clk);req_valid=1;
        @(negedge clk);req_valid=0;repeat(8) @(negedge clk);
        if(!busy||rsp_valid) $fatal(1,"missed active arena cancel");
        cancel=1;@(negedge clk);cancel=0;
        repeat(30) begin @(negedge clk);if(busy||rsp_valid) $fatal(1,"late arena response");end
        defaults();check();
        $display("C1_FRAMES_ARENA_PASS checks=%0d random=180 snapshot=1 cancel_recovery=1",checks);
        $finish;
    end
    initial begin #2000000;$fatal(1,"arena test timeout");end
endmodule
