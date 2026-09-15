`timescale 1ns/1ps
// Independent legal operand construction. No CNN feeder or inverse-codec golden.
module tb_c39_operand_codec;
    reg [2:0] mode;
    reg [767:0] source_a;
    reg [35:0] channels;
    reg [431:0] expected_payload;
    wire [431:0] packed_a;
    wire [767:0] restored;
    reg [127:0] first_pixel, second_pixel;
    reg [31:0] rng=32'h174592ab;
    integer checks=0, wraps=0, lane, word_id, trial, shape, cout, start, channel;
    c39_operand_pack u_pack(.mode(mode),.expanded(source_a),.packed_a(packed_a));
    c39_operand_unpack u_unpack(.mode(mode),.channels(channels),.packed_a(packed_a),.expanded(restored));

    task random_pixels;
        begin
            for(word_id=0;word_id<4;word_id=word_id+1)begin
                rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                first_pixel[word_id*32+:32]=rng;
                second_pixel[word_id*32+:32]=~rng;
            end
        end
    endtask
    task verify;
        begin
            #1;
            if(packed_a!==expected_payload)
                $fatal(1,"C39 codec payload mismatch mode=%0d check=%0d",mode,checks);
            if(restored!==source_a)
                $fatal(1,"C39 codec roundtrip mismatch mode=%0d check=%0d",mode,checks);
            checks=checks+1;
        end
    endtask
    initial begin
        // Every possible starting channel, including all five wrap locations.
        mode=0;
        for(trial=0;trial<32;trial=trial+1)begin
            random_pixels();
            for(shape=0;shape<4;shape=shape+1)begin
                case(shape) 0:cout=8;1:cout=16;2:cout=24;3:cout=48;endcase
                for(start=0;start<cout;start=start+1)begin
                    source_a=0;channels=0;
                    for(lane=0;lane<6;lane=lane+1)begin
                        channel=(start+lane)%cout;
                        channels[lane*6+:6]=channel;
                        source_a[lane*128+:128]=(start+lane>=cout) ? second_pixel : first_pixel;
                    end
                    expected_payload={176'd0,(start+5>=cout ? second_pixel : first_pixel),first_pixel};
                    if(start+5>=cout)wraps=wraps+1;
                    verify();
                end
            end
        end
        for(trial=0;trial<512;trial=trial+1)begin
            random_pixels();
            for(mode=1;mode<=5;mode=mode+1)begin
                source_a=0;expected_payload=0;channels=0;
                for(lane=0;lane<6;lane=lane+1)begin
                    rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                    case(mode)
                        1:begin
                            source_a[lane*128+:128]=lane<3 ? first_pixel : second_pixel;
                            expected_payload={176'd0,second_pixel,first_pixel};
                        end
                        2:begin
                            source_a[lane*128+:72]={rng[7:0],rng,~rng};
                            expected_payload[lane*72+:72]={rng[7:0],rng,~rng};
                        end
                        3:begin
                            source_a[lane*128+:16]=rng[15:0];
                            expected_payload[lane*16+:16]=rng[15:0];
                        end
                        default:begin
                            source_a[lane*128+:128]=first_pixel;
                            expected_payload={304'd0,first_pixel};
                        end
                    endcase
                end
                verify();
            end
        end
        if(checks!=5632 || wraps!=640)$fatal(1,"C39 codec coverage incomplete");
        $display("C39_OPERAND_CODEC_PASS checks=%0d pw_wrap_cases=%0d modes=6 shapes=4",checks,wraps);
        $finish;
    end
endmodule
