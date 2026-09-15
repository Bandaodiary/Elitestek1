`timescale 1ns/1ps
// Independent signed64 reference; no production arithmetic helper is reused.
// Every beat changes all channel kernels and affine fields. An outstanding
// batch is reset, then a different batch checks that no old metadata survives.
module tb_c1_dwconv_stream_config #(parameter bit RANDOM_STALLS=1);
    logic clk=0,rst=1; always #5 clk=~clk;
    logic start_valid=0; wire start_ready;
    logic [575:0] start_weights_s8,in_window_s8;
    logic [255:0] start_bias_s32;
    logic [143:0] start_mult_s18;
    logic [47:0] start_shift_u6;
    logic [15:0] start_activation;
    logic in_valid=0;wire in_ready;
    logic in_sof,in_eol,in_eof;logic [15:0] in_x,in_y;
    wire out_valid;logic out_ready=0;
    wire [63:0] out_data_s8;wire out_sof,out_eol,out_eof;
    wire [15:0] out_x,out_y;wire busy,done,overflow_seen;
    c1_dwconv3x3_c8_requant_core #(.PER_BEAT_CONFIG(1)) dut(.*);
    integer tx=0,rx=0,cycles=0,batch=0,target=128;
    integer input_run=0,max_input_run=0,out_stalls=0,in_stalls=0,overflows=0;
    integer done_count=0;
    integer nontrivial_lanes=0,changed_beats=0;
    bit sending=0,block_output=0;
    logic [31:0] rng=32'h09aacf61;
    logic [63:0] expected[0:511];
    logic [34:0] expected_meta[0:511];
    logic held=0; logic [98:0] held_payload;
    logic input_accepted=0,input_held=0;logic [1650:0] held_input;
    integer n,w,a,m,shift;
    always_comb begin
        start_weights_s8='0;in_window_s8='0;start_bias_s32='0;
        start_mult_s18='0;start_shift_u6='0;start_activation='0;
        n=tx+batch*977;
        for(integer lane=0;lane<8;lane++) begin
            for(integer tap=0;tap<9;tap++) begin
                w=((n*19+lane*11+tap*7)&255)-128;
                a=((n*31+lane*23+tap*13)&255)-128;
                start_weights_s8[(lane*9+tap)*8+:8]=w[7:0];
                in_window_s8[(tap*8+lane)*8+:8]=a[7:0];
            end
            case((n+lane)%4)
                0:start_bias_s32[lane*32+:32]=32'h7fffffff;
                1:start_bias_s32[lane*32+:32]=32'h80000000;
                default:start_bias_s32[lane*32+:32]=(n*41-lane*419-5000);
            endcase
            m=((n*131+lane*39)&262143)-131072;
            start_mult_s18[lane*18+:18]=m[17:0];
            case((n+lane)%7)
                0:shift=0;1:shift=1;2:shift=7;3:shift=15;
                4:shift=23;5:shift=31;default:shift=47;
            endcase
            start_shift_u6[lane*6+:6]=shift[5:0];
            start_activation[lane*2+:2]=(n+lane)%2;
        end
        in_x=tx%17;in_y=tx/17;in_sof=(tx==0);
        in_eof=(tx==target-1);in_eol=in_eof || tx%17==16;
    end
    function automatic logic [63:0] reference_word();
        longint signed total,wrapped,scaled,mag,rounded;
        integer sh;logic [63:0] word;
        begin
            word=0;
            for(integer lane=0;lane<8;lane++) begin
                total=$signed(start_bias_s32[lane*32+:32]);
                for(integer tap=0;tap<9;tap++)
                    total+=longint'($signed(in_window_s8[(tap*8+lane)*8+:8]))*
                        longint'($signed(start_weights_s8[(lane*9+tap)*8+:8]));
                wrapped=$signed(total[31:0]);
                scaled=wrapped*longint'($signed(start_mult_s18[lane*18+:18]));
                sh=start_shift_u6[lane*6+:6];mag=(scaled<0)?-scaled:scaled;
                rounded=(sh==0)?mag:((mag+(64'sd1<<(sh-1)))>>sh);
                if(scaled<0) rounded=-rounded;
                if(rounded>127)rounded=127;
                if(rounded< -128)rounded=-128;
                if(start_activation[lane*2+:2]==1 && rounded<0)rounded=0;
                word[lane*8+:8]=rounded[7:0];
            end
            reference_word=word;
        end
    endfunction
    always @(negedge clk) begin
        if(rst) begin in_valid=0;out_ready=0;end
        else begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(!in_valid || input_accepted) in_valid=sending && tx<target && (!RANDOM_STALLS || rng[3]);
            out_ready=!block_output && (!RANDOM_STALLS || (cycles%61>15 && rng[7]));
        end
    end
    always @(posedge clk) begin
        if(rst) begin tx=0;rx=0;cycles=0;held=0;done_count=0;
            nontrivial_lanes=0;changed_beats=0;
            input_accepted=0;input_held=0;
            input_run=0;max_input_run=0;out_stalls=0;in_stalls=0;overflows=0;end
        else begin
            cycles++;
            if(input_held && (!in_valid || {start_weights_s8,start_bias_s32,start_mult_s18,
                start_shift_u6,start_activation,in_window_s8,in_sof,in_eol,in_eof,in_x,in_y}!==held_input))
                $fatal(1,"DW streaming source/config changed while stalled");
            input_held=in_valid&&!in_ready;
            held_input={start_weights_s8,start_bias_s32,start_mult_s18,start_shift_u6,start_activation,
                in_window_s8,in_sof,in_eol,in_eof,in_x,in_y};
            input_accepted=in_valid&&in_ready;
            if(held && (!out_valid || {out_data_s8,out_sof,out_eol,out_eof,out_x,out_y}!==held_payload))
                $fatal(1,"DW streaming output/config changed while stalled");
            held=out_valid&&!out_ready;held_payload={out_data_s8,out_sof,out_eol,out_eof,out_x,out_y};
            if(in_valid && !in_ready)in_stalls++;
            if(out_valid && !out_ready)out_stalls++;
            if(done)done_count++;
            if(overflow_seen)overflows++;
            if(in_valid && in_ready) begin
                expected[tx]=reference_word();expected_meta[tx]={in_sof,in_eol,in_eof,in_x,in_y};
                if(tx>0 && expected[tx]!=expected[tx-1])changed_beats++;
                for(integer lane=0;lane<8;lane++)
                    if(expected[tx][lane*8+:8]!=8'h00 && expected[tx][lane*8+:8]!=8'h7f &&
                       expected[tx][lane*8+:8]!=8'h80)nontrivial_lanes++;
                tx++;input_run++;if(input_run>max_input_run)max_input_run=input_run;
            end else input_run=0;
            if(out_valid && out_ready) begin
                if(rx>=tx || out_data_s8!==expected[rx] ||
                    {out_sof,out_eol,out_eof,out_x,out_y}!==expected_meta[rx])
                    $fatal(1,"DW per-beat config mismatch index=%0d got=%h expected=%h",rx,out_data_s8,expected[rx]);
                rx++;
            end
        end
    end
    task automatic open_batch;
        begin @(negedge clk);start_valid=1;
            do @(posedge clk);while(!start_ready);
            @(negedge clk);start_valid=0;sending=1;end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;block_output=1;open_batch();
        wait(tx>=6);repeat(8)@(negedge clk);
        if(!busy || !out_valid || rx!=0 || tx==0)$fatal(1,"DW cancel did not contain held in-flight metadata");
        sending=0;rst=1;repeat(3)@(negedge clk);
        batch=1;target=257;block_output=0;rst=0;
        @(negedge clk);
        if(out_valid || busy || done || !start_ready)$fatal(1,"DW canceled pipeline not empty");
        open_batch();wait(rx==target);sending=0;repeat(5)@(negedge clk);
        if(busy || !start_ready || tx!=target || done_count!=1 || overflows==0)
            $fatal(1,"DW streaming retirement/overflow coverage failed");
        if(RANDOM_STALLS && (out_stalls==0 || in_stalls==0))$fatal(1,"DW stalls not exercised");
        if(!RANDOM_STALLS && max_input_run<32)$fatal(1,"DW streaming did not sustain one beat per cycle");
        if(nontrivial_lanes<64 || changed_beats<128)$fatal(1,"DW golden lacks nonconstant/non-saturated witnesses");
        $display("C1_DW_STREAM_CONFIG_PASS random=%0d beats=%0d max_input_run=%0d in_stalls=%0d out_stalls=%0d reset_pending=1 changed_config=1",RANDOM_STALLS,rx,max_input_run,in_stalls,out_stalls);
        $display("C1_DW_STREAM_WITNESS_PASS nontrivial_lanes=%0d changed_beats=%0d",nontrivial_lanes,changed_beats);
        $finish;
    end
    initial begin #1000000;$fatal(1,"DW streaming test timeout");end
endmodule
