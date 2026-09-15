`timescale 1ns/1ps

module tb_c1_event_cdc #(
    parameter realtime SRC_HALF=3.5, DST_HALF=5.5);
    localparam integer EVENTS = 1000;
    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;
    logic src_rst = 1'b1;
    logic dst_rst = 1'b1;
    logic src_pulse = 1'b0;
    logic src_ready;
    logic dst_pulse;
    logic [15:0] lfsr = 16'hd431;
    integer sent = 0;
    integer received = 0;
    integer src_cycles = 0;
    integer dst_cycles = 0;
    logic previous_dst_pulse = 1'b0;
    logic dst_run = 1'b1;
    integer pause_sent;
    logic pause_checked = 1'b0;

    always #(SRC_HALF) src_clk = ~src_clk;
    always #(DST_HALF) if(dst_run) dst_clk = ~dst_clk;

    c1_event_cdc dut (.*);

    initial begin
        repeat (7) @(negedge src_clk);
        src_rst = 1'b0;
        repeat (5) @(negedge dst_clk);
        dst_rst = 1'b0;
    end

    always @(negedge src_clk) begin
        src_cycles = src_cycles + 1;
        if (src_rst) begin
            src_pulse = 1'b0;
        end else begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            src_pulse = 1'b0;
            if ((sent < EVENTS) && src_ready && (lfsr[0] || lfsr[5])) begin
                src_pulse = 1'b1;
            end
        end
        if (src_cycles > 50000)
            $fatal(1, "event CDC source timeout sent=%0d received=%0d", sent, received);
    end

    // Count accepted events, not the earlier stimulus presentation.
    always @(posedge src_clk)
        if(!src_rst && src_pulse && src_ready) sent = sent + 1;

    initial begin
        wait(sent >= 100);
        @(negedge dst_clk); dst_run=0; pause_sent=sent;
        repeat(100) @(negedge src_clk);
        // At most one extra source handshake can use an ACK already in
        // flight. No further events can retire with the destination stopped.
        if(src_ready || sent-pause_sent>1)
            $fatal(1,"stopped destination failed source backpressure");
        dst_run=1; pause_checked=1;
    end

    always @(posedge dst_clk) begin
        #1;
        dst_cycles = dst_cycles + 1;
        if (!dst_rst && dst_pulse) begin
            if (previous_dst_pulse)
                $fatal(1, "event CDC dst_pulse wider than one cycle");
            if (received >= sent)
                $fatal(1, "event CDC duplicated or invented an event");
            received = received + 1;
        end
        previous_dst_pulse = !dst_rst && dst_pulse;
        if (dst_cycles > 50000)
            $fatal(1, "event CDC destination timeout sent=%0d received=%0d", sent, received);
    end

    initial begin
        wait (!src_rst && !dst_rst);
        wait (received == EVENTS);
        wait (src_ready);
        repeat (4) @(posedge dst_clk);
        if (sent != EVENTS || received != EVENTS || dst_pulse || !pause_checked)
            $fatal(1, "event CDC final count/state mismatch");
        $display("C1_EVENT_CDC_PASS events=%0d src_cycles=%0d dst_cycles=%0d pause_checked=1",
                 EVENTS, src_cycles, dst_cycles);
        $finish;
    end
endmodule
