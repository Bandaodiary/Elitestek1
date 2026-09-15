`timescale 1ns/1ps

// Board-independent two-line RGB888 sampler for c1_r1_resize_system.
//
// Source pixels arrive once, in strict raster order.  Resize sample requests
// must have nondecreasing (y0,y1), and the supported bilinear pair is y1=y0
// or y1=y0+1.  Those restrictions are sufficient for the existing
// r1_resize_request_q16 generator.  A request outside this contract is
// reported and is never answered with fabricated data.
//
// Two source rows are retained.  When a downsample request skips rows, source
// rows below the waiting y0 are validated and discarded.  Repeated upsample
// requests reuse the retained rows.  Source ready is removed before either
// retained row could be overwritten while it may still be needed.
//
// C23 independent derivative: each row is banked by x parity, not copied.
// Only adjacent/clamped horizontal pairs are legal; invalid pairs use the
// existing ERR_REQUEST_PAIR path. The connected coordinate generator always
// meets this restriction, including negative phases/steps and edge clamping.
// Four half-depth banks consume 2*ceil(MAX_WIDTH/2)*2*24 logical bits.
// Original R1 source is retained for arbitrary horizontal sampling.
//
// An accepted request launches all four synchronous reads.  On the following
// clock their outputs are copied, with the saved row-bank selectors, into an
// elastic response register.  At most one RAM read is pending, and a pending
// read is never allowed to overwrite an unconsumed response.  The connected
// c1_r1_resize_system is itself one-outstanding, so this conservative cache
// protocol does not reduce that system's supported request concurrency.
// The retain/discard action for an incoming row is registered one clock before
// its x=0 beat may handshake.  That row-plan boundary prevents a presented
// resize request from feeding source-coordinate state in the same cycle.
module c1_r2_resize_line_sampler #(
    parameter integer MAX_WIDTH = 2048
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start,
    output logic                    start_ready,
    output logic                    start_error,
    input  logic [15:0]             cfg_win,
    input  logic [15:0]             cfg_hin,
    output logic                    busy,
    output logic                    done,
    output logic                    error,
    output logic [3:0]              error_code,

    input  logic                    src_valid,
    output logic                    src_ready,
    input  logic [15:0]             src_x,
    input  logic [15:0]             src_y,
    input  logic                    src_sof,
    input  logic                    src_eol,
    input  logic                    src_eof,
    input  logic [23:0]             src_rgb888,

    input  logic                    sample_req_valid,
    output logic                    sample_req_ready,
    input  logic                    sample_req_last,
    input  logic [15:0]             sample_req_out_x,
    input  logic [15:0]             sample_req_out_y,
    input  logic [15:0]             sample_req_x0,
    input  logic [15:0]             sample_req_x1,
    input  logic [15:0]             sample_req_y0,
    input  logic [15:0]             sample_req_y1,
    input  logic [12:0]             sample_req_wx0,
    input  logic [12:0]             sample_req_wx1,
    input  logic [12:0]             sample_req_wy0,
    input  logic [12:0]             sample_req_wy1,

    output logic                    sample_rsp_valid,
    input  logic                    sample_rsp_ready,
    output logic [23:0]             sample_rsp_rgb_y0x0,
    output logic [23:0]             sample_rsp_rgb_y0x1,
    output logic [23:0]             sample_rsp_rgb_y1x0,
    output logic [23:0]             sample_rsp_rgb_y1x1
);

    localparam logic [3:0] ERR_NONE             = 4'd0;
    localparam logic [3:0] ERR_BAD_CONFIG       = 4'd1;
    localparam logic [3:0] ERR_SOURCE_RASTER    = 4'd2;
    localparam logic [3:0] ERR_REQUEST_BOUNDS   = 4'd3;
    localparam logic [3:0] ERR_REQUEST_PAIR     = 4'd4;
    localparam logic [3:0] ERR_REQUEST_ORDER    = 4'd5;
    localparam logic [3:0] ERR_SOURCE_PASSED    = 4'd6;
    localparam integer RAM_ADDR_WIDTH =
        (MAX_WIDTH <= 1) ? 1 : $clog2(MAX_WIDTH);

    logic                    ram_rd_en;
    logic [RAM_ADDR_WIDTH-1:0] ram_x0_rd_addr;
    logic [RAM_ADDR_WIDTH-1:0] ram_x1_rd_addr;
    logic                    ram_line0_wr_en;
    logic                    ram_line1_wr_en;
    logic [RAM_ADDR_WIDTH-1:0] ram_wr_addr;
    logic [23:0]             ram_wr_data;
    logic [23:0]             ram_line0_x0_rd_data;
    logic [23:0]             ram_line0_x1_rd_data;
    logic [23:0]             ram_line1_x0_rd_data;
    logic [23:0]             ram_line1_x1_rd_data;

    logic job_active;
    logic fault;
    logic [15:0] win_q;
    logic [15:0] hin_q;

    logic line0_valid;
    logic line1_valid;
    logic [15:0] line0_y;
    logic [15:0] line1_y;

    logic [15:0] expected_src_x;
    logic [15:0] expected_src_y;
    logic row_store_q;
    logic row_bank_q;
    logic source_done;

    logic last_pair_valid;
    logic [15:0] last_y0;
    logic [15:0] last_y1;
    logic last_request_seen;
    logic last_response_done;
    logic response_last_q;
    logic read_pending;
    logic read_y0_bank_q;
    logic read_y1_bank_q;

    logic req_y0_line0;
    logic req_y0_line1;
    logic req_y1_line0;
    logic req_y1_line1;
    logic req_lines_present;
    logic req_bounds_bad;
    logic req_pair_bad;
    logic req_order_bad;
    logic req_source_passed;
    logic req_bad_now;

    logic retention_valid;
    logic [15:0] retention_floor;
    logic line0_available;
    logic line1_available;
    logic row_start_store;
    logic row_start_discard;
    logic row_start_bank;
    logic row_start_ready;
    logic row_plan_valid;
    logic row_plan_store;
    logic row_plan_bank;
    logic write_pixel;
    logic write_bank;

    logic expected_sof;
    logic expected_eol;
    logic expected_eof;
    logic source_protocol_bad;
    logic source_handshake;
    logic request_handshake;
    logic response_handshake;
    logic source_eof_handshake;
    logic response_last_handshake;
    logic finish_job;

    c1_r2_resize_pair_ram #(.MAX_WIDTH(MAX_WIDTH)) u_pair_ram (
        .clk(clk),.rst(rst),.rd_en(ram_rd_en),
        .rd_x0(sample_req_x0),.rd_x1(sample_req_x1),
        .row0_x0(ram_line0_x0_rd_data),.row0_x1(ram_line0_x1_rd_data),
        .row1_x0(ram_line1_x0_rd_data),.row1_x1(ram_line1_x1_rd_data),
        .wr_row0(ram_line0_wr_en),.wr_row1(ram_line1_wr_en),
        .wr_x(expected_src_x),.wr_rgb(ram_wr_data)
    );

    always_comb begin
        start_ready = !rst && !job_active && !sample_rsp_valid &&
                      !read_pending && !row_plan_valid;
        busy = job_active;

        req_y0_line0 = line0_valid && (line0_y == sample_req_y0);
        req_y0_line1 = line1_valid && (line1_y == sample_req_y0);
        req_y1_line0 = line0_valid && (line0_y == sample_req_y1);
        req_y1_line1 = line1_valid && (line1_y == sample_req_y1);
        req_lines_present = (req_y0_line0 || req_y0_line1) &&
                            (req_y1_line0 || req_y1_line1);

        req_bounds_bad = (sample_req_x0 >= win_q) ||
                         (sample_req_x1 >= win_q) ||
                         (sample_req_y0 >= hin_q) ||
                         (sample_req_y1 >= hin_q);
        req_pair_bad = (sample_req_y1 < sample_req_y0) ||
                       (sample_req_y1 > sample_req_y0 + 16'd1) ||
                       (sample_req_x1 < sample_req_x0) ||
                       ({1'b0,sample_req_x1} > {1'b0,sample_req_x0} + 17'd1);
        req_order_bad = last_pair_valid &&
                        ((sample_req_y0 < last_y0) ||
                         (sample_req_y1 < last_y1));
        req_source_passed =
            ((!req_y0_line0 && !req_y0_line1) &&
             (source_done || (expected_src_y > sample_req_y0))) ||
            ((!req_y1_line0 && !req_y1_line1) &&
             (source_done || (expected_src_y > sample_req_y1)));
        req_bad_now = sample_req_valid &&
                      (req_bounds_bad || req_pair_bad || req_order_bad ||
                       req_source_passed);

        sample_req_ready = job_active && !fault && sample_req_valid &&
                           !req_bad_now && req_lines_present &&
                           !read_pending &&
                           (!sample_rsp_valid || sample_rsp_ready);

        // A presented request is the earliest future consumer and therefore
        // defines which older completed rows are evictable.  Between requests
        // the most recently accepted y0 remains the conservative floor.
        // The presented request is held stable until handshake.  Use its y0
        // directly for retention planning even while the independent error
        // checker is evaluating it.  A malformed request is terminal in the
        // sequential priority chain and src_ready is already gated low, so
        // folding req_bad_now into this plan would only create a long cascade
        // of unrelated bounds/order comparisons.
        if (sample_req_valid) begin
            retention_valid = 1'b1;
            retention_floor = sample_req_y0;
        end else begin
            retention_valid = last_pair_valid;
            retention_floor = last_y0;
        end
        line0_available = !line0_valid ||
                          (retention_valid && (line0_y < retention_floor));
        line1_available = !line1_valid ||
                          (retention_valid && (line1_y < retention_floor));

        row_start_store = 1'b0;
        row_start_discard = 1'b0;
        row_start_bank = 1'b0;
        row_start_ready = 1'b0;
        if (last_request_seen) begin
            // No later request can use source storage; drain the raster.
            row_start_discard = 1'b1;
            row_start_ready = 1'b1;
        end else if (sample_req_valid &&
                     (expected_src_y < sample_req_y0)) begin
            // Downsample skip: validate but do not retain obsolete rows.
            row_start_discard = 1'b1;
            row_start_ready = 1'b1;
        end else if (line0_available) begin
            row_start_store = 1'b1;
            row_start_bank = 1'b0;
            row_start_ready = 1'b1;
        end else if (line1_available) begin
            row_start_store = 1'b1;
            row_start_bank = 1'b1;
            row_start_ready = 1'b1;
        end

        if (!job_active || fault || source_done || req_bad_now)
            src_ready = 1'b0;
        else if (expected_src_x == 16'd0)
            src_ready = row_plan_valid;
        else
            src_ready = 1'b1;

        write_pixel = (expected_src_x == 16'd0) ?
                      row_plan_store : row_store_q;
        write_bank = (expected_src_x == 16'd0) ?
                     row_plan_bank : row_bank_q;

        expected_sof = (expected_src_x == 16'd0) &&
                       (expected_src_y == 16'd0);
        expected_eol = (expected_src_x == win_q - 16'd1);
        expected_eof = expected_eol &&
                       (expected_src_y == hin_q - 16'd1);
        source_protocol_bad = (src_x != expected_src_x) ||
                              (src_y != expected_src_y) ||
                              (src_sof != expected_sof) ||
                              (src_eol != expected_eol) ||
                              (src_eof != expected_eof);

        source_handshake = src_valid && src_ready;
        request_handshake = sample_req_valid && sample_req_ready;
        response_handshake = sample_rsp_valid && sample_rsp_ready;
        source_eof_handshake = source_handshake && !source_protocol_bad &&
                               expected_eof;
        response_last_handshake = response_handshake && response_last_q;
        finish_job = job_active &&
                     (source_done || source_eof_handshake) &&
                     (last_response_done || response_last_handshake);

        // All four RAMs are read together.  Saved row selectors choose the
        // two requested rows after the synchronous read latency.
        ram_rd_en = request_handshake;
        ram_x0_rd_addr = sample_req_x0[RAM_ADDR_WIDTH-1:0];
        ram_x1_rd_addr = sample_req_x1[RAM_ADDR_WIDTH-1:0];

        // Malformed source beats must not alter either RAM even though RAM
        // write logic resides outside this module's sequential fault branch.
        ram_line0_wr_en = source_handshake && !source_protocol_bad &&
                          write_pixel && !write_bank;
        ram_line1_wr_en = source_handshake && !source_protocol_bad &&
                          write_pixel && write_bank;
        ram_wr_addr = expected_src_x[RAM_ADDR_WIDTH-1:0];
        ram_wr_data = src_rgb888;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            job_active <= 1'b0;
            fault <= 1'b0;
            start_error <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
            win_q <= 16'd0;
            hin_q <= 16'd0;
            line0_valid <= 1'b0;
            line1_valid <= 1'b0;
            line0_y <= 16'd0;
            line1_y <= 16'd0;
            expected_src_x <= 16'd0;
            expected_src_y <= 16'd0;
            row_store_q <= 1'b0;
            row_bank_q <= 1'b0;
            row_plan_valid <= 1'b0;
            row_plan_store <= 1'b0;
            row_plan_bank <= 1'b0;
            source_done <= 1'b0;
            last_pair_valid <= 1'b0;
            last_y0 <= 16'd0;
            last_y1 <= 16'd0;
            last_request_seen <= 1'b0;
            last_response_done <= 1'b0;
            response_last_q <= 1'b0;
            read_pending <= 1'b0;
            read_y0_bank_q <= 1'b0;
            read_y1_bank_q <= 1'b0;
            sample_rsp_valid <= 1'b0;
            sample_rsp_rgb_y0x0 <= 24'd0;
            sample_rsp_rgb_y0x1 <= 24'd0;
            sample_rsp_rgb_y1x0 <= 24'd0;
            sample_rsp_rgb_y1x1 <= 24'd0;
        end else begin
            start_error <= 1'b0;
            done <= 1'b0;

            if (start && start_ready) begin
                fault <= 1'b0;
                error <= 1'b0;
                error_code <= ERR_NONE;
                line0_valid <= 1'b0;
                line1_valid <= 1'b0;
                expected_src_x <= 16'd0;
                expected_src_y <= 16'd0;
                row_store_q <= 1'b0;
                row_bank_q <= 1'b0;
                row_plan_valid <= 1'b0;
                row_plan_store <= 1'b0;
                row_plan_bank <= 1'b0;
                source_done <= 1'b0;
                last_pair_valid <= 1'b0;
                last_y0 <= 16'd0;
                last_y1 <= 16'd0;
                last_request_seen <= 1'b0;
                last_response_done <= 1'b0;
                response_last_q <= 1'b0;
                read_pending <= 1'b0;
                read_y0_bank_q <= 1'b0;
                read_y1_bank_q <= 1'b0;
                sample_rsp_valid <= 1'b0;
                if ((cfg_win == 16'd0) || (cfg_hin == 16'd0) ||
                    (cfg_win > MAX_WIDTH)) begin
                    start_error <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_BAD_CONFIG;
                    job_active <= 1'b0;
                    win_q <= 16'd0;
                    hin_q <= 16'd0;
                end else begin
                    job_active <= 1'b1;
                    win_q <= cfg_win;
                    hin_q <= cfg_hin;
                end
            end else if (job_active && !fault) begin
                // A malformed presented request is terminal for this frame.
                // Holding both ready signals low prevents a fake response or
                // further source loss; reset is required to recover.
                if (sample_req_valid && req_bounds_bad) begin
                    fault <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_REQUEST_BOUNDS;
                end else if (sample_req_valid && req_pair_bad) begin
                    fault <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_REQUEST_PAIR;
                end else if (sample_req_valid && req_order_bad) begin
                    fault <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_REQUEST_ORDER;
                end else if (sample_req_valid && req_source_passed) begin
                    fault <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_SOURCE_PASSED;
                end else if (source_handshake && source_protocol_bad) begin
                    fault <= 1'b1;
                    error <= 1'b1;
                    error_code <= ERR_SOURCE_RASTER;
                end else begin
                    // Resolve the next-row action into stable registers before
                    // allowing its x=0 source beat.  row_start_* may depend on
                    // the held resize request; accepted source state does not.
                    if (!source_done && !row_plan_valid &&
                        (expected_src_x == 16'd0) && row_start_ready) begin
                        row_plan_valid <= 1'b1;
                        row_plan_store <= row_start_store;
                        row_plan_bank <= row_start_bank;
                    end

                    if (response_handshake)
                        sample_rsp_valid <= 1'b0;

                    // RAM outputs correspond to the request accepted one
                    // clock earlier.  Copy them into the elastic response
                    // slot only after that synchronous read has completed.
                    if (read_pending) begin
                        read_pending <= 1'b0;
                        sample_rsp_valid <= 1'b1;
                        if (!read_y0_bank_q) begin
                            sample_rsp_rgb_y0x0 <= ram_line0_x0_rd_data;
                            sample_rsp_rgb_y0x1 <= ram_line0_x1_rd_data;
                        end else begin
                            sample_rsp_rgb_y0x0 <= ram_line1_x0_rd_data;
                            sample_rsp_rgb_y0x1 <= ram_line1_x1_rd_data;
                        end
                        if (!read_y1_bank_q) begin
                            sample_rsp_rgb_y1x0 <= ram_line0_x0_rd_data;
                            sample_rsp_rgb_y1x1 <= ram_line0_x1_rd_data;
                        end else begin
                            sample_rsp_rgb_y1x0 <= ram_line1_x0_rd_data;
                            sample_rsp_rgb_y1x1 <= ram_line1_x1_rd_data;
                        end
                    end

                    if (request_handshake) begin
                        read_pending <= 1'b1;
                        response_last_q <= sample_req_last;
                        read_y0_bank_q <= req_y0_line1;
                        read_y1_bank_q <= req_y1_line1;
                        last_pair_valid <= 1'b1;
                        last_y0 <= sample_req_y0;
                        last_y1 <= sample_req_y1;
                        if (sample_req_last)
                            last_request_seen <= 1'b1;

                    end

                    if (response_last_handshake)
                        last_response_done <= 1'b1;

                    if (source_handshake) begin
                        if (expected_src_x == 16'd0) begin
                            row_plan_valid <= 1'b0;
                            row_store_q <= row_plan_store;
                            row_bank_q <= row_plan_bank;
                            if (row_plan_store) begin
                                if (!row_plan_bank) begin
                                    line0_valid <= 1'b0;
                                    line0_y <= expected_src_y;
                                end else begin
                                    line1_valid <= 1'b0;
                                    line1_y <= expected_src_y;
                                end
                            end
                        end

                        if (expected_eol) begin
                            if (write_pixel) begin
                                if (!write_bank)
                                    line0_valid <= 1'b1;
                                else
                                    line1_valid <= 1'b1;
                            end
                            row_store_q <= 1'b0;
                            if (expected_eof) begin
                                source_done <= 1'b1;
                            end else begin
                                expected_src_x <= 16'd0;
                                expected_src_y <= expected_src_y + 16'd1;
                            end
                        end else begin
                            expected_src_x <= expected_src_x + 16'd1;
                        end
                    end

                    if (finish_job) begin
                        job_active <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Interface fields not consumed by the cache are intentionally present so
    // this module can connect directly to c1_r1_resize_system.
    logic [57:0] sim_unused_request_metadata;
    always_comb begin
        sim_unused_request_metadata = {
            sample_req_out_x, sample_req_out_y,
            sample_req_wx0[6:0], sample_req_wx1[6:0],
            sample_req_wy0[5:0], sample_req_wy1[5:0]
        };
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (sample_rsp_valid && !sample_rsp_ready && request_handshake)
                $fatal(1, "line sampler overwrote a stalled response");
            if (read_pending && sample_rsp_valid && !sample_rsp_ready)
                $fatal(1, "line sampler has a RAM result behind stalled response");
            if (line0_valid && line1_valid && (line0_y == line1_y))
                $fatal(1, "line sampler retained duplicate row tags");
        end
    end
`endif

endmodule
