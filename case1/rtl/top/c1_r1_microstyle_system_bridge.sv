// Boardless-frame-system bridge around the tested dispatcher-compatible
// MicroStyle CNN top. The complete 22-descriptor snapshot is fanned out
// losslessly to the arithmetic engine and to an explicit inter-stage tensor
// adapter before any source pixel is released.
//
// The adapter is a first-class architectural boundary, not a placeholder
// convolution. It owns 3x3 window construction, stride/padding, C8 group
// sequencing, upsample/residual routing and intermediate feature storage.
// Keeping these ports explicit prevents a single C8 pixel from being copied
// nine times and incorrectly treated as a real 3x3 neighborhood.
module c1_r1_microstyle_system_bridge #(
    parameter integer REQUIRED_STAGES = 22,
    parameter integer PARAM_ADDR_W = 11,
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    parameter integer PIPELINED_DESCRIPTOR_REPLAY = 0,
    parameter integer PREVALIDATE_DESCRIPTOR_REPLAY = 0,
    // Optional two-cycle validation schedule in the replay-side command
    // decoder.  Default zero preserves the legacy one-cycle command path.
    parameter integer PIPELINED_DECODER_VALIDATION = 0,
    // Optional registered CNN-result boundary.  Default zero preserves the
    // original direct CNN-to-adapter handshake; the opt-in branch is a
    // complete-payload depth-2 FIFO experiment.
    parameter integer ENABLE_UNIFIED_OUTPUT_FIFO = 0,
    // Optional one-entry complete-payload skid boundary.  This is kept
    // separate from the depth-2 FIFO so the two timing experiments can be
    // compared without changing either implementation's occupancy rules.
    parameter integer ENABLE_UNIFIED_OUTPUT_SKID = 0,
    // Optional Efinity-friendly packed affine-cache representation.  The
    // default preserves the legacy unpacked cache; Ti60 multi-group builds
    // can opt in after map/P&R and functional validation.
    parameter integer PACKED_AFFINE_CACHE = 0,
    parameter integer CACHE_DW_WEIGHT_TILES = 0,
    parameter integer MAC_PREFETCH_OVERLAP = 0,
    parameter bit STREAM_DW_GROUPS = 1'b0,
    parameter bit STREAM_POINTWISE_REDUCTION = 1'b0,
    parameter bit OVERLAP_MAC_REQUANTIZATION = 1'b0,
    parameter bit PIPELINE_DOT_PIXELS = 1'b0,
    parameter bit PIPELINE_DW_PIXELS = 1'b0,
    parameter bit STREAM_DW_FRAME = 1'b0,
    parameter bit PIPELINE_ALL_DOT_GROUPS = 1'b0,
    parameter bit PACK_RGB_CONV_REDUCTION = 1'b0,
    parameter bit ELIDE_VIRTUAL_UPSAMPLE = 1'b0,
    parameter bit FUSE_FINAL_OUTPUT = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       abort,

    input  logic                       start_valid,
    output logic                       start_ready,
    input  logic [15:0]                stage_count,
    input  logic [7:0]                 config_generation,
    input  logic                       parameter_active_valid,
    input  logic [31:0]                parameter_generation,
    output logic                       busy,
    output logic                       done,
    output logic                       aborted,
    output logic                       error,
    output logic [7:0]                 error_code,

    input  logic                       stage_config_valid,
    output logic                       stage_config_ready,
    input  logic [15:0]                stage_config_index,
    input  logic [511:0]               stage_config_descriptor,
    input  logic [7:0]                 stage_config_generation,

    output logic                       param_rd_en,
    output logic [PARAM_ADDR_W-1:0]    param_rd_addr,
    input  logic                       param_rd_valid,
    input  logic                       param_rd_error,
    input  logic [127:0]               param_rd_data,

    // C8 RGB frame from/to c1_r1_boardless_frame_system.
    input  logic                       board_in_valid,
    output logic                       board_in_ready,
    input  logic [63:0]                board_in_data_s8,
    input  logic [15:0]                board_in_x,
    input  logic [15:0]                board_in_y,
    input  logic                       board_in_sof,
    input  logic                       board_in_eol,
    input  logic                       board_in_eof,
    output logic                       board_out_valid,
    input  logic                       board_out_ready,
    output logic [63:0]                board_out_data_s8,
    output logic [15:0]                board_out_x,
    output logic [15:0]                board_out_y,
    output logic                       board_out_sof,
    output logic                       board_out_eol,
    output logic                       board_out_eof,

    // Tensor-adapter lifecycle and descriptor snapshot.
    output logic                       adapter_start_valid,
    input  logic                       adapter_start_ready,
    output logic                       adapter_abort,
    output logic                       adapter_stage_config_valid,
    input  logic                       adapter_stage_config_ready,
    output logic [15:0]                adapter_stage_config_index,
    output logic [511:0]               adapter_stage_config_descriptor,
    output logic [7:0]                 adapter_stage_config_generation,
    input  logic                       adapter_error,
    input  logic [7:0]                 adapter_error_code,

    // Initial frame delivered to the adapter.
    output logic                       adapter_source_valid,
    input  logic                       adapter_source_ready,
    output logic [63:0]                adapter_source_data_s8,
    output logic [15:0]                adapter_source_x,
    output logic [15:0]                adapter_source_y,
    output logic                       adapter_source_sof,
    output logic                       adapter_source_eol,
    output logic                       adapter_source_eof,

    // Adapter-prepared operands for the currently active arithmetic stage.
    input  logic                       adapter_engine_valid,
    output logic                       adapter_engine_ready,
    input  logic [575:0]               adapter_engine_window_s8,
    input  logic [63:0]                adapter_engine_residual_s8,
    input  logic [2:0]                 adapter_engine_group_index,
    input  logic                       adapter_engine_group_last,
    input  logic [15:0]                adapter_engine_x,
    input  logic [15:0]                adapter_engine_y,
    input  logic                       adapter_engine_sof,
    input  logic                       adapter_engine_eol,
    input  logic                       adapter_engine_eof,

    // Arithmetic result returned to the adapter for routing/storage.
    output logic                       adapter_result_valid,
    input  logic                       adapter_result_ready,
    output logic [63:0]                adapter_result_data_s8,
    output logic [2:0]                 adapter_result_group_index,
    output logic                       adapter_result_group_last,
    output logic [15:0]                adapter_result_x,
    output logic [15:0]                adapter_result_y,
    output logic                       adapter_result_sof,
    output logic                       adapter_result_eol,
    output logic                       adapter_result_eof,

    // Final RGB-C8 frame returned by the adapter.
    input  logic                       adapter_final_valid,
    output logic                       adapter_final_ready,
    input  logic [63:0]                adapter_final_data_s8,
    input  logic [15:0]                adapter_final_x,
    input  logic [15:0]                adapter_final_y,
    input  logic                       adapter_final_sof,
    input  logic                       adapter_final_eol,
    input  logic                       adapter_final_eof,

    output logic [4:0]                 engine_stage_index,
    output logic [7:0]                 engine_stage_opcode,
    output logic                       engine_stage_active,
    output logic                       engine_adapter_required,
    output logic                       engine_stage_done,
    output logic                       engine_overflow_seen,
    output logic                       config_capture_complete,
    input  logic                       adapter_view_valid,
    output logic                       adapter_view_ready,
    input  logic [4:0]                 adapter_view_stage,
    input  logic [7:0]                 adapter_view_generation
);

    logic active_q;
    logic start_pending_q;
    logic cnn_start_sent_q;
    logic adapter_start_sent_q;
    logic cnn_start_fire;
    logic adapter_start_fire;
    logic [15:0] start_stage_count_q;
    logic [7:0] start_config_generation_q;
    logic start_parameter_active_valid_q;
    logic [31:0] start_parameter_generation_q;
    logic descriptor_hold_valid_q;
    logic [15:0] descriptor_hold_index_q;
    logic [511:0] descriptor_hold_data_q;
    logic [7:0] descriptor_hold_generation_q;
    logic cnn_descriptor_sent_q;
    logic adapter_descriptor_sent_q;
    logic cnn_config_complete_pulse;
    logic cnn_config_complete_seen_q;
    logic adapter_config_complete_seen_q;
    logic cnn_start_valid;
    logic cnn_start_ready;
    logic cnn_busy;
    logic cnn_done;
    logic cnn_aborted;
    logic cnn_error;
    logic [7:0] cnn_error_code;
    logic cnn_stage_config_valid;
    logic cnn_stage_config_ready;
    logic cnn_stage_config_fire;
    logic adapter_stage_config_fire;
    logic final_fire;
    logic source_enable;
    logic start_contract_fault;
    logic start_contract_fault_q;
    logic [7:0] start_contract_fault_code_q;
    logic cnn_done_seen_q;
    logic final_eof_seen_q;
    logic done_q;
    logic cnn_result_valid;
    logic cnn_result_ready;
    logic [63:0] cnn_result_data_s8;
    logic [2:0] cnn_result_group_index;
    logic cnn_result_group_last;
    logic [15:0] cnn_result_x;
    logic [15:0] cnn_result_y;
    logic cnn_result_sof;
    logic cnn_result_eol;
    logic cnn_result_eof;
    logic unified_fifo_out_valid;
    logic unified_fifo_out_ready;
    logic bridge_error_now;
    logic [1:0] unified_fifo_level;
    logic unified_fifo_full;
    logic unified_fifo_empty;
    logic unified_skid_out_valid;
    logic unified_skid_out_ready;
    logic unified_skid_level;
    logic unified_skid_full;
    logic unified_skid_empty;

    always_comb begin
        // Lossless two-sink start fanout. VALID must never depend on the
        // other sink's READY: an adapter that asserts READY only after seeing
        // VALID is AXI-stream legal and would deadlock the former combinational
        // cross-gating.  The upstream job is accepted into this one-entry
        // buffer, then each sink acknowledges independently.
        start_ready = !active_q && !start_pending_q;
        start_contract_fault = active_q &&
            ((stage_count != start_stage_count_q) ||
             (config_generation != start_config_generation_q) ||
             !parameter_active_valid ||
             (parameter_generation != start_parameter_generation_q));
        cnn_start_valid = start_pending_q && !cnn_start_sent_q &&
                          !start_contract_fault;
        adapter_start_valid = start_pending_q && !adapter_start_sent_q &&
                              !start_contract_fault;
        cnn_start_fire = cnn_start_valid && cnn_start_ready;
        adapter_start_fire = adapter_start_valid && adapter_start_ready;

        // The live generation comparison still suppresses both launch
        // valids immediately, but runtime transfer/error gating uses the
        // sticky registered verdict.  A runtime mutation can therefore let
        // at most one already-present beat retire on the capture edge; the
        // fault invalidates/aborts the whole frame, so that beat can never be
        // committed to display.  Compute the public fault view before any
        // VALID/READY gates so event simulation and synthesized logic use the
        // same-cycle value without relying on always_comb re-entry.
        bridge_error_now = cnn_error || adapter_error ||
                           start_contract_fault_q;
        error = bridge_error_now;
        if (cnn_error)
            error_code = cnn_error_code;
        else if (adapter_error)
            error_code = 8'h60 | adapter_error_code;
        else if (start_contract_fault_q)
            error_code = start_contract_fault_code_q;
        else
            error_code = 8'h00;

        stage_config_ready = active_q && !start_pending_q &&
                             !descriptor_hold_valid_q &&
                             !abort && !bridge_error_now;
        cnn_stage_config_valid = descriptor_hold_valid_q &&
                                 !cnn_descriptor_sent_q;
        adapter_stage_config_valid = descriptor_hold_valid_q &&
                                     !adapter_descriptor_sent_q;
        adapter_stage_config_index = descriptor_hold_index_q;
        adapter_stage_config_descriptor = descriptor_hold_data_q;
        adapter_stage_config_generation =
            descriptor_hold_generation_q;
        cnn_stage_config_fire =
            cnn_stage_config_valid && cnn_stage_config_ready;
        adapter_stage_config_fire =
            adapter_stage_config_valid && adapter_stage_config_ready;

        source_enable = active_q && cnn_config_complete_seen_q &&
                        adapter_config_complete_seen_q &&
                        !bridge_error_now;
        adapter_source_valid = board_in_valid && source_enable;
        board_in_ready = adapter_source_ready && source_enable;
        adapter_source_data_s8 = board_in_data_s8;
        adapter_source_x = board_in_x;
        adapter_source_y = board_in_y;
        adapter_source_sof = board_in_sof;
        adapter_source_eol = board_in_eol;
        adapter_source_eof = board_in_eof;

        // Earlier final-frame pixels may stream while the last arithmetic
        // stage is still running, but its EOF is not allowed to retire into
        // the boardless output DMA until the arithmetic engine has also
        // retired.  This makes compute-shell EOF a sound terminal condition
        // instead of trusting a malformed/early adapter final marker.
        board_out_valid = adapter_final_valid && active_q &&
            !bridge_error_now &&
            (!adapter_final_eof || cnn_done_seen_q || cnn_done);
        adapter_final_ready = board_out_ready && active_q &&
            !bridge_error_now &&
            (!adapter_final_eof || cnn_done_seen_q || cnn_done);
        board_out_data_s8 = adapter_final_data_s8;
        board_out_x = adapter_final_x;
        board_out_y = adapter_final_y;
        board_out_sof = adapter_final_sof;
        board_out_eol = adapter_final_eol;
        board_out_eof = adapter_final_eof;
        final_fire = board_out_valid && board_out_ready;

        adapter_abort = abort;
        busy = active_q || cnn_busy;
        done = done_q;
        aborted = cnn_aborted;
        config_capture_complete = cnn_config_complete_seen_q &&
                                  adapter_config_complete_seen_q;
    end

    always_ff @(posedge clk) begin
        if (rst || abort) begin
            active_q <= 1'b0;
            start_pending_q <= 1'b0;
            cnn_start_sent_q <= 1'b0;
            adapter_start_sent_q <= 1'b0;
            start_stage_count_q <= 16'd0;
            start_config_generation_q <= 8'd0;
            start_parameter_active_valid_q <= 1'b0;
            start_parameter_generation_q <= 32'd0;
            descriptor_hold_valid_q <= 1'b0;
            descriptor_hold_index_q <= 16'd0;
            descriptor_hold_data_q <= 512'd0;
            descriptor_hold_generation_q <= 8'd0;
            cnn_descriptor_sent_q <= 1'b0;
            adapter_descriptor_sent_q <= 1'b0;
            cnn_config_complete_seen_q <= 1'b0;
            adapter_config_complete_seen_q <= 1'b0;
            cnn_done_seen_q <= 1'b0;
            final_eof_seen_q <= 1'b0;
            done_q <= 1'b0;
            start_contract_fault_q <= 1'b0;
            start_contract_fault_code_q <= 8'd0;
        end else begin
            done_q <= 1'b0;
            if (start_valid && start_ready) begin
                active_q <= 1'b1;
                start_pending_q <= 1'b1;
                cnn_start_sent_q <= 1'b0;
                adapter_start_sent_q <= 1'b0;
                start_stage_count_q <= stage_count;
                start_config_generation_q <= config_generation;
                start_parameter_active_valid_q <= parameter_active_valid;
                start_parameter_generation_q <= parameter_generation;
                descriptor_hold_valid_q <= 1'b0;
                cnn_descriptor_sent_q <= 1'b0;
                adapter_descriptor_sent_q <= 1'b0;
                cnn_config_complete_seen_q <= 1'b0;
                adapter_config_complete_seen_q <= 1'b0;
                cnn_done_seen_q <= 1'b0;
                final_eof_seen_q <= 1'b0;
                start_contract_fault_q <= 1'b0;
                start_contract_fault_code_q <= 8'd0;
            end

            // A transient mutation of the live launch contract must remain a
            // terminal fault even if software or another block restores the
            // value on the following cycle.
            if (start_contract_fault) begin
                start_contract_fault_q <= 1'b1;
                if ((stage_count != start_stage_count_q) ||
                    (config_generation != start_config_generation_q))
                    start_contract_fault_code_q <= 8'h03;
                else
                    start_contract_fault_code_q <= 8'h04;
            end

            if (cnn_start_fire)
                cnn_start_sent_q <= 1'b1;
            if (adapter_start_fire)
                adapter_start_sent_q <= 1'b1;
            if (start_pending_q &&
                (cnn_start_sent_q || cnn_start_fire) &&
                (adapter_start_sent_q || adapter_start_fire)) begin
                start_pending_q <= 1'b0;
                cnn_start_sent_q <= 1'b0;
                adapter_start_sent_q <= 1'b0;
            end

            if (stage_config_valid && stage_config_ready) begin
                descriptor_hold_valid_q <= 1'b1;
                descriptor_hold_index_q <= stage_config_index;
                descriptor_hold_data_q <= stage_config_descriptor;
                descriptor_hold_generation_q <=
                    stage_config_generation;
                cnn_descriptor_sent_q <= 1'b0;
                adapter_descriptor_sent_q <= 1'b0;
            end

            if (cnn_stage_config_fire)
                cnn_descriptor_sent_q <= 1'b1;
            if (adapter_stage_config_fire) begin
                adapter_descriptor_sent_q <= 1'b1;
                if (descriptor_hold_index_q == REQUIRED_STAGES - 1)
                    adapter_config_complete_seen_q <= 1'b1;
            end

            if (descriptor_hold_valid_q &&
                (cnn_descriptor_sent_q || cnn_stage_config_fire) &&
                (adapter_descriptor_sent_q ||
                 adapter_stage_config_fire)) begin
                descriptor_hold_valid_q <= 1'b0;
                cnn_descriptor_sent_q <= 1'b0;
                adapter_descriptor_sent_q <= 1'b0;
            end

            if (cnn_config_complete_pulse)
                cnn_config_complete_seen_q <= 1'b1;

            if (active_q && cnn_done)
                cnn_done_seen_q <= 1'b1;
            if (final_fire && adapter_final_eof)
                final_eof_seen_q <= 1'b1;

            // Only a launch may acquire job ownership. A canceled adapter
            // can report a late drain error after the one-cycle abort; keep
            // that public diagnostic, but never resurrect an inactive job.
            // Active faults still retain ownership and suppress completion.
            if (active_q && !(cnn_error || adapter_error || start_contract_fault ||
                start_contract_fault_q) && (cnn_done_seen_q || cnn_done) &&
                     (final_eof_seen_q ||
                      (final_fire && adapter_final_eof))) begin
                active_q <= 1'b0;
                cnn_done_seen_q <= 1'b0;
                final_eof_seen_q <= 1'b0;
                done_q <= 1'b1;
            end
        end
    end

    generate
        if (ENABLE_UNIFIED_OUTPUT_SKID) begin : GEN_UNIFIED_OUTPUT_SKID
            c1_r1_unified_output_skid #(
                .COMBINATIONAL_ERROR_GATE(0)
            ) u_unified_output_skid (
                .clk(clk),
                .rst(rst),
                .abort(abort),
                .error_flush(bridge_error_now),
                .in_valid(cnn_result_valid),
                .in_ready(cnn_result_ready),
                .in_data_s8(cnn_result_data_s8),
                .in_group_index(cnn_result_group_index),
                .in_group_last(cnn_result_group_last),
                .in_x(cnn_result_x),
                .in_y(cnn_result_y),
                .in_sof(cnn_result_sof),
                .in_eol(cnn_result_eol),
                .in_eof(cnn_result_eof),
                .out_valid(unified_skid_out_valid),
                .out_ready(unified_skid_out_ready),
                .out_data_s8(adapter_result_data_s8),
                .out_group_index(adapter_result_group_index),
                .out_group_last(adapter_result_group_last),
                .out_x(adapter_result_x),
                .out_y(adapter_result_y),
                .out_sof(adapter_result_sof),
                .out_eol(adapter_result_eol),
                .out_eof(adapter_result_eof),
                .level(unified_skid_level),
                .full(unified_skid_full),
                .empty(unified_skid_empty)
            );
            // Keep error flushing synchronous inside the skid while fencing
            // the downstream adapter handshake immediately.  This mirrors
            // the bridge-local depth-2 FIFO experiment and avoids feeding
            // bridge error fanout back into cnn_result_ready.
            assign adapter_result_valid = unified_skid_out_valid &&
                                           !bridge_error_now;
            assign unified_skid_out_ready = adapter_result_ready &&
                                             !bridge_error_now;
        end else if (ENABLE_UNIFIED_OUTPUT_FIFO) begin : GEN_UNIFIED_OUTPUT_FIFO
            c1_r1_unified_output_fifo #(
                .DEPTH(2),
                .COMBINATIONAL_ERROR_GATE(0)
            ) u_unified_output_fifo (
                .clk(clk),
                .rst(rst),
                .abort(abort),
                .error_flush(bridge_error_now),
                .in_valid(cnn_result_valid),
                .in_ready(cnn_result_ready),
                .in_data_s8(cnn_result_data_s8),
                .in_group_index(cnn_result_group_index),
                .in_group_last(cnn_result_group_last),
                .in_x(cnn_result_x),
                .in_y(cnn_result_y),
                .in_sof(cnn_result_sof),
                .in_eol(cnn_result_eol),
                .in_eof(cnn_result_eof),
                .out_valid(unified_fifo_out_valid),
                .out_ready(unified_fifo_out_ready),
                .out_data_s8(adapter_result_data_s8),
                .out_group_index(adapter_result_group_index),
                .out_group_last(adapter_result_group_last),
                .out_x(adapter_result_x),
                .out_y(adapter_result_y),
                .out_sof(adapter_result_sof),
                .out_eol(adapter_result_eol),
                .out_eof(adapter_result_eof),
                .level(unified_fifo_level),
                .full(unified_fifo_full),
                .empty(unified_fifo_empty)
            );
            // Error is a synchronous lifecycle event.  The FIFO clears on
            // the error edge; gate the adapter-side handshake immediately so
            // no stale result can be accepted after the bridge has reported
            // the error, without feeding error back into cnn_result_ready.
            // COMBINATIONAL_ERROR_GATE=0 is intentional here: the normal
            // standalone FIFO default remains the stricter combinational
            // fence, while this bridge-local cut keeps the abort/ready timing
            // path from being re-created through FIFO occupancy logic.
            assign adapter_result_valid = unified_fifo_out_valid &&
                                           !bridge_error_now;
            assign unified_fifo_out_ready = adapter_result_ready &&
                                             !bridge_error_now;
        end else begin : GEN_DIRECT_OUTPUT
            assign cnn_result_ready = adapter_result_ready;
            assign adapter_result_valid = cnn_result_valid;
            assign adapter_result_data_s8 = cnn_result_data_s8;
            assign adapter_result_group_index = cnn_result_group_index;
            assign adapter_result_group_last = cnn_result_group_last;
            assign adapter_result_x = cnn_result_x;
            assign adapter_result_y = cnn_result_y;
            assign adapter_result_sof = cnn_result_sof;
            assign adapter_result_eol = cnn_result_eol;
            assign adapter_result_eof = cnn_result_eof;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (ENABLE_UNIFIED_OUTPUT_FIFO && ENABLE_UNIFIED_OUTPUT_SKID)
            $fatal(1,
                   "unified output FIFO and one-entry skid are mutually exclusive");
    end
`endif

    c1_r1_microstyle_cnn_top #(
        .REQUIRED_STAGES(REQUIRED_STAGES),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
        .CACHE_DW_WEIGHT_TILES(CACHE_DW_WEIGHT_TILES),
        .MAC_PREFETCH_OVERLAP(MAC_PREFETCH_OVERLAP),
        .STREAM_DW_GROUPS(STREAM_DW_GROUPS),
        .STREAM_POINTWISE_REDUCTION(STREAM_POINTWISE_REDUCTION),
        .OVERLAP_MAC_REQUANTIZATION(OVERLAP_MAC_REQUANTIZATION),
        .PIPELINE_DOT_PIXELS(PIPELINE_DOT_PIXELS),
        .PIPELINE_DW_PIXELS(PIPELINE_DW_PIXELS),
        .STREAM_DW_FRAME(STREAM_DW_FRAME),
        .PIPELINE_ALL_DOT_GROUPS(PIPELINE_ALL_DOT_GROUPS),
        .PACK_RGB_CONV_REDUCTION(PACK_RGB_CONV_REDUCTION),
        .ELIDE_VIRTUAL_UPSAMPLE(ELIDE_VIRTUAL_UPSAMPLE),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL_OUTPUT),
        .PIPELINED_DESCRIPTOR_REPLAY(PIPELINED_DESCRIPTOR_REPLAY),
        .PREVALIDATE_DESCRIPTOR_REPLAY(PREVALIDATE_DESCRIPTOR_REPLAY),
        .PIPELINED_DECODER_VALIDATION(PIPELINED_DECODER_VALIDATION),
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
    ) u_cnn (
        .view_commit_valid(adapter_view_valid),.view_commit_ready(adapter_view_ready),
        .view_commit_stage(adapter_view_stage),.view_commit_generation(adapter_view_generation),
        .clk(clk),
        .rst(rst),
        .abort(abort),
        .start_valid(cnn_start_valid),
        .start_ready(cnn_start_ready),
        .stage_count(start_stage_count_q),
        .config_generation(start_config_generation_q),
        .parameter_active_valid(start_parameter_active_valid_q),
        .parameter_generation(start_parameter_generation_q),
        .busy(cnn_busy),
        .done(cnn_done),
        .aborted(cnn_aborted),
        .error(cnn_error),
        .error_code(cnn_error_code),
        .stage_config_valid(cnn_stage_config_valid),
        .stage_config_ready(cnn_stage_config_ready),
        .stage_config_index(descriptor_hold_index_q),
        .stage_config_descriptor(descriptor_hold_data_q),
        .stage_config_generation(descriptor_hold_generation_q),
        .param_rd_en(param_rd_en),
        .param_rd_addr(param_rd_addr),
        .param_rd_valid(param_rd_valid),
        .param_rd_error(param_rd_error),
        .param_rd_data(param_rd_data),
        .in_valid(adapter_engine_valid),
        .in_ready(adapter_engine_ready),
        .in_window_s8(adapter_engine_window_s8),
        .in_residual_s8(adapter_engine_residual_s8),
        .in_group_index(adapter_engine_group_index),
        .in_group_last(adapter_engine_group_last),
        .in_x(adapter_engine_x),
        .in_y(adapter_engine_y),
        .in_sof(adapter_engine_sof),
        .in_eol(adapter_engine_eol),
        .in_eof(adapter_engine_eof),
        .out_valid(cnn_result_valid),
        .out_ready(cnn_result_ready),
        .out_data_s8(cnn_result_data_s8),
        .out_group_index(cnn_result_group_index),
        .out_group_last(cnn_result_group_last),
        .out_x(cnn_result_x),
        .out_y(cnn_result_y),
        .out_sof(cnn_result_sof),
        .out_eol(cnn_result_eol),
        .out_eof(cnn_result_eof),
        .stage_index(engine_stage_index),
        .stage_opcode(engine_stage_opcode),
        .stage_active(engine_stage_active),
        .adapter_required(engine_adapter_required),
        .stage_done(engine_stage_done),
        .overflow_seen(engine_overflow_seen),
        .config_capture_complete(cnn_config_complete_pulse)
    );

endmodule
