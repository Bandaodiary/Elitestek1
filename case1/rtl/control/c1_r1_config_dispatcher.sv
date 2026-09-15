`timescale 1ns/1ps

// Active configuration dispatcher for the dedicated R1 streaming stage graph.
//
// c1_r1_config_loader_subsystem commits a complete descriptor batch into its
// active bank before a frame may launch.  This module is the runtime client of
// that bank: one accepted start snapshots active_count/generation, reads each
// descriptor exactly once, and forwards it to the corresponding physical
// stage through a ready/valid interface.  It can therefore connect directly to
// the descriptor busy/done/error participant of c1_r1_job_frontend.
//
// The active configuration is immutable for the lifetime of a dispatched
// frame.  A generation change is a system integration fault.  If it is first
// observed while a stage descriptor is stalled, the held ready/valid payload
// is not retracted; the fault is reported immediately after that transfer so
// the job controller can abort the engine without violating payload stability.
//
// READ_TIMEOUT_CYCLES==0 disables the local bank-read timeout.  The enclosing
// job watchdog remains responsible for an indefinitely stalled stage sink.
module c1_r1_config_dispatcher #(
    parameter integer MAX_STAGES          = 22,
    parameter integer COUNT_BITS          = 16,
    parameter integer GENERATION_BITS     = 8,
    parameter integer READ_TIMEOUT_CYCLES = 256
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         start,
    output logic                         start_ready,
    input  logic                         abort,

    input  logic [COUNT_BITS-1:0]        active_count,
    input  logic [GENERATION_BITS-1:0]   active_generation,

    output logic                         config_read_enable,
    output logic [COUNT_BITS-1:0]        config_read_index,
    input  logic                         config_read_ready,
    input  logic                         config_read_busy,
    input  logic                         config_read_valid,
    input  logic [511:0]                 config_read_descriptor,
    input  logic [GENERATION_BITS-1:0]   config_read_generation,

    output logic                         stage_config_valid,
    input  logic                         stage_config_ready,
    output logic [COUNT_BITS-1:0]        stage_config_index,
    output logic [511:0]                 stage_config_descriptor,
    output logic [GENERATION_BITS-1:0]   stage_config_generation,

    output logic                         busy,
    output logic                         done,
    output logic                         error,
    output logic                         aborted,
    output logic [7:0]                   error_code,
    output logic [31:0]                  error_address
);

    localparam logic [7:0] ERR_NONE                = 8'h00;
    localparam logic [7:0] ERR_COUNT_ZERO          = 8'h51;
    localparam logic [7:0] ERR_COUNT_RANGE         = 8'h52;
    localparam logic [7:0] ERR_GENERATION_CHANGED  = 8'h53;
    localparam logic [7:0] ERR_RESPONSE_GENERATION = 8'h54;
    localparam logic [7:0] ERR_READ_TIMEOUT        = 8'h55;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_ISSUE_READ,
        STATE_WAIT_READ,
        STATE_SEND,
        STATE_DRAIN_READ
    } state_t;

    typedef enum logic {
        DRAIN_ERROR,
        DRAIN_ABORT
    } drain_reason_t;

    state_t state;
    drain_reason_t drain_reason_q;
    logic [COUNT_BITS-1:0] count_q;
    logic [COUNT_BITS-1:0] index_q;
    logic [GENERATION_BITS-1:0] generation_q;
    logic [511:0] descriptor_q;
    logic generation_fault_pending_q;
    logic [31:0] read_wait_count_q;

    logic start_fire;
    logic read_fire;
    logic stage_fire;
    logic read_timeout;
    logic generation_changed;
    logic read_interface_idle;

    always_comb begin
        read_interface_idle = !config_read_busy && !config_read_valid;
        // Compute the generation guard before any combinational request uses
        // it.  Keeping this assignment ahead of config_read_enable avoids a
        // one-delta stale value when active_generation changes while READY is
        // high in STATE_ISSUE_READ.
        generation_changed = (active_generation != generation_q);
        start_ready = !rst && !abort && (state == STATE_IDLE) &&
                      read_interface_idle;
        start_fire = start && start_ready;

        busy = (state != STATE_IDLE);

        // The stage bank names this signal ENABLE rather than VALID.  Match
        // its native contract and issue a one-cycle request only when READY
        // is already observed; no request payload is exposed while stalled.
        config_read_enable = (state == STATE_ISSUE_READ) && !abort &&
                             !generation_changed && config_read_ready;
        config_read_index = index_q;
        read_fire = config_read_enable;

        stage_config_valid = (state == STATE_SEND) && !abort;
        stage_config_index = index_q;
        stage_config_descriptor = descriptor_q;
        stage_config_generation = generation_q;
        stage_fire = stage_config_valid && stage_config_ready;

        read_timeout = (READ_TIMEOUT_CYCLES != 0) &&
                       (read_wait_count_q >= READ_TIMEOUT_CYCLES - 1);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            drain_reason_q <= DRAIN_ERROR;
            count_q <= '0;
            index_q <= '0;
            generation_q <= '0;
            descriptor_q <= '0;
            generation_fault_pending_q <= 1'b0;
            read_wait_count_q <= 32'd0;
            done <= 1'b0;
            error <= 1'b0;
            aborted <= 1'b0;
            error_code <= ERR_NONE;
            error_address <= 32'd0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;
            aborted <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    read_wait_count_q <= 32'd0;
                    generation_fault_pending_q <= 1'b0;
                    if (start_fire) begin
                        error_code <= ERR_NONE;
                        error_address <= 32'd0;
                        count_q <= active_count;
                        index_q <= '0;
                        generation_q <= active_generation;
                        if (active_count == {COUNT_BITS{1'b0}}) begin
                            error <= 1'b1;
                            error_code <= ERR_COUNT_ZERO;
                            error_address <= 32'd0;
                        end else if ($unsigned(active_count) > MAX_STAGES) begin
                            error <= 1'b1;
                            error_code <= ERR_COUNT_RANGE;
                            error_address <= {{(32-COUNT_BITS){1'b0}},
                                              active_count};
                        end else begin
                            state <= STATE_ISSUE_READ;
                        end
                    end
                end

                STATE_ISSUE_READ: begin
                    if (abort) begin
                        state <= STATE_IDLE;
                        aborted <= 1'b1;
                    end else if (generation_changed) begin
                        state <= STATE_IDLE;
                        error <= 1'b1;
                        error_code <= ERR_GENERATION_CHANGED;
                        error_address <= {{(32-COUNT_BITS){1'b0}}, index_q};
                    end else if (read_fire) begin
                        read_wait_count_q <= 32'd0;
                        // SYNC_READ=0 config banks return VALID and payload
                        // combinationally on the ENABLE edge.  Capture that
                        // zero-latency response here; synchronous wide/narrow
                        // banks take the ordinary WAIT_READ path.
                        if (config_read_valid) begin
                            if (config_read_generation != generation_q) begin
                                error <= 1'b1;
                                error_code <= ERR_RESPONSE_GENERATION;
                                error_address <=
                                    {{(32-COUNT_BITS){1'b0}}, index_q};
                                state <= STATE_IDLE;
                            end else begin
                                descriptor_q <= config_read_descriptor;
                                generation_fault_pending_q <= 1'b0;
                                state <= STATE_SEND;
                            end
                        end else begin
                            state <= STATE_WAIT_READ;
                        end
                    end else if (read_timeout) begin
                        state <= STATE_IDLE;
                        error <= 1'b1;
                        error_code <= ERR_READ_TIMEOUT;
                        error_address <= {{(32-COUNT_BITS){1'b0}}, index_q};
                    end else begin
                        read_wait_count_q <= read_wait_count_q + 1'b1;
                    end
                end

                STATE_WAIT_READ: begin
                    if (abort) begin
                        drain_reason_q <= DRAIN_ABORT;
                        state <= STATE_DRAIN_READ;
                    end else if (generation_changed) begin
                        drain_reason_q <= DRAIN_ERROR;
                        error_code <= ERR_GENERATION_CHANGED;
                        error_address <= {{(32-COUNT_BITS){1'b0}}, index_q};
                        state <= STATE_DRAIN_READ;
                    end else if (config_read_valid) begin
                        read_wait_count_q <= 32'd0;
                        if (config_read_generation != generation_q) begin
                            error <= 1'b1;
                            error_code <= ERR_RESPONSE_GENERATION;
                            error_address <= {{(32-COUNT_BITS){1'b0}}, index_q};
                            state <= STATE_IDLE;
                        end else begin
                            descriptor_q <= config_read_descriptor;
                            generation_fault_pending_q <= 1'b0;
                            state <= STATE_SEND;
                        end
                    end else if (read_timeout) begin
                        drain_reason_q <= DRAIN_ERROR;
                        error_code <= ERR_READ_TIMEOUT;
                        error_address <= {{(32-COUNT_BITS){1'b0}}, index_q};
                        state <= STATE_DRAIN_READ;
                    end else begin
                        read_wait_count_q <= read_wait_count_q + 1'b1;
                    end
                end

                STATE_SEND: begin
                    if (abort) begin
                        state <= STATE_IDLE;
                        aborted <= 1'b1;
                        generation_fault_pending_q <= 1'b0;
                    end else begin
                        if (generation_changed)
                            generation_fault_pending_q <= 1'b1;

                        if (stage_fire) begin
                            if (generation_changed ||
                                generation_fault_pending_q) begin
                                state <= STATE_IDLE;
                                error <= 1'b1;
                                error_code <= ERR_GENERATION_CHANGED;
                                error_address <=
                                    {{(32-COUNT_BITS){1'b0}}, index_q};
                            end else if (index_q == (count_q - 1'b1)) begin
                                state <= STATE_IDLE;
                                done <= 1'b1;
                            end else begin
                                index_q <= index_q + 1'b1;
                                read_wait_count_q <= 32'd0;
                                state <= STATE_ISSUE_READ;
                            end
                        end
                    end
                end

                STATE_DRAIN_READ: begin
                    // The config-bank response has no READY.  Wait until both
                    // its busy level and one-cycle response pulse are gone so
                    // a subsequent start cannot consume a stale response.
                    if (read_interface_idle) begin
                        state <= STATE_IDLE;
                        if (drain_reason_q == DRAIN_ABORT) begin
                            aborted <= 1'b1;
                        end else begin
                            error <= 1'b1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

    initial begin
        if ((MAX_STAGES < 1) || (COUNT_BITS < 1) || (COUNT_BITS > 32) ||
            (GENERATION_BITS < 1) || (READ_TIMEOUT_CYCLES < 0))
            $fatal(1, "c1_r1_config_dispatcher parameter range error");
    end

`ifndef SYNTHESIS
    logic previous_stage_stall;
    logic [COUNT_BITS+GENERATION_BITS+511:0] previous_stage_payload;
    always_ff @(posedge clk) begin
        if (rst) begin
            previous_stage_stall <= 1'b0;
            previous_stage_payload <= '0;
        end else begin
            if (previous_stage_stall && !abort) begin
                if (!stage_config_valid)
                    $fatal(1, "config dispatcher retracted stalled stage VALID");
                if ({stage_config_index, stage_config_generation,
                     stage_config_descriptor} !== previous_stage_payload)
                    $fatal(1, "config dispatcher changed stalled payload");
            end
            if (done && (error || aborted))
                $fatal(1, "config dispatcher emitted multiple terminals");
            if (error && aborted)
                $fatal(1, "config dispatcher emitted error and abort together");
            previous_stage_stall <= stage_config_valid &&
                                    !stage_config_ready && !abort;
            previous_stage_payload <= {stage_config_index,
                                       stage_config_generation,
                                       stage_config_descriptor};
        end
    end
`endif

endmodule
