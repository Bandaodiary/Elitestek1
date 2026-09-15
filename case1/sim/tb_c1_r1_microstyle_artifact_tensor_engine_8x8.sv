`timescale 1ns/1ps

// Boardless trained-artifact integration probe.
//
// This testbench deliberately keeps the memory fabric local and bounded.  It
// connects the real trained descriptor/arena vectors to the tensor adapter,
// the real MicroStyle engine, and a small associative DDR model.  It is not a
// portable-SoC performance test: the purpose is to close the next correctness
// boundary (source pixel -> adapter window/address -> engine result -> tensor
// write/final stream) before attempting native 640x480.
//
// Defining C1_STAGE1_HANDOFF keeps the full 22-stage configuration barrier,
// runs the complete scaled 8x8 stage-0 (4x4 output), then retires a bounded
// portion of stage 1 before asserting a safe abort.  The default handoff mode
// retires only the first stage-1 output pixel (three C8 groups).  Defining
// C1_STAGE1_FULL retires the complete scaled stage-1 2x2 output (12 groups).
// Defining C1_STAGE2_FULL additionally retires the complete scaled stage-2
// 1x1 expansion (2x2 output, six C8 groups per pixel).  Defining
// C1_STAGE3_FULL extends the same bounded chain through res0.depthwise3x3
// (2x2 output, six groups, nine taps per input group).  C1_STAGE4_FULL,
// C1_STAGE5_FULL, C1_STAGE6_FULL, and C1_STAGE7_FULL continue through
// res0.project1x1, res0.add_relu, res1.expand1x1, and res1.depthwise3x3
// respectively.  C1_STAGE8_FULL through C1_STAGE21_FULL continue the same
// finite bank-to-bank handoff through the remaining residual/decoder/output
// stages.  A higher stage switch recursively enables all lower prerequisites.
// Stage21 retires the final RGB stream and therefore runs to adapter_done
// instead of asserting an abort after a tensor write.
`ifdef C1_STAGE21_FULL
`ifndef C1_STAGE20_FULL
`define C1_STAGE20_FULL
`endif
`endif
`ifdef C1_STAGE20_FULL
`ifndef C1_STAGE19_FULL
`define C1_STAGE19_FULL
`endif
`endif
`ifdef C1_STAGE19_FULL
`ifndef C1_STAGE18_FULL
`define C1_STAGE18_FULL
`endif
`endif
`ifdef C1_STAGE18_FULL
`ifndef C1_STAGE17_FULL
`define C1_STAGE17_FULL
`endif
`endif
`ifdef C1_STAGE17_FULL
`ifndef C1_STAGE16_FULL
`define C1_STAGE16_FULL
`endif
`endif
`ifdef C1_STAGE16_FULL
`ifndef C1_STAGE15_FULL
`define C1_STAGE15_FULL
`endif
`endif
`ifdef C1_STAGE15_FULL
`ifndef C1_STAGE14_FULL
`define C1_STAGE14_FULL
`endif
`endif
`ifdef C1_STAGE14_FULL
`ifndef C1_STAGE13_FULL
`define C1_STAGE13_FULL
`endif
`endif
`ifdef C1_STAGE13_FULL
`ifndef C1_STAGE12_FULL
`define C1_STAGE12_FULL
`endif
`endif
`ifdef C1_STAGE12_FULL
`ifndef C1_STAGE11_FULL
`define C1_STAGE11_FULL
`endif
`endif
`ifdef C1_STAGE11_FULL
`ifndef C1_STAGE10_FULL
`define C1_STAGE10_FULL
`endif
`endif
`ifdef C1_STAGE10_FULL
`ifndef C1_STAGE9_FULL
`define C1_STAGE9_FULL
`endif
`endif
`ifdef C1_STAGE9_FULL
`ifndef C1_STAGE8_FULL
`define C1_STAGE8_FULL
`endif
`endif
`ifdef C1_STAGE8_FULL
`ifndef C1_STAGE7_FULL
`define C1_STAGE7_FULL
`endif
`endif
`ifdef C1_STAGE7_FULL
`ifndef C1_STAGE6_FULL
`define C1_STAGE6_FULL
`endif
`endif
`ifdef C1_STAGE6_FULL
`ifndef C1_STAGE5_FULL
`define C1_STAGE5_FULL
`endif
`endif
`ifdef C1_STAGE5_FULL
`ifndef C1_STAGE4_FULL
`define C1_STAGE4_FULL
`endif
`endif
`ifdef C1_STAGE4_FULL
`ifndef C1_STAGE3_FULL
`define C1_STAGE3_FULL
`endif
`endif
`ifdef C1_STAGE3_FULL
`ifndef C1_STAGE2_FULL
`define C1_STAGE2_FULL
`endif
`endif
`ifdef C1_STAGE2_FULL
`ifndef C1_STAGE1_FULL
`define C1_STAGE1_FULL
`endif
`endif
`ifdef C1_STAGE1_FULL
`ifndef C1_STAGE1_HANDOFF
`define C1_STAGE1_HANDOFF
`endif
`endif
module tb_c1_r1_microstyle_artifact_tensor_engine_8x8;
`ifdef C1_PACKED_AFFINE_CACHE
  localparam integer PACKED_AFFINE_CACHE = 1;
`else
  localparam integer PACKED_AFFINE_CACHE = 0;
`endif
  localparam integer STAGES       = 22;
  localparam integer FRAME_W      = 8;
  localparam integer FRAME_H      = 8;
  localparam integer PARAM_BYTES  = 16896;
  localparam integer PARAM_WORDS  = PARAM_BYTES / 16;
  // Keep the production 8 MiB/bank address contract.  The BFM below stores
  // only a sparse 4 KiB-word window per bank, which is sufficient for the
  // 8x8 scaled graph and avoids allocating a 24 MiB dense simulator array.
  localparam integer BANK_BYTES   = 8 * 1024 * 1024;
  localparam integer SPARSE_WORDS = 4096;
  localparam integer RECORDS      = 896;
  localparam integer EXPECTED     = 836;

  // Handoff level is the last fully retired tensor stage.  Level 0 is the
  // historical first-pixel probe; levels 1..21 retire the complete output of
  // that stage.  A negative level means the ordinary unbounded full-frame
  // regression (the handoff-only accounting below is then unused).
`ifdef C1_STAGE21_FULL
  localparam integer HANDOFF_LEVEL = 21;
`elsif C1_STAGE20_FULL
  localparam integer HANDOFF_LEVEL = 20;
`elsif C1_STAGE19_FULL
  localparam integer HANDOFF_LEVEL = 19;
`elsif C1_STAGE18_FULL
  localparam integer HANDOFF_LEVEL = 18;
`elsif C1_STAGE17_FULL
  localparam integer HANDOFF_LEVEL = 17;
`elsif C1_STAGE16_FULL
  localparam integer HANDOFF_LEVEL = 16;
`elsif C1_STAGE15_FULL
  localparam integer HANDOFF_LEVEL = 15;
`elsif C1_STAGE14_FULL
  localparam integer HANDOFF_LEVEL = 14;
`elsif C1_STAGE13_FULL
  localparam integer HANDOFF_LEVEL = 13;
`elsif C1_STAGE12_FULL
  localparam integer HANDOFF_LEVEL = 12;
`elsif C1_STAGE11_FULL
  localparam integer HANDOFF_LEVEL = 11;
`elsif C1_STAGE10_FULL
  localparam integer HANDOFF_LEVEL = 10;
`elsif C1_STAGE9_FULL
  localparam integer HANDOFF_LEVEL = 9;
`elsif C1_STAGE8_FULL
  localparam integer HANDOFF_LEVEL = 8;
`elsif C1_STAGE7_FULL
  localparam integer HANDOFF_LEVEL = 7;
`elsif C1_STAGE6_FULL
  localparam integer HANDOFF_LEVEL = 6;
`elsif C1_STAGE5_FULL
  localparam integer HANDOFF_LEVEL = 5;
`elsif C1_STAGE4_FULL
  localparam integer HANDOFF_LEVEL = 4;
`elsif C1_STAGE3_FULL
  localparam integer HANDOFF_LEVEL = 3;
`elsif C1_STAGE2_FULL
  localparam integer HANDOFF_LEVEL = 2;
`elsif C1_STAGE1_FULL
  localparam integer HANDOFF_LEVEL = 1;
`elsif C1_STAGE1_HANDOFF
  localparam integer HANDOFF_LEVEL = 0;
`else
  localparam integer HANDOFF_LEVEL = -1;
`endif

  localparam integer HANDOFF_OPERANDS =
      (HANDOFF_LEVEL == 0)  ? 18  :
      (HANDOFF_LEVEL == 1)  ? 24  :
      (HANDOFF_LEVEL == 2)  ? 36  :
      (HANDOFF_LEVEL == 3)  ? 60  :
      (HANDOFF_LEVEL == 4)  ? 84  :
      (HANDOFF_LEVEL == 5)  ? 96  :
      (HANDOFF_LEVEL == 6)  ? 108 :
      (HANDOFF_LEVEL == 7)  ? 132 :
      (HANDOFF_LEVEL == 8)  ? 156 :
      (HANDOFF_LEVEL == 9)  ? 168 :
      (HANDOFF_LEVEL == 10) ? 180 :
      (HANDOFF_LEVEL == 11) ? 204 :
      (HANDOFF_LEVEL == 12) ? 228 :
      (HANDOFF_LEVEL == 13) ? 240 :
      (HANDOFF_LEVEL == 14) ? 288 :
      (HANDOFF_LEVEL == 15) ? 336 :
      (HANDOFF_LEVEL == 16) ? 384 :
      (HANDOFF_LEVEL == 17) ? 512 :
      (HANDOFF_LEVEL == 18) ? 640 :
      (HANDOFF_LEVEL == 19) ? 768 :
      (HANDOFF_LEVEL == 20) ? 832 :
      (HANDOFF_LEVEL == 21) ? 896 : RECORDS;
  localparam integer HANDOFF_RESULTS =
      (HANDOFF_LEVEL == 0)  ? 35  :
      (HANDOFF_LEVEL == 1)  ? 44  :
      (HANDOFF_LEVEL == 2)  ? 68  :
      (HANDOFF_LEVEL == 3)  ? 92  :
      (HANDOFF_LEVEL == 4)  ? 104 :
      (HANDOFF_LEVEL == 5)  ? 116 :
      (HANDOFF_LEVEL == 6)  ? 140 :
      (HANDOFF_LEVEL == 7)  ? 164 :
      (HANDOFF_LEVEL == 8)  ? 176 :
      (HANDOFF_LEVEL == 9)  ? 188 :
      (HANDOFF_LEVEL == 10) ? 212 :
      (HANDOFF_LEVEL == 11) ? 236 :
      (HANDOFF_LEVEL == 12) ? 248 :
      (HANDOFF_LEVEL == 13) ? 260 :
      (HANDOFF_LEVEL == 14) ? 308 :
      (HANDOFF_LEVEL == 15) ? 356 :
      (HANDOFF_LEVEL == 16) ? 388 :
      (HANDOFF_LEVEL == 17) ? 516 :
      (HANDOFF_LEVEL == 18) ? 644 :
      (HANDOFF_LEVEL == 19) ? 708 :
      (HANDOFF_LEVEL == 20) ? 772 :
      (HANDOFF_LEVEL == 21) ? 836 : EXPECTED;
  localparam integer HANDOFF_FINAL_GROUPS =
      (HANDOFF_LEVEL == 0) ? 3 :
      (HANDOFF_LEVEL == 1) ? 12 :
      (HANDOFF_LEVEL == 2) ? 24 :
      (HANDOFF_LEVEL == 3) ? 24 :
      (HANDOFF_LEVEL == 4) ? 12 :
      (HANDOFF_LEVEL == 5) ? 12 :
      (HANDOFF_LEVEL == 6) ? 24 :
      (HANDOFF_LEVEL == 7) ? 24 :
      (HANDOFF_LEVEL == 8) ? 12 :
      (HANDOFF_LEVEL == 9) ? 12 :
      (HANDOFF_LEVEL == 10) ? 24 :
      (HANDOFF_LEVEL == 11) ? 24 :
      (HANDOFF_LEVEL == 12) ? 12 :
      (HANDOFF_LEVEL == 13) ? 12 :
      (HANDOFF_LEVEL == 14) ? 48 :
      (HANDOFF_LEVEL == 15) ? 48 :
      (HANDOFF_LEVEL == 16) ? 32 :
      (HANDOFF_LEVEL == 17) ? 128 :
      (HANDOFF_LEVEL == 18) ? 128 :
      (HANDOFF_LEVEL == 19) ? 64 :
      (HANDOFF_LEVEL == 20) ? 64 :
      (HANDOFF_LEVEL == 21) ? 64 : FRAME_W * FRAME_H;

  // Per-stage memory contracts.  The values are compile-time selected so a
  // finite gate cannot silently consume traffic from a later stage.
  localparam integer HANDOFF_STAGE1_READS  = (HANDOFF_LEVEL == 0) ? 18 : (HANDOFF_LEVEL >= 1 ? 72 : 0);
  localparam integer HANDOFF_STAGE1_WRITES = (HANDOFF_LEVEL == 0) ? 3  : (HANDOFF_LEVEL >= 1 ? 12 : 0);
  localparam integer HANDOFF_STAGE1_PIXELS = (HANDOFF_LEVEL == 0) ? 1  : (HANDOFF_LEVEL >= 1 ? 4  : 0);
  localparam integer HANDOFF_STAGE2_READS  = (HANDOFF_LEVEL >= 2) ? 12  : 0;
  localparam integer HANDOFF_STAGE2_WRITES = (HANDOFF_LEVEL >= 2) ? 24  : 0;
  localparam integer HANDOFF_STAGE2_PIXELS = (HANDOFF_LEVEL >= 2) ? 4   : 0;
  localparam integer HANDOFF_STAGE3_READS  = (HANDOFF_LEVEL >= 3) ? 216 : 0;
  localparam integer HANDOFF_STAGE3_WRITES = (HANDOFF_LEVEL >= 3) ? 24  : 0;
  localparam integer HANDOFF_STAGE3_PIXELS = (HANDOFF_LEVEL >= 3) ? 4   : 0;
  localparam integer HANDOFF_STAGE4_READS  = (HANDOFF_LEVEL >= 4) ? 24  : 0;
  localparam integer HANDOFF_STAGE4_WRITES = (HANDOFF_LEVEL >= 4) ? 12  : 0;
  localparam integer HANDOFF_STAGE4_PIXELS = (HANDOFF_LEVEL >= 4) ? 4   : 0;
  localparam integer HANDOFF_STAGE5_READS  = (HANDOFF_LEVEL >= 5) ? 24  : 0;
  localparam integer HANDOFF_STAGE5_MAIN_READS = (HANDOFF_LEVEL >= 5) ? 12 : 0;
  localparam integer HANDOFF_STAGE5_RESIDUAL_READS = (HANDOFF_LEVEL >= 5) ? 12 : 0;
  localparam integer HANDOFF_STAGE5_WRITES = (HANDOFF_LEVEL >= 5) ? 12  : 0;
  localparam integer HANDOFF_STAGE5_PIXELS = (HANDOFF_LEVEL >= 5) ? 4   : 0;
  localparam integer HANDOFF_STAGE6_READS  = (HANDOFF_LEVEL >= 6) ? 12  : 0;
  localparam integer HANDOFF_STAGE6_WRITES = (HANDOFF_LEVEL >= 6) ? 24  : 0;
  localparam integer HANDOFF_STAGE6_PIXELS = (HANDOFF_LEVEL >= 6) ? 4   : 0;
  localparam integer HANDOFF_STAGE7_READS  = (HANDOFF_LEVEL >= 7) ? 216 : 0;
  localparam integer HANDOFF_STAGE7_WRITES = (HANDOFF_LEVEL >= 7) ? 24  : 0;
  localparam integer HANDOFF_STAGE7_PIXELS = (HANDOFF_LEVEL >= 7) ? 4   : 0;
  localparam integer HANDOFF_STAGE8_READS  = (HANDOFF_LEVEL >= 8) ? 24  : 0;
  localparam integer HANDOFF_STAGE8_WRITES = (HANDOFF_LEVEL >= 8) ? 12  : 0;
  localparam integer HANDOFF_STAGE8_PIXELS = (HANDOFF_LEVEL >= 8) ? 4   : 0;
  localparam integer HANDOFF_STAGE9_READS  = (HANDOFF_LEVEL >= 9) ? 24  : 0;
  localparam integer HANDOFF_STAGE9_MAIN_READS = (HANDOFF_LEVEL >= 9) ? 12 : 0;
  localparam integer HANDOFF_STAGE9_RESIDUAL_READS = (HANDOFF_LEVEL >= 9) ? 12 : 0;
  localparam integer HANDOFF_STAGE9_WRITES = (HANDOFF_LEVEL >= 9) ? 12  : 0;
  localparam integer HANDOFF_STAGE9_PIXELS = (HANDOFF_LEVEL >= 9) ? 4   : 0;
  localparam integer HANDOFF_STAGE10_READS  = (HANDOFF_LEVEL >= 10) ? 12  : 0;
  localparam integer HANDOFF_STAGE10_WRITES = (HANDOFF_LEVEL >= 10) ? 24  : 0;
  localparam integer HANDOFF_STAGE10_PIXELS = (HANDOFF_LEVEL >= 10) ? 4   : 0;
  localparam integer HANDOFF_STAGE11_READS  = (HANDOFF_LEVEL >= 11) ? 216 : 0;
  localparam integer HANDOFF_STAGE11_WRITES = (HANDOFF_LEVEL >= 11) ? 24  : 0;
  localparam integer HANDOFF_STAGE11_PIXELS = (HANDOFF_LEVEL >= 11) ? 4   : 0;
  localparam integer HANDOFF_STAGE12_READS  = (HANDOFF_LEVEL >= 12) ? 24  : 0;
  localparam integer HANDOFF_STAGE12_WRITES = (HANDOFF_LEVEL >= 12) ? 12  : 0;
  localparam integer HANDOFF_STAGE12_PIXELS = (HANDOFF_LEVEL >= 12) ? 4   : 0;
  localparam integer HANDOFF_STAGE13_READS  = (HANDOFF_LEVEL >= 13) ? 24  : 0;
  localparam integer HANDOFF_STAGE13_MAIN_READS = (HANDOFF_LEVEL >= 13) ? 12 : 0;
  localparam integer HANDOFF_STAGE13_RESIDUAL_READS = (HANDOFF_LEVEL >= 13) ? 12 : 0;
  localparam integer HANDOFF_STAGE13_WRITES = (HANDOFF_LEVEL >= 13) ? 12  : 0;
  localparam integer HANDOFF_STAGE13_PIXELS = (HANDOFF_LEVEL >= 13) ? 4   : 0;
  localparam integer HANDOFF_STAGE14_READS  = (HANDOFF_LEVEL >= 14) ? 48  : 0;
  localparam integer HANDOFF_STAGE14_WRITES = (HANDOFF_LEVEL >= 14) ? 48  : 0;
  localparam integer HANDOFF_STAGE14_PIXELS = (HANDOFF_LEVEL >= 14) ? 16  : 0;
  localparam integer HANDOFF_STAGE15_READS  = (HANDOFF_LEVEL >= 15) ? 432 : 0;
  localparam integer HANDOFF_STAGE15_WRITES = (HANDOFF_LEVEL >= 15) ? 48  : 0;
  localparam integer HANDOFF_STAGE15_PIXELS = (HANDOFF_LEVEL >= 15) ? 16  : 0;
  localparam integer HANDOFF_STAGE16_READS  = (HANDOFF_LEVEL >= 16) ? 48  : 0;
  localparam integer HANDOFF_STAGE16_WRITES = (HANDOFF_LEVEL >= 16) ? 32  : 0;
  localparam integer HANDOFF_STAGE16_PIXELS = (HANDOFF_LEVEL >= 16) ? 16  : 0;
  localparam integer HANDOFF_STAGE17_READS  = (HANDOFF_LEVEL >= 17) ? 128 : 0;
  localparam integer HANDOFF_STAGE17_WRITES = (HANDOFF_LEVEL >= 17) ? 128 : 0;
  localparam integer HANDOFF_STAGE17_PIXELS = (HANDOFF_LEVEL >= 17) ? 64  : 0;
  localparam integer HANDOFF_STAGE18_READS  = (HANDOFF_LEVEL >= 18) ? 1152 : 0;
  localparam integer HANDOFF_STAGE18_WRITES = (HANDOFF_LEVEL >= 18) ? 128  : 0;
  localparam integer HANDOFF_STAGE18_PIXELS = (HANDOFF_LEVEL >= 18) ? 64   : 0;
  localparam integer HANDOFF_STAGE19_READS  = (HANDOFF_LEVEL >= 19) ? 128 : 0;
  localparam integer HANDOFF_STAGE19_WRITES = (HANDOFF_LEVEL >= 19) ? 64  : 0;
  localparam integer HANDOFF_STAGE19_PIXELS = (HANDOFF_LEVEL >= 19) ? 64  : 0;
  localparam integer HANDOFF_STAGE20_READS  = (HANDOFF_LEVEL >= 20) ? 576 : 0;
  localparam integer HANDOFF_STAGE20_WRITES = (HANDOFF_LEVEL >= 20) ? 64  : 0;
  localparam integer HANDOFF_STAGE20_PIXELS = (HANDOFF_LEVEL >= 20) ? 64  : 0;
  localparam integer HANDOFF_STAGE21_READS  = (HANDOFF_LEVEL >= 21) ? 64 : 0;
  localparam integer HANDOFF_STAGE21_WRITES = 0;
  localparam integer HANDOFF_STAGE21_PIXELS = (HANDOFF_LEVEL >= 21) ? 64 : 0;
  localparam integer HANDOFF_STAGE_DONE =
      (HANDOFF_LEVEL < 0) ? STAGES :
      ((HANDOFF_LEVEL == 0) ? 1 : HANDOFF_LEVEL + 1);
  localparam logic [31:0] BASE_ADDR = 32'h0010_0000;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic [511:0] descriptors [0:STAGES-1];
  logic [127:0] parameter_mem [0:PARAM_WORDS-1];
  logic [1023:0] input_records [0:RECORDS-1];
  logic [63:0] expected_records [0:EXPECTED-1];
  logic [127:0] stage_meta [0:STAGES-1];

  // Adapter control and stream ports.
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
  logic [31:0] tensor_base_addr;
  logic cache_stage_start_valid, cache_stage_start_ready;
  logic cache_stage_enable;
  logic [31:0] cache_stage_base_addr;
  logic [15:0] cache_stage_width, cache_stage_height;
  logic [3:0] cache_stage_groups;
  logic mem_req_valid, mem_req_ready, mem_req_write;
  logic [31:0] mem_req_addr;
  logic [63:0] mem_req_wdata;
  logic [7:0] mem_req_wstrb;
  logic mem_req_cacheable;
  logic signed [16:0] mem_req_cache_x, mem_req_cache_y;
  logic [2:0] mem_req_cache_group;
  logic mem_rsp_valid, mem_rsp_ready, mem_rsp_error;
  logic [63:0] mem_rsp_rdata;
  logic adapter_busy, adapter_done, adapter_aborted;
  logic adapter_config_complete;
  logic [4:0] adapter_active_stage;
  logic [7:0] adapter_active_opcode;
  logic [1:0] adapter_input_bank, adapter_output_bank, adapter_residual_bank;

  // Engine-top ports.
  logic engine_start_valid, engine_start_ready;
  logic [15:0] engine_stage_count = STAGES;
  logic [7:0] engine_config_generation = 8'h51;
`ifdef C1_USE_PARAMETER_BANK
  logic engine_parameter_active_valid;
  logic [31:0] engine_parameter_generation;
`else
  logic engine_parameter_active_valid = 1'b1;
  logic [31:0] engine_parameter_generation = 32'h2026_0828;
`endif
  logic engine_busy, engine_done, engine_aborted, engine_error;
  logic [7:0] engine_error_code;
  logic engine_stage_config_valid, engine_stage_config_ready;
  logic [15:0] engine_stage_config_index;
  logic [511:0] engine_stage_config_descriptor;
  logic [7:0] engine_stage_config_generation;
  logic param_rd_en, param_rd_valid, param_rd_error;
  logic [10:0] param_rd_addr;
  logic [127:0] param_rd_data;
  logic engine_in_valid, engine_in_ready;
  logic [575:0] engine_in_window_s8;
  logic [63:0] engine_in_residual_s8;
  logic [2:0] engine_in_group_index;
  logic engine_in_group_last;
  logic [15:0] engine_in_x, engine_in_y;
  logic engine_in_sof, engine_in_eol, engine_in_eof;
  logic engine_out_valid, engine_out_ready;
  logic [63:0] engine_out_data_s8;
  logic [2:0] engine_out_group_index;
  logic engine_out_group_last;
  logic [15:0] engine_out_x, engine_out_y;
  logic engine_out_sof, engine_out_eol, engine_out_eof;
  logic [4:0] engine_stage_index;
  logic [7:0] engine_stage_opcode;
  logic engine_stage_active, engine_adapter_required, engine_stage_done;
  logic engine_overflow_seen, engine_config_capture_complete;

  assign engine_in_valid            = adapter_engine_valid;
  assign adapter_engine_ready      = engine_in_ready;
  assign engine_in_window_s8       = adapter_engine_window_s8;
  assign engine_in_residual_s8     = adapter_engine_residual_s8;
  assign engine_in_group_index     = adapter_engine_group_index;
  assign engine_in_group_last      = adapter_engine_group_last;
  assign engine_in_x               = adapter_engine_x;
  assign engine_in_y               = adapter_engine_y;
  assign engine_in_sof             = adapter_engine_sof;
  assign engine_in_eol             = adapter_engine_eol;
  assign engine_in_eof             = adapter_engine_eof;
  assign adapter_result_valid      = engine_out_valid;
  assign engine_out_ready          = adapter_result_ready;
  assign adapter_result_data_s8    = engine_out_data_s8;
  assign adapter_result_group_index= engine_out_group_index;
  assign adapter_result_group_last = engine_out_group_last;
  assign adapter_result_x           = engine_out_x;
  assign adapter_result_y           = engine_out_y;
  assign adapter_result_sof         = engine_out_sof;
  assign adapter_result_eol         = engine_out_eol;
  assign adapter_result_eof         = engine_out_eof;
  assign adapter_final_ready        = 1'b1;
  assign cache_stage_start_ready    = 1'b1;

  c1_r1_microstyle_tensor_adapter #(
    .REQUIRED_STAGES(STAGES),
    .TENSOR_BANK_BYTES(BANK_BYTES),
    .STRICT_DESCRIPTOR_VALIDATION(1),
    .ENABLE_WINDOW_CACHE_SIDEBAND(0)
  ) u_adapter (
    .clk, .rst, .adapter_start_valid, .adapter_start_ready,
    .adapter_abort, .adapter_stage_config_valid,
    .adapter_stage_config_ready, .adapter_stage_config_index,
    .adapter_stage_config_descriptor, .adapter_stage_config_generation,
    .adapter_error, .adapter_error_code, .adapter_source_valid,
    .adapter_source_ready, .adapter_source_data_s8, .adapter_source_x,
    .adapter_source_y, .adapter_source_sof, .adapter_source_eol,
    .adapter_source_eof, .adapter_engine_valid, .adapter_engine_ready,
    .adapter_engine_window_s8, .adapter_engine_residual_s8,
    .adapter_engine_group_index, .adapter_engine_group_last,
    .adapter_engine_x, .adapter_engine_y, .adapter_engine_sof,
    .adapter_engine_eol, .adapter_engine_eof, .adapter_result_valid,
    .adapter_result_ready, .adapter_result_data_s8,
    .adapter_result_group_index, .adapter_result_group_last,
    .adapter_result_x, .adapter_result_y, .adapter_result_sof,
    .adapter_result_eol, .adapter_result_eof, .adapter_final_valid,
    .adapter_final_ready, .adapter_final_data_s8, .adapter_final_x,
    .adapter_final_y, .adapter_final_sof, .adapter_final_eol,
    .adapter_final_eof, .tensor_base_addr, .cache_stage_start_valid,
    .cache_stage_start_ready, .cache_stage_enable, .cache_stage_base_addr,
    .cache_stage_width, .cache_stage_height, .cache_stage_groups,
    .mem_req_valid, .mem_req_ready, .mem_req_write, .mem_req_addr,
    .mem_req_wdata, .mem_req_wstrb, .mem_req_cacheable, .mem_req_cache_x,
    .mem_req_cache_y, .mem_req_cache_group, .mem_rsp_valid,
    .mem_rsp_ready, .mem_rsp_error, .mem_rsp_rdata, .adapter_busy,
    .adapter_done, .adapter_aborted, .adapter_config_complete,
    .active_stage_index(adapter_active_stage),
    .active_stage_opcode(adapter_active_opcode),
    .active_input_bank(adapter_input_bank),
    .active_output_bank(adapter_output_bank),
    .active_residual_bank(adapter_residual_bank)
  );

  c1_r1_microstyle_cnn_top #(
    .REQUIRED_STAGES(STAGES), .PARAM_ADDR_W(11),
    .PARAM_ARENA_BYTES(PARAM_BYTES), .MAX_CHANNELS(48),
    .MAX_WEIGHT_BYTES(2592),
    .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
  ) u_engine (
    .clk, .rst, .abort(adapter_abort), .start_valid(engine_start_valid),
    .start_ready(engine_start_ready), .stage_count(engine_stage_count),
    .config_generation(engine_config_generation),
    .parameter_active_valid(engine_parameter_active_valid),
    .parameter_generation(engine_parameter_generation),
    .busy(engine_busy), .done(engine_done), .aborted(engine_aborted),
    .error(engine_error), .error_code(engine_error_code),
    .stage_config_valid(engine_stage_config_valid),
    .stage_config_ready(engine_stage_config_ready),
    .stage_config_index(engine_stage_config_index),
    .stage_config_descriptor(engine_stage_config_descriptor),
    .stage_config_generation(engine_stage_config_generation),
    .param_rd_en, .param_rd_addr, .param_rd_valid, .param_rd_error,
    .param_rd_data, .in_valid(engine_in_valid), .in_ready(engine_in_ready),
    .in_window_s8(engine_in_window_s8), .in_residual_s8(engine_in_residual_s8),
    .in_group_index(engine_in_group_index), .in_group_last(engine_in_group_last),
    .in_x(engine_in_x), .in_y(engine_in_y), .in_sof(engine_in_sof),
    .in_eol(engine_in_eol), .in_eof(engine_in_eof),
    .out_valid(engine_out_valid), .out_ready(engine_out_ready),
    .out_data_s8(engine_out_data_s8),
    .out_group_index(engine_out_group_index),
    .out_group_last(engine_out_group_last), .out_x(engine_out_x),
    .out_y(engine_out_y), .out_sof(engine_out_sof),
    .out_eol(engine_out_eol), .out_eof(engine_out_eof),
    .stage_index(engine_stage_index), .stage_opcode(engine_stage_opcode),
    .stage_active(engine_stage_active),
    .adapter_required(engine_adapter_required), .stage_done(engine_stage_done),
    .overflow_seen(engine_overflow_seen),
    .config_capture_complete(engine_config_capture_complete)
  );

`ifdef C1_USE_PARAMETER_BANK
  // Focused handoff mode uses the production atomic dual-bank parameter RAM.
  logic parameter_load_start, parameter_load_start_ready;
  logic parameter_load_valid, parameter_load_ready;
  logic [127:0] parameter_load_data;
  logic parameter_load_last, parameter_load_abort;
  logic parameter_load_busy, parameter_load_done, parameter_load_aborted;
  logic parameter_load_error;
  logic [2:0] parameter_load_error_code;
  logic parameter_bank_active_valid, parameter_bank_active_bank;
  logic [31:0] parameter_bank_generation;
  logic [0:0] parameter_bank_rd_en, parameter_bank_rd_valid,
              parameter_bank_rd_error;
  logic [10:0] parameter_bank_rd_addr;
  logic [127:0] parameter_bank_rd_data;

  assign engine_parameter_active_valid = parameter_bank_active_valid;
  assign engine_parameter_generation = parameter_bank_generation;
  assign parameter_bank_rd_en[0] = param_rd_en;
  assign parameter_bank_rd_addr = param_rd_addr;
  assign param_rd_valid = parameter_bank_rd_valid[0];
  assign param_rd_error = parameter_bank_rd_error[0];
  assign param_rd_data = parameter_bank_rd_data;

  c1_r1_parameter_bank #(
    .ARENA_BYTES(PARAM_BYTES), .READ_PORTS(1), .ADDR_W(11)
  ) u_parameter_bank (
    .clk, .rst,
    .load_start(parameter_load_start),
    .load_start_ready(parameter_load_start_ready),
    .load_valid(parameter_load_valid), .load_ready(parameter_load_ready),
    .load_data(parameter_load_data), .load_last(parameter_load_last),
    .load_abort(parameter_load_abort), .load_busy(parameter_load_busy),
    .load_done(parameter_load_done), .load_aborted(parameter_load_aborted),
    .load_error(parameter_load_error),
    .load_error_code(parameter_load_error_code),
    .active_valid(parameter_bank_active_valid),
    .active_bank(parameter_bank_active_bank),
    .generation(parameter_bank_generation),
    .rd_en(parameter_bank_rd_en), .rd_addr(parameter_bank_rd_addr),
    .rd_valid(parameter_bank_rd_valid), .rd_error(parameter_bank_rd_error),
    .rd_data(parameter_bank_rd_data)
  );
`endif

`ifndef C1_USE_PARAMETER_BANK
  // Registered one-outstanding parameter response model.
  logic parameter_pending_q;
  integer parameter_pending_addr_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      parameter_pending_q <= 1'b0;
      param_rd_valid <= 1'b0;
      param_rd_error <= 1'b0;
      param_rd_data <= 128'd0;
    end else begin
      param_rd_valid <= 1'b0;
      param_rd_error <= 1'b0;
      if (param_rd_en) begin
        if (parameter_pending_q)
          $fatal(1, "parameter scheduler issued two outstanding reads");
        parameter_pending_q <= 1'b1;
        parameter_pending_addr_q <= param_rd_addr;
      end
      if (parameter_pending_q) begin
        if (parameter_pending_addr_q < 0 ||
            parameter_pending_addr_q >= PARAM_WORDS)
          $fatal(1, "parameter address out of range: %0d",
                 parameter_pending_addr_q);
        param_rd_data <= parameter_mem[parameter_pending_addr_q];
        param_rd_valid <= 1'b1;
        parameter_pending_q <= 1'b0;
      end
    end
  end
`endif

  // Small DDR model for the adapter.  A short deterministic response delay
  // exercises the adapter's request/response hold contract without creating
  // a large waveform or simulation directory.
  logic [63:0] tensor_bank0 [0:SPARSE_WORDS-1];
  logic [63:0] tensor_bank1 [0:SPARSE_WORDS-1];
  logic [63:0] tensor_bank2 [0:SPARSE_WORDS-1];
  logic mem_pending_q;
  logic [2:0] mem_delay_q;
  logic [63:0] mem_response_data_q;
  logic mem_response_error_q;
  logic [31:0] lfsr_q;
  integer mem_pending_index_q;
  integer mem_bank;
  integer mem_local_index;
  integer lane;
`ifdef C1_STAGE1_HANDOFF
  // Stage-boundary accounting is intentionally kept in the BFM: it proves
  // that stage 1 consumes the words written by stage 0, without adding any
  // production RTL state or a large tensor image.
  logic [SPARSE_WORDS-1:0] bank1_written_q;
  // Stage 2 consumes bank0 words produced by stage 1.  Keep a separate
  // provenance bitmap because bank0 is also used for the source frame and
  // the stage-1 writes intentionally overwrite its low addresses.
  logic [SPARSE_WORDS-1:0] bank0_stage1_written_q;
  // Stage 2 also overwrites bank1 (the same physical low-address window used
  // by stage 0), so stage 3 gets its own provenance bitmap.
  logic [SPARSE_WORDS-1:0] bank1_stage2_written_q;
  // Stage 3 writes bank2, which is the source bank for stage 4.
  logic [SPARSE_WORDS-1:0] bank2_stage3_written_q;
  // Stage 4 overwrites bank1 with the C24 project output.  Stage 5 must not
  // mistake the earlier C48 stage-2 words for valid primary operands.
  logic [SPARSE_WORDS-1:0] bank1_stage4_written_q;
  // Stage 5 overwrites bank2 with the residual-add output.  Stage 6 consumes
  // this bank, so keep a distinct producer bitmap from stage 3.
  logic [SPARSE_WORDS-1:0] bank2_stage5_written_q;
  // Stage 6 overwrites bank0 with the C48 expansion output.  Stage 7 consumes
  // this bank, so keep a distinct producer bitmap from the earlier stage-1
  // writes in the same low-address window.
  logic [SPARSE_WORDS-1:0] bank0_stage6_written_q;
  // Stage 7 overwrites bank1 with the C48 depthwise output.  Keep provenance
  // separate from the earlier stage-0/2/4 contents for any later handoff.
  logic [SPARSE_WORDS-1:0] bank1_stage7_written_q;
  // Stages 8..20 continue the ping-pong/skip-bank schedule.  Each producer
  // gets an independent bitmap because low tensor addresses are deliberately
  // reused as the spatial shape changes (2x2 -> 4x4 -> 8x8).
  logic [SPARSE_WORDS-1:0] bank0_stage8_written_q;
  logic [SPARSE_WORDS-1:0] bank1_stage9_written_q;
  logic [SPARSE_WORDS-1:0] bank2_stage10_written_q;
  logic [SPARSE_WORDS-1:0] bank0_stage11_written_q;
  logic [SPARSE_WORDS-1:0] bank2_stage12_written_q;
  logic [SPARSE_WORDS-1:0] bank0_stage13_written_q;
  logic [SPARSE_WORDS-1:0] bank1_stage14_written_q;
  logic [SPARSE_WORDS-1:0] bank0_stage15_written_q;
  logic [SPARSE_WORDS-1:0] bank1_stage16_written_q;
  logic [SPARSE_WORDS-1:0] bank0_stage17_written_q;
  logic [SPARSE_WORDS-1:0] bank1_stage18_written_q;
  logic [SPARSE_WORDS-1:0] bank0_stage19_written_q;
  logic [SPARSE_WORDS-1:0] bank1_stage20_written_q;
  logic handoff_abort_q;
  integer source_write_count;
  integer stage0_write_count;
  integer stage0_read_count;
  integer stage1_read_count;
  integer stage1_write_count;
  integer stage2_read_count;
  integer stage2_write_count;
  integer stage3_read_count;
  integer stage3_write_count;
  integer stage4_read_count;
  integer stage4_write_count;
  integer stage5_read_count;
  integer stage5_main_read_count;
  integer stage5_residual_read_count;
  integer stage5_write_count;
  integer stage6_read_count;
  integer stage6_write_count;
  integer stage7_read_count;
  integer stage7_write_count;
  integer stage8_read_count;
  integer stage8_write_count;
  integer stage9_read_count;
  integer stage9_main_read_count;
  integer stage9_residual_read_count;
  integer stage9_write_count;
  integer stage10_read_count;
  integer stage10_write_count;
  integer stage11_read_count;
  integer stage11_write_count;
  integer stage12_read_count;
  integer stage12_write_count;
  integer stage13_read_count;
  integer stage13_main_read_count;
  integer stage13_residual_read_count;
  integer stage13_write_count;
  integer stage14_read_count;
  integer stage14_write_count;
  integer stage15_read_count;
  integer stage15_write_count;
  integer stage16_read_count;
  integer stage16_write_count;
  integer stage17_read_count;
  integer stage17_write_count;
  integer stage18_read_count;
  integer stage18_write_count;
  integer stage19_read_count;
  integer stage19_write_count;
  integer stage20_read_count;
  integer stage20_write_count;
  integer stage21_read_count;
  integer handoff_mem_txn_count;
  integer handoff_forced_response_delay;
  assign adapter_abort = handoff_abort_q;

  function automatic integer stage1_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer tap_index;
    integer group_index;
    integer dx;
    integer dy;
    integer sx;
    integer sy;
    begin
      // Stage 1 consumes a 4x4 input plane with two C8 groups and produces a
      // 2x2 output plane.  Records are raster ordered by output pixel, then
      // input group, then the nine SAME_REPLICATE taps.
      pixel_index = read_index / 18;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      tap_index = (read_index % 18) % 9;
      group_index = (read_index % 18) / 9;
      dy = tap_index / 3;
      dx = tap_index % 3;
      sx = output_x * 2 + dx - 1;
      sy = output_y * 2 + dy - 1;
      if (sx < 0) sx = 0;
      else if (sx > 3) sx = 3;
      if (sy < 0) sy = 0;
      else if (sy > 3) sy = 3;
      stage1_read_word = ((sy * 4 + sx) * 2) + group_index;
    end
  endfunction

  function automatic integer stage2_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer group_index;
    begin
      // Stage 2 is res0.expand1x1: a 2x2 input/output plane, three input
      // groups, and one center-tap read per group.  The adapter's 1x1 path
      // therefore emits twelve reads in raster-pixel/group order.
      pixel_index = read_index / 3;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      group_index = read_index % 3;
      stage2_read_word = ((output_y * 2 + output_x) * 3) + group_index;
    end
  endfunction

  function automatic integer stage3_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer tap_index;
    integer group_index;
    integer dx;
    integer dy;
    integer sx;
    integer sy;
    begin
      // Stage 3 is res0.depthwise3x3: a 2x2 input/output plane with six C8
      // groups.  Each output pixel/group consumes a SAME_REPLICATE 3x3
      // window, so records arrive as pixel -> group -> tap.
      pixel_index = read_index / 54;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      tap_index = (read_index % 54) % 9;
      group_index = (read_index % 54) / 9;
      dy = tap_index / 3;
      dx = tap_index % 3;
      sx = output_x + dx - 1;
      sy = output_y + dy - 1;
      if (sx < 0) sx = 0;
      else if (sx > 1) sx = 1;
      if (sy < 0) sy = 0;
      else if (sy > 1) sy = 1;
      stage3_read_word = ((sy * 2 + sx) * 6) + group_index;
    end
  endfunction

  function automatic integer stage4_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer group_index;
    begin
      // Stage 4 is res0.project1x1: C48 input (six C8 groups) to C24
      // output (three groups), with one center-tap read per input group.
      pixel_index = read_index / 6;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      group_index = read_index % 6;
      stage4_read_word = ((output_y * 2 + output_x) * 6) + group_index;
    end
  endfunction

  function automatic integer stage5_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer group_index;
    begin
      // Both primary and residual stage-5 reads are C24, three groups per
      // pixel, and follow the same raster/group order.  They are separated by
      // bank and counters at the call site.
      pixel_index = read_index / 3;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      group_index = read_index % 3;
      stage5_read_word = ((output_y * 2 + output_x) * 3) + group_index;
    end
  endfunction

  function automatic integer stage6_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer group_index;
    begin
      // Stage 6 is res1.expand1x1: C24 input (three groups) to C48 output
      // (six groups), again with one center-tap read per input group.
      pixel_index = read_index / 3;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      group_index = read_index % 3;
      stage6_read_word = ((output_y * 2 + output_x) * 3) + group_index;
    end
  endfunction

  function automatic integer stage7_read_word(input integer read_index);
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer tap_index;
    integer group_index;
    integer dx;
    integer dy;
    integer sx;
    integer sy;
    begin
      // Stage 7 is res1.depthwise3x3: a 2x2 input/output plane with six C8
      // groups.  The adapter emits each SAME_REPLICATE window in
      // raster-pixel -> input-group -> tap order, just like stage 3.
      pixel_index = read_index / 54;
      output_x = pixel_index % 2;
      output_y = pixel_index / 2;
      tap_index = (read_index % 54) % 9;
      group_index = (read_index % 54) / 9;
      dy = tap_index / 3;
      dx = tap_index % 3;
      sx = output_x + dx - 1;
      sy = output_y + dy - 1;
      if (sx < 0) sx = 0;
      else if (sx > 1) sx = 1;
      if (sy < 0) sy = 0;
      else if (sy > 1) sy = 1;
      stage7_read_word = ((sy * 2 + sx) * 6) + group_index;
    end
  endfunction

  function automatic integer stage8_21_read_word(
      input integer stage_index, input integer read_index);
    integer input_width;
    integer input_height;
    integer input_groups;
    integer output_width;
    integer output_height;
    integer windowed;
    integer taps;
    integer pixel_index;
    integer output_x;
    integer output_y;
    integer tap_index;
    integer group_index;
    integer dx;
    integer dy;
    integer sx;
    integer sy;
    begin
      // The production adapter emits one request per 64-bit C8 beat.  The
      // stage-specific geometry below mirrors the descriptor table and keeps
      // the BFM independent of the generated operand payload values.
      input_width = 2;
      input_height = 2;
      input_groups = 1;
      output_width = 2;
      output_height = 2;
      windowed = 0;
      case (stage_index)
        8: begin input_groups = 6; end
        9: begin input_groups = 3; end
        10: begin input_groups = 3; end
        11: begin input_groups = 6; windowed = 1; end
        12: begin input_groups = 6; end
        13: begin input_groups = 3; end
        14: begin input_width = 2; input_height = 2;
                  output_width = 4; output_height = 4; input_groups = 3; end
        15: begin input_width = 4; input_height = 4;
                  output_width = 4; output_height = 4;
                  input_groups = 3; windowed = 1; end
        16: begin input_width = 4; input_height = 4;
                  output_width = 4; output_height = 4; input_groups = 3; end
        17: begin input_width = 4; input_height = 4;
                  output_width = 8; output_height = 8; input_groups = 2; end
        18: begin input_width = 8; input_height = 8;
                  output_width = 8; output_height = 8;
                  input_groups = 2; windowed = 1; end
        19: begin input_width = 8; input_height = 8;
                  output_width = 8; output_height = 8; input_groups = 2; end
        20: begin input_width = 8; input_height = 8;
                  output_width = 8; output_height = 8;
                  input_groups = 1; windowed = 1; end
        21: begin input_width = 8; input_height = 8;
                  output_width = 8; output_height = 8; input_groups = 1; end
        default: begin end
      endcase
      taps = windowed ? 9 : 1;
      pixel_index = read_index / (input_groups * taps);
      output_x = pixel_index % output_width;
      output_y = pixel_index / output_width;
      if (windowed) begin
        tap_index = (read_index % (input_groups * taps)) % taps;
        group_index = (read_index % (input_groups * taps)) / taps;
        dy = tap_index / 3;
        dx = tap_index % 3;
        sx = output_x + dx - 1;
        sy = output_y + dy - 1;
        if (sx < 0) sx = 0;
        else if (sx >= input_width) sx = input_width - 1;
        if (sy < 0) sy = 0;
        else if (sy >= input_height) sy = input_height - 1;
      end else begin
        group_index = read_index % input_groups;
        if ((stage_index == 14) || (stage_index == 17)) begin
          sx = output_x >> 1;
          sy = output_y >> 1;
        end else begin
          sx = output_x;
          sy = output_y;
        end
      end
      stage8_21_read_word = ((sy * input_width + sx) * input_groups) +
                            group_index;
    end
  endfunction
`endif
  assign mem_req_ready = !mem_pending_q && lfsr_q[0];
  assign mem_rsp_valid = mem_pending_q && (mem_delay_q == 0);
  assign mem_rsp_error = mem_response_error_q;
  assign mem_rsp_rdata = mem_response_data_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_pending_q <= 1'b0;
      mem_delay_q <= 3'd0;
      mem_response_data_q <= 64'd0;
      mem_response_error_q <= 1'b0;
      lfsr_q <= 32'h71a2_45c9;
`ifdef C1_STAGE1_HANDOFF
      bank1_written_q <= '0;
      bank0_stage1_written_q <= '0;
      bank1_stage2_written_q <= '0;
      bank2_stage3_written_q <= '0;
      bank1_stage4_written_q <= '0;
      bank2_stage5_written_q <= '0;
      bank0_stage6_written_q <= '0;
      bank1_stage7_written_q <= '0;
      bank0_stage8_written_q <= '0;
      bank1_stage9_written_q <= '0;
      bank2_stage10_written_q <= '0;
      bank0_stage11_written_q <= '0;
      bank2_stage12_written_q <= '0;
      bank0_stage13_written_q <= '0;
      bank1_stage14_written_q <= '0;
      bank0_stage15_written_q <= '0;
      bank1_stage16_written_q <= '0;
      bank0_stage17_written_q <= '0;
      bank1_stage18_written_q <= '0;
      bank0_stage19_written_q <= '0;
      bank1_stage20_written_q <= '0;
      handoff_abort_q <= 1'b0;
      source_write_count <= 0;
      stage0_write_count <= 0;
      stage0_read_count <= 0;
      stage1_read_count <= 0;
      stage1_write_count <= 0;
      stage2_read_count <= 0;
      stage2_write_count <= 0;
      stage3_read_count <= 0;
      stage3_write_count <= 0;
      stage4_read_count <= 0;
      stage4_write_count <= 0;
      stage5_read_count <= 0;
      stage5_main_read_count <= 0;
      stage5_residual_read_count <= 0;
      stage5_write_count <= 0;
      stage6_read_count <= 0;
      stage6_write_count <= 0;
      stage7_read_count <= 0;
      stage7_write_count <= 0;
      stage8_read_count <= 0;
      stage8_write_count <= 0;
      stage9_read_count <= 0;
      stage9_main_read_count <= 0;
      stage9_residual_read_count <= 0;
      stage9_write_count <= 0;
      stage10_read_count <= 0;
      stage10_write_count <= 0;
      stage11_read_count <= 0;
      stage11_write_count <= 0;
      stage12_read_count <= 0;
      stage12_write_count <= 0;
      stage13_read_count <= 0;
      stage13_main_read_count <= 0;
      stage13_residual_read_count <= 0;
      stage13_write_count <= 0;
      stage14_read_count <= 0;
      stage14_write_count <= 0;
      stage15_read_count <= 0;
      stage15_write_count <= 0;
      stage16_read_count <= 0;
      stage16_write_count <= 0;
      stage17_read_count <= 0;
      stage17_write_count <= 0;
      stage18_read_count <= 0;
      stage18_write_count <= 0;
      stage19_read_count <= 0;
      stage19_write_count <= 0;
      stage20_read_count <= 0;
      stage20_write_count <= 0;
      stage21_read_count <= 0;
      handoff_mem_txn_count <= 0;
      handoff_forced_response_delay <= 0;
`endif
    end else begin
      lfsr_q <= {lfsr_q[30:0],
                 lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
      if (mem_pending_q && (mem_delay_q != 0))
        mem_delay_q <= mem_delay_q - 1'b1;
      if (mem_req_valid && mem_req_ready) begin
`ifdef C1_STAGE1_HANDOFF
        handoff_mem_txn_count <= handoff_mem_txn_count + 1;
`endif
        if (mem_pending_q)
          $fatal(1, "adapter issued a second outstanding tensor request");
        if (mem_req_addr[2:0] != 0 || mem_req_addr < BASE_ADDR ||
            mem_req_addr >= BASE_ADDR + 3 * BANK_BYTES)
          $fatal(1, "tensor address out of range: %h", mem_req_addr);
        mem_bank = (mem_req_addr - BASE_ADDR) / BANK_BYTES;
        mem_local_index = ((mem_req_addr - BASE_ADDR) % BANK_BYTES) >> 3;
        if (mem_bank < 0 || mem_bank > 2 ||
            mem_local_index < 0 || mem_local_index >= SPARSE_WORDS)
          $fatal(1, "tensor sparse BFM window overflow bank=%0d word=%0d",
                 mem_bank, mem_local_index);
        mem_pending_index_q <= mem_local_index;
        mem_pending_q <= 1'b1;
        mem_delay_q <= {1'b0, lfsr_q[3:2]};
        mem_response_error_q <= 1'b0;
        if (mem_req_write) begin
          if (mem_req_wstrb != 8'hff)
            $fatal(1, "adapter tensor write was not a full C8 beat");
`ifdef C1_STAGE1_HANDOFF
          if ((mem_bank == 0) && (source_write_count < FRAME_W * FRAME_H)) begin
            if (mem_local_index != source_write_count)
              $fatal(1, "source write address mismatch got=%0d exp=%0d",
                     mem_local_index, source_write_count);
            source_write_count <= source_write_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 0)) begin
            if (stage0_write_count >= 32 ||
                mem_local_index != stage0_write_count)
              $fatal(1, "stage0 output write mismatch word=%0d local=%0d",
                     stage0_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[stage0_write_count])
              $fatal(1, "stage0 handoff word mismatch n=%0d got=%h exp=%h",
                     stage0_write_count, mem_req_wdata,
                     expected_records[stage0_write_count]);
            bank1_written_q[mem_local_index] <= 1'b1;
            stage0_write_count <= stage0_write_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 1)) begin
            if (stage1_write_count >= HANDOFF_STAGE1_WRITES ||
                mem_local_index != stage1_write_count)
              $fatal(1, "stage1 output write mismatch word=%0d local=%0d",
                     stage1_write_count, mem_local_index);
             if (mem_req_wdata !== expected_records[32 + stage1_write_count])
               $fatal(1, "stage1 output mismatch n=%0d got=%h exp=%h",
                      stage1_write_count, mem_req_wdata,
                      expected_records[32 + stage1_write_count]);
            bank0_stage1_written_q[mem_local_index] <= 1'b1;
            stage1_write_count <= stage1_write_count + 1;
            if (stage1_write_count == HANDOFF_STAGE1_WRITES - 1) begin
`ifndef C1_STAGE2_FULL
              // Keep the final write response outstanding for several cycles
              // after abort is armed.  This makes the adapter's drain contract
              // deterministic instead of relying on the pseudo-random delay.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 2)) begin
            if (stage2_write_count >= HANDOFF_STAGE2_WRITES ||
                mem_local_index != stage2_write_count)
              $fatal(1, "stage2 output write mismatch word=%0d local=%0d",
                     stage2_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[44 + stage2_write_count])
              $fatal(1, "stage2 output mismatch n=%0d got=%h exp=%h",
                     stage2_write_count, mem_req_wdata,
                     expected_records[44 + stage2_write_count]);
            bank1_stage2_written_q[mem_local_index] <= 1'b1;
            stage2_write_count <= stage2_write_count + 1;
            if (stage2_write_count == HANDOFF_STAGE2_WRITES - 1) begin
`ifndef C1_STAGE3_FULL
              // The stage-2 terminal write is the abort boundary.  Delaying
              // its response proves that the adapter drains an accepted write
              // even while abort is asserted.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 2) && (adapter_active_stage == 3)) begin
            if (stage3_write_count >= HANDOFF_STAGE3_WRITES ||
                mem_local_index != stage3_write_count)
              $fatal(1, "stage3 output write mismatch word=%0d local=%0d",
                     stage3_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[68 + stage3_write_count])
              $fatal(1, "stage3 output mismatch n=%0d got=%h exp=%h",
                     stage3_write_count, mem_req_wdata,
                     expected_records[68 + stage3_write_count]);
            bank2_stage3_written_q[mem_local_index] <= 1'b1;
            stage3_write_count <= stage3_write_count + 1;
            if (stage3_write_count == HANDOFF_STAGE3_WRITES - 1) begin
`ifndef C1_STAGE4_FULL
              // The stage-3 terminal write is the bounded abort boundary.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 4)) begin
            if (stage4_write_count >= HANDOFF_STAGE4_WRITES ||
                mem_local_index != stage4_write_count)
              $fatal(1, "stage4 output write mismatch word=%0d local=%0d",
                     stage4_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[92 + stage4_write_count])
              $fatal(1, "stage4 output mismatch n=%0d got=%h exp=%h",
                     stage4_write_count, mem_req_wdata,
                     expected_records[92 + stage4_write_count]);
            bank1_stage4_written_q[mem_local_index] <= 1'b1;
            stage4_write_count <= stage4_write_count + 1;
            if (stage4_write_count == HANDOFF_STAGE4_WRITES - 1) begin
`ifndef C1_STAGE5_FULL
              // The stage-4 terminal write is the bounded abort boundary.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 2) && (adapter_active_stage == 5)) begin
            if (stage5_write_count >= HANDOFF_STAGE5_WRITES ||
                mem_local_index != stage5_write_count)
              $fatal(1, "stage5 output write mismatch word=%0d local=%0d",
                     stage5_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[104 + stage5_write_count])
              $fatal(1, "stage5 output mismatch n=%0d got=%h exp=%h",
                     stage5_write_count, mem_req_wdata,
                     expected_records[104 + stage5_write_count]);
            bank2_stage5_written_q[mem_local_index] <= 1'b1;
            stage5_write_count <= stage5_write_count + 1;
            if (stage5_write_count == HANDOFF_STAGE5_WRITES - 1) begin
`ifndef C1_STAGE6_FULL
              // The stage-5 terminal write is the bounded abort boundary.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 6)) begin
            if (stage6_write_count >= HANDOFF_STAGE6_WRITES ||
                mem_local_index != stage6_write_count)
              $fatal(1, "stage6 output write mismatch word=%0d local=%0d",
                     stage6_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[116 + stage6_write_count])
              $fatal(1, "stage6 output mismatch n=%0d got=%h exp=%h",
                     stage6_write_count, mem_req_wdata,
                     expected_records[116 + stage6_write_count]);
            bank0_stage6_written_q[mem_local_index] <= 1'b1;
            stage6_write_count <= stage6_write_count + 1;
            if (stage6_write_count == HANDOFF_STAGE6_WRITES - 1) begin
`ifndef C1_STAGE7_FULL
              // Stage 6 is the terminal boundary unless stage 7 is enabled;
              // its final write is always drained after abort.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 7)) begin
            if (stage7_write_count >= HANDOFF_STAGE7_WRITES ||
                mem_local_index != stage7_write_count)
              $fatal(1, "stage7 output write mismatch word=%0d local=%0d",
                     stage7_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[140 + stage7_write_count])
              $fatal(1, "stage7 output mismatch n=%0d got=%h exp=%h",
                     stage7_write_count, mem_req_wdata,
                     expected_records[140 + stage7_write_count]);
            bank1_stage7_written_q[mem_local_index] <= 1'b1;
            stage7_write_count <= stage7_write_count + 1;
            if (stage7_write_count == HANDOFF_STAGE7_WRITES - 1) begin
`ifndef C1_STAGE8_FULL
              // Stage 7 is the terminal boundary only when no later handoff
              // is selected.  Delay the final response to exercise drain.
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 8)) begin
            if (stage8_write_count >= HANDOFF_STAGE8_WRITES ||
                mem_local_index != stage8_write_count)
              $fatal(1, "stage8 output write mismatch word=%0d local=%0d",
                     stage8_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[164 + stage8_write_count])
              $fatal(1, "stage8 output mismatch n=%0d got=%h exp=%h",
                     stage8_write_count, mem_req_wdata,
                     expected_records[164 + stage8_write_count]);
            bank0_stage8_written_q[mem_local_index] <= 1'b1;
            stage8_write_count <= stage8_write_count + 1;
            if (stage8_write_count == HANDOFF_STAGE8_WRITES - 1) begin
`ifndef C1_STAGE9_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 9)) begin
            if (stage9_write_count >= HANDOFF_STAGE9_WRITES ||
                mem_local_index != stage9_write_count)
              $fatal(1, "stage9 output write mismatch word=%0d local=%0d",
                     stage9_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[176 + stage9_write_count])
              $fatal(1, "stage9 output mismatch n=%0d got=%h exp=%h",
                     stage9_write_count, mem_req_wdata,
                     expected_records[176 + stage9_write_count]);
            bank1_stage9_written_q[mem_local_index] <= 1'b1;
            stage9_write_count <= stage9_write_count + 1;
            if (stage9_write_count == HANDOFF_STAGE9_WRITES - 1) begin
`ifndef C1_STAGE10_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 2) && (adapter_active_stage == 10)) begin
            if (stage10_write_count >= HANDOFF_STAGE10_WRITES ||
                mem_local_index != stage10_write_count)
              $fatal(1, "stage10 output write mismatch word=%0d local=%0d",
                     stage10_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[188 + stage10_write_count])
              $fatal(1, "stage10 output mismatch n=%0d got=%h exp=%h",
                     stage10_write_count, mem_req_wdata,
                     expected_records[188 + stage10_write_count]);
            bank2_stage10_written_q[mem_local_index] <= 1'b1;
            stage10_write_count <= stage10_write_count + 1;
            if (stage10_write_count == HANDOFF_STAGE10_WRITES - 1) begin
`ifndef C1_STAGE11_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 11)) begin
            if (stage11_write_count >= HANDOFF_STAGE11_WRITES ||
                mem_local_index != stage11_write_count)
              $fatal(1, "stage11 output write mismatch word=%0d local=%0d",
                     stage11_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[212 + stage11_write_count])
              $fatal(1, "stage11 output mismatch n=%0d got=%h exp=%h",
                     stage11_write_count, mem_req_wdata,
                     expected_records[212 + stage11_write_count]);
            bank0_stage11_written_q[mem_local_index] <= 1'b1;
            stage11_write_count <= stage11_write_count + 1;
            if (stage11_write_count == HANDOFF_STAGE11_WRITES - 1) begin
`ifndef C1_STAGE12_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 2) && (adapter_active_stage == 12)) begin
            if (stage12_write_count >= HANDOFF_STAGE12_WRITES ||
                mem_local_index != stage12_write_count)
              $fatal(1, "stage12 output write mismatch word=%0d local=%0d",
                     stage12_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[236 + stage12_write_count])
              $fatal(1, "stage12 output mismatch n=%0d got=%h exp=%h",
                     stage12_write_count, mem_req_wdata,
                     expected_records[236 + stage12_write_count]);
            bank2_stage12_written_q[mem_local_index] <= 1'b1;
            stage12_write_count <= stage12_write_count + 1;
            if (stage12_write_count == HANDOFF_STAGE12_WRITES - 1) begin
`ifndef C1_STAGE13_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 13)) begin
            if (stage13_write_count >= HANDOFF_STAGE13_WRITES ||
                mem_local_index != stage13_write_count)
              $fatal(1, "stage13 output write mismatch word=%0d local=%0d",
                     stage13_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[248 + stage13_write_count])
              $fatal(1, "stage13 output mismatch n=%0d got=%h exp=%h",
                     stage13_write_count, mem_req_wdata,
                     expected_records[248 + stage13_write_count]);
            bank0_stage13_written_q[mem_local_index] <= 1'b1;
            stage13_write_count <= stage13_write_count + 1;
            if (stage13_write_count == HANDOFF_STAGE13_WRITES - 1) begin
`ifndef C1_STAGE14_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 14)) begin
            if (stage14_write_count >= HANDOFF_STAGE14_WRITES ||
                mem_local_index != stage14_write_count)
              $fatal(1, "stage14 output write mismatch word=%0d local=%0d",
                     stage14_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[260 + stage14_write_count])
              $fatal(1, "stage14 output mismatch n=%0d got=%h exp=%h",
                     stage14_write_count, mem_req_wdata,
                     expected_records[260 + stage14_write_count]);
            bank1_stage14_written_q[mem_local_index] <= 1'b1;
            stage14_write_count <= stage14_write_count + 1;
            if (stage14_write_count == HANDOFF_STAGE14_WRITES - 1) begin
`ifndef C1_STAGE15_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 15)) begin
            if (stage15_write_count >= HANDOFF_STAGE15_WRITES ||
                mem_local_index != stage15_write_count)
              $fatal(1, "stage15 output write mismatch word=%0d local=%0d",
                     stage15_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[308 + stage15_write_count])
              $fatal(1, "stage15 output mismatch n=%0d got=%h exp=%h",
                     stage15_write_count, mem_req_wdata,
                     expected_records[308 + stage15_write_count]);
            bank0_stage15_written_q[mem_local_index] <= 1'b1;
            stage15_write_count <= stage15_write_count + 1;
            if (stage15_write_count == HANDOFF_STAGE15_WRITES - 1) begin
`ifndef C1_STAGE16_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 16)) begin
            if (stage16_write_count >= HANDOFF_STAGE16_WRITES ||
                mem_local_index != stage16_write_count)
              $fatal(1, "stage16 output write mismatch word=%0d local=%0d",
                     stage16_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[356 + stage16_write_count])
              $fatal(1, "stage16 output mismatch n=%0d got=%h exp=%h",
                     stage16_write_count, mem_req_wdata,
                     expected_records[356 + stage16_write_count]);
            bank1_stage16_written_q[mem_local_index] <= 1'b1;
            stage16_write_count <= stage16_write_count + 1;
            if (stage16_write_count == HANDOFF_STAGE16_WRITES - 1) begin
`ifndef C1_STAGE17_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 17)) begin
            if (stage17_write_count >= HANDOFF_STAGE17_WRITES ||
                mem_local_index != stage17_write_count)
              $fatal(1, "stage17 output write mismatch word=%0d local=%0d",
                     stage17_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[388 + stage17_write_count])
              $fatal(1, "stage17 output mismatch n=%0d got=%h exp=%h",
                     stage17_write_count, mem_req_wdata,
                     expected_records[388 + stage17_write_count]);
            bank0_stage17_written_q[mem_local_index] <= 1'b1;
            stage17_write_count <= stage17_write_count + 1;
            if (stage17_write_count == HANDOFF_STAGE17_WRITES - 1) begin
`ifndef C1_STAGE18_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 18)) begin
            if (stage18_write_count >= HANDOFF_STAGE18_WRITES ||
                mem_local_index != stage18_write_count)
              $fatal(1, "stage18 output write mismatch word=%0d local=%0d",
                     stage18_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[516 + stage18_write_count])
              $fatal(1, "stage18 output mismatch n=%0d got=%h exp=%h",
                     stage18_write_count, mem_req_wdata,
                     expected_records[516 + stage18_write_count]);
            bank1_stage18_written_q[mem_local_index] <= 1'b1;
            stage18_write_count <= stage18_write_count + 1;
            if (stage18_write_count == HANDOFF_STAGE18_WRITES - 1) begin
`ifndef C1_STAGE19_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 0) && (adapter_active_stage == 19)) begin
            if (stage19_write_count >= HANDOFF_STAGE19_WRITES ||
                mem_local_index != stage19_write_count)
              $fatal(1, "stage19 output write mismatch word=%0d local=%0d",
                     stage19_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[644 + stage19_write_count])
              $fatal(1, "stage19 output mismatch n=%0d got=%h exp=%h",
                     stage19_write_count, mem_req_wdata,
                     expected_records[644 + stage19_write_count]);
            bank0_stage19_written_q[mem_local_index] <= 1'b1;
            stage19_write_count <= stage19_write_count + 1;
            if (stage19_write_count == HANDOFF_STAGE19_WRITES - 1) begin
`ifndef C1_STAGE20_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else if ((mem_bank == 1) && (adapter_active_stage == 20)) begin
            if (stage20_write_count >= HANDOFF_STAGE20_WRITES ||
                mem_local_index != stage20_write_count)
              $fatal(1, "stage20 output write mismatch word=%0d local=%0d",
                     stage20_write_count, mem_local_index);
            if (mem_req_wdata !== expected_records[708 + stage20_write_count])
              $fatal(1, "stage20 output mismatch n=%0d got=%h exp=%h",
                     stage20_write_count, mem_req_wdata,
                     expected_records[708 + stage20_write_count]);
            bank1_stage20_written_q[mem_local_index] <= 1'b1;
            stage20_write_count <= stage20_write_count + 1;
            if (stage20_write_count == HANDOFF_STAGE20_WRITES - 1) begin
`ifndef C1_STAGE21_FULL
              handoff_abort_q <= 1'b1;
              mem_delay_q <= 3'd3;
              handoff_forced_response_delay <= 3;
`endif
            end
          end else begin
            $fatal(1, "unexpected handoff tensor write bank=%0d stage=%0d",
                   mem_bank, adapter_active_stage);
          end
`endif
          for (lane = 0; lane < 8; lane = lane + 1)
            if (mem_req_wstrb[lane])
              case (mem_bank)
                0: tensor_bank0[mem_local_index][lane*8 +: 8] <=
                       mem_req_wdata[lane*8 +: 8];
                1: tensor_bank1[mem_local_index][lane*8 +: 8] <=
                       mem_req_wdata[lane*8 +: 8];
                default: tensor_bank2[mem_local_index][lane*8 +: 8] <=
                       mem_req_wdata[lane*8 +: 8];
              endcase
          mem_response_data_q <= 64'd0;
        end else begin
          if (mem_req_wstrb != 0)
            $fatal(1, "adapter tensor read carried write strobes");
`ifdef C1_STAGE1_HANDOFF
          if ((mem_bank == 0) && (adapter_active_stage == 0)) begin
            stage0_read_count <= stage0_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 1)) begin
            if (!bank1_written_q[mem_local_index])
              $fatal(1, "stage1 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage1_read_word(stage1_read_count))
              $fatal(1, "stage1 input address mismatch n=%0d local=%0d",
                     stage1_read_count, mem_local_index);
            stage1_read_count <= stage1_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 2)) begin
            if (!bank0_stage1_written_q[mem_local_index])
              $fatal(1, "stage2 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage2_read_word(stage2_read_count))
              $fatal(1, "stage2 input address mismatch n=%0d local=%0d",
                     stage2_read_count, mem_local_index);
            stage2_read_count <= stage2_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 3)) begin
            if (!bank1_stage2_written_q[mem_local_index])
              $fatal(1, "stage3 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage3_read_word(stage3_read_count))
              $fatal(1, "stage3 input address mismatch n=%0d local=%0d",
                     stage3_read_count, mem_local_index);
            stage3_read_count <= stage3_read_count + 1;
          end else if ((mem_bank == 2) && (adapter_active_stage == 4)) begin
            // Stage 4 must consume the words produced by stage 3.  The
            // separate stage-3 bitmap is used even though both stages share
            // the low bank address window.
            if (!bank2_stage3_written_q[mem_local_index])
              $fatal(1, "stage4 read consumed unwritten bank2 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage4_read_word(stage4_read_count))
              $fatal(1, "stage4 input address mismatch n=%0d local=%0d",
                     stage4_read_count, mem_local_index);
            stage4_read_count <= stage4_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 5)) begin
            if (!bank1_stage4_written_q[mem_local_index])
              $fatal(1, "stage5 primary read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage5_read_word(stage5_main_read_count))
              $fatal(1, "stage5 primary address mismatch n=%0d local=%0d",
                     stage5_main_read_count, mem_local_index);
            stage5_main_read_count <= stage5_main_read_count + 1;
            stage5_read_count <= stage5_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 5)) begin
            if (!bank0_stage1_written_q[mem_local_index])
              $fatal(1, "stage5 residual read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage5_read_word(stage5_residual_read_count))
              $fatal(1, "stage5 residual address mismatch n=%0d local=%0d",
                     stage5_residual_read_count, mem_local_index);
            stage5_residual_read_count <= stage5_residual_read_count + 1;
            stage5_read_count <= stage5_read_count + 1;
          end else if ((mem_bank == 2) && (adapter_active_stage == 6)) begin
            if (!bank2_stage5_written_q[mem_local_index])
              $fatal(1, "stage6 read consumed unwritten bank2 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage6_read_word(stage6_read_count))
              $fatal(1, "stage6 input address mismatch n=%0d local=%0d",
                     stage6_read_count, mem_local_index);
            stage6_read_count <= stage6_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 7)) begin
            if (!bank0_stage6_written_q[mem_local_index])
              $fatal(1, "stage7 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage7_read_word(stage7_read_count))
              $fatal(1, "stage7 input address mismatch n=%0d local=%0d",
                     stage7_read_count, mem_local_index);
            stage7_read_count <= stage7_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 8)) begin
            if (!bank1_stage7_written_q[mem_local_index])
              $fatal(1, "stage8 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(8, stage8_read_count))
              $fatal(1, "stage8 input address mismatch n=%0d local=%0d",
                     stage8_read_count, mem_local_index);
            stage8_read_count <= stage8_read_count + 1;
          end else if ((adapter_active_stage == 9) && (mem_bank == 0)) begin
            if (!bank0_stage8_written_q[mem_local_index])
              $fatal(1, "stage9 primary read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(9, stage9_main_read_count))
              $fatal(1, "stage9 primary address mismatch n=%0d local=%0d",
                     stage9_main_read_count, mem_local_index);
            stage9_main_read_count <= stage9_main_read_count + 1;
            stage9_read_count <= stage9_read_count + 1;
          end else if ((adapter_active_stage == 9) && (mem_bank == 2)) begin
            if (!bank2_stage5_written_q[mem_local_index])
              $fatal(1, "stage9 residual read consumed unwritten bank2 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(9, stage9_residual_read_count))
              $fatal(1, "stage9 residual address mismatch n=%0d local=%0d",
                     stage9_residual_read_count, mem_local_index);
            stage9_residual_read_count <= stage9_residual_read_count + 1;
            stage9_read_count <= stage9_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 10)) begin
            if (!bank1_stage9_written_q[mem_local_index])
              $fatal(1, "stage10 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(10, stage10_read_count))
              $fatal(1, "stage10 input address mismatch n=%0d local=%0d",
                     stage10_read_count, mem_local_index);
            stage10_read_count <= stage10_read_count + 1;
          end else if ((mem_bank == 2) && (adapter_active_stage == 11)) begin
            if (!bank2_stage10_written_q[mem_local_index])
              $fatal(1, "stage11 read consumed unwritten bank2 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(11, stage11_read_count))
              $fatal(1, "stage11 input address mismatch n=%0d local=%0d",
                     stage11_read_count, mem_local_index);
            stage11_read_count <= stage11_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 12)) begin
            if (!bank0_stage11_written_q[mem_local_index])
              $fatal(1, "stage12 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(12, stage12_read_count))
              $fatal(1, "stage12 input address mismatch n=%0d local=%0d",
                     stage12_read_count, mem_local_index);
            stage12_read_count <= stage12_read_count + 1;
          end else if ((adapter_active_stage == 13) && (mem_bank == 2)) begin
            if (!bank2_stage12_written_q[mem_local_index])
              $fatal(1, "stage13 primary read consumed unwritten bank2 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(13, stage13_main_read_count))
              $fatal(1, "stage13 primary address mismatch n=%0d local=%0d",
                     stage13_main_read_count, mem_local_index);
            stage13_main_read_count <= stage13_main_read_count + 1;
            stage13_read_count <= stage13_read_count + 1;
          end else if ((adapter_active_stage == 13) && (mem_bank == 1)) begin
            if (!bank1_stage9_written_q[mem_local_index])
              $fatal(1, "stage13 residual read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(13, stage13_residual_read_count))
              $fatal(1, "stage13 residual address mismatch n=%0d local=%0d",
                     stage13_residual_read_count, mem_local_index);
            stage13_residual_read_count <= stage13_residual_read_count + 1;
            stage13_read_count <= stage13_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 14)) begin
            if (!bank0_stage13_written_q[mem_local_index])
              $fatal(1, "stage14 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(14, stage14_read_count))
              $fatal(1, "stage14 input address mismatch n=%0d local=%0d",
                     stage14_read_count, mem_local_index);
            stage14_read_count <= stage14_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 15)) begin
            if (!bank1_stage14_written_q[mem_local_index])
              $fatal(1, "stage15 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(15, stage15_read_count))
              $fatal(1, "stage15 input address mismatch n=%0d local=%0d",
                     stage15_read_count, mem_local_index);
            stage15_read_count <= stage15_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 16)) begin
            if (!bank0_stage15_written_q[mem_local_index])
              $fatal(1, "stage16 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(16, stage16_read_count))
              $fatal(1, "stage16 input address mismatch n=%0d local=%0d",
                     stage16_read_count, mem_local_index);
            stage16_read_count <= stage16_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 17)) begin
            if (!bank1_stage16_written_q[mem_local_index])
              $fatal(1, "stage17 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(17, stage17_read_count))
              $fatal(1, "stage17 input address mismatch n=%0d local=%0d",
                     stage17_read_count, mem_local_index);
            stage17_read_count <= stage17_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 18)) begin
            if (!bank0_stage17_written_q[mem_local_index])
              $fatal(1, "stage18 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(18, stage18_read_count))
              $fatal(1, "stage18 input address mismatch n=%0d local=%0d",
                     stage18_read_count, mem_local_index);
            stage18_read_count <= stage18_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 19)) begin
            if (!bank1_stage18_written_q[mem_local_index])
              $fatal(1, "stage19 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(19, stage19_read_count))
              $fatal(1, "stage19 input address mismatch n=%0d local=%0d",
                     stage19_read_count, mem_local_index);
            stage19_read_count <= stage19_read_count + 1;
          end else if ((mem_bank == 0) && (adapter_active_stage == 20)) begin
            if (!bank0_stage19_written_q[mem_local_index])
              $fatal(1, "stage20 read consumed unwritten bank0 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(20, stage20_read_count))
              $fatal(1, "stage20 input address mismatch n=%0d local=%0d",
                     stage20_read_count, mem_local_index);
            stage20_read_count <= stage20_read_count + 1;
          end else if ((mem_bank == 1) && (adapter_active_stage == 21)) begin
            if (!bank1_stage20_written_q[mem_local_index])
              $fatal(1, "stage21 read consumed unwritten bank1 word=%0d",
                     mem_local_index);
            if (mem_local_index != stage8_21_read_word(21, stage21_read_count))
              $fatal(1, "stage21 input address mismatch n=%0d local=%0d",
                     stage21_read_count, mem_local_index);
            stage21_read_count <= stage21_read_count + 1;
          end else begin
            $fatal(1, "unexpected handoff tensor read bank=%0d stage=%0d",
                   mem_bank, adapter_active_stage);
          end
`endif
          case (mem_bank)
            0: mem_response_data_q <= tensor_bank0[mem_local_index];
            1: mem_response_data_q <= tensor_bank1[mem_local_index];
            default: mem_response_data_q <= tensor_bank2[mem_local_index];
          endcase
        end
      end
      if (mem_rsp_valid && mem_rsp_ready)
        mem_pending_q <= 1'b0;
    end
  end

  function automatic logic [63:0] source_pixel_fn(input integer x, input integer y);
    logic [63:0] value;
    integer c;
    integer unsigned_code;
    integer signed_code;
    begin
      value = 64'd0;
      for (c = 0; c < 3; c = c + 1) begin
        unsigned_code = (17 * x + 31 * y + 53 * c + 11) & 255;
        signed_code = unsigned_code - 128;
        value[c*8 +: 8] = signed_code & 255;
      end
      source_pixel_fn = value;
    end
  endfunction

  task automatic pulse_adapter_start;
    begin
      @(negedge clk);
      tensor_base_addr = BASE_ADDR;
      adapter_start_valid = 1'b1;
      while (!adapter_start_ready) @(negedge clk);
      @(negedge clk);
      adapter_start_valid = 1'b0;
    end
  endtask

  task automatic pulse_engine_start;
    begin
      @(negedge clk);
      engine_start_valid = 1'b1;
      while (!engine_start_ready) @(negedge clk);
      @(negedge clk);
      engine_start_valid = 1'b0;
    end
  endtask

  task automatic send_adapter_config(input integer index);
    begin
      @(negedge clk);
      adapter_stage_config_index = index[15:0];
      adapter_stage_config_descriptor = descriptors[index];
      adapter_stage_config_generation = 8'h51;
      adapter_stage_config_valid = 1'b1;
      while (!adapter_stage_config_ready) @(negedge clk);
      @(negedge clk);
      adapter_stage_config_valid = 1'b0;
    end
  endtask

  task automatic send_engine_config(input integer index);
    begin
      @(negedge clk);
      engine_stage_config_index = index[15:0];
      engine_stage_config_descriptor = descriptors[index];
      engine_stage_config_generation = 8'h51;
      engine_stage_config_valid = 1'b1;
      while (!engine_stage_config_ready) @(negedge clk);
      @(negedge clk);
      engine_stage_config_valid = 1'b0;
    end
  endtask

  task automatic send_source_pixel(input integer x, input integer y);
    begin
      @(negedge clk);
      adapter_source_data_s8 = source_pixel_fn(x, y);
      adapter_source_x = x[15:0];
      adapter_source_y = y[15:0];
      adapter_source_sof = (x == 0) && (y == 0);
      adapter_source_eol = (x == FRAME_W - 1);
      adapter_source_eof = (x == FRAME_W - 1) && (y == FRAME_H - 1);
      adapter_source_valid = 1'b1;
      while (!adapter_source_ready) @(negedge clk);
      @(negedge clk);
      adapter_source_valid = 1'b0;
    end
  endtask

  task automatic send_source_frame;
    integer x, y;
    begin
      for (y = 0; y < FRAME_H; y = y + 1)
        for (x = 0; x < FRAME_W; x = x + 1)
          send_source_pixel(x, y);
    end
  endtask

`ifdef C1_USE_PARAMETER_BANK
  task automatic load_parameter_bank;
    integer load_i;
    integer load_timeout;
    begin
      @(negedge clk);
      parameter_load_start = 1'b1;
      while (!parameter_load_start_ready) @(negedge clk);
      @(negedge clk);
      parameter_load_start = 1'b0;
      for (load_i = 0; load_i < PARAM_WORDS; load_i = load_i + 1) begin
        @(negedge clk);
        parameter_load_data = parameter_mem[load_i];
        parameter_load_last = (load_i == PARAM_WORDS - 1);
        parameter_load_valid = 1'b1;
        while (!parameter_load_ready) @(negedge clk);
        @(negedge clk);
        parameter_load_valid = 1'b0;
        parameter_load_last = 1'b0;
      end
      load_timeout = 0;
      while (!parameter_load_done && load_timeout < 10000) begin
        @(negedge clk);
        load_timeout = load_timeout + 1;
      end
      if (!parameter_load_done || parameter_load_error ||
          !parameter_bank_active_valid || parameter_bank_generation != 1)
        $fatal(1, "parameter bank load failed done=%0d error=%0d gen=%0d",
               parameter_load_done, parameter_load_error,
               parameter_bank_generation);
    end
  endtask
`endif

  integer operand_cursor;
  integer expected_cursor;
  integer final_count;
  integer cycle_count;
  integer stage_done_count;
  logic [1023:0] current_input_record;
  logic [63:0] current_expected_record;
`ifdef C1_STAGE1_HANDOFF
  logic [4:0] handoff_expected_stage;
  logic [15:0] handoff_expected_x;
  logic [15:0] handoff_expected_y;
  logic [2:0] handoff_expected_group;
  logic handoff_expected_group_last;
  logic handoff_expected_sof;
  logic handoff_expected_eol;
  logic handoff_expected_eof;
  integer handoff_meta_index;
  integer handoff_meta_pixel;
  integer handoff_meta_width;
  integer handoff_meta_height;
  integer handoff_meta_groups;
  always_comb begin
    handoff_expected_stage = 5'd0;
    handoff_meta_index = expected_cursor;
    handoff_meta_width = 4;
    handoff_meta_height = 4;
    handoff_meta_groups = 2;
    if (expected_cursor >= 772) begin
      handoff_expected_stage = 5'd21;
      handoff_meta_index = expected_cursor - 772;
      handoff_meta_width = 8;
      handoff_meta_height = 8;
      handoff_meta_groups = 1;
    end else if (expected_cursor >= 708) begin
      handoff_expected_stage = 5'd20;
      handoff_meta_index = expected_cursor - 708;
      handoff_meta_width = 8;
      handoff_meta_height = 8;
      handoff_meta_groups = 1;
    end else if (expected_cursor >= 644) begin
      handoff_expected_stage = 5'd19;
      handoff_meta_index = expected_cursor - 644;
      handoff_meta_width = 8;
      handoff_meta_height = 8;
      handoff_meta_groups = 1;
    end else if (expected_cursor >= 516) begin
      handoff_expected_stage = 5'd18;
      handoff_meta_index = expected_cursor - 516;
      handoff_meta_width = 8;
      handoff_meta_height = 8;
      handoff_meta_groups = 2;
    end else if (expected_cursor >= 388) begin
      handoff_expected_stage = 5'd17;
      handoff_meta_index = expected_cursor - 388;
      handoff_meta_width = 8;
      handoff_meta_height = 8;
      handoff_meta_groups = 2;
    end else if (expected_cursor >= 356) begin
      handoff_expected_stage = 5'd16;
      handoff_meta_index = expected_cursor - 356;
      handoff_meta_width = 4;
      handoff_meta_height = 4;
      handoff_meta_groups = 2;
    end else if (expected_cursor >= 308) begin
      handoff_expected_stage = 5'd15;
      handoff_meta_index = expected_cursor - 308;
      handoff_meta_width = 4;
      handoff_meta_height = 4;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 260) begin
      handoff_expected_stage = 5'd14;
      handoff_meta_index = expected_cursor - 260;
      handoff_meta_width = 4;
      handoff_meta_height = 4;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 248) begin
      handoff_expected_stage = 5'd13;
      handoff_meta_index = expected_cursor - 248;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 236) begin
      handoff_expected_stage = 5'd12;
      handoff_meta_index = expected_cursor - 236;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 212) begin
      handoff_expected_stage = 5'd11;
      handoff_meta_index = expected_cursor - 212;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 188) begin
      handoff_expected_stage = 5'd10;
      handoff_meta_index = expected_cursor - 188;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 176) begin
      handoff_expected_stage = 5'd9;
      handoff_meta_index = expected_cursor - 176;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 164) begin
      handoff_expected_stage = 5'd8;
      handoff_meta_index = expected_cursor - 164;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 140) begin
      handoff_expected_stage = 5'd7;
      handoff_meta_index = expected_cursor - 140;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 116) begin
      handoff_expected_stage = 5'd6;
      handoff_meta_index = expected_cursor - 116;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 104) begin
      handoff_expected_stage = 5'd5;
      handoff_meta_index = expected_cursor - 104;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 92) begin
      handoff_expected_stage = 5'd4;
      handoff_meta_index = expected_cursor - 92;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end else if (expected_cursor >= 68) begin
      handoff_expected_stage = 5'd3;
      handoff_meta_index = expected_cursor - 68;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 44) begin
      handoff_expected_stage = 5'd2;
      handoff_meta_index = expected_cursor - 44;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 6;
    end else if (expected_cursor >= 32) begin
      handoff_expected_stage = 5'd1;
      handoff_meta_index = expected_cursor - 32;
      handoff_meta_width = 2;
      handoff_meta_height = 2;
      handoff_meta_groups = 3;
    end
    if (handoff_meta_index < 0)
      handoff_meta_index = 0;
    handoff_meta_pixel = handoff_meta_index / handoff_meta_groups;
    handoff_expected_group = handoff_meta_index % handoff_meta_groups;
    handoff_expected_x = handoff_meta_pixel % handoff_meta_width;
    handoff_expected_y = handoff_meta_pixel / handoff_meta_width;
    handoff_expected_group_last =
        (handoff_expected_group == handoff_meta_groups - 1);
    handoff_expected_sof = (handoff_expected_x == 0) &&
                           (handoff_expected_y == 0) &&
                           (handoff_expected_group == 0);
    handoff_expected_eol = (handoff_expected_x == handoff_meta_width - 1) &&
                           handoff_expected_group_last;
    handoff_expected_eof = handoff_expected_eol &&
                           (handoff_expected_y == handoff_meta_height - 1);
  end
`endif
  function automatic logic [575:0] adapter_window_expected(
      input logic [1023:0] record);
    logic [575:0] value;
    integer tap;
    begin
      value = record[575:0];
      // The generated engine vectors intentionally carry a self-describing
      // full 3x3 window for 1x1/bypass records.  The real adapter only issues
      // the center tap for those opcodes, so normalize the other taps here.
      if ((stage_meta[record[751:744]][119:112] != 8'd1) &&
          (stage_meta[record[751:744]][119:112] != 8'd3)) begin
        for (tap = 0; tap < 9; tap = tap + 1)
          if (tap != 4)
            value[tap*64 +: 64] = 64'd0;
      end
      adapter_window_expected = value;
    end
  endfunction
  always_comb begin
    if (operand_cursor < RECORDS)
      current_input_record = input_records[operand_cursor];
    else
      current_input_record = 1024'd0;
    if (expected_cursor < EXPECTED)
      current_expected_record = expected_records[expected_cursor];
    else
      current_expected_record = 64'd0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      operand_cursor <= 0;
      expected_cursor <= 0;
      final_count <= 0;
      cycle_count <= 0;
      stage_done_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (adapter_engine_valid && adapter_engine_ready) begin
        if (operand_cursor >= HANDOFF_OPERANDS)
          $fatal(1, "extra adapter operand");
        if (adapter_engine_window_s8 !== adapter_window_expected(current_input_record) ||
            adapter_engine_residual_s8 !== current_input_record[639:576] ||
            adapter_engine_x !== current_input_record[719:704] ||
            adapter_engine_y !== current_input_record[735:720] ||
            adapter_engine_group_index !== current_input_record[738:736] ||
            adapter_active_stage !== current_input_record[751:744])
          $fatal(1, "adapter operand mismatch cursor=%0d stage=%0d x=%0d y=%0d g=%0d",
                 operand_cursor, current_input_record[751:744],
                 adapter_engine_x, adapter_engine_y,
                 adapter_engine_group_index);
        operand_cursor <= operand_cursor + 1;
      end
      if (engine_out_valid && engine_out_ready) begin
        if (expected_cursor >= HANDOFF_RESULTS)
          $fatal(1, "extra engine result");
`ifdef C1_STAGE1_HANDOFF
        if (engine_stage_index !== handoff_expected_stage ||
            engine_out_x !== handoff_expected_x ||
            engine_out_y !== handoff_expected_y ||
            engine_out_group_index !== handoff_expected_group ||
            engine_out_group_last !== handoff_expected_group_last ||
            engine_out_sof !== handoff_expected_sof ||
            engine_out_eol !== handoff_expected_eol ||
            engine_out_eof !== handoff_expected_eof)
          $fatal(1, "stage handoff output index mismatch cursor=%0d stage=%0d",
                 expected_cursor, engine_stage_index);
`endif
        if (engine_out_data_s8 !== current_expected_record)
          $fatal(1, "engine result mismatch cursor=%0d stage=%0d x=%0d y=%0d g=%0d got=%h exp=%h",
                 expected_cursor, engine_stage_index, engine_out_x,
                 engine_out_y, engine_out_group_index,
                 engine_out_data_s8, current_expected_record);
        expected_cursor <= expected_cursor + 1;
      end
      if (engine_overflow_seen)
        $fatal(1, "unexpected engine accumulator overflow");
      if (engine_stage_done)
        stage_done_count <= stage_done_count + 1;
      if (adapter_final_valid && adapter_final_ready) begin
`ifdef C1_STAGE21_FULL
        if (final_count >= HANDOFF_STAGE21_PIXELS ||
            adapter_final_data_s8 !== expected_records[772 + final_count] ||
            adapter_final_x !== (final_count % FRAME_W) ||
            adapter_final_y !== (final_count / FRAME_W) ||
            adapter_final_sof !== (final_count == 0) ||
            adapter_final_eol !== ((final_count % FRAME_W) == FRAME_W - 1) ||
            adapter_final_eof !== (final_count == FRAME_W * FRAME_H - 1))
          $fatal(1, "final RGB stream mismatch n=%0d x=%0d y=%0d got=%h exp=%h",
                 final_count, adapter_final_x, adapter_final_y,
                 adapter_final_data_s8, expected_records[772 + final_count]);
`endif
        final_count <= final_count + 1;
      end
      if (adapter_error)
        $fatal(1, "tensor adapter error code=%02h", adapter_error_code);
      if (engine_error)
        $fatal(1, "engine error code=%02h", engine_error_code);
      if (cycle_count > 1000000)
        $fatal(1, "artifact tensor-engine probe timeout");
    end
  end

  integer i;
  integer adapter_config_i;
  integer engine_config_i;
  integer timeout;
  initial begin
    $readmemh("descriptors.mem", descriptors);
    $readmemh("parameter_arena.mem", parameter_mem);
    $readmemh("engine_vectors.mem", input_records);
    $readmemh("expected_outputs.mem", expected_records);
    $readmemh("stage_meta.mem", stage_meta);

    adapter_start_valid = 1'b0;
`ifndef C1_STAGE1_HANDOFF
    adapter_abort = 1'b0;
`endif
    adapter_stage_config_valid = 1'b0;
    adapter_stage_config_index = 16'd0;
    adapter_stage_config_descriptor = 512'd0;
    adapter_stage_config_generation = 8'd0;
    adapter_source_valid = 1'b0;
    adapter_source_data_s8 = 64'd0;
    adapter_source_x = 16'd0;
    adapter_source_y = 16'd0;
    adapter_source_sof = 1'b0;
    adapter_source_eol = 1'b0;
    adapter_source_eof = 1'b0;
    engine_start_valid = 1'b0;
    engine_stage_config_valid = 1'b0;
    engine_stage_config_index = 16'd0;
    engine_stage_config_descriptor = 512'd0;
    engine_stage_config_generation = 8'd0;
    tensor_base_addr = BASE_ADDR;
`ifdef C1_USE_PARAMETER_BANK
    parameter_load_start = 1'b0;
    parameter_load_valid = 1'b0;
    parameter_load_data = 128'd0;
    parameter_load_last = 1'b0;
    parameter_load_abort = 1'b0;
`endif
    for (i = 0; i < SPARSE_WORDS; i = i + 1) begin
      tensor_bank0[i] = 64'd0;
      tensor_bank1[i] = 64'd0;
      tensor_bank2[i] = 64'd0;
    end

    repeat (8) @(negedge clk);
    rst = 1'b0;
`ifdef C1_USE_PARAMETER_BANK
    load_parameter_bank();
`endif
    fork
      pulse_adapter_start();
      pulse_engine_start();
    join
    fork
      begin
        for (adapter_config_i = 0; adapter_config_i < STAGES;
             adapter_config_i = adapter_config_i + 1)
          send_adapter_config(adapter_config_i);
      end
      begin
        for (engine_config_i = 0; engine_config_i < STAGES;
             engine_config_i = engine_config_i + 1)
          send_engine_config(engine_config_i);
      end
    join

    timeout = 0;
    while (!adapter_config_complete && timeout < 10000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_config_complete)
      $fatal(1, "adapter configuration did not complete");
    timeout = 0;
    while (!engine_config_capture_complete && timeout < 10000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!engine_config_capture_complete)
      $fatal(1, "engine configuration did not complete");

    send_source_frame();
    timeout = 0;
`ifdef C1_STAGE1_HANDOFF
`ifdef C1_STAGE21_FULL
    // The output-RGB stage has no tensor write to use as an abort boundary.
    // Let the final stream retire naturally and check adapter_done/final_count.
    while (!adapter_done && timeout < 1000000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_done)
      $fatal(1, "stage21 final stream did not complete");
    repeat (4) @(posedge clk);
    if (adapter_busy || engine_busy || mem_pending_q)
      $fatal(1, "stage21 full-chain completion did not drain");
    if (final_count != HANDOFF_STAGE21_PIXELS)
      $fatal(1, "stage21 final count mismatch got=%0d exp=%0d",
             final_count, HANDOFF_STAGE21_PIXELS);
`else
    while (!handoff_abort_q && timeout < 1000000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!handoff_abort_q)
      $fatal(1, "stage1 handoff abort was not armed");
    timeout = 0;
    while ((adapter_busy || engine_busy || mem_pending_q) &&
           timeout < 10000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    repeat (4) @(posedge clk);
    if (adapter_busy || engine_busy || mem_pending_q)
      $fatal(1, "stage1 handoff abort did not drain");
`endif
    if (operand_cursor != HANDOFF_OPERANDS)
      $fatal(1, "handoff operand count mismatch got=%0d exp=%0d",
             operand_cursor, HANDOFF_OPERANDS);
    if (expected_cursor != HANDOFF_RESULTS)
      $fatal(1, "handoff result count mismatch got=%0d exp=%0d",
             expected_cursor, HANDOFF_RESULTS);
    if (source_write_count != FRAME_W * FRAME_H ||
        stage0_read_count != 144 || stage0_write_count != 32 ||
        stage1_read_count != HANDOFF_STAGE1_READS ||
        stage1_write_count != HANDOFF_STAGE1_WRITES ||
        stage2_read_count != HANDOFF_STAGE2_READS ||
        stage2_write_count != HANDOFF_STAGE2_WRITES ||
        stage3_read_count != HANDOFF_STAGE3_READS ||
        stage3_write_count != HANDOFF_STAGE3_WRITES ||
        stage4_read_count != HANDOFF_STAGE4_READS ||
        stage4_write_count != HANDOFF_STAGE4_WRITES ||
        stage5_read_count != HANDOFF_STAGE5_READS ||
        stage5_main_read_count != HANDOFF_STAGE5_MAIN_READS ||
        stage5_residual_read_count != HANDOFF_STAGE5_RESIDUAL_READS ||
        stage5_write_count != HANDOFF_STAGE5_WRITES ||
        stage6_read_count != HANDOFF_STAGE6_READS ||
        stage6_write_count != HANDOFF_STAGE6_WRITES ||
        stage7_read_count != HANDOFF_STAGE7_READS ||
        stage7_write_count != HANDOFF_STAGE7_WRITES ||
        stage8_read_count != HANDOFF_STAGE8_READS ||
        stage8_write_count != HANDOFF_STAGE8_WRITES ||
        stage9_read_count != HANDOFF_STAGE9_READS ||
        stage9_main_read_count != HANDOFF_STAGE9_MAIN_READS ||
        stage9_residual_read_count != HANDOFF_STAGE9_RESIDUAL_READS ||
        stage9_write_count != HANDOFF_STAGE9_WRITES ||
        stage10_read_count != HANDOFF_STAGE10_READS ||
        stage10_write_count != HANDOFF_STAGE10_WRITES ||
        stage11_read_count != HANDOFF_STAGE11_READS ||
        stage11_write_count != HANDOFF_STAGE11_WRITES ||
        stage12_read_count != HANDOFF_STAGE12_READS ||
        stage12_write_count != HANDOFF_STAGE12_WRITES ||
        stage13_read_count != HANDOFF_STAGE13_READS ||
        stage13_main_read_count != HANDOFF_STAGE13_MAIN_READS ||
        stage13_residual_read_count != HANDOFF_STAGE13_RESIDUAL_READS ||
        stage13_write_count != HANDOFF_STAGE13_WRITES ||
        stage14_read_count != HANDOFF_STAGE14_READS ||
        stage14_write_count != HANDOFF_STAGE14_WRITES ||
        stage15_read_count != HANDOFF_STAGE15_READS ||
        stage15_write_count != HANDOFF_STAGE15_WRITES ||
        stage16_read_count != HANDOFF_STAGE16_READS ||
        stage16_write_count != HANDOFF_STAGE16_WRITES ||
        stage17_read_count != HANDOFF_STAGE17_READS ||
        stage17_write_count != HANDOFF_STAGE17_WRITES ||
        stage18_read_count != HANDOFF_STAGE18_READS ||
        stage18_write_count != HANDOFF_STAGE18_WRITES ||
        stage19_read_count != HANDOFF_STAGE19_READS ||
        stage19_write_count != HANDOFF_STAGE19_WRITES ||
        stage20_read_count != HANDOFF_STAGE20_READS ||
        stage20_write_count != HANDOFF_STAGE20_WRITES ||
        stage21_read_count != HANDOFF_STAGE21_READS)
      $fatal(1, "handoff memory counts source=%0d s0r=%0d s0w=%0d s1r=%0d s1w=%0d s2r=%0d s2w=%0d s3r=%0d s3w=%0d s4r=%0d s4w=%0d s5r=%0d s5main=%0d s5res=%0d s5w=%0d s6r=%0d s6w=%0d s7r=%0d s7w=%0d s8r=%0d s8w=%0d s9r=%0d s9main=%0d s9res=%0d s9w=%0d s10r=%0d s10w=%0d s11r=%0d s11w=%0d s12r=%0d s12w=%0d s13r=%0d s13main=%0d s13res=%0d s13w=%0d s14r=%0d s14w=%0d s15r=%0d s15w=%0d s16r=%0d s16w=%0d s17r=%0d s17w=%0d s18r=%0d s18w=%0d s19r=%0d s19w=%0d s20r=%0d s20w=%0d s21r=%0d",
             source_write_count, stage0_read_count, stage0_write_count,
             stage1_read_count, stage1_write_count,
             stage2_read_count, stage2_write_count,
             stage3_read_count, stage3_write_count,
             stage4_read_count, stage4_write_count,
             stage5_read_count, stage5_main_read_count,
              stage5_residual_read_count, stage5_write_count,
              stage6_read_count, stage6_write_count,
              stage7_read_count, stage7_write_count,
              stage8_read_count, stage8_write_count,
              stage9_read_count, stage9_main_read_count,
              stage9_residual_read_count, stage9_write_count,
              stage10_read_count, stage10_write_count,
              stage11_read_count, stage11_write_count,
              stage12_read_count, stage12_write_count,
              stage13_read_count, stage13_main_read_count,
              stage13_residual_read_count, stage13_write_count,
              stage14_read_count, stage14_write_count,
              stage15_read_count, stage15_write_count,
              stage16_read_count, stage16_write_count,
              stage17_read_count, stage17_write_count,
              stage18_read_count, stage18_write_count,
              stage19_read_count, stage19_write_count,
              stage20_read_count, stage20_write_count,
              stage21_read_count);
    if (stage_done_count != HANDOFF_STAGE_DONE)
      $fatal(1, "handoff completed-stage count mismatch got=%0d exp=%0d",
             stage_done_count, HANDOFF_STAGE_DONE);
    if ((HANDOFF_LEVEL == 21 && handoff_forced_response_delay != 0) ||
        (HANDOFF_LEVEL != 21 && handoff_forced_response_delay != 3))
      $fatal(1, "handoff response-delay contract mismatch level=%0d delay=%0d",
             HANDOFF_LEVEL, handoff_forced_response_delay);
    if (HANDOFF_LEVEL >= 8) begin
      $display("C1_R1_STAGE%0d_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d final=%0d stage_done=%0d abort=%0d boundary=PRODUCTION_BANK_HANDOFF",
               HANDOFF_LEVEL, operand_cursor, expected_cursor, final_count,
               stage_done_count, (HANDOFF_LEVEL == 21) ? 0 : 1);
      $display("C1_R1_STAGE_HANDOFF_COUNTS s0=%0d/%0d s1=%0d/%0d s2=%0d/%0d s3=%0d/%0d s4=%0d/%0d s5=%0d/%0d s6=%0d/%0d s7=%0d/%0d s8=%0d/%0d s9=%0d/%0d/%0d s10=%0d/%0d s11=%0d/%0d s12=%0d/%0d s13=%0d/%0d/%0d s14=%0d/%0d s15=%0d/%0d s16=%0d/%0d s17=%0d/%0d s18=%0d/%0d s19=%0d/%0d s20=%0d/%0d s21=%0d final=%0d",
               stage0_read_count, stage0_write_count,
               stage1_read_count, stage1_write_count,
               stage2_read_count, stage2_write_count,
               stage3_read_count, stage3_write_count,
               stage4_read_count, stage4_write_count,
               stage5_read_count, stage5_write_count,
               stage6_read_count, stage6_write_count,
               stage7_read_count, stage7_write_count,
               stage8_read_count, stage8_write_count,
               stage9_main_read_count, stage9_residual_read_count,
               stage9_write_count,
               stage10_read_count, stage10_write_count,
               stage11_read_count, stage11_write_count,
               stage12_read_count, stage12_write_count,
               stage13_main_read_count, stage13_residual_read_count,
               stage13_write_count,
               stage14_read_count, stage14_write_count,
               stage15_read_count, stage15_write_count,
               stage16_read_count, stage16_write_count,
               stage17_read_count, stage17_write_count,
               stage18_read_count, stage18_write_count,
               stage19_read_count, stage19_write_count,
               stage20_read_count, stage20_write_count,
               stage21_read_count, final_count);
    end else begin
`ifdef C1_STAGE7_FULL
    $display("C1_R1_STAGE7_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage3_reads=%0d stage3_inputs=24 stage3_pixels=%0d stage3_writes=%0d stage3_outputs=%0d stage4_reads=%0d stage4_inputs=24 stage4_pixels=%0d stage4_writes=%0d stage4_outputs=%0d stage5_reads=%0d stage5_main_reads=%0d stage5_residual_reads=%0d stage5_inputs=12 stage5_pixels=%0d stage5_writes=%0d stage5_outputs=%0d stage6_reads=%0d stage6_inputs=12 stage6_pixels=%0d stage6_writes=%0d stage6_outputs=%0d stage7_reads=%0d stage7_inputs=24 stage7_pixels=%0d stage7_writes=%0d stage7_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_STAGE5_STAGE6_COMPLETE_PLUS_STAGE7_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage3_read_count, HANDOFF_STAGE3_PIXELS,
             stage3_write_count, HANDOFF_STAGE3_WRITES, stage4_read_count,
             HANDOFF_STAGE4_PIXELS, stage4_write_count, HANDOFF_STAGE4_WRITES,
             stage5_read_count, stage5_main_read_count,
             stage5_residual_read_count, HANDOFF_STAGE5_PIXELS,
             stage5_write_count, HANDOFF_STAGE5_WRITES, stage6_read_count,
             HANDOFF_STAGE6_PIXELS, stage6_write_count, HANDOFF_STAGE6_WRITES,
             stage7_read_count, HANDOFF_STAGE7_PIXELS, stage7_write_count,
             HANDOFF_STAGE7_WRITES, stage_done_count, handoff_forced_response_delay,
             expected_records[140], expected_records[163]);
`elsif C1_STAGE6_FULL
    $display("C1_R1_STAGE6_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage3_reads=%0d stage3_inputs=24 stage3_pixels=%0d stage3_writes=%0d stage3_outputs=%0d stage4_reads=%0d stage4_inputs=24 stage4_pixels=%0d stage4_writes=%0d stage4_outputs=%0d stage5_reads=%0d stage5_main_reads=%0d stage5_residual_reads=%0d stage5_inputs=12 stage5_pixels=%0d stage5_writes=%0d stage5_outputs=%0d stage6_reads=%0d stage6_inputs=12 stage6_pixels=%0d stage6_writes=%0d stage6_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_STAGE5_COMPLETE_PLUS_STAGE6_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage3_read_count, HANDOFF_STAGE3_PIXELS,
             stage3_write_count, HANDOFF_STAGE3_WRITES, stage4_read_count,
             HANDOFF_STAGE4_PIXELS, stage4_write_count, HANDOFF_STAGE4_WRITES,
             stage5_read_count, stage5_main_read_count,
             stage5_residual_read_count, HANDOFF_STAGE5_PIXELS,
             stage5_write_count, HANDOFF_STAGE5_WRITES, stage6_read_count,
             HANDOFF_STAGE6_PIXELS, stage6_write_count, HANDOFF_STAGE6_WRITES,
             stage_done_count, handoff_forced_response_delay,
             expected_records[116], expected_records[139]);
`elsif C1_STAGE5_FULL
    $display("C1_R1_STAGE5_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage3_reads=%0d stage3_inputs=24 stage3_pixels=%0d stage3_writes=%0d stage3_outputs=%0d stage4_reads=%0d stage4_inputs=24 stage4_pixels=%0d stage4_writes=%0d stage4_outputs=%0d stage5_reads=%0d stage5_main_reads=%0d stage5_residual_reads=%0d stage5_inputs=12 stage5_pixels=%0d stage5_writes=%0d stage5_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_COMPLETE_PLUS_STAGE5_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage3_read_count, HANDOFF_STAGE3_PIXELS,
             stage3_write_count, HANDOFF_STAGE3_WRITES, stage4_read_count,
             HANDOFF_STAGE4_PIXELS, stage4_write_count, HANDOFF_STAGE4_WRITES,
             stage5_read_count, stage5_main_read_count,
             stage5_residual_read_count, HANDOFF_STAGE5_PIXELS,
             stage5_write_count, HANDOFF_STAGE5_WRITES, stage_done_count,
             handoff_forced_response_delay, expected_records[104],
             expected_records[115]);
`elsif C1_STAGE4_FULL
    $display("C1_R1_STAGE4_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage3_reads=%0d stage3_inputs=24 stage3_pixels=%0d stage3_writes=%0d stage3_outputs=%0d stage4_reads=%0d stage4_inputs=24 stage4_pixels=%0d stage4_writes=%0d stage4_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_COMPLETE_PLUS_STAGE4_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage3_read_count, HANDOFF_STAGE3_PIXELS,
             stage3_write_count, HANDOFF_STAGE3_WRITES, stage4_read_count,
             HANDOFF_STAGE4_PIXELS, stage4_write_count, HANDOFF_STAGE4_WRITES,
             stage_done_count, handoff_forced_response_delay,
             expected_records[92], expected_records[103]);
 `elsif C1_STAGE3_FULL
    $display("C1_R1_STAGE3_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage3_reads=%0d stage3_inputs=24 stage3_pixels=%0d stage3_writes=%0d stage3_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_STAGE2_COMPLETE_PLUS_STAGE3_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage3_read_count, HANDOFF_STAGE3_PIXELS,
             stage3_write_count, HANDOFF_STAGE3_WRITES, stage_done_count,
             handoff_forced_response_delay,
             expected_records[68], expected_records[91]);
`elsif C1_STAGE2_FULL
    $display("C1_R1_STAGE2_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage2_reads=%0d stage2_inputs=12 stage2_pixels=%0d stage2_writes=%0d stage2_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_STAGE1_COMPLETE_PLUS_STAGE2_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage2_read_count, HANDOFF_STAGE2_PIXELS, stage2_write_count,
             HANDOFF_STAGE2_WRITES, stage_done_count,
             handoff_forced_response_delay,
             expected_records[44], expected_records[67]);
`elsif C1_STAGE1_FULL
    $display("C1_R1_STAGE1_FULL_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=8 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d first_group=%016h last_group=%016h boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FULL_2X2_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage_done_count, handoff_forced_response_delay,
             expected_records[32], expected_records[43]);
`else
    $display("C1_R1_STAGE1_HANDOFF_8X8_PASS frame=8x8 stages=22 operands=%0d results=%0d source_writes=%0d stage0_reads=%0d stage0_writes=%0d stage1_reads=%0d stage1_inputs=2 stage1_pixels=%0d stage1_writes=%0d stage1_outputs=%0d stage_done=%0d abort=1 abort_response_delay=%0d group0=%016h group1=%016h group2=%016h boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FIRST_PIXEL_BANK_HANDOFF",
             operand_cursor, expected_cursor, source_write_count,
             stage0_read_count, stage0_write_count, stage1_read_count,
             HANDOFF_STAGE1_PIXELS, stage1_write_count, HANDOFF_STAGE1_WRITES,
             stage_done_count,
             handoff_forced_response_delay,
             expected_records[32], expected_records[33], expected_records[34]);
`endif
    end
`else
    while (!adapter_done && timeout < 1000000) begin
      @(posedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_done)
      $fatal(1, "adapter did not complete trained-artifact frame");
    repeat (4) @(posedge clk);
    if (operand_cursor != RECORDS)
      $fatal(1, "operand count mismatch got=%0d exp=%0d",
             operand_cursor, RECORDS);
    if (expected_cursor != EXPECTED)
      $fatal(1, "result count mismatch got=%0d exp=%0d",
             expected_cursor, EXPECTED);
    if (final_count != FRAME_W * FRAME_H)
      $fatal(1, "final count mismatch got=%0d exp=%0d",
             final_count, FRAME_W * FRAME_H);
    $display("C1_R1_MICROSTYLE_ARTIFACT_TENSOR_ENGINE_8X8_PASS stages=%0d operands=%0d results=%0d final=%0d cycles=%0d stage_done=%0d",
             STAGES, operand_cursor, expected_cursor, final_count,
             cycle_count, stage_done_count);
`endif
    $finish;
  end
endmodule
