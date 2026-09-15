`timescale 1ns/1ps

// Small-frame contract test for c1_window_line_cache_ctrl.
// It drives one 8x8 stride-1 3x3 SAME traversal and one 8x8-input stride-2
// traversal.  A refill handshake is accepted immediately; the DUT must hold
// a missed tap until its row is installed, then accept the retried tap.
module tb_c1_window_line_cache_ctrl;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic group_start;
    logic [15:0] frame_width, frame_height;
    logic tap_valid, tap_ready;
    logic [15:0] tap_x, tap_y;
    logic refill_valid, refill_ready, refill_fire;
    logic [15:0] refill_row;
    logic tap_fire, tap_hit, tap_miss;
    logic [63:0] tap_count, hit_count, miss_count, refill_count;
    logic [63:0] external_word_count;
    logic busy, quiescent;

    c1_window_line_cache_ctrl #(.LINE_ROWS(3)) dut (
        .clk(clk), .rst(rst), .group_start(group_start),
        .frame_width(frame_width), .frame_height(frame_height),
        .tap_valid(tap_valid), .tap_ready(tap_ready),
        .tap_x(tap_x), .tap_y(tap_y),
        .refill_valid(refill_valid), .refill_ready(refill_ready),
        .refill_row(refill_row), .tap_fire(tap_fire), .tap_hit(tap_hit),
        .tap_miss(tap_miss), .tap_count(tap_count), .hit_count(hit_count),
        .miss_count(miss_count), .refill_count(refill_count),
        .external_word_count(external_word_count), .busy(busy),
        .quiescent(quiescent)
    );

    assign refill_ready = 1'b1;
    assign refill_fire = refill_valid && refill_ready;

    task automatic start_group;
        begin
            @(negedge clk);
            group_start <= 1'b1;
            @(negedge clk);
            group_start <= 1'b0;
        end
    endtask

    task automatic send_tap(input integer x, input integer y);
        begin
            @(negedge clk);
            tap_x = x[15:0];
            tap_y = y[15:0];
            tap_valid = 1'b1;
            // Observe ready after a clock edge has settled, then wait for
            // the following edge where the level is sampled by the DUT.
            #1;
            while (!tap_ready) begin
                @(negedge clk);
                #1;
            end
            @(posedge clk);
            @(negedge clk);
            tap_valid = 1'b0;
        end
    endtask

    task automatic drive_stage(input integer stride);
        integer ox, oy, kx, ky;
        integer iy, ix;
        begin
            for (oy = 0; oy < (stride == 1 ? 8 : 4); oy = oy + 1) begin
                for (ox = 0; ox < (stride == 1 ? 8 : 4); ox = ox + 1) begin
                    for (ky = -1; ky <= 1; ky = ky + 1) begin
                        iy = oy * stride + ky;
                        if (iy < 0) iy = 0;
                        if (iy > 7) iy = 7;
                        for (kx = -1; kx <= 1; kx = kx + 1) begin
                            ix = ox * stride + kx;
                            if (ix < 0) ix = 0;
                            if (ix > 7) ix = 7;
                            send_tap(ix, iy);
                        end
                    end
                end
            end
        end
    endtask

    initial begin
        group_start = 1'b0;
        frame_width = 16'd8;
        frame_height = 16'd8;
        tap_valid = 1'b0;
        tap_x = 0;
        tap_y = 0;
        repeat (4) @(negedge clk);
        rst <= 1'b0;

        start_group();
        drive_stage(1);
        start_group();
        drive_stage(2);

        repeat (4) @(negedge clk);
        // 8x8 stride-1: 64 pixels*9 taps; 4x4 stride-2: 16*9 taps.
        if (tap_count != 64'd720 || hit_count != 64'd720 ||
            miss_count != 64'd16 || refill_count != 64'd16 ||
            external_word_count != 64'd128)
            $fatal(1, "line cache counters mismatch taps=%0d hits=%0d misses=%0d refills=%0d external=%0d",
                   tap_count, hit_count, miss_count, refill_count,
                   external_word_count);
        if (busy || !quiescent)
            $fatal(1, "line cache did not quiesce");
        $display("C1_WINDOW_LINE_CACHE_RTL_PASS taps=%0d hits=%0d misses=%0d refills=%0d external_words=%0d hit_rate_pct=%0f",
                 tap_count, hit_count, miss_count, refill_count,
                 external_word_count, (100.0 * hit_count) / tap_count);
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "line cache timeout");
    end
endmodule
