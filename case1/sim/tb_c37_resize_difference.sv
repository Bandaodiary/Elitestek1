`timescale 1ns/1ps
module tb_c37_resize_difference;
    parameter integer BAD_WEIGHT=0,BAD_GOLDEN=0;
    localparam integer TOTAL=4097*8+4096;
    reg clk=0,rst=1,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    wire in_ready,out_valid,out_sof,out_eol,out_eof;
    wire ref_ready,ref_valid,ref_sof,ref_eol,ref_eof;
    reg in_sof=0,in_eol=0,in_eof=0;
    reg [15:0] in_x=0,in_y=0;
    wire [15:0] out_x,out_y,ref_x,ref_y;
    reg [23:0] in_p00=0,in_p01=0,in_p10=0,in_p11=0;
    wire [23:0] in_rgb_y0x0=in_p00,in_rgb_y0x1=in_p01,in_rgb_y1x0=in_p10,in_rgb_y1x1=in_p11;
    reg [12:0] in_wx0=4096,in_wx1=0,in_wy0=4096,in_wy1=0;
    wire [23:0] out_rgb,ref_rgb;
    r1_bilinear_interp_rgb888 dut(.*);
    c37_retained_interp ref_dut(.in_ready(ref_ready),.out_valid(ref_valid),
        .out_rgb(ref_rgb),.out_x(ref_x),.out_y(ref_y),
        .out_sof(ref_sof),.out_eol(ref_eol),.out_eof(ref_eof),.*);
    reg [58:0] expected[0:TOTAL-1];
    integer sent=0,received=0,cycles=0,held=0,resets=0,c;
    reg [23:0] golden;
    reg [58:0] held_payload;
    reg was_held=0,input_held=0;
    function automatic [7:0] reference_pixel(input integer p00,p01,p10,p11,wx,wy);
        integer a,b;
        begin
            a=(p00*(4096-wx)+p01*wx+2048)/4096;
            b=(p10*(4096-wx)+p11*wx+2048)/4096;
            reference_pixel=(a*(4096-wy)+b*wy+2048)/4096;
        end
    endfunction
    always @(negedge clk)begin
        cycles=cycles+1;
        rst=cycles<4 || cycles==43 || cycles==44 || cycles==123;
        if(cycles==43 || cycles==123)resets=resets+1;
        out_ready=(cycles%29>=13);
        in_valid=!rst && (input_held || (sent<TOTAL && (cycles%7!=0)));
        // sent changes only after acceptance: stalled operands remain fixed.
        in_x=sent;in_y=sent>>4;
        in_sof=sent%257==0;in_eol=sent%257==256;in_eof=sent==TOTAL-1;
        in_wx1=sent<4097*8 ? sent%4097 : (sent*157)%4097;
        in_wy1=(sent*251+17)%4097;
        in_wx0=4096-in_wx1+(BAD_WEIGHT!=0);in_wy0=4096-in_wy1;
        case(sent/4097)
            0:begin in_p00=0;in_p01=24'hffffff;in_p10=24'hffffff;in_p11=0;end
            1:begin in_p00=24'hffffff;in_p01=0;in_p10=0;in_p11=24'hffffff;end
            2:begin in_p00=24'h000100;in_p01=24'h010001;in_p10=24'h010001;in_p11=24'h000100;end
            3:begin in_p00=24'hfefffe;in_p01=24'hfffeff;in_p10=24'hfffeff;in_p11=24'hfefffe;end
            default:begin
                in_p00=sent*32'h37ac691;in_p01=sent*32'h1a5c319;
                in_p10=sent*32'h237b471;in_p11=sent*32'h54a3261;
            end
        endcase
        if(cycles>250000)$fatal(1,"C37 resize timeout");
    end
    always @(posedge clk)begin
        if(rst)begin sent=0;received=0;was_held=0;input_held=0;end
        else begin
            input_held=in_valid && !in_ready;
            if(in_ready!==ref_ready || out_valid!==ref_valid ||
                (out_valid && {out_rgb,out_x,out_y,out_sof,out_eol,out_eof}!==
                {ref_rgb,ref_x,ref_y,ref_sof,ref_eol,ref_eof}))
                $fatal(1,"C37 resize baseline cycle/bit mismatch");
            if(was_held && (!out_valid || {out_rgb,out_x,out_y,out_sof,out_eol,out_eof}!==held_payload))
                $fatal(1,"C37 resize held output changed");
            was_held=out_valid && !out_ready;
            if(was_held)begin held=held+1;held_payload={out_rgb,out_x,out_y,out_sof,out_eol,out_eof};end
            if(out_valid && out_ready)begin
                if(received>=sent || {out_rgb,out_x,out_y,out_sof,out_eol,out_eof}!==expected[received])
                    $fatal(1,"C37 resize independent golden mismatch index=%0d",received);
                received=received+1;
            end
            if(in_valid && in_ready)begin
                for(c=0;c<3;c=c+1)golden[c*8+:8]=reference_pixel(
                    in_p00[c*8+:8],in_p01[c*8+:8],in_p10[c*8+:8],in_p11[c*8+:8],in_wx1,in_wy1);
                expected[sent]={golden^(BAD_GOLDEN ? 24'd1 : 24'd0),in_x,in_y,in_sof,in_eol,in_eof};
                sent=sent+1;
            end
            if(received==TOTAL)begin
                if(held<100 || resets!=2)$fatal(1,"C37 resize insufficient coverage");
                $display("C37_RESIZE_DIFFERENCE_PASS pixels=%0d weights=4097 resets=%0d held=%0d cycle_miter=1",received,resets,held);
                $finish;
            end
        end
    end
endmodule
