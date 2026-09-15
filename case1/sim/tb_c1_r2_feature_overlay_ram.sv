`timescale 1ns/1ps
module tb_c1_r2_feature_overlay_ram;
    parameter integer NEGATIVE=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,linear_rd_en=0,spatial_rd_en=0,spatial_wr_en=0;
    reg [17:0] linear_rd_addr=0;
    reg [19:0] spatial_rd_addr=0;
    reg [7:0] linear_wr_en=0;
    reg [71:0] linear_wr_addr=0;
    reg [255:0] linear_wr_data=0;
    reg [9:0] spatial_wr_addr=0;
    reg [127:0] spatial_wr_data=0;
    wire [255:0] linear_rd_data;
    wire [127:0] spatial_rd_data;
    c1_r2_feature_overlay_ram dut(.*);
    reg [7:0] bytes[0:16383];
    reg [31:0] random_q=32'h29842187;
    integer linear_reads=0,spatial_reads=0,linear_writes=0,spatial_writes=0,hold_checks=0,resets=0;
    function automatic [31:0] random_next(input [31:0] x);
        reg [31:0] y;begin y=x^(x<<13);y=y^(y>>17);random_next=y^(y<<5);end
    endfunction
    // Byte offsets, expressed independently of the RTL's physical RAM IDs.
    function automatic integer linear_offset(input integer bank,address,word_id);
        linear_offset=bank*8192+(word_id/2)*4096+address*8+(word_id%2)*4;
    endfunction
    task idle_inputs;
        begin linear_rd_en=0;spatial_rd_en=0;linear_wr_en=0;spatial_wr_en=0;end
    endtask
    task put_linear(input integer address,input [7:0] mask);
        integer offset;
        begin
            @(negedge clk);idle_inputs;linear_wr_en=mask;
            for(integer id=0;id<8;id=id+1)begin
                linear_wr_addr[id*9+:9]=address;
                random_q=random_next(random_q);linear_wr_data[id*32+:32]=random_q;
                if(mask[id])begin
                    offset=linear_offset(id/4,address,id%4);
                    for(integer b=0;b<4;b=b+1)bytes[offset+b]=random_q[b*8+:8];
                    linear_writes=linear_writes+1;
                end
            end
            @(posedge clk);#1;
        end
    endtask
    task put_spatial(input integer address);
        integer offset;
        begin
            @(negedge clk);idle_inputs;spatial_wr_en=1;spatial_wr_addr=address;
            for(integer word_id=0;word_id<4;word_id=word_id+1)begin
                random_q=random_next(random_q);spatial_wr_data[word_id*32+:32]=random_q;
                offset=(word_id/2)*8192+address*8+(word_id%2)*4;
                for(integer b=0;b<4;b=b+1)bytes[offset+b]=random_q[b*8+:8];
            end
            spatial_writes=spatial_writes+1;@(posedge clk);#1;
        end
    endtask
    task get_linear(input integer a,b);
        integer offset;
        begin
            @(negedge clk);idle_inputs;linear_rd_en=1;linear_rd_addr={9'(b),9'(a)};
            @(posedge clk);#1;
            for(integer bank=0;bank<2;bank=bank+1)
                for(integer word_id=0;word_id<4;word_id=word_id+1)begin
                    offset=linear_offset(bank,bank ? b : a,word_id);
                    for(integer byte_id=0;byte_id<4;byte_id=byte_id+1)
                        if(linear_rd_data[bank*128+word_id*32+byte_id*8+:8]!==bytes[offset+byte_id])
                            $fatal(1,"overlay linear data/latency mismatch bank=%0d word=%0d addr=%0d",bank,word_id,bank ? b : a);
                end
            linear_reads=linear_reads+1;
        end
    endtask
    task get_spatial(input integer a,b);
        integer offset;
        begin
            @(negedge clk);idle_inputs;spatial_rd_en=1;spatial_rd_addr={10'(b),10'(a)};
            @(posedge clk);#1;
            for(integer bank=0;bank<2;bank=bank+1)begin
                offset=bank*8192+(bank ? b : a)*8;
                for(integer byte_id=0;byte_id<8;byte_id=byte_id+1)
                    if(spatial_rd_data[bank*64+byte_id*8+:8]!==bytes[offset+byte_id])
                        $fatal(1,"overlay spatial half/select/latency mismatch bank=%0d addr=%0d",bank,bank ? b : a);
            end
            spatial_reads=spatial_reads+1;
        end
    endtask
    task hold_or_reset(input bit reset_now);
        reg [383:0] saved;
        begin
            saved={linear_rd_data,spatial_rd_data};
            @(negedge clk);idle_inputs;rst=reset_now;
            if(reset_now)begin linear_rd_en=1;spatial_rd_en=1;linear_wr_en=255;spatial_wr_en=1;end
            repeat(3)begin
                @(posedge clk);#1;
                if({linear_rd_data,spatial_rd_data}!==saved)$fatal(1,"overlay inactive/reset output changed");
                hold_checks=hold_checks+1;
            end
            @(negedge clk);idle_inputs;rst=0;
            if(reset_now)resets=resets+1;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        if(NEGATIVE)begin
            if(NEGATIVE==5)put_linear(0,255);
            if(NEGATIVE==6)put_spatial(0);
            @(negedge clk);idle_inputs;
            case(NEGATIVE)
                1:begin linear_rd_en=1;spatial_rd_en=1;end
                2:begin linear_wr_en=1;spatial_wr_en=1;end
                3:begin linear_rd_en=1;linear_wr_en=1;end
                4:begin spatial_rd_en=1;spatial_wr_en=1;end
                5:spatial_rd_en=1;
                6:linear_rd_en=1;
                7:begin linear_wr_en=1;spatial_rd_en=1;end
                8:begin linear_rd_en=1;spatial_wr_en=1;end
                default:$fatal(1,"bad overlay negative control");
            endcase
            repeat(3)@(negedge clk);$fatal(1,"overlay invalid access not rejected");
        end
        for(integer address=0;address<512;address=address+1)put_linear(address,255);
        for(integer address=0;address<512;address=address+1)get_linear(address,(address*7)%512);
        // A write changes ownership. Reinterpret the other bytes deliberately
        // to prove the physical alias mapping, not dual-pool persistence.
        put_spatial(0);
        for(integer address=0;address<1024;address=address+1)get_spatial(address,1023-address);
        for(integer address=0;address<1024;address=address+1)put_spatial(address);
        for(integer address=0;address<1024;address=address+1)get_spatial((address*13)%1024,address);
        put_linear(511,8'h81);
        for(integer address=0;address<512;address=address+1)get_linear(511-address,address);
        for(integer trial=0;trial<512;trial=trial+1)begin
            random_q=random_next(random_q);put_linear(trial,random_q[7:0] | 1);
            get_linear(trial,trial);
            hold_or_reset(trial%31==0);
            put_spatial(trial*2);
            get_spatial(trial*2,trial*2+1);
        end
        if(linear_reads!=1536 || spatial_reads!=2560 || spatial_writes!=1537 || resets!=17 || hold_checks!=1536)
            $fatal(1,"wrong overlay unit coverage");
        $display("C1_R2_OVERLAY_RAM_PASS linear_reads=%0d spatial_reads=%0d linear_word_writes=%0d spatial_writes=%0d resets=%0d hold_checks=%0d byte_capacity=16384 read_latency=1 alias_mapping_checked=1",linear_reads,spatial_reads,linear_writes,spatial_writes,resets,hold_checks);
        $finish;
    end
    initial begin repeat(40000)@(posedge clk);$fatal(1,"overlay RAM timeout");end
endmodule
