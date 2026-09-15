`timescale 1ns/1ps

// Board-independent QoS telemetry for the ID-less shared AXI fabric.
//
// This block is deliberately observation-only: it never drives VALID, READY,
// an owner select, or a payload.  It can therefore be enabled in a native
// portable-SoC build before the owner/epoch fence or any payload mux is
// enabled.  The counters are intended to answer the questions that cannot be
// answered from a single end-to-end frame time: which client is waiting for
// AR/AW, which client is holding R/B, how long an arbiter owner is retained,
// and whether a job crossed its measured deadline.
module c1_axi_shared_qos_monitor #(
    parameter integer CLIENTS = 7,
    parameter integer INDEX_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS),
    parameter integer COUNTER_W = 32
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         clear_stats,

    input  logic [CLIENTS-1:0]           awvalid,
    input  logic [CLIENTS-1:0]           awready,
    input  logic [CLIENTS-1:0]           wvalid,
    input  logic [CLIENTS-1:0]           wready,
    input  logic [CLIENTS-1:0]           bvalid,
    input  logic [CLIENTS-1:0]           bready,
    input  logic [CLIENTS-1:0]           arvalid,
    input  logic [CLIENTS-1:0]           arready,
    input  logic [CLIENTS-1:0]           rvalid,
    input  logic [CLIENTS-1:0]           rready,

    input  logic                         read_busy,
    input  logic                         read_quiescent,
    input  logic                         write_busy,
    input  logic                         write_quiescent,
    input  logic [INDEX_W-1:0]            read_owner,
    input  logic [INDEX_W-1:0]            write_owner,

    // A frame/job boundary is intentionally supplied by the integration
    // layer.  It may be a software/job handshake plus a tagged prefetch drain
    // or a committed display swap, but it is never a guessed pixel-domain
    // edge.  The portable SoC currently selects the tagged new-pair prefetch
    // completion, keeping this monitor reusable across different front ends.
    input  logic                         frame_start,
    input  logic                         frame_done,
    input  logic [COUNTER_W-1:0]          frame_deadline_cycles,
    input  logic                         display_underflow_event,

    output logic [CLIENTS-1:0][COUNTER_W-1:0] aw_accept_count,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] w_accept_count,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] b_accept_count,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] ar_accept_count,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] r_accept_count,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] aw_wait_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] w_wait_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] b_stall_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] ar_wait_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] r_stall_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] aw_wait_max,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] w_wait_max,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] b_stall_max,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] ar_wait_max,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] r_stall_max,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] read_owner_hold_total,
    output logic [CLIENTS-1:0][COUNTER_W-1:0] write_owner_hold_total,
    // Global maximum owner hold and the client that caused it.  Keeping the
    // run/max state scalar avoids a variable-indexed array writeback on the
    // critical path while the per-client totals above still identify the
    // aggregate owner share.
    output logic [COUNTER_W-1:0]       read_owner_hold_max,
    output logic [COUNTER_W-1:0]       write_owner_hold_max,
    output logic [INDEX_W-1:0]         read_owner_hold_max_owner,
    output logic [INDEX_W-1:0]         write_owner_hold_max_owner,
    output logic [COUNTER_W-1:0]       read_busy_cycles,
    output logic [COUNTER_W-1:0]       write_busy_cycles,
    output logic [COUNTER_W-1:0]       frame_count,
    output logic [COUNTER_W-1:0]       current_frame_cycles,
    output logic [COUNTER_W-1:0]       last_frame_cycles,
    output logic [COUNTER_W-1:0]       deadline_miss_count,
    output logic [COUNTER_W-1:0]       display_underflow_count,
    output logic [COUNTER_W-1:0]       protocol_error_count,
    output logic                       frame_active,
    output logic                       monitor_overflow,
    // Synchronous lifecycle cancellation, NOT a statistics reset. Tie low
    // in integrations without cancellation; do not leave this input open.
    input logic                        frame_abort
);

    // Per-frame wrap evidence is separate from the global diagnostic sticky
    // bit: other counters and previous frames must not imply this frame missed.
    logic frame_wrapped_q;
    logic [CLIENTS-1:0][COUNTER_W-1:0] aw_wait_run_q;
    logic [CLIENTS-1:0][COUNTER_W-1:0] w_wait_run_q;
    logic [CLIENTS-1:0][COUNTER_W-1:0] b_stall_run_q;
    logic [CLIENTS-1:0][COUNTER_W-1:0] ar_wait_run_q;
    logic [CLIENTS-1:0][COUNTER_W-1:0] r_stall_run_q;
    logic [COUNTER_W-1:0]              read_owner_run_q;
    logic [COUNTER_W-1:0]              write_owner_run_q;
    logic [INDEX_W-1:0]                read_owner_prev_q;
    logic [INDEX_W-1:0]                write_owner_prev_q;
    logic                              read_owner_prev_valid_q;
    logic                              write_owner_prev_valid_q;
    logic                              protocol_event_comb;

    integer i;

    // Packed {overflow, saturated_value} avoids output function arguments,
    // which some SystemVerilog simulators cannot elaborate.
    function automatic logic [COUNTER_W:0] sat_inc(
        input logic [COUNTER_W-1:0] value
    );
        begin
            if (&value) begin
                sat_inc = {1'b1,value};
            end else begin
                sat_inc = {1'b0,value + {{(COUNTER_W-1){1'b0}}, 1'b1}};
            end
        end
    endfunction

    // A small helper keeps all wait/run/max counters saturating.  Saturation
    // is preferable to wraparound because a long DDR stall must remain
    // visible in a post-mortem snapshot.
    task automatic bump_wait_counter(
        inout logic [COUNTER_W-1:0] total,
        inout logic [COUNTER_W-1:0] run,
        inout logic [COUNTER_W-1:0] max_run
    );
        logic ov_total, ov_run;
        logic [COUNTER_W-1:0] next_run;
        begin
            {ov_total,total} = sat_inc(total);
            {ov_run,next_run} = sat_inc(run);
            run = next_run;
            if (next_run > max_run)
                max_run = next_run;
            if (ov_total || ov_run)
                monitor_overflow <= 1'b1;
        end
    endtask

    task automatic bump_counter(
        inout logic [COUNTER_W-1:0] value
    );
        logic ov;
        begin
            {ov,value} = sat_inc(value);
            if (ov)
                monitor_overflow <= 1'b1;
        end
    endtask

    task automatic bump_owner_hold(
        inout logic [COUNTER_W-1:0] total,
        inout logic [COUNTER_W-1:0] run,
        inout logic [COUNTER_W-1:0] max_run,
        inout logic [INDEX_W-1:0]   max_owner,
        input logic [INDEX_W-1:0]   owner
    );
        logic ov_total, ov_run;
        logic [COUNTER_W-1:0] next_run;
        begin
            {ov_total,total} = sat_inc(total);
            {ov_run,next_run} = sat_inc(run);
            run = next_run;
            if (next_run > max_run) begin
                max_run = next_run;
                max_owner = owner;
            end
            if (ov_total || ov_run)
                monitor_overflow <= 1'b1;
        end
    endtask

    // Collapse all protocol anomalies into one event per clock.  The previous
    // implementation called the 32-bit increment task once for every anomaly
    // source in the same sequential block; synthesis consequently built a
    // serial chain of full-width adders on protocol_error_count.  A single
    // combinational event keeps the diagnostic counter off the critical path.
    always_comb begin
        protocol_event_comb = 1'b0;
        if (read_busy && (read_owner >= CLIENTS))
            protocol_event_comb = 1'b1;
        if (write_busy && (write_owner >= CLIENTS))
            protocol_event_comb = 1'b1;
        if (read_quiescent != !read_busy)
            protocol_event_comb = 1'b1;
        if (write_quiescent != !write_busy)
            protocol_event_comb = 1'b1;
        if (!frame_abort && frame_start && frame_active)
            protocol_event_comb = 1'b1;
        if (!frame_abort && frame_done && !frame_active && !frame_start)
            protocol_event_comb = 1'b1;
    end

    always_ff @(posedge clk) begin : telemetry_regs
        logic [COUNTER_W-1:0] next_frame_cycles;
        if (rst || clear_stats) begin
            aw_accept_count       <= '0;
            w_accept_count        <= '0;
            b_accept_count        <= '0;
            ar_accept_count       <= '0;
            r_accept_count        <= '0;
            aw_wait_total         <= '0;
            w_wait_total          <= '0;
            b_stall_total         <= '0;
            ar_wait_total         <= '0;
            r_stall_total         <= '0;
            aw_wait_max           <= '0;
            w_wait_max            <= '0;
            b_stall_max           <= '0;
            ar_wait_max           <= '0;
            r_stall_max           <= '0;
            read_owner_hold_total <= '0;
            write_owner_hold_total <= '0;
            read_owner_hold_max   <= '0;
            write_owner_hold_max  <= '0;
            read_owner_hold_max_owner <= '0;
            write_owner_hold_max_owner <= '0;
            read_busy_cycles      <= '0;
            write_busy_cycles     <= '0;
            frame_count           <= '0;
            current_frame_cycles  <= '0;
            last_frame_cycles     <= '0;
            deadline_miss_count   <= '0;
            display_underflow_count <= '0;
            protocol_error_count  <= '0;
            frame_active          <= 1'b0;
            frame_wrapped_q       <= 1'b0;
            monitor_overflow      <= 1'b0;
            aw_wait_run_q         <= '0;
            w_wait_run_q          <= '0;
            b_stall_run_q         <= '0;
            ar_wait_run_q         <= '0;
            r_stall_run_q         <= '0;
            read_owner_run_q      <= '0;
            write_owner_run_q     <= '0;
            read_owner_prev_q     <= '0;
            write_owner_prev_q    <= '0;
            read_owner_prev_valid_q <= 1'b0;
            write_owner_prev_valid_q <= 1'b0;
            // Software clears accumulated statistics, not an accepted job.
            // Preserve its full elapsed time so clearing mid-frame cannot
            // invent an orphan done or report a truncated successful duration.
            // Historical stats clear wins over a coincident terminal sample;
            // lifecycle transitions still occur (abort > start > done).
            if (!rst && !frame_abort) begin
                if (frame_start) begin
                    frame_active <= 1'b1;
                end else if (frame_active) begin
                    frame_active <= !frame_done;
                    current_frame_cycles <= current_frame_cycles + 1'b1;
                    frame_wrapped_q <= frame_wrapped_q || (&current_frame_cycles);
                    monitor_overflow <= frame_wrapped_q || (&current_frame_cycles);
                end
            end
        end else begin
            // Handshake and response-hold telemetry is sampled at the same
            // core-clock edge as the arbiter.  A VALID/!READY cycle is one
            // unit of wait/stall, while a VALID&READY edge is one accepted
            // transaction/beat.
            for (i = 0; i < CLIENTS; i = i + 1) begin
                if (awvalid[i] && awready[i]) bump_counter(aw_accept_count[i]);
                if (wvalid[i]  && wready[i])  bump_counter(w_accept_count[i]);
                if (bvalid[i]  && bready[i])  bump_counter(b_accept_count[i]);
                if (arvalid[i] && arready[i]) bump_counter(ar_accept_count[i]);
                if (rvalid[i]  && rready[i])  bump_counter(r_accept_count[i]);

                if (awvalid[i] && !awready[i])
                    bump_wait_counter(aw_wait_total[i], aw_wait_run_q[i],
                                      aw_wait_max[i]);
                else
                    aw_wait_run_q[i] <= '0;

                if (wvalid[i] && !wready[i])
                    bump_wait_counter(w_wait_total[i], w_wait_run_q[i],
                                      w_wait_max[i]);
                else
                    w_wait_run_q[i] <= '0;

                if (bvalid[i] && !bready[i])
                    bump_wait_counter(b_stall_total[i], b_stall_run_q[i],
                                      b_stall_max[i]);
                else
                    b_stall_run_q[i] <= '0;

                if (arvalid[i] && !arready[i])
                    bump_wait_counter(ar_wait_total[i], ar_wait_run_q[i],
                                      ar_wait_max[i]);
                else
                    ar_wait_run_q[i] <= '0;

                if (rvalid[i] && !rready[i])
                    bump_wait_counter(r_stall_total[i], r_stall_run_q[i],
                                      r_stall_max[i]);
                else
                    r_stall_run_q[i] <= '0;
            end

            if (read_busy)
                bump_counter(read_busy_cycles);
            if (write_busy)
                bump_counter(write_busy_cycles);

            // Owner hold is counted per selected client.  The owner status is
            // guarded before indexing so an uninitialized/illegal owner is
            // reported as a protocol error instead of creating an out-of-
            // range simulation access.
            if (read_busy) begin
                if (read_owner < CLIENTS) begin
                    if (read_owner_prev_valid_q &&
                        (read_owner_prev_q == read_owner)) begin
                        bump_owner_hold(read_owner_hold_total[read_owner],
                                        read_owner_run_q,
                                        read_owner_hold_max,
                                        read_owner_hold_max_owner,
                                        read_owner);
                    end else begin
                        bump_counter(read_owner_hold_total[read_owner]);
                        read_owner_run_q <= {{(COUNTER_W-1){1'b0}},1'b1};
                        if (read_owner_hold_max == '0) begin
                            read_owner_hold_max <=
                                {{(COUNTER_W-1){1'b0}},1'b1};
                            read_owner_hold_max_owner <= read_owner;
                        end
                    end
                    read_owner_prev_q <= read_owner;
                    read_owner_prev_valid_q <= 1'b1;
                end else begin
                    read_owner_prev_valid_q <= 1'b0;
                end
            end else begin
                read_owner_prev_valid_q <= 1'b0;
                read_owner_run_q <= '0;
            end

            if (write_busy) begin
                if (write_owner < CLIENTS) begin
                    if (write_owner_prev_valid_q &&
                        (write_owner_prev_q == write_owner)) begin
                        bump_owner_hold(write_owner_hold_total[write_owner],
                                        write_owner_run_q,
                                        write_owner_hold_max,
                                        write_owner_hold_max_owner,
                                        write_owner);
                    end else begin
                        bump_counter(write_owner_hold_total[write_owner]);
                        write_owner_run_q <= {{(COUNTER_W-1){1'b0}},1'b1};
                        if (write_owner_hold_max == '0) begin
                            write_owner_hold_max <=
                                {{(COUNTER_W-1){1'b0}},1'b1};
                            write_owner_hold_max_owner <= write_owner;
                        end
                    end
                    write_owner_prev_q <= write_owner;
                    write_owner_prev_valid_q <= 1'b1;
                end else begin
                    write_owner_prev_valid_q <= 1'b0;
                end
            end else begin
                write_owner_prev_valid_q <= 1'b0;
                write_owner_run_q <= '0;
            end

            if (protocol_event_comb)
                bump_counter(protocol_error_count);
            if (display_underflow_event)
                bump_counter(display_underflow_count);

            // Job-level deadline timer.  The terminal cycle is included in
            // last_frame_cycles and in the deadline comparison.  A zero
            // deadline disables the comparison, which is useful while the
            // board-specific measured budget is not known.
            // The frame timer uses a plain carry-chain increment.  Saturating
            // every diagnostic counter is useful, but putting a full-width
            // reduction/mux in front of the terminal frame snapshot created
            // an avoidable timing path.  Wrap is still reported explicitly as
            // monitor_overflow. Keep per-frame wrap evidence so a long frame
            // cannot wrap below its deadline and be classified as on time.
            next_frame_cycles = current_frame_cycles + 1'b1;
            if (!frame_abort && frame_active && !frame_start && (&current_frame_cycles))
                monitor_overflow <= 1'b1;
            if (frame_abort) begin
                // A canceled job is not a completed frame. Keep historical
                // counters and last completed duration, and continue observing
                // bus drain traffic above. Abort wins over start/done.
                frame_active <= 1'b0;
                current_frame_cycles <= '0;
                frame_wrapped_q <= 1'b0;
            end else if (frame_start) begin
                frame_active <= 1'b1;
                current_frame_cycles <= '0;
                frame_wrapped_q <= 1'b0;
            end else if (frame_active) begin
                current_frame_cycles <= next_frame_cycles;
                if (&current_frame_cycles) frame_wrapped_q <= 1'b1;
                if (frame_done) begin
                    last_frame_cycles <= next_frame_cycles;
                    bump_counter(frame_count);
                    if ((frame_deadline_cycles != '0) &&
                        (frame_wrapped_q || (&current_frame_cycles) ||
                         (next_frame_cycles > frame_deadline_cycles)))
                        bump_counter(deadline_miss_count);
                    frame_active <= 1'b0;
                end
            end else if (frame_done) begin
                // An orphan terminal pulse is accounted for by
                // protocol_event_comb above.
            end
        end
    end

`ifndef SYNTHESIS
    // A quiescent indication is a status contract, not a timing assumption.
    // Catch an integration wiring error early without constraining the data
    // path or requiring a vendor-specific assertion library.
    always_ff @(posedge clk) begin
        if (!rst && (read_quiescent != !read_busy ||
                     write_quiescent != !write_busy))
            $error("c1_axi_shared_qos_monitor: busy/quiescent mismatch");
    end
`endif

endmodule
