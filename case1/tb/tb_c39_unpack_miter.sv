`timescale 1ns/1ps
// Compare every output bit, including unused/default-mode bits. Not a full host test.
module tb_c39_unpack_miter;
    reg [2:0] mode;
    reg [35:0] channels;
    reg [431:0] packed_a;
    wire [767:0] candidate, reference_a;
    reg [31:0] rng=32'h347b9321;
    integer m,trial,word_id,bit_id,lane,checks=0;
    c39_operand_unpack dut(.mode(mode),.channels(channels),.packed_a(packed_a),.expanded(candidate));
    c39_operand_unpack_reference ref_dut(.mode(mode),.channels(channels),.packed_a(packed_a),.expanded(reference_a));
    task verify;
        begin
            #1;
            if(candidate!==reference_a) $fatal(1,"C39 unpack miter mismatch mode=%0d check=%0d",mode,checks);
            checks=checks+1;
        end
    endtask
    task advance;
        begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);end
    endtask
    initial begin
        for(m=0;m<8;m=m+1)begin
            mode=m;
            for(trial=0;trial<512;trial=trial+1)begin
                for(lane=0;lane<6;lane=lane+1)begin advance();channels[lane*6+:6]=rng[5:0];end
                for(word_id=0;word_id<27;word_id=word_id+1)begin advance();packed_a[word_id*16+:16]=rng[15:0];end
                verify();
            end
            // Every data bit, both PW selector sides, all default modes.
            for(bit_id=0;bit_id<432;bit_id=bit_id+1)begin
                packed_a=0;packed_a[bit_id]=1;channels=0;verify();
                channels={30'd0,6'd63};verify();
            end
            packed_a='1;channels=0;verify();
        end
        $display("C39_UNPACK_MITER_PASS checks=%0d modes=8 output_bits=768",checks);
        $finish;
    end
endmodule
