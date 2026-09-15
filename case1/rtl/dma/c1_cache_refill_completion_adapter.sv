`timescale 1ns/1ps

// Board-independent completion adapter for a line-cache refill sink.
//
// c1_cache_refill_scheduler deliberately exposes only responses for requests
// which were accepted by its leaf.  That is the right contract for an
// ID-less, credit-based reader, but c1_window_line_cache_c8 has a stronger
// contract: once a refill request is accepted it must handshake exactly the
// declared number of words, even when a maintenance fence cancels the row.
//
// This adapter is the small ABI bridge between those contracts.  It merges
// scheduler word_* and drain_word_* into one refill_word_* stream.  If the
// scheduler reports abort/flush completion (or a command error) before all
// declared words have arrived, the adapter emits zero/error poison words for
// the unissued suffix.  The line cache can therefore finish its count and
// discard the poisoned row using its existing discard_refill_q path.
//
// The adapter accepts at most one command at a time.  It does not own AXI,
// alter scheduler epochs, or instantiate vendor primitives.  The command
// fields are forwarded unchanged to the scheduler; row/word_count/epoch are
// latched locally only for suffix generation and protocol checking.  A
// command is not retired until both the declared output count and one
// scheduler terminal token (cmd_done, abort_done, or flush_done) have been
// observed; all three token inputs are therefore required at integration.
module c1_cache_refill_completion_adapter #(
    parameter integer ADDR_W = 32,
    parameter integer DATA_W = 64,
    parameter integer EPOCH_W = 8,
    // A cancellation intentionally produces an error-marked refill suffix,
    // but it is not necessarily a structural protocol fault.  The historical
    // adapter treated every cancel as sticky protocol_error, which made a
    // line-cache stage permanently fall back after a normal frame flush.  Keep
    // that strict behavior as the default for existing users; exact burst
    // cache integrations can opt out while still observing refill_done_error.
    parameter bit CANCEL_IS_PROTOCOL_ERROR = 1'b1
) (
    input  logic                         clk,
    input  logic                         rst,

    // Refill command source (normally the line cache).
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [ADDR_W-1:0]            cmd_base_addr,
    input  logic [ADDR_W-1:0]            cmd_stride_bytes,
    input  logic [15:0]                  cmd_row,
    input  logic [15:0]                  cmd_word_count,
    input  logic [EPOCH_W-1:0]           cmd_epoch,

    // Forwarded command stream to c1_cache_refill_scheduler.
    output logic                         sched_cmd_valid,
    input  logic                         sched_cmd_ready,
    output logic [ADDR_W-1:0]            sched_cmd_base_addr,
    output logic [ADDR_W-1:0]            sched_cmd_stride_bytes,
    output logic [15:0]                  sched_cmd_row,
    output logic [15:0]                  sched_cmd_word_count,
    output logic [EPOCH_W-1:0]           sched_cmd_epoch,

    // Scheduler completion and maintenance tokens.
    input  logic                         sched_cmd_done,
    input  logic                         sched_cmd_done_error,
    input  logic [15:0]                  sched_cmd_done_row,
    input  logic [EPOCH_W-1:0]            sched_cmd_done_epoch,
    input  logic                         sched_abort_done,
    input  logic                         sched_flush_done,

    // Scheduler normal current-epoch word stream.
    input  logic                         sched_word_valid,
    output logic                         sched_word_ready,
    input  logic [DATA_W-1:0]            sched_word_data,
    input  logic                         sched_word_error,
    input  logic                         sched_word_last,
    input  logic [15:0]                  sched_word_row,
    input  logic [15:0]                  sched_word_index,
    input  logic [EPOCH_W-1:0]            sched_word_epoch,

    // Scheduler canceled/stale response stream.  This may be tied inactive
    // when the scheduler is instantiated with EMIT_DRAIN_WORDS=0.
    input  logic                         sched_drain_valid,
    output logic                         sched_drain_ready,
    input  logic [DATA_W-1:0]            sched_drain_data,
    input  logic                         sched_drain_error,
    input  logic                         sched_drain_last,
    input  logic [15:0]                  sched_drain_row,
    input  logic [15:0]                  sched_drain_index,
    input  logic [EPOCH_W-1:0]            sched_drain_epoch,

    // Unified exact-count refill stream for the line-cache sink.
    output logic                         refill_word_valid,
    input  logic                         refill_word_ready,
    output logic [DATA_W-1:0]             refill_word_data,
    output logic                         refill_word_error,
    output logic                         refill_word_last,
    output logic [15:0]                  refill_word_row,
    output logic [15:0]                  refill_word_index,
    output logic [EPOCH_W-1:0]            refill_word_epoch,

    // One-cycle completion for the unified declared-count stream.  The pulse
    // is delayed until the scheduler terminal token as well as the exact
    // count, so it is not an early AXI/row-done indication.
    output logic                         refill_done,
    output logic                         refill_done_error,
    output logic                         protocol_error,
    output logic                         active,
    output logic                         synthetic_active,
    output logic [15:0]                  emitted_count
);

    initial begin
        if (ADDR_W < 1)
            $fatal(1, "ADDR_W must be positive");
        if (DATA_W < 1)
            $fatal(1, "DATA_W must be positive");
        if (EPOCH_W < 1)
            $fatal(1, "EPOCH_W must be positive");
    end

    logic active_q, synthetic_q;
    // Keep the command active until both sides of the ABI have retired:
    // the exact declared word count and the scheduler's terminal token.  A
    // normal final word can precede sched_cmd_done by several cycles while
    // the AXI reader closes its last descriptor; accepting a new command in
    // that window would let the late token corrupt the new command.
    logic stream_complete_q, terminal_seen_q, terminal_error_q;
    logic [15:0] expected_words_q;
    logic [15:0] next_index_q;
    logic [15:0] row_q;
    logic [EPOCH_W-1:0] epoch_q;
    logic protocol_error_q;
    logic data_error_q;
    logic refill_done_q, refill_done_error_q;

    logic cmd_fire;
    logic normal_select, drain_select;
    logic source_fire, refill_fire, synthetic_fire;
    logic expected_last;
    logic cancel_event, scheduler_terminal_event;
    logic [16:0] retired_count;
    logic suffix_needed;
    logic terminal_event_error;
    logic stream_complete_now, terminal_seen_now;
    logic close_event, synthetic_close_event, close_error_now;
    logic source_last_bad;
    logic source_sideband_bad;
    logic source_data_error;
    logic cmd_done_sideband_bad;

    assign sched_cmd_base_addr = cmd_base_addr;
    assign sched_cmd_stride_bytes = cmd_stride_bytes;
    assign sched_cmd_row = cmd_row;
    assign sched_cmd_word_count = cmd_word_count;
    assign sched_cmd_epoch = cmd_epoch;

    // No second command is accepted until the exact-count output stream and
    // the scheduler terminal token have both completed.  Also leave one
    // quiet cycle around a terminal pulse: scheduler completion outputs are
    // registered pulses and may remain high during the cycle in which
    // active_q is cleared.  This prevents an idle/held token from being
    // mistaken for the next command's terminal event.
    assign cmd_ready = !rst && !active_q && !scheduler_terminal_event &&
                       sched_cmd_ready;
    assign sched_cmd_valid = !rst && !active_q && !scheduler_terminal_event &&
                             cmd_valid;
    assign cmd_fire = sched_cmd_valid && sched_cmd_ready;

    assign expected_last = (expected_words_q != 0) &&
                           (next_index_q == expected_words_q - 1'b1);

    // Normal has priority only as a defensive choice; the scheduler contract
    // requires the two streams to be mutually exclusive.  An assertion below
    // turns an accidental overlap into a visible simulation failure.
    assign normal_select = !rst && active_q && !synthetic_q && sched_word_valid;
    assign drain_select = !rst && active_q && !synthetic_q && !sched_word_valid &&
                          sched_drain_valid;
    assign source_fire = (normal_select && sched_word_ready) ||
                         (drain_select && sched_drain_ready);
    assign synthetic_fire = active_q && synthetic_q && refill_word_valid &&
                            refill_word_ready;
    assign refill_fire = source_fire || synthetic_fire;
    assign retired_count = {1'b0, next_index_q} +
                           (refill_fire ? 17'd1 : 17'd0);
    assign cancel_event = sched_abort_done || sched_flush_done;
    assign scheduler_terminal_event = sched_cmd_done || cancel_event;
    assign terminal_event_error = (sched_cmd_done && sched_cmd_done_error) ||
                                 (cancel_event && CANCEL_IS_PROTOCOL_ERROR);
    assign stream_complete_now = stream_complete_q ||
                                 (refill_fire && expected_last) ||
                                 (active_q && (expected_words_q == 0));
    assign terminal_seen_now = terminal_seen_q ||
                               (active_q && scheduler_terminal_event);
    assign suffix_needed = active_q && !synthetic_q &&
                           scheduler_terminal_event &&
                           (retired_count < {1'b0, expected_words_q});
    assign close_error_now = terminal_error_q || terminal_event_error ||
                             protocol_error_q || data_error_q ||
                             cmd_done_sideband_bad || source_last_bad ||
                             source_sideband_bad || source_data_error ||
                             (source_fire && drain_select);
    assign close_event = active_q && !synthetic_q && stream_complete_now &&
                         terminal_seen_now;
    assign synthetic_close_event = active_q && synthetic_q &&
                                   synthetic_fire && expected_last;
    assign source_last_bad = source_fire &&
                             ((normal_select ? sched_word_last :
                               sched_drain_last) != expected_last);
    assign source_sideband_bad = source_fire &&
        ((normal_select &&
          ((sched_word_index != next_index_q) ||
           (sched_word_row != row_q) || (sched_word_epoch != epoch_q))) ||
         (drain_select &&
         ((sched_drain_index != next_index_q) ||
           (sched_drain_row != row_q) || (sched_drain_epoch != epoch_q))));
    assign source_data_error = source_fire && normal_select &&
                               sched_word_error;
    assign cmd_done_sideband_bad = active_q && sched_cmd_done &&
        ((sched_cmd_done_row != row_q) ||
         (sched_cmd_done_epoch != epoch_q));

    always_comb begin
        sched_word_ready = 1'b0;
        sched_drain_ready = 1'b0;
        refill_word_valid = 1'b0;
        refill_word_data = '0;
        refill_word_error = 1'b0;
        refill_word_last = 1'b0;
        refill_word_row = row_q;
        refill_word_index = next_index_q;
        refill_word_epoch = epoch_q;

        if (normal_select) begin
            sched_word_ready = refill_word_ready;
            refill_word_valid = 1'b1;
            refill_word_data = sched_word_data;
            refill_word_error = sched_word_error || source_last_bad ||
                                source_sideband_bad;
            // Normalize LAST to the declared-count boundary.  A mismatch is
            // still reported through protocol_error, but the line-cache sink
            // always receives exactly one final marker.
            refill_word_last = expected_last;
            refill_word_row = sched_word_row;
            refill_word_index = sched_word_index;
            refill_word_epoch = sched_word_epoch;
        end else if (drain_select) begin
            sched_drain_ready = refill_word_ready;
            refill_word_valid = 1'b1;
            refill_word_data = sched_drain_data;
            refill_word_error = 1'b1 | sched_drain_error;
            refill_word_last = expected_last;
            refill_word_row = sched_drain_row;
            refill_word_index = sched_drain_index;
            refill_word_epoch = sched_drain_epoch;
        end else if (!rst && active_q && synthetic_q &&
                     (next_index_q < expected_words_q)) begin
            // Poison words complete the unissued suffix after a cancellation.
            refill_word_valid = 1'b1;
            refill_word_data = '0;
            refill_word_error = 1'b1;
            refill_word_last = expected_last;
            refill_word_row = row_q;
            refill_word_index = next_index_q;
            refill_word_epoch = epoch_q;
        end
    end

    assign refill_done = refill_done_q;
    assign refill_done_error = refill_done_error_q;
    assign protocol_error = protocol_error_q;
    assign active = active_q;
    assign synthetic_active = synthetic_q;
    assign emitted_count = next_index_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            active_q <= 1'b0;
            synthetic_q <= 1'b0;
            stream_complete_q <= 1'b0;
            terminal_seen_q <= 1'b0;
            terminal_error_q <= 1'b0;
            expected_words_q <= 16'd0;
            next_index_q <= 16'd0;
            row_q <= 16'd0;
            epoch_q <= '0;
            protocol_error_q <= 1'b0;
            data_error_q <= 1'b0;
            refill_done_q <= 1'b0;
            refill_done_error_q <= 1'b0;
        end else begin
            refill_done_q <= 1'b0;
            refill_done_error_q <= 1'b0;

            if (cmd_fire) begin
                active_q <= 1'b1;
                synthetic_q <= 1'b0;
                stream_complete_q <= (cmd_word_count == 0);
                terminal_seen_q <= 1'b0;
                terminal_error_q <= 1'b0;
                expected_words_q <= cmd_word_count;
                next_index_q <= 16'd0;
                row_q <= cmd_row;
                epoch_q <= cmd_epoch;
                protocol_error_q <= 1'b0;
                data_error_q <= 1'b0;
            end

            // The line-cache ABI has no zero-word terminal handshake.  Mark
            // such a declaration as an adapter error immediately as well as
            // relying on the scheduler's command reject token.
            if (cmd_fire && (cmd_word_count == 0)) begin
                protocol_error_q <= 1'b1;
                data_error_q <= 1'b1;
            end

            if (source_last_bad || source_sideband_bad)
                protocol_error_q <= 1'b1;
            if (cmd_done_sideband_bad)
                protocol_error_q <= 1'b1;
            if (source_data_error || cmd_done_sideband_bad)
                data_error_q <= 1'b1;

            // A normal command completion is deliberately a two-party
            // handshake: the scheduler token and the exact-count stream.  A
            // cancellation token is also an error token even when every
            // already-accepted response happened to drain before it arrived.
            if (active_q && scheduler_terminal_event) begin
                terminal_seen_q <= 1'b1;
                if (terminal_event_error || cmd_done_sideband_bad)
                    terminal_error_q <= 1'b1;
            end

            if (refill_fire) begin
                if (expected_words_q == 0) begin
                    // No valid output should be possible for a zero-length
                    // command.  Keep this as a defensive protocol fault; the
                    // actual completion is closed by the scheduler token.
                    protocol_error_q <= 1'b1;
                end else if (expected_last) begin
                    stream_complete_q <= 1'b1;
                    next_index_q <= next_index_q + 1'b1;
                end else begin
                    next_index_q <= next_index_q + 1'b1;
                end
            end

            // A scheduler terminal token before the declared count means the
            // remaining words were never accepted by the leaf.  Switch to a
            // held synthetic stream; its exact-count handshakes will retire
            // the adapter even though no more leaf responses exist.
            if (suffix_needed) begin
                synthetic_q <= 1'b1;
                if (CANCEL_IS_PROTOCOL_ERROR)
                    protocol_error_q <= 1'b1;
                terminal_seen_q <= 1'b1;
                terminal_error_q <= 1'b1;
            end

            // Close only after both exact-count and scheduler completion have
            // been observed.  close_event includes a same-cycle final source
            // handshake/token; synthetic_close_event handles a canceled
            // suffix whose final word is generated locally.
            if (close_event || synthetic_close_event) begin
                active_q <= 1'b0;
                synthetic_q <= 1'b0;
                refill_done_q <= 1'b1;
                refill_done_error_q <= close_error_now ||
                                       (synthetic_close_event ? 1'b1 : 1'b0);
                stream_complete_q <= 1'b0;
                terminal_seen_q <= 1'b0;
                terminal_error_q <= 1'b0;
                if (synthetic_close_event)
                    next_index_q <= next_index_q + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic out_stalled_q;
    logic [DATA_W+2+16+16+EPOCH_W-1:0] out_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            out_stalled_q <= 1'b0;
            out_payload_q <= '0;
        end else begin
            if (sched_word_valid && sched_drain_valid)
                $fatal(1, "completion adapter saw normal and drain valid together");
            if (out_stalled_q &&
                (!refill_word_valid ||
                 ({refill_word_data, refill_word_error, refill_word_last,
                   refill_word_row, refill_word_index, refill_word_epoch} !=
                  out_payload_q)))
                $fatal(1, "completion adapter changed stalled refill payload");
            if (refill_word_valid &&
                (refill_word_index >= expected_words_q))
                $fatal(1, "completion adapter emitted beyond declared count");
            out_stalled_q <= refill_word_valid && !refill_word_ready;
            out_payload_q <= {refill_word_data, refill_word_error,
                              refill_word_last, refill_word_row,
                              refill_word_index, refill_word_epoch};
        end
    end
`endif

endmodule
