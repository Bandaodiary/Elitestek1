`timescale 1ns/1ps
module tb_c1_display_flush_reset #(parameter integer PIXEL_HALF=7);
    logic core_clk=0, pixel_clk=0, pixel_run=1;
    logic core_rst=1, pixel_rst=1, request=0, safe_to_flush=0;
    wire busy, done, core_soft_reset, pixel_soft_reset;
    integer completed=0, scenario;
    logic previous_done=0;
    always #5 core_clk=~core_clk;
    always #(PIXEL_HALF) if(pixel_run) pixel_clk=~pixel_clk;
    c1_display_flush_reset dut(.*);

    always @(posedge core_clk) begin
        #1;
        if(!core_rst) begin
            if(done && previous_done) $fatal(1,"flush done wider than one cycle");
            if(done) begin
                if(busy || core_soft_reset || pixel_soft_reset)
                    $fatal(1,"flush completed before both resets released");
                completed++;
            end
        end
        previous_done=done;
    end

    task automatic hold_core(input integer n, input logic expected_reset);
        repeat(n) begin
            @(negedge core_clk);
            if(!busy || done || core_soft_reset!==expected_reset)
                $fatal(1,"flush lost pending request/reset scenario=%0d",scenario);
        end
    endtask

    initial begin
        repeat(6) @(negedge pixel_clk);
        @(negedge core_clk); core_rst=0; pixel_rst=0;
        for(scenario=0; scenario<3; scenario++) begin
            @(negedge core_clk); request=1; safe_to_flush=0;
            @(negedge core_clk); request=0;
            // A one-cycle request must survive arbitrarily slow AXI drain.
            hold_core(23,0);
            if(pixel_soft_reset) $fatal(1,"pixel reset preceded safe-to-flush");
            if(scenario==1) begin
                @(negedge pixel_clk); pixel_run=0;
            end
            @(negedge core_clk); safe_to_flush=1;
            wait(core_soft_reset);
            if(scenario==1) begin
                hold_core(31,1);
                if(pixel_soft_reset) $fatal(1,"stopped pixel clock observed reset");
                pixel_run=1;
            end
            if(scenario==2) begin
                wait(pixel_soft_reset);
                // Stop low while reset is asserted; the returned high ACK
                // may reach core, but a low ACK cannot arrive until resumed.
                @(negedge pixel_clk); pixel_run=0;
                hold_core(31,1);
                if(!pixel_soft_reset) $fatal(1,"pixel reset released without clock");
                pixel_run=1;
            end
            wait(done);
            @(negedge core_clk);
            if(completed!=scenario+1) $fatal(1,"missing/duplicate flush completion");
            repeat(12) @(negedge core_clk);
            if(busy || done || core_soft_reset || pixel_soft_reset)
                $fatal(1,"flush did not remain idle after recovery");
        end
        $display("C1_DISPLAY_FLUSH_RESET_PASS half=%0d completions=%0d safe_wait=23 clock_pause=31",PIXEL_HALF,completed);
        $finish;
    end
    initial begin #100000; $fatal(1,"flush handshake timeout"); end
endmodule
