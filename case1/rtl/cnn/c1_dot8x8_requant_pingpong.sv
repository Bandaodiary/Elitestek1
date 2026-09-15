`timescale 1ns/1ps

// Transaction-level inter-pixel overlap shell for the parallel MAC bank.
//
// c1_dot8x8_requant_bank is intentionally lock-step and accepts one complete
// dot transaction at a time.  This wrapper keeps that well-tested contract,
// but instantiates two (or more) banks and alternates complete transactions
// between them.  While bank A is draining its requant/output stage, bank B can
// receive the next pixel's C8 beats.  A small bank-id FIFO restores the input
// transaction order at the output, so downstream stage boundaries do not need
// to understand the physical bank selection.
//
// The wrapper does not interleave beats from two transactions: after START is
// accepted, all input beats up to IN_LAST go to the selected bank.  This keeps
// the existing scheduler ABI unchanged and makes the measured gain attributable
// to inter-pixel overlap rather than a hidden protocol change.  Weight/window
// bandwidth is consequently still the responsibility of the upstream
// scheduler.
module c1_dot8x8_requant_pingpong #(
    parameter integer BANKS = 2,
    parameter integer LANES = 2,
    parameter integer X_BITS = 10,
    parameter integer Y_BITS = 9,
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    parameter integer TAG_FIFO_DEPTH = BANKS * 4,
    // Optional one-entry first-beat skid.  A producer may handshake START
    // and the first IN beat together; the beat is held until the selected
    // bank is ready.  Default zero preserves the original two-phase contract.
    parameter bit ACCEPT_FIRST_BEAT_ON_START = 1'b0,
    // Optional reuse of a bank on the exact edge its ordered output retires.
    // This removes an inter-transaction bubble once all banks are occupied;
    // the default remains the conservative busy-to-idle handoff.
    parameter bit ALLOW_OUTPUT_RESTART = 1'b0,
    // Optional tag FIFO full pop+push.  When the ordered head result retires
    // on the same edge as a new START, a full tag FIFO has one slot available
    // for replacement.  This option is useful only when the selected bank
    // also supports same-edge output restart; it is deliberately independent
    // and disabled by default so the legacy full-FIFO admission rule is
    // unchanged.
    parameter bit ALLOW_TAG_POP_PUSH = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         start_valid,
    output logic                         start_ready,
    input  logic [LANES*256-1:0]         start_bias_s32,
    input  logic [LANES*144-1:0]         start_mult_s18,
    input  logic [LANES*48-1:0]          start_shift_u6,
    input  logic [LANES-1:0]             start_relu,
    input  logic [LANES-1:0]             start_sof,
    input  logic [LANES-1:0]             start_eol,
    input  logic [LANES-1:0]             start_eof,
    input  logic [LANES*X_BITS-1:0]      start_x,
    input  logic [LANES*Y_BITS-1:0]      start_y,

    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic                         in_last,
    input  logic [7:0]                   in_lane_mask,
    input  logic [63:0]                  in_activations_s8,
    input  logic [LANES*512-1:0]         in_weights_s8,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic [LANES*64-1:0]          out_data_s8,
    output logic [LANES-1:0]             out_sof,
    output logic [LANES-1:0]             out_eol,
    output logic [LANES-1:0]             out_eof,
    output logic [LANES*X_BITS-1:0]      out_x,
    output logic [LANES*Y_BITS-1:0]      out_y,
    output logic                         busy,
    output logic [LANES-1:0]             overflow_seen
);

    localparam integer BANK_IDX_W = (BANKS <= 1) ? 1 : $clog2(BANKS);
    localparam integer TAG_PTR_W = (TAG_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(TAG_FIFO_DEPTH);
    localparam integer TAG_CNT_W = (TAG_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(TAG_FIFO_DEPTH + 1);

    initial begin
        if (BANKS < 2)
            $fatal(1, "pingpong BANKS must be at least two");
        if (LANES < 1)
            $fatal(1, "pingpong LANES must be positive");
        if (TAG_FIFO_DEPTH < BANKS || TAG_FIFO_DEPTH > 255)
            $fatal(1, "pingpong TAG_FIFO_DEPTH must be BANKS..255");
    end

    logic [BANKS-1:0] bank_start_valid;
    logic [BANKS-1:0] bank_start_ready;
    logic [BANKS-1:0] bank_in_valid;
    logic [BANKS-1:0] bank_in_ready;
    logic [BANKS-1:0] bank_out_valid;
    logic [BANKS-1:0] bank_out_ready;
    logic [BANKS-1:0] bank_busy;
    logic [LANES-1:0] bank_overflow_vec [0:BANKS-1];
    logic [LANES*64-1:0] bank_out_data [0:BANKS-1];
    logic [LANES-1:0] bank_out_sof [0:BANKS-1];
    logic [LANES-1:0] bank_out_eol [0:BANKS-1];
    logic [LANES-1:0] bank_out_eof [0:BANKS-1];
    logic [LANES*X_BITS-1:0] bank_out_x [0:BANKS-1];
    logic [LANES*Y_BITS-1:0] bank_out_y [0:BANKS-1];

    // Declare the routed input bundle before the generated bank instances.
    // Some Vivado front ends create an implicit net when a signal is first
    // referenced in a generate instance; keeping these declarations here
    // avoids silently disconnecting the LAST/metadata sideband.
    logic routed_in_last;
    logic [7:0] routed_in_lane_mask;
    logic [63:0] routed_in_activations;
    logic [LANES*512-1:0] routed_in_weights;

    // Keep the generated bank interfaces as unpacked arrays.  This is
    // accepted by both Vivado and Efinity front ends and avoids relying on a
    // tool-specific interpretation of nested packed dimensions.
    genvar g;
    generate
        for (g = 0; g < BANKS; g = g + 1) begin : gen_bank
            c1_dot8x8_requant_bank #(
                .LANES(LANES),
                .X_BITS(X_BITS),
                .Y_BITS(Y_BITS),
                .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
                .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
                .ALLOW_OUTPUT_RESTART(ALLOW_OUTPUT_RESTART)
            ) u_bank (
                .clk(clk),
                .rst(rst),
                .start_valid(bank_start_valid[g]),
                .start_ready(bank_start_ready[g]),
                .start_bias_s32(start_bias_s32),
                .start_mult_s18(start_mult_s18),
                .start_shift_u6(start_shift_u6),
                .start_relu(start_relu),
                .start_sof(start_sof),
                .start_eol(start_eol),
                .start_eof(start_eof),
                .start_x(start_x),
                .start_y(start_y),
                .in_valid(bank_in_valid[g]),
                .in_ready(bank_in_ready[g]),
                .in_last(routed_in_last),
                .in_lane_mask(routed_in_lane_mask),
                .in_activations_s8(routed_in_activations),
                .in_weights_s8(routed_in_weights),
                .out_valid(bank_out_valid[g]),
                .out_ready(bank_out_ready[g]),
                .out_data_s8(bank_out_data[g]),
                .out_sof(bank_out_sof[g]),
                .out_eol(bank_out_eol[g]),
                .out_eof(bank_out_eof[g]),
                .out_x(bank_out_x[g]),
                .out_y(bank_out_y[g]),
                .busy(bank_busy[g]),
                .overflow_seen(bank_overflow_vec[g])
            );
        end
    endgenerate

    logic input_active_q;
    logic [BANK_IDX_W-1:0] input_bank_q;
    logic [BANK_IDX_W-1:0] rr_bank_q;
    logic [BANK_IDX_W-1:0] selected_bank;
    logic selected_valid;
    logic start_fire;
    logic in_fire;
    logic bank_in_fire;
    logic first_capture_fire;
    logic first_beat_pending_q;
    logic first_beat_last_q;
    logic [7:0] first_beat_mask_q;
    logic [63:0] first_beat_activations_q;
    logic [LANES*512-1:0] first_beat_weights_q;

    logic [BANK_IDX_W-1:0] tag_mem [0:TAG_FIFO_DEPTH-1];
    logic [TAG_PTR_W-1:0] tag_head_q, tag_tail_q;
    logic [TAG_CNT_W-1:0] tag_count_q;
    logic tag_valid;
    logic [BANK_IDX_W-1:0] tag_head_bank;
    logic out_fire;
    logic tag_space_available;
    integer sel_i;
    integer route_i;
    integer busy_i;
    integer overflow_i;
    integer init_i;

    function automatic logic [BANK_IDX_W-1:0] bank_add(
        input logic [BANK_IDX_W-1:0] value,
        input integer offset
    );
        integer tmp;
        begin
            tmp = value + offset;
            if (tmp >= BANKS)
                tmp = tmp - BANKS;
            bank_add = tmp[BANK_IDX_W-1:0];
        end
    endfunction

    function automatic logic [TAG_PTR_W-1:0] tag_ptr_inc(
        input logic [TAG_PTR_W-1:0] value
    );
        begin
            if (value == TAG_FIFO_DEPTH - 1)
                tag_ptr_inc = '0;
            else
                tag_ptr_inc = value + 1'b1;
        end
    endfunction

    // Pick the first idle bank at or after the round-robin cursor.  A bank's
    // start_ready is low while its previous output is held, so a bank cannot
    // be reused before its result is safely represented by the tag FIFO.
    always_comb begin
        selected_bank = rr_bank_q;
        selected_valid = 1'b0;
        for (sel_i = 0; sel_i < BANKS; sel_i = sel_i + 1) begin
            if (!selected_valid && bank_start_ready[bank_add(rr_bank_q, sel_i)]) begin
                selected_bank = bank_add(rr_bank_q, sel_i);
                selected_valid = 1'b1;
            end
        end
    end

    assign tag_valid = (tag_count_q != 0);
    assign tag_head_bank = tag_valid ? tag_mem[tag_head_q] : '0;
    // A simultaneous ordered output retirement frees the head slot at the
    // active edge.  Permit START to consume that slot only in the explicit
    // optional mode; the sequential count update already preserves the
    // pop+push count when both handshakes occur together.
    assign tag_space_available = (tag_count_q < TAG_FIFO_DEPTH) ||
                                 (ALLOW_TAG_POP_PUSH && out_fire);
    assign start_ready = !rst && !input_active_q &&
                         tag_space_available && selected_valid;
    assign start_fire = start_valid && start_ready;
    // In optional mode the producer may present the first beat alongside
    // START.  It is captured only when both VALID channels are live; while a
    // captured beat waits for the selected bank, upstream IN_READY is held
    // low so no second beat can overwrite the one-entry skid.
    always_comb begin
        if (input_active_q)
            in_ready = first_beat_pending_q ? 1'b0 :
                       bank_in_ready[input_bank_q];
        else if (ACCEPT_FIRST_BEAT_ON_START && start_valid && start_ready)
            in_ready = 1'b1;
        else
            in_ready = 1'b0;
    end
    assign in_fire = in_valid && in_ready;
    assign first_capture_fire = ACCEPT_FIRST_BEAT_ON_START &&
                                start_fire && in_valid;

    always_comb begin
        for (route_i = 0; route_i < BANKS; route_i = route_i + 1) begin
            bank_start_valid[route_i] = 1'b0;
            bank_in_valid[route_i] = 1'b0;
            bank_out_ready[route_i] = 1'b0;
        end
        if (start_ready)
            bank_start_valid[selected_bank] = start_valid;
        if (input_active_q)
            bank_in_valid[input_bank_q] = first_beat_pending_q ?
                                          1'b1 : in_valid;
        if (tag_valid)
            bank_out_ready[tag_head_bank] = out_ready;
    end

    // Select the held first beat or the live stream for the bank inputs.  The
    // same bundle is broadcast to all banks; only one bank has IN_VALID.
    always_comb begin
        routed_in_last = first_beat_pending_q ? first_beat_last_q : in_last;
        routed_in_lane_mask = first_beat_pending_q ? first_beat_mask_q :
                              in_lane_mask;
        routed_in_activations = first_beat_pending_q ?
                                first_beat_activations_q : in_activations_s8;
        routed_in_weights = first_beat_pending_q ? first_beat_weights_q :
                            in_weights_s8;
    end
    assign bank_in_fire = input_active_q &&
                          bank_in_valid[input_bank_q] &&
                          bank_in_ready[input_bank_q];

    always_comb begin
        out_valid = 1'b0;
        out_data_s8 = '0;
        out_sof = '0;
        out_eol = '0;
        out_eof = '0;
        out_x = '0;
        out_y = '0;
        if (tag_valid) begin
            out_valid = bank_out_valid[tag_head_bank];
            out_data_s8 = bank_out_data[tag_head_bank];
            out_sof = bank_out_sof[tag_head_bank];
            out_eol = bank_out_eol[tag_head_bank];
            out_eof = bank_out_eof[tag_head_bank];
            out_x = bank_out_x[tag_head_bank];
            out_y = bank_out_y[tag_head_bank];
        end
    end
    assign out_fire = out_valid && out_ready;

    always_comb begin
        busy = input_active_q || (tag_count_q != 0);
        for (busy_i = 0; busy_i < BANKS; busy_i = busy_i + 1)
            if (bank_busy[busy_i])
                busy = 1'b1;
        overflow_seen = '0;
        for (overflow_i = 0; overflow_i < BANKS;
             overflow_i = overflow_i + 1)
            overflow_seen = overflow_seen | bank_overflow_vec[overflow_i];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            input_active_q <= 1'b0;
            input_bank_q <= '0;
            rr_bank_q <= '0;
            first_beat_pending_q <= 1'b0;
            first_beat_last_q <= 1'b0;
            first_beat_mask_q <= 8'd0;
            first_beat_activations_q <= 64'd0;
            first_beat_weights_q <= '0;
            tag_head_q <= '0;
            tag_tail_q <= '0;
            tag_count_q <= '0;
            for (init_i = 0; init_i < TAG_FIFO_DEPTH; init_i = init_i + 1)
                tag_mem[init_i] <= '0;
        end else begin
            if (start_fire) begin
                input_active_q <= 1'b1;
                input_bank_q <= selected_bank;
                rr_bank_q <= bank_add(selected_bank, 1);
                tag_mem[tag_tail_q] <= selected_bank;
                tag_tail_q <= tag_ptr_inc(tag_tail_q);
                if (first_capture_fire) begin
                    first_beat_pending_q <= 1'b1;
                    first_beat_last_q <= in_last;
                    first_beat_mask_q <= in_lane_mask;
                    first_beat_activations_q <= in_activations_s8;
                    first_beat_weights_q <= in_weights_s8;
                end
            end
            if (bank_in_fire) begin
                if (first_beat_pending_q) begin
                    first_beat_pending_q <= 1'b0;
                    if (first_beat_last_q)
                        input_active_q <= 1'b0;
                end else if (in_last) begin
                    input_active_q <= 1'b0;
                end
            end
            if (out_fire)
                tag_head_q <= tag_ptr_inc(tag_head_q);
            case ({start_fire, out_fire})
                2'b10: tag_count_q <= tag_count_q + 1'b1;
                2'b01: tag_count_q <= tag_count_q - 1'b1;
                default: tag_count_q <= tag_count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (tag_count_q > TAG_FIFO_DEPTH)
                $fatal(1, "pingpong tag FIFO overflow");
            if (out_fire && !tag_valid)
                $fatal(1, "pingpong output fired without tag");
        end
    end
`endif

endmodule
