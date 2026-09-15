`timescale 1ns/1ps
module tb_c1_pixel_result_writer #(
    parameter integer CAPACITY=15, BATCH=1, FRAME_W=5, FRAME_H=4, GROUPS=1,
    parameter bit DYNAMIC_GROUPS=0
);
    integer configured_groups=GROUPS;
    logic [3:0] groups_bus=GROUPS;
    wire [31:0] PIXELS=FRAME_W*FRAME_H*configured_groups; // logical C8 words
    wire [31:0] ROW_WORDS=FRAME_W*configured_groups;
    logic clk=0,rst=1,abort=0,sv=0,sr,iv=0,ir;
    logic [31:0] base=0;logic [15:0] width=FRAME_W,height=FRAME_H;
    logic [63:0] data=0;logic [2:0] group_index=0;
    logic group_last=1;logic [15:0] x=0,y=0;logic sof=0,eol=0,eof=0;
    logic qv,qr=0,qe,rv=0,rr,re=0,busy,done,aborted,error;
    logic [31:0] qa;logic [63:0] qd;logic [7:0] code;
    bit hold_req=0,hold_rsp=0,inject_error=0;
    integer cycle=0,epoch=0,requests=0,responses=0,queued=0;
    integer peak=0,completed=0,ends=0;
    always #5 clk=~clk;
    c1_pixel_result_writer #(.MAX_PENDING(CAPACITY),.BATCH_WORDS(BATCH),.MULTI_GROUP(GROUPS!=1 || DYNAMIC_GROUPS)) dut (
        .clk,.rst,.abort,.start_valid(sv),.start_ready(sr),.start_base(base),
        .start_width(width),.start_height(height),.in_valid(iv),.in_ready(ir),
        .start_groups(groups_bus),
        .in_data(data),.in_group(group_index),.in_group_last(group_last),
        .in_x(x),.in_y(y),.in_sof(sof),.in_eol(eol),.in_eof(eof),
        .mem_req_valid(qv),.mem_req_ready(qr),.mem_req_addr(qa),.mem_req_data(qd),
        .mem_req_end(qe),
        .mem_rsp_valid(rv),.mem_rsp_ready(rr),.mem_rsp_error(re),
        .busy,.done,.aborted,.error,.error_code(code));
    function automatic logic [63:0] value(input integer index);
        value=64'hcafe000000000000 + epoch*65536 + index*13+7;
    endfunction
    // Responses become visible on a later half-cycle, never combinationally
    // in the request-accepting cycle. They represent real accepted writes.
    always @(negedge clk) begin
        qr=!rst && !hold_req && cycle%5!=2;
        rv=!rst && !hold_rsp && queued>0 && cycle%4!=1;
        re=inject_error;
    end
    always @(posedge clk) begin
        cycle++;
        if(rst) begin queued=0;requests=0;responses=0;peak=0;end
        else if(sv && sr) begin
            if(queued!=0)$fatal(1,"writer restarted before memory drained");
            requests=0;responses=0;peak=0;ends=0;
        end else begin
            if(rv && rr)begin responses++;queued--;end
            if(qv && qr) begin
                if(qa!==base+requests*8 || qd!==value(requests))
                    $fatal(1,"writer address/data order mismatch index=%0d",requests);
                // Independent raster arithmetic, not the writer's cursor.
                if(qe !== (((requests%ROW_WORDS)+1)%BATCH==0 || requests%ROW_WORDS==ROW_WORDS-1))
                    $fatal(1,"writer end hint mismatch index=%0d batch=%0d",requests,BATCH);
                if(qe)ends++;
                requests++;queued++;
            end
            if(queued<0 || queued>CAPACITY)$fatal(1,"writer unowned response or credit overflow");
            if(dut.reservations>peak)peak=dut.reservations;
        end
    end
    task automatic start_job(input integer forced_groups=-1);
        begin
            @(negedge clk);while(!sr)@(negedge clk);
            epoch++;base=32'h4000+epoch*2048;
            if(DYNAMIC_GROUPS)case(epoch%4)
                0:configured_groups=2;1:configured_groups=3;2:configured_groups=6;3:configured_groups=8;
            endcase
            else configured_groups=GROUPS;
            if(forced_groups>=0)configured_groups=forced_groups;
            groups_bus=configured_groups;sv=1;
            @(posedge clk);@(negedge clk);sv=0;
            // Invalid live bus values must not alter the START snapshot.
            groups_bus=0;
        end
    endtask
    task automatic drive_pixel(input integer index,input integer bad=-1);
        begin
            x=(index/configured_groups)%FRAME_W;y=index/ROW_WORDS;sof=index==0;eol=index%ROW_WORDS==ROW_WORDS-1;eof=index==PIXELS-1;
            data=value(index);group_index=index%configured_groups;group_last=index%configured_groups==configured_groups-1;
            case(bad)
                0:group_index=group_index+1;1:group_last=!group_last;2:x=x+1;3:y=y+1;
                4:sof=!sof;5:eol=!eol;6:eof=!eof;
                default:;
            endcase
        end
    endtask
    task automatic send_pixel(input integer index,input integer bad=-1);
        integer guard;
        begin
            @(negedge clk);drive_pixel(index,bad);iv=1;guard=0;
            do begin @(posedge clk);guard++;if(guard>1000)$fatal(1,"writer input timeout");end while(!ir);
            @(negedge clk);iv=0;
        end
    endtask
    task automatic good_frame;
        begin
            start_job();for(integer i=0;i<PIXELS;i++)send_pixel(i);
            wait(!busy);@(negedge clk);
            if(error || !done || requests!=PIXELS || responses!=PIXELS || queued!=0 ||
               ends!=((ROW_WORDS+BATCH-1)/BATCH)*FRAME_H)
                $fatal(1,"writer completed before the exact final write response");
            completed++;
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;good_frame();
        hold_req=1;hold_rsp=1;start_job();send_pixel(0);
        repeat(7)@(negedge clk);abort=1;
        repeat(7)begin @(negedge clk);if(!qv || !busy || done || aborted)$fatal(1,"writer canceled a held request");end
        abort=0;hold_req=0;wait(requests==1);repeat(5)@(negedge clk);
        if(!busy || done || aborted)$fatal(1,"writer canceled before write response");
        hold_rsp=0;wait(!busy);@(negedge clk);
        if(error || !aborted || requests!=1 || responses!=1)$fatal(1,"writer abort drain failed");
        $display("C1_PIXEL_WRITER_ABORT_PASS held_request=1 reset=0");good_frame();

        hold_rsp=1;start_job();for(integer i=0;i<CAPACITY;i++)send_pixel(i);
        repeat(10)@(negedge clk);
        if(dut.reservations!=CAPACITY || requests!=CAPACITY)$fatal(1,"writer capacity not exercised");
        drive_pixel(CAPACITY);iv=1;
        repeat(7)begin @(negedge clk);if(ir)$fatal(1,"writer exceeded total reservations");end
        inject_error=1;hold_rsp=0;wait(error);@(negedge clk);iv=0;inject_error=0;
        wait(!busy);@(negedge clk);
        if(code!=7 || done || requests!=CAPACITY || responses!=CAPACITY || queued!=0)
            $fatal(1,"writer failed to drain after a real accepted-write error");
        $display("C1_PIXEL_WRITER_CREDIT_ERROR_PASS capacity=%0d reset=0",CAPACITY);good_frame();

        // A response error must not withdraw a DIFFERENT, already-presented
        // write request. Capacity one cannot own both obligations at once.
        if(CAPACITY>1) begin
            hold_rsp=1;start_job();send_pixel(0);wait(requests==1);
            @(negedge clk);hold_req=1;send_pixel(1);
            inject_error=1;hold_rsp=0;wait(error);@(negedge clk);inject_error=0;
            repeat(7)begin
                @(negedge clk);
                if(!busy || !qv || qa!==base+8 || qd!==value(1) || done || aborted || ir)
                    $fatal(1,"writer response error withdrew a held next request");
            end
            hold_req=0;wait(!busy);@(negedge clk);
            if(code!=7 || !aborted || done || requests!=2 || responses!=2 || queued!=0)
                $fatal(1,"writer failed held-request error drain");
            $display("C1_PIXEL_WRITER_HELD_ERROR_PASS writes=2 reset=0");good_frame();
        end

        // EOF input admission is not completion. Hold its request, then its
        // real response; cover success, cancellation and a final B error.
        for(integer terminal=0;terminal<3;terminal++)begin
            start_job();for(integer i=0;i<PIXELS-1;i++)send_pixel(i);
            wait(responses==PIXELS-1);@(negedge clk);hold_req=1;hold_rsp=1;send_pixel(PIXELS-1);
            repeat(7)begin
                @(negedge clk);if(!busy || !qv || done || aborted || ir)
                    $fatal(1,"writer retired EOF before request acceptance");
            end
            hold_req=0;wait(requests==PIXELS);@(negedge clk);
            if(terminal==1)abort=1;
            repeat(7)begin
                @(negedge clk);if(!busy || done || aborted || ir)
                    $fatal(1,"writer retired EOF before its response");
            end
            inject_error=terminal==2;hold_rsp=0;wait(!busy);@(negedge clk);
            if(requests!=PIXELS || responses!=PIXELS || queued!=0 || done!==(terminal==0) ||
               aborted!==(terminal!=0) || error!==(terminal==2) || (terminal==2 && code!=7))
                $fatal(1,"writer EOF terminal status mismatch mode=%0d",terminal);
            if(terminal==0)completed++;
            abort=0;inject_error=0;
            $display("C1_PIXEL_WRITER_EOF_FENCE_PASS mode=%0d writes=%0d reset=0",terminal,PIXELS);good_frame();
        end

        for(integer bad=0;bad<7;bad++)begin
            start_job();for(integer i=0;i<3;i++)send_pixel(i);send_pixel(3,bad);
            wait(!busy);@(negedge clk);
            if(!error || code!=6 || done || requests!=3 || responses!=3)
                $fatal(1,"writer emitted malformed metadata field=%0d",bad);
            $display("C1_PIXEL_WRITER_METADATA_PASS field=%0d writes=3 reset=0",bad);
            good_frame();
        end
        if(GROUPS!=1 || DYNAMIC_GROUPS)begin
            for(integer invalid_index=0;invalid_index<2;invalid_index++)begin
                start_job(invalid_index==0 ? 0 : 9);wait(!busy);@(negedge clk);
                if(!aborted || !error || code!=6 || done || requests!=0 || responses!=0)
                    $fatal(1,"writer invalid group count escaped START validation");
                $display("C1_PIXEL_WRITER_GROUP_REJECT_PASS groups=%0d requests=0 reset=0",configured_groups);
                good_frame();
            end
        end
        $display("C1_PIXEL_RESULT_WRITER_PASS capacity=%0d batch=%0d width=%0d height=%0d groups=%0d dynamic=%0d full_frames=%0d",
                 CAPACITY,BATCH,FRAME_W,FRAME_H,GROUPS,DYNAMIC_GROUPS,completed);
        $finish;
    end
    initial begin #2000000;$fatal(1,"pixel writer watchdog");end
endmodule
