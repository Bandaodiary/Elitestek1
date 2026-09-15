`timescale 1ns/1ps

module tb_c1_reset_sync;
    localparam integer STAGES = 3;

    logic clk;
    logic arst_n = 1'b0;
    logic srst_n;
    integer pulse_index;
    integer edge_index;

    c1_reset_sync #(
        .STAGES(STAGES)
    ) dut (
        .clk,
        .arst_n,
        .srst_n
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic release_and_check;
        begin
            @(negedge clk);
            #1 arst_n = 1'b1;
            for (edge_index = 0; edge_index < STAGES-1;
                 edge_index = edge_index + 1) begin
                @(posedge clk);
                #1;
                if (srst_n !== 1'b0)
                    $fatal(1, "reset released early at edge %0d", edge_index+1);
            end
            @(posedge clk);
            #1;
            if (srst_n !== 1'b1)
                $fatal(1, "reset did not release after %0d edges", STAGES);
        end
    endtask

    initial begin
        arst_n = 1'b0;
        #1;
        if (srst_n !== 1'b0)
            $fatal(1, "reset not asserted at startup");

        for (pulse_index = 0; pulse_index < 64;
             pulse_index = pulse_index + 1) begin
            release_and_check();

            // Assert away from a clock edge and require an asynchronous
            // response before the next rising edge.
            #(1 + (pulse_index % 3));
            arst_n = 1'b0;
            #1;
            if (srst_n !== 1'b0)
                $fatal(1, "asynchronous assertion failed at pulse %0d",
                       pulse_index);
        end

        $display("C1_RESET_SYNC_PASS pulses=64 stages=%0d", STAGES);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "reset synchronizer timeout");
    end
endmodule
