`timescale 1ns/1ps
module tb_c37_window_capacity;
    parameter integer ROW_WORDS=512;
    reg clk=0,rst=1;always #5 clk=~clk;
    reg write_en=0,bulk_en=0,linear_rd_en=0;
    reg [13:0] write_addr=0;reg [31:0] write_data=0;
    reg [1:0] bulk_row=0;reg [9:0] bulk_pair=0;
    reg [2:0] bulk_group=0,bulk_groups=1;reg [127:0] bulk_data=0;
    reg [17:0] linear_rd_addr=0;wire [255:0] linear_rd_data;
    reg [7:0] linear_wr_en=0;reg [71:0] linear_wr_addr=0;reg [255:0] linear_wr_data=0;
    reg req_valid=0,out_ready=0;wire req_ready,out_valid;
    reg [9:0] req_x=0;reg [10:0] req_width=1;
    reg [2:0] req_group=0,req_groups=1;
    reg req_top=0,req_bottom=0,req_up2=0,req_row_phase=0;
    reg [5:0] req_row_map=6'b10_01_00;
    wire [9:0] out_x;wire [2:0] out_group;wire [767:0] out_window;
    wire old_req_ready,old_out_valid;wire [9:0] old_out_x;wire [2:0] old_out_group;
    wire [767:0] old_out_window;wire [255:0] old_linear_data;
    c1_r2_partitioned_window_store #(.ROW_WORDS(ROW_WORDS)) dut(
        .partition_en(1'b0),.partition_base(9'd0),.partition_end(10'd0),.*);
    c1_r2_overlay_window_store retained(.req_ready(old_req_ready),.out_valid(old_out_valid),
        .out_x(old_out_x),.out_group(old_out_group),.out_window(old_out_window),.linear_rd_data(old_linear_data),.*);
    reg [767:0] expected[0:65535];reg [12:0] tags[0:65535];
    integer cycles=0,pushed=0,popped=0,configs=0,writes=0,held=0;
    reg was_held=0;reg [780:0] held_payload;
    function automatic [63:0] pixel(input integer row,x,group_id);
        pixel=(64'h9e3779b97f4a7c15*(x+1)) ^ (64'hfedcba9876543210*(row+1)) ^ (64'h123456780000001d*(group_id+1));
    endfunction
    function automatic [767:0] window_reference;
        integer r,c,x,physical_row;
        reg top,bottom;
        begin
            top=req_top || (req_up2 && req_row_phase);
            bottom=req_bottom || (req_up2 && !req_row_phase);
            for(r=0;r<3;r=r+1)begin
                physical_row=(r==0 && top)||(r==2 && bottom) ? req_row_map[3:2] : ((req_row_map>>(r*2))&3);
                for(c=0;c<4;c=c+1)begin
                    x=$unsigned(req_x)+c-1;
                    if(x<0)x=0;
                    if(x>=req_width)x=req_width-1;
                    if(req_up2)x=x/2;
                    window_reference[(r*4+c)*64+:64]=pixel(physical_row,x,req_group);
                end
            end
        end
    endfunction
    always @(negedge clk)if(!rst)out_ready=(cycles%17>=7);
    always @(posedge clk)if(!rst)begin
        cycles=cycles+1;
        if(req_ready!==old_req_ready || out_valid!==old_out_valid ||
           (out_valid && {out_window,out_x,out_group}!=={old_out_window,old_out_x,old_out_group}))
            $fatal(1,"C37 window cycle-equivalence mismatch");
        if(was_held && (!out_valid || {out_window,out_x,out_group}!==held_payload))$fatal(1,"C37 window held output changed");
        was_held=out_valid && !out_ready;held_payload={out_window,out_x,out_group};
        if(was_held)held=held+1;
        if(out_valid && out_ready)begin
            if(popped>=pushed || out_window!==expected[popped] || {out_x,out_group}!==tags[popped])
                $fatal(1,"C29 independent window golden mismatch item=%0d",popped);
            popped=popped+1;
        end
        if(req_valid && req_ready)begin
            if(pushed>=65536)$fatal(1,"C29 test queue exhausted");
            expected[pushed]=window_reference();tags[pushed]={req_x,req_group};pushed=pushed+1;
        end
        if(bulk_en)writes=writes+1;
    end
    task request(input integer x,g);
        begin
            @(negedge clk);req_valid=1;req_x=x;req_group=g;
            @(posedge clk);while(!req_ready)@(posedge clk);
        end
    endtask
    task drain;
        begin @(negedge clk);req_valid=0;wait(popped==pushed);repeat(5)@(negedge clk);end
    endtask
    integer wi,gi,up,edge_mode,row,pair_id,g,xid,w,groups,physical_width;
    initial begin
        repeat(5)@(negedge clk);rst=0;
        for(wi=0;wi<10;wi=wi+1)for(gi=0;gi<4;gi=gi+1)for(up=0;up<2;up=up+1)begin
            case(wi)0:w=1;1:w=2;2:w=17;3:w=340;4:w=640;5:w=1024;6:w=170;7:w=341;8:w=512;default:w=513;endcase
            case(gi)0:groups=1;1:groups=2;2:groups=3;default:groups=6;endcase
            physical_width=up ? w/2 : w;
            if(!(up && w%2) && ((physical_width+1)/2)*groups<=ROW_WORDS)begin
                drain();req_width=w;req_groups=groups;req_up2=up;bulk_groups=groups;
                for(row=0;row<3;row=row+1)for(pair_id=0;pair_id<(physical_width+1)/2;pair_id=pair_id+1)
                    for(g=0;g<groups;g=g+1)begin
                        @(negedge clk);bulk_en=1;bulk_row=row;bulk_pair=pair_id;bulk_group=g;
                        bulk_data={pixel(row,pair_id*2+1,g),pixel(row,pair_id*2,g)};
                    end
                @(negedge clk);bulk_en=0;
                for(edge_mode=0;edge_mode<8;edge_mode=edge_mode+1)begin
                    drain();req_top=edge_mode[0];req_bottom=edge_mode[1];req_row_phase=edge_mode[2];
                    req_row_map=edge_mode[2] ? 6'b00_10_01 : 6'b10_01_00;
                    for(g=0;g<groups;g=g+1)for(xid=0;xid<5;xid=xid+1)begin
                        request(xid==0 ? 0 : xid==1 ? (w>1 ? 1 : 0) : xid==2 ? w/2 : xid==3 ? (w>1 ? w-2 : 0) : w-1,g);
                    end
                end
                configs=configs+1;
            end
        end
        drain();
        if(held==0 || configs<20 || pushed!=popped)$fatal(1,"C37 window coverage missing");
        $display("C37_WINDOW_CAPACITY_PASS configurations=%0d requests=%0d bulk_writes=%0d held=%0d cycle_equivalent=1 independent_golden=1",configs,popped,writes,held);
        $finish;
    end
    initial begin #10000000;$fatal(1,"C37 window timeout");end
endmodule
