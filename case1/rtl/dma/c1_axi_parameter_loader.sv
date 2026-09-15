`timescale 1ns/1ps

// Board-independent AXI4 parameter-arena loader.
//
// A legal start handshake atomically samples start_base_addr and starts the
// inactive shadow arena in c1_r1_parameter_bank.  The fixed ARENA_BYTES image
// is fetched as sequential 128-bit AXI4 INCR bursts.  There is at most one
// burst outstanding, every burst is at most 16 beats, and no burst crosses a
// 4 KiB boundary.
//
// The one-beat buffer is intentional: an AXI beat is checked for RRESP and
// RLAST before it is offered to the parameter bank.  Consequently an invalid
// final AXI beat can never assert bank_load_last and accidentally commit the
// inactive bank.  AXI backpressure also propagates correctly when the bank is
// stalled.
//
// Abort/error contract:
//   * abort before AR handshake stops immediately;
//   * abort on/after AR handshake stops new AR requests but drains the already
//     accepted burst using RREADY, without forwarding more data;
//   * a bad RRESP or RLAST follows the same drain path;
//   * after draining, bank_load_abort pulses for one cycle.  Only then does
//     this module pulse aborted (explicit abort) or error (AXI/bank failure).
// Thus a partial or failed image cannot change the active parameter bank.
//
// done, error, and aborted are mutually-exclusive one-cycle terminal pulses.
// error_code and error_address retain the most recent failure information
// until the next accepted start.  Address arithmetic permits an exclusive end
// of 2^32 (last byte at 0xffff_ffff), but never an address beyond it.
module c1_axi_parameter_loader #(
    parameter integer ARENA_BYTES = 16896,
    parameter integer REM_W =
        (((ARENA_BYTES / 16) + 1 <= 2) ? 1 :
         $clog2((ARENA_BYTES / 16) + 1))
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          start_valid,
    output logic          start_ready,
    input  logic [31:0]   start_base_addr,
    input  logic          abort,

    output logic          busy,
    output logic          done,
    output logic          error,
    output logic          aborted,
    output logic [3:0]    error_code,
    output logic [31:0]   error_address,

    // Direct connection to c1_r1_parameter_bank load interface.
    output logic          bank_load_start,
    input  logic          bank_load_start_ready,
    output logic          bank_load_valid,
    input  logic          bank_load_ready,
    output logic [127:0]  bank_load_data,
    output logic          bank_load_last,
    output logic          bank_load_abort,
    input  logic          bank_load_busy,
    input  logic          bank_load_done,
    input  logic          bank_load_aborted,
    input  logic          bank_load_error,

    // ID-less, 128-bit AXI4 read master.
    output logic [31:0]   m_axi_araddr,
    output logic [7:0]    m_axi_arlen,
    output logic [2:0]    m_axi_arsize,
    output logic [1:0]    m_axi_arburst,
    output logic          m_axi_arvalid,
    input  logic          m_axi_arready,

    input  logic [127:0]  m_axi_rdata,
    input  logic [1:0]    m_axi_rresp,
    input  logic          m_axi_rlast,
    input  logic          m_axi_rvalid,
    output logic          m_axi_rready
);

    localparam integer ARENA_WORDS = ARENA_BYTES / 16;

    localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    localparam logic [3:0] ERR_NONE          = 4'd0;
    localparam logic [3:0] ERR_BASE_ALIGN    = 4'd1;
    localparam logic [3:0] ERR_ADDR_OVERFLOW = 4'd2;
    localparam logic [3:0] ERR_RRESP         = 4'd3;
    localparam logic [3:0] ERR_RLAST         = 4'd4;
    localparam logic [3:0] ERR_BANK          = 4'd5;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PREPARE,
        ST_AR,
        ST_R,
        ST_FLUSH,
        ST_BANK_ABORT
    } state_t;

    state_t state;

    logic [31:0] current_addr;
    logic [REM_W-1:0] words_remaining;
    logic [4:0] burst_beats_target;
    logic [4:0] burst_beat_index;

    logic         beat_buffer_valid;
    logic [127:0] beat_buffer_data;
    logic         beat_buffer_last;

    logic drop_mode;
    logic failure_is_abort;

    logic [63:0] start_end_exclusive_wide;
    logic        start_aligned;
    logic        start_in_range;
    logic        start_legal;
    logic        start_fire;
    logic        ar_fire;
    logic        r_fire;
    logic        bank_fire;
    logic        bank_fault;
    logic        expected_rlast;
    logic        current_r_error;
    logic        current_global_last;
    logic [31:0] current_beat_address;

    function automatic [4:0] choose_burst_beats(
        input logic [31:0] address,
        input logic [REM_W-1:0] words_left
    );
        integer beats_to_4k;
        integer selected;
        begin
            beats_to_4k = (4096 - address[11:0]) >> 4;
            selected = 16;
            if (words_left < selected)
                selected = words_left;
            if (beats_to_4k < selected)
                selected = beats_to_4k;
            choose_burst_beats = selected[4:0];
        end
    endfunction

    always_comb begin
        start_end_exclusive_wide = {32'd0, start_base_addr} +
                                   ARENA_BYTES;
        start_aligned = (start_base_addr[3:0] == 4'd0);
        start_in_range =
            (start_end_exclusive_wide <= 64'h0000_0001_0000_0000);
        start_legal = start_aligned && start_in_range;

        // An invalid request never touches the bank, so it need not wait for
        // bank_load_start_ready.  A valid request handshakes atomically with
        // the bank load start.
        start_ready = (state == ST_IDLE) && !rst && !abort &&
                      (!start_legal || bank_load_start_ready);
        start_fire = start_valid && start_ready;
        bank_load_start = start_fire && start_legal;

        m_axi_araddr  = current_addr;
        m_axi_arlen   = {3'd0, burst_beats_target} - 8'd1;
        m_axi_arsize  = 3'd4; // 2**4 = 16 bytes
        m_axi_arburst = AXI_BURST_INCR;
        m_axi_arvalid = (state == ST_AR);
        ar_fire = m_axi_arvalid && m_axi_arready;

        bank_fault = bank_load_error || bank_load_aborted;

        // During failure/abort drain, bank backpressure must not prevent the
        // outstanding AXI burst from completing.
        m_axi_rready = (state == ST_R) &&
                       ((drop_mode || abort || bank_fault) ? 1'b1 :
                        (!beat_buffer_valid || bank_load_ready));
        r_fire = m_axi_rvalid && m_axi_rready;

        bank_load_valid = beat_buffer_valid &&
                          ((state == ST_R) || (state == ST_FLUSH)) &&
                          !drop_mode && !abort && !bank_fault;
        bank_load_data = beat_buffer_data;
        bank_load_last = beat_buffer_last && bank_load_valid;
        bank_fire = bank_load_valid && bank_load_ready;

        bank_load_abort = (state == ST_BANK_ABORT);

        expected_rlast =
            (burst_beat_index == (burst_beats_target - 5'd1));
        current_r_error = (m_axi_rresp != AXI_RESP_OKAY) ||
                          (m_axi_rlast != expected_rlast);
        current_global_last = expected_rlast &&
                              (words_remaining == burst_beats_target);
        current_beat_address = current_addr +
                               ({27'd0, burst_beat_index} << 4);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            current_addr <= 32'd0;
            words_remaining <= '0;
            burst_beats_target <= 5'd0;
            burst_beat_index <= 5'd0;
            beat_buffer_valid <= 1'b0;
            beat_buffer_data <= 128'd0;
            beat_buffer_last <= 1'b0;
            drop_mode <= 1'b0;
            failure_is_abort <= 1'b0;
            busy <= 1'b0;
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
                ST_IDLE: begin
                    busy <= 1'b0;
                    beat_buffer_valid <= 1'b0;
                    drop_mode <= 1'b0;
                    failure_is_abort <= 1'b0;

                    if (start_fire) begin
                        error_code <= ERR_NONE;
                        error_address <= 32'd0;
                        if (!start_aligned) begin
                            error <= 1'b1;
                            error_code <= ERR_BASE_ALIGN;
                            error_address <= start_base_addr;
                        end else if (!start_in_range) begin
                            error <= 1'b1;
                            error_code <= ERR_ADDR_OVERFLOW;
                            error_address <= start_base_addr;
                        end else begin
                            current_addr <= start_base_addr;
                            words_remaining <= ARENA_WORDS;
                            burst_beat_index <= 5'd0;
                            busy <= 1'b1;
                            state <= ST_PREPARE;
                        end
                    end
                end

                ST_PREPARE: begin
                    if (bank_fault) begin
                        failure_is_abort <= 1'b0;
                        error_code <= ERR_BANK;
                        error_address <= current_addr;
                        state <= ST_BANK_ABORT;
                    end else if (abort) begin
                        failure_is_abort <= 1'b1;
                        state <= ST_BANK_ABORT;
                    end else begin
                        burst_beats_target <=
                            choose_burst_beats(current_addr, words_remaining);
                        burst_beat_index <= 5'd0;
                        state <= ST_AR;
                    end
                end

                ST_AR: begin
                    if (bank_fault) begin
                        failure_is_abort <= 1'b0;
                        error_code <= ERR_BANK;
                        error_address <= current_addr;
                        if (ar_fire) begin
                            drop_mode <= 1'b1;
                            burst_beat_index <= 5'd0;
                            state <= ST_R;
                        end else begin
                            state <= ST_BANK_ABORT;
                        end
                    end else if (ar_fire) begin
                        // AR handshake wins the state transition.  If abort is
                        // high on this edge, the committed burst is drained.
                        burst_beat_index <= 5'd0;
                        drop_mode <= abort;
                        if (abort)
                            failure_is_abort <= 1'b1;
                        state <= ST_R;
                    end else if (abort) begin
                        failure_is_abort <= 1'b1;
                        state <= ST_BANK_ABORT;
                    end
                end

                ST_R: begin
                    // A previously buffered, already-validated beat may leave
                    // while the next AXI beat is accepted in the same cycle.
                    if (bank_fire)
                        beat_buffer_valid <= 1'b0;

                    if (bank_fault && !drop_mode) begin
                        drop_mode <= 1'b1;
                        beat_buffer_valid <= 1'b0;
                        failure_is_abort <= 1'b0;
                        error_code <= ERR_BANK;
                        error_address <= current_beat_address;
                    end else if (abort && !drop_mode) begin
                        drop_mode <= 1'b1;
                        beat_buffer_valid <= 1'b0;
                        failure_is_abort <= 1'b1;
                    end

                    if (r_fire) begin
                        if (drop_mode || abort || bank_fault ||
                            current_r_error) begin
                            beat_buffer_valid <= 1'b0;
                            drop_mode <= 1'b1;

                            // Preserve the first terminal cause.  An explicit
                            // abort already in progress remains an abort even
                            // if malformed R traffic is seen while draining.
                            if (!drop_mode && !abort && !bank_fault) begin
                                failure_is_abort <= 1'b0;
                                error_address <= current_beat_address;
                                if (m_axi_rresp != AXI_RESP_OKAY)
                                    error_code <= ERR_RRESP;
                                else
                                    error_code <= ERR_RLAST;
                            end
                        end else begin
                            beat_buffer_valid <= 1'b1;
                            beat_buffer_data <= m_axi_rdata;
                            beat_buffer_last <= current_global_last;
                        end

                        if (expected_rlast) begin
                            if (drop_mode || abort || bank_fault ||
                                current_r_error) begin
                                state <= ST_BANK_ABORT;
                            end else begin
                                current_addr <= current_addr +
                                    ({27'd0, burst_beats_target} << 4);
                                words_remaining <= words_remaining -
                                                   burst_beats_target;
                                state <= ST_FLUSH;
                            end
                        end else if (m_axi_rlast) begin
                            // An early RLAST is the slave's actual burst
                            // termination.  Waiting for the ARLEN-implied
                            // remainder could deadlock because no more R beats
                            // are required to arrive after this beat.
                            state <= ST_BANK_ABORT;
                        end else begin
                            burst_beat_index <= burst_beat_index + 5'd1;
                        end
                    end
                end

                ST_FLUSH: begin
                    if (bank_fault) begin
                        beat_buffer_valid <= 1'b0;
                        failure_is_abort <= 1'b0;
                        error_code <= ERR_BANK;
                        error_address <= current_addr;
                        state <= ST_BANK_ABORT;
                    end else if (abort) begin
                        beat_buffer_valid <= 1'b0;
                        failure_is_abort <= 1'b1;
                        state <= ST_BANK_ABORT;
                    end else if (bank_fire) begin
                        beat_buffer_valid <= 1'b0;
                        if (beat_buffer_last) begin
                            // The real parameter bank commits on this same
                            // handshake edge, so the job is now irrevocably
                            // successful and a later abort belongs to no job.
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            state <= ST_PREPARE;
                        end
                    end
                end

                ST_BANK_ABORT: begin
                    // bank_load_abort is combinationally high throughout this
                    // state and is sampled by the bank on this edge.
                    beat_buffer_valid <= 1'b0;
                    drop_mode <= 1'b0;
                    busy <= 1'b0;
                    if (failure_is_abort)
                        aborted <= 1'b1;
                    else
                        error <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    busy <= 1'b0;
                    beat_buffer_valid <= 1'b0;
                    drop_mode <= 1'b0;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ARENA_BYTES <= 0 || (ARENA_BYTES % 16) != 0)
            $fatal(1, "ARENA_BYTES must be positive and divisible by 16");
        if (ARENA_WORDS > ((1 << REM_W) - 1))
            $fatal(1, "REM_W cannot represent ARENA_WORDS");
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            if ((done && error) || (done && aborted) ||
                (error && aborted))
                $fatal(1, "loader terminal pulses overlap");
            if (m_axi_arvalid && (burst_beats_target == 0 ||
                                  burst_beats_target > 16))
                $fatal(1, "invalid AXI burst length");
            if (m_axi_arvalid &&
                ({1'b0, m_axi_araddr[11:0]} +
                 ({8'd0, m_axi_arlen} + 13'd1) * 13'd16 > 13'd4096))
                $fatal(1, "AXI burst crosses 4 KiB boundary");
            if (bank_load_last && !bank_load_valid)
                $fatal(1, "bank_load_last without bank_load_valid");
            if (done && !bank_load_done)
                $fatal(1, "loader done without parameter-bank commit");
        end
    end
`endif

    // These status inputs are intentionally part of the interface even though
    // successful completion is recognized on the final bank handshake.  They
    // make a bank protocol fault visible and allow the simulation assertion
    // above to prove the loader/bank commit edges coincide.
    logic _unused_bank_status;
    always_comb begin
        _unused_bank_status = bank_load_busy ^ bank_load_done ^
                              bank_load_aborted;
    end

endmodule
