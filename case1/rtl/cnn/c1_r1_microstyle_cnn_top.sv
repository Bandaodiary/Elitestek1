`timescale 1ns/1ps

// Dispatcher-compatible MicroStyle CNN runtime top.
//
// c1_r1_config_dispatcher sends all 22 descriptors before the boardless top
// releases the first C8 pixel.  The arithmetic engine, however, consumes one
// descriptor per executed stage.  This wrapper is the explicit bridge: it
// atomically captures the complete ordered configuration snapshot, launches
// c1_r1_microstyle_engine only after the final descriptor handshake, and then
// replays the cached descriptors as each stage becomes ready.  Consequently
// the existing pre-frame configuration barrier cannot deadlock against a
// stage-by-stage compute engine.
//
// Tensor ports retain the prepared-output-site contract documented by
// c1_r1_microstyle_engine.  A separate inter-stage tensor adapter is still
// responsible for 3x3 windows, stride/padding, upsample expansion and feature
// storage; this wrapper resolves control/config ordering, not tensor storage.
module c1_r1_microstyle_cnn_top #(
    parameter integer REQUIRED_STAGES = 22,
    parameter integer PARAM_ADDR_W = 11,
    parameter integer PARAM_ARENA_BYTES = 16896,
    parameter integer MAX_CHANNELS = 48,
    parameter integer MAX_WEIGHT_BYTES = 2592,
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    // Optional registered descriptor replay.  The default keeps the legacy
    // asynchronous cache read/decoder contract; the experimental branch
    // inserts one prefetch register but still presents one descriptor per
    // cycle after the initial fill.
    parameter integer PIPELINED_DESCRIPTOR_REPLAY = 0,
    // Optional capture-time validation.  Only a five-bit error result is
    // cached per stage; the 512-bit descriptor itself is not duplicated.
    parameter integer PREVALIDATE_DESCRIPTOR_REPLAY = 0,
    // Optional two-cycle validation schedule in the replay-side command
    // decoder.  Default zero preserves the direct decoder contract.
    parameter integer PIPELINED_DECODER_VALIDATION = 0,
    // Optional per-output-group depthwise weight tile cache.  Default zero
    // preserves the legacy nine-cycle prefetch contract.
    parameter integer CACHE_DW_WEIGHT_TILES = 0,
    // Optional steady-state Conv/1x1 tile prefetch overlap.  The first tile
    // still pays the registered prefetch boundary; subsequent tiles can be
    // captured on the input handshake.  Default zero preserves the legacy
    // cycle contract.
    parameter integer MAC_PREFETCH_OVERLAP = 0,
    // Efinity-compatible affine-cache storage form.  Zero keeps the
    // historical unpacked arrays; one uses packed words with guarded
    // variable part-selects.  The latter is useful for Ti60 front-end
    // elaboration at MAX_CHANNELS > 8 and is intentionally opt-in until the
    // full board image selects it.
    parameter integer PACKED_AFFINE_CACHE = 0,
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

    input  logic                       in_valid,
    output logic                       in_ready,
    input  logic [575:0]               in_window_s8,
    input  logic [63:0]                in_residual_s8,
    input  logic [2:0]                 in_group_index,
    input  logic                       in_group_last,
    input  logic [15:0]                in_x,
    input  logic [15:0]                in_y,
    input  logic                       in_sof,
    input  logic                       in_eol,
    input  logic                       in_eof,

    output logic                       out_valid,
    input  logic                       out_ready,
    output logic [63:0]                out_data_s8,
    output logic [2:0]                 out_group_index,
    output logic                       out_group_last,
    output logic [15:0]                out_x,
    output logic [15:0]                out_y,
    output logic                       out_sof,
    output logic                       out_eol,
    output logic                       out_eof,

    output logic [4:0]                 stage_index,
    output logic [7:0]                 stage_opcode,
    output logic                       stage_active,
    output logic                       adapter_required,
    output logic                       stage_done,
    output logic                       overflow_seen,
    output logic                       config_capture_complete,
    input  logic                       view_commit_valid,
    output logic                       view_commit_ready,
    input  logic [4:0]                 view_commit_stage,
    input  logic [7:0]                 view_commit_generation
);

    import c1_descriptor_decoder_pkg::*;

    localparam logic [7:0] ERR_COUNT      = 8'he0;
    localparam logic [7:0] ERR_CFG_INDEX  = 8'he1;
    localparam logic [7:0] ERR_CFG_GEN    = 8'he2;
    localparam logic [7:0] ERR_PARAM_GEN  = 8'he3;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CAPTURE,
        ST_LAUNCH,
        ST_RUN,
        ST_ERROR
    } wrapper_state_t;

    wrapper_state_t state_q;
    logic [511:0] descriptor_cache [0:REQUIRED_STAGES-1];
    logic [4:0] descriptor_error_cache [0:REQUIRED_STAGES-1];
    logic [15:0] expected_capture_index_q;
    logic [4:0] replay_index_q;
    logic [15:0] stage_count_q;
    logic [7:0] config_generation_q;
    logic [31:0] parameter_generation_q;
    logic error_q;

    logic engine_job_start_valid;
    logic engine_job_start_ready;
    logic engine_busy, engine_done, engine_aborted;
    logic engine_error;
    logic [7:0] engine_error_code;
    logic engine_stage_config_valid;
    logic engine_stage_config_ready;
    logic engine_abort;
    logic [511:0] replay_descriptor;
    logic [511:0] replay_descriptor_q;
    logic [4:0] replay_descriptor_error;
    logic [4:0] replay_descriptor_error_q;
    logic replay_valid_q;
    logic capture_fire;
    logic replay_fire;
    logic live_generation_fault;

    always_comb begin
        start_ready = (state_q == ST_IDLE) && engine_job_start_ready;
        stage_config_ready = (state_q == ST_CAPTURE);
        capture_fire = stage_config_valid && stage_config_ready;

        engine_job_start_valid = (state_q == ST_LAUNCH);
        if (PIPELINED_DESCRIPTOR_REPLAY != 0) begin
            engine_stage_config_valid = (state_q == ST_RUN) &&
                                        replay_valid_q;
            replay_descriptor = replay_descriptor_q;
            replay_descriptor_error = replay_descriptor_error_q;
        end else begin
            engine_stage_config_valid = (state_q == ST_RUN) &&
                                        (replay_index_q < REQUIRED_STAGES);
            replay_descriptor = 512'd0;
            if (replay_index_q < REQUIRED_STAGES)
                replay_descriptor = descriptor_cache[replay_index_q];
            replay_descriptor_error = 5'd0;
            if ((PREVALIDATE_DESCRIPTOR_REPLAY != 0) &&
                (replay_index_q < REQUIRED_STAGES))
                replay_descriptor_error =
                    descriptor_error_cache[replay_index_q];
        end
        replay_fire = engine_stage_config_valid &&
                      engine_stage_config_ready;
        engine_abort = abort || (state_q == ST_ERROR);

        live_generation_fault = (state_q != ST_IDLE) &&
            (state_q != ST_ERROR) &&
            ((config_generation != config_generation_q) ||
             !parameter_active_valid ||
             (parameter_generation != parameter_generation_q));

        busy = (state_q == ST_CAPTURE) || (state_q == ST_LAUNCH) ||
               (state_q == ST_RUN);
        error = error_q;
    end

    c1_r1_microstyle_engine #(
        .REQUIRED_STAGES(REQUIRED_STAGES),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .PARAM_ARENA_BYTES(PARAM_ARENA_BYTES),
        .MAX_CHANNELS(MAX_CHANNELS),
        .MAX_WEIGHT_BYTES(MAX_WEIGHT_BYTES),
        .ENFORCE_MICROSTYLE_TOPOLOGY(1'b1),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
        .PREVALIDATE_DESCRIPTOR_REPLAY(PREVALIDATE_DESCRIPTOR_REPLAY),
        .PIPELINED_DECODER_VALIDATION(PIPELINED_DECODER_VALIDATION),
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
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
    ) u_engine (
        .view_commit_valid,.view_commit_ready,.view_commit_stage,.view_commit_generation,
        .clk,
        .rst,
        .abort(engine_abort),
        .job_start_valid(engine_job_start_valid),
        .job_start_ready(engine_job_start_ready),
        .job_stage_count(stage_count_q),
        .config_generation,
        .parameter_active_valid,
        .parameter_generation,
        .busy(engine_busy),
        .done(engine_done),
        .aborted(engine_aborted),
        .error(engine_error),
        .error_code(engine_error_code),
        .stage_config_valid(engine_stage_config_valid),
        .stage_config_ready(engine_stage_config_ready),
        .stage_config_descriptor(replay_descriptor),
        .stage_config_error(replay_descriptor_error),
        .stage_config_generation(config_generation_q),
        .param_rd_en,
        .param_rd_addr,
        .param_rd_valid,
        .param_rd_error,
        .param_rd_data,
        .in_valid,
        .in_ready,
        .in_window_s8,
        .in_residual_s8,
        .in_group_index,
        .in_group_last,
        .in_x,
        .in_y,
        .in_sof,
        .in_eol,
        .in_eof,
        .out_valid,
        .out_ready,
        .out_data_s8,
        .out_group_index,
        .out_group_last,
        .out_x,
        .out_y,
        .out_sof,
        .out_eol,
        .out_eof,
        .stage_index,
        .stage_opcode,
        .stage_active,
        .adapter_required,
        .stage_done,
        .overflow_seen
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            expected_capture_index_q <= 16'd0;
            replay_index_q <= 5'd0;
            replay_descriptor_q <= 512'd0;
            replay_descriptor_error_q <= 5'd0;
            replay_valid_q <= 1'b0;
            stage_count_q <= 16'd0;
            config_generation_q <= 8'd0;
            parameter_generation_q <= 32'd0;
            error_q <= 1'b0;
            error_code <= 8'd0;
            done <= 1'b0;
            aborted <= 1'b0;
            config_capture_complete <= 1'b0;
        end else if (abort) begin
            aborted <= busy || (state_q == ST_ERROR);
            state_q <= ST_IDLE;
            expected_capture_index_q <= 16'd0;
            replay_index_q <= 5'd0;
            replay_descriptor_q <= 512'd0;
            replay_descriptor_error_q <= 5'd0;
            replay_valid_q <= 1'b0;
            error_q <= 1'b0;
            error_code <= 8'd0;
            done <= 1'b0;
            config_capture_complete <= 1'b0;
        end else begin
            done <= 1'b0;
            aborted <= 1'b0;
            config_capture_complete <= 1'b0;

            if (live_generation_fault) begin
                error_q <= 1'b1;
                if (config_generation != config_generation_q)
                    error_code <= ERR_CFG_GEN;
                else
                    error_code <= ERR_PARAM_GEN;
                state_q <= ST_ERROR;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_valid && start_ready) begin
                            error_q <= 1'b0;
                            error_code <= 8'd0;
                            if ((stage_count != REQUIRED_STAGES) ||
                                !parameter_active_valid) begin
                                error_q <= 1'b1;
                                error_code <= ERR_COUNT;
                                state_q <= ST_ERROR;
                            end else begin
                                stage_count_q <= stage_count;
                                config_generation_q <= config_generation;
                                parameter_generation_q <=
                                    parameter_generation;
                                expected_capture_index_q <= 16'd0;
                                state_q <= ST_CAPTURE;
                            end
                        end
                    end

                    ST_CAPTURE: begin
                        if (capture_fire) begin
                            if (stage_config_generation !=
                                config_generation_q) begin
                                error_q <= 1'b1;
                                error_code <= ERR_CFG_GEN;
                                state_q <= ST_ERROR;
                            end else if (stage_config_index !=
                                         expected_capture_index_q) begin
                                error_q <= 1'b1;
                                error_code <= ERR_CFG_INDEX;
                                state_q <= ST_ERROR;
                            end else begin
                                descriptor_cache[stage_config_index[4:0]] <=
                                    stage_config_descriptor;
                                if (PREVALIDATE_DESCRIPTOR_REPLAY != 0)
                                    descriptor_error_cache[
                                        stage_config_index[4:0]] <=
                                        c1_validate_descriptor(
                                            stage_config_descriptor);
                                if (expected_capture_index_q ==
                                    REQUIRED_STAGES - 1) begin
                                    replay_index_q <= 5'd0;
                                    replay_valid_q <= 1'b0;
                                    config_capture_complete <= 1'b1;
                                    state_q <= ST_LAUNCH;
                                end else begin
                                    expected_capture_index_q <=
                                        expected_capture_index_q + 1'b1;
                                end
                            end
                        end
                    end

                    ST_LAUNCH: begin
                        if (engine_job_start_ready) begin
                            if (PIPELINED_DESCRIPTOR_REPLAY != 0) begin
                                // The final capture write completed on the
                                // previous edge, so descriptor zero is now
                                // safe to sample into the replay register.
                                replay_descriptor_q <= descriptor_cache[0];
                                if (PREVALIDATE_DESCRIPTOR_REPLAY != 0)
                                    replay_descriptor_error_q <=
                                        descriptor_error_cache[0];
                                replay_valid_q <= 1'b1;
                            end
                            state_q <= ST_RUN;
                        end
                    end

                    ST_RUN: begin
                        if (replay_fire) begin
                            if (PIPELINED_DESCRIPTOR_REPLAY != 0) begin
                                if (replay_index_q == REQUIRED_STAGES - 1) begin
                                    replay_valid_q <= 1'b0;
                                end else begin
                                    replay_index_q <= replay_index_q + 1'b1;
                                    // Prefetch the next descriptor while the
                                    // current one is being accepted.  The
                                    // register boundary removes the RAM read
                                    // from the decoder's same-cycle path and
                                    // preserves one descriptor/clock after
                                    // the initial fill.
                                    replay_descriptor_q <= descriptor_cache[
                                        replay_index_q + 1'b1];
                                    if (PREVALIDATE_DESCRIPTOR_REPLAY != 0)
                                        replay_descriptor_error_q <=
                                            descriptor_error_cache[
                                                replay_index_q + 1'b1];
                                    replay_valid_q <= 1'b1;
                                end
                            end else begin
                                replay_index_q <= replay_index_q + 1'b1;
                            end
                        end
                        if (engine_error) begin
                            error_q <= 1'b1;
                            error_code <= engine_error_code;
                            state_q <= ST_ERROR;
                        end else if (engine_done) begin
                            done <= 1'b1;
                            state_q <= ST_IDLE;
                        end
                    end

                    default: state_q <= ST_ERROR;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (REQUIRED_STAGES != 22)
            $fatal(1, "dispatcher-compatible MicroStyle top requires 22 stages");
    end

    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (engine_job_start_valid && !engine_job_start_ready)
                $fatal(1, "wrapper launch state lost engine readiness");
            if (replay_fire && (replay_index_q >= REQUIRED_STAGES))
                $fatal(1, "wrapper replay index overflow");
            if (out_valid && (state_q != ST_RUN))
                $fatal(1, "wrapper output escaped outside run state");
        end
    end
`endif

endmodule
