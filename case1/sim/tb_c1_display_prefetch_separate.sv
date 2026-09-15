`timescale 1ns/1ps
module tb_c1_display_prefetch_separate #(parameter integer FIFO=0,
    parameter integer RESET_PRIMED=0);
    logic core_clk=0, pixel_clk=0, rst=1;
    always #5 core_clk=~core_clk;
    always #7 pixel_clk=~pixel_clk;
    logic start=0, ready, busy, done, error, primed;
    logic [15:0] ow=8, oh=3, sw=4, sh=1;
    logic [1:0] request=0, response, underflow;
    logic [2:0] x[2];
    logic [7:0] y[2];
    wire [23:0] rgb[2];
    wire [31:0] araddr[2];
    wire [7:0] arlen[2];
    wire [2:0] arsize[2];
    wire [1:0] arburst[2];
    wire [1:0] arvalid, arready, rvalid, rready, rlast;
    wire [127:0] rdata[2];
    integer widths[2], heights[2], reads[2], checked=0, jobs=0;
    integer i, j, k, which, before_reads;

    function automatic [23:0] pixel(input integer c, row, col);
        pixel={c ? 8'hb2 : 8'h3d, 8'(row*17+3), 8'(col*29+5)};
    endfunction

    // Independent AXI BFM: two beats for width 8, one for width 4.
    // Distinct 64/48-byte strides expose cross-channel geometry mistakes.
    for (genvar c=0; c<2; c++) begin: memory
        logic pending=0;
        logic [31:0] address;
        integer beat=0, count=0, row, col;
        assign arready[c]=!pending;
        assign rvalid[c]=pending;
        assign rlast[c]=pending && beat==count-1;
        logic [127:0] data_value;
        assign rdata[c]=data_value;
        always_comb begin
            row=(address-(c ? 32'h2000 : 32'h1000))/(c ? 48 : 64);
            col=beat*4;
            data_value=0;
            for (integer n=0;n<4;n++) data_value[n*32+:32]={8'd0,pixel(c,row,col+n)};
        end
        always @(posedge core_clk) begin
            if(rst) begin pending<=0; reads[c]<=0; end
            else begin
                if(arvalid[c] && arready[c]) begin
                    if(araddr[c] !== (c ? 32'h2000 : 32'h1000)+reads[c]*(c ? 48 : 64) ||
                       arlen[c] !== widths[c]/4-1 || arsize[c]!==4 || arburst[c]!==1 ||
                       reads[c]>=heights[c])
                        $fatal(1,"channel %0d wrong AXI row/shape addr=%h len=%0d row=%0d",c,araddr[c],arlen[c],reads[c]);
                    pending<=1; address<=araddr[c]; beat<=0; count<=arlen[c]+1;
                    reads[c]<=reads[c]+1;
                end
                if(rvalid[c] && rready[c]) begin
                    if(rlast[c]) pending<=0;
                    else beat<=beat+1;
                end
            end
        end
    end

    c1_display_prefetch_pair #(.MAX_WIDTH(8),.X_BITS(3),.Y_BITS(8),
        .MAX_HEIGHT(3),.ENABLE_RESPONSE_FIFO(FIFO),.SEPARATE_ORIGINAL_GEOMETRY(1)) dut (
        .core_clk(core_clk),.core_rst(rst),.pixel_clk(pixel_clk),.pixel_rst(rst),
        .start_valid(start),.start_ready(ready),.abort(1'b0),.hold_requests(1'b0),
        .original_base(32'h1000),.original_stride(32'd64),
        .styled_base(32'h2000),.styled_stride(32'd48),
        .width_pixels(sw),.height_lines(sh),.original_width_pixels(ow),.original_height_lines(oh),
        .busy(busy),.done(done),.error(error),.primed(primed),.aborted(),
        .original_request(request[0]),.original_request_x(x[0]),.original_request_y(y[0]),
        .original_response_valid(response[0]),.original_rgb(rgb[0]),.original_underflow(underflow[0]),
        .styled_request(request[1]),.styled_request_x(x[1]),.styled_request_y(y[1]),
        .styled_response_valid(response[1]),.styled_rgb(rgb[1]),.styled_underflow(underflow[1]),
        .original_axi_araddr(araddr[0]),.original_axi_arlen(arlen[0]),.original_axi_arsize(arsize[0]),
        .original_axi_arburst(arburst[0]),.original_axi_arvalid(arvalid[0]),.original_axi_arready(arready[0]),
        .original_axi_rdata(rdata[0]),.original_axi_rresp(2'd0),.original_axi_rlast(rlast[0]),
        .original_axi_rvalid(rvalid[0]),.original_axi_rready(rready[0]),
        .styled_axi_araddr(araddr[1]),.styled_axi_arlen(arlen[1]),.styled_axi_arsize(arsize[1]),
        .styled_axi_arburst(arburst[1]),.styled_axi_arvalid(arvalid[1]),.styled_axi_arready(arready[1]),
        .styled_axi_rdata(rdata[1]),.styled_axi_rresp(2'd0),.styled_axi_rlast(rlast[1]),
        .styled_axi_rvalid(rvalid[1]),.styled_axi_rready(rready[1])
    );

    task automatic begin_job;
        @(negedge core_clk); start=1;
        do @(posedge core_clk); while(!ready);
        @(negedge core_clk); start=0;
    endtask

    initial begin
        x[0]=0;x[1]=0;y[0]=0;y[1]=0;
        for(which=0;which<2;which++) begin
            rst=1; repeat(5) @(negedge core_clk);
            widths[0]=which ? 4 : 8; heights[0]=which ? 1 : 3;
            widths[1]=which ? 8 : 4; heights[1]=which ? 3 : 1;
            ow=widths[0];oh=heights[0];sw=widths[1];sh=heights[1];rst=0;
            begin_job();
            // Change all live config: only accepted START owns dimensions.
            ow=4;oh=2;sw=4;sh=2;
            wait(primed);
            if(RESET_PRIMED) begin
                // Observe the reset boundary before its first active edge.
                @(negedge core_clk); rst=1; #1;
                if(primed || ready)
                    $fatal(1,"reset exposed stale display readiness primed=%b ready=%b",primed,ready);
                repeat(5) @(negedge core_clk);
                if(busy || primed || |arvalid)
                    $fatal(1,"reset did not clear display transaction");
                $display("C1_DISPLAY_PRIMED_RESET_PASS fifo=%0d",FIFO);
                $finish;
            end
            repeat(10) @(negedge pixel_clk);
            if(!busy || ready || done)
                $fatal(1,"unconsumed old frame was retired early");
            for(i=0;i<2;i++) begin
                for(j=0;j<heights[i];j++) begin
                    // Permit CDC release and next-row DMA refill, independently
                    // of internal primed flags (which only describe initial fill).
                    repeat(60) @(negedge pixel_clk);
                    for(k=0;k<widths[i];k++) begin
                        if(!busy || ready || done)
                            $fatal(1,"frame retired before final pixel c=%0d y=%0d x=%0d",i,j,k);
                        x[i]=k;y[i]=j;request[i]=1;
                        @(posedge pixel_clk); #1;
                        if(response[i]!==1 || underflow[i]!==0 || rgb[i]!==pixel(i,j,k))
                            $fatal(1,"pixel mismatch c=%0d y=%0d x=%0d rgb=%h valid=%b underflow=%b",i,j,k,rgb[i],response[i],underflow[i]);
                        checked++;
                        @(negedge pixel_clk);request[i]=0;
                    end
                end
            end
            wait(done); if(error) $fatal(1,"valid separate geometry returned error");
            @(negedge core_clk);
            if(reads[0]!=heights[0] || reads[1]!=heights[1]) $fatal(1,"incomplete AXI rows");
            jobs++;
        end
        // Reject invalid dimensions on EITHER side before any AXI request.
        for(which=0;which<4;which++) begin
            wait(ready); before_reads=reads[0]+reads[1];
            ow=4;oh=1;sw=4;sh=1;
            case(which)
                0:ow=0;
                1:oh=4;
                2:sw=6;
                3:sh=0;
            endcase
            begin_job(); wait(done);
            if(!error || reads[0]+reads[1]!=before_reads || |arvalid)
                $fatal(1,"invalid geometry leaked traffic or lacked error");
            @(negedge core_clk);
        end
        $display("C1_DISPLAY_PREFETCH_SEPARATE_PASS fifo=%0d jobs=%0d pixels=%0d invalid=4",FIFO,jobs,checked);
        $finish;
    end
    initial begin #1000000;$fatal(1,"separate display timeout");end
endmodule
