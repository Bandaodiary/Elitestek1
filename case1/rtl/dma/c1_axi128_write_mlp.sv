`timescale 1ns/1ps

// Board-independent burst-level AXI4-128 write MLP seam.
//
// This block is deliberately separate from the legacy logical-write packer
// and from the default portable-SoC.  Software (or an upstream descriptor
// reader) presents a descriptor, followed by a sequential stream of complete
// 128-bit AXI beats.  A descriptor is accepted into a small ring, its payload
// is captured in the corresponding slot, and AW descriptors may be issued
// ahead of the strictly ordered W/B head.  No AXI IDs are required: W and B
// are retired in descriptor order while AW can have up to MAX_OUTSTANDING
// requests in flight.
//
// The payload framing is intentionally checked rather than silently trusted:
// payload_last must coincide with the declared beat count, and
// payload_flush aborts the current descriptor.  A command-invalid descriptor
// is converted to an ordered local error response and does not issue an
// illegal AXI transaction.  In the opt-in early-AW mode, a valid command with
// a malformed payload frame instead emits a legal declared-length burst with
// deterministic zero-fill for missing beats.  This makes the seam useful in
// boardless xsim stress tests before a vendor DMA/IP choice is made.
module c1_axi128_write_mlp #(
    parameter integer MAX_OUTSTANDING = 4,
    parameter integer MAX_BEATS = 16,
    parameter integer RSP_FIFO_DEPTH = MAX_OUTSTANDING,
    parameter integer TAG_WIDTH = 16,
    // Optional throughput mode.  When set, a command-valid descriptor may
    // issue AW as soon as it enters the ring; W still waits for the complete
    // payload frame and remains strictly ordered at the head.  The default
    // keeps the conservative payload-complete-before-AW behavior used by the
    // original boardless seam.
    parameter bit ISSUE_AW_BEFORE_PAYLOAD = 1'b0,
    // Optional response-FIFO fall-through.  When the descriptor response
    // FIFO is full, allow a B (or local-error retirement) to be accepted in
    // the same cycle that the oldest public response is consumed.  The
    // default keeps the conservative registered-space contract and therefore
    // preserves the historical BREADY timing path.
    parameter bit ALLOW_RSP_POP_REFILL = 1'b0,
    // Independently advance the ordered W cursor after WLAST, rather than
    // waiting for the same descriptor's B. Payload slots remain owned until
    // B retirement; local poison is skipped exactly once by the W cursor.
    parameter bit PIPELINE_WRITE_DATA = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    // Descriptor command stream.  cmd_beats is in the range 1..MAX_BEATS.
    // Invalid values are accepted as poisoned descriptors so that the input
    // stream cannot wedge; they consume a clamped payload frame and return
    // rsp_error.
    input  logic                         cmd_valid,
    output logic                         cmd_ready,
    input  logic [31:0]                  cmd_addr,
    input  logic [8:0]                   cmd_beats,

    // Sequential payload stream, in descriptor acceptance order.
    input  logic                         payload_valid,
    output logic                         payload_ready,
    input  logic [127:0]                 payload_data,
    input  logic [15:0]                  payload_strb,
    input  logic                         payload_last,
    input  logic                         payload_flush,

    // One descriptor-level ordered response per accepted descriptor.
    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic                         rsp_error,
    output logic [31:0]                  rsp_addr,
    output logic [8:0]                   rsp_beats,
    output logic [TAG_WIDTH-1:0]         rsp_tag,

    // AXI4 write channels (single ID-less stream).
    output logic [31:0]                  m_axi_awaddr,
    output logic [7:0]                   m_axi_awlen,
    output logic [2:0]                   m_axi_awsize,
    output logic [1:0]                   m_axi_awburst,
    output logic                         m_axi_awvalid,
    input  logic                         m_axi_awready,

    output logic [127:0]                 m_axi_wdata,
    output logic [15:0]                  m_axi_wstrb,
    output logic                         m_axi_wlast,
    output logic                         m_axi_wvalid,
    input  logic                         m_axi_wready,

    input  logic [1:0]                   m_axi_bresp,
    input  logic                         m_axi_bvalid,
    output logic                         m_axi_bready,

    // Sticky protocol diagnostics.  They are intentionally separate so a
    // boardless test can distinguish stream framing from AXI response faults.
    output logic                         protocol_error,
    output logic                         early_payload_last_error,
    output logic                         late_payload_last_error,
    output logic                         payload_flush_error,
    output logic                         orphan_payload_error,
    output logic                         early_b_error,
    output logic                         orphan_b_error,

    // Performance/occupancy counters.
    output logic                         perf_busy,
    output logic [63:0]                  perf_cmd_accept_count,
    output logic [63:0]                  perf_payload_beat_count,
    output logic [63:0]                  perf_axi_burst_count,
    output logic [63:0]                  perf_axi_beat_count,
    output logic [63:0]                  perf_aw_issue_count,
    output logic [63:0]                  perf_rsp_count,
    output logic [63:0]                  perf_error_count,
    output logic [63:0]                  perf_aw_stall_count,
    output logic [63:0]                  perf_w_stall_count,
    output logic [63:0]                  perf_b_stall_count,
    output logic [7:0]                   perf_cmd_occupancy,
    output logic [7:0]                   perf_max_cmd_occupancy,
    output logic [7:0]                   perf_outstanding,
    output logic [7:0]                   perf_max_outstanding
);

    localparam integer PTR_W = (MAX_OUTSTANDING <= 1) ? 1 :
                               $clog2(MAX_OUTSTANDING);
    localparam integer CNT_W = (MAX_OUTSTANDING <= 1) ? 1 :
                               $clog2(MAX_OUTSTANDING + 1);
    localparam integer BEAT_PTR_W = (MAX_BEATS <= 1) ? 1 :
                                    $clog2(MAX_BEATS);
    localparam integer BEAT_CNT_W = (MAX_BEATS <= 1) ? 1 :
                                    $clog2(MAX_BEATS + 1);
    localparam integer RSP_PTR_W = (RSP_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(RSP_FIFO_DEPTH);
    localparam integer RSP_CNT_W = (RSP_FIFO_DEPTH <= 1) ? 1 :
                                   $clog2(RSP_FIFO_DEPTH + 1);

    initial begin
        if (MAX_OUTSTANDING < 2 || MAX_OUTSTANDING > 255)
            $fatal(1, "MAX_OUTSTANDING must be in the range 2..255");
        if (MAX_BEATS < 1 || MAX_BEATS > 256)
            $fatal(1, "MAX_BEATS must be in the range 1..256");
        // A response FIFO may intentionally be shallower than the descriptor
        // MLP depth; BREADY backpressure then provides the required bound.
        if (RSP_FIFO_DEPTH < 2 || RSP_FIFO_DEPTH > 255)
            $fatal(1, "RSP_FIFO_DEPTH must be in the range 2..255");
        if (TAG_WIDTH < 1)
            $fatal(1, "TAG_WIDTH must be positive");
    end

    // ------------------------------------------------------------------
    // Descriptor and payload storage.
    // ------------------------------------------------------------------
    logic [31:0] desc_addr_mem [0:MAX_OUTSTANDING-1];
    logic [8:0]  desc_beats_mem [0:MAX_OUTSTANDING-1];
    logic [TAG_WIDTH-1:0] desc_tag_mem [0:MAX_OUTSTANDING-1];
    // Command-time poison is kept separate from payload framing errors.  In
    // early-AW mode a valid command may acquire an AW before framing is
    // known; conflating the two would suppress W and deadlock that burst.
    logic desc_cmd_error_mem [0:MAX_OUTSTANDING-1];
    logic desc_local_error_mem [0:MAX_OUTSTANDING-1];
    logic desc_payload_done_mem [0:MAX_OUTSTANDING-1];
    logic desc_aw_issued_mem [0:MAX_OUTSTANDING-1];
    logic desc_w_done_mem [0:MAX_OUTSTANDING-1];

    // This is a deliberately bounded boardless seam.  With the default
    // MAX_OUTSTANDING=4/MAX_BEATS=16 it stores 64 AXI beats (about 1.1 KiB
    // of payload/strobes plus metadata), small enough for proxy synthesis
    // while exposing real MLP.
    logic [127:0] payload_mem [0:MAX_OUTSTANDING-1][0:MAX_BEATS-1];
    logic [15:0]  payload_strb_mem [0:MAX_OUTSTANDING-1][0:MAX_BEATS-1];
    // A short/flush frame leaves declared beats uncaptured.  Valid bits make
    // those beats deterministic zero-fill in early-AW mode without clearing
    // the whole payload RAM on every descriptor reuse.
    logic [MAX_BEATS-1:0] payload_valid_mem [0:MAX_OUTSTANDING-1];

    logic [PTR_W-1:0] head_q, tail_q, fill_ptr_q, issue_ptr_q;
    logic [CNT_W-1:0] desc_count_q, fill_count_q, issued_count_q;
    logic [CNT_W-1:0] axi_pending_q;
    logic [BEAT_CNT_W-1:0] fill_beat_q;
    logic [BEAT_PTR_W-1:0] w_beat_q;
    logic [PTR_W-1:0] write_ptr_q;
    logic [CNT_W-1:0] write_pending_q;
    wire [PTR_W-1:0] write_slot=PIPELINE_WRITE_DATA ? write_ptr_q : head_q;
    wire write_available=PIPELINE_WRITE_DATA ? write_pending_q!=0 : desc_count_q!=0;
    wire write_local=ISSUE_AW_BEFORE_PAYLOAD ? desc_cmd_error_mem[write_slot] : desc_local_error_mem[write_slot];
    wire write_skip=PIPELINE_WRITE_DATA && !rst && write_available &&
        desc_payload_done_mem[write_slot] && write_local;
    wire write_advance=write_skip || (m_axi_wvalid && m_axi_wready && m_axi_wlast);
    logic [TAG_WIDTH-1:0] next_tag_q;

    function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] value);
        integer tmp;
        begin
            tmp = value + 1;
            if (tmp >= MAX_OUTSTANDING)
                tmp = 0;
            ptr_inc = tmp[PTR_W-1:0];
        end
    endfunction

    function automatic [RSP_PTR_W-1:0] rsp_ptr_inc(
        input [RSP_PTR_W-1:0] value
    );
        integer tmp;
        begin
            tmp = value + 1;
            if (tmp >= RSP_FIFO_DEPTH)
                tmp = 0;
            rsp_ptr_inc = tmp[RSP_PTR_W-1:0];
        end
    endfunction

    function automatic [8:0] clamp_beats(input [8:0] value);
        begin
            if (value == 0)
                clamp_beats = 9'd1;
            else if (value > MAX_BEATS)
                clamp_beats = MAX_BEATS;
            else
                clamp_beats = value;
        end
    endfunction

    // ------------------------------------------------------------------
    // Request/payload framing.
    // ------------------------------------------------------------------
    logic cmd_fire, payload_fire, payload_finish;
    logic payload_early, payload_late, payload_flush_finish;
    logic fill_available;
    logic [8:0] fill_beats_comb;
    logic fill_expected_last;
    logic [8:0] cmd_beats_eff;
    logic cmd_cross_4k;
    logic cmd_local_error_comb;

    assign cmd_ready = !rst && (desc_count_q < MAX_OUTSTANDING);
    assign cmd_fire = cmd_valid && cmd_ready;
    assign cmd_beats_eff = clamp_beats(cmd_beats);
    assign cmd_cross_4k = ({1'b0, cmd_addr[11:0]} +
                          ({4'd0, cmd_beats_eff} << 4) > 13'd4096);
    assign cmd_local_error_comb = (cmd_addr[3:0] != 4'b0000) ||
                                  (cmd_beats == 0) ||
                                  (cmd_beats > MAX_BEATS) ||
                                  cmd_cross_4k;

    assign fill_available = (fill_count_q != 0) &&
                            !desc_payload_done_mem[fill_ptr_q];
    // A flush is a control beat and can complete a frame without a data
    // handshake.  payload_ready itself remains a normal VALID/READY signal.
    assign payload_ready = !rst && fill_available;
    assign payload_fire = payload_valid && payload_ready;
    assign fill_beats_comb = desc_beats_mem[fill_ptr_q];
    assign fill_expected_last = (fill_beat_q == (fill_beats_comb - 1'b1));
    assign payload_early = payload_fire && payload_last &&
                           !fill_expected_last;
    assign payload_late = payload_fire && !payload_last &&
                          fill_expected_last;
    assign payload_flush_finish = payload_flush && fill_available;
    assign payload_finish = payload_flush_finish || payload_early ||
                             payload_late ||
                             (payload_fire && fill_expected_last);

    // Response FIFO declarations precede the AXI scheduler because its
    // conservative BREADY/space qualification references rsp_count_q.
    logic [31:0] rsp_addr_mem [0:RSP_FIFO_DEPTH-1];
    logic [8:0]  rsp_beats_mem [0:RSP_FIFO_DEPTH-1];
    logic [TAG_WIDTH-1:0] rsp_tag_mem [0:RSP_FIFO_DEPTH-1];
    logic rsp_err_mem [0:RSP_FIFO_DEPTH-1];
    logic [RSP_PTR_W-1:0] rsp_head_q, rsp_tail_q;
    logic [RSP_CNT_W-1:0] rsp_count_q;

    // ------------------------------------------------------------------
    // AW issue scheduler.  The default path waits for a descriptor's payload
    // frame to complete; ISSUE_AW_BEFORE_PAYLOAD optionally releases AW for
    // command-valid descriptors as soon as they enter the ring. W and B each
    // remain strictly ordered; PIPELINE_WRITE_DATA separates their cursors.
    // ------------------------------------------------------------------
    logic issue_candidate, issue_local, aw_fire, issue_step;
    logic head_local_ready, head_axi_ready, b_fire, retire_fire;
    logic rsp_space, rsp_push, rsp_pop, retire_error;

    assign issue_candidate = !rst && (desc_count_q != 0) &&
                             (issued_count_q < desc_count_q) &&
                             (ISSUE_AW_BEFORE_PAYLOAD ?
                              (!desc_cmd_error_mem[issue_ptr_q] ||
                               desc_payload_done_mem[issue_ptr_q]) :
                              desc_payload_done_mem[issue_ptr_q]);
    // In the optional mode only command-time poison is local.  Payload
    // framing errors are discovered after an early AW and must therefore
    // still flow through the normal W/B path.  The default path intentionally
    // retains its historical aggregate-error behavior.
    assign issue_local = issue_candidate &&
                         (ISSUE_AW_BEFORE_PAYLOAD ?
                          desc_cmd_error_mem[issue_ptr_q] :
                          desc_local_error_mem[issue_ptr_q]);

    always_comb begin
        m_axi_awaddr = 32'd0;
        m_axi_awlen = 8'd0;
        m_axi_awsize = 3'd4;
        m_axi_awburst = 2'b01;
        m_axi_awvalid = 1'b0;
        if (issue_candidate && !issue_local) begin
            m_axi_awaddr = desc_addr_mem[issue_ptr_q];
            m_axi_awlen = desc_beats_mem[issue_ptr_q] - 1'b1;
            m_axi_awvalid = 1'b1;
        end

        m_axi_wdata = 128'd0;
        m_axi_wstrb = 16'd0;
        m_axi_wlast = 1'b0;
        m_axi_wvalid = 1'b0;
        // The head owns a complete immutable payload before W is exposed.
        // AW acceptance is not a prerequisite: a legal slave may wait for
        // WVALID to accept AW. W completion does not retire the head; the
        // existing AW-issued and B-response gates retain that ownership.
        if (!rst && write_available && desc_payload_done_mem[write_slot] &&
            !desc_w_done_mem[write_slot] && !write_local) begin
            // In early-AW mode a malformed payload frame is still emitted as
            // a legal declared-length burst.  Any beat not captured before
            // LAST/flush is deterministic zero data with zero strobe.  Keep
            // the old direct RAM path in the default mode so its timing
            // remains constant-propagation friendly.
            if (ISSUE_AW_BEFORE_PAYLOAD) begin
                if (payload_valid_mem[write_slot][w_beat_q]) begin
                    m_axi_wdata = payload_mem[write_slot][w_beat_q];
                    m_axi_wstrb = payload_strb_mem[write_slot][w_beat_q];
                end else begin
                    m_axi_wdata = 128'd0;
                    m_axi_wstrb = 16'd0;
                end
            end else begin
                m_axi_wdata = payload_mem[write_slot][w_beat_q];
                m_axi_wstrb = payload_strb_mem[write_slot][w_beat_q];
            end
            m_axi_wlast = (w_beat_q == (desc_beats_mem[write_slot] - 1'b1));
            m_axi_wvalid = 1'b1;
        end

        m_axi_bready = 1'b0;
        if (!rst && (desc_count_q != 0) && (issued_count_q != 0) &&
            desc_aw_issued_mem[head_q] && desc_w_done_mem[head_q] &&
            (ISSUE_AW_BEFORE_PAYLOAD ?
             !desc_cmd_error_mem[head_q] :
             !desc_local_error_mem[head_q]) && rsp_space)
            m_axi_bready = 1'b1;
        else if (!rst && (issued_count_q == 0) && m_axi_bvalid)
            // Drain an unsolicited B so a malformed slave cannot wedge the
            // shared write channel.  It never retires a descriptor.
            m_axi_bready = 1'b1;
    end

    assign aw_fire = m_axi_awvalid && m_axi_awready;
    assign issue_step = issue_local || aw_fire;
    assign b_fire = m_axi_bvalid && m_axi_bready;

    // A simultaneous public response pop releases one slot at the active
    // edge.  The optional mode uses that slot immediately; no count overflow
    // occurs because the sequential two-bit case below handles push+pop as a
    // net-zero occupancy change.  Keeping this disabled by default avoids a
    // rsp_ready -> BREADY combinational path in the portable build.
    assign rsp_space = (rsp_count_q < RSP_FIFO_DEPTH) ||
                       (ALLOW_RSP_POP_REFILL && rsp_pop);
    assign head_local_ready = !rst && (desc_count_q != 0) &&
                              (issued_count_q != 0) &&
                              desc_aw_issued_mem[head_q] &&
                              desc_w_done_mem[head_q] &&
                              (ISSUE_AW_BEFORE_PAYLOAD ?
                               (desc_cmd_error_mem[head_q] &&
                                desc_payload_done_mem[head_q]) :
                               desc_local_error_mem[head_q]) && rsp_space;
    // An unsolicited B is deliberately drained (m_axi_bready is asserted
    // when issued_count_q==0), but it must never retire the descriptor ring.
    // Gate retirement with the in-flight count so orphan B cannot decrement
    // desc_count_q/issued_count_q or enqueue a phantom response.
    assign head_axi_ready = b_fire && (issued_count_q != 0);
    assign retire_fire = head_local_ready || head_axi_ready;
    assign retire_error = head_local_ready ?
                          (ISSUE_AW_BEFORE_PAYLOAD ? 1'b1 :
                           desc_local_error_mem[head_q]) :
                          (ISSUE_AW_BEFORE_PAYLOAD ?
                           (desc_local_error_mem[head_q] ||
                            (m_axi_bresp != 2'b00)) :
                           (m_axi_bresp != 2'b00));

    // ------------------------------------------------------------------
    // Descriptor response FIFO.
    // ------------------------------------------------------------------
    assign rsp_valid = !rst && (rsp_count_q != 0);
    assign rsp_error = rsp_valid ? rsp_err_mem[rsp_head_q] : 1'b0;
    assign rsp_addr = rsp_valid ? rsp_addr_mem[rsp_head_q] : 32'd0;
    assign rsp_beats = rsp_valid ? rsp_beats_mem[rsp_head_q] : 9'd0;
    assign rsp_tag = rsp_valid ? rsp_tag_mem[rsp_head_q] : '0;
    assign rsp_pop = rsp_valid && rsp_ready;
    assign rsp_push = retire_fire;

    // The public occupancy counters intentionally use descriptor-level
    // counts; axi_pending_q is the true physical no-ID AXI MLP depth.
    assign perf_busy = (desc_count_q != 0) || (rsp_count_q != 0) ||
                       (fill_count_q != 0);
    assign perf_cmd_occupancy = desc_count_q;
    // issued_count_q includes locally poisoned descriptors. Public AXI
    // occupancy must count only real AW minus owned B handshakes.
    assign perf_outstanding = axi_pending_q;

    // Sticky diagnostics and protocol aggregate.
    logic early_payload_last_error_q, late_payload_last_error_q;
    logic payload_flush_error_q, orphan_payload_error_q;
    logic early_b_error_q, orphan_b_error_q;
    assign early_payload_last_error = early_payload_last_error_q;
    assign late_payload_last_error = late_payload_last_error_q;
    assign payload_flush_error = payload_flush_error_q;
    assign orphan_payload_error = orphan_payload_error_q;
    assign early_b_error = early_b_error_q;
    assign orphan_b_error = orphan_b_error_q;
    assign protocol_error = early_payload_last_error_q ||
                            late_payload_last_error_q ||
                            payload_flush_error_q ||
                            orphan_payload_error_q ||
                            early_b_error_q || orphan_b_error_q;

    logic w_fire;
    assign w_fire = m_axi_wvalid && m_axi_wready;

    integer init_i, init_j;
    always_ff @(posedge clk) begin
        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            fill_ptr_q <= '0;
            issue_ptr_q <= '0;
            desc_count_q <= '0;
            fill_count_q <= '0;
            issued_count_q <= '0;
            axi_pending_q <= '0;
            fill_beat_q <= '0;
            w_beat_q <= '0;
            write_ptr_q <= '0;
            write_pending_q <= '0;
            next_tag_q <= '0;
            rsp_head_q <= '0;
            rsp_tail_q <= '0;
            rsp_count_q <= '0;
            early_payload_last_error_q <= 1'b0;
            late_payload_last_error_q <= 1'b0;
            payload_flush_error_q <= 1'b0;
            orphan_payload_error_q <= 1'b0;
            early_b_error_q <= 1'b0;
            orphan_b_error_q <= 1'b0;
            perf_cmd_accept_count <= 64'd0;
            perf_payload_beat_count <= 64'd0;
            perf_axi_burst_count <= 64'd0;
            perf_axi_beat_count <= 64'd0;
            perf_aw_issue_count <= 64'd0;
            perf_rsp_count <= 64'd0;
            perf_error_count <= 64'd0;
            perf_aw_stall_count <= 64'd0;
            perf_w_stall_count <= 64'd0;
            perf_b_stall_count <= 64'd0;
            perf_max_cmd_occupancy <= 8'd0;
            perf_max_outstanding <= 8'd0;
            for (init_i = 0; init_i < MAX_OUTSTANDING; init_i = init_i + 1) begin
                desc_addr_mem[init_i] <= 32'd0;
                desc_beats_mem[init_i] <= 9'd1;
                desc_tag_mem[init_i] <= '0;
                desc_cmd_error_mem[init_i] <= 1'b0;
                desc_local_error_mem[init_i] <= 1'b0;
                desc_payload_done_mem[init_i] <= 1'b0;
                desc_aw_issued_mem[init_i] <= 1'b0;
                desc_w_done_mem[init_i] <= 1'b0;
                payload_valid_mem[init_i] <= '0;
                for (init_j = 0; init_j < MAX_BEATS; init_j = init_j + 1) begin
                    payload_mem[init_i][init_j] <= 128'd0;
                    payload_strb_mem[init_i][init_j] <= 16'd0;
                end
            end
            for (init_i = 0; init_i < RSP_FIFO_DEPTH; init_i = init_i + 1) begin
                rsp_addr_mem[init_i] <= 32'd0;
                rsp_beats_mem[init_i] <= 9'd0;
                rsp_tag_mem[init_i] <= '0;
                rsp_err_mem[init_i] <= 1'b0;
            end
        end else begin
            // Descriptor acceptance.  A malformed address/length is retained
            // as a poisoned descriptor and still consumes its clamped frame.
            if (cmd_fire) begin
                desc_addr_mem[tail_q] <= cmd_addr;
                desc_beats_mem[tail_q] <= cmd_beats_eff;
                desc_tag_mem[tail_q] <= next_tag_q;
                desc_cmd_error_mem[tail_q] <= cmd_local_error_comb;
                desc_local_error_mem[tail_q] <= cmd_local_error_comb;
                desc_payload_done_mem[tail_q] <= 1'b0;
                desc_aw_issued_mem[tail_q] <= 1'b0;
                desc_w_done_mem[tail_q] <= 1'b0;
                payload_valid_mem[tail_q] <= '0;
                tail_q <= ptr_inc(tail_q);
                next_tag_q <= next_tag_q + 1'b1;
                perf_cmd_accept_count <= perf_cmd_accept_count + 1'b1;
            end

            // Descriptor occupancy and payload-pending occupancy.  Explicit
            // two-bit cases preserve simultaneous enqueue/retire semantics.
            case ({cmd_fire, retire_fire})
                2'b10: desc_count_q <= desc_count_q + 1'b1;
                2'b01: desc_count_q <= desc_count_q - 1'b1;
                default: desc_count_q <= desc_count_q;
            endcase
            case ({cmd_fire, payload_finish})
                2'b10: fill_count_q <= fill_count_q + 1'b1;
                2'b01: fill_count_q <= fill_count_q - 1'b1;
                default: fill_count_q <= fill_count_q;
            endcase
            if (cmd_fire && (desc_count_q + 1'b1 > perf_max_cmd_occupancy))
                perf_max_cmd_occupancy <= desc_count_q + 1'b1;

            // Start the fill pointer when the first descriptor enters an
            // empty payload queue.  If the current frame finishes while a new
            // command arrives, point directly at that newly appended slot.
            if (payload_finish) begin
                desc_payload_done_mem[fill_ptr_q] <= 1'b1;
                if (payload_early)
                    early_payload_last_error_q <= 1'b1;
                if (payload_late)
                    late_payload_last_error_q <= 1'b1;
                if (payload_flush_finish)
                    payload_flush_error_q <= 1'b1;
                if (payload_fire)
                    perf_payload_beat_count <= perf_payload_beat_count + 1'b1;
                if (payload_early || payload_late || payload_flush_finish)
                    desc_local_error_mem[fill_ptr_q] <= 1'b1;
                fill_beat_q <= '0;
                if (cmd_fire && (fill_count_q == 1))
                    fill_ptr_q <= tail_q;
                else
                    fill_ptr_q <= ptr_inc(fill_ptr_q);
            end else if (payload_fire) begin
                payload_mem[fill_ptr_q][fill_beat_q] <= payload_data;
                payload_strb_mem[fill_ptr_q][fill_beat_q] <= payload_strb;
                fill_beat_q <= fill_beat_q + 1'b1;
                perf_payload_beat_count <= perf_payload_beat_count + 1'b1;
            end
            // Store the terminal beat as well as marking the descriptor done.
            // This separate assignment is intentionally after the framing
            // branch so a final beat is never lost.
            if (payload_fire) begin
                payload_mem[fill_ptr_q][fill_beat_q] <= payload_data;
                payload_strb_mem[fill_ptr_q][fill_beat_q] <= payload_strb;
                payload_valid_mem[fill_ptr_q][fill_beat_q] <= 1'b1;
            end
            if (cmd_fire && (fill_count_q == 0) && !payload_finish)
                fill_ptr_q <= tail_q;

            if (payload_flush && !fill_available)
                orphan_payload_error_q <= 1'b1;
            if (payload_valid && payload_last && !fill_available)
                orphan_payload_error_q <= 1'b1;

            // AW issue: local errors consume an issue slot without driving AXI.
            if (issue_step) begin
                desc_aw_issued_mem[issue_ptr_q] <= 1'b1;
                if (issue_local && !PIPELINE_WRITE_DATA)
                    desc_w_done_mem[issue_ptr_q] <= 1'b1;
                issue_ptr_q <= ptr_inc(issue_ptr_q);
                if (aw_fire) begin
                    perf_axi_burst_count <= perf_axi_burst_count + 1'b1;
                    perf_aw_issue_count <= perf_aw_issue_count + 1'b1;
                end
            end
            case ({issue_step, retire_fire})
                2'b10: issued_count_q <= issued_count_q + 1'b1;
                2'b01: issued_count_q <= issued_count_q - 1'b1;
                default: issued_count_q <= issued_count_q;
            endcase
            case({aw_fire,head_axi_ready})
                2'b10:begin
                    axi_pending_q<=axi_pending_q+1'b1;
                    if(axi_pending_q+1'b1>perf_max_outstanding)
                        perf_max_outstanding<=axi_pending_q+1'b1;
                end
                2'b01:axi_pending_q<=axi_pending_q-1'b1;
                default:;
            endcase

            // Strictly ordered W stream.  The seam itself generates WLAST
            // from the declared length; counters make stalls visible.
            if(PIPELINE_WRITE_DATA) begin
                case({cmd_fire,write_advance})
                    2'b10:write_pending_q<=write_pending_q+1'b1;
                    2'b01:write_pending_q<=write_pending_q-1'b1;
                    default:;
                endcase
                if(write_advance) write_ptr_q<=ptr_inc(write_ptr_q);
                if(write_skip) begin desc_w_done_mem[write_slot]<=1'b1;w_beat_q<='0;end
            end
            if (w_fire) begin
                perf_axi_beat_count <= perf_axi_beat_count + 1'b1;
                if (m_axi_wlast ||
                    (w_beat_q == (desc_beats_mem[write_slot] - 1'b1))) begin
                    desc_w_done_mem[write_slot] <= 1'b1;
                    w_beat_q <= '0;
                end else begin
                    w_beat_q <= w_beat_q + 1'b1;
                end
            end

            // Ordered B retirement (or local poisoned-descriptor retirement).
            if (retire_fire) begin
                rsp_addr_mem[rsp_tail_q] <= desc_addr_mem[head_q];
                rsp_beats_mem[rsp_tail_q] <= desc_beats_mem[head_q];
                rsp_tag_mem[rsp_tail_q] <= desc_tag_mem[head_q];
                rsp_err_mem[rsp_tail_q] <= retire_error;
                if (retire_error)
                    perf_error_count <= perf_error_count + 1'b1;
                desc_aw_issued_mem[head_q] <= 1'b0;
                desc_w_done_mem[head_q] <= 1'b0;
                desc_payload_done_mem[head_q] <= 1'b0;
                desc_cmd_error_mem[head_q] <= 1'b0;
                desc_local_error_mem[head_q] <= 1'b0;
                payload_valid_mem[head_q] <= '0;
                head_q <= ptr_inc(head_q);
            end

            // Response FIFO pointer/count and response-performance counter.
            if (rsp_push)
                rsp_tail_q <= rsp_ptr_inc(rsp_tail_q);
            if (rsp_pop) begin
                rsp_head_q <= rsp_ptr_inc(rsp_head_q);
                perf_rsp_count <= perf_rsp_count + 1'b1;
            end
            case ({rsp_push, rsp_pop})
                2'b10: rsp_count_q <= rsp_count_q + 1'b1;
                2'b01: rsp_count_q <= rsp_count_q - 1'b1;
                default: rsp_count_q <= rsp_count_q;
            endcase

            // Sticky malformed-slave diagnostics.  An unsolicited B is
            // drained, while a B before W completion is held as an error and
            // not allowed to retire the head descriptor.
            if (m_axi_bvalid && (issued_count_q == 0))
                orphan_b_error_q <= 1'b1;
            else if (m_axi_bvalid && (issued_count_q != 0) &&
                     !desc_w_done_mem[head_q] &&
                     (ISSUE_AW_BEFORE_PAYLOAD ?
                      !desc_cmd_error_mem[head_q] :
                      !desc_local_error_mem[head_q]))
                early_b_error_q <= 1'b1;

            // Stall counters are intentionally event counters, not sampled
            // durations, so they remain cheap and unambiguous in hardware.
            if (m_axi_awvalid && !m_axi_awready)
                perf_aw_stall_count <= perf_aw_stall_count + 1'b1;
            if (m_axi_wvalid && !m_axi_wready)
                perf_w_stall_count <= perf_w_stall_count + 1'b1;
            if (m_axi_bvalid && !m_axi_bready)
                perf_b_stall_count <= perf_b_stall_count + 1'b1;
        end
    end

`ifndef SYNTHESIS
    // Local VALID-hold assertions catch accidental payload changes while an
    // AXI channel is stalled.  They are excluded from synthesis and keep the
    // detached xsim test self-checking without an external AXI VIP license.
    logic aw_stalled_q, w_stalled_q, b_stalled_q;
    logic [44:0] aw_payload_q;
    logic [144:0] w_payload_q;
    logic [1:0] b_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_stalled_q <= 1'b0;
            w_stalled_q <= 1'b0;
            b_stalled_q <= 1'b0;
        end else begin
            if (aw_stalled_q && (!m_axi_awvalid ||
                ({m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst} !==
                 aw_payload_q)))
                $fatal(1, "write MLP changed stalled AW payload");
            if (w_stalled_q && (!m_axi_wvalid ||
                ({m_axi_wdata,m_axi_wstrb,m_axi_wlast} !== w_payload_q)))
                $fatal(1, "write MLP changed stalled W payload");
            // AXI requires both BVALID and BRESP to remain stable while the
            // slave response is stalled.  Checking the payload as well as the
            // valid bit catches a fabric that changes the response code under
            // backpressure; this is simulation-only and has no synthesis cost.
            if (b_stalled_q && (!m_axi_bvalid ||
                m_axi_bresp !== b_payload_q))
                $fatal(1, "write MLP changed stalled B payload");
            aw_stalled_q <= m_axi_awvalid && !m_axi_awready;
            aw_payload_q <= {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            w_stalled_q <= m_axi_wvalid && !m_axi_wready;
            w_payload_q <= {m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            b_stalled_q <= m_axi_bvalid && !m_axi_bready;
            b_payload_q <= m_axi_bresp;
            if (m_axi_awvalid && m_axi_awready &&
                (m_axi_awaddr[3:0] != 4'b0000))
                $fatal(1, "write MLP issued unaligned AW");
            if (m_axi_awvalid && m_axi_awready &&
                ({1'b0,m_axi_awaddr[11:0]} +
                 ({5'd0,m_axi_awlen}+1'b1)*13'd16 > 13'd4096))
                $fatal(1, "write MLP AW crossed 4KiB boundary");
            if (ISSUE_AW_BEFORE_PAYLOAD && m_axi_awvalid &&
                desc_cmd_error_mem[issue_ptr_q])
                $fatal(1, "early-AW mode issued command-poisoned descriptor");
            if (ISSUE_AW_BEFORE_PAYLOAD && m_axi_wvalid &&
                !desc_payload_done_mem[write_slot])
                $fatal(1, "early-AW mode drove W before payload completion");
            if (ISSUE_AW_BEFORE_PAYLOAD && m_axi_wvalid &&
                desc_cmd_error_mem[write_slot])
                $fatal(1, "early-AW mode drove W for command-poisoned descriptor");
            if(PIPELINE_WRITE_DATA && (write_pending_q>desc_count_q ||
               (write_advance && write_pending_q==0)))
                $fatal(1,"write MLP cursor lost payload ownership");
            if(axi_pending_q>MAX_OUTSTANDING || (head_axi_ready && axi_pending_q==0))
                $fatal(1,"write MLP physical AW/B credit mismatch");
        end
    end
`endif

endmodule
