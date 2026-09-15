`timescale 1ns/1ps

// Board-independent MicroStyle-24 C8 stage engine.
//
// This module closes the former "opaque CNN" control/compute seam at the
// descriptor, parameter and C8 arithmetic boundaries.  A job consumes exactly
// REQUIRED_STAGES validated ABI descriptors.  Convolution parameters are read
// from the active 128-bit parameter arena into a layer-local cache, then real
// signed-int8 OIHW convolution/depthwise arithmetic and affine requantization
// are performed by the existing bit-exact C8 cores.  Linear ABI weights are
// repacked once per stage into lane-banked tiles.  A dot beat therefore reads
// 64 small fixed banks at one sequential tile address instead of building 64
// independent random muxes over the complete 2592-byte cache.
//
// Tensor-adapter contract
// -----------------------
// The engine is intentionally independent of a DDR/inter-stage tensor fabric.
// For each *output spatial site*, the adapter presents one beat per input C8
// group.  in_window_s8 is tap-major (9 C8 taps) and coordinates are already in
// output-stage raster order.  Thus a 1x1 stage uses tap 4, a 3x3 stage consumes
// all taps, and stride/padding/window construction remains in the adapter.
// UPSAMPLE2 is likewise presented after nearest-neighbour expansion.  This
// makes the arithmetic engine usable with either a dedicated streaming graph
// or a DDR ping-pong tensor adapter without baking either storage policy into
// the compute block.  adapter_required is asserted for every active stage and
// is especially significant for CONV3X3/UPSAMPLE2.
//
// Packed conventions match the rest of R1: channel/group zero is least
// significant; weight cache is signed-int8 OIHW; bias and multiplier entries
// are signed32 little-endian (multipliers must sign-extend signed18); shift is
// u8 in 0..47.  Output padding lanes are forced to zero.
module c1_r1_microstyle_engine #(
    parameter integer REQUIRED_STAGES = 22,
    parameter integer PARAM_ADDR_W = 11,
    parameter integer PARAM_ARENA_BYTES = 16896,
    parameter integer MAX_CHANNELS = 48,
    parameter integer MAX_WEIGHT_BYTES = 2592,
    // For MAX_CHANNELS=48/MAX_WEIGHT_BYTES=2592, every scheduler-legal
    // convolution requires at most 72 padded C8xC8xTap tiles.
    parameter integer MAX_PACKED_WEIGHT_TILES = 72,
    parameter bit ENFORCE_MICROSTYLE_TOPOLOGY = 1'b1,
    // Optional one-stage dot-product reduction pipeline.  Default zero keeps
    // the legacy arithmetic latency and cycle contract unchanged.
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    // Optional capture-time descriptor validation.  The wrapper supplies a
    // cached five-bit result during replay, removing the wide validator from
    // the descriptor-cache-to-error path.
    parameter integer PREVALIDATE_DESCRIPTOR_REPLAY = 0,
    // Optional two-cycle validation schedule inside the replay-side
    // layer-command decoder.  The default keeps the direct descriptor-to-
    // command timing and cycle contract.  When enabled, the decoder first
    // captures the 512-bit record and then publishes a command or error from
    // a compact registered result.  This is separate from the tensor-adapter
    // checker and targets only the replay-side decoder cone.
    parameter integer PIPELINED_DECODER_VALIDATION = 0,
    // Optional per-output-group DW weight tile cache.  The default preserves
    // the original nine-cycle prefetch for every pixel; when enabled, each
    // group is prefetched once per stage and replayed from a compact tile RAM
    // on subsequent pixels.
    parameter integer CACHE_DW_WEIGHT_TILES = 0,
    // Optional steady-state overlap for the convolution/pointwise input
    // tile path.  The first tile still uses ST_MAC_PREFETCH; after an input
    // beat is accepted, the next activation/weight tile is captured in the
    // same clock edge and ST_MAC_FEED is kept asserted.  This removes the
    // legacy one-cycle PREFETCH bubble between tiles while preserving the
    // ready/valid hold contract (the registers only change on input_fire).
    // Default zero keeps the original cycle/latency contract unchanged.
    parameter integer MAC_PREFETCH_OVERLAP = 0,
    // Diagnostic-only override for Efinity front-end bisection.  Zero keeps
    // the architectural group count derived from MAX_CHANNELS.  A positive
    // value is never used by the production top; it lets a boardless probe
    // hold the channel count constant while varying the depth of group-indexed
    // memories, isolating tool elaboration issues without changing protocols.
    parameter integer MAX_GROUPS_OVERRIDE = 0,
    // Diagnostic-only affine-cache extent override.  It is useful for
    // separating Efinity's parameterized channel-array handling from the
    // scheduler's channel geometry.  Zero preserves MAX_CHANNELS exactly.
    parameter integer AFFINE_CACHE_DEPTH_OVERRIDE = 0,
    // Optional packed representation for the small affine metadata caches.
    // This is a boardless compatibility knob: packed slices avoid the
    // Efinity 2026.1 database failure seen with dynamic unpacked indices at
    // channel counts above one C8 group.  Zero preserves the historical
    // unpacked arrays; no production top enables this until A/B gates pass.
    parameter integer PACKED_AFFINE_CACHE = 0,
    // Stream all warm-cached DW output groups of ONE pixel through the same
    // core. No extra multipliers or cross-pixel/stage overlap. Requires tile
    // caching; cold pixels retain the original nine-tap population schedule.
    parameter bit STREAM_DW_GROUPS = 1'b0,
    // For 1x1 convolutions, accumulate output group 0 as input groups arrive.
    // Later output groups reuse the already collected window cache normally.
    // No extra MAC, window bank or external handshake is introduced.
    parameter bit STREAM_POINTWISE_REDUCTION = 1'b0,
    parameter bit OVERLAP_MAC_REQUANTIZATION = 1'b0,
    parameter bit PIPELINE_DOT_PIXELS = 1'b0,
    parameter bit PIPELINE_DW_PIXELS = 1'b0,
    // Reuse the existing per-beat-config DW pipeline across warm pixels.
    // The cold first pixel still populates/fences the weight cache normally.
    parameter bit STREAM_DW_FRAME = 1'b0,
    // Extend the existing dot pixel pipeline beyond one output C8 group.
    // The next window may overwrite the old one only after the last group's
    // last reduction feed. Retirement keeps its own modulo-group cursor.
    parameter bit PIPELINE_ALL_DOT_GROUPS = 1'b0,
    // Pack the 27 RGB 3x3 products into four C8 reduction beats. The OIHW
    // parameter ABI and tap-major input window remain unchanged. No extra
    // multipliers, weight banks, or window banks are introduced.
    parameter bit PACK_RGB_CONV_REDUCTION = 1'b0,
    // An explicit metadata handshake commits the two fixed-graph nearest-
    // neighbour views. No dummy input or fabricated output C8 is transferred.
    parameter bit ELIDE_VIRTUAL_UPSAMPLE = 1'b0,
    // Stage 21 is an identity C8 view of the final convolution. The adapter
    // holds its real final pixel until this validated metadata commit finishes.
    parameter bit FUSE_FINAL_OUTPUT = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       abort,

    input  logic                       job_start_valid,
    output logic                       job_start_ready,
    input  logic [15:0]                job_stage_count,
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
    input  logic [511:0]               stage_config_descriptor,
    input  logic [4:0]                 stage_config_error,
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
    input  logic                       view_commit_valid,
    output logic                       view_commit_ready,
    input  logic [4:0]                 view_commit_stage,
    input  logic [7:0]                 view_commit_generation
);

    localparam logic [7:0] OP_CONV3X3      = 8'd1;
    localparam logic [7:0] OP_CONV1X1      = 8'd2;
    localparam logic [7:0] OP_DWCONV3X3    = 8'd3;
    localparam logic [7:0] OP_UPSAMPLE2    = 8'd4;
    localparam logic [7:0] OP_RESIDUAL_ADD = 8'd5;
    localparam logic [7:0] OP_OUTPUT_RGB   = 8'd6;
    localparam logic [1:0] ACT_NONE = 2'd0;
    localparam logic [1:0] ACT_RELU = 2'd1;

    localparam logic [7:0] ERR_NONE              = 8'h00;
    localparam logic [7:0] ERR_JOB_CONFIG        = 8'h01;
    localparam logic [7:0] ERR_TOPOLOGY          = 8'h02;
    localparam logic [7:0] ERR_CONFIG_GENERATION = 8'h03;
    localparam logic [7:0] ERR_PARAM_GENERATION  = 8'h04;
    localparam logic [7:0] ERR_PARAM_SCHEDULER   = 8'h50;
    localparam logic [7:0] ERR_AFFINE_FORMAT     = 8'h06;
    localparam logic [7:0] ERR_INPUT_PROTOCOL    = 8'h07;
    localparam logic [7:0] ERR_CYCLE_BUDGET      = 8'h08;
    localparam logic [7:0] ERR_WEIGHT_LAYOUT     = 8'h09;
    localparam logic [7:0] ERR_DESCRIPTOR_BASE   = 8'h80;

    localparam logic [1:0] REGION_WEIGHT = 2'd0;
    localparam logic [1:0] REGION_BIAS   = 2'd1;
    localparam logic [1:0] REGION_MULT   = 2'd2;
    localparam logic [1:0] REGION_SHIFT  = 2'd3;
    localparam integer MAX_GROUPS =
        (MAX_GROUPS_OVERRIDE > 0) ? MAX_GROUPS_OVERRIDE :
        ((MAX_CHANNELS + 7) / 8);
    localparam integer AFFINE_CACHE_DEPTH =
        (AFFINE_CACHE_DEPTH_OVERRIDE > 0) ? AFFINE_CACHE_DEPTH_OVERRIDE :
        MAX_CHANNELS;
    localparam integer WEIGHT_WORDS = (MAX_WEIGHT_BYTES + 15) / 16;
    localparam integer CONV_TILE_ADDR_W =
        (MAX_PACKED_WEIGHT_TILES <= 2) ? 1 :
        $clog2(MAX_PACKED_WEIGHT_TILES);
    localparam integer DW_WEIGHT_DEPTH = MAX_GROUPS * 9;
    localparam integer DW_WEIGHT_ADDR_W =
        (DW_WEIGHT_DEPTH <= 2) ? 1 : $clog2(DW_WEIGHT_DEPTH);

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_WAIT_CONFIG,
        ST_PARAM_START,
        ST_PARAM_WAIT,
        ST_WEIGHT_LAYOUT,
        ST_WEIGHT_READ,
        ST_WEIGHT_REPACK,
        ST_PARAM_VALIDATE,
        ST_COLLECT,
        ST_MAC_START,
        ST_MAC_PREFETCH,
        ST_MAC_FEED,
        ST_MAC_OUT,
        ST_DW_PREFETCH,
        ST_DW_START,
        ST_DW_FEED,
        ST_DW_OUT,
        ST_BYPASS_OUT,
        ST_ERROR,
        ST_DW_STREAM
    } state_t;

    state_t state_q;
    logic job_busy_q;
    logic error_q;
    logic [7:0] config_generation_q;
    logic [31:0] parameter_generation_q;
    logic [7:0] pending_stage_generation_q;
    logic [4:0] stage_index_q;

    logic [7:0] opcode_q;
    logic [1:0] activation_q;
    logic [5:0] flags_q;
    logic [15:0] input_width_q, input_height_q;
    logic [15:0] output_width_q, output_height_q;
    logic [15:0] input_channels_q, output_channels_q;
    logic [31:0] weight_offset_q, bias_offset_q;
    logic [31:0] multiplier_offset_q, shift_offset_q;
    logic [31:0] cycle_budget_q;
    logic [31:0] stage_cycle_q;
    logic [3:0] input_groups_q, output_groups_q;
    logic [7:0] input_tail_mask_q, output_tail_mask_q;
    logic previous_output_valid_q;
    logic [15:0] previous_output_width_q, previous_output_height_q;
    logic [15:0] previous_output_channels_q;

    // The scheduler writes the original 128-bit ABI words here.  A sequential
    // OIHW walker then transposes them into independently addressed lane banks.
    (* ram_style = "block" *)
    logic [127:0] weight_word_cache [0:WEIGHT_WORDS-1];
    (* ram_style = "distributed" *)
    logic [7:0] conv_weight_bank
                [0:63][0:MAX_PACKED_WEIGHT_TILES-1];
    (* ram_style = "distributed" *)
    logic [7:0] dw_weight_bank
                [0:7][0:DW_WEIGHT_DEPTH-1];
    logic [31:0] bias_cache [0:AFFINE_CACHE_DEPTH-1];
    logic [31:0] multiplier_cache [0:AFFINE_CACHE_DEPTH-1];
    logic [7:0] shift_cache [0:AFFINE_CACHE_DEPTH-1];
    logic [AFFINE_CACHE_DEPTH*32-1:0] bias_cache_packed;
    logic [AFFINE_CACHE_DEPTH*32-1:0] multiplier_cache_packed;
    logic [AFFINE_CACHE_DEPTH*8-1:0] shift_cache_packed;
    logic [575:0] window_cache [0:MAX_GROUPS-1];
    logic [63:0] residual_cache [0:MAX_GROUPS-1];

    logic [2:0] expected_input_group_q;
    logic [15:0] expected_x_q, expected_y_q;
    logic [15:0] meta_x_q, meta_y_q;
    logic meta_sof_q, meta_eol_q, meta_eof_q;
    logic [2:0] output_group_q;
    logic [2:0] reduction_group_q;
    logic [3:0] tap_q;
    logic [15:0] repack_linear_index_q;
    logic [3:0] repack_byte_lane_q;
    logic [127:0] repack_word_q;
    logic [15:0] repack_output_channel_q;
    logic [15:0] repack_input_channel_q;
    logic [3:0] repack_tap_q;
    logic [15:0] repack_last_linear_q;
    logic [15:0] repack_last_input_channel_q;
    logic [3:0] repack_last_tap_q;
    logic weight_layout_valid_q;
    logic affine_invalid_q;
    logic affine_word_invalid_q;
    logic affine_word_invalid_comb;
    logic [CONV_TILE_ADDR_W-1:0] conv_tile_read_addr_q;
    logic [3:0] dw_prefetch_tap_q;
    logic [63:0] dot_activation_tile_q;
    logic [7:0] dot_lane_mask_tile_q;
    logic dot_last_tile_q;
    logic [511:0] dot_weight_tile_q;
    logic [575:0] dw_weight_tile_q;
    // One complete 8-lane x 9-tap tile per output group.  Store it as nine
    // tap-major 64-bit words rather than one 576-bit vector.  The previous
    // byte-sliced vector required a variable part-select write for every
    // lane/tap and Vivado implemented most of the cache as LUT/FF muxing.
    // Each tap bank now receives one full-word write per prefetch cycle;
    // cache-hit reads are transposed back to the lane-major layout expected
    // by c1_dwconv3x3_c8_requant_core.  The attribute is only a hint: Efinity
    // may choose EBR or distributed RAM based on the target geometry.
    (* ram_style = "distributed" *)
    logic [63:0] dw_group_tile_mem
                [0:8][0:MAX_GROUPS-1];
    logic [MAX_GROUPS-1:0] dw_group_tile_valid_q;

    // Cache read lookup is selected for the two hit sites (the first group
    // after ST_COLLECT, or the next group after ST_DW_OUT).  A static bit
    // permutation restores the lane-major tile bus without arithmetic muxes;
    // only the small group-index read mux remains in each tap bank.
    logic [2:0] dw_cache_lookup_group_comb;
    logic [575:0] dw_cache_lookup_tile_comb;
    logic dw_stream_q, dw_feed_done_q;
    logic pointwise_stream_q;
    logic [2:0] dot_retire_group_q;
    logic [2:0] dw_retire_group_q;
    wire pixel_dw_mode = PIPELINE_DW_PIXELS && opcode_q==OP_DWCONV3X3;
    wire dw_result_state = state_q==ST_COLLECT || state_q==ST_DW_PREFETCH ||
        state_q==ST_DW_START || state_q==ST_DW_FEED || state_q==ST_DW_OUT || state_q==ST_DW_STREAM;
    logic dot_issue_done_q;
    wire dot_schedule_state = state_q==ST_MAC_START || state_q==ST_MAC_PREFETCH ||
                              state_q==ST_MAC_FEED || state_q==ST_MAC_OUT;
    wire pixel_dot_mode = PIPELINE_DOT_PIXELS && (output_groups_q==1 || PIPELINE_ALL_DOT_GROUPS) &&
        (opcode_q==OP_CONV1X1 || opcode_q==OP_CONV3X3);
    wire dot_result_state = dot_schedule_state || (pixel_dot_mode && state_q==ST_COLLECT);
    logic [2:0] dw_feed_group_q;
    logic dw_all_tiles_valid;
    logic [575:0] dw_stream_window_q;
    logic [255:0] dw_stream_bias_q;
    logic [207:0] dw_stream_affine_q;
    wire [2:0] dw_next_input_group = (dw_feed_group_q==output_groups_q-1'b1) ?
        dw_feed_group_q : dw_feed_group_q+3'd1;
    logic [63:0] dw_cache_write_word_comb;
    integer cache_tile_lane, cache_tile_tap, cache_write_lane;

    logic [3:0] mac_next_reduction_group;
    logic [3:0] mac_next_tap;
    logic [CONV_TILE_ADDR_W-1:0] mac_next_tile_addr;
    logic mac_next_last_tile;

    logic decoder_descriptor_ready;
    logic decoder_command_valid;
    logic decoder_command_ready;
    logic [511:0] decoder_command_descriptor;
    logic decoder_error_pulse;
    logic [4:0] decoder_error_code;
    logic raw_descriptor_fire;
    logic decoded_descriptor_fire;

    logic parameter_start_valid, parameter_start_ready;
    logic parameter_scheduler_busy;
    logic parameter_scheduler_done;
    logic parameter_scheduler_error;
    logic [3:0] parameter_scheduler_error_code;
    logic cache_write_valid;
    logic [1:0] cache_write_region;
    logic [15:0] cache_write_word_index;
    logic [4:0] cache_write_byte_count;
    logic [127:0] cache_write_data;
    logic [3:0] scheduler_input_groups, scheduler_output_groups;
    logic [7:0] scheduler_input_mask, scheduler_output_mask;
    logic [3:0] scheduler_taps;
    wire pack_rgb_conv_mode = PACK_RGB_CONV_REDUCTION &&
                             opcode_q == OP_CONV3X3 && input_channels_q == 3;
    // The parameter scheduler/repacker still traverses nine physical taps.
    // Only the compute-side reduction cursor uses the packed four-beat form.
    wire [3:0] dot_reduction_taps = pack_rgb_conv_mode ? 4'd4 : scheduler_taps;
    wire view_layer = (ELIDE_VIRTUAL_UPSAMPLE && opcode_q==OP_UPSAMPLE2 &&
        (stage_index_q==14 || stage_index_q==17)) ||
        (FUSE_FINAL_OUTPUT && opcode_q==OP_OUTPUT_RGB && stage_index_q==21);
    logic [15:0] scheduler_weight_bytes;

    logic topology_valid;
    logic continuity_valid;
    logic weight_layout_valid;
    logic generation_changed;
    logic input_protocol_valid;
    logic expected_group_last;
    logic expected_sof, expected_eol, expected_eof;
    logic final_output_group;
    logic out_fire;
    logic core_rst;

    logic dot_start_valid, dot_start_ready;
    logic [255:0] dot_start_bias;
    logic [143:0] dot_start_mult;
    logic [47:0] dot_start_shift;
    logic dot_start_relu;
    logic dot_in_valid, dot_in_ready, dot_in_last;
    logic [7:0] dot_in_lane_mask;
    logic [63:0] dot_in_activations;
    logic [511:0] dot_in_weights;
    logic dot_out_valid, dot_out_ready;
    logic [63:0] dot_out_data;
    logic dot_out_sof, dot_out_eol, dot_out_eof;
    logic [15:0] dot_out_x, dot_out_y;
    logic dot_busy, dot_overflow;

    logic dw_start_valid, dw_start_ready;
    logic [575:0] dw_start_weights;
    logic [255:0] dw_start_bias;
    logic [143:0] dw_start_mult;
    logic [47:0] dw_start_shift;
    logic [15:0] dw_start_activation;
    logic dw_in_valid, dw_in_ready;
    logic dw_out_valid, dw_out_ready;
    logic [63:0] dw_out_data;
    logic [15:0] dw_out_x,dw_out_y;
    logic dw_busy, dw_done, dw_overflow;
    wire dw_frame_continue = STREAM_DW_FRAME && pixel_dw_mode &&
                             dw_stream_q && dw_busy;

    logic [63:0] masked_dot_data, masked_dw_data;
    logic [63:0] bypass_data;
    logic [7:0] current_output_mask;
    integer cache_byte_lane;
    integer cache_entry_lane;
    integer affine_check_lane;
    integer affine_lane;
    integer global_output_comb;
    integer bypass_lane;
    integer prefetch_output_lane, prefetch_input_lane;
    integer prefetch_dw_lane;

    logic repack_conv_write;
    logic repack_dw_write;
    logic [5:0] repack_bank_comb;
    logic [CONV_TILE_ADDR_W-1:0] repack_conv_addr_comb;
    logic [DW_WEIGHT_ADDR_W-1:0] repack_dw_addr_comb;
    logic [7:0] repack_byte_comb;
    logic [4:0] repack_rgb_index;

    function automatic logic [63:0] rgb_reduction_tile(
        input logic [575:0] window_value, input logic [1:0] beat
    );
        logic [255:0] words;
        integer product_index;
        begin
            words = '0;
            // Constant-index wiring, followed by a four-way word mux. The
            // divide/modulo operands are elaboration-time loop constants.
            for (product_index = 0; product_index < 27; product_index = product_index + 1)
                words[product_index*8 +: 8] =
                    window_value[(product_index/3)*64 + (product_index%3)*8 +: 8];
            rgb_reduction_tile = words[beat*64 +: 64];
        end
    endfunction

    function automatic logic [7:0] tail_mask(
        input logic [15:0] channels
    );
        logic [3:0] remainder;
        begin
            remainder = channels[3:0] & 4'h7;
            if (remainder == 0)
                tail_mask = 8'hff;
            else
                tail_mask = (8'h01 << remainder) - 1'b1;
        end
    endfunction

    function automatic logic [7:0] expected_opcode(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0, 5'd1, 5'd20: expected_opcode = OP_CONV3X3;
                5'd2, 5'd4, 5'd6, 5'd8, 5'd10, 5'd12,
                5'd16, 5'd19: expected_opcode = OP_CONV1X1;
                5'd3, 5'd7, 5'd11, 5'd15, 5'd18:
                    expected_opcode = OP_DWCONV3X3;
                5'd5, 5'd9, 5'd13: expected_opcode = OP_RESIDUAL_ADD;
                5'd14, 5'd17: expected_opcode = OP_UPSAMPLE2;
                5'd21: expected_opcode = OP_OUTPUT_RGB;
                default: expected_opcode = 8'hff;
            endcase
        end
    endfunction

    function automatic logic [15:0] expected_cin(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0: expected_cin = 16'd3;
                5'd1: expected_cin = 16'd12;
                5'd2, 5'd5, 5'd6, 5'd9, 5'd10, 5'd13,
                5'd14, 5'd15, 5'd16: expected_cin = 16'd24;
                5'd3, 5'd4, 5'd7, 5'd8, 5'd11, 5'd12:
                    expected_cin = 16'd48;
                5'd17, 5'd18, 5'd19: expected_cin = 16'd16;
                5'd20: expected_cin = 16'd8;
                5'd21: expected_cin = 16'd3;
                default: expected_cin = 16'd0;
            endcase
        end
    endfunction

    function automatic logic [15:0] expected_cout(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0: expected_cout = 16'd12;
                5'd1, 5'd4, 5'd5, 5'd8, 5'd9, 5'd12, 5'd13,
                5'd14, 5'd15: expected_cout = 16'd24;
                5'd2, 5'd3, 5'd6, 5'd7, 5'd10, 5'd11:
                    expected_cout = 16'd48;
                5'd16, 5'd17, 5'd18: expected_cout = 16'd16;
                5'd19: expected_cout = 16'd8;
                5'd20, 5'd21: expected_cout = 16'd3;
                default: expected_cout = 16'd0;
            endcase
        end
    endfunction

    function automatic logic [7:0] sat_add_s8(
        input logic [7:0] a_bits,
        input logic [7:0] b_bits,
        input logic relu
    );
        logic signed [8:0] sum;
        logic signed [7:0] saturated;
        begin
            sum = $signed({a_bits[7], a_bits}) +
                  $signed({b_bits[7], b_bits});
            if (sum > 9'sd127)
                saturated = 8'sd127;
            else if (sum < -9'sd128)
                saturated = -8'sd128;
            else
                saturated = sum[7:0];
            if (relu && saturated[7])
                sat_add_s8 = 8'd0;
            else
                sat_add_s8 = saturated;
        end
    endfunction

    // Parameter data still enters the layer-local caches on the bank response
    // cycle.  Only the per-word affine-format verdict is registered here so
    // the parameter-bank BRAM output does not continue through the sticky
    // error/reset cone in the same cycle.  Convolution stages perform weight
    // repacking before ST_PARAM_VALIDATE, so the one-cycle verdict boundary
    // does not add a bubble to the compute data path.
    always_comb begin
        affine_word_invalid_comb = 1'b0;
        if (cache_write_valid && (cache_write_region == REGION_MULT)) begin
            for (affine_check_lane = 0; affine_check_lane < 4;
                 affine_check_lane = affine_check_lane + 1) begin
                if (((cache_write_word_index * 4 + affine_check_lane) <
                     output_channels_q) &&
                    (((cache_write_data[
                           affine_check_lane*32 + 18 +: 14] != 14'd0) &&
                      (cache_write_data[
                           affine_check_lane*32 + 18 +: 14] != 14'h3fff)) ||
                     (cache_write_data[
                          affine_check_lane*32 + 18 +: 14] !=
                      {14{cache_write_data[
                          affine_check_lane*32 + 17]}})))
                    affine_word_invalid_comb = 1'b1;
            end
        end else if (cache_write_valid &&
                     (cache_write_region == REGION_SHIFT)) begin
            for (affine_check_lane = 0; affine_check_lane < 16;
                 affine_check_lane = affine_check_lane + 1) begin
                if ((affine_check_lane < cache_write_byte_count) &&
                    ((cache_write_word_index * 16 + affine_check_lane) <
                     output_channels_q) &&
                    (cache_write_data[
                         affine_check_lane*8 +: 8] > 8'd47))
                    affine_word_invalid_comb = 1'b1;
            end
        end
    end

    // One ABI byte is transposed per clock.  Static generate-bank write ports
    // preserve RAM inference: only the selected small bank receives a write,
    // while compute later reads one address from every bank in parallel.
    always_comb begin
        repack_conv_write = 1'b0;
        repack_dw_write = 1'b0;
        repack_bank_comb = 6'd0;
        repack_conv_addr_comb = '0;
        repack_dw_addr_comb = '0;
        repack_byte_comb =
            repack_word_q[repack_byte_lane_q*8 +: 8];
        repack_rgb_index = ({1'b0,repack_tap_q} << 1) +
                           {1'b0,repack_tap_q} + {3'd0,repack_input_channel_q[1:0]};

        if ((state_q == ST_WEIGHT_REPACK) && !rst && !abort &&
            !generation_changed) begin
            if (opcode_q == OP_DWCONV3X3) begin
                repack_dw_write = 1'b1;
                repack_bank_comb = {3'd0, repack_output_channel_q[2:0]};
                repack_dw_addr_comb =
                    ((repack_output_channel_q >> 3) * 9) + repack_tap_q;
            end else begin
                repack_conv_write = 1'b1;
                if (pack_rgb_conv_mode) begin
                    repack_bank_comb = {repack_output_channel_q[2:0], repack_rgb_index[2:0]};
                    repack_conv_addr_comb = (repack_output_channel_q >> 3)*4 +
                                            {3'd0,repack_rgb_index[4:3]};
                end else begin
                    repack_bank_comb = {
                        repack_output_channel_q[2:0],
                        repack_input_channel_q[2:0]
                    };
                    repack_conv_addr_comb =
                        ((((repack_output_channel_q >> 3) * input_groups_q) +
                          (repack_input_channel_q >> 3)) * scheduler_taps) +
                        repack_tap_q;
                end
            end
        end
    end

    genvar conv_bank_gen;
    generate
        for (conv_bank_gen = 0; conv_bank_gen < 64;
             conv_bank_gen = conv_bank_gen + 1) begin : g_conv_weight_bank
            always_ff @(posedge clk) begin
                if (repack_conv_write &&
                    (repack_bank_comb == conv_bank_gen))
                    conv_weight_bank[conv_bank_gen][repack_conv_addr_comb] <=
                        repack_byte_comb;
            end
        end
    endgenerate

    genvar dw_bank_gen;
    generate
        for (dw_bank_gen = 0; dw_bank_gen < 8;
             dw_bank_gen = dw_bank_gen + 1) begin : g_dw_weight_bank
            always_ff @(posedge clk) begin
                if (repack_dw_write && (repack_bank_comb == dw_bank_gen))
                    dw_weight_bank[dw_bank_gen][repack_dw_addr_comb] <=
                        repack_byte_comb;
            end
        end
    endgenerate

    // Tap-bank cache read/write shaping.  A cache hit needs all nine tap
    // words at once so that the existing DW core can retain its lane-major
    // 576-bit start interface.  The nested loops below are elaborated into a
    // fixed bit permutation; only the group index is dynamic and therefore
    // synthesizes as a small mux per tap bank.  The write side forms one
    // complete 64-bit tap word, avoiding the old 8-bit variable part-select
    // write fanout that prevented RAM inference.
    always_comb begin
        dw_cache_lookup_group_comb = output_group_q;
        // Prepare NEXT group into registers only when this group is accepted.
        // No cache-select -> multiplier path is added by the streaming mode.
        if (state_q == ST_DW_STREAM) dw_cache_lookup_group_comb = dw_next_input_group;
        if ((state_q == ST_DW_OUT) &&
            (output_group_q != output_groups_q - 1'b1))
            dw_cache_lookup_group_comb = output_group_q + 1'b1;

        dw_cache_lookup_tile_comb = '0;
        if ((CACHE_DW_WEIGHT_TILES != 0) &&
            (dw_cache_lookup_group_comb < MAX_GROUPS) &&
            dw_group_tile_valid_q[dw_cache_lookup_group_comb]) begin
            for (cache_tile_tap = 0; cache_tile_tap < 9;
                 cache_tile_tap = cache_tile_tap + 1) begin
                for (cache_tile_lane = 0; cache_tile_lane < 8;
                     cache_tile_lane = cache_tile_lane + 1) begin
                    dw_cache_lookup_tile_comb[
                        cache_tile_lane*72 + cache_tile_tap*8 +: 8] =
                        dw_group_tile_mem[cache_tile_tap]
                            [dw_cache_lookup_group_comb]
                            [cache_tile_lane*8 +: 8];
                end
            end
        end

        dw_cache_write_word_comb = '0;
        if ((CACHE_DW_WEIGHT_TILES != 0) &&
            (output_group_q < MAX_GROUPS) &&
            (dw_prefetch_tap_q < 9)) begin
            for (cache_write_lane = 0; cache_write_lane < 8;
                 cache_write_lane = cache_write_lane + 1) begin
                if ((output_group_q * 8 + cache_write_lane) <
                    output_channels_q)
                    dw_cache_write_word_comb[cache_write_lane*8 +: 8] =
                    dw_weight_bank[cache_write_lane]
                        [(output_group_q * 9) + dw_prefetch_tap_q];
            end
        end
    end

    c1_layer_command_decoder #(
        .USE_EXTERNAL_VALIDATION(PREVALIDATE_DESCRIPTOR_REPLAY),
        .PIPELINED_VALIDATION(PIPELINED_DECODER_VALIDATION)
    ) u_descriptor_decoder (
        .clk,
        .rst,
        .abort(abort || (state_q == ST_ERROR)),
        .descriptor_valid(stage_config_valid &&
                          (state_q == ST_WAIT_CONFIG)),
        .descriptor_ready(decoder_descriptor_ready),
        .descriptor_data(stage_config_descriptor),
        .descriptor_error_override(stage_config_error),
        .command_valid(decoder_command_valid),
        .command_ready(decoder_command_ready),
        .command_descriptor(decoder_command_descriptor),
        .command_opcode(), .command_activation(), .command_flags(),
        .command_version(), .command_words(),
        .command_input_width(), .command_input_height(),
        .command_output_width(), .command_output_height(),
        .command_input_channels(), .command_output_channels(),
        .command_input_offset(), .command_output_offset(),
        .command_residual_offset(), .command_weight_offset(),
        .command_bias_offset(), .command_multiplier_offset(),
        .command_shift_offset(), .command_input_row_stride(),
        .command_output_row_stride(), .command_kernel_width(),
        .command_kernel_height(), .command_stride_x(),
        .command_stride_y(), .command_channel_block(),
        .command_mac_lanes(), .command_tile_width(),
        .command_tile_height(), .command_cycle_budget(),
        .error_pulse(decoder_error_pulse),
        .error_code(decoder_error_code)
    );

    c1_r1_c8_parameter_scheduler #(
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .PARAM_ARENA_BYTES(PARAM_ARENA_BYTES),
        .MAX_CHANNELS(MAX_CHANNELS),
        .MAX_WEIGHT_BYTES(MAX_WEIGHT_BYTES)
    ) u_parameter_scheduler (
        .clk,
        .rst,
        .abort(abort || (state_q == ST_ERROR)),
        .start_valid(parameter_start_valid),
        .start_ready(parameter_start_ready),
        .cfg_opcode(opcode_q),
        .cfg_input_channels(input_channels_q),
        .cfg_output_channels(output_channels_q),
        .cfg_weight_offset(weight_offset_q),
        .cfg_bias_offset(bias_offset_q),
        .cfg_multiplier_offset(multiplier_offset_q),
        .cfg_shift_offset(shift_offset_q),
        .param_rd_en,
        .param_rd_addr,
        .param_rd_valid,
        .param_rd_error,
        .param_rd_data,
        .cache_write_valid,
        .cache_write_region,
        .cache_write_word_index,
        .cache_write_byte_count,
        .cache_write_data,
        .busy(parameter_scheduler_busy),
        .done(parameter_scheduler_done),
        .error(parameter_scheduler_error),
        .error_code(parameter_scheduler_error_code),
        .input_group_count(scheduler_input_groups),
        .output_group_count(scheduler_output_groups),
        .input_tail_mask(scheduler_input_mask),
        .output_tail_mask(scheduler_output_mask),
        .kernel_taps(scheduler_taps),
        .weight_bytes(scheduler_weight_bytes)
    );

    c1_dot8x8_requant_core #(
        .X_BITS(16), .Y_BITS(16),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
        .OVERLAP_REQUANTIZATION(OVERLAP_MAC_REQUANTIZATION)
    ) u_dot_core (
        .clk,
        .rst(core_rst),
        .start_valid(dot_start_valid),
        .start_ready(dot_start_ready),
        .start_bias_s32(dot_start_bias),
        .start_mult_s18(dot_start_mult),
        .start_shift_u6(dot_start_shift),
        .start_relu(dot_start_relu),
        .start_sof(meta_sof_q && (output_group_q == 0)),
        .start_eol(meta_eol_q && final_output_group),
        .start_eof(meta_eof_q && final_output_group),
        .start_x(meta_x_q), .start_y(meta_y_q),
        .in_valid(dot_in_valid), .in_ready(dot_in_ready),
        .in_last(dot_in_last), .in_lane_mask(dot_in_lane_mask),
        .in_activations_s8(dot_in_activations),
        .in_weights_s8(dot_in_weights),
        .out_valid(dot_out_valid), .out_ready(dot_out_ready),
        .out_data_s8(dot_out_data), .out_sof(dot_out_sof),
        .out_eol(dot_out_eol), .out_eof(dot_out_eof),
        .out_x(dot_out_x), .out_y(dot_out_y),
        .busy(dot_busy), .overflow_seen(dot_overflow)
    );

    c1_dwconv3x3_c8_requant_core #(
        .X_BITS(16), .Y_BITS(16), .PER_BEAT_CONFIG(STREAM_DW_GROUPS)
    ) u_dw_core (
        .clk,
        .rst(core_rst),
        .start_valid(dw_start_valid), .start_ready(dw_start_ready),
        .start_weights_s8(dw_start_weights),
        .start_bias_s32((state_q==ST_DW_STREAM) ? dw_stream_bias_q : dw_start_bias),
        .start_mult_s18((state_q==ST_DW_STREAM) ? dw_stream_affine_q[143:0] : dw_start_mult),
        .start_shift_u6((state_q==ST_DW_STREAM) ? dw_stream_affine_q[191:144] : dw_start_shift),
        .start_activation((state_q==ST_DW_STREAM) ? dw_stream_affine_q[207:192] : dw_start_activation),
        .in_valid(dw_in_valid), .in_ready(dw_in_ready),
        .in_window_s8((state_q==ST_DW_STREAM) ? dw_stream_window_q : window_cache[output_group_q]),
        .in_sof((state_q!=ST_DW_STREAM) || dw_feed_group_q==0),
        .in_eol((state_q!=ST_DW_STREAM) || dw_feed_group_q==output_groups_q-1'b1),
        .in_eof((state_q!=ST_DW_STREAM) ||
                ((dw_feed_group_q==output_groups_q-1'b1) &&
                 (!STREAM_DW_FRAME || meta_eof_q))),
        .in_x(meta_x_q), .in_y(meta_y_q),
        .out_valid(dw_out_valid), .out_ready(dw_out_ready),
        .out_data_s8(dw_out_data), .out_sof(), .out_eol(), .out_eof(),
        .out_x(dw_out_x), .out_y(dw_out_y), .busy(dw_busy), .done(dw_done),
        .overflow_seen(dw_overflow)
    );

    always_comb begin
        stage_config_ready = (state_q == ST_WAIT_CONFIG) &&
                             decoder_descriptor_ready;
        raw_descriptor_fire = stage_config_valid && stage_config_ready;
        decoder_command_ready = (state_q == ST_WAIT_CONFIG);
        decoded_descriptor_fire = decoder_command_valid &&
                                  decoder_command_ready;

        parameter_start_valid = (state_q == ST_PARAM_START);
        core_rst = rst || abort || (state_q == ST_ERROR);

        topology_valid = 1'b1;
        if (ENFORCE_MICROSTYLE_TOPOLOGY) begin
            topology_valid =
                (decoder_command_descriptor[7:0] ==
                    expected_opcode(stage_index_q)) &&
                (decoder_command_descriptor[111:96] ==
                    expected_cin(stage_index_q)) &&
                (decoder_command_descriptor[127:112] ==
                    expected_cout(stage_index_q));
            if ((stage_index_q == 0) &&
                !decoder_command_descriptor[12])
                topology_valid = 1'b0;
            if ((stage_index_q == REQUIRED_STAGES-1) &&
                !decoder_command_descriptor[13])
                topology_valid = 1'b0;
        end

        continuity_valid = !previous_output_valid_q ||
            ((decoder_command_descriptor[47:32] ==
                previous_output_width_q) &&
             (decoder_command_descriptor[63:48] ==
                previous_output_height_q) &&
             (decoder_command_descriptor[111:96] ==
                previous_output_channels_q));

        weight_layout_valid = 1'b1;
        if ((opcode_q == OP_CONV3X3) || (opcode_q == OP_CONV1X1)) begin
            if ((output_groups_q * input_groups_q * dot_reduction_taps) >
                MAX_PACKED_WEIGHT_TILES)
                weight_layout_valid = 1'b0;
        end else if (opcode_q == OP_DWCONV3X3) begin
            if ((output_groups_q * 9) > DW_WEIGHT_DEPTH)
                weight_layout_valid = 1'b0;
        end

        generation_changed = job_busy_q &&
            ((config_generation != config_generation_q) ||
             !parameter_active_valid ||
             (parameter_generation != parameter_generation_q));

        expected_group_last =
            (expected_input_group_q == input_groups_q - 1'b1);
        expected_sof = (expected_x_q == 0) && (expected_y_q == 0);
        expected_eol = (expected_x_q == output_width_q - 1'b1);
        expected_eof = expected_eol &&
                       (expected_y_q == output_height_q - 1'b1);
        input_protocol_valid =
            (in_group_index == expected_input_group_q) &&
            (in_group_last == expected_group_last) &&
            (in_x == expected_x_q) && (in_y == expected_y_q) &&
            (in_sof == expected_sof) &&
            (in_eol == expected_eol) &&
            (in_eof == expected_eof);
        if (expected_input_group_q != 0)
            input_protocol_valid = input_protocol_valid &&
                (in_x == meta_x_q) && (in_y == meta_y_q) &&
                (in_sof == meta_sof_q) &&
                (in_eol == meta_eol_q) &&
                (in_eof == meta_eof_q);

        final_output_group =
            (output_group_q == output_groups_q - 1'b1);
        current_output_mask = final_output_group ?
                              output_tail_mask_q : 8'hff;

        // The overlap branch advances the tile cursors only after the
        // current beat has actually been accepted.  Keep these values purely
        // combinational so a stalled core leaves the registered bundle
        // untouched and therefore stable.
        mac_next_reduction_group = {1'b0, reduction_group_q};
        mac_next_tap = tap_q;
        mac_next_tile_addr = conv_tile_read_addr_q + 1'b1;
        if (tap_q == dot_reduction_taps - 1'b1) begin
            mac_next_tap = 4'd0;
            mac_next_reduction_group = {1'b0, reduction_group_q} + 1'b1;
        end else begin
            mac_next_tap = tap_q + 1'b1;
        end
        mac_next_last_tile =
            (mac_next_reduction_group == input_groups_q - 1'b1) &&
            (mac_next_tap == dot_reduction_taps - 1'b1);

        dot_start_bias = '0;
        dot_start_mult = '0;
        dot_start_shift = '0;
        dw_start_bias = '0;
        dw_start_mult = '0;
        dw_start_shift = '0;
        dw_start_activation = '0;
        dw_all_tiles_valid = 1'b1;
        for (integer g=0;g<MAX_GROUPS;g++)
            if (g<output_groups_q && !dw_group_tile_valid_q[g]) dw_all_tiles_valid=1'b0;
        for (affine_lane = 0; affine_lane < 8;
             affine_lane = affine_lane + 1) begin
            global_output_comb = ((state_q==ST_DW_STREAM) ? dw_next_input_group : output_group_q) * 8 + affine_lane;
            if ((global_output_comb < output_channels_q) &&
                (global_output_comb < AFFINE_CACHE_DEPTH)) begin
                if (PACKED_AFFINE_CACHE != 0) begin
                    dot_start_bias[affine_lane*32 +: 32] =
                        bias_cache_packed[global_output_comb*32 +: 32];
                    dot_start_mult[affine_lane*18 +: 18] =
                        multiplier_cache_packed[global_output_comb*32 +: 18];
                    dot_start_shift[affine_lane*6 +: 6] =
                        shift_cache_packed[global_output_comb*8 +: 6];
                    dw_start_bias[affine_lane*32 +: 32] =
                        bias_cache_packed[global_output_comb*32 +: 32];
                    dw_start_mult[affine_lane*18 +: 18] =
                        multiplier_cache_packed[global_output_comb*32 +: 18];
                    dw_start_shift[affine_lane*6 +: 6] =
                        shift_cache_packed[global_output_comb*8 +: 6];
                end else begin
                    dot_start_bias[affine_lane*32 +: 32] =
                        bias_cache[global_output_comb];
                    dot_start_mult[affine_lane*18 +: 18] =
                        multiplier_cache[global_output_comb][17:0];
                    dot_start_shift[affine_lane*6 +: 6] =
                        shift_cache[global_output_comb][5:0];
                    dw_start_bias[affine_lane*32 +: 32] =
                        bias_cache[global_output_comb];
                    dw_start_mult[affine_lane*18 +: 18] =
                        multiplier_cache[global_output_comb][17:0];
                    dw_start_shift[affine_lane*6 +: 6] =
                        shift_cache[global_output_comb][5:0];
                end
            end else begin
                dot_start_mult[affine_lane*18 +: 18] = 18'd1;
                dw_start_mult[affine_lane*18 +: 18] = 18'd1;
            end
            dw_start_activation[affine_lane*2 +: 2] = activation_q;
        end
        dot_start_relu = (activation_q == ACT_RELU);

        // Prefetch registers, not the linear ABI store, source the arithmetic
        // cores.  They remain stable for the complete ready/valid stall.
        dot_in_weights = dot_weight_tile_q;
        dot_in_activations = dot_activation_tile_q;
        dot_in_lane_mask = dot_lane_mask_tile_q;
        dot_in_last = dot_last_tile_q;

        dw_start_weights = dw_weight_tile_q;

        masked_dot_data = '0;
        masked_dw_data = '0;
        for (bypass_lane = 0; bypass_lane < 8;
             bypass_lane = bypass_lane + 1) begin
            // Older dot results can also retire while COLLECT accepts the
            // next pixel. Its current output-group cursor is NOT the owner
            // of those results, including their padded-lane mask.
            if ((OVERLAP_MAC_REQUANTIZATION && dot_result_state) ?
                ((dot_retire_group_q*8+bypass_lane)<output_channels_q) : current_output_mask[bypass_lane]) begin
                masked_dot_data[bypass_lane*8 +: 8] =
                    dot_out_data[bypass_lane*8 +: 8];
            end
            if(pixel_dw_mode ? ((dw_retire_group_q*8+bypass_lane)<output_channels_q) : current_output_mask[bypass_lane]) begin
                masked_dw_data[bypass_lane*8 +: 8] =
                    dw_out_data[bypass_lane*8 +: 8];
            end
        end

        bypass_data = '0;
        for (bypass_lane = 0; bypass_lane < 8;
             bypass_lane = bypass_lane + 1) begin
            if (current_output_mask[bypass_lane]) begin
                if (opcode_q == OP_RESIDUAL_ADD)
                    bypass_data[bypass_lane*8 +: 8] = sat_add_s8(
                        window_cache[output_group_q][4*64 +
                                                     bypass_lane*8 +: 8],
                        residual_cache[output_group_q][bypass_lane*8 +: 8],
                        activation_q == ACT_RELU);
                else
                    bypass_data[bypass_lane*8 +: 8] =
                        window_cache[output_group_q][4*64 +
                                                     bypass_lane*8 +: 8];
            end
        end

        in_ready = (state_q == ST_COLLECT) && !generation_changed && !view_layer &&
                   !((ELIDE_VIRTUAL_UPSAMPLE || FUSE_FINAL_OUTPUT) && view_commit_valid);
        view_commit_ready = (ELIDE_VIRTUAL_UPSAMPLE || FUSE_FINAL_OUTPUT) && (state_q==ST_COLLECT) &&
                            job_busy_q && !generation_changed && !rst && !abort &&
                            !error_q && (!view_layer || (!dot_busy && !dw_busy));
        dot_start_valid = (state_q == ST_MAC_START);
        dot_in_valid = (state_q == ST_MAC_FEED);
        dot_out_ready = (OVERLAP_MAC_REQUANTIZATION ? dot_result_state : state_q==ST_MAC_OUT) && out_ready;
        // Continuation is NOT a new START offer. Never present a stalled
        // START that would be withdrawn after preparing the next pixel.
        dw_start_valid = (state_q == ST_DW_START) && !dw_frame_continue;
        dw_in_valid = (state_q == ST_DW_FEED) || ((state_q==ST_DW_STREAM) && !dw_feed_done_q);
        dw_out_ready = (pixel_dw_mode ? dw_result_state : ((state_q == ST_DW_OUT) || (state_q==ST_DW_STREAM))) && out_ready;

        out_valid = 1'b0;
        out_data_s8 = 64'd0;
        out_group_index = output_group_q;
        out_group_last = final_output_group;
        out_x = meta_x_q;
        out_y = meta_y_q;
        out_sof = meta_sof_q && (output_group_q == 0);
        out_eol = meta_eol_q && final_output_group;
        out_eof = meta_eof_q && final_output_group;
        case (state_q)
            ST_MAC_OUT: begin
                out_valid = dot_out_valid;
                out_data_s8 = masked_dot_data;
                out_x = dot_out_x;
                out_y = dot_out_y;
                out_sof = dot_out_sof;
                out_eol = dot_out_eol;
                out_eof = dot_out_eof;
            end
            ST_DW_OUT, ST_DW_STREAM: begin
                out_valid = dw_out_valid;
                out_data_s8 = masked_dw_data;
            end
            ST_BYPASS_OUT: begin
                out_valid = 1'b1;
                out_data_s8 = bypass_data;
            end
            default: begin end
        endcase
        if(OVERLAP_MAC_REQUANTIZATION && dot_result_state) begin
            out_valid=dot_out_valid;out_data_s8=masked_dot_data;
            out_group_index=dot_retire_group_q;
            out_group_last=dot_retire_group_q==output_groups_q-1'b1;
            out_x=dot_out_x;out_y=dot_out_y;
            out_sof=dot_out_sof;out_eol=dot_out_eol;out_eof=dot_out_eof;
        end
        if(pixel_dw_mode && dw_result_state) begin
            out_valid=dw_out_valid;out_data_s8=masked_dw_data;
            out_group_index=dw_retire_group_q;
            out_group_last=dw_retire_group_q==output_groups_q-1'b1;
            // The core tags each accepted beat. Never use the newer input
            // pixel's meta_* registers for an older quantized result.
            out_x=dw_out_x;out_y=dw_out_y;
            out_sof=dw_out_x==0 && dw_out_y==0 && dw_retire_group_q==0;
            out_eol=out_group_last && dw_out_x==output_width_q-1'b1;
            out_eof=out_eol && dw_out_y==output_height_q-1'b1;
        end
        out_fire = out_valid && out_ready;

        job_start_ready = (state_q == ST_IDLE);
        busy = job_busy_q;
        error = error_q;
        stage_index = stage_index_q;
        stage_opcode = opcode_q;
        stage_active = job_busy_q &&
                       (state_q != ST_WAIT_CONFIG) &&
                       (state_q != ST_ERROR);
        adapter_required = stage_active;
        overflow_seen = dot_overflow || dw_overflow;
    end

    task automatic enter_error(input logic [7:0] selected_code);
        begin
            pointwise_stream_q <= 1'b0;
            error_q <= 1'b1;
            error_code <= selected_code;
            job_busy_q <= 1'b0;
            state_q <= ST_ERROR;
        end
    endtask

    task automatic retire_output_group(input state_t restart_state);
        begin
            if (!final_output_group) begin
                output_group_q <= output_group_q + 1'b1;
                state_q <= restart_state;
            end else if (meta_eof_q) begin
                stage_done <= 1'b1;
                if (stage_index_q == REQUIRED_STAGES - 1) begin
                    done <= 1'b1;
                    job_busy_q <= 1'b0;
                    previous_output_valid_q <= 1'b0;
                    state_q <= ST_IDLE;
                end else begin
                    stage_index_q <= stage_index_q + 1'b1;
                    state_q <= ST_WAIT_CONFIG;
                end
            end else begin
                expected_input_group_q <= 3'd0;
                output_group_q <= 3'd0;
                if (expected_x_q == output_width_q - 1'b1) begin
                    expected_x_q <= 16'd0;
                    expected_y_q <= expected_y_q + 1'b1;
                end else begin
                    expected_x_q <= expected_x_q + 1'b1;
                end
                state_q <= ST_COLLECT;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            job_busy_q <= 1'b0;
            error_q <= 1'b0;
            error_code <= ERR_NONE;
            done <= 1'b0;
            aborted <= 1'b0;
            stage_done <= 1'b0;
            config_generation_q <= 8'd0;
            parameter_generation_q <= 32'd0;
            pending_stage_generation_q <= 8'd0;
            stage_index_q <= 5'd0;
            opcode_q <= 8'd0;
            activation_q <= ACT_NONE;
            flags_q <= 6'd0;
            input_width_q <= 16'd0;
            input_height_q <= 16'd0;
            output_width_q <= 16'd0;
            output_height_q <= 16'd0;
            input_channels_q <= 16'd0;
            output_channels_q <= 16'd0;
            weight_offset_q <= 32'd0;
            bias_offset_q <= 32'd0;
            multiplier_offset_q <= 32'd0;
            shift_offset_q <= 32'd0;
            cycle_budget_q <= 32'd0;
            stage_cycle_q <= 32'd0;
            input_groups_q <= 4'd0;
            output_groups_q <= 4'd0;
            input_tail_mask_q <= 8'd0;
            output_tail_mask_q <= 8'd0;
            previous_output_valid_q <= 1'b0;
            previous_output_width_q <= 16'd0;
            previous_output_height_q <= 16'd0;
            previous_output_channels_q <= 16'd0;
            expected_input_group_q <= 3'd0;
            expected_x_q <= 16'd0;
            expected_y_q <= 16'd0;
            meta_x_q <= 16'd0;
            meta_y_q <= 16'd0;
            meta_sof_q <= 1'b0;
            meta_eol_q <= 1'b0;
            meta_eof_q <= 1'b0;
            output_group_q <= 3'd0;
            reduction_group_q <= 3'd0;
            tap_q <= 4'd0;
            repack_linear_index_q <= 16'd0;
            repack_byte_lane_q <= 4'd0;
            repack_word_q <= 128'd0;
            repack_output_channel_q <= 16'd0;
            repack_input_channel_q <= 16'd0;
            repack_tap_q <= 4'd0;
            repack_last_linear_q <= 16'd0;
            repack_last_input_channel_q <= 16'd0;
            repack_last_tap_q <= 4'd0;
            weight_layout_valid_q <= 1'b0;
            affine_invalid_q <= 1'b0;
            affine_word_invalid_q <= 1'b0;
            conv_tile_read_addr_q <= '0;
            dw_prefetch_tap_q <= 4'd0;
            dot_activation_tile_q <= 64'd0;
            dot_lane_mask_tile_q <= 8'd0;
            dot_last_tile_q <= 1'b0;
            dot_weight_tile_q <= 512'd0;
            dw_weight_tile_q <= 576'd0;
            dw_group_tile_valid_q <= '0;
            dw_stream_q<=0;dw_feed_done_q<=0;dw_feed_group_q<=0;
            pointwise_stream_q<=0;
            dot_retire_group_q<=0;dot_issue_done_q<=0;
            dw_retire_group_q<=0;
            dw_stream_window_q<='0;dw_stream_bias_q<='0;dw_stream_affine_q<='0;
            bias_cache_packed <= '0;
            multiplier_cache_packed <= '0;
            shift_cache_packed <= '0;
        end else if (abort) begin
            pointwise_stream_q<=0;
            dot_retire_group_q<=0;dot_issue_done_q<=0;
            dw_retire_group_q<=0;
            aborted <= job_busy_q || (state_q == ST_ERROR);
            state_q <= ST_IDLE;
            job_busy_q <= 1'b0;
            error_q <= 1'b0;
            error_code <= ERR_NONE;
            done <= 1'b0;
            stage_done <= 1'b0;
            previous_output_valid_q <= 1'b0;
            expected_input_group_q <= 3'd0;
            output_group_q <= 3'd0;
            reduction_group_q <= 3'd0;
            tap_q <= 4'd0;
            repack_linear_index_q <= 16'd0;
            repack_byte_lane_q <= 4'd0;
            repack_output_channel_q <= 16'd0;
            repack_input_channel_q <= 16'd0;
            repack_tap_q <= 4'd0;
            repack_last_linear_q <= 16'd0;
            repack_last_input_channel_q <= 16'd0;
            repack_last_tap_q <= 4'd0;
            weight_layout_valid_q <= 1'b0;
            affine_invalid_q <= 1'b0;
            affine_word_invalid_q <= 1'b0;
            conv_tile_read_addr_q <= '0;
            dw_prefetch_tap_q <= 4'd0;
            dot_activation_tile_q <= 64'd0;
            dot_lane_mask_tile_q <= 8'd0;
            dot_last_tile_q <= 1'b0;
            dot_weight_tile_q <= 512'd0;
            dw_weight_tile_q <= 576'd0;
            dw_group_tile_valid_q <= '0;
            dw_stream_q<=0;dw_feed_done_q<=0;dw_feed_group_q<=0;
            dw_stream_window_q<='0;dw_stream_bias_q<='0;dw_stream_affine_q<='0;
            bias_cache_packed <= '0;
            multiplier_cache_packed <= '0;
            shift_cache_packed <= '0;
        end else begin
            done <= 1'b0;
            aborted <= 1'b0;
            stage_done <= 1'b0;
            affine_word_invalid_q <= affine_word_invalid_comb;

            if (raw_descriptor_fire)
                pending_stage_generation_q <= stage_config_generation;

            if (cache_write_valid) begin
                case (cache_write_region)
                    REGION_WEIGHT: begin
                        if (cache_write_word_index < WEIGHT_WORDS)
                            weight_word_cache[cache_write_word_index] <=
                                cache_write_data;
                    end
                    REGION_BIAS: begin
                        for (cache_entry_lane = 0; cache_entry_lane < 4;
                             cache_entry_lane = cache_entry_lane + 1)
                            if ((cache_write_word_index * 4 +
                                 cache_entry_lane) < AFFINE_CACHE_DEPTH)
                                if (PACKED_AFFINE_CACHE != 0)
                                    bias_cache_packed[
                                        (cache_write_word_index * 4 +
                                         cache_entry_lane)*32 +: 32] <=
                                        cache_write_data[cache_entry_lane*32 +: 32];
                                else
                                    bias_cache[cache_write_word_index * 4 +
                                               cache_entry_lane] <=
                                        cache_write_data[cache_entry_lane*32 +: 32];
                    end
                    REGION_MULT: begin
                        for (cache_entry_lane = 0; cache_entry_lane < 4;
                             cache_entry_lane = cache_entry_lane + 1)
                            if ((cache_write_word_index * 4 +
                                 cache_entry_lane) < AFFINE_CACHE_DEPTH) begin
                                if (PACKED_AFFINE_CACHE != 0)
                                    multiplier_cache_packed[
                                        (cache_write_word_index * 4 +
                                         cache_entry_lane)*32 +: 32] <=
                                        cache_write_data[cache_entry_lane*32 +: 32];
                                else
                                    multiplier_cache[cache_write_word_index * 4 +
                                                     cache_entry_lane] <=
                                        cache_write_data[cache_entry_lane*32 +: 32];
                            end
                    end
                    default: begin
                        for (cache_byte_lane = 0; cache_byte_lane < 16;
                             cache_byte_lane = cache_byte_lane + 1) begin
                            if ((cache_byte_lane < cache_write_byte_count) &&
                                 ((cache_write_word_index * 16 +
                                  cache_byte_lane) < AFFINE_CACHE_DEPTH))
                                if (PACKED_AFFINE_CACHE != 0)
                                    shift_cache_packed[
                                        (cache_write_word_index * 16 +
                                         cache_byte_lane)*8 +: 8] <=
                                        cache_write_data[cache_byte_lane*8 +: 8];
                                else
                                    shift_cache[cache_write_word_index * 16 +
                                                cache_byte_lane] <=
                                        cache_write_data[cache_byte_lane*8 +: 8];
                        end
                    end
                endcase
            end

            if (affine_word_invalid_q)
                affine_invalid_q <= 1'b1;

            if (generation_changed) begin
                if (config_generation != config_generation_q)
                    enter_error(ERR_CONFIG_GENERATION);
                else
                    enter_error(ERR_PARAM_GENERATION);
            end else if (decoder_error_pulse) begin
                enter_error(ERR_DESCRIPTOR_BASE | {3'd0, decoder_error_code});
            end else if (parameter_scheduler_error) begin
                enter_error(ERR_PARAM_SCHEDULER |
                            {4'd0, parameter_scheduler_error_code});
            end else if (job_busy_q && (state_q != ST_WAIT_CONFIG) &&
                         (cycle_budget_q != 0) &&
                         (stage_cycle_q >= cycle_budget_q)) begin
                enter_error(ERR_CYCLE_BUDGET);
            end else begin
                if (job_busy_q && (state_q != ST_WAIT_CONFIG))
                    stage_cycle_q <= stage_cycle_q + 1'b1;

                case (state_q)
                    ST_IDLE: begin
                        if (job_start_valid) begin
                            if ((job_stage_count != REQUIRED_STAGES) ||
                                !parameter_active_valid) begin
                                enter_error(ERR_JOB_CONFIG);
                            end else begin
                                job_busy_q <= 1'b1;
                                error_q <= 1'b0;
                                error_code <= ERR_NONE;
                                config_generation_q <= config_generation;
                                parameter_generation_q <= parameter_generation;
                                stage_index_q <= 5'd0;
                                previous_output_valid_q <= 1'b0;
                                state_q <= ST_WAIT_CONFIG;
                            end
                        end
                    end

                    ST_WAIT_CONFIG: begin
                        if (decoded_descriptor_fire) begin
                            if (pending_stage_generation_q !=
                                config_generation_q)
                                enter_error(ERR_CONFIG_GENERATION);
                            else if (!topology_valid || !continuity_valid)
                                enter_error(ERR_TOPOLOGY);
                            else begin
                                opcode_q <= decoder_command_descriptor[7:0];
                                activation_q <=
                                    decoder_command_descriptor[9:8];
                                flags_q <= decoder_command_descriptor[15:10];
                                input_width_q <=
                                    decoder_command_descriptor[47:32];
                                input_height_q <=
                                    decoder_command_descriptor[63:48];
                                output_width_q <=
                                    decoder_command_descriptor[79:64];
                                output_height_q <=
                                    decoder_command_descriptor[95:80];
                                input_channels_q <=
                                    decoder_command_descriptor[111:96];
                                output_channels_q <=
                                    decoder_command_descriptor[127:112];
                                weight_offset_q <=
                                    decoder_command_descriptor[255:224];
                                bias_offset_q <=
                                    decoder_command_descriptor[287:256];
                                multiplier_offset_q <=
                                    decoder_command_descriptor[319:288];
                                shift_offset_q <=
                                    decoder_command_descriptor[351:320];
                                cycle_budget_q <=
                                    decoder_command_descriptor[511:480];
                                input_groups_q <=
                                    (decoder_command_descriptor[111:96] +
                                     16'd7) >> 3;
                                output_groups_q <=
                                    (decoder_command_descriptor[127:112] +
                                     16'd7) >> 3;
                                input_tail_mask_q <= tail_mask(
                                    decoder_command_descriptor[111:96]);
                                output_tail_mask_q <= tail_mask(
                                    decoder_command_descriptor[127:112]);
                                affine_invalid_q <= 1'b0;
                                // Weight contents change with every stage;
                                // invalidate the optional DW tile cache before
                                // parameter repack begins.
                                dw_group_tile_valid_q <= '0;
                                previous_output_valid_q <= 1'b1;
                                previous_output_width_q <=
                                    decoder_command_descriptor[79:64];
                                previous_output_height_q <=
                                    decoder_command_descriptor[95:80];
                                previous_output_channels_q <=
                                    decoder_command_descriptor[127:112];
                                expected_input_group_q <= 3'd0;
                                expected_x_q <= 16'd0;
                                expected_y_q <= 16'd0;
                                output_group_q <= 3'd0;
                                dw_retire_group_q <= 0;
                                dot_retire_group_q <= 0;
                                stage_cycle_q <= 32'd0;
                                state_q <= ST_PARAM_START;
                            end
                        end
                    end

                    ST_PARAM_START: begin
                        if (parameter_start_ready)
                            state_q <= ST_PARAM_WAIT;
                    end

                    ST_PARAM_WAIT: begin
                        if (parameter_scheduler_done) begin
                            input_groups_q <= scheduler_input_groups;
                            output_groups_q <= scheduler_output_groups;
                            input_tail_mask_q <= scheduler_input_mask;
                            output_tail_mask_q <= scheduler_output_mask;
                            // Capture the multiply/compare verdict and all
                            // repack terminal values before they can affect
                            // the counter-enable cone.  ST_WEIGHT_LAYOUT
                            // consumes only registered metadata one cycle
                            // later.
                            weight_layout_valid_q <= weight_layout_valid;
                            if (scheduler_weight_bytes != 0) begin
                                repack_linear_index_q <= 16'd0;
                                repack_byte_lane_q <= 4'd0;
                                repack_output_channel_q <= 16'd0;
                                repack_input_channel_q <= 16'd0;
                                repack_tap_q <= 4'd0;
                                repack_last_linear_q <=
                                    scheduler_weight_bytes - 1'b1;
                                repack_last_input_channel_q <=
                                    input_channels_q - 1'b1;
                                repack_last_tap_q <=
                                    scheduler_taps - 1'b1;
                                state_q <= ST_WEIGHT_LAYOUT;
                            end else begin
                                state_q <= ST_PARAM_VALIDATE;
                            end
                        end
                    end

                    ST_WEIGHT_LAYOUT: begin
                        if (!weight_layout_valid_q)
                            enter_error(ERR_WEIGHT_LAYOUT);
                        else
                            state_q <= ST_WEIGHT_READ;
                    end

                    ST_WEIGHT_READ: begin
                        // Registered 128-bit read: the following state emits
                        // its sixteen bytes one at a time into the lane banks.
                        repack_word_q <= weight_word_cache[
                            repack_linear_index_q[15:4]];
                        repack_byte_lane_q <= 4'd0;
                        state_q <= ST_WEIGHT_REPACK;
                    end

                    ST_WEIGHT_REPACK: begin
                        if (repack_linear_index_q ==
                            repack_last_linear_q) begin
                            repack_linear_index_q <=
                                repack_linear_index_q + 1'b1;
                            state_q <= ST_PARAM_VALIDATE;
                        end else begin
                            repack_linear_index_q <=
                                repack_linear_index_q + 1'b1;

                            if (opcode_q == OP_DWCONV3X3) begin
                                if (repack_tap_q == 4'd8) begin
                                    repack_tap_q <= 4'd0;
                                    repack_output_channel_q <=
                                        repack_output_channel_q + 1'b1;
                                end else begin
                                    repack_tap_q <= repack_tap_q + 1'b1;
                                end
                            end else if (repack_tap_q ==
                                         repack_last_tap_q) begin
                                repack_tap_q <= 4'd0;
                                if (repack_input_channel_q ==
                                    repack_last_input_channel_q) begin
                                    repack_input_channel_q <= 16'd0;
                                    repack_output_channel_q <=
                                        repack_output_channel_q + 1'b1;
                                end else begin
                                    repack_input_channel_q <=
                                        repack_input_channel_q + 1'b1;
                                end
                            end else begin
                                repack_tap_q <= repack_tap_q + 1'b1;
                            end

                            if (repack_byte_lane_q == 4'd15)
                                state_q <= ST_WEIGHT_READ;
                            else
                                repack_byte_lane_q <=
                                    repack_byte_lane_q + 1'b1;
                        end
                    end

                    ST_PARAM_VALIDATE: begin
                        if (((opcode_q == OP_CONV3X3) ||
                             (opcode_q == OP_CONV1X1) ||
                             (opcode_q == OP_DWCONV3X3)) &&
                            affine_invalid_q)
                            enter_error(ERR_AFFINE_FORMAT);
                        else
                            state_q <= ST_COLLECT;
                    end

                    ST_COLLECT: begin
                        if(view_commit_valid && view_commit_ready) begin
                            if(!view_layer || view_commit_stage!=stage_index_q ||
                               view_commit_generation!=config_generation_q ||
                               expected_x_q!=0 || expected_y_q!=0 || expected_input_group_q!=0)
                                enter_error(ERR_INPUT_PROTOCOL);
                            else begin
                                // Descriptor topology/continuity and parameter
                                // preparation have already passed. The adapter
                                // retains the physical input bank for the next
                                // layer's virtual coordinate mapping.
                                stage_done<=1;
                                if (FUSE_FINAL_OUTPUT && stage_index_q==21) begin
                                    done<=1;
                                    job_busy_q<=0;
                                    previous_output_valid_q<=0;
                                    state_q<=ST_IDLE;
                                end else begin
                                    stage_index_q<=stage_index_q+1'b1;
                                    state_q<=ST_WAIT_CONFIG;
                                end
                            end
                        end else if (in_valid && in_ready) begin
                            if (!input_protocol_valid) begin
                                enter_error(ERR_INPUT_PROTOCOL);
                            end else begin
                                window_cache[expected_input_group_q] <=
                                    in_window_s8;
                                residual_cache[expected_input_group_q] <=
                                    in_residual_s8;
                                if (expected_input_group_q == 0) begin
                                    if(!pixel_dot_mode)dot_retire_group_q<=0;
                                    dot_issue_done_q<=0;
                                    meta_x_q <= in_x;
                                    meta_y_q <= in_y;
                                    meta_sof_q <= in_sof;
                                    meta_eol_q <= in_eol;
                                    meta_eof_q <= in_eof;
                                end
                                if (STREAM_POINTWISE_REDUCTION && opcode_q==OP_CONV1X1 && input_groups_q>1) begin
                                    expected_input_group_q <= expected_group_last ? 3'd0 : expected_input_group_q+1'b1;
                                    tap_q <= 0;
                                    reduction_group_q <= expected_input_group_q;
                                    if(expected_input_group_q==0) begin
                                        pointwise_stream_q <= 1;
                                        output_group_q <= 0;
                                        state_q <= ST_MAC_START;
                                    end else begin
                                        // The preceding group already retired
                                        // into this dot transaction. Read the
                                        // newly committed cached group next.
                                        state_q <= ST_MAC_PREFETCH;
                                    end
                                end else if (expected_group_last) begin
                                    expected_input_group_q <= 3'd0;
                                    output_group_q <= 3'd0;
                                    reduction_group_q <= 3'd0;
                                    tap_q <= 4'd0;
                                    if ((opcode_q == OP_CONV3X3) ||
                                        (opcode_q == OP_CONV1X1))
                                        state_q <= ST_MAC_START;
                                    else if (opcode_q == OP_DWCONV3X3) begin
                                        dw_stream_q <= STREAM_DW_GROUPS && CACHE_DW_WEIGHT_TILES!=0 && dw_all_tiles_valid;
                                        dw_feed_group_q<=0;dw_feed_done_q<=0;
                                        dw_prefetch_tap_q <= 4'd0;
                                        if ((CACHE_DW_WEIGHT_TILES != 0) &&
                                            dw_group_tile_valid_q[0]) begin
                                            dw_weight_tile_q <=
                                                dw_cache_lookup_tile_comb;
                                            state_q <= ST_DW_START;
                                        end else begin
                                            state_q <= ST_DW_PREFETCH;
                                        end
                                    end
                                    else
                                        state_q <= ST_BYPASS_OUT;
                                end else begin
                                    expected_input_group_q <=
                                        expected_input_group_q + 1'b1;
                                end
                            end
                        end
                    end

                    ST_MAC_START: begin
                        if (dot_start_ready) begin
                            reduction_group_q <= 3'd0;
                            tap_q <= 4'd0;
                            conv_tile_read_addr_q <=
                                (output_group_q * input_groups_q) *
                                dot_reduction_taps;
                            state_q <= ST_MAC_PREFETCH;
                        end
                    end

                    ST_MAC_PREFETCH: begin
                        // Register the complete elastic MAC input bundle.
                        // Both the fixed weight banks and the window LUTRAM
                        // are therefore isolated from the arithmetic core by
                        // this prefetch boundary and remain stable on stalls.
                        if (pack_rgb_conv_mode)
                            dot_activation_tile_q <= rgb_reduction_tile(window_cache[0],tap_q[1:0]);
                        else if (opcode_q == OP_CONV1X1)
                            dot_activation_tile_q <=
                                window_cache[reduction_group_q]
                                            [4*64 +: 64];
                        else
                            dot_activation_tile_q <=
                                window_cache[reduction_group_q]
                                            [tap_q*64 +: 64];
                        dot_lane_mask_tile_q <=
                            pack_rgb_conv_mode ? ((tap_q==3) ? 8'h07 : 8'hff) :
                            (reduction_group_q == input_groups_q - 1'b1) ?
                            input_tail_mask_q : 8'hff;
                        dot_last_tile_q <=
                            (reduction_group_q == input_groups_q - 1'b1) &&
                            (tap_q == dot_reduction_taps - 1'b1);

                        // Each weight bank has a fixed lane-pair identity;
                        // only the small sequential tile address is dynamic.
                        for (prefetch_output_lane = 0;
                             prefetch_output_lane < 8;
                             prefetch_output_lane =
                                 prefetch_output_lane + 1) begin
                            for (prefetch_input_lane = 0;
                                 prefetch_input_lane < 8;
                                 prefetch_input_lane =
                                     prefetch_input_lane + 1) begin
                                if (((output_group_q * 8 +
                                      prefetch_output_lane) <
                                     output_channels_q) &&
                                    (pack_rgb_conv_mode ? ((tap_q*8 + prefetch_input_lane) < 27) :
                                    ((reduction_group_q * 8 +
                                      prefetch_input_lane) <
                                     input_channels_q)))
                                    dot_weight_tile_q[
                                        prefetch_output_lane*64 +
                                        prefetch_input_lane*8 +: 8] <=
                                        conv_weight_bank[
                                            prefetch_output_lane*8 +
                                            prefetch_input_lane]
                                            [conv_tile_read_addr_q];
                                else
                                    dot_weight_tile_q[
                                        prefetch_output_lane*64 +
                                        prefetch_input_lane*8 +: 8] <= 8'd0;
                            end
                        end
                        state_q <= ST_MAC_FEED;
                    end

                    ST_MAC_FEED: begin
                        if (dot_in_valid && dot_in_ready) begin
                            if (dot_in_last) begin
                                if(pixel_dot_mode && final_output_group) begin
                                    pointwise_stream_q<=0;dot_issue_done_q<=1;
                                    expected_input_group_q<=0;
                                    if(meta_eof_q) state_q<=ST_MAC_OUT;
                                    else begin
                                        if(expected_x_q==output_width_q-1'b1) begin
                                            expected_x_q<=0;expected_y_q<=expected_y_q+1'b1;
                                        end else expected_x_q<=expected_x_q+1'b1;
                                        state_q<=ST_COLLECT;
                                    end
                                end else if(OVERLAP_MAC_REQUANTIZATION) begin
                                    pointwise_stream_q<=0;
                                    if(!final_output_group) begin
                                        output_group_q<=output_group_q+1'b1;
                                        state_q<=ST_MAC_START;
                                    end else begin
                                        dot_issue_done_q<=1;
                                        state_q<=ST_MAC_OUT;
                                    end
                                end else state_q <= ST_MAC_OUT;
                            end else if (pointwise_stream_q) begin
                                // Do not prefetch an input group that has not
                                // handshaken. The adapter can fetch it while
                                // this accepted beat traverses the MAC tree.
                                reduction_group_q <= reduction_group_q + 1'b1;
                                conv_tile_read_addr_q <= conv_tile_read_addr_q + 1'b1;
                                state_q <= ST_COLLECT;
                            end else if (MAC_PREFETCH_OVERLAP != 0) begin
                                // The current registered bundle has been
                                // consumed.  Capture the next sequential
                                // tile now so it can be presented on the
                                // following cycle without returning through
                                // ST_MAC_PREFETCH.  No assignment occurs
                                // while stalled, which keeps every payload
                                // bit stable under ready/valid backpressure.
                                reduction_group_q <=
                                    mac_next_reduction_group[2:0];
                                tap_q <= mac_next_tap;
                                conv_tile_read_addr_q <= mac_next_tile_addr;
                                if (pack_rgb_conv_mode)
                                    dot_activation_tile_q <= rgb_reduction_tile(window_cache[0],mac_next_tap[1:0]);
                                else if (opcode_q == OP_CONV1X1)
                                    dot_activation_tile_q <=
                                        window_cache[
                                            mac_next_reduction_group]
                                            [4*64 +: 64];
                                else
                                    dot_activation_tile_q <=
                                        window_cache[
                                            mac_next_reduction_group]
                                            [mac_next_tap*64 +: 64];
                                dot_lane_mask_tile_q <=
                                    pack_rgb_conv_mode ? ((mac_next_tap==3) ? 8'h07 : 8'hff) :
                                    (mac_next_reduction_group ==
                                     input_groups_q - 1'b1) ?
                                    input_tail_mask_q : 8'hff;
                                dot_last_tile_q <= mac_next_last_tile;
                                for (prefetch_output_lane = 0;
                                     prefetch_output_lane < 8;
                                     prefetch_output_lane =
                                         prefetch_output_lane + 1) begin
                                    for (prefetch_input_lane = 0;
                                         prefetch_input_lane < 8;
                                         prefetch_input_lane =
                                             prefetch_input_lane + 1) begin
                                        if (((output_group_q * 8 +
                                              prefetch_output_lane) <
                                             output_channels_q) &&
                                            (pack_rgb_conv_mode ? ((mac_next_tap*8 + prefetch_input_lane) < 27) :
                                            ((mac_next_reduction_group * 8 +
                                              prefetch_input_lane) <
                                             input_channels_q)))
                                            dot_weight_tile_q[
                                                prefetch_output_lane*64 +
                                                prefetch_input_lane*8 +: 8] <=
                                                conv_weight_bank[
                                                    prefetch_output_lane*8 +
                                                    prefetch_input_lane]
                                                    [mac_next_tile_addr];
                                        else
                                            dot_weight_tile_q[
                                                prefetch_output_lane*64 +
                                                prefetch_input_lane*8 +: 8] <=
                                                8'd0;
                                    end
                                end
                                state_q <= ST_MAC_FEED;
                            end else if (tap_q == dot_reduction_taps - 1'b1) begin
                                tap_q <= 4'd0;
                                reduction_group_q <=
                                    reduction_group_q + 1'b1;
                                conv_tile_read_addr_q <=
                                    conv_tile_read_addr_q + 1'b1;
                                state_q <= ST_MAC_PREFETCH;
                            end else begin
                                tap_q <= tap_q + 1'b1;
                                conv_tile_read_addr_q <=
                                    conv_tile_read_addr_q + 1'b1;
                                state_q <= ST_MAC_PREFETCH;
                            end
                        end
                    end

                    ST_MAC_OUT: begin
                        if (out_fire && !OVERLAP_MAC_REQUANTIZATION) begin
                            pointwise_stream_q <= 0;
                            retire_output_group(ST_MAC_START);
                        end
                    end

                    ST_DW_PREFETCH: begin
                        // A depthwise bank serves one channel lane.  Nine
                        // sequential tap reads construct the 8x9 start tile.
                        for (prefetch_dw_lane = 0; prefetch_dw_lane < 8;
                             prefetch_dw_lane = prefetch_dw_lane + 1) begin
                            if ((output_group_q * 8 + prefetch_dw_lane) <
                                output_channels_q)
                                dw_weight_tile_q[
                                    prefetch_dw_lane*72 +
                                    dw_prefetch_tap_q*8 +: 8] <=
                                    dw_weight_bank[prefetch_dw_lane][
                                        (output_group_q * 9) +
                                        dw_prefetch_tap_q];
                            else
                                dw_weight_tile_q[
                                    prefetch_dw_lane*72 +
                                    dw_prefetch_tap_q*8 +: 8] <= 8'd0;
                        end
                        // One full tap word per cycle gives each cache bank
                        // a conventional RAM write port.  The case keeps
                        // the tap-bank select explicit for inference.
                        if ((CACHE_DW_WEIGHT_TILES != 0) &&
                            (output_group_q < MAX_GROUPS)) begin
                            case (dw_prefetch_tap_q)
                                4'd0: dw_group_tile_mem[0][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd1: dw_group_tile_mem[1][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd2: dw_group_tile_mem[2][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd3: dw_group_tile_mem[3][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd4: dw_group_tile_mem[4][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd5: dw_group_tile_mem[5][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd6: dw_group_tile_mem[6][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd7: dw_group_tile_mem[7][output_group_q] <=
                                    dw_cache_write_word_comb;
                                4'd8: dw_group_tile_mem[8][output_group_q] <=
                                    dw_cache_write_word_comb;
                                default: begin end
                            endcase
                        end
                        if (dw_prefetch_tap_q == 4'd8) begin
                            dw_prefetch_tap_q <= 4'd0;
                            if (CACHE_DW_WEIGHT_TILES != 0)
                                dw_group_tile_valid_q[output_group_q] <= 1'b1;
                            state_q <= ST_DW_START;
                        end else begin
                            dw_prefetch_tap_q <= dw_prefetch_tap_q + 1'b1;
                        end
                    end

                    ST_DW_START: begin
                        if (dw_start_ready || dw_frame_continue) begin
                            if(dw_stream_q) begin
                                dw_stream_window_q<=window_cache[0];
                                dw_stream_bias_q<=dw_start_bias;
                                dw_stream_affine_q<={dw_start_activation,dw_start_shift,dw_start_mult};
                                state_q <= ST_DW_STREAM;
                            end
                            else state_q <= ST_DW_FEED;
                        end
                    end

                    ST_DW_STREAM: begin
                        if (dw_in_valid && dw_in_ready) begin
                            if (dw_feed_group_q==output_groups_q-1'b1) begin
                                dw_feed_done_q<=1;
                                // All old windows have reached the product
                                // stage. Reuse the existing window cache for
                                // the next pixel while requant/output drains.
                                // Default mode fences each pixel. Frame mode
                                // keeps the same per-beat-config batch open;
                                // only the layer's actual final input has EOF.
                                if(pixel_dw_mode && !meta_eof_q) begin
                                    expected_input_group_q<=0;
                                    if(expected_x_q==output_width_q-1'b1) begin
                                        expected_x_q<=0;expected_y_q<=expected_y_q+1'b1;
                                    end else expected_x_q<=expected_x_q+1'b1;
                                    state_q<=ST_COLLECT;
                                end
                            end
                            else begin
                                dw_feed_group_q<=dw_feed_group_q+1'b1;
                                dw_weight_tile_q<=dw_cache_lookup_tile_comb;
                                dw_stream_window_q<=window_cache[dw_next_input_group];
                                dw_stream_bias_q<=dw_start_bias;
                                dw_stream_affine_q<={dw_start_activation,dw_start_shift,dw_start_mult};
                            end
                        end
                        if (out_fire && !pixel_dw_mode) retire_output_group(ST_DW_STREAM);
                    end

                    ST_DW_FEED: begin
                        if (dw_in_valid && dw_in_ready)
                            state_q <= ST_DW_OUT;
                    end

                    ST_DW_OUT: begin
                        if (out_fire) begin
                            dw_prefetch_tap_q <= 4'd0;
                            if (!final_output_group) begin
                                // The current pixel advances to the next
                                // output group without returning through
                                // ST_COLLECT.  Reuse a tile already captured
                                // for this stage, otherwise perform the
                                // normal nine-cycle bank prefetch.
                                output_group_q <= output_group_q + 1'b1;
                                if ((CACHE_DW_WEIGHT_TILES != 0) &&
                                    dw_group_tile_valid_q[output_group_q + 1'b1]) begin
                                    dw_weight_tile_q <=
                                        dw_cache_lookup_tile_comb;
                                    state_q <= ST_DW_START;
                                end else begin
                                    state_q <= ST_DW_PREFETCH;
                                end
                            end else begin
                                retire_output_group(ST_DW_PREFETCH);
                            end
                        end
                    end

                    ST_BYPASS_OUT: begin
                        if (out_fire)
                            retire_output_group(ST_BYPASS_OUT);
                    end

                    default: state_q <= ST_ERROR;
                endcase
                // Input scheduling and ordered result retirement have
                // separate cursors. Pixel overlap can reuse the input window
                // only after its last feed; layer release still waits for EOF.
                if(pixel_dw_mode && dw_result_state && out_fire) begin
                    if(out_group_last)dw_retire_group_q<=0;
                    else dw_retire_group_q<=dw_retire_group_q+1'b1;
                    // Cold first-pixel scheduling still uses ST_DW_OUT and
                    // the legacy retirement task. Warm streaming input has
                    // ALREADY advanced its own cursor, never advance twice.
                    if(dw_stream_q && out_eof) begin
                        stage_done<=1;
                        if(stage_index_q==REQUIRED_STAGES-1) begin
                            done<=1;job_busy_q<=0;previous_output_valid_q<=0;state_q<=ST_IDLE;
                        end else begin
                            stage_index_q<=stage_index_q+1'b1;state_q<=ST_WAIT_CONFIG;
                        end
                    end
                end else if(pixel_dot_mode && dot_result_state && out_fire) begin
                    if(out_group_last)dot_retire_group_q<=0;
                    else dot_retire_group_q<=dot_retire_group_q+1'b1;
                    // Result metadata belongs to the retiring pixel, not the
                    // newer pixel whose input window may already be collected.
                    if(dot_out_eof) begin
                        stage_done<=1;
                        if(stage_index_q==REQUIRED_STAGES-1) begin
                            done<=1;job_busy_q<=0;previous_output_valid_q<=0;state_q<=ST_IDLE;
                        end else begin
                            stage_index_q<=stage_index_q+1'b1;state_q<=ST_WAIT_CONFIG;
                        end
                    end
                end else if(OVERLAP_MAC_REQUANTIZATION && dot_schedule_state && out_fire) begin
                    if(dot_retire_group_q==output_groups_q-1'b1)
                        retire_output_group(ST_MAC_START);
                    else dot_retire_group_q<=dot_retire_group_q+1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial if(STREAM_DW_FRAME && !PIPELINE_DW_PIXELS)
        $fatal(1,"DW frame streaming requires DW pixel pipeline");
    initial if(PIPELINE_DW_PIXELS && (!STREAM_DW_GROUPS || !CACHE_DW_WEIGHT_TILES))
        $fatal(1,"DW pixel pipeline requires group streaming and cached weights");
    integer dw_pixel_inputs_q,dw_pixel_results_q;
    always_ff @(posedge clk) begin
        if(core_rst || state_q==ST_WAIT_CONFIG) begin dw_pixel_inputs_q<=0;dw_pixel_results_q<=0;end
        else if(pixel_dw_mode) begin
            if(dw_in_valid && dw_in_ready)dw_pixel_inputs_q<=dw_pixel_inputs_q+1;
            if(dw_result_state && out_fire)begin
                if(dw_pixel_results_q>=dw_pixel_inputs_q ||
                   out_group_index!=dw_pixel_results_q%output_groups_q ||
                   out_x!=(dw_pixel_results_q/output_groups_q)%output_width_q ||
                   out_y!=(dw_pixel_results_q/output_groups_q)/output_width_q)
                    $fatal(1,"DW pixel pipeline crossed ordered result ownership");
                dw_pixel_results_q<=dw_pixel_results_q+1;
            end
        end
        if(!core_rst && (stage_done || done || state_q==ST_WAIT_CONFIG) && dw_busy)
            $fatal(1,"DW pixel pipeline changed layer with arithmetic results pending");
    end
    initial if(PIPELINE_DOT_PIXELS && !OVERLAP_MAC_REQUANTIZATION)
        $fatal(1,"dot pixel pipeline requires MAC requant overlap");
    initial if((ELIDE_VIRTUAL_UPSAMPLE || FUSE_FINAL_OUTPUT) && (!ENFORCE_MICROSTYLE_TOPOLOGY || REQUIRED_STAGES!=22))
        $fatal(1,"view elision requires the fixed 22-stage topology");
    initial if(PIPELINE_ALL_DOT_GROUPS && !PIPELINE_DOT_PIXELS)
        $fatal(1,"all dot groups requires dot pixel pipeline");
    integer pixel_mac_complete_q,pixel_results_q;
    always_ff @(posedge clk) begin
        if(core_rst || state_q==ST_WAIT_CONFIG) begin
            pixel_mac_complete_q<=0;pixel_results_q<=0;
        end else if(pixel_dot_mode) begin
            if(dot_in_valid && dot_in_ready && dot_in_last)
                pixel_mac_complete_q<=pixel_mac_complete_q+1;
            if(dot_result_state && out_fire) begin
                if(pixel_results_q>=pixel_mac_complete_q || out_group_index!=pixel_results_q%output_groups_q ||
                   out_group_last!=(pixel_results_q%output_groups_q==output_groups_q-1) ||
                   out_x!=(pixel_results_q/output_groups_q)%output_width_q ||
                   out_y!=(pixel_results_q/output_groups_q)/output_width_q ||
                   out_eof!=(pixel_results_q==output_width_q*output_height_q*output_groups_q-1))
                    $fatal(1,"dot pixel pipeline crossed ordered full-reduction retirement fence");
                pixel_results_q<=pixel_results_q+1;
            end
        end
        if(!core_rst && (stage_done || done || state_q==ST_WAIT_CONFIG) && dot_busy)
            $fatal(1,"dot pixel pipeline changed layer with arithmetic results pending");
    end
    integer rq_issued_q,rq_retired_q;
    always_ff @(posedge clk) begin
        if(core_rst) begin rq_issued_q<=0;rq_retired_q<=0;end
        else if(OVERLAP_MAC_REQUANTIZATION && !pixel_dot_mode) begin
            if(in_valid && in_ready && in_group_index==0) begin rq_issued_q<=0;rq_retired_q<=0;end
            if(dot_schedule_state && dot_start_valid && dot_start_ready) begin
                if(output_group_q!=rq_issued_q || rq_issued_q>=output_groups_q)
                    $fatal(1,"requant overlap issued a duplicate/wrong output group");
                rq_issued_q<=rq_issued_q+1;
            end
            if(dot_schedule_state && out_fire) begin
                if(dot_retire_group_q!=rq_retired_q || rq_retired_q>=rq_issued_q ||
                   (out_group_last && (!dot_issue_done_q || rq_issued_q!=output_groups_q)))
                    $fatal(1,"requant overlap crossed output retirement fence");
                rq_retired_q<=rq_retired_q+1;
            end
            if((stage_done || done || state_q==ST_WAIT_CONFIG) && dot_busy)
                $fatal(1,"requant overlap crossed layer boundary with pending results");
        end
    end
    integer pw_inputs_q, pw_feeds_q;
    logic pw_dot_held_q;
    logic [584:0] pw_dot_payload_q;
    always_ff @(posedge clk) begin
        if(core_rst) begin pw_inputs_q<=0;pw_feeds_q<=0;pw_dot_held_q<=0;end
        else if(STREAM_POINTWISE_REDUCTION) begin
            if(in_valid && in_ready && opcode_q==OP_CONV1X1 && input_groups_q>1) begin
                if(in_group_index==0) begin pw_inputs_q<=1;pw_feeds_q<=0;end
                else pw_inputs_q<=pw_inputs_q+1;
            end
            if(pointwise_stream_q) begin
                if(opcode_q!=OP_CONV1X1 || output_group_q!=0 || input_groups_q<=1)
                    $fatal(1,"pointwise stream escaped first-output-group ownership");
                if(dot_in_valid && dot_in_ready) begin
                    if(pw_feeds_q>=pw_inputs_q || reduction_group_q!=pw_feeds_q ||
                       (dot_in_last && (pw_inputs_q!=input_groups_q || pw_feeds_q!=input_groups_q-1)))
                        $fatal(1,"pointwise stream consumed an unaccepted/wrong/early-last group");
                    pw_feeds_q<=pw_feeds_q+1;
                end
                if(out_fire && (!pixel_dot_mode || (out_x==meta_x_q && out_y==meta_y_q)) &&
                   (pw_inputs_q!=input_groups_q || pw_feeds_q!=input_groups_q))
                    $fatal(1,"pointwise result preceded complete reduction retirement");
            end
            if(pw_dot_held_q && (!dot_in_valid ||
                {dot_in_activations,dot_in_weights,dot_in_lane_mask,dot_in_last}!==pw_dot_payload_q))
                $fatal(1,"pointwise MAC input changed while stalled");
            pw_dot_held_q<=pointwise_stream_q && dot_in_valid && !dot_in_ready;
            pw_dot_payload_q<={dot_in_activations,dot_in_weights,dot_in_lane_mask,dot_in_last};
        end
    end
    initial if (STREAM_DW_GROUPS && CACHE_DW_WEIGHT_TILES==0)
        $fatal(1,"STREAM_DW_GROUPS requires cached DW weight tiles");
    logic stream_input_held_q;
    logic [1615:0] stream_input_payload_q;
    integer stream_accepted_q,stream_retired_q;
    always_ff @(posedge clk) begin
        if(rst || abort || state_q==ST_ERROR) begin
            stream_input_held_q<=0;stream_accepted_q<=0;stream_retired_q<=0;
        end else if(STREAM_DW_GROUPS) begin
            if(stream_input_held_q && (!dw_in_valid ||
                {dw_stream_window_q,dw_start_weights,dw_stream_bias_q,dw_stream_affine_q}!==stream_input_payload_q))
                $fatal(1,"DW stream changed an unaccepted window/config tuple");
            stream_input_held_q<=state_q==ST_DW_STREAM && dw_in_valid && !dw_in_ready;
            stream_input_payload_q<={dw_stream_window_q,dw_start_weights,dw_stream_bias_q,dw_stream_affine_q};
            if(state_q==ST_DW_START && dw_start_ready && dw_stream_q) begin
                if(pixel_dw_mode && stream_accepted_q!=stream_retired_q)
                    $fatal(1,"DW pixel pipeline restarted core before old outputs drained");
                stream_accepted_q<=0;stream_retired_q<=0;
            end
            if(state_q==ST_DW_STREAM) begin
                if(!dw_all_tiles_valid)$fatal(1,"DW stream read a cold/stale weight group");
                if(dw_in_valid && dw_in_ready)stream_accepted_q<=stream_accepted_q+1;
            end
            if(state_q==ST_DW_STREAM || (pixel_dw_mode && dw_stream_q && dw_result_state)) begin
                if(out_fire) begin
                    if(stream_retired_q>=stream_accepted_q ||
                       out_group_index!=(STREAM_DW_FRAME ? stream_retired_q%output_groups_q : stream_retired_q))
                        $fatal(1,"DW stream retired an unaccepted/out-of-order group");
                    if(out_group_last && ((!pixel_dw_mode && !dw_feed_done_q) ||
                       (STREAM_DW_FRAME ? (stream_retired_q+1>stream_accepted_q) : stream_accepted_q!=output_groups_q)))
                        $fatal(1,"DW stream final output escaped input retirement fence");
                    stream_retired_q<=stream_retired_q+1;
                end
            end
        end
    end
    initial begin
        if (REQUIRED_STAGES != 22 && ENFORCE_MICROSTYLE_TOPOLOGY)
            $fatal(1, "MicroStyle topology enforcement requires 22 stages");
        if (MAX_CHANNELS != 48 && ENFORCE_MICROSTYLE_TOPOLOGY)
            $fatal(1, "frozen MicroStyle topology requires MAX_CHANNELS=48");
        if (MAX_GROUPS > 8)
            $fatal(1, "in_group_index is three bits; MAX_GROUPS must be <= 8");
        if ((CACHE_DW_WEIGHT_TILES != 0) && (CACHE_DW_WEIGHT_TILES != 1))
            $fatal(1, "CACHE_DW_WEIGHT_TILES must be 0 or 1");
        if ((MAC_PREFETCH_OVERLAP != 0) && (MAC_PREFETCH_OVERLAP != 1))
            $fatal(1, "MAC_PREFETCH_OVERLAP must be 0 or 1");
    end

    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (out_valid && !stage_active)
                $fatal(1, "MicroStyle engine emitted output outside an active stage");
            if (done && busy)
                $fatal(1, "MicroStyle engine done overlapped busy");
            if (stage_done && error)
                $fatal(1, "MicroStyle stage_done overlapped error");
            if (dot_busy && dw_busy)
                $fatal(1, "pointwise and depthwise cores became active together");
            if (parameter_scheduler_busy &&
                !((state_q == ST_PARAM_START) ||
                  (state_q == ST_PARAM_WAIT)))
                $fatal(1, "parameter scheduler busy outside load state");
        end
    end
`endif

endmodule
