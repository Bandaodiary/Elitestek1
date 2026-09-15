`timescale 1ns/1ps

// Board-independent sequential tensor adapter for the 22-stage MicroStyle
// engine.  This block is deliberately a correctness-first memory scheduler:
// by default one 64-bit C8 read/write transaction may be outstanding. It
// provides real descriptor caching, raster/group sequencing, SAME_REPLICATE
// window construction, nearest-neighbour upsample addressing, residual-bank
// routing and final-frame backpressure.
// ENABLE_COLUMN_READS adds a separate, one-inflight 192-bit vertical column
// response for 3x3 windows; non-windowed traffic remains on the scalar port.
//
// Memory contract
// ---------------
// Each accepted request has exactly one later response, including writes.
// Responses may not be combinationally returned in the request-accept cycle.
// Request payload remains stable until ready. By default only one request is
// in flight; PIPELINED_RESULT_WRITES optionally overlaps one pixel's result
// group writes, fencing their real responses before any following read.
// OVERLAP_COLUMN_WRITEBACK additionally permits next-pixel COLUMN reads from
// a distinct immutable input bank while old writes retire. Scalar reads,
// stage changes, completion and cancellation retain the full response fence.
// PIPELINED_SOURCE_WRITES independently pipelines source upload only. It
// closes batches every eight C8 words or EOL and fences all write responses
// before stage 0. No source and result credits may coexist.
// A read returns one NHWC-C8 beat; wstrb is 8'hff for all tensor writes.
//
// This is NOT an AXI burst mover, line cache, multi-port SRAM, or a complete
// high-throughput convolution fabric.  ENABLE_WINDOW_CACHE_SIDEBAND optionally
// exposes the stage/tap metadata needed by an external line-cache seam; the
// cache itself remains outside this adapter.  A future DDR adapter may coalesce
// these transactions without changing the bridge/engine contracts.  At the default
// 8 MiB per bank, three banks reserve 24 MiB and cover the largest 640x480
// MicroStyle tensor (640x480x2 C8 groups = 4,915,200 bytes).
//
// The current software descriptor set identifies a dedicated streaming graph:
// tensor offsets and row strides are zero.  This sequential adapter therefore
// intentionally derives physical tensor addresses from its fixed three-bank
// schedule and descriptor H/W/C fields; it does not reinterpret those zero
// ABI fields as valid DDR addresses.  Parameter offsets remain owned by the
// arithmetic engine and are not consumed here.
module c1_r1_microstyle_tensor_adapter #(
    parameter integer REQUIRED_STAGES = 22,
    parameter integer TENSOR_BANK_BYTES = 8 * 1024 * 1024,
    // Default zero preserves the original FSM and cycle-level behavior.  When
    // enabled, every loaded stage pauses in ST_CACHE_CONFIG until the external
    // cache seam accepts one configuration record.
    parameter integer ENABLE_WINDOW_CACHE_SIDEBAND = 0,
    // Strict validation is the default correctness contract.  A performance
    // build may set this to zero only after the software artifact/ABI has been
    // validated out of band; the expensive 512-bit descriptor topology and
    // tensor-size checker is then removed from the core timing cone.  In
    // simulation, a fatal guard below still checks the descriptor.
    parameter integer STRICT_DESCRIPTOR_VALIDATION = 1,
    // Optional two-boundary descriptor validation schedule.  In the default
    // mode the 512-bit descriptor checker and cache write are performed in
    // the accepting ST_CONFIG cycle for cycle-compatibility.  When enabled,
    // ST_CONFIG only captures the record, ST_CONFIG_VALIDATE computes a
    // compact result, and ST_CONFIG_COMMIT updates the cache/context.  This
    // keeps the wide validation cone away from the descriptor-cache CE path;
    // it adds a fixed two-cycle bubble per descriptor and is intended for an
    // explicitly timed performance build only.
    parameter integer PIPELINED_DESCRIPTOR_VALIDATION = 0,
    // Optional exact-width reduction for the descriptor tensor-size check.
    // For 16-bit W/H/C fields, W*H is at most 32 bits and
    // ceil(C/8)*8 is at most 16 bits, so the 48-bit product is mathematically
    // sufficient for the full ABI field range (not just the nominal 640x480
    // shape).  Default zero keeps the original 64-bit reference expression.
    parameter integer NARROW_DESCRIPTOR_SIZE_CHECK = 0,
    // Optional performance arithmetic for the fixed Case-1 tensor contract.
    // The default keeps the wide 64-bit reference expression.  When enabled,
    // the supported <=48-channel geometry uses a 32-bit pixel index and
    // shift/add group scaling, avoiding a long cascade of wide DSP products.
    // Descriptor ABI/range checks remain the caller's responsibility in this
    // mode; the relaxed xsim build still fatal-checks malformed descriptors.
    parameter integer FAST_TENSOR_ADDRESS_ARITH = 0,
    // Optional address-generation schedule.  The legacy mode computes
    // coordinate transforms and the final tensor byte address in one state
    // transition.  This mode captures resolved coordinates, registers the
    // pixel index (y*width+x), and computes group/base/byte scaling in a
    // following state.  It is intentionally opt-in because it adds two core
    // cycles per memory request but gives synthesis real arithmetic boundaries
    // instead of relying on width/shift tricks.
    parameter integer PIPELINED_TENSOR_ADDRESS = 0,
    // Optional extra arithmetic boundary for the pixel-index product.  When
    // enabled together with PIPELINED_TENSOR_ADDRESS, the y*width row product
    // is registered first and the +x operation is performed on the following
    // cycle.  This adds one more core cycle per memory request, but prevents a
    // multiplier-to-adder carry chain from sharing one setup window.  The
    // default is zero so both the legacy path and the existing two-state
    // address pipeline remain cycle-compatible.
    parameter integer PIPELINED_TENSOR_PIXEL_INDEX = 0,
    // Optional arithmetic split for the strict, pipelined descriptor checker.
    // When enabled together with PIPELINED_DESCRIPTOR_VALIDATION, width*height
    // and the group-byte product are captured before the bank-limit compare.
    // This adds two checker cycles per descriptor (one shared product state is
    // visited for input and output) but keeps the long size multiplier out of
    // descriptor_input/output_size_result_q.  The default is zero so the
    // existing validation schedule and ABI timing are unchanged.
    parameter integer PIPELINED_DESCRIPTOR_SIZE_ARITH = 0,
    // Optional Case-1 fixed-bank limit comparator.  This is a refinement of
    // PIPELINED_DESCRIPTOR_SIZE_ARITH: for the strict 22-stage, narrow,
    // 8-MiB-bank contract it replaces the registered pixel-count ×
    // bytes/group multiply with exact constants for groups 1..6.  All other
    // parameter combinations fall back to the generic product path.
    parameter integer FIXED_DESCRIPTOR_SIZE_LIMITS = 0,
    // Optional extra boundary for the fixed-limit path: capture W/H first,
    // then form W*H in the shared arithmetic state.  It is intentionally
    // scoped to the fixed Case-1 contract and disabled by default.
    parameter integer PIPELINED_DESCRIPTOR_PIXEL_COUNT = 0,
    // Optional synthesis preservation hint for the fixed descriptor-size
    // operand registers.  This never changes the RTL protocol or schedule;
    // when enabled it asks Vivado to retain the W/H and bytes-per-group
    // boundaries for a controlled timing A/B.  Default zero keeps the normal
    // optimizer freedom.
    parameter integer KEEP_DESCRIPTOR_SIZE_OPERANDS = 0,
    // Optional resource-saving descriptor W*H calculator.  When enabled in
    // the fixed Case-1 size-check path, the shared arithmetic state performs
    // an unsigned 16-cycle shift/add multiply instead of inferring a wide
    // combinational multiplier.  The parameter is appended to preserve the
    // positional parameter ABI and is disabled by default.
    parameter integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT = 0,
    // Optional registered cache-sideband saturation.  The normal sideband ABI
    // deliberately carries the signed logical tap so a standalone cache can
    // implement SAME_REPLICATE itself.  When enabled, the adapter instead
    // publishes the already-saturated physical coordinate from the same
    // functions used for mem_req_addr.  This is required before enabling the
    // cache's PRECLAMPED_TAP_COORDS fast path; the value is registered with the
    // request and therefore does not put a new comparator on cache tap_ready.
    parameter integer PRECLAMPED_TAP_COORDS = 0,
    // Permit ordered writes for the output groups of ONE pixel to coexist.
    // Responses still mean real memory completion, never posted acceptance.
    // The last group fences every accepted write before reads/stage changes.
    // Requires an ordered, one-response-per-request downstream interface.
    parameter integer PIPELINED_RESULT_WRITES = 0,
    // Reuse the address pipeline once the current tap address is locked,
    // including request backpressure and response wait. Prepare addresses,
    // never speculative memory requests; an unfinished preparation uses the
    // original address states. Effective with PIPELINED_TENSOR_ADDRESS only.
    parameter integer PREFETCH_NEXT_TAP_ADDRESS = 0,
    // Retain the last two columns per input group for horizontal SAME windows.
    // Inputs must remain immutable during a stage, as with the external cache.
    parameter integer REUSE_HORIZONTAL_WINDOW = 0,
    // Separate, atomic vertical-column port for 3x3 operands only. Ordinary
    // reads/writes retain the scalar memory ABI. Requires stage metadata and
    // an immutable input bank until the stage completes, as with the cache.
    parameter integer ENABLE_COLUMN_READS = 0,
    // Fixed MicroStyle graph only, with the column interface enabled. Keep
    // all 22 engine stages/results, but do not materialize stages 14/17 in
    // DDR. Stages 15/18 read the smaller producer through nearest-neighbour
    // coordinate/row-lane mapping. This is storage elision, NOT compute fusion.
    // Alternate banks after stage 13 preserve the still-live small source.
    parameter bit VIRTUAL_UPSAMPLE_TENSORS = 1'b0,
    // Windowed stages only: columns read an immutable input bank while older
    // results retire to a distinct output bank. The stage/abort fence still
    // waits for every response. Requires pipelined writes and column ports.
    parameter bit OVERLAP_COLUMN_WRITEBACK = 1'b0,
    // Use the existing row-refill/column cache for 1x1 raster input too.
    // Only its center lane becomes the scalar C8 operand; other taps stay 0.
    parameter bit POINTWISE_COLUMN_READS = 1'b0,
    parameter bit PREFETCH_NEXT_PIXEL_COLUMN = 1'b0,
    // Up to 15 ordered source writes may retire independently of admission.
    // Bounded eight-C8 batches (also closed at EOL) let a downstream packer
    // combine traffic. The backend must retire partial batches on idle/abort;
    // req_end is a batching hint, never a prerequisite for a write response.
    // All real responses fence stage 0, errors, and cancellation.
    parameter bit PIPELINED_SOURCE_WRITES = 1'b0,
    // Extend next-pixel first-column prefetch to every input C8 group.
    // At most eight 192-bit entries; still only one external column in flight.
    parameter bit PREFETCH_ALL_PIXEL_GROUPS = 1'b0,
    parameter bit PIPELINE_DOT_PIXELS = 1'b0,
    parameter integer PIXEL_WRITE_BATCH_WORDS = 1,
    parameter bit PIPELINE_DW_PIXELS = 1'b0,
    parameter bit PIPELINE_ALL_DOT_GROUPS = 1'b0,
    parameter bit ELIDE_VIRTUAL_UPSAMPLE = 1'b0,
    parameter bit FUSE_FINAL_OUTPUT = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst,

    // Exact c1_r1_microstyle_system_bridge lifecycle/config seam.
    input  logic                       adapter_start_valid,
    output logic                       adapter_start_ready,
    input  logic                       adapter_abort,
    input  logic                       adapter_stage_config_valid,
    output logic                       adapter_stage_config_ready,
    input  logic [15:0]                adapter_stage_config_index,
    input  logic [511:0]               adapter_stage_config_descriptor,
    input  logic [7:0]                 adapter_stage_config_generation,
    output logic                       adapter_error,
    output logic [7:0]                 adapter_error_code,

    input  logic                       adapter_source_valid,
    output logic                       adapter_source_ready,
    input  logic [63:0]                adapter_source_data_s8,
    input  logic [15:0]                adapter_source_x,
    input  logic [15:0]                adapter_source_y,
    input  logic                       adapter_source_sof,
    input  logic                       adapter_source_eol,
    input  logic                       adapter_source_eof,

    output logic                       adapter_engine_valid,
    input  logic                       adapter_engine_ready,
    output logic [575:0]               adapter_engine_window_s8,
    output logic [63:0]                adapter_engine_residual_s8,
    output logic [2:0]                 adapter_engine_group_index,
    output logic                       adapter_engine_group_last,
    output logic [15:0]                adapter_engine_x,
    output logic [15:0]                adapter_engine_y,
    output logic                       adapter_engine_sof,
    output logic                       adapter_engine_eol,
    output logic                       adapter_engine_eof,

    input  logic                       adapter_result_valid,
    output logic                       adapter_result_ready,
    input  logic [63:0]                adapter_result_data_s8,
    input  logic [2:0]                 adapter_result_group_index,
    input  logic                       adapter_result_group_last,
    input  logic [15:0]                adapter_result_x,
    input  logic [15:0]                adapter_result_y,
    input  logic                       adapter_result_sof,
    input  logic                       adapter_result_eol,
    input  logic                       adapter_result_eof,

    output logic                       adapter_final_valid,
    input  logic                       adapter_final_ready,
    output logic [63:0]                adapter_final_data_s8,
    output logic [15:0]                adapter_final_x,
    output logic [15:0]                adapter_final_y,
    output logic                       adapter_final_sof,
    output logic                       adapter_final_eol,
    output logic                       adapter_final_eof,

    // Physical tensor arena base.  It is captured atomically on start.
    input  logic [31:0]                tensor_base_addr,

    // Optional per-stage window-cache configuration.  cache_stage_base_addr is
    // the base of the current input bank (row=0, x=0, group=0), not the arena
    // base.  A record is sent for every stage; cache_stage_enable distinguishes
    // Conv3x3/DWConv3x3 stages from mandatory-bypass stages.
    output logic                       cache_stage_start_valid,
    input  logic                       cache_stage_start_ready,
    output logic                       cache_stage_enable,
    output logic [31:0]                cache_stage_base_addr,
    output logic [15:0]                cache_stage_width,
    output logic [15:0]                cache_stage_height,
    output logic [3:0]                 cache_stage_groups,

    // Portable transaction-level memory seam.
    output logic                       mem_req_valid,
    input  logic                       mem_req_ready,
    output logic                       mem_req_write,
    output logic [31:0]                mem_req_addr,
    output logic [63:0]                mem_req_wdata,
    output logic [7:0]                 mem_req_wstrb,
    // Request metadata for the optional cache seam.  cache_x/y are the signed,
    // unclamped logical tap coordinates; mem_req_addr still names the SAME-
    // replicate-clamped physical word.  Only 3x3 input tap reads are cacheable.
    output logic                       mem_req_cacheable,
    output logic signed [16:0]         mem_req_cache_x,
    output logic signed [16:0]         mem_req_cache_y,
    output logic [2:0]                 mem_req_cache_group,
    input  logic                       mem_rsp_valid,
    output logic                       mem_rsp_ready,
    input  logic                       mem_rsp_error,
    input  logic [63:0]                mem_rsp_rdata,

    // Standalone diagnostics; the bridge only requires adapter_error/code.
    output logic                       adapter_busy,
    output logic                       adapter_done,
    output logic                       adapter_aborted,
    output logic                       adapter_config_complete,
    output logic [4:0]                 active_stage_index,
    output logic [7:0]                 active_stage_opcode,
    output logic [1:0]                 active_input_bank,
    output logic [1:0]                 active_output_bank,
    output logic [1:0]                 active_residual_bank,
    output logic                       mem_req_end,

    // Exactly one response per accepted column, including errors/cancellation.
    // In pointwise mode only the middle C8 lane is consumed by the engine.
    // No same-cycle response. A presented request must not be withdrawn on
    // adapter_abort; the downstream owner must still accept/retire it. Do not
    // reset or fence the cache out from under a stalled column request.
    output logic                       column_req_valid,
    input  logic                       column_req_ready,
    output logic signed [16:0]         column_req_x,
    output logic signed [16:0]         column_req_center_y,
    output logic [2:0]                 column_req_group,
    input  logic                       column_rsp_valid,
    output logic                       column_rsp_ready,
    input  logic [191:0]               column_rsp_data_s8,
    input  logic                       column_rsp_error,
    output logic                       column_allow_pending_writes,
    output logic                       view_commit_valid,
    input  logic                       view_commit_ready,
    output logic [4:0]                 view_commit_stage,
    output logic [7:0]                 view_commit_generation
);

    localparam logic [7:0] OP_CONV3X3      = 8'd1;
    localparam logic [7:0] OP_CONV1X1      = 8'd2;
    localparam logic [7:0] OP_DWCONV3X3    = 8'd3;
    localparam logic [7:0] OP_UPSAMPLE2    = 8'd4;
    localparam logic [7:0] OP_RESIDUAL_ADD = 8'd5;
    localparam logic [7:0] OP_OUTPUT_RGB   = 8'd6;

    localparam logic [7:0] ERR_NONE         = 8'h00;
    localparam logic [7:0] ERR_START_BASE   = 8'h01;
    localparam logic [7:0] ERR_CONFIG_ORDER = 8'h02;
    localparam logic [7:0] ERR_CONFIG_GEN   = 8'h03;
    localparam logic [7:0] ERR_DESCRIPTOR   = 8'h04;
    localparam logic [7:0] ERR_SOURCE       = 8'h05;
    localparam logic [7:0] ERR_RESULT       = 8'h06;
    localparam logic [7:0] ERR_MEMORY       = 8'h07;

    localparam logic [1:0] ADDR_KIND_SOURCE   = 2'd0;
    localparam logic [1:0] ADDR_KIND_OPERAND  = 2'd1;
    localparam logic [1:0] ADDR_KIND_RESIDUAL = 2'd2;
    localparam logic [1:0] ADDR_KIND_RESULT   = 2'd3;

    // The fixed-limit shortcut is intentionally narrow in scope.  It is
    // mathematically equivalent to the generic tensor-size check only for the
    // shipped Case-1 contract and is inert for every other build shape.
    localparam logic FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE =
        (FIXED_DESCRIPTOR_SIZE_LIMITS != 0) &&
        (PIPELINED_DESCRIPTOR_SIZE_ARITH != 0) &&
        (PIPELINED_DESCRIPTOR_VALIDATION != 0) &&
        (STRICT_DESCRIPTOR_VALIDATION != 0) &&
        (NARROW_DESCRIPTOR_SIZE_CHECK != 0) &&
        (REQUIRED_STAGES == 22) &&
        (TENSOR_BANK_BYTES == (8 * 1024 * 1024));
    localparam logic PIPELINED_DESCRIPTOR_PIXEL_COUNT_ACTIVE =
        (PIPELINED_DESCRIPTOR_PIXEL_COUNT != 0) &&
        FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE;
    // The iterative calculator deliberately shares the same narrow activation
    // fence as the fixed threshold comparator.  This keeps arbitrary
    // parameter combinations on the legacy arithmetic path and makes the
    // optional latency/resource trade-off explicit.
    localparam logic ITERATIVE_DESCRIPTOR_PIXEL_COUNT_ACTIVE =
        (ITERATIVE_DESCRIPTOR_PIXEL_COUNT != 0) &&
        FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE;
    // Keep the selector packed.  Vivado rejects an unpacked string localparam
    // in an attribute expression during synth_design, while a one-bit constant
    // is accepted and maps to the same true/false property semantics.
    localparam logic KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR =
        (KEEP_DESCRIPTOR_SIZE_OPERANDS != 0);

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_CONFIG,
        ST_SOURCE,
        ST_SOURCE_REQ,
        ST_SOURCE_RSP,
        ST_STAGE_LOAD,
        ST_OPERAND_BEGIN,
        ST_READ_REQ,
        ST_READ_RSP,
        ST_RESIDUAL_REQ,
        ST_RESIDUAL_RSP,
        ST_ENGINE,
        ST_RESULT,
        ST_WRITE_REQ,
        ST_WRITE_RSP,
        ST_FINAL,
        ST_ERROR,
        // Appended so ENABLE=0 retains every legacy state's encoded value.
        ST_CACHE_CONFIG,
        ST_SOURCE_ADDR,
        ST_OPERAND_ADDR,
        ST_RESIDUAL_ADDR,
        ST_RESULT_ADDR,
        ST_TENSOR_ADDR_FINAL,
        // Appended after all legacy/address states so the default state
        // encoding remains unchanged for existing waveforms and assertions.
        ST_CONFIG_VALIDATE,
        ST_CONFIG_COMMIT,
        // The strict checker is intentionally split into independent
        // registered predicates.  This prevents a wide size/geometry cone
        // from being re-merged into one timing path by the cache write.
        ST_CONFIG_VALIDATE_SIZE_IN,
        ST_CONFIG_VALIDATE_SIZE_OUT,
        ST_CONFIG_VALIDATE_GEOM,
        ST_CONFIG_VALIDATE_KERNEL,
        ST_CONFIG_VALIDATE_SHAPE,
        // Appended after all existing states to preserve legacy encodings.
        ST_TENSOR_PIXEL_ADD,
        // One shared arithmetic state is used twice when the optional
        // descriptor-size pipeline is enabled; value 31 fits the legacy
        // five-bit state encoding and leaves all earlier encodings intact.
        ST_CONFIG_VALIDATE_SIZE_ARITH
    } state_t;

    state_t state_q;
    logic [3:0] source_writes_pending_q;
    wire source_write_accept = PIPELINED_SOURCE_WRITES &&
        state_q == ST_SOURCE_REQ && mem_req_valid && mem_req_ready;
    wire source_write_retire = PIPELINED_SOURCE_WRITES &&
        source_writes_pending_q != 0 && mem_rsp_valid && mem_rsp_ready;
    always_ff @(posedge clk) begin
        if (rst || !PIPELINED_SOURCE_WRITES) source_writes_pending_q <= 0;
        else case ({source_write_accept, source_write_retire})
            2'b10: source_writes_pending_q <= source_writes_pending_q + 1'b1;
            2'b01: source_writes_pending_q <= source_writes_pending_q - 1'b1;
            default: source_writes_pending_q <= source_writes_pending_q;
        endcase
    end
    logic [3:0] result_writes_pending_q;
    wire result_write_accept = (PIPELINED_RESULT_WRITES != 0) &&
                               (state_q == ST_WRITE_REQ) &&
                               mem_req_valid && mem_req_ready;
    wire result_write_retire = (PIPELINED_RESULT_WRITES != 0) &&
                               (result_writes_pending_q != 0) &&
                               mem_rsp_valid && mem_rsp_ready;
    always_ff @(posedge clk) begin
        if (rst || (PIPELINED_RESULT_WRITES == 0))
            result_writes_pending_q <= 0;
        else case ({result_write_accept,result_write_retire})
            2'b10: result_writes_pending_q <= result_writes_pending_q + 1'b1;
            2'b01: result_writes_pending_q <= result_writes_pending_q - 1'b1;
            default: result_writes_pending_q <= result_writes_pending_q;
        endcase
    end
    logic [511:0] descriptor_cache [0:REQUIRED_STAGES-1];
    logic [15:0] config_index_q;
    logic [7:0] config_generation_q;
    logic config_generation_valid_q;
    logic [15:0] capture_prev_width_q;
    logic [15:0] capture_prev_height_q;
    logic [15:0] capture_prev_channels_q;
    logic config_complete_q;

    // Optional descriptor-validation pipeline.  These registers are only
    // exercised when PIPELINED_DESCRIPTOR_VALIDATION is enabled; the compact
    // result/error keeps the wide checker off the cache write-enable path.
    logic [511:0] descriptor_pending_q;
    logic [15:0] descriptor_pending_index_q;
    logic [7:0] descriptor_pending_generation_q;
    logic [15:0] descriptor_pending_prev_width_q;
    logic [15:0] descriptor_pending_prev_height_q;
    logic [15:0] descriptor_pending_prev_channels_q;
    logic [7:0] descriptor_pending_error_q;
    logic descriptor_validation_result_q;
    logic descriptor_basic_result_q;
    logic descriptor_input_size_result_q;
    logic descriptor_output_size_result_q;
    logic descriptor_context_result_q;
    logic descriptor_kernel_result_q;
    logic descriptor_shape_result_q;

    // Optional descriptor-size arithmetic pipeline registers.  Narrow and
    // reference-width forms are kept separate so enabling the option does not
    // accidentally widen the NARROW_DESCRIPTOR_SIZE_CHECK datapath.
    logic [31:0] descriptor_size_pixel_count_narrow_q;
    (* keep = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR,
       dont_touch = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR *)
    logic [16:0] descriptor_size_bytes_per_group_narrow_q;
    logic [63:0] descriptor_size_pixel_count_wide_q;
    logic [63:0] descriptor_size_bytes_per_group_wide_q;
    logic [63:0] descriptor_size_product_q;
    logic descriptor_size_limit_result_q;
    logic descriptor_size_arith_output_q;
    (* keep = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR,
       dont_touch = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR *)
    logic [15:0] descriptor_size_width_q;
    (* keep = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR,
       dont_touch = KEEP_DESCRIPTOR_SIZE_OPERANDS_ATTR *)
    logic [15:0] descriptor_size_height_q;
    logic descriptor_size_pixel_pending_q;
    // Shift/add W*H workspace used only by the optional iterative fixed-limit
    // path.  A separate pending bit avoids changing the five-bit state enum:
    // ST_CONFIG_VALIDATE_SIZE_ARITH is revisited for all 16 iterations and
    // once more to consume the registered pixel count.
    logic [31:0] descriptor_size_iter_acc_q;
    logic [31:0] descriptor_size_iter_multiplicand_q;
    // W/H are 16-bit ABI fields; the multiplier therefore needs no wider
    // storage, while five bits cover operation counts 0..15 plus consume=16.
    logic [15:0] descriptor_size_iter_multiplier_q;
    logic [4:0] descriptor_size_iter_count_q;
    logic descriptor_size_iter_pending_q;

    logic [31:0] tensor_base_q;
    logic error_q;
    logic [7:0] error_code_q;
    logic abort_pending_q;
    logic abort_seen_q;

    logic [4:0] stage_index_q;
    wire virtual_upsample_input = VIRTUAL_UPSAMPLE_TENSORS &&
        (ENABLE_COLUMN_READS != 0) && (stage_index_q == 15 || stage_index_q == 18);
    wire virtual_upsample_output = VIRTUAL_UPSAMPLE_TENSORS &&
        (ENABLE_COLUMN_READS != 0) && (stage_index_q == 14 || stage_index_q == 17);
    wire fused_compute_layer = FUSE_FINAL_OUTPUT && stage_index_q==20;
    wire fused_final_view = FUSE_FINAL_OUTPUT && stage_index_q==21;
    wire view_layer = (ELIDE_VIRTUAL_UPSAMPLE && virtual_upsample_output) || fused_final_view;
    logic [7:0] opcode_q;
    logic [15:0] input_width_q, input_height_q;
    logic [15:0] output_width_q, output_height_q;
    logic [15:0] input_channels_q, output_channels_q;
    logic [7:0] stride_x_q, stride_y_q;
    logic [3:0] input_groups_q, output_groups_q;
    logic [1:0] input_bank_q, output_bank_q, residual_bank_q;

    logic [15:0] source_x_q, source_y_q;
    logic source_eof_q;
    logic [15:0] output_x_q, output_y_q;
    logic [2:0] input_group_q;
    logic [3:0] tap_q;
    logic [15:0] operand_source_x_q;
    logic [15:0] operand_source_y_q;
    logic [1:0] addr_bank_q;
    logic [15:0] addr_width_q;
    logic [3:0] addr_groups_q;
    logic [15:0] addr_x_q;
    logic [15:0] addr_y_q;
    logic [2:0] addr_group_q;
    logic [31:0] addr_row_product_q;
    logic [31:0] addr_pixel_index_q;
    logic [2:0] tap_addr_prefetch_phase_q;
    logic [31:0] tap_addr_prefetch_q;
    logic [1:0] addr_kind_q;
    logic [575:0] window_q;
    logic [383:0] window_history_q [0:7];
    logic [15:0] window_history_x_q [0:7];
    logic [15:0] window_history_y_q [0:7];
    logic [7:0] window_history_valid_q;
    logic window_reuse_q;
    logic windowed_opcode;
    wire pointwise_column_operand = POINTWISE_COLUMN_READS &&
        (ENABLE_COLUMN_READS != 0) && opcode_q == OP_CONV1X1;
    wire window_reuse_admit = (REUSE_HORIZONTAL_WINDOW != 0) && windowed_opcode &&
        input_bank_q != output_bank_q && output_x_q != 0 &&
        (stride_x_q == 1 || stride_x_q == 2) &&
        window_history_valid_q[input_group_q] &&
        window_history_x_q[input_group_q] + 16'd1 == output_x_q &&
        window_history_y_q[input_group_q] == output_y_q;
    wire [3:0] first_operand_tap = !windowed_opcode ? 4'd4 :
        !window_reuse_admit ? 4'd0 : (stride_x_q == 1 ? 4'd2 : 4'd1);
    typedef enum logic [1:0] { PF_EMPTY, PF_REQUEST, PF_RESPONSE, PF_READY } pf_state_t;
    pf_state_t pixel_prefetch_state_q;
    logic signed [16:0] pixel_prefetch_x_q,pixel_prefetch_y_q;
    logic [15:0] pixel_prefetch_output_x_q,pixel_prefetch_output_y_q;
    logic [4:0] pixel_prefetch_stage_q;
    logic [3:0] pixel_prefetch_tap_q;
    localparam integer PIXEL_PREFETCH_SLOTS = PREFETCH_ALL_PIXEL_GROUPS ? 8 : 1;
    logic [191:0] pixel_prefetch_data_bank [0:PIXEL_PREFETCH_SLOTS-1];
    logic [PIXEL_PREFETCH_SLOTS-1:0] pixel_prefetch_valid_q, pixel_prefetch_errors_q;
    logic [2:0] pixel_prefetch_issue_group_q;
    logic [3:0] pixel_prefetch_groups_q, pixel_prefetch_consumed_q;
    wire [2:0] pixel_prefetch_read_slot = PREFETCH_ALL_PIXEL_GROUPS ? input_group_q : 3'd0;
    wire [191:0] pixel_prefetch_data_q = pixel_prefetch_data_bank[pixel_prefetch_read_slot];
    wire pixel_prefetch_error_q = pixel_prefetch_errors_q[pixel_prefetch_read_slot];
    wire pixel_prefetch_busy = pixel_prefetch_state_q != PF_EMPTY;
    wire pixel_prefetch_bus_busy = pixel_prefetch_state_q==PF_REQUEST || pixel_prefetch_state_q==PF_RESPONSE;
    wire [15:0] next_pixel_x = output_x_q == output_width_q-1'b1 ? 16'd0 : output_x_q+16'd1;
    wire [15:0] next_pixel_y = output_y_q + (output_x_q == output_width_q-1'b1 ? 16'd1 : 16'd0);
    // Every group's history has been saved by the final engine-input
    // handshake (including the one-group case), before prefetch can start.
    wire [3:0] next_pixel_tap = !windowed_opcode ? 4'd4 :
        ((REUSE_HORIZONTAL_WINDOW!=0 && next_pixel_x!=0 && (stride_x_q==1 || stride_x_q==2)) ?
            (stride_x_q==1 ? 4'd2 : 4'd1) : 4'd0);
    wire pixel_prefetch_select = pixel_prefetch_busy && input_group_q<pixel_prefetch_groups_q &&
        stage_index_q==pixel_prefetch_stage_q && output_x_q==pixel_prefetch_output_x_q &&
        output_y_q==pixel_prefetch_output_y_q && tap_q==pixel_prefetch_tap_q;
    wire pixel_prefetch_take = state_q==ST_READ_RSP && pixel_prefetch_select &&
        pixel_prefetch_valid_q[pixel_prefetch_read_slot];
    wire operand_column_rsp_valid = pixel_prefetch_select ? pixel_prefetch_valid_q[pixel_prefetch_read_slot] :
        (!pixel_prefetch_bus_busy && column_rsp_valid);
    wire [191:0] operand_column_rsp_data = pixel_prefetch_select ? pixel_prefetch_data_q : column_rsp_data_s8;
    wire operand_column_rsp_error = pixel_prefetch_select ? pixel_prefetch_error_q : column_rsp_error;
    wire pixel_prefetch_fault = pixel_prefetch_state_q==PF_RESPONSE && column_rsp_valid && column_rsp_ready && column_rsp_error;
    wire column_operand;
    logic pixel_stream_q;
    wire pixel_stream_eligible = column_operand && !fused_compute_layer &&
        ((PIPELINE_DOT_PIXELS && (output_groups_q==1 || PIPELINE_ALL_DOT_GROUPS) && (opcode_q==OP_CONV1X1 || opcode_q==OP_CONV3X3)) ||
         (PIPELINE_DW_PIXELS && opcode_q==OP_DWCONV3X3)) &&
        input_bank_q!=output_bank_q && stage_index_q!=REQUIRED_STAGES-1;
    wire pixel_sink_start_ready,pixel_sink_ready,pixel_sink_busy,pixel_sink_done,pixel_sink_error;
    wire [7:0] pixel_sink_error_code;
    wire pixel_sink_req_valid,pixel_sink_rsp_ready,pixel_sink_req_end;
    wire [31:0] pixel_sink_req_addr;
    wire [63:0] pixel_sink_req_data;
    logic [63:0] residual_q;
    logic [2:0] expected_result_group_q;

    logic request_write_q;
    logic [31:0] request_addr_q;
    logic [63:0] request_wdata_q;
    logic [7:0] request_wstrb_q;
    logic request_cacheable_q;
    logic signed [16:0] request_cache_x_q;
    logic signed [16:0] request_cache_y_q;
    logic [2:0] request_cache_group_q;
    logic result_group_last_q;
    logic result_eof_q;
    logic [63:0] final_data_q;
    logic [15:0] final_x_q, final_y_q;
    logic final_sof_q, final_eol_q, final_eof_q;
    logic final_group_last_q;
    logic fused_final_pending_q, fused_have_result_q;
    wire [15:0] fused_expected_x = !fused_have_result_q ? 16'd0 :
        (final_x_q==output_width_q-1'b1 ? 16'd0 : final_x_q+16'd1);
    wire [15:0] fused_expected_y = !fused_have_result_q ? 16'd0 :
        (final_x_q==output_width_q-1'b1 ? final_y_q+16'd1 : final_y_q);
    wire fused_result_protocol_valid =
        (!fused_have_result_q || !final_eof_q) &&
        adapter_result_group_index==0 && adapter_result_group_last &&
        adapter_result_x==fused_expected_x && adapter_result_y==fused_expected_y &&
        adapter_result_sof==!fused_have_result_q &&
        adapter_result_eol==(fused_expected_x==output_width_q-1'b1) &&
        adapter_result_eof==((fused_expected_x==output_width_q-1'b1) &&
                            (fused_expected_y==output_height_q-1'b1)) &&
        adapter_result_data_s8[63:24]==0;
    wire fused_result_fault = fused_compute_layer && adapter_result_valid &&
        adapter_result_ready && !fused_result_protocol_valid;
    logic [511:0] active_descriptor;
    logic result_protocol_valid;
    logic source_protocol_valid;
    logic memory_request_state;
    logic memory_response_state;

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
                5'd5, 5'd9, 5'd13:
                    expected_opcode = OP_RESIDUAL_ADD;
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
                5'd14, 5'd15: expected_cin = 16'd24;
                5'd3, 5'd4, 5'd7, 5'd8, 5'd11, 5'd12:
                    expected_cin = 16'd48;
                5'd16: expected_cin = 16'd24;
                5'd17, 5'd18: expected_cin = 16'd16;
                5'd19: expected_cin = 16'd16;
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
                5'd16: expected_cout = 16'd16;
                5'd17, 5'd18: expected_cout = 16'd16;
                5'd19: expected_cout = 16'd8;
                5'd20, 5'd21: expected_cout = 16'd3;
                default: expected_cout = 16'd0;
            endcase
        end
    endfunction

    // Three-bank mapping.  Banks holding the residual skip are not overwritten
    // by the expand/depthwise/project chain which consumes the other two.
    function automatic logic [1:0] stage_input_bank_fn(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0: stage_input_bank_fn = 2'd0;
                5'd1: stage_input_bank_fn = 2'd1;
                5'd2: stage_input_bank_fn = 2'd0;
                5'd3: stage_input_bank_fn = 2'd1;
                5'd4: stage_input_bank_fn = 2'd2;
                5'd5: stage_input_bank_fn = 2'd1;
                5'd6: stage_input_bank_fn = 2'd2;
                5'd7: stage_input_bank_fn = 2'd0;
                5'd8: stage_input_bank_fn = 2'd1;
                5'd9: stage_input_bank_fn = 2'd0;
                5'd10: stage_input_bank_fn = 2'd1;
                5'd11: stage_input_bank_fn = 2'd2;
                5'd12: stage_input_bank_fn = 2'd0;
                5'd13: stage_input_bank_fn = 2'd2;
                5'd14: stage_input_bank_fn = 2'd0;
                5'd15: stage_input_bank_fn = 2'd1;
                5'd16: stage_input_bank_fn = 2'd0;
                5'd17: stage_input_bank_fn = 2'd1;
                5'd18: stage_input_bank_fn = 2'd0;
                5'd19: stage_input_bank_fn = 2'd1;
                5'd20: stage_input_bank_fn = 2'd0;
                5'd21: stage_input_bank_fn = 2'd1;
                default: stage_input_bank_fn = 2'd0;
            endcase
            if (VIRTUAL_UPSAMPLE_TENSORS && ENABLE_COLUMN_READS != 0) begin
                case (index)
                    5'd15, 5'd17: stage_input_bank_fn = 2'd0;
                    5'd16: stage_input_bank_fn = 2'd1;
                    default: ;
                endcase
            end
        end
    endfunction

    function automatic logic [1:0] stage_output_bank_fn(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd0: stage_output_bank_fn = 2'd1;
                5'd1: stage_output_bank_fn = 2'd0;
                5'd2: stage_output_bank_fn = 2'd1;
                5'd3: stage_output_bank_fn = 2'd2;
                5'd4: stage_output_bank_fn = 2'd1;
                5'd5: stage_output_bank_fn = 2'd2;
                5'd6: stage_output_bank_fn = 2'd0;
                5'd7: stage_output_bank_fn = 2'd1;
                5'd8: stage_output_bank_fn = 2'd0;
                5'd9: stage_output_bank_fn = 2'd1;
                5'd10: stage_output_bank_fn = 2'd2;
                5'd11: stage_output_bank_fn = 2'd0;
                5'd12: stage_output_bank_fn = 2'd2;
                5'd13: stage_output_bank_fn = 2'd0;
                5'd14: stage_output_bank_fn = 2'd1;
                5'd15: stage_output_bank_fn = 2'd0;
                5'd16: stage_output_bank_fn = 2'd1;
                5'd17: stage_output_bank_fn = 2'd0;
                5'd18: stage_output_bank_fn = 2'd1;
                5'd19: stage_output_bank_fn = 2'd0;
                5'd20: stage_output_bank_fn = 2'd1;
                default: stage_output_bank_fn = 2'd3;
            endcase
            if (VIRTUAL_UPSAMPLE_TENSORS && ENABLE_COLUMN_READS != 0) begin
                case (index)
                    // 3 denotes no materialized tensor, as for final RGB.
                    5'd14, 5'd17: stage_output_bank_fn = 2'd3;
                    5'd15: stage_output_bank_fn = 2'd1;
                    5'd16: stage_output_bank_fn = 2'd0;
                    default: ;
                endcase
            end
        end
    endfunction

    function automatic logic [1:0] stage_residual_bank_fn(
        input logic [4:0] index
    );
        begin
            case (index)
                5'd5: stage_residual_bank_fn = 2'd0;
                5'd9: stage_residual_bank_fn = 2'd2;
                5'd13: stage_residual_bank_fn = 2'd1;
                default: stage_residual_bank_fn = 2'd3;
            endcase
        end
    endfunction

    function automatic logic [63:0] tensor_size_bytes(
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [15:0] channels
    );
        logic [63:0] width_u64;
        logic [63:0] height_u64;
        logic [63:0] groups;
        begin
            // Do not let the 16-bit descriptor operands determine the
            // intermediate expression width.  Native 640x480 geometry
            // exceeds 16-bit pixel-count space before the result is
            // assigned to the 64-bit return value.
            width_u64 = width;
            height_u64 = height;
            groups = (channels + 16'd7) >> 3;
            tensor_size_bytes = width_u64 * height_u64 * groups * 64'd8;
        end
    endfunction

    function automatic logic [63:0] tensor_size_bytes_narrow(
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [15:0] channels
    );
        logic [31:0] pixel_count_u32;
        logic [15:0] groups_u16;
        logic [47:0] bytes_u48;
        logic [47:0] bytes_per_pixel_group_u48;
        begin
            // Explicit extensions prevent Verilog expression sizing from
            // truncating the 16x16 pixel product.  The largest possible
            // value is strictly below 2^48, so this is exact for all legal
            // 16-bit descriptor fields.
            pixel_count_u32 = {16'd0, width} * {16'd0, height};
            groups_u16 = ({1'b0, channels} + 17'd7) >> 3;
            bytes_per_pixel_group_u48 =
                {32'd0, groups_u16} << 3;
            bytes_u48 = {16'd0, pixel_count_u32} *
                        bytes_per_pixel_group_u48;
            tensor_size_bytes_narrow = {16'd0, bytes_u48};
        end
    endfunction

    // Building blocks for the optional descriptor-size arithmetic pipeline.
    // Each helper has an explicit result width; this avoids Verilog's
    // expression-sizing rules silently truncating the 16x16 pixel product.
    function automatic logic [31:0] tensor_pixel_count_narrow_fn(
        input logic [15:0] width,
        input logic [15:0] height
    );
        logic [31:0] width_u32;
        logic [31:0] height_u32;
        begin
            width_u32 = {16'd0, width};
            height_u32 = {16'd0, height};
            tensor_pixel_count_narrow_fn = width_u32 * height_u32;
        end
    endfunction

    function automatic logic [16:0] tensor_bytes_per_group_narrow_fn(
        input logic [15:0] channels
    );
        logic [16:0] groups_u17;
        begin
            groups_u17 = ({1'b0, channels} + 17'd7) >> 3;
            tensor_bytes_per_group_narrow_fn = groups_u17 << 3;
        end
    endfunction

    function automatic logic [47:0] tensor_size_product_narrow_fn(
        input logic [31:0] pixel_count,
        input logic [16:0] bytes_per_group
    );
        logic [47:0] pixel_u48;
        logic [47:0] group_u48;
        begin
            pixel_u48 = {16'd0, pixel_count};
            group_u48 = {31'd0, bytes_per_group};
            // The legal 16-bit W/H/C range is strictly below 2^48 bytes.
            tensor_size_product_narrow_fn = pixel_u48 * group_u48;
        end
    endfunction

    function automatic logic fixed_descriptor_size_limit_fn(
        input logic [31:0] pixel_count,
        input logic [16:0] bytes_per_group
    );
        begin
            // 8 MiB / (groups * 8), with floor semantics matching
            // tensor_size_bytes_narrow(...) <= TENSOR_BANK_BYTES.  The
            // default arm deliberately rejects groups outside 1..6; the
            // strict Case-1 basic predicate rejects those channel counts too.
            case (bytes_per_group)
                17'd8:  fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd1_048_576);
                17'd16: fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd524_288);
                17'd24: fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd349_525);
                17'd32: fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd262_144);
                17'd40: fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd209_715);
                17'd48: fixed_descriptor_size_limit_fn =
                    (pixel_count <= 32'd174_762);
                default: fixed_descriptor_size_limit_fn = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [63:0] tensor_pixel_count_wide_fn(
        input logic [15:0] width,
        input logic [15:0] height
    );
        logic [63:0] width_u64;
        logic [63:0] height_u64;
        begin
            width_u64 = width;
            height_u64 = height;
            tensor_pixel_count_wide_fn = width_u64 * height_u64;
        end
    endfunction

    function automatic logic [63:0] tensor_bytes_per_group_wide_fn(
        input logic [15:0] channels
    );
        logic [63:0] channels_u64;
        logic [63:0] groups_u64;
        begin
            channels_u64 = channels;
            groups_u64 = (channels_u64 + 64'd7) >> 3;
            tensor_bytes_per_group_wide_fn = groups_u64 * 64'd8;
        end
    endfunction

    function automatic logic [63:0] tensor_size_product_wide_fn(
        input logic [63:0] pixel_count,
        input logic [63:0] bytes_per_group
    );
        begin
            tensor_size_product_wide_fn = pixel_count * bytes_per_group;
        end
    endfunction

    function automatic logic tensor_size_within_bank_fn(
        input logic [15:0] width,
        input logic [15:0] height,
        input logic [15:0] channels
    );
        begin
            if (NARROW_DESCRIPTOR_SIZE_CHECK != 0)
                tensor_size_within_bank_fn =
                    (tensor_size_bytes_narrow(width, height, channels) <=
                     TENSOR_BANK_BYTES);
            else
                tensor_size_within_bank_fn =
                    (tensor_size_bytes(width, height, channels) <=
                     TENSOR_BANK_BYTES);
        end
    endfunction

    function automatic logic descriptor_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor,
        input logic [15:0] previous_width,
        input logic [15:0] previous_height,
        input logic [15:0] previous_channels
    );
        logic [7:0] op;
        logic [5:0] flags;
        logic [7:0] version, words;
        logic [15:0] iw, ih, ow, oh, ci, co;
        logic [7:0] kw, kh, sx, sy;
        logic [7:0] channel_block, mac_lanes, tile_w, tile_h;
        logic ok;
        begin
            op = descriptor[7:0];
            flags = descriptor[15:10];
            version = descriptor[23:16];
            words = descriptor[31:24];
            iw = descriptor[47:32];
            ih = descriptor[63:48];
            ow = descriptor[79:64];
            oh = descriptor[95:80];
            ci = descriptor[111:96];
            co = descriptor[127:112];
            kw = descriptor[423:416];
            kh = descriptor[431:424];
            sx = descriptor[439:432];
            sy = descriptor[447:440];
            channel_block = descriptor[455:448];
            mac_lanes = descriptor[463:456];
            tile_w = descriptor[471:464];
            tile_h = descriptor[479:472];

            ok = (index < REQUIRED_STAGES) &&
                 (version == 8'd1) && (words == 8'd16) &&
                 (op == expected_opcode(index)) &&
                 (ci == expected_cin(index)) &&
                 (co == expected_cout(index)) &&
                 (iw != 0) && (ih != 0) && (ow != 0) && (oh != 0) &&
                 (channel_block != 0) && (mac_lanes != 0) &&
                 (tile_w != 0) && (tile_h != 0) &&
                 tensor_size_within_bank_fn(iw, ih, ci) &&
                 tensor_size_within_bank_fn(ow, oh, co);

            if (index == 0)
                ok = ok && (iw[1:0] == 0) && (ih[1:0] == 0);
            else
                ok = ok && (iw == previous_width) &&
                     (ih == previous_height) &&
                     (ci == previous_channels);

            case (op)
                OP_CONV3X3: begin
                    // The ABI only permits stride 1 or 2 here.  Express the
                    // ceil-divide explicitly instead of using a variable
                    // divider; Vivado maps the latter to a very deep carry/
                    // mux cone even though all legal divisors are constants.
                    ok = ok && (kw == 3) && (kh == 3) &&
                         (sx == sy) && ((sx == 1) || (sx == 2)) && flags[0];
                    if (sx == 1)
                        ok = ok && (ow == iw) && (oh == ih);
                    else if (sx == 2)
                        ok = ok && (ow == ((iw + 16'd1) >> 1)) &&
                             (oh == ((ih + 16'd1) >> 1));
                    else
                        ok = 1'b0;
                end
                OP_CONV1X1: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && (ow == iw) && (oh == ih);
                OP_DWCONV3X3: ok = ok && (kw == 3) && (kh == 3) &&
                    (sx == 1) && (sy == 1) && flags[0] &&
                    (ow == iw) && (oh == ih) && (ci == co);
                OP_UPSAMPLE2: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 2) && (sy == 2) &&
                    (ow == (iw << 1)) && (oh == (ih << 1)) && (ci == co);
                OP_RESIDUAL_ADD: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && flags[1] &&
                    (ow == iw) && (oh == ih) && (ci == co);
                OP_OUTPUT_RGB: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && (ow == iw) && (oh == ih) &&
                    (ci == 3) && (co == 3);
                default: ok = 1'b0;
            endcase
            descriptor_valid_fn = ok;
        end
    endfunction

    // Predicate decomposition used only by the optional pipelined checker.
    // Keeping these predicates independent is important: Vivado can otherwise
    // fold the two tensor-size products and opcode geometry checks back into a
    // single carry chain feeding descriptor_cache[].CE.
    function automatic logic descriptor_basic_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor
    );
        logic [7:0] op;
        logic [7:0] version, words;
        logic [15:0] iw, ih, ow, oh, ci, co;
        logic [7:0] channel_block, mac_lanes, tile_w, tile_h;
        begin
            op = descriptor[7:0];
            version = descriptor[23:16];
            words = descriptor[31:24];
            iw = descriptor[47:32];
            ih = descriptor[63:48];
            ow = descriptor[79:64];
            oh = descriptor[95:80];
            ci = descriptor[111:96];
            co = descriptor[127:112];
            channel_block = descriptor[455:448];
            mac_lanes = descriptor[463:456];
            tile_w = descriptor[471:464];
            tile_h = descriptor[479:472];
            descriptor_basic_valid_fn =
                (index < REQUIRED_STAGES) &&
                (version == 8'd1) && (words == 8'd16) &&
                (op == expected_opcode(index)) &&
                (ci == expected_cin(index)) &&
                (co == expected_cout(index)) &&
                (iw != 0) && (ih != 0) && (ow != 0) && (oh != 0) &&
                (channel_block != 0) && (mac_lanes != 0) &&
                (tile_w != 0) && (tile_h != 0);
        end
    endfunction

    function automatic logic descriptor_geometry_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor,
        input logic [15:0] previous_width,
        input logic [15:0] previous_height,
        input logic [15:0] previous_channels
    );
        logic [7:0] op;
        logic [5:0] flags;
        logic [15:0] iw, ih, ow, oh, ci, co;
        logic [7:0] kw, kh, sx, sy;
        logic ok;
        begin
            op = descriptor[7:0];
            flags = descriptor[15:10];
            iw = descriptor[47:32];
            ih = descriptor[63:48];
            ow = descriptor[79:64];
            oh = descriptor[95:80];
            ci = descriptor[111:96];
            co = descriptor[127:112];
            kw = descriptor[423:416];
            kh = descriptor[431:424];
            sx = descriptor[439:432];
            sy = descriptor[447:440];

            if (index == 0)
                ok = (iw[1:0] == 0) && (ih[1:0] == 0);
            else
                ok = (iw == previous_width) &&
                     (ih == previous_height) &&
                     (ci == previous_channels);

            case (op)
                OP_CONV3X3: begin
                    ok = ok && (kw == 3) && (kh == 3) &&
                         (sx == sy) && ((sx == 1) || (sx == 2)) && flags[0];
                    if (sx == 1)
                        ok = ok && (ow == iw) && (oh == ih);
                    else if (sx == 2)
                        ok = ok && (ow == ((iw + 16'd1) >> 1)) &&
                             (oh == ((ih + 16'd1) >> 1));
                    else
                        ok = 1'b0;
                end
                OP_CONV1X1: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && (ow == iw) && (oh == ih);
                OP_DWCONV3X3: ok = ok && (kw == 3) && (kh == 3) &&
                    (sx == 1) && (sy == 1) && flags[0] &&
                    (ow == iw) && (oh == ih) && (ci == co);
                OP_UPSAMPLE2: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 2) && (sy == 2) &&
                    (ow == (iw << 1)) && (oh == (ih << 1)) && (ci == co);
                OP_RESIDUAL_ADD: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && flags[1] &&
                    (ow == iw) && (oh == ih) && (ci == co);
                OP_OUTPUT_RGB: ok = ok && (kw == 1) && (kh == 1) &&
                    (sx == 1) && (sy == 1) && (ow == iw) && (oh == ih) &&
                    (ci == 3) && (co == 3);
                default: ok = 1'b0;
            endcase
            descriptor_geometry_valid_fn = ok;
        end
    endfunction

    function automatic logic descriptor_context_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor,
        input logic [15:0] previous_width,
        input logic [15:0] previous_height,
        input logic [15:0] previous_channels
    );
        logic [15:0] iw, ih, ci;
        begin
            iw = descriptor[47:32];
            ih = descriptor[63:48];
            ci = descriptor[111:96];
            if (index == 0)
                descriptor_context_valid_fn =
                    (iw[1:0] == 0) && (ih[1:0] == 0);
            else
                descriptor_context_valid_fn =
                    (iw == previous_width) &&
                    (ih == previous_height) &&
                    (ci == previous_channels);
        end
    endfunction

    function automatic logic descriptor_kernel_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor
    );
        logic [7:0] op;
        logic [5:0] flags;
        logic [7:0] kw, kh, sx, sy;
        logic [15:0] ci, co;
        begin
            op = descriptor[7:0];
            flags = descriptor[15:10];
            ci = descriptor[111:96];
            co = descriptor[127:112];
            kw = descriptor[423:416];
            kh = descriptor[431:424];
            sx = descriptor[439:432];
            sy = descriptor[447:440];
            case (op)
                OP_CONV3X3: descriptor_kernel_valid_fn =
                    (kw == 3) && (kh == 3) && (sx == sy) &&
                    ((sx == 1) || (sx == 2)) && flags[0];
                OP_CONV1X1: descriptor_kernel_valid_fn =
                    (kw == 1) && (kh == 1) && (sx == 1) && (sy == 1);
                OP_DWCONV3X3: descriptor_kernel_valid_fn =
                    (kw == 3) && (kh == 3) && (sx == 1) && (sy == 1) &&
                    flags[0] && (ci == co);
                OP_UPSAMPLE2: descriptor_kernel_valid_fn =
                    (kw == 1) && (kh == 1) && (sx == 2) && (sy == 2) &&
                    (ci == co);
                OP_RESIDUAL_ADD: descriptor_kernel_valid_fn =
                    (kw == 1) && (kh == 1) && (sx == 1) && (sy == 1) &&
                    flags[1] && (ci == co);
                OP_OUTPUT_RGB: descriptor_kernel_valid_fn =
                    (kw == 1) && (kh == 1) && (sx == 1) && (sy == 1) &&
                    (ci == 3) && (co == 3);
                default: descriptor_kernel_valid_fn = 1'b0;
            endcase
        end
    endfunction

    function automatic logic descriptor_shape_valid_fn(
        input logic [4:0] index,
        input logic [511:0] descriptor
    );
        logic [7:0] op, sx, sy;
        logic [15:0] iw, ih, ow, oh;
        begin
            op = descriptor[7:0];
            sx = descriptor[439:432];
            sy = descriptor[447:440];
            iw = descriptor[47:32];
            ih = descriptor[63:48];
            ow = descriptor[79:64];
            oh = descriptor[95:80];
            case (op)
                OP_CONV3X3: begin
                    if (sx == 1)
                        descriptor_shape_valid_fn =
                            (ow == iw) && (oh == ih);
                    else if (sx == 2)
                        descriptor_shape_valid_fn =
                            (ow == ((iw + 16'd1) >> 1)) &&
                            (oh == ((ih + 16'd1) >> 1));
                    else
                        descriptor_shape_valid_fn = 1'b0;
                end
                OP_CONV1X1, OP_DWCONV3X3, OP_RESIDUAL_ADD,
                OP_OUTPUT_RGB:
                    descriptor_shape_valid_fn =
                        (ow == iw) && (oh == ih);
                OP_UPSAMPLE2:
                    descriptor_shape_valid_fn =
                        (ow == (iw << 1)) && (oh == (ih << 1));
                default: descriptor_shape_valid_fn = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [31:0] tensor_addr_fn(
        input logic [1:0] bank,
        input logic [15:0] width,
        input logic [3:0] groups,
        input logic [15:0] x,
        input logic [15:0] y,
        input logic [2:0] group_index
    );
        logic [31:0] pixel_index_u32;
        logic [31:0] beat_index_u32;
        logic [31:0] byte_address_u32;
        logic [31:0] group_scaled_u32;
        logic [31:0] width_u32;
        logic [31:0] x_u32;
        logic [31:0] y_u32;
        logic [63:0] width_u64;
        logic [63:0] x_u64;
        logic [63:0] y_u64;
        logic [63:0] groups_u64;
        logic [63:0] group_index_u64;
        logic [63:0] beat_index;
        logic [63:0] byte_address;
        begin
            if (FAST_TENSOR_ADDRESS_ARITH != 0) begin
                // The validated Case-1 tensor is at most 8 MiB per bank, so
                // the pixel/beat products fit comfortably in 32 bits.  Keep
                // the group scale explicit; groups are 1..6 for C8/C48.
                width_u32 = width;
                x_u32 = x;
                y_u32 = y;
                pixel_index_u32 = (y_u32 * width_u32) + x_u32;
                case (groups)
                    4'd1: group_scaled_u32 = pixel_index_u32;
                    4'd2: group_scaled_u32 = pixel_index_u32 << 1;
                    4'd3: group_scaled_u32 = pixel_index_u32 +
                                               (pixel_index_u32 << 1);
                    4'd4: group_scaled_u32 = pixel_index_u32 << 2;
                    4'd5: group_scaled_u32 = pixel_index_u32 +
                                               (pixel_index_u32 << 2);
                    4'd6: group_scaled_u32 = (pixel_index_u32 << 2) +
                                               (pixel_index_u32 << 1);
                    4'd7: group_scaled_u32 = (pixel_index_u32 << 3) -
                                               pixel_index_u32;
                    4'd8: group_scaled_u32 = pixel_index_u32 << 3;
                    default: group_scaled_u32 = pixel_index_u32 * groups;
                endcase
                beat_index_u32 = group_scaled_u32 + group_index;
                byte_address_u32 = tensor_base_q +
                                   (bank * TENSOR_BANK_BYTES) +
                                   (beat_index_u32 << 3);
                tensor_addr_fn = byte_address_u32;
            end else begin
                // Reference path: explicitly widen before the row/pixel
                // products so y*width remains correct for native geometry.
                width_u64 = width;
                x_u64 = x;
                y_u64 = y;
                groups_u64 = groups;
                group_index_u64 = group_index;
                beat_index = ((y_u64 * width_u64 + x_u64) * groups_u64) +
                             group_index_u64;
                byte_address = tensor_base_q +
                               (bank * TENSOR_BANK_BYTES) +
                               (beat_index << 3);
                tensor_addr_fn = byte_address[31:0];
            end
        end
    endfunction

    // Final half of the optional address pipeline.  The row/pixel product is
    // deliberately supplied as a registered pixel index, so this expression
    // only covers group scaling, byte scaling and bank/base addition.
    function automatic logic [31:0] tensor_addr_from_pixel_fn(
        input logic [1:0] bank,
        input logic [31:0] pixel_index,
        input logic [3:0] groups,
        input logic [2:0] group_index
    );
        logic [31:0] group_scaled_u32;
        logic [31:0] beat_index_u32;
        logic [31:0] byte_offset_u32;
        logic [31:0] bank_base_u32;
        begin
            // Relaxed synthesis still receives descriptor-contract groups in
            // 1..6 (the generic C8 limit is 8).  Spell out that small-domain
            // scale so a 32x64 generic multiply cannot become a two-DSP
            // cascade after the registered pixel-index boundary.
            case (groups)
                4'd0: group_scaled_u32 = 32'd0;
                4'd1: group_scaled_u32 = pixel_index;
                4'd2: group_scaled_u32 = pixel_index << 1;
                4'd3: group_scaled_u32 = pixel_index +
                                               (pixel_index << 1);
                4'd4: group_scaled_u32 = pixel_index << 2;
                4'd5: group_scaled_u32 = pixel_index +
                                               (pixel_index << 2);
                4'd6: group_scaled_u32 = (pixel_index << 2) +
                                               (pixel_index << 1);
                4'd7: group_scaled_u32 = (pixel_index << 3) -
                                               pixel_index;
                4'd8: group_scaled_u32 = pixel_index << 3;
                default: group_scaled_u32 = 32'd0;
            endcase
            beat_index_u32 = group_scaled_u32 + {29'd0, group_index};
            byte_offset_u32 = beat_index_u32 << 3;

            // bank is the fixed ping-pong schedule (0..2).  Constant cases
            // avoid retaining a generic bank multiply in this final stage.
            case (bank)
                2'd0: bank_base_u32 = tensor_base_q;
                2'd1: bank_base_u32 = tensor_base_q + TENSOR_BANK_BYTES;
                2'd2: bank_base_u32 = tensor_base_q +
                                           (2 * TENSOR_BANK_BYTES);
                default: bank_base_u32 = tensor_base_q;
            endcase
            tensor_addr_from_pixel_fn = bank_base_u32 + byte_offset_u32;
        end
    endfunction

    function automatic logic [31:0] tensor_pixel_index_fn(
        input logic [15:0] width,
        input logic [15:0] x,
        input logic [15:0] y
    );
        logic [31:0] width_u32;
        logic [31:0] x_u32;
        logic [31:0] y_u32;
        begin
            width_u32 = width;
            x_u32 = x;
            y_u32 = y;
            tensor_pixel_index_fn = (y_u32 * width_u32) + x_u32;
        end
    endfunction

    // Keep the row product as an explicit 32-bit operation.  Descriptor
    // coordinates are 16-bit, so y*width is mathematically bounded below
    // 2^32 for every legal field value; truncation is therefore not used to
    // hide an overflow.  The optional deep pipeline places this operation in
    // its own register boundary before the x add.
    function automatic logic [31:0] tensor_row_product_fn(
        input logic [15:0] width,
        input logic [15:0] y
    );
        logic [31:0] width_u32;
        logic [31:0] y_u32;
        begin
            width_u32 = width;
            y_u32 = y;
            tensor_row_product_fn = y_u32 * width_u32;
        end
    endfunction

    function automatic logic [31:0] tensor_bank_base_fn(
        input logic [1:0] bank
    );
        logic [31:0] byte_address_u32;
        logic [63:0] byte_address;
        begin
            if (FAST_TENSOR_ADDRESS_ARITH != 0) begin
                byte_address_u32 = tensor_base_q +
                                   (bank * TENSOR_BANK_BYTES);
                tensor_bank_base_fn = byte_address_u32;
            end else begin
                byte_address = tensor_base_q + (bank * TENSOR_BANK_BYTES);
                tensor_bank_base_fn = byte_address[31:0];
            end
        end
    endfunction

    function automatic logic [15:0] tap_source_x_fn(
        input logic [15:0] out_x,
        input logic [7:0] stride,
        input logic [3:0] tap,
        input logic [15:0] input_width
    );
        integer signed center;
        integer signed candidate;
        integer signed delta;
        logic [16:0] center_fast;
        logic signed [17:0] candidate_fast;
        logic signed [2:0] delta_fast;
        begin
            if (PIPELINED_TENSOR_ADDRESS != 0) begin
                // Validated Case-1 windowed descriptors use stride 1 or 2.
                // Keep this coordinate stage in narrow fabric arithmetic so
                // it does not become a DSP feeding the pixel-index DSP on the
                // following pipeline cycle.
                center_fast = (stride == 8'd2) ?
                              {out_x, 1'b0} : {1'b0, out_x};
                case (tap)
                    4'd0, 4'd3, 4'd6: delta_fast = -3'sd1;
                    4'd1, 4'd4, 4'd7: delta_fast = 3'sd0;
                    default:          delta_fast = 3'sd1;
                endcase
                candidate_fast = $signed({1'b0, center_fast}) + delta_fast;
                if (candidate_fast < 0)
                    tap_source_x_fn = 16'd0;
                else if (candidate_fast >=
                         $signed({2'b00, input_width}))
                    tap_source_x_fn = input_width - 1'b1;
                else
                    tap_source_x_fn = candidate_fast[15:0];
            end else begin
                center = out_x * stride;
                delta = (tap % 3) - 1;
                candidate = center + delta;
                if (candidate < 0)
                    tap_source_x_fn = 16'd0;
                else if (candidate >= input_width)
                    tap_source_x_fn = input_width - 1'b1;
                else
                    tap_source_x_fn = candidate[15:0];
            end
        end
    endfunction

    function automatic logic [15:0] tap_source_y_fn(
        input logic [15:0] out_y,
        input logic [7:0] stride,
        input logic [3:0] tap,
        input logic [15:0] input_height
    );
        integer signed center;
        integer signed candidate;
        integer signed delta;
        logic [16:0] center_fast;
        logic signed [17:0] candidate_fast;
        logic signed [2:0] delta_fast;
        begin
            if (PIPELINED_TENSOR_ADDRESS != 0) begin
                center_fast = (stride == 8'd2) ?
                              {out_y, 1'b0} : {1'b0, out_y};
                case (tap)
                    4'd0, 4'd1, 4'd2: delta_fast = -3'sd1;
                    4'd3, 4'd4, 4'd5: delta_fast = 3'sd0;
                    default:          delta_fast = 3'sd1;
                endcase
                candidate_fast = $signed({1'b0, center_fast}) + delta_fast;
                if (candidate_fast < 0)
                    tap_source_y_fn = 16'd0;
                else if (candidate_fast >=
                         $signed({2'b00, input_height}))
                    tap_source_y_fn = input_height - 1'b1;
                else
                    tap_source_y_fn = candidate_fast[15:0];
            end else begin
                center = out_y * stride;
                delta = (tap / 3) - 1;
                candidate = center + delta;
                if (candidate < 0)
                    tap_source_y_fn = 16'd0;
                else if (candidate >= input_height)
                    tap_source_y_fn = input_height - 1'b1;
                else
                    tap_source_y_fn = candidate[15:0];
            end
        end
    endfunction

    function automatic logic [31:0] operand_addr_fn(
        input logic [3:0] requested_tap
    );
        logic [15:0] source_x;
        logic [15:0] source_y;
        begin
            if ((opcode_q == OP_CONV3X3) ||
                (opcode_q == OP_DWCONV3X3)) begin
                source_x = tap_source_x_fn(output_x_q, stride_x_q,
                                           requested_tap, input_width_q);
                source_y = tap_source_y_fn(output_y_q, stride_y_q,
                                           requested_tap, input_height_q);
            end else if (opcode_q == OP_UPSAMPLE2) begin
                source_x = output_x_q >> 1;
                source_y = output_y_q >> 1;
            end else begin
                source_x = output_x_q;
                source_y = output_y_q;
            end
            operand_addr_fn = tensor_addr_fn(
                input_bank_q, input_width_q, input_groups_q,
                source_x, source_y, input_group_q);
        end
    endfunction

    // Unlike operand_addr_fn, these helpers normally retain the signed
    // pre-clamp coordinate.  The cache seam uses it to reproduce
    // SAME_REPLICATE while validating that mem_req_addr names the corresponding
    // clamped word.  The opt-in adapter contract publishes the physical,
    // already-clamped coordinate instead; this is safe because the address
    // path and the sideband then use exactly the same saturation functions.
    function automatic logic signed [16:0] operand_cache_x_fn(
        input logic [3:0] requested_tap
    );
        integer signed source_x;
        begin
            source_x = output_x_q;
            if ((opcode_q == OP_CONV3X3) ||
                (opcode_q == OP_DWCONV3X3))
                source_x = (source_x * stride_x_q) +
                           (requested_tap % 3) - 1;
            else if (opcode_q == OP_UPSAMPLE2)
                source_x = output_x_q >> 1;
            else
                source_x = output_x_q;
            if ((PRECLAMPED_TAP_COORDS != 0) &&
                ((opcode_q == OP_CONV3X3) ||
                 (opcode_q == OP_DWCONV3X3))) begin
                operand_cache_x_fn = $signed({1'b0,
                    tap_source_x_fn(output_x_q, stride_x_q,
                                    requested_tap, input_width_q)});
            end else begin
                operand_cache_x_fn = source_x[16:0];
            end
        end
    endfunction

    function automatic logic signed [16:0] operand_cache_y_fn(
        input logic [3:0] requested_tap
    );
        integer signed source_y;
        begin
            source_y = output_y_q;
            if ((opcode_q == OP_CONV3X3) ||
                (opcode_q == OP_DWCONV3X3))
                source_y = (source_y * stride_y_q) +
                           (requested_tap / 3) - 1;
            else if (opcode_q == OP_UPSAMPLE2)
                source_y = output_y_q >> 1;
            else
                source_y = output_y_q;
            if ((PRECLAMPED_TAP_COORDS != 0) &&
                ((opcode_q == OP_CONV3X3) ||
                 (opcode_q == OP_DWCONV3X3))) begin
                operand_cache_y_fn = $signed({1'b0,
                    tap_source_y_fn(output_y_q, stride_y_q,
                                    requested_tap, input_height_q)});
            end else begin
                operand_cache_y_fn = source_y[16:0];
            end
        end
    endfunction

    // The current external request is held in request_* registers, separate
    // from this scratch arithmetic context. Seed only after its address has
    // been computed, including chained fast-path requests.
    function automatic logic [3:0] next_operand_tap_fn(input logic [3:0] tap);
        if (REUSE_HORIZONTAL_WINDOW != 0 && window_reuse_q) begin
            if (stride_x_q == 1)
                next_operand_tap_fn = tap + 4'd3;
            else
                next_operand_tap_fn = tap + ((tap == 2 || tap == 5) ? 4'd2 : 4'd1);
        end else
            next_operand_tap_fn = tap + 4'd1;
    endfunction

    task automatic seed_tap_addr_prefetch(input logic [3:0] next_tap);
        begin
            addr_x_q <= tap_source_x_fn(output_x_q, stride_x_q,
                next_tap, input_width_q);
            addr_y_q <= tap_source_y_fn(output_y_q, stride_y_q,
                next_tap, input_height_q);
            addr_bank_q <= input_bank_q;
            addr_width_q <= input_width_q;
            addr_groups_q <= input_groups_q;
            addr_group_q <= input_group_q;
            tap_addr_prefetch_phase_q <= 3'd1;
        end
    endtask

    task automatic advance_tap_addr_prefetch;
        begin
            if (PREFETCH_NEXT_TAP_ADDRESS != 0 && PIPELINED_TENSOR_ADDRESS != 0) begin
                case (tap_addr_prefetch_phase_q)
                    1: begin
                        if (PIPELINED_TENSOR_PIXEL_INDEX != 0) begin
                            addr_row_product_q <= tensor_row_product_fn(addr_width_q, addr_y_q);
                            tap_addr_prefetch_phase_q <= 3'd2;
                        end else begin
                            addr_pixel_index_q <= tensor_pixel_index_fn(addr_width_q, addr_x_q, addr_y_q);
                            tap_addr_prefetch_phase_q <= 3'd3;
                        end
                    end
                    2: begin
                        addr_pixel_index_q <= addr_row_product_q + {16'd0, addr_x_q};
                        tap_addr_prefetch_phase_q <= 3'd3;
                    end
                    3: begin
                        tap_addr_prefetch_q <= tensor_addr_from_pixel_fn(
                            addr_bank_q, addr_pixel_index_q, addr_groups_q, addr_group_q);
                        tap_addr_prefetch_phase_q <= 3'd4;
                    end
                    default: ;
                endcase
            end
        end
    endtask

    task automatic enter_error(input logic [7:0] code);
        begin
            error_q <= 1'b1;
            error_code_q <= code;
            state_q <= ST_ERROR;
        end
    endtask

    // Compute LOGICAL coordinates directly. A preclamped scalar top tap
    // cannot be used to reconstruct this center at the top/bottom boundary.
    function automatic logic signed [16:0] column_x_at_fn(input logic [15:0] raster_x, input logic [3:0] col);
        logic signed [31:0] x;
        begin
            x = $signed({1'b0,raster_x}) * $signed({1'b0,stride_x_q}) +
                $signed({1'b0,col}) - 1;
            column_x_at_fn = x[16:0];
            if (pointwise_column_operand)
                column_x_at_fn = $signed({1'b0,raster_x});
            // Clamp in the LOGICAL enlarged image before halving. In
            // particular -1 must map to physical 0, not unsigned 32767.
            if (virtual_upsample_input)
                column_x_at_fn = $signed({1'b0,
                    tap_source_x_fn(raster_x, stride_x_q, col, input_width_q)}) >>> 1;
        end
    endfunction
    function automatic logic signed [16:0] column_center_y_at_fn(input logic [15:0] raster_y);
        logic [31:0] y;
        begin
            y = {16'b0,raster_y} * stride_y_q;
            column_center_y_at_fn = $signed(y[16:0]);
            if (pointwise_column_operand)
                column_center_y_at_fn = $signed({1'b0,raster_y});
            if (virtual_upsample_input)
                column_center_y_at_fn = $signed(y[16:0]) >>> 1;
        end
    endfunction
    function automatic logic signed [16:0] column_x_fn(input logic [3:0] col);
        column_x_fn = column_x_at_fn(output_x_q,col);
    endfunction
    function automatic logic signed [16:0] column_center_y_fn();
        column_center_y_fn = column_center_y_at_fn(output_y_q);
    endfunction
    assign column_operand = (ENABLE_COLUMN_READS != 0) &&
        (windowed_opcode || pointwise_column_operand);
    assign column_allow_pending_writes = OVERLAP_COLUMN_WRITEBACK &&
        (PIPELINED_RESULT_WRITES != 0) && column_operand &&
        (input_bank_q != output_bank_q);

    wire pixel_prefetch_seed = PREFETCH_NEXT_PIXEL_COLUMN && column_allow_pending_writes &&
        state_q==ST_ENGINE && adapter_engine_valid && adapter_engine_ready &&
        input_group_q==input_groups_q-1'b1 && !adapter_engine_eof &&
        !pixel_prefetch_busy && !error_q && !(result_write_retire && mem_rsp_error);
    always_ff @(posedge clk) begin
        if(rst) begin
            pixel_prefetch_state_q<=PF_EMPTY;
            pixel_prefetch_x_q<=0;pixel_prefetch_y_q<=0;
            pixel_prefetch_output_x_q<=0;pixel_prefetch_output_y_q<=0;
            pixel_prefetch_stage_q<=0;pixel_prefetch_tap_q<=0;
            pixel_prefetch_valid_q<='0;pixel_prefetch_errors_q<='0;
            pixel_prefetch_issue_group_q<=0;pixel_prefetch_groups_q<=0;pixel_prefetch_consumed_q<=0;
        end else begin
          if(pixel_prefetch_take) begin
              pixel_prefetch_valid_q[pixel_prefetch_read_slot]<=0;
              pixel_prefetch_consumed_q<=pixel_prefetch_consumed_q+1'b1;
          end
          case(pixel_prefetch_state_q)
            PF_EMPTY: if(pixel_prefetch_seed) begin
                pixel_prefetch_state_q<=PF_REQUEST;
                pixel_prefetch_x_q<=column_x_at_fn(next_pixel_x,next_pixel_tap);
                pixel_prefetch_y_q<=column_center_y_at_fn(next_pixel_y);
                pixel_prefetch_output_x_q<=next_pixel_x;pixel_prefetch_output_y_q<=next_pixel_y;
                pixel_prefetch_stage_q<=stage_index_q;pixel_prefetch_tap_q<=next_pixel_tap;
                pixel_prefetch_issue_group_q<=0;pixel_prefetch_consumed_q<=0;
                pixel_prefetch_groups_q<=PREFETCH_ALL_PIXEL_GROUPS ? input_groups_q : 4'd1;
                pixel_prefetch_valid_q<='0;pixel_prefetch_errors_q<='0;
            end
            // Offered/accepted requests remain owned even on fault/cancel.
            PF_REQUEST: if(column_req_valid && column_req_ready) pixel_prefetch_state_q<=PF_RESPONSE;
            PF_RESPONSE: if(column_rsp_valid && column_rsp_ready) begin
                pixel_prefetch_data_bank[pixel_prefetch_issue_group_q]<=column_rsp_data_s8;
                pixel_prefetch_valid_q[pixel_prefetch_issue_group_q]<=1;
                pixel_prefetch_errors_q[pixel_prefetch_issue_group_q]<=column_rsp_error;
                if(({1'b0,pixel_prefetch_issue_group_q}+4'd1)<pixel_prefetch_groups_q &&
                   !column_rsp_error && !error_q && !adapter_abort && !abort_pending_q &&
                   !(result_write_retire && mem_rsp_error)) begin
                    pixel_prefetch_issue_group_q<=pixel_prefetch_issue_group_q+1'b1;
                    pixel_prefetch_state_q<=PF_REQUEST;
                end else pixel_prefetch_state_q<=PF_READY;
            end
            PF_READY: if((pixel_prefetch_consumed_q+(pixel_prefetch_take?4'd1:4'd0)==pixel_prefetch_groups_q) ||
                         error_q || adapter_abort || abort_pending_q)
                pixel_prefetch_state_q<=PF_EMPTY;
          endcase
        end
    end

    assign active_descriptor = descriptor_cache[stage_index_q];
    c1_pixel_result_writer #(.BATCH_WORDS(PIXEL_WRITE_BATCH_WORDS),.MULTI_GROUP(PIPELINE_DW_PIXELS || PIPELINE_ALL_DOT_GROUPS)) u_pixel_writer (
        .clk,.rst,.abort(adapter_abort || abort_pending_q || error_q),
        .start_valid(cache_stage_start_valid && cache_stage_start_ready && pixel_stream_eligible),
        .start_ready(pixel_sink_start_ready),.start_base(tensor_bank_base_fn(output_bank_q)),
        .start_width(output_width_q),.start_height(output_height_q),
        .start_groups(output_groups_q),
        .in_valid(adapter_result_valid && pixel_stream_q),.in_ready(pixel_sink_ready),
        .in_data(adapter_result_data_s8),.in_group(adapter_result_group_index),
        .in_group_last(adapter_result_group_last),.in_x(adapter_result_x),.in_y(adapter_result_y),
        .in_sof(adapter_result_sof),.in_eol(adapter_result_eol),.in_eof(adapter_result_eof),
        .mem_req_valid(pixel_sink_req_valid),.mem_req_ready(mem_req_ready && pixel_stream_q),
        .mem_req_addr(pixel_sink_req_addr),.mem_req_data(pixel_sink_req_data),.mem_req_end(pixel_sink_req_end),
        .mem_rsp_valid(mem_rsp_valid && pixel_stream_q),.mem_rsp_ready(pixel_sink_rsp_ready),
        .mem_rsp_error(mem_rsp_error),.busy(pixel_sink_busy),.done(pixel_sink_done),
        .aborted(),.error(pixel_sink_error),.error_code(pixel_sink_error_code)
    );
    assign windowed_opcode = (opcode_q == OP_CONV3X3) ||
                             (opcode_q == OP_DWCONV3X3);

    always_comb begin
        memory_request_state = (state_q == ST_SOURCE_REQ) ||
                               ((state_q == ST_READ_REQ) && !column_operand) ||
                               (state_q == ST_RESIDUAL_REQ) ||
                               (state_q == ST_WRITE_REQ);
        memory_response_state = (state_q == ST_SOURCE_RSP) ||
                                ((state_q == ST_READ_RSP) && !column_operand) ||
                                (state_q == ST_RESIDUAL_RSP) ||
                                (state_q == ST_WRITE_RSP);

        adapter_start_ready = (state_q == ST_IDLE) && !rst &&
                              !adapter_abort && !abort_pending_q && !pixel_sink_busy;
        adapter_stage_config_ready = (state_q == ST_CONFIG) &&
                                     !abort_pending_q && !adapter_abort;
        adapter_source_ready = (state_q == ST_SOURCE) &&
                               !abort_pending_q && !adapter_abort &&
                               (!PIPELINED_SOURCE_WRITES ||
                                (source_writes_pending_q < 15 && !error_q &&
                                 !(source_write_retire && mem_rsp_error)));

        cache_stage_start_valid =
            (ENABLE_WINDOW_CACHE_SIDEBAND != 0) &&
            (state_q == ST_CACHE_CONFIG) &&
            !abort_pending_q && !adapter_abort && (!pixel_stream_eligible || pixel_sink_start_ready);
        cache_stage_enable = windowed_opcode || pointwise_column_operand;
        cache_stage_base_addr = tensor_bank_base_fn(input_bank_q);
        cache_stage_width = virtual_upsample_input ? input_width_q >> 1 : input_width_q;
        cache_stage_height = virtual_upsample_input ? input_height_q >> 1 : input_height_q;
        cache_stage_groups = input_groups_q;

        view_commit_valid = (state_q==ST_ENGINE) && view_layer &&
                            !abort_pending_q && !adapter_abort && !error_q &&
                            !pixel_prefetch_busy && !pixel_sink_busy &&
                            source_writes_pending_q==0 && result_writes_pending_q==0 &&
                            (!fused_final_view || (fused_final_pending_q && final_eof_q));
        view_commit_stage = stage_index_q;
        view_commit_generation = config_generation_q;
        adapter_engine_valid = (state_q == ST_ENGINE) && !view_layer &&
                               !abort_pending_q && !adapter_abort;
        adapter_engine_window_s8 = window_q;
        adapter_engine_residual_s8 = residual_q;
        adapter_engine_group_index = input_group_q;
        adapter_engine_group_last =
            (input_group_q == input_groups_q - 1'b1);
        adapter_engine_x = output_x_q;
        adapter_engine_y = output_y_q;
        adapter_engine_sof = (output_x_q == 0) && (output_y_q == 0);
        adapter_engine_eol = (output_x_q == output_width_q - 1'b1);
        adapter_engine_eof = adapter_engine_eol &&
                             (output_y_q == output_height_q - 1'b1);

        adapter_result_ready = (state_q == ST_RESULT) &&
                               !abort_pending_q && !adapter_abort &&
                               (!OVERLAP_COLUMN_WRITEBACK || result_writes_pending_q < 15);
        if(pixel_stream_q) adapter_result_ready=pixel_sink_ready;
        if(fused_compute_layer)
            adapter_result_ready = config_complete_q && state_q!=ST_IDLE &&
                state_q!=ST_STAGE_LOAD && state_q!=ST_CACHE_CONFIG &&
                !abort_pending_q && !adapter_abort && !error_q &&
                (!fused_final_pending_q || adapter_final_ready);

        // The final beat is validated and captured before it is exposed.  An
        // engine protocol fault therefore cannot leak a malformed pixel to the
        // board/output DMA in the same cycle that ERR_RESULT is raised.
        adapter_final_valid = (state_q == ST_FINAL) &&
                              !abort_pending_q && !adapter_abort;
        if(FUSE_FINAL_OUTPUT)
            adapter_final_valid = fused_final_pending_q && !abort_pending_q && !adapter_abort && !error_q;
        adapter_final_data_s8 = final_data_q;
        adapter_final_x = final_x_q;
        adapter_final_y = final_y_q;
        adapter_final_sof = final_sof_q;
        adapter_final_eol = final_eol_q;
        adapter_final_eof = final_eof_q;

        mem_req_valid = memory_request_state;
        mem_req_write = request_write_q;
        // Legacy source writes are single-request batches. Result writes may pack
        // output groups. An end marker always closes the pixel's write batch,
        // including when distinct-bank columns overlap older write retirement.
        mem_req_end = (state_q == ST_WRITE_REQ) ? result_group_last_q : 1'b1;
        if (PIPELINED_SOURCE_WRITES && state_q == ST_SOURCE_REQ)
            mem_req_end = source_x_q[2:0] == 3'd7 ||
                          source_x_q == descriptor_cache[0][47:32] - 1'b1;
        mem_req_addr = request_addr_q;
        mem_req_wdata = request_wdata_q;
        mem_req_wstrb = request_wstrb_q;
        mem_req_cacheable = request_cacheable_q;
        mem_req_cache_x = request_cache_x_q;
        mem_req_cache_y = request_cache_y_q;
        mem_req_cache_group = request_cache_group_q;
        mem_rsp_ready = memory_response_state;
        if (PIPELINED_RESULT_WRITES != 0)
            mem_rsp_ready = (result_writes_pending_q != 0) ||
                           (memory_response_state && state_q != ST_WRITE_RSP);
        if (PIPELINED_SOURCE_WRITES)
            mem_rsp_ready = (source_writes_pending_q != 0) ||
                           (mem_rsp_ready && state_q != ST_SOURCE_RSP);
        if(pixel_stream_q) begin
            mem_req_valid=pixel_sink_req_valid;mem_req_write=1;
            mem_req_addr=pixel_sink_req_addr;mem_req_wdata=pixel_sink_req_data;
            mem_req_wstrb=8'hff;mem_req_end=pixel_sink_req_end;
            mem_req_cacheable=0;mem_req_cache_x=0;mem_req_cache_y=0;mem_req_cache_group=0;
            mem_rsp_ready=pixel_sink_rsp_ready;
        end

        column_req_valid = !rst && (pixel_prefetch_state_q==PF_REQUEST ||
            (column_operand && state_q==ST_READ_REQ && !pixel_prefetch_bus_busy));
        column_req_x = pixel_prefetch_state_q==PF_REQUEST ? pixel_prefetch_x_q : request_cache_x_q;
        column_req_center_y = pixel_prefetch_state_q==PF_REQUEST ? pixel_prefetch_y_q : request_cache_y_q;
        column_req_group = pixel_prefetch_state_q==PF_REQUEST ? pixel_prefetch_issue_group_q : request_cache_group_q;
        column_rsp_ready = !rst && (pixel_prefetch_state_q==PF_RESPONSE ||
            (column_operand && state_q==ST_READ_RSP && !pixel_prefetch_bus_busy && !pixel_prefetch_select));

        adapter_error = error_q;
        adapter_error_code = error_code_q;
        adapter_busy = (state_q != ST_IDLE);
        adapter_config_complete = config_complete_q;
        active_stage_index = stage_index_q;
        active_stage_opcode = opcode_q;
        active_input_bank = input_bank_q;
        active_output_bank = output_bank_q;
        active_residual_bank = residual_bank_q;

        source_protocol_valid =
            (adapter_source_x == source_x_q) &&
            (adapter_source_y == source_y_q) &&
            (adapter_source_sof ==
                ((source_x_q == 0) && (source_y_q == 0))) &&
            (adapter_source_eol ==
                (source_x_q == descriptor_cache[0][47:32] - 1'b1)) &&
            (adapter_source_eof ==
                ((source_x_q == descriptor_cache[0][47:32] - 1'b1) &&
                 (source_y_q == descriptor_cache[0][63:48] - 1'b1)));

        result_protocol_valid =
            (adapter_result_group_index == expected_result_group_q) &&
            (adapter_result_group_last ==
                (expected_result_group_q == output_groups_q - 1'b1)) &&
            (adapter_result_x == output_x_q) &&
            (adapter_result_y == output_y_q) &&
            (adapter_result_sof ==
                ((expected_result_group_q == 0) &&
                 (output_x_q == 0) && (output_y_q == 0))) &&
            (adapter_result_eol ==
                ((expected_result_group_q == output_groups_q - 1'b1) &&
                 (output_x_q == output_width_q - 1'b1))) &&
            (adapter_result_eof ==
                ((expected_result_group_q == output_groups_q - 1'b1) &&
                 (output_x_q == output_width_q - 1'b1) &&
                 (output_y_q == output_height_q - 1'b1)));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_IDLE;
            config_index_q <= 16'd0;
            config_generation_q <= 8'd0;
            config_generation_valid_q <= 1'b0;
            capture_prev_width_q <= 16'd0;
            capture_prev_height_q <= 16'd0;
            capture_prev_channels_q <= 16'd0;
            config_complete_q <= 1'b0;
            descriptor_pending_q <= '0;
            descriptor_pending_index_q <= 16'd0;
            descriptor_pending_generation_q <= 8'd0;
            descriptor_pending_prev_width_q <= 16'd0;
            descriptor_pending_prev_height_q <= 16'd0;
            descriptor_pending_prev_channels_q <= 16'd0;
            descriptor_pending_error_q <= ERR_NONE;
            descriptor_validation_result_q <= 1'b0;
            descriptor_basic_result_q <= 1'b0;
            descriptor_input_size_result_q <= 1'b0;
            descriptor_output_size_result_q <= 1'b0;
            descriptor_context_result_q <= 1'b0;
            descriptor_kernel_result_q <= 1'b0;
            descriptor_shape_result_q <= 1'b0;
            descriptor_size_pixel_count_narrow_q <= 32'd0;
            descriptor_size_bytes_per_group_narrow_q <= 17'd0;
            descriptor_size_pixel_count_wide_q <= 64'd0;
            descriptor_size_bytes_per_group_wide_q <= 64'd0;
            descriptor_size_product_q <= 64'd0;
            descriptor_size_limit_result_q <= 1'b0;
            descriptor_size_arith_output_q <= 1'b0;
            descriptor_size_width_q <= 16'd0;
            descriptor_size_height_q <= 16'd0;
            descriptor_size_pixel_pending_q <= 1'b0;
            descriptor_size_iter_acc_q <= 32'd0;
            descriptor_size_iter_multiplicand_q <= 32'd0;
            descriptor_size_iter_multiplier_q <= 16'd0;
            descriptor_size_iter_count_q <= 5'd0;
            descriptor_size_iter_pending_q <= 1'b0;
            tensor_base_q <= 32'd0;
            error_q <= 1'b0;
            error_code_q <= ERR_NONE;
            abort_pending_q <= 1'b0;
            abort_seen_q <= 1'b0;
            adapter_done <= 1'b0;
            pixel_stream_q <= 1'b0;
            adapter_aborted <= 1'b0;
            stage_index_q <= 5'd0;
            opcode_q <= 8'd0;
            input_width_q <= 16'd0;
            input_height_q <= 16'd0;
            output_width_q <= 16'd0;
            output_height_q <= 16'd0;
            input_channels_q <= 16'd0;
            output_channels_q <= 16'd0;
            stride_x_q <= 8'd0;
            stride_y_q <= 8'd0;
            input_groups_q <= 4'd0;
            output_groups_q <= 4'd0;
            input_bank_q <= 2'd0;
            output_bank_q <= 2'd0;
            residual_bank_q <= 2'd3;
            source_x_q <= 16'd0;
            source_y_q <= 16'd0;
            source_eof_q <= 1'b0;
            output_x_q <= 16'd0;
            output_y_q <= 16'd0;
            input_group_q <= 3'd0;
            tap_q <= 4'd0;
            operand_source_x_q <= 16'd0;
            operand_source_y_q <= 16'd0;
            addr_bank_q <= 2'd0;
            addr_width_q <= 16'd0;
            addr_groups_q <= 4'd0;
            addr_x_q <= 16'd0;
            addr_y_q <= 16'd0;
            addr_group_q <= 3'd0;
            addr_row_product_q <= 32'd0;
            addr_pixel_index_q <= 32'd0;
            tap_addr_prefetch_phase_q <= 3'd0;
            tap_addr_prefetch_q <= 32'd0;
            addr_kind_q <= ADDR_KIND_SOURCE;
            window_q <= 576'd0;
            window_history_valid_q <= 8'd0;
            window_reuse_q <= 1'b0;
            residual_q <= 64'd0;
            expected_result_group_q <= 3'd0;
            request_write_q <= 1'b0;
            request_addr_q <= 32'd0;
            request_wdata_q <= 64'd0;
            request_wstrb_q <= 8'd0;
            request_cacheable_q <= 1'b0;
            request_cache_x_q <= 17'sd0;
            request_cache_y_q <= 17'sd0;
            request_cache_group_q <= 3'd0;
            result_group_last_q <= 1'b0;
            result_eof_q <= 1'b0;
            final_data_q <= 64'd0;
            fused_final_pending_q<=0;fused_have_result_q<=0;
            final_x_q <= 16'd0;
            final_y_q <= 16'd0;
            final_sof_q <= 1'b0;
            final_eol_q <= 1'b0;
            final_eof_q <= 1'b0;
            final_group_last_q <= 1'b0;
            // The descriptor cache is intentionally not reset; entries are
            // consumed only after a complete validated snapshot is captured.
        end else begin
            adapter_done <= 1'b0;
            if(state_q==ST_IDLE || state_q==ST_STAGE_LOAD) pixel_stream_q<=0;
            adapter_aborted <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (adapter_start_valid && adapter_start_ready) begin
                        fused_final_pending_q<=0;fused_have_result_q<=0;
                        tensor_base_q <= tensor_base_addr;
                        config_index_q <= 16'd0;
                        config_generation_valid_q <= 1'b0;
                        capture_prev_width_q <= 16'd0;
                        capture_prev_height_q <= 16'd0;
                        capture_prev_channels_q <= 16'd0;
                        config_complete_q <= 1'b0;
                        descriptor_pending_q <= '0;
                        descriptor_pending_index_q <= 16'd0;
                        descriptor_pending_generation_q <= 8'd0;
                        descriptor_pending_prev_width_q <= 16'd0;
                        descriptor_pending_prev_height_q <= 16'd0;
                        descriptor_pending_prev_channels_q <= 16'd0;
                        descriptor_pending_error_q <= ERR_NONE;
                        descriptor_validation_result_q <= 1'b0;
                        descriptor_basic_result_q <= 1'b0;
                        descriptor_input_size_result_q <= 1'b0;
                        descriptor_output_size_result_q <= 1'b0;
                        descriptor_context_result_q <= 1'b0;
                        descriptor_kernel_result_q <= 1'b0;
                        descriptor_shape_result_q <= 1'b0;
                        descriptor_size_pixel_count_narrow_q <= 32'd0;
                        descriptor_size_bytes_per_group_narrow_q <= 17'd0;
                        descriptor_size_pixel_count_wide_q <= 64'd0;
                        descriptor_size_bytes_per_group_wide_q <= 64'd0;
                        descriptor_size_product_q <= 64'd0;
                        descriptor_size_limit_result_q <= 1'b0;
                        descriptor_size_arith_output_q <= 1'b0;
                        descriptor_size_width_q <= 16'd0;
                        descriptor_size_height_q <= 16'd0;
                        descriptor_size_pixel_pending_q <= 1'b0;
                        descriptor_size_iter_acc_q <= 32'd0;
                        descriptor_size_iter_multiplicand_q <= 32'd0;
                        descriptor_size_iter_multiplier_q <= 16'd0;
                        descriptor_size_iter_count_q <= 5'd0;
                        descriptor_size_iter_pending_q <= 1'b0;
                        error_q <= 1'b0;
                        error_code_q <= ERR_NONE;
                        abort_pending_q <= 1'b0;
                        stage_index_q <= 5'd0;
                        if (tensor_base_addr[2:0] != 0 ||
                            (TENSOR_BANK_BYTES <= 0) ||
                            ((TENSOR_BANK_BYTES % 8) != 0) ||
                            (REQUIRED_STAGES != 22) ||
                            ({1'b0, tensor_base_addr} +
                             (3 * TENSOR_BANK_BYTES) > 33'h1_0000_0000)) begin
                            enter_error(ERR_START_BASE);
                        end else begin
                            state_q <= ST_CONFIG;
                        end
                    end
                end

                ST_CONFIG: begin
                    if (adapter_stage_config_valid &&
                        adapter_stage_config_ready) begin
                        if (PIPELINED_DESCRIPTOR_VALIDATION != 0) begin
                            // Capture the complete record and the context
                            // against which it must be checked.  The wide
                            // descriptor payload is therefore not in the
                            // same-cycle cache CE decision.
                            descriptor_pending_q <=
                                adapter_stage_config_descriptor;
                            descriptor_pending_index_q <= config_index_q;
                            descriptor_pending_generation_q <=
                                adapter_stage_config_generation;
                            descriptor_pending_prev_width_q <=
                                capture_prev_width_q;
                            descriptor_pending_prev_height_q <=
                                capture_prev_height_q;
                            descriptor_pending_prev_channels_q <=
                                capture_prev_channels_q;
                            descriptor_pending_error_q <= ERR_NONE;
                            descriptor_validation_result_q <= 1'b1;

                            // Preserve the legacy error priority: ordering
                            // and generation mismatches dominate descriptor
                            // topology errors.  A relaxed build still checks
                            // the software artifact in simulation, but does
                            // not synthesize the checker into this path.
                            if (adapter_stage_config_index != config_index_q) begin
                                descriptor_pending_error_q <= ERR_CONFIG_ORDER;
                                state_q <= ST_CONFIG_COMMIT;
                            end else if (config_generation_valid_q &&
                                         (adapter_stage_config_generation !=
                                          config_generation_q)) begin
                                descriptor_pending_error_q <= ERR_CONFIG_GEN;
                                state_q <= ST_CONFIG_COMMIT;
                            end else if (STRICT_DESCRIPTOR_VALIDATION != 0) begin
                                state_q <= ST_CONFIG_VALIDATE;
                            end else begin
`ifndef SYNTHESIS
                                if (!descriptor_valid_fn(
                                        config_index_q[4:0],
                                        adapter_stage_config_descriptor,
                                        capture_prev_width_q,
                                        capture_prev_height_q,
                                        capture_prev_channels_q))
                                    $fatal(1,
                                           "relaxed descriptor path received invalid ABI stage=%0d",
                                           config_index_q);
`endif
                                state_q <= ST_CONFIG_COMMIT;
                            end
                        end else begin
`ifndef SYNTHESIS
                        if ((STRICT_DESCRIPTOR_VALIDATION == 0) &&
                            !descriptor_valid_fn(
                                config_index_q[4:0],
                                adapter_stage_config_descriptor,
                                capture_prev_width_q,
                                capture_prev_height_q,
                                capture_prev_channels_q))
                            $fatal(1,
                                   "relaxed descriptor path received invalid ABI stage=%0d",
                                   config_index_q);
`endif
                        if (adapter_stage_config_index != config_index_q) begin
                            enter_error(ERR_CONFIG_ORDER);
                        end else if (config_generation_valid_q &&
                                     (adapter_stage_config_generation !=
                                      config_generation_q)) begin
                            enter_error(ERR_CONFIG_GEN);
                        end else if ((STRICT_DESCRIPTOR_VALIDATION != 0) &&
                                     !descriptor_valid_fn(
                                config_index_q[4:0],
                                adapter_stage_config_descriptor,
                                capture_prev_width_q,
                                capture_prev_height_q,
                                capture_prev_channels_q)) begin
                            enter_error(ERR_DESCRIPTOR);
                        end else begin
                            descriptor_cache[config_index_q[4:0]] <=
                                adapter_stage_config_descriptor;
                            if (!config_generation_valid_q) begin
                                config_generation_q <=
                                    adapter_stage_config_generation;
                                config_generation_valid_q <= 1'b1;
                            end
                            capture_prev_width_q <=
                                adapter_stage_config_descriptor[79:64];
                            capture_prev_height_q <=
                                adapter_stage_config_descriptor[95:80];
                            capture_prev_channels_q <=
                                adapter_stage_config_descriptor[127:112];
                            if (config_index_q == REQUIRED_STAGES - 1) begin
                                config_complete_q <= 1'b1;
                                source_x_q <= 16'd0;
                                source_y_q <= 16'd0;
                                state_q <= ST_SOURCE;
                            end else begin
                                config_index_q <= config_index_q + 1'b1;
                            end
                        end
                        end
                    end
                end

                ST_CONFIG_VALIDATE: begin
                    // First evaluate only field/opcode/range predicates.
                    // Size products and geometry divisions are deliberately
                    // placed behind additional flops below.
                    descriptor_basic_result_q <= descriptor_basic_valid_fn(
                        descriptor_pending_index_q[4:0],
                        descriptor_pending_q);
                    state_q <= ST_CONFIG_VALIDATE_SIZE_IN;
                end

                ST_CONFIG_VALIDATE_SIZE_IN: begin
                    if ((PIPELINED_DESCRIPTOR_SIZE_ARITH != 0) &&
                        (PIPELINED_DESCRIPTOR_VALIDATION != 0)) begin
                        // Stage 1: capture the size operands.  The product
                        // and bank-limit compare happen in later states.
                        if (NARROW_DESCRIPTOR_SIZE_CHECK != 0) begin
                            if (ITERATIVE_DESCRIPTOR_PIXEL_COUNT_ACTIVE) begin
                                // Seed an unsigned shift/add W*H multiply.
                                // The shared arithmetic state consumes the
                                // registered operands for exactly 16 cycles;
                                // a separate consume visit publishes the
                                // accumulated product before thresholding.
                                descriptor_size_width_q <=
                                    descriptor_pending_q[47:32];
                                descriptor_size_height_q <=
                                    descriptor_pending_q[63:48];
                                descriptor_size_iter_acc_q <= 32'd0;
                                descriptor_size_iter_multiplicand_q <=
                                    {16'd0, descriptor_pending_q[47:32]};
                                descriptor_size_iter_multiplier_q <=
                                    descriptor_pending_q[63:48];
                                descriptor_size_iter_count_q <= 5'd0;
                                descriptor_size_iter_pending_q <= 1'b1;
                                descriptor_size_pixel_pending_q <= 1'b0;
                            end else if (PIPELINED_DESCRIPTOR_PIXEL_COUNT_ACTIVE) begin
                                descriptor_size_width_q <=
                                    descriptor_pending_q[47:32];
                                descriptor_size_height_q <=
                                    descriptor_pending_q[63:48];
                                descriptor_size_pixel_pending_q <= 1'b1;
                            end else begin
                                descriptor_size_pixel_count_narrow_q <=
                                    tensor_pixel_count_narrow_fn(
                                        descriptor_pending_q[47:32],
                                        descriptor_pending_q[63:48]);
                                descriptor_size_pixel_pending_q <= 1'b0;
                            end
                            descriptor_size_bytes_per_group_narrow_q <=
                                tensor_bytes_per_group_narrow_fn(
                                    descriptor_pending_q[111:96]);
                        end else begin
                            descriptor_size_pixel_pending_q <= 1'b0;
                            descriptor_size_pixel_count_wide_q <=
                                tensor_pixel_count_wide_fn(
                                    descriptor_pending_q[47:32],
                                    descriptor_pending_q[63:48]);
                            descriptor_size_bytes_per_group_wide_q <=
                                tensor_bytes_per_group_wide_fn(
                                    descriptor_pending_q[111:96]);
                        end
                        descriptor_size_arith_output_q <= 1'b0;
                        state_q <= ST_CONFIG_VALIDATE_SIZE_ARITH;
                    end else begin
                        descriptor_input_size_result_q <=
                            tensor_size_within_bank_fn(
                                descriptor_pending_q[47:32],
                                descriptor_pending_q[63:48],
                                descriptor_pending_q[111:96]);
                        state_q <= ST_CONFIG_VALIDATE_SIZE_OUT;
                    end
                end

                ST_CONFIG_VALIDATE_SIZE_OUT: begin
                    if ((PIPELINED_DESCRIPTOR_SIZE_ARITH != 0) &&
                        (PIPELINED_DESCRIPTOR_VALIDATION != 0)) begin
                        // The shared arithmetic state has just produced the
                        // input product.  Compare it here, then capture the
                        // output W*H/group-byte operands for the next visit.
                        if (FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE)
                            descriptor_input_size_result_q <=
                                descriptor_size_limit_result_q;
                        else
                            descriptor_input_size_result_q <=
                                (descriptor_size_product_q <= TENSOR_BANK_BYTES);
                        if (NARROW_DESCRIPTOR_SIZE_CHECK != 0) begin
                            if (ITERATIVE_DESCRIPTOR_PIXEL_COUNT_ACTIVE) begin
                                descriptor_size_width_q <=
                                    descriptor_pending_q[79:64];
                                descriptor_size_height_q <=
                                    descriptor_pending_q[95:80];
                                descriptor_size_iter_acc_q <= 32'd0;
                                descriptor_size_iter_multiplicand_q <=
                                    {16'd0, descriptor_pending_q[79:64]};
                                descriptor_size_iter_multiplier_q <=
                                    descriptor_pending_q[95:80];
                                descriptor_size_iter_count_q <= 5'd0;
                                descriptor_size_iter_pending_q <= 1'b1;
                                descriptor_size_pixel_pending_q <= 1'b0;
                            end else if (PIPELINED_DESCRIPTOR_PIXEL_COUNT_ACTIVE) begin
                                descriptor_size_width_q <=
                                    descriptor_pending_q[79:64];
                                descriptor_size_height_q <=
                                    descriptor_pending_q[95:80];
                                descriptor_size_pixel_pending_q <= 1'b1;
                            end else begin
                                descriptor_size_pixel_count_narrow_q <=
                                    tensor_pixel_count_narrow_fn(
                                        descriptor_pending_q[79:64],
                                        descriptor_pending_q[95:80]);
                                descriptor_size_pixel_pending_q <= 1'b0;
                            end
                            descriptor_size_bytes_per_group_narrow_q <=
                                tensor_bytes_per_group_narrow_fn(
                                    descriptor_pending_q[127:112]);
                        end else begin
                            descriptor_size_pixel_pending_q <= 1'b0;
                            descriptor_size_pixel_count_wide_q <=
                                tensor_pixel_count_wide_fn(
                                    descriptor_pending_q[79:64],
                                    descriptor_pending_q[95:80]);
                            descriptor_size_bytes_per_group_wide_q <=
                                tensor_bytes_per_group_wide_fn(
                                    descriptor_pending_q[127:112]);
                        end
                        descriptor_size_arith_output_q <= 1'b1;
                        state_q <= ST_CONFIG_VALIDATE_SIZE_ARITH;
                    end else begin
                        descriptor_output_size_result_q <=
                            tensor_size_within_bank_fn(
                                descriptor_pending_q[79:64],
                                descriptor_pending_q[95:80],
                                descriptor_pending_q[127:112]);
                        state_q <= ST_CONFIG_VALIDATE_GEOM;
                    end
                end

                ST_CONFIG_VALIDATE_SIZE_ARITH: begin
                    if (ITERATIVE_DESCRIPTOR_PIXEL_COUNT_ACTIVE &&
                        descriptor_size_iter_pending_q) begin
                        // One bit of the multiplier is consumed per visit.
                        // Counts 0..15 perform the 16 shift/add operations.
                        // Count 16 is a separate consume visit: reading the
                        // already-registered accumulator here avoids an NBA
                        // stale-value hazard on the final add.  Threshold
                        // comparison is deferred one more visit below.
                        if (descriptor_size_iter_count_q == 5'd16) begin
                            descriptor_size_pixel_count_narrow_q <=
                                descriptor_size_iter_acc_q;
                            descriptor_size_iter_pending_q <= 1'b0;
                            descriptor_size_iter_count_q <= 5'd0;
                            state_q <= ST_CONFIG_VALIDATE_SIZE_ARITH;
                        end else begin
                            if (descriptor_size_iter_multiplier_q[0])
                                descriptor_size_iter_acc_q <=
                                    descriptor_size_iter_acc_q +
                                    descriptor_size_iter_multiplicand_q;
                            descriptor_size_iter_multiplicand_q <=
                                descriptor_size_iter_multiplicand_q << 1;
                            descriptor_size_iter_multiplier_q <=
                                descriptor_size_iter_multiplier_q >> 1;
                            descriptor_size_iter_count_q <=
                                descriptor_size_iter_count_q + 5'd1;
                            state_q <= ST_CONFIG_VALIDATE_SIZE_ARITH;
                        end
                    end else if (PIPELINED_DESCRIPTOR_PIXEL_COUNT_ACTIVE &&
                        descriptor_size_pixel_pending_q) begin
                        // Optional extra boundary: form W*H only after W/H
                        // have been captured from descriptor_pending_q.  Keep
                        // the state for one more cycle so the threshold or
                        // generic size product consumes a registered count.
                        descriptor_size_pixel_count_narrow_q <=
                            tensor_pixel_count_narrow_fn(
                                descriptor_size_width_q,
                                descriptor_size_height_q);
                        descriptor_size_pixel_pending_q <= 1'b0;
                        state_q <= ST_CONFIG_VALIDATE_SIZE_ARITH;
                    end else begin
                        // Stage 2: multiply the registered pixel count by the
                        // registered bytes-per-pixel-group, or use the fixed
                        // Case-1 threshold comparator.  The following state
                        // performs only the bank-limit compare, so no size
                        // arithmetic feeds descriptor_*_size_result_q in the
                        // same cycle.
                        if (FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE) begin
                            descriptor_size_limit_result_q <=
                                fixed_descriptor_size_limit_fn(
                                    descriptor_size_pixel_count_narrow_q,
                                    descriptor_size_bytes_per_group_narrow_q);
                            descriptor_size_product_q <= 64'd0;
                        end else if (NARROW_DESCRIPTOR_SIZE_CHECK != 0) begin
                            descriptor_size_product_q <=
                                {16'd0, tensor_size_product_narrow_fn(
                                    descriptor_size_pixel_count_narrow_q,
                                    descriptor_size_bytes_per_group_narrow_q)};
                        end else begin
                            descriptor_size_product_q <=
                                tensor_size_product_wide_fn(
                                    descriptor_size_pixel_count_wide_q,
                                    descriptor_size_bytes_per_group_wide_q);
                        end
                        if (descriptor_size_arith_output_q)
                            state_q <= ST_CONFIG_VALIDATE_GEOM;
                        else
                            state_q <= ST_CONFIG_VALIDATE_SIZE_OUT;
                    end
                end

                ST_CONFIG_VALIDATE_GEOM: begin
                    if ((PIPELINED_DESCRIPTOR_SIZE_ARITH != 0) &&
                        (PIPELINED_DESCRIPTOR_VALIDATION != 0)) begin
                        // The output product was registered on the previous
                        // shared arithmetic visit.  Keep this compare as a
                        // separate assignment from the geometry predicate.
                        if (FIXED_DESCRIPTOR_SIZE_LIMITS_ACTIVE)
                            descriptor_output_size_result_q <=
                                descriptor_size_limit_result_q;
                        else
                            descriptor_output_size_result_q <=
                                (descriptor_size_product_q <= TENSOR_BANK_BYTES);
                    end
                    descriptor_context_result_q <= descriptor_context_valid_fn(
                        descriptor_pending_index_q[4:0],
                        descriptor_pending_q,
                        descriptor_pending_prev_width_q,
                        descriptor_pending_prev_height_q,
                        descriptor_pending_prev_channels_q);
                    state_q <= ST_CONFIG_VALIDATE_KERNEL;
                end

                ST_CONFIG_VALIDATE_KERNEL: begin
                    descriptor_kernel_result_q <= descriptor_kernel_valid_fn(
                        descriptor_pending_index_q[4:0],
                        descriptor_pending_q);
                    state_q <= ST_CONFIG_VALIDATE_SHAPE;
                end

                ST_CONFIG_VALIDATE_SHAPE: begin
                    descriptor_shape_result_q <= descriptor_shape_valid_fn(
                        descriptor_pending_index_q[4:0],
                        descriptor_pending_q);
                    // This compact aggregate intentionally excludes the
                    // shape function evaluated above; context, kernel and
                    // shape each have their own register boundary and are
                    // checked separately in ST_CONFIG_COMMIT.
                    descriptor_validation_result_q <=
                        descriptor_basic_result_q &&
                        descriptor_input_size_result_q &&
                        descriptor_output_size_result_q &&
                        descriptor_context_result_q &&
                        descriptor_kernel_result_q;
                    state_q <= ST_CONFIG_COMMIT;
                end

                ST_CONFIG_COMMIT: begin
                    if (descriptor_pending_error_q != ERR_NONE) begin
                        enter_error(descriptor_pending_error_q);
                    end else if ((STRICT_DESCRIPTOR_VALIDATION != 0) &&
                                 (!descriptor_basic_result_q ||
                                  !descriptor_input_size_result_q ||
                                  !descriptor_output_size_result_q ||
                                  !descriptor_context_result_q ||
                                  !descriptor_kernel_result_q ||
                                  !descriptor_shape_result_q ||
                                  !descriptor_validation_result_q)) begin
                        enter_error(ERR_DESCRIPTOR);
                    end else begin
                        descriptor_cache[descriptor_pending_index_q[4:0]] <=
                            descriptor_pending_q;
                        if (!config_generation_valid_q) begin
                            config_generation_q <=
                                descriptor_pending_generation_q;
                            config_generation_valid_q <= 1'b1;
                        end
                        capture_prev_width_q <=
                            descriptor_pending_q[79:64];
                        capture_prev_height_q <=
                            descriptor_pending_q[95:80];
                        capture_prev_channels_q <=
                            descriptor_pending_q[127:112];
                        if (descriptor_pending_index_q == REQUIRED_STAGES - 1) begin
                            config_complete_q <= 1'b1;
                            source_x_q <= 16'd0;
                            source_y_q <= 16'd0;
                            state_q <= ST_SOURCE;
                        end else begin
                            config_index_q <= descriptor_pending_index_q + 1'b1;
                            state_q <= ST_CONFIG;
                        end
                    end
                end

                ST_SOURCE: begin
                    if (adapter_source_valid && adapter_source_ready) begin
                        if (!source_protocol_valid) begin
                        enter_error(ERR_SOURCE);
                        end else begin
                            request_write_q <= 1'b1;
                            request_wdata_q <= adapter_source_data_s8;
                            request_wstrb_q <= 8'hff;
                            request_cacheable_q <= 1'b0;
                            request_cache_x_q <= $signed({1'b0, source_x_q});
                            request_cache_y_q <= $signed({1'b0, source_y_q});
                            request_cache_group_q <= 3'd0;
                            source_eof_q <= adapter_source_eof;
                            if (PIPELINED_TENSOR_ADDRESS != 0) begin
                                addr_bank_q <= 2'd0;
                                addr_width_q <= descriptor_cache[0][47:32];
                                addr_groups_q <= 4'd1;
                                addr_x_q <= source_x_q;
                                addr_y_q <= source_y_q;
                                addr_group_q <= 3'd0;
                                addr_kind_q <= ADDR_KIND_SOURCE;
                                state_q <= ST_SOURCE_ADDR;
                            end else begin
                                request_addr_q <= tensor_addr_fn(
                                    2'd0, descriptor_cache[0][47:32], 4'd1,
                                    source_x_q, source_y_q, 3'd0);
                                state_q <= ST_SOURCE_REQ;
                            end
                        end
                    end
                end

                ST_SOURCE_ADDR: begin
                    if (PIPELINED_TENSOR_PIXEL_INDEX != 0) begin
                        addr_row_product_q <= tensor_row_product_fn(
                            addr_width_q, addr_y_q);
                        state_q <= ST_TENSOR_PIXEL_ADD;
                    end else begin
                        addr_pixel_index_q <= tensor_pixel_index_fn(
                            addr_width_q, addr_x_q, addr_y_q);
                        state_q <= ST_TENSOR_ADDR_FINAL;
                    end
                end

                ST_SOURCE_REQ: begin
                    if (mem_req_valid && mem_req_ready) begin
                        if (PIPELINED_SOURCE_WRITES && error_q)
                            state_q <= ST_ERROR;
                        else if (PIPELINED_SOURCE_WRITES && !source_eof_q) begin
                            if (source_x_q == descriptor_cache[0][47:32] - 1'b1) begin
                                source_x_q <= 0;
                                source_y_q <= source_y_q + 1'b1;
                            end else source_x_q <= source_x_q + 1'b1;
                            state_q <= ST_SOURCE;
                        end else state_q <= ST_SOURCE_RSP;
                    end
                end

                ST_SOURCE_RSP: begin
                    if (PIPELINED_SOURCE_WRITES ? source_writes_pending_q == 0 :
                        (mem_rsp_valid && mem_rsp_ready)) begin
                        if (PIPELINED_SOURCE_WRITES ? error_q : mem_rsp_error) begin
                            enter_error(ERR_MEMORY);
                        end else if (source_eof_q) begin
                            stage_index_q <= 5'd0;
                            state_q <= ST_STAGE_LOAD;
                        end else begin
                            if (source_x_q ==
                                descriptor_cache[0][47:32] - 1'b1) begin
                                source_x_q <= 16'd0;
                                source_y_q <= source_y_q + 1'b1;
                            end else begin
                                source_x_q <= source_x_q + 1'b1;
                            end
                            state_q <= ST_SOURCE;
                        end
                    end
                end

                ST_STAGE_LOAD: begin
                    if(fused_compute_layer) begin
                        fused_final_pending_q<=0;fused_have_result_q<=0;
                    end
                    window_history_valid_q <= 8'd0;
                    window_reuse_q <= 1'b0;
                    opcode_q <= active_descriptor[7:0];
                    input_width_q <= active_descriptor[47:32];
                    input_height_q <= active_descriptor[63:48];
                    output_width_q <= active_descriptor[79:64];
                    output_height_q <= active_descriptor[95:80];
                    input_channels_q <= active_descriptor[111:96];
                    output_channels_q <= active_descriptor[127:112];
                    stride_x_q <= active_descriptor[439:432];
                    stride_y_q <= active_descriptor[447:440];
                    input_groups_q <=
                        (active_descriptor[111:96] + 16'd7) >> 3;
                    output_groups_q <=
                        (active_descriptor[127:112] + 16'd7) >> 3;
                    input_bank_q <= stage_input_bank_fn(stage_index_q);
                    output_bank_q <= stage_output_bank_fn(stage_index_q);
                    residual_bank_q <= stage_residual_bank_fn(stage_index_q);
                    output_x_q <= 16'd0;
                    output_y_q <= 16'd0;
                    input_group_q <= 3'd0;
                    expected_result_group_q <= 3'd0;
                    if (ENABLE_WINDOW_CACHE_SIDEBAND != 0)
                        state_q <= ST_CACHE_CONFIG;
                    else if(view_layer)
                        state_q <= ST_ENGINE;
                    else
                        state_q <= ST_OPERAND_BEGIN;
                end

                ST_CACHE_CONFIG: begin
                    if (cache_stage_start_valid && cache_stage_start_ready) begin
                        pixel_stream_q<=pixel_stream_eligible;
                        if(view_layer) state_q<=ST_ENGINE;
                        else state_q<=ST_OPERAND_BEGIN;
                    end
                end

                ST_OPERAND_BEGIN: begin
                    tap_addr_prefetch_phase_q <= 3'd0;
                    window_q <= 576'd0;
                    window_reuse_q <= window_reuse_admit;
                    if (window_reuse_admit) begin
                        for (integer row = 0; row < 3; row = row + 1) begin
                            window_q[row*192 +: 64] <= (stride_x_q == 1) ?
                                window_history_q[input_group_q][row*128 +: 64] :
                                window_history_q[input_group_q][row*128+64 +: 64];
                            if (stride_x_q == 1)
                                window_q[row*192+64 +: 64] <=
                                    window_history_q[input_group_q][row*128+64 +: 64];
                        end
                    end
                    residual_q <= 64'd0;
                    tap_q <= first_operand_tap;
                    request_write_q <= 1'b0;
                    request_wdata_q <= 64'd0;
                    request_wstrb_q <= 8'd0;
                    request_cacheable_q <= windowed_opcode;
                    if (windowed_opcode) begin
                        operand_source_x_q <= tap_source_x_fn(
                            output_x_q, stride_x_q, first_operand_tap, input_width_q);
                        operand_source_y_q <= tap_source_y_fn(
                            output_y_q, stride_y_q, first_operand_tap, input_height_q);
                    end else if (opcode_q == OP_UPSAMPLE2) begin
                        operand_source_x_q <= output_x_q >> 1;
                        operand_source_y_q <= output_y_q >> 1;
                    end else begin
                        operand_source_x_q <= output_x_q;
                        operand_source_y_q <= output_y_q;
                    end
                    if (PIPELINED_TENSOR_ADDRESS != 0) begin
                        addr_bank_q <= input_bank_q;
                        addr_width_q <= input_width_q;
                        addr_groups_q <= input_groups_q;
                        addr_group_q <= input_group_q;
                        addr_kind_q <= ADDR_KIND_OPERAND;
                        if (windowed_opcode) begin
                            addr_x_q <= tap_source_x_fn(
                                output_x_q, stride_x_q, first_operand_tap, input_width_q);
                            addr_y_q <= tap_source_y_fn(
                                output_y_q, stride_y_q, first_operand_tap, input_height_q);
                        end else if (opcode_q == OP_UPSAMPLE2) begin
                            addr_x_q <= output_x_q >> 1;
                            addr_y_q <= output_y_q >> 1;
                        end else begin
                            addr_x_q <= output_x_q;
                            addr_y_q <= output_y_q;
                        end
                    end
                    request_cache_x_q <= operand_cache_x_fn(
                        first_operand_tap);
                    request_cache_y_q <= operand_cache_y_fn(
                        first_operand_tap);
                    request_cache_group_q <= input_group_q;
                    if (column_operand) begin
                        request_cache_x_q <= column_x_fn(first_operand_tap);
                        request_cache_y_q <= column_center_y_fn();
                        if(pixel_prefetch_busy) begin
                            if(input_group_q>=pixel_prefetch_groups_q || stage_index_q!=pixel_prefetch_stage_q ||
                               output_x_q!=pixel_prefetch_output_x_q || output_y_q!=pixel_prefetch_output_y_q ||
                               first_operand_tap!=pixel_prefetch_tap_q)
                                enter_error(ERR_MEMORY);
                            else state_q<=ST_READ_RSP;
                        end else state_q <= ST_READ_REQ;
                    end else if (PIPELINED_TENSOR_ADDRESS != 0)
                        state_q <= ST_OPERAND_ADDR;
                    else begin
                        request_addr_q <= operand_addr_fn(
                            first_operand_tap);
                        state_q <= ST_READ_REQ;
                    end
                end

                ST_OPERAND_ADDR: begin
                    // tap_q is either the initial tap registered in
                    // ST_OPERAND_BEGIN or the next tap registered by
                    // ST_READ_RSP.  The coordinate transform has already
                    // crossed a flop in the pipelined mode.
                    if (PIPELINED_TENSOR_PIXEL_INDEX != 0) begin
                        addr_row_product_q <= tensor_row_product_fn(
                            addr_width_q, addr_y_q);
                        state_q <= ST_TENSOR_PIXEL_ADD;
                    end else begin
                        addr_pixel_index_q <= tensor_pixel_index_fn(
                            addr_width_q, addr_x_q, addr_y_q);
                        state_q <= ST_TENSOR_ADDR_FINAL;
                    end
                end

                ST_READ_REQ: begin
                    if (!column_operand) advance_tap_addr_prefetch();
                    if (column_operand ? (column_req_valid && column_req_ready && pixel_prefetch_state_q!=PF_REQUEST) :
                                         (mem_req_valid && mem_req_ready)) begin
                        state_q <= ST_READ_RSP;
                    end
                end

                ST_READ_RSP: begin
                    if (!column_operand) advance_tap_addr_prefetch();
                    if (column_operand) begin
                        if (operand_column_rsp_valid) begin
                            if (operand_column_rsp_error || error_q) enter_error(ERR_MEMORY);
                            else if (pointwise_column_operand) begin
                                // Preserve the scalar 1x1 ABI: exactly the
                                // center tap is nonzero, even though the cache
                                // returns three vertically adjacent C8 lanes.
                                window_q[4*64 +: 64] <= operand_column_rsp_data[64 +: 64];
                                state_q <= ST_ENGINE;
                            end else begin
                                // In this mode tap_q holds COLUMN 0..2, not
                                // a row-major tap. Scatter the three row lanes.
                                for (integer r=0;r<3;r++) begin
                                    // Physical center k returns [k-1,k,k+1].
                                    // Logical even row 2k wants [k-1,k,k];
                                    // odd row 2k+1 wants [k,k,k+1]. Cache
                                    // SAME_REPLICATE handles physical borders,
                                    // including a one-row source. Save/reuse
                                    // these LOGICAL lanes, not raw cache lanes.
                                    if (virtual_upsample_input)
                                        window_q[(r*3+tap_q)*64 +: 64] <=
                                            operand_column_rsp_data[((output_y_q[0] ?
                                                ((r==0)?1:r) : ((r==2)?1:r))*64) +: 64];
                                    else
                                        window_q[(r*3+tap_q)*64 +: 64] <= operand_column_rsp_data[r*64 +: 64];
                                end
                                if (tap_q != 2) begin
                                    tap_q <= tap_q + 1'b1;
                                    request_cache_x_q <= column_x_fn(tap_q + 1'b1);
                                    state_q <= ST_READ_REQ;
                                end else state_q <= ST_ENGINE;
                            end
                        end
                    end else if (mem_rsp_valid && mem_rsp_ready) begin
                        tap_addr_prefetch_phase_q <= 3'd0;
                        if (mem_rsp_error) begin
                            enter_error(ERR_MEMORY);
                        end else begin
                            window_q[tap_q*64 +: 64] <= mem_rsp_rdata;
                            if (windowed_opcode && (tap_q != 8)) begin
                                tap_q <= next_operand_tap_fn(tap_q);
                                if (PIPELINED_TENSOR_ADDRESS != 0) begin
                                    operand_source_x_q <= tap_source_x_fn(
                                        output_x_q, stride_x_q,
                                        next_operand_tap_fn(tap_q), input_width_q);
                                    operand_source_y_q <= tap_source_y_fn(
                                        output_y_q, stride_y_q,
                                        next_operand_tap_fn(tap_q), input_height_q);
                                    addr_x_q <= tap_source_x_fn(
                                        output_x_q, stride_x_q,
                                        next_operand_tap_fn(tap_q), input_width_q);
                                    addr_y_q <= tap_source_y_fn(
                                        output_y_q, stride_y_q,
                                        next_operand_tap_fn(tap_q), input_height_q);
                                    addr_bank_q <= input_bank_q;
                                    addr_width_q <= input_width_q;
                                    addr_groups_q <= input_groups_q;
                                    addr_group_q <= input_group_q;
                                    addr_kind_q <= ADDR_KIND_OPERAND;
                                end
                                request_cacheable_q <= 1'b1;
                                request_cache_x_q <=
                                    operand_cache_x_fn(next_operand_tap_fn(tap_q));
                                request_cache_y_q <=
                                    operand_cache_y_fn(next_operand_tap_fn(tap_q));
                                request_cache_group_q <= input_group_q;
                                if (PREFETCH_NEXT_TAP_ADDRESS != 0 &&
                                    PIPELINED_TENSOR_ADDRESS != 0 &&
                                    (tap_addr_prefetch_phase_q == 3 ||
                                     tap_addr_prefetch_phase_q == 4)) begin
                                    // Phase 3 already has a registered pixel
                                    // index: use the same final scaling stage
                                    // as ST_TENSOR_ADDR_FINAL on this edge.
                                    request_addr_q <= (tap_addr_prefetch_phase_q == 4) ?
                                        tap_addr_prefetch_q : tensor_addr_from_pixel_fn(
                                            addr_bank_q, addr_pixel_index_q,
                                            addr_groups_q, addr_group_q);
                                    state_q <= ST_READ_REQ;
                                    // The next missing tap is now locked. Prepare
                                    // the following missing tap (reused columns
                                    // are skipped) without changing that request.
                                    if (next_operand_tap_fn(tap_q) < 8 &&
                                        !adapter_abort && !abort_pending_q)
                                        seed_tap_addr_prefetch(next_operand_tap_fn(next_operand_tap_fn(tap_q)));
                                end else if (PIPELINED_TENSOR_ADDRESS != 0)
                                    state_q <= ST_OPERAND_ADDR;
                                else begin
                                    request_addr_q <= operand_addr_fn(
                                        next_operand_tap_fn(tap_q));
                                    state_q <= ST_READ_REQ;
                                end
                            end else if (opcode_q == OP_RESIDUAL_ADD) begin
                                request_cacheable_q <= 1'b0;
                                request_cache_x_q <=
                                    $signed({1'b0, output_x_q});
                                request_cache_y_q <=
                                    $signed({1'b0, output_y_q});
                                request_cache_group_q <= input_group_q;
                                if (PIPELINED_TENSOR_ADDRESS != 0) begin
                                    addr_bank_q <= residual_bank_q;
                                    addr_width_q <= input_width_q;
                                    addr_groups_q <= input_groups_q;
                                    addr_x_q <= output_x_q;
                                    addr_y_q <= output_y_q;
                                    addr_group_q <= input_group_q;
                                    addr_kind_q <= ADDR_KIND_RESIDUAL;
                                    state_q <= ST_RESIDUAL_ADDR;
                                end else begin
                                    request_addr_q <= tensor_addr_fn(
                                        residual_bank_q, input_width_q,
                                        input_groups_q, output_x_q, output_y_q,
                                        input_group_q);
                                    state_q <= ST_RESIDUAL_REQ;
                                end
                            end else begin
                                state_q <= ST_ENGINE;
                            end
                        end
                    end
                end

                ST_RESIDUAL_ADDR: begin
                    if (PIPELINED_TENSOR_PIXEL_INDEX != 0) begin
                        addr_row_product_q <= tensor_row_product_fn(
                            addr_width_q, addr_y_q);
                        state_q <= ST_TENSOR_PIXEL_ADD;
                    end else begin
                        addr_pixel_index_q <= tensor_pixel_index_fn(
                            addr_width_q, addr_x_q, addr_y_q);
                        state_q <= ST_TENSOR_ADDR_FINAL;
                    end
                end

                ST_RESIDUAL_REQ: begin
                    if (mem_req_valid && mem_req_ready)
                        state_q <= ST_RESIDUAL_RSP;
                end

                ST_RESIDUAL_RSP: begin
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        if (mem_rsp_error) begin
                            enter_error(ERR_MEMORY);
                        end else begin
                            residual_q <= mem_rsp_rdata;
                            state_q <= ST_ENGINE;
                        end
                    end
                end

                ST_ENGINE: begin
                    if(view_commit_valid && view_commit_ready) begin
                        if(fused_final_view) state_q<=ST_FINAL;
                        else begin
                            stage_index_q<=stage_index_q+1'b1;
                            state_q<=ST_STAGE_LOAD;
                        end
                    end else if (adapter_engine_valid && adapter_engine_ready) begin
                        if (REUSE_HORIZONTAL_WINDOW != 0 && windowed_opcode) begin
                            for (integer row = 0; row < 3; row = row + 1)
                                window_history_q[input_group_q][row*128 +: 128] <=
                                    window_q[row*192+64 +: 128];
                            window_history_x_q[input_group_q] <= output_x_q;
                            window_history_y_q[input_group_q] <= output_y_q;
                            window_history_valid_q[input_group_q] <= 1'b1;
                        end
                        if (input_group_q == input_groups_q - 1'b1) begin
                            expected_result_group_q <= 3'd0;
                            if((pixel_stream_q || fused_compute_layer) && !adapter_engine_eof) begin
                                input_group_q<=0;
                                if(output_x_q==output_width_q-1'b1) begin
                                    output_x_q<=0;output_y_q<=output_y_q+1'b1;
                                end else output_x_q<=output_x_q+1'b1;
                                state_q<=ST_OPERAND_BEGIN;
                            end else state_q <= ST_RESULT;
                        end else begin
                            input_group_q <= input_group_q + 1'b1;
                            state_q <= ST_OPERAND_BEGIN;
                        end
                    end
                end

                ST_RESULT: begin
                    if(fused_compute_layer) begin
                        // Independent validated final register retires below.
                        // No intermediate tensor write or synthetic memory ACK.
                    end else if(pixel_stream_q) begin
                        if(pixel_sink_done) begin
                            stage_index_q<=stage_index_q+1'b1;state_q<=ST_STAGE_LOAD;
                        end
                    end else if (adapter_result_valid && adapter_result_ready) begin
                        if (!result_protocol_valid) begin
                            enter_error(ERR_RESULT);
                        end else if (virtual_upsample_output) begin
                            // Still validate/retire every engine result. No
                            // fake memory request or posted write response:
                            // the input tensor remains the physical owner.
                            if (!adapter_result_group_last) begin
                                expected_result_group_q <= expected_result_group_q + 1'b1;
                            end else if (adapter_result_eof) begin
                                stage_index_q <= stage_index_q + 1'b1;
                                state_q <= ST_STAGE_LOAD;
                            end else begin
                                expected_result_group_q <= 3'd0;
                                input_group_q <= 3'd0;
                                if (output_x_q == output_width_q - 1'b1) begin
                                    output_x_q <= 16'd0;
                                    output_y_q <= output_y_q + 1'b1;
                                end else output_x_q <= output_x_q + 1'b1;
                                state_q <= ST_OPERAND_BEGIN;
                            end
                        end else if (stage_index_q ==
                                     REQUIRED_STAGES - 1) begin
                            final_data_q <= adapter_result_data_s8;
                            final_x_q <= adapter_result_x;
                            final_y_q <= adapter_result_y;
                            final_sof_q <= adapter_result_sof;
                            final_eol_q <= adapter_result_eol;
                            final_eof_q <= adapter_result_eof;
                            final_group_last_q <=
                                adapter_result_group_last;
                            state_q <= ST_FINAL;
                        end else begin
                            request_write_q <= 1'b1;
                            request_wdata_q <= adapter_result_data_s8;
                            request_wstrb_q <= 8'hff;
                            request_cacheable_q <= 1'b0;
                            request_cache_x_q <=
                                $signed({1'b0, output_x_q});
                            request_cache_y_q <=
                                $signed({1'b0, output_y_q});
                            request_cache_group_q <=
                                adapter_result_group_index;
                            result_group_last_q <=
                                adapter_result_group_last;
                            result_eof_q <= adapter_result_eof;
                            if (PIPELINED_TENSOR_ADDRESS != 0) begin
                                addr_bank_q <= output_bank_q;
                                addr_width_q <= output_width_q;
                                addr_groups_q <= output_groups_q;
                                addr_x_q <= output_x_q;
                                addr_y_q <= output_y_q;
                                addr_group_q <= adapter_result_group_index;
                                addr_kind_q <= ADDR_KIND_RESULT;
                                state_q <= ST_RESULT_ADDR;
                            end else begin
                                request_addr_q <= tensor_addr_fn(
                                    output_bank_q, output_width_q,
                                    output_groups_q, output_x_q, output_y_q,
                                    adapter_result_group_index);
                                state_q <= ST_WRITE_REQ;
                            end
                        end
                    end
                end

                ST_RESULT_ADDR: begin
                    if (PIPELINED_TENSOR_PIXEL_INDEX != 0) begin
                        addr_row_product_q <= tensor_row_product_fn(
                            addr_width_q, addr_y_q);
                        state_q <= ST_TENSOR_PIXEL_ADD;
                    end else begin
                        addr_pixel_index_q <= tensor_pixel_index_fn(
                            addr_width_q, addr_x_q, addr_y_q);
                        state_q <= ST_TENSOR_ADDR_FINAL;
                    end
                end

                ST_TENSOR_PIXEL_ADD: begin
                    // The row product was captured in the preceding state;
                    // this separate add completes y*width+x before the final
                    // group/byte/bank scaling stage.
                    addr_pixel_index_q <= addr_row_product_q +
                                           {16'd0, addr_x_q};
                    state_q <= ST_TENSOR_ADDR_FINAL;
                end

                ST_TENSOR_ADDR_FINAL: begin
                    request_addr_q <= tensor_addr_from_pixel_fn(
                        addr_bank_q, addr_pixel_index_q, addr_groups_q,
                        addr_group_q);
                    if (PREFETCH_NEXT_TAP_ADDRESS != 0 &&
                        PIPELINED_TENSOR_ADDRESS != 0 &&
                        addr_kind_q == ADDR_KIND_OPERAND && windowed_opcode &&
                        tap_q < 8 && !adapter_abort && !abort_pending_q)
                        seed_tap_addr_prefetch(next_operand_tap_fn(tap_q));
                    case (addr_kind_q)
                        ADDR_KIND_SOURCE:   state_q <= ST_SOURCE_REQ;
                        ADDR_KIND_OPERAND:  state_q <= ST_READ_REQ;
                        ADDR_KIND_RESIDUAL: state_q <= ST_RESIDUAL_REQ;
                        default:             state_q <= ST_WRITE_REQ;
                    endcase
                end

                ST_WRITE_REQ: begin
                    if (mem_req_valid && mem_req_ready) begin
                        if (PIPELINED_RESULT_WRITES != 0 && error_q)
                            state_q <= ST_ERROR;
                        else if (PIPELINED_RESULT_WRITES != 0 && !result_group_last_q) begin
                            expected_result_group_q <= expected_result_group_q + 1'b1;
                            state_q <= ST_RESULT;
                        end else if (column_allow_pending_writes && !result_eof_q) begin
                            // All current results were accepted by the write
                            // seam, not yet necessarily committed. The next
                            // pixel reads only the distinct immutable bank.
                            expected_result_group_q <= 0;
                            input_group_q <= 0;
                            if (output_x_q == output_width_q - 1'b1) begin
                                output_x_q <= 0;
                                output_y_q <= output_y_q + 1'b1;
                            end else output_x_q <= output_x_q + 1'b1;
                            state_q <= ST_OPERAND_BEGIN;
                        end else
                            state_q <= ST_WRITE_RSP;
                    end
                end

                ST_WRITE_RSP: begin
                    if ((PIPELINED_RESULT_WRITES != 0) ?
                        (result_writes_pending_q == 0) :
                        (mem_rsp_valid && mem_rsp_ready)) begin
                        if ((PIPELINED_RESULT_WRITES != 0) ? error_q : mem_rsp_error) begin
                            enter_error(ERR_MEMORY);
                        end else if (!result_group_last_q) begin
                            expected_result_group_q <=
                                expected_result_group_q + 1'b1;
                            state_q <= ST_RESULT;
                        end else if (result_eof_q) begin
                            stage_index_q <= stage_index_q + 1'b1;
                            state_q <= ST_STAGE_LOAD;
                        end else begin
                            expected_result_group_q <= 3'd0;
                            input_group_q <= 3'd0;
                            if (output_x_q == output_width_q - 1'b1) begin
                                output_x_q <= 16'd0;
                                output_y_q <= output_y_q + 1'b1;
                            end else begin
                                output_x_q <= output_x_q + 1'b1;
                            end
                            state_q <= ST_OPERAND_BEGIN;
                        end
                    end
                end

                ST_FINAL: begin
                    if (adapter_final_valid && adapter_final_ready) begin
                        if (final_eof_q) begin
                            state_q <= ST_IDLE;
                            config_complete_q <= 1'b0;
                            adapter_done <= 1'b1;
                        end else if (final_group_last_q) begin
                            expected_result_group_q <= 3'd0;
                            input_group_q <= 3'd0;
                            if (output_x_q == output_width_q - 1'b1) begin
                                output_x_q <= 16'd0;
                                output_y_q <= output_y_q + 1'b1;
                            end else begin
                                output_x_q <= output_x_q + 1'b1;
                            end
                            state_q <= ST_OPERAND_BEGIN;
                        end else begin
                            expected_result_group_q <=
                                expected_result_group_q + 1'b1;
                            state_q <= ST_RESULT;
                        end
                    end
                end

                ST_ERROR: begin
                    // Sticky until the bridge aborts the failed job.
                end

                default: enter_error(ERR_DESCRIPTOR);
            endcase

            if(FUSE_FINAL_OUTPUT) begin
                if(adapter_final_valid && adapter_final_ready) begin
                    fused_final_pending_q<=0;
                    if(final_eof_q) begin
                        // The bridge gates EOF until the engine has checked
                        // stage 21. Never make its commit depend on EOF READY.
                        if(!fused_final_view || state_q!=ST_FINAL) enter_error(ERR_RESULT);
                        else begin
                            state_q<=ST_IDLE;config_complete_q<=0;adapter_done<=1;
                        end
                    end
                end
                if(fused_compute_layer && adapter_result_valid && adapter_result_ready) begin
                    if(fused_result_protocol_valid) begin
                        final_data_q<=adapter_result_data_s8;
                        final_x_q<=adapter_result_x;final_y_q<=adapter_result_y;
                        final_sof_q<=adapter_result_sof;final_eol_q<=adapter_result_eol;
                        final_eof_q<=adapter_result_eof;final_group_last_q<=1;
                        fused_final_pending_q<=1;fused_have_result_q<=1;
                        if(adapter_result_eof) begin
                            stage_index_q<=21;state_q<=ST_STAGE_LOAD;
                        end
                    end
                end
            end

            // A source completion can fail while the next source request is
            // already offered. Preserve that payload until its handshake;
            // the independent credit counter drains it even in ST_ERROR.
            if (source_write_retire && mem_rsp_error) begin
                error_q <= 1'b1;
                error_code_q <= ERR_MEMORY;
                if (state_q != ST_SOURCE_REQ || mem_req_ready)
                    state_q <= ST_ERROR;
            end

            // Retire result writes independently from result admission.
            // On failure, preserve an already-presented request until accepted;
            // ST_ERROR drains all other accepted writes via mem_rsp_ready.
            if ((result_write_retire && mem_rsp_error) || pixel_prefetch_fault ||
                (pixel_stream_q && pixel_sink_error && state_q!=ST_IDLE)) begin
                error_q <= 1'b1;
                error_code_q <= (pixel_stream_q && pixel_sink_error) ? pixel_sink_error_code : ERR_MEMORY;
                // A write can now fail while an independent column request
                // or response is held. Preserve and drain that obligation
                // before entering ERROR; never withdraw VALID on a fault.
                if (state_q == ST_READ_REQ && column_operand) begin
                    if (pixel_prefetch_bus_busy) state_q <= ST_ERROR;
                    else if (column_req_ready) state_q <= ST_READ_RSP;
                end else if (state_q == ST_READ_RSP && column_operand) begin
                    // The independent prefetch FSM continues its own drain
                    // in ERROR; normal demand reads remain state-owned.
                    if (pixel_prefetch_select || pixel_prefetch_bus_busy ||
                        (column_rsp_valid && column_rsp_ready)) state_q <= ST_ERROR;
                end else if (state_q != ST_WRITE_REQ || mem_req_ready)
                    state_q <= ST_ERROR;
            end

            // Synchronous protocol-safe abort.  A request which has already
            // been presented is never withdrawn; after acceptance its response
            // is drained.  No new source/engine/result transfer is admitted.
            if (!adapter_abort)
                abort_seen_q <= 1'b0;
            // A bad final result can arrive while the next window demand is
            // offered/in flight. Preserve that obligation even before ABORT;
            // stop new compute/final admission, drain, then remain in ERROR.
            if(fused_result_fault || (fused_compute_layer && error_q)) begin
                error_q<=1;
                if(fused_result_fault && !error_q) error_code_q<=ERR_RESULT;
                if(state_q==ST_READ_REQ) begin
                    if(column_operand) begin
                        if(pixel_prefetch_bus_busy) state_q<=ST_ERROR;
                        else if(column_req_valid && column_req_ready) state_q<=ST_READ_RSP;
                    end else if(mem_req_valid && mem_req_ready) state_q<=ST_READ_RSP;
                end else if(state_q==ST_READ_RSP) begin
                    if(column_operand ? (pixel_prefetch_select || pixel_prefetch_bus_busy || operand_column_rsp_valid) :
                                        (mem_rsp_valid && mem_rsp_ready)) state_q<=ST_ERROR;
                end else state_q<=ST_ERROR;
            end

            if (adapter_abort && !abort_seen_q) begin
                fused_final_pending_q<=0;fused_have_result_q<=0;
                abort_seen_q <= 1'b1;
                abort_pending_q <= 1'b1;
            end
            if ((adapter_abort && !abort_seen_q) || abort_pending_q) begin
                window_history_valid_q <= 8'd0;
                case (state_q)
                    ST_SOURCE_REQ: begin
                        if (mem_req_ready)
                            state_q <= ST_SOURCE_RSP;
                    end
                    ST_READ_REQ: begin
                        // A prefetch may own the physical port while this
                        // demand request has not yet been presented. Drain
                        // that owner; do not invent a demand response debt.
                        if(column_operand && pixel_prefetch_bus_busy)
                            state_q <= ST_ERROR;
                        else if (column_operand ? column_req_ready : mem_req_ready)
                            state_q <= ST_READ_RSP;
                    end
                    ST_RESIDUAL_REQ: begin
                        if (mem_req_ready)
                            state_q <= ST_RESIDUAL_RSP;
                    end
                    ST_WRITE_REQ: begin
                        if (mem_req_ready)
                            state_q <= ST_WRITE_RSP;
                    end
                    ST_SOURCE_RSP, ST_READ_RSP,
                    ST_RESIDUAL_RSP, ST_WRITE_RSP: begin
                        // Cached future groups do not own an outstanding
                        // normal demand read. Only select/bus ownership lets
                        // the independent prefetch FSM drain this obligation.
                        if(state_q==ST_READ_RSP && column_operand &&
                           (pixel_prefetch_select || pixel_prefetch_bus_busy)) begin
                            state_q <= ST_ERROR;
                        end else if ((PIPELINED_SOURCE_WRITES && state_q == ST_SOURCE_RSP) ?
                            (source_writes_pending_q == 0) :
                            (PIPELINED_RESULT_WRITES != 0 && state_q == ST_WRITE_RSP) ?
                            (result_writes_pending_q == 0) :
                            ((state_q == ST_READ_RSP && column_operand) ? operand_column_rsp_valid : mem_rsp_valid)) begin
                            if (pixel_prefetch_busy || pixel_sink_busy || (PIPELINED_RESULT_WRITES != 0 &&
                                state_q == ST_READ_RSP && column_operand &&
                                result_writes_pending_q != 0)) begin
                                // Column response consumed; ERROR's abort
                                // branch drains the remaining scalar writes.
                                state_q <= ST_ERROR;
                            end else begin
                                state_q <= ST_IDLE;
                                abort_pending_q <= 1'b0;
                                error_q <= 1'b0;
                                error_code_q <= ERR_NONE;
                                config_complete_q <= 1'b0;
                                adapter_aborted <= 1'b1;
                            end
                        end
                    end
                    default: begin
                        if (source_writes_pending_q != 0 || pixel_prefetch_busy || pixel_sink_busy ||
                            (PIPELINED_RESULT_WRITES != 0 && result_writes_pending_q != 0)) begin
                            state_q <= ST_ERROR;
                        end else begin
                            state_q <= ST_IDLE;
                            abort_pending_q <= 1'b0;
                            error_q <= 1'b0;
                            error_code_q <= ERR_NONE;
                            config_complete_q <= 1'b0;
                            adapter_aborted <= 1'b1;
                        end
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    integer pixel_feed_count,pixel_return_count;
    always_ff @(posedge clk) begin
        if(rst || (cache_stage_start_valid && cache_stage_start_ready)) begin
            pixel_feed_count<=0;pixel_return_count<=0;
        end else if(pixel_stream_q) begin
            if(adapter_engine_valid && adapter_engine_ready && adapter_engine_group_last)
                pixel_feed_count<=pixel_feed_count+1;
            if(adapter_result_valid && adapter_result_ready) begin
                if(pixel_return_count>=pixel_feed_count*output_groups_q)
                    $fatal(1,"pixel result preceded its admitted complete input window");
                pixel_return_count<=pixel_return_count+1;
            end
            if(pixel_sink_done && pixel_feed_count*output_groups_q!=pixel_return_count)
                $fatal(1,"pixel writer completion omitted admitted pixels");
            if(source_writes_pending_q!=0 || result_writes_pending_q!=0)
                $fatal(1,"pixel writer overlapped legacy scalar ownership");
        end
        if(!rst && pixel_sink_busy && (state_q==ST_IDLE || state_q==ST_STAGE_LOAD ||
           adapter_aborted || adapter_done || adapter_start_ready))
            $fatal(1,"adapter released a pixel writeback obligation");
    end
    initial if(PIPELINE_DOT_PIXELS && !OVERLAP_COLUMN_WRITEBACK)
        $fatal(1,"dot pixel pipeline requires column writeback overlap");
    initial if(PIPELINE_DW_PIXELS && !OVERLAP_COLUMN_WRITEBACK)
        $fatal(1,"DW pixel pipeline requires column writeback overlap");
    initial if(ELIDE_VIRTUAL_UPSAMPLE && (!VIRTUAL_UPSAMPLE_TENSORS || ENABLE_COLUMN_READS==0 || ENABLE_WINDOW_CACHE_SIDEBAND==0))
        $fatal(1,"view elision requires virtual tensors and column configuration");
    initial if(PIPELINE_ALL_DOT_GROUPS && !PIPELINE_DOT_PIXELS)
        $fatal(1,"all dot groups requires dot pixel pipeline");
    initial if(PIXEL_WRITE_BATCH_WORDS!=1 && !PIPELINE_DOT_PIXELS && !PIPELINE_DW_PIXELS)
        $fatal(1,"pixel write batching requires dot or DW pixel pipeline");
    initial if(PREFETCH_ALL_PIXEL_GROUPS && !PREFETCH_NEXT_PIXEL_COLUMN)
        $fatal(1,"all-group pixel prefetch requires next-pixel prefetch");
    initial if(PREFETCH_NEXT_PIXEL_COLUMN && !OVERLAP_COLUMN_WRITEBACK)
        $fatal(1,"pixel column prefetch requires column writeback overlap");
    initial if (POINTWISE_COLUMN_READS && ENABLE_COLUMN_READS == 0)
        $fatal(1,"pointwise column reads require the column interface");
    initial if (OVERLAP_COLUMN_WRITEBACK &&
        (ENABLE_COLUMN_READS == 0 || PIPELINED_RESULT_WRITES == 0))
        $fatal(1,"column writeback overlap requires columns and pipelined writes");
    initial if (VIRTUAL_UPSAMPLE_TENSORS &&
        (ENABLE_COLUMN_READS == 0 || ENABLE_WINDOW_CACHE_SIDEBAND == 0 || REQUIRED_STAGES != 22))
        $fatal(1,"virtual upsample tensors require the fixed 22-stage graph and column configuration");
    initial if (ENABLE_COLUMN_READS != 0 && ENABLE_WINDOW_CACHE_SIDEBAND == 0)
        $fatal(1,"column reads require the per-stage cache configuration interface");
    logic column_stalled_q;
    logic [36:0] column_payload_q;
    always_ff @(posedge clk) begin
        if (rst) column_stalled_q <= 1'b0;
        else begin
            if(pixel_prefetch_busy && (pixel_prefetch_groups_q<1 ||
               pixel_prefetch_groups_q>PIXEL_PREFETCH_SLOTS || pixel_prefetch_consumed_q>pixel_prefetch_groups_q))
                $fatal(1,"pixel prefetch exceeded bounded group storage");
            if(pixel_prefetch_take && input_group_q!=pixel_prefetch_consumed_q)
                $fatal(1,"pixel prefetch consumed a duplicate or out-of-order group");
            if(pixel_prefetch_state_q==PF_RESPONSE && column_rsp_valid && column_rsp_ready &&
               (pixel_prefetch_issue_group_q>=pixel_prefetch_groups_q ||
                pixel_prefetch_valid_q[pixel_prefetch_issue_group_q]))
                $fatal(1,"pixel prefetch overwrote an unconsumed group");
            if (virtual_upsample_output && mem_req_valid && mem_req_write)
                $fatal(1,"virtual upsample tensor unexpectedly issued a write");
            if (virtual_upsample_input && column_req_valid &&
                (opcode_q != OP_DWCONV3X3 || stride_x_q != 1 || stride_y_q != 1 ||
                 input_width_q[0] || input_height_q[0] || input_bank_q == output_bank_q))
                $fatal(1,"virtual upsample input geometry/ownership contract violated");
            if (column_stalled_q && (!column_req_valid ||
                {column_req_x,column_req_center_y,column_req_group} !== column_payload_q))
                $fatal(1,"tensor adapter changed/withdrew a stalled column request");
            column_stalled_q <= column_req_valid && !column_req_ready;
            column_payload_q <= {column_req_x,column_req_center_y,column_req_group};
            if (column_req_valid && ((mem_req_valid &&
                !((pixel_prefetch_state_q==PF_REQUEST || pixel_stream_q) && mem_req_write && column_allow_pending_writes)) ||
                (result_writes_pending_q != 0 && !column_allow_pending_writes)))
                $fatal(1,"column request crossed the scalar memory/write completion fence");
            if (column_req_valid && pixel_prefetch_state_q!=PF_REQUEST && !pointwise_column_operand && tap_q > 2)
                $fatal(1,"column request used a scalar tap index");
            if (column_req_valid && pixel_prefetch_state_q!=PF_REQUEST && pointwise_column_operand &&
                (tap_q != 4 || column_req_x != $signed({1'b0,output_x_q}) ||
                 column_req_center_y != $signed({1'b0,output_y_q})))
                $fatal(1,"pointwise column changed scalar raster coordinates");
            if(pixel_prefetch_busy && (state_q==ST_IDLE || state_q==ST_STAGE_LOAD ||
                state_q==ST_CACHE_CONFIG || adapter_aborted || adapter_done))
                $fatal(1,"pixel prefetch crossed stage/job/drain ownership fence");
        end
    end
    always_ff @(posedge clk) begin
        if (!rst && PIPELINED_RESULT_WRITES != 0) begin
            if (!OVERLAP_COLUMN_WRITEBACK && result_writes_pending_q > 8)
                $fatal(1,"result write count exceeded one pixel's group bound");
            if(result_write_accept && result_writes_pending_q==15 && !result_write_retire)
                $fatal(1,"result write credit overflow");
            if (result_writes_pending_q != 0 &&
                ((mem_req_valid && state_q != ST_WRITE_REQ) ||
                 state_q == ST_STAGE_LOAD || state_q == ST_CACHE_CONFIG ||
                 adapter_done || adapter_aborted || adapter_start_ready))
                $fatal(1,"adapter crossed write completion fence");
        end
    end
    logic mem_req_stalled_q;
    logic [143:0] mem_req_payload_q;
    logic cache_stage_stalled_q;
    logic [68:0] cache_stage_payload_q;
    logic engine_stalled_q;
    logic [678:0] engine_payload_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_req_stalled_q <= 1'b0;
            cache_stage_stalled_q <= 1'b0;
            engine_stalled_q <= 1'b0;
        end else begin
            if (mem_req_stalled_q &&
                (!mem_req_valid ||
                 ({mem_req_write, mem_req_addr, mem_req_wdata, mem_req_wstrb,
                   mem_req_cacheable, mem_req_cache_x, mem_req_cache_y,
                   mem_req_cache_group, mem_req_end} !=
                  mem_req_payload_q)))
                $fatal(1, "tensor adapter changed a stalled memory request/sideband");
            mem_req_stalled_q <= mem_req_valid && !mem_req_ready;
            mem_req_payload_q <= {mem_req_write, mem_req_addr,
                                  mem_req_wdata, mem_req_wstrb,
                                  mem_req_cacheable, mem_req_cache_x,
                                  mem_req_cache_y, mem_req_cache_group, mem_req_end};

            if (cache_stage_stalled_q && !adapter_abort &&
                (!cache_stage_start_valid ||
                 ({cache_stage_enable, cache_stage_base_addr,
                   cache_stage_width, cache_stage_height,
                   cache_stage_groups} != cache_stage_payload_q)))
                $fatal(1, "tensor adapter changed/withdrew stalled cache-stage config");
            cache_stage_stalled_q <= cache_stage_start_valid &&
                                     !cache_stage_start_ready;
            cache_stage_payload_q <= {
                cache_stage_enable, cache_stage_base_addr,
                cache_stage_width, cache_stage_height, cache_stage_groups};

            if ((ENABLE_WINDOW_CACHE_SIDEBAND == 0) &&
                cache_stage_start_valid)
                $fatal(1, "disabled cache sideband asserted stage valid");
            if (mem_req_valid && mem_req_cacheable &&
                (mem_req_write || (state_q != ST_READ_REQ) ||
                 !windowed_opcode))
                $fatal(1, "non-3x3-tap request marked cacheable");
            if (mem_req_valid && !mem_req_write && !column_operand && (state_q == ST_READ_REQ) &&
                windowed_opcode && !mem_req_cacheable)
                $fatal(1, "3x3 tap read was not marked cacheable");
            if(pixel_stream_q && mem_req_valid && (!mem_req_write || mem_req_cacheable))
                $fatal(1,"pixel writer changed its noncacheable scalar-write contract");
            if (mem_req_valid && mem_req_write &&
                (mem_req_wstrb != 8'hff))
                $fatal(1, "tensor adapter write violated aligned full-beat contract");
            if (mem_req_valid && !mem_req_write && (mem_req_wstrb != 8'h00))
                $fatal(1, "tensor adapter read carried byte strobes");
            if (mem_req_valid && (mem_req_addr[2:0] != 3'b000))
                $fatal(1, "tensor adapter request violated 8-byte alignment");

            if (engine_stalled_q &&
                ({adapter_engine_window_s8,
                  adapter_engine_residual_s8,
                  adapter_engine_group_index,
                  adapter_engine_group_last,
                  adapter_engine_x, adapter_engine_y,
                  adapter_engine_sof, adapter_engine_eol,
                  adapter_engine_eof} != engine_payload_q))
                $fatal(1, "tensor adapter changed a stalled engine operand");
            engine_stalled_q <= adapter_engine_valid &&
                                !adapter_engine_ready;
            engine_payload_q <= {adapter_engine_window_s8,
                                 adapter_engine_residual_s8,
                                 adapter_engine_group_index,
                                 adapter_engine_group_last,
                                 adapter_engine_x, adapter_engine_y,
                                 adapter_engine_sof, adapter_engine_eol,
                                 adapter_engine_eof};
            if (mem_req_valid && mem_rsp_ready && !pixel_stream_q &&
                !(PIPELINED_SOURCE_WRITES && state_q == ST_SOURCE_REQ &&
                  source_writes_pending_q != 0) &&
                !(PIPELINED_RESULT_WRITES != 0 && state_q == ST_WRITE_REQ &&
                  result_writes_pending_q != 0))
                $fatal(1, "tensor adapter requested and retired memory together");
            if (source_write_accept && source_writes_pending_q == 15 && !source_write_retire)
                $fatal(1, "source write credit overflow");
            if (source_writes_pending_q != 0 &&
                (result_writes_pending_q != 0 || adapter_engine_valid || column_req_valid ||
                 cache_stage_start_valid || adapter_start_ready || adapter_done || adapter_aborted ||
                 state_q == ST_STAGE_LOAD || (mem_req_valid && state_q != ST_SOURCE_REQ)))
                $fatal(1, "adapter crossed source write completion fence");
        end
    end
`endif

endmodule
