`timescale 1ns/1ps
// C35 actual DW packet sink -> partition SRAM -> PW operand feeder test.
// Arithmetic/DDR are outside this component's scope. The retained feeder
// runs in parallel against an independent mathematical INPUT source.
module tb_c1_r2_pw_shadow_feeder;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start_valid=0,baseline_enable=1,start_shadow=0,finish=0;
    reg [13:0] start_count=0;
    reg [5:0] start_channels=16,start_outputs=8;
    reg [8:0] start_shadow_base=0;
    reg start_linear=0,req_ready=0;
    wire start_ready,busy,feature_rd_en,weight_read_en,req_valid,req_first,req_last;
    wire [17:0] feature_rd_addr;
    wire [255:0] feature_data;
    wire [7:0] unused_we;
    wire [71:0] unused_wa;
    wire [255:0] unused_wd;
    wire [47:0] weight_read_addr;
    wire [53:0] weight_lane_addr;
    reg [767:0] weight_data;
    reg [255:0] bias_data;
    reg [199:0] affine_data;
    wire [5:0] req_mask,req_relu;
    wire [15:0] req_tag;
    wire [767:0] req_a,req_b;
    wire [191:0] req_bias;
    wire [107:0] req_mult;
    wire [35:0] req_shift;
    wire old_ready,old_busy,old_read,old_valid,old_first,old_last,old_weight_en;
    wire [17:0] old_address;
    reg [255:0] old_data;
    wire [47:0] old_weight_addr;
    wire [53:0] old_lane_addr;
    wire [5:0] old_mask,old_relu;
    wire [15:0] old_tag;
    wire [767:0] old_a,old_b;
    wire [191:0] old_bias;
    wire [107:0] old_mult;
    wire [35:0] old_shift;
    c1_r2_pw_shadow_feeder dut(
        .clk(clk),.rst(rst),.load_valid(1'b0),.load_ready(),.load_addr(12'd0),.load_data(32'd0),
        .bulk_en(1'b0),.bulk_residual(1'b0),.bulk_residual_b(1'b0),.bulk_pair(10'd0),
        .bulk_group(3'd0),.bulk_groups(3'd2),.bulk_data(128'd0),
        .start_valid(start_valid),.start_ready(start_ready),.start_count(start_count),
        .start_channels(start_channels),.start_outputs(start_outputs),.start_linear(start_linear),
        .start_shadow(start_shadow),.start_shadow_base(start_shadow_base),.finish(finish),.busy(busy),
        .feature_rd_en(feature_rd_en),.feature_rd_addr(feature_rd_addr),.feature_data(feature_data),
        .feature_wr_en(unused_we),.feature_wr_addr(unused_wa),.feature_wr_data(unused_wd),
        .weight_read_en(weight_read_en),.weight_read_addr(weight_read_addr),.weight_lane_addr(weight_lane_addr),
        .weight_data(weight_data),.bias_data(bias_data),.affine_data(affine_data),
        .req_valid(req_valid),.req_ready(req_ready),.req_first(req_first),.req_last(req_last),
        .req_mask(req_mask),.req_tag(req_tag),.req_a(req_a),.req_b(req_b),.req_bias(req_bias),
        .req_mult(req_mult),.req_shift(req_shift),.req_relu(req_relu)
    );
    c1_r2_pw_overlay_feeder reference_feeder(
        .clk(clk),.rst(rst),.load_valid(1'b0),.load_ready(),.load_addr(12'd0),.load_data(32'd0),
        .bulk_en(1'b0),.bulk_residual(1'b0),.bulk_residual_b(1'b0),.bulk_pair(10'd0),
        .bulk_group(3'd0),.bulk_groups(3'd2),.bulk_data(128'd0),
        .start_valid(start_valid && baseline_enable),.start_ready(old_ready),.start_count(start_count),
        .start_channels(start_channels),.start_outputs(start_outputs),.start_linear(start_linear),.finish(finish),.busy(old_busy),
        .feature_rd_en(old_read),.feature_rd_addr(old_address),.feature_data(old_data),
        .feature_wr_en(),.feature_wr_addr(),.feature_wr_data(),
        .weight_read_en(old_weight_en),.weight_read_addr(old_weight_addr),.weight_lane_addr(old_lane_addr),
        .weight_data(weight_data),.bias_data(bias_data),.affine_data(affine_data),
        .req_valid(old_valid),.req_ready(req_ready),.req_first(old_first),.req_last(old_last),
        .req_mask(old_mask),.req_tag(old_tag),.req_a(old_a),.req_b(old_b),.req_bias(old_bias),
        .req_mult(old_mult),.req_shift(old_shift),.req_relu(old_relu)
    );
    reg partition_en=0,spatial_rd_en=0,spatial_wr_en=0;
    reg [8:0] partition_base=1;
    reg [9:0] partition_end=3,spatial_wr_addr=0;
    reg [19:0] spatial_rd_addr=0;
    reg [127:0] spatial_wr_data=0;
    wire [127:0] spatial_rd_data;
    reg [7:0] manual_we=0;
    reg [71:0] manual_wa=0;
    reg [255:0] manual_wd=0;
    reg sink_start=0,sink_valid=0,sink_last=0;
    reg [10:0] sink_width=0;
    reg [47:0] sink_packet=0;
    reg [5:0] sink_mask=0;
    reg [15:0] sink_index=0;
    wire sink_start_ready,sink_ready,sink_busy,sink_done,sink_error,sink_row_valid;
    wire [7:0] sink_we;
    wire [71:0] sink_wa;
    wire [255:0] sink_wd;
    c1_r2_dw16_row_shadow_writer sink(
        .clk(clk),.rst(rst),.abort(1'b0),.start_valid(sink_start),.start_ready(sink_start_ready),
        .start_width(sink_width),.start_base(partition_base),.write_enable(1'b1),
        .in_valid(sink_valid),.in_ready(sink_ready),.in_data(sink_packet),.in_mask(sink_mask),
        .in_index(sink_index),.in_last(sink_last),.linear_wr_en(sink_we),.linear_wr_addr(sink_wa),
        .linear_wr_data(sink_wd),.busy(sink_busy),.done(sink_done),.error(sink_error),.row_valid(sink_row_valid)
    );
    c1_r2_partitioned_feature_ram ram(
        .clk(clk),.rst(rst),.partition_en(partition_en),.partition_base(partition_base),.partition_end(partition_end),
        .linear_rd_en(feature_rd_en),.linear_rd_addr(feature_rd_addr),.linear_rd_data(feature_data),
        .linear_wr_en(sink_we|manual_we),.linear_wr_addr(|manual_we ? manual_wa : sink_wa),
        .linear_wr_data(|manual_we ? manual_wd : sink_wd),.spatial_rd_en(spatial_rd_en),
        .spatial_rd_addr(spatial_rd_addr),.spatial_rd_data(spatial_rd_data),.spatial_wr_en(spatial_wr_en),
        .spatial_wr_addr(spatial_wr_addr),.spatial_wr_data(spatial_wr_data)
    );
    integer width_cfg=0,ci_cfg=16,co_cfg=8,chunks_cfg=1,seed_cfg=0;
    integer total_requests=0,active_vectors=0,stall_checks=0,clamp_reads=0,cycles=0;
    integer complete_rows=0,cancelled_rows=0,rejected=0,accepted=0,next_tag=0,next_k=0;
    reg testing=0,stalled_q=0;
    reg [1901:0] held_request;
    wire [1901:0] request={req_first,req_last,req_mask,req_tag,req_bias,req_a,req_b,req_mult,req_shift,req_relu};
    function automatic [7:0] value_byte(input integer pixel,channel,seed);
        value_byte=(pixel*37+channel*19+seed*11)&255;
    endfunction
    function automatic [31:0] source_word(input integer parity,address,word_id);
        source_word=32'h908f2137 ^ (parity*32'h89136245) ^ (address*32'h17030501) ^ (word_id*32'h473ad321);
    endfunction
    // The baseline sees mathematical input bytes, not DUT outputs or a
    // golden intermediate substituted into a complete CNN graph.
    always @(posedge clk)if(!rst && old_read)begin
        for(integer p=0;p<2;p=p+1)for(integer c=0;c<16;c=c+1)
            old_data[p*128+c*8+:8]<=value_byte((old_address[p*9+:9]/chunks_cfg)*2+p,
                                             (old_address[p*9+:9]%chunks_cfg)*16+c,seed_cfg);
    end
    always @(posedge clk)begin : operand_scoreboard
        integer scalar,pixel,channel,expected_mask,expected_addr;
        if(rst)stalled_q=0;
        else if(testing)begin
            if(req_valid!==old_valid || feature_rd_en!==old_read || weight_read_en!==old_weight_en || busy!==old_busy)
                $fatal(1,"PW candidate changed retained schedule");
            if(feature_rd_en)begin
                if(weight_lane_addr!==old_lane_addr || weight_read_addr!==old_weight_addr)
                    $fatal(1,"PW candidate changed parameter address");
                for(integer p=0;p<2;p=p+1)begin
                    expected_addr=old_address[p*9+:9];
                    if(partition_en)begin
                        if(expected_addr>=width_cfg/2)begin expected_addr=width_cfg/2-1;clamp_reads=clamp_reads+1;end
                        expected_addr=expected_addr+partition_base;
                    end
                    if(feature_rd_addr[p*9+:9]!==9'(expected_addr))$fatal(1,"PW shadow base/tail mapping mismatch");
                end
            end
            if(stalled_q)begin
                if(!req_valid || request!==held_request)$fatal(1,"PW request changed under backpressure");
                stall_checks=stall_checks+1;
            end
            stalled_q=req_valid && !req_ready;
            if(stalled_q)held_request=request;
            if(req_valid && req_ready)begin
                if(req_tag!=next_tag || req_first!=(next_k==0) || req_last!=(next_k==chunks_cfg-1))
                    $fatal(1,"PW request tag/beat sequence mismatch");
                expected_mask=(1<<((width_cfg*co_cfg-next_tag)<6 ? width_cfg*co_cfg-next_tag : 6))-1;
                if(req_mask!=expected_mask || {req_first,req_last,req_mask,req_tag,req_b,req_bias,req_mult,req_shift,req_relu}!==
                    {old_first,old_last,old_mask,old_tag,old_b,old_bias,old_mult,old_shift,old_relu})
                    $fatal(1,"PW candidate changed parameter/packet metadata");
                for(integer lane=0;lane<6;lane=lane+1)if(req_mask[lane])begin
                    scalar=next_tag+lane;pixel=scalar/co_cfg;
                    for(integer c=0;c<16;c=c+1)begin
                        if(req_a[lane*128+c*8+:8]!==((next_k*16+c)>=ci_cfg ? 8'd0 : value_byte(pixel,next_k*16+c,seed_cfg)))
                            $fatal(1,"PW actual shadow operand mismatch tag=%0d lane=%0d k=%0d c=%0d",next_tag,lane,next_k,c);
                    end
                    if(req_a[lane*128+:128]!==old_a[lane*128+:128])$fatal(1,"PW active operands differ from retained feeder");
                    active_vectors=active_vectors+1;
                end
                if(next_k==chunks_cfg-1)begin next_tag=next_tag+6;next_k=0;end else next_k=next_k+1;
                accepted=accepted+1;total_requests=total_requests+1;
            end
        end else stalled_q=0;
        cycles=cycles+1;
    end
    task tick;begin @(posedge clk);#2;end endtask
    task idle;
        begin start_valid=0;finish=0;req_ready=0;sink_start=0;sink_valid=0;manual_we=0;spatial_rd_en=0;spatial_wr_en=0;end
    endtask
    task prepare(input integer width,ci,co,seed,input bit shadow);
        integer pairs,pair,group_id,phase,flat,address;
        begin
            @(negedge clk);idle;testing=0;partition_en=0;tick;
            width_cfg=width;ci_cfg=ci;co_cfg=co;chunks_cfg=(ci+15)/16;seed_cfg=seed;
            if(shadow)begin
                @(negedge clk);partition_en=1;partition_base=width/4;partition_end=width*3/4;tick;
                for(integer a=0;a<width/2;a=a+1)begin
                    @(negedge clk);idle;spatial_wr_en=1;spatial_wr_addr=a;
                    for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)
                        spatial_wr_data[p*64+w*32+:32]=source_word(p,a,w);
                    tick;
                end
                @(negedge clk);idle;sink_start=1;sink_width=width;
                #1;if(!sink_start_ready)$fatal(1,"DW source sink start rejected");tick;
                for(integer packet=0;packet<width*3;packet=packet+1)begin
                    pair=packet/6;group_id=(packet%6)/3;phase=packet%3;
                    @(negedge clk);idle;sink_valid=1;sink_index=pair*64+group_id*4+phase;
                    sink_mask=phase==2 ? 15 : 63;sink_last=packet==width*3-1;
                    for(integer lane=0;lane<6;lane=lane+1)begin
                        flat=phase*6+lane;
                        sink_packet[lane*8+:8]=flat<16 ? value_byte(pair*2+flat/8,group_id*8+flat%8,seed) : 8'ha5;
                    end
                    spatial_rd_en=1;spatial_rd_addr={10'(packet%(width/2)),10'((packet*7)%(width/2))};
                    #1;if(!sink_ready)$fatal(1,"DW source sink backpressure unexpected");tick;
                end
                if(!sink_done || sink_error || !sink_row_valid)$fatal(1,"DW row not actually published");
            end else begin
                // Fallback includes Cin24's poisoned upper tail bytes. The
                // retained feeder must mask those lanes, not rely on zero RAM.
                for(integer a=0;a<((width+1)/2)*chunks_cfg;a=a+1)begin
                    @(negedge clk);idle;manual_we=255;manual_wa={8{9'(a)}};
                    for(integer p=0;p<2;p=p+1)for(integer c=0;c<16;c=c+1)
                        manual_wd[p*128+c*8+:8]=value_byte((a/chunks_cfg)*2+p,(a%chunks_cfg)*16+c,seed);
                    tick;
                end
            end
            @(negedge clk);idle;start_count=width;start_channels=ci;start_outputs=co;
            start_shadow=shadow;start_shadow_base=shadow ? partition_base : 9'd491;
            start_valid=1;start_linear=0;baseline_enable=1;
            #1;if(!start_ready || !old_ready)$fatal(1,"PW valid start rejected");
            accepted=0;next_tag=0;next_k=0;testing=1;tick;
            @(negedge clk);idle;
            // Change live pins after admission: the in-flight request must
            // use latched configuration, not the latest CSR-like input.
            start_shadow_base=511;start_count=4;start_shadow=!shadow;
        end
    endtask
    task run_row(input integer width,ci,co,seed,input bit shadow,input integer cancel_after);
        integer guard,expected_requests;
        begin
            prepare(width,ci,co,seed,shadow);
            expected_requests=((width*co+5)/6)*((ci+15)/16);guard=0;
            while(accepted<expected_requests && (cancel_after==0 || accepted<cancel_after))begin
                @(negedge clk);req_ready=(guard%7!=1 && guard%7!=2 && guard%11!=5);tick;guard=guard+1;
                if(guard>50000)$fatal(1,"PW progress timeout");
            end
            if(cancel_after!=0)begin
                @(negedge clk);idle;rst=1;tick;
                if(busy || old_busy || req_valid || old_valid)$fatal(1,"PW reset left pending request");
                @(negedge clk);rst=0;testing=0;tick;cancelled_rows=cancelled_rows+1;
            end else begin
                @(negedge clk);idle;finish=1;tick;
                if(busy || old_busy || req_valid || old_valid)$fatal(1,"PW finish did not drain");
                @(negedge clk);idle;testing=0;tick;complete_rows=complete_rows+1;
            end
            if(shadow)for(integer a=0;a<width/2;a=a+1)begin
                @(negedge clk);idle;spatial_rd_en=1;spatial_rd_addr={10'(width/2-1-a),10'(a)};tick;
                for(integer p=0;p<2;p=p+1)for(integer w=0;w<2;w=w+1)
                    if(spatial_rd_data[p*64+w*32+:32]!==source_word(p,p ? width/2-1-a : a,w))
                        $fatal(1,"PW read path damaged protected DW input");
            end
            @(negedge clk);idle;tick;
        end
    endtask
    initial begin
        for(integer lane=0;lane<6;lane=lane+1)weight_data[lane*128+:128]={16{8'(lane*13+3)}};
        for(integer bank=0;bank<8;bank=bank+1)begin
            bias_data[bank*32+:32]=32'h19723100+bank;
            affine_data[bank*25+:25]={1'b1,6'(bank),18'(bank+1)};
        end
        repeat(3)@(negedge clk);rst=0;
        run_row(4,16,8,1,1,0);run_row(12,16,8,2,1,0);
        run_row(32,16,8,3,1,0);run_row(640,16,8,4,1,0);
        run_row(12,16,8,5,1,3);run_row(12,16,8,6,1,0);
        run_row(12,16,8,7,0,0);run_row(12,24,24,8,0,0);
        run_row(12,48,48,9,0,0);run_row(32,16,48,10,0,0);
        run_row(340,48,8,11,0,0);
        // Invalid shadow-specific admission cannot start or read either RAM.
        @(negedge clk);idle;partition_en=0;baseline_enable=0;start_shadow=1;
        for(integer kind=0;kind<7;kind=kind+1)begin
            @(negedge clk);start_count=12;start_channels=16;start_outputs=8;start_shadow_base=3;start_linear=0;start_valid=1;
            case(kind)
                0:start_count=0;
                1:start_count=14;
                2:start_channels=24;
                3:start_outputs=16;
                4:start_linear=1;
                5:start_shadow_base=2;
                6:begin start_count=640;start_shadow_base=193;end
            endcase
            #1;if(start_ready)$fatal(1,"invalid shadow shape admitted");tick;
            if(busy || feature_rd_en || req_valid)$fatal(1,"invalid shadow start changed state");rejected=rejected+1;
        end
        @(negedge clk);idle;tick;
        if(complete_rows!=10 || cancelled_rows!=1 || rejected!=7 || clamp_reads!=7 ||
           stall_checks<100 || active_vectors!=17714 || total_requests!=2956)
            $fatal(1,"PW shadow coverage insufficient rows=%0d clamps=%0d vectors=%0d",complete_rows,clamp_reads,active_vectors);
        $display("C35_PW_SHADOW_FEEDER_PASS complete_rows=%0d cancelled_rows=%0d rejected=%0d requests=%0d active_vectors=%0d stall_checks=%0d clamp_reads=%0d retained_schedule_checked=1 actual_DW_packet_RAM_source=1",complete_rows,cancelled_rows,rejected,total_requests,active_vectors,stall_checks,clamp_reads);
        $finish;
    end
    initial begin repeat(100000)@(posedge clk);$fatal(1,"PW shadow test timeout");end
endmodule
