`timescale 1ns/1ps
module tb_c1_dot8x8_requant_overlap #(parameter integer TREE=0);
    logic clk=0;always #5 clk=~clk;
    logic rst=1,sv=0,sr,iv=0,ir,last=0,ov,orr=0,busy,overflow;
    logic [255:0] bias='0;
    logic [143:0] mult='0;
    logic [47:0] shift='0;
    logic relu=0,sof=0,eol=0,eof=0;
    logic [15:0] x=0,y=0,ox,oy;
    logic os,ol,oe;
    logic [7:0] mask=0;
    logic [63:0] act=0,data;
    logic [511:0] weights=0;
    logic hold_results=1;
    integer cycle=0,head=0,tail=0,accepted=0,retired=0,peak=0,early=0,held_cycles=0,start_stalls=0;
    logic [98:0] expected[0:255];
    bit expected_overflow[0:255];
    logic out_held=0,start_held=0,input_held=0;
    logic [98:0] held_out;
    logic [483:0] held_start;
    logic [584:0] held_input;
    c1_dot8x8_requant_core #(.X_BITS(16),.Y_BITS(16),
        .PIPELINED_DOT_TREE(TREE==1),.PIPELINED_DOT_TREE_FULL(TREE==2),
        .OVERLAP_REQUANTIZATION(1)) dut (
        .clk,.rst,.start_valid(sv),.start_ready(sr),.start_bias_s32(bias),
        .start_mult_s18(mult),.start_shift_u6(shift),.start_relu(relu),
        .start_sof(sof),.start_eol(eol),.start_eof(eof),.start_x(x),.start_y(y),
        .in_valid(iv),.in_ready(ir),.in_last(last),.in_lane_mask(mask),
        .in_activations_s8(act),.in_weights_s8(weights),.out_valid(ov),.out_ready(orr),
        .out_data_s8(data),.out_sof(os),.out_eol(ol),.out_eof(oe),.out_x(ox),.out_y(oy),
        .busy,.overflow_seen(overflow));
    function automatic integer aval(input integer t,g,i); aval=(t*3+g*5+i*7)%31-15;endfunction
    function automatic integer wval(input integer t,g,o,i); wval=(t+g*3+o*5+i*2)%17-8;endfunction
    function automatic integer bval(input integer t,o);bval=(t%17==0)?32'h7fffffe0:(t*17+o*31)%2001-1000;endfunction
    function automatic integer mval(input integer t,o);
        mval=(t%13==0)?131071:((t%13==1)?-131072:(t+o)%7-3);
    endfunction
    function automatic integer sval(input integer t,o);sval=((t+o)%11==0)?47:(t+o)%8;endfunction
    function automatic logic [7:0] quant(input integer acc,m,s,input bit r);
        longint signed p,v,mag;
        begin
            p=acc;p=p*m;mag=p<0?-p:p;
            if(s>0)mag=(mag+(64'sd1<<(s-1)))>>>s;
            v=p<0?-mag:mag;
            if(v>127)v=127;if(v< -128)v=-128;if(r && v<0)v=0;
            quant=v[7:0];
        end
    endfunction
    task automatic send_dot(input integer t);
        integer g,o,i,groups,lanes,acc;
        longint signed next_acc;
        logic [63:0] answer;
        bit wraps;
        begin
            groups=1+t%5;lanes=1+t%8;wraps=0;answer=0;
            @(negedge clk);
            for(o=0;o<8;o++) begin
                bias[o*32+:32]=bval(t,o);mult[o*18+:18]=mval(t,o);shift[o*6+:6]=sval(t,o);
                acc=bval(t,o);
                for(g=0;g<groups;g++) begin
                    next_acc=acc;
                    for(i=0;i<8;i++)if(g!=groups-1 || i<lanes)next_acc+=aval(t,g,i)*wval(t,g,o,i);
                    if(next_acc>2147483647 || next_acc< -2147483648)wraps=1;
                    acc=next_acc;
                end
                answer[o*8+:8]=quant(acc,mval(t,o),sval(t,o),t%2);
            end
            relu=t%2;sof=t%5==0;eol=t%7==0;eof=t%11==0;x=t*3+5;y=t*7+1;
            expected[tail]={answer,sof,eol,eof,x,y};expected_overflow[tail]=wraps;tail++;
            sv=1;do @(posedge clk);while(!sr);
            @(negedge clk);sv=0;
            for(g=0;g<groups;g++) begin
                if((t+g)%3==0)repeat(2)@(negedge clk);
                mask=(g==groups-1)?(8'hff>>(8-lanes)):8'hff;last=g==groups-1;
                for(i=0;i<8;i++)act[i*8+:8]=aval(t,g,i);
                for(o=0;o<8;o++)for(i=0;i<8;i++)weights[o*64+i*8+:8]=wval(t,g,o,i);
                iv=1;do @(posedge clk);while(!ir);
                @(negedge clk);iv=0;
            end
        end
    endtask
    always @(negedge clk) orr=!rst && !hold_results && cycle%23<15 && cycle%7!=2;
    always @(posedge clk) begin
        cycle++;
        if(rst) begin
            head=0;tail=0;accepted=0;retired=0;peak=0;early=0;held_cycles=0;start_stalls=0;
            out_held=0;start_held=0;input_held=0;
        end else begin
            if(out_held && (!ov || {data,os,ol,oe,ox,oy}!==held_out))$fatal(1,"overlapped output changed while held");
            if(start_held && (!sv || {bias,mult,shift,relu,sof,eol,eof,x,y}!==held_start))$fatal(1,"overlapped START changed while held");
            if(input_held && (!iv || {act,weights,mask,last}!==held_input))$fatal(1,"overlapped input changed while held");
            out_held=ov&&!orr;held_out={data,os,ol,oe,ox,oy};
            start_held=sv&&!sr;held_start={bias,mult,shift,relu,sof,eol,eof,x,y};
            input_held=iv&&!ir;held_input={act,weights,mask,last};
            if(out_held)held_cycles++;if(start_held)start_stalls++;
            if(sv&&sr)begin if(accepted>retired)early++;accepted++;end
            if(ov&&orr)begin
                if(head>=tail || {data,os,ol,oe,ox,oy}!==expected[head])
                    $fatal(1,"overlapped data/config/order mismatch item=%0d",head);
                if(expected_overflow[head] && !overflow)$fatal(1,"overlapped overflow witness lost");
                head++;retired++;
            end
            if(accepted-retired>peak)peak=accepted-retired;
            if(accepted-retired>6)$fatal(1,"overlapped core exceeded bounded storage");
        end
    end
    initial begin
        repeat(6)@(negedge clk);rst=0;
        for(integer t=0;t<6;t++)send_dot(t);
        repeat(20)@(negedge clk);
        if(!busy || sr || !ov || accepted!=6 || retired!=0 || dut.transactions_pending_q!=6)
            $fatal(1,"did not saturate five requant slots plus active dot");
        sv=1;
        repeat(10)@(negedge clk);
        if(sr || start_stalls<10)$fatal(1,"full requant pipeline did not fence new START");
        rst=1;sv=0;iv=0;repeat(3)@(negedge clk);rst=0;
        repeat(3)@(negedge clk);
        if(busy || ov || !sr)$fatal(1,"canceled requant transactions leaked after reset");
        $display("C1_DOT_REQUANT_RESET_PASS discarded=6");
        // Saturate again, then release backpressure with a seventh START
        // already held. Unlike the cancellation above, all six old results
        // must now retire exactly once with their original affine metadata.
        for(integer t=0;t<6;t++)send_dot(t);
        repeat(20)@(negedge clk);
        if(!busy || sr || !ov || accepted!=6 || retired!=0)
            $fatal(1,"full-pipeline drain was not exercised at capacity");
        fork
            send_dot(6);
            begin repeat(10)@(negedge clk);hold_results=0;end
        join
        for(integer t=7;t<160;t++)send_dot(t);
        wait(retired==160);repeat(3)@(negedge clk);
        if(busy || ov || !sr || peak!=6 || early==0 || held_cycles==0 || start_stalls<10)
            $fatal(1,"requant overlap or final drain untested");
        $display("C1_DOT_REQUANT_FULL_DRAIN_PASS outputs=160 peak=6");
        $display("C1_DOT_REQUANT_OVERLAP_PASS tree=%0d outputs=%0d early_starts=%0d peak=%0d held=%0d",TREE,retired,early,peak,held_cycles);
        $finish;
    end
    initial begin #2000000;$fatal(1,"requant overlap timeout");end
endmodule
