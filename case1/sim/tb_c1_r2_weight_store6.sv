`timescale 1ns/1ps
module tb_c1_r2_weight_store6;
    parameter integer NEGATIVE=0,PACKED=0;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,load_valid=0,read_en=0;
    reg [1:0] load_kind=0;
    reg [10:0] load_addr=0;
    reg [31:0] load_data=0;
    reg [47:0] read_addr=0;
    wire [1023:0] old_w;
    wire [767:0] new_w;
    reg [53:0] lane_addr=0;
    wire [255:0] old_b,new_b;
    wire [199:0] old_a,new_a;
    c1_r2_weight_store8 baseline(.clk(clk),.rst(rst),.load_valid(NEGATIVE==0 && load_valid),.load_kind(load_kind),
        .load_addr(load_addr),.load_data(load_data),.read_en(NEGATIVE==0 && read_en),.read_addr(read_addr),
        .read_weights(old_w),.read_bias(old_b),.read_affine(old_a));
    c1_r2_weight_store6 #(.PACKED(PACKED)) dut(.clk(clk),.rst(rst),.load_valid(load_valid),.load_kind(load_kind),
        .load_addr(load_addr),.load_data(load_data),.read_en(read_en),.read_addr(read_addr),
        .lane_addr(lane_addr),.read_weights(new_w),.read_bias(new_b),.read_affine(new_a));
    // Independent logical bank/row/word model; no replica/bit-slice addressing.
    reg [31:0] weights[0:7][0:47][0:3],biases[0:47];
    reg [24:0] affine[0:47];
    reg [1023:0] saved_old_w;
    reg [767:0] saved_w;
    reg [255:0] saved_b;
    reg [199:0] saved_a;
    reg have_read=0;
    reg [31:0] random_q=32'h981264af;
    integer reads=0,loads=0,resets=0,hold_checks=0;
    function automatic [31:0] next_random(input [31:0] x);
        reg [31:0] y;
        begin y=x^(x<<13);y=y^(y>>17);next_random=y^(y<<5);end
    endfunction
    function automatic [31:0] legal_affine(input [31:0] x);
        legal_affine={7'd0,x[24],6'(x[23:18]%48),x[17:0]};
    endfunction
    task check_held;
        begin
            if(have_read)begin
                if(old_w!==saved_old_w || new_w!==saved_w || old_b!==saved_b || new_b!==saved_b ||
                   old_a!==saved_a || new_a!==saved_a)$fatal(1,"disabled/write/reset changed parameter outputs");
                hold_checks=hold_checks+1;
            end
        end
    endtask
    task put(input integer kind,input integer address,input [31:0] value);
        integer bank,row,word_id;
        begin
            @(negedge clk);read_en=0;load_valid=1;load_kind=kind;load_addr=address;load_data=value;
            @(posedge clk);#1;
            if(kind==1)begin
                bank=address/256;row=(address%256)/4;word_id=address%4;
                weights[bank][row][word_id]=value;
            end else if(kind==2)biases[address]=value;
            else affine[address]=value[24:0];
            loads=loads+1;check_held;
        end
    endtask
    task get(input [47:0] addresses);
        integer row,co;
        integer selected_bank,selected_row;
        begin
            @(negedge clk);load_valid=0;read_en=1;read_addr=addresses;
            @(posedge clk);#1;
            for(integer bank=0;bank<8;bank=bank+1)begin
                row=addresses[bank*6+:6];co=(row/8)*8+bank;
                for(integer word_id=0;word_id<4;word_id=word_id+1)
                    if(old_w[bank*128+word_id*32+:32]!==weights[bank][row][word_id] ||
                       1'b0)
                        $fatal(1,"weight bank/row/word or read latency mismatch bank=%0d row=%0d word=%0d",bank,row,word_id);
                if(old_b[bank*32+:32]!==biases[co] || new_b[bank*32+:32]!==biases[co] ||
                   old_a[bank*25+:25]!==affine[co] || new_a[bank*25+:25]!==affine[co])
                    $fatal(1,"bias/affine mismatch co=%0d",co);
            end
            for(integer lane=0;lane<6;lane=lane+1)begin
                selected_bank=lane_addr[lane*9+6+:3];selected_row=lane_addr[lane*9+:6];
                for(integer word_id=0;word_id<4;word_id=word_id+1)
                    if(new_w[lane*128+word_id*32+:32]!==weights[selected_bank][selected_row][word_id])
                        $fatal(1,"replica lane/value/latency mismatch lane=%0d bank=%0d row=%0d word=%0d got=%h expected=%h",lane,selected_bank,selected_row,word_id,new_w[lane*128+word_id*32+:32],weights[selected_bank][selected_row][word_id]);
            end
            saved_old_w=old_w;saved_w=new_w;saved_b=new_b;saved_a=new_a;have_read=1;reads=reads+1;
        end
    endtask
    task reset_consumers;
        begin
            @(negedge clk);load_valid=1;load_kind=1;load_addr=0;load_data=32'hbadd_cafe;read_en=1;rst=1;
            repeat(2)begin @(posedge clk);#1;check_held;end
            @(negedge clk);rst=0;load_valid=0;read_en=0;resets=resets+1;
        end
    endtask
    reg [47:0] addresses;
    integer address;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        if(NEGATIVE!=0)begin
            @(negedge clk);
            case(NEGATIVE)
                1:begin load_valid=1;load_kind=1;read_en=1;end
                2:begin load_valid=1;load_kind=1;load_addr=192;end
                3:begin load_valid=1;load_kind=2;load_addr=48;end
                4:begin load_valid=1;load_kind=3;load_data=48<<18;end
                5:begin read_en=1;read_addr[5:0]=48;end
                6:begin load_valid=1;load_kind=3;load_data=1<<25;end
                7:begin read_en=1;lane_addr[5:0]=48;end
                default:$fatal(1,"unknown negative control");
            endcase
            repeat(3)@(negedge clk);
            $fatal(1,"negative control was not rejected");
        end
        for(integer bank=0;bank<8;bank=bank+1)
            for(integer row=0;row<48;row=row+1)
                for(integer word_id=0;word_id<4;word_id=word_id+1)begin
                    random_q=next_random(random_q);
                    put(1,bank*256+row*4+word_id,random_q^(bank<<28)^(row<<16)^(word_id<<12));
                end
        for(integer co=0;co<48;co=co+1)begin
            random_q=next_random(random_q);put(2,co,random_q);
            random_q=next_random(random_q);put(3,co,legal_affine(random_q));
        end
        // Every legal entry in every replica, with independent lane addresses.
        for(integer index=0;index<384;index=index+1)begin
            for(integer bank=0;bank<8;bank=bank+1)addresses[bank*6+:6]=(index+7*bank)%48;
            for(integer lane=0;lane<6;lane=lane+1)begin
                address=(index+37*lane)%384;
                lane_addr[lane*9+:9]=9'((address/48)*64+address%48);
            end
            get(addresses);
        end
        // Update every word separately, then immediately verify all six copies
        // and that the other three words in the wide read were not overwritten.
        for(integer bank=0;bank<8;bank=bank+1)
            for(integer row=0;row<48;row=row+1)
                for(integer word_id=0;word_id<4;word_id=word_id+1)begin
                    random_q=next_random(random_q);put(1,bank*256+row*4+word_id,random_q);
                    for(integer b=0;b<8;b=b+1)addresses[b*6+:6]=row;
                    for(integer lane=0;lane<6;lane=lane+1)lane_addr[lane*9+:9]=9'(bank*64+row);
                    get(addresses);
                end
        for(integer test_id=0;test_id<1000;test_id=test_id+1)begin
            if(test_id%3==0)begin
                random_q=next_random(random_q);
                address=(random_q[2:0]*256)+((random_q[15:8]%48)*4)+random_q[21:20];
                random_q=next_random(random_q);put(1,address,random_q);
            end
            if(test_id%11==0)begin random_q=next_random(random_q);put(2,random_q[7:0]%48,random_q);end
            if(test_id%13==0)begin random_q=next_random(random_q);put(3,random_q[7:0]%48,legal_affine(random_q));end
            if(test_id%97==0)reset_consumers;
            for(integer bank=0;bank<8;bank=bank+1)begin
                random_q=next_random(random_q);addresses[bank*6+:6]=random_q%48;
            end
            for(integer lane=0;lane<6;lane=lane+1)begin
                random_q=next_random(random_q);
                lane_addr[lane*9+:9]=9'(random_q[2:0]*64+((random_q>>3)%48));
            end
            get(addresses);
        end
        @(negedge clk);read_en=0;load_valid=0;
        repeat(4)begin @(posedge clk);#1;check_held;end
        if(reads!=2920 || loads!=3670 || resets!=11 || hold_checks!=2064)$fatal(1,"wrong directed/random coverage");
        $display("C1_R2_WEIGHT_REPLICA_PASS packed=%0d reads=%0d loads=%0d resets=%0d hold_checks=%0d logical_banks=8 physical_replicas=6 legal_rows=48 weight_words=1536 checked_weight_words=%0d independent_model=1 retained_baseline=1 read_latency=1 arbitrary_word_updates=1",PACKED,reads,loads,resets,hold_checks,reads*24);
        $finish;
    end
    initial begin repeat(20000)@(posedge clk);$fatal(1,"weight replica test timeout");end
endmodule
