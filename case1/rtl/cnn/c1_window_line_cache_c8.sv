`timescale 1ns/1ps

// Three-row, board-independent cache for C8 signed-int8 tensor pixels.
//
// One 64-bit word contains eight signed-int8 channels.  A cached row contains
// every C8 group for that row in the tensor adapter's native order:
//
//     word_index = x * frame_groups + group
//
// Consequently, changing tap_group does not invalidate or replace a row.
// group_start denotes the beginning of a tensor stage, snapshots the frame
// geometry, and invalidates all row tags.  It is accepted only while the cache
// is quiescent.
//
// Miss/refill contract:
// * A tap producer holds tap_valid, tap_x/y, and tap_group stable until
//   tap_ready.  Signed x/y coordinates are clamped for SAME/replicate edges.
// * A row miss does not consume the tap.  The cache issues one refill request,
//   then the producer retries the still-pending tap after the row is resident.
// * A refill contains exactly refill_req_word_count words, in x-major and
//   group-minor order.  refill_word_last must be asserted on the final word
//   only.  refill_word_error poisons the whole row, but it does not shorten the
//   transfer: the source must still provide the declared number of words.
// * A refill row becomes visible only after its complete, error-free stream.
//
// Maintenance contract:
// * abort_req and flush_req are edge-qualified requests and are internally
//   latched.  Holding either request high triggers exactly one operation.
// * Neither operation withdraws a stalled refill_req_valid or tap_rsp_valid.
//   An accepted refill is drained for its declared word count, even after an
//   abort/flush request, and its data is discarded.
// * Completion waits for any tap response to be accepted, invalidates all row
//   tags, and pulses the corresponding *_done output.  Flush preserves the
//   active stage geometry; abort also clears config_valid.
// * quiescent describes internal protocol state.  It does not depend on an
//   unaccepted tap_valid or group_start_valid presented by the environment.
(* use_dsp = "no" *)
module c1_window_line_cache_c8 #(
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    // When set, the upstream seam guarantees that tap_x/tap_y have already
    // been saturated to the active stage geometry.  Bypassing the duplicate
    // width/height compares removes those registers from the tap_ready path.
    // Keep zero for the standalone/general-purpose cache ABI.
    parameter integer PRECLAMPED_TAP_COORDS = 0,
    // Opt-in physical row banking. Scalar tap latency/order are unchanged;
    // exposing parallel taps requires a separate controller/interface change.
    parameter integer ROW_BANKED_STORAGE = 0
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       group_start_valid,
    output logic                       group_start_ready,
    input  logic [15:0]                frame_width,
    input  logic [15:0]                frame_height,
    input  logic [3:0]                 frame_groups,
    output logic                       group_start_done,
    output logic                       group_start_error,
    output logic [2:0]                 group_start_error_code,
    output logic                       config_valid,

    input  logic                       abort_req,
    output logic                       abort_done,
    input  logic                       flush_req,
    output logic                       flush_done,

    input  logic                       tap_valid,
    output logic                       tap_ready,
    input  logic signed [16:0]         tap_x,
    input  logic signed [16:0]         tap_y,
    input  logic [2:0]                 tap_group,

    output logic                       tap_rsp_valid,
    input  logic                       tap_rsp_ready,
    output logic [DATA_W-1:0]          tap_rsp_data_s8,
    output logic                       tap_rsp_error,

    output logic                       refill_req_valid,
    input  logic                       refill_req_ready,
    output logic [15:0]                refill_req_row,
    output logic [15:0]                refill_req_word_count,

    input  logic                       refill_word_valid,
    output logic                       refill_word_ready,
    input  logic [DATA_W-1:0]          refill_word_data_s8,
    input  logic                       refill_word_last,
    input  logic                       refill_word_error,

    output logic                       cache_error,
    output logic [2:0]                 cache_error_code,
    output logic                       busy,
    output logic                       quiescent
);

    localparam logic [2:0] START_ERR_NONE = 3'd0;
    localparam logic [2:0] START_ERR_ZERO_GEOMETRY = 3'd1;
    localparam logic [2:0] START_ERR_GROUP_LIMIT = 3'd2;
    localparam logic [2:0] START_ERR_ROW_CAPACITY = 3'd3;

    localparam logic [2:0] CACHE_ERR_NONE = 3'd0;
    localparam logic [2:0] CACHE_ERR_REFILL_DATA = 3'd1;
    localparam logic [2:0] CACHE_ERR_REFILL_LAST = 3'd2;

    localparam integer PTR_W = (LINE_ROWS <= 1) ? 1 : $clog2(LINE_ROWS);
    localparam integer MEM_WORDS = LINE_ROWS * MAX_ROW_WORDS;
    localparam integer MEM_ADDR_W = (MEM_WORDS <= 1) ? 1 : $clog2(MEM_WORDS);

    initial begin
        if (DATA_W < 1)
            $fatal(1, "DATA_W must be positive");
        if (LINE_ROWS < 1)
            $fatal(1, "LINE_ROWS must be positive");
        if ((MAX_ROW_WORDS < 1) || (MAX_ROW_WORDS > 65535))
            $fatal(1, "MAX_ROW_WORDS must be in the range 1..65535");
        if ((MAX_GROUPS < 1) || (MAX_GROUPS > 8))
            $fatal(1, "MAX_GROUPS must be in the range 1..8");
    end

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_REFILL_REQ,
        ST_REFILL_DATA
    } state_t;

    state_t state_q;

    logic [15:0] width_q;
    logic [15:0] height_q;
    logic [3:0] groups_q;
    logic [15:0] row_words_q;
    logic config_valid_q;

    logic [LINE_ROWS-1:0] row_valid_q;
    logic [15:0] row_tag_q [0:LINE_ROWS-1];
    logic [PTR_W-1:0] replace_ptr_q;

    logic [15:0] refill_row_q;
    logic [15:0] refill_words_q;
    logic [15:0] refill_word_index_q;
    logic [PTR_W-1:0] refill_slot_q;
    logic refill_bad_q;
    logic discard_refill_q;

    logic tap_rsp_valid_q;
    logic [DATA_W-1:0] tap_rsp_data_q;
    logic tap_rsp_error_q;
    logic address_pending_q;
    logic [LINE_ROWS-1:0] read_slot_onehot_q;
    logic [MEM_ADDR_W-1:0] read_offset_q;
    logic read_pending_q;
    logic [MEM_ADDR_W-1:0] read_addr_q;

    logic abort_seen_q;
    logic abort_pending_q;
    logic flush_seen_q;
    logic flush_pending_q;

    logic cache_error_q;
    logic [2:0] cache_error_code_q;

    // The payload RAM is deliberately not reset.  A word may be read only
    // after its complete row has acquired a valid tag.
    (* ram_style = "block" *)
    logic [DATA_W-1:0] data_mem [0:MEM_WORDS-1];
    localparam integer ROW_ADDR_W = (MAX_ROW_WORDS <= 1) ? 1 : $clog2(MAX_ROW_WORDS);
    logic [LINE_ROWS-1:0] bank_read_slot_q;
    logic [ROW_ADDR_W-1:0] bank_read_offset_q;
    wire [LINE_ROWS*DATA_W-1:0] bank_read_data;
    logic [DATA_W-1:0] bank_selected_data;
    logic refill_word_fire;
    logic refill_word_protocol_bad;
    logic maintenance_active;
    generate if (ROW_BANKED_STORAGE != 0) begin : g_banked_storage
        wire [LINE_ROWS-1:0] rd_en, wr_en;
        wire [LINE_ROWS*ROW_ADDR_W-1:0] rd_addr;
        for(genvar b=0;b<LINE_ROWS;b++) begin : g_ports
            assign rd_en[b] = !rst && read_pending_q && bank_read_slot_q[b];
            assign rd_addr[b*ROW_ADDR_W +: ROW_ADDR_W] = bank_read_offset_q;
            assign wr_en[b] = !rst && refill_word_fire && refill_slot_q == b &&
                !discard_refill_q && !maintenance_active && !refill_bad_q &&
                !refill_word_error && !refill_word_protocol_bad;
        end
        c1_row_banked_ram #(.DATA_WIDTH(DATA_W), .ROWS(LINE_ROWS),
            .ROW_WORDS(MAX_ROW_WORDS), .ADDR_WIDTH(ROW_ADDR_W)) u_rows (
            .clk(clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(bank_read_data),
            .wr_en(wr_en), .wr_addr(refill_word_index_q[ROW_ADDR_W-1:0]),
            .wr_data(refill_word_data_s8)
        );
    end else begin : g_no_banked_storage
        assign bank_read_data = '0;
    end endgenerate
    always_comb begin
        bank_selected_data = '0;
        for(integer b=0;b<LINE_ROWS;b++)
            if(bank_read_slot_q[b])
                bank_selected_data = bank_read_data[b*DATA_W +: DATA_W];
    end

    logic [19:0] cfg_row_words_full;
    logic [19:0] tap_row_offset_full;
    logic [15:0] clamped_x;
    logic [15:0] clamped_y;
    logic [LINE_ROWS-1:0] row_hit;
    logic lookup_hit;
    logic tap_group_valid;
    logic response_space;
    logic tap_fire;
    logic miss_event;
    logic refill_expected_last;
    logic new_abort;
    logic new_flush;
    logic complete_maintenance;
    logic invalid_found;
    integer victim_slot;
    integer comb_k;
    integer seq_k;
    logic [MEM_ADDR_W-1:0] pending_read_addr;
    logic [MEM_ADDR_W-1:0] refill_mem_addr;

    // Four-bit shift/add multiply.  Keeping the small dynamic group count out
    // of a generic multiplier avoids making a DSP block part of the cache ABI.
    function automatic logic [19:0] width_times_groups(
        input logic [15:0] width_value,
        input logic [3:0] group_value
    );
        logic [19:0] product;
        begin
            product = 20'd0;
            if (group_value[0])
                product = product + {4'd0, width_value};
            if (group_value[1])
                product = product + ({4'd0, width_value} << 1);
            if (group_value[2])
                product = product + ({4'd0, width_value} << 2);
            if (group_value[3])
                product = product + ({4'd0, width_value} << 3);
            width_times_groups = product;
        end
    endfunction

    always_comb begin
        cfg_row_words_full = width_times_groups(frame_width, frame_groups);

        if (PRECLAMPED_TAP_COORDS != 0) begin
            // The exact/seam wrappers clamp before presenting a tap.  Keep a
            // sign guard so an accidental negative value cannot turn into a
            // large RAM address; upper-bound checking belongs to that wrapper.
            clamped_x = tap_x[16] ? 16'd0 : tap_x[15:0];
            clamped_y = tap_y[16] ? 16'd0 : tap_y[15:0];
        end else begin
            if (!config_valid_q || (width_q == 0) || ($signed(tap_x) < 0))
                clamped_x = 16'd0;
            else if ($unsigned(tap_x) >= {1'b0, width_q})
                clamped_x = width_q - 1'b1;
            else
                clamped_x = tap_x[15:0];

            if (!config_valid_q || (height_q == 0) || ($signed(tap_y) < 0))
                clamped_y = 16'd0;
            else if ($unsigned(tap_y) >= {1'b0, height_q})
                clamped_y = height_q - 1'b1;
            else
                clamped_y = tap_y[15:0];
        end

        tap_row_offset_full = width_times_groups(clamped_x, groups_q) +
                              tap_group;

        row_hit = '0;
        lookup_hit = 1'b0;
        for (comb_k = 0; comb_k < LINE_ROWS; comb_k = comb_k + 1) begin
            row_hit[comb_k] = row_valid_q[comb_k] &&
                              (row_tag_q[comb_k] == clamped_y);
            lookup_hit = lookup_hit || row_hit[comb_k];
        end

        // Prefer the lowest invalid slot.  Once all slots are valid, use a
        // deterministic round-robin victim.
        victim_slot = 0;
        invalid_found = 1'b0;
        for (comb_k = 0; comb_k < LINE_ROWS; comb_k = comb_k + 1) begin
            if (!row_valid_q[comb_k] && !invalid_found) begin
                victim_slot = comb_k;
                invalid_found = 1'b1;
            end
        end
        if (!invalid_found) begin
            victim_slot = replace_ptr_q;
            if (victim_slot >= LINE_ROWS)
                victim_slot = 0;
        end

        // LINE_ROWS is a synthesis-time constant.  Express each slot base as
        // an unrolled constant-select mux instead of multiplying a dynamic
        // slot index by MAX_ROW_WORDS.  Besides matching Efinity-friendly
        // hardware, this prevents Vivado from putting a DSP48 in the address
        // path of the block RAM.
        pending_read_addr = read_offset_q;
        refill_mem_addr = refill_word_index_q;
        for (comb_k = 0; comb_k < LINE_ROWS; comb_k = comb_k + 1) begin
            // The hit vector and row offset were captured on tap_fire.  This
            // second pipeline stage now has only a constant-base mux and an
            // address add between registers; tag compare/clamp logic is not
            // part of the same timing path.
            if (read_slot_onehot_q[comb_k])
                pending_read_addr = (comb_k * MAX_ROW_WORDS) +
                                    read_offset_q;
            if (refill_slot_q == comb_k[PTR_W-1:0])
                refill_mem_addr = (comb_k * MAX_ROW_WORDS) +
                                  refill_word_index_q;
        end
    end

    always_comb begin
        new_abort = abort_req && !abort_seen_q;
        new_flush = flush_req && !flush_seen_q;
        maintenance_active = abort_pending_q || flush_pending_q ||
                             new_abort || new_flush;

        tap_group_valid = config_valid_q && (tap_group < groups_q);
        response_space = !tap_rsp_valid_q || tap_rsp_ready;

        quiescent = (state_q == ST_IDLE) && !address_pending_q &&
                    !read_pending_q &&
                    !tap_rsp_valid_q &&
                    !abort_pending_q && !flush_pending_q;
        busy = !quiescent;

        group_start_ready = !rst && quiescent &&
                            !abort_req && !flush_req;

        // An invalid group is consumed as an error response.  A row miss is
        // not consumed; miss_event starts its refill and the request retries.
        tap_ready = !rst && (state_q == ST_IDLE) && config_valid_q &&
                    !address_pending_q && !read_pending_q &&
                    response_space && !maintenance_active &&
                    !group_start_valid && !cache_error_q &&
                    (lookup_hit || !tap_group_valid);
        tap_fire = tap_valid && tap_ready;
        miss_event = !rst && (state_q == ST_IDLE) && config_valid_q &&
                     tap_valid && tap_group_valid && !lookup_hit &&
                     !address_pending_q && !read_pending_q &&
                     response_space && !maintenance_active &&
                     !group_start_valid && !cache_error_q;

        tap_rsp_valid = tap_rsp_valid_q;
        tap_rsp_data_s8 = (ROW_BANKED_STORAGE != 0) ?
            ((tap_rsp_valid_q && !tap_rsp_error_q) ? bank_selected_data : '0) : tap_rsp_data_q;
        tap_rsp_error = tap_rsp_error_q;

        refill_req_valid = (state_q == ST_REFILL_REQ);
        refill_req_row = refill_row_q;
        refill_req_word_count = refill_words_q;
        refill_word_ready = (state_q == ST_REFILL_DATA);
        refill_word_fire = refill_word_valid && refill_word_ready;
        refill_expected_last =
            (refill_word_index_q == refill_words_q - 1'b1);
        refill_word_protocol_bad =
            (refill_word_last != refill_expected_last);

        complete_maintenance = maintenance_active &&
                               (state_q == ST_IDLE) &&
                               !address_pending_q &&
                               !read_pending_q &&
                               !tap_rsp_valid_q;

        config_valid = config_valid_q;
        cache_error = cache_error_q;
        cache_error_code = cache_error_code_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            width_q <= 16'd0;
            height_q <= 16'd0;
            groups_q <= 4'd0;
            row_words_q <= 16'd0;
            config_valid_q <= 1'b0;
            row_valid_q <= '0;
            replace_ptr_q <= '0;
            refill_row_q <= 16'd0;
            refill_words_q <= 16'd0;
            refill_word_index_q <= 16'd0;
            refill_slot_q <= '0;
            refill_bad_q <= 1'b0;
            discard_refill_q <= 1'b0;
            tap_rsp_valid_q <= 1'b0;
            tap_rsp_data_q <= '0;
            tap_rsp_error_q <= 1'b0;
            address_pending_q <= 1'b0;
            read_slot_onehot_q <= '0;
            bank_read_slot_q <= '0;
            bank_read_offset_q <= '0;
            read_offset_q <= '0;
            read_pending_q <= 1'b0;
            read_addr_q <= '0;
            abort_seen_q <= 1'b0;
            abort_pending_q <= 1'b0;
            flush_seen_q <= 1'b0;
            flush_pending_q <= 1'b0;
            cache_error_q <= 1'b0;
            cache_error_code_q <= CACHE_ERR_NONE;
            group_start_done <= 1'b0;
            group_start_error <= 1'b0;
            group_start_error_code <= START_ERR_NONE;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            for (seq_k = 0; seq_k < LINE_ROWS; seq_k = seq_k + 1)
                row_tag_q[seq_k] <= 16'd0;
        end else begin
            group_start_done <= 1'b0;
            group_start_error <= 1'b0;
            group_start_error_code <= START_ERR_NONE;
            abort_done <= 1'b0;
            flush_done <= 1'b0;

            if (!abort_req)
                abort_seen_q <= 1'b0;
            if (!flush_req)
                flush_seen_q <= 1'b0;

            if (new_abort) begin
                abort_seen_q <= 1'b1;
                abort_pending_q <= 1'b1;
                if ((state_q == ST_REFILL_REQ) ||
                    (state_q == ST_REFILL_DATA))
                    discard_refill_q <= 1'b1;
            end
            if (new_flush) begin
                flush_seen_q <= 1'b1;
                flush_pending_q <= 1'b1;
                if ((state_q == ST_REFILL_REQ) ||
                    (state_q == ST_REFILL_DATA))
                    discard_refill_q <= 1'b1;
            end

            if (tap_rsp_valid_q && tap_rsp_ready)
                tap_rsp_valid_q <= 1'b0;

            // Stage 2: turn the captured one-hot slot and in-row word offset
            // into a complete registered physical RAM address.
            if (address_pending_q) begin
                read_addr_q <= pending_read_addr;
                bank_read_slot_q <= read_slot_onehot_q;
                bank_read_offset_q <= read_offset_q[ROW_ADDR_W-1:0];
                read_pending_q <= 1'b1;
                address_pending_q <= 1'b0;
            end

            // Stage 3: the registered address drives the synchronous block-
            // RAM read.  Maintenance completion waits for both internal
            // stages and the resulting externally visible response to retire.
            if (read_pending_q) begin
                tap_rsp_valid_q <= 1'b1;
                if (ROW_BANKED_STORAGE == 0)
                    tap_rsp_data_q <= data_mem[read_addr_q];
                tap_rsp_error_q <= 1'b0;
                read_pending_q <= 1'b0;
            end

            if (group_start_valid && group_start_ready) begin
                group_start_done <= 1'b1;
                row_valid_q <= '0;
                replace_ptr_q <= '0;
                cache_error_q <= 1'b0;
                cache_error_code_q <= CACHE_ERR_NONE;
                width_q <= frame_width;
                height_q <= frame_height;
                groups_q <= frame_groups;
                row_words_q <= cfg_row_words_full[15:0];

                if ((frame_width == 0) || (frame_height == 0) ||
                    (frame_groups == 0)) begin
                    config_valid_q <= 1'b0;
                    group_start_error <= 1'b1;
                    group_start_error_code <= START_ERR_ZERO_GEOMETRY;
                end else if (frame_groups > MAX_GROUPS) begin
                    config_valid_q <= 1'b0;
                    group_start_error <= 1'b1;
                    group_start_error_code <= START_ERR_GROUP_LIMIT;
                end else if (cfg_row_words_full > MAX_ROW_WORDS) begin
                    config_valid_q <= 1'b0;
                    group_start_error <= 1'b1;
                    group_start_error_code <= START_ERR_ROW_CAPACITY;
                end else begin
                    config_valid_q <= 1'b1;
                end
            end

            if (tap_fire) begin
                if (!tap_group_valid) begin
                    tap_rsp_valid_q <= 1'b1;
                    tap_rsp_data_q <= '0;
                    tap_rsp_error_q <= 1'b1;
                end else begin
                    // Stage 1: the valid tag proves the entire selected row
                    // was filled.  Preserve the one-hot slot to avoid an
                    // encode/decode round trip in the next address stage.
                    address_pending_q <= 1'b1;
                    read_slot_onehot_q <= row_hit;
                    read_offset_q <= tap_row_offset_full;
                end
            end

            if (miss_event) begin
                state_q <= ST_REFILL_REQ;
                refill_row_q <= clamped_y;
                refill_words_q <= row_words_q;
                refill_word_index_q <= 16'd0;
                refill_slot_q <= victim_slot[PTR_W-1:0];
                refill_bad_q <= 1'b0;
                discard_refill_q <= 1'b0;
                row_valid_q[victim_slot] <= 1'b0;
            end

            if ((state_q == ST_REFILL_REQ) && refill_req_ready)
                state_q <= ST_REFILL_DATA;

            if (refill_word_fire) begin
                // Writes to a discarded or already-poisoned refill are not
                // required.  The stream is nevertheless drained in full.
                if (ROW_BANKED_STORAGE == 0 && !discard_refill_q && !maintenance_active &&
                    !refill_bad_q && !refill_word_error &&
                    !refill_word_protocol_bad)
                    data_mem[refill_mem_addr] <= refill_word_data_s8;

                if (refill_word_error || refill_word_protocol_bad) begin
                    refill_bad_q <= 1'b1;
                    if (!cache_error_q) begin
                        cache_error_q <= 1'b1;
                        if (refill_word_error)
                            cache_error_code_q <= CACHE_ERR_REFILL_DATA;
                        else
                            cache_error_code_q <= CACHE_ERR_REFILL_LAST;
                    end
                end

                if (refill_expected_last) begin
                    state_q <= ST_IDLE;
                    refill_word_index_q <= 16'd0;
                    if (!discard_refill_q && !maintenance_active &&
                        !refill_bad_q && !refill_word_error &&
                        !refill_word_protocol_bad) begin
                        row_valid_q[refill_slot_q] <= 1'b1;
                        row_tag_q[refill_slot_q] <= refill_row_q;
                        if (refill_slot_q == LINE_ROWS-1)
                            replace_ptr_q <= '0;
                        else
                            replace_ptr_q <= refill_slot_q + 1'b1;
                    end else begin
                        row_valid_q[refill_slot_q] <= 1'b0;
                    end
                end else begin
                    refill_word_index_q <= refill_word_index_q + 1'b1;
                end
            end

            // Complete maintenance only after every externally visible valid
            // has retired and every accepted refill word has been drained.
            // This final block intentionally overrides the request latches.
            if (complete_maintenance) begin
                row_valid_q <= '0;
                replace_ptr_q <= '0;
                discard_refill_q <= 1'b0;
                cache_error_q <= 1'b0;
                cache_error_code_q <= CACHE_ERR_NONE;
                if (abort_pending_q || new_abort) begin
                    abort_pending_q <= 1'b0;
                    abort_done <= 1'b1;
                    config_valid_q <= 1'b0;
                end
                if (flush_pending_q || new_flush) begin
                    flush_pending_q <= 1'b0;
                    flush_done <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Local protocol guards make the no-withdrawal contract executable in
    // simulation without imposing assertions on the external producers.
    logic refill_req_stalled_q;
    logic [31:0] refill_req_payload_q;
    logic tap_rsp_stalled_q;
    logic [DATA_W:0] tap_rsp_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            refill_req_stalled_q <= 1'b0;
            tap_rsp_stalled_q <= 1'b0;
        end else begin
            if ((PRECLAMPED_TAP_COORDS != 0) && tap_valid && tap_ready &&
                (!config_valid_q || (width_q == 0) || (height_q == 0) ||
                 tap_x[16] || tap_y[16] ||
                 ($unsigned(tap_x) >= {1'b0, width_q}) ||
                 ($unsigned(tap_y) >= {1'b0, height_q})))
                $fatal(1, "preclamped tap contract violated");
            if (refill_req_stalled_q &&
                (!refill_req_valid ||
                 ({refill_req_row, refill_req_word_count} !=
                  refill_req_payload_q)))
                $fatal(1, "line cache withdrew/changed stalled refill request");
            refill_req_stalled_q <= refill_req_valid && !refill_req_ready;
            refill_req_payload_q <= {refill_req_row,
                                     refill_req_word_count};

            if (tap_rsp_stalled_q &&
                (!tap_rsp_valid ||
                 ({tap_rsp_error, tap_rsp_data_s8} != tap_rsp_payload_q)))
                $fatal(1, "line cache withdrew/changed stalled tap response");
            tap_rsp_stalled_q <= tap_rsp_valid && !tap_rsp_ready;
            tap_rsp_payload_q <= {tap_rsp_error, tap_rsp_data_s8};
        end
    end
`endif

endmodule
