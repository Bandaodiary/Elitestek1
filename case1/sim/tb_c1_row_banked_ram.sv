`timescale 1ns/1ps
module tb_c1_row_banked_ram #(
    parameter integer ROWS=3,
    parameter integer WORDS=5,
    parameter integer FAULT=0
);
    localparam integer AW=(WORDS<=1)?1:$clog2(WORDS);
    logic clk=0;
    always #5 clk=~clk;
    logic [ROWS-1:0] rd_en='0, wr_en='0;
    logic [ROWS*AW-1:0] rd_addr='0;
    wire [ROWS*64-1:0] rd_data;
    logic [AW-1:0] wr_addr='0;
    logic [63:0] wr_data=0;
    logic [63:0] shadow[0:ROWS-1][0:WORDS-1];
    logic [63:0] expected[0:ROWS-1];
    logic [ROWS-1:0] have_read='0;
    integer parallel_cycles=0, collisions=0;
    c1_row_banked_ram #(.ROWS(ROWS),.ROW_WORDS(WORDS)) dut(.*);

    task automatic step;
        begin
            for(integer b=0;b<ROWS;b++) begin
                if(rd_en[b]) begin
                    expected[b]=shadow[b][rd_addr[b*AW +: AW]];
                    have_read[b]=1;
                    if(wr_en[b] && wr_addr==rd_addr[b*AW +: AW]) collisions++;
                end
            end
            if(rd_en=={ROWS{1'b1}}) parallel_cycles++;
            @(posedge clk); #1;
            for(integer b=0;b<ROWS;b++) begin
                if(have_read[b] && rd_data[b*64 +: 64] !== expected[b])
                    $fatal(1,"bank %0d read/hold/read-first mismatch",b);
                if(wr_en[b]) shadow[b][wr_addr]=wr_data;
            end
        end
    endtask

    initial begin
        for(integer b=0;b<ROWS;b++) begin
            for(integer a=0;a<WORDS;a++) begin
                @(negedge clk);
                wr_en='0; wr_en[b]=1; wr_addr=a;
                wr_data=64'ha500000000000000 | (b<<16) | a;
                step();
            end
        end
        if(FAULT!=0) begin
            @(negedge clk); rd_en='0; wr_en='0;
            if(FAULT==1) begin rd_en[0]=1; rd_addr[0 +: AW]=WORDS; end
            else if(FAULT==2) begin wr_en[0]=1; wr_addr=WORDS; end
            else if(FAULT==3) begin rd_en[0]=1; rd_addr[0 +: AW]='x; end
            else if(FAULT==4) begin wr_en[0]=1; wr_addr='x; end
            else if(FAULT==5) rd_en[0]=1'bx;
            else if(FAULT==6) wr_en[0]=1'bx;
            else $fatal(1,"unsupported bank fault selector");
            @(posedge clk); #1;
            $fatal(1,"expected bank address rejection missing");
        end
        for(integer c=0;c<64;c++) begin
            @(negedge clk);
            wr_en='0;
            rd_en=(c!=0 && c%7==0)?'0:'1;
            for(integer b=0;b<ROWS;b++) rd_addr[b*AW +: AW]=(c*(b+1)+b)%WORDS;
            if(c%3==0) wr_en[c%ROWS]=1;
            wr_addr=rd_addr[(c%ROWS)*AW +: AW];
            wr_data=64'hcf00000000000000 | c;
            step();
        end
        // Verify all committed writes, not just old data on collision cycles.
        for(integer a=0;a<WORDS;a++) begin
            @(negedge clk); wr_en='0; rd_en='1;
            for(integer b=0;b<ROWS;b++) rd_addr[b*AW +: AW]=a;
            step();
        end
        repeat(8) begin
            // Disabled ports must ignore unknown addresses and retain output.
            @(negedge clk); wr_en='0; rd_en='0; rd_addr='x; wr_addr='x; step();
        end
        if(parallel_cycles<50 || collisions==0) $fatal(1,"banked RAM coverage missing");
        $display("C1_ROW_BANKED_RAM_PASS rows=%0d words=%0d parallel_cycles=%0d collisions=%0d",ROWS,WORDS,parallel_cycles,collisions);
        $finish;
    end
    initial begin #1000000; $fatal(1,"banked RAM timeout"); end
endmodule
