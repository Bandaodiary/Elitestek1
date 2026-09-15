`timescale 1ns/1ps
module tb_c1_frame_pair_geometry;
    logic clk=0,rst=1,start=0;
    always #5 clk=~clk;
    logic [15:0] iw=1,ih=1,ow=1,oh=1;
    logic [127:0] input_entry,output_entry;
    wire ready,rv,err,busy;
    wire [7:0] code;
    wire [15:0] riw,rih,row,roh;
    wire [31:0] araddr;
    wire arvalid,rready;
    logic rvalid=0;
    logic [127:0] rdata=0;
    integer passed=0;
    c1_frame_pair_resolver #(.SEPARATE_INPUT_GEOMETRY(1)) dut(
        .clk(clk),.rst(rst),.abort(1'b0),.start_valid(start),.start_ready(ready),
        .input_table_base(64'h1000),.output_table_base(64'h2000),
        .input_buffer_index(2'd0),.output_buffer_index(2'd0),
        .expected_width_pixels(ow),.expected_height_lines(oh),
        .expected_input_width_pixels(iw),.expected_input_height_lines(ih),
        .response_valid(rv),.response_ready(1'b1),.response_error(err),.response_error_code(code),
        .response_error_address(),.resolved_input_base(),.resolved_input_stride(),
        .resolved_input_width(riw),.resolved_input_height(rih),
        .resolved_output_base(),.resolved_output_stride(),.resolved_output_width(row),.resolved_output_height(roh),
        .busy(busy),.m_axi_araddr(araddr),.m_axi_arlen(),.m_axi_arsize(),.m_axi_arburst(),
        .m_axi_arvalid(arvalid),.m_axi_arready(!rvalid),.m_axi_rdata(rdata),
        .m_axi_rresp(2'd0),.m_axi_rlast(1'b1),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    always @(posedge clk) begin
        if(rst) rvalid<=0;
        else begin
            if(rvalid && rready) rvalid<=0;
            if(arvalid && !rvalid) begin
                if(araddr!=32'h1000 && araddr!=32'h2000) $fatal(1,"unexpected table address");
                rdata<= araddr==32'h1000 ? input_entry : output_entry;
                rvalid<=1;
            end
        end
    end
    task automatic run_pair(input integer w0,h0,w1,h1,b0,s0,b1,s1,input integer bad);
        integer overlap,waits;
        logic [7:0] expected_code;
        begin
            overlap=0;
            for(integer y=0;y<h0;y=y+1)
                for(integer z=0;z<h1;z=z+1)
                    if(b0+y*s0 < b1+z*s1+w1*4 && b1+z*s1 < b0+y*s0+w0*4) overlap=1;
            expected_code=overlap ? 8'h30 : 0;
            if(bad==1) expected_code=8'h24;
            if(bad==2) expected_code=8'h25;
            if(w0==0 || h0==0 || w1==0 || h1==0) expected_code=3;
            @(negedge clk);
            iw=w0; ih=h0; ow=w1; oh=h1;
            input_entry={16'(h0),16'(w0+(bad==1)),32'(s0),32'd0,32'(b0)};
            output_entry={16'(h1),16'(w1+(bad==2)),32'(s1),32'd0,32'(b1)};
            while(!ready) @(negedge clk);
            start=1;
            @(negedge clk); start=0;
            // Snapshot must not depend on changing software inputs after start.
            iw=0; ih=0; ow=0; oh=0;
            waits=0;
            while(!rv && waits<500) begin @(negedge clk); waits=waits+1; end
            if(!rv || err!==(expected_code!=0) || code!==expected_code)
                $fatal(1,"geometry response mismatch expected=%h actual=%h error=%b",expected_code,code,err);
            if(!err && (riw!==w0 || rih!==h0 || row!==w1 || roh!==h1))
                $fatal(1,"resolved independent geometry mismatch");
            passed=passed+1;
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        run_pair(12,6,8,8,'h10000,64,'h20000,32,0);
        run_pair(8,8,12,6,'h10000,32,'h20000,64,0);
        // Width-only and late-row overlaps; padding-only interleaving is legal.
        run_pair(12,1,4,1,'h10000,64,'h10020,16,0);
        run_pair(4,1,12,1,'h10020,16,'h10000,64,0);
        run_pair(4,5,4,1,'h10000,32,'h10080,16,0);
        run_pair(4,1,4,5,'h10080,16,'h10000,32,0);
        for(integer offset=0;offset<12;offset=offset+1)
            run_pair(4,5,8,3,'h10000,64,'h10000+16*offset,64,0);
        run_pair(12,6,8,8,'h10000,64,'h20000,32,1);
        run_pair(12,6,8,8,'h10000,64,'h20000,48,2);
        run_pair(0,6,8,8,'h10000,64,'h20000,32,0);
        run_pair(12,6,0,8,'h10000,64,'h20000,32,0);
        $display("C1_FRAME_PAIR_GEOMETRY_PASS cases=%0d",passed); $finish;
    end
    initial begin #1000000; $fatal(1,"geometry test timeout"); end
endmodule
