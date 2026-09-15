`timescale 1ns/1ps

// Boardless contract regression for c1_axi_shared_owner_epoch_fence.
// The read/write busy signals stand in for the real ID-less arbiter owners;
// no AXI payload memory is needed for this control-only gate.
module tb_c1_axi_shared_owner_epoch_fence;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic context_start_valid = 1'b0;
    logic context_start_ready;
    logic abort_req = 1'b0;
    logic flush_req = 1'b0;
    logic read_busy = 1'b0;
    logic read_quiescent = 1'b1;
    logic write_busy = 1'b0;
    logic write_quiescent = 1'b1;
    logic read_fire = 1'b0;
    logic write_fire = 1'b0;
    logic read_admit, write_admit, context_active;
    logic [3:0] current_epoch;
    logic fence_busy, abort_done, flush_done, epoch_bump;
    logic protocol_error;
    logic [63:0] perf_fence_count, perf_abort_count, perf_flush_count;
    integer cycles = 0;
    integer abort_pulses = 0;
    integer flush_pulses = 0;
    integer epoch_pulses = 0;

    c1_axi_shared_owner_epoch_fence #(
        .EPOCH_W(4), .REQUIRE_CONTEXT(1'b1), .ALLOW_RESTART(1'b1)
    ) dut (
        .clk(clk), .rst(rst),
        .context_start_valid(context_start_valid),
        .context_start_ready(context_start_ready),
        .abort_req(abort_req), .flush_req(flush_req),
        .read_busy(read_busy), .read_quiescent(read_quiescent),
        .write_busy(write_busy), .write_quiescent(write_quiescent),
        .read_fire(read_fire), .write_fire(write_fire),
        .read_admit(read_admit), .write_admit(write_admit),
        .context_active(context_active), .current_epoch(current_epoch),
        .fence_busy(fence_busy), .abort_done(abort_done),
        .flush_done(flush_done), .epoch_bump(epoch_bump),
        .protocol_error(protocol_error),
        .perf_fence_count(perf_fence_count),
        .perf_abort_count(perf_abort_count),
        .perf_flush_count(perf_flush_count)
    );

    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            if (abort_done) abort_pulses = abort_pulses + 1;
            if (flush_done) flush_pulses = flush_pulses + 1;
            if (epoch_bump) epoch_pulses = epoch_pulses + 1;
        end
    end

    task automatic fail(input string message);
        begin
            $display("C1_AXI_SHARED_OWNER_EPOCH_FENCE_FAIL %s", message);
            $fatal(1, "%s", message);
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            context_start_valid <= 1'b1;
            while (!context_start_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            context_start_valid <= 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        if (!context_start_ready || read_admit || write_admit)
            fail("idle gate did not expose start-only state");
        pulse_start();
        if (!context_active || current_epoch !== 4'd0)
            fail("context start/initial epoch mismatch");
        if (!read_admit || !write_admit)
            fail("admission did not open after context start");

        // An accepted read remains in flight while abort is raised.  The
        // current cycle is admitted; the next cycle must be fenced.
        @(negedge clk);
        read_fire <= 1'b1;
        read_busy <= 1'b1;
        read_quiescent <= 1'b0;
        @(posedge clk);
        @(negedge clk);
        read_fire <= 1'b0;
        abort_req <= 1'b1;
        #1;
        if (read_admit || write_admit || context_start_ready)
            fail("abort edge did not close admissions");
        @(posedge clk);
        #1;
        if (!fence_busy || read_admit || write_admit)
            fail("abort fence failed to enter drain");

        // Keep the read owner busy for one cycle, then release both owners.
        @(negedge clk);
        read_busy <= 1'b0;
        read_quiescent <= 1'b1;
        @(posedge clk);
        #1;
        if (!abort_done || !epoch_bump || current_epoch !== 4'd1 ||
            context_active || perf_abort_count != 1 ||
            perf_fence_count != 1)
            fail("abort drain completion/epoch mismatch");
        @(negedge clk);
        abort_req <= 1'b0;

        pulse_start();
        if (!context_active || current_epoch !== 4'd1)
            fail("restart after abort failed");

        // Flush waits for the write owner but preserves context_active.
        @(negedge clk);
        write_busy <= 1'b1;
        write_quiescent <= 1'b0;
        flush_req <= 1'b1;
        #1;
        if (read_admit || write_admit)
            fail("flush edge left admission open");
        @(posedge clk);
        @(negedge clk);
        flush_req <= 1'b0;
        write_busy <= 1'b0;
        write_quiescent <= 1'b1;
        @(posedge clk);
        #1;
        if (!flush_done || !epoch_bump || current_epoch !== 4'd2 ||
            !context_active || perf_flush_count != 1 ||
            perf_fence_count != 2)
            fail("flush drain completion/epoch mismatch");

        // Simultaneous abort+flush is acknowledged by both tokens but bumps
        // the generation only once.
        @(negedge clk);
        abort_req <= 1'b1;
        flush_req <= 1'b1;
        #1;
        @(posedge clk);
        @(negedge clk);
        abort_req <= 1'b0;
        flush_req <= 1'b0;
        @(posedge clk);
        #1;
        if (!abort_done || !flush_done || !epoch_bump ||
            current_epoch !== 4'd3 || context_active ||
            perf_abort_count != 2 || perf_flush_count != 2 ||
            perf_fence_count != 3)
            fail("simultaneous abort/flush did not coalesce");

        // Let the monitor observe the one-cycle done/epoch pulses before the
        // final pulse-count assertion.
        @(posedge clk);
        #1;

        if (protocol_error || perf_fence_count != 3 ||
            perf_abort_count != 2 || perf_flush_count != 2 ||
            abort_pulses != 2 || flush_pulses != 2 || epoch_pulses != 3)
            fail("diagnostic counters/protocol bit mismatch");

        $display("C1_AXI_SHARED_OWNER_EPOCH_FENCE_PASS abort=%0d flush=%0d epoch=%0d fence_count=%0d cycles=%0d",
                 abort_pulses, flush_pulses, current_epoch,
                 perf_fence_count, cycles);
        $finish;
    end

    initial begin
        #20000;
        fail("timeout");
    end
endmodule
