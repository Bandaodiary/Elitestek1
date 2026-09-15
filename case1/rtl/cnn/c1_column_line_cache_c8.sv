`timescale 1ns/1ps

// Atomic vertical column of three C8 words, backed by independent row RAMs.
// Lane 0/1/2 is (x,y-1)/(x,y)/(x,y+1), each coordinate clamped separately.
// Words within a row are x-major, group-minor. Input storage must be immutable
// between group_start operations (the same ownership rule as the scalar cache).
//
// Unlike c1_window_line_cache_c8, a miss ACCEPTS and snapshots the request.
// One accepted column always retires exactly one response. Do not connect
// this interface to a scalar tap retry producer without an explicit adapter.
// Needed resident rows are protected throughout all missing-row refills;
// duplicate boundary rows share one bank/read and fan out into multiple lanes.
// All distinct rows are read on the SAME clock, not three scalar transactions.
//
// Refill: exactly word_count beats, irrespective of last/error. Bad last or
// data error poisons the row, drains the declared count, returns a zero/error
// column and raises a sticky cache_error. Config or maintenance clears it.
//
// Maintenance: edge-qualified, coalesced independently by kind. Never withdraw
// an offered refill request or response. Drain an offered/accepted refill in
// full; an accepted column not yet presented becomes a zero/error response.
// An already presented response is preserved, even if successful. Completion
// waits for its consumption, then invalidates tags. Flush preserves geometry;
// abort also clears config_valid. Holding a request high does not retrigger,
// but inhibits new column/config acceptance until lowered. Reset is a global
// protocol reset, not a substitute for graceful maintenance.
module c1_column_line_cache_c8 #(
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    // Issue the synchronous RAM read on the all-hit lookup edge instead of
    // spending another cycle in ST_READ. Adds tag-hit logic to RAM enable;
    // retain the registered path by default until physical timing is checked.
    parameter bit READ_ON_LOOKUP = 1'b0,
    // Forward already-clocked RAM data during capture; a stalled response
    // uses the existing holding register. Keep the fully registered path
    // by default: this moves the row-selection mux across the interface.
    parameter bit RESPONSE_BYPASS = 1'b0,
    // Consecutive columns with the SAME signed center Y use the last proven
    // row-bank map. Read synchronous RAM on acceptance; no extra transaction
    // slot or data cache. Adds request-offset selection at the RAM address.
    parameter bit REUSE_ROW_MAP = 1'b0
) (
    input logic clk, rst,
    input logic group_start_valid,
    output logic group_start_ready,
    input logic [15:0] frame_width, frame_height,
    input logic [3:0] frame_groups,
    output logic group_start_done, group_start_error,
    output logic [2:0] group_start_error_code,
    output logic config_valid,
    input logic abort_req, flush_req,
    output logic abort_done, flush_done,
    input logic column_valid,
    output logic column_ready,
    input logic signed [16:0] column_x, column_y,
    input logic [2:0] column_group,
    output logic column_rsp_valid,
    input logic column_rsp_ready,
    output logic [3*DATA_W-1:0] column_rsp_data_s8,
    output logic column_rsp_error,
    output logic refill_req_valid,
    input logic refill_req_ready,
    output logic [15:0] refill_req_row, refill_req_word_count,
    input logic refill_word_valid,
    output logic refill_word_ready,
    input logic [DATA_W-1:0] refill_word_data_s8,
    input logic refill_word_last, refill_word_error,
    output logic cache_error,
    output logic [2:0] cache_error_code,
    output logic busy, quiescent
);
    localparam integer AW = (MAX_ROW_WORDS <= 1) ? 1 : $clog2(MAX_ROW_WORDS);
    localparam integer BW = (LINE_ROWS <= 1) ? 1 : $clog2(LINE_ROWS);
    typedef enum logic [2:0] {
        ST_IDLE, ST_LOOKUP, ST_REFILL_REQ, ST_REFILL_DATA,
        ST_READ, ST_CAPTURE, ST_RESPONSE
    } state_t;
    state_t state_q;
    logic [15:0] width_q, height_q, row_words_q;
    logic [3:0] groups_q;
    logic [LINE_ROWS-1:0] row_valid_q;
    logic [15:0] row_tag_q [0:LINE_ROWS-1];
    logic [BW-1:0] replace_q, refill_slot_q;
    logic [15:0] target_y_q [0:2];
    logic [AW-1:0] offset_q;
    logic [15:0] refill_row_q, refill_index_q;
    logic refill_bad_q;
    logic abort_seen_q, flush_seen_q, abort_pending_q, flush_pending_q;
    wire new_abort = abort_req && !abort_seen_q;
    wire new_flush = flush_req && !flush_seen_q;
    wire maintenance = abort_pending_q || flush_pending_q || new_abort || new_flush;
    wire refill_fire = refill_word_valid && refill_word_ready;
    wire expected_last = (refill_index_q == row_words_q - 1'b1);
    wire bad_beat = refill_word_error || (refill_word_last != expected_last);
    wire [19:0] cfg_words = {4'b0,frame_width} * frame_groups;
    logic [15:0] clamped_x;
    logic [19:0] request_offset;
    logic [LINE_ROWS-1:0] lane_hit [0:2];
    logic [LINE_ROWS-1:0] protected_rows, read_mask_q;
    logic [LINE_ROWS-1:0] read_lane_q [0:2];
    logic all_hit, missing_found, victim_found;
    logic [15:0] missing_row;
    logic [BW-1:0] victim;
    integer candidate;
    wire [LINE_ROWS-1:0] rd_en, wr_en;
    wire [LINE_ROWS*AW-1:0] rd_addr;
    wire [LINE_ROWS*DATA_W-1:0] rd_data;
    logic [3*DATA_W-1:0] selected_column;
    logic [3*DATA_W-1:0] response_data_q;
    logic response_error_q;
    logic row_map_valid_q;
    logic signed [16:0] request_y_q;
    wire reuse_row_fire = REUSE_ROW_MAP && column_valid && column_ready &&
        row_map_valid_q && column_y == request_y_q && column_group < groups_q;

    // Extend BEFORE +/-1, so signed 17-bit endpoints do not wrap.
    function automatic [15:0] clamp_coord(input logic signed [17:0] c,
                                         input logic [15:0] size);
        if (c < 0) clamp_coord = 0;
        else if ($unsigned(c) >= {2'b0,size}) clamp_coord = size - 1'b1;
        else clamp_coord = c[15:0];
    endfunction

    always_comb begin
        clamped_x = clamp_coord({column_x[16],column_x}, width_q);
        request_offset = {4'b0,clamped_x} * groups_q + column_group;
        protected_rows = '0;
        all_hit = 1'b1;
        missing_found = 1'b0;
        missing_row = '0;
        for (integer lane=0; lane<3; lane++) begin
            lane_hit[lane] = '0;
            for (integer b=0; b<LINE_ROWS; b++)
                lane_hit[lane][b] = row_valid_q[b] && row_tag_q[b] == target_y_q[lane];
            protected_rows = protected_rows | lane_hit[lane];
            if (lane_hit[lane] == '0) begin
                all_hit = 1'b0;
                if (!missing_found) begin
                    missing_row = target_y_q[lane];
                    missing_found = 1'b1;
                end
            end
        end
        // Prefer empty banks, then round-robin among UNPROTECTED banks.
        // Protect all three targets, not only the row currently being filled.
        victim = '0;
        victim_found = 1'b0;
        for (integer b=0; b<LINE_ROWS; b++) begin
            if (!row_valid_q[b] && !victim_found) begin
                victim = BW'(b);
                victim_found = 1'b1;
            end
        end
        candidate = 0;
        for (integer n=0; n<LINE_ROWS; n++) begin
            candidate = int'(replace_q) + n;
            if (candidate >= LINE_ROWS) candidate = candidate - LINE_ROWS;
            if (!protected_rows[candidate] && !victim_found) begin
                victim = BW'(candidate);
                victim_found = 1'b1;
            end
        end
    end

    for (genvar b=0; b<LINE_ROWS; b++) begin : g_ports
        assign rd_en[b] = !rst && !maintenance &&
            ((state_q == ST_READ && read_mask_q[b]) ||
             (READ_ON_LOOKUP && state_q == ST_LOOKUP && all_hit && protected_rows[b]) ||
             (reuse_row_fire && read_mask_q[b]));
        assign rd_addr[b*AW +: AW] = reuse_row_fire ? request_offset[AW-1:0] : offset_q;
        assign wr_en[b] = !rst && refill_fire && refill_slot_q == b &&
                         !maintenance && !refill_bad_q && !bad_beat;
    end
    c1_row_banked_ram #(.DATA_WIDTH(DATA_W), .ROWS(LINE_ROWS),
        .ROW_WORDS(MAX_ROW_WORDS), .ADDR_WIDTH(AW)) u_rows (
        .clk(clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data),
        .wr_en(wr_en), .wr_addr(refill_index_q[AW-1:0]), .wr_data(refill_word_data_s8)
    );
    always_comb begin
        selected_column = '0;
        for (integer lane=0; lane<3; lane++)
            for (integer b=0; b<LINE_ROWS; b++)
                if (read_lane_q[lane][b])
                    selected_column[lane*DATA_W +: DATA_W] = rd_data[b*DATA_W +: DATA_W];
    end

    always_comb begin
        quiescent = state_q == ST_IDLE && !abort_pending_q && !flush_pending_q;
        busy = !quiescent;
        group_start_ready = !rst && quiescent && !abort_req && !flush_req;
        column_ready = !rst && quiescent && config_valid && !cache_error &&
                       !group_start_valid && !abort_req && !flush_req;
        column_rsp_valid = !rst && (state_q == ST_RESPONSE ||
                                   (RESPONSE_BYPASS && state_q == ST_CAPTURE));
        column_rsp_data_s8 = (RESPONSE_BYPASS && state_q == ST_CAPTURE) ?
                            (response_error_q ? '0 : selected_column) : response_data_q;
        column_rsp_error = response_error_q;
        refill_req_valid = !rst && state_q == ST_REFILL_REQ;
        refill_req_row = refill_row_q;
        refill_req_word_count = row_words_q;
        refill_word_ready = !rst && state_q == ST_REFILL_DATA;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            width_q <= '0; height_q <= '0; groups_q <= '0; row_words_q <= '0;
            config_valid <= 1'b0;
            row_valid_q <= '0; replace_q <= '0;
            offset_q <= '0; read_mask_q <= '0;
            refill_slot_q <= '0; refill_row_q <= '0; refill_index_q <= '0;
            refill_bad_q <= 1'b0;
            abort_seen_q <= 1'b0; flush_seen_q <= 1'b0;
            abort_pending_q <= 1'b0; flush_pending_q <= 1'b0;
            abort_done <= 1'b0; flush_done <= 1'b0;
            group_start_done <= 1'b0; group_start_error <= 1'b0;
            group_start_error_code <= '0;
            response_data_q <= '0; response_error_q <= 1'b0;
            row_map_valid_q <= 1'b0; request_y_q <= '0;
            cache_error <= 1'b0; cache_error_code <= '0;
            for (integer b=0; b<LINE_ROWS; b++) row_tag_q[b] <= '0;
            for (integer lane=0; lane<3; lane++) begin
                target_y_q[lane] <= '0;
                read_lane_q[lane] <= '0;
            end
        end else begin
            group_start_done <= 1'b0; group_start_error <= 1'b0;
            group_start_error_code <= '0;
            abort_done <= 1'b0; flush_done <= 1'b0;
            abort_seen_q <= abort_req; flush_seen_q <= flush_req;
            if (new_abort) abort_pending_q <= 1'b1;
            if (new_flush) flush_pending_q <= 1'b1;
            // Clear eligibility, not the in-flight read map/data: a response
            // already presented before maintenance must remain unchanged.
            if (maintenance) row_map_valid_q <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (group_start_valid && group_start_ready) begin
                        group_start_done <= 1'b1;
                        row_valid_q <= '0; replace_q <= '0;
                        row_map_valid_q <= 1'b0;
                        cache_error <= 1'b0; cache_error_code <= '0;
                        width_q <= frame_width; height_q <= frame_height;
                        groups_q <= frame_groups; row_words_q <= cfg_words[15:0];
                        config_valid <= 1'b0;
                        if (!frame_width || !frame_height || !frame_groups) begin
                            group_start_error <= 1'b1; group_start_error_code <= 3'd1;
                        end else if (frame_groups > MAX_GROUPS) begin
                            group_start_error <= 1'b1; group_start_error_code <= 3'd2;
                        end else if (cfg_words > MAX_ROW_WORDS) begin
                            group_start_error <= 1'b1; group_start_error_code <= 3'd3;
                        end else config_valid <= 1'b1;
                    end else if (column_valid && column_ready) begin
                        response_data_q <= '0;
                        response_error_q <= column_group >= groups_q;
                        if (column_group >= groups_q) begin
                            row_map_valid_q <= 1'b0;
                            state_q <= ST_RESPONSE;
                        end
                        else begin
                            offset_q <= request_offset[AW-1:0];
                            target_y_q[0] <= clamp_coord($signed({column_y[16],column_y}) - 18'sd1, height_q);
                            target_y_q[1] <= clamp_coord({column_y[16],column_y}, height_q);
                            target_y_q[2] <= clamp_coord($signed({column_y[16],column_y}) + 18'sd1, height_q);
                            if (reuse_row_fire) state_q <= ST_CAPTURE;
                            else begin
                                // Exact signed Y matters at replicated borders:
                                // centers -1 and 0 do not have the same lanes.
                                request_y_q <= column_y;
                                row_map_valid_q <= 1'b0;
                                state_q <= ST_LOOKUP;
                            end
                        end
                    end
                end
                ST_LOOKUP: begin
                    if (maintenance) begin
                        response_data_q <= '0; response_error_q <= 1'b1;
                        state_q <= ST_RESPONSE;
                    end else if (all_hit) begin
                        read_mask_q <= protected_rows;
                        row_map_valid_q <= REUSE_ROW_MAP;
                        for (integer lane=0; lane<3; lane++) read_lane_q[lane] <= lane_hit[lane];
                        if(READ_ON_LOOKUP) state_q <= ST_CAPTURE;
                        else state_q <= ST_READ;
                    end else if (victim_found) begin
                        refill_slot_q <= victim; refill_row_q <= missing_row;
                        refill_index_q <= '0; refill_bad_q <= 1'b0;
                        row_valid_q[victim] <= 1'b0;
                        state_q <= ST_REFILL_REQ;
                    end
                end
                ST_REFILL_REQ: if (refill_req_ready) state_q <= ST_REFILL_DATA;
                ST_REFILL_DATA: if (refill_fire) begin
                    if (bad_beat) begin
                        refill_bad_q <= 1'b1;
                        if (!cache_error) begin
                            cache_error <= 1'b1;
                            cache_error_code <= refill_word_error ? 3'd1 : 3'd2;
                        end
                    end
                    if (expected_last) begin
                        refill_index_q <= '0;
                        if (maintenance || refill_bad_q || bad_beat) begin
                            response_data_q <= '0; response_error_q <= 1'b1;
                            state_q <= ST_RESPONSE;
                        end else begin
                            row_tag_q[refill_slot_q] <= refill_row_q;
                            row_valid_q[refill_slot_q] <= 1'b1;
                            replace_q <= (refill_slot_q == LINE_ROWS-1) ? '0 : refill_slot_q + 1'b1;
                            state_q <= ST_LOOKUP;
                        end
                    end else refill_index_q <= refill_index_q + 1'b1;
                end
                ST_READ: begin
                    // Freeze the outcome at the RAM-read edge. A fence
                    // arriving AFTER capture is visible may not poison it.
                    if (RESPONSE_BYPASS) response_error_q <= maintenance;
                    state_q <= ST_CAPTURE;
                end
                ST_CAPTURE: begin
                    if (RESPONSE_BYPASS) begin
                        response_data_q <= column_rsp_data_s8;
                        if (column_rsp_ready) state_q <= ST_IDLE;
                        else state_q <= ST_RESPONSE;
                    end else begin
                        response_data_q <= maintenance ? '0 : selected_column;
                        response_error_q <= maintenance;
                        state_q <= ST_RESPONSE;
                    end
                end
                ST_RESPONSE: if (column_rsp_ready) state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase

            if (maintenance && state_q == ST_IDLE) begin
                row_valid_q <= '0; replace_q <= '0;
                cache_error <= 1'b0; cache_error_code <= '0;
                if (abort_pending_q || new_abort) begin
                    config_valid <= 1'b0;
                    abort_pending_q <= 1'b0; abort_done <= 1'b1;
                end
                if (flush_pending_q || new_flush) begin
                    flush_pending_q <= 1'b0; flush_done <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_W < 1 || LINE_ROWS < 3)
            $fatal(1,"column cache needs positive data width and at least three rows");
        if (MAX_ROW_WORDS < 1 || MAX_ROW_WORDS > 65535 || MAX_GROUPS < 1 || MAX_GROUPS > 8)
            $fatal(1,"column cache invalid row/group capacity");
    end
    logic held_req_q, held_rsp_q;
    logic [31:0] held_req_payload_q;
    logic [3*DATA_W:0] held_rsp_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin held_req_q <= 1'b0; held_rsp_q <= 1'b0; end
        else begin
            if (reuse_row_fire) begin
                if (!all_hit || read_mask_q != protected_rows || maintenance)
                    $fatal(1,"column cache reused stale row ownership");
                for (integer lane=0; lane<3; lane++)
                    if (read_lane_q[lane] != lane_hit[lane])
                        $fatal(1,"column cache reused stale lane mapping");
            end
            if (held_req_q && (!refill_req_valid ||
                {refill_req_row,refill_req_word_count} !== held_req_payload_q))
                $fatal(1,"column cache withdrew/changed stalled refill request");
            if (held_rsp_q && (!column_rsp_valid ||
                {column_rsp_error,column_rsp_data_s8} !== held_rsp_payload_q))
                $fatal(1,"column cache withdrew/changed stalled response");
            held_req_q <= refill_req_valid && !refill_req_ready;
            held_req_payload_q <= {refill_req_row,refill_req_word_count};
            held_rsp_q <= column_rsp_valid && !column_rsp_ready;
            held_rsp_payload_q <= {column_rsp_error,column_rsp_data_s8};
            if (state_q == ST_LOOKUP && !maintenance && !all_hit && !victim_found)
                $fatal(1,"column cache has no unprotected victim");
            if (state_q == ST_LOOKUP && !maintenance && !all_hit && protected_rows[victim])
                $fatal(1,"column cache attempted to evict a target row");
            if (state_q == ST_READ && !maintenance &&
                ((read_mask_q & row_valid_q) !== read_mask_q || offset_q >= row_words_q))
                $fatal(1,"column cache read without complete row/address ownership");
        end
    end
`endif
endmodule
