`timescale 1ns/1ps

module tb_c1_axi_shared_qos_monitor;
    localparam integer CLIENTS = 2;
    localparam integer COUNTER_W = 16;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear_stats = 1'b0;
    logic [CLIENTS-1:0] awvalid = '0, awready = '0;
    logic [CLIENTS-1:0] wvalid = '0, wready = '0;
    logic [CLIENTS-1:0] bvalid = '0, bready = '0;
    logic [CLIENTS-1:0] arvalid = '0, arready = '0;
    logic [CLIENTS-1:0] rvalid = '0, rready = '0;
    logic read_busy = 1'b0, write_busy = 1'b0;
    logic read_quiescent, write_quiescent;
    logic [0:0] read_owner = '0, write_owner = '0;
    logic frame_start = 1'b0, frame_done = 1'b0;
    logic frame_abort=0;
    logic [COUNTER_W-1:0] frame_deadline_cycles = 16'd3;
    logic display_underflow_event = 1'b0;

    logic [CLIENTS-1:0][COUNTER_W-1:0] aw_accept_count;
    logic [CLIENTS-1:0][COUNTER_W-1:0] w_accept_count;
    logic [CLIENTS-1:0][COUNTER_W-1:0] b_accept_count;
    logic [CLIENTS-1:0][COUNTER_W-1:0] ar_accept_count;
    logic [CLIENTS-1:0][COUNTER_W-1:0] r_accept_count;
    logic [CLIENTS-1:0][COUNTER_W-1:0] aw_wait_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] w_wait_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] b_stall_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] ar_wait_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] r_stall_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] aw_wait_max;
    logic [CLIENTS-1:0][COUNTER_W-1:0] w_wait_max;
    logic [CLIENTS-1:0][COUNTER_W-1:0] b_stall_max;
    logic [CLIENTS-1:0][COUNTER_W-1:0] ar_wait_max;
    logic [CLIENTS-1:0][COUNTER_W-1:0] r_stall_max;
    logic [CLIENTS-1:0][COUNTER_W-1:0] read_owner_hold_total;
    logic [CLIENTS-1:0][COUNTER_W-1:0] write_owner_hold_total;
    logic [COUNTER_W-1:0] read_owner_hold_max;
    logic [COUNTER_W-1:0] write_owner_hold_max;
    logic [0:0] read_owner_hold_max_owner;
    logic [0:0] write_owner_hold_max_owner;
    logic [COUNTER_W-1:0] read_busy_cycles, write_busy_cycles;
    logic [COUNTER_W-1:0] frame_count, current_frame_cycles;
    logic [COUNTER_W-1:0] last_frame_cycles, deadline_miss_count;
    logic [COUNTER_W-1:0] display_underflow_count, protocol_error_count;
    logic frame_active, monitor_overflow;

    always #5 clk = ~clk;
    assign read_quiescent = !read_busy;
    assign write_quiescent = !write_busy;

    c1_axi_shared_qos_monitor #(
        .CLIENTS(CLIENTS), .COUNTER_W(COUNTER_W)
    ) dut (
        .clk(clk), .rst(rst), .clear_stats(clear_stats),
        .awvalid(awvalid), .awready(awready),
        .wvalid(wvalid), .wready(wready),
        .bvalid(bvalid), .bready(bready),
        .arvalid(arvalid), .arready(arready),
        .rvalid(rvalid), .rready(rready),
        .read_busy(read_busy), .read_quiescent(read_quiescent),
        .write_busy(write_busy), .write_quiescent(write_quiescent),
        .read_owner(read_owner), .write_owner(write_owner),
        .frame_start(frame_start), .frame_done(frame_done),
        .frame_abort(frame_abort),
        .frame_deadline_cycles(frame_deadline_cycles),
        .display_underflow_event(display_underflow_event),
        .aw_accept_count(aw_accept_count), .w_accept_count(w_accept_count),
        .b_accept_count(b_accept_count), .ar_accept_count(ar_accept_count),
        .r_accept_count(r_accept_count), .aw_wait_total(aw_wait_total),
        .w_wait_total(w_wait_total), .b_stall_total(b_stall_total),
        .ar_wait_total(ar_wait_total), .r_stall_total(r_stall_total),
        .aw_wait_max(aw_wait_max), .w_wait_max(w_wait_max),
        .b_stall_max(b_stall_max), .ar_wait_max(ar_wait_max),
        .r_stall_max(r_stall_max),
        .read_owner_hold_total(read_owner_hold_total),
        .write_owner_hold_total(write_owner_hold_total),
        .read_owner_hold_max(read_owner_hold_max),
        .write_owner_hold_max(write_owner_hold_max),
        .read_owner_hold_max_owner(read_owner_hold_max_owner),
        .write_owner_hold_max_owner(write_owner_hold_max_owner),
        .read_busy_cycles(read_busy_cycles),
        .write_busy_cycles(write_busy_cycles), .frame_count(frame_count),
        .current_frame_cycles(current_frame_cycles),
        .last_frame_cycles(last_frame_cycles),
        .deadline_miss_count(deadline_miss_count),
        .display_underflow_count(display_underflow_count),
        .protocol_error_count(protocol_error_count),
        .frame_active(frame_active), .monitor_overflow(monitor_overflow)
    );

    task automatic wait_posedges(input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1)
                @(posedge clk);
            #1;
        end
    endtask

    // Advance the actual counter: do not force internal state at wrap boundaries.
    task automatic check_frame_boundary(input integer cycles,
        input logic [COUNTER_W-1:0] deadline,
        input bit expected_miss, input bit expected_overflow);
        logic [COUNTER_W-1:0] misses_before, frames_before;
        begin
            @(negedge clk);
            misses_before=deadline_miss_count; frames_before=frame_count;
            frame_deadline_cycles=deadline; frame_start=1;
            @(negedge clk); frame_start=0;
            repeat(cycles-1) @(negedge clk);
            frame_done=1;
            @(negedge clk); frame_done=0;
            if(frame_active || last_frame_cycles!==COUNTER_W'(cycles) ||
               frame_count!==frames_before+1'b1 ||
               deadline_miss_count!==misses_before+COUNTER_W'(expected_miss) ||
               monitor_overflow!==expected_overflow)
                $fatal(1,"frame boundary cycles=%0d deadline=%0d last=%0d miss_delta=%0d overflow=%b",
                    cycles,deadline,last_frame_cycles,deadline_miss_count-misses_before,monitor_overflow);
            repeat(3) @(negedge clk);
            if(monitor_overflow!==expected_overflow)
                $fatal(1,"idle frame timer fabricated overflow cycles=%0d",cycles);
        end
    endtask

    initial begin
        wait_posedges(3);
        rst = 1'b0;
        wait_posedges(1);

        // Three AW wait cycles followed by one accepted address.
        @(negedge clk); awvalid[0] = 1'b1; awready[0] = 1'b0;
        wait_posedges(3);
        @(negedge clk); awready[0] = 1'b1;
        wait_posedges(1);
        @(negedge clk); awvalid[0] = 1'b0; awready[0] = 1'b0;

        // Two AR wait cycles followed by one accepted address.
        @(negedge clk); arvalid[1] = 1'b1; arready[1] = 1'b0;
        wait_posedges(2);
        @(negedge clk); arready[1] = 1'b1;
        wait_posedges(1);
        @(negedge clk); arvalid[1] = 1'b0; arready[1] = 1'b0;

        // One W stall, two B stalls, and four R stalls.
        @(negedge clk); wvalid[0] = 1'b1; wready[0] = 1'b0;
        wait_posedges(1);
        @(negedge clk); wready[0] = 1'b1;
        wait_posedges(1);
        @(negedge clk); wvalid[0] = 1'b0; wready[0] = 1'b0;
        @(negedge clk); bvalid[0] = 1'b1; bready[0] = 1'b0;
        wait_posedges(2);
        @(negedge clk); bready[0] = 1'b1;
        wait_posedges(1);
        @(negedge clk); bvalid[0] = 1'b0; bready[0] = 1'b0;
        @(negedge clk); rvalid[1] = 1'b1; rready[1] = 1'b0;
        wait_posedges(4);
        @(negedge clk); rready[1] = 1'b1;
        wait_posedges(1);
        @(negedge clk); rvalid[1] = 1'b0; rready[1] = 1'b0;

        // Hold the selected read/write owners for measurable intervals.
        @(negedge clk); read_busy = 1'b1; read_owner = 1'b1;
        wait_posedges(4);
        @(negedge clk); read_busy = 1'b0;
        @(negedge clk); write_busy = 1'b1; write_owner = 1'b0;
        wait_posedges(3);
        @(negedge clk); write_busy = 1'b0;

        @(negedge clk); display_underflow_event = 1'b1;
        wait_posedges(1);
        @(negedge clk); display_underflow_event = 1'b0;

        // A five-cycle job against a three-cycle deadline must be recorded as
        // one miss, while the terminal cycle is included in the snapshot.
        @(negedge clk); frame_start = 1'b1;
        wait_posedges(1);
        @(negedge clk); frame_start = 1'b0;
        wait_posedges(4);
        @(negedge clk); frame_done = 1'b1;
        wait_posedges(1);
        @(negedge clk); frame_done = 1'b0;
        wait_posedges(1);

        if (aw_accept_count[0] !== 16'd1 || aw_wait_total[0] !== 16'd3 ||
            aw_wait_max[0] !== 16'd3)
            $fatal(1, "AW telemetry mismatch accept=%0d total=%0d max=%0d",
                   aw_accept_count[0], aw_wait_total[0], aw_wait_max[0]);
        if (ar_accept_count[1] !== 16'd1 || ar_wait_total[1] !== 16'd2 ||
            ar_wait_max[1] !== 16'd2)
            $fatal(1, "AR telemetry mismatch accept=%0d total=%0d max=%0d",
                   ar_accept_count[1], ar_wait_total[1], ar_wait_max[1]);
        if (w_wait_total[0] !== 16'd1 || b_stall_total[0] !== 16'd2 ||
            r_stall_total[1] !== 16'd4)
            $fatal(1, "response/request stall mismatch w=%0d b=%0d r=%0d",
                   w_wait_total[0], b_stall_total[0], r_stall_total[1]);
        if (read_owner_hold_total[1] !== 16'd4 ||
            write_owner_hold_total[0] !== 16'd3 ||
            read_busy_cycles !== 16'd4 || write_busy_cycles !== 16'd3)
            $fatal(1, "owner hold mismatch read=%0d/%0d write=%0d/%0d",
                   read_owner_hold_total[1], read_busy_cycles,
                   write_owner_hold_total[0], write_busy_cycles);
        if (read_owner_hold_max !== 16'd4 || read_owner_hold_max_owner !== 1'b1 ||
            write_owner_hold_max !== 16'd3 || write_owner_hold_max_owner !== 1'b0)
            $fatal(1, "owner maximum mismatch read=%0d/%0d write=%0d/%0d",
                   read_owner_hold_max, read_owner_hold_max_owner,
                   write_owner_hold_max, write_owner_hold_max_owner);
        if (display_underflow_count !== 16'd1 || frame_count !== 16'd1 ||
            deadline_miss_count !== 16'd1 || last_frame_cycles <= 16'd3 ||
            frame_active !== 1'b0 || protocol_error_count !== 16'd0)
            $fatal(1, "frame/underflow telemetry mismatch underflow=%0d frame=%0d last=%0d miss=%0d active=%0b protocol=%0d",
                   display_underflow_count, frame_count, last_frame_cycles,
                   deadline_miss_count, frame_active, protocol_error_count);

        // Software's clear-stats pulse is a synchronous control boundary.
        @(negedge clk); clear_stats = 1'b1;
        wait_posedges(1);
        @(negedge clk); clear_stats = 1'b0;
        wait_posedges(1);
        if (aw_accept_count[0] !== '0 || ar_wait_total[1] !== '0 ||
            frame_count !== '0 || display_underflow_count !== '0)
            $fatal(1, "clear_stats did not reset telemetry");

        // Boundary check of the portable packed return; no forcing of counters.
        if(dut.sat_inc(16'h0000)!==17'h00001 ||
           dut.sat_inc(16'hfffe)!==17'h0ffff ||
           dut.sat_inc(16'hffff)!==17'h1ffff)
            $fatal(1,"packed saturating increment value/overflow mismatch");
        $display("C1_QOS_SAT_INCREMENT_PASS boundaries=3");
        check_frame_boundary(65535,16'hffff,0,0);
        check_frame_boundary(65536,16'hffff,1,1);
        check_frame_boundary(65540,16'hffff,1,1);
        // A previous frame's overflow must not contaminate a short new frame.
        check_frame_boundary(2,16'd3,0,1);
        // Explicitly disabled deadline stays disabled, even across wrap.
        check_frame_boundary(65536,16'd0,0,1);
        @(negedge clk); clear_stats=1;
        @(negedge clk); clear_stats=0;
        check_frame_boundary(3,16'd3,0,0);
        check_frame_boundary(4,16'd3,1,0);
        $display("C1_QOS_FRAME_WRAP_PASS boundaries=7 idle_no_overflow=1 fresh_frame=1 clear_stats=1");
        begin : cancel_frame_checks
            logic [15:0] saved_frames,saved_misses,saved_last,saved_protocol,saved_aw;
            saved_frames=frame_count;saved_misses=deadline_miss_count;
            saved_last=last_frame_cycles;saved_protocol=protocol_error_count;
            saved_aw=aw_accept_count[0];
            @(negedge clk);frame_start=1;
            @(negedge clk);frame_start=0;
            repeat(5) @(negedge clk);
            frame_abort=1;
            awvalid[0]=1;awready[0]=1;
            @(negedge clk);
            awvalid[0]=0;awready[0]=0;
            if(frame_active || current_frame_cycles!==0 || frame_count!==saved_frames ||
               deadline_miss_count!==saved_misses || last_frame_cycles!==saved_last ||
               aw_accept_count[0]!==saved_aw+1'b1)
                $fatal(1,"canceled frame timer remains active or altered completed statistics");
            // Abort wins over a simultaneous start/done and can be held.
            frame_start=1;frame_done=1;
            repeat(3) @(negedge clk);
            frame_start=0;frame_done=0;frame_abort=0;
            check_frame_boundary(2,16'd3,0,0);
            if(frame_count!==saved_frames+1'b1 || deadline_miss_count!==saved_misses ||
               protocol_error_count!==saved_protocol)
                $fatal(1,"legal restart after cancellation reported reentry/protocol error");
            $display("C1_QOS_FRAME_ABORT_PASS canceled=1 held_abort=4 collisions=3 restart=1 stats_preserved=1 drain_traffic_counted=1");
        end
        begin : clear_live_frame
            logic [15:0] elapsed_before;
            @(negedge clk);frame_start=1;frame_deadline_cycles=100;
            @(negedge clk);frame_start=0;
            repeat(3) @(negedge clk);
            elapsed_before=current_frame_cycles;clear_stats=1;
            @(negedge clk);
            if(!frame_active || current_frame_cycles!==elapsed_before+1'b1 || frame_count!==0)
                $fatal(1,"clear_stats lost active frame ownership or elapsed time");
            @(negedge clk);clear_stats=0;frame_done=1;
            @(negedge clk);frame_done=0;
            if(frame_active || frame_count!==1 || last_frame_cycles!==elapsed_before+16'd3 || protocol_error_count!==0)
                $fatal(1,"completion after statistics clear became orphan/partial duration");
            // Clear coincident with start must still track the new lifecycle.
            clear_stats=1;frame_start=1;
            @(negedge clk);clear_stats=0;frame_start=0;frame_done=1;
            @(negedge clk);frame_done=0;
            if(frame_count!==1 || last_frame_cycles!==1 || protocol_error_count!==0)
                $fatal(1,"clear/start collision lost accepted job");
            frame_start=1;
            @(negedge clk);frame_start=0;clear_stats=1;frame_done=1;
            @(negedge clk);clear_stats=0;frame_done=0;
            if(frame_active || frame_count!==0 || last_frame_cycles!==0)
                $fatal(1,"clear/done priority contract violated");
            check_frame_boundary(2,16'd3,0,0);
            if(protocol_error_count!==0) $fatal(1,"restart after clear/done reported reentry");
            // Preserve evidence when the clear edge is also the wrap edge.
            clear_stats=1;frame_start=1;frame_deadline_cycles=16'hffff;
            @(negedge clk);clear_stats=0;frame_start=0;
            repeat(65535) @(negedge clk);
            if(current_frame_cycles!==16'hffff) $fatal(1,"clear/wrap setup missed boundary");
            clear_stats=1;
            @(negedge clk);
            if(!frame_active || current_frame_cycles!==0 || !monitor_overflow)
                $fatal(1,"clear/wrap lost active overflow evidence");
            clear_stats=0;frame_done=1;
            @(negedge clk);frame_done=0;
            if(frame_count!==1 || deadline_miss_count!==1 || last_frame_cycles!==1)
                $fatal(1,"clear/wrap caused missed deadline");
            clear_stats=1;frame_abort=1;frame_start=1;
            @(negedge clk);clear_stats=0;frame_abort=0;frame_start=0;
            if(frame_active || frame_count!==0 || current_frame_cycles!==0 || monitor_overflow)
                $fatal(1,"abort did not win clear/start collision");
            $display("C1_QOS_LIVE_CLEAR_PASS active_clear=2 start_collision=1 done_collision=1 full_duration=1 wrap_collision=1 abort_priority=1");
        end
        $display("C1_AXI_SHARED_QOS_MONITOR_PASS aw0_wait=3 ar1_wait=2 b0_stall=2 r1_stall=4 read_hold=4 write_hold=3 underflow=1 deadline_miss=1");
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "QoS monitor testbench timeout");
    end
endmodule
