`timescale 1ns/1ps
module tb_c39_requant_narrow;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,in_valid=0,out_ready=0;
    wire ref_ready,dut_ready,ref_valid,dut_valid;
    reg [255:0] acc=0;
    reg [143:0] mult=0;
    reg [47:0] shift=0;
    reg [15:0] activation=0;
    reg [18:0] meta=0;
    wire [18:0] ref_meta,dut_meta;
    wire [63:0] ref_data,dut_data;
    c1_requant_bank8_compact #(.X_BITS(10),.Y_BITS(6)) reference (
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(ref_ready),
        .in_acc_s32(acc),.in_mult_s18(mult),.in_shift_u6(shift),.in_activation(activation),
        .in_sof(meta[18]),.in_eol(meta[17]),.in_eof(meta[16]),.in_x(meta[15:6]),.in_y(meta[5:0]),
        .out_valid(ref_valid),.out_ready(out_ready),.out_data_s8(ref_data),
        .out_sof(ref_meta[18]),.out_eol(ref_meta[17]),.out_eof(ref_meta[16]),.out_x(ref_meta[15:6]),.out_y(ref_meta[5:0])
    );
    c39_requant_bank8_narrow #(.X_BITS(10),.Y_BITS(6)) candidate (
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(dut_ready),
        .in_acc_s32(acc),.in_mult_s18(mult),.in_shift_u6(shift),.in_activation(activation),
        .in_sof(meta[18]),.in_eol(meta[17]),.in_eof(meta[16]),.in_x(meta[15:6]),.in_y(meta[5:0]),
        .out_valid(dut_valid),.out_ready(out_ready),.out_data_s8(dut_data),
        .out_sof(dut_meta[18]),.out_eol(dut_meta[17]),.out_eof(dut_meta[16]),.out_x(dut_meta[15:6]),.out_y(dut_meta[5:0])
    );
    function automatic [7:0] golden(input signed [31:0] a,input signed [17:0] b,input [5:0] s,input relu);
        reg signed [63:0] product;
        reg [63:0] magnitude,q;
        begin
            product=a*b;magnitude=product<0 ? -product : product;
            q=(magnitude+(s==0 ? 64'd0 : 64'd1<<(s-1)))>>s;
            if(product<0 && relu)golden=0;
            else if(product<0)golden=q>128 ? 8'h80 : 8'd0-q[7:0];
            else golden=q>127 ? 8'h7f : q[7:0];
        end
    endfunction
    reg [63:0] queue_data[0:32767];
    reg [18:0] queue_meta[0:32767];
    integer wr=0,rd=0,accepted_count=0,retired_count=0,reset_count=0,hold_count=0,ii_count=0;
    reg accepted=0,held=0;
    reg [82:0] held_payload;
    reg [47:0] seen_shifts=0;
    integer cycle;
    reg [31:0] rng=32'hc390001;
    function automatic [31:0] next_rng(input [31:0] v);
        reg [31:0] x;
        begin x=v^(v<<13);x=x^(x>>17);next_rng=x^(x<<5);end
    endfunction
    always @(posedge clk)begin
        accepted<=!rst && in_valid && ref_ready;
        if(rst)begin wr=0;rd=0;held=0;reset_count=reset_count+1;end
        else begin
            if(ref_ready!==dut_ready || ref_valid!==dut_valid)$fatal(1,"C39 requant handshake mismatch");
            if(dut_valid && {ref_meta,ref_data}!=={dut_meta,dut_data})$fatal(1,"C39 requant value mismatch");
            if(held && (!dut_valid || {dut_meta,dut_data}!==held_payload))$fatal(1,"C39 requant hold mismatch");
            if(dut_valid && !out_ready)hold_count=hold_count+1;
            held=dut_valid && !out_ready;held_payload={dut_meta,dut_data};
            if(dut_valid && out_ready)begin
                if(rd==wr || dut_data!==queue_data[rd] || dut_meta!==queue_meta[rd])$fatal(1,"C39 independent golden mismatch");
                rd=rd+1;retired_count=retired_count+1;
            end
            if(in_valid && ref_ready)begin
                for(integer c=0;c<8;c=c+1)begin
                    queue_data[wr][c*8+:8]=golden(acc[c*32+:32],mult[c*18+:18],shift[c*6+:6],activation[c*2]);
                    seen_shifts[shift[c*6+:6]]=1;
                end
                queue_meta[wr]=meta;wr=wr+1;accepted_count=accepted_count+1;
            end
            if(cycle>=12 && cycle<256)begin
                if(!ref_ready || !dut_valid)$fatal(1,"C39 requant II1 lost");
                ii_count=ii_count+1;
            end
        end
    end
    initial begin
        for(cycle=0;cycle<16000;cycle=cycle+1)begin
            @(negedge clk);
            rst=cycle<3 || cycle==5001 || cycle==9002 || cycle==13003;
            rng=next_rng(rng);
            out_ready=cycle<256 || cycle>=15900 ? 1 :
                (cycle%1000>=800 && cycle%1000<900 ? 0 : rng[0] || rng[3]);
            if(rst)in_valid=0;
            else if(accepted || !in_valid)begin
                in_valid=cycle<15900 && (cycle<256 || rng[2] || rng[7]);
                meta=rng[18:0];
                for(integer c=0;c<8;c=c+1)begin
                    rng=next_rng(rng);acc[c*32+:32]=rng;
                    rng=next_rng(rng);mult[c*18+:18]=rng[17:0];
                    shift[c*6+:6]=(cycle+c)%48;activation[c*2+:2]={1'b0,rng[22]};
                    if(cycle%4==0)begin
                        case((cycle/4+c)%8)
                            0:begin acc[c*32+:32]=32'h80000000;mult[c*18+:18]=18'h20000;end
                            1:begin acc[c*32+:32]=32'h7fffffff;mult[c*18+:18]=18'h1ffff;end
                            2:begin acc[c*32+:32]=511;mult[c*18+:18]=1;shift[c*6+:6]=1;end
                            3:begin acc[c*32+:32]=-511;mult[c*18+:18]=1;shift[c*6+:6]=1;end
                            4:begin acc[c*32+:32]=255;mult[c*18+:18]=1;shift[c*6+:6]=1;end
                            5:begin acc[c*32+:32]=-255;mult[c*18+:18]=1;shift[c*6+:6]=1;end
                            6:begin acc[c*32+:32]=0;mult[c*18+:18]=0;end
                            7:begin acc[c*32+:32]=1;mult[c*18+:18]=-1;end
                        endcase
                    end
                end
            end
        end
        @(negedge clk);
        if(wr!=rd || dut_valid || accepted_count<8000 || retired_count<8000 || hold_count<1000 || ii_count!=244 || seen_shifts!==48'hffffffffffff)
            $fatal(1,"C39 requant coverage/drain failed accepted=%0d retired=%0d pending=%0d",accepted_count,retired_count,wr-rd);
        $display("C39_REQUANT_RTL_PASS accepted=%0d retired=%0d hold_cycles=%0d reset_cycles=%0d ii1=%0d shifts=48 lanes=8 golden=1 cycle_miter=1",accepted_count,retired_count,hold_count,reset_count,ii_count);
        $finish;
    end
endmodule
