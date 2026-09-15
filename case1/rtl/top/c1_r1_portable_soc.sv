// Final board-independent case-1 SoC composition boundary.
//
// Real integrated paths:
//   APB CSR/ISP config -> lifecycle controller
//   RAW10 camera CDC -> R1 ISP -> capture table lookup -> XRGB DDR writer
//   DDR parameter loader -> atomic parameter bank -> real MicroStyle engine
//   frame manager -> boardless frame job -> descriptor cache/CNN arithmetic
//   resolved input/output pair -> dual-clock display prefetch -> 720p/OSD
//   22-stage tensor scheduler + optional C8 window cache + 64/128-bit bridge
//       -> shared DDR arena
//   seven memory clients (+ optional Resize preview writer) -> shared AXI4-128
//
// No vendor IP is instantiated here.  The only board-facing data-plane seam
// is the single AXI4-128 master; clocks, reset, APB, camera and video pins are
// intentionally portable integration boundaries.
module c1_r1_portable_soc #(
    parameter integer APB_ADDR_W = 12,
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer SENSOR_WIDTH = FRAME_WIDTH + 2,
    parameter integer SENSOR_HEIGHT = FRAME_HEIGHT + 2,
    parameter integer CAMERA_X_BITS =
        (SENSOR_WIDTH <= 1) ? 1 : $clog2(SENSOR_WIDTH),
    parameter integer CAMERA_Y_BITS =
        (SENSOR_HEIGHT <= 1) ? 1 : $clog2(SENSOR_HEIGHT),
    parameter integer PARAM_ADDR_W = 11,
    // The sequential correctness adapter has a zero-latency structural
    // lower bound above 85M clocks/frame.  Keep a finite but deliberately
    // loose watchdog until burst/tile caching replaces it; a performance
    // build must override this with its measured frame deadline.
    parameter logic [31:0] JOB_CYCLE_BUDGET = 32'd1000000000,
    // Default zero preserves the original direct adapter-to-memory-bridge
    // transaction path.  Set to one only for builds that include the
    // board-independent three-row C8 tensor window cache seam.
    parameter integer ENABLE_TENSOR_WINDOW_CACHE = 0,
    // Optional next-phase refill-side burst/multi-outstanding client.  It
    // keeps the legacy bridge for writes and non-cacheable reads, and is
    // deliberately disabled in the compatibility/default build until its
    // native long-frame QoS and abort/flush gates are complete.
    parameter integer ENABLE_TENSOR_BURST_REFILL = 0,
    // Cancellation policy for the optional burst/refill seam.  Zero is the
    // boardless default: an expected fence reports refill-data error but does
    // not permanently poison the cache stage.  Set to one for strict legacy
    // sticky protocol-error semantics.
    parameter integer TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR = 0,
    // Optional storage format for the burst reader response FIFO.  Logical
    // mode (0) keeps one complete C8 refill record per entry and is the
    // conservative default.  Beat mode (1) stores one AXI128 beat plus lane
    // metadata per entry; it can be substantially smaller, but the minimum
    // safe depth depends on BURST_BEATS and reader outstanding count.  These
    // knobs are exposed at the portable-top boundary so a board-specific
    // EBR mapping can be explored without editing the burst client RTL.
    parameter integer TENSOR_BURST_RSP_FIFO_BEAT_MODE = 0,
    parameter integer TENSOR_BURST_RSP_FIFO_DEPTH = 128,
    // Optional one-burst response FIFOs on the two display readers.  The
    // default remains the historical direct line-store path; enabling this
    // parameter is an experimental QoS build that prevents an in-flight
    // display R burst from holding the ID-less fabric while the pixel domain
    // is paused.
    parameter integer ENABLE_DISPLAY_RESPONSE_FIFO = 0,
    parameter integer DISPLAY_RESPONSE_FIFO_DEPTH = 64,
    // Optional one-entry response register in the shared read fabric.  It
    // cuts the direct selected-client RREADY path at the arbiter boundary;
    // default zero preserves the historical cycle timing.
    parameter integer ENABLE_FABRIC_READ_RESPONSE_SKID = 0,
    // Optional registered table-reader response boundary.  Default zero keeps
    // the original direct table response handshake.
    parameter integer ENABLE_TABLE_RESPONSE_FIFO = 0,
    // Keep strict descriptor validation by default.  A performance artifact
    // build may explicitly relax the synthesizable checker after software ABI
    // validation; simulation still fatal-checks relaxed descriptors.
    parameter integer STRICT_DESCRIPTOR_VALIDATION = 1,
    // Optional two-boundary descriptor checker schedule.  Default zero keeps
    // the legacy one-cycle configuration behavior; enabled builds add a
    // fixed validation/commit bubble per descriptor to remove the wide
    // checker from the descriptor-cache CE timing path.
    parameter integer PIPELINED_DESCRIPTOR_VALIDATION = 0,
    // Optional exact-width tensor-size arithmetic for the descriptor checker.
    // Default zero preserves the reference 64-bit expression.
    parameter integer NARROW_DESCRIPTOR_SIZE_CHECK = 0,
    // Optional narrow/shift-add tensor address arithmetic.  Keep disabled in
    // the default correctness build until the target FPGA timing is measured.
    parameter integer FAST_TENSOR_ADDRESS_ARITH = 0,
    // Optional real register boundaries between coordinate transforms,
    // pixel-index arithmetic and the final tensor byte-address calculation.
    // This costs two core cycles per memory request; it is disabled in the
    // default compatibility build.
    parameter integer PIPELINED_TENSOR_ADDRESS = 0,
    // Optional third arithmetic boundary: register y*width, then add x on the
    // next cycle before final group/byte scaling.  It is meaningful only when
    // PIPELINED_TENSOR_ADDRESS is enabled and is disabled by default.
    parameter integer PIPELINED_TENSOR_PIXEL_INDEX = 0,
    // Optional arithmetic split for strict descriptor tensor-size checks.
    // Disabled by default; when enabled it is meaningful together with
    // PIPELINED_DESCRIPTOR_VALIDATION and adds two checker cycles per stage.
    parameter integer PIPELINED_DESCRIPTOR_SIZE_ARITH = 0,
    // Optional Case-1 fixed-bank threshold comparator refinement.  It is
    // meaningful only with the descriptor-size arithmetic pipeline and is
    // disabled by default.
    parameter integer FIXED_DESCRIPTOR_SIZE_LIMITS = 0,
    // Optional extra W/H capture boundary for the fixed descriptor-size path.
    // Disabled by default and inert unless the fixed-limit pipeline is active.
    parameter integer PIPELINED_DESCRIPTOR_PIXEL_COUNT = 0,
    // Optional one-cycle register boundary between frame-pair resolution and
    // the Resize/compute shell.  Disabled in the compatibility build.
    parameter integer PIPELINED_START_CONFIG = 0,
    // Optional registered destructive-flush boundary in the Resize ingress.
    // Raw abort still fences all external handshakes immediately; the option
    // only gives the child synchronous state machines a complete reset edge.
    parameter integer REGISTER_ABORT_RESET = 0,
    // Optional one-stage dot-product reduction pipeline.  Disabled by default
    // because it adds one cycle to the final dot result.
    parameter integer PIPELINED_DOT_TREE = 0,
    parameter integer PIPELINED_DOT_TREE_FULL = 0,
    // Optional registered descriptor replay in the CNN wrapper.  It adds one
    // initial prefetch cycle but keeps one descriptor/clock after fill.
    parameter integer PIPELINED_DESCRIPTOR_REPLAY = 0,
    // Optional capture-time descriptor validation.  The cached five-bit
    // result removes the wide validation tree from descriptor replay timing.
    parameter integer PREVALIDATE_DESCRIPTOR_REPLAY = 0,
    // Optional two-cycle validation schedule in the replay-side command
    // decoder.  Default zero preserves the historical direct decoder path;
    // enable only for a measured timing build because configuration replay
    // gains a fixed validation bubble per stage.
    parameter integer PIPELINED_DECODER_VALIDATION = 0,
    // Optional synthesis-only replication of the lifecycle abort broadcast.
    // Default zero preserves the original cycle-accurate control net.
    parameter integer REPLICATE_ABORT_CONTROL = 0,
    // Optional registered subsystem-fault ticket.  Manual software abort and
    // system-disable fences remain immediate; only classified internal fatal
    // errors cross this one-cycle boundary.
    parameter integer REGISTER_FATAL_TICKET = 0,
    // Optional depth-2 complete-payload CNN result boundary.  Default zero
    // preserves the direct CNN-to-adapter path.
    parameter integer ENABLE_UNIFIED_OUTPUT_FIFO = 0,
    // Optional one-entry complete-payload CNN result skid boundary.  Default
    // zero preserves the direct path and keeps the depth-2 experiment
    // independently selectable.
    parameter integer ENABLE_UNIFIED_OUTPUT_SKID = 0,
    // Optional Efinity-friendly packed affine-cache representation.  Keep
    // zero for the compatibility image; set one for Ti60 multi-group builds
    // after boardless map/P&R and functional gates pass.
    parameter integer PACKED_AFFINE_CACHE = 0,
    // Default-off observation boundary for the native seven-client AXI
    // fabric.  Enabling it adds counters only; it does not alter arbitration,
    // payload routing, or the owner/epoch fence.
    parameter integer ENABLE_SHARED_QOS_MONITOR = 0,
    // Per-client QoS counters default to 24 bits.  At 100 MHz this covers
    // 167 ms of continuous wait/hold time, comfortably beyond a 15-fps
    // 66.7-ms frame while avoiding a wide diagnostic carry chain.  Override
    // only when a longer measured frame budget is worth the timing cost.
    parameter integer SHARED_QOS_COUNTER_W = 24,
    // A zero value disables the deadline comparison until a measured board or
    // native long-frame budget is available. Out-of-range positive deadlines
    // clamp to the counter maximum, never wrap to zero (disabled). This is a
    // conservative alarm: increase SHARED_QOS_COUNTER_W for an exact larger
    // budget. The default effective deadline width is 24 bits.
    // The parameter is deliberately separate from JOB_CYCLE_BUDGET so the
    // existing watchdog semantics stay unchanged in compatibility builds.
    parameter logic [31:0] SHARED_QOS_DEADLINE_CYCLES = 32'd0,
    // Optional synthesis preservation hint for the fixed descriptor-size
    // operand registers.  Default zero leaves Vivado's normal optimization
    // freedom; the adapter consumes this only for a timing A/B build.
    parameter integer KEEP_DESCRIPTOR_SIZE_OPERANDS = 0,
    // Optional 16-cycle shift/add W*H calculator in the fixed descriptor-size
    // checker.  Appended to preserve positional parameter compatibility.
    parameter integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT = 0,
    // Optional timing candidate for the cache-enabled path.  When enabled,
    // the tensor adapter registers SAME_REPLICATE-saturated tap coordinates
    // before either cache client sees them; the payload cache can then omit a
    // duplicate width/height compare.  Default zero retains the general-
    // purpose signed-logical-coordinate cache contract.
    parameter integer PRECLAMPED_TAP_COORDS = 0,
    // Opt-in background display refills during CNN work; requires enough
    // response FIFO credit for a complete burst on each display reader.
    parameter integer CONCURRENT_DISPLAY_PREFETCH = 0,
    // Ordered result-write admission; downstream responses remain commit
    // acknowledgements. Does not itself replace the single-beat AXI bridge.
    parameter integer PIPELINED_RESULT_WRITES = 0,
    parameter integer ENABLE_TENSOR_PACKED_WRITES = 0,
    parameter integer USE_TENSOR_WRITE_END = 0,
    // Opt-in queued writes. Protocol faults lock admission until the shared
    // control/fabric reset; software ABORT does not repair corrupted AXI state.
    parameter integer FABRIC_WRITE_FIFO_DEPTH = 0,
    parameter bit FABRIC_WRITE_W_AHEAD_OF_B = 1'b0,
    parameter bit FABRIC_WRITE_EMPTY_AW_BYPASS = 1'b0,
    // The default refill scheduler limits logical requests to 16. Expose the
    // backing request FIFO depth for measured storage tuning; keep the
    // historical allocation unless an integration explicitly selects it.
    parameter integer TENSOR_BURST_REQ_FIFO_DEPTH = 32,
    parameter integer TENSOR_BURST_SCHED_MAX_OUTSTANDING = 16,
    // Shared by scalar burst refill and the column exact-count backend.
    // Requests remain registered; 32-credit operation changes only scheduler
    // metadata capacity, not the number of AXI reader descriptors/MAC lanes.
    parameter bit TENSOR_BURST_SCHED_REQ_HANDOFF = 1'b0,
    // Opt-in Resize preview capture. Slots share processed-frame ownership,
    // NOT addresses. Integrator must reserve two disjoint FRAME_WIDTH*HEIGHT*4
    // byte slots outside all other live DDR allocations. Defaults fail closed.
    parameter bit ENABLE_PREVIEW_CAPTURE = 1'b0,
    parameter logic [31:0] PREVIEW_BUFFER0_BASE = 32'd0,
    parameter logic [31:0] PREVIEW_BUFFER1_BASE = 32'd0,
    parameter logic [32:0] PREVIEW_REGION_BEGIN = 33'd0,
    parameter logic [32:0] PREVIEW_REGION_END = 33'h1_0000_0000,
    // Static first-display-source selection; implies preview capture so an
    // unwritten preview can never be selected merely by omitting CAPTURE.
    parameter bit DISPLAY_RESIZED_PREVIEW = 1'b0,
    // Leave disabled for a sensor/CSI stream that cannot honor backpressure.
    parameter bit CAMERA_READY_VALID_SOURCE = 1'b0,
    // Experimental hardware raster rejection/local ISP recovery. Validate
    // writer cancellation and ownership drain before enabling in a board build.
    parameter bit CHECK_RAW_RASTER = 1'b0,
    parameter integer RAW_IDLE_TIMEOUT_CYCLES = 0,
    parameter bit ENABLE_EXPLICIT_CAPTURE_RECOVERY = 1'b0,
    // Opt-in shared-engine throughput experiments. Default-off until the
    // selected combination passes whole-system numerical/recovery gates.
    parameter integer CACHE_DW_WEIGHT_TILES = 0,
    parameter integer MAC_PREFETCH_OVERLAP = 0,
    parameter integer PREFETCH_NEXT_TAP_ADDRESS = 0,
    parameter integer REUSE_HORIZONTAL_WINDOW = 0,
    parameter bit ENABLE_TENSOR_COLUMN_READS = 1'b0,
    parameter bit TENSOR_COLUMN_READ_ON_LOOKUP = 1'b0,
    parameter bit TENSOR_SCALAR_READ_BEAT_CACHE = 1'b0,
    parameter integer TENSOR_SCALAR_READ_CACHE_ENTRIES = 1,
    parameter bit TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION = 1'b0,
    // Fixed graph storage optimization; requires the column-cache branch.
    parameter bit VIRTUAL_UPSAMPLE_TENSORS = 1'b0,
    parameter bit STREAM_DW_GROUPS = 1'b0,
    parameter bit OVERLAP_COLUMN_WRITEBACK = 1'b0,
    parameter bit POINTWISE_COLUMN_READS = 1'b0,
    parameter bit TENSOR_COLUMN_RESPONSE_BYPASS = 1'b0,
    parameter bit PREFETCH_NEXT_PIXEL_COLUMN = 1'b0,
    parameter bit PIPELINED_SOURCE_WRITES = 1'b0,
    parameter bit STREAM_POINTWISE_REDUCTION = 1'b0,
    parameter bit OVERLAP_MAC_REQUANTIZATION = 1'b0,
    parameter bit PREFETCH_ALL_PIXEL_GROUPS = 1'b0,
    parameter bit PIPELINE_DOT_PIXELS = 1'b0,
    parameter integer TENSOR_WRITE_OUTSTANDING = 1,
    parameter integer PIXEL_WRITE_BATCH_WORDS = 1,
    parameter integer TENSOR_WRITE_BUILD_TIMEOUT = 8,
    parameter bit PIPELINE_DW_PIXELS = 1'b0,
    parameter bit STREAM_DW_FRAME = 1'b0,
    parameter bit PIPELINE_ALL_DOT_GROUPS = 1'b0,
    parameter bit PACK_RGB_CONV_REDUCTION = 1'b0,
    parameter bit ELIDE_VIRTUAL_UPSAMPLE = 1'b0,
    parameter bit TENSOR_COLUMN_REUSE_ROW_MAP = 1'b0,
    parameter bit FUSE_FINAL_OUTPUT = 1'b0
) (
    input  logic                         core_clk,
    input  logic                         pixel_clk,
    input  logic                         camera_clk,
    input  logic                         arst_n,

    input  logic                         psel,
    input  logic                         penable,
    input  logic                         pwrite,
    input  logic [APB_ADDR_W-1:0]        paddr,
    input  logic [31:0]                  pwdata,
    input  logic [3:0]                   pstrb,
    output logic [31:0]                  prdata,
    output logic                         pready,
    output logic                         pslverr,
    output logic                         irq,

    input  logic                         camera_valid,
    output logic                         camera_ready,
    input  logic [9:0]                   camera_raw10,
    input  logic [CAMERA_X_BITS-1:0]     camera_x,
    input  logic [CAMERA_Y_BITS-1:0]     camera_y,
    input  logic                         camera_sof,
    input  logic                         camera_eol,
    input  logic                         camera_eof,
    output logic                         camera_overflow,

    output logic [23:0]                  video_rgb,
    output logic                         video_de,
    output logic                         video_hsync,
    output logic                         video_vsync,

    output logic [4:0]                   engine_stage_index,
    output logic [7:0]                   engine_stage_opcode,
    output logic                         engine_stage_active,
    output logic                         engine_overflow_seen,
    output logic                         system_busy,

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
    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,
    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready,
    // Synchronous core-domain hardware recovery interface. Optional APB command
    // shares this path, with external hardware requests taking priority.
    // Accept on request && ready. Stop the source before asserting quiescent;
    // keep it stopped through done. Both clocks must run to finish FIFO reset.
    // External asynchronous acknowledgements require a board-level CDC bridge.
    // Disabled by default; held requests are accepted once, not queued.
    input logic capture_recovery_request,capture_source_quiescent,
    output logic capture_recovery_ready,capture_recovery_busy,capture_recovery_done
);

    // Client numbering is part of the board-independent memory contract.
    // The tensor adapter/cache/bridge path is the seventh, zero-based client;
    // keep the symbolic index beside the fabric width so a future client
    // insertion cannot silently move it.
    localparam bit PREVIEW_CAPTURE_ACTIVE=ENABLE_PREVIEW_CAPTURE || DISPLAY_RESIZED_PREVIEW;
    localparam integer AXI_CLIENT_COLUMN = PREVIEW_CAPTURE_ACTIVE ? 8 : 7;
    localparam integer AXI_CLIENTS = AXI_CLIENT_COLUMN + (ENABLE_TENSOR_COLUMN_READS ? 1 : 0);
    localparam integer AXI_CLIENT_TENSOR_CACHE = 6;
    localparam integer AXI_INDEX_W =
        (AXI_CLIENTS <= 1) ? 1 : $clog2(AXI_CLIENTS);

`ifndef SYNTHESIS
    initial begin
        if(TENSOR_WRITE_OUTSTANDING!=1 && TENSOR_WRITE_OUTSTANDING!=2 && TENSOR_WRITE_OUTSTANDING!=4)
            $fatal(1,"tensor write outstanding must be 1, 2 or 4");
        if(TENSOR_WRITE_OUTSTANDING!=1 && (!ENABLE_TENSOR_COLUMN_READS || !ENABLE_TENSOR_PACKED_WRITES))
            $fatal(1,"tensor write MLP requires packed column branch");
        if(PIXEL_WRITE_BATCH_WORDS!=1 && ((!PIPELINE_DOT_PIXELS && !PIPELINE_DW_PIXELS) || !ENABLE_TENSOR_PACKED_WRITES || !USE_TENSOR_WRITE_END))
            $fatal(1,"pixel write batching requires dot or DW pixels, packing and end markers");
        if(TENSOR_WRITE_BUILD_TIMEOUT<1 || TENSOR_WRITE_BUILD_TIMEOUT>255)
            $fatal(1,"tensor write build timeout must be 1..255");
        if(TENSOR_WRITE_BUILD_TIMEOUT!=8 && (!ENABLE_TENSOR_COLUMN_READS || !ENABLE_TENSOR_PACKED_WRITES))
            $fatal(1,"tensor write build timeout requires packed column branch");
        if (TENSOR_COLUMN_REUSE_ROW_MAP && !ENABLE_TENSOR_COLUMN_READS)
            $fatal(1,"column row-map reuse requires tensor column reads");
        if (TENSOR_COLUMN_RESPONSE_BYPASS && !ENABLE_TENSOR_COLUMN_READS)
            $fatal(1,"column response bypass requires tensor column reads");
        if (VIRTUAL_UPSAMPLE_TENSORS && !ENABLE_TENSOR_COLUMN_READS)
            $fatal(1,"virtual upsample tensors require tensor column reads");
        if (TENSOR_SCALAR_READ_BEAT_CACHE && !ENABLE_TENSOR_COLUMN_READS)
            $fatal(1,"Scalar read-beat cache is currently wired only in the column tensor branch");
        if (TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION && !TENSOR_SCALAR_READ_BEAT_CACHE)
            $fatal(1,"Precise write invalidation requires the scalar read-beat cache");
        if(TENSOR_SCALAR_READ_CACHE_ENTRIES!=1 && TENSOR_SCALAR_READ_CACHE_ENTRIES!=2)
            $fatal(1,"scalar read cache entries must be 1 or 2");
        if(TENSOR_SCALAR_READ_CACHE_ENTRIES!=1 && !TENSOR_SCALAR_READ_BEAT_CACHE)
            $fatal(1,"two scalar read entries require the scalar read-beat cache");
        if (USE_TENSOR_WRITE_END != 0 && ENABLE_TENSOR_PACKED_WRITES == 0)
            $fatal(1,"Tensor write end markers require packed writes");
        if (ENABLE_TENSOR_PACKED_WRITES != 0 && ENABLE_TENSOR_BURST_REFILL == 0 && !ENABLE_TENSOR_COLUMN_READS)
            $fatal(1,"Packed tensor writes require the burst tensor client branch");
        if (AXI_CLIENT_TENSOR_CACHE >= AXI_CLIENTS)
            $fatal(1, "tensor cache client index exceeds AXI fabric width");
        if ((CONCURRENT_DISPLAY_PREFETCH != 0) &&
            ((ENABLE_DISPLAY_RESPONSE_FIFO == 0) || (DISPLAY_RESPONSE_FIFO_DEPTH < 64)))
            $fatal(1, "Concurrent display requires response FIFOs of at least 64 pixels");
    end
`endif

    logic core_srst_n, pixel_srst_n, camera_srst_n;
    logic core_rst, pixel_rst, camera_rst;

    logic csr_psel, csr_penable, csr_pwrite;
    logic [APB_ADDR_W-1:0] csr_paddr;
    logic [31:0] csr_pwdata, csr_prdata;
    logic [3:0] csr_pstrb;
    logic csr_pready, csr_pslverr;
    logic isp_psel, isp_penable, isp_pwrite;
    logic [APB_ADDR_W-1:0] isp_paddr;
    logic [31:0] isp_pwdata, isp_prdata;
    logic [3:0] isp_pstrb;
    logic isp_pready, isp_pslverr;

    logic csr_system_enable, csr_continuous_mode;
    logic csr_drop_oldest_mode, csr_start_pulse, csr_abort_pulse;
    logic csr_clear_stats_pulse;
    logic [15:0] csr_frame_width, csr_frame_height;
    logic [31:0] csr_input_frame_size;
    logic [15:0] boardless_source_width, boardless_source_height;
    logic signed [31:0] csr_resize_x_step, boardless_resize_x_step;
    logic signed [31:0] csr_resize_y_step, boardless_resize_y_step;
    logic signed [31:0] csr_resize_x_phase0, boardless_resize_x_phase0;
    logic signed [31:0] csr_resize_y_phase0, boardless_resize_y_phase0;
    logic [31:0] csr_input_stride, csr_output_stride;
    logic [3:0] csr_input_format, csr_output_format;
    logic [63:0] csr_input_table_base, csr_output_table_base;
    logic [63:0] csr_descriptor_base, csr_weight_base;
    logic [31:0] csr_tensor_base;
    logic [15:0] csr_descriptor_count;
    logic [7:0] csr_style_id, csr_display_mode;
    logic control_done_event, control_error_event;
    logic [7:0] control_error_code;
    logic [31:0] control_error_address;
    logic control_capture_drop_event, control_display_swap_event;
    logic display_prefetch_new_done_event;
    logic [2:0] control_input_ready_count;
    logic [1:0] control_output_ready_count;
    logic [31:0] control_display_frame_id;
    logic display_underflow_event;

    logic isp_cfg_valid, isp_cfg_ready;
    logic [1:0] isp_cfg_bayer_pattern;
    logic isp_cfg_roi_x_parity, isp_cfg_roi_y_parity;
    logic [9:0] isp_cfg_black_r, isp_cfg_black_gr;
    logic [9:0] isp_cfg_black_gb, isp_cfg_black_b;
    logic [15:0] isp_cfg_awb_gain_r, isp_cfg_awb_gain_g;
    logic [15:0] isp_cfg_awb_gain_b;
    logic signed [15:0] isp_cfg_ccm_rr, isp_cfg_ccm_rg;
    logic signed [15:0] isp_cfg_ccm_rb, isp_cfg_ccm_gr;
    logic signed [15:0] isp_cfg_ccm_gg, isp_cfg_ccm_gb;
    logic signed [15:0] isp_cfg_ccm_br, isp_cfg_ccm_bg;
    logic signed [15:0] isp_cfg_ccm_bb;
    logic signed [31:0] isp_cfg_ccm_offset_r;
    logic signed [31:0] isp_cfg_ccm_offset_g;
    logic signed [31:0] isp_cfg_ccm_offset_b;
    logic isp_gamma_valid, isp_gamma_ready;
    logic [9:0] isp_gamma_addr;
    logic [7:0] isp_gamma_data;
    logic isp_abort_pending_config_unused;

    logic parameter_start_valid, parameter_start_ready;
    logic [31:0] parameter_base_addr;
    logic parameter_abort_request, parameter_abort_pending;
    logic parameter_busy, parameter_done, parameter_error;
    logic parameter_aborted;
    logic [3:0] parameter_error_code;
    logic [31:0] parameter_error_address;
    logic parameter_active_valid, parameter_active_bank;
    logic [31:0] parameter_generation;
    logic parameter_rd_en, parameter_rd_valid, parameter_rd_error;
    logic [PARAM_ADDR_W-1:0] parameter_rd_addr;
    logic [127:0] parameter_rd_data;

    logic capture_frame_waiting, capture_begin_ready;
    logic capture_begin_frame, capture_drop_frame;
    logic capture_abort_frame, capture_clear_error;
    logic capture_discard_idle, capture_cleanup_busy;
    logic capture_ingress_done, capture_frame_dropped;
    logic capture_frame_aborted, capture_error;
    logic [7:0] capture_error_code;
    logic capture_table_request_valid, capture_table_request_ready;
    logic [63:0] capture_table_request_base;
    logic [1:0] capture_table_request_index;
    logic capture_table_response_valid, capture_table_response_ready;
    logic capture_table_response_error;
    logic [63:0] capture_table_response_base;
    logic [31:0] capture_table_response_stride;
    logic [15:0] capture_table_response_width;
    logic [15:0] capture_table_response_height;
    logic capture_table_abort_request, capture_table_abort_pending;
    logic capture_writer_start, capture_writer_cancel;
    logic [31:0] capture_writer_base, capture_writer_stride;
    logic [15:0] capture_writer_width, capture_writer_height;
    logic capture_writer_busy, capture_writer_done, capture_writer_error;

    logic boardless_start_valid, boardless_start_ready;
    logic boardless_abort, boardless_busy, boardless_done;
    logic boardless_error, boardless_aborted;
    logic [7:0] boardless_error_code;
    logic [31:0] boardless_error_address;
    logic [1:0] boardless_input_index, boardless_output_index;
    logic [63:0] boardless_input_table_base;
    logic [63:0] boardless_output_table_base;
    logic [15:0] boardless_frame_width, boardless_frame_height;
    logic [31:0] boardless_descriptor_base;
    logic [15:0] boardless_descriptor_count;
    logic [31:0] boardless_cycle_budget;
    logic [31:0] boardless_tensor_base;
    logic [31:0] resolved_input_base, resolved_input_stride;
    logic [15:0] resolved_input_width, resolved_input_height;
    logic [31:0] resolved_output_base, resolved_output_stride;
    logic [15:0] resolved_output_width, resolved_output_height;
    logic [31:0] resolved_preview_base,resolved_preview_stride;
    logic boardless_active_config_bank;
    logic [15:0] boardless_active_config_count;
    logic [7:0] boardless_active_config_generation;
    logic boardless_dispatch_complete;
    logic stage_config_valid, stage_config_ready;
    logic [15:0] stage_config_index;
    logic [511:0] stage_config_descriptor;
    logic [7:0] stage_config_generation;
    logic cnn_start_valid, cnn_start_ready, cnn_abort;
    logic cnn_error;
    logic [7:0] cnn_error_code;
    logic board_cnn_in_valid, board_cnn_in_ready;
    logic [63:0] board_cnn_in_data;
    logic [15:0] board_cnn_in_x, board_cnn_in_y;
    logic board_cnn_in_sof, board_cnn_in_eol, board_cnn_in_eof;
    logic board_cnn_out_valid, board_cnn_out_ready;
    logic [63:0] board_cnn_out_data;
    logic [15:0] board_cnn_out_x, board_cnn_out_y;
    logic board_cnn_out_sof, board_cnn_out_eol, board_cnn_out_eof;
    logic bridge_busy, bridge_done, bridge_aborted;
    logic bridge_config_complete;
    logic engine_adapter_required, engine_stage_done;
    logic control_status_busy;
    logic tensor_adapter_busy, tensor_adapter_done;
    logic tensor_adapter_aborted, tensor_adapter_config_complete;

    logic adapter_start_valid, adapter_start_ready, adapter_abort;
    logic adapter_stage_config_valid, adapter_stage_config_ready;
    logic [15:0] adapter_stage_config_index;
    logic [511:0] adapter_stage_config_descriptor;
    logic [7:0] adapter_stage_config_generation;
    logic adapter_error;
    logic [7:0] adapter_error_code;
    logic adapter_source_valid, adapter_source_ready;
    logic [63:0] adapter_source_data_s8;
    logic [15:0] adapter_source_x, adapter_source_y;
    logic adapter_source_sof, adapter_source_eol, adapter_source_eof;
    logic adapter_engine_valid, adapter_engine_ready;
    logic adapter_view_valid,adapter_view_ready;
    logic [4:0] adapter_view_stage;
    logic [7:0] adapter_view_generation;
    logic [575:0] adapter_engine_window_s8;
    logic [63:0] adapter_engine_residual_s8;
    logic [2:0] adapter_engine_group_index;
    logic adapter_engine_group_last;
    logic [15:0] adapter_engine_x, adapter_engine_y;
    logic adapter_engine_sof, adapter_engine_eol, adapter_engine_eof;
    logic adapter_result_valid, adapter_result_ready;
    logic [63:0] adapter_result_data_s8;
    logic [2:0] adapter_result_group_index;
    logic adapter_result_group_last;
    logic [15:0] adapter_result_x, adapter_result_y;
    logic adapter_result_sof, adapter_result_eol, adapter_result_eof;
    logic adapter_final_valid, adapter_final_ready;
    logic [63:0] adapter_final_data_s8;
    logic [15:0] adapter_final_x, adapter_final_y;
    logic adapter_final_sof, adapter_final_eol, adapter_final_eof;
    logic tensor_mem_req_valid, tensor_mem_req_ready;
    logic tensor_mem_req_end;
    logic tensor_mem_req_write;
    logic [31:0] tensor_mem_req_addr;
    logic [63:0] tensor_mem_req_wdata;
    logic [7:0] tensor_mem_req_wstrb;
    logic tensor_mem_rsp_valid, tensor_mem_rsp_ready;
    logic tensor_mem_rsp_error;
    logic [63:0] tensor_mem_rsp_rdata;
    logic tensor_mem_req_cacheable;
    logic signed [16:0] tensor_mem_req_cache_x;
    logic signed [16:0] tensor_mem_req_cache_y;
    logic [2:0] tensor_mem_req_cache_group;
    logic tensor_cache_stage_start_valid;
    logic tensor_column_valid,tensor_column_ready,tensor_column_rsp_valid,tensor_column_rsp_ready;
    logic signed [16:0] tensor_column_x,tensor_column_y;
    logic [2:0] tensor_column_group;
    logic [191:0] tensor_column_data;
    logic tensor_column_error;
    logic tensor_column_allow_pending_writes;
    logic tensor_cache_stage_start_ready;
    logic tensor_cache_stage_enable;
    logic [31:0] tensor_cache_stage_base_addr;
    logic [15:0] tensor_cache_stage_width;
    logic [15:0] tensor_cache_stage_height;
    logic [3:0] tensor_cache_stage_groups;

    // These diagnostics intentionally remain internal to the portable SoC;
    // board wrappers do not need cache-specific pins.  Structural smoke tests
    // inspect them hierarchically until software-visible counters are added.
    logic tensor_cache_stage_start_done;
    logic tensor_cache_stage_active;
    logic tensor_cache_stage_fallback;
    logic [3:0] tensor_cache_stage_reason;
    logic tensor_cache_abort_done;
    logic tensor_cache_error;
    logic [2:0] tensor_cache_error_code;
    logic tensor_cache_busy;
    logic tensor_cache_quiescent;

    logic display_frame_start_event;
    logic display_prefetch_start_valid, display_prefetch_start_ready;
    logic display_prefetch_abort, display_flush_request;
    logic display_flush_busy, display_flush_done;
    logic [31:0] display_original_base, display_original_stride;
    logic [31:0] display_styled_base, display_styled_stride;
    wire [96:0] boardless_expected_input;
    wire boardless_region_request,boardless_region_cancel,boardless_region_response;
    wire [7:0] boardless_region_error_code;
    wire [31:0] boardless_region_error_address;
    logic [15:0] display_width, display_height;
    logic [15:0] display_original_width, display_original_height;
    logic display_prefetch_busy, display_prefetch_done;
    logic display_prefetch_aborted, display_prefetch_error;
    logic display_prefetch_primed;
    logic display_feed_active;
    logic display_hold_requests;
    logic osd_alarm_q;
    logic [31:0] osd_status_word;

    logic [AXI_CLIENTS-1:0][31:0] axi_s_awaddr;
    logic [AXI_CLIENTS-1:0][7:0] axi_s_awlen;
    logic [AXI_CLIENTS-1:0][2:0] axi_s_awsize;
    logic [AXI_CLIENTS-1:0][1:0] axi_s_awburst;
    logic [AXI_CLIENTS-1:0] axi_s_awvalid, axi_s_awready;
    logic [AXI_CLIENTS-1:0][127:0] axi_s_wdata;
    logic [AXI_CLIENTS-1:0][15:0] axi_s_wstrb;
    logic [AXI_CLIENTS-1:0] axi_s_wlast, axi_s_wvalid, axi_s_wready;
    logic [AXI_CLIENTS-1:0][1:0] axi_s_bresp;
    logic [AXI_CLIENTS-1:0] axi_s_bvalid, axi_s_bready;
    logic [AXI_CLIENTS-1:0][31:0] axi_s_araddr;
    logic [AXI_CLIENTS-1:0][7:0] axi_s_arlen;
    logic [AXI_CLIENTS-1:0][2:0] axi_s_arsize;
    logic [AXI_CLIENTS-1:0][1:0] axi_s_arburst;
    logic [AXI_CLIENTS-1:0] axi_s_arvalid, axi_s_arready;
    logic [AXI_CLIENTS-1:0][127:0] axi_s_rdata;
    logic [AXI_CLIENTS-1:0][1:0] axi_s_rresp;
    logic [AXI_CLIENTS-1:0] axi_s_rlast, axi_s_rvalid, axi_s_rready;

    // Read-only owner/status outputs from the real serial arbiter.  They are
    // consumed by the optional QoS monitor now and by the owner/epoch fence
    // when a future default-path integration is enabled.
    logic fabric_read_busy, fabric_read_quiescent;
    logic fabric_write_busy, fabric_write_quiescent;
    logic fabric_write_protocol_error;
    logic [AXI_INDEX_W-1:0] fabric_read_owner, fabric_write_owner;

    // Hierarchical diagnostics for native builds.  These vectors stay inside
    // the portable SoC so the board wrapper and APB ABI remain unchanged.
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_aw_accept_count;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_w_accept_count;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_b_accept_count;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_ar_accept_count;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_r_accept_count;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_aw_wait_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_w_wait_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_b_stall_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_ar_wait_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_r_stall_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_aw_wait_max;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_w_wait_max;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_b_stall_max;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_ar_wait_max;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_r_stall_max;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_read_owner_hold_total;
    logic [AXI_CLIENTS-1:0][SHARED_QOS_COUNTER_W-1:0] qos_write_owner_hold_total;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_read_owner_hold_max;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_write_owner_hold_max;
    logic [AXI_INDEX_W-1:0] qos_read_owner_hold_max_owner;
    logic [AXI_INDEX_W-1:0] qos_write_owner_hold_max_owner;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_read_busy_cycles, qos_write_busy_cycles;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_frame_count, qos_current_frame_cycles;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_last_frame_cycles, qos_deadline_miss_count;
    logic [SHARED_QOS_COUNTER_W-1:0] qos_display_underflow_count, qos_protocol_error_count;
    logic qos_frame_active, qos_monitor_overflow;
    logic qos_frame_start_event, qos_frame_done_event;

    // 32-bit APB view of the optional monitor.  Assignment from the
    // parameterized counter width deliberately zero/sign extends according
    // to normal SV sizing; the APB ABI is fixed at 32 bits.
    logic qos_apb_monitor_enabled, qos_apb_frame_active, qos_apb_monitor_overflow;
    logic [31:0] qos_apb_frame_count, qos_apb_last_frame_cycles;
    logic [31:0] qos_apb_deadline_miss_count, qos_apb_display_underflow_count;
    logic [31:0] qos_apb_read_busy_cycles, qos_apb_write_busy_cycles;
    logic [31:0] qos_apb_read_owner_hold_max, qos_apb_write_owner_hold_max;
    logic [31:0] qos_apb_protocol_error_count;

    // Software BUSY is also the external-memory quiescence fence.  The SoC
    // lifecycle controller may retire its foreground ownership before an
    // aborted adapter has consumed the response to its last accepted tensor
    // transaction.  An enabled window cache can then require additional
    // maintenance cycles before its tags/configuration are safe to reuse, so
    // retain BUSY until the bridge, adapter, and optional cache are all idle.
    // One accepted request cancels every client through the normal lifecycle
    // controller. Do not hold abort throughout recovery: that would repeatedly
    // request the display flush that this recovery must wait to finish.
    wire csr_capture_recovery_request;
    wire capture_recovery_request_mux = capture_recovery_request || csr_capture_recovery_request;
    wire capture_recovery_accept = ENABLE_EXPLICIT_CAPTURE_RECOVERY &&
        capture_recovery_request_mux && capture_recovery_ready;
    // A fabric may be idle while a leaf still offers a stalled address/data.
    // Require both fabric drain and no pending offers before local FIFO reset.
    wire capture_recovery_safe = fabric_read_quiescent && !(|axi_s_arvalid) &&
        fabric_write_quiescent && !(|axi_s_awvalid) && !(|axi_s_wvalid) &&
        !boardless_busy && !parameter_busy && !parameter_abort_pending &&
        !display_prefetch_busy && !display_flush_busy &&
        !bridge_busy && !tensor_adapter_busy && !tensor_cache_busy;
    assign system_busy = capture_recovery_busy || control_status_busy || bridge_busy ||
                         tensor_adapter_busy || tensor_cache_busy;
    // Start at the accepted boardless job boundary and retire only after the
    // newly produced display pair has completed its readers, response FIFOs,
    // and line-store drain.  The control-side qualifier excludes periodic
    // refreshes of the currently displayed pair, so one terminal pulse maps
    // to one CNN job even when the display service runs in the background.
    // The separate display-swap pulse is a VSYNC ownership commit and is not
    // used as a proxy for AXI drain completion.
    assign qos_frame_start_event = boardless_start_valid && boardless_start_ready;
    assign qos_frame_done_event = display_prefetch_new_done_event;

    c1_reset_sync u_core_reset (
        .clk(core_clk), .arst_n(arst_n), .srst_n(core_srst_n));
    c1_reset_sync u_pixel_reset (
        .clk(pixel_clk), .arst_n(arst_n), .srst_n(pixel_srst_n));
    c1_reset_sync u_camera_reset (
        .clk(camera_clk), .arst_n(arst_n), .srst_n(camera_srst_n));
    assign core_rst = ~core_srst_n;
    assign pixel_rst = ~pixel_srst_n;
    assign camera_rst = ~camera_srst_n;

    c1_apb_r1_mux #(.APB_ADDR_W(APB_ADDR_W)) u_apb_mux (
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready),
        .pslverr(pslverr),
        .csr_psel(csr_psel), .csr_penable(csr_penable),
        .csr_pwrite(csr_pwrite), .csr_paddr(csr_paddr),
        .csr_pwdata(csr_pwdata), .csr_pstrb(csr_pstrb),
        .csr_prdata(csr_prdata), .csr_pready(csr_pready),
        .csr_pslverr(csr_pslverr),
        .isp_psel(isp_psel), .isp_penable(isp_penable),
        .isp_pwrite(isp_pwrite), .isp_paddr(isp_paddr),
        .isp_pwdata(isp_pwdata), .isp_pstrb(isp_pstrb),
        .isp_prdata(isp_prdata), .isp_pready(isp_pready),
        .isp_pslverr(isp_pslverr)
    );

    c1_apb_csr #(.APB_ADDR_W(APB_ADDR_W),
        .ENABLE_CAPTURE_RECOVERY(ENABLE_EXPLICIT_CAPTURE_RECOVERY)) u_csr (
        .recovery_ready(capture_recovery_ready && !capture_recovery_request),
        .recovery_busy(capture_recovery_busy),.recovery_done(capture_recovery_done),
        .source_quiescent(capture_source_quiescent),
        .recovery_request(csr_capture_recovery_request),
        .input_frame_size(csr_input_frame_size),
        .resize_x_step_q16(csr_resize_x_step),
        .resize_y_step_q16(csr_resize_y_step),
        .resize_x_phase0_q16(csr_resize_x_phase0),
        .resize_y_phase0_q16(csr_resize_y_phase0),
        .clk(core_clk), .rst_n(core_srst_n),
        .psel(csr_psel), .penable(csr_penable), .pwrite(csr_pwrite),
        .paddr(csr_paddr), .pwdata(csr_pwdata), .pstrb(csr_pstrb),
        .prdata(csr_prdata), .pready(csr_pready),
        .pslverr(csr_pslverr), .busy(system_busy),
        .done_event(control_done_event), .error_event(control_error_event),
        .error_code_in(control_error_code),
        .error_address_in(control_error_address),
        .capture_drop_event(control_capture_drop_event),
        .display_swap_event(control_display_swap_event),
        .display_underflow_event(display_underflow_event),
        .input_ready_count(control_input_ready_count),
        .output_ready_count(control_output_ready_count),
        .qos_monitor_enabled(qos_apb_monitor_enabled),
        .qos_frame_active(qos_apb_frame_active),
        .qos_monitor_overflow(qos_apb_monitor_overflow),
        .qos_frame_count(qos_apb_frame_count),
        .qos_last_frame_cycles(qos_apb_last_frame_cycles),
        .qos_deadline_miss_count(qos_apb_deadline_miss_count),
        .qos_display_underflow_count(qos_apb_display_underflow_count),
        .qos_read_busy_cycles(qos_apb_read_busy_cycles),
        .qos_write_busy_cycles(qos_apb_write_busy_cycles),
        .qos_read_owner_hold_max(qos_apb_read_owner_hold_max),
        .qos_write_owner_hold_max(qos_apb_write_owner_hold_max),
        .qos_protocol_error_count(qos_apb_protocol_error_count),
        .system_enable(csr_system_enable),
        .continuous_mode(csr_continuous_mode),
        .drop_oldest_mode(csr_drop_oldest_mode),
        .start_pulse(csr_start_pulse), .abort_pulse(csr_abort_pulse),
        .clear_stats_pulse(csr_clear_stats_pulse),
        .frame_width(csr_frame_width), .frame_height(csr_frame_height),
        .input_stride_bytes(csr_input_stride),
        .output_stride_bytes(csr_output_stride),
        .input_pixel_format(csr_input_format),
        .output_pixel_format(csr_output_format),
        .input_buffer_table_base(csr_input_table_base),
        .output_buffer_table_base(csr_output_table_base),
        .descriptor_base(csr_descriptor_base),
        .descriptor_count(csr_descriptor_count),
        .style_id(csr_style_id), .weight_base(csr_weight_base),
        .tensor_base_addr(csr_tensor_base),
        .display_mode(csr_display_mode), .irq(irq)
    );

    c1_apb_isp_config #(.APB_ADDR_W(APB_ADDR_W)) u_isp_csr (
        .clk(core_clk), .rst_n(core_srst_n),
        .psel(isp_psel), .penable(isp_penable), .pwrite(isp_pwrite),
        .paddr(isp_paddr), .pwdata(isp_pwdata), .pstrb(isp_pstrb),
        .prdata(isp_prdata), .pready(isp_pready),
        .pslverr(isp_pslverr),
        .cfg_valid(isp_cfg_valid), .cfg_ready(isp_cfg_ready),
        .cfg_bayer_pattern(isp_cfg_bayer_pattern),
        .cfg_roi_x_parity(isp_cfg_roi_x_parity),
        .cfg_roi_y_parity(isp_cfg_roi_y_parity),
        .cfg_black_r(isp_cfg_black_r), .cfg_black_gr(isp_cfg_black_gr),
        .cfg_black_gb(isp_cfg_black_gb), .cfg_black_b(isp_cfg_black_b),
        .cfg_awb_gain_r(isp_cfg_awb_gain_r),
        .cfg_awb_gain_g(isp_cfg_awb_gain_g),
        .cfg_awb_gain_b(isp_cfg_awb_gain_b),
        .cfg_ccm_rr(isp_cfg_ccm_rr), .cfg_ccm_rg(isp_cfg_ccm_rg),
        .cfg_ccm_rb(isp_cfg_ccm_rb), .cfg_ccm_gr(isp_cfg_ccm_gr),
        .cfg_ccm_gg(isp_cfg_ccm_gg), .cfg_ccm_gb(isp_cfg_ccm_gb),
        .cfg_ccm_br(isp_cfg_ccm_br), .cfg_ccm_bg(isp_cfg_ccm_bg),
        .cfg_ccm_bb(isp_cfg_ccm_bb),
        .cfg_ccm_offset_r(isp_cfg_ccm_offset_r),
        .cfg_ccm_offset_g(isp_cfg_ccm_offset_g),
        .cfg_ccm_offset_b(isp_cfg_ccm_offset_b),
        .gamma_valid(isp_gamma_valid),
        .gamma_cfg_ready(isp_gamma_ready),
        .gamma_cfg_addr(isp_gamma_addr),
        .gamma_cfg_data(isp_gamma_data),
        .abort_pulse(isp_abort_pending_config_unused)
    );

    c1_r1_soc_control #(
        .FENCE_FABRIC_DRAIN(1'b1),
        .CHECK_WRITE_REGIONS(1'b1),.RESERVE_PREVIEW(PREVIEW_CAPTURE_ACTIVE),
        .DISPLAY_RESIZED_PREVIEW(DISPLAY_RESIZED_PREVIEW),
        .ENABLE_FABRIC_FAULT(FABRIC_WRITE_FIFO_DEPTH != 0),
        .SEPARATE_INPUT_GEOMETRY(1),
        // The valid 3x3 Debayer crop emits (sensor width-2)x(height-2).
        .REQUIRED_INPUT_WIDTH(SENSOR_WIDTH-2),
        .REQUIRED_INPUT_HEIGHT(SENSOR_HEIGHT-2),
        .CONFIGURABLE_RESIZE(1),
        .REQUIRED_STAGES(22),
        .JOB_CYCLE_BUDGET(JOB_CYCLE_BUDGET),
        .REQUIRED_FRAME_WIDTH(FRAME_WIDTH),
        .REQUIRED_FRAME_HEIGHT(FRAME_HEIGHT),
        .REPLICATE_ABORT_CONTROL(REPLICATE_ABORT_CONTROL),
        .REGISTER_FATAL_TICKET(REGISTER_FATAL_TICKET),
        .CONCURRENT_DISPLAY_PREFETCH(CONCURRENT_DISPLAY_PREFETCH)
    ) u_control (
        .fabric_write_protocol_error(fabric_write_protocol_error),
        .fabric_write_busy(fabric_write_busy),
        // The arbiter's idle indication excludes a client request awaiting
        // grant. Do not release canceled regions on that one-cycle gap.
        .fabric_read_quiescent(fabric_read_quiescent && !(|axi_s_arvalid)),
        .fabric_write_quiescent(fabric_write_quiescent && !(|axi_s_awvalid) && !(|axi_s_wvalid)),
        .resize_x_step_q16(csr_resize_x_step), .boardless_x_step_q16(boardless_resize_x_step),
        .resize_y_step_q16(csr_resize_y_step), .boardless_y_step_q16(boardless_resize_y_step),
        .resize_x_phase0_q16(csr_resize_x_phase0), .boardless_x_phase0_q16(boardless_resize_x_phase0),
        .resize_y_phase0_q16(csr_resize_y_phase0), .boardless_y_phase0_q16(boardless_resize_y_phase0),
        // Whole-word zero retains the legacy same-size software contract.
        // A partially zero word is NOT defaulted: control must reject it.
        .input_frame_width(csr_input_frame_size == 0 ? csr_frame_width : csr_input_frame_size[15:0]),
        .input_frame_height(csr_input_frame_size == 0 ? csr_frame_height : csr_input_frame_size[31:16]),
        .boardless_input_width(boardless_source_width),
        .boardless_input_height(boardless_source_height),
        .display_original_width(display_original_width),
        .display_original_height(display_original_height),
        .clk(core_clk), .rst(core_rst),
        .system_enable(csr_system_enable),
        .continuous_mode(csr_continuous_mode),
        .drop_oldest_mode(csr_drop_oldest_mode),
        .start_pulse(csr_start_pulse),
        .abort_pulse(csr_abort_pulse || capture_recovery_accept),
        .frame_width(csr_frame_width),
        .frame_height(csr_frame_height),
        .input_pixel_format(csr_input_format),
        .output_pixel_format(csr_output_format),
        .input_table_base(csr_input_table_base),
        .output_table_base(csr_output_table_base),
        .descriptor_base(csr_descriptor_base),
        .descriptor_count(csr_descriptor_count),
        .weight_base(csr_weight_base),
        .tensor_base_addr(csr_tensor_base),
        .status_busy(control_status_busy),
        .done_event(control_done_event),
        .error_event(control_error_event),
        .error_code(control_error_code),
        .error_address(control_error_address),
        .capture_drop_event(control_capture_drop_event),
        .display_swap_event(control_display_swap_event),
        .input_ready_count(control_input_ready_count),
        .output_ready_count(control_output_ready_count),
         .display_frame_id(control_display_frame_id),
         .display_feed_active(display_feed_active),
         .display_hold_requests(display_hold_requests),
        .parameter_start_valid(parameter_start_valid),
        .parameter_start_ready(parameter_start_ready),
        .parameter_base_addr(parameter_base_addr),
        .parameter_abort_request(parameter_abort_request),
        .parameter_abort_pending(parameter_abort_pending),
        .parameter_busy(parameter_busy),
        .parameter_done(parameter_done),
        .parameter_error(parameter_error),
        .parameter_aborted(parameter_aborted),
        .parameter_error_code(parameter_error_code),
        .parameter_error_address(parameter_error_address),
        .parameter_active_valid(parameter_active_valid),
        .parameter_generation(parameter_generation),
        .active_parameter_generation(),
        .capture_frame_waiting(capture_frame_waiting),
        .capture_begin_ready(capture_begin_ready),
        .capture_begin_frame(capture_begin_frame),
        .capture_drop_frame(capture_drop_frame),
        .capture_abort_frame(capture_abort_frame),
        .capture_clear_error(capture_clear_error),
        .capture_discard_idle(capture_discard_idle),
        .capture_cleanup_busy(capture_cleanup_busy),
        .capture_ingress_done(capture_ingress_done),
        .capture_frame_dropped(capture_frame_dropped),
        .capture_frame_aborted(capture_frame_aborted),
        .capture_error(capture_error),
        .capture_error_code(capture_error_code),
        .capture_table_request_valid(capture_table_request_valid),
        .capture_table_request_ready(capture_table_request_ready),
        .capture_table_request_base(capture_table_request_base),
        .capture_table_request_index(capture_table_request_index),
        .capture_table_response_valid(capture_table_response_valid),
        .capture_table_response_ready(capture_table_response_ready),
        .capture_table_response_error(capture_table_response_error),
        .capture_table_response_base(capture_table_response_base),
        .capture_table_response_stride(capture_table_response_stride),
        .capture_table_response_width(capture_table_response_width),
        .capture_table_response_height(capture_table_response_height),
        .capture_table_abort_request(capture_table_abort_request),
        .capture_table_abort_pending(capture_table_abort_pending),
        .capture_writer_start(capture_writer_start),
        .capture_writer_cancel(capture_writer_cancel),
        .capture_writer_base(capture_writer_base),
        .capture_writer_stride(capture_writer_stride),
        .capture_writer_width(capture_writer_width),
        .capture_writer_height(capture_writer_height),
        .capture_writer_busy(capture_writer_busy),
        .capture_writer_done(capture_writer_done),
        .capture_writer_error(capture_writer_error),
        .boardless_start_valid(boardless_start_valid),
        .boardless_start_ready(boardless_start_ready),
        .boardless_abort(boardless_abort),
        .boardless_input_index(boardless_input_index),
        .boardless_output_index(boardless_output_index),
        .boardless_input_table_base(boardless_input_table_base),
        .boardless_output_table_base(boardless_output_table_base),
        .boardless_frame_width(boardless_frame_width),
        .boardless_frame_height(boardless_frame_height),
        .boardless_descriptor_base(boardless_descriptor_base),
        .boardless_descriptor_count(boardless_descriptor_count),
        .boardless_cycle_budget(boardless_cycle_budget),
        .boardless_tensor_base_addr(boardless_tensor_base),
        .boardless_busy(boardless_busy),
        .boardless_done(boardless_done),
        .boardless_error(boardless_error),
        .boardless_aborted(boardless_aborted),
        .boardless_error_code(boardless_error_code),
        .boardless_error_address(boardless_error_address),
        .boardless_resolved_input_base(resolved_input_base),
        .boardless_resolved_input_stride(resolved_input_stride),
        .boardless_resolved_input_width(resolved_input_width),
        .boardless_resolved_input_height(resolved_input_height),
        .boardless_resolved_output_base(resolved_output_base),
        .boardless_resolved_output_stride(resolved_output_stride),
        .boardless_resolved_output_width(resolved_output_width),
        .boardless_resolved_output_height(resolved_output_height),
        .boardless_resolved_preview_base(resolved_preview_base),
        .boardless_resolved_preview_stride(resolved_preview_stride),
        .display_frame_start_event(display_frame_start_event),
        .display_prefetch_start_valid(display_prefetch_start_valid),
        .display_prefetch_start_ready(display_prefetch_start_ready),
        .display_prefetch_abort(display_prefetch_abort),
        .display_flush_request(display_flush_request),
        .display_flush_busy(display_flush_busy),
        .boardless_expected_input(boardless_expected_input),
        .boardless_region_request(boardless_region_request),.boardless_region_cancel(boardless_region_cancel),
        .boardless_region_response(boardless_region_response),.boardless_region_error_code(boardless_region_error_code),
        .boardless_region_error_address(boardless_region_error_address),
        .display_original_base(display_original_base),
        .display_original_stride(display_original_stride),
        .display_styled_base(display_styled_base),
        .display_styled_stride(display_styled_stride),
        .display_width(display_width),
        .display_height(display_height),
        .display_prefetch_busy(display_prefetch_busy),
        .display_prefetch_done(display_prefetch_done),
        .display_prefetch_new_done_event(display_prefetch_new_done_event),
        .display_prefetch_aborted(display_prefetch_aborted),
        .display_prefetch_error(display_prefetch_error),
        .display_prefetch_primed(display_prefetch_primed)
    );

    c1_r1_parameter_subsystem #(
        .ARENA_BYTES(16896),
        .PARAM_ADDR_W(PARAM_ADDR_W)
    ) u_parameters (
        .clk(core_clk), .rst(core_rst),
        .start_valid(parameter_start_valid),
        .start_ready(parameter_start_ready),
        .base_addr(parameter_base_addr),
        .abort_request(parameter_abort_request),
        .abort_pending(parameter_abort_pending),
        .busy(parameter_busy), .done(parameter_done),
        .error(parameter_error), .aborted(parameter_aborted),
        .error_code(parameter_error_code),
        .error_address(parameter_error_address),
        .active_valid(parameter_active_valid),
        .active_bank(parameter_active_bank),
        .generation(parameter_generation),
        .engine_rd_en(parameter_rd_en),
        .engine_rd_addr(parameter_rd_addr),
        .engine_rd_valid(parameter_rd_valid),
        .engine_rd_error(parameter_rd_error),
        .engine_rd_data(parameter_rd_data),
        .m_axi_araddr(axi_s_araddr[2]),
        .m_axi_arlen(axi_s_arlen[2]),
        .m_axi_arsize(axi_s_arsize[2]),
        .m_axi_arburst(axi_s_arburst[2]),
        .m_axi_arvalid(axi_s_arvalid[2]),
        .m_axi_arready(axi_s_arready[2]),
        .m_axi_rdata(axi_s_rdata[2]),
        .m_axi_rresp(axi_s_rresp[2]),
        .m_axi_rlast(axi_s_rlast[2]),
        .m_axi_rvalid(axi_s_rvalid[2]),
        .m_axi_rready(axi_s_rready[2])
    );

    c1_r1_capture_subsystem #(
        .CAMERA_READY_VALID_SOURCE(CAMERA_READY_VALID_SOURCE),
        .CHECK_RAW_RASTER(CHECK_RAW_RASTER),
        .RAW_IDLE_TIMEOUT_CYCLES(RAW_IDLE_TIMEOUT_CYCLES),
        .ENABLE_EXPLICIT_RECOVERY(ENABLE_EXPLICIT_CAPTURE_RECOVERY),
        .SENSOR_WIDTH(SENSOR_WIDTH),
        .SENSOR_HEIGHT(SENSOR_HEIGHT),
        .X_BITS(CAMERA_X_BITS), .Y_BITS(CAMERA_Y_BITS),
        .ENABLE_TABLE_RESPONSE_FIFO(ENABLE_TABLE_RESPONSE_FIFO)
    ) u_capture (
        .recovery_request(capture_recovery_request_mux),
        .recovery_source_quiescent(capture_source_quiescent),
        .recovery_fabric_drained(capture_recovery_safe),
        .recovery_ready(capture_recovery_ready),.recovery_busy(capture_recovery_busy),
        .recovery_done(capture_recovery_done),
        .camera_clk(camera_clk), .camera_rst(camera_rst),
        .camera_valid(camera_valid), .camera_ready(camera_ready),
        .camera_raw10(camera_raw10), .camera_x(camera_x),
        .camera_y(camera_y), .camera_sof(camera_sof),
        .camera_eol(camera_eol), .camera_eof(camera_eof),
        .camera_overflow(camera_overflow),
        .core_clk(core_clk), .core_rst(core_rst),
        .frame_waiting(capture_frame_waiting),
        .begin_frame(capture_begin_frame),
        .begin_ready(capture_begin_ready),
        .drop_frame(capture_drop_frame),
        .abort_frame(capture_abort_frame),
        .clear_error(capture_clear_error),
        .discard_idle(capture_discard_idle),
        .cleanup_busy(capture_cleanup_busy),
        .frame_ingress_done(capture_ingress_done),
        .frame_dropped(capture_frame_dropped),
        .frame_aborted(capture_frame_aborted),
        .capture_error(capture_error),
        .capture_error_code(capture_error_code),
        .cfg_commit(isp_cfg_valid), .cfg_ready(isp_cfg_ready),
        .cfg_bayer_pattern(isp_cfg_bayer_pattern),
        .cfg_roi_x_parity(isp_cfg_roi_x_parity),
        .cfg_roi_y_parity(isp_cfg_roi_y_parity),
        .cfg_black_r(isp_cfg_black_r),
        .cfg_black_gr(isp_cfg_black_gr),
        .cfg_black_gb(isp_cfg_black_gb),
        .cfg_black_b(isp_cfg_black_b),
        .cfg_awb_gain_r(isp_cfg_awb_gain_r),
        .cfg_awb_gain_g(isp_cfg_awb_gain_g),
        .cfg_awb_gain_b(isp_cfg_awb_gain_b),
        .cfg_ccm_rr(isp_cfg_ccm_rr), .cfg_ccm_rg(isp_cfg_ccm_rg),
        .cfg_ccm_rb(isp_cfg_ccm_rb), .cfg_ccm_gr(isp_cfg_ccm_gr),
        .cfg_ccm_gg(isp_cfg_ccm_gg), .cfg_ccm_gb(isp_cfg_ccm_gb),
        .cfg_ccm_br(isp_cfg_ccm_br), .cfg_ccm_bg(isp_cfg_ccm_bg),
        .cfg_ccm_bb(isp_cfg_ccm_bb),
        .cfg_ccm_offset_r(isp_cfg_ccm_offset_r),
        .cfg_ccm_offset_g(isp_cfg_ccm_offset_g),
        .cfg_ccm_offset_b(isp_cfg_ccm_offset_b),
        .gamma_cfg_we(isp_gamma_valid),
        .gamma_cfg_addr(isp_gamma_addr),
        .gamma_cfg_data(isp_gamma_data),
        .gamma_cfg_ready(isp_gamma_ready),
        .table_request_valid(capture_table_request_valid),
        .table_request_ready(capture_table_request_ready),
        .table_request_base(capture_table_request_base),
        .table_request_index(capture_table_request_index),
        .table_response_valid(capture_table_response_valid),
        .table_response_ready(capture_table_response_ready),
        .table_response_error(capture_table_response_error),
        .table_response_base(capture_table_response_base),
        .table_response_stride(capture_table_response_stride),
        .table_response_width(capture_table_response_width),
        .table_response_height(capture_table_response_height),
        .table_abort_request(capture_table_abort_request),
        .table_abort_pending(capture_table_abort_pending),
        .writer_start(capture_writer_start),
        .writer_cancel(capture_writer_cancel),
        .writer_base(capture_writer_base),
        .writer_stride(capture_writer_stride),
        .writer_width(capture_writer_width),
        .writer_height(capture_writer_height),
        .writer_busy(capture_writer_busy),
        .writer_done(capture_writer_done),
        .writer_error(capture_writer_error),
        .table_axi_araddr(axi_s_araddr[3]),
        .table_axi_arlen(axi_s_arlen[3]),
        .table_axi_arsize(axi_s_arsize[3]),
        .table_axi_arburst(axi_s_arburst[3]),
        .table_axi_arvalid(axi_s_arvalid[3]),
        .table_axi_arready(axi_s_arready[3]),
        .table_axi_rdata(axi_s_rdata[3]),
        .table_axi_rresp(axi_s_rresp[3]),
        .table_axi_rlast(axi_s_rlast[3]),
        .table_axi_rvalid(axi_s_rvalid[3]),
        .table_axi_rready(axi_s_rready[3]),
        .writer_axi_awaddr(axi_s_awaddr[1]),
        .writer_axi_awlen(axi_s_awlen[1]),
        .writer_axi_awsize(axi_s_awsize[1]),
        .writer_axi_awburst(axi_s_awburst[1]),
        .writer_axi_awvalid(axi_s_awvalid[1]),
        .writer_axi_awready(axi_s_awready[1]),
        .writer_axi_wdata(axi_s_wdata[1]),
        .writer_axi_wstrb(axi_s_wstrb[1]),
        .writer_axi_wlast(axi_s_wlast[1]),
        .writer_axi_wvalid(axi_s_wvalid[1]),
        .writer_axi_wready(axi_s_wready[1]),
        .writer_axi_bresp(axi_s_bresp[1]),
        .writer_axi_bvalid(axi_s_bvalid[1]),
        .writer_axi_bready(axi_s_bready[1])
    );

    // Constant allocation checks deliberately remain synthesizable: invalid
    // parameters feed stride=0 to preflight, so a bad build cannot issue DMA.
    localparam logic [63:0] PREVIEW_SLOT_BYTES=64'(FRAME_WIDTH)*64'(FRAME_HEIGHT)*64'd4;
    localparam logic [63:0] PREVIEW_END0={32'd0,PREVIEW_BUFFER0_BASE}+PREVIEW_SLOT_BYTES;
    localparam logic [63:0] PREVIEW_END1={32'd0,PREVIEW_BUFFER1_BASE}+PREVIEW_SLOT_BYTES;
    localparam bit PREVIEW_ALLOCATION_VALID=
        FRAME_WIDTH>0 && FRAME_HEIGHT>0 && FRAME_WIDTH<=65535 && FRAME_HEIGHT<=65535 &&
        (FRAME_WIDTH%4)==0 && PREVIEW_BUFFER0_BASE[3:0]==0 && PREVIEW_BUFFER1_BASE[3:0]==0 &&
        PREVIEW_REGION_BEGIN<PREVIEW_REGION_END && PREVIEW_REGION_END<=33'h1_0000_0000 &&
        {1'b0,PREVIEW_BUFFER0_BASE}>=PREVIEW_REGION_BEGIN &&
        {1'b0,PREVIEW_BUFFER1_BASE}>=PREVIEW_REGION_BEGIN &&
        PREVIEW_END0<={31'd0,PREVIEW_REGION_END} && PREVIEW_END1<={31'd0,PREVIEW_REGION_END} &&
        (PREVIEW_END0<={32'd0,PREVIEW_BUFFER1_BASE} || PREVIEW_END1<={32'd0,PREVIEW_BUFFER0_BASE});
    wire [31:0] preview_job_base=boardless_output_index[0] ? PREVIEW_BUFFER1_BASE : PREVIEW_BUFFER0_BASE;
    wire [31:0] preview_job_stride=(PREVIEW_ALLOCATION_VALID && boardless_output_index<2 &&
        boardless_frame_width<=FRAME_WIDTH && boardless_frame_height<=FRAME_HEIGHT) ? FRAME_WIDTH*4 : 32'd0;
    wire [31:0] preview_awaddr;
    wire [7:0] preview_awlen;
    wire [2:0] preview_awsize;
    wire [1:0] preview_awburst,preview_bresp;
    wire [127:0] preview_wdata;
    wire [15:0] preview_wstrb;
    wire preview_awvalid,preview_awready,preview_wlast,preview_wvalid,preview_wready,preview_bvalid,preview_bready;
    generate if(PREVIEW_CAPTURE_ACTIVE) begin: g_preview_fabric
        assign axi_s_awaddr[7]=preview_awaddr;assign axi_s_awlen[7]=preview_awlen;
        assign axi_s_awsize[7]=preview_awsize;assign axi_s_awburst[7]=preview_awburst;
        assign axi_s_awvalid[7]=preview_awvalid;assign preview_awready=axi_s_awready[7];
        assign axi_s_wdata[7]=preview_wdata;assign axi_s_wstrb[7]=preview_wstrb;
        assign axi_s_wlast[7]=preview_wlast;assign axi_s_wvalid[7]=preview_wvalid;
        assign preview_wready=axi_s_wready[7];assign preview_bresp=axi_s_bresp[7];
        assign preview_bvalid=axi_s_bvalid[7];assign axi_s_bready[7]=preview_bready;
        assign axi_s_araddr[7]=0;assign axi_s_arlen[7]=0;assign axi_s_arsize[7]=0;
        assign axi_s_arburst[7]=0;assign axi_s_arvalid[7]=0;assign axi_s_rready[7]=0;
    end else begin: g_no_preview_fabric
        assign preview_awready=0;assign preview_wready=0;
        assign preview_bresp=0;assign preview_bvalid=0;
    end endgenerate

    c1_r1_boardless_frame_system #(
        .CHECK_WRITE_REGIONS(1'b1),
        .CHECK_INPUT_SNAPSHOT(1'b1),
        .ENABLE_PREVIEW(PREVIEW_CAPTURE_ACTIVE),
        .PREVIEW_REGION_BEGIN(PREVIEW_REGION_BEGIN),.PREVIEW_REGION_END(PREVIEW_REGION_END),
        .SEPARATE_INPUT_GEOMETRY(1),
        .MAX_WIDTH((FRAME_WIDTH > SENSOR_WIDTH-2) ? FRAME_WIDTH : SENSOR_WIDTH-2),
        .MAX_STAGES(22),
        .COUNT_BITS(16),
        .GENERATION_BITS(8),
        .FAST_WIDE(1'b0),
        .PIPELINED_START_CONFIG(PIPELINED_START_CONFIG),
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET)
    ) u_boardless (
        .job_expected_input(boardless_expected_input),
        .region_request(boardless_region_request),.region_cancel(boardless_region_cancel),
        .region_response(boardless_region_response),.region_error_code(boardless_region_error_code),
        .region_error_address(boardless_region_error_address),
        .resolved_preview_base(resolved_preview_base),.resolved_preview_stride(resolved_preview_stride),
        .job_preview_base(preview_job_base),.job_preview_stride(preview_job_stride),
        .preview_axi_awaddr(preview_awaddr),.preview_axi_awlen(preview_awlen),
        .preview_axi_awsize(preview_awsize),.preview_axi_awburst(preview_awburst),
        .preview_axi_awvalid(preview_awvalid),.preview_axi_awready(preview_awready),
        .preview_axi_wdata(preview_wdata),.preview_axi_wstrb(preview_wstrb),
        .preview_axi_wlast(preview_wlast),.preview_axi_wvalid(preview_wvalid),.preview_axi_wready(preview_wready),
        .preview_axi_bresp(preview_bresp),.preview_axi_bvalid(preview_bvalid),.preview_axi_bready(preview_bready),
        .job_input_width_pixels(boardless_source_width),
        .job_input_height_lines(boardless_source_height),
        .clk(core_clk), .rst(core_rst),
        .job_start_valid(boardless_start_valid),
        .job_start_ready(boardless_start_ready),
        .job_abort(boardless_abort),
        .job_input_table_base(boardless_input_table_base),
        .job_output_table_base(boardless_output_table_base),
        .job_input_buffer_index(boardless_input_index),
        .job_output_buffer_index(boardless_output_index),
        .job_width_pixels(boardless_frame_width),
        .job_height_lines(boardless_frame_height),
        .job_descriptor_base(boardless_descriptor_base),
        .job_descriptor_count(boardless_descriptor_count),
        .job_cycle_budget(boardless_cycle_budget),
        .job_x_step_q16(boardless_resize_x_step),
        .job_y_step_q16(boardless_resize_y_step),
        .job_x_phase0_q16(boardless_resize_x_phase0),
        .job_y_phase0_q16(boardless_resize_y_phase0),
        .busy(boardless_busy), .job_done(boardless_done),
        .job_error(boardless_error), .job_aborted(boardless_aborted),
        .error_code(boardless_error_code),
        .error_address(boardless_error_address),
        .resolved_input_base(resolved_input_base),
        .resolved_input_stride(resolved_input_stride),
        .resolved_input_width(resolved_input_width),
        .resolved_input_height(resolved_input_height),
        .resolved_output_base(resolved_output_base),
        .resolved_output_stride(resolved_output_stride),
        .resolved_output_width(resolved_output_width),
        .resolved_output_height(resolved_output_height),
        .active_config_bank(boardless_active_config_bank),
        .active_config_count(boardless_active_config_count),
        .active_config_generation(boardless_active_config_generation),
        .stage_dispatch_complete(boardless_dispatch_complete),
        .stage_config_valid(stage_config_valid),
        .stage_config_ready(stage_config_ready),
        .stage_config_index(stage_config_index),
        .stage_config_descriptor(stage_config_descriptor),
        .stage_config_generation(stage_config_generation),
        .cnn_start_valid(cnn_start_valid),
        .cnn_start_ready(cnn_start_ready),
        .cnn_abort(cnn_abort),
        .cnn_error(cnn_error),
        .cnn_error_code(cnn_error_code),
        .cnn_in_valid(board_cnn_in_valid),
        .cnn_in_ready(board_cnn_in_ready),
        .cnn_in_data_s8(board_cnn_in_data),
        .cnn_in_x(board_cnn_in_x), .cnn_in_y(board_cnn_in_y),
        .cnn_in_sof(board_cnn_in_sof),
        .cnn_in_eol(board_cnn_in_eol),
        .cnn_in_eof(board_cnn_in_eof),
        .cnn_out_valid(board_cnn_out_valid),
        .cnn_out_ready(board_cnn_out_ready),
        .cnn_out_data_s8(board_cnn_out_data),
        .cnn_out_x(board_cnn_out_x), .cnn_out_y(board_cnn_out_y),
        .cnn_out_sof(board_cnn_out_sof),
        .cnn_out_eol(board_cnn_out_eol),
        .cnn_out_eof(board_cnn_out_eof),
        .m_axi_awaddr(axi_s_awaddr[0]),
        .m_axi_awlen(axi_s_awlen[0]),
        .m_axi_awsize(axi_s_awsize[0]),
        .m_axi_awburst(axi_s_awburst[0]),
        .m_axi_awvalid(axi_s_awvalid[0]),
        .m_axi_awready(axi_s_awready[0]),
        .m_axi_wdata(axi_s_wdata[0]),
        .m_axi_wstrb(axi_s_wstrb[0]),
        .m_axi_wlast(axi_s_wlast[0]),
        .m_axi_wvalid(axi_s_wvalid[0]),
        .m_axi_wready(axi_s_wready[0]),
        .m_axi_bresp(axi_s_bresp[0]),
        .m_axi_bvalid(axi_s_bvalid[0]),
        .m_axi_bready(axi_s_bready[0]),
        .m_axi_araddr(axi_s_araddr[0]),
        .m_axi_arlen(axi_s_arlen[0]),
        .m_axi_arsize(axi_s_arsize[0]),
        .m_axi_arburst(axi_s_arburst[0]),
        .m_axi_arvalid(axi_s_arvalid[0]),
        .m_axi_arready(axi_s_arready[0]),
        .m_axi_rdata(axi_s_rdata[0]),
        .m_axi_rresp(axi_s_rresp[0]),
        .m_axi_rlast(axi_s_rlast[0]),
        .m_axi_rvalid(axi_s_rvalid[0]),
        .m_axi_rready(axi_s_rready[0])
    );

    c1_r1_microstyle_system_bridge #(
        .REQUIRED_STAGES(22),
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
        .PIPELINE_ALL_DOT_GROUPS(PIPELINE_ALL_DOT_GROUPS),
        .STREAM_DW_FRAME(STREAM_DW_FRAME),
        .PACK_RGB_CONV_REDUCTION(PACK_RGB_CONV_REDUCTION),
        .ELIDE_VIRTUAL_UPSAMPLE(ELIDE_VIRTUAL_UPSAMPLE),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL_OUTPUT),
        .PIPELINED_DESCRIPTOR_REPLAY(PIPELINED_DESCRIPTOR_REPLAY),
        .PREVALIDATE_DESCRIPTOR_REPLAY(PREVALIDATE_DESCRIPTOR_REPLAY),
        .PIPELINED_DECODER_VALIDATION(PIPELINED_DECODER_VALIDATION),
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE),
        .ENABLE_UNIFIED_OUTPUT_FIFO(ENABLE_UNIFIED_OUTPUT_FIFO),
        .ENABLE_UNIFIED_OUTPUT_SKID(ENABLE_UNIFIED_OUTPUT_SKID)
    ) u_microstyle (
        .clk(core_clk), .rst(core_rst), .abort(cnn_abort),
        .start_valid(cnn_start_valid), .start_ready(cnn_start_ready),
        .stage_count(boardless_active_config_count),
        .config_generation(boardless_active_config_generation),
        .parameter_active_valid(parameter_active_valid),
        .parameter_generation(parameter_generation),
        .busy(bridge_busy), .done(bridge_done),
        .aborted(bridge_aborted), .error(cnn_error),
        .error_code(cnn_error_code),
        .stage_config_valid(stage_config_valid),
        .stage_config_ready(stage_config_ready),
        .stage_config_index(stage_config_index),
        .stage_config_descriptor(stage_config_descriptor),
        .stage_config_generation(stage_config_generation),
        .param_rd_en(parameter_rd_en),
        .param_rd_addr(parameter_rd_addr),
        .param_rd_valid(parameter_rd_valid),
        .param_rd_error(parameter_rd_error),
        .param_rd_data(parameter_rd_data),
        .board_in_valid(board_cnn_in_valid),
        .board_in_ready(board_cnn_in_ready),
        .board_in_data_s8(board_cnn_in_data),
        .board_in_x(board_cnn_in_x), .board_in_y(board_cnn_in_y),
        .board_in_sof(board_cnn_in_sof),
        .board_in_eol(board_cnn_in_eol),
        .board_in_eof(board_cnn_in_eof),
        .board_out_valid(board_cnn_out_valid),
        .board_out_ready(board_cnn_out_ready),
        .board_out_data_s8(board_cnn_out_data),
        .board_out_x(board_cnn_out_x), .board_out_y(board_cnn_out_y),
        .board_out_sof(board_cnn_out_sof),
        .board_out_eol(board_cnn_out_eol),
        .board_out_eof(board_cnn_out_eof),
        .adapter_start_valid(adapter_start_valid),
        .adapter_start_ready(adapter_start_ready),
        .adapter_abort(adapter_abort),
        .adapter_stage_config_valid(adapter_stage_config_valid),
        .adapter_stage_config_ready(adapter_stage_config_ready),
        .adapter_stage_config_index(adapter_stage_config_index),
        .adapter_stage_config_descriptor(
            adapter_stage_config_descriptor),
        .adapter_stage_config_generation(
            adapter_stage_config_generation),
        .adapter_error(adapter_error),
        .adapter_error_code(adapter_error_code),
        .adapter_source_valid(adapter_source_valid),
        .adapter_source_ready(adapter_source_ready),
        .adapter_source_data_s8(adapter_source_data_s8),
        .adapter_source_x(adapter_source_x),
        .adapter_source_y(adapter_source_y),
        .adapter_source_sof(adapter_source_sof),
        .adapter_source_eol(adapter_source_eol),
        .adapter_source_eof(adapter_source_eof),
        .adapter_engine_valid(adapter_engine_valid),
        .adapter_view_valid,.adapter_view_ready,.adapter_view_stage,.adapter_view_generation,
        .adapter_engine_ready(adapter_engine_ready),
        .adapter_engine_window_s8(adapter_engine_window_s8),
        .adapter_engine_residual_s8(adapter_engine_residual_s8),
        .adapter_engine_group_index(adapter_engine_group_index),
        .adapter_engine_group_last(adapter_engine_group_last),
        .adapter_engine_x(adapter_engine_x),
        .adapter_engine_y(adapter_engine_y),
        .adapter_engine_sof(adapter_engine_sof),
        .adapter_engine_eol(adapter_engine_eol),
        .adapter_engine_eof(adapter_engine_eof),
        .adapter_result_valid(adapter_result_valid),
        .adapter_result_ready(adapter_result_ready),
        .adapter_result_data_s8(adapter_result_data_s8),
        .adapter_result_group_index(adapter_result_group_index),
        .adapter_result_group_last(adapter_result_group_last),
        .adapter_result_x(adapter_result_x),
        .adapter_result_y(adapter_result_y),
        .adapter_result_sof(adapter_result_sof),
        .adapter_result_eol(adapter_result_eol),
        .adapter_result_eof(adapter_result_eof),
        .adapter_final_valid(adapter_final_valid),
        .adapter_final_ready(adapter_final_ready),
        .adapter_final_data_s8(adapter_final_data_s8),
        .adapter_final_x(adapter_final_x),
        .adapter_final_y(adapter_final_y),
        .adapter_final_sof(adapter_final_sof),
        .adapter_final_eol(adapter_final_eol),
        .adapter_final_eof(adapter_final_eof),
        .engine_stage_index(engine_stage_index),
        .engine_stage_opcode(engine_stage_opcode),
        .engine_stage_active(engine_stage_active),
        .engine_adapter_required(engine_adapter_required),
        .engine_stage_done(engine_stage_done),
        .engine_overflow_seen(engine_overflow_seen),
        .config_capture_complete(bridge_config_complete)
    );

    // Correctness-first 22-stage tensor scheduler.  It owns all inter-stage
    // feature storage, SAME-replicate windows, C8 group sequencing,
    // upsample and residual bank routing.  The base is an APB-programmed,
    // START-snapshotted 24 MiB arena (three 8 MiB banks).
    c1_r1_microstyle_tensor_adapter #( 
        .REQUIRED_STAGES(22),
        .TENSOR_BANK_BYTES(8 * 1024 * 1024),
        .ENABLE_WINDOW_CACHE_SIDEBAND(ENABLE_TENSOR_WINDOW_CACHE || ENABLE_TENSOR_COLUMN_READS),
        .ENABLE_COLUMN_READS(ENABLE_TENSOR_COLUMN_READS),
        .VIRTUAL_UPSAMPLE_TENSORS(VIRTUAL_UPSAMPLE_TENSORS),
        .OVERLAP_COLUMN_WRITEBACK(OVERLAP_COLUMN_WRITEBACK),
        .POINTWISE_COLUMN_READS(POINTWISE_COLUMN_READS),
        .PREFETCH_NEXT_PIXEL_COLUMN(PREFETCH_NEXT_PIXEL_COLUMN),
        .PREFETCH_ALL_PIXEL_GROUPS(PREFETCH_ALL_PIXEL_GROUPS),
        .PIPELINE_DOT_PIXELS(PIPELINE_DOT_PIXELS),
        .PIXEL_WRITE_BATCH_WORDS(PIXEL_WRITE_BATCH_WORDS),
        .PIPELINE_DW_PIXELS(PIPELINE_DW_PIXELS),
        .PIPELINE_ALL_DOT_GROUPS(PIPELINE_ALL_DOT_GROUPS),
        .PIPELINED_SOURCE_WRITES(PIPELINED_SOURCE_WRITES),
        .ELIDE_VIRTUAL_UPSAMPLE(ELIDE_VIRTUAL_UPSAMPLE),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL_OUTPUT),
        .STRICT_DESCRIPTOR_VALIDATION(STRICT_DESCRIPTOR_VALIDATION),
        .PIPELINED_DESCRIPTOR_VALIDATION(PIPELINED_DESCRIPTOR_VALIDATION),
        .NARROW_DESCRIPTOR_SIZE_CHECK(NARROW_DESCRIPTOR_SIZE_CHECK),
        .FAST_TENSOR_ADDRESS_ARITH(FAST_TENSOR_ADDRESS_ARITH),
        .PIPELINED_TENSOR_ADDRESS(PIPELINED_TENSOR_ADDRESS),
        .PIPELINED_TENSOR_PIXEL_INDEX(PIPELINED_TENSOR_PIXEL_INDEX),
        .PIPELINED_DESCRIPTOR_SIZE_ARITH(PIPELINED_DESCRIPTOR_SIZE_ARITH),
        .FIXED_DESCRIPTOR_SIZE_LIMITS(FIXED_DESCRIPTOR_SIZE_LIMITS),
        .PIPELINED_DESCRIPTOR_PIXEL_COUNT(PIPELINED_DESCRIPTOR_PIXEL_COUNT),
        .KEEP_DESCRIPTOR_SIZE_OPERANDS(KEEP_DESCRIPTOR_SIZE_OPERANDS),
        .ITERATIVE_DESCRIPTOR_PIXEL_COUNT(ITERATIVE_DESCRIPTOR_PIXEL_COUNT),
        .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS),
        .PIPELINED_RESULT_WRITES(PIPELINED_RESULT_WRITES),
        .PREFETCH_NEXT_TAP_ADDRESS(PREFETCH_NEXT_TAP_ADDRESS),
        .REUSE_HORIZONTAL_WINDOW(REUSE_HORIZONTAL_WINDOW)
    ) u_tensor_adapter (
        .view_commit_valid(adapter_view_valid),.view_commit_ready(adapter_view_ready),
        .view_commit_stage(adapter_view_stage),.view_commit_generation(adapter_view_generation),
        .column_req_valid(tensor_column_valid),.column_req_ready(tensor_column_ready),
        .column_req_x(tensor_column_x),.column_req_center_y(tensor_column_y),
        .column_req_group(tensor_column_group),.column_rsp_valid(tensor_column_rsp_valid),
        .column_rsp_ready(tensor_column_rsp_ready),.column_rsp_data_s8(tensor_column_data),
        .column_rsp_error(tensor_column_error),
        .column_allow_pending_writes(tensor_column_allow_pending_writes),
        .clk(core_clk), .rst(core_rst),
        .adapter_start_valid(adapter_start_valid),
        .adapter_start_ready(adapter_start_ready),
        .adapter_abort(adapter_abort),
        .adapter_stage_config_valid(adapter_stage_config_valid),
        .adapter_stage_config_ready(adapter_stage_config_ready),
        .adapter_stage_config_index(adapter_stage_config_index),
        .adapter_stage_config_descriptor(
            adapter_stage_config_descriptor),
        .adapter_stage_config_generation(
            adapter_stage_config_generation),
        .adapter_error(adapter_error),
        .adapter_error_code(adapter_error_code),
        .adapter_source_valid(adapter_source_valid),
        .adapter_source_ready(adapter_source_ready),
        .adapter_source_data_s8(adapter_source_data_s8),
        .adapter_source_x(adapter_source_x),
        .adapter_source_y(adapter_source_y),
        .adapter_source_sof(adapter_source_sof),
        .adapter_source_eol(adapter_source_eol),
        .adapter_source_eof(adapter_source_eof),
        .adapter_engine_valid(adapter_engine_valid),
        .adapter_engine_ready(adapter_engine_ready),
        .adapter_engine_window_s8(adapter_engine_window_s8),
        .adapter_engine_residual_s8(adapter_engine_residual_s8),
        .adapter_engine_group_index(adapter_engine_group_index),
        .adapter_engine_group_last(adapter_engine_group_last),
        .adapter_engine_x(adapter_engine_x),
        .adapter_engine_y(adapter_engine_y),
        .adapter_engine_sof(adapter_engine_sof),
        .adapter_engine_eol(adapter_engine_eol),
        .adapter_engine_eof(adapter_engine_eof),
        .adapter_result_valid(adapter_result_valid),
        .adapter_result_ready(adapter_result_ready),
        .adapter_result_data_s8(adapter_result_data_s8),
        .adapter_result_group_index(adapter_result_group_index),
        .adapter_result_group_last(adapter_result_group_last),
        .adapter_result_x(adapter_result_x),
        .adapter_result_y(adapter_result_y),
        .adapter_result_sof(adapter_result_sof),
        .adapter_result_eol(adapter_result_eol),
        .adapter_result_eof(adapter_result_eof),
        .adapter_final_valid(adapter_final_valid),
        .adapter_final_ready(adapter_final_ready),
        .adapter_final_data_s8(adapter_final_data_s8),
        .adapter_final_x(adapter_final_x),
        .adapter_final_y(adapter_final_y),
        .adapter_final_sof(adapter_final_sof),
        .adapter_final_eol(adapter_final_eol),
        .adapter_final_eof(adapter_final_eof),
        .tensor_base_addr(boardless_tensor_base),
        .cache_stage_start_valid(tensor_cache_stage_start_valid),
        .cache_stage_start_ready(tensor_cache_stage_start_ready),
        .cache_stage_enable(tensor_cache_stage_enable),
        .cache_stage_base_addr(tensor_cache_stage_base_addr),
        .cache_stage_width(tensor_cache_stage_width),
        .cache_stage_height(tensor_cache_stage_height),
        .cache_stage_groups(tensor_cache_stage_groups),
        .mem_req_valid(tensor_mem_req_valid),
        .mem_req_end(tensor_mem_req_end),
        .mem_req_ready(tensor_mem_req_ready),
        .mem_req_write(tensor_mem_req_write),
        .mem_req_addr(tensor_mem_req_addr),
        .mem_req_wdata(tensor_mem_req_wdata),
        .mem_req_wstrb(tensor_mem_req_wstrb),
        .mem_req_cacheable(tensor_mem_req_cacheable),
        .mem_req_cache_x(tensor_mem_req_cache_x),
        .mem_req_cache_y(tensor_mem_req_cache_y),
        .mem_req_cache_group(tensor_mem_req_cache_group),
        .mem_rsp_valid(tensor_mem_rsp_valid),
        .mem_rsp_ready(tensor_mem_rsp_ready),
        .mem_rsp_error(tensor_mem_rsp_error),
        .mem_rsp_rdata(tensor_mem_rsp_rdata),
        .adapter_busy(tensor_adapter_busy),
        .adapter_done(tensor_adapter_done),
        .adapter_aborted(tensor_adapter_aborted),
        .adapter_config_complete(tensor_adapter_config_complete),
        .active_stage_index(),
        .active_stage_opcode(), .active_input_bank(),
        .active_output_bank(), .active_residual_bank()
    );

    // Explicit tensor/cache client boundary.  Its AXI master is connected to
    // slot 6 of the shared N-way fabric below; all cache diagnostics remain
    // internal to this portable top and are folded into system_busy.  The
    // burst branch is an opt-in refill-side experiment; the legacy branch is
    // structurally identical to the historical default.
    generate
        if (!ENABLE_TENSOR_COLUMN_READS) begin : g_no_tensor_columns
            assign tensor_column_ready=1'b0;
            assign tensor_column_rsp_valid=1'b0;
            assign tensor_column_error=1'b0;
            assign tensor_column_data='0;
        end
        if (ENABLE_TENSOR_COLUMN_READS) begin : g_tensor_column_reads
            logic [7:0] scalar_pending_q;
            logic scalar_ready,scalar_valid,column_ready_i,column_busy,column_idle;
            logic config_ready_i,column_abort_done,abort_seen_q,abort_pending_q,abort_ack_q;
            logic scalar_read_owned_q;
            wire column_admit=(scalar_pending_q==0) ||
                (OVERLAP_COLUMN_WRITEBACK && tensor_column_allow_pending_writes &&
                 !scalar_read_owned_q && tensor_cache_stage_active);
            // A prefetch may be presented while the old pixel has a held
            // result write. Keep scalar READS fenced, but permit the distinct
            // output-bank write to use its existing independent AXI client.
            wire prefetch_write_admit=(PREFETCH_NEXT_PIXEL_COLUMN || PIPELINE_DOT_PIXELS || PIPELINE_DW_PIXELS) &&
                tensor_column_allow_pending_writes && tensor_mem_req_write &&
                !scalar_read_owned_q && tensor_cache_stage_active;
            wire scalar_admit=(!column_busy && !tensor_column_valid) || prefetch_write_admit;
            wire scalar_fire=scalar_valid && scalar_ready;
            wire scalar_retire=tensor_mem_rsp_valid && tensor_mem_rsp_ready;
            assign scalar_valid=tensor_mem_req_valid && scalar_admit;
            assign tensor_mem_req_ready=scalar_ready && scalar_admit;
            assign tensor_column_ready=column_ready_i && column_admit;
            assign tensor_cache_stage_start_ready=config_ready_i && scalar_pending_q==0;
            assign tensor_cache_busy=column_busy || scalar_pending_q!=0 || abort_pending_q;
            assign tensor_cache_quiescent=!tensor_cache_busy;
            assign tensor_cache_stage_fallback=1'b0;
            assign tensor_cache_stage_reason=4'b0;
            always_ff @(posedge core_clk) begin
                if(core_rst) begin
                    scalar_pending_q<=0;abort_seen_q<=0;abort_pending_q<=0;
                    scalar_read_owned_q<=0;
                    abort_ack_q<=0;tensor_cache_abort_done<=0;
                end else begin
                    if(scalar_fire && !tensor_mem_req_write) scalar_read_owned_q<=1;
                    if(scalar_retire && scalar_read_owned_q) scalar_read_owned_q<=0;
                    case({scalar_fire,scalar_retire})
                        2'b10:scalar_pending_q<=scalar_pending_q+1'b1;
                        2'b01:scalar_pending_q<=scalar_pending_q-1'b1;
                        default:;
                    endcase
                    abort_seen_q<=adapter_abort;tensor_cache_abort_done<=0;
                    if(adapter_abort && !abort_seen_q) abort_pending_q<=1;
                    if(column_abort_done) abort_ack_q<=1;
                    if(abort_pending_q && (abort_ack_q || column_abort_done) &&
                       scalar_pending_q==0 && !tensor_mem_req_valid && column_idle) begin
                        tensor_cache_abort_done<=1;abort_pending_q<=0;abort_ack_q<=0;
                    end
                end
            end
            c1_tensor_mem_axi128_packing_bridge #(
                .ENABLE_PACKED_WRITES(ENABLE_TENSOR_PACKED_WRITES),.USE_WRITE_END(USE_TENSOR_WRITE_END),
                .WRITE_OUTSTANDING(TENSOR_WRITE_OUTSTANDING),
                .WRITE_BUILD_TIMEOUT(TENSOR_WRITE_BUILD_TIMEOUT),
                .ENABLE_READ_BEAT_CACHE(TENSOR_SCALAR_READ_BEAT_CACHE),
                .READ_BEAT_CACHE_ENTRIES(TENSOR_SCALAR_READ_CACHE_ENTRIES),
                .PRECISE_WRITE_INVALIDATION(TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION)
            ) u_scalar (
                .clk(core_clk),.rst(core_rst),
                // The tensor adapter owns the input/output regions for each
                // stage. Fence every new stage and cancellation, not just DW
                // stages; the scalar path also reads 1x1/skip/resize tensors.
                // Local writes use the selected conservative/line-tag policy.
                // Stage and abort invalidation always remain unconditional.
                .read_cache_invalidate(tensor_cache_stage_start_valid || adapter_abort),
                .mem_req_valid(scalar_valid),.mem_req_ready(scalar_ready),
                .mem_req_write(tensor_mem_req_write),.mem_req_addr(tensor_mem_req_addr),
                .mem_req_wdata(tensor_mem_req_wdata),.mem_req_wstrb(tensor_mem_req_wstrb),
                .mem_req_end(tensor_mem_req_end),.mem_rsp_valid(tensor_mem_rsp_valid),
                .mem_rsp_ready(tensor_mem_rsp_ready),.mem_rsp_error(tensor_mem_rsp_error),
                .mem_rsp_rdata(tensor_mem_rsp_rdata),
                .m_axi_awaddr(axi_s_awaddr[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awlen(axi_s_awlen[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awsize(axi_s_awsize[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awburst(axi_s_awburst[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awvalid(axi_s_awvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awready(axi_s_awready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wdata(axi_s_wdata[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wstrb(axi_s_wstrb[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wlast(axi_s_wlast[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wvalid(axi_s_wvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wready(axi_s_wready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bresp(axi_s_bresp[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bvalid(axi_s_bvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bready(axi_s_bready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_araddr(axi_s_araddr[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arlen(axi_s_arlen[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arsize(axi_s_arsize[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arburst(axi_s_arburst[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arvalid(axi_s_arvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arready(axi_s_arready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rdata(axi_s_rdata[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rresp(axi_s_rresp[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rlast(axi_s_rlast[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rvalid(axi_s_rvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rready(axi_s_rready[AXI_CLIENT_TENSOR_CACHE])
            );
            c1_column_cache_owned_exact_burst_shell #(
                .COLUMN_READ_ON_LOOKUP(TENSOR_COLUMN_READ_ON_LOOKUP),
                .COLUMN_RESPONSE_BYPASS(TENSOR_COLUMN_RESPONSE_BYPASS),
                .COLUMN_REUSE_ROW_MAP(TENSOR_COLUMN_REUSE_ROW_MAP),
                .CANCEL_IS_PROTOCOL_ERROR(TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR!=0),
                .RSP_FIFO_BEAT_MODE(TENSOR_BURST_RSP_FIFO_BEAT_MODE!=0),
                .RSP_FIFO_DEPTH(TENSOR_BURST_RSP_FIFO_DEPTH),
                .REQ_FIFO_DEPTH(TENSOR_BURST_REQ_FIFO_DEPTH),
                .SCHED_MAX_OUTSTANDING(TENSOR_BURST_SCHED_MAX_OUTSTANDING),
                .ALLOW_SCHED_REQ_HANDOFF(TENSOR_BURST_SCHED_REQ_HANDOFF)
            ) u_column (
                .clk(core_clk),.rst(core_rst),
                .stage_base_valid(1'b1),.stage_base_addr(tensor_cache_stage_base_addr),
                .group_start_valid(tensor_cache_stage_start_valid && scalar_pending_q==0),
                .group_start_ready(config_ready_i),.frame_width(tensor_cache_stage_width),
                .frame_height(tensor_cache_stage_height),.frame_groups(tensor_cache_stage_groups),
                .group_start_done(tensor_cache_stage_start_done),.config_valid(tensor_cache_stage_active),
                .abort_req(adapter_abort),.abort_done(column_abort_done),.flush_req(1'b0),
                .tap_valid(tensor_column_valid && column_admit),.tap_ready(column_ready_i),
                .tap_x(tensor_column_x),.tap_y(tensor_column_y),.tap_group(tensor_column_group),
                .tap_rsp_valid(tensor_column_rsp_valid),.tap_rsp_ready(tensor_column_rsp_ready),
                .tap_rsp_data_s8(tensor_column_data),.tap_rsp_error(tensor_column_error),
                .cache_error(tensor_cache_error),.cache_error_code(tensor_cache_error_code),
                .busy(column_busy),.quiescent(column_idle),
                .m_axi_araddr(axi_s_araddr[AXI_CLIENT_COLUMN]),
                .m_axi_arlen(axi_s_arlen[AXI_CLIENT_COLUMN]),
                .m_axi_arsize(axi_s_arsize[AXI_CLIENT_COLUMN]),
                .m_axi_arburst(axi_s_arburst[AXI_CLIENT_COLUMN]),
                .m_axi_arvalid(axi_s_arvalid[AXI_CLIENT_COLUMN]),
                .m_axi_arready(axi_s_arready[AXI_CLIENT_COLUMN]),
                .m_axi_rdata(axi_s_rdata[AXI_CLIENT_COLUMN]),
                .m_axi_rresp(axi_s_rresp[AXI_CLIENT_COLUMN]),
                .m_axi_rlast(axi_s_rlast[AXI_CLIENT_COLUMN]),
                .m_axi_rvalid(axi_s_rvalid[AXI_CLIENT_COLUMN]),
                .m_axi_rready(axi_s_rready[AXI_CLIENT_COLUMN])
            );
            // This extra client is read-only; preserve the existing tensor
            // write slot and preview slot numbering.
            assign axi_s_awaddr[AXI_CLIENT_COLUMN]='0;
            assign axi_s_awlen[AXI_CLIENT_COLUMN]='0;
            assign axi_s_awsize[AXI_CLIENT_COLUMN]='0;
            assign axi_s_awburst[AXI_CLIENT_COLUMN]='0;
            assign axi_s_awvalid[AXI_CLIENT_COLUMN]='0;
            assign axi_s_wdata[AXI_CLIENT_COLUMN]='0;
            assign axi_s_wstrb[AXI_CLIENT_COLUMN]='0;
            assign axi_s_wlast[AXI_CLIENT_COLUMN]='0;
            assign axi_s_wvalid[AXI_CLIENT_COLUMN]='0;
            assign axi_s_bready[AXI_CLIENT_COLUMN]='0;
`ifndef SYNTHESIS
            always_ff @(posedge core_clk) if(!core_rst) begin
                if(scalar_retire && scalar_pending_q==0)
                    $fatal(1,"column SoC scalar response without ownership");
                if(scalar_fire && (column_busy || tensor_column_valid) && !prefetch_write_admit)
                    $fatal(1,"column SoC admitted an unowned scalar read/write during prefetch");
                if(scalar_fire && scalar_pending_q==255 && !scalar_retire)
                    $fatal(1,"column SoC scalar credit overflow");
                if(tensor_column_valid && tensor_column_ready && scalar_pending_q!=0 &&
                   (!OVERLAP_COLUMN_WRITEBACK || !tensor_column_allow_pending_writes || scalar_read_owned_q))
                    $fatal(1,"column SoC bypassed pending scalar writes");
            end
`endif
        end else if (ENABLE_TENSOR_BURST_REFILL != 0) begin : g_tensor_burst_refill
            c1_tensor_window_cache_burst_axi_client #(
                .BURST_CANCEL_IS_PROTOCOL_ERROR(
                    TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR != 0),
                .BURST_RSP_FIFO_BEAT_MODE(
                    TENSOR_BURST_RSP_FIFO_BEAT_MODE != 0),
                .BURST_RSP_FIFO_DEPTH(TENSOR_BURST_RSP_FIFO_DEPTH),
                .BURST_REQ_FIFO_DEPTH(TENSOR_BURST_REQ_FIFO_DEPTH),
                .BURST_SCHED_MAX_OUTSTANDING(TENSOR_BURST_SCHED_MAX_OUTSTANDING),
                .BURST_ALLOW_SCHED_REQ_HANDOFF(TENSOR_BURST_SCHED_REQ_HANDOFF),
                .BURST_PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS),
                .ENABLE_PACKED_WRITES(ENABLE_TENSOR_PACKED_WRITES),
                .USE_WRITE_END(USE_TENSOR_WRITE_END)
            ) u_tensor_cache_axi_client (
                .clk(core_clk),
                .rst(core_rst),
                .stage_start_valid(tensor_cache_stage_start_valid),
                .stage_start_ready(tensor_cache_stage_start_ready),
                .stage_cache_enable(tensor_cache_stage_enable),
                .stage_base_addr(tensor_cache_stage_base_addr),
                .stage_width(tensor_cache_stage_width),
                .stage_height(tensor_cache_stage_height),
                .stage_groups(tensor_cache_stage_groups),
                .stage_start_done(tensor_cache_stage_start_done),
                .stage_cache_active(tensor_cache_stage_active),
                .stage_cache_fallback(tensor_cache_stage_fallback),
                .stage_cache_reason(tensor_cache_stage_reason),
                .abort_req(adapter_abort),
                .abort_done(tensor_cache_abort_done),
                .flush_req(1'b0), .flush_done(),
                .s_req_valid(tensor_mem_req_valid),
                .s_req_end(tensor_mem_req_end),
                .s_req_ready(tensor_mem_req_ready),
                .s_req_write(tensor_mem_req_write),
                .s_req_addr(tensor_mem_req_addr),
                .s_req_wdata(tensor_mem_req_wdata),
                .s_req_wstrb(tensor_mem_req_wstrb),
                .s_req_cacheable(tensor_mem_req_cacheable),
                .s_req_cache_x(tensor_mem_req_cache_x),
                .s_req_cache_y(tensor_mem_req_cache_y),
                .s_req_cache_group(tensor_mem_req_cache_group),
                .s_rsp_valid(tensor_mem_rsp_valid),
                .s_rsp_ready(tensor_mem_rsp_ready),
                .s_rsp_error(tensor_mem_rsp_error),
                .s_rsp_rdata(tensor_mem_rsp_rdata),
                .m_axi_awaddr(axi_s_awaddr[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awlen(axi_s_awlen[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awsize(axi_s_awsize[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awburst(axi_s_awburst[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awvalid(axi_s_awvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_awready(axi_s_awready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wdata(axi_s_wdata[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wstrb(axi_s_wstrb[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wlast(axi_s_wlast[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wvalid(axi_s_wvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_wready(axi_s_wready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bresp(axi_s_bresp[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bvalid(axi_s_bvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_bready(axi_s_bready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_araddr(axi_s_araddr[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arlen(axi_s_arlen[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arsize(axi_s_arsize[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arburst(axi_s_arburst[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arvalid(axi_s_arvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_arready(axi_s_arready[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rdata(axi_s_rdata[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rresp(axi_s_rresp[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rlast(axi_s_rlast[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rvalid(axi_s_rvalid[AXI_CLIENT_TENSOR_CACHE]),
                .m_axi_rready(axi_s_rready[AXI_CLIENT_TENSOR_CACHE]),
                .cache_error(tensor_cache_error),
                .cache_error_code(tensor_cache_error_code),
                .busy(tensor_cache_busy),
                .quiescent(tensor_cache_quiescent)
            );
        end else begin : g_tensor_legacy_client
            c1_tensor_window_cache_axi_client #(
                .ENABLE_CACHE(ENABLE_TENSOR_WINDOW_CACHE),
                .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS)
            ) u_tensor_cache_axi_client (
        .clk(core_clk),
        .rst(core_rst),
        .stage_start_valid(tensor_cache_stage_start_valid),
        .stage_start_ready(tensor_cache_stage_start_ready),
        .stage_cache_enable(tensor_cache_stage_enable),
        .stage_base_addr(tensor_cache_stage_base_addr),
        .stage_width(tensor_cache_stage_width),
        .stage_height(tensor_cache_stage_height),
        .stage_groups(tensor_cache_stage_groups),
        .stage_start_done(tensor_cache_stage_start_done),
        .stage_cache_active(tensor_cache_stage_active),
        .stage_cache_fallback(tensor_cache_stage_fallback),
        .stage_cache_reason(tensor_cache_stage_reason),
        .abort_req(adapter_abort),
        .abort_done(tensor_cache_abort_done),
        .flush_req(1'b0),
        .flush_done(),
        .s_req_valid(tensor_mem_req_valid),
        .s_req_ready(tensor_mem_req_ready),
        .s_req_write(tensor_mem_req_write),
        .s_req_addr(tensor_mem_req_addr),
        .s_req_wdata(tensor_mem_req_wdata),
        .s_req_wstrb(tensor_mem_req_wstrb),
        .s_req_cacheable(tensor_mem_req_cacheable),
        .s_req_cache_x(tensor_mem_req_cache_x),
        .s_req_cache_y(tensor_mem_req_cache_y),
        .s_req_cache_group(tensor_mem_req_cache_group),
        .s_rsp_valid(tensor_mem_rsp_valid),
        .s_rsp_ready(tensor_mem_rsp_ready),
        .s_rsp_error(tensor_mem_rsp_error),
        .s_rsp_rdata(tensor_mem_rsp_rdata),
        .m_axi_awaddr(axi_s_awaddr[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_awlen(axi_s_awlen[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_awsize(axi_s_awsize[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_awburst(axi_s_awburst[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_awvalid(axi_s_awvalid[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_awready(axi_s_awready[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_wdata(axi_s_wdata[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_wstrb(axi_s_wstrb[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_wlast(axi_s_wlast[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_wvalid(axi_s_wvalid[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_wready(axi_s_wready[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_bresp(axi_s_bresp[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_bvalid(axi_s_bvalid[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_bready(axi_s_bready[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_araddr(axi_s_araddr[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_arlen(axi_s_arlen[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_arsize(axi_s_arsize[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_arburst(axi_s_arburst[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_arvalid(axi_s_arvalid[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_arready(axi_s_arready[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_rdata(axi_s_rdata[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_rresp(axi_s_rresp[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_rlast(axi_s_rlast[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_rvalid(axi_s_rvalid[AXI_CLIENT_TENSOR_CACHE]),
        .m_axi_rready(axi_s_rready[AXI_CLIENT_TENSOR_CACHE]),
        .cache_error(tensor_cache_error),
        .cache_error_code(tensor_cache_error_code),
        .busy(tensor_cache_busy),
        .quiescent(tensor_cache_quiescent)
            );
        end
    endgenerate

    assign osd_status_word = {
        control_error_code,
        engine_stage_index,
        control_display_frame_id[18:0]
    };

    always_ff @(posedge core_clk) begin
        if (core_rst)
            osd_alarm_q <= 1'b0;
        else begin
            if (control_error_event)
                osd_alarm_q <= 1'b1;
            if (csr_clear_stats_pulse)
                osd_alarm_q <= 1'b0;
        end
    end

    c1_r1_display_subsystem #(
        .SEPARATE_ORIGINAL_GEOMETRY(1),
        .FRAME_WIDTH((FRAME_WIDTH > SENSOR_WIDTH-2) ? FRAME_WIDTH : SENSOR_WIDTH-2),
        .ENABLE_RESPONSE_FIFO(ENABLE_DISPLAY_RESPONSE_FIFO),
        .RESPONSE_FIFO_DEPTH(DISPLAY_RESPONSE_FIFO_DEPTH)
    ) u_display (
        .original_width_pixels(display_original_width),
        .original_height_lines(display_original_height),
        .core_clk(core_clk), .core_rst(core_rst),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
        .start_valid(display_prefetch_start_valid),
        .start_ready(display_prefetch_start_ready),
        .abort(display_prefetch_abort),
        .flush_request(display_flush_request),
        .flush_busy(display_flush_busy),
        .flush_done(display_flush_done),
        .original_base(display_original_base),
        .original_stride(display_original_stride),
        .styled_base(display_styled_base),
        .styled_stride(display_styled_stride),
        .width_pixels(display_width),
        .height_lines(display_height),
        .busy(display_prefetch_busy),
        .done(display_prefetch_done),
        .aborted(display_prefetch_aborted),
        .error(display_prefetch_error),
         .primed(display_prefetch_primed),
         .feed_active(display_feed_active),
         .hold_requests(display_hold_requests),
        .display_mode(csr_display_mode),
        .osd_status_word(osd_status_word),
        .osd_alarm(osd_alarm_q),
        .frame_start_event(display_frame_start_event),
        .underflow_event(display_underflow_event),
        .video_rgb(video_rgb), .video_de(video_de),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .original_axi_araddr(axi_s_araddr[4]),
        .original_axi_arlen(axi_s_arlen[4]),
        .original_axi_arsize(axi_s_arsize[4]),
        .original_axi_arburst(axi_s_arburst[4]),
        .original_axi_arvalid(axi_s_arvalid[4]),
        .original_axi_arready(axi_s_arready[4]),
        .original_axi_rdata(axi_s_rdata[4]),
        .original_axi_rresp(axi_s_rresp[4]),
        .original_axi_rlast(axi_s_rlast[4]),
        .original_axi_rvalid(axi_s_rvalid[4]),
        .original_axi_rready(axi_s_rready[4]),
        .styled_axi_araddr(axi_s_araddr[5]),
        .styled_axi_arlen(axi_s_arlen[5]),
        .styled_axi_arsize(axi_s_arsize[5]),
        .styled_axi_arburst(axi_s_arburst[5]),
        .styled_axi_arvalid(axi_s_arvalid[5]),
        .styled_axi_arready(axi_s_arready[5]),
        .styled_axi_rdata(axi_s_rdata[5]),
        .styled_axi_rresp(axi_s_rresp[5]),
        .styled_axi_rlast(axi_s_rlast[5]),
        .styled_axi_rvalid(axi_s_rvalid[5]),
        .styled_axi_rready(axi_s_rready[5])
    );

    // Unused directions are tied off per leaf. Clients 0,1,6 own writes;
    // clients 0,2,3,4,5,6 own reads.
    assign axi_s_awaddr[2] = 32'd0;
    assign axi_s_awlen[2] = 8'd0;
    assign axi_s_awsize[2] = 3'd0;
    assign axi_s_awburst[2] = 2'd0;
    assign axi_s_awvalid[2] = 1'b0;
    assign axi_s_wdata[2] = 128'd0;
    assign axi_s_wstrb[2] = 16'd0;
    assign axi_s_wlast[2] = 1'b0;
    assign axi_s_wvalid[2] = 1'b0;
    assign axi_s_bready[2] = 1'b0;
    assign axi_s_awaddr[3] = 32'd0;
    assign axi_s_awlen[3] = 8'd0;
    assign axi_s_awsize[3] = 3'd0;
    assign axi_s_awburst[3] = 2'd0;
    assign axi_s_awvalid[3] = 1'b0;
    assign axi_s_wdata[3] = 128'd0;
    assign axi_s_wstrb[3] = 16'd0;
    assign axi_s_wlast[3] = 1'b0;
    assign axi_s_wvalid[3] = 1'b0;
    assign axi_s_bready[3] = 1'b0;
    assign axi_s_awaddr[4] = 32'd0;
    assign axi_s_awlen[4] = 8'd0;
    assign axi_s_awsize[4] = 3'd0;
    assign axi_s_awburst[4] = 2'd0;
    assign axi_s_awvalid[4] = 1'b0;
    assign axi_s_wdata[4] = 128'd0;
    assign axi_s_wstrb[4] = 16'd0;
    assign axi_s_wlast[4] = 1'b0;
    assign axi_s_wvalid[4] = 1'b0;
    assign axi_s_bready[4] = 1'b0;
    assign axi_s_awaddr[5] = 32'd0;
    assign axi_s_awlen[5] = 8'd0;
    assign axi_s_awsize[5] = 3'd0;
    assign axi_s_awburst[5] = 2'd0;
    assign axi_s_awvalid[5] = 1'b0;
    assign axi_s_wdata[5] = 128'd0;
    assign axi_s_wstrb[5] = 16'd0;
    assign axi_s_wlast[5] = 1'b0;
    assign axi_s_wvalid[5] = 1'b0;
    assign axi_s_bready[5] = 1'b0;
    assign axi_s_araddr[1] = 32'd0;
    assign axi_s_arlen[1] = 8'd0;
    assign axi_s_arsize[1] = 3'd0;
    assign axi_s_arburst[1] = 2'd0;
    assign axi_s_arvalid[1] = 1'b0;
    assign axi_s_rready[1] = 1'b0;

    c1_axi_n_serial_arbiter_128 #(
        .CLIENTS(AXI_CLIENTS),
        .WRITE_FIFO_DEPTH(FABRIC_WRITE_FIFO_DEPTH),
        .WRITE_W_AHEAD_OF_B(FABRIC_WRITE_W_AHEAD_OF_B),
        .WRITE_EMPTY_AW_BYPASS(FABRIC_WRITE_EMPTY_AW_BYPASS),
        .READ_RESPONSE_SKID(ENABLE_FABRIC_READ_RESPONSE_SKID)
    ) u_memory_fabric (
        .clk(core_clk), .rst(core_rst),
        .s_awaddr(axi_s_awaddr), .s_awlen(axi_s_awlen),
        .s_awsize(axi_s_awsize), .s_awburst(axi_s_awburst),
        .s_awvalid(axi_s_awvalid), .s_awready(axi_s_awready),
        .s_wdata(axi_s_wdata), .s_wstrb(axi_s_wstrb),
        .s_wlast(axi_s_wlast), .s_wvalid(axi_s_wvalid),
        .s_wready(axi_s_wready), .s_bresp(axi_s_bresp),
        .s_bvalid(axi_s_bvalid), .s_bready(axi_s_bready),
        .s_araddr(axi_s_araddr), .s_arlen(axi_s_arlen),
        .s_arsize(axi_s_arsize), .s_arburst(axi_s_arburst),
        .s_arvalid(axi_s_arvalid), .s_arready(axi_s_arready),
        .s_rdata(axi_s_rdata), .s_rresp(axi_s_rresp),
        .s_rlast(axi_s_rlast), .s_rvalid(axi_s_rvalid),
        .s_rready(axi_s_rready),
        .m_awaddr(m_axi_awaddr), .m_awlen(m_axi_awlen),
        .m_awsize(m_axi_awsize), .m_awburst(m_axi_awburst),
        .m_awvalid(m_axi_awvalid), .m_awready(m_axi_awready),
        .m_wdata(m_axi_wdata), .m_wstrb(m_axi_wstrb),
        .m_wlast(m_axi_wlast), .m_wvalid(m_axi_wvalid),
        .m_wready(m_axi_wready), .m_bresp(m_axi_bresp),
        .m_bvalid(m_axi_bvalid), .m_bready(m_axi_bready),
        .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst),
        .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready),
        .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast), .m_rvalid(m_axi_rvalid),
        .m_rready(m_axi_rready),
        .read_busy(fabric_read_busy),
        .read_quiescent(fabric_read_quiescent),
        .write_busy(fabric_write_busy),
        .write_quiescent(fabric_write_quiescent),
        .read_owner(fabric_read_owner),
        .write_owner(fabric_write_owner),
        .write_protocol_error(fabric_write_protocol_error),
        .write_data_busy(),.write_data_owner()
    );

    // The monitor is a deliberately optional observation/control boundary.
    // Per-client vectors remain hierarchical diagnostics, while the selected
    // aggregate snapshot is already wired to the APB QoS window above.  The
    // generate stays disabled by default so legacy synthesis has no counter
    // fanout or timing cost.
    generate
        if (ENABLE_SHARED_QOS_MONITOR != 0) begin : g_shared_qos_monitor
            localparam logic [SHARED_QOS_COUNTER_W-1:0] DEADLINE_MAX='1;
            localparam logic [SHARED_QOS_COUNTER_W-1:0] EFFECTIVE_DEADLINE=
                (SHARED_QOS_DEADLINE_CYCLES > DEADLINE_MAX) ? DEADLINE_MAX :
                SHARED_QOS_COUNTER_W'(SHARED_QOS_DEADLINE_CYCLES);
            c1_axi_shared_qos_monitor #(
                .CLIENTS(AXI_CLIENTS), .INDEX_W(AXI_INDEX_W),
                .COUNTER_W(SHARED_QOS_COUNTER_W)
            ) u_monitor (
                .clk(core_clk), .rst(core_rst),
                .clear_stats(csr_clear_stats_pulse),
                .awvalid(axi_s_awvalid), .awready(axi_s_awready),
                .wvalid(axi_s_wvalid), .wready(axi_s_wready),
                .bvalid(axi_s_bvalid), .bready(axi_s_bready),
                .arvalid(axi_s_arvalid), .arready(axi_s_arready),
                .rvalid(axi_s_rvalid), .rready(axi_s_rready),
                .read_busy(fabric_read_busy),
                .read_quiescent(fabric_read_quiescent),
                .write_busy(fabric_write_busy),
                .write_quiescent(fabric_write_quiescent),
                .read_owner(fabric_read_owner),
                .write_owner(fabric_write_owner),
                .frame_start(qos_frame_start_event),
                .frame_done(qos_frame_done_event),
                // This is the controller's shared lifecycle abort broadcast,
                // including display faults after the CNN has completed.
                .frame_abort(boardless_abort),
                .frame_deadline_cycles(EFFECTIVE_DEADLINE),
                .display_underflow_event(display_underflow_event),
                .aw_accept_count(qos_aw_accept_count),
                .w_accept_count(qos_w_accept_count),
                .b_accept_count(qos_b_accept_count),
                .ar_accept_count(qos_ar_accept_count),
                .r_accept_count(qos_r_accept_count),
                .aw_wait_total(qos_aw_wait_total),
                .w_wait_total(qos_w_wait_total),
                .b_stall_total(qos_b_stall_total),
                .ar_wait_total(qos_ar_wait_total),
                .r_stall_total(qos_r_stall_total),
                .aw_wait_max(qos_aw_wait_max),
                .w_wait_max(qos_w_wait_max),
                .b_stall_max(qos_b_stall_max),
                .ar_wait_max(qos_ar_wait_max),
                .r_stall_max(qos_r_stall_max),
                .read_owner_hold_total(qos_read_owner_hold_total),
                .write_owner_hold_total(qos_write_owner_hold_total),
                .read_owner_hold_max(qos_read_owner_hold_max),
                .write_owner_hold_max(qos_write_owner_hold_max),
                .read_owner_hold_max_owner(qos_read_owner_hold_max_owner),
                .write_owner_hold_max_owner(qos_write_owner_hold_max_owner),
                .read_busy_cycles(qos_read_busy_cycles),
                .write_busy_cycles(qos_write_busy_cycles),
                .frame_count(qos_frame_count),
                .current_frame_cycles(qos_current_frame_cycles),
                .last_frame_cycles(qos_last_frame_cycles),
                .deadline_miss_count(qos_deadline_miss_count),
                .display_underflow_count(qos_display_underflow_count),
                .protocol_error_count(qos_protocol_error_count),
                .frame_active(qos_frame_active),
                .monitor_overflow(qos_monitor_overflow)
            );

            assign qos_apb_monitor_enabled       = 1'b1;
            assign qos_apb_frame_active          = qos_frame_active;
            assign qos_apb_monitor_overflow      = qos_monitor_overflow;
            assign qos_apb_frame_count           = qos_frame_count;
            assign qos_apb_last_frame_cycles     = qos_last_frame_cycles;
            assign qos_apb_deadline_miss_count   = qos_deadline_miss_count;
            assign qos_apb_display_underflow_count = qos_display_underflow_count;
            assign qos_apb_read_busy_cycles      = qos_read_busy_cycles;
            assign qos_apb_write_busy_cycles     = qos_write_busy_cycles;
            assign qos_apb_read_owner_hold_max   = qos_read_owner_hold_max;
            assign qos_apb_write_owner_hold_max  = qos_write_owner_hold_max;
            assign qos_apb_protocol_error_count  = qos_protocol_error_count;
        end else begin : g_shared_qos_monitor_disabled
            // Keep the APB read window deterministic when the optional
            // observation logic is compiled out.
            assign qos_apb_monitor_enabled         = 1'b0;
            assign qos_apb_frame_active            = 1'b0;
            assign qos_apb_monitor_overflow        = 1'b0;
            assign qos_apb_frame_count             = 32'd0;
            assign qos_apb_last_frame_cycles       = 32'd0;
            assign qos_apb_deadline_miss_count     = 32'd0;
            assign qos_apb_display_underflow_count = 32'd0;
            assign qos_apb_read_busy_cycles        = 32'd0;
            assign qos_apb_write_busy_cycles       = 32'd0;
            assign qos_apb_read_owner_hold_max     = 32'd0;
            assign qos_apb_write_owner_hold_max    = 32'd0;
            assign qos_apb_protocol_error_count    = 32'd0;
        end
    endgenerate

`ifndef SYNTHESIS
    // compute-shell EOF is permitted to retire the boardless job only after
    // the bridge has observed both arithmetic completion and adapter final
    // EOF.  The bridge explicitly fences an early final EOF; keep this top-
    // level assertion as an integration invariant.
    always_ff @(posedge core_clk) begin
        if (!core_rst && boardless_done && bridge_busy)
            $fatal(1,
                   "boardless job retired before MicroStyle bridge terminal");
        if (!core_rst && !system_busy &&
            (axi_s_awvalid[AXI_CLIENT_TENSOR_CACHE] ||
             axi_s_wvalid[AXI_CLIENT_TENSOR_CACHE] ||
             axi_s_bready[AXI_CLIENT_TENSOR_CACHE] ||
             axi_s_arvalid[AXI_CLIENT_TENSOR_CACHE] ||
             axi_s_rready[AXI_CLIENT_TENSOR_CACHE]))
            $fatal(1,
                   "tensor AXI transaction remained active after BUSY cleared");
    end
`endif

endmodule
