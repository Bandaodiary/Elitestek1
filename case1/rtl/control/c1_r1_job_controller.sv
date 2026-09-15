`timescale 1ns/1ps

// Pure control-plane orchestrator for one R1 frame job.
//
// Sequence:
//   1. Accept one job start and latch cycle_budget.
//   2. Issue independent ready/valid starts to the frame-pair resolver and the
//      descriptor/config loader.  Each request is issued exactly once.
//   3. Consume both ready/valid responses.  Only after both succeed and all
//      three execution clients are ready, pulse input_dma_start,
//      output_dma_start and engine_start on the same clock.
//   4. Arm runtime observation only after the launch edge.  Remember the
//      terminal event of input DMA, descriptor executor, engine, and output
//      DMA.  Pre-launch/stale terminal inputs are deliberately ignored.
//   5. After all four report success, enter a success-drain phase and pulse
//      job_done only after every client busy input is low. Success remains
//      tentative until that edge: abort or a late runtime error vetoes it.
//
// Error/abort contract:
//   * The first error is retained until the next accepted job.  Simultaneous
//     errors use deterministic priority: pair, config, input DMA, descriptor,
//     engine, output DMA, watchdog.
//   * Explicit abort has priority over a new same-cycle error.  Before launch,
//     it cancels the prerequisite clients and reports job_aborted as soon as
//     their busy indications clear.  After launch, it never resets or retracts
//     a DMA transaction: descriptor/engine receive abort pulses, both issued
//     DMAs must still report done/error, and every busy input must clear before
//     job_aborted is emitted.
//   * Runtime error uses the same safe drain rule and then emits job_error.
//     Once error/abort drain is selected, later diagnostics do not reclassify
//     its terminal result or overwrite its first error. No repeated cancels.
//   * Launch is inhibited while any runtime error input is asserted and while
//     the descriptor runtime client is busy.  A done/error input is sampled
//     only from STATE_RUN or a launched STATE_DRAIN, never before launch or on
//     the launch edge itself.
//   * Abort/error requests are one-clock pulses in this common clk domain.
//   * rst synchronously clears controller state, but immediately inhibits
//     command/response handshakes and runtime launches. Reset is not a safe
//     substitute for abort/drain of already issued external transactions.
//
// cycle_budget==0 disables the watchdog.  Otherwise it counts active clocks
// after start acceptance through preflight/wait/run.  Completion of all four
// runtime clients on the expiry edge wins over timeout; every other unfinished
// job times out with code F0 and the elapsed active-cycle count as its address.
module c1_r1_job_controller (
    input  logic           clk,
    input  logic           rst,

    input  logic           start_valid,
    output logic           start_ready,
    input  logic [31:0]    cycle_budget,
    input  logic           abort,

    output logic           busy,
    output logic           job_done,
    output logic           job_error,
    output logic           job_aborted,
    output logic [7:0]     error_code,
    output logic [31:0]    error_address,

    output logic           pair_start_valid,
    input  logic           pair_start_ready,
    input  logic           pair_response_valid,
    output logic           pair_response_ready,
    input  logic           pair_response_error,
    input  logic [7:0]     pair_response_error_code,
    input  logic [31:0]    pair_response_error_address,
    input  logic           pair_busy,
    output logic           pair_abort_pulse,

    output logic           config_start_valid,
    input  logic           config_start_ready,
    input  logic           config_response_valid,
    output logic           config_response_ready,
    input  logic           config_response_error,
    input  logic [7:0]     config_response_error_code,
    input  logic [31:0]    config_response_error_address,
    input  logic           config_busy,
    output logic           config_abort_pulse,

    input  logic           input_dma_ready,
    output logic           input_dma_start,
    input  logic           input_dma_busy,
    input  logic           input_dma_done,
    input  logic           input_dma_error,
    input  logic [7:0]     input_dma_error_code,
    input  logic [31:0]    input_dma_error_address,

    input  logic           output_dma_ready,
    output logic           output_dma_start,
    input  logic           output_dma_busy,
    input  logic           output_dma_done,
    input  logic           output_dma_error,
    input  logic [7:0]     output_dma_error_code,
    input  logic [31:0]    output_dma_error_address,

    input  logic           descriptor_busy,
    input  logic           descriptor_done,
    input  logic           descriptor_error,
    input  logic [7:0]     descriptor_error_code,
    input  logic [31:0]    descriptor_error_address,
    output logic           descriptor_abort_pulse,

    input  logic           engine_ready,
    output logic           engine_start,
    input  logic           engine_busy,
    input  logic           engine_done,
    input  logic           engine_error,
    input  logic [7:0]     engine_error_code,
    input  logic [31:0]    engine_error_address,
    output logic           engine_abort_pulse
);

    localparam logic [7:0] WATCHDOG_ERROR_CODE = 8'hf0;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_PREFLIGHT,
        STATE_WAIT_LAUNCH,
        STATE_RUN,
        STATE_DRAIN
    } state_t;

    state_t state;

    logic [31:0] cycle_budget_reg;
    logic [31:0] watchdog_count;
    logic pair_request_sent;
    logic config_request_sent;
    logic pair_complete;
    logic config_complete;
    logic job_launched;
    logic drain_for_abort;
    logic drain_for_success;

    logic input_terminal_seen;
    logic output_terminal_seen;
    logic descriptor_terminal_seen;
    logic engine_terminal_seen;
    logic wait_input_error_seen;
    logic wait_output_error_seen;
    logic wait_descriptor_error_seen;
    logic wait_engine_error_seen;

    logic start_fire;
    logic pair_start_fire;
    logic config_start_fire;
    logic pair_response_fire;
    logic config_response_fire;
    logic launch_fire;
    logic watchdog_expired;

    logic pair_complete_now;
    logic config_complete_now;
    logic input_terminal_now;
    logic output_terminal_now;
    logic descriptor_terminal_now;
    logic engine_terminal_now;
    logic all_runtime_terminal_now;
    logic all_clients_idle;
    logic drain_complete;

    always_comb begin
        start_ready = !rst && !abort && (state == STATE_IDLE) &&
                      !pair_busy && !config_busy &&
                      !input_dma_busy && !output_dma_busy &&
                      !descriptor_busy && !engine_busy;
        start_fire = start_valid && start_ready;
        busy = (state != STATE_IDLE);

        pair_start_valid = (state == STATE_PREFLIGHT) &&
                           !pair_request_sent && !abort && !rst;
        config_start_valid = (state == STATE_PREFLIGHT) &&
                             !config_request_sent && !abort && !rst;
        pair_start_fire = pair_start_valid && pair_start_ready;
        config_start_fire = config_start_valid && config_start_ready;

        pair_response_ready = (state == STATE_PREFLIGHT) &&
                              !pair_complete &&
                              (pair_request_sent || pair_start_fire) && !abort && !rst;
        config_response_ready = (state == STATE_PREFLIGHT) &&
                                !config_complete &&
                                (config_request_sent || config_start_fire) && !abort && !rst;
        pair_response_fire = pair_response_valid && pair_response_ready;
        config_response_fire = config_response_valid && config_response_ready;

        watchdog_expired =
            ((state == STATE_PREFLIGHT) ||
             (state == STATE_WAIT_LAUNCH) ||
             (state == STATE_RUN)) &&
            (cycle_budget_reg != 0) &&
            (watchdog_count >= (cycle_budget_reg - 1'b1));

        launch_fire = (state == STATE_WAIT_LAUNCH) &&
                      input_dma_ready && output_dma_ready && engine_ready &&
                      !descriptor_busy &&
                      !input_dma_error && !output_dma_error &&
                      !descriptor_error && !engine_error &&
                      !abort && !rst && !watchdog_expired;
        input_dma_start = launch_fire;
        output_dma_start = launch_fire;
        engine_start = launch_fire;

        pair_complete_now = pair_complete ||
                            (pair_response_fire && !pair_response_error);
        config_complete_now = config_complete ||
                              (config_response_fire && !config_response_error);

        input_terminal_now = input_terminal_seen ||
                             input_dma_done || input_dma_error;
        output_terminal_now = output_terminal_seen ||
                              output_dma_done || output_dma_error;
        descriptor_terminal_now = descriptor_terminal_seen ||
                                  descriptor_done || descriptor_error;
        engine_terminal_now = engine_terminal_seen ||
                              engine_done || engine_error;
        all_runtime_terminal_now = input_terminal_now && output_terminal_now &&
                                   descriptor_terminal_now && engine_terminal_now;

        all_clients_idle = !pair_busy && !config_busy &&
                           !input_dma_busy && !output_dma_busy &&
                           !descriptor_busy && !engine_busy;
        if (job_launched && drain_for_success)
            drain_complete = all_runtime_terminal_now && all_clients_idle;
        else if (job_launched)
            drain_complete = input_terminal_now && output_terminal_now &&
                             all_clients_idle;
        else
            drain_complete = all_clients_idle;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            cycle_budget_reg <= 32'd0;
            watchdog_count <= 32'd0;
            pair_request_sent <= 1'b0;
            config_request_sent <= 1'b0;
            pair_complete <= 1'b0;
            config_complete <= 1'b0;
            job_launched <= 1'b0;
            drain_for_abort <= 1'b0;
            drain_for_success <= 1'b0;
            input_terminal_seen <= 1'b0;
            output_terminal_seen <= 1'b0;
            descriptor_terminal_seen <= 1'b0;
            engine_terminal_seen <= 1'b0;
            wait_input_error_seen <= 1'b0;
            wait_output_error_seen <= 1'b0;
            wait_descriptor_error_seen <= 1'b0;
            wait_engine_error_seen <= 1'b0;
            job_done <= 1'b0;
            job_error <= 1'b0;
            job_aborted <= 1'b0;
            error_code <= 8'd0;
            error_address <= 32'd0;
            pair_abort_pulse <= 1'b0;
            config_abort_pulse <= 1'b0;
            descriptor_abort_pulse <= 1'b0;
            engine_abort_pulse <= 1'b0;

        end else begin
            job_done <= 1'b0;
            job_error <= 1'b0;
            job_aborted <= 1'b0;
            pair_abort_pulse <= 1'b0;
            config_abort_pulse <= 1'b0;
            descriptor_abort_pulse <= 1'b0;
            engine_abort_pulse <= 1'b0;

            // A one-clock terminal/error pulse left over before launch is
            // stale and must not retire the new job.  ERROR still masks
            // launch combinationally, but is classified as a real stuck
            // prelaunch fault only after the same client asserts it on two
            // consecutive WAIT_LAUNCH samples.
            if (state == STATE_WAIT_LAUNCH) begin
                wait_input_error_seen <= input_dma_error;
                wait_output_error_seen <= output_dma_error;
                wait_descriptor_error_seen <= descriptor_error;
                wait_engine_error_seen <= engine_error;
            end else begin
                wait_input_error_seen <= 1'b0;
                wait_output_error_seen <= 1'b0;
                wait_descriptor_error_seen <= 1'b0;
                wait_engine_error_seen <= 1'b0;
            end

            case (state)
                STATE_IDLE: begin
                    if (start_fire) begin
                        cycle_budget_reg <= cycle_budget;
                        watchdog_count <= 32'd0;
                        pair_request_sent <= 1'b0;
                        config_request_sent <= 1'b0;
                        pair_complete <= 1'b0;
                        config_complete <= 1'b0;
                        job_launched <= 1'b0;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        input_terminal_seen <= 1'b0;
                        output_terminal_seen <= 1'b0;
                        descriptor_terminal_seen <= 1'b0;
                        engine_terminal_seen <= 1'b0;
                        error_code <= 8'd0;
                        error_address <= 32'd0;
                        state <= STATE_PREFLIGHT;
                    end
                end

                STATE_PREFLIGHT: begin
                    if (pair_start_fire)
                        pair_request_sent <= 1'b1;
                    if (config_start_fire)
                        config_request_sent <= 1'b1;
                    if (pair_response_fire && !pair_response_error)
                        pair_complete <= 1'b1;
                    if (config_response_fire && !config_response_error)
                        config_complete <= 1'b1;
                    if (abort) begin
                        drain_for_abort <= 1'b1;
                        drain_for_success <= 1'b0;
                        pair_abort_pulse <= 1'b1;
                        config_abort_pulse <= 1'b1;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (pair_response_fire && pair_response_error) begin
                        error_code <= pair_response_error_code;
                        error_address <= pair_response_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        pair_abort_pulse <= 1'b1;
                        config_abort_pulse <= 1'b1;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (config_response_fire && config_response_error) begin
                        error_code <= config_response_error_code;
                        error_address <= config_response_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        pair_abort_pulse <= 1'b1;
                        config_abort_pulse <= 1'b1;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (watchdog_expired) begin
                        error_code <= WATCHDOG_ERROR_CODE;
                        error_address <= watchdog_count + 1'b1;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        pair_abort_pulse <= 1'b1;
                        config_abort_pulse <= 1'b1;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else begin
                        watchdog_count <= watchdog_count + 1'b1;
                        if (pair_complete_now && config_complete_now)
                            state <= STATE_WAIT_LAUNCH;
                    end
                end

                STATE_WAIT_LAUNCH: begin
                    if (abort) begin
                        drain_for_abort <= 1'b1;
                        drain_for_success <= 1'b0;
                        pair_abort_pulse <= 1'b1;
                        config_abort_pulse <= 1'b1;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (input_dma_error && wait_input_error_seen) begin
                        // A runtime client that holds ERROR while otherwise
                        // advertising readiness must not leave a zero-budget
                        // job parked here forever.  Short terminal pulses that
                        // disappeared before WAIT_LAUNCH remain deliberately
                        // ignored; a level still asserted in this state is a
                        // current launch-inhibit fault and retains its native
                        // diagnostic payload.
                        error_code <= input_dma_error_code;
                        error_address <= input_dma_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (descriptor_error &&
                                 wait_descriptor_error_seen) begin
                        error_code <= descriptor_error_code;
                        error_address <= descriptor_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (engine_error && wait_engine_error_seen) begin
                        error_code <= engine_error_code;
                        error_address <= engine_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (output_dma_error &&
                                 wait_output_error_seen) begin
                        error_code <= output_dma_error_code;
                        error_address <= output_dma_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (watchdog_expired) begin
                        error_code <= WATCHDOG_ERROR_CODE;
                        error_address <= watchdog_count + 1'b1;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (launch_fire) begin
                        job_launched <= 1'b1;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        // The launch edge arms the runtime clients; it does
                        // not consume terminal inputs left over from an older
                        // transaction.  Sampling begins in STATE_RUN.
                        input_terminal_seen <= 1'b0;
                        output_terminal_seen <= 1'b0;
                        descriptor_terminal_seen <= 1'b0;
                        engine_terminal_seen <= 1'b0;
                        watchdog_count <= watchdog_count + 1'b1;
                        state <= STATE_RUN;
                    end else begin
                        watchdog_count <= watchdog_count + 1'b1;
                    end
                end

                STATE_RUN: begin
                    if (input_dma_done || input_dma_error)
                        input_terminal_seen <= 1'b1;
                    if (output_dma_done || output_dma_error)
                        output_terminal_seen <= 1'b1;
                    if (descriptor_done || descriptor_error)
                        descriptor_terminal_seen <= 1'b1;
                    if (engine_done || engine_error)
                        engine_terminal_seen <= 1'b1;

                    if (abort) begin
                        drain_for_abort <= 1'b1;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (input_dma_error) begin
                        error_code <= input_dma_error_code;
                        error_address <= input_dma_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (descriptor_error) begin
                        error_code <= descriptor_error_code;
                        error_address <= descriptor_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (engine_error) begin
                        error_code <= engine_error_code;
                        error_address <= engine_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (output_dma_error) begin
                        error_code <= output_dma_error_code;
                        error_address <= output_dma_error_address;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (all_runtime_terminal_now) begin
                        // Terminal success and client idleness are separate
                        // contracts.  Keep the job armed until every client
                        // has retired its internal state.
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b1;
                        state <= STATE_DRAIN;
                    end else if (watchdog_expired) begin
                        error_code <= WATCHDOG_ERROR_CODE;
                        error_address <= watchdog_count + 1'b1;
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        state <= STATE_DRAIN;
                    end else begin
                        watchdog_count <= watchdog_count + 1'b1;
                    end
                end

                STATE_DRAIN: begin
                    if (job_launched) begin
                        if (input_dma_done || input_dma_error)
                            input_terminal_seen <= 1'b1;
                        if (output_dma_done || output_dma_error)
                            output_terminal_seen <= 1'b1;
                        if (descriptor_done || descriptor_error)
                            descriptor_terminal_seen <= 1'b1;
                        if (engine_done || engine_error)
                            engine_terminal_seen <= 1'b1;
                    end

                    // Terminal tokens do not end job ownership. A client can
                    // still fail while busy drains, and software can cancel
                    // on the very edge that the final busy falls. Give those
                    // events the same priority as RUN before publishing DONE.
                    // Existing failure/cancel drains retain their first cause.
                    if (job_launched && drain_for_success && abort) begin
                        drain_for_abort <= 1'b1;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                    end else if (job_launched && drain_for_success &&
                                 (input_dma_error || descriptor_error || engine_error || output_dma_error)) begin
                        drain_for_abort <= 1'b0;
                        drain_for_success <= 1'b0;
                        descriptor_abort_pulse <= 1'b1;
                        engine_abort_pulse <= 1'b1;
                        if (input_dma_error) begin
                            error_code <= input_dma_error_code;
                            error_address <= input_dma_error_address;
                        end else if (descriptor_error) begin
                            error_code <= descriptor_error_code;
                            error_address <= descriptor_error_address;
                        end else if (engine_error) begin
                            error_code <= engine_error_code;
                            error_address <= engine_error_address;
                        end else begin
                            error_code <= output_dma_error_code;
                            error_address <= output_dma_error_address;
                        end
                    end else if (drain_complete) begin
                        if (drain_for_success)
                            job_done <= 1'b1;
                        else if (drain_for_abort)
                            job_aborted <= 1'b1;
                        else
                            job_error <= 1'b1;
                        job_launched <= 1'b0;
                        drain_for_success <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
