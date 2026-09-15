`timescale 1ns/1ps

// Optional three-row C8 cache in front of the existing 64-bit tensor-memory
// request/response seam.
//
// A registered front end accepts one complete upstream request, clamps and
// snapshots its cache sideband, then classifies it through two narrow
// arithmetic stages.  Physical-address validation is retained, but there is
// no combinational multiplier on s_req_ready or the cache tap/miss path.
// Every accepted request owns exactly one later upstream response.
//
// Writes, ordinary reads, and requests whose cache sideband fails validation
// are forwarded unchanged.  Eligible 3x3 reads drive
// c1_window_line_cache_c8.  A miss fetches one complete row in
// x-major/group-minor order.  The refill row base is captured from the
// validated request; subsequent 64-bit read addresses advance by eight, so
// the refill datapath contains no per-word row multiplication.
//
// Stage address-range validation uses a 16-cycle shift/add calculation.
// Request address validation uses registered, explicitly split shift/add
// partial products.  This keeps the complete module DSP-free while preserving
// the capacity, alignment, address-range, and sideband consistency guards.
//
// Abort/flush are drain operations.  A request accepted in the same cycle as
// abort/flush, a registered front-end request, a stalled downstream request,
// an accepted refill, and a presented response are all retired before the
// internal cache receives maintenance.  No ready/valid presentation is
// withdrawn.
module c1_tensor_window_cache_seam #(
    parameter integer DATA_W = 64,
    parameter integer LINE_ROWS = 3,
    parameter integer MAX_ROW_WORDS = 1280,
    parameter integer MAX_GROUPS = 8,
    // The registered front end clamps cache sideband coordinates before they
    // reach the payload cache.  This opt-in lets the child omit its duplicate
    // geometry compare; zero preserves the standalone cache contract.
    parameter integer PRECLAMPED_TAP_COORDS = 0
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       stage_start_valid,
    output logic                       stage_start_ready,
    input  logic                       stage_cache_enable,
    input  logic [31:0]                stage_base_addr,
    input  logic [15:0]                stage_width,
    input  logic [15:0]                stage_height,
    input  logic [3:0]                 stage_groups,
    output logic                       stage_start_done,
    output logic                       stage_cache_active,
    output logic                       stage_cache_fallback,
    output logic [3:0]                 stage_cache_reason,

    input  logic                       abort_req,
    output logic                       abort_done,
    input  logic                       flush_req,
    output logic                       flush_done,

    input  logic                       s_req_valid,
    output logic                       s_req_ready,
    input  logic                       s_req_write,
    input  logic [31:0]                s_req_addr,
    input  logic [DATA_W-1:0]          s_req_wdata,
    input  logic [(DATA_W/8)-1:0]      s_req_wstrb,
    input  logic                       s_req_cacheable,
    input  logic signed [16:0]         s_req_cache_x,
    input  logic signed [16:0]         s_req_cache_y,
    input  logic [2:0]                 s_req_cache_group,

    output logic                       s_rsp_valid,
    input  logic                       s_rsp_ready,
    output logic                       s_rsp_error,
    output logic [DATA_W-1:0]          s_rsp_rdata,

    output logic                       m_req_valid,
    input  logic                       m_req_ready,
    output logic                       m_req_write,
    output logic [31:0]                m_req_addr,
    output logic [DATA_W-1:0]          m_req_wdata,
    output logic [(DATA_W/8)-1:0]      m_req_wstrb,
    input  logic                       m_rsp_valid,
    output logic                       m_rsp_ready,
    input  logic                       m_rsp_error,
    input  logic [DATA_W-1:0]          m_rsp_rdata,

    output logic                       cache_error,
    output logic [2:0]                 cache_error_code,
    output logic                       busy,
    output logic                       quiescent
);

    localparam logic [3:0] CACHE_REASON_NONE = 4'd0;
    localparam logic [3:0] CACHE_REASON_DISABLED = 4'd1;
    localparam logic [3:0] CACHE_REASON_ZERO_GEOMETRY = 4'd2;
    localparam logic [3:0] CACHE_REASON_GROUP_LIMIT = 4'd3;
    localparam logic [3:0] CACHE_REASON_ROW_CAPACITY = 4'd4;
    localparam logic [3:0] CACHE_REASON_BASE_ALIGN = 4'd5;
    localparam logic [3:0] CACHE_REASON_ADDRESS_RANGE = 4'd6;
    localparam logic [3:0] CACHE_REASON_RUNTIME_ERROR = 4'd7;
    localparam logic [3:0] CACHE_REASON_COHERENCE = 4'd8;
    localparam logic [3:0] CACHE_REASON_CONFIG_REJECT = 4'd9;

    initial begin
        if (DATA_W != 64)
            $fatal(1, "tensor window cache seam currently requires DATA_W=64");
        if (MAX_GROUPS > 8)
            $fatal(1, "3-bit cache group sideband supports at most 8 groups");
    end

    typedef enum logic [1:0] {
        LOGICAL_NONE,
        LOGICAL_BYPASS,
        LOGICAL_CACHE
    } logical_owner_t;

    typedef enum logic [1:0] {
        DOWN_NONE,
        DOWN_BYPASS,
        DOWN_REFILL
    } down_owner_t;

    typedef enum logic [1:0] {
        MAINT_IDLE,
        MAINT_WAIT_ABORT,
        MAINT_WAIT_FLUSH
    } maint_state_t;

    typedef enum logic [1:0] {
        CFG_IDLE,
        CFG_MULTIPLY,
        CFG_FINISH
    } cfg_state_t;

    typedef enum logic [2:0] {
        FRONT_EMPTY,
        FRONT_SUM,
        FRONT_CHECK,
        FRONT_DISPATCH
    } front_state_t;

    logical_owner_t logical_owner_q;
    down_owner_t down_owner_q;
    maint_state_t maint_state_q;
    cfg_state_t cfg_state_q;
    front_state_t front_state_q;

    logic [31:0] stage_base_q;
    logic [32:0] stage_end_q;
    logic [15:0] stage_width_q;
    logic [15:0] stage_height_q;
    logic [3:0] stage_groups_q;
    logic [15:0] stage_row_words_q;
    logic stage_configured_q;
    logic stage_guard_active_q;
    logic [3:0] stage_reason_q;
    logic coherence_poison_q;

    logic [26:0] cfg_accum_q;
    logic [26:0] cfg_multiplicand_q;
    logic [15:0] cfg_multiplier_q;
    logic [4:0] cfg_count_q;
    logic [26:0] cfg_accum_next;
    logic [32:0] cfg_end_next;

    logic front_req_write_q;
    logic [31:0] front_req_addr_q;
    logic [DATA_W-1:0] front_req_wdata_q;
    logic [(DATA_W/8)-1:0] front_req_wstrb_q;
    logic signed [16:0] front_cache_x_q;
    logic signed [16:0] front_cache_y_q;
    logic [2:0] front_cache_group_q;
    logic front_cache_candidate_q;
    logic front_cache_route_q;
    (* use_dsp = "no" *) logic [26:0] front_partial0_q;
    (* use_dsp = "no" *) logic [26:0] front_partial1_q;
    (* use_dsp = "no" *) logic [26:0] front_partial2_q;
    logic [19:0] front_word_index_q;
    logic [26:0] front_y_words_q;
    logic [26:0] front_beat_index_q;
    logic [31:0] front_row_base_addr_q;

    logic refill_active_q;
    logic [15:0] refill_row_q;
    logic [15:0] refill_word_count_q;
    logic [15:0] refill_word_index_q;
    logic [31:0] refill_addr_q;
    logic refill_error_seen_q;

    logic abort_seen_q;
    logic abort_pending_q;
    logic flush_seen_q;
    logic flush_pending_q;
    logic drain_front_q;
    logic cache_abort_req_q;
    logic cache_flush_req_q;
    logic cache_start_seen_q;
    logic cache_start_ok_q;

    logic [19:0] stage_row_words_comb;
    logic stage_prelim_active;
    logic [3:0] stage_prelim_reason;

    logic [15:0] req_clamped_x;
    logic [15:0] req_clamped_y;
    (* use_dsp = "no" *) logic [26:0] req_partial0_comb;
    (* use_dsp = "no" *) logic [26:0] req_partial1_comb;
    (* use_dsp = "no" *) logic [26:0] req_partial2_comb;
    logic [19:0] req_word_index_comb;
    logic [26:0] front_y_sum_comb;
    logic [26:0] front_beat_sum_comb;
    logic [32:0] front_expected_addr_comb;
    logic [32:0] front_row_base_comb;

    logic s_req_fire;
    logic s_rsp_fire;
    logic front_cache_drive;
    logic front_bypass_drive;
    logic refill_down_request;
    logic bypass_down_request;
    logic m_req_fire;
    logic m_rsp_fire;
    logic refill_last_word;

    logic new_abort;
    logic new_flush;
    logic maintenance_pending;
    logic maintenance_can_launch;

    logic cache_group_start_valid;
    logic cache_group_start_ready;
    logic cache_group_start_done;
    logic cache_group_start_error;
    logic [2:0] cache_group_start_error_code;
    logic cache_config_valid;
    logic cache_abort_done;
    logic cache_flush_done;
    logic cache_tap_valid;
    logic cache_tap_ready;
    logic cache_tap_rsp_valid;
    logic cache_tap_rsp_ready;
    logic [DATA_W-1:0] cache_tap_rsp_data;
    logic cache_tap_rsp_error;
    logic cache_refill_req_valid;
    logic cache_refill_req_ready;
    logic [15:0] cache_refill_req_row;
    logic [15:0] cache_refill_req_word_count;
    logic cache_refill_word_valid;
    logic cache_refill_word_ready;
    logic [DATA_W-1:0] cache_refill_word_data;
    logic cache_refill_word_last;
    logic cache_error_i;
    logic [2:0] cache_error_code_i;
    logic cache_busy;
    logic cache_quiescent;

    // Four-bit shift/add multiply, used for width*groups and x*groups.
    function automatic logic [19:0] mul16x4_nodsp(
        input logic [15:0] value,
        input logic [3:0] factor
    );
        logic [19:0] extended;
        logic [19:0] pair0;
        logic [19:0] pair1;
        begin
            extended = {4'd0, value};
            pair0 = (factor[0] ? extended : 20'd0) +
                    (factor[1] ? (extended << 1) : 20'd0);
            pair1 = (factor[2] ? (extended << 2) : 20'd0) +
                    (factor[3] ? (extended << 3) : 20'd0);
            mul16x4_nodsp = pair0 + pair1;
        end
    endfunction

    // Split y*row_words into three registered four-bit partial products.  A
    // valid cache stage guarantees row_words <= MAX_ROW_WORDS (default 1280),
    // so 27 bits cover the largest product.
    function automatic logic [26:0] mul_part_0_3_nodsp(
        input logic [15:0] value,
        input logic [15:0] factor
    );
        logic [26:0] extended;
        logic [26:0] pair0;
        logic [26:0] pair1;
        begin
            extended = {11'd0, value};
            pair0 = (factor[0] ? extended : 27'd0) +
                    (factor[1] ? (extended << 1) : 27'd0);
            pair1 = (factor[2] ? (extended << 2) : 27'd0) +
                    (factor[3] ? (extended << 3) : 27'd0);
            mul_part_0_3_nodsp = pair0 + pair1;
        end
    endfunction

    function automatic logic [26:0] mul_part_4_7_nodsp(
        input logic [15:0] value,
        input logic [15:0] factor
    );
        logic [26:0] extended;
        logic [26:0] pair0;
        logic [26:0] pair1;
        begin
            extended = {11'd0, value};
            pair0 = (factor[4] ? (extended << 4) : 27'd0) +
                    (factor[5] ? (extended << 5) : 27'd0);
            pair1 = (factor[6] ? (extended << 6) : 27'd0) +
                    (factor[7] ? (extended << 7) : 27'd0);
            mul_part_4_7_nodsp = pair0 + pair1;
        end
    endfunction

    function automatic logic [26:0] mul_part_8_11_nodsp(
        input logic [15:0] value,
        input logic [15:0] factor
    );
        logic [26:0] extended;
        logic [26:0] pair0;
        logic [26:0] pair1;
        begin
            extended = {11'd0, value};
            pair0 = (factor[8] ? (extended << 8) : 27'd0) +
                    (factor[9] ? (extended << 9) : 27'd0);
            pair1 = (factor[10] ? (extended << 10) : 27'd0) +
                    (factor[11] ? (extended << 11) : 27'd0);
            mul_part_8_11_nodsp = pair0 + pair1;
        end
    endfunction

    c1_window_line_cache_c8 #(
        .DATA_W(DATA_W),
        .LINE_ROWS(LINE_ROWS),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(MAX_GROUPS),
        .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS)
    ) u_line_cache (
        .clk(clk),
        .rst(rst),
        .group_start_valid(cache_group_start_valid),
        .group_start_ready(cache_group_start_ready),
        .frame_width(stage_width),
        .frame_height(stage_height),
        .frame_groups(stage_groups),
        .group_start_done(cache_group_start_done),
        .group_start_error(cache_group_start_error),
        .group_start_error_code(cache_group_start_error_code),
        .config_valid(cache_config_valid),
        .abort_req(cache_abort_req_q),
        .abort_done(cache_abort_done),
        .flush_req(cache_flush_req_q),
        .flush_done(cache_flush_done),
        .tap_valid(cache_tap_valid),
        .tap_ready(cache_tap_ready),
        .tap_x(front_cache_x_q),
        .tap_y(front_cache_y_q),
        .tap_group(front_cache_group_q),
        .tap_rsp_valid(cache_tap_rsp_valid),
        .tap_rsp_ready(cache_tap_rsp_ready),
        .tap_rsp_data_s8(cache_tap_rsp_data),
        .tap_rsp_error(cache_tap_rsp_error),
        .refill_req_valid(cache_refill_req_valid),
        .refill_req_ready(cache_refill_req_ready),
        .refill_req_row(cache_refill_req_row),
        .refill_req_word_count(cache_refill_req_word_count),
        .refill_word_valid(cache_refill_word_valid),
        .refill_word_ready(cache_refill_word_ready),
        .refill_word_data_s8(cache_refill_word_data),
        .refill_word_last(cache_refill_word_last),
        // Downstream errors are returned on the logical response.  The line
        // stream still completes so the accepted request cannot deadlock.
        .refill_word_error(1'b0),
        .cache_error(cache_error_i),
        .cache_error_code(cache_error_code_i),
        .busy(cache_busy),
        .quiescent(cache_quiescent)
    );

    always_comb begin
        stage_row_words_comb = mul16x4_nodsp(stage_width, stage_groups);
        stage_prelim_active = 1'b0;
        stage_prelim_reason = CACHE_REASON_NONE;
        if (!stage_cache_enable)
            stage_prelim_reason = CACHE_REASON_DISABLED;
        else if ((stage_width == 0) || (stage_height == 0) ||
                 (stage_groups == 0))
            stage_prelim_reason = CACHE_REASON_ZERO_GEOMETRY;
        else if (stage_groups > MAX_GROUPS)
            stage_prelim_reason = CACHE_REASON_GROUP_LIMIT;
        else if (stage_row_words_comb > MAX_ROW_WORDS)
            stage_prelim_reason = CACHE_REASON_ROW_CAPACITY;
        else if (stage_base_addr[2:0] != 3'b000)
            stage_prelim_reason = CACHE_REASON_BASE_ALIGN;
        else
            stage_prelim_active = 1'b1;

        cfg_accum_next = cfg_accum_q +
                         (cfg_multiplier_q[0] ? cfg_multiplicand_q : 27'd0);
        cfg_end_next = {1'b0, stage_base_q} +
                       {{3{1'b0}}, cfg_accum_next, 3'b000};
    end

    always_comb begin
        if (!stage_configured_q || (stage_width_q == 0) ||
            ($signed(s_req_cache_x) < 0))
            req_clamped_x = 16'd0;
        else if ($unsigned(s_req_cache_x) >= {1'b0, stage_width_q})
            req_clamped_x = stage_width_q - 1'b1;
        else
            req_clamped_x = s_req_cache_x[15:0];

        if (!stage_configured_q || (stage_height_q == 0) ||
            ($signed(s_req_cache_y) < 0))
            req_clamped_y = 16'd0;
        else if ($unsigned(s_req_cache_y) >= {1'b0, stage_height_q})
            req_clamped_y = stage_height_q - 1'b1;
        else
            req_clamped_y = s_req_cache_y[15:0];

        req_partial0_comb =
            mul_part_0_3_nodsp(req_clamped_y, stage_row_words_q);
        req_partial1_comb =
            mul_part_4_7_nodsp(req_clamped_y, stage_row_words_q);
        req_partial2_comb =
            mul_part_8_11_nodsp(req_clamped_y, stage_row_words_q);
        req_word_index_comb =
            mul16x4_nodsp(req_clamped_x, stage_groups_q) +
            s_req_cache_group;

        front_y_sum_comb = front_partial0_q + front_partial1_q +
                           front_partial2_q;
        front_beat_sum_comb = front_y_sum_comb + front_word_index_q;
        front_expected_addr_comb = {1'b0, stage_base_q} +
                                   {{3{1'b0}}, front_beat_index_q, 3'b000};
        front_row_base_comb = {1'b0, stage_base_q} +
                              {{3{1'b0}}, front_y_words_q, 3'b000};

        stage_cache_active = stage_configured_q &&
                             stage_guard_active_q && cache_config_valid &&
                             !coherence_poison_q && !cache_error_i;
        stage_cache_fallback = stage_configured_q &&
                               !stage_cache_active;
        if (cache_error_i)
            stage_cache_reason = CACHE_REASON_RUNTIME_ERROR;
        else if (coherence_poison_q)
            stage_cache_reason = CACHE_REASON_COHERENCE;
        else
            stage_cache_reason = stage_reason_q;
    end

    always_comb begin
        new_abort = abort_req && !abort_seen_q;
        new_flush = flush_req && !flush_seen_q;
        maintenance_pending = abort_pending_q || flush_pending_q;

        s_req_ready = !rst && (cfg_state_q == CFG_IDLE) &&
                      (front_state_q == FRONT_EMPTY) &&
                      (logical_owner_q == LOGICAL_NONE) &&
                      (down_owner_q == DOWN_NONE) && !refill_active_q &&
                      (maint_state_q == MAINT_IDLE) &&
                      (!maintenance_pending || drain_front_q) &&
                      cache_quiescent;
        s_req_fire = s_req_valid && s_req_ready;

        front_cache_drive = (front_state_q == FRONT_DISPATCH) &&
                            front_cache_route_q && !cache_error_i &&
                            cache_config_valid &&
                            (logical_owner_q == LOGICAL_NONE);
        front_bypass_drive = (front_state_q == FRONT_DISPATCH) &&
                             (!front_cache_route_q || cache_error_i ||
                              !cache_config_valid) &&
                             (logical_owner_q == LOGICAL_NONE) &&
                             !refill_active_q &&
                             (down_owner_q == DOWN_NONE);
        cache_tap_valid = front_cache_drive;
        cache_tap_rsp_ready = 1'b0;

        cache_refill_req_ready = front_cache_drive &&
                                 !refill_active_q &&
                                 (down_owner_q == DOWN_NONE);
        refill_last_word =
            (refill_word_index_q == refill_word_count_q - 1'b1);
        cache_refill_word_valid = 1'b0;
        cache_refill_word_data = m_rsp_rdata;
        cache_refill_word_last = refill_last_word;

        m_req_valid = 1'b0;
        m_req_write = 1'b0;
        m_req_addr = 32'd0;
        m_req_wdata = '0;
        m_req_wstrb = '0;
        refill_down_request = 1'b0;
        bypass_down_request = 1'b0;
        if (down_owner_q == DOWN_NONE) begin
            if (refill_active_q) begin
                refill_down_request = 1'b1;
                m_req_valid = 1'b1;
                m_req_addr = refill_addr_q;
            end else if (front_bypass_drive) begin
                bypass_down_request = 1'b1;
                m_req_valid = 1'b1;
                m_req_write = front_req_write_q;
                m_req_addr = front_req_addr_q;
                m_req_wdata = front_req_wdata_q;
                m_req_wstrb = front_req_wstrb_q;
            end
        end
        m_req_fire = m_req_valid && m_req_ready;

        s_rsp_valid = 1'b0;
        s_rsp_error = 1'b0;
        s_rsp_rdata = '0;
        m_rsp_ready = 1'b0;
        if (logical_owner_q == LOGICAL_BYPASS) begin
            s_rsp_valid = (down_owner_q == DOWN_BYPASS) && m_rsp_valid;
            s_rsp_error = m_rsp_error;
            s_rsp_rdata = m_rsp_rdata;
            m_rsp_ready = s_rsp_ready;
        end else if (logical_owner_q == LOGICAL_CACHE) begin
            s_rsp_valid = cache_tap_rsp_valid;
            s_rsp_error = cache_tap_rsp_error || refill_error_seen_q;
            s_rsp_rdata = cache_tap_rsp_data;
            cache_tap_rsp_ready = s_rsp_ready;
        end else if (down_owner_q == DOWN_REFILL) begin
            cache_refill_word_valid = m_rsp_valid;
            m_rsp_ready = cache_refill_word_ready;
        end
        s_rsp_fire = s_rsp_valid && s_rsp_ready;
        m_rsp_fire = m_rsp_valid && m_rsp_ready;

        maintenance_can_launch = maintenance_pending &&
                                 (maint_state_q == MAINT_IDLE) &&
                                 (cfg_state_q == CFG_IDLE) &&
                                 (front_state_q == FRONT_EMPTY) &&
                                 (logical_owner_q == LOGICAL_NONE) &&
                                 (down_owner_q == DOWN_NONE) &&
                                 !refill_active_q && !drain_front_q &&
                                 cache_quiescent;

        quiescent = (cfg_state_q == CFG_IDLE) &&
                    (front_state_q == FRONT_EMPTY) &&
                    (logical_owner_q == LOGICAL_NONE) &&
                    (down_owner_q == DOWN_NONE) && !refill_active_q &&
                    (maint_state_q == MAINT_IDLE) &&
                    !abort_pending_q && !flush_pending_q &&
                    !drain_front_q && !s_req_valid && cache_quiescent;
        busy = !quiescent;

        stage_start_ready = !rst && quiescent &&
                            cache_group_start_ready &&
                            !abort_req && !flush_req;
        cache_group_start_valid = stage_start_valid &&
                                  stage_start_ready;

        cache_error = cache_error_i;
        cache_error_code = cache_error_code_i;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            logical_owner_q <= LOGICAL_NONE;
            down_owner_q <= DOWN_NONE;
            maint_state_q <= MAINT_IDLE;
            cfg_state_q <= CFG_IDLE;
            front_state_q <= FRONT_EMPTY;
            stage_base_q <= 32'd0;
            stage_end_q <= 33'd0;
            stage_width_q <= 16'd0;
            stage_height_q <= 16'd0;
            stage_groups_q <= 4'd0;
            stage_row_words_q <= 16'd0;
            stage_configured_q <= 1'b0;
            stage_guard_active_q <= 1'b0;
            stage_reason_q <= CACHE_REASON_NONE;
            coherence_poison_q <= 1'b0;
            cfg_accum_q <= 27'd0;
            cfg_multiplicand_q <= 27'd0;
            cfg_multiplier_q <= 16'd0;
            cfg_count_q <= 5'd0;
            front_req_write_q <= 1'b0;
            front_req_addr_q <= 32'd0;
            front_req_wdata_q <= '0;
            front_req_wstrb_q <= '0;
            front_cache_x_q <= 17'sd0;
            front_cache_y_q <= 17'sd0;
            front_cache_group_q <= 3'd0;
            front_cache_candidate_q <= 1'b0;
            front_cache_route_q <= 1'b0;
            front_partial0_q <= 27'd0;
            front_partial1_q <= 27'd0;
            front_partial2_q <= 27'd0;
            front_word_index_q <= 20'd0;
            front_y_words_q <= 27'd0;
            front_beat_index_q <= 27'd0;
            front_row_base_addr_q <= 32'd0;
            refill_active_q <= 1'b0;
            refill_row_q <= 16'd0;
            refill_word_count_q <= 16'd0;
            refill_word_index_q <= 16'd0;
            refill_addr_q <= 32'd0;
            refill_error_seen_q <= 1'b0;
            abort_seen_q <= 1'b0;
            abort_pending_q <= 1'b0;
            flush_seen_q <= 1'b0;
            flush_pending_q <= 1'b0;
            drain_front_q <= 1'b0;
            cache_abort_req_q <= 1'b0;
            cache_flush_req_q <= 1'b0;
            cache_start_seen_q <= 1'b0;
            cache_start_ok_q <= 1'b0;
            stage_start_done <= 1'b0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
        end else begin
            stage_start_done <= 1'b0;
            abort_done <= 1'b0;
            flush_done <= 1'b0;
            cache_abort_req_q <= 1'b0;
            cache_flush_req_q <= 1'b0;

            if (!abort_req)
                abort_seen_q <= 1'b0;
            if (!flush_req)
                flush_seen_q <= 1'b0;
            if (new_abort) begin
                abort_seen_q <= 1'b1;
                abort_pending_q <= 1'b1;
            end
            if (new_flush) begin
                flush_seen_q <= 1'b1;
                flush_pending_q <= 1'b1;
            end
            if ((new_abort || new_flush) &&
                (logical_owner_q == LOGICAL_NONE) && s_req_valid &&
                !s_req_fire)
                drain_front_q <= 1'b1;

            if (stage_start_valid && stage_start_ready) begin
                stage_base_q <= stage_base_addr;
                stage_width_q <= stage_width;
                stage_height_q <= stage_height;
                stage_groups_q <= stage_groups;
                stage_row_words_q <= stage_row_words_comb[15:0];
                stage_end_q <= {1'b0, stage_base_addr};
                stage_configured_q <= 1'b0;
                stage_guard_active_q <= 1'b0;
                stage_reason_q <= stage_prelim_reason;
                coherence_poison_q <= 1'b0;
                refill_error_seen_q <= 1'b0;
                cfg_accum_q <= 27'd0;
                cfg_multiplicand_q <= {7'd0, stage_row_words_comb};
                cfg_multiplier_q <= stage_height;
                cfg_count_q <= 5'd0;
                cache_start_seen_q <= 1'b0;
                cache_start_ok_q <= 1'b0;
                if (stage_prelim_active)
                    cfg_state_q <= CFG_MULTIPLY;
                else
                    cfg_state_q <= CFG_FINISH;
            end

            // c1_window_line_cache_c8 acknowledges its group-start one cycle
            // after the shared handshake.  Latch that pulse rather than
            // assuming the seam and cache guards can never diverge.  A future
            // parameter/check mismatch therefore degrades to direct memory
            // instead of leaving a cache-routed request permanently stalled.
            if (cache_group_start_done) begin
                cache_start_seen_q <= 1'b1;
                cache_start_ok_q <= !cache_group_start_error &&
                                    cache_config_valid;
            end

            if (cfg_state_q == CFG_MULTIPLY) begin
                cfg_accum_q <= cfg_accum_next;
                if (cfg_count_q == 15) begin
                    stage_end_q <= cfg_end_next;
                    if (cfg_end_next > 33'h1_0000_0000) begin
                        stage_guard_active_q <= 1'b0;
                        stage_reason_q <= CACHE_REASON_ADDRESS_RANGE;
                    end else begin
                        stage_guard_active_q <= 1'b1;
                        stage_reason_q <= CACHE_REASON_NONE;
                    end
                    cfg_state_q <= CFG_FINISH;
                end else begin
                    cfg_multiplicand_q <= cfg_multiplicand_q << 1;
                    cfg_multiplier_q <= cfg_multiplier_q >> 1;
                    cfg_count_q <= cfg_count_q + 1'b1;
                end
            end

            if (cfg_state_q == CFG_FINISH) begin
                stage_configured_q <= 1'b1;
                if (stage_guard_active_q &&
                    (!(cache_start_seen_q || cache_group_start_done) ||
                     !(cache_group_start_done ?
                           (!cache_group_start_error && cache_config_valid) :
                           cache_start_ok_q) ||
                     !cache_config_valid)) begin
                    stage_guard_active_q <= 1'b0;
                    stage_reason_q <= CACHE_REASON_CONFIG_REJECT;
                end
                stage_start_done <= 1'b1;
                cfg_state_q <= CFG_IDLE;
            end

            if (s_req_fire) begin
                drain_front_q <= 1'b0;
                front_req_write_q <= s_req_write;
                front_req_addr_q <= s_req_addr;
                front_req_wdata_q <= s_req_wdata;
                front_req_wstrb_q <= s_req_wstrb;
                front_cache_x_q <= $signed({1'b0, req_clamped_x});
                front_cache_y_q <= $signed({1'b0, req_clamped_y});
                front_cache_group_q <= s_req_cache_group;
                front_cache_candidate_q <=
                    s_req_cacheable && !s_req_write &&
                    (s_req_wstrb == '0) && stage_cache_active &&
                    (s_req_cache_group < stage_groups_q) &&
                    (s_req_addr[2:0] == 3'b000);
                front_partial0_q <= req_partial0_comb;
                front_partial1_q <= req_partial1_comb;
                front_partial2_q <= req_partial2_comb;
                front_word_index_q <= req_word_index_comb;
                front_state_q <= FRONT_SUM;
            end

            if (front_state_q == FRONT_SUM) begin
                front_y_words_q <= front_y_sum_comb;
                front_beat_index_q <= front_beat_sum_comb;
                front_state_q <= FRONT_CHECK;
            end

            if (front_state_q == FRONT_CHECK) begin
                front_cache_route_q <= front_cache_candidate_q &&
                    !front_expected_addr_comb[32] &&
                    (front_req_addr_q == front_expected_addr_comb[31:0]);
                front_row_base_addr_q <= front_row_base_comb[31:0];
                front_state_q <= FRONT_DISPATCH;
            end

            // Once a not-yet-owned cache route becomes unusable, freeze this
            // registered request onto the bypass path.  An already accepted
            // cache hit has LOGICAL_CACHE ownership and is deliberately left
            // untouched so it cannot generate a duplicate direct request.
            if ((front_state_q == FRONT_DISPATCH) && front_cache_route_q &&
                (cache_error_i || !cache_config_valid) &&
                (logical_owner_q == LOGICAL_NONE))
                front_cache_route_q <= 1'b0;

            if (cache_refill_req_valid && cache_refill_req_ready) begin
                refill_active_q <= 1'b1;
                refill_row_q <= cache_refill_req_row;
                refill_word_count_q <= cache_refill_req_word_count;
                refill_word_index_q <= 16'd0;
                refill_addr_q <= front_row_base_addr_q;
                refill_error_seen_q <= 1'b0;
            end

            if (front_cache_drive && cache_tap_ready) begin
                logical_owner_q <= LOGICAL_CACHE;
                front_state_q <= FRONT_EMPTY;
            end

            if (m_req_fire && bypass_down_request) begin
                logical_owner_q <= LOGICAL_BYPASS;
                down_owner_q <= DOWN_BYPASS;
                front_state_q <= FRONT_EMPTY;
                if (front_req_write_q && stage_cache_active &&
                    ({1'b0, front_req_addr_q} >= {1'b0, stage_base_q}) &&
                    ({1'b0, front_req_addr_q} < stage_end_q))
                    coherence_poison_q <= 1'b1;
            end

            if (m_req_fire && refill_down_request)
                down_owner_q <= DOWN_REFILL;

            if (m_rsp_fire) begin
                if (down_owner_q == DOWN_REFILL) begin
                    down_owner_q <= DOWN_NONE;
                    if (m_rsp_error)
                        refill_error_seen_q <= 1'b1;
                    if (refill_last_word) begin
                        refill_active_q <= 1'b0;
                        refill_word_index_q <= 16'd0;
                    end else begin
                        refill_word_index_q <= refill_word_index_q + 1'b1;
                        refill_addr_q <= refill_addr_q + 32'd8;
                    end
                end else if (down_owner_q == DOWN_BYPASS) begin
                    down_owner_q <= DOWN_NONE;
                end
            end

            if (s_rsp_fire) begin
                if ((logical_owner_q == LOGICAL_CACHE) &&
                    (cache_tap_rsp_error || refill_error_seen_q))
                    coherence_poison_q <= 1'b1;
                logical_owner_q <= LOGICAL_NONE;
                refill_error_seen_q <= 1'b0;
            end

            if (maintenance_can_launch) begin
                if (abort_pending_q) begin
                    cache_abort_req_q <= 1'b1;
                    maint_state_q <= MAINT_WAIT_ABORT;
                end else if (flush_pending_q) begin
                    cache_flush_req_q <= 1'b1;
                    maint_state_q <= MAINT_WAIT_FLUSH;
                end
            end

            if ((maint_state_q == MAINT_WAIT_ABORT) && cache_abort_done) begin
                maint_state_q <= MAINT_IDLE;
                abort_pending_q <= 1'b0;
                abort_done <= 1'b1;
                stage_configured_q <= 1'b0;
                stage_guard_active_q <= 1'b0;
                stage_reason_q <= CACHE_REASON_NONE;
                coherence_poison_q <= 1'b0;
                refill_error_seen_q <= 1'b0;
                if (flush_pending_q || new_flush) begin
                    flush_pending_q <= 1'b0;
                    flush_done <= 1'b1;
                end
            end

            if ((maint_state_q == MAINT_WAIT_FLUSH) && cache_flush_done) begin
                maint_state_q <= MAINT_IDLE;
                flush_pending_q <= 1'b0;
                flush_done <= 1'b1;
                coherence_poison_q <= 1'b0;
                refill_error_seen_q <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    logic s_req_stalled_q;
    logic [142:0] s_req_payload_q;
    logic m_req_stalled_q;
    logic [104:0] m_req_payload_q;
    logic s_rsp_stalled_q;
    logic [DATA_W:0] s_rsp_payload_q;
    logic logical_outstanding_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            s_req_stalled_q <= 1'b0;
            m_req_stalled_q <= 1'b0;
            s_rsp_stalled_q <= 1'b0;
            logical_outstanding_q <= 1'b0;
        end else begin
            if (s_req_stalled_q &&
                (!s_req_valid ||
                 ({s_req_write, s_req_addr, s_req_wdata, s_req_wstrb,
                   s_req_cacheable, s_req_cache_x, s_req_cache_y,
                   s_req_cache_group} != s_req_payload_q)))
                $fatal(1, "upstream changed/withdrew a stalled tensor request");
            s_req_stalled_q <= s_req_valid && !s_req_ready;
            s_req_payload_q <= {s_req_write, s_req_addr, s_req_wdata,
                                s_req_wstrb, s_req_cacheable,
                                s_req_cache_x, s_req_cache_y,
                                s_req_cache_group};

            if (m_req_stalled_q &&
                (!m_req_valid ||
                 ({m_req_write, m_req_addr, m_req_wdata, m_req_wstrb} !=
                  m_req_payload_q)))
                $fatal(1, "window cache seam changed/withdrew downstream request");
            m_req_stalled_q <= m_req_valid && !m_req_ready;
            m_req_payload_q <= {m_req_write, m_req_addr,
                                m_req_wdata, m_req_wstrb};

            if (s_rsp_stalled_q &&
                (!s_rsp_valid ||
                 ({s_rsp_error, s_rsp_rdata} != s_rsp_payload_q)))
                $fatal(1, "window cache seam changed/withdrew upstream response");
            s_rsp_stalled_q <= s_rsp_valid && !s_rsp_ready;
            s_rsp_payload_q <= {s_rsp_error, s_rsp_rdata};

            if (s_req_fire) begin
                if (logical_outstanding_q)
                    $fatal(1, "accepted a second logical request");
                logical_outstanding_q <= 1'b1;
            end
            if (s_rsp_fire) begin
                if (!logical_outstanding_q)
                    $fatal(1, "retired a response without an accepted request");
                logical_outstanding_q <= 1'b0;
            end

            if ((logical_owner_q == LOGICAL_CACHE) &&
                (down_owner_q == DOWN_BYPASS))
                $fatal(1, "cache logical owner paired with bypass downstream owner");
            if ((down_owner_q == DOWN_REFILL) && !refill_active_q)
                $fatal(1, "refill downstream owner without active refill");
            if (refill_active_q && (logical_owner_q != LOGICAL_NONE))
                $fatal(1, "active refill overlapped a logical response owner");
            if (refill_active_q &&
                ((refill_word_count_q == 0) ||
                 (refill_word_index_q >= refill_word_count_q) ||
                 (refill_addr_q[2:0] != 3'b000)))
                $fatal(1, "active refill carried invalid count/index/address");
            if (cache_refill_word_valid &&
                (down_owner_q != DOWN_REFILL))
                $fatal(1, "refill word presented without refill downstream owner");
            if ((down_owner_q == DOWN_BYPASS) &&
                (logical_owner_q != LOGICAL_BYPASS))
                $fatal(1, "bypass downstream owner without bypass logical owner");
            if (s_rsp_valid && (logical_owner_q == LOGICAL_NONE))
                $fatal(1, "upstream response presented without logical owner");
            if (m_rsp_valid && (down_owner_q == DOWN_NONE))
                $fatal(1, "downstream response presented without downstream owner");
            if (stage_cache_active && !cache_config_valid)
                $fatal(1, "active cache stage without accepted cache configuration");
            if (refill_down_request && bypass_down_request)
                $fatal(1, "refill and bypass requested downstream together");
            if (cache_refill_req_valid && cache_refill_req_ready &&
                ((cache_refill_req_word_count != stage_row_words_q) ||
                 (cache_refill_req_row != front_cache_y_q[15:0])))
                $fatal(1, "line cache emitted invalid refill geometry");
        end
    end
`endif

    wire unused_cache_status = cache_busy ^
                               (^cache_group_start_error_code) ^
                               (^refill_row_q);

endmodule
