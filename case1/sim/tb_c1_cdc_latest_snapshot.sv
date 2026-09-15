`timescale 1ns/1ps
module tb_c1_cdc_latest_snapshot #(parameter integer SH=3, DH=7);
    logic src_clk=0, dst_clk=0, src_rst=1, dst_rst=1, run_dst=1, run_src=1;
    logic [40:0] src_data=0;
    wire [40:0] dst_data;
    wire dst_valid, dst_update;
    logic [40:0] expected[0:4095];
    logic [40:0] held;
    integer sent=0, received=0, epoch, i, before_sent, reset_phase, release_order;
    always #(SH) if(run_src) src_clk=~src_clk;
    always #(DH) if(run_dst) dst_clk=~dst_clk;
    c1_cdc_latest_snapshot dut(.*);
    function automatic [40:0] pattern(input integer n);
        pattern={8'(n^8'ha7),32'(n),^(32'(n))};
    endfunction
    always @(posedge src_clk) begin
        if(!src_rst) begin
            if(dut.src_accept) begin
                expected[sent]=src_data; sent++;
            end
            held=dut.payload_q;
            if(!dut.src_ready) begin
                #1;
                if(dut.payload_q!==held) $fatal(1,"bundled payload changed before ACK");
            end
        end
    end
    always @(posedge dst_clk) begin
        #1;
        if(!dst_rst && dst_update) begin
            if(!dst_valid || received>=sent || dst_data!==expected[received])
                $fatal(1,"snapshot mismatch sent=%0d received=%0d",sent,received);
            received++;
        end
    end
    task automatic reset_outstanding(input bit delivered, input integer order);
        integer old_sent, old_received;
        begin
            wait(dut.src_ready);
            @(negedge dst_clk);run_dst=0;
            @(negedge src_clk);
            old_sent=sent;old_received=received;
            src_data=pattern(2000+delivered*10+order);
            @(posedge src_clk);#2;run_src=0;
            if(sent!=old_sent+1 || received!=old_received || dut.src_ready)
                $fatal(1,"reset test missed pending-request phase");
            if(delivered) begin
                run_dst=1;
                repeat(8) @(negedge dst_clk);
                if(received!=old_received+1 || dut.src_ready)
                    $fatal(1,"reset test missed returned-ACK phase");
            end
            // Assert both resets before restarting stopped clocks. Each
            // domain must actually sample reset; a pulse with no clock is not
            // a reset for this synchronous-reset block.
            src_rst=1;dst_rst=1;run_src=1;run_dst=1;
            repeat(6) @(negedge dst_clk);
            repeat(6) @(negedge src_clk);
            if(dst_valid!==0 || dst_update!==0 || dst_data!==0 ||
               dut.request_q!==0 || dut.acknowledge_q!==0)
                $fatal(1,"coordinated reset did not clear link state");
            sent=0;received=0;src_data=pattern(3000+delivered*10+order);
            if(order==1) begin
                src_rst=0;
                repeat(6) @(negedge src_clk);
                @(negedge dst_clk);dst_rst=0;
            end else if(order==2) begin
                dst_rst=0;
                repeat(6) @(negedge dst_clk);
                @(negedge src_clk);src_rst=0;
            end else begin
                src_rst=0;dst_rst=0;
            end
            wait(dst_valid && dst_data===src_data);
            wait(dut.src_ready);
            repeat(12) @(negedge src_clk);
            repeat(12) @(negedge dst_clk);
            if(sent!=1 || received!=1)
                $fatal(1,"pre-reset snapshot leaked or fresh snapshot duplicated");
        end
    endtask
    initial begin
        // Exercise reset of an idle link and coordinated reset after activity.
        for(epoch=0;epoch<2;epoch++) begin
            src_rst=1;dst_rst=1;
            repeat(6) @(negedge dst_clk);
            @(negedge src_clk); sent=0;received=0;src_data=0;
            src_rst=0;dst_rst=0;
            for(i=1;i<=300;i++) begin
                @(negedge src_clk); src_data=pattern(i+epoch*1000);
            end
            @(negedge dst_clk);run_dst=0;before_sent=sent;
            for(i=301;i<=400;i++) begin
                @(negedge src_clk);src_data=pattern(i+epoch*1000);
            end
            if(sent-before_sent>1) $fatal(1,"missing stopped-clock backpressure");
            run_dst=1;
            wait(dst_valid && dst_data===src_data);
            wait(dut.src_ready);
            repeat(12) @(negedge src_clk);
            if(sent!=received || sent>=400) $fatal(1,"lost accepted snapshot or no coalescing");

            // Stop the source after a real acceptance, before ACK can return.
            // Changes on its input while stopped must not change the held bus.
            @(negedge src_clk);before_sent=sent;src_data=pattern(500+epoch*1000);
            @(posedge src_clk);#2;run_src=0;
            if(sent!=before_sent+1 || dut.src_ready)
                $fatal(1,"source-stop test did not catch an outstanding request");
            for(i=0;i<20;i++) begin
                @(negedge dst_clk);src_data=pattern(600+i+epoch*1000);
                if(dut.payload_q!==pattern(500+epoch*1000))
                    $fatal(1,"stopped source changed held payload");
            end
            if(sent!=before_sent+1 || received!=sent ||
               dst_data!==pattern(500+epoch*1000))
                $fatal(1,"stopped source caused missing/duplicate/torn snapshot");
            run_src=1;
            wait(dst_valid && dst_data===src_data);
            wait(dut.src_ready);
            repeat(12) @(negedge src_clk);
            if(sent!=before_sent+2 || received!=sent)
                $fatal(1,"source restart did not coalesce to one latest snapshot");
        end
        $display("C1_CDC_SOURCE_STOP_PASS epochs=2 held_dst_cycles=20 resumed_latest=1");
        $display("C1_CDC_LATEST_SNAPSHOT_PASS sh=%0d dh=%0d epochs=2 sent=%0d received=%0d",SH,DH,sent,received);
        for(reset_phase=0;reset_phase<2;reset_phase++)
            for(release_order=0;release_order<3;release_order++)
                reset_outstanding(reset_phase!=0,release_order);
        $display("C1_CDC_PENDING_RESET_PASS phases=2 release_orders=3 fresh_updates=1");
        $finish;
    end
    initial begin #1000000;$fatal(1,"snapshot timeout");end
endmodule
