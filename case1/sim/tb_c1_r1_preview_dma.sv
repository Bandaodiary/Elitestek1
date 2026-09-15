`timescale 1ns/1ps
module tb_c1_r1_preview_dma #(parameter bit REGION_GUARD=0);
    logic clk=0,rst=1; always #5 clk=~clk;
    logic start_valid=0,start_ready,cancel=0,busy,done,error,aborted;
    logic [31:0] base_addr=32'h1000,stride_bytes=32;
    logic [15:0] width_pixels=8,height_lines=1;
    logic in_valid=0,in_ready,cnn_valid,cnn_ready;
    logic [63:0] in_data_s8,cnn_data_s8;
    logic [15:0] in_x,in_y=0,cnn_x,cnn_y;
    logic in_sof,in_eol,in_eof,cnn_sof,cnn_eol,cnn_eof;
    wire [31:0] m_axi_awaddr;wire [7:0] m_axi_awlen;wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;wire m_axi_awvalid;logic m_axi_awready;
    wire [127:0] m_axi_wdata;wire [15:0] m_axi_wstrb;wire m_axi_wlast,m_axi_wvalid;
    logic m_axi_wready;logic [1:0] m_axi_bresp=0;
    wire m_axi_bvalid,m_axi_bready;
    integer sent=0,received=0,beats=0,aws=0,bs=0,cycle=0,mode=0;
    logic permit_b=0,hold_cnn_eof=0;
    integer fault_index;
    c1_r1_preview_dma #(
        .DEST_REGION_BEGIN(REGION_GUARD ? 33'h1000 : 33'd0),
        .DEST_REGION_END(REGION_GUARD ? 33'h1020 : 33'h1_0000_0000)
    ) dut(.*);
    function automatic [63:0] token(input integer n);
        token={40'h1020304050,8'(n*19),8'(n*11+1),8'(n*7+2)};
    endfunction
    function automatic [31:0] pixel(input integer n);
        logic [63:0] v;
        v=token(n);pixel={8'd0,v[7:0]^8'h80,v[15:8]^8'h80,v[23:16]^8'h80};
    endfunction
    assign m_axi_bvalid=permit_b && aws==1 && beats==2 && bs==0;
    always_comb begin
        in_data_s8=token(sent);in_x=sent;in_sof=(sent==0);in_eol=(sent==7);in_eof=(sent==7);
        in_y=0;
        if(mode==8 && sent==0) in_x=1;
        if(mode==9 && sent==0) in_y=1;
        fault_index=0;
        case(mode)
            11: begin fault_index=0; if(sent==0) in_sof=0; end
            12: begin fault_index=1; if(sent==1) in_sof=1; end
            13: begin fault_index=2; if(sent==2) in_eol=1; end
            14: begin fault_index=7; if(sent==7) in_eol=0; end
            15: begin fault_index=3; if(sent==3) in_eof=1; end
            16: begin fault_index=7; if(sent==7) in_eof=0; end
        endcase
        cnn_ready=!(hold_cnn_eof && cnn_eof) && cycle%5!=0;
        m_axi_awready=(cycle%3!=0);m_axi_wready=(cycle%4!=0);
    end
    always @(posedge clk) if(!rst) begin
        cycle<=cycle+1;
        if(in_valid&&in_ready) begin
            if(sent>=8) $fatal(1,"next-frame token admitted after EOF");
            sent<=sent+1;
        end
        if(cnn_valid&&cnn_ready) begin
            if(cnn_data_s8!==token(received) || cnn_x!==received || cnn_y!==0 ||
               cnn_sof!==(received==0) || cnn_eol!==(received==7) || cnn_eof!==(received==7))
                $fatal(1,"CNN token mismatch n=%0d",received);
            received<=received+1;
        end
        if(m_axi_awvalid&&m_axi_awready) begin
            if(aws!=0 || m_axi_awaddr!==32'h1000 || m_axi_awlen!==1 || m_axi_awsize!==4 || m_axi_awburst!==1)
                $fatal(1,"preview AW or config snapshot mismatch");
            aws<=aws+1;
        end
        if(m_axi_wvalid&&m_axi_wready) begin
            if(beats>=2 || m_axi_wstrb!==16'hffff || m_axi_wlast!==(beats==1)) $fatal(1,"preview W shape mismatch");
            for(integer n=0;n<4;n++)
                if(m_axi_wdata[n*32+:32]!==pixel(beats*4+n)) $fatal(1,"physical RGB write mismatch");
            beats<=beats+1;
        end
        if(m_axi_bvalid&&m_axi_bready) bs<=bs+1;
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(mode=0;mode<18;mode++) begin
            if(!REGION_GUARD && mode==5) mode=8;
            wait(start_ready);@(negedge clk);
            sent=0;received=0;beats=0;aws=0;bs=0;permit_b=0;
            hold_cnn_eof=(mode==4);m_axi_bresp=(mode==2 ? 2 : 0);
            base_addr=32'h1000;stride_bytes=32;width_pixels=(mode==3 ? 3 : 8);height_lines=1;
            if(mode==5) base_addr=32'h0ff0; // Below allocation start.
            if(mode==6) base_addr=32'h1010; // Start legal, final byte outside.
            if(mode==7) begin height_lines=2;stride_bytes=64;end // Strided extent outside.
            start_valid=1;in_valid=1;
            @(negedge clk);start_valid=0;
            base_addr=32'hdead0000;stride_bytes=16;width_pixels=4;height_lines=2;
            if(mode==8 || mode==9 || (mode>=11 && mode<=16)) begin
                repeat(80) @(negedge clk);
                if(!error || sent!=fault_index+1 || received!=fault_index || aws!=0 || beats!=0 || !busy)
                    $fatal(1,"raster fault leaked or not detected mode=%0d error=%b sent=%0d cnn=%0d",mode,error,sent,received);
                cancel=1;@(negedge clk);cancel=0;in_valid=0;
                wait(done);@(negedge clk);
                if(!error || !aborted || busy) $fatal(1,"coordinate fault cancel did not retire");
            end else if(mode==3 || (mode>=5 && mode<=7)) begin
                wait(done);@(negedge clk);in_valid=0;
                if(!error || aborted || sent!=0 || received!=0 || aws!=0 || beats!=0)
                    $fatal(1,"invalid preflight leaked stream/AXI work");
            end else begin
                wait(sent==8);@(negedge clk);in_valid=1;
                wait(beats==2 && aws==1);@(negedge clk);
                if(mode==1) begin cancel=1;@(negedge clk);cancel=0;in_valid=1;end
                repeat(20) begin
                    @(negedge clk);
                    if(!busy || done || in_ready) $fatal(1,"premature B retirement or post-EOF/cancel admission");
                end
                in_valid=0;permit_b=1;
                if(mode==4) begin
                    wait(bs==1);repeat(10) @(negedge clk);
                    if(!busy || done || received!=7) $fatal(1,"writer completion lost pending CNN EOF");
                    hold_cnn_eof=0;
                end
                wait(done);@(negedge clk);
                if(busy || bs!=1 || received!=8 || error!==(mode==2) || aborted!==(mode==1))
                    $fatal(1,"preview terminal mismatch mode=%0d busy=%b B=%0d cnn=%0d err=%b abort=%b",mode,busy,bs,received,error,aborted);
            end
        end
        if(REGION_GUARD) $display("C1_PREVIEW_REGION_GUARD_PASS rejected=3 exact_end=1 snapshot=1 no_stream_or_axi_on_reject=1");
        $display("C1_PREVIEW_COORDINATE_GUARD_PASS bad_x=1 bad_y=1 no_bad_fanout=1 cancel_restart=1");
        $display("C1_PREVIEW_MARKER_GUARD_PASS missing_sof=1 repeated_sof=1 early_eol=1 missing_eol=1 early_eof=1 missing_eof=1 no_bad_fanout=1 restart=1");
        $display("C1_PREVIEW_DMA_PASS jobs=%0d successful=4 aborted=9 errors=%0d pixels_compared=68 late_B=6 late_CNN=1 no_reset_restart=1",REGION_GUARD ? 18 : 15,REGION_GUARD ? 13 : 10);
        $finish;
    end
    initial begin #200000;$fatal(1,"preview DMA timeout");end
endmodule
