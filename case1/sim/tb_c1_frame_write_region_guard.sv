`timescale 1ns/1ps
module tb_c1_frame_write_region_guard #(parameter bit TENSOR_CASES=0,parameter bit STATIC_CASES=0);
    logic clk=0,rst=1,cancel=0,req_valid=0;
    wire busy,rsp_valid;
    logic [32:0] tensor_begin=33'h02000000,tensor_end=33'h03800000;
    logic [3:0][32:0] static_begin='0,static_end='0;
    logic [1:0] writer_valid;
    logic [1:0][31:0] writer_base,writer_stride;
    logic [1:0][15:0] writer_width,writer_height;
    logic [6:0] held_valid;
    logic [6:0][31:0] held_base,held_stride;
    logic [6:0][15:0] held_width,held_height;
    wire [7:0] error_code;
    wire [31:0] error_address;
    integer checks=0;
    always #5 clk=~clk;
    c1_frame_write_region_guard #(.CHECK_TENSOR_ARENA(TENSOR_CASES),.CHECK_STATIC_ARENAS(STATIC_CASES)) dut(.*);
    task automatic defaults;
        tensor_begin=33'h02000000;tensor_end=33'h03800000;
        for(integer i=0;i<4;i=i+1) begin
            static_begin[i]=33'h10000+i*33'h1000;static_end[i]=static_begin[i]+32;
        end
        writer_valid=3;writer_base={32'h08000000,32'h04000000};
        writer_stride={2{32'd64}};writer_width={2{16'd8}};writer_height={2{16'd3}};
        held_valid=7'h7f;held_stride={7{32'd64}};
        held_width={7{16'd8}};held_height={7{16'd3}};
        for(integer i=0;i<7;i=i+1) held_base[i]=32'h10000000+i*32'h1000;
    endtask
    task automatic check(input logic [7:0] code,input logic [31:0] address);
        integer cycles;
        @(negedge clk);req_valid=1;
        @(negedge clk);
        // All public metadata may change after acceptance; check the snapshot.
        writer_base='1;held_base='0;held_valid=0;
        tensor_begin=0;tensor_end=0;
        static_begin='0;static_end='0;
        cycles=0;
        while(!rsp_valid&&cycles<2500) begin @(negedge clk);cycles++;end
        if(!rsp_valid||error_code!==code||(code!=0&&error_address!==address))
            $fatal(1,"region guard mismatch expected=%h/%h got=%h/%h cycles=%0d",code,address,error_code,error_address,cycles);
        repeat(5) begin
            @(negedge clk);
            if(!rsp_valid||!busy||error_code!==code) $fatal(1,"response not held");
        end
        cancel=1;req_valid=0;
        @(negedge clk);cancel=0;
        if(busy||rsp_valid) $fatal(1,"region cancel failed");
        checks++;
    endtask
    initial begin
        defaults();repeat(4) @(negedge clk);rst=0;
        if(STATIC_CASES) begin
            check(0,0);
            for(integer w=0;w<2;w=w+1) begin
                for(integer a=0;a<4;a=a+1) begin
                    defaults();static_begin[a]={1'b0,writer_base[w]}+16;static_end[a]=static_begin[a]+16;
                    check(8'h39,writer_base[w]);
                end
            end
            defaults();static_begin[0]={1'b0,held_base[0]};static_end[0]=static_begin[0]+32;
            check(0,0); // Read-only retained image and static reader can alias.
            defaults();static_end[3]=static_begin[3];check(8'h3a,32'h04000000);
            defaults();static_begin[3]=33'h04000020;static_end[3]=33'h04000040;
            check(0,0); // Static artifact fits exactly in padding.
            defaults();@(negedge clk);req_valid=1;
            wait(dut.arena_phase_q==4&&dut.state==dut.ARENA_WAIT);
            repeat(5) @(negedge clk);
            if(!busy||rsp_valid) $fatal(1,"missed last static arena cancel");
            cancel=1;req_valid=0;@(negedge clk);cancel=0;
            repeat(80) begin @(negedge clk);if(busy||rsp_valid) $fatal(1,"late static admission");end
            defaults();check(0,0);
            $display("C1_STATIC_REGION_GUARD_PASS checks=%0d tensor=%0d artifacts=4 snapshot=1 cancel_recovery=1",checks,TENSOR_CASES);
            $finish;
        end
        if(TENSOR_CASES) begin
            check(0,0);
            for(integer w=0;w<2;w=w+1) begin
                defaults();tensor_begin={1'b0,writer_base[w]};tensor_end=tensor_begin+32;
                check(8'h37,writer_base[w]);
            end
            for(integer h=0;h<7;h=h+1) begin
                defaults();tensor_begin={1'b0,held_base[h]};tensor_end=tensor_begin+32;
                check(8'h37,held_base[h]);
            end
            defaults();tensor_end=33'h100000001;check(8'h38,32'h04000000);
            defaults();@(negedge clk);req_valid=1;
            repeat(12) @(negedge clk);
            if(!busy||rsp_valid) $fatal(1,"missed tensor admission cancel");
            cancel=1;req_valid=0;@(negedge clk);cancel=0;
            repeat(80) begin @(negedge clk);if(busy||rsp_valid) $fatal(1,"late tensor admission");end
            defaults();check(0,0);
            $display("C1_TENSOR_REGION_GUARD_PASS checks=%0d held_slots=7 writers=2 cancel_recovery=1",checks);
            $finish;
        end
        check(0,0);
        for(integer w=0;w<2;w=w+1) begin
            for(integer h=0;h<7;h=h+1) begin
                defaults();held_valid=7'b1<<h;
                held_base[h]=writer_base[w]+16;
                check(8'h35,w ? 32'h08000000 : 32'h04000000);
            end
        end
        // Effective rows can legally occupy the other frame's padding.
        defaults();held_valid=1;held_base[0]=32'h04000020;
        check(0,0);
        defaults();held_valid=1;held_base[0]=32'h04000030;
        check(8'h35,32'h04000000);
        defaults();held_valid=1;held_base[0]=32'hfffffff0;held_width[0]=4;held_height[0]=1;
        check(0,0); // Exclusive end exactly 2^32 is legal.
        defaults();held_valid=1;held_base[0]=32'hfffffff0;held_width[0]=8;held_height[0]=1;
        check(8'h36,32'h04000000);
        // Disable the preview writer without introducing a fake zero frame.
        defaults();writer_valid=1;held_valid=1;held_base[0]=writer_base[1];
        check(0,0);
        // Cancel a running check, not merely its held response.
        defaults();@(negedge clk);req_valid=1;
        repeat(12) @(negedge clk);
        if(!busy||rsp_valid) $fatal(1,"cancel test missed active check");
        cancel=1;req_valid=0;@(negedge clk);cancel=0;
        repeat(80) begin @(negedge clk);if(busy||rsp_valid) $fatal(1,"late cancelled response");end
        defaults();check(0,0);
        $display("C1_FRAME_WRITE_REGION_GUARD_PASS checks=%0d cancel_recovery=1 held_slots=7 writers=2",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"region guard timeout");end
endmodule
