`timescale 1ns/1ps
// Three padded rows, real fork/writer, ordered delayed AXI responses.
module tb_c1_r1_preview_multiline;
    logic clk=0,rst=1; always #5 clk=~clk;
    logic start_valid=0,start_ready,cancel=0,busy,done,error,aborted;
    logic [31:0] base_addr=32'h1000,stride_bytes=32;
    logic [15:0] width_pixels=4,height_lines=3;
    logic in_valid,in_ready,cnn_valid,cnn_ready;
    logic [63:0] in_data_s8,cnn_data_s8;
    logic [15:0] in_x,in_y,cnn_x,cnn_y;
    logic in_sof,in_eol,in_eof,cnn_sof,cnn_eol,cnn_eof;
    wire [31:0] m_axi_awaddr; wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize; wire [1:0] m_axi_awburst;
    wire m_axi_awvalid; logic m_axi_awready;
    wire [127:0] m_axi_wdata; wire [15:0] m_axi_wstrb;
    wire m_axi_wlast,m_axi_wvalid; logic m_axi_wready;
    logic [1:0] m_axi_bresp=0; wire m_axi_bvalid,m_axi_bready;
    integer mode=0,sent=0,received=0,aws=0,beats=0,bs=0,cycles=0;
    integer fault_index=0,limit=0,completed=0,held_b_cases=0;
    logic permit_b=1,hold_b=0;
    c1_r1_preview_dma #(.DEST_REGION_BEGIN(33'h1000),.DEST_REGION_END(33'h1050)) dut(.*);
    function automatic [63:0] token(input integer n);
        token={40'h123456789a,8'(n*17),8'(n*11+3),8'(n*7+1)};
    endfunction
    function automatic [31:0] pixel(input integer n);
        logic [63:0] t;
        t=token(n); pixel={8'd0,t[7:0]^8'h80,t[15:8]^8'h80,t[23:16]^8'h80};
    endfunction
    assign in_valid=sent<limit;
    assign m_axi_bvalid=(aws>bs)&&(beats>bs)&&(!hold_b||permit_b);
    always_comb begin
        in_data_s8=token(sent);in_x=16'(sent%4);in_y=16'(sent/4);
        in_sof=(sent==0);in_eol=(sent%4==3);in_eof=(sent==11);
        if(sent==fault_index) begin
            case(mode)
                1: in_x=1;
                2: in_y=0;
                3: in_sof=1;
                4: in_eol=1;
                5: in_eol=0;
                6: in_eof=1;
                7: in_eof=0;
            endcase
        end
        cnn_ready=(cycles%5!=1);
        m_axi_awready=(cycles%3!=0);m_axi_wready=(cycles%4!=0);
    end
    always @(posedge clk) if(!rst) begin
        cycles<=cycles+1;
        if(in_valid&&in_ready) sent<=sent+1;
        if(cnn_valid&&cnn_ready) begin
            if(cnn_data_s8!==token(received)||cnn_x!==16'(received%4)||cnn_y!==16'(received/4)||
               cnn_sof!==(received==0)||cnn_eol!==(received%4==3)||cnn_eof!==(received==11))
                $fatal(1,"multiline CNN raster mismatch mode=%0d pixel=%0d",mode,received);
            if(mode>0&&mode<8&&received>=fault_index) $fatal(1,"malformed pixel entered CNN");
            received<=received+1;
        end
        if(m_axi_awvalid&&m_axi_awready) begin
            if(aws>=3||m_axi_awaddr!==32'(32'h1000+aws*32)||m_axi_awlen!==0||
               m_axi_awsize!==4||m_axi_awburst!==1) $fatal(1,"multiline AW stride/extent mismatch");
            aws<=aws+1;
        end
        if(m_axi_wvalid&&m_axi_wready) begin
            if(beats>=3||m_axi_wstrb!==16'hffff||m_axi_wlast!==1'b1) $fatal(1,"multiline W shape");
            for(integer k=0;k<4;k++)
                if(m_axi_wdata[k*32+:32]!==pixel(beats*4+k)) $fatal(1,"multiline DDR data");
            beats<=beats+1;
        end
        if(m_axi_bvalid&&m_axi_bready) bs<=bs+1;
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(mode=0;mode<9;mode++) begin
            wait(start_ready);@(negedge clk);
            sent=0;received=0;aws=0;beats=0;bs=0;
            case(mode)
                1,2,3: fault_index=4;
                4: fault_index=5;
                5,6: fault_index=7;
                7: fault_index=11;
                default: fault_index=99;
            endcase
            hold_b=(mode>=1&&mode<=3);permit_b=!hold_b;
            base_addr=32'h1000;stride_bytes=32;width_pixels=4;height_lines=3;
            limit=12;start_valid=1;@(negedge clk);start_valid=0;
            // Poison live configuration: the frame must use its snapshot.
            base_addr=32'hbad00000;stride_bytes=16;width_pixels=8;height_lines=1;
            if(mode>0&&mode<8) begin
                wait(error);@(negedge clk);
                if(sent!=fault_index+1||received!=fault_index||!busy||done||in_ready)
                    $fatal(1,"multiline fault not isolated mode=%0d sent=%0d received=%0d",mode,sent,received);
                if(hold_b) begin
                    wait(aws==1&&beats==1);@(negedge clk);
                    if(bs!=0) $fatal(1,"missing held B coverage");
                end
                limit=sent;cancel=1;@(negedge clk);cancel=0;
                if(hold_b) begin
                    repeat(24) begin
                        @(negedge clk);
                        if(done||!busy||start_ready||bs!=0) $fatal(1,"fault cancel retired before B");
                    end
                    held_b_cases=held_b_cases+1;permit_b=1;
                end
                if(!done) begin wait(done);@(negedge clk);end
                if(!error||!aborted||busy||aws!=bs||beats!=bs||bs!=fault_index/4)
                    $fatal(1,"multiline error retirement mode=%0d AW=%0d W=%0d B=%0d",mode,aws,beats,bs);
            end else begin
                wait(done);@(negedge clk);
                if(error||aborted||busy||sent!=12||received!=12||aws!=3||beats!=3||bs!=3)
                    $fatal(1,"multiline normal/recovery failure");
            end
            limit=0;completed=completed+1;
            repeat(3) begin @(negedge clk);if(done) $fatal(1,"duplicate done");end
        end
        if(completed!=9||held_b_cases!=3) $fatal(1,"multiline insufficient coverage");
        $display("C1_PREVIEW_MULTILINE_PASS jobs=9 normal=2 raster_faults=7 held_B_cancel=3 hold_cycles=24 rows=3 stride=32 snapshot=1 no_reset=1");
        $finish;
    end
    initial begin #200000;$fatal(1,"multiline timeout mode=%0d sent=%0d received=%0d",mode,sent,received);end
endmodule
