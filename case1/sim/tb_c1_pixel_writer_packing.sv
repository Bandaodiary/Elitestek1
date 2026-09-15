`timescale 1ns/1ps
// Real raster sink + real serial/ordered-MLP packer. The independent physical
// byte BFM deliberately serializes AXI transactions; this is a packing and
// drain test, NOT a proof that SLOT_COUNT transactions reached the slave.
module tb_c1_pixel_writer_packing #(
    parameter integer BATCH=8, SLOT_COUNT=1, TIMEOUT=64, W_FIRST=0, GROUPS=1
);
    logic clk=0,rst=1,abort=0,sv=0,sr,iv=0,ir;
    logic [31:0] base=0;logic [15:0] width=17,height=2;
    logic [63:0] data=0;logic [15:0] x=0,y=0;
    logic [2:0] group_index=0;logic group_last=1;
    logic sof=0,eol=0,eof=0,qv,qr,qe,rv,rr,re,busy,done,aborted,error;
    logic [31:0] qa;logic [63:0] qd;logic [7:0] code;
    logic hold_b=0,block_req=0,inject_error=0;
    integer epoch=0,requests=0,responses=0,ends=0,frames=0;
    byte unsigned expected[0:8191];
    wire admitted_valid=qv && !block_req;
    always #5 clk=~clk;
    c1_pixel_result_writer #(.BATCH_WORDS(BATCH),.MULTI_GROUP(GROUPS!=1)) dut (
        .clk,.rst,.abort,.start_valid(sv),.start_ready(sr),.start_base(base),
        .start_width(width),.start_height(height),.in_valid(iv),.in_ready(ir),
        .in_data(data),.in_group(group_index),.in_group_last(group_last),.start_groups(4'(GROUPS)),
        .in_x(x),.in_y(y),.in_sof(sof),.in_eol(eol),.in_eof(eof),
        .mem_req_valid(qv),.mem_req_ready(qr),.mem_req_addr(qa),.mem_req_data(qd),.mem_req_end(qe),
        .mem_rsp_valid(rv),.mem_rsp_ready(rr),.mem_rsp_error(re),
        .busy,.done,.aborted,.error,.error_code(code));
    tb_c1_tensor_packing_memory #(.EXTERNAL_DRIVER(1),.USE_END(1),.W_FIRST(W_FIRST),
        .WRITE_OUTSTANDING(SLOT_COUNT),.WRITE_BUILD_TIMEOUT(TIMEOUT)) physical();
    assign qr=physical.mem_req_ready && !block_req;
    assign rv=physical.mem_rsp_valid;
    assign re=physical.mem_rsp_error;
    initial begin
        force physical.clk=clk;force physical.rst=rst;
        force physical.mem_req_valid=admitted_valid;force physical.mem_req_write=1'b1;
        force physical.mem_req_addr=qa;force physical.mem_req_wdata=qd;
        force physical.mem_req_wstrb=8'hff;force physical.mem_req_end=qe;
        force physical.mem_rsp_ready=rr;force physical.hold_responses=hold_b;
        force physical.fault=inject_error;
        for(integer b=0;b<8192;b++)expected[b]=0;
    end
    function automatic logic [63:0] value(input integer index);
        value=64'h1234_abcd_9988_0000+epoch*65536+index*17+3;
    endfunction
    always @(posedge clk) if(!rst)begin
        if(sv && sr)begin requests=0;responses=0;ends=0;end
        if(qv && qr)begin
            if(qa!==base+requests*8 || qd!==value(requests) ||
               qe!==(((requests%(width*GROUPS))+1)%BATCH==0 || requests%(width*GROUPS)==width*GROUPS-1))
                $fatal(1,"physical pixel request/order/end mismatch index=%0d",requests);
            for(integer b=0;b<8;b++)expected[qa+b]=qd[b*8+:8];
            requests++;if(qe)ends++;
        end
        if(rv && rr)responses++;
        if(responses>requests)$fatal(1,"physical pixel unowned response");
    end
    task automatic start_job(input integer frame_width=17);
        begin
            @(negedge clk);while(!sr)@(negedge clk);
            if(physical.aws!=physical.bs || physical.aw_held || physical.w_count!=0)
                $fatal(1,"physical restart before B drain");
            epoch++;base=32'h1000+(epoch%4)*512;width=frame_width;sv=1;
            @(posedge clk);@(negedge clk);sv=0;
        end
    endtask
    task automatic send_pixel(input integer index,input bit malformed=0);
        begin
            @(negedge clk);x=(index/GROUPS)%width+malformed;y=index/(width*GROUPS);sof=index==0;
            group_index=index%GROUPS;group_last=index%GROUPS==GROUPS-1;
            eol=index%(width*GROUPS)==width*GROUPS-1;eof=index==width*height*GROUPS-1;data=value(index);iv=1;
            do @(posedge clk);while(!ir);
            @(negedge clk);iv=0;
        end
    endtask
    task automatic check_terminal(input integer count,input bit canceled,input integer error_code);
        begin
            wait(!busy);@(negedge clk);
            if(requests!=count || responses!=count || done!==!canceled || aborted!==canceled ||
               error!==(error_code!=0) || code!=error_code || physical.aws!=physical.bs ||
               physical.aw_held || physical.w_count!=0 || physical.b_valid_q)
                $fatal(1,"physical pixel terminal debt/status mismatch count=%0d req=%0d rsp=%0d code=%0d",count,requests,responses,code);
            for(integer b=0;b<8192;b++)if(physical.physical_mem[b]!==expected[b])
                $fatal(1,"physical pixel byte mismatch including guard regions at %0d",b);
        end
    endtask
    task automatic good_frame(input integer frame_width=17);
        integer old_aw;
        begin
            old_aw=physical.aws;start_job(frame_width);
            for(integer i=0;i<width*height*GROUPS;i++)send_pixel(i);
            check_terminal(width*height*GROUPS,0,0);frames++;
            if(ends!=((width*GROUPS+BATCH-1)/BATCH)*height)
                $fatal(1,"physical pixel row-tail end budget mismatch");
            // The driver has no voluntary gap, but downstream slot/credit
            // pressure can still stall it beyond a SHORT timeout. Require
            // full batches only for this BFM's explicitly long-timeout case.
            if(frame_width==16 && TIMEOUT>=64 && physical.aws-old_aw!=32*GROUPS/BATCH)
                $fatal(1,"aligned continuous pixels failed to form full batches aw=%0d expected=%0d",physical.aws-old_aw,32*GROUPS/BATCH);
            if(frame_width==16 && (physical.aws-old_aw<32*GROUPS/BATCH || physical.aws-old_aw>32*GROUPS))
                $fatal(1,"aligned pixel physical burst count outside packing bounds");
        end
    endtask
    initial begin
        repeat(6)@(negedge clk);rst=0;good_frame(16);good_frame();
        // Partial batch has NO terminal hint and no more producer data.
        // Both cancellation and malformed metadata must drain via timeout.
        for(integer mode=0;mode<3;mode++)begin
            hold_b=1;inject_error=mode==2;start_job();send_pixel(0);
            if(mode==0)abort=1;
            if(mode==1)send_pixel(1,1);
            wait(physical.aw_held && physical.w_complete);
            if(ends!=0 || requests!=1 || responses!=0)
                $fatal(1,"partial pixel batch test did not exercise absent end and real B debt");
            repeat(64)begin
                @(negedge clk);if(!busy || done || aborted || responses!=0)
                    $fatal(1,"partial pixel batch retired before real B");
            end
            hold_b=0;check_terminal(1,1,mode==1 ? 6 : (mode==2 ? 7 : 0));
            abort=0;inject_error=0;
            $display("C1_PIXEL_PACKING_PARTIAL_PASS mode=%0d end=0 held_b=64 reset=0",mode);
            good_frame();
        end
        // A presented partial request survives cancellation unchanged.
        block_req=1;hold_b=1;start_job();send_pixel(0);abort=1;
        repeat(9)begin @(negedge clk);if(!qv || qe || !busy)$fatal(1,"held partial end changed on abort");end
        block_req=0;wait(physical.aw_held && physical.w_complete);
        repeat(9)@(negedge clk);hold_b=0;check_terminal(1,1,0);abort=0;
        $display("C1_PIXEL_PACKING_HELD_PASS end=0 reset=0");good_frame();
        // Separately hold the physical response of the final odd-row tail.
        for(integer mode=0;mode<3;mode++)begin
            start_job();for(integer i=0;i<width*height*GROUPS-1;i++)send_pixel(i);
            wait(responses==width*height*GROUPS-1);@(negedge clk);hold_b=1;inject_error=mode==2;
            send_pixel(width*height*GROUPS-1);wait(physical.aw_held && physical.w_complete);
            if(mode==1)abort=1;
            repeat(64)begin
                @(negedge clk);if(!busy || done || aborted || responses!=width*height*GROUPS-1)
                    $fatal(1,"EOF pixel retired before physical B");
            end
            hold_b=0;check_terminal(width*height*GROUPS,mode!=0,mode==2 ? 7 : 0);
            abort=0;inject_error=0;
            $display("C1_PIXEL_PACKING_EOF_PASS mode=%0d held_b=64 reset=0",mode);good_frame();
        end
        $display("C1_PIXEL_WRITER_PACKING_PASS batch=%0d slots=%0d timeout=%0d w_first=%0d groups=%0d full_frames=%0d aw=%0d w=%0d b=%0d",
            BATCH,SLOT_COUNT,TIMEOUT,W_FIRST,GROUPS,frames,physical.aws,physical.ws,physical.bs);
        $finish;
    end
    initial begin #2000000;$fatal(1,"pixel packing bounded watchdog");end
endmodule
