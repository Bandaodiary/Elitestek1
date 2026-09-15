`timescale 1ns/1ps
`ifdef C1_ALL_DOT_PIXEL_WRITE_ABORT
`define C1_PIXEL_WRITE_ABORT
`define C1_PIXEL_ABORT_STAGE 0
`elsif C1_DOT_PIXEL_WRITE_ABORT
`define C1_PIXEL_WRITE_ABORT
`define C1_PIXEL_ABORT_STAGE 20
`elsif C1_DW_PIXEL_WRITE_ABORT
`define C1_PIXEL_WRITE_ABORT
`define C1_PIXEL_ABORT_STAGE 18
`endif
`ifndef C1_PIXEL_WRITE_BATCH_WORDS
`define C1_PIXEL_WRITE_BATCH_WORDS 1
`endif
`ifndef C1_TENSOR_WRITE_BUILD_TIMEOUT
`define C1_TENSOR_WRITE_BUILD_TIMEOUT 8
`endif
`ifdef C1_TENSOR_WRITE_MLP4
`define C1_TENSOR_WRITE_OUTSTANDING 4
`elsif C1_TENSOR_WRITE_MLP2
`define C1_TENSOR_WRITE_OUTSTANDING 2
`else
`define C1_TENSOR_WRITE_OUTSTANDING 1
`endif
`ifdef C1_TENSOR_COLUMN_READS
`define C1_COLUMN_SOC_ENABLE 1
`else
`define C1_COLUMN_SOC_ENABLE 0
`endif

// Small-frame dynamic integration test for the portable SoC.
//
// This test intentionally instantiates the real top (rather than the cache
// seam in isolation) with a selectable small active frame.  The default is
// 8x8; C1_FRAME_16X8, C1_FRAME_64X48 and C1_FRAME_640X480 provide deterministic scale-up
// points for the same complete lifecycle.
// software-visible lifecycle:
//
//   APB tables/descriptor/parameter setup -> ISP commit -> START
//   RAW10 (FRAME_W+2)x(FRAME_H+2) camera frame -> capture table lookup
//   -> XRGB DDR write
//   parameter arena + 22 descriptors -> boardless CNN job
//   tensor adapter/cache (client 6) -> seven-client AXI128 fabric
//   output DDR write -> display prefetch reads
//
// The memory model is deliberately a protocol BFM, not a zero-latency tie-off:
// AW/W/AR are independently backpressured, R/B responses are delayed and held
// until READY, and byte strobes are applied to a small sparse line store.
// Descriptor and table regions are decoded functionally, so the test does not
// allocate a multi-megabyte four-state memory just to represent the 32-bit
// address space.
module tb_c1_r1_portable_soc_cache_ddr_bfm;
    // Extra *testbench* latency, in core clocks. Zero preserves the historic
    // deterministic jitter profile. These are not calibrated DDR timings.
`ifdef C1_BFM_READ_FIRST_EXTRA
    localparam integer READ_FIRST_EXTRA=`C1_BFM_READ_FIRST_EXTRA;
`else
    localparam integer READ_FIRST_EXTRA=0;
`endif
`ifdef C1_BFM_READ_BEAT_EXTRA
    localparam integer READ_BEAT_EXTRA=`C1_BFM_READ_BEAT_EXTRA;
`else
    localparam integer READ_BEAT_EXTRA=0;
`endif
`ifdef C1_BFM_WRITE_RESPONSE_EXTRA
    localparam integer WRITE_RESPONSE_EXTRA=`C1_BFM_WRITE_RESPONSE_EXTRA;
`else
    localparam integer WRITE_RESPONSE_EXTRA=0;
`endif
    initial begin
        if(READ_FIRST_EXTRA<0 || READ_FIRST_EXTRA>255 ||
           READ_BEAT_EXTRA<0 || READ_BEAT_EXTRA>255 ||
           WRITE_RESPONSE_EXTRA<0 || WRITE_RESPONSE_EXTRA>255)
            $fatal(1,"BFM extra latency must be in 0..255 core cycles");
        $display("C1_NUM_BFM_DELAY first_extra=%0d beat_extra=%0d write_extra=%0d",
                 READ_FIRST_EXTRA,READ_BEAT_EXTRA,WRITE_RESPONSE_EXTRA);
    end
`ifdef C1_RAW_RASTER_FAULT
    localparam integer RAW_FAULT_CFG=1;
`else
    localparam integer RAW_FAULT_CFG=0;
`endif
    logic release_raw_fault=0;
    integer error_seen=0;
`ifdef C1_EXPLICIT_CAPTURE_RECOVERY
    localparam bit EXPLICIT_RECOVERY_CFG=1;
`else
    localparam bit EXPLICIT_RECOVERY_CFG=0;
`endif
    logic recovery_request=0,source_quiescent=0;
`ifdef C1_APB_CAPTURE_RECOVERY
    localparam bit APB_RECOVERY_CFG=1;
`else
    localparam bit APB_RECOVERY_CFG=0;
`endif
`ifdef C1_RECOVERY_LATE_SOURCE_ACK
    localparam bit RECOVERY_LATE_ACK=1;
`else
    localparam bit RECOVERY_LATE_ACK=0;
`endif
    wire recovery_ready,recovery_busy,recovery_done;
    integer recovery_completions=0;
`ifdef C1_RAW_IDLE_TIMEOUT
    localparam bit RAW_IDLE_CFG=1;
`else
    localparam bit RAW_IDLE_CFG=0;
`endif
    localparam logic [7:0] EXPECT_RAW_CODE=RAW_IDLE_CFG ? 8'h06 : 8'h05;
    localparam logic [7:0] EXPECT_CONTROL_CODE=RAW_IDLE_CFG ? 8'h46 : 8'h45;
`ifdef C1_RAW_MISSING_EOF
    localparam bit RAW_MISSING_EOF_CFG=1;
`else
    localparam bit RAW_MISSING_EOF_CFG=0;
`endif
`ifdef C1_DISTINCT_RECOVERY_FRAME
    localparam logic [9:0] RECOVERY_TONE=10'd32;
`else
    localparam logic [9:0] RECOVERY_TONE=10'd0;
`endif
`ifdef C1_SOURCE_GEOMETRY
    localparam logic [31:0] TEST_XS=32'h18000, TEST_YS=32'h14000;
    localparam logic [31:0] TEST_XP=32'h4000, TEST_YP=32'h2000;
`elsif C1_RESIZE_FIXTURE
    localparam logic [31:0] TEST_XS=32'hfffec000, TEST_YS=32'h0000c000;
    localparam logic [31:0] TEST_XP=32'h00078000, TEST_YP=32'hffffc000;
`else
    localparam logic [31:0] TEST_XS=32'h00010000, TEST_YS=32'h00010000;
    localparam logic [31:0] TEST_XP=0, TEST_YP=0;
`endif
`ifdef C1_CONCURRENT_DISPLAY_PREFETCH
    localparam integer CONCURRENT_DISPLAY_CFG = 1;
`else
    localparam integer CONCURRENT_DISPLAY_CFG = 0;
`endif
    integer concurrent_display_ar_count = 0;
`ifdef C1_TRAINED_ARTIFACT
    // Boardless artifact mode is an opt-in 8x8 integration probe.  The
    // default BFM remains the historical zero-parameter lifecycle test so
    // existing traffic/timing baselines are not changed accidentally.
    localparam integer TRAINED_ARTIFACT_CFG = 1;
`else
    localparam integer TRAINED_ARTIFACT_CFG = 0;
`endif
`ifdef C1_FRAME_16X8
    localparam integer FRAME_W = 16;
    localparam integer FRAME_H = 8;
`elsif C1_FRAME_16X16
    localparam integer FRAME_W = 16;
    localparam integer FRAME_H = 16;
`elsif C1_FRAME_64X48
    localparam integer FRAME_W = 64;
    localparam integer FRAME_H = 48;
`elsif C1_FRAME_640X480
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
`else
    localparam integer FRAME_W = 8;
    localparam integer FRAME_H = 8;
`endif
`ifdef C1_DISPLAY_RESPONSE_FIFO
    localparam integer DISPLAY_RESPONSE_FIFO_ENABLE = 1;
    // Leave one complete 16-beat/64-pixel burst of headroom even when a
    // previous burst has not yet drained into the line store.
    localparam integer DISPLAY_RESPONSE_FIFO_DEPTH_CFG = 128;
`else
    localparam integer DISPLAY_RESPONSE_FIFO_ENABLE = 0;
    localparam integer DISPLAY_RESPONSE_FIFO_DEPTH_CFG = 64;
`endif
`ifdef C1_TABLE_RESPONSE_FIFO
    localparam integer ENABLE_TABLE_RESPONSE_FIFO_CFG = 1;
`else
    localparam integer ENABLE_TABLE_RESPONSE_FIFO_CFG = 0;
`endif
`ifdef C1_RELAXED_DESCRIPTOR
    // The relaxed build is an explicitly opted-in performance experiment.
    // The DUT keeps a simulation-time ABI guard so malformed descriptors still
    // fail loudly instead of silently producing an invalid tensor address.
    localparam integer STRICT_DESCRIPTOR_VALIDATION_CFG = 0;
`else
    localparam integer STRICT_DESCRIPTOR_VALIDATION_CFG = 1;
`endif
`ifdef C1_PREFETCH_NEXT_TAP_ADDRESS
    localparam integer PREFETCH_NEXT_TAP_ADDRESS_CFG = 1;
`else
    localparam integer PREFETCH_NEXT_TAP_ADDRESS_CFG = 0;
`endif
`ifdef C1_REUSE_HORIZONTAL_WINDOW
    localparam integer REUSE_HORIZONTAL_WINDOW_CFG = 1;
`else
    localparam integer REUSE_HORIZONTAL_WINDOW_CFG = 0;
`endif
`ifdef C1_FAST_ADDRESS
    localparam integer FAST_TENSOR_ADDRESS_ARITH_CFG = 1;
`else
    localparam integer FAST_TENSOR_ADDRESS_ARITH_CFG = 0;
`endif
`ifdef C1_PIPELINED_ADDRESS
    localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 1;
`else
    localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 0;
`endif
`ifdef C1_PIPELINED_TENSOR_PIXEL_INDEX
    localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 1;
`else
    localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_VALIDATION
    // Optional two-boundary strict descriptor checker.  It adds a fixed
    // bubble per stage configuration but should not alter the descriptor
    // stream payload or error priority.
    localparam integer PIPELINED_DESCRIPTOR_VALIDATION_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_VALIDATION_CFG = 0;
`endif
`ifdef C1_NARROW_DESCRIPTOR_SIZE_CHECK
    localparam integer NARROW_DESCRIPTOR_SIZE_CHECK_CFG = 1;
`else
    localparam integer NARROW_DESCRIPTOR_SIZE_CHECK_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_SIZE_ARITH
    localparam integer PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG = 0;
`endif
`ifdef C1_FIXED_DESCRIPTOR_SIZE_LIMITS
    localparam integer FIXED_DESCRIPTOR_SIZE_LIMITS_CFG = 1;
`else
    localparam integer FIXED_DESCRIPTOR_SIZE_LIMITS_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_PIXEL_COUNT
    localparam integer PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG = 0;
`endif
`ifdef C1_ITERATIVE_DESCRIPTOR_PIXEL_COUNT
    localparam integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG = 1;
`else
    localparam integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG = 0;
`endif
`ifdef C1_PRECLAMPED_TAP_COORDS
    // The tensor seam clamps cache sideband coordinates before the payload
    // cache sees them; this opt-in removes the child's duplicate geometry
    // compare for timing A/B only.
    localparam integer PRECLAMPED_TAP_COORDS_CFG = 1;
`else
    localparam integer PRECLAMPED_TAP_COORDS_CFG = 0;
`endif
`ifdef C1_REGISTER_ABORT_RESET
    // Optional one-cycle child-reset hold used only for timing attribution;
    // raw abort handshakes remain fenced immediately by the RTL wrapper.
    localparam integer REGISTER_ABORT_RESET_CFG = 1;
`else
    localparam integer REGISTER_ABORT_RESET_CFG = 0;
`endif
`ifdef C1_PIPELINED_START_CONFIG
    localparam integer PIPELINED_START_CONFIG_CFG = 1;
`else
    localparam integer PIPELINED_START_CONFIG_CFG = 0;
`endif
`ifdef C1_CACHE_DW_WEIGHT_TILES
    localparam integer CACHE_DW_WEIGHT_TILES_CFG=1;
`else
    localparam integer CACHE_DW_WEIGHT_TILES_CFG=0;
`endif
`ifdef C1_MAC_PREFETCH_OVERLAP
    localparam integer MAC_PREFETCH_OVERLAP_CFG=1;
`else
    localparam integer MAC_PREFETCH_OVERLAP_CFG=0;
`endif
`ifdef C1_PIPELINED_DOT_TREE
    localparam integer PIPELINED_DOT_TREE_CFG = 1;
`else
    localparam integer PIPELINED_DOT_TREE_CFG = 0;
`endif
`ifdef C1_PIPELINED_DOT_TREE_FULL
    localparam integer PIPELINED_DOT_TREE_FULL_CFG = 1;
`else
    localparam integer PIPELINED_DOT_TREE_FULL_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_REPLAY
    localparam integer PIPELINED_DESCRIPTOR_REPLAY_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_REPLAY_CFG = 0;
`endif
`ifdef C1_PREVALIDATE_DESCRIPTOR_REPLAY
    localparam integer PREVALIDATE_DESCRIPTOR_REPLAY_CFG = 1;
`else
    localparam integer PREVALIDATE_DESCRIPTOR_REPLAY_CFG = 0;
`endif
`ifdef C1_PIPELINED_DECODER_VALIDATION
    // Optional two-cycle validation schedule in the replay-side command
    // decoder.  It is independent of the tensor-adapter checker above.
    localparam integer PIPELINED_DECODER_VALIDATION_CFG = 1;
`else
    localparam integer PIPELINED_DECODER_VALIDATION_CFG = 0;
`endif
`ifdef C1_REPLICATE_ABORT_CONTROL
    localparam integer REPLICATE_ABORT_CONTROL_CFG = 1;
`else
    localparam integer REPLICATE_ABORT_CONTROL_CFG = 0;
`endif
`ifdef C1_UNIFIED_OUTPUT_FIFO
    localparam integer ENABLE_UNIFIED_OUTPUT_FIFO_CFG = 1;
`else
    localparam integer ENABLE_UNIFIED_OUTPUT_FIFO_CFG = 0;
`endif
`ifdef C1_UNIFIED_OUTPUT_SKID
    localparam integer ENABLE_UNIFIED_OUTPUT_SKID_CFG = 1;
`else
    localparam integer ENABLE_UNIFIED_OUTPUT_SKID_CFG = 0;
`endif
`ifdef C1_FABRIC_READ_RESPONSE_SKID
    localparam integer ENABLE_FABRIC_READ_RESPONSE_SKID_CFG = 1;
`else
    localparam integer ENABLE_FABRIC_READ_RESPONSE_SKID_CFG = 0;
`endif
`ifdef C1_REGISTER_FATAL_TICKET
    localparam integer REGISTER_FATAL_TICKET_CFG = 1;
`else
    localparam integer REGISTER_FATAL_TICKET_CFG = 0;
`endif
`ifdef C1_SHARED_QOS_MONITOR
    localparam integer ENABLE_SHARED_QOS_MONITOR_CFG = 1;
    // The native 8x8 BFM intentionally includes a long ID-less R hold.  A
    // one-million-cycle budget therefore exercises the deadline-miss counter
    // while remaining below the 24-bit monitor range.
    localparam logic [31:0] SHARED_QOS_DEADLINE_CYCLES_CFG = 32'd1_000_000;
    // The display timing domain is a fixed 720p raster, while the active test
    // image may be wider/taller than the 8x8 smoke shape.  A tagged prefetch
    // completion is allowed to wait for the pixel side to acknowledge the last
    // line, so a larger shape can legitimately cross a 50 ms (5 M core-cycle)
    // observation window even after the ownership swap has occurred.  Keep the
    // A small image now drains only inside its actual height (no erroneous
    // requests in the rest of the 480-line panel). It may need the next
    // raster after a refresh and ownership commit. Allow 100 ms for smoke;
    // this is an observation bound, NOT a relaxed hardware QoS deadline.
    localparam integer SHARED_QOS_BOUNDARY_WAIT_CYCLES =
        ((FRAME_W * FRAME_H) >= 3072) ? 20_000_000 : 10_000_000;
`else
    localparam integer ENABLE_SHARED_QOS_MONITOR_CFG = 0;
    localparam logic [31:0] SHARED_QOS_DEADLINE_CYCLES_CFG = 32'd0;
`endif
`ifdef C1_TENSOR_BURST_REFILL
    localparam integer ENABLE_TENSOR_BURST_REFILL_CFG = 1;
`else
    localparam integer ENABLE_TENSOR_BURST_REFILL_CFG = 0;
`endif
`ifdef C1_COMPACT_REFILL_FIFOS
    localparam integer TENSOR_BURST_RSP_FIFO_BEAT_MODE_CFG = 0;
    localparam integer TENSOR_BURST_RSP_FIFO_DEPTH_CFG = 16;
`elsif C1_TENSOR_BURST_BEAT_MODE
    // The top-level beat-record option uses the conservative minimum depth
    // for the default 16-beat/4-outstanding reader configuration.  It is only
    // meaningful when the burst client itself is enabled.
    localparam integer TENSOR_BURST_RSP_FIFO_BEAT_MODE_CFG = 1;
    localparam integer TENSOR_BURST_RSP_FIFO_DEPTH_CFG = 64;
`else
    localparam integer TENSOR_BURST_RSP_FIFO_BEAT_MODE_CFG = 0;
    localparam integer TENSOR_BURST_RSP_FIFO_DEPTH_CFG = 128;
`endif
`ifdef C1_SOURCE_GEOMETRY
    localparam integer SOURCE_W=12, SOURCE_H=10, SOURCE_STRIDE=64;
`else
    localparam integer SOURCE_W=FRAME_W, SOURCE_H=FRAME_H, SOURCE_STRIDE=FRAME_W*4;
`endif
    localparam integer SENSOR_W = SOURCE_W + 2;
    localparam integer SENSOR_H = SOURCE_H + 2;
    localparam integer INPUT_SLOT_BYTES=((SOURCE_STRIDE*SOURCE_H+255)/256)*256;
    localparam integer CAM_X_W = (SENSOR_W <= 1) ? 1 : $clog2(SENSOR_W);
    localparam integer CAM_Y_W = (SENSOR_H <= 1) ? 1 : $clog2(SENSOR_H);

    localparam logic [31:0] IN_TABLE   = 32'h0000_1000;
    localparam logic [31:0] OUT_TABLE  = 32'h0000_2000;
    localparam logic [31:0] DESC_BASE  = 32'h0000_4000;
    localparam logic [31:0] WEIGHT_BASE= 32'h0001_0000;
    localparam logic [31:0] INPUT_BASE = 32'h0010_0000;
    // The compact smoke-map is sufficient for the small frames, but a native
    // 640x480 slot is 0x12c000 bytes.  Move output far enough past all three
    // input slots before any native runtime test; keep the historical map for
    // the existing small-frame traffic baselines.
    localparam logic [31:0] OUTPUT_BASE = (FRAME_W >= 640) ?
                                          32'h0060_0000 : 32'h0020_0000;
    localparam logic [31:0] TENSOR_BASE= 32'h0200_0000;
    localparam integer XRGB_STRIDE = FRAME_W * 4;
    // Frame-manager table indices must not alias when the parameterized
    // image is larger than the original 8x8 smoke-test frame.  Keep every
    // slot 0x100 aligned so descriptor/table ABI alignment remains intact.
    localparam integer FRAME_BYTES = XRGB_STRIDE * FRAME_H;
    localparam integer FRAME_SLOT_BYTES =
        ((FRAME_BYTES + 16'h00ff) / 16'h0100) * 16'h0100;
    // The bounded hash store is intentionally retained for fast small-frame
    // regressions.  Native geometry switches to an address-keyed associative
    // store below so line collisions cannot masquerade as frame corruption.
    // Different source geometry exceeds the collision-free footprint of the
    // old 8x8 direct-mapped BFM. Preserve all committed DDR addresses.
`ifdef C1_TWO_FRAME_TRACE
    localparam logic USE_ASSOC_MEM = 1'b1;
    integer two_job=-1,two_completed=0;
    integer two_inputs[0:1]='{0,0},two_outputs[0:1]='{0,0};
    logic [511:0] two_written='0;
    integer two_video_raw[0:1]='{0,0},two_video_styled[0:1]='{0,0};
    // Fixed BFM clocks: core 10 ns, pixel 14 ns; fixed 720p raster 1650x750.
    // A committed swap may miss this raster's pixel-domain enable latch.
    localparam integer TWO_VIDEO_WAIT_CYCLES=(2*1650*750*14+9)/10;
`else
    // A 16x8 stage-17 output at 0x02000500 collides with the still-live input
    // at 0x02800100 in the old index function. All trained runs must preserve
    // every full address; increasing MEM_SLOTS is not a correctness fix.
    localparam logic USE_ASSOC_MEM = TRAINED_ARTIFACT_CFG || (FRAME_W >= 640) ||
                                   (SOURCE_W!=FRAME_W) || (SOURCE_H!=FRAME_H);
`endif
    localparam integer MEM_SLOTS = 32768;

    // The size-matched artifact is loaded only by the opt-in trained mode.
    // Keeping the arrays at the fixed ABI dimensions also lets the same
    // source elaborate in Icarus and Vivado without allocating a dense DDR
    // image.  The normal mode never reads these arrays.
    logic [511:0] trained_descriptors [0:21];
    logic [127:0] trained_parameter_mem [0:1055];

    logic core_clk = 1'b0;
    always @(posedge core_clk) if(recovery_done) recovery_completions<=recovery_completions+1;
    always @(posedge core_clk) begin
        if (dut.boardless_busy) begin
            if (dut.axi_s_arvalid[4] && dut.axi_s_arready[4])
                concurrent_display_ar_count <= concurrent_display_ar_count + 1;
            else if (dut.axi_s_arvalid[5] && dut.axi_s_arready[5])
                concurrent_display_ar_count <= concurrent_display_ar_count + 1;
        end
    end
    logic pixel_clk = 1'b0;
    logic camera_clk = 1'b0;
    logic arst_n = 1'b0;
    always #5 core_clk = ~core_clk;
    always #7 pixel_clk = ~pixel_clk;
    always #6 camera_clk = ~camera_clk;

    logic psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    logic [11:0] paddr = 12'd0;
    logic [31:0] pwdata = 32'd0, prdata;
    logic [3:0] pstrb = 4'd0;
    logic pready, pslverr, irq;

    logic camera_valid = 1'b0, camera_ready;
    logic [9:0] camera_raw10 = 10'd0;
    logic [CAM_X_W-1:0] camera_x = '0;
    logic [CAM_Y_W-1:0] camera_y = '0;
    logic camera_sof = 1'b0, camera_eol = 1'b0, camera_eof = 1'b0;
    logic camera_overflow;
    logic [23:0] video_rgb;
    logic video_de, video_hsync, video_vsync;
    logic [4:0] engine_stage_index;
    logic [7:0] engine_stage_opcode;
    logic engine_stage_active, engine_overflow_seen, system_busy;

    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize;
    logic [1:0] awburst, arburst;
    logic awvalid, awready;
    logic [127:0] wdata;
    logic [15:0] wstrb;
    logic wlast, wvalid, wready;
    logic [1:0] bresp;
    logic bvalid, bready;
    logic arvalid, arready;
    logic [127:0] rdata;
    logic [1:0] rresp;
    logic rlast, rvalid, rready;

`ifdef C1_QUEUED_WRITE_FABRIC
    localparam bit QUEUED_WRITE_CFG=1;
`else
    localparam bit QUEUED_WRITE_CFG=0;
`endif
    c1_r1_portable_soc #(
        .TENSOR_WRITE_OUTSTANDING(`C1_TENSOR_WRITE_OUTSTANDING),
        .PIXEL_WRITE_BATCH_WORDS(`C1_PIXEL_WRITE_BATCH_WORDS),
        .TENSOR_WRITE_BUILD_TIMEOUT(`C1_TENSOR_WRITE_BUILD_TIMEOUT),
`ifdef C1_OVERLAP_MAC_REQUANTIZATION
        .OVERLAP_MAC_REQUANTIZATION(1),
`endif
`ifdef C1_STREAM_POINTWISE_REDUCTION
        .STREAM_POINTWISE_REDUCTION(1),
`endif
`ifdef C1_PIPELINED_SOURCE_WRITES
        .PIPELINED_SOURCE_WRITES(1),
`endif
`ifdef C1_PIXEL_COLUMN_PREFETCH
        .PREFETCH_NEXT_PIXEL_COLUMN(1),
`endif
`ifdef C1_ALL_PIXEL_GROUPS
        .PREFETCH_ALL_PIXEL_GROUPS(1),
`endif
`ifdef C1_PIPELINE_DOT_PIXELS
        .PIPELINE_DOT_PIXELS(1),
`endif
`ifdef C1_PIPELINE_ALL_DOT_GROUPS
        .PIPELINE_ALL_DOT_GROUPS(1),
`endif
`ifdef C1_PACK_RGB_CONV_REDUCTION
        .PACK_RGB_CONV_REDUCTION(1),
`endif
`ifdef C1_ELIDE_VIRTUAL_UPSAMPLE
        .ELIDE_VIRTUAL_UPSAMPLE(1),
`endif
`ifdef C1_PIPELINE_DW_PIXELS
        .PIPELINE_DW_PIXELS(1),
`endif
`ifdef C1_STREAM_DW_FRAME
        .STREAM_DW_FRAME(1),
`endif
`ifdef C1_COLUMN_RESPONSE_BYPASS
        .TENSOR_COLUMN_RESPONSE_BYPASS(1),
`endif
`ifdef C1_COLUMN_REUSE_ROW_MAP
        .TENSOR_COLUMN_REUSE_ROW_MAP(1),
`endif
`ifdef C1_FUSE_FINAL_OUTPUT
        .FUSE_FINAL_OUTPUT(1),
`endif
`ifdef C1_POINTWISE_COLUMN_READS
        .POINTWISE_COLUMN_READS(1),
`endif
`ifdef C1_COLUMN_WRITE_OVERLAP
        .OVERLAP_COLUMN_WRITEBACK(1),
`endif
`ifdef C1_PRECISE_WRITE_INVALIDATION
        .TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION(1),
`endif
`ifdef C1_VIRTUAL_UPSAMPLE_TENSORS
        .VIRTUAL_UPSAMPLE_TENSORS(1),
`endif
`ifdef C1_STREAM_DW_GROUPS
        .STREAM_DW_GROUPS(1),
`endif
`ifdef C1_SCALAR_READ_BEAT_CACHE
        .TENSOR_SCALAR_READ_BEAT_CACHE(1),
`endif
`ifdef C1_SCALAR_READ_CACHE_TWO
        .TENSOR_SCALAR_READ_CACHE_ENTRIES(2),
`endif
`ifdef C1_COLUMN_READ_ON_LOOKUP
        .TENSOR_COLUMN_READ_ON_LOOKUP(1),
`endif
        .ENABLE_TENSOR_COLUMN_READS(`C1_COLUMN_SOC_ENABLE),
`ifdef C1_RAW_RASTER_FAULT
        .CHECK_RAW_RASTER(1),.CAMERA_READY_VALID_SOURCE(1),
        .RAW_IDLE_TIMEOUT_CYCLES(RAW_IDLE_CFG ? 4096 : 0),
        .ENABLE_EXPLICIT_CAPTURE_RECOVERY(EXPLICIT_RECOVERY_CFG),
`endif
`ifdef C1_PREVIEW_DISPLAY
        .DISPLAY_RESIZED_PREVIEW(1),
`endif
`ifdef C1_PREVIEW_CAPTURE
        .ENABLE_PREVIEW_CAPTURE(1),.PREVIEW_BUFFER0_BASE(32'h0100_0000),
        .PREVIEW_BUFFER1_BASE(32'h0100_0100),
        .PREVIEW_REGION_BEGIN(33'h0100_0000),.PREVIEW_REGION_END(33'h0100_0200),
`endif
        .FABRIC_WRITE_FIFO_DEPTH(QUEUED_WRITE_CFG ? 4 : 0),
`ifdef C1_SERIALIZE_WRITE_DATA
        .FABRIC_WRITE_W_AHEAD_OF_B(0),
`else
        .FABRIC_WRITE_W_AHEAD_OF_B(QUEUED_WRITE_CFG),
`endif
        .FABRIC_WRITE_EMPTY_AW_BYPASS(QUEUED_WRITE_CFG),
        .FRAME_WIDTH(FRAME_W),
        .FRAME_HEIGHT(FRAME_H),
        .SENSOR_WIDTH(SENSOR_W),
        .SENSOR_HEIGHT(SENSOR_H),
        .ENABLE_TENSOR_WINDOW_CACHE(1),
        .ENABLE_TENSOR_BURST_REFILL(ENABLE_TENSOR_BURST_REFILL_CFG),
        .TENSOR_BURST_RSP_FIFO_BEAT_MODE(TENSOR_BURST_RSP_FIFO_BEAT_MODE_CFG),
        .TENSOR_BURST_RSP_FIFO_DEPTH(TENSOR_BURST_RSP_FIFO_DEPTH_CFG),
`ifdef C1_REFILL_REQUEST_HANDOFF
        .TENSOR_BURST_SCHED_REQ_HANDOFF(1),
`endif
`ifdef C1_WIDE_REFILL_WINDOW
        .TENSOR_BURST_SCHED_MAX_OUTSTANDING(32),
`endif
`ifdef C1_COMPACT_REFILL_FIFOS
        .TENSOR_BURST_REQ_FIFO_DEPTH(16),
`endif
        .ENABLE_DISPLAY_RESPONSE_FIFO(DISPLAY_RESPONSE_FIFO_ENABLE),
        .CONCURRENT_DISPLAY_PREFETCH(CONCURRENT_DISPLAY_CFG),
        .DISPLAY_RESPONSE_FIFO_DEPTH(DISPLAY_RESPONSE_FIFO_DEPTH_CFG),
        .ENABLE_FABRIC_READ_RESPONSE_SKID(ENABLE_FABRIC_READ_RESPONSE_SKID_CFG),
        .ENABLE_TABLE_RESPONSE_FIFO(ENABLE_TABLE_RESPONSE_FIFO_CFG),
        .STRICT_DESCRIPTOR_VALIDATION(STRICT_DESCRIPTOR_VALIDATION_CFG),
        .PIPELINED_DESCRIPTOR_VALIDATION(PIPELINED_DESCRIPTOR_VALIDATION_CFG),
        .NARROW_DESCRIPTOR_SIZE_CHECK(NARROW_DESCRIPTOR_SIZE_CHECK_CFG),
        .PIPELINED_DESCRIPTOR_SIZE_ARITH(PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG),
        .FIXED_DESCRIPTOR_SIZE_LIMITS(FIXED_DESCRIPTOR_SIZE_LIMITS_CFG),
        .PIPELINED_DESCRIPTOR_PIXEL_COUNT(PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG),
        .ITERATIVE_DESCRIPTOR_PIXEL_COUNT(ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG),
        .PRECLAMPED_TAP_COORDS(PRECLAMPED_TAP_COORDS_CFG),
`ifdef C1_PIPELINED_RESULT_WRITES
        .PIPELINED_RESULT_WRITES(1),
`endif
`ifdef C1_TENSOR_PACKED_WRITES
        .ENABLE_TENSOR_PACKED_WRITES(1),
`endif
`ifdef C1_TENSOR_WRITE_END
        .USE_TENSOR_WRITE_END(1),
`endif
        .REGISTER_ABORT_RESET(REGISTER_ABORT_RESET_CFG),
        .FAST_TENSOR_ADDRESS_ARITH(FAST_TENSOR_ADDRESS_ARITH_CFG),
        .PIPELINED_TENSOR_ADDRESS(PIPELINED_TENSOR_ADDRESS_CFG),
        .PIPELINED_TENSOR_PIXEL_INDEX(PIPELINED_TENSOR_PIXEL_INDEX_CFG),
        .PIPELINED_START_CONFIG(PIPELINED_START_CONFIG_CFG),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE_CFG),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL_CFG),
        .CACHE_DW_WEIGHT_TILES(CACHE_DW_WEIGHT_TILES_CFG),
        .MAC_PREFETCH_OVERLAP(MAC_PREFETCH_OVERLAP_CFG),
        .PREFETCH_NEXT_TAP_ADDRESS(PREFETCH_NEXT_TAP_ADDRESS_CFG),
        .REUSE_HORIZONTAL_WINDOW(REUSE_HORIZONTAL_WINDOW_CFG),
        .PIPELINED_DESCRIPTOR_REPLAY(PIPELINED_DESCRIPTOR_REPLAY_CFG),
        .PREVALIDATE_DESCRIPTOR_REPLAY(PREVALIDATE_DESCRIPTOR_REPLAY_CFG),
        .PIPELINED_DECODER_VALIDATION(PIPELINED_DECODER_VALIDATION_CFG),
        .REPLICATE_ABORT_CONTROL(REPLICATE_ABORT_CONTROL_CFG),
        .REGISTER_FATAL_TICKET(REGISTER_FATAL_TICKET_CFG),
        .ENABLE_UNIFIED_OUTPUT_FIFO(ENABLE_UNIFIED_OUTPUT_FIFO_CFG),
        .ENABLE_UNIFIED_OUTPUT_SKID(ENABLE_UNIFIED_OUTPUT_SKID_CFG),
        .ENABLE_SHARED_QOS_MONITOR(ENABLE_SHARED_QOS_MONITOR_CFG),
        .SHARED_QOS_COUNTER_W(24),
        .SHARED_QOS_DEADLINE_CYCLES(SHARED_QOS_DEADLINE_CYCLES_CFG),
        .JOB_CYCLE_BUDGET(32'd1_000_000_000)
    ) dut (
        .core_clk(core_clk), .pixel_clk(pixel_clk), .camera_clk(camera_clk),
        .capture_recovery_request(recovery_request),
        .capture_source_quiescent(source_quiescent),
        .capture_recovery_ready(recovery_ready),
        .capture_recovery_busy(recovery_busy),
        .capture_recovery_done(recovery_done),
        .arst_n(arst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready),
        .pslverr(pslverr), .irq(irq),
        .camera_valid(camera_valid), .camera_ready(camera_ready),
        .camera_raw10(camera_raw10), .camera_x(camera_x), .camera_y(camera_y),
        .camera_sof(camera_sof), .camera_eol(camera_eol), .camera_eof(camera_eof),
        .camera_overflow(camera_overflow),
        .video_rgb(video_rgb), .video_de(video_de),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .engine_stage_index(engine_stage_index),
        .engine_stage_opcode(engine_stage_opcode),
        .engine_stage_active(engine_stage_active),
        .engine_overflow_seen(engine_overflow_seen), .system_busy(system_busy),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    // ------------------------------------------------------------------
    // Descriptor/table/parameter image helpers
    // ------------------------------------------------------------------
    function automatic [7:0] stage_opcode(input integer si);
        begin
            case (si)
                0,1,20: stage_opcode=8'd1;
                2,4,6,8,10,12,16,19: stage_opcode=8'd2;
                3,7,11,15,18: stage_opcode=8'd3;
                14,17: stage_opcode=8'd4;
                5,9,13: stage_opcode=8'd5;
                21: stage_opcode=8'd6;
                default: stage_opcode=8'd0;
            endcase
        end
    endfunction

    function automatic integer stage_cin(input integer si);
        begin
            case (si)
                0: stage_cin=3;
                1: stage_cin=12;
                2,5,6,9,10,13,14,15,16: stage_cin=24;
                3,4,7,8,11,12: stage_cin=48;
                17,18,19: stage_cin=16;
                20: stage_cin=8;
                21: stage_cin=3;
                default: stage_cin=0;
            endcase
        end
    endfunction

    function automatic integer stage_cout(input integer si);
        begin
            case (si)
                0: stage_cout=12;
                1,4,5,8,9,12,13,14,15: stage_cout=24;
                2,3,6,7,10,11: stage_cout=48;
                16,17,18: stage_cout=16;
                19: stage_cout=8;
                20,21: stage_cout=3;
                default: stage_cout=0;
            endcase
        end
    endfunction

    function automatic integer scale_width(input integer base_width);
        scale_width = (base_width * FRAME_W) / 8;
    endfunction

    function automatic integer scale_height(input integer base_height);
        scale_height = (base_height * FRAME_H) / 8;
    endfunction

    function automatic integer stage_iw(input integer si);
        integer base_width;
        begin
            if (si == 0) base_width=8;
            else if (si == 1) base_width=4;
            else if (si <= 14) base_width=2;
            else if (si <= 17) base_width=4;
            else base_width=8;
            stage_iw = scale_width(base_width);
        end
    endfunction

    function automatic integer stage_ih(input integer si);
        integer base_height;
        begin
            if (si == 0) base_height=8;
            else if (si == 1) base_height=4;
            else if (si <= 14) base_height=2;
            else if (si <= 17) base_height=4;
            else base_height=8;
            stage_ih = scale_height(base_height);
        end
    endfunction

    function automatic integer stage_ow(input integer si);
        integer base_width;
        begin
            if (si == 0) base_width=4;
            else if (si <= 13) base_width=2;
            else if (si <= 16) base_width=4;
            else base_width=8;
            stage_ow = scale_width(base_width);
        end
    endfunction

    function automatic integer stage_oh(input integer si);
        integer base_height;
        begin
            if (si == 0) base_height=4;
            else if (si <= 13) base_height=2;
            else if (si <= 16) base_height=4;
            else base_height=8;
            stage_oh = scale_height(base_height);
        end
    endfunction

    function automatic integer stage_act(input integer si);
        begin
            case (si)
                4,8,12,14,17,19,20,21: stage_act=0;
                default: stage_act=1;
            endcase
        end
    endfunction

    function automatic [511:0] make_descriptor(input integer si);
        logic [511:0] d;
        logic [7:0] op;
        integer iw,ih,ow,oh,cin,cout,act;
        begin
            op=stage_opcode(si); iw=stage_iw(si); ih=stage_ih(si);
            ow=stage_ow(si); oh=stage_oh(si); cin=stage_cin(si);
            cout=stage_cout(si); act=stage_act(si);
            d='0;
            d[7:0]=op; d[9:8]=act[1:0];
            d[23:16]=8'd1; d[31:24]=8'd16;
            d[47:32]=iw; d[63:48]=ih; d[79:64]=ow; d[95:80]=oh;
            d[111:96]=cin; d[127:112]=cout;
            d[455:448]=8'd8; d[463:456]=8'd1;
            d[471:464]=8'd1; d[479:472]=8'd1;
            if ((op==8'd1)||(op==8'd3)) begin
                d[423:416]=8'd3; d[431:424]=8'd3; d[10]=1'b1;
            end else begin
                d[423:416]=8'd1; d[431:424]=8'd1;
            end
            if ((si==0)||(si==1)) begin
                d[439:432]=8'd2; d[447:440]=8'd2;
            end else if (op==8'd4) begin
                d[439:432]=8'd2; d[447:440]=8'd2;
            end else begin
                d[439:432]=8'd1; d[447:440]=8'd1;
            end
            if (op==8'd5) d[11]=1'b1;
            if (si==0) d[12]=1'b1;
            if (si==21) d[13]=1'b1;
            d[511:480]=32'd1_000_000;
            make_descriptor=d;
        end
    endfunction

    // Keep each frame-manager buffer index on a distinct frame-sized,
    // 0x100-aligned slot.  This is required for serialized multi-frame runs:
    // a fixed 0x100 stride would overlap 64x48 (12 KiB) image buffers.
    function automatic [127:0] table_entry(input logic [31:0] base,
                                           input integer index);
        logic [127:0] t;
        begin
            t='0;
            t[63:0]=base + (index * (base==INPUT_BASE ? INPUT_SLOT_BYTES : FRAME_SLOT_BYTES));
            t[95:64]=base==INPUT_BASE ? SOURCE_STRIDE : XRGB_STRIDE;
            t[111:96]=base==INPUT_BASE ? SOURCE_W : FRAME_W;
            t[127:112]=base==INPUT_BASE ? SOURCE_H : FRAME_H;
            table_entry=t;
        end
    endfunction

    // The default parameter image is intentionally all zero.  In the
    // opt-in trained-artifact mode this function instead exposes the exact
    // 16-byte words exported by the QAT arena, while preserving the same DDR
    // address contract used by the parameter loader.
    function automatic [127:0] parameter_word(input logic [31:0] addr);
        integer parameter_index;
        begin
            parameter_word = 128'd0;
            if (TRAINED_ARTIFACT_CFG &&
                (addr >= WEIGHT_BASE) &&
                (addr < (WEIGHT_BASE + 32'd16896)) &&
                (addr[3:0] == 4'd0)) begin
                parameter_index = (addr - WEIGHT_BASE) >> 4;
                if ((parameter_index >= 0) && (parameter_index < 1056))
                    parameter_word = trained_parameter_mem[parameter_index];
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Sparse 128-bit line store for frame/tensor writes
    // ------------------------------------------------------------------
    logic mem_valid [0:MEM_SLOTS-1];
    logic [31:0] mem_tag [0:MEM_SLOTS-1];
    logic [127:0] mem_line [0:MEM_SLOTS-1];
    // Native mode uses the full AXI line address as the key.  This remains a
    // testbench-only data structure and grows only for lines actually touched
    // by the run; it avoids the 32K modulo-hash collision limit.
    logic [127:0] mem_line_assoc [longint unsigned];
`ifdef C1_NUMERICAL_TRACE
    // Only AXI WSTRB commits establish byte coverage, never logical requests.
    localparam integer NUMERIC_FRAME_LINES=3*FRAME_SLOT_BYTES/16;
    logic [15:0] numeric_frame_written [0:NUMERIC_FRAME_LINES-1];
    initial begin
        for(integer n=0;n<NUMERIC_FRAME_LINES;n=n+1) numeric_frame_written[n]=0;
`ifdef C1_COLOR_FIXTURE
        $display("C1_NUM_FIXTURE color_rggb");
`else
        $display("C1_NUM_FIXTURE gray");
`endif
    end
`endif

    function automatic integer line_index(input logic [31:0] addr);
        // Mix the high address bits before the bounded sparse-store index.
        // INPUT/OUTPUT/TENSOR bases are intentionally far apart but share
        // low modulo bits; direct mapping would make a two-frame ownership
        // test look like an overwrite even when the AXI address is correct.
        line_index = ((addr[31:4] ^ (addr[31:4] >> 13) ^
                       (addr[31:4] >> 26)) % MEM_SLOTS);
    endfunction

    function automatic [127:0] read_beat(input logic [31:0] addr);
        logic [127:0] value;
        logic [511:0] descriptor_value;
        longint unsigned assoc_key;
        integer di, beat, idx, table_idx;
        begin
            value='0;
            assoc_key = addr[31:4];
            if ((addr >= DESC_BASE) && (addr < DESC_BASE + 32'd1408)) begin
                di=(addr-DESC_BASE)>>6; beat=((addr-DESC_BASE)>>4)&3;
                if (TRAINED_ARTIFACT_CFG && (di >= 0) && (di < 22))
                    descriptor_value=trained_descriptors[di];
                else
                    descriptor_value=make_descriptor(di);
                case (beat)
                    0: value=descriptor_value[127:0];
                    1: value=descriptor_value[255:128];
                    2: value=descriptor_value[383:256];
                    default: value=descriptor_value[511:384];
                endcase
            end else if ((addr >= IN_TABLE) && (addr < IN_TABLE+32'd64)) begin
                table_idx=(addr-IN_TABLE)>>4;
                value=table_entry(INPUT_BASE,table_idx);
            end else if ((addr >= OUT_TABLE) && (addr < OUT_TABLE+32'd64)) begin
                table_idx=(addr-OUT_TABLE)>>4;
                value=table_entry(OUTPUT_BASE,table_idx);
            end else if ((addr >= WEIGHT_BASE) &&
                         (addr < WEIGHT_BASE+32'd16896)) begin
                value=parameter_word(addr);
            end else begin
                if (USE_ASSOC_MEM) begin
                    if (mem_line_assoc.exists(assoc_key))
                        value=mem_line_assoc[assoc_key];
                    else begin
                        if(TRAINED_ARTIFACT_CFG)
                            $fatal(1,"trained DDR read of unwritten line addr=%08x",addr);
                        value={32'hc1dd_0000,addr,addr+32'd16,addr+32'd32};
                    end
                end else begin
                    idx=line_index(addr);
                    if (mem_valid[idx] && (mem_tag[idx] == addr[31:4]))
                        value=mem_line[idx];
                    else
                        value={32'hc1dd_0000,addr,addr+32'd16,addr+32'd32};
                end
            end
            read_beat=value;
        end
    endfunction

`ifdef C1_PREVIEW_CAPTURE
    logic [31:0] preview_expected [0:63];
    logic [31:0] preview_accepted_base,preview_completed_base;
`ifdef C1_PREVIEW_BRESP_RECOVERY
    logic preview_trace_enable=0;
`elsif C1_PREVIEW_CANCEL_RECOVERY
    logic preview_trace_enable=0;
`else
    logic preview_trace_enable=1;
`endif
    logic [511:0] preview_written='0;
    integer preview_pixels=0,preview_aw=0,preview_w=0,preview_b=0;
    always @(posedge core_clk) begin
        if(!dut.core_rst) begin
            if(dut.boardless_start_valid && dut.boardless_start_ready) begin
`ifdef C1_TWO_FRAME_TRACE
                if(dut.boardless_output_index==1 && (preview_aw!=8 || preview_w!=16 || preview_b!=8 || preview_pixels!=64))
                    $fatal(1,"first preview accounting incomplete before second admission");
                preview_pixels<=0;preview_aw<=0;preview_w<=0;preview_b<=0;
`endif
                if(dut.boardless_output_index>1 || dut.preview_job_base!==
                   (32'h0100_0000+32'(dut.boardless_output_index)*32'h100))
                    $fatal(1,"preview slot does not match processed slot index");
                preview_accepted_base<=dut.preview_job_base;
                if(preview_trace_enable)
                    $display("C1_NUM_PREVIEW_ADMIT base=%08h slot=%0d",dut.preview_job_base,dut.boardless_output_index);
            end
            if(dut.board_cnn_in_valid && dut.board_cnn_in_ready) begin
                if(dut.board_cnn_in_x>=8 || dut.board_cnn_in_y>=8) $fatal(1,"preview source geometry");
                preview_expected[dut.board_cnn_in_y*8+dut.board_cnn_in_x]<=
                    {8'h00,dut.board_cnn_in_data[7:0]^8'h80,
                     dut.board_cnn_in_data[15:8]^8'h80,dut.board_cnn_in_data[23:16]^8'h80};
                preview_pixels<=preview_pixels+1;
            end
            if(dut.preview_awvalid&&dut.preview_awready) preview_aw<=preview_aw+1;
            if(dut.preview_wvalid&&dut.preview_wready) preview_w<=preview_w+1;
            if(dut.preview_bvalid&&dut.preview_bready) preview_b<=preview_b+1;
            if(dut.boardless_done && (preview_b!=8 || preview_pixels!=64))
                $fatal(1,"preview not retired at boardless done");
            if(dut.boardless_done) preview_completed_base<=preview_accepted_base;
        end
    end
`endif
    task automatic store_beat(
        input logic [31:0] addr,
        input logic [127:0] data,
        input logic [15:0] strb
    );
        longint unsigned assoc_key;
        integer idx, lane;
        begin
            assoc_key = addr[31:4];
`ifdef C1_PREVIEW_CAPTURE
            if(addr>=32'h0100_0000 && addr<32'h0100_0200)
                preview_written[(addr-32'h0100_0000) +: 16] =
                    preview_written[(addr-32'h0100_0000) +: 16] | strb;
`endif
`ifdef C1_TWO_FRAME_TRACE
            if(addr>=OUTPUT_BASE && addr<OUTPUT_BASE+2*FRAME_SLOT_BYTES)
                two_written[(addr-OUTPUT_BASE) +: 16] = two_written[(addr-OUTPUT_BASE) +: 16] | strb;
`endif
`ifdef C1_NUMERICAL_TRACE
            if(addr>=OUTPUT_BASE && addr<OUTPUT_BASE+3*FRAME_SLOT_BYTES)
                numeric_frame_written[(addr-OUTPUT_BASE)>>4] =
                    numeric_frame_written[(addr-OUTPUT_BASE)>>4] | strb;
`endif
            if (USE_ASSOC_MEM) begin
                if (!mem_line_assoc.exists(assoc_key))
                    mem_line_assoc[assoc_key]='0;
                for (lane=0; lane<16; lane=lane+1)
                    if (strb[lane])
                        mem_line_assoc[assoc_key][lane*8 +: 8]=
                            data[lane*8 +: 8];
            end else begin
                idx=line_index(addr);
                if (!mem_valid[idx] || (mem_tag[idx] != addr[31:4])) begin
                    mem_valid[idx]=1'b1;
                    mem_tag[idx]=addr[31:4];
                    mem_line[idx]='0;
                end
                for (lane=0; lane<16; lane=lane+1)
                    if (strb[lane]) mem_line[idx][lane*8 +: 8]=data[lane*8 +: 8];
            end
        end
    endtask

    // ------------------------------------------------------------------
    // AXI128 slave BFM: independent channel stalls and held responses
    // ------------------------------------------------------------------
    integer cycle_count=0;
    integer axi_aw_count=0, axi_w_count=0, axi_b_count=0;
    integer axi_ar_count=0, axi_r_count=0;
    integer trained_weight_ar_count=0;
    integer aw_stall_count=0, w_stall_count=0, ar_stall_count=0;
    integer r_stall_count=0, fabric_r_stall_count=0, b_stall_count=0;
    integer r_gap_count=0, b_gap_count=0;
    logic aw_active=1'b0, b_pending=1'b0, bvalid_q=1'b0;
    logic [31:0] aw_base_q=32'd0;
    logic [7:0] aw_len_q=8'd0;
    integer w_index_q=0, b_delay_q=0;
    // Separate AW/W/B cursors. Eight slave slots exceed the fabric depth four;
    // an accepted AW slot is retained until its own ordered B handshake.
    logic [31:0] queued_aw_base[0:7];
    logic [7:0] queued_aw_len[0:7];
    integer queued_b_ready_cycle[0:7];
    integer queued_w_completed=0,queued_max_outstanding=0,queued_w_ahead_beats=0;
`ifdef C1_CONCURRENT_CAPTURE
    localparam bit CONCURRENT_CAPTURE_CFG=1;
`else
    localparam bit CONCURRENT_CAPTURE_CFG=0;
`endif
    integer capture_starts=0,capture_aw_while_compute=0;
`ifdef C1_SERIALIZE_WRITE_DATA
    localparam bit SERIALIZE_WRITE_DATA_CFG=1;
    initial $display("C1_NUM_WRITE_MODE serial");
`else
    localparam bit SERIALIZE_WRITE_DATA_CFG=0;
    initial if(QUEUED_WRITE_CFG) $display("C1_NUM_WRITE_MODE ahead");
`endif
    // Slave-side response latency control; never withdraw a presented BVALID.
    logic hold_queued_b=0;
`ifdef C1_PREVIEW_CANCEL
    logic preview_cancel_hold=1;
    integer preview_aborted_count=0;
    wire preview_cancel_head=(queued_aw_base[axi_b_count%8]==32'h010000e0);
    always @(posedge core_clk) if(!dut.core_rst && dut.boardless_aborted)
        preview_aborted_count<=preview_aborted_count+1;
`endif
`ifdef C1_PREVIEW_BRESP_ERROR
    integer preview_fault_responses=0,preview_fault_hold=0;
    logic preview_fault_cnn_pending=0;
    // Only the last row of preview slot 0 receives SLVERR. The selected
    // response and payload remain stable until the physical B handshake.
    wire preview_fault_head=(queued_aw_base[axi_b_count%8]==32'h0100_00e0) && preview_fault_responses==0;
    always @(posedge core_clk) if(!dut.core_rst) begin
        if(bvalid&&bready&&bresp==2) begin
            preview_fault_responses<=preview_fault_responses+1;
            preview_fault_cnn_pending<=dut.board_cnn_in_valid&&!dut.board_cnn_in_ready;
        end
        if(queued_w_completed>axi_b_count && preview_fault_head && !bvalid_q &&
           cycle_count<queued_b_ready_cycle[axi_b_count%8]) begin
            preview_fault_hold<=preview_fault_hold+1;
            if(!dut.boardless_busy || !system_busy || dut.boardless_done || dut.control_done_event)
                $fatal(1,"preview late B escaped joint retirement fence");
        end
    end
`endif
    logic hold_read_response=0;
`ifdef C1_INFLIGHT_READ_ABORT
    localparam bit READ_ABORT_CFG=1;
`else
    localparam bit READ_ABORT_CFG=0;
`endif
`ifdef C1_SCALAR_READ_ABORT
    localparam bit SCALAR_READ_ABORT_CFG=1;
    initial $display("C1_NUM_READ_ABORT_TARGET scalar");
`else
    localparam bit SCALAR_READ_ABORT_CFG=0;
`endif
`ifdef C1_SCALAR_ASSOC_READ_ABORT
    localparam bit SCALAR_ASSOC_ABORT_CFG=1;
`else
    localparam bit SCALAR_ASSOC_ABORT_CFG=0;
`endif
`ifdef C1_POINTWISE_REDUCTION_READ_ABORT
    localparam bit PW_REDUCTION_ABORT_CFG=1;
`else
    localparam bit PW_REDUCTION_ABORT_CFG=0;
`endif
    wire [3:0] read_abort_owner_target=(SCALAR_READ_ABORT_CFG || PW_REDUCTION_ABORT_CFG) ? 6 :
        (`C1_COLUMN_SOC_ENABLE ? dut.AXI_CLIENT_COLUMN : 6);
    wire scalar_cache_fill_allowed, scalar_cache_valid;
    wire [7:0] scalar_pending_count;
`ifdef C1_TENSOR_COLUMN_READS
    assign scalar_pending_count=dut.g_tensor_column_reads.scalar_pending_q;
    generate if(1) begin : g_scalar_assoc_probe
        wire read_fire=dut.g_tensor_column_reads.u_scalar.mem_req_valid &&
                       dut.g_tensor_column_reads.u_scalar.mem_req_ready &&
                       !dut.g_tensor_column_reads.u_scalar.mem_req_write;
        wire rsp_fire=dut.g_tensor_column_reads.u_scalar.mem_rsp_valid &&
                      dut.g_tensor_column_reads.u_scalar.mem_rsp_ready;
        wire ar_fire=dut.g_tensor_column_reads.u_scalar.m_axi_arvalid &&
                     dut.g_tensor_column_reads.u_scalar.m_axi_arready;
        wire r_fire=dut.g_tensor_column_reads.u_scalar.m_axi_rvalid &&
                    dut.g_tensor_column_reads.u_scalar.m_axi_rready;
        wire hit;
`ifdef C1_TENSOR_PACKED_WRITES
        assign hit=dut.g_tensor_column_reads.u_scalar.g_packed.u_read.read_beat_hit;
        wire [31:0] actual_entries=dut.g_tensor_column_reads.u_scalar.g_packed.u_read.READ_BEAT_CACHE_ENTRIES;
`else
        assign hit=dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.read_beat_hit;
        wire [31:0] actual_entries=dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.READ_BEAT_CACHE_ENTRIES;
`endif
        integer job=0,reads=0,hits=0,ars=0,beats=0,responses=0,owner=0;
        bit active=0;
`ifdef C1_NUMERICAL_TRACE
        integer stage_reads[0:21],stage_hits[0:21],stage_ars[0:21],stage_beats[0:21];
        integer stage;
`endif
        initial begin
            #1;
            if(actual_entries!=dut.TENSOR_SCALAR_READ_CACHE_ENTRIES)
                $fatal(1,"scalar cache entries did not reach actual read bridge");
            $display("C1_NUM_SCALAR_ASSOC version=1 enabled=%0d entries=%0d precise=%0d",
                     dut.TENSOR_SCALAR_READ_BEAT_CACHE,actual_entries,dut.TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION);
        end
        always @(posedge core_clk) begin
            if(dut.core_rst) begin active=0;job=0;owner=0;end
            else if(dut.boardless_abort) begin active=0;owner=0;end
            else if(dut.qos_frame_start_event) begin
                if(active) $fatal(1,"overlapping scalar cache performance jobs");
                active=1;job++;reads=0;hits=0;ars=0;beats=0;responses=0;owner=0;
`ifdef C1_NUMERICAL_TRACE
                for(integer n=0;n<22;n++) begin
                    stage_reads[n]=0;stage_hits[n]=0;stage_ars[n]=0;stage_beats[n]=0;
                end
`endif
            end else if(active) begin
                if(rsp_fire && owner!=0) begin responses++;owner--;end
                if(read_fire) begin
                    if(owner!=0) $fatal(1,"scalar cache duplicated physical read ownership");
                    reads++;owner++;if(hit) hits++;
                end
                if(ar_fire) ars++;
                if(r_fire) beats++;
`ifdef C1_NUMERICAL_TRACE
                stage=int'(dut.u_tensor_adapter.stage_index_q);
                if(stage>=0 && stage<22) begin
                    if(read_fire) begin stage_reads[stage]++;if(hit) stage_hits[stage]++;end
                    if(ar_fire) stage_ars[stage]++;
                    if(r_fire) stage_beats[stage]++;
                end
`endif
                if(dut.control_done_event) begin
                    if(owner!=0 || reads!=responses || reads!=hits+ars || ars!=beats)
                        $fatal(1,"scalar cache actual request/hit/AR/R retirement disagrees");
                    $display("C1_PERF_SCALAR_ASSOC job=%0d reads=%0d responses=%0d hits=%0d ar=%0d beats=%0d",
                             job,reads,responses,hits,ars,beats);
`ifdef C1_NUMERICAL_TRACE
                    for(integer n=0;n<22;n++)
                        $display("C1_PERF_SCALAR_ASSOC_STAGE job=%0d stage=%0d reads=%0d hits=%0d ar=%0d beats=%0d",
                                 job,n,stage_reads[n],stage_hits[n],stage_ars[n],stage_beats[n]);
`endif
                    active=0;
                end
            end
        end
    end endgenerate
`ifdef C1_TENSOR_PACKED_WRITES
    assign scalar_cache_fill_allowed=dut.g_tensor_column_reads.u_scalar.g_packed.u_read.read_fill_allowed_q;
    assign scalar_cache_valid=|dut.g_tensor_column_reads.u_scalar.g_packed.u_read.read_beat_valid_q;
`else
    assign scalar_cache_fill_allowed=dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.read_fill_allowed_q;
    assign scalar_cache_valid=|dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.read_beat_valid_q;
`endif
`else
    assign scalar_cache_fill_allowed=1'b0;
    assign scalar_cache_valid=1'b0;
    assign scalar_pending_count=8'd0;
`endif
    always @(posedge core_clk) if(arst_n) begin
        if(dut.capture_writer_start) capture_starts<=capture_starts+1;
        if(dut.axi_s_awvalid[1] && dut.axi_s_awready[1] && dut.boardless_busy)
            capture_aw_while_compute<=capture_aw_while_compute+1;
    end
    logic r_active=1'b0, rvalid_q=1'b0;
    logic [31:0] ar_base_q=32'd0;
    logic [7:0] ar_len_q=8'd0;
    integer r_index_q=0, r_delay_q=0;
    integer r_wait_start_q=0;
    integer first_latency_min=2147483647, first_latency_max=0, first_events=0;
    integer beat_latency_min=2147483647, beat_latency_max=0, beat_events=0;
    logic [127:0] rdata_q=128'd0;
    logic rlast_q=1'b0;
    integer done_seen=0;
`ifdef C1_DISPLAY_FAULT_RECOVERY
    logic fault_reserved_q=0, fault_burst_q=0;
    logic [1:0] fault_rresp_q=0;
    integer injected_faults=0;
`endif
    always_comb begin
        awready = !aw_active && !b_pending && !bvalid_q &&
                  ((cycle_count % 7) != 0);
        wready = aw_active && !b_pending && !bvalid_q &&
                 ((cycle_count % 5) != 0);
        if(QUEUED_WRITE_CFG) begin
            awready=(axi_aw_count-axi_b_count<8) && ((cycle_count%7)!=0);
            wready=(axi_aw_count>queued_w_completed) && ((cycle_count%5)!=0);
        end
        arready = !r_active && !rvalid_q && ((cycle_count % 6) != 0);
        bvalid = bvalid_q;
        bresp = 2'b00;
`ifdef C1_PREVIEW_BRESP_ERROR
        if(preview_fault_head) bresp=2'b10;
`endif
        rvalid = rvalid_q;
        rdata = rdata_q;
        rresp = 2'b00;
`ifdef C1_DISPLAY_FAULT_RECOVERY
        rresp = fault_rresp_q;
`endif
        rlast = rlast_q;
    end

    always @(posedge core_clk) begin : axi_bfm_proc
        integer write_addr;
        if (!arst_n) begin
            cycle_count <= 0;
            aw_active <= 1'b0; b_pending <= 1'b0; bvalid_q <= 1'b0;
            r_active <= 1'b0; rvalid_q <= 1'b0;
            w_index_q <= 0; r_index_q <= 0;
            b_delay_q <= 0; r_delay_q <= 0;
            r_wait_start_q<=0;
            first_latency_min<=2147483647;first_latency_max<=0;first_events<=0;
            beat_latency_min<=2147483647;beat_latency_max<=0;beat_events<=0;
            axi_aw_count <= 0; axi_w_count <= 0; axi_b_count <= 0;
            queued_w_completed<=0;queued_max_outstanding<=0;queued_w_ahead_beats<=0;
            axi_ar_count <= 0; axi_r_count <= 0;
            trained_weight_ar_count <= 0;
            aw_stall_count <= 0; w_stall_count <= 0; ar_stall_count <= 0;
            r_stall_count <= 0; fabric_r_stall_count <= 0;
            b_stall_count <= 0;
            r_gap_count <= 0; b_gap_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (awvalid && !awready) aw_stall_count <= aw_stall_count + 1;
            if (wvalid && !wready) w_stall_count <= w_stall_count + 1;
            if (arvalid && !arready) ar_stall_count <= ar_stall_count + 1;
            if (rvalid_q && !rready) r_stall_count <= r_stall_count + 1;
            // A registered fabric response boundary can absorb all DDR-side
            // R stalls while still exercising backpressure at the selected
            // client.  Count both boundaries so the stress requirement is
            // preserved instead of being weakened for the skid build.
            if (|(dut.axi_s_rvalid & ~dut.axi_s_rready))
                fabric_r_stall_count <= fabric_r_stall_count + 1;
            if (bvalid_q && !bready) b_stall_count <= b_stall_count + 1;

            if(QUEUED_WRITE_CFG) begin
                if(dut.fabric_write_protocol_error)
                    $fatal(1,"queued fabric protocol error during numerical job");
                if(axi_aw_count-axi_b_count>queued_max_outstanding)
                    queued_max_outstanding<=axi_aw_count-axi_b_count;
                if(awvalid&&awready) begin
                    if(awsize!==4 || awburst!==1 || awaddr[3:0]!=0 ||
                       ({1'b0,awaddr[11:0]}+((int'(awlen)+1)*16)>4096))
                        $fatal(1,"queued SoC malformed AW/boundary");
                    queued_aw_base[axi_aw_count%8]<=awaddr;
                    queued_aw_len[axi_aw_count%8]<=awlen;
                    axi_aw_count<=axi_aw_count+1;
                end
                if(wvalid&&wready) begin
                    if(wlast!==(w_index_q==queued_aw_len[queued_w_completed%8]))
                        $fatal(1,"queued SoC WLAST mismatch");
                    write_addr=queued_aw_base[queued_w_completed%8]+w_index_q*16;
                    store_beat(write_addr,wdata,wstrb);
                    axi_w_count<=axi_w_count+1;
                    if(queued_w_completed>axi_b_count) queued_w_ahead_beats<=queued_w_ahead_beats+1;
                    if(wlast) begin
                        queued_b_ready_cycle[queued_w_completed%8]<=cycle_count+
                            (CONCURRENT_CAPTURE_CFG ? 32 : 3)+(cycle_count%3)+WRITE_RESPONSE_EXTRA
`ifdef C1_PREVIEW_BRESP_ERROR
                            + (queued_aw_base[queued_w_completed%8]==32'h0100_00e0 && preview_fault_responses==0 ? 64 : 0)
`endif
                            ;
                        queued_w_completed<=queued_w_completed+1;
                        w_index_q<=0;
                    end else w_index_q<=w_index_q+1;
                end
                if(!bvalid_q && queued_w_completed>axi_b_count) begin
                    if(!hold_queued_b && cycle_count>=queued_b_ready_cycle[axi_b_count%8]
`ifdef C1_PREVIEW_CANCEL
                       && !(preview_cancel_hold && preview_cancel_head)
`endif
                    ) bvalid_q<=1;
                    else b_gap_count<=b_gap_count+1;
                end
                if(bvalid_q&&bready) begin bvalid_q<=0;axi_b_count<=axi_b_count+1;end
                // Keep existing end-of-test drain observations meaningful.
                aw_active <= (axi_aw_count+int'(awvalid&&awready) !=
                              queued_w_completed+int'(wvalid&&wready&&wlast));
                b_pending <= (queued_w_completed+int'(wvalid&&wready&&wlast) !=
                              axi_b_count+int'(bvalid_q&&bready));
            end else begin
            if (awvalid && awready) begin
                if ((awsize !== 3'd4) || (awburst !== 2'b01))
                    $fatal(1,"portable SoC emitted malformed AW");
                aw_active <= 1'b1;
                aw_base_q <= awaddr;
                aw_len_q <= awlen;
                w_index_q <= 0;
                axi_aw_count <= axi_aw_count + 1;
            end

            if (wvalid && wready) begin
                if (!aw_active) $fatal(1,"W accepted without AW");
                if (wlast !== (w_index_q == aw_len_q))
                    $fatal(1,"W.last mismatch addr=%08x beat=%0d len=%0d",
                           aw_base_q,w_index_q,aw_len_q);
                write_addr = aw_base_q + (w_index_q * 16);
                store_beat(write_addr,wdata,wstrb);
                axi_w_count <= axi_w_count + 1;
                if (wlast) begin
                    aw_active <= 1'b0;
                    b_pending <= 1'b1;
                    b_delay_q <= 2 + (cycle_count % 3) + WRITE_RESPONSE_EXTRA;
                end else begin
                    w_index_q <= w_index_q + 1;
                end
            end

            if (b_pending && !bvalid_q) begin
                if (b_delay_q > 0) begin
                    b_delay_q <= b_delay_q - 1;
                    b_gap_count <= b_gap_count + 1;
                end else begin
                    bvalid_q <= 1'b1;
                end
            end
            if (bvalid_q && bready) begin
                bvalid_q <= 1'b0;
                b_pending <= 1'b0;
                axi_b_count <= axi_b_count + 1;
            end

            end
            if (arvalid && arready) begin
                if ((arsize !== 3'd4) || (arburst !== 2'b01))
                    $fatal(1,"portable SoC emitted malformed AR");
                if (TRAINED_ARTIFACT_CFG &&
                    (araddr >= WEIGHT_BASE) &&
                    (araddr < (WEIGHT_BASE + 32'd16896)))
                    trained_weight_ar_count <= trained_weight_ar_count + 1;
                r_active <= 1'b1;
`ifdef C1_DISPLAY_FAULT_RECOVERY
                // After compute completion, the next input-frame read is
                // display prefetch. Select on accepted DDR address, then
                // register RRESP with the response so skid/backpressure is safe.
                fault_burst_q <= !fault_reserved_q && done_seen>0 &&
                    araddr>=INPUT_BASE && araddr<INPUT_BASE+3*INPUT_SLOT_BYTES;
                if (!fault_reserved_q && done_seen>0 &&
                    araddr>=INPUT_BASE && araddr<INPUT_BASE+3*INPUT_SLOT_BYTES)
                    fault_reserved_q<=1;
`endif
                ar_base_q <= araddr;
                ar_len_q <= arlen;
                r_index_q <= 0;
                r_delay_q <= 1 + (cycle_count % 3) + READ_FIRST_EXTRA;
                r_wait_start_q <= cycle_count;
                axi_ar_count <= axi_ar_count + 1;
            end

            if (r_active && !rvalid_q) begin
                if (r_delay_q > 0) begin
                    r_delay_q <= r_delay_q - 1;
                    r_gap_count <= r_gap_count + 1;
                end else if(!hold_read_response) begin
                    // Count until response presentation, not retirement:
                    // downstream RREADY stalls must not look like DDR latency.
                    if(r_index_q==0) begin
                        first_events<=first_events+1;
                        if(cycle_count-r_wait_start_q < 2+READ_FIRST_EXTRA)
                            $fatal(1,"BFM first read response appeared too early");
                        if(cycle_count-r_wait_start_q<first_latency_min)
                            first_latency_min<=cycle_count-r_wait_start_q;
                        if(cycle_count-r_wait_start_q>first_latency_max)
                            first_latency_max<=cycle_count-r_wait_start_q;
                    end else begin
                        beat_events<=beat_events+1;
                        if(cycle_count-r_wait_start_q < 2+READ_BEAT_EXTRA)
                            $fatal(1,"BFM following read beat appeared too early");
                        if(cycle_count-r_wait_start_q<beat_latency_min)
                            beat_latency_min<=cycle_count-r_wait_start_q;
                        if(cycle_count-r_wait_start_q>beat_latency_max)
                            beat_latency_max<=cycle_count-r_wait_start_q;
                    end
                    rdata_q <= read_beat(ar_base_q + (r_index_q * 16));
                    rlast_q <= (r_index_q == ar_len_q);
                    rvalid_q <= 1'b1;
`ifdef C1_DISPLAY_FAULT_RECOVERY
                    fault_rresp_q <= (fault_burst_q && r_index_q==0) ? 2'b10 : 2'b00;
`endif
                end
            end
            if (rvalid_q && rready) begin
`ifdef C1_DISPLAY_FAULT_RECOVERY
                if (fault_rresp_q!=0) injected_faults<=injected_faults+1;
`endif
                rvalid_q <= 1'b0;
                axi_r_count <= axi_r_count + 1;
                if (rlast_q) begin
                    r_active <= 1'b0;
                end else begin
                    r_index_q <= r_index_q + 1;
                    r_delay_q <= 1 + ((cycle_count + r_index_q) % 2) + READ_BEAT_EXTRA;
                    r_wait_start_q <= cycle_count;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // APB and camera stimulus
    // ------------------------------------------------------------------
    task automatic apb_write(input logic [11:0] address,
                              input logic [31:0] data,
                              input bit expect_error=0);
        begin
            @(negedge core_clk);
            psel<=1'b1; penable<=1'b0; pwrite<=1'b1;
            paddr<=address; pwdata<=data; pstrb<=4'hf;
            @(negedge core_clk); penable<=1'b1;
            // APB completes at the rising edge, before sequential state updates.
            // Sampling at the following falling edge sees the command's own
            // newly-set pending flag and can falsely report a busy error.
            do @(posedge core_clk); while (!pready);
            if (pslverr !== expect_error)
                $fatal(1,"APB write error addr=%03x actual=%b expected=%b",address,pslverr,expect_error);
            @(negedge core_clk);
            psel<=1'b0; penable<=1'b0; pwrite<=1'b0;
            paddr<=12'd0; pwdata<=32'd0; pstrb<=4'd0;
        end
    endtask

    task automatic apb_read(input logic [11:0] address,
                             output logic [31:0] data);
        begin
            @(negedge core_clk);
            psel<=1'b1; penable<=1'b0; pwrite<=1'b0; paddr<=address;
            @(negedge core_clk); penable<=1'b1;
            do @(posedge core_clk); while (!pready);
            data=prdata;
            if (pslverr) $fatal(1,"APB read error addr=%03x",address);
            @(negedge core_clk);
            psel<=1'b0; penable<=1'b0; paddr<=12'd0;
        end
    endtask

    task automatic send_camera_frame(input logic [9:0] tone_offset);
        integer x,y;
        begin : source_frame
            for (y=0; y<SENSOR_H; y=y+1) begin
                for (x=0; x<SENSOR_W; x=x+1) begin
                    @(negedge camera_clk);
                    if(RAW_FAULT_CFG && tone_offset==10'h055 &&
                       x==0 && y==SENSOR_H/2) begin
                        camera_valid<=0;
                        while(!release_raw_fault) @(negedge camera_clk);
                        if(RAW_IDLE_CFG) begin
                            // Hold the actual source silent until the hardware
                            // watchdog, not a testbench error force, fires.
                            while(error_seen==0) @(negedge camera_clk);
                            // Permanent stop: no tail/EOF/maintenance frame.
                            if(EXPLICIT_RECOVERY_CFG) disable source_frame;
                        end
                    end
                    camera_valid<=1'b1;
                    camera_x<=x[CAM_X_W-1:0]; camera_y<=y[CAM_Y_W-1:0];
                    if(RAW_FAULT_CFG && !RAW_MISSING_EOF_CFG && !RAW_IDLE_CFG && tone_offset==10'h055 &&
                       x==0 && y==SENSOR_H/2) camera_x<=1;
`ifdef C1_COLOR_FIXTURE
                    // RGGB: three parallel linear planes, with distinct
                    // offsets. RAW10 wraps modulo 1024 for larger frames;
                    // the golden must interpolate the actual wrapped CFA,
                    // not assume the centre-plane shortcut remains valid.
                    camera_raw10<=((x*17)+(y*29)+64+tone_offset+
                        (((x%2)==0 && (y%2)==0) ? 96 :
                         (((x%2)==1 && (y%2)==1) ? 0 : 40))) & 10'h3ff;
`else
                    camera_raw10<=((x*17)+(y*29)+10'h40+tone_offset) & 10'h3ff;
`endif
                    camera_sof<=(x==0)&&(y==0);
                    camera_eol<=(x==SENSOR_W-1);
                    camera_eof<=(x==SENSOR_W-1)&&(y==SENSOR_H-1);
                    if(RAW_MISSING_EOF_CFG && tone_offset==10'h055) camera_eof<=0;
                    do @(posedge camera_clk); while (!camera_ready);
                end
            end
            @(negedge camera_clk);
            camera_valid<=1'b0; camera_sof<=1'b0;
            camera_eol<=1'b0; camera_eof<=1'b0;
        end
    endtask

    // Test-only, cycle-domain attribution. The four adapter input bins are
    // mutually exclusive while bridge_busy; memory/result counters overlap
    // those bins and MUST NOT be added to obtain total latency or MAC duty.
    // Interval excludes the start edge and includes the completion edge.
    longint unsigned perf_cycle=0, perf_start=0, perf_job=0;
    longint unsigned perf_adapter_cycles[0:31];
    longint unsigned perf_tap_prepared, perf_tap_fallback;
    longint unsigned perf_reuse_stride1, perf_reuse_stride2, perf_reuse_saved;
    longint unsigned perf_adapter_input_wait[0:31];
    longint unsigned perf_adapter_result_stall[0:31];
    longint unsigned perf_hist_total,perf_hist_input,perf_hist_result;
    integer perf_state,perf_bin;
`ifdef C1_NUMERICAL_TRACE
    // Residency is charged to the adapter stage index, so stage 0 includes
    // job startup/descriptor overhead. Dot/DW counts are actual handshakes,
    // not estimates from nominal MAC lanes or enabled optimization flags.
    integer perf_stage,perf_fsm_bin;
    longint unsigned perf_stage_cycles[0:21], perf_stage_dot[0:21], perf_stage_dw[0:21];
    longint unsigned perf_stage_read[0:21], perf_stage_write[0:21], perf_stage_column[0:21];
    longint unsigned perf_stage_total, perf_stage_read_total, perf_stage_write_total, perf_stage_column_total;
    // Stage0 also includes the RGB source-copy/startup phase. Charge every
    // cycle to both actual FSMs before calling its whole residency a MAC cost.
    longint unsigned perf_stage0_engine[0:31],perf_stage0_adapter[0:31];
    longint unsigned perf_stage0_engine_total,perf_stage0_adapter_total;
    // Simulation-only per-layer attribution. Each FSM independently covers
    // the SAME adapter-stage residency; setup is not mislabeled MAC work.
    longint unsigned perf_stage_engine[0:21][0:31],perf_stage_adapter[0:21][0:31];
    longint unsigned perf_stage_engine_total,perf_stage_adapter_total;
    initial $display("C1_NUM_STAGE_PERF version=1 includes_setup=1");
    initial $display("C1_NUM_STAGE_FSM version=1 includes_setup=1 stage_source=adapter");
`ifdef C1_TENSOR_COLUMN_READS
    longint unsigned perf_column_state[0:21][0:6],perf_column_refills[0:21],perf_column_words[0:21];
    longint unsigned perf_column_state_total;
    initial $display("C1_NUM_COLUMN_STAGE version=1 includes_setup=1 stage_source=adapter");
`endif
`endif
    longint unsigned perf_bridge=0, perf_feed=0, perf_input_wait=0;
    longint unsigned perf_engine_hold=0, perf_neither=0;
    longint unsigned perf_mem_read=0, perf_mem_write=0;
    longint unsigned perf_columns=0,perf_column_responses=0;
    longint unsigned perf_dw_stream=0,perf_dw_adjacent=0;
    longint unsigned perf_pw_stream=0,perf_pw_early=0;
    longint unsigned perf_rgb_beats=0,perf_rgb_tails=0;
    longint unsigned perf_view_commits=0;
    bit perf_view_context_seen=0;
    longint unsigned perf_rq_starts=0,perf_rq_outputs=0,perf_rq_early=0,perf_rq_peak=0;
    integer perf_rq_pending=0;
    longint unsigned perf_pixel_starts=0,perf_pixel_outputs=0,perf_pixel_inputs_ahead=0,perf_pixel_starts_ahead=0;
    longint unsigned perf_pixel_writes=0,perf_pixel_responses=0,perf_pixel_peak=0,perf_pixel_ends=0;
    longint unsigned perf_dw_pixel_inputs=0,perf_dw_pixel_feeds=0,perf_dw_pixel_outputs=0;
    longint unsigned perf_dw_pixel_writes=0,perf_dw_pixel_responses=0,perf_dw_pixel_ends=0;
    longint unsigned perf_dw_pixel_ahead=0,perf_dw_pixel_warm=0,perf_dw_pixel_peak=0;
    longint unsigned perf_dw_frame_cold=0,perf_dw_frame_warm=0,perf_dw_frame_continue=0;
    longint unsigned perf_dw_frame_in_eof=0,perf_dw_frame_out_eof=0,perf_dw_frame_held=0;
    longint unsigned perf_column_overlap=0,perf_write_peak=0;
    wire [4:0] perf_active_write_debt = dut.u_tensor_adapter.pixel_stream_q ?
        {1'b0,dut.u_tensor_adapter.u_pixel_writer.pending_q} :
        {1'b0,dut.u_tensor_adapter.result_writes_pending_q};
    longint unsigned perf_pointwise_columns=0;
    longint unsigned perf_column_bypass=0;
    longint unsigned perf_fused_inputs=0,perf_fused_outputs=0,perf_fused_commits=0,perf_fused_eofs=0;
    longint unsigned perf_fused_starts=0,perf_fused_dot_outputs=0,perf_fused_inputs_ahead=0,perf_fused_starts_ahead=0;
    bit perf_fused_context_seen=0;
    longint unsigned perf_map_accept=0,perf_map_reused=0,perf_map_eligible=0,perf_map_ram=0;
    bit perf_map_previous_good=0;
    logic signed [16:0] perf_map_request_y=0,perf_map_previous_y=0;
`ifdef C1_TENSOR_COLUMN_READS
    wire perf_map_fire=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_valid &&
        dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_ready;
    wire perf_map_reuse_fire=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.reuse_row_fire;
    wire perf_map_rsp_fire=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_rsp_valid &&
        dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_rsp_ready;
    wire perf_map_config_fire=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.group_start_valid &&
        dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.group_start_ready;
    wire perf_map_maintenance=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.maintenance;
    wire signed [16:0] perf_map_y=dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_y;
`endif
    longint unsigned perf_pixel_pf_req=0,perf_pixel_pf_rsp=0,perf_pixel_pf_take=0,perf_pixel_pf_early=0;
    longint unsigned perf_source_accept=0,perf_source_req=0,perf_source_rsp=0;
    longint unsigned perf_source_end=0,perf_source_peak=0,perf_source_wait=0;
    integer perf_source_debt=0;
    bit perf_dw_previous=0;
    wire dw_stream_fire=dut.u_microstyle.u_cnn.u_engine.state_q==19 &&
        dut.u_microstyle.u_cnn.u_engine.dw_in_valid && dut.u_microstyle.u_cnn.u_engine.dw_in_ready;
    longint unsigned perf_tensor_aw=0,perf_tensor_w=0,perf_tensor_b=0,perf_tensor_full_w=0;
    longint unsigned perf_tensor_write_peak=0;
    longint unsigned perf_tensor_ar=0,perf_tensor_r=0;
    longint unsigned perf_req_stall=0, perf_rsp_stall=0;
    longint unsigned perf_result_stall=0;
    bit perf_active=0;
`ifdef C1_TENSOR_COLUMN_READS
    // Observe the actual active COLUMN backend, not the inactive legacy
    // scalar burst hierarchy. Counters are independent of the job profiler.
    generate if(1) begin : g_column_refill_probe
        wire [31:0] req_used=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_read_client.req_count_q;
        wire [31:0] rsp_used=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_read_client.rsp_count_q;
        wire [31:0] meta_used=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.meta_count_q;
        wire pending=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.req_pending_q;
        wire req_fire=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.req_fire;
        wire rsp_fire=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.rsp_fire;
        wire handoff=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.handoff_event &&
                     dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.launch_event;
        bit active=0,previous_req=0;
        integer job=0,req_peak=0,rsp_peak=0,meta_peak=0,credit_peak=0;
        longint unsigned requests=0,responses=0,handoffs=0,adjacent=0,ar=0,beats=0;
        longint unsigned burst_bins[1:16],declared_beats=0;
        initial begin
            if(dut.TENSOR_BURST_SCHED_REQ_HANDOFF!=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.ALLOW_REQ_HANDOFF ||
               dut.TENSOR_BURST_SCHED_MAX_OUTSTANDING!=dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.MAX_OUTSTANDING)
                $fatal(1,"column refill scheduler configuration was not forwarded");
            $display("C1_NUM_COLUMN_REFILL version=2 window=%0d req_depth=%0d rsp_depth=%0d beat_mode=%0d handoff=%0d",
                dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.MAX_OUTSTANDING,
                dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_read_client.REQ_FIFO_DEPTH,
                dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_read_client.RSP_FIFO_DEPTH,
                dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_read_client.RSP_FIFO_BEAT_MODE,
                dut.g_tensor_column_reads.u_column.u_backend.u_exact.u_core.u_scheduler.ALLOW_REQ_HANDOFF);
        end
        always @(posedge core_clk) begin
            if(dut.core_rst) begin active=0;job=0;previous_req=0;end
            else if(dut.boardless_abort) begin active=0;previous_req=0;end
            else if(dut.qos_frame_start_event) begin
                if(active)$fatal(1,"column refill profiler overlapped jobs");
                active=1;job++;previous_req=0;
                req_peak=0;rsp_peak=0;meta_peak=0;credit_peak=0;
                requests=0;responses=0;handoffs=0;adjacent=0;ar=0;beats=0;
                declared_beats=0;for(integer n=1;n<=16;n++)burst_bins[n]=0;
            end else if(active) begin
                if($isunknown({req_used,rsp_used,meta_used,pending}) ||
                   req_used+rsp_used>meta_used || meta_used+pending>dut.TENSOR_BURST_SCHED_MAX_OUTSTANDING)
                    $fatal(1,"column refill exceeded actual logical/reserved credit");
                if(req_used>req_peak)req_peak=req_used;
                if(rsp_used>rsp_peak)rsp_peak=rsp_used;
                if(meta_used>meta_peak)meta_peak=meta_used;
                if(meta_used+pending>credit_peak)credit_peak=meta_used+pending;
                if(req_fire) begin requests++;if(previous_req)adjacent++;end
                if(rsp_fire)responses++;
                if(handoff)handoffs++;
                previous_req=req_fire;
                if(dut.g_tensor_column_reads.u_column.m_axi_arvalid && dut.g_tensor_column_reads.u_column.m_axi_arready) begin
                    if($isunknown(dut.g_tensor_column_reads.u_column.m_axi_arlen) ||
                       dut.g_tensor_column_reads.u_column.m_axi_arlen>=16)$fatal(1,"column refill AR exceeds selected burst size");
                    ar++;
                    burst_bins[int'(dut.g_tensor_column_reads.u_column.m_axi_arlen)+1]++;
                    declared_beats+=int'(dut.g_tensor_column_reads.u_column.m_axi_arlen)+1;
                end
                if(dut.g_tensor_column_reads.u_column.m_axi_rvalid && dut.g_tensor_column_reads.u_column.m_axi_rready)beats++;
                if(dut.control_done_event) begin
                    if(requests!=responses || beats!=declared_beats || meta_used!=0 || req_used!=0 || rsp_used!=0 || pending)
                        $fatal(1,"successful frame retained column refill debt");
                    $display("C1_PERF_COLUMN_REFILL job=%0d requests=%0d responses=%0d handoffs=%0d adjacent=%0d req_peak=%0d rsp_peak=%0d meta_peak=%0d credit_peak=%0d ar=%0d beats=%0d",
                        job,requests,responses,handoffs,adjacent,req_peak,rsp_peak,meta_peak,credit_peak,ar,beats);
                    for(integer n=1;n<=16;n++) if(burst_bins[n]!=0)
                        $display("C1_PERF_COLUMN_BURSTS job=%0d beats=%0d count=%0d",job,n,burst_bins[n]);
                    active=0;
                end
            end
        end
    end endgenerate
`endif
    generate if(ENABLE_TENSOR_BURST_REFILL_CFG) begin : g_refill_capacity_probe
        wire [31:0] req_used = dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_core.u_read_client.req_count_q;
        wire [31:0] rsp_used = dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_core.u_read_client.rsp_count_q;
        wire [31:0] meta_used = dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_core.u_scheduler.meta_count_q;
        integer req_peak=0,rsp_peak=0,meta_peak=0;
        initial $display("C1_NUM_REFILL_WINDOW %0d",dut.TENSOR_BURST_SCHED_MAX_OUTSTANDING);
        always @(posedge core_clk) begin
            if(dut.core_rst) begin req_peak=0;rsp_peak=0;meta_peak=0;end
            else begin
                // Every accepted leaf request retains a scheduler metadata
                // slot until its ordered response is consumed. FIFO entries
                // are disjoint subsets of that outstanding logical work.
                if($isunknown({req_used,rsp_used,meta_used}) ||
                   meta_used>dut.TENSOR_BURST_SCHED_MAX_OUTSTANDING || req_used+rsp_used>meta_used)
                    $fatal(1,"refill capacity accounting violated req=%0d rsp=%0d meta=%0d",req_used,rsp_used,meta_used);
                if(req_used>req_peak) req_peak=req_used;
                if(rsp_used>rsp_peak) rsp_peak=rsp_used;
                if(meta_used>meta_peak) meta_peak=meta_used;
                if(dut.control_done_event)
                    $display("C1_NUM_REFILL_CAPACITY req_depth=%0d rsp_depth=%0d beat_mode=%0d req_peak=%0d rsp_peak=%0d meta_peak=%0d",
                        dut.TENSOR_BURST_REQ_FIFO_DEPTH,TENSOR_BURST_RSP_FIFO_DEPTH_CFG,
                        TENSOR_BURST_RSP_FIFO_BEAT_MODE_CFG,req_peak,rsp_peak,meta_peak);
            end
        end
    end endgenerate
    always @(posedge core_clk) begin
        if (dut.core_rst) begin
            perf_cycle=0; perf_active=0; perf_job=0;
        end else begin
            perf_cycle=perf_cycle+1;
            if (dut.boardless_abort) begin
                if(perf_active) begin
                    $display("C1_FINAL_FUSION_STOP job=%0d generation=%0d inputs=%0d outputs=%0d commits=%0d eofs=%0d",perf_job,
                        dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_fused_inputs,perf_fused_outputs,perf_fused_commits,perf_fused_eofs);
                    $display("C1_VIEW_STOP job=%0d generation=%0d views=%0d",perf_job,
                        dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_view_commits);
                    $display("C1_PERF_ABORT job=%0d cycle=%0d elapsed=%0d",perf_job,perf_cycle,perf_cycle-perf_start);
                end
                perf_active=0;
            end else if (dut.qos_frame_start_event) begin
                if (perf_active) $fatal(1,"performance monitor overlapping jobs");
                perf_active=1; perf_job=perf_job+1; perf_start=perf_cycle;
                perf_bridge=0; perf_feed=0; perf_input_wait=0;
                perf_engine_hold=0; perf_neither=0;
                perf_mem_read=0; perf_mem_write=0;
                perf_dw_stream=0;perf_dw_adjacent=0;perf_dw_previous=0;
                perf_pw_stream=0;perf_pw_early=0;
                perf_rgb_beats=0;perf_rgb_tails=0;
                perf_view_commits=0;
                perf_view_context_seen=0;
                perf_rq_starts=0;perf_rq_outputs=0;perf_rq_early=0;perf_rq_peak=0;perf_rq_pending=0;
                perf_pixel_starts=0;perf_pixel_outputs=0;perf_pixel_inputs_ahead=0;perf_pixel_starts_ahead=0;
                perf_pixel_writes=0;perf_pixel_responses=0;perf_pixel_peak=0;perf_pixel_ends=0;
                perf_dw_pixel_inputs=0;perf_dw_pixel_feeds=0;perf_dw_pixel_outputs=0;
                perf_dw_pixel_writes=0;perf_dw_pixel_responses=0;perf_dw_pixel_ends=0;
                perf_dw_pixel_ahead=0;perf_dw_pixel_warm=0;perf_dw_pixel_peak=0;
                perf_dw_frame_cold=0;perf_dw_frame_warm=0;perf_dw_frame_continue=0;
                perf_dw_frame_in_eof=0;perf_dw_frame_out_eof=0;perf_dw_frame_held=0;
                perf_column_overlap=0;perf_write_peak=0;
                perf_pointwise_columns=0;
                perf_column_bypass=0;
                perf_fused_inputs=0;perf_fused_outputs=0;perf_fused_commits=0;perf_fused_eofs=0;perf_fused_context_seen=0;
                perf_fused_starts=0;perf_fused_dot_outputs=0;perf_fused_inputs_ahead=0;perf_fused_starts_ahead=0;
                perf_map_accept=0;perf_map_reused=0;perf_map_eligible=0;perf_map_ram=0;
                perf_map_previous_good=0;perf_map_request_y=0;perf_map_previous_y=0;
                perf_pixel_pf_req=0;perf_pixel_pf_rsp=0;perf_pixel_pf_take=0;perf_pixel_pf_early=0;
                perf_source_accept=0;perf_source_req=0;perf_source_rsp=0;
                perf_source_end=0;perf_source_peak=0;perf_source_wait=0;perf_source_debt=0;
                perf_columns=0;perf_column_responses=0;
                perf_tensor_aw=0;perf_tensor_w=0;perf_tensor_b=0;perf_tensor_full_w=0;
                perf_tensor_write_peak=0;
                perf_tensor_ar=0;perf_tensor_r=0;
                perf_tap_prepared=0; perf_tap_fallback=0;
                perf_reuse_stride1=0; perf_reuse_stride2=0; perf_reuse_saved=0;
                perf_req_stall=0; perf_rsp_stall=0; perf_result_stall=0;
                for(perf_bin=0;perf_bin<32;perf_bin++) begin
                    perf_adapter_cycles[perf_bin]=0;
                    perf_adapter_input_wait[perf_bin]=0;
                    perf_adapter_result_stall[perf_bin]=0;
                end
`ifdef C1_NUMERICAL_TRACE
                for(perf_bin=0;perf_bin<22;perf_bin++) begin
                    perf_stage_cycles[perf_bin]=0; perf_stage_dot[perf_bin]=0; perf_stage_dw[perf_bin]=0;
                    perf_stage_read[perf_bin]=0; perf_stage_write[perf_bin]=0; perf_stage_column[perf_bin]=0;
`ifdef C1_TENSOR_COLUMN_READS
                    perf_column_refills[perf_bin]=0;perf_column_words[perf_bin]=0;
                    for(perf_fsm_bin=0;perf_fsm_bin<7;perf_fsm_bin++) perf_column_state[perf_bin][perf_fsm_bin]=0;
`endif
                    for(perf_fsm_bin=0;perf_fsm_bin<32;perf_fsm_bin++) begin
                        perf_stage_engine[perf_bin][perf_fsm_bin]=0;
                        perf_stage_adapter[perf_bin][perf_fsm_bin]=0;
                    end
                end
                for(perf_bin=0;perf_bin<32;perf_bin++) begin
                    perf_stage0_engine[perf_bin]=0;perf_stage0_adapter[perf_bin]=0;
                end
`endif
                $display("C1_PERF_START job=%0d cycle=%0d",perf_job,perf_cycle);
            end else if (perf_active) begin
                if(dut.FUSE_FINAL_OUTPUT) begin
                    if(!perf_fused_context_seen && dut.u_tensor_adapter.stage_index_q==20 &&
                       dut.u_tensor_adapter.state_q==dut.u_tensor_adapter.ST_STAGE_LOAD) begin
                        perf_fused_context_seen=1;
                        $display("C1_FINAL_FUSION_BEGIN job=%0d generation=%0d width=%0d height=%0d",perf_job,
                            dut.u_microstyle.u_cnn.u_engine.config_generation_q,FRAME_W,FRAME_H);
                    end
                    if(dut.u_tensor_adapter.stage_index_q>=20 && dut.tensor_mem_req_valid &&
                       (dut.tensor_mem_req_write || dut.u_tensor_adapter.stage_index_q==21))
                        $fatal(1,"fused final path materialized/read the final intermediate tensor");
                    if(dut.u_tensor_adapter.stage_index_q==21 && (dut.tensor_column_valid || dut.adapter_engine_valid || dut.adapter_result_valid))
                        $fatal(1,"fused identity layer transferred physical C8 data");
                    if(dut.adapter_result_valid && dut.adapter_result_ready &&
                       dut.u_microstyle.u_cnn.u_engine.stage_index_q==20)perf_fused_inputs++;
                    if(dut.adapter_final_valid && dut.adapter_final_ready) begin
                        perf_fused_outputs++;
                        if(dut.adapter_final_eof) begin
                            if(perf_fused_commits!=1 || !(dut.u_microstyle.cnn_done || dut.u_microstyle.cnn_done_seen_q))
                                $fatal(1,"fused EOF preceded final descriptor/engine completion");
                            perf_fused_eofs++;
                            $display("C1_FINAL_FUSION_EOF job=%0d generation=%0d inputs=%0d outputs=%0d",perf_job,
                                dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_fused_inputs,perf_fused_outputs);
                        end
                    end
                end
                if(dut.ELIDE_VIRTUAL_UPSAMPLE && !perf_view_context_seen &&
                   dut.u_microstyle.u_cnn.u_engine.stage_index_q==14 && dut.engine_stage_active) begin
                    perf_view_context_seen=1;
                    $display("C1_VIEW_CONTEXT job=%0d generation=%0d",perf_job,dut.u_microstyle.u_cnn.u_engine.config_generation_q);
                end
                if(dut.ELIDE_VIRTUAL_UPSAMPLE &&
                   (dut.u_tensor_adapter.stage_index_q==14 || dut.u_tensor_adapter.stage_index_q==17) &&
                   (dut.tensor_mem_req_valid || dut.tensor_column_valid || dut.adapter_engine_valid || dut.adapter_result_valid))
                    $fatal(1,"elided view attempted a tensor/data transfer");
                if(dut.adapter_view_valid && dut.adapter_view_ready && dut.adapter_view_stage==21) begin
                    if(!dut.FUSE_FINAL_OUTPUT || !dut.u_microstyle.u_cnn.u_engine.view_layer ||
                       dut.u_microstyle.u_cnn.u_engine.stage_index_q!=21 ||
                       dut.adapter_view_generation!=dut.u_microstyle.u_cnn.u_engine.config_generation_q ||
                       !dut.adapter_final_valid || !dut.adapter_final_eof || dut.adapter_final_ready ||
                       perf_fused_inputs!=FRAME_W*FRAME_H || perf_fused_outputs!=FRAME_W*FRAME_H-1 ||
                       dut.u_tensor_adapter.pixel_prefetch_busy || dut.u_tensor_adapter.pixel_sink_busy ||
                       dut.u_tensor_adapter.result_writes_pending_q!=0 || dut.u_tensor_adapter.source_writes_pending_q!=0)
                        $fatal(1,"fused final commit lacks actual held EOF, complete input or drain");
                    perf_fused_commits++;
                    $display("C1_FINAL_FUSION_COMMIT job=%0d generation=%0d stage=21 inputs=%0d outputs=%0d held_eof=1",perf_job,
                        dut.adapter_view_generation,perf_fused_inputs,perf_fused_outputs);
                end else if(dut.adapter_view_valid && dut.adapter_view_ready) begin
                    if(!dut.ELIDE_VIRTUAL_UPSAMPLE || !dut.u_tensor_adapter.view_layer ||
                       !dut.u_microstyle.u_cnn.u_engine.view_layer ||
                       dut.adapter_view_stage!=dut.u_microstyle.u_cnn.u_engine.stage_index_q ||
                       dut.adapter_view_generation!=dut.u_microstyle.u_cnn.u_engine.config_generation_q ||
                       dut.u_tensor_adapter.input_width_q!=dut.u_microstyle.u_cnn.u_engine.input_width_q ||
                       dut.u_tensor_adapter.input_height_q!=dut.u_microstyle.u_cnn.u_engine.input_height_q ||
                       dut.u_tensor_adapter.input_groups_q!=dut.u_microstyle.u_cnn.u_engine.input_groups_q ||
                       dut.u_tensor_adapter.pixel_prefetch_busy || dut.u_tensor_adapter.pixel_sink_busy ||
                       dut.u_tensor_adapter.result_writes_pending_q!=0 || dut.u_tensor_adapter.source_writes_pending_q!=0)
                        $fatal(1,"view commit identity/geometry/drain mismatch");
                    perf_view_commits++;
                    $display("C1_VIEW_COMMIT job=%0d stage=%0d generation=%0d input_bank=%0d output_bank=%0d width=%0d height=%0d groups=%0d debt=0",
                        perf_job,dut.adapter_view_stage,dut.adapter_view_generation,
                        dut.u_tensor_adapter.input_bank_q,dut.u_tensor_adapter.output_bank_q,
                        dut.u_tensor_adapter.input_width_q,dut.u_tensor_adapter.input_height_q,dut.u_tensor_adapter.input_groups_q);
                end
                if(dut.u_microstyle.u_cnn.u_engine.opcode_q==1 &&
                   dut.u_microstyle.u_cnn.u_engine.input_channels_q==3 &&
                   dut.u_microstyle.u_cnn.u_engine.dot_in_valid && dut.u_microstyle.u_cnn.u_engine.dot_in_ready) begin
                    perf_rgb_beats++;
                    if(dut.u_microstyle.u_cnn.u_engine.dot_in_last)perf_rgb_tails++;
                end
                if(dw_stream_fire) begin
                    perf_dw_stream++;
                    if(perf_dw_previous) perf_dw_adjacent++;
                end
                perf_dw_previous=dw_stream_fire;
                if(dut.u_tensor_adapter.pixel_prefetch_state_q==dut.u_tensor_adapter.PF_REQUEST &&
                   dut.tensor_column_valid && dut.tensor_column_ready) perf_pixel_pf_req++;
                if(dut.u_tensor_adapter.pixel_prefetch_state_q==dut.u_tensor_adapter.PF_RESPONSE &&
                   dut.tensor_column_rsp_valid && dut.tensor_column_rsp_ready) begin
                    perf_pixel_pf_rsp++;
                    if(dut.u_tensor_adapter.state_q!=dut.u_tensor_adapter.ST_READ_RSP) perf_pixel_pf_early++;
                end
                if(dut.u_tensor_adapter.pixel_prefetch_take) perf_pixel_pf_take++;
                if(dut.u_tensor_adapter.pixel_stream_q && dut.u_tensor_adapter.opcode_q!=3) begin
                    if(dut.adapter_engine_valid && dut.adapter_engine_ready && dut.adapter_engine_group_index==0 &&
                       dut.u_microstyle.u_cnn.u_engine.dot_busy) perf_pixel_inputs_ahead++;
                    if(dut.u_microstyle.u_cnn.u_engine.dot_start_valid && dut.u_microstyle.u_cnn.u_engine.dot_start_ready) begin
                        perf_pixel_starts++;
                        // Count next-pixel starts, not ordinary group1..N
                        // restarts already charged to requant overlap.
                        if(perf_rq_pending!=0 && dut.u_microstyle.u_cnn.u_engine.output_group_q==0)
                            perf_pixel_starts_ahead++;
                    end
                    if(dut.adapter_result_valid && dut.adapter_result_ready)perf_pixel_outputs++;
                    if(dut.tensor_mem_req_valid && dut.tensor_mem_req_ready)begin
                        perf_pixel_writes++;
                        if(dut.tensor_mem_req_end)perf_pixel_ends++;
                    end
                    if(dut.tensor_mem_rsp_valid && dut.tensor_mem_rsp_ready)perf_pixel_responses++;
                    if(dut.u_tensor_adapter.u_pixel_writer.reservations>perf_pixel_peak)
                        perf_pixel_peak=dut.u_tensor_adapter.u_pixel_writer.reservations;
                end
                if(dut.u_tensor_adapter.pixel_stream_q && dut.u_tensor_adapter.opcode_q==3) begin
                    if(dut.adapter_engine_valid && dut.adapter_engine_ready) begin
                        perf_dw_pixel_inputs++;
                        if(dut.adapter_engine_group_index==0 && dut.u_microstyle.u_cnn.u_engine.dw_busy)perf_dw_pixel_ahead++;
                    end
                    if(dut.u_microstyle.u_cnn.u_engine.dw_in_valid && dut.u_microstyle.u_cnn.u_engine.dw_in_ready)perf_dw_pixel_feeds++;
                    if(dut.u_microstyle.u_cnn.u_engine.state_q==dut.u_microstyle.u_cnn.u_engine.ST_DW_START &&
                       (dut.u_microstyle.u_cnn.u_engine.dw_start_ready || dut.u_microstyle.u_cnn.u_engine.dw_frame_continue) &&
                       dut.u_microstyle.u_cnn.u_engine.dw_stream_q)perf_dw_pixel_warm++;
                    if(dut.adapter_result_valid && dut.adapter_result_ready)perf_dw_pixel_outputs++;
                    if(dut.tensor_mem_req_valid && dut.tensor_mem_req_ready)begin
                        perf_dw_pixel_writes++;if(dut.tensor_mem_req_end)perf_dw_pixel_ends++;
                    end
                    if(dut.tensor_mem_rsp_valid && dut.tensor_mem_rsp_ready)perf_dw_pixel_responses++;
                    if(dut.u_tensor_adapter.u_pixel_writer.reservations>perf_dw_pixel_peak)
                        perf_dw_pixel_peak=dut.u_tensor_adapter.u_pixel_writer.reservations;
                end
                if(dut.STREAM_DW_FRAME) begin
                    if(dut.u_microstyle.u_cnn.u_engine.dw_start_valid && dut.u_microstyle.u_cnn.u_engine.dw_start_ready) begin
                        if(dut.u_microstyle.u_cnn.u_engine.dw_stream_q)perf_dw_frame_warm++;
                        else perf_dw_frame_cold++;
                    end
                    if(dut.u_microstyle.u_cnn.u_engine.state_q==dut.u_microstyle.u_cnn.u_engine.ST_DW_START &&
                       dut.u_microstyle.u_cnn.u_engine.dw_frame_continue) begin
                        perf_dw_frame_continue++;
                        if(dut.u_microstyle.u_cnn.u_engine.dw_out_valid && !dut.u_microstyle.u_cnn.u_engine.dw_out_ready)
                            perf_dw_frame_held++;
                    end
                    if(dut.u_microstyle.u_cnn.u_engine.u_dw_core.in_valid &&
                       dut.u_microstyle.u_cnn.u_engine.u_dw_core.in_ready && dut.u_microstyle.u_cnn.u_engine.u_dw_core.in_eof)
                        perf_dw_frame_in_eof++;
                    if(dut.u_microstyle.u_cnn.u_engine.u_dw_core.out_valid &&
                       dut.u_microstyle.u_cnn.u_engine.u_dw_core.out_ready && dut.u_microstyle.u_cnn.u_engine.u_dw_core.out_eof)
                        perf_dw_frame_out_eof++;
                end
                // Final-convolution compute is independent of the tensor
                // writer. Count real handshakes before updating global debt;
                // never infer these starts from a global counter difference.
                if(dut.FUSE_FINAL_OUTPUT && dut.u_microstyle.u_cnn.u_engine.stage_index_q==20) begin
                    if(dut.adapter_engine_valid && dut.adapter_engine_ready && dut.adapter_engine_group_index==0 &&
                       dut.u_microstyle.u_cnn.u_engine.dot_busy)perf_fused_inputs_ahead++;
                    if(dut.u_microstyle.u_cnn.u_engine.dot_start_valid && dut.u_microstyle.u_cnn.u_engine.dot_start_ready) begin
                        perf_fused_starts++;
                        if(perf_rq_pending!=0)perf_fused_starts_ahead++;
                    end
                    if(dut.u_microstyle.u_cnn.u_engine.dot_out_valid && dut.u_microstyle.u_cnn.u_engine.dot_out_ready)
                        perf_fused_dot_outputs++;
                end
                if(dut.u_microstyle.u_cnn.u_engine.dot_start_valid && dut.u_microstyle.u_cnn.u_engine.dot_start_ready) begin
                    if(perf_rq_pending!=0)perf_rq_early++;
                    perf_rq_starts++;perf_rq_pending++;
                end
                if(dut.u_microstyle.u_cnn.u_engine.dot_out_valid && dut.u_microstyle.u_cnn.u_engine.dot_out_ready) begin
                    perf_rq_outputs++;perf_rq_pending--;
                end
                if(perf_rq_pending>perf_rq_peak)perf_rq_peak=perf_rq_pending;
                if(perf_rq_pending<0 || perf_rq_pending>6)$fatal(1,"SoC dot/requant credit mismatch");
                if(dut.u_microstyle.u_cnn.u_engine.pointwise_stream_q &&
                   dut.u_microstyle.u_cnn.u_engine.dot_in_valid && dut.u_microstyle.u_cnn.u_engine.dot_in_ready) begin
                    perf_pw_stream++;
                    if(dut.u_microstyle.u_cnn.u_engine.expected_input_group_q!=0) perf_pw_early++;
                end
                if(dut.u_tensor_adapter.adapter_source_valid && dut.u_tensor_adapter.adapter_source_ready)
                    perf_source_accept++;
                // Count real port handshakes, not the DUT credit flags.
                if(dut.u_tensor_adapter.state_q==3 && dut.tensor_mem_req_valid && dut.tensor_mem_req_ready) begin
                    if(!dut.tensor_mem_req_write ||
                       dut.tensor_mem_req_addr != dut.u_tensor_adapter.tensor_bank_base_fn(0)+8*perf_source_req ||
                       dut.u_tensor_adapter.mem_req_end !==
                         (!dut.PIPELINED_SOURCE_WRITES || (perf_source_req%FRAME_W)%8==7 || perf_source_req%FRAME_W==FRAME_W-1))
                        $fatal(1,"source write raster address/end marker mismatch");
                    perf_source_req++;perf_source_debt++;
                    if(dut.u_tensor_adapter.mem_req_end) perf_source_end++;
                end
                if(perf_source_debt>0 && dut.tensor_mem_rsp_valid && dut.tensor_mem_rsp_ready) begin
                    perf_source_rsp++;perf_source_debt--;
                end
                if(perf_source_debt>perf_source_peak) perf_source_peak=perf_source_debt;
                if(perf_source_debt>0) perf_source_wait++;
                if(perf_source_debt>15 || (perf_source_debt>0 &&
                    (dut.adapter_engine_valid || dut.u_tensor_adapter.cache_stage_start_valid)))
                    $fatal(1,"source write real retirement fence violated");
                if(dut.tensor_column_valid && dut.tensor_column_ready &&
                   perf_active_write_debt!=0) perf_column_overlap++;
                if(dut.tensor_column_valid && dut.tensor_column_ready &&
                   dut.u_tensor_adapter.opcode_q==2) perf_pointwise_columns++;
`ifdef C1_TENSOR_COLUMN_READS
                if(perf_map_fire) begin
                    perf_map_accept++;
                    if(perf_map_previous_good && perf_map_y==perf_map_previous_y) perf_map_eligible++;
                    if(perf_map_reuse_fire) perf_map_reused++;
                    if(perf_map_reuse_fire != (dut.TENSOR_COLUMN_REUSE_ROW_MAP &&
                       perf_map_previous_good && perf_map_y==perf_map_previous_y))
                        $fatal(1,"row-map reuse disagrees with independent accepted/retired history");
                    perf_map_request_y=perf_map_y;
                end
                if(|dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.rd_en)perf_map_ram++;
                if(perf_map_rsp_fire) begin
                    perf_map_previous_good=!dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_rsp_error;
                    perf_map_previous_y=perf_map_request_y;
                end
                if(perf_map_config_fire || perf_map_maintenance)perf_map_previous_good=0;
                if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.state_q==
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.ST_CAPTURE &&
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_rsp_valid &&
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.column_rsp_ready)
                    perf_column_bypass++;
`endif
                if(perf_active_write_debt>perf_write_peak)perf_write_peak=perf_active_write_debt;
`ifdef C1_NUMERICAL_TRACE
                if($isunknown(dut.u_tensor_adapter.stage_index_q) || dut.u_tensor_adapter.stage_index_q>=22)
                    $fatal(1,"unknown/out-of-range adapter stage in performance monitor");
                perf_stage=int'(dut.u_tensor_adapter.stage_index_q);
                perf_stage_cycles[perf_stage]++;
`ifdef C1_TENSOR_COLUMN_READS
                if($isunknown(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.state_q) ||
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.state_q>6)
                    $fatal(1,"unknown column FSM during layer profiling");
                perf_column_state[perf_stage][int'(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.state_q)]++;
                if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.refill_req_valid &&
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.refill_req_ready)
                    perf_column_refills[perf_stage]++;
                if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.refill_word_valid &&
                   dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.refill_word_ready)
                    perf_column_words[perf_stage]++;
`endif
                if($isunknown(dut.u_microstyle.u_cnn.u_engine.state_q) ||
                   $isunknown(dut.u_tensor_adapter.state_q))
                    $fatal(1,"stage profile observed unknown FSM state");
                perf_stage_engine[perf_stage][int'(dut.u_microstyle.u_cnn.u_engine.state_q)]++;
                perf_stage_adapter[perf_stage][int'(dut.u_tensor_adapter.state_q)]++;
                if(perf_stage==0) begin
                    if($isunknown(dut.u_microstyle.u_cnn.u_engine.state_q) ||
                       $isunknown(dut.u_tensor_adapter.state_q))
                        $fatal(1,"stage0 profile observed unknown FSM state");
                    perf_stage0_engine[int'(dut.u_microstyle.u_cnn.u_engine.state_q)]++;
                    perf_stage0_adapter[int'(dut.u_tensor_adapter.state_q)]++;
                end
                if(dut.u_microstyle.u_cnn.u_engine.dot_in_valid && dut.u_microstyle.u_cnn.u_engine.dot_in_ready)
                    perf_stage_dot[perf_stage]++;
                if(dut.u_microstyle.u_cnn.u_engine.dw_in_valid && dut.u_microstyle.u_cnn.u_engine.dw_in_ready)
                    perf_stage_dw[perf_stage]++;
                if(dut.tensor_mem_req_valid && dut.tensor_mem_req_ready) begin
                    if(dut.tensor_mem_req_write) perf_stage_write[perf_stage]++;
                    else perf_stage_read[perf_stage]++;
                end
                if(dut.tensor_column_valid && dut.tensor_column_ready) perf_stage_column[perf_stage]++;
`endif
                if($isunknown(dut.u_tensor_adapter.state_q))
                    $fatal(1,"unknown adapter state during performance measurement");
                perf_state=int'(dut.u_tensor_adapter.state_q);
                perf_adapter_cycles[perf_state]++;
                if(perf_state==6 && dut.u_tensor_adapter.window_reuse_admit &&
                   !dut.u_tensor_adapter.adapter_abort && !dut.u_tensor_adapter.abort_pending_q) begin
                    if(dut.u_tensor_adapter.stride_x_q==1) begin
                        perf_reuse_stride1++; perf_reuse_saved+=6;
                    end else begin
                        perf_reuse_stride2++; perf_reuse_saved+=3;
                    end
                end
                if(perf_state==8 && dut.u_tensor_adapter.mem_rsp_valid &&
                   dut.u_tensor_adapter.mem_rsp_ready && !dut.u_tensor_adapter.mem_rsp_error &&
                   dut.u_tensor_adapter.windowed_opcode && dut.u_tensor_adapter.tap_q!=8 &&
                   !dut.u_tensor_adapter.adapter_abort && !dut.u_tensor_adapter.abort_pending_q) begin
                    if(dut.u_tensor_adapter.tap_addr_prefetch_phase_q==3 ||
                       dut.u_tensor_adapter.tap_addr_prefetch_phase_q==4)
                        perf_tap_prepared++;
                    else perf_tap_fallback++;
                end
                if(dut.bridge_busy && !dut.adapter_engine_valid && dut.adapter_engine_ready)
                    perf_adapter_input_wait[perf_state]++;
                if(dut.adapter_result_valid && !dut.adapter_result_ready)
                    perf_adapter_result_stall[perf_state]++;
                if (dut.bridge_busy) begin
                    perf_bridge=perf_bridge+1;
                    case ({dut.adapter_engine_valid,dut.adapter_engine_ready})
                        2'b11: perf_feed=perf_feed+1;
                        2'b01: perf_input_wait=perf_input_wait+1;
                        2'b10: perf_engine_hold=perf_engine_hold+1;
                        2'b00: perf_neither=perf_neither+1;
                        default: $fatal(1,"unknown adapter handshake during job");
                    endcase
                end
                if (dut.tensor_mem_req_valid && dut.tensor_mem_req_ready) begin
                    if (dut.tensor_mem_req_write) perf_mem_write=perf_mem_write+1;
                    else perf_mem_read=perf_mem_read+1;
                end
                if(dut.tensor_column_valid && dut.tensor_column_ready) perf_columns++;
                if(dut.tensor_column_rsp_valid && dut.tensor_column_rsp_ready) perf_column_responses++;
                if(dut.axi_s_awvalid[6] && dut.axi_s_awready[6]) perf_tensor_aw++;
                if(dut.axi_s_arvalid[6] && dut.axi_s_arready[6]) perf_tensor_ar++;
                if(dut.axi_s_rvalid[6] && dut.axi_s_rready[6]) perf_tensor_r++;
                if(dut.axi_s_bvalid[6] && dut.axi_s_bready[6]) perf_tensor_b++;
                if(perf_tensor_aw-perf_tensor_b>perf_tensor_write_peak)perf_tensor_write_peak=perf_tensor_aw-perf_tensor_b;
                if(perf_tensor_b>perf_tensor_aw || perf_tensor_write_peak>dut.TENSOR_WRITE_OUTSTANDING)
                    $fatal(1,"tensor client exceeded actual AXI write outstanding contract");
                if(dut.axi_s_wvalid[6] && dut.axi_s_wready[6]) begin
                    perf_tensor_w++;
                    if(dut.axi_s_wstrb[6]==16'hffff) perf_tensor_full_w++;
                end
                if (dut.tensor_mem_req_valid && !dut.tensor_mem_req_ready)
                    perf_req_stall=perf_req_stall+1;
                if (dut.tensor_mem_rsp_valid && !dut.tensor_mem_rsp_ready)
                    perf_rsp_stall=perf_rsp_stall+1;
                if (dut.adapter_result_valid && !dut.adapter_result_ready)
                    perf_result_stall=perf_result_stall+1;
                if (dut.boardless_done || dut.control_error_event) begin
                    if(dut.control_error_event) begin
                        $display("C1_FINAL_FUSION_STOP job=%0d generation=%0d inputs=%0d outputs=%0d commits=%0d eofs=%0d",perf_job,
                            dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_fused_inputs,perf_fused_outputs,perf_fused_commits,perf_fused_eofs);
                        $display("C1_VIEW_STOP job=%0d generation=%0d views=%0d",perf_job,
                            dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_view_commits);
                    end
                    if(!dut.control_error_event) begin
                        $display("C1_PERF_DW_STREAM job=%0d beats=%0d adjacent_feeds=%0d",perf_job,perf_dw_stream,perf_dw_adjacent);
                        $display("C1_PERF_POINTWISE_REDUCTION job=%0d beats=%0d early=%0d",perf_job,perf_pw_stream,perf_pw_early);
                        $display("C1_PERF_RGB_REDUCTION job=%0d beats=%0d tails=%0d",perf_job,perf_rgb_beats,perf_rgb_tails);
                        $display("C1_PERF_VIEW_ELISION job=%0d generation=%0d views=%0d",perf_job,
                            dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_view_commits);
                        if(dut.FUSE_FINAL_OUTPUT)
                            $display("C1_PERF_FINAL_COMPUTE job=%0d generation=%0d starts=%0d outputs=%0d inputs_ahead=%0d starts_ahead=%0d",perf_job,
                                dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_fused_starts,perf_fused_dot_outputs,
                                perf_fused_inputs_ahead,perf_fused_starts_ahead);
                        $display("C1_PERF_FINAL_FUSION job=%0d generation=%0d inputs=%0d outputs=%0d commits=%0d eofs=%0d",perf_job,
                            dut.u_microstyle.u_cnn.u_engine.config_generation_q,perf_fused_inputs,perf_fused_outputs,perf_fused_commits,perf_fused_eofs);
                        if(perf_rq_pending!=0)$fatal(1,"completed job retained dot/requant debt");
                        $display("C1_PERF_MAC_REQUANT_OVERLAP job=%0d starts=%0d outputs=%0d early=%0d peak=%0d",
                            perf_job,perf_rq_starts,perf_rq_outputs,perf_rq_early,perf_rq_peak);
                        if(dut.u_tensor_adapter.pixel_sink_busy)$fatal(1,"completed job retained pixel write debt");
                        $display("C1_PERF_DOT_PIXEL_PIPELINE job=%0d starts=%0d outputs=%0d inputs_ahead=%0d starts_ahead=%0d writes=%0d responses=%0d peak=%0d",
                            perf_job,perf_pixel_starts,perf_pixel_outputs,perf_pixel_inputs_ahead,perf_pixel_starts_ahead,
                            perf_pixel_writes,perf_pixel_responses,perf_pixel_peak);
                        $display("C1_PERF_PIXEL_WRITE_BATCH job=%0d writes=%0d ends=%0d",
                            perf_job,perf_pixel_writes,perf_pixel_ends);
                        $display("C1_PERF_DW_PIXEL_PIPELINE job=%0d inputs=%0d feeds=%0d outputs=%0d writes=%0d responses=%0d ends=%0d warm=%0d ahead=%0d peak=%0d",
                            perf_job,perf_dw_pixel_inputs,perf_dw_pixel_feeds,perf_dw_pixel_outputs,perf_dw_pixel_writes,
                            perf_dw_pixel_responses,perf_dw_pixel_ends,perf_dw_pixel_warm,perf_dw_pixel_ahead,perf_dw_pixel_peak);
                        if(dut.OVERLAP_COLUMN_WRITEBACK && (perf_column_overlap==0 || perf_write_peak>15))
                            $fatal(1,"column/write overlap missing or exceeded credits");
                        $display("C1_PERF_COLUMN_WRITE_OVERLAP job=%0d columns=%0d peak_writes=%0d",perf_job,perf_column_overlap,perf_write_peak);
                        $display("C1_PERF_POINTWISE_COLUMNS job=%0d reads=%0d",perf_job,perf_pointwise_columns);
                        if(dut.TENSOR_COLUMN_RESPONSE_BYPASS &&
                           (perf_column_bypass==0 || perf_column_bypass!=perf_column_responses))
                            $fatal(1,"successful job did not bypass every real column response");
                        $display("C1_PERF_COLUMN_RESPONSE_BYPASS job=%0d responses=%0d",perf_job,perf_column_bypass);
                        if(perf_map_accept!=perf_columns || perf_map_ram!=perf_columns ||
                           perf_map_reused!=(dut.TENSOR_COLUMN_REUSE_ROW_MAP?perf_map_eligible:0))
                            $fatal(1,"row-map accepted/read/eligible conservation mismatch");
                        $display("C1_PERF_COLUMN_ROW_MAP job=%0d accepted=%0d eligible=%0d reused=%0d normal=%0d ram_reads=%0d",
                            perf_job,perf_map_accept,perf_map_eligible,perf_map_reused,perf_map_accept-perf_map_reused,perf_map_ram);
                        $display("C1_PERF_PIXEL_COLUMN_PREFETCH job=%0d requests=%0d responses=%0d uses=%0d early=%0d",
                            perf_job,perf_pixel_pf_req,perf_pixel_pf_rsp,perf_pixel_pf_take,perf_pixel_pf_early);
                        if(perf_source_debt!=0) $fatal(1,"successful job retained source write debt");
                        $display("C1_PERF_SOURCE_WRITES job=%0d inputs=%0d requests=%0d responses=%0d ends=%0d peak=%0d pending_cycles=%0d",
                            perf_job,perf_source_accept,perf_source_req,perf_source_rsp,perf_source_end,perf_source_peak,perf_source_wait);
                    end
                    if(dut.STREAM_DW_FRAME && !dut.control_error_event)
                        $display("C1_PERF_DW_FRAME job=%0d cold_starts=%0d warm_starts=%0d continues=%0d input_eofs=%0d output_eofs=%0d held_continues=%0d",
                            perf_job,perf_dw_frame_cold,perf_dw_frame_warm,perf_dw_frame_continue,
                            perf_dw_frame_in_eof,perf_dw_frame_out_eof,perf_dw_frame_held);
`ifdef C1_NUMERICAL_TRACE
                    perf_stage_total=0; perf_stage_read_total=0; perf_stage_write_total=0; perf_stage_column_total=0;
                    perf_stage0_engine_total=0;perf_stage0_adapter_total=0;
                    for(perf_bin=0;perf_bin<32;perf_bin++) begin
                        perf_stage0_engine_total+=perf_stage0_engine[perf_bin];
                        perf_stage0_adapter_total+=perf_stage0_adapter[perf_bin];
                        if(perf_stage0_engine[perf_bin]!=0)
                            $display("C1_PERF_STAGE0_FSM job=%0d side=engine state=%0d cycles=%0d",perf_job,perf_bin,perf_stage0_engine[perf_bin]);
                        if(perf_stage0_adapter[perf_bin]!=0)
                            $display("C1_PERF_STAGE0_FSM job=%0d side=adapter state=%0d cycles=%0d",perf_job,perf_bin,perf_stage0_adapter[perf_bin]);
                    end
                    if(perf_stage0_engine_total!=perf_stage_cycles[0] || perf_stage0_adapter_total!=perf_stage_cycles[0])
                        $fatal(1,"stage0 FSM profiles did not cover every stage0 cycle exactly once");
                    for(perf_bin=0;perf_bin<22;perf_bin++) begin
                        perf_stage_engine_total=0;perf_stage_adapter_total=0;
`ifdef C1_TENSOR_COLUMN_READS
                        perf_column_state_total=0;
                        for(perf_fsm_bin=0;perf_fsm_bin<7;perf_fsm_bin++) perf_column_state_total+=perf_column_state[perf_bin][perf_fsm_bin];
                        if(perf_column_state_total!=perf_stage_cycles[perf_bin])$fatal(1,"column FSM residency mismatch");
                        if(!dut.control_error_event)
                            $display("C1_PERF_COLUMN_STAGE job=%0d stage=%0d idle=%0d lookup=%0d req=%0d data=%0d read=%0d capture=%0d response=%0d refill_commands=%0d refill_words=%0d",
                                perf_job,perf_bin,perf_column_state[perf_bin][0],perf_column_state[perf_bin][1],
                                perf_column_state[perf_bin][2],perf_column_state[perf_bin][3],perf_column_state[perf_bin][4],
                                perf_column_state[perf_bin][5],perf_column_state[perf_bin][6],perf_column_refills[perf_bin],perf_column_words[perf_bin]);
`endif
                        for(perf_fsm_bin=0;perf_fsm_bin<32;perf_fsm_bin++) begin
                            perf_stage_engine_total+=perf_stage_engine[perf_bin][perf_fsm_bin];
                            perf_stage_adapter_total+=perf_stage_adapter[perf_bin][perf_fsm_bin];
                            if(!dut.control_error_event && perf_stage_engine[perf_bin][perf_fsm_bin]!=0)
                                $display("C1_PERF_STAGE_FSM job=%0d stage=%0d side=engine state=%0d cycles=%0d",
                                    perf_job,perf_bin,perf_fsm_bin,perf_stage_engine[perf_bin][perf_fsm_bin]);
                            if(!dut.control_error_event && perf_stage_adapter[perf_bin][perf_fsm_bin]!=0)
                                $display("C1_PERF_STAGE_FSM job=%0d stage=%0d side=adapter state=%0d cycles=%0d",
                                    perf_job,perf_bin,perf_fsm_bin,perf_stage_adapter[perf_bin][perf_fsm_bin]);
                        end
                        if(perf_stage_engine_total!=perf_stage_cycles[perf_bin] ||
                           perf_stage_adapter_total!=perf_stage_cycles[perf_bin])
                            $fatal(1,"stage FSM profiles did not cover every stage cycle exactly once");
                        perf_stage_total+=perf_stage_cycles[perf_bin];
                        perf_stage_read_total+=perf_stage_read[perf_bin];
                        perf_stage_write_total+=perf_stage_write[perf_bin];
                        perf_stage_column_total+=perf_stage_column[perf_bin];
                        if(!dut.control_error_event)
                            $display("C1_PERF_STAGE job=%0d stage=%0d cycles=%0d dot_beats=%0d dw_beats=%0d mem_read=%0d mem_write=%0d columns=%0d",
                                perf_job,perf_bin,perf_stage_cycles[perf_bin],perf_stage_dot[perf_bin],perf_stage_dw[perf_bin],
                                perf_stage_read[perf_bin],perf_stage_write[perf_bin],perf_stage_column[perf_bin]);
                    end
                    if(perf_stage_total!=perf_cycle-perf_start || perf_stage_read_total!=perf_mem_read ||
                       perf_stage_write_total!=perf_mem_write || perf_stage_column_total!=perf_columns)
                        $fatal(1,"stage performance counters do not reconcile with job totals");
`endif
                    perf_hist_total=0;perf_hist_input=0;perf_hist_result=0;
                    for(perf_bin=0;perf_bin<32;perf_bin++) begin
                        perf_hist_total+=perf_adapter_cycles[perf_bin];
                        perf_hist_input+=perf_adapter_input_wait[perf_bin];
                        perf_hist_result+=perf_adapter_result_stall[perf_bin];
                        if(perf_adapter_cycles[perf_bin]!=0)
                            $display("C1_PERF_ADAPTER job=%0d state=%0d cycles=%0d input_wait=%0d result_stall=%0d",
                                perf_job,perf_bin,perf_adapter_cycles[perf_bin],
                                perf_adapter_input_wait[perf_bin],perf_adapter_result_stall[perf_bin]);
                    end
                    if(perf_hist_total!=perf_cycle-perf_start ||
                       perf_hist_input!=perf_input_wait || perf_hist_result!=perf_result_stall)
                        $fatal(1,"adapter state histogram does not reconcile with job counters");
                    if (perf_bridge != perf_feed+perf_input_wait+perf_engine_hold+perf_neither)
                        $fatal(1,"performance monitor partition mismatch");
                    $display("C1_PERF_TAP_ADDRESS job=%0d prepared=%0d fallback=%0d",
                        perf_job,perf_tap_prepared,perf_tap_fallback);
                    $display("C1_PERF_HORIZONTAL_REUSE job=%0d stride1=%0d stride2=%0d saved=%0d",
                        perf_job,perf_reuse_stride1,perf_reuse_stride2,perf_reuse_saved);
                    if(`C1_COLUMN_SOC_ENABLE && !dut.control_error_event &&
                       (perf_columns==0 || perf_columns!=perf_column_responses))
                        $fatal(1,"SoC column requests did not retire exactly once");
                    $display("C1_PERF_COLUMNS job=%0d accepted=%0d retired=%0d",perf_job,perf_columns,perf_column_responses);
                    if(!dut.control_error_event && perf_tensor_aw!=perf_tensor_b)
                        $fatal(1,"successful tensor job left unretired AXI writes");
                    $display("C1_PERF_TENSOR_AXI_WRITE job=%0d aw=%0d beats=%0d b=%0d full_beats=%0d",
                        perf_job,perf_tensor_aw,perf_tensor_w,perf_tensor_b,perf_tensor_full_w);
                    if(!dut.control_error_event)
                        $display("C1_PERF_TENSOR_WRITE_MLP job=%0d aw=%0d b=%0d peak=%0d",perf_job,perf_tensor_aw,perf_tensor_b,perf_tensor_write_peak);
                    $display("C1_PERF_TENSOR_AXI_READ job=%0d ar=%0d beats=%0d",perf_job,perf_tensor_ar,perf_tensor_r);
                    $display("C1_PERF_JOB job=%0d cycle=%0d elapsed=%0d error=%0b bridge=%0d feed=%0d input_wait=%0d engine_hold=%0d neither=%0d mem_read=%0d mem_write=%0d req_stall=%0d rsp_stall=%0d result_stall=%0d",
                             perf_job,perf_cycle,perf_cycle-perf_start,
                             dut.control_error_event,perf_bridge,perf_feed,
                             perf_input_wait,perf_engine_hold,perf_neither,
                             perf_mem_read,perf_mem_write,perf_req_stall,
                             perf_rsp_stall,perf_result_stall);
                    perf_active=0;
                end
            end
            // Global event timestamps, not assigned to perf_job: previous-frame
            // display prefetch may legitimately overlap the next compute job.
            if (dut.control_display_swap_event)
                $display("C1_PERF_DISPLAY_SWAP cycle=%0d",perf_cycle);
            if (dut.display_prefetch_new_done_event)
                $display("C1_PERF_DISPLAY_NEW_DONE cycle=%0d",perf_cycle);
        end
    end

`ifdef C1_NUMERICAL_TRACE
    // Bounded size-matched trace: only accepted source pixels and C8 results.
    integer numeric_expected_results=0; // computed from the loaded descriptors
`ifdef C1_INFLIGHT_ABORT
    logic numeric_compute_trace_enable=0;
`elsif C1_PREVIEW_BRESP_RECOVERY
    logic numeric_compute_trace_enable=0;
`elsif C1_PREVIEW_CANCEL_RECOVERY
    logic numeric_compute_trace_enable=0;
`else
    logic numeric_compute_trace_enable=1;
`endif
    integer numeric_video_raw=0, numeric_video_styled=0;
`ifdef C1_PREVIEW_DISPLAY
    localparam integer FIRST_DISPLAY_PIXELS=64;
    initial $display("C1_NUM_FIRST_DISPLAY preview");
`else
    localparam integer FIRST_DISPLAY_PIXELS=SOURCE_W*SOURCE_H;
`endif
    logic [9:0] numeric_raw_x=0, numeric_style_x=0;
    logic [8:0] numeric_raw_y=0, numeric_style_y=0;
    logic numeric_select_raw=0, numeric_select_style=0;
    logic [23:0] numeric_expected_compositor;
    always @(posedge pixel_clk) begin
        if (dut.u_display.pair_pixel_reset || dut.u_display.pixel_rst) begin
            numeric_select_raw=0; numeric_select_style=0;
        end else begin
            numeric_expected_compositor=24'd0;
            if(numeric_select_raw && dut.u_display.original_response_valid)
                numeric_expected_compositor=dut.u_display.original_rgb;
            else if(numeric_select_style && dut.u_display.styled_response_valid)
                numeric_expected_compositor=dut.u_display.styled_rgb;
            if(dut.u_display.original_response_valid && numeric_video_raw<FIRST_DISPLAY_PIXELS) begin
                $display("C1_NUM_VIDEO_RAW %0d %0d %08h",numeric_raw_x,numeric_raw_y,
                         {8'd0,dut.u_display.original_rgb});
                numeric_video_raw=numeric_video_raw+1;
            end
            if(dut.u_display.styled_response_valid && numeric_video_styled<FRAME_W*FRAME_H) begin
                $display("C1_NUM_VIDEO_STYLED %0d %0d %08h",numeric_style_x,numeric_style_y,
                         {8'd0,dut.u_display.styled_rgb});
                numeric_video_styled=numeric_video_styled+1;
            end
            numeric_raw_x=dut.u_display.prefetch_original_x;
            numeric_raw_y=dut.u_display.prefetch_original_y;
            numeric_style_x=dut.u_display.prefetch_styled_x;
            numeric_style_y=dut.u_display.prefetch_styled_y;
            numeric_select_raw=dut.u_display.compositor_original_request;
            numeric_select_style=dut.u_display.compositor_styled_request;
            #1;
            if(dut.u_display.compositor_rgb!==numeric_expected_compositor)
                $fatal(1,"display compositor response/selection alignment mismatch");
        end
    end
    // Input is the CNN boundary, not a claim of independent camera/ISP gold.
    integer numeric_inputs=0, numeric_outputs=0;
    always @(posedge core_clk) if (!dut.core_rst) begin
        if (dut.u_capture.u_frontend.u_isp.blc_valid &&
            $isunknown(dut.u_capture.u_frontend.u_isp.blc_raw10))
            $fatal(1,"unknown BLC output");
        if (dut.u_capture.u_frontend.u_isp.debayer_valid &&
            $isunknown({dut.u_capture.u_frontend.u_isp.debayer_r10,
                        dut.u_capture.u_frontend.u_isp.debayer_g10,
                        dut.u_capture.u_frontend.u_isp.debayer_b10}))
            $fatal(1,"unknown Debayer output");
        if (dut.u_capture.stream_valid && dut.u_capture.stream_ready &&
            $isunknown(dut.u_capture.stream_rgb))
            $fatal(1,"unknown RGB at capture writer: %h",dut.u_capture.stream_rgb);
        if(numeric_compute_trace_enable && dut.adapter_source_valid && dut.adapter_source_ready) begin
            if ($isunknown(dut.adapter_source_data_s8))
                $fatal(1,"unknown CNN source at (%0d,%0d): %h",dut.adapter_source_x,
                       dut.adapter_source_y,dut.adapter_source_data_s8);
            if(numeric_inputs>=FRAME_W*FRAME_H) $fatal(1,"numerical source trace exceeded one configured frame");
            numeric_inputs=numeric_inputs+1;
            $display("C1_NUM_IN %0d %0d %016h",dut.adapter_source_x,
                     dut.adapter_source_y,dut.adapter_source_data_s8);
        end
        if(numeric_compute_trace_enable && dut.adapter_result_valid && dut.adapter_result_ready) begin
            if ($isunknown(dut.adapter_result_data_s8))
                $fatal(1,"unknown CNN result at stage %0d",dut.u_tensor_adapter.stage_index_q);
            if(numeric_outputs>=numeric_expected_results) $fatal(1,"numerical result trace exceeded trained topology");
            numeric_outputs=numeric_outputs+1;
            $display("C1_NUM_OUT %0d %0d %0d %0d %016h",
                     dut.u_tensor_adapter.stage_index_q,dut.adapter_result_x,
                     dut.adapter_result_y,dut.adapter_result_group_index,dut.adapter_result_data_s8);
        end
    end
`endif
`ifdef C1_TWO_FRAME_TRACE
    // Separate two-job trace; do not relax the older single-frame checker.
`ifdef C1_COLOR_FIXTURE
    initial $display("C1_NUM_TWO_FIXTURE color_rggb");
`endif
`ifdef C1_PREVIEW_DISPLAY
    initial $display("C1_NUM_TWO_PREVIEW_MODE source=12x10 slots=01000000,01000100 stride=32");
`endif
    logic [31:0] two_video_id=0;
    logic [9:0] two_raw_x=0,two_styled_x=0;
    logic [8:0] two_raw_y=0,two_styled_y=0;
    logic two_select_raw=0,two_select_styled=0;
    logic [23:0] two_expected_compositor;
    always @(posedge pixel_clk) begin
        if(dut.u_display.pair_pixel_reset || dut.u_display.pixel_rst) begin
            two_select_raw=0;two_select_styled=0;
        end else begin
            two_expected_compositor=0;
            if(dut.u_display.timing_frame_start)
                $display("C1_PERF_TWO_VIDEO_BOUNDARY frame=%0d enable_sync=%0b enable_frame=%0b hold=%0b t=%0t",
                    dut.control_display_frame_id,dut.u_display.request_enable_sync2_q,
                    dut.u_display.request_enable_frame_q,dut.display_hold_requests,$time);
            if(two_select_raw && dut.u_display.original_response_valid)
                two_expected_compositor=dut.u_display.original_rgb;
            else if(two_select_styled && dut.u_display.styled_response_valid)
                two_expected_compositor=dut.u_display.styled_rgb;
            if(dut.u_display.original_response_valid || dut.u_display.styled_response_valid) begin
                if($isunknown(two_video_id) || two_video_id>1)
                    $fatal(1,"two-frame video has invalid request frame tag");
            end
            if(dut.u_display.original_response_valid && two_video_raw[two_video_id]<64) begin
                $display("C1_NUM_TWO_VIDEO_RAW %0d %0d %0d %08h",two_video_id,two_raw_x,two_raw_y,{8'd0,dut.u_display.original_rgb});
                two_video_raw[two_video_id]++;
            end
            if(dut.u_display.styled_response_valid && two_video_styled[two_video_id]<64) begin
                $display("C1_NUM_TWO_VIDEO_STYLED %0d %0d %0d %08h",two_video_id,two_styled_x,two_styled_y,{8'd0,dut.u_display.styled_rgb});
                two_video_styled[two_video_id]++;
            end
            // Snapshot the manager's committed frame ID with the request,
            // not the currently running CNN job (which may already be newer).
            two_video_id=dut.control_display_frame_id;
            two_raw_x=dut.u_display.prefetch_original_x;two_raw_y=dut.u_display.prefetch_original_y;
            two_styled_x=dut.u_display.prefetch_styled_x;two_styled_y=dut.u_display.prefetch_styled_y;
            two_select_raw=dut.u_display.compositor_original_request;
            two_select_styled=dut.u_display.compositor_styled_request;
            #1;
            if(dut.u_display.compositor_rgb!==two_expected_compositor)
                $fatal(1,"two-frame compositor response alignment mismatch");
        end
    end
    always @(posedge core_clk) if(!dut.core_rst) begin : two_frame_trace
        logic [31:0] address_value;
        logic [127:0] line_value;
        if(dut.boardless_start_valid && dut.boardless_start_ready) begin
            two_job=two_job+1;
            if(two_job>1 || dut.boardless_output_index!==two_job || dut.boardless_input_index!==two_job)
                $fatal(1,"two-frame trace unexpected admission/slot");
            $display("C1_NUM_TWO_BEGIN %0d %0d %0d",two_job,dut.boardless_input_index,dut.boardless_output_index);
        end
        if(dut.adapter_source_valid && dut.adapter_source_ready) begin
            if(two_job<0 || two_job>1 || two_inputs[two_job]>=64 || $isunknown(dut.adapter_source_data_s8))
                $fatal(1,"two-frame source accounting/unknown");
            two_inputs[two_job]++;
            $display("C1_NUM_TWO_IN %0d %0d %0d %016h",two_job,dut.adapter_source_x,dut.adapter_source_y,dut.adapter_source_data_s8);
        end
        if(dut.adapter_result_valid && dut.adapter_result_ready) begin
            if(two_job<0 || two_job>1 || two_outputs[two_job]>=((dut.ELIDE_VIRTUAL_UPSAMPLE?660:836)-(dut.FUSE_FINAL_OUTPUT?64:0)) || $isunknown(dut.adapter_result_data_s8))
                $fatal(1,"two-frame result accounting/unknown");
            two_outputs[two_job]++;
            $display("C1_NUM_TWO_OUT %0d %0d %0d %0d %0d %016h",two_job,dut.u_tensor_adapter.stage_index_q,
                dut.adapter_result_x,dut.adapter_result_y,dut.adapter_result_group_index,dut.adapter_result_data_s8);
        end
        if(dut.boardless_done) begin
            if(two_completed!=two_job || two_inputs[two_job]!=64 || two_outputs[two_job]!=((dut.ELIDE_VIRTUAL_UPSAMPLE?660:836)-(dut.FUSE_FINAL_OUTPUT?64:0)) ||
               dut.resolved_output_base!==OUTPUT_BASE+two_job*FRAME_SLOT_BYTES ||
               dut.resolved_input_base!==INPUT_BASE+two_job*INPUT_SLOT_BYTES)
                $fatal(1,"two-frame completion mismatch/metadata alias");
            for(integer p=0;p<64;p++) begin
                address_value=OUTPUT_BASE+two_job*FRAME_SLOT_BYTES+p*4;
                if(two_written[(address_value-OUTPUT_BASE) +: 4]!==4'hf || !mem_line_assoc.exists(address_value[31:4]))
                    $fatal(1,"two-frame DDR missing physical pixel writes");
                line_value=mem_line_assoc[address_value[31:4]];
                if($isunknown(line_value[(p%4)*32 +: 32])) $fatal(1,"two-frame DDR unknown pixel");
                $display("C1_NUM_TWO_DDR %0d %0d %0d %08h",two_job,p%8,p/8,line_value[(p%4)*32 +: 32]);
            end
`ifdef C1_PREVIEW_DISPLAY
            if(dut.AXI_CLIENTS!=8 || preview_aw!=8 || preview_w!=16 || preview_b!=8 ||
               preview_accepted_base!==32'h01000000+two_job*256)
                $fatal(1,"two-frame preview slot/retirement mismatch");
            for(integer p=0;p<64;p++) begin
                address_value=32'h01000000+two_job*256+p*4;
                if(preview_written[(address_value-32'h01000000) +: 4]!==4'hf || !mem_line_assoc.exists(address_value[31:4]))
                    $fatal(1,"two-frame preview missing physical byte writes");
                line_value=mem_line_assoc[address_value[31:4]];
                $display("C1_NUM_TWO_PREVIEW %0d %0d %0d %08h",two_job,p%8,p/8,line_value[(p%4)*32 +: 32]);
            end
            $display("C1_NUM_TWO_PREVIEW_RETIRED %0d 8 16 8",two_job);
`endif
            $display("C1_NUM_TWO_END %0d",two_job);
            two_completed++;
        end
    end
`endif
    integer expected_config_errors=0;
    logic expecting_config_reject=0;
    integer descriptor_fire_count=0;
    logic [21:0] descriptor_stage_seen=22'd0;
    logic display_done_seen=1'b0;
    integer display_swap_count=0;
    integer qos_start_count=0;
    integer qos_prefetch_done_count=0;
    integer qos_new_done_count=0;
    integer qos_swap_event_count=0;
    integer capture_drop_count=0;
    always @(posedge core_clk) begin
        if (arst_n) begin
            if (dut.control_done_event) done_seen <= done_seen + 1;
            if (dut.control_error_event) begin
                error_seen <= error_seen + 1;
                $display("portable SoC control error code=%02x addr=%08x",
                         dut.control_error_code,dut.control_error_address);
            end
            if (dut.u_microstyle.u_cnn.u_engine.raw_descriptor_fire) begin
                descriptor_fire_count <= descriptor_fire_count + 1;
                descriptor_stage_seen[dut.u_microstyle.u_cnn.u_engine.stage_index_q] <= 1'b1;
            end
            if (dut.display_prefetch_done)
                begin
                    display_done_seen <= 1'b1;
                    qos_prefetch_done_count <= qos_prefetch_done_count + 1;
                end
            if (dut.display_prefetch_new_done_event)
                qos_new_done_count <= qos_new_done_count + 1;
            if (dut.control_display_swap_event)
                begin
                    display_swap_count <= display_swap_count + 1;
                    qos_swap_event_count <= qos_swap_event_count + 1;
                end
            if (dut.qos_frame_start_event)
                qos_start_count <= qos_start_count + 1;
            if (dut.control_capture_drop_event)
                capture_drop_count <= capture_drop_count + 1;
            if (dut.u_microstyle.cnn_error || dut.u_boardless.compute_error ||
                (dut.u_control.fatal_now
                 && !(expecting_config_reject && dut.u_control.fatal_code==8'h12 &&
                      dut.u_control.fatal_address==DESC_BASE)
                 && !(RAW_FAULT_CFG && release_raw_fault && error_seen==0 &&
                      dut.capture_error && dut.capture_error_code==EXPECT_RAW_CODE &&
                      dut.u_control.fatal_code==EXPECT_CONTROL_CODE && dut.u_control.fatal_address==0)
`ifdef C1_PREVIEW_BRESP_ERROR
                 && !(preview_fault_responses==1 && dut.u_control.fatal_code==8'h63 &&
                      dut.u_control.fatal_address==32'h01000000)
`endif
`ifdef C1_DISPLAY_FAULT_RECOVERY
                 && !(injected_faults==1 && dut.u_control.fatal_code==8'h70)
`endif
                )) begin
                // Keep the failure actionable for scaled-frame bring-up: an
                // engine cycle-budget error usually means that a stage is
                // waiting for a missing/incorrectly shaped input beat, not
                // that the DDR BFM merely ran out of sparse storage.
                $display("diag bases input=%08x output=%08x capture=%08x/%0dx%0d writer_busy=%0b writer_done=%0b writer_err=%0b",
                         dut.u_boardless.resolved_input_base,
                         dut.u_boardless.resolved_output_base,
                         dut.u_control.capture_writer_base,
                         dut.u_control.capture_writer_width,
                         dut.u_control.capture_writer_height,
                         dut.u_capture.u_writer.busy,
                         dut.u_capture.u_writer.done,
                         dut.u_capture.u_writer.error);
                $display("diag input_dma state=%0d busy/done/err=%0b/%0b/%0b row=%0d addr=%08x row_beats=%0d burst=%0d/%0d lane=%0d xy=%0d,%0d shell_ready=%0b stream=%0b/%0b/%0b/%0b/%0b",
                         dut.u_boardless.u_input_dma.state,
                         dut.u_boardless.u_input_dma.busy,
                         dut.u_boardless.u_input_dma.done,
                         dut.u_boardless.u_input_dma.error,
                         dut.u_boardless.u_input_dma.current_row,
                         dut.u_boardless.u_input_dma.current_addr,
                         dut.u_boardless.u_input_dma.row_beats_remaining,
                         dut.u_boardless.u_input_dma.burst_beat_index,
                         dut.u_boardless.u_input_dma.burst_beats_target,
                         dut.u_boardless.u_input_dma.pixel_lane,
                         dut.u_boardless.u_input_dma.output_x,
                         dut.u_boardless.u_input_dma.output_y,
                         dut.u_boardless.shell_dma_ready,
                         dut.u_boardless.input_stream_valid,
                         dut.u_boardless.input_stream_ready,
                         dut.u_boardless.input_stream_sof,
                         dut.u_boardless.input_stream_eol,
                         dut.u_boardless.input_stream_eof);
                $display("diag axi reader ar=%0b/%0b addr=%08x len=%0d active=%0b rvalid=%0b idx=%0d/%0d base=%08x",
                         dut.u_boardless.reader_arvalid,
                         dut.u_boardless.reader_arready,
                         dut.u_boardless.reader_araddr,
                         dut.u_boardless.reader_arlen,
                         r_active,
                         rvalid_q,
                         r_index_q,
                         ar_len_q,
                         ar_base_q);
                $display("diag ingress active=%0b resize_busy=%0b resize_req=%0b/%0b out=%0b/%0b xy=%0d,%0d",
                         dut.u_boardless.u_compute_shell.u_compute_ingress.ingress_active,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.resize_busy,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.u_request.busy,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.u_request.req_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.out_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.out_ready,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.out_x,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.out_y);
                $display("diag sampler src=%0b/%0b expected=%0d,%0d done=%0b rows=%0b/%0b tags=%0d/%0d req=%0b/%0b",
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.src_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.src_ready,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.expected_src_x,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.expected_src_y,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.source_done,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.line0_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.line1_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.line0_y,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_line_sampler.line1_y,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.sample_req_valid,
                         dut.u_boardless.u_compute_shell.u_compute_ingress.u_resize_pipeline.u_resize_system.sample_req_ready);
                $display("diag adapter state=%0d stage=%0d src=%0d,%0d out=%0d,%0d err=%0b/%02x cfg=%0b mem=%0b/%0b cache=%0b/%0b",
                         dut.u_tensor_adapter.state_q,
                         dut.u_tensor_adapter.stage_index_q,
                         dut.u_tensor_adapter.source_x_q,
                         dut.u_tensor_adapter.source_y_q,
                         dut.u_tensor_adapter.output_x_q,
                         dut.u_tensor_adapter.output_y_q,
                         dut.u_tensor_adapter.error_q,
                         dut.u_tensor_adapter.error_code_q,
                         dut.u_tensor_adapter.config_complete_q,
                         dut.u_tensor_adapter.mem_req_valid,
                         dut.u_tensor_adapter.mem_rsp_valid,
                         dut.tensor_cache_busy,
                         dut.tensor_cache_quiescent);
`ifdef C1_TENSOR_BURST_REFILL
                $display("diag burst_client owner=%0d bridge_inflight=%0b route_burst=%0b route_bridge=%0b stage_en=%0b reject=%0b cfg=%0b burst_busy=%0b burst_q=%0b tap=%0b/%0b bridge_req=%0b/%0b rsp=%0b/%0b",
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.owner_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.bridge_inflight_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.route_burst,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.route_bridge,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.stage_cache_enable_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.stage_reject_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.burst_config_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.burst_busy,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.burst_quiescent,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.burst_tap_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.burst_tap_ready,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.bridge_req_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.bridge_req_ready,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.s_rsp_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.s_rsp_ready);
                $display("diag burst_shell cache_cfg=%0b cache_busy/q=%0b/%0b exact_busy/q=%0b/%0b cmd_hold=%0b start_gate=%0b cache_tap=%0b/%0b refill=%0b/%0b exact_cmd=%0b/%0b",
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_config_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_busy,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_quiescent,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.exact_busy,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.exact_quiescent,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cmd_hold_valid_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.start_gate,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_tap_ready,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.tap_ready,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_refill_req_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.cache_refill_req_ready,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.exact_cmd_valid,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.exact_cmd_ready);
                $display("diag burst_deep cache_state=%0d refill_index=%0d addr_pending=%0b read_pending=%0b tap_rsp=%0b exact_core_busy/q=%0b/%0b core_cmd_occ=%0d core_out=%0d comp_active=%0b synth=%0b comp_words=%0d",
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.g_scalar.u_cache.state_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.g_scalar.u_cache.refill_word_index_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.g_scalar.u_cache.address_pending_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.g_scalar.u_cache.read_pending_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.g_scalar.u_cache.tap_rsp_valid_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.core_busy,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.core_quiescent,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.core_cmd_occupancy,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.core_outstanding,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_completion.active_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_completion.synthetic_q,
                         dut.g_tensor_burst_refill.u_tensor_cache_axi_client.u_burst_cache.u_exact.u_completion.next_index_q);
`endif
                $fatal(1,"portable SoC compute/control error code=%02x/%02x/%02x stage=%0d state=%0d stage_cycle=%0d budget=%0d dims=%0dx%0d->%0dx%0d exp=%0d,%0d grp=%0d in=%0b/%0b xy=%0d,%0d sof/eol/eof=%0b/%0b/%0b resolved=%0dx%0d->%0dx%0d dma=%0dx%0d idx=%0d/%0d cfg_h=%0d",
                       dut.u_microstyle.cnn_error_code,
                       dut.u_boardless.compute_error_code,
                       dut.u_control.fatal_code,
                       dut.u_microstyle.u_cnn.u_engine.stage_index_q,
                       dut.u_microstyle.u_cnn.u_engine.state_q,
                       dut.u_microstyle.u_cnn.u_engine.stage_cycle_q,
                       dut.u_microstyle.u_cnn.u_engine.cycle_budget_q,
                       dut.u_microstyle.u_cnn.u_engine.input_width_q,
                       dut.u_microstyle.u_cnn.u_engine.input_height_q,
                       dut.u_microstyle.u_cnn.u_engine.output_width_q,
                       dut.u_microstyle.u_cnn.u_engine.output_height_q,
                       dut.u_microstyle.u_cnn.u_engine.expected_x_q,
                       dut.u_microstyle.u_cnn.u_engine.expected_y_q,
                       dut.u_microstyle.u_cnn.u_engine.expected_input_group_q,
                       dut.u_microstyle.u_cnn.u_engine.in_valid,
                       dut.u_microstyle.u_cnn.u_engine.in_ready,
                       dut.u_microstyle.u_cnn.u_engine.in_x,
                       dut.u_microstyle.u_cnn.u_engine.in_y,
                       dut.u_microstyle.u_cnn.u_engine.in_sof,
                        dut.u_microstyle.u_cnn.u_engine.in_eol,
                        dut.u_microstyle.u_cnn.u_engine.in_eof,
                        dut.u_boardless.resolved_input_width,
                       dut.u_boardless.resolved_input_height,
                       dut.u_boardless.resolved_output_width,
                       dut.u_boardless.resolved_output_height,
                       dut.u_boardless.u_input_dma.width_reg,
                       dut.u_boardless.u_input_dma.height_reg,
                       dut.u_control.nn_input_index_q,
                        dut.u_control.manager_nn_input_index,
                        dut.u_control.cfg_frame_height_q);
            end
            if (engine_overflow_seen || camera_overflow)
                $fatal(1,"capture/engine overflow asserted");
            if (dut.qos_frame_start_event || dut.display_prefetch_done ||
                dut.display_prefetch_new_done_event ||
                dut.control_display_swap_event) begin
`ifdef C1_SHARED_QOS_MONITOR
                $display("C1_QOS_EVENT t=%0t start=%0b raw_done=%0b new_done=%0b swap=%0b active_tag=%0b loading_new=%0b request_new=%0b prefetch_busy=%0b monitor_active=%0b monitor_frame=%0d",
                         $time,dut.qos_frame_start_event,
                         dut.display_prefetch_done,
                         dut.display_prefetch_new_done_event,
                         dut.control_display_swap_event,
                         dut.u_control.prefetch_active_is_new_q,
                         dut.u_control.prefetch_loading_new_q,
                         dut.u_control.prefetch_request_is_new_q,
                         dut.display_prefetch_busy,
                         dut.g_shared_qos_monitor.u_monitor.frame_active,
                         dut.g_shared_qos_monitor.u_monitor.frame_count);
`else
                // Keep the event trace format stable without referring to the
                // optional monitor hierarchy when it is compiled out.
                $display("C1_QOS_EVENT t=%0t start=%0b raw_done=%0b new_done=%0b swap=%0b active_tag=%0b loading_new=%0b request_new=%0b prefetch_busy=%0b monitor_active=0 monitor_frame=0",
                         $time,dut.qos_frame_start_event,
                         dut.display_prefetch_done,
                         dut.display_prefetch_new_done_event,
                         dut.control_display_swap_event,
                         dut.u_control.prefetch_active_is_new_q,
                         dut.u_control.prefetch_loading_new_q,
                         dut.u_control.prefetch_request_is_new_q,
                         dut.display_prefetch_busy);
`endif
            end
        end
    end

    initial begin : check_engine_options
        #1;
        $display("C1_NUM_TENSOR_WRITE_MLP outstanding=%0d",dut.TENSOR_WRITE_OUTSTANDING);
        $display("C1_NUM_PIXEL_WRITE_BATCH words=%0d build_timeout=%0d",
            dut.PIXEL_WRITE_BATCH_WORDS,dut.TENSOR_WRITE_BUILD_TIMEOUT);
        if(dut.PIXEL_WRITE_BATCH_WORDS!=`C1_PIXEL_WRITE_BATCH_WORDS ||
           dut.TENSOR_WRITE_BUILD_TIMEOUT!=`C1_TENSOR_WRITE_BUILD_TIMEOUT ||
           dut.PIXEL_WRITE_BATCH_WORDS!=dut.u_tensor_adapter.PIXEL_WRITE_BATCH_WORDS ||
           dut.PIXEL_WRITE_BATCH_WORDS!=dut.u_tensor_adapter.u_pixel_writer.BATCH_WORDS)
            $fatal(1,"pixel write batch/timeout selection lost at boundary");
        if(dut.TENSOR_WRITE_OUTSTANDING!=`C1_TENSOR_WRITE_OUTSTANDING)
            $fatal(1,"tensor MLP selection lost at SoC boundary");
`ifdef C1_TENSOR_COLUMN_READS
        if(dut.TENSOR_WRITE_OUTSTANDING!=dut.g_tensor_column_reads.u_scalar.WRITE_OUTSTANDING)
            $fatal(1,"tensor MLP selection lost at packing boundary");
        if(dut.TENSOR_WRITE_BUILD_TIMEOUT!=dut.g_tensor_column_reads.u_scalar.WRITE_BUILD_TIMEOUT)
            $fatal(1,"tensor write timeout selection lost at packing boundary");
`endif
        if(dut.u_tensor_adapter.REUSE_HORIZONTAL_WINDOW != REUSE_HORIZONTAL_WINDOW_CFG)
            $fatal(1,"horizontal reuse option did not reach adapter");
        $display("C1_NUM_HORIZONTAL_REUSE_OPTION enabled=%0d",dut.u_tensor_adapter.REUSE_HORIZONTAL_WINDOW);
        if(dut.ENABLE_TENSOR_COLUMN_READS != `C1_COLUMN_SOC_ENABLE ||
           dut.u_tensor_adapter.ENABLE_COLUMN_READS != `C1_COLUMN_SOC_ENABLE)
            $fatal(1,"SoC column option mismatch");
        $display("C1_NUM_COLUMN_OPTION enabled=%0d clients=%0d",dut.ENABLE_TENSOR_COLUMN_READS,dut.AXI_CLIENTS);
`ifdef C1_TENSOR_COLUMN_READS
        if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.READ_ON_LOOKUP != dut.TENSOR_COLUMN_READ_ON_LOOKUP)
            $fatal(1,"column lookup option did not reach physical cache controller");
        if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.RESPONSE_BYPASS != dut.TENSOR_COLUMN_RESPONSE_BYPASS)
            $fatal(1,"column response bypass did not reach physical cache controller");
        if(dut.g_tensor_column_reads.u_column.u_backend.g_column.u_cache.REUSE_ROW_MAP != dut.TENSOR_COLUMN_REUSE_ROW_MAP)
            $fatal(1,"column row-map option did not reach physical cache controller");
`endif
        $display("C1_NUM_COLUMN_RESPONSE_BYPASS enabled=%0d",dut.TENSOR_COLUMN_RESPONSE_BYPASS);
        $display("C1_NUM_COLUMN_ROW_MAP enabled=%0d",dut.TENSOR_COLUMN_REUSE_ROW_MAP);
        if(dut.PREFETCH_NEXT_PIXEL_COLUMN!=dut.u_tensor_adapter.PREFETCH_NEXT_PIXEL_COLUMN)
            $fatal(1,"pixel column prefetch did not reach tensor adapter");
        $display("C1_NUM_PIXEL_COLUMN_PREFETCH enabled=%0d",dut.PREFETCH_NEXT_PIXEL_COLUMN);
        $display("C1_NUM_ALL_PIXEL_GROUPS enabled=%0d",dut.PREFETCH_ALL_PIXEL_GROUPS);
        $display("C1_NUM_DOT_PIXEL_PIPELINE enabled=%0d",dut.PIPELINE_DOT_PIXELS);
        $display("C1_NUM_ALL_DOT_GROUPS enabled=%0d",dut.PIPELINE_ALL_DOT_GROUPS);
        $display("C1_NUM_RGB_REDUCTION enabled=%0d",dut.PACK_RGB_CONV_REDUCTION);
        $display("C1_NUM_VIEW_ELISION enabled=%0d",dut.ELIDE_VIRTUAL_UPSAMPLE);
        $display("C1_NUM_FINAL_FUSION enabled=%0d",dut.FUSE_FINAL_OUTPUT);
        if(dut.FUSE_FINAL_OUTPUT!=dut.u_tensor_adapter.FUSE_FINAL_OUTPUT ||
           dut.FUSE_FINAL_OUTPUT!=dut.u_microstyle.u_cnn.u_engine.FUSE_FINAL_OUTPUT)
            $fatal(1,"final fusion option did not reach both engine and adapter");
        if(dut.ELIDE_VIRTUAL_UPSAMPLE!=dut.u_tensor_adapter.ELIDE_VIRTUAL_UPSAMPLE ||
           dut.ELIDE_VIRTUAL_UPSAMPLE!=dut.u_microstyle.u_cnn.u_engine.ELIDE_VIRTUAL_UPSAMPLE)
            $fatal(1,"view elision option did not reach both owners");
        if(dut.PACK_RGB_CONV_REDUCTION!=dut.u_microstyle.u_cnn.u_engine.PACK_RGB_CONV_REDUCTION)
            $fatal(1,"RGB reduction option did not reach actual engine");
        if(dut.PIPELINE_ALL_DOT_GROUPS!=dut.u_tensor_adapter.PIPELINE_ALL_DOT_GROUPS ||
           dut.PIPELINE_ALL_DOT_GROUPS!=dut.u_microstyle.u_cnn.u_engine.PIPELINE_ALL_DOT_GROUPS ||
           ((dut.PIPELINE_DW_PIXELS || dut.PIPELINE_ALL_DOT_GROUPS)!=dut.u_tensor_adapter.u_pixel_writer.MULTI_GROUP))
            $fatal(1,"all dot groups did not reach both scheduler endpoints and result sink");
        $display("C1_NUM_DW_PIXEL_PIPELINE enabled=%0d",dut.PIPELINE_DW_PIXELS);
        $display("C1_NUM_DW_FRAME_STREAM enabled=%0d",dut.STREAM_DW_FRAME);
        if(dut.STREAM_DW_FRAME!=dut.u_microstyle.STREAM_DW_FRAME ||
           dut.STREAM_DW_FRAME!=dut.u_microstyle.u_cnn.STREAM_DW_FRAME ||
           dut.STREAM_DW_FRAME!=dut.u_microstyle.u_cnn.u_engine.STREAM_DW_FRAME)
            $fatal(1,"DW frame stream option did not reach actual engine");
        if(dut.PIPELINE_DW_PIXELS!=dut.u_tensor_adapter.PIPELINE_DW_PIXELS ||
           dut.PIPELINE_DW_PIXELS!=dut.u_microstyle.u_cnn.u_engine.PIPELINE_DW_PIXELS)
            $fatal(1,"DW pixel pipeline did not reach both scheduler endpoints and result sink");
        if(dut.PIPELINE_DOT_PIXELS!=dut.u_tensor_adapter.PIPELINE_DOT_PIXELS ||
           dut.PIPELINE_DOT_PIXELS!=dut.u_microstyle.u_cnn.u_engine.PIPELINE_DOT_PIXELS)
            $fatal(1,"dot pixel pipeline did not reach both scheduler endpoints");
        if(dut.PREFETCH_ALL_PIXEL_GROUPS!=dut.u_tensor_adapter.PREFETCH_ALL_PIXEL_GROUPS)
            $fatal(1,"all-group prefetch parameter not forwarded");
        $display("C1_NUM_SOURCE_PIPELINE enabled=%0d",dut.PIPELINED_SOURCE_WRITES);
        if(dut.PIPELINED_SOURCE_WRITES!=dut.u_tensor_adapter.PIPELINED_SOURCE_WRITES)
            $fatal(1,"source write pipeline parameter not forwarded");
        $display("C1_NUM_COLUMN_LOOKUP enabled=%0d",dut.TENSOR_COLUMN_READ_ON_LOOKUP);
        $display("C1_NUM_SCALAR_READ_CACHE enabled=%0d",dut.TENSOR_SCALAR_READ_BEAT_CACHE);
        $display("C1_NUM_SCALAR_CACHE_ENTRIES entries=%0d",dut.TENSOR_SCALAR_READ_CACHE_ENTRIES);
        $display("C1_NUM_PRECISE_WRITE_INVALIDATION enabled=%0d",dut.TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION);
        if(dut.u_tensor_adapter.VIRTUAL_UPSAMPLE_TENSORS != dut.VIRTUAL_UPSAMPLE_TENSORS)
            $fatal(1,"virtual upsample option did not reach tensor adapter");
        $display("C1_NUM_VIRTUAL_UPSAMPLE enabled=%0d",dut.u_tensor_adapter.VIRTUAL_UPSAMPLE_TENSORS);
        if(dut.u_microstyle.u_cnn.u_engine.STREAM_DW_GROUPS!=dut.STREAM_DW_GROUPS ||
           dut.u_microstyle.u_cnn.u_engine.u_dw_core.PER_BEAT_CONFIG!=dut.STREAM_DW_GROUPS)
            $fatal(1,"DW group streaming option failed to reach engine/core");
        $display("C1_NUM_DW_STREAM enabled=%0d",dut.STREAM_DW_GROUPS);
        $display("C1_NUM_MAC_REQUANT_OVERLAP enabled=%0d",dut.OVERLAP_MAC_REQUANTIZATION);
        if(dut.OVERLAP_MAC_REQUANTIZATION!=dut.u_microstyle.u_cnn.u_engine.u_dot_core.OVERLAP_REQUANTIZATION)
            $fatal(1,"MAC/requant option not forwarded to actual core");
        $display("C1_NUM_POINTWISE_REDUCTION enabled=%0d",dut.STREAM_POINTWISE_REDUCTION);
        if(dut.STREAM_POINTWISE_REDUCTION!=dut.u_microstyle.u_cnn.u_engine.STREAM_POINTWISE_REDUCTION)
            $fatal(1,"pointwise reduction option not forwarded to engine");
        if(dut.u_tensor_adapter.OVERLAP_COLUMN_WRITEBACK!=dut.OVERLAP_COLUMN_WRITEBACK)
            $fatal(1,"column/write overlap option did not reach tensor adapter");
        $display("C1_NUM_COLUMN_WRITE_OVERLAP enabled=%0d",dut.OVERLAP_COLUMN_WRITEBACK);
        if(dut.u_tensor_adapter.POINTWISE_COLUMN_READS!=dut.POINTWISE_COLUMN_READS)
            $fatal(1,"pointwise column-read option did not reach tensor adapter");
        $display("C1_NUM_POINTWISE_COLUMN_READS enabled=%0d",dut.POINTWISE_COLUMN_READS);
`ifdef C1_TENSOR_COLUMN_READS
        if(dut.g_tensor_column_reads.u_scalar.PRECISE_WRITE_INVALIDATION != dut.TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION)
            $fatal(1,"precise invalidation option did not reach scalar wrapper");
`ifdef C1_TENSOR_PACKED_WRITES
        if(dut.g_tensor_column_reads.u_scalar.g_packed.u_read.PRECISE_WRITE_INVALIDATION != dut.TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION)
`else
        if(dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.PRECISE_WRITE_INVALIDATION != dut.TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION)
`endif
            $fatal(1,"precise invalidation option did not reach read bridge");
`ifdef C1_TENSOR_PACKED_WRITES
        if(dut.g_tensor_column_reads.u_scalar.g_packed.u_read.ENABLE_READ_BEAT_CACHE != dut.TENSOR_SCALAR_READ_BEAT_CACHE)
`else
        if(dut.g_tensor_column_reads.u_scalar.g_legacy.u_bridge.ENABLE_READ_BEAT_CACHE != dut.TENSOR_SCALAR_READ_BEAT_CACHE)
`endif
            $fatal(1,"scalar read cache option did not reach the AXI read bridge");
`endif
        $display("C1_NUM_TENSOR_WRITE_OPTIONS packed=%0d pipeline=%0d end=%0d",
            dut.ENABLE_TENSOR_PACKED_WRITES,dut.PIPELINED_RESULT_WRITES,dut.USE_TENSOR_WRITE_END);
        if(dut.u_tensor_adapter.PREFETCH_NEXT_TAP_ADDRESS != PREFETCH_NEXT_TAP_ADDRESS_CFG ||
           dut.u_tensor_adapter.PIPELINED_TENSOR_ADDRESS != PIPELINED_TENSOR_ADDRESS_CFG ||
           dut.u_tensor_adapter.PIPELINED_TENSOR_PIXEL_INDEX != PIPELINED_TENSOR_PIXEL_INDEX_CFG)
            $fatal(1,"actual tap-address options differ from requested build");
        $display("C1_NUM_TAP_ADDRESS_OPTIONS prefetch=%0d pipeline=%0d pixel_pipeline=%0d",
            dut.u_tensor_adapter.PREFETCH_NEXT_TAP_ADDRESS,
            dut.u_tensor_adapter.PIPELINED_TENSOR_ADDRESS,
            dut.u_tensor_adapter.PIPELINED_TENSOR_PIXEL_INDEX);
        if(dut.u_microstyle.u_cnn.u_engine.CACHE_DW_WEIGHT_TILES != CACHE_DW_WEIGHT_TILES_CFG ||
           dut.u_microstyle.u_cnn.u_engine.MAC_PREFETCH_OVERLAP != MAC_PREFETCH_OVERLAP_CFG)
            $fatal(1,"actual engine options differ from requested build");
        $display("C1_NUM_ENGINE_OPTIONS dw_cache=%0d mac_overlap=%0d",
            dut.u_microstyle.u_cnn.u_engine.CACHE_DW_WEIGHT_TILES,
            dut.u_microstyle.u_cnn.u_engine.MAC_PREFETCH_OVERLAP);
    end
    initial begin : main_test
        logic [31:0] status_word;
        logic [31:0] qos_apb_status;
        logic [31:0] qos_apb_frame_count;
        logic [31:0] qos_apb_last_frame;
        logic [31:0] qos_apb_deadline;
        logic [31:0] qos_apb_underflow;
        logic [31:0] qos_apb_read_busy;
        logic [31:0] qos_apb_write_busy;
        logic [31:0] qos_apb_read_owner_max;
        logic [31:0] qos_apb_write_owner_max;
        logic [31:0] qos_apb_protocol;
        integer wait_cycles;
        integer i;
        integer first_descriptor_count;
        integer first_swap_count;
        if (TRAINED_ARTIFACT_CFG) begin
            // The detached runner generates size-matched compact files in its
            // disposable working directory.  A direct Icarus invocation can
            // do the same before starting vvp.  No large simulator database
            // is needed; the arrays contain only the descriptor/arena ABI.
            $readmemh("trained_descriptors.mem", trained_descriptors);
            $readmemh("trained_parameter_arena.mem", trained_parameter_mem);
            for(integer si=0;si<22;si++) begin
                if($isunknown(trained_descriptors[si]) ||
                   trained_descriptors[si][7:0] != stage_opcode(si) ||
                   trained_descriptors[si][47:32] != stage_iw(si) ||
                   trained_descriptors[si][63:48] != stage_ih(si) ||
                   trained_descriptors[si][79:64] != stage_ow(si) ||
                   trained_descriptors[si][95:80] != stage_oh(si) ||
                   trained_descriptors[si][111:96] != stage_cin(si) ||
                   trained_descriptors[si][127:112] != stage_cout(si))
                    $fatal(1,"trained descriptor shape/topology mismatch stage=%0d frame=%0dx%0d",si,FRAME_W,FRAME_H);
`ifdef C1_NUMERICAL_TRACE
                if(!((dut.ELIDE_VIRTUAL_UPSAMPLE && (si==14 || si==17)) || (dut.FUSE_FINAL_OUTPUT && si==21)))
                numeric_expected_results += trained_descriptors[si][79:64] *
                    trained_descriptors[si][95:80] * ((trained_descriptors[si][127:112]+7)/8);
`endif
            end
            for(integer pi=0;pi<1056;pi++)
                if($isunknown(trained_parameter_mem[pi])) $fatal(1,"missing trained arena word %0d",pi);
`ifdef C1_NUMERICAL_TRACE
            $display("C1_NUM_SHAPE width=%0d height=%0d C8_results=%0d",FRAME_W,FRAME_H,numeric_expected_results);
`endif
        end
        if ((FRAME_W >= 640) &&
            (OUTPUT_BASE <= (INPUT_BASE + (3 * INPUT_SLOT_BYTES))))
            $fatal(1, "native frame table address regions overlap input=%08x output=%08x slot=%0d",
                   INPUT_BASE, OUTPUT_BASE, FRAME_SLOT_BYTES);
        if ((FRAME_W >= 640) &&
            ((OUTPUT_BASE + (2 * FRAME_SLOT_BYTES)) >= TENSOR_BASE))
            $fatal(1, "native output arena overlaps tensor arena output=%08x tensor=%08x",
                   OUTPUT_BASE, TENSOR_BASE);
        if ((FRAME_W >= 640) && !USE_ASSOC_MEM)
            $fatal(1, "native frame requires address-keyed DDR store");
        for (i=0;i<MEM_SLOTS;i=i+1) begin
            mem_valid[i]=1'b0; mem_tag[i]=32'd0; mem_line[i]=128'd0;
        end
        if(TRAINED_ARTIFACT_CFG) begin : check_address_preservation
            // Real memory-model tasks, before clocks leave reset. These two
            // different DDR lines collide under the legacy direct index.
            if(!USE_ASSOC_MEM || line_index(32'h0280_0100)!=line_index(32'h0200_0500))
                $fatal(1,"invalid trained DDR address-preservation self-test");
            store_beat(32'h0280_0100,128'h00112233445566778899aabbccddeeff,16'hffff);
            store_beat(32'h0200_0500,128'hffeeddccbbaa99887766554433221100,16'hffff);
            store_beat(32'h0280_0100,128'd0,16'h00f0);
            if(read_beat(32'h0280_0100)!==128'h001122334455667700000000ccddeeff ||
               read_beat(32'h0200_0500)!==128'hffeeddccbbaa99887766554433221100)
                $fatal(1,"DDR address preservation or byte strobe failure");
            mem_line_assoc.delete(); // remove self-test data before any DUT traffic
`ifdef C1_NUMERICAL_TRACE
            $display("C1_NUM_DDR_STORE address_keyed collision_pair=02800100:02000500 byte_strobes=1");
`endif
        end

        repeat (8) @(posedge core_clk);
        arst_n <= 1'b1;
        repeat (12) @(posedge core_clk);

        // Scalar ISP reset values are identity; Gamma RAM is NOT reset.
        // Program all entries through the real APB path before capture.
        for (integer gamma_index=0; gamma_index<1024; gamma_index=gamma_index+1) begin
            apb_write(12'h260,gamma_index);
            apb_write(12'h264,gamma_index >> 2);
            apb_write(12'h268,32'd1);
        end
        // The scalar ISP CSR reset image is already a legal identity configuration.
        // Leave it uncommitted here: cfg_valid=0 makes the capture frontend
        // use that reset image immediately, avoiding a needless APB commit
        // race while the three clock domains are still releasing.
        repeat (20) @(posedge core_clk);

        // Legal parameterized job image.  Descriptor count remains the frozen
        // 22; the descriptor graph itself is intentionally independent of the
        // outer capture/display scale used by this BFM.
        apb_write(12'h040,IN_TABLE);
        apb_write(12'h048,OUT_TABLE);
        apb_write(12'h050,((FRAME_H << 16) | FRAME_W));
        apb_write(12'h054,SOURCE_STRIDE);
        apb_write(12'h058,XRGB_STRIDE);
        apb_write(12'h05c,32'h0000_0022);
        apb_write(12'h080,DESC_BASE);
        apb_write(12'h088,32'd22);
        apb_write(12'h090,WEIGHT_BASE);
        apb_write(12'h098,TENSOR_BASE);
        apb_write(12'h0c0,32'd0);
`ifdef C1_REJECT_GEOMETRY
        begin : reject_geometry_before_valid_job
            integer test_index, before_ar, before_aw, before_error;
            logic [31:0] bad_source;
            apb_write(12'h010,32'h1);
            for(test_index=0;test_index<6;test_index++) begin
                case(test_index)
                    0: bad_source=0; // inherits 8x8, incompatible with 12x10 sensor output
                    1: bad_source=(SOURCE_H<<16);
                    2: bad_source=SOURCE_W;
                    3: bad_source=(SOURCE_H<<16)|(SOURCE_W-4);
                    4: bad_source=((SOURCE_H-1)<<16)|SOURCE_W;
                    default: bad_source=(SOURCE_H<<16)|SOURCE_W;
                endcase
                apb_write(12'h060,bad_source);
                apb_write(12'h068,test_index==5 ? 32'hffffffff : TEST_YS);
                before_ar=axi_ar_count; before_aw=axi_aw_count; before_error=error_seen;
                expecting_config_reject=1;
                apb_write(12'h010,32'h13);
                repeat(64) begin
                    @(posedge core_clk);
                    if(arvalid || awvalid || wvalid || dut.parameter_start_valid ||
                       dut.capture_writer_start || dut.boardless_start_valid || dut.control_done_event)
                        $fatal(1,"invalid geometry launched external work test=%0d",test_index);
                end
                @(negedge core_clk);
                if(error_seen!=before_error+1 || axi_ar_count!=before_ar || axi_aw_count!=before_aw)
                    $fatal(1,"invalid geometry report/traffic count mismatch test=%0d",test_index);
                apb_read(12'h020,status_word);
                if(status_word!==32'h12) $fatal(1,"invalid geometry error code mismatch %h",status_word);
                apb_read(12'h014,status_word);
                if(status_word[1] || !status_word[3]) $fatal(1,"invalid geometry not idle/error");
                apb_write(12'h01c,32'h2);
                apb_read(12'h014,status_word);
                if(status_word[3]) $fatal(1,"geometry error W1C failed");
                expected_config_errors++;
                expecting_config_reject=0;
            end
            $display("C1_NUM_GEOMETRY_REJECT_PASS cases=6 no_axi=1 no_reset=1");
        end
`endif

        // Enable and arm one frame.  The camera source starts only after the
        // START edge, so the capture FIFO cannot silently discard its SOF.
        apb_write(12'h010,32'h1);
`ifdef C1_SOURCE_GEOMETRY
        apb_write(12'h060,((SOURCE_H<<16)|SOURCE_W));
        $display("C1_NUM_SOURCE 12x10");
`endif
`ifdef C1_RESIZE_FIXTURE
        // Explicit source geometry path; the unit fixture retains reset-zero
        // fallback so both software ABI modes receive full numeric coverage.
        apb_write(12'h060,((FRAME_H<<16)|FRAME_W));
`endif
        apb_write(12'h064,TEST_XS); apb_write(12'h068,TEST_YS);
        apb_write(12'h06c,TEST_XP); apb_write(12'h070,TEST_YP);
`ifdef C1_RESIZE_FIXTURE
        $display("C1_NUM_RESIZE reverse_fractional");
`endif
        apb_read(12'h010,status_word);
        $display("after enable CONTROL=%08x csr_enable=%0b",status_word,dut.csr_system_enable);
        apb_write(12'h010,CONCURRENT_CAPTURE_CFG ? 32'h1b : 32'h13);
        // START snapshots the geometry programmed before this point.
        $display("after start write csr_enable=%0b start_pulse=%0b run_armed=%0b",
                 dut.csr_system_enable,dut.csr_start_pulse,dut.u_control.run_armed_q);
        // Do not rely on the relative phase of camera/core clocks for SOF
        // admission.  Wait until the one-shot arm is visible in the core
        // domain and idle-frame discard is closed.
        wait_cycles=0;
        while ((!dut.u_control.run_armed_q || dut.capture_discard_idle) &&
               (wait_cycles < 1000)) begin
            @(posedge core_clk);
            wait_cycles=wait_cycles+1;
        end
        if (!dut.u_control.run_armed_q || dut.capture_discard_idle)
            $fatal(1,"camera started before one-shot admission opened");
`ifdef C1_NUMERICAL_TRACE
        // Busy writes update only the next launch. In particular a negative
        // live y step must not fault this already accepted job.
        apb_write(12'h064,32'hfffe8000);
        apb_write(12'h068,32'hffffffff);
        apb_write(12'h06c,32'h7fffffff);
        apb_write(12'h070,32'hffff8000);
        apb_read(12'h068,status_word);
        if(status_word !== 32'hffffffff || dut.boardless_resize_x_step !== TEST_XS ||
           dut.boardless_resize_y_step !== TEST_YS || dut.boardless_resize_x_phase0 !== TEST_XP ||
           dut.boardless_resize_y_phase0 !== TEST_YP || dut.control_error_event)
            $fatal(1,"Resize CSR write leaked into active launch");
        apb_write(12'h060,32'h00080000); // nonzero word with invalid zero width
        apb_read(12'h060,status_word);
        if(status_word !== 32'h00080000 || dut.boardless_source_width !== SOURCE_W ||
           dut.boardless_source_height !== SOURCE_H || dut.control_error_event)
            $fatal(1,"Source geometry CSR write leaked into active launch");
        apb_write(12'h060,32'd0);
        $display("C1_NUM_SOURCE_CSR_SNAPSHOT_PASS busy_writes=1");
        apb_write(12'h064,32'h10000); apb_write(12'h068,32'h10000);
        apb_write(12'h06c,32'd0); apb_write(12'h070,32'd0);
        $display("C1_NUM_RESIZE_CSR_SNAPSHOT_PASS busy_writes=4");
`endif
        send_camera_frame(10'd0);

`ifdef C1_PREVIEW_CANCEL
        begin : preview_cancel_check
            integer held_aw,held_b,held_capture;
            wait_cycles=0;
            while(!(queued_w_completed>axi_b_count && preview_cancel_head && !bvalid_q) && wait_cycles<2000000) begin
                @(negedge core_clk);wait_cycles++;
            end
            if(wait_cycles==2000000 || preview_aw!=8 || preview_w!=16 || preview_b!=7)
                $fatal(1,"preview cancel did not reach final physical B hold");
            apb_write(12'h010,32'h5);
            repeat(4) @(negedge core_clk);
            held_aw=axi_aw_count;held_b=axi_b_count;held_capture=capture_starts;
            // A START during drain must be rejected, never queued for replay.
            apb_write(12'h010,32'h13,1'b1);
            repeat(64) begin
                @(negedge core_clk);
                if(!system_busy || !dut.boardless_busy || !dut.fabric_write_busy ||
                   axi_aw_count!=held_aw || axi_b_count!=held_b || capture_starts!=held_capture ||
                   preview_aborted_count!=0 || done_seen!=0 || error_seen!=0 || display_swap_count!=0 ||
                   dut.u_control.run_armed_q || dut.boardless_start_valid || dut.capture_writer_start ||
                   dut.u_control.manager_nn_grant || dut.u_control.manager_cap_accept)
                    $fatal(1,"preview cancel escaped drain/reallocation fence");
            end
            preview_cancel_hold=0;
            wait_cycles=0;
            while((system_busy || dut.boardless_busy || dut.fabric_write_busy || r_active || rvalid_q ||
                   aw_active || b_pending || bvalid_q) && wait_cycles<200000) begin
                @(negedge core_clk);wait_cycles++;
            end
            repeat(64) @(negedge core_clk);
            if(wait_cycles==200000 || preview_aborted_count!=1 || error_seen!=0 || done_seen!=0 ||
               display_swap_count!=0 || dut.u_control.run_armed_q || capture_starts!=held_capture ||
               axi_aw_count!=axi_b_count || queued_w_completed!=axi_aw_count || preview_b!=8 ||
               dut.fabric_write_protocol_error)
                $fatal(1,"preview cancel failed retirement/disarm contract");
`ifndef C1_PREVIEW_CANCEL_RECOVERY
            $display("C1_SOC_QUEUED_WRITE_NUMERIC_PASS aw=%0d w=%0d b=%0d max_outstanding=%0d w_ahead_beats=%0d",
                axi_aw_count,axi_w_count,axi_b_count,queued_max_outstanding,queued_w_ahead_beats);
`endif
            $display("C1_SOC_PREVIEW_CANCEL_PASS clients=8 held_cycles=64 preview_aw=8 preview_w=16 preview_b=8 aborted=1 errors=0 done=0 swaps=0 start_rejected=1 drained=1 reset=0");
`ifdef C1_PREVIEW_CANCEL_RECOVERY
            // Only per-frame BFM accounting is cleared; DUT and DDR persist.
            preview_pixels=0;preview_aw=0;preview_w=0;preview_b=0;preview_written='0;
            for(integer n=0;n<NUMERIC_FRAME_LINES;n++) numeric_frame_written[n]=0;
            numeric_compute_trace_enable=1;preview_trace_enable=1;
            apb_write(12'h060,((SOURCE_H<<16)|SOURCE_W));
            apb_write(12'h064,TEST_XS);apb_write(12'h068,TEST_YS);
            apb_write(12'h06c,TEST_XP);apb_write(12'h070,TEST_YP);
            apb_write(12'h010,32'h13);
            wait_cycles=0;
            while((!dut.u_control.run_armed_q || dut.capture_discard_idle) && wait_cycles<1000) begin
                @(negedge core_clk);wait_cycles++;
            end
            if(wait_cycles==1000) $fatal(1,"preview cancel recovery failed to rearm");
            if(RECOVERY_TONE!=0) $display("C1_NUM_SOURCE_TONE %0d",RECOVERY_TONE);
            send_camera_frame(RECOVERY_TONE);
`else
            $finish;
`endif
        end
`endif

`ifdef C1_PREVIEW_BRESP_ERROR
        wait_cycles=0;
        while(error_seen==0 && wait_cycles<2000000) begin @(posedge core_clk);wait_cycles++;end
        if(error_seen!=1 || preview_fault_responses!=1 || preview_fault_hold<64)
            $fatal(1,"preview fault not observed errors=%0d responses=%0d hold=%0d",error_seen,preview_fault_responses,preview_fault_hold);
        apb_read(12'h020,status_word);
        if(status_word!=32'h63) $fatal(1,"preview fault APB code %h",status_word);
        apb_read(12'h024,status_word);
        if(status_word!=32'h01000000) $fatal(1,"preview fault APB address %h",status_word);
        wait_cycles=0;
        while((system_busy || dut.boardless_busy || dut.fabric_write_busy ||
               r_active || rvalid_q || aw_active || b_pending || bvalid_q) && wait_cycles<200000) begin
            @(posedge core_clk);wait_cycles++;
        end
        repeat(64) @(negedge core_clk);
        if(wait_cycles==200000 || error_seen!=1 || done_seen!=0 || display_swap_count!=0 ||
           dut.u_control.run_armed_q || dut.fabric_write_protocol_error ||
           axi_aw_count!=axi_b_count || queued_w_completed!=axi_aw_count ||
           preview_aw!=8 || preview_w!=16 || preview_b!=8 || preview_pixels!=63 || !preview_fault_cnn_pending)
            $fatal(1,"preview fault failed drain/no-publish contract err/done/swap=%0d/%0d/%0d aw/b/wdone=%0d/%0d/%0d preview=%0d/%0d/%0d cnn=%0d pending=%0b",
                error_seen,done_seen,display_swap_count,axi_aw_count,axi_b_count,queued_w_completed,
                preview_aw,preview_w,preview_b,preview_pixels,preview_fault_cnn_pending);
`ifndef C1_PREVIEW_BRESP_RECOVERY
        $display("C1_SOC_QUEUED_WRITE_NUMERIC_PASS aw=%0d w=%0d b=%0d max_outstanding=%0d w_ahead_beats=%0d",
                 axi_aw_count,axi_w_count,axi_b_count,queued_max_outstanding,queued_w_ahead_beats);
`endif
        $display("C1_SOC_PREVIEW_BRESP_ERROR_PASS clients=8 errors=1 done=0 swaps=0 code=63 address=01000000 preview_aw=8 preview_w=16 preview_b=8 cnn_pixels=63 pending_cnn_at_fault=1 hold=%0d drained=1 no_software_abort=1",preview_fault_hold);
`ifdef C1_PREVIEW_BRESP_RECOVERY
        // Reset only testbench per-frame accounting after verified drain.
        // No DUT reset, force, memory erase, or error-counter reset is allowed.
        preview_pixels=0;preview_aw=0;preview_w=0;preview_b=0;preview_written='0;
        for(integer n=0;n<NUMERIC_FRAME_LINES;n++) numeric_frame_written[n]=0;
        expected_config_errors=1;
        numeric_compute_trace_enable=1;preview_trace_enable=1;
        apb_write(12'h01c,32'h2);
        apb_write(12'h060,((SOURCE_H<<16)|SOURCE_W));
        apb_write(12'h064,TEST_XS);apb_write(12'h068,TEST_YS);
        apb_write(12'h06c,TEST_XP);apb_write(12'h070,TEST_YP);
        apb_write(12'h010,32'h13);
        wait_cycles=0;
        while((!dut.u_control.run_armed_q || dut.capture_discard_idle) && wait_cycles<1000) begin
            @(negedge core_clk);wait_cycles++;
        end
        if(wait_cycles==1000) $fatal(1,"preview fault recovery could not rearm");
        if(RECOVERY_TONE!=0) $display("C1_NUM_SOURCE_TONE %0d",RECOVERY_TONE);
        send_camera_frame(RECOVERY_TONE);
`else
        $finish;
`endif
`endif

        if(CONCURRENT_CAPTURE_CFG) begin
            // Real continuous-mode capture into a second managed input slot,
            // while the first frame is executing. No internal AXI forcing.
            wait(dut.boardless_busy && engine_stage_active);
`ifdef C1_INFLIGHT_ABORT
            begin : inflight_abort_check
                integer held_b,held_capture,held_done,held_aw,pending_at_abort;
                integer held_r,held_ar;
                integer pixel_abort_wait;
                logic [2:0] held_regions;
                logic [95:0] held_region_bases;
                fork
                    begin
`ifdef C1_PIXEL_WRITE_ABORT
                        // The scalar packing client has one physical AXI
                        // transaction in flight even with multiple logical
                        // sink writes queued. Keep a genuine second producer
                        // active at stage20; do not equate logical credits
                        // with two physical AW/B obligations from this client.
                        if(dut.TENSOR_WRITE_OUTSTANDING==1)
                            wait(dut.u_tensor_adapter.stage_index_q==`C1_PIXEL_ABORT_STAGE && dut.u_tensor_adapter.pixel_stream_q);
`endif
                        send_camera_frame(10'h055);
                        if(RAW_MISSING_EOF_CFG) begin
                            wait(error_seen==1 && !hold_queued_b &&
                                 axi_aw_count==axi_b_count && !dut.capture_writer_busy);
                            repeat(64) begin
                                @(negedge core_clk);
                                if(!system_busy || !dut.capture_cleanup_busy ||
                                   dut.u_control.input_region_valid_q==0 ||
                                   dut.capture_writer_start || done_seen!=0)
                                    $fatal(1,"missing EOF released ownership before new boundary");
                            end
                            $display("C1_SOC_RAW_EOF_WAIT_PASS cycles=64 bus_drained=1 cleanup_held=1");
                            // Maintenance frame supplies a physical boundary.
                            // It is deliberately not an admitted capture.
                            send_camera_frame(10'h066);
                        end
                    end
                    begin
                      if(READ_ABORT_CFG) begin
`ifdef C1_VIRTUAL_UPSAMPLE_READ_ABORT
                        wait(dut.u_tensor_adapter.stage_index_q==18);
`endif
                        // Observe the selected production refill client, not
                        // the old scalar slot when columns use a new slot.
                        wait(r_active && ((SCALAR_READ_ABORT_CFG || PW_REDUCTION_ABORT_CFG) ? ar_len_q==0 : ar_len_q>0) &&
                             dut.fabric_read_owner==read_abort_owner_target &&
`ifdef C1_SCALAR_ASSOC_READ_ABORT
                             dut.u_tensor_adapter.stage_index_q==5 && scalar_cache_valid &&
                             g_scalar_assoc_probe.hits>=2 && g_scalar_assoc_probe.reads>=5 &&
`endif
`ifdef C1_POINTWISE_REDUCTION_READ_ABORT
                             dut.u_tensor_adapter.stage_index_q==19 &&
                             dut.u_microstyle.u_cnn.u_engine.pointwise_stream_q &&
                             dut.u_microstyle.u_cnn.u_engine.state_q==dut.u_microstyle.u_cnn.u_engine.ST_COLLECT &&
                             dut.u_microstyle.u_cnn.u_engine.reduction_group_q==1 &&
`endif
`ifdef C1_PIXEL_PREFETCH_READ_ABORT
                             dut.u_tensor_adapter.pixel_prefetch_state_q==dut.u_tensor_adapter.PF_RESPONSE &&
`endif
                             r_index_q==0 && !rvalid_q);
                        hold_read_response=1;
                        pending_at_abort=ar_len_q+1;
`ifdef C1_POINTWISE_REDUCTION_READ_ABORT
                        if(dut.u_microstyle.u_cnn.u_engine.expected_input_group_q!=1 ||
                           dut.u_microstyle.u_cnn.u_engine.output_group_q!=0 ||
                           !dut.u_microstyle.u_cnn.u_engine.dot_busy ||
                           dut.u_microstyle.u_cnn.u_engine.pw_feeds_q!=1)
                            $fatal(1,"pointwise cancel missed partial real reduction");
                        $display("C1_NUM_POINTWISE_REDUCTION_ABORT stage=19 group=1 output_group=0");
`endif
`ifdef C1_VIRTUAL_UPSAMPLE_READ_ABORT
                        if(!dut.u_tensor_adapter.virtual_upsample_input ||
                           dut.u_tensor_adapter.stage_index_q!=18 ||
                           dut.u_tensor_adapter.cache_stage_width!=4 || dut.u_tensor_adapter.cache_stage_height!=4 ||
                           dut.u_tensor_adapter.input_bank_q!=0 || dut.u_tensor_adapter.output_bank_q!=1)
                            $fatal(1,"virtual upsample abort missed physical small-input refill");
                        $display("C1_NUM_VIRTUAL_UPSAMPLE_ABORT stage=18 width=4 height=4 input_bank=0 output_bank=1");
`endif
`ifdef C1_PIXEL_PREFETCH_READ_ABORT
                        if(!dut.PREFETCH_NEXT_PIXEL_COLUMN || dut.u_tensor_adapter.pixel_prefetch_stage_q!=18)
                            $fatal(1,"prefetch read abort missed owned next-pixel refill");
                        $display("C1_NUM_PIXEL_PREFETCH_ABORT stage=%0d x=%0d y=%0d",
                            dut.u_tensor_adapter.pixel_prefetch_stage_q,
                            dut.u_tensor_adapter.pixel_prefetch_output_x_q,dut.u_tensor_adapter.pixel_prefetch_output_y_q);
`endif
                        if(SCALAR_READ_ABORT_CFG && (scalar_cache_fill_allowed!==1'b1 ||
                           scalar_cache_valid!==SCALAR_ASSOC_ABORT_CFG || scalar_pending_count!==8'd1))
                            $fatal(1,"scalar abort missed a real cacheable in-flight miss");
`ifdef C1_SCALAR_ASSOC_READ_ABORT
                        if(dut.TENSOR_SCALAR_READ_CACHE_ENTRIES!=2 || g_scalar_assoc_probe.hits!=2 ||
                           g_scalar_assoc_probe.reads!=5 || pending_at_abort!=1)
                            $fatal(1,"associative abort missed the first warm replacement read");
                        $display("C1_NUM_SCALAR_ASSOC_ABORT stage=5 entries=2 surviving_valid=1 hits=2 reads=5 pending=1");
`endif
                        if(!dut.boardless_busy || !dut.fabric_read_busy)
                            $fatal(1,"read abort missed real active refill");
                        apb_write(12'h010,32'h5);
                        repeat(4) @(negedge core_clk);
                        held_r=axi_r_count;held_ar=axi_ar_count;
                        held_capture=capture_starts;held_done=done_seen;
                        if(held_capture!=2 || held_done!=0 || !r_active)
                            $fatal(1,"read abort workload/ownership mismatch");
                        apb_write(12'h010,32'h13,1'b1);
                        repeat(64) begin
                            @(negedge core_clk);
                            if(SCALAR_READ_ABORT_CFG && (scalar_cache_fill_allowed!==1'b0 || scalar_cache_valid!==1'b0 ||
                               scalar_pending_count!==8'd1))
                                $fatal(1,"scalar cache canceled miss lost debt or remained fillable");
                            if(!system_busy || !dut.fabric_read_busy || !r_active ||
                               axi_r_count!=held_r || axi_ar_count!=held_ar ||
                               capture_starts!=held_capture || done_seen!=0 ||
                               dut.tensor_cache_abort_done || dut.u_control.run_armed_q ||
                               dut.capture_writer_start || dut.boardless_start_valid ||
                               dut.u_control.manager_nn_grant || dut.u_control.manager_cap_accept)
                                $fatal(1,"pending refill escaped cancel/drain fence");
                        end
                        hold_read_response=0;
                      end else begin
                        // Do not freeze tensor B before the second capture
                        // has read its table. Serial mode needs two writers;
                        // MLP waits for capture idle, freezes the first real
                        // tensor debt, THEN requires two completed AW/W debts
                        // below. Larger batches may never naturally overlap
                        // short-latency B responses before this injection.
`ifdef C1_PIXEL_WRITE_ABORT
                        pixel_abort_wait=0;
                        while(!(dut.u_tensor_adapter.stage_index_q==`C1_PIXEL_ABORT_STAGE && dut.u_tensor_adapter.pixel_stream_q &&
                                dut.u_tensor_adapter.u_pixel_writer.pending_q!=0 &&
                                (dut.TENSOR_WRITE_OUTSTANDING==1 ? dut.capture_writer_busy : !dut.capture_writer_busy) &&
                                axi_aw_count-axi_b_count>=(dut.TENSOR_WRITE_OUTSTANDING==1 ? 2 : 1) &&
                                (dut.TENSOR_WRITE_OUTSTANDING==1 || perf_tensor_aw-perf_tensor_b>=1)) &&
                              pixel_abort_wait<200000) begin
                            @(negedge core_clk);pixel_abort_wait++;
                        end
                        if(pixel_abort_wait==200000)
                            $fatal(1,"pixel abort target timeout stage=%0d adapter=%0d engine=%0d stream=%b sink_busy=%b pending=%0d req=%b/%b rsp=%b/%b col=%b/%b pf=%0d aw=%0d b=%0d error=%0d",
                                dut.u_tensor_adapter.stage_index_q,dut.u_tensor_adapter.state_q,
                                dut.u_microstyle.u_cnn.u_engine.state_q,dut.u_tensor_adapter.pixel_stream_q,
                                dut.u_tensor_adapter.pixel_sink_busy,dut.u_tensor_adapter.u_pixel_writer.pending_q,
                                dut.tensor_mem_req_valid,dut.tensor_mem_req_ready,dut.tensor_mem_rsp_valid,dut.tensor_mem_rsp_ready,
                                dut.tensor_column_valid,dut.tensor_column_ready,dut.u_tensor_adapter.pixel_prefetch_state_q,
                                axi_aw_count,axi_b_count,error_seen);
                        $display("C1_PIXEL_WRITE_ABORT_TARGET stage=%0d sink_pending=%0d aw=%0d b=%0d",
                            `C1_PIXEL_ABORT_STAGE,dut.u_tensor_adapter.u_pixel_writer.pending_q,axi_aw_count,axi_b_count);
`else
                        wait(axi_aw_count-axi_b_count>=2
`ifdef C1_SOURCE_WRITE_ABORT
                             && dut.u_tensor_adapter.source_writes_pending_q!=0
`endif
                        );
`endif
                        @(negedge core_clk);hold_queued_b=1;
`ifdef C1_PIXEL_WRITE_ABORT
                        pixel_abort_wait=0;
                        while(!(axi_aw_count-axi_b_count>=2 && queued_w_completed-axi_b_count>=2) &&
                              pixel_abort_wait<4096) begin
                            @(negedge core_clk);pixel_abort_wait++;
                        end
                        if(pixel_abort_wait==4096)
                            $fatal(1,"pixel abort multiple debt timeout stage=%0d adapter=%0d engine=%0d pending=%0d req=%b/%b col=%b/%b pf=%0d aw=%0d w=%0d b=%0d",
                                dut.u_tensor_adapter.stage_index_q,dut.u_tensor_adapter.state_q,
                                dut.u_microstyle.u_cnn.u_engine.state_q,dut.u_tensor_adapter.u_pixel_writer.pending_q,
                                dut.tensor_mem_req_valid,dut.tensor_mem_req_ready,dut.tensor_column_valid,dut.tensor_column_ready,
                                dut.u_tensor_adapter.pixel_prefetch_state_q,axi_aw_count,queued_w_completed,axi_b_count);
`else
                        wait(axi_aw_count-axi_b_count>=2 && queued_w_completed-axi_b_count>=2);
`endif
                        @(negedge core_clk);
                        pending_at_abort=axi_aw_count-axi_b_count;
`ifdef C1_SOURCE_WRITE_ABORT
                        if(dut.u_tensor_adapter.source_writes_pending_q==0 ||
                           !(dut.u_tensor_adapter.state_q==2 || dut.u_tensor_adapter.state_q==3 || dut.u_tensor_adapter.state_q==4) ||
                           dut.adapter_engine_valid || perf_source_req==0 || perf_source_req>FRAME_W*FRAME_H)
                            $fatal(1,"source write abort missed real upload ownership");
                        $display("C1_NUM_SOURCE_WRITE_ABORT pending=%0d accepted=%0d state=%0d",
                            dut.u_tensor_adapter.source_writes_pending_q,perf_source_req,dut.u_tensor_adapter.state_q);
`endif
`ifdef C1_PIXEL_WRITE_ABORT
                        if(dut.u_tensor_adapter.stage_index_q!=`C1_PIXEL_ABORT_STAGE || !dut.u_tensor_adapter.pixel_stream_q ||
                           dut.u_tensor_adapter.u_pixel_writer.pending_q<2 ||
                           (dut.TENSOR_WRITE_OUTSTANDING==1 && !dut.capture_writer_busy) ||
                           !dut.boardless_busy || !dut.fabric_write_busy)
                            $fatal(1,"pixel write abort missed multiple real selected-stage write obligations");
`ifdef C1_DW_PIXEL_WRITE_ABORT
                        $display("C1_NUM_DW_PIXEL_ABORT stage=18 pending=%0d",dut.u_tensor_adapter.u_pixel_writer.pending_q);
`elsif C1_ALL_DOT_PIXEL_WRITE_ABORT
                        $display("C1_NUM_ALL_DOT_PIXEL_ABORT stage=0 pending=%0d",dut.u_tensor_adapter.u_pixel_writer.pending_q);
`else
                        $display("C1_NUM_DOT_PIXEL_ABORT stage=20 pending=%0d",dut.u_tensor_adapter.u_pixel_writer.pending_q);
`endif
                        if(dut.TENSOR_WRITE_OUTSTANDING>1)begin
                            if(dut.capture_writer_busy || perf_tensor_aw-perf_tensor_b<2)
                                $fatal(1,"MLP abort was not owned by the tensor client alone");
                            $display("C1_NUM_TENSOR_MLP_ABORT client=6 pending=%0d capture_idle=1",perf_tensor_aw-perf_tensor_b);
                        end
`else
                        if(!dut.capture_writer_busy || !dut.boardless_busy || !dut.fabric_write_busy)
                            $fatal(1,"abort did not overlap two real active writers");
`endif
                        if(RAW_FAULT_CFG) begin
                            held_regions=dut.u_control.input_region_valid_q;
                            held_region_bases=dut.u_control.input_region_base_q;
                            if(held_regions==0) $fatal(1,"RAW fault fixture has no physical reservations");
                            release_raw_fault=1;
                            wait(error_seen==1);
                            if(dut.control_error_code!==EXPECT_CONTROL_CODE || dut.control_error_address!=0)
                                $fatal(1,"real RAW raster fault diagnostic mismatch");
                            if(EXPLICIT_RECOVERY_CFG) begin
                                @(negedge core_clk);
                                if(!recovery_ready || camera_valid)
                                    $fatal(1,"explicit recovery source/request precondition failed");
                                source_quiescent=!RECOVERY_LATE_ACK;
                                if(APB_RECOVERY_CFG) begin
                                    apb_read(12'h008,status_word);
                                    if(!status_word[16]) $fatal(1,"missing APB recovery capability");
                                    apb_read(12'h020,status_word);
                                    if(status_word[7:0]!==EXPECT_CONTROL_CODE)
                                        $fatal(1,"software cannot preserve fault diagnostic");
                                    apb_write(12'h130,1);
                                    apb_read(12'h134,status_word);
                                    if(status_word[3:0]!==4'h5)
                                        $fatal(1,"software recovery did not enter pending state");
                                    apb_write(12'h130,1,1);
                                    $display("C1_SOC_EXPLICIT_RECOVERY_APB_ACCEPT_PASS diagnostic=46 busy=1 duplicate_rejected=1");
                                end else recovery_request=1;
                            end
                        end else apb_write(12'h010,32'h5);
                        // Let any B already presented before the hold retire.
                        repeat(4) @(negedge core_clk);
                        held_b=axi_b_count;held_capture=capture_starts;
                        held_done=done_seen;held_aw=axi_aw_count;
                        if(held_done!=0 || axi_aw_count-axi_b_count<2)
                            $fatal(1,"abort window lost pending work");
                        apb_write(12'h010,32'h13,1'b1);
                        repeat(64) begin
                            @(negedge core_clk);
                            if(RAW_FAULT_CFG && (dut.u_control.input_region_valid_q!==held_regions ||
                               dut.u_control.input_region_base_q!==held_region_bases ||
                               !dut.u_control.input_region_cancel_hold_q || error_seen!=1))
                                $fatal(1,"RAW fault released physical reservations before B");
                            if(EXPLICIT_RECOVERY_CFG && (!recovery_busy || recovery_done ||
                               dut.u_capture.u_frontend.recovery_core_reset ||
                               dut.u_capture.u_frontend.recovery_camera_reset))
                                $fatal(1,"explicit recovery reset before outstanding B drain");
                            if(!system_busy || !dut.fabric_write_busy || axi_b_count!=held_b ||
                               capture_starts!=held_capture || done_seen!=held_done ||
                               dut.u_control.run_armed_q || dut.capture_writer_start ||
                               dut.boardless_start_valid || dut.u_control.manager_nn_grant ||
                               dut.u_control.manager_cap_accept)
                                $fatal(1,"pending writes escaped cancel/reallocation fence");
                        end
                        if(axi_aw_count!=held_aw)
                            $fatal(1,"canceled writers issued additional AW after settling");
                        hold_queued_b=0;
                        if(EXPLICIT_RECOVERY_CFG) begin
                            if(RECOVERY_LATE_ACK) begin
                                wait(axi_aw_count==axi_b_count && !dut.fabric_write_busy &&
                                     !dut.capture_writer_busy && !dut.boardless_busy);
                                repeat(32) begin
                                    @(negedge core_clk);
                                    if(!recovery_busy || !system_busy || recovery_done ||
                                       dut.u_capture.u_frontend.recovery_core_reset ||
                                       dut.u_capture.u_frontend.recovery_camera_reset ||
                                       dut.u_control.input_region_valid_q!==held_regions ||
                                       dut.u_control.input_region_base_q!==held_region_bases ||
                                       !dut.u_control.input_region_cancel_hold_q)
                                        $fatal(1,"drained DDR released ownership before source ACK");
                                end
                                apb_write(12'h010,32'h13,1'b1);
                                @(negedge core_clk);source_quiescent=1;
                                $display("C1_SOC_EXPLICIT_RECOVERY_LATE_ACK_PASS cycles=32 bus_drained=1 ownership_held=1");
                            end
                            wait_cycles=0;
                            while(!recovery_done && wait_cycles<1024) begin
                                @(negedge core_clk);
                                wait_cycles++;
                                if(dut.u_control.input_region_valid_q!==held_regions ||
                                   dut.u_control.input_region_base_q!==held_region_bases ||
                                   !dut.u_control.input_region_cancel_hold_q || !system_busy)
                                    $fatal(1,"ownership released during dual-clock recovery handshake");
                            end
                            if(!recovery_done)
                                $fatal(1,"recovery handshake timeout ready=%b busy=%b req=%b csr_req=%b safe=%b source=%b fabric_r=%b fabric_w=%b boardless=%b parameter=%b parameter_abort=%b prefetch=%b flush=%b bridge=%b adapter=%b cache=%b leaf_safe=%b core_reset=%b camera_reset=%b",
                                    recovery_ready,recovery_busy,recovery_request,dut.csr_capture_recovery_request,
                                    dut.capture_recovery_safe,source_quiescent,dut.fabric_read_quiescent,
                                    dut.fabric_write_quiescent,dut.boardless_busy,dut.parameter_busy,
                                    dut.parameter_abort_pending,dut.display_prefetch_busy,dut.display_flush_busy,
                                    dut.bridge_busy,dut.tensor_adapter_busy,dut.tensor_cache_busy,
                                    dut.u_capture.recovery_leaf_safe,dut.u_capture.u_frontend.recovery_core_reset,
                                    dut.u_capture.u_frontend.recovery_camera_reset);
                            $display("C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS pending=%0d held_cycles=64 source_stopped=1",pending_at_abort);
                        end
                      end
                    end
                join
                wait_cycles=0;
                while((system_busy || dut.fabric_write_busy || r_active || rvalid_q ||
                       aw_active || b_pending || bvalid_q) && wait_cycles<200000) begin
                    @(negedge core_clk);wait_cycles++;
                end
                if(wait_cycles==200000 || axi_aw_count!=axi_b_count ||
                   queued_w_completed!=axi_aw_count || error_seen!=RAW_FAULT_CFG || done_seen!=0) begin
`ifdef C1_PIXEL_PREFETCH_READ_ABORT
                    $display("C1_PIXEL_PREFETCH_DRAIN_DEBUG adapter=%0d pf=%0d writes=%0d abort=%b abort_pending=%b error=%b bridge=%b boardless=%b cache=%b scalar_pending=%0d column_busy=%b column_idle=%b fence_pending=%b fence_ack=%b owner_state=%0d owner_pending=%b owner_sent=%b owner_ack=%b",
                        dut.u_tensor_adapter.state_q,dut.u_tensor_adapter.pixel_prefetch_state_q,
                        dut.u_tensor_adapter.result_writes_pending_q,dut.adapter_abort,
                        dut.u_tensor_adapter.abort_pending_q,dut.u_tensor_adapter.error_q,dut.bridge_busy,
                        dut.boardless_busy,dut.tensor_cache_busy,dut.g_tensor_column_reads.scalar_pending_q,
                        dut.g_tensor_column_reads.column_busy,dut.g_tensor_column_reads.column_idle,
                        dut.g_tensor_column_reads.abort_pending_q,dut.g_tensor_column_reads.abort_ack_q,
                        dut.g_tensor_column_reads.u_column.g_owner.owner.state_q,
                        dut.g_tensor_column_reads.u_column.g_owner.owner.pending_q,
                        dut.g_tensor_column_reads.u_column.g_owner.owner.sent_q,
                        dut.g_tensor_column_reads.u_column.g_owner.owner.ack_q);
`endif
                    $fatal(1,"canceled SoC failed drain aw=%0d wdone=%0d b=%0d busy=%b",axi_aw_count,queued_w_completed,axi_b_count,system_busy);
                end
                if(READ_ABORT_CFG)
                    $display("C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS pending_beats=%0d held_cycles=64 owner=%0d no_restart=1",pending_at_abort,read_abort_owner_target);
                else
                    $display("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=%0d held_cycles=64 aw=%0d b=%0d no_restart=1",pending_at_abort,axi_aw_count,axi_b_count);
                if(SCALAR_READ_ABORT_CFG) begin
                    if(scalar_cache_valid!==1'b0 || scalar_cache_fill_allowed!==1'b0 ||
                       scalar_pending_count!==8'd0)
                        $fatal(1,"late scalar R repopulated cache after abort/drain");
                    $display("C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0");
                end
                // Restore next-launch geometry poisoned by the snapshot test.
                apb_write(12'h060,((SOURCE_H<<16)|SOURCE_W));
                apb_write(12'h064,TEST_XS);apb_write(12'h068,TEST_YS);
                apb_write(12'h06c,TEST_XP);apb_write(12'h070,TEST_YP);
                numeric_compute_trace_enable=1;
                source_quiescent=0;
                apb_write(12'h010,32'h13);
                wait(dut.u_control.run_armed_q && !dut.capture_discard_idle);
                send_camera_frame(10'd0);
                wait_cycles=0;
                while((done_seen!=1 || system_busy || !display_done_seen) && wait_cycles<3000000) begin
                    @(negedge core_clk);wait_cycles++;
                end
                if(wait_cycles==3000000 || error_seen!=RAW_FAULT_CFG || done_seen!=1 ||
                   axi_aw_count!=axi_b_count || queued_w_completed!=axi_aw_count ||
                   dut.fabric_write_busy || dut.fabric_write_protocol_error || capture_starts!=3 ||
                   numeric_inputs!=64 || numeric_outputs!=((dut.ELIDE_VIRTUAL_UPSAMPLE?660:836)-(dut.FUSE_FINAL_OUTPUT?64:0)))
                    $fatal(1,"SoC failed no-reset restart after pending-write abort");
                wait_cycles=0;
                while((numeric_video_raw<FIRST_DISPLAY_PIXELS || numeric_video_styled<64) && wait_cycles<100000) begin
                    @(negedge core_clk);wait_cycles++;
                end
                if(numeric_video_raw!=FIRST_DISPLAY_PIXELS || numeric_video_styled!=64)
                    $fatal(1,"restarted frame display trace incomplete");
                begin : recovered_ddr_trace
                    logic [31:0] addr,pixel;
                    logic [127:0] line_data;
                    integer slot,lane;
                    if(!USE_ASSOC_MEM || $isunknown(dut.display_styled_base) ||
                       dut.display_styled_base<OUTPUT_BASE ||
                       dut.display_styled_base>=OUTPUT_BASE+3*FRAME_SLOT_BYTES ||
                       ((dut.display_styled_base-OUTPUT_BASE)%FRAME_SLOT_BYTES)!=0 ||
                       dut.display_styled_stride!==XRGB_STRIDE)
                        $fatal(1,"invalid recovered frame metadata");
                    for(integer y=0;y<8;y++) for(integer x=0;x<8;x++) begin
                        addr=dut.display_styled_base+y*XRGB_STRIDE+x*4;
                        slot=(addr-OUTPUT_BASE)>>4;lane=addr[3:0];
                        if(numeric_frame_written[slot][lane +: 4]!==4'hf ||
                           !mem_line_assoc.exists(addr[31:4]))
                            $fatal(1,"recovered DDR pixel not physically written");
                        line_data=mem_line_assoc[addr[31:4]];
                        pixel=line_data[lane*8 +: 32];
                        if($isunknown(pixel)) $fatal(1,"unknown recovered DDR pixel");
                        $display("C1_NUM_DDR %0d %0d %08h",x,y,pixel);
                    end
                end
                $display("C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_8X8_PASS recovery=1 inputs=%0d results=%0d done=%0d",numeric_inputs,numeric_outputs,done_seen);
                $display("C1_SOC_QUEUED_WRITE_NUMERIC_PASS aw=%0d w=%0d b=%0d max_outstanding=%0d w_ahead_beats=%0d",axi_aw_count,axi_w_count,axi_b_count,queued_max_outstanding,queued_w_ahead_beats);
                if(RAW_FAULT_CFG)
                    $display("C1_SOC_RAW_RASTER_FAULT_PASS pending=%0d held_cycles=64 captures=%0d errors=%0d done=%0d reset=0",pending_at_abort,capture_starts,error_seen,done_seen);
                if(RAW_MISSING_EOF_CFG)
                    $display("C1_SOC_RAW_MISSING_EOF_PASS bus_hold=64 boundary_wait=64 captures=3 errors=1 done=1 reset=0");
                if(RAW_IDLE_CFG)
                    $display("C1_SOC_RAW_IDLE_TIMEOUT_PASS threshold=4096 code=46 captures=3 errors=1 done=1 reset=0");
                if(EXPLICIT_RECOVERY_CFG) begin
                    if(recovery_completions!=1 || recovery_busy ||
                       (APB_RECOVERY_CFG ? (!recovery_ready || recovery_request) :
                                           (recovery_ready || !recovery_request)))
                        $fatal(1,"explicit recovery held request retriggered during new job");
                    if(APB_RECOVERY_CFG) begin
                        apb_read(12'h134,status_word);
                        if(status_word[3:0]!==4'hb) $fatal(1,"software completion was not retained");
                        apb_write(12'h130,2);
                        apb_read(12'h134,status_word);
                        if(status_word[3:0]!==4'h3) $fatal(1,"software completion clear failed");
                        $display("C1_SOC_EXPLICIT_RECOVERY_APB_PASS hardware_request=0 completion_read=1 completion_cleared=1");
                    end
                    $display("C1_SOC_EXPLICIT_RECOVERY_PASS flushes=1 captures=3 errors=1 done=1 reset=0");
                end
                if(READ_ABORT_CFG)
                    $display("C1_SOC_INFLIGHT_READ_ABORT_PASS pending_beats=%0d held_cycles=64 captures=%0d done=%0d owner=%0d reset=0",pending_at_abort,capture_starts,done_seen,read_abort_owner_target);
                else
                    $display("C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=%0d held_cycles=64 captures=%0d done=%0d aw=%0d b=%0d reset=0",pending_at_abort,capture_starts,done_seen,axi_aw_count,axi_b_count);
                $finish;
            end
`else
            send_camera_frame(10'h055);
`endif
        end

`ifdef C1_DISPLAY_FAULT_RECOVERY
        wait_cycles=0;
        while(error_seen==0 && wait_cycles<2_000_000) begin
            @(posedge core_clk); wait_cycles++;
        end
        if(error_seen!=1 || injected_faults!=1)
            $fatal(1,"display fault count mismatch injected=%0d reported=%0d armed=%b display_error=%b done=%0d",
                injected_faults,error_seen,dut.u_control.run_armed_q,dut.display_prefetch_error,done_seen);
        apb_read(12'h020,status_word);
        if(status_word!=32'h70) $fatal(1,"wrong APB display fault code %h",status_word);
        wait_cycles=0;
        while((system_busy || dut.display_prefetch_busy || dut.display_flush_busy ||
               r_active || rvalid_q || aw_active || b_pending || bvalid_q) && wait_cycles<20000) begin
            @(posedge core_clk); wait_cycles++;
        end
        if(wait_cycles==20000 || dut.u_control.run_armed_q)
            $fatal(1,"SoC display fault did not drain/disarm");
        // Error details retain the last fault by CSR contract; acknowledge
        // the W1C IRQ bit explicitly, rather than assuming START erases it.
        apb_write(12'h01c,32'h2);
        apb_write(12'h010,32'h13);
        wait_cycles=0;
        while((!dut.u_control.run_armed_q || dut.capture_discard_idle) && wait_cycles<1000) begin
            @(posedge core_clk); wait_cycles++;
        end
        if(wait_cycles==1000) $fatal(1,"SoC did not rearm after display fault");
        send_camera_frame(10'h155);
        wait_cycles=0;
        while((done_seen<2 || system_busy || dut.display_prefetch_busy || dut.display_flush_busy) &&
              wait_cycles<5_000_000) begin
            @(posedge core_clk); wait_cycles++;
        end
        apb_read(12'h01c,status_word);
        if(wait_cycles==5_000_000 || error_seen!=1 || status_word[1] ||
           descriptor_fire_count<44 || r_active || rvalid_q || aw_active || b_pending || bvalid_q)
            $fatal(1,"SoC restart failed done=%0d errors=%0d csr=%h",done_seen,error_seen,status_word);
        $display("C1_PORTABLE_SOC_DISPLAY_FAULT_RECOVERY_PASS injected=%0d errors=%0d done=%0d descriptors=%0d",
            injected_faults,error_seen,done_seen,descriptor_fire_count);
        $finish;
`endif

        wait_cycles=0;
        while ((done_seen==0) && (error_seen==expected_config_errors) && (wait_cycles<20_000_000)) begin
            @(posedge core_clk);
            wait_cycles=wait_cycles+1;
        end
        if (error_seen!=expected_config_errors)
            $fatal(1,"portable SoC reported a control error");
        if (done_seen==0)
            $fatal(1,"portable SoC small-frame job timed out");

        // The display subsystem intentionally uses the real 720p raster
        // timing, even in this small-frame regression.  Its two-line stores
        // cannot release the third line until the pixel domain reaches the
        // corresponding active line, and request enable is committed only at
        // a local frame boundary.  The guard therefore covers one complete
        // 720p frame plus margin rather than a short arbitrary drain.
        if(CONCURRENT_CAPTURE_CFG) begin
            // Keep the first full display/golden result, then stop continuous
            // operation via the real APB abort before a second CNN frame can
            // produce tokens. Queued capture data is discarded by ownership
            // cleanup; accepted AXI transactions still have to retire.
            wait(display_done_seen);
            apb_write(12'h010,32'h5);
        end
        wait_cycles = 0;
        while ((system_busy || !display_done_seen) &&
               (wait_cycles < 2_500_000)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
        // The frozen 22-descriptor graph has 21 stage indices: stage 0 is
        // emitted twice while the engine advances from its first descriptor
        // fetch into the first compute stage.  Count both descriptor fires,
        // but require the complete stage-index set 0..20.
        if (descriptor_fire_count < 22 ||
            descriptor_stage_seen !== 22'h1fffff)
            $fatal(1,"not all 22 CNN descriptors/stages were accepted count=%0d mask=%06x",
                   descriptor_fire_count,descriptor_stage_seen);
        if (!display_done_seen) begin
            $display("display timeout system=%0b control=%0b feed=%0b start_v/r=%0b/%0b busy=%0b done=%0b primed=%0b err=%0b pending=%0b current=%0b loading_new=%0b frame_start=%0b",
                     system_busy,dut.control_status_busy,dut.display_feed_active,
                     dut.display_prefetch_start_valid,dut.display_prefetch_start_ready,
                     dut.display_prefetch_busy,dut.display_prefetch_done,
                     dut.display_prefetch_primed,dut.display_prefetch_error,
                     dut.u_control.pending_pair_valid_q,
                     dut.u_control.current_pair_valid_q,
                     dut.u_control.prefetch_loading_new_q,
                     dut.display_frame_start_event);
            $display("  readers orig/styled busy done err state=%0b/%0b/%0b/%0d %0b/%0b/%0b/%0d stores primed=%0b/%0b empty=%0b/%0b",
                     dut.u_display.u_prefetch.original_reader_busy,
                     dut.u_display.u_prefetch.original_reader_done,
                     dut.u_display.u_prefetch.original_reader_error,
                     dut.u_display.u_prefetch.u_original_reader.state,
                     dut.u_display.u_prefetch.styled_reader_busy,
                     dut.u_display.u_prefetch.styled_reader_done,
                     dut.u_display.u_prefetch.styled_reader_error,
                     dut.u_display.u_prefetch.u_styled_reader.state,
                     dut.u_display.u_prefetch.original_primed,
                     dut.u_display.u_prefetch.styled_primed,
                     dut.u_display.u_prefetch.original_empty,
                     dut.u_display.u_prefetch.styled_empty);
            $display("  pixel timing x/y=%0d/%0d req_en=%0b frame_req=%0b line_ready=%0b/%0b toggles=%b/%b ack=%b/%b",
                     dut.u_display.timing_x,dut.u_display.timing_y,
                     dut.u_display.request_enable_core,
                     dut.u_display.request_enable_frame_q,
                     dut.u_display.compositor_original_request,
                     dut.u_display.compositor_styled_request,
                     dut.u_display.u_prefetch.u_original_store.ready_toggle_core,
                     dut.u_display.u_prefetch.u_styled_store.ready_toggle_core,
                     dut.u_display.u_prefetch.u_original_store.ack_toggle_pixel,
                     dut.u_display.u_prefetch.u_styled_store.ack_toggle_pixel);
            $fatal(1,"display prefetch did not report completion");
        end

`ifdef C1_TWO_FRAME
        // Optional serialized two-frame contract test.  STATUS.BUSY is not
        // equivalent to boardless_done: the previous display pair may still
        // be pending a frame-boundary swap.  Wait for the ownership barrier
        // before issuing the second START, then use table entry 1 and a
        // different camera tone so an address/index mix-up is observable.
        first_descriptor_count = descriptor_fire_count;
        first_swap_count = display_swap_count;
        wait_cycles = 0;
        // display_prefetch_busy may remain high while the display service
        // refreshes the currently-owned pair in the background; it is not a
        // foreground ownership fence.  The pending/new-pair bookkeeping is
        // the relevant condition for a serialized one-shot START.  The swap
        // count is sampled only for the final two-frame assertion; comparing
        // it with itself here would be a vacuous wait, while waiting for the
        // next swap would deadlock because the second START creates it.
        while ((system_busy || dut.u_control.pending_pair_valid_q ||
                dut.u_control.prefetch_loading_new_q ||
                dut.u_control.display_swap_requested_q) &&
               (wait_cycles < 3_000_000)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
        if (system_busy || dut.u_control.pending_pair_valid_q ||
            dut.u_control.prefetch_loading_new_q ||
            dut.u_control.display_swap_requested_q)
            $display("two-frame barrier timeout system=%0b control=%0b prefetch_busy=%0b pending=%0b loading_new=%0b swap_req=%0b swap=%0d first_swap=%0d frame_id=%0d done=%0d display_done=%0b primed=%0b feed=%0b",
                     system_busy,dut.control_status_busy,dut.display_prefetch_busy,
                     dut.u_control.pending_pair_valid_q,
                     dut.u_control.prefetch_loading_new_q,
                     dut.u_control.display_swap_requested_q,
                     display_swap_count,
                     first_swap_count,dut.control_display_frame_id,done_seen,
                     display_done_seen,dut.display_prefetch_primed,
                     dut.display_feed_active);
        if (system_busy || dut.u_control.pending_pair_valid_q ||
            dut.u_control.prefetch_loading_new_q ||
            dut.u_control.display_swap_requested_q)
            $fatal(1,"first frame ownership barrier did not close");

        apb_write(12'h010,32'h13);
        wait_cycles = 0;
        while ((!dut.u_control.run_armed_q || dut.capture_discard_idle) &&
               (wait_cycles < 1000)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
        if (!dut.u_control.run_armed_q || dut.capture_discard_idle)
            $fatal(1,"second START did not open camera admission");
`ifdef C1_TWO_FRAME_TRACE
        send_camera_frame(10'd32);
`else
        send_camera_frame(10'h155);
`endif

        wait_cycles = 0;
`ifdef C1_SHARED_QOS_MONITOR
        // The frame-manager swap is a VSYNC ownership commit and may occur
        // while the tagged prefetch reader is still draining its final R
        // beats.  Keep the native QoS assertion aligned with that terminal
        // drain instead of sampling frame_count immediately after swap.
        while ((done_seen < 2 || display_swap_count < (first_swap_count + 1) ||
                system_busy || (qos_new_done_count < 2)) &&
               (wait_cycles < SHARED_QOS_BOUNDARY_WAIT_CYCLES)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
`else
        while ((done_seen < 2 || display_swap_count < (first_swap_count + 1) ||
                system_busy) && (wait_cycles < 5_000_000)) begin
            @(posedge core_clk);
            wait_cycles = wait_cycles + 1;
        end
`endif
        if (done_seen < 2)
            $fatal(1,"second one-shot job timed out done=%0d",done_seen);
        if (descriptor_fire_count < (first_descriptor_count + 22))
            $fatal(1,"second job accepted fewer than 22 descriptors total=%0d",
                   descriptor_fire_count);
        if (display_swap_count < (first_swap_count + 1))
             $display("second swap timeout done=%0d desc=%0d swaps=%0d drops=%0d system=%0b control=%0b pending=%0b current=%0b loading_new=%0b prefetch busy/done/err/primed=%0b/%0b/%0b/%0b pair orig=%08x/%08x styled=%08x/%08x readers=%0b/%0b states=%0d/%0d timing=%0d/%0d hold=%0b",
                      done_seen,descriptor_fire_count,display_swap_count,
                      capture_drop_count,system_busy,dut.control_status_busy,
                      dut.u_control.pending_pair_valid_q,
                      dut.u_control.current_pair_valid_q,
                      dut.u_control.prefetch_loading_new_q,
                      dut.display_prefetch_busy,dut.display_prefetch_done,
                      dut.display_prefetch_error,dut.display_prefetch_primed,
                      dut.u_control.current_original_base_q,
                      dut.u_control.pending_original_base_q,
                      dut.u_control.current_styled_base_q,
                      dut.u_control.pending_styled_base_q,
                      dut.u_display.u_prefetch.original_reader_busy,
                      dut.u_display.u_prefetch.styled_reader_busy,
                      dut.u_display.u_prefetch.u_original_reader.state,
                      dut.u_display.u_prefetch.u_styled_reader.state,
                      dut.u_display.timing_x,dut.u_display.timing_y,
                      dut.display_hold_requests);
        if (display_swap_count < (first_swap_count + 1))
            $fatal(1,"second display pair did not swap count=%0d",
                   display_swap_count);
        if (capture_drop_count != 0)
            $fatal(1,"two-frame contract dropped capture frames count=%0d",
                   capture_drop_count);
`endif
        apb_read(12'h100,status_word);
`ifdef C1_TWO_FRAME
        if (status_word < 32'd2)
            $fatal(1,"processed frame count did not reach two: %0d",status_word);
`else
        if (status_word == 32'd0)
            $fatal(1,"processed frame count did not advance");
`endif
        if (axi_aw_count==0 || axi_w_count==0 || axi_b_count==0 ||
            axi_ar_count==0 || axi_r_count==0)
            $fatal(1,"small-frame run produced incomplete AXI traffic");
        $display("DDR BFM traffic aw=%0d w=%0d b=%0d ar=%0d r=%0d stalls aw/w/ar/r/fabric_r/b=%0d/%0d/%0d/%0d/%0d/%0d gaps r/b=%0d/%0d",
                 axi_aw_count,axi_w_count,axi_b_count,axi_ar_count,axi_r_count,
                 aw_stall_count,w_stall_count,ar_stall_count,r_stall_count,
                 fabric_r_stall_count,b_stall_count,r_gap_count,b_gap_count);
        if (aw_stall_count==0 || w_stall_count==0 || ar_stall_count==0 ||
            ((r_stall_count==0) && (fabric_r_stall_count==0)) ||
            (r_gap_count==0) || (b_gap_count==0))
            $fatal(1,"DDR BFM did not exercise request/response delay or backpressure");
        if (system_busy) begin
            $display("busy fence: system=%0b control=%0b bridge=%0b adapter=%0b cache=%0b cache_q=%0b display=%0b prefetch=%0b writer=%0b boardless=%0b parameter=%0b",
                     system_busy,dut.control_status_busy,dut.bridge_busy,
                     dut.tensor_adapter_busy,dut.tensor_cache_busy,
                     dut.tensor_cache_quiescent,dut.display_prefetch_busy,
                     dut.display_prefetch_start_valid,dut.capture_writer_busy,
                     dut.boardless_busy,dut.parameter_busy);
            $display("  display readers orig busy/done/err/state=%0b/%0b/%0b/%0d styled=%0b/%0b/%0b/%0d primed=%0b/%0b empty=%0b/%0b",
                     dut.u_display.u_prefetch.original_reader_busy,
                     dut.u_display.u_prefetch.original_reader_done,
                     dut.u_display.u_prefetch.original_reader_error,
                     dut.u_display.u_prefetch.u_original_reader.state,
                     dut.u_display.u_prefetch.styled_reader_busy,
                     dut.u_display.u_prefetch.styled_reader_done,
                     dut.u_display.u_prefetch.styled_reader_error,
                     dut.u_display.u_prefetch.u_styled_reader.state,
                     dut.u_display.u_prefetch.original_primed,
                     dut.u_display.u_prefetch.styled_primed,
                     dut.u_display.u_prefetch.original_empty,
                     dut.u_display.u_prefetch.styled_empty);
            $fatal(1,"portable SoC remained busy after drain");
        end

`ifdef C1_SHARED_QOS_MONITOR
        // The production monitor is observation-only, so native traffic and
        // lifecycle checks above remain the authority.  This gate additionally
        // proves that the real seven-client path produced a coherent job
        // snapshot and did not report an owner-status wiring error.
        $display("C1_QOS_EVENT_COUNTS start=%0d prefetch_done=%0d new_done=%0d swap=%0d monitor_frame=%0d monitor_active=%0b",
                 qos_start_count,qos_prefetch_done_count,qos_new_done_count,
                 qos_swap_event_count,
                 dut.g_shared_qos_monitor.u_monitor.frame_count,
                 dut.g_shared_qos_monitor.u_monitor.frame_active);
`ifdef C1_TWO_FRAME
        if (dut.g_shared_qos_monitor.u_monitor.frame_count < 24'd2) begin
            // This diagnostic is intentionally emitted before the fatal so a
            // shape-scaled run distinguishes a slow pixel-domain drain from a
            // real reader error/deadlock.  The persistent runner keeps only
            // this short line and the log tail; the full xsim tree is removed.
            $display("C1_QOS_BOUNDARY_TIMEOUT wait=%0d limit=%0d starts=%0d raw_done=%0d new_done=%0d swaps=%0d monitor_frame=%0d active=%0b prefetch_busy=%0b prefetch_done=%0b primed=%0b error=%0b readers=%0b/%0b states=%0d/%0d empty=%0b/%0b fifo=%0d/%0d fifo_drained=%0b req_en=%0b/%0b hold=%0b timing=%0d/%0d",
                     wait_cycles,SHARED_QOS_BOUNDARY_WAIT_CYCLES,
                     qos_start_count,qos_prefetch_done_count,qos_new_done_count,
                     qos_swap_event_count,
                     dut.g_shared_qos_monitor.u_monitor.frame_count,
                     dut.g_shared_qos_monitor.u_monitor.frame_active,
                     dut.display_prefetch_busy,dut.display_prefetch_done,
                     dut.display_prefetch_primed,dut.display_prefetch_error,
                     dut.u_display.u_prefetch.original_reader_busy,
                     dut.u_display.u_prefetch.styled_reader_busy,
                     dut.u_display.u_prefetch.u_original_reader.state,
                     dut.u_display.u_prefetch.u_styled_reader.state,
                     dut.u_display.u_prefetch.original_empty,
                     dut.u_display.u_prefetch.styled_empty,
                     dut.u_display.u_prefetch.original_fifo_level,
                     dut.u_display.u_prefetch.styled_fifo_level,
                     dut.u_display.u_prefetch.response_fifo_drained,
                     dut.u_display.request_enable_core,
                     dut.u_display.request_enable_frame_q,
                     dut.display_hold_requests,
                     dut.u_display.timing_x,dut.u_display.timing_y);
            $fatal(1,"QoS monitor missed a native job boundary: frame_count=%0d",
                   dut.g_shared_qos_monitor.u_monitor.frame_count);
        end
`else
        if (dut.g_shared_qos_monitor.u_monitor.frame_count < 24'd1)
            $fatal(1,"QoS monitor missed the native job boundary");
`endif
        if (dut.g_shared_qos_monitor.u_monitor.protocol_error_count != 24'd0)
            $fatal(1,"QoS monitor saw protocol errors: %0d",
                   dut.g_shared_qos_monitor.u_monitor.protocol_error_count);
        // Read back the production APB aggregate window after the native job
        // is idle.  This proves the software-visible path carries the same
        // snapshot as the hierarchical monitor; per-client vectors remain
        // intentionally outside this compact ABI.
        apb_read(12'h108,qos_apb_status);
        apb_read(12'h10c,qos_apb_frame_count);
        apb_read(12'h110,qos_apb_last_frame);
        apb_read(12'h114,qos_apb_deadline);
        apb_read(12'h118,qos_apb_underflow);
        apb_read(12'h11c,qos_apb_read_busy);
        apb_read(12'h120,qos_apb_write_busy);
        apb_read(12'h124,qos_apb_read_owner_max);
        apb_read(12'h128,qos_apb_write_owner_max);
        apb_read(12'h12c,qos_apb_protocol);
        if ((qos_apb_status & 32'h0000_0001) == 0 ||
            (qos_apb_status & 32'h0000_0006) != 0 ||
            (((qos_apb_status & 32'h0000_0008) != 0) != (qos_apb_underflow != 0)) ||
            (((qos_apb_status & 32'h0000_0010) != 0) != (qos_apb_deadline != 0)) ||
            (((qos_apb_status & 32'h0000_0020) != 0) != (qos_apb_protocol != 0)) ||
            qos_apb_frame_count != dut.g_shared_qos_monitor.u_monitor.frame_count ||
            qos_apb_last_frame != dut.g_shared_qos_monitor.u_monitor.last_frame_cycles ||
            qos_apb_deadline != dut.g_shared_qos_monitor.u_monitor.deadline_miss_count ||
            qos_apb_underflow != dut.g_shared_qos_monitor.u_monitor.display_underflow_count ||
            qos_apb_read_busy > dut.g_shared_qos_monitor.u_monitor.read_busy_cycles ||
            qos_apb_write_busy > dut.g_shared_qos_monitor.u_monitor.write_busy_cycles ||
            qos_apb_read_owner_max > dut.g_shared_qos_monitor.u_monitor.read_owner_hold_max ||
            qos_apb_write_owner_max > dut.g_shared_qos_monitor.u_monitor.write_owner_hold_max ||
            qos_apb_protocol != dut.g_shared_qos_monitor.u_monitor.protocol_error_count)
            $fatal(1,"QoS APB aggregate readback mismatch/live-order violation status=%08x frame=%0d last=%0d deadline=%0d underflow=%0d read_busy=%0d write_busy=%0d r_owner=%0d w_owner=%0d protocol=%0d",
                   qos_apb_status,qos_apb_frame_count,qos_apb_last_frame,
                   qos_apb_deadline,qos_apb_underflow,qos_apb_read_busy,
                   qos_apb_write_busy,qos_apb_read_owner_max,
                   qos_apb_write_owner_max,qos_apb_protocol);
        $display("C1_QOS_APB_READBACK pass=1 status=%08x frame=%0d last=%0d deadline=%0d underflow=%0d read_busy=%0d write_busy=%0d r_owner=%0d w_owner=%0d protocol=%0d",
                 qos_apb_status,qos_apb_frame_count,qos_apb_last_frame,
                 qos_apb_deadline,qos_apb_underflow,qos_apb_read_busy,
                 qos_apb_write_busy,qos_apb_read_owner_max,
                 qos_apb_write_owner_max,qos_apb_protocol);
        $display("C1_R1_PORTABLE_SOC_SHARED_QOS_STATS frame_count=%0d last_frame_cycles=%0d deadline_miss=%0d underflow=%0d read_busy=%0d write_busy=%0d r4_stall=%0d r5_stall=%0d ar4_wait=%0d ar5_wait=%0d protocol=%0d overflow=%0b event_start=%0d event_prefetch_done=%0d event_new_done=%0d event_swap=%0d",
                 dut.g_shared_qos_monitor.u_monitor.frame_count,
                 dut.g_shared_qos_monitor.u_monitor.last_frame_cycles,
                 dut.g_shared_qos_monitor.u_monitor.deadline_miss_count,
                 dut.g_shared_qos_monitor.u_monitor.display_underflow_count,
                 dut.g_shared_qos_monitor.u_monitor.read_busy_cycles,
                 dut.g_shared_qos_monitor.u_monitor.write_busy_cycles,
                 dut.g_shared_qos_monitor.u_monitor.r_stall_total[4],
                 dut.g_shared_qos_monitor.u_monitor.r_stall_total[5],
                 dut.g_shared_qos_monitor.u_monitor.ar_wait_total[4],
                 dut.g_shared_qos_monitor.u_monitor.ar_wait_total[5],
                 dut.g_shared_qos_monitor.u_monitor.protocol_error_count,
                  dut.g_shared_qos_monitor.u_monitor.monitor_overflow,
                  qos_start_count,qos_prefetch_done_count,qos_new_done_count,
                  qos_swap_event_count);
        // Keep the per-client vectors out of the software ABI, but emit a
        // bounded seven-line attribution table in the native BFM.  This is
        // the next optimization decision point: it distinguishes tensor
        // client-6 demand from display/parameter/engine arbitration without
        // retaining a large waveform or a full xsim log.
        for (i = 0; i < 7; i = i + 1) begin
            $display("C1_QOS_CLIENT id=%0d aw=%0d w=%0d b=%0d ar=%0d r=%0d aw_wait=%0d w_wait=%0d b_stall=%0d ar_wait=%0d r_stall=%0d aw_max=%0d w_max=%0d b_max=%0d ar_max=%0d r_max=%0d r_owner=%0d w_owner=%0d",
                     i,
                     dut.g_shared_qos_monitor.u_monitor.aw_accept_count[i],
                     dut.g_shared_qos_monitor.u_monitor.w_accept_count[i],
                     dut.g_shared_qos_monitor.u_monitor.b_accept_count[i],
                     dut.g_shared_qos_monitor.u_monitor.ar_accept_count[i],
                     dut.g_shared_qos_monitor.u_monitor.r_accept_count[i],
                     dut.g_shared_qos_monitor.u_monitor.aw_wait_total[i],
                     dut.g_shared_qos_monitor.u_monitor.w_wait_total[i],
                     dut.g_shared_qos_monitor.u_monitor.b_stall_total[i],
                     dut.g_shared_qos_monitor.u_monitor.ar_wait_total[i],
                     dut.g_shared_qos_monitor.u_monitor.r_stall_total[i],
                     dut.g_shared_qos_monitor.u_monitor.aw_wait_max[i],
                     dut.g_shared_qos_monitor.u_monitor.w_wait_max[i],
                     dut.g_shared_qos_monitor.u_monitor.b_stall_max[i],
                     dut.g_shared_qos_monitor.u_monitor.ar_wait_max[i],
                     dut.g_shared_qos_monitor.u_monitor.r_stall_max[i],
                     dut.g_shared_qos_monitor.u_monitor.read_owner_hold_total[i],
                     dut.g_shared_qos_monitor.u_monitor.write_owner_hold_total[i]);
        end
`endif

`ifdef C1_TWO_FRAME
`ifdef C1_TWO_FRAME_TRACE
        begin : wait_two_frame_video
            integer n;
            n=0;
            while((two_video_raw[0]!=64 || two_video_raw[1]!=64 ||
                   two_video_styled[0]!=64 || two_video_styled[1]!=64) && n<TWO_VIDEO_WAIT_CYCLES) begin
                @(posedge core_clk);n++;
            end
            if(two_video_raw[0]!=64 || two_video_raw[1]!=64 ||
               two_video_styled[0]!=64 || two_video_styled[1]!=64)
                $fatal(1,"two-frame video incomplete raw=%0d/%0d styled=%0d/%0d",
                    two_video_raw[0],two_video_raw[1],two_video_styled[0],two_video_styled[1]);
            $display("C1_PERF_TWO_VIDEO_WAIT cycles=%0d limit=%0d",n,TWO_VIDEO_WAIT_CYCLES);
            $display("C1_NUM_TWO_VIDEO_PASS frames=2 raw=128 styled=128 compositor_aligned=1");
        end
        if(two_job!=1 || two_completed!=2 || done_seen!=2 || display_swap_count!=2 || error_seen!=0)
            $fatal(1,"two-frame numerical lifecycle incomplete");
        $display("C1_NUM_TWO_PASS frames=2 inputs=128 outputs=%0d ddr=128 swaps=2",(dut.ELIDE_VIRTUAL_UPSAMPLE?1320:1672)-(dut.FUSE_FINAL_OUTPUT?128:0));
`endif
        $display("C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_TWO_FRAME_PASS frame=%0dx%0d done=%0d swaps=%0d drops=%0d descriptors=%0d stage_mask=%06x display_done=%0b drain_cycles=%0d axi_aw=%0d axi_w=%0d axi_b=%0d axi_ar=%0d axi_r=%0d aw_stalls=%0d w_stalls=%0d ar_stalls=%0d r_stalls=%0d fabric_r_stalls=%0d b_stalls=%0d r_gaps=%0d b_gaps=%0d descriptor_size_arith=%0d fixed_descriptor_size_limits=%0d pipelined_descriptor_pixel_count=%0d iterative_descriptor_pixel_count=%0d preclamped_tap_coords=%0d",
`else
        $display("C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS frame=%0dx%0d done=%0d swaps=%0d drops=%0d descriptors=%0d stage_mask=%06x display_done=%0b drain_cycles=%0d axi_aw=%0d axi_w=%0d axi_b=%0d axi_ar=%0d axi_r=%0d aw_stalls=%0d w_stalls=%0d ar_stalls=%0d r_stalls=%0d fabric_r_stalls=%0d b_stalls=%0d r_gaps=%0d b_gaps=%0d descriptor_size_arith=%0d fixed_descriptor_size_limits=%0d pipelined_descriptor_pixel_count=%0d iterative_descriptor_pixel_count=%0d preclamped_tap_coords=%0d",
`endif
                 FRAME_W,FRAME_H,done_seen,display_swap_count,
                 capture_drop_count,descriptor_fire_count,descriptor_stage_seen,
                 display_done_seen,wait_cycles,
                 axi_aw_count,axi_w_count,axi_b_count,axi_ar_count,axi_r_count,
                 aw_stall_count,w_stall_count,
                 ar_stall_count,r_stall_count,fabric_r_stall_count,
                 b_stall_count,r_gap_count,b_gap_count,
                 PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG,
                 FIXED_DESCRIPTOR_SIZE_LIMITS_CFG,
                 PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG,
                 ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG,
                  PRECLAMPED_TAP_COORDS_CFG);
        if (TRAINED_ARTIFACT_CFG) begin
            if (trained_weight_ar_count == 0)
                $fatal(1, "trained artifact mode did not issue a parameter-arena read");
`ifdef C1_NUMERICAL_TRACE
            begin : wait_numeric_video
                integer video_wait;
                video_wait=0;
                while((numeric_video_raw<FIRST_DISPLAY_PIXELS || numeric_video_styled<FRAME_W*FRAME_H) && video_wait<100000) begin
                    @(posedge core_clk); video_wait=video_wait+1;
                end
                if(numeric_video_raw!=FIRST_DISPLAY_PIXELS || numeric_video_styled!=FRAME_W*FRAME_H)
                    $fatal(1,"incomplete video trace raw=%0d styled=%0d",numeric_video_raw,numeric_video_styled);
            end
            if(numeric_inputs!=FRAME_W*FRAME_H || numeric_outputs!=numeric_expected_results)
                $fatal(1,"incomplete numerical trace inputs=%0d outputs=%0d",numeric_inputs,numeric_outputs);
            begin : check_final_frame
                logic [31:0] pixel_addr, pixel_word;
                logic [127:0] stored_line;
                integer slot_line, byte_lane, sparse_index;
                if($isunknown(dut.display_styled_base) ||
                   dut.display_styled_base<OUTPUT_BASE ||
                   dut.display_styled_base>=OUTPUT_BASE+3*FRAME_SLOT_BYTES ||
                   ((dut.display_styled_base-OUTPUT_BASE)%FRAME_SLOT_BYTES)!=0 ||
                   dut.display_styled_stride!==XRGB_STRIDE)
                    $fatal(1,"invalid committed styled frame metadata");
                for(integer y=0;y<FRAME_H;y=y+1) begin
                    for(integer x=0;x<FRAME_W;x=x+1) begin
                        pixel_addr=dut.display_styled_base+y*XRGB_STRIDE+x*4;
                        slot_line=(pixel_addr-OUTPUT_BASE)>>4;
                        byte_lane=pixel_addr[3:0];
                        sparse_index=line_index(pixel_addr);
                        if(numeric_frame_written[slot_line][byte_lane +: 4]!==4'hf)
                            $fatal(1,"final DDR pixel not physically written: %h",pixel_addr);
                        if(USE_ASSOC_MEM) begin
                            if(!mem_line_assoc.exists(pixel_addr[31:4]))
                                $fatal(1,"final DDR associative line missing: %h",pixel_addr);
                            stored_line=mem_line_assoc[pixel_addr[31:4]];
                        end else begin
                            if(!mem_valid[sparse_index] || mem_tag[sparse_index]!==pixel_addr[31:4])
                                $fatal(1,"final DDR direct line missing: %h",pixel_addr);
                            stored_line=mem_line[sparse_index];
                        end
                        pixel_word=stored_line[byte_lane*8 +: 32];
                        if($isunknown(pixel_word)) $fatal(1,"unknown final DDR pixel");
                        $display("C1_NUM_DDR %0d %0d %08h",x,y,pixel_word);
                    end
                end
            end
`endif
            $display("C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_%0dX%0d_PASS descriptors=%0d weight_ar=%0d axi_r=%0d done=%0d stage_mask=%06x",
                     FRAME_W, FRAME_H, descriptor_fire_count, trained_weight_ar_count, axi_r_count,
                     done_seen, descriptor_stage_seen);
        end
`ifdef C1_CONCURRENT_DISPLAY_PREFETCH
`ifdef C1_TWO_FRAME
        if (concurrent_display_ar_count == 0)
            $fatal(1,"No real display AXI reads overlapped the CNN job");
        $display("C1_CONCURRENT_DISPLAY_OVERLAP_PASS ar_during_job=%0d", concurrent_display_ar_count);
`endif
`endif
`ifdef C1_PREVIEW_CAPTURE
        begin : check_preview_ddr
            logic [127:0] line_value;
            logic [31:0] address_value;
            if(dut.AXI_CLIENTS!=8 || preview_aw!=8 || preview_w!=16 || preview_b!=8 || preview_pixels!=64)
                $fatal(1,"preview fabric coverage aw=%0d w=%0d b=%0d pixels=%0d",preview_aw,preview_w,preview_b,preview_pixels);
            for(integer p=0;p<64;p++) begin
                address_value=preview_completed_base+p*4;
                if(preview_written[address_value-32'h0100_0000 +: 4]!==4'hf)
                    $fatal(1,"preview pixel not fully physically written");
                if(!mem_line_assoc.exists(address_value[31:4])) $fatal(1,"preview physical DDR line missing");
                line_value=mem_line_assoc[address_value[31:4]];
                if(line_value[(p%4)*32 +: 32]!==preview_expected[p]) $fatal(1,"preview DDR mismatch pixel=%0d",p);
                $display("C1_NUM_PREVIEW_DDR %0d %0d %08h",p%8,p/8,line_value[(p%4)*32 +: 32]);
            end
            $display("C1_NUM_PREVIEW_CAPTURE_PASS clients=8 pixels=64 aw=8 w=16 b=8 paired_base=%08h retired_before_done=1",preview_completed_base);
`ifdef C1_PREVIEW_CANCEL_RECOVERY
            if(error_seen!=0 || done_seen!=1 || capture_starts!=2 || preview_aborted_count!=1)
                $fatal(1,"preview cancel recovery accounting failed");
            $display("C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS aborted=1 errors=0 done=1 captures=2 reset=0 pixels=64");
`endif
`ifdef C1_PREVIEW_BRESP_RECOVERY
            apb_read(12'h01c,status_word);
            if(error_seen!=1 || done_seen!=1 || capture_starts!=2 || preview_fault_responses!=1 || status_word[1])
                $fatal(1,"preview recovery error accounting or IRQ acknowledgement failed");
            $display("C1_SOC_PREVIEW_BRESP_RECOVERY_PASS errors=1 done=1 captures=2 injected=1 reset=0 pixels=64");
`endif
        end
`endif
        if(QUEUED_WRITE_CFG) begin
            if(axi_aw_count!=axi_b_count || queued_w_completed!=axi_aw_count || dut.fabric_write_busy)
                $fatal(1,"queued write descriptors did not fully retire");
            $display("C1_SOC_QUEUED_WRITE_NUMERIC_PASS aw=%0d w=%0d b=%0d max_outstanding=%0d w_ahead_beats=%0d",
                     axi_aw_count,axi_w_count,axi_b_count,queued_max_outstanding,queued_w_ahead_beats);
        end
        if(CONCURRENT_CAPTURE_CFG) begin
            if(capture_starts!=2 || capture_aw_while_compute==0 || queued_max_outstanding<2 ||
               (SERIALIZE_WRITE_DATA_CFG ? queued_w_ahead_beats!=0 : queued_w_ahead_beats==0) ||
               done_seen!=1 || capture_drop_count!=0)
                $fatal(1,"insufficient real concurrent capture starts=%0d overlap_aw=%0d peak=%0d ahead=%0d done=%0d drops=%0d",
                    capture_starts,capture_aw_while_compute,queued_max_outstanding,queued_w_ahead_beats,done_seen,capture_drop_count);
            $display("C1_SOC_CONCURRENT_CAPTURE_PASS captures=%0d capture_aw_during_compute=%0d peak=%0d ahead=%0d done=%0d",
                capture_starts,capture_aw_while_compute,queued_max_outstanding,queued_w_ahead_beats,done_seen);
        end
        $finish;
    end

    initial begin
`ifdef C1_TWO_FRAME
        #600_000_000;
`else
        #300_000_000;
`endif
        $fatal(1,"portable SoC cache DDR BFM timeout");
    end
    // All successful lifecycle branches (including early recovery finishes)
    // emit exactly one summary. Failed runs can print it too, but the runner
    // and golden checker reject non-successful status before using evidence.
    final begin
        $display("C1_PERF_BFM_LATENCY first_events=%0d first_min=%0d first_max=%0d beat_events=%0d beat_min=%0d beat_max=%0d",
                 first_events,first_latency_min,first_latency_max,
                 beat_events,beat_latency_min,beat_latency_max);
    end
endmodule
