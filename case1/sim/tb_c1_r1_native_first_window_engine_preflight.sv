`timescale 1ns/1ps

// Bounded native first-window arithmetic preflight.
//
// This test is intentionally smaller than a native full-frame CNN run while
// crossing the next real integration boundary: the production 640x480
// tensor adapter is connected to the production trained-artifact CNN top.
// The adapter still ingests a complete source frame, but the test aborts
// immediately after a small number of output groups of stage zero, so no
// unbounded 22-stage/native waveform is produced.  C1_NATIVE_WINDOW_PIXELS
// supports the bounded first-row gate sizes 1, 2, 4, 8 and 16; the default is
// one pixel and remains compatible with the original preflight.
module tb_c1_r1_native_first_window_engine_preflight;
`ifdef C1_PIPELINED_TENSOR_ADDRESS
  localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 1;
`else
  localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 0;
`endif
`ifdef C1_PIPELINED_TENSOR_PIXEL_INDEX
  localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 1;
`else
  localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 0;
`endif
`ifdef C1_NATIVE_WINDOW_PIXELS_16
  localparam integer WINDOW_PIXELS = 16;
`elsif C1_NATIVE_WINDOW_PIXELS_8
  localparam integer WINDOW_PIXELS = 8;
`elsif C1_NATIVE_WINDOW_PIXELS_4
  localparam integer WINDOW_PIXELS = 4;
`elsif C1_NATIVE_WINDOW_PIXELS_2
  localparam integer WINDOW_PIXELS = 2;
`elsif C1_NATIVE_WINDOW_PIXELS_1
  localparam integer WINDOW_PIXELS = 1;
`elsif C1_NATIVE_WINDOW_PIXELS
  localparam integer WINDOW_PIXELS = `C1_NATIVE_WINDOW_PIXELS;
`else
  // Keep the original one-pixel gate as the default regression boundary.
  localparam integer WINDOW_PIXELS = 1;
`endif

  localparam integer STAGES      = 22;
  localparam integer FRAME_W     = 640;
  localparam integer FRAME_H     = 480;
  localparam integer PIXELS      = FRAME_W * FRAME_H;
  localparam integer PARAM_BYTES = 16896;
  localparam integer PARAM_WORDS = PARAM_BYTES / 16;
  localparam integer BANK_BYTES  = 8 * 1024 * 1024;
  localparam integer SPARSE_WORDS = 4096;
  localparam logic [31:0] BASE_ADDR = 32'h0010_0000;

  // Expected signed-INT8 stage-zero output for the deterministic source
  // pattern below.  These values are generated from the same native arena
  // with model/microstyle_quant._integer_conv (3x3, stride 2, edge padding).
  // The first sixteen output pixels are retained so the optional finite
  // window gate can check repeated address/window/weight reuse across several
  // source-address/cache-line boundaries without a long frame.
  localparam logic [63:0] EXPECTED_GROUP0 = 64'h0e09_0000_0032_0005;
  localparam logic [63:0] EXPECTED_GROUP1 = 64'h0000_0000_0019_0006;
  localparam integer STAGE0_OUTPUT_GROUPS = 2;
  localparam integer WINDOW_OUTPUT_WRITES = WINDOW_PIXELS * STAGE0_OUTPUT_GROUPS;

  function automatic logic [63:0] expected_group0_fn(input integer pixel_index);
    begin
      case (pixel_index)
        0: expected_group0_fn = EXPECTED_GROUP0;
        1: expected_group0_fn = 64'h1900_0000_003a_000f;
        2: expected_group0_fn = 64'h2500_0007_0041_001b;
        3: expected_group0_fn = 64'h3600_0028_003f_0015;
        4: expected_group0_fn = 64'h0300_0118_0000_0011;
        5: expected_group0_fn = 64'h1100_6017_0000_2103;
        6: expected_group0_fn = 64'h0000_000a_0500_0000;
        7: expected_group0_fn = 64'h0811_0000_2f20_0f00;
        8: expected_group0_fn = 64'h1206_0000_0036_0009;
        9: expected_group0_fn = 64'h1f00_0000_003d_0015;
        10: expected_group0_fn = 64'h2b00_000c_0044_0021;
        11: expected_group0_fn = 64'h2000_002f_0032_001c;
        12: expected_group0_fn = 64'h1900_2d0f_0000_001e;
        13: expected_group0_fn = 64'h0000_1e0c_0000_0a00;
        14: expected_group0_fn = 64'h0213_000c_1700_0000;
        15: expected_group0_fn = 64'h1603_0003_1f14_001c;
        default: expected_group0_fn = 64'd0;
      endcase
    end
  endfunction

  function automatic logic [63:0] expected_group1_fn(input integer pixel_index);
    begin
      case (pixel_index)
        0: expected_group1_fn = EXPECTED_GROUP1;
        1: expected_group1_fn = 64'h0000_0000_0011_0000;
        2: expected_group1_fn = 64'h0000_0000_0107_0200;
        3: expected_group1_fn = 64'h0000_0000_1a00_1a00;
        4: expected_group1_fn = 64'h0000_0000_1400_2600;
        5: expected_group1_fn = 64'h0000_0000_1700_0000;
        6: expected_group1_fn = 64'h0000_0000_2400_0000;
        7: expected_group1_fn = 64'h0000_0000_0011_2a10;
        8: expected_group1_fn = 64'h0000_0000_0017_0001;
        9: expected_group1_fn = 64'h0000_0000_000c_0000;
        10: expected_group1_fn = 64'h0000_0000_0602_0800;
        11: expected_group1_fn = 64'h0000_0000_3001_1200;
        12: expected_group1_fn = 64'h0000_0000_0b00_3900;
        13: expected_group1_fn = 64'h0000_0000_2400_0000;
        14: expected_group1_fn = 64'h0000_0000_0100_2a0b;
        15: expected_group1_fn = 64'h0000_0000_0015_0008;
        default: expected_group1_fn = 64'd0;
      endcase
    end
  endfunction

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic [511:0] descriptors [0:STAGES-1];
  logic [127:0] parameter_mem [0:PARAM_WORDS-1];

  // Adapter signals.
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
  logic [1:0] adapter_input_bank, adapter_output_bank;
  logic [1:0] adapter_residual_bank;

  // Production dispatcher-compatible CNN top signals.
  logic engine_start_valid, engine_start_ready;
  logic [15:0] engine_stage_count = STAGES;
  logic [7:0] engine_config_generation = 8'h51;
  logic engine_parameter_active_valid;
  logic [31:0] engine_parameter_generation;
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

  assign engine_in_valid             = adapter_engine_valid;
  assign adapter_engine_ready       = engine_in_ready;
  assign engine_in_window_s8        = adapter_engine_window_s8;
  assign engine_in_residual_s8      = adapter_engine_residual_s8;
  assign engine_in_group_index      = adapter_engine_group_index;
  assign engine_in_group_last       = adapter_engine_group_last;
  assign engine_in_x                = adapter_engine_x;
  assign engine_in_y                = adapter_engine_y;
  assign engine_in_sof              = adapter_engine_sof;
  assign engine_in_eol              = adapter_engine_eol;
  assign engine_in_eof              = adapter_engine_eof;
  assign adapter_result_valid       = engine_out_valid;
  assign engine_out_ready           = adapter_result_ready;
  assign adapter_result_data_s8     = engine_out_data_s8;
  assign adapter_result_group_index = engine_out_group_index;
  assign adapter_result_group_last  = engine_out_group_last;
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
    .ENABLE_WINDOW_CACHE_SIDEBAND(0),
    .PIPELINED_TENSOR_ADDRESS(PIPELINED_TENSOR_ADDRESS_CFG),
    .PIPELINED_TENSOR_PIXEL_INDEX(PIPELINED_TENSOR_PIXEL_INDEX_CFG)
  ) u_adapter (
    .clk, .rst, .adapter_start_valid, .adapter_start_ready, .adapter_abort,
    .adapter_stage_config_valid, .adapter_stage_config_ready,
    .adapter_stage_config_index, .adapter_stage_config_descriptor,
    .adapter_stage_config_generation, .adapter_error, .adapter_error_code,
    .adapter_source_valid, .adapter_source_ready,
    .adapter_source_data_s8, .adapter_source_x, .adapter_source_y,
    .adapter_source_sof, .adapter_source_eol, .adapter_source_eof,
    .adapter_engine_valid, .adapter_engine_ready,
    .adapter_engine_window_s8, .adapter_engine_residual_s8,
    .adapter_engine_group_index, .adapter_engine_group_last,
    .adapter_engine_x, .adapter_engine_y, .adapter_engine_sof,
    .adapter_engine_eol, .adapter_engine_eof,
    .adapter_result_valid, .adapter_result_ready,
    .adapter_result_data_s8, .adapter_result_group_index,
    .adapter_result_group_last, .adapter_result_x, .adapter_result_y,
    .adapter_result_sof, .adapter_result_eol, .adapter_result_eof,
    .adapter_final_valid, .adapter_final_ready, .adapter_final_data_s8,
    .adapter_final_x, .adapter_final_y, .adapter_final_sof,
    .adapter_final_eol, .adapter_final_eof, .tensor_base_addr,
    .cache_stage_start_valid, .cache_stage_start_ready, .cache_stage_enable,
    .cache_stage_base_addr, .cache_stage_width, .cache_stage_height,
    .cache_stage_groups, .mem_req_valid, .mem_req_ready, .mem_req_write,
    .mem_req_addr, .mem_req_wdata, .mem_req_wstrb, .mem_req_cacheable,
    .mem_req_cache_x, .mem_req_cache_y, .mem_req_cache_group,
    .mem_rsp_valid, .mem_rsp_ready, .mem_rsp_error, .mem_rsp_rdata,
    .adapter_busy, .adapter_done, .adapter_aborted,
    .adapter_config_complete, .active_stage_index(adapter_active_stage),
    .active_stage_opcode(adapter_active_opcode),
    .active_input_bank(adapter_input_bank),
    .active_output_bank(adapter_output_bank),
    .active_residual_bank(adapter_residual_bank)
  );

  c1_r1_microstyle_cnn_top #(
    .REQUIRED_STAGES(STAGES),
    .PARAM_ADDR_W(11),
    .PARAM_ARENA_BYTES(PARAM_BYTES),
    .MAX_CHANNELS(48),
    .MAX_WEIGHT_BYTES(2592)
  ) u_engine (
    .clk, .rst, .abort(adapter_abort),
    .start_valid(engine_start_valid), .start_ready(engine_start_ready),
    .stage_count(engine_stage_count),
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
    .in_window_s8(engine_in_window_s8),
    .in_residual_s8(engine_in_residual_s8),
    .in_group_index(engine_in_group_index),
    .in_group_last(engine_in_group_last),
    .in_x(engine_in_x), .in_y(engine_in_y), .in_sof(engine_in_sof),
    .in_eol(engine_in_eol), .in_eof(engine_in_eof),
    .out_valid(engine_out_valid), .out_ready(engine_out_ready),
    .out_data_s8(engine_out_data_s8),
    .out_group_index(engine_out_group_index),
    .out_group_last(engine_out_group_last),
    .out_x(engine_out_x), .out_y(engine_out_y),
    .out_sof(engine_out_sof), .out_eol(engine_out_eol),
    .out_eof(engine_out_eof), .stage_index(engine_stage_index),
    .stage_opcode(engine_stage_opcode), .stage_active(engine_stage_active),
    .adapter_required(engine_adapter_required),
    .stage_done(engine_stage_done), .overflow_seen(engine_overflow_seen),
    .config_capture_complete(engine_config_capture_complete)
  );

  // By default the TB can use a one-cycle direct arena model.  Defining
  // C1_USE_PARAMETER_BANK replaces it with the production atomic dual-bank
  // parameter RAM and an explicit 1,056-word load transaction.
`ifdef C1_USE_PARAMETER_BANK
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
`else
  // The production parameter scheduler promises one outstanding read.  This
  // compact registered BFM returns one 128-bit arena word on the next cycle.
  logic parameter_pending_q;
  integer parameter_pending_addr_q;
  assign engine_parameter_active_valid = 1'b1;
  assign engine_parameter_generation = 32'h2026_0828;
  always_ff @(posedge clk) begin
    if (rst) begin
      parameter_pending_q <= 1'b0;
      parameter_pending_addr_q <= 0;
      param_rd_valid <= 1'b0;
      param_rd_error <= 1'b0;
      param_rd_data <= 128'd0;
    end else begin
      param_rd_valid <= 1'b0;
      param_rd_error <= 1'b0;
      if (param_rd_en) begin
        if (parameter_pending_q)
          $fatal(1, "native engine issued two parameter reads");
        parameter_pending_q <= 1'b1;
        parameter_pending_addr_q <= param_rd_addr;
      end
      if (parameter_pending_q) begin
        if (parameter_pending_addr_q < 0 ||
            parameter_pending_addr_q >= PARAM_WORDS)
          $fatal(1, "native parameter address out of range=%0d",
                 parameter_pending_addr_q);
        param_rd_data <= parameter_mem[parameter_pending_addr_q];
        param_rd_valid <= 1'b1;
        parameter_pending_q <= 1'b0;
      end
    end
  end
`endif

  // Dense source storage is only 307,200 64-bit words.  Output banks stay
  // sparse because the test retires exactly two words before abort.
  logic [63:0] source_mem [0:PIXELS-1];
  logic [63:0] sparse_bank1 [0:SPARSE_WORDS-1];
  logic [63:0] sparse_bank2 [0:SPARSE_WORDS-1];
  logic pending_q;
  logic [63:0] pending_data_q;
  logic abort_q;
  integer cycle_count;
  integer request_count;
  integer source_write_count;
  integer window_read_count;
  integer output_write_count;
  integer engine_input_count;
  integer engine_output_count;
  integer bank_index;
  integer local_word;
  integer i;
  integer tap_i;
  integer lane_i;

  assign adapter_abort = abort_q;
  assign mem_req_ready = !pending_q && ((cycle_count % 11) != 5);
  assign mem_rsp_valid = pending_q;
  assign mem_rsp_error = 1'b0;
  assign mem_rsp_rdata = pending_data_q;

  function automatic logic [63:0] source_pixel_fn(input integer x,
                                                    input integer y);
    logic [63:0] value;
    integer unsigned_code;
    integer signed_code;
    begin
      value = 64'd0;
      for (lane_i = 0; lane_i < 3; lane_i = lane_i + 1) begin
        unsigned_code = (17 * x + 31 * y + 53 * lane_i + 11) & 255;
        signed_code = unsigned_code - 128;
        value[lane_i*8 +: 8] = signed_code & 255;
      end
      source_pixel_fn = value;
    end
  endfunction

  function automatic logic [7:0] source_lane_fn(input integer x,
                                                  input integer y,
                                                  input integer lane);
    integer unsigned_code;
    begin
      unsigned_code = (17 * x + 31 * y + 53 * lane + 11) & 255;
      source_lane_fn = (unsigned_code - 128) & 255;
    end
  endfunction

  function automatic logic [31:0] expected_window_tap_addr(
      input integer read_index);
    integer pixel_index, tap_index, tx, ty;
    begin
      pixel_index = read_index / 9;
      tap_index = read_index % 9;
      // Stage zero is stride two.  Edge padding is implemented by clamping
      // the source coordinate to the nearest valid frame pixel.
      tx = (pixel_index * 2) + (tap_index % 3) - 1;
      ty = (tap_index / 3) - 1;
      if (tx < 0) tx = 0;
      else if (tx >= FRAME_W) tx = FRAME_W - 1;
      if (ty < 0) ty = 0;
      else if (ty >= FRAME_H) ty = FRAME_H - 1;
      expected_window_tap_addr =
          BASE_ADDR + ((ty * FRAME_W + tx) * 8);
    end
  endfunction

  function automatic logic [7:0] expected_window_lane(
      input integer pixel_index, input integer tap_index, input integer lane);
    integer tx, ty;
    begin
      tx = (pixel_index * 2) + (tap_index % 3) - 1;
      ty = (tap_index / 3) - 1;
      if (tx < 0) tx = 0;
      else if (tx >= FRAME_W) tx = FRAME_W - 1;
      if (ty < 0) ty = 0;
      else if (ty >= FRAME_H) ty = FRAME_H - 1;
      expected_window_lane = source_lane_fn(tx, ty, lane);
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      pending_q <= 1'b0;
      pending_data_q <= 64'd0;
      abort_q <= 1'b0;
      cycle_count <= 0;
      request_count <= 0;
      source_write_count <= 0;
      window_read_count <= 0;
      output_write_count <= 0;
      engine_input_count <= 0;
      engine_output_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (abort_q)
        abort_q <= 1'b0;

      if (mem_req_valid && mem_req_ready) begin
        if (pending_q)
          $fatal(1, "native engine BFM accepted two tensor requests");
        if (mem_req_addr[2:0] != 0 || mem_req_addr < BASE_ADDR ||
            mem_req_addr >= BASE_ADDR + 3*BANK_BYTES)
          $fatal(1, "native engine tensor address out of range=%08h",
                 mem_req_addr);
        bank_index = (mem_req_addr - BASE_ADDR) / BANK_BYTES;
        local_word = ((mem_req_addr - BASE_ADDR) % BANK_BYTES) >> 3;
        if (local_word < 0 || local_word >= BANK_BYTES/8)
          $fatal(1, "native engine local word out of range=%0d", local_word);
        request_count <= request_count + 1;
        pending_q <= 1'b1;
        if (mem_req_write) begin
          if (mem_req_wstrb != 8'hff)
            $fatal(1, "native engine tensor write was partial");
          case (bank_index)
            0: begin
              if (local_word >= PIXELS)
                $fatal(1, "native source write escaped RGB tensor");
              source_mem[local_word] <= mem_req_wdata;
              source_write_count <= source_write_count + 1;
              if (local_word != source_write_count)
                $fatal(1, "native source address sequence word=%0d expected=%0d",
                       local_word, source_write_count);
            end
            1: begin
              if (local_word >= SPARSE_WORDS)
                $fatal(1, "native engine output escaped sparse bank");
              sparse_bank1[local_word] <= mem_req_wdata;
              if (local_word != output_write_count)
                $fatal(1, "native output address word=%0d expected=%0d",
                       local_word, output_write_count);
              if (mem_req_wdata !==
                  (((output_write_count % STAGE0_OUTPUT_GROUPS) == 0) ?
                   expected_group0_fn(output_write_count /
                                      STAGE0_OUTPUT_GROUPS) :
                   expected_group1_fn(output_write_count /
                                      STAGE0_OUTPUT_GROUPS)))
                $fatal(1, "native stage-zero output mismatch word=%0d got=%h",
                       output_write_count, mem_req_wdata);
              output_write_count <= output_write_count + 1;
              if (output_write_count >= WINDOW_OUTPUT_WRITES - 1)
                abort_q <= 1'b1;
            end
            2: begin
              if (local_word >= SPARSE_WORDS)
                $fatal(1, "unexpected native bank-2 output");
              sparse_bank2[local_word] <= mem_req_wdata;
            end
            default: $fatal(1, "invalid native tensor bank");
          endcase
          pending_data_q <= 64'd0;
        end else begin
          if (mem_req_wstrb != 0)
            $fatal(1, "native engine tensor read carried WSTRB");
          case (bank_index)
            0: begin
              if (adapter_active_stage == 0 && adapter_active_opcode == 8'd1 &&
                  mem_req_cacheable) begin
                if (window_read_count >= WINDOW_PIXELS * 9)
                  $fatal(1, "extra native first-window read index=%0d",
                         window_read_count);
                if (mem_req_addr !== expected_window_tap_addr(window_read_count))
                  $fatal(1, "native first-window address index=%0d got=%08h exp=%08h",
                         window_read_count, mem_req_addr,
                         expected_window_tap_addr(window_read_count));
                window_read_count <= window_read_count + 1;
              end
              if (local_word >= PIXELS)
                $fatal(1, "native source read escaped written frame");
              pending_data_q <= source_mem[local_word];
            end
            1: pending_data_q <=
                (local_word < SPARSE_WORDS) ? sparse_bank1[local_word] : 64'd0;
            2: pending_data_q <=
                (local_word < SPARSE_WORDS) ? sparse_bank2[local_word] : 64'd0;
            default: pending_data_q <= 64'd0;
          endcase
        end
      end
      if (mem_rsp_valid && mem_rsp_ready)
        pending_q <= 1'b0;

      if (adapter_engine_valid && adapter_engine_ready) begin
        engine_input_count <= engine_input_count + 1;
        if (engine_input_count >= WINDOW_PIXELS ||
            window_read_count != (engine_input_count + 1) * 9 ||
            adapter_engine_group_index != 0 || !adapter_engine_group_last ||
            adapter_engine_x != engine_input_count || adapter_engine_y != 0 ||
            adapter_engine_sof != (engine_input_count == 0) ||
            adapter_engine_eol || adapter_engine_eof ||
            adapter_engine_residual_s8 != 0)
          $fatal(1, "native engine input metadata mismatch");
        for (tap_i = 0; tap_i < 9; tap_i = tap_i + 1)
          for (lane_i = 0; lane_i < 3; lane_i = lane_i + 1)
            if (adapter_engine_window_s8[tap_i*64 + lane_i*8 +: 8] !==
                expected_window_lane(engine_input_count, tap_i, lane_i))
              $fatal(1, "native engine input window mismatch pixel=%0d tap=%0d lane=%0d",
                     engine_input_count, tap_i, lane_i);
      end

      if (engine_out_valid && engine_out_ready) begin
        engine_output_count <= engine_output_count + 1;
        if (engine_output_count >= WINDOW_OUTPUT_WRITES ||
            engine_out_x != (engine_output_count / STAGE0_OUTPUT_GROUPS) ||
            engine_out_y != 0 || engine_out_eol || engine_out_eof ||
            engine_out_group_index !=
              (engine_output_count % STAGE0_OUTPUT_GROUPS) ||
            engine_out_group_last !=
              ((engine_output_count % STAGE0_OUTPUT_GROUPS) ==
               STAGE0_OUTPUT_GROUPS - 1) ||
            engine_out_sof != (engine_output_count == 0) ||
            engine_out_data_s8 !==
              (((engine_output_count % STAGE0_OUTPUT_GROUPS) == 0) ?
               expected_group0_fn(engine_output_count /
                                  STAGE0_OUTPUT_GROUPS) :
               expected_group1_fn(engine_output_count /
                                  STAGE0_OUTPUT_GROUPS)))
          $fatal(1, "native stage-zero engine output protocol/data mismatch n=%0d got=%h",
                 engine_output_count, engine_out_data_s8);
      end
      if (adapter_error)
        $fatal(1, "native engine adapter error=%02h", adapter_error_code);
      if (engine_error)
        $fatal(1, "native engine error=%02h", engine_error_code);
      if (engine_overflow_seen)
        $fatal(1, "native engine accumulator overflow");
      if (cycle_count > 8_000_000)
        $fatal(1, "native first-window engine preflight timeout");
    end
  end

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

  task automatic send_source(input integer x, input integer y);
    begin
      @(negedge clk);
      adapter_source_data_s8 = source_pixel_fn(x, y);
      adapter_source_x = x[15:0];
      adapter_source_y = y[15:0];
      adapter_source_sof = (x == 0 && y == 0);
      adapter_source_eol = (x == FRAME_W-1);
      adapter_source_eof = (x == FRAME_W-1 && y == FRAME_H-1);
      adapter_source_valid = 1'b1;
      while (!adapter_source_ready) @(negedge clk);
      @(negedge clk);
      adapter_source_valid = 1'b0;
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
        $fatal(1, "native parameter bank load failed done=%0d error=%0d gen=%0d",
               parameter_load_done, parameter_load_error,
               parameter_bank_generation);
    end
  endtask
`endif

  integer x, y, cfg_i, adapter_cfg_i, engine_cfg_i, timeout;
  initial begin
    if ((WINDOW_PIXELS != 1) && (WINDOW_PIXELS != 2) &&
        (WINDOW_PIXELS != 4) && (WINDOW_PIXELS != 8) &&
        (WINDOW_PIXELS != 16))
      $fatal(1, "C1_NATIVE_WINDOW_PIXELS must be one of {1,2,4,8,16}, got %0d",
             WINDOW_PIXELS);
    $readmemh("descriptors.mem", descriptors);
    $readmemh("parameter_arena.mem", parameter_mem);
    adapter_start_valid = 1'b0;
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
    for (i = 0; i < PIXELS; i = i + 1)
      source_mem[i] = 64'd0;
    for (i = 0; i < SPARSE_WORDS; i = i + 1) begin
      sparse_bank1[i] = 64'd0;
      sparse_bank2[i] = 64'd0;
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
        for (adapter_cfg_i = 0; adapter_cfg_i < STAGES;
             adapter_cfg_i = adapter_cfg_i + 1)
          send_adapter_config(adapter_cfg_i);
      end
      begin
        for (engine_cfg_i = 0; engine_cfg_i < STAGES;
             engine_cfg_i = engine_cfg_i + 1)
          send_engine_config(engine_cfg_i);
      end
    join

    timeout = 0;
    while (!adapter_config_complete && timeout < 10000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_config_complete)
      $fatal(1, "native engine adapter configuration incomplete");
    timeout = 0;
    while (!engine_config_capture_complete && timeout < 10000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (!engine_config_capture_complete)
      $fatal(1, "native engine configuration capture incomplete");

    for (y = 0; y < FRAME_H; y = y + 1)
      for (x = 0; x < FRAME_W; x = x + 1)
        send_source(x, y);

    timeout = 0;
    while (!adapter_aborted && timeout < 8_000_000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_aborted)
      $fatal(1, "native engine abort did not complete");
    repeat (6) @(posedge clk);
    if (adapter_error || adapter_busy || adapter_done || pending_q ||
        engine_error || engine_busy || engine_done)
      $fatal(1, "native engine abort did not return both blocks idle");
    if (source_write_count != PIXELS ||
        window_read_count != WINDOW_PIXELS * 9 ||
        engine_input_count != WINDOW_PIXELS ||
        engine_output_count != WINDOW_OUTPUT_WRITES ||
        output_write_count != WINDOW_OUTPUT_WRITES)
      $fatal(1, "native engine coverage mismatch source=%0d reads=%0d in=%0d out=%0d writes=%0d",
             source_write_count, window_read_count, engine_input_count,
             engine_output_count, output_write_count);
    $display("C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=%0d pixel_pipeline=%0d window_pixels=%0d source_writes=%0d first_window_reads=%0d engine_inputs=%0d engine_outputs=%0d output_writes=%0d abort=1 group0=%016h group1=%016h boundary=NATIVE_SOURCE_INGEST_PLUS_REAL_STAGE0_ARITHMETIC_ONLY",
             PIPELINED_TENSOR_ADDRESS_CFG, PIPELINED_TENSOR_PIXEL_INDEX_CFG,
             WINDOW_PIXELS, source_write_count, window_read_count, engine_input_count,
             engine_output_count, output_write_count, EXPECTED_GROUP0,
             EXPECTED_GROUP1);
    $finish;
  end

  initial begin
    #100_000_000;
    $fatal(1, "native first-window engine global timeout");
  end
endmodule
