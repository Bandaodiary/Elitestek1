`timescale 1ns/1ps
module tb_c37_indexed_compute;
    parameter integer MAX_CHANNELS=24,NEGATIVE=0;
    reg clk=0,rst=1,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    reg in_first=0,in_last=0,in_residual=0;
    reg [5:0] in_mask=0;
    reg [15:0] in_tag=0;
    reg [767:0] in_a=0,in_b=0;
    reg [191:0] in_bias=0;
    reg [35:0] in_channels=0;
    reg [MAX_CHANNELS*25-1:0] affine_table=0;
    wire in_ready,out_valid,busy;
    wire [47:0] out_data;
    wire [5:0] out_mask;
    wire [15:0] out_tag;
    c37_compute6_indexed #(.MAX_CHANNELS(MAX_CHANNELS)) dut(.*);
    wire ref_ready,ref_valid,ref_busy;
    wire [47:0] ref_data;wire [5:0] ref_mask;wire [15:0] ref_tag;
    c37_compute6_indexed_v1 #(.MAX_CHANNELS(MAX_CHANNELS)) retained(
        .in_ready(ref_ready),.out_valid(ref_valid),.busy(ref_busy),
        .out_data(ref_data),.out_mask(ref_mask),.out_tag(ref_tag),.*);
    reg [69:0] expected[0:511];
    reg signed [31:0] accumulated[0:5];
    reg [69:0] held_payload;
    reg held=0;
    integer pushed=0,popped=0,checked=0,cycles=0,held_cycles=0,reset_count=0;
    integer epoch,t,k,r,lane,channel,term,terms;
    reg [47:0] expected_data;
    reg [24:0] q;
    reg signed [31:0] aa,bb;
    function automatic [31:0] bias_value(input integer channel_id);
        case(channel_id%6)
            0:bias_value=32'h80000000;
            1:bias_value=32'h7fffffff;
            2:bias_value=-129;
            3:bias_value=127;
            4:bias_value=0;
            default:bias_value=32'h12345678;
        endcase
    endfunction
    function automatic [17:0] multiplier(input integer id);
        case(id%6)
            0:multiplier=18'h20000;
            1:multiplier=18'h1ffff;
            2:multiplier=-1;
            3:multiplier=1;
            4:multiplier=0;
            default:multiplier=65536;
        endcase
    endfunction
    // Independent signed64 quotient/remainder reference, with INT32 modular
    // accumulation performed before multiplication. No production shifter code.
    function automatic [7:0] quantize(input reg signed [31:0] acc,input [24:0] config_word);
        reg signed [63:0] product,mag,den,value;
        reg signed [17:0] mult;
        begin
            mult=config_word[17:0];product=acc;product=product*mult;
            mag=product<0 ? -product : product;
            den=64'sd1<<config_word[23:18];value=mag/den;
            if((mag%den)*2>=den)value=value+1;
            if(product<0)value=-value;
            if(value>127)value=127;if(value< -128)value=-128;
            if(config_word[24] && value<0)value=0;
            quantize=value[7:0];
        end
    endfunction
    always @(negedge clk)out_ready=!rst && cycles%31>=14;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst)begin popped=0;held=0;end
        else begin
            if(in_ready!==ref_ready || out_valid!==ref_valid || busy!==ref_busy ||
               (out_valid && {out_data,out_mask,out_tag}!=={ref_data,ref_mask,ref_tag}))
                $fatal(1,"C37 static selector changed baseline cycle/data");
            if(held && (!out_valid || {out_tag,out_mask,out_data}!==held_payload))
                $fatal(1,"C37 indexed held output changed");
            held=out_valid && !out_ready;held_payload={out_tag,out_mask,out_data};
            if(held)held_cycles=held_cycles+1;
            if(out_valid && out_ready)begin
                if(popped>=pushed || {out_tag,out_mask,out_data}!==expected[popped])
                    $fatal(1,"C37 indexed independent golden mismatch index=%0d",popped);
                popped=popped+1;checked=checked+1;
            end
        end
    end
    task beat(input integer job,beat_id,beat_count,layer);
        begin
            @(negedge clk);
            in_valid=1;in_first=beat_id==0;in_last=beat_id==beat_count-1;
            in_tag=job+layer*100;in_mask=job%5==0 ? 6'b010111 : 6'b111111;
            in_residual=job%13==0;
            for(lane=0;lane<6;lane=lane+1)begin
                channel=(job*6+lane)%MAX_CHANNELS;
                in_channels[lane*6+:6]=channel;
                in_bias[lane*32+:32]=in_residual ? 32'd0 : bias_value(channel);
                for(term=0;term<16;term=term+1)begin
                    in_a[lane*128+term*8+:8]=(job*71+lane*43+term*13+beat_id*19+layer*17);
                    in_b[lane*128+term*8+:8]=(job*17+lane*7+term*31+beat_id*67+layer*53);
                end
            end
            if(NEGATIVE==2 && job==2 && beat_id==1)in_channels[5:0]=in_channels[5:0]+1'b1;
            if(NEGATIVE==3 && job==1 && beat_id==0)in_channels[5:0]=MAX_CHANNELS;
            @(posedge clk);while(!in_ready)@(posedge clk);
            for(lane=0;lane<6;lane=lane+1)begin
                if(in_first)accumulated[lane]=in_bias[lane*32+:32];
                for(term=0;term<16;term=term+1)begin
                    aa=$signed(in_a[lane*128+term*8+:8]);bb=$signed(in_b[lane*128+term*8+:8]);
                    accumulated[lane]=accumulated[lane]+aa*bb;
                end
                q=in_residual ? {1'b1,6'd0,18'd1} : affine_table[in_channels[lane*6+:6]*25+:25];
                expected_data[lane*8+:8]=in_mask[lane] ? quantize(accumulated[lane],q) : 8'd0;
            end
            if(in_last)begin expected[pushed]={in_tag,in_mask,expected_data};pushed=pushed+1;end
            if(NEGATIVE==1 && job==1 && beat_id==0)begin
                @(negedge clk);affine_table[0]=~affine_table[0];
            end
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;
        for(epoch=0;epoch<4;epoch=epoch+1)begin
            if(busy)$fatal(1,"C37 test attempted premature parameter reload");
            for(r=0;r<MAX_CHANNELS;r=r+1)begin
                affine_table[r*25+:18]=multiplier(r+epoch);
                affine_table[r*25+18+:6]=(r+epoch*12)%48;
                affine_table[r*25+24]=r%2;
            end
            for(t=0;t<96;t=t+1)begin
                terms=t%3==0 ? 1 : t%3==1 ? 2 : 7;
                for(k=0;k<terms;k=k+1)beat(t,k,terms,epoch);
            end
            @(negedge clk);in_valid=0;
            wait(popped==pushed);@(negedge clk);
            if(busy)$fatal(1,"C37 indexed busy after full drain");
            if(epoch==1)begin
                // Abort a genuine partial 7-beat reduction, then reload a
                // different affine table and verify the complete next epoch.
                for(k=0;k<3;k=k+1)beat(97,k,7,epoch);
                if(!busy)$fatal(1,"C37 indexed reset did not interrupt actual work");
                @(negedge clk);in_valid=0;rst=1;reset_count=reset_count+1;
                repeat(3)@(negedge clk);pushed=0;rst=0;
            end
        end
        if(checked!=384 || reset_count!=1 || held_cycles<100)$fatal(1,"C37 indexed coverage missing");
        $display("C37_INDEXED_COMPUTE_PASS channels=%0d transactions=%0d shifts=48 layers=4 partial_resets=%0d held=%0d",MAX_CHANNELS,checked,reset_count,held_cycles);
        $finish;
    end
    initial begin #5000000;$fatal(1,"C37 indexed timeout");end
endmodule
