`timescale 1ns/1ps
// C35 storage/packet component test. No CNN arithmetic, AXI or fps claim.
module tb_c1_r2_dw16_row_shadow;
    parameter integer NEGATIVE=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,abort=0,start_valid=0,write_enable=0,in_valid=0,in_last=0;
    reg [10:0] start_width=0;
    reg [8:0] start_base=0;
    reg [47:0] in_data=0;
    reg [5:0] in_mask=0;
    reg [15:0] in_index=0;
    wire start_ready,in_ready,busy,done,error,row_valid;
    wire [7:0] sink_we;
    wire [71:0] sink_addr;
    wire [255:0] sink_data;
    reg partition_en=0,linear_rd_en=0,spatial_rd_en=0,spatial_wr_en=0;
    reg [8:0] partition_base=1;
    reg [9:0] partition_end=3;
    reg [17:0] linear_rd_addr=0;
    reg [19:0] spatial_rd_addr=0;
    reg [7:0] manual_we=0;
    reg [71:0] manual_addr=0;
    reg [255:0] manual_data=0;
    reg [9:0] spatial_wr_addr=0;
    reg [127:0] spatial_wr_data=0;
    wire [7:0] linear_wr_en=manual_we|sink_we;
    wire [71:0] linear_wr_addr=|manual_we ? manual_addr : sink_addr;
    wire [255:0] linear_wr_data=|manual_we ? manual_data : sink_data;
    wire [255:0] linear_rd_data;
    wire [127:0] spatial_rd_data;
    c1_r2_partitioned_feature_ram ram(.*);
    c1_r2_dw16_row_shadow_writer sink(
        .clk(clk),.rst(rst),.abort(abort),.start_valid(start_valid),.start_ready(start_ready),
        .start_width(start_width),.start_base(start_base),.write_enable(write_enable),
        .in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),.in_mask(in_mask),
        .in_index(in_index),.in_last(in_last),.linear_wr_en(sink_we),
        .linear_wr_addr(sink_addr),.linear_wr_data(sink_data),.busy(busy),.done(done),.error(error),.row_valid(row_valid)
    );
    // Reference storage uses integer word coordinates, with known-byte
    // ownership. It observes only actual writes, never feeds the DUT reads.
    reg [31:0] memory[0:4095];
    bit known[0:4095];
    reg [255:0] expect_linear;
    reg [127:0] expect_spatial;
    reg [383:0] before_outputs;
    integer linear_reads=0,spatial_reads=0,word_writes=0,cross_cycles=0,hold_checks=0;
    integer rows=0,packets=0,stall_cycles=0,protocol_cases=0,aborts=0,resets=0;
    integer packet_word_checks=0,cycle=0;
    function automatic integer spatial_offset(input integer parity,address,word_id);
        spatial_offset=(parity*4+(address%2)*2+word_id)*512+address/2;
    endfunction
    function automatic [7:0] pixel_byte(input integer x,c,seed);
        pixel_byte=(x*37+c*19+seed*11)&255;
    endfunction
    function automatic [31:0] spatial_word(input integer parity,address,w,seed);
        spatial_word=32'h9037a5e1 ^ (parity*32'h193b1207) ^ (address*32'h07030501) ^ (w*32'h43b21d97) ^ seed;
    endfunction
    always @(posedge clk)begin : scoreboard
        integer slot,address,offset;
        bit check_l,check_s,check_hold;
        cycle=cycle+1;
        check_l=!rst && linear_rd_en;check_s=!rst && spatial_rd_en;
        check_hold=rst || (!linear_rd_en && !spatial_rd_en);
        before_outputs={linear_rd_data,spatial_rd_data};
        if(!rst && NEGATIVE==0)begin
            if(|manual_we && |sink_we)$fatal(1,"testbench two linear owners");
            if(check_l)begin
                for(integer p=0;p<2;p=p+1)for(integer w=0;w<4;w=w+1)begin
                    offset=(p*4+w)*512+linear_rd_addr[p*9+:9];
                    if(!known[offset])$fatal(1,"linear read without actual producer");
                    expect_linear[p*128+w*32+:32]=memory[offset];
                end
                linear_reads=linear_reads+1;
            end
            if(check_s)begin
                for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)begin
                    offset=spatial_offset(p,spatial_rd_addr[p*10+:10],w);
                    if(!known[offset])$fatal(1,"spatial read without actual producer");
                    expect_spatial[p*64+w*32+:32]=memory[offset];
                end
                spatial_reads=spatial_reads+1;
            end
            if((check_s && |linear_wr_en) || (check_l && spatial_wr_en))cross_cycles=cross_cycles+1;
            for(integer id=0;id<8;id=id+1)if(linear_wr_en[id])begin
                offset=id*512+linear_wr_addr[id*9+:9];
                memory[offset]=linear_wr_data[id*32+:32];known[offset]=1;word_writes=word_writes+1;
            end
            if(spatial_wr_en)for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)begin
                offset=spatial_offset(p,spatial_wr_addr,w);
                memory[offset]=spatial_wr_data[p*64+w*32+:32];known[offset]=1;
            end
        end
        #1;
        if(NEGATIVE==0)begin
            if(check_l && linear_rd_data!==expect_linear)$fatal(1,"linear RAM data/latency mismatch cycle=%0d",cycle);
            if(check_s && spatial_rd_data!==expect_spatial)$fatal(1,"spatial RAM data/latency mismatch cycle=%0d",cycle);
            if(check_hold)begin
                if({linear_rd_data,spatial_rd_data}!==before_outputs)$fatal(1,"RAM changed on idle/reset");
                hold_checks=hold_checks+1;
            end
        end
    end
    task idle;
        begin
            start_valid=0;in_valid=0;write_enable=0;in_last=0;
            linear_rd_en=0;spatial_rd_en=0;spatial_wr_en=0;manual_we=0;
        end
    endtask
    task tick;begin @(posedge clk);#2;end endtask
    task put_spatial(input integer a,seed);
        begin
            @(negedge clk);idle;spatial_wr_en=1;spatial_wr_addr=a;
            for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)
                spatial_wr_data[p*64+w*32+:32]=spatial_word(p,a,w,seed);
            tick;
        end
    endtask
    task get_spatial(input integer a,b);
        begin
            @(negedge clk);idle;spatial_rd_en=1;spatial_rd_addr={10'(b),10'(a)};tick;
        end
    endtask
    task get_linear(input integer a,b);
        begin
            @(negedge clk);idle;linear_rd_en=1;linear_rd_addr={9'(b),9'(a)};tick;
        end
    endtask
    task new_partition(input integer width,seed);
        begin
            @(negedge clk);idle;partition_en=0;tick;
            @(negedge clk);partition_en=1;partition_base=width/4;partition_end=width*3/4;tick;
            for(integer a=0;a<width/2;a=a+1)put_spatial(a,seed);
        end
    endtask
    task begin_row(input integer width,base);
        begin
            @(negedge clk);idle;start_valid=1;start_width=width;start_base=base;
            if(!start_ready)$fatal(1,"shadow row start not ready");tick;
            @(negedge clk);idle;
        end
    endtask
    // Also validates each committed 32-bit word directly against mathematical
    // pixel/channel coordinates, independently of the RAM alias scoreboard.
    task send_packet(input integer width,index,seed,bad_kind,input bit check_done);
        integer pair,group_id,phase,flat,id,x,c,delay,accepted,wc;
        reg [31:0] expected_word;
        begin
            pair=index/6;group_id=(index%6)/3;phase=index%3;
            @(negedge clk);idle;in_valid=1;
            in_index=(pair*2)*32+group_id*4+phase;
            in_mask=phase==2 ? 15 : 63;in_last=index==width*3-1;
            for(integer lane=0;lane<6;lane=lane+1)begin
                flat=phase*6+lane;
                in_data[lane*8+:8]=flat<16 ? pixel_byte(pair*2+flat/8,group_id*8+flat%8,seed) : 8'ha5;
            end
            case(bad_kind)
                1:in_index=in_index^16'h0004;
                2:in_mask=in_mask^6'h10;
                3:in_last=1;
                4:in_last=0;
            endcase
            delay=(index+seed)%4;
            if(!error)for(integer n=0;n<delay;n=n+1)begin
                write_enable=0;spatial_rd_en=1;
                spatial_rd_addr={10'((index+n+1)%(width/2)),10'((index+n)%(width/2))};
                #1;if(in_ready || |sink_we)$fatal(1,"shadow accepted a stalled packet");
                tick;stall_cycles=stall_cycles+1;@(negedge clk);
            end
            write_enable=!error;spatial_rd_en=1;
            spatial_rd_addr={10'((index*7+1)%(width/2)),10'((index*3)%(width/2))};
            #1;if(!in_ready)$fatal(1,"shadow did not accept/drain packet");
            if(bad_kind!=0 || error)begin
                if(|sink_we)$fatal(1,"bad/draining packet wrote RAM");
            end else begin
                wc=0;
                for(integer bank=0;bank<8;bank=bank+1)if(sink_we[bank])begin
                    wc=wc+1;x=pair*2+bank/4;c=(bank%4)*4;
                    for(integer b=0;b<4;b=b+1)expected_word[b*8+:8]=pixel_byte(x,c+b,seed);
                    if(sink_addr[bank*9+:9]!==9'(partition_base+pair) || sink_data[bank*32+:32]!==expected_word)
                        $fatal(1,"DW packet word mapping failed packet=%0d bank=%0d",index,bank);
                    packet_word_checks=packet_word_checks+1;
                end
                if(wc!=(phase==1 ? 2 : 1))$fatal(1,"wrong number of packet word commits");
            end
            tick;packets=packets+1;
            if(check_done && index==width*3-1 && (!done || !row_valid || busy || error))
                $fatal(1,"complete shadow row not published exactly after LAST");
        end
    endtask
    task check_row(input integer width,seed,source_seed);
        integer a,b;
        begin
            for(integer pair=0;pair<width/2;pair=pair+1)begin
                a=pair;b=width/2-1-pair;
                get_linear(partition_base+a,partition_base+b);
                for(integer p=0;p<2;p=p+1)for(integer c=0;c<16;c=c+1)
                    if(linear_rd_data[p*128+c*8+:8]!==pixel_byte((p ? b : a)*2+p,c,seed))
                        $fatal(1,"PW row shadow pixel/channel mismatch");
            end
            for(integer address=0;address<width/2;address=address+1)begin
                get_spatial(address,width/2-1-address);
                for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)
                    if(spatial_rd_data[p*64+w*32+:32]!==spatial_word(p,p ? width/2-1-address : address,w,source_seed))
                        $fatal(1,"shadow write corrupted protected DW source");
            end
            rows=rows+1;
        end
    endtask
    task good_row(input integer width,seed,source_seed);
        begin
            begin_row(width,partition_base);
            for(integer index=0;index<width*3;index=index+1)send_packet(width,index,seed,0,1);
            check_row(width,seed,source_seed);
        end
    endtask
    initial begin : stimulus
        integer width;
        repeat(3)@(negedge clk);rst=0;
        if(NEGATIVE!=0)begin
            // Each failing access is a real DUT assertion, not a fabricated
            // message or a checker-side rejection.
            @(negedge clk);idle;partition_en=1;partition_base=4;partition_end=12;tick;
            @(negedge clk);idle;
            case(NEGATIVE)
                1:begin linear_rd_en=1;spatial_rd_en=1;end
                2:begin manual_we=1;spatial_wr_en=1;end
                3:begin linear_rd_en=1;manual_we=1;end
                4:begin spatial_rd_en=1;spatial_wr_en=1;end
                5:partition_base=0;
                6:begin linear_rd_en=1;linear_rd_addr={9'd4,9'd3};end
                7:begin spatial_rd_en=1;spatial_rd_addr={10'd0,10'd8};end
                8:begin manual_we=1;manual_addr[8:0]=12;end
                9:begin spatial_wr_en=1;spatial_wr_addr=8;end
                10:partition_base=5;
                11:begin spatial_wr_en=1;tick;@(negedge clk);idle;partition_en=0;linear_rd_en=1;end
                12:begin partition_en=0;linear_rd_en=1;spatial_wr_en=1;end
                default:$fatal(1,"unknown C35 negative case");
            endcase
            repeat(3)tick;$fatal(1,"C35 invalid access not rejected");
        end
        // Full-range fallback spatial mapping, then physical alias reads.
        for(integer address=0;address<1024;address=address+1)put_spatial(address,73);
        for(integer address=0;address<1024;address=address+1)get_spatial(address,1023-address);
        @(negedge clk);idle;manual_we=8'h81;manual_addr={8{9'd511}};manual_data={8{32'h79b123e5}};tick;
        for(integer address=0;address<512;address=address+1)get_linear(address,511-address);
        for(integer test_id=0;test_id<4;test_id=test_id+1)begin
            case(test_id)0:width=4;1:width=12;2:width=32;3:width=640;endcase
            new_partition(width,100+test_id);
            good_row(width,10+test_id,100+test_id);
            // A second complete shadow row must replace every byte, without
            // refilling or modifying the still-live DW source partition.
            good_row(width,40+test_id,100+test_id);
        end
        new_partition(12,191);
        // Protocol failures drain real remaining packets, then next row works.
        for(integer kind=1;kind<=4;kind=kind+1)begin
            begin_row(12,partition_base);
            if(kind==4)begin
                for(integer index=0;index<36;index=index+1)send_packet(12,index,21,index==35 ? 4 : 0,0);
                if(!busy || !error || row_valid)$fatal(1,"missing LAST not held for drain");
                send_packet(12,35,21,0,0);
            end else begin
                for(integer index=0;index<=4;index=index+1)send_packet(12,index,21,index==4 ? kind : 0,0);
                if(kind!=3)for(integer index=5;index<36;index=index+1)send_packet(12,index,21,0,0);
            end
            if(busy || !done || !error || row_valid)$fatal(1,"malformed row incorrectly published");
            protocol_cases=protocol_cases+1;good_row(12,50+kind,191);
        end
        // Abort/reset at each assembly phase, including a near-final packet.
        for(integer point=0;point<4;point=point+1)begin
            begin_row(12,partition_base);
            for(integer index=0;index<(point==3 ? 35 : point+1);index=index+1)send_packet(12,index,67,0,0);
            @(negedge clk);idle;abort=point!=2;rst=point==2;
            in_valid=1;write_enable=1;in_last=1;tick;
            if(|sink_we || busy || row_valid || in_ready || start_ready)$fatal(1,"abort/reset failed to cancel local ownership");
            if(rst)resets=resets+1;else aborts=aborts+1;
            @(negedge clk);idle;abort=0;rst=0;tick;
            good_row(12,70+point,191);
        end
        for(integer kind=0;kind<4;kind=kind+1)begin
            case(kind)
                0:begin_row(0,3);
                1:begin_row(14,4);
                2:begin_row(640,159);
                3:begin_row(640,193);
            endcase
            if(busy || !error || row_valid)$fatal(1,"invalid row geometry accepted");
            protocol_cases=protocol_cases+1;
        end
        good_row(12,99,191);
        // Reverse cross-view access is also legal when addresses are disjoint.
        @(negedge clk);idle;linear_rd_en=1;linear_rd_addr={2{partition_base}};
        spatial_wr_en=1;spatial_wr_addr=0;spatial_wr_data=128'h12345678;tick;
        @(negedge clk);idle;tick;
        if(rows!=17 || protocol_cases!=8 || aborts!=3 || resets!=1 ||
           cross_cycles<4000 || packet_word_checks<6000 || stall_cycles<6000)
            $fatal(1,"C35 row shadow coverage incomplete rows=%0d cross=%0d words=%0d stalls=%0d",rows,cross_cycles,packet_word_checks,stall_cycles);
        $display("C35_ROW_SHADOW_PASS rows=%0d packets=%0d packet_word_checks=%0d linear_reads=%0d spatial_reads=%0d cross_cycles=%0d stall_cycles=%0d protocol_cases=%0d aborts=%0d resets=%0d byte_capacity=16384 read_latency=1 invalid_padding_poisoned=1",rows,packets,packet_word_checks,linear_reads,spatial_reads,cross_cycles,stall_cycles,protocol_cases,aborts,resets);
        $finish;
    end
    initial begin repeat(100000)@(posedge clk);$fatal(1,"C35 row shadow timeout");end
endmodule
