`timescale 1ns/1ps
module tb_c1_r1_preview_fork;
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic in_valid=0,in_ready,cnn_valid,cnn_ready=0,preview_valid,preview_ready=0,busy;
    logic [63:0] in_data_s8,cnn_data_s8;
    logic [15:0] in_x,in_y,cnn_x,cnn_y,preview_x,preview_y;
    logic in_sof,in_eol,in_eof,cnn_sof,cnn_eol,cnn_eof,preview_sof,preview_eol,preview_eof;
    logic [23:0] preview_rgb;
    integer sent=0,cnn_count=0,preview_count=0,epoch=0,cycle=0,replaces=0;
    integer cnn_only=0,preview_only=0,total=0;
    logic cnn_held=0,preview_held=0;
    logic [98:0] cnn_previous;
    logic [58:0] preview_previous;
    c1_r1_preview_fork dut(.*);
    function automatic [98:0] token(input integer n, e);
        logic [63:0] data;
        data={40'h123456789a,8'(n*11+e),8'(n*7+e*3),8'(n*19+e*5)};
        token={(n==0),(n%8==7),(n==63),16'(n/8),16'(n%8),data};
    endfunction
    always @(posedge clk) begin : scoreboard
        logic [98:0] expected;
        if(rst) begin
            if(in_ready || cnn_valid || preview_valid || busy) $fatal(1,"flush handshake leak");
            cnn_held=0;preview_held=0;
        end else begin
            if(cnn_held && (!cnn_valid || {cnn_sof,cnn_eol,cnn_eof,cnn_y,cnn_x,cnn_data_s8}!==cnn_previous))
                $fatal(1,"CNN stalled token changed");
            if(preview_held && (!preview_valid || {preview_sof,preview_eol,preview_eof,preview_y,preview_x,preview_rgb}!==preview_previous))
                $fatal(1,"preview stalled token changed");
            cnn_held=cnn_valid&&!cnn_ready;preview_held=preview_valid&&!preview_ready;
            cnn_previous={cnn_sof,cnn_eol,cnn_eof,cnn_y,cnn_x,cnn_data_s8};
            preview_previous={preview_sof,preview_eol,preview_eof,preview_y,preview_x,preview_rgb};
            if(cnn_valid && cnn_ready) begin
                expected=token(cnn_count,epoch);
                if(cnn_count>=sent || cnn_previous!==expected) $fatal(1,"CNN missing/duplicate/corrupt token");
                cnn_count++;
            end
            if(preview_valid && preview_ready) begin
                expected=token(preview_count,epoch);
                if(preview_count>=sent || preview_previous!=={expected[98:64],expected[7:0]^8'h80,expected[15:8]^8'h80,expected[23:16]^8'h80})
                    $fatal(1,"preview missing/duplicate/corrupt token");
                preview_count++;
            end
            if(cnn_valid && cnn_ready && preview_valid && !preview_ready) cnn_only++;
            if(preview_valid && preview_ready && cnn_valid && !cnn_ready) preview_only++;
            if(in_valid && in_ready) begin if(busy) replaces++;sent++;total++;end
        end
    end
    initial begin
        // Cancellation after only one consumer has accepted must discard
        // the other's pending token, with no stale replay after reset.
        for(epoch=0;epoch<4;epoch++) begin
            @(negedge clk);rst=1;in_valid=0;
            repeat(2) @(negedge clk);
            sent=0;cnn_count=0;preview_count=0;rst=0;
            for(cycle=0;cycle<8;cycle++) begin
                in_valid=(sent==0);{in_sof,in_eol,in_eof,in_y,in_x,in_data_s8}=token(sent,epoch);
                cnn_ready=(epoch%2==0);preview_ready=(epoch%2==1);
                @(negedge clk);
            end
            if(sent!=1 || cnn_count!=(epoch%2==0) || preview_count!=(epoch%2==1) || !busy)
                $fatal(1,"one-sided cancellation setup invalid");
        end
        @(negedge clk);rst=1;in_valid=0;repeat(2) @(negedge clk);
        sent=0;cnn_count=0;preview_count=0;rst=0;
        for(cycle=0;cycle<500;cycle++) begin
            in_valid=sent<64;
            {in_sof,in_eol,in_eof,in_y,in_x,in_data_s8}=token(sent,epoch);
            cnn_ready=(cycle%7!=0);
            preview_ready=(cycle>=35 && cycle%5!=0 && !(sent==64 && cycle<200));
            @(negedge clk);
            if(cycle==190 && (cnn_count!=64 || preview_count!=63 || !busy || !preview_valid || !preview_eof))
                $fatal(1,"preview EOF was lost or retired before slow branch accepted");
        end
        if(sent!=64 || cnn_count!=64 || preview_count!=64 || busy || replaces==0 || cnn_only==0 || preview_only==0)
            $fatal(1,"fork coverage/drain failed sent=%0d cnn=%0d preview=%0d replace=%0d",sent,cnn_count,preview_count,replaces);
        $display("C1_PREVIEW_FORK_PASS pixels=64 aborts=4 eof_hold=1 replace=%0d cnn_first=%0d preview_first=%0d",replaces,cnn_only,preview_only);
        $finish;
    end
    initial begin #100000; $fatal(1,"fork timeout"); end
endmodule
