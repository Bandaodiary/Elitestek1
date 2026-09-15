`timescale 1ns/1ps
module tb_c37_capacity;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg [2:0] mode=0;
    reg [13:0] start_size=0,load_addr=0;
    reg [5:0] start_channels=16,start_outputs=8;
    reg virtual_up2=0,load_valid=0,bulk_valid=0;
    reg [1:0] load_kind=2,bulk_row=1;
    reg [31:0] load_data=0;
    reg [9:0] bulk_pair=0;
    reg [2:0] bulk_groups=2,bulk_group=0;
    wire [1:0] load_ready,start_ready,bulk_ready;
    integer checks=0,c;
    for(genvar p=0;p<2;p=p+1)begin : g_profile
        c1_r2_cnn_row_shadow_engine #(.MAX_CHANNELS(p==0 ? 24 : 48),.ROW_WORDS(p==0 ? 512 : 1024)) dut(
            .clk(clk),.rst(rst),.mode(mode),.partition_en(1'b0),.partition_base(9'd0),.partition_end(10'd0),
            .start_shadow_capture(1'b0),.start_shadow_read(1'b0),
            .load_valid(load_valid),.load_ready(load_ready[p]),.load_kind(load_kind),.load_addr(load_addr),.load_data(load_data),
            .bulk_valid(bulk_valid),.bulk_ready(bulk_ready[p]),.bulk_row(bulk_row),.bulk_pair(bulk_pair),
            .bulk_group(bulk_group),.bulk_groups(bulk_groups),.bulk_residual_b(1'b0),.bulk_data(128'd0),
            .start_valid(1'b0),.start_ready(start_ready[p]),.start_size(start_size),
            .start_channels(start_channels),.start_outputs(start_outputs),.virtual_up2(virtual_up2),
            .row_top(1'b0),.row_bottom(1'b0),.row_phase(1'b0),.start_row_map(6'b100100),.out_ready(1'b1));
    end
    task shape(input integer m,w,ci,co,up,input [1:0] expected);
        begin
            @(negedge clk);mode=m;start_size=w;start_channels=ci;start_outputs=co;virtual_up2=up;
            #1;if(start_ready!==expected)$fatal(1,"C37 capacity shape m=%0d w=%0d ci=%0d got=%b expected=%b",m,w,ci,start_ready,expected);
            checks=checks+1;
        end
    endtask
    task parameter_word(input integer kind,address,input [31:0] value,input [1:0] expected);
        begin
            @(negedge clk);load_valid=1;load_kind=kind;load_addr=address;load_data=value;
            #1;if(load_ready!==expected)$fatal(1,"C37 parameter capacity address=%0d kind=%0d got=%b",address,kind,load_ready);
            @(posedge clk);#1;checks=checks+1;
            @(negedge clk);load_valid=0;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        shape(0,4,16,24,0,2'b11);
        shape(0,4,24,48,0,2'b10);
        shape(0,4,48,24,0,2'b10);
        shape(1,1024,8,3,0,2'b11);
        shape(1,1025,8,3,0,2'b00);
        shape(2,512,16,16,0,2'b11);
        shape(2,513,16,16,0,2'b10);
        shape(2,340,24,24,0,2'b11);
        shape(2,341,24,24,0,2'b10);
        shape(2,320,16,16,1,2'b11);
        shape(2,513,16,16,1,2'b00);
        shape(4,1024,3,12,0,2'b11);
        shape(5,512,12,24,0,2'b11);
        shape(5,513,12,24,0,2'b10);
        shape(5,320,12,24,0,2'b11);
        shape(3,8192,24,24,0,2'b11);
        shape(3,8193,24,24,0,2'b00);
        shape(0,0,16,8,0,2'b00);
        @(negedge clk);mode=0;
        for(c=0;c<48;c=c+1)begin
            parameter_word(2,c,32'h70001000+c,c<24 ? 2'b11 : 2'b10);
            parameter_word(3,c,32'h01000003+(c%48)*262144,c<24 ? 2'b11 : 2'b10);
        end
        parameter_word(2,48,32'd0,2'b00);
        parameter_word(3,23,32'h02000000,2'b00);
        parameter_word(3,23,32'h01c00001,2'b00);
        for(c=0;c<48;c=c+1)begin
            if(g_profile[1].dut.bias_table[c*32+:32]!==32'h70001000+c)
                $fatal(1,"C37 48-channel bias table mismatch");
            if(g_profile[1].dut.affine_table[c*25+:25]!==25'h1000003+(c%48)*262144)
                $fatal(1,"C37 48-channel affine table mismatch");
            if(c<24)begin
                if(g_profile[0].dut.bias_table[c*32+:32]!==32'h70001000+c)
                    $fatal(1,"C37 rejected write aliased 24-channel bias");
                if(g_profile[0].dut.affine_table[c*25+:25]!==25'h1000003+(c%48)*262144)
                    $fatal(1,"C37 rejected write aliased 24-channel affine");
            end
        end
        // Reach the last bank word, then verify actual bulk admission denies
        // the first out-of-capacity word instead of truncating its address.
        @(negedge clk);mode=2;bulk_groups=2;bulk_group=1;bulk_pair=255;bulk_valid=1;
        #1;if(bulk_ready!==2'b11)$fatal(1,"C37 row last word rejected");checks=checks+1;
        @(negedge clk);bulk_pair=256;bulk_group=0;
        #1;if(bulk_ready!==2'b10)$fatal(1,"C37 row overflow not rejected");checks=checks+1;
        @(negedge clk);bulk_pair=512;
        #1;if(bulk_ready!==2'b00)$fatal(1,"C37 compatibility row overflow not rejected");checks=checks+1;
        @(negedge clk);bulk_valid=0;
        $display("C37_CAPACITY_PASS profiles=2 shape_checks=18 admission_checks=%0d channels_checked=72",checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"C37 capacity timeout");end
endmodule
