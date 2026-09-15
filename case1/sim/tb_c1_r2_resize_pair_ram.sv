`timescale 1ns/1ps
module tb_c1_r2_resize_pair_ram #(
    parameter integer WIDTH=2048,NEGATIVE=0
);
    reg clk=0,rst=1,rd_en=0,wr0=0,wr1=0;
    always #5 clk=~clk;
    reg [15:0] x0=0,x1=0,wx=0;
    reg [23:0] wd=0;
    wire [23:0] a,b,c,d;
    reg [23:0] reference0[0:WIDTH-1],reference1[0:WIDTH-1];
    reg [95:0] held;
    reg [31:0] random_state=32'h61ea972d;
    integer reads=0,writes=0,holds=0,resets=0,i,k,q;
    c1_r2_resize_pair_ram #(.MAX_WIDTH(WIDTH)) dut (
        .clk(clk),.rst(rst),.rd_en(rd_en),.rd_x0(x0),.rd_x1(x1),
        .row0_x0(a),.row0_x1(b),.row1_x0(c),.row1_x1(d),
        .wr_row0(wr0),.wr_row1(wr1),.wr_x(wx),.wr_rgb(wd)
    );
    function automatic [31:0] next_random(input [31:0] old);
        reg [31:0] v;
        begin v=old^(old<<13);v=v^(v>>17);next_random=v^(v<<5);end
    endfunction
    task put(input integer row,input integer x,input [23:0] pixel);
        begin
            @(negedge clk);wr0=row==0;wr1=row==1;wx=x;wd=pixel;
            @(posedge clk);#1;
            if(row==0)reference0[x]=pixel;else reference1[x]=pixel;
            writes=writes+1;
            @(negedge clk);wr0=0;wr1=0;
        end
    endtask
    task get_pair(input integer left,input integer right);
        begin
            @(negedge clk);rd_en=1;x0=left;x1=right;
            @(posedge clk);#1;
            if({a,b,c,d}!=={reference0[left],reference0[right],reference1[left],reference1[right]})
                $fatal(1,"pair RAM mismatch width=%0d left=%0d right=%0d",WIDTH,left,right);
            reads=reads+1;held={a,b,c,d};
            @(negedge clk);rd_en=0;x0=0;x1=0;
            @(posedge clk);#1;
            if({a,b,c,d}!==held)$fatal(1,"pair RAM output did not hold");
            holds=holds+1;
        end
    endtask
    task warm_reset;
        begin
            @(negedge clk);rst=1;rd_en=1;wr0=1;wr1=1;x0=0;x1=0;wx=0;wd=24'hbadbad;
            repeat(2)begin
                @(posedge clk);#1;
                if({a,b,c,d}!==held)$fatal(1,"reset changed held RAM data");
            end
            @(negedge clk);rst=0;rd_en=0;wr0=0;wr1=0;resets=resets+1;
            get_pair(0,0);
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        if(NEGATIVE!=0)begin
            @(negedge clk);
            case(NEGATIVE)
                1:begin rd_en=1;x0=0;x1=2;end
                2:begin rd_en=1;x0=2;x1=1;end
                3:begin rd_en=1;x0=WIDTH;x1=WIDTH;end
                4:begin wr0=1;wx=WIDTH;end
            endcase
            repeat(3)@(posedge clk);
            $fatal(1,"negative test not rejected");
        end
        for(i=0;i<WIDTH;i=i+1)begin
            put(0,i,(i*65793)^24'ha13648);
            put(1,i,(i*131587)^24'h29cd07);
        end
        for(i=0;i<WIDTH;i=i+1)get_pair(i,i==WIDTH-1 ? i : i+1);
        for(i=WIDTH-1;i>=0;i=i-1)get_pair(i,i);
        for(k=0;k<128;k=k+1)begin
            random_state=next_random(random_state);q=random_state%WIDTH;
            put(random_state[5],q,random_state[31:8]);
            get_pair(q,q==WIDTH-1 ? q : q+1);
            if(k%16==0)warm_reset();
        end
        $display("C1_R2_RESIZE_RAM_PASS width=%0d reads=%0d writes=%0d holds=%0d resets=%0d read_latency=1",WIDTH,reads,writes,holds,resets);
        $finish;
    end
    initial begin repeat(200000)@(posedge clk);$fatal(1,"pair RAM timeout");end
endmodule
