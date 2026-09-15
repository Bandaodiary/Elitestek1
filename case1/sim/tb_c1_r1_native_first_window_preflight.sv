`timescale 1ns/1ps

// Bounded native tensor data-plane preflight.
//
// The production adapter is configured with the real 640x480/22-stage
// descriptors.  A complete source frame is written through its normal
// 64-bit memory seam, then only the first stage's first output pixel is
// consumed by a tiny synthetic engine.  The test checks the nine SAME-
// REPLICATE addresses/data words and both output-group writes, and asserts a
// protocol-safe abort immediately after the first output write.  It therefore
// exercises native geometry/addressing without running the remaining 21 stages
// or producing a large waveform/database.
module tb_c1_r1_native_first_window_preflight;
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
  localparam integer STAGES = 22;
  localparam integer FRAME_W = 640;
  localparam integer FRAME_H = 480;
  localparam integer PIXELS = FRAME_W * FRAME_H;
  localparam integer BANK_BYTES = 8 * 1024 * 1024;
  localparam logic [31:0] BASE_ADDR = 32'h0010_0000;
  localparam integer MAX_SPARSE_WORDS = 4096;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic [511:0] descriptors [0:STAGES-1];

  logic adapter_start_valid, adapter_start_ready;
  logic adapter_abort;
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
  logic [4:0] active_stage_index;
  logic [7:0] active_stage_opcode;
  logic [1:0] active_input_bank, active_output_bank, active_residual_bank;

  c1_r1_microstyle_tensor_adapter #(
    .REQUIRED_STAGES(STAGES),
    .TENSOR_BANK_BYTES(BANK_BYTES),
    .STRICT_DESCRIPTOR_VALIDATION(1),
    .ENABLE_WINDOW_CACHE_SIDEBAND(0),
    .PIPELINED_TENSOR_ADDRESS(PIPELINED_TENSOR_ADDRESS_CFG),
    .PIPELINED_TENSOR_PIXEL_INDEX(PIPELINED_TENSOR_PIXEL_INDEX_CFG)
  ) dut (
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
    .adapter_result_valid, .adapter_result_ready, .adapter_result_data_s8,
    .adapter_result_group_index, .adapter_result_group_last,
    .adapter_result_x, .adapter_result_y, .adapter_result_sof,
    .adapter_result_eol, .adapter_result_eof,
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
    .adapter_config_complete, .active_stage_index, .active_stage_opcode,
    .active_input_bank, .active_output_bank, .active_residual_bank
  );

  // Bank 0 is large enough for the native RGB source tensor.  Output banks
  // are sparse because the test retires only two words before aborting.
  logic [63:0] source_mem [0:PIXELS-1];
  logic [63:0] sparse_bank1 [0:MAX_SPARSE_WORDS-1];
  logic [63:0] sparse_bank2 [0:MAX_SPARSE_WORDS-1];
  logic pending_q;
  logic [63:0] pending_data_q;
  logic abort_q;
  integer cycle_count;
  integer request_count;
  integer source_write_count;
  integer window_read_count;
  integer output_write_count;
  integer engine_input_count;
  integer bank_index;
  integer local_word;
  integer i;
  integer tap_i;

  assign adapter_abort = abort_q;
  assign cache_stage_start_ready = 1'b1;
  assign adapter_final_ready = 1'b1;
  assign adapter_engine_ready = 1'b1;

  // One outstanding response, with a deterministic request-side bubble.
  assign mem_req_ready = !pending_q && ((cycle_count % 11) != 5);
  assign mem_rsp_valid = pending_q;
  assign mem_rsp_error = 1'b0;
  assign mem_rsp_rdata = pending_data_q;

  function automatic logic [63:0] source_pixel_fn(input integer x,
                                                    input integer y);
    logic [63:0] value;
    integer lane;
    begin
      value = 64'd0;
      for (lane = 0; lane < 3; lane = lane + 1)
        value[lane*8 +: 8] = (8'h21 + 7*x + 13*y + 29*lane) & 8'hff;
      source_pixel_fn = value;
    end
  endfunction

  function automatic logic [31:0] expected_first_tap_addr(input integer tap);
    integer tx, ty;
    begin
      // tap order is row-major; SAME_REPLICATE clamps -1 to zero.
      tx = ((tap % 3) == 2) ? 1 : 0;
      ty = (tap / 3 == 2) ? 1 : 0;
      expected_first_tap_addr = BASE_ADDR + ((ty * FRAME_W + tx) * 8);
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
    end else begin
      cycle_count <= cycle_count + 1;
      if (abort_q)
        abort_q <= 1'b0;

      if (mem_req_valid && mem_req_ready) begin
        if (pending_q)
          $fatal(1, "native first-window BFM accepted two outstanding requests");
        if (mem_req_addr[2:0] != 0 || mem_req_addr < BASE_ADDR ||
            mem_req_addr >= BASE_ADDR + 3*BANK_BYTES)
          $fatal(1, "native tensor address out of range: %08h", mem_req_addr);
        bank_index = (mem_req_addr - BASE_ADDR) / BANK_BYTES;
        local_word = ((mem_req_addr - BASE_ADDR) % BANK_BYTES) >> 3;
        if (local_word < 0 || local_word >= (BANK_BYTES/8))
          $fatal(1, "native tensor local word out of range: %0d", local_word);
        request_count <= request_count + 1;
        pending_q <= 1'b1;
        if (mem_req_write) begin
          if (mem_req_wstrb != 8'hff)
            $fatal(1, "native tensor write has partial strobe");
          case (bank_index)
            0: begin
              if (local_word >= PIXELS)
                $fatal(1, "source write escaped native RGB tensor");
              source_mem[local_word] <= mem_req_wdata;
              source_write_count <= source_write_count + 1;
              if (local_word != source_write_count)
                $fatal(1, "source address sequence mismatch word=%0d expected=%0d",
                       local_word, source_write_count);
            end
            1: begin
              if (local_word >= MAX_SPARSE_WORDS)
                $fatal(1, "first output write escaped sparse bank window");
              sparse_bank1[local_word] <= mem_req_wdata;
              output_write_count <= output_write_count + 1;
              // The first stage is stride-2, so x=0,y=0,g=0/1 are bank-1
              // words 0 and 1.  Abort only after the first write is accepted;
              // the response is still drained by the adapter.
              if (active_stage_index != 0 || active_stage_opcode != 8'd1 ||
                  local_word > 1)
                $fatal(1, "unexpected first-stage output address bank=%0d word=%0d",
                       bank_index, local_word);
              // Let both output groups retire.  The old counter value is 1
              // on the second write, so the abort is asserted only then.
              if (output_write_count >= 1)
                abort_q <= 1'b1;
            end
            2: begin
              if (local_word >= MAX_SPARSE_WORDS)
                $fatal(1, "unexpected bank-2 write outside sparse window");
              sparse_bank2[local_word] <= mem_req_wdata;
            end
            default: $fatal(1, "invalid tensor bank");
          endcase
          pending_data_q <= 64'd0;
        end else begin
          if (mem_req_wstrb != 0)
            $fatal(1, "native tensor read carried write strobe");
          case (bank_index)
            0: begin
              if (active_stage_index == 0 && active_stage_opcode == 8'd1 &&
                  mem_req_cacheable) begin
                if (window_read_count >= 9)
                  $fatal(1, "extra first-window read before engine launch");
                if (mem_req_addr !== expected_first_tap_addr(window_read_count))
                  $fatal(1, "first-window address mismatch tap=%0d got=%08h exp=%08h",
                         window_read_count, mem_req_addr,
                         expected_first_tap_addr(window_read_count));
                window_read_count <= window_read_count + 1;
              end
              if (local_word >= PIXELS)
                $fatal(1, "native source read escaped written frame");
              pending_data_q <= source_mem[local_word];
            end
            1: pending_data_q <= (local_word < MAX_SPARSE_WORDS) ?
                                  sparse_bank1[local_word] : 64'd0;
            2: pending_data_q <= (local_word < MAX_SPARSE_WORDS) ?
                                  sparse_bank2[local_word] : 64'd0;
            default: pending_data_q <= 64'd0;
          endcase
        end
      end
      if (mem_rsp_valid && mem_rsp_ready)
        pending_q <= 1'b0;

      if (adapter_engine_valid && adapter_engine_ready) begin
        engine_input_count <= engine_input_count + 1;
        if (engine_input_count != 0 || window_read_count != 9 ||
            adapter_engine_group_index != 0 || !adapter_engine_group_last ||
            adapter_engine_x != 0 || adapter_engine_y != 0 ||
            !adapter_engine_sof || adapter_engine_eol || adapter_engine_eof ||
            adapter_engine_residual_s8 != 0)
          $fatal(1, "first native engine input protocol mismatch");
        for (tap_i = 0; tap_i < 9; tap_i = tap_i + 1)
          if (adapter_engine_window_s8[tap_i*64 +: 64] !==
              source_pixel_fn(((tap_i % 3) == 2) ? 1 : 0,
                              (tap_i / 3 == 2) ? 1 : 0))
            $fatal(1, "first native window data mismatch tap=%0d", tap_i);
      end
      if (adapter_error)
        $fatal(1, "native first-window adapter error=%02h", adapter_error_code);
      if (cycle_count > 4_000_000)
        $fatal(1, "native first-window preflight timeout");
    end
  end

  // A two-beat synthetic engine response: one input group produces the two
  // output groups of native stage 0.  The payload is intentionally zero; this
  // gate is about address/window/protocol semantics, not arithmetic accuracy.
  logic fake_active_q;
  logic fake_group_q;
  always_comb begin
    adapter_result_valid = fake_active_q;
    adapter_result_data_s8 = 64'd0;
    adapter_result_group_index = {2'd0, fake_group_q};
    adapter_result_group_last = fake_group_q;
    adapter_result_x = 16'd0;
    adapter_result_y = 16'd0;
    adapter_result_sof = !fake_group_q;
    adapter_result_eol = 1'b0;
    adapter_result_eof = 1'b0;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      fake_active_q <= 1'b0;
      fake_group_q <= 1'b0;
    end else begin
      if (adapter_engine_valid && adapter_engine_ready) begin
        if (fake_active_q)
          $fatal(1, "synthetic engine overlap");
        fake_active_q <= 1'b1;
        fake_group_q <= 1'b0;
      end else if (adapter_result_valid && adapter_result_ready) begin
        if (!fake_group_q)
          fake_group_q <= 1'b1;
        else
          fake_active_q <= 1'b0;
      end
    end
  end

  task automatic send_config(input integer index);
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

  integer x, y;
  integer cfg_i;
  integer timeout;
  initial begin
    $readmemh("descriptors.mem", descriptors);
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
    tensor_base_addr = BASE_ADDR;
    for (i = 0; i < PIXELS; i = i + 1)
      source_mem[i] = 64'd0;
    for (i = 0; i < MAX_SPARSE_WORDS; i = i + 1) begin
      sparse_bank1[i] = 64'd0;
      sparse_bank2[i] = 64'd0;
    end

    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    adapter_start_valid = 1'b1;
    while (!adapter_start_ready) @(negedge clk);
    @(negedge clk);
    adapter_start_valid = 1'b0;

    for (cfg_i = 0; cfg_i < STAGES; cfg_i = cfg_i + 1)
      send_config(cfg_i);
    timeout = 0;
    while (!adapter_config_complete && timeout < 1000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_config_complete)
      $fatal(1, "native tensor adapter configuration did not complete");

    // Source ingestion is the only full-frame operation in this preflight.
    // No stage beyond the first output pixel is allowed to launch.
    for (y = 0; y < FRAME_H; y = y + 1)
      for (x = 0; x < FRAME_W; x = x + 1)
        send_source(x, y);

    timeout = 0;
    while (!adapter_aborted && timeout < 200000) begin
      @(negedge clk);
      timeout = timeout + 1;
    end
    if (!adapter_aborted)
      $fatal(1, "native first-window abort did not complete");
    if (adapter_error || adapter_busy || adapter_done || pending_q)
      $fatal(1, "native first-window abort did not return idle cleanly");
    if (source_write_count != PIXELS || window_read_count != 9 ||
        engine_input_count != 1 || output_write_count != 2)
      $fatal(1, "native first-window coverage mismatch source=%0d reads=%0d engine=%0d writes=%0d",
             source_write_count, window_read_count, engine_input_count,
             output_write_count);
    $display("C1_R1_NATIVE_FIRST_WINDOW_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=%0d pixel_pipeline=%0d source_writes=%0d first_window_reads=%0d engine_inputs=%0d output_writes=%0d abort=1 base=%08h boundary=NATIVE_SOURCE_INGEST_PLUS_FIRST_STAGE_WINDOW_ONLY",
             PIPELINED_TENSOR_ADDRESS_CFG, PIPELINED_TENSOR_PIXEL_INDEX_CFG,
             source_write_count, window_read_count, engine_input_count,
             output_write_count, BASE_ADDR);
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "native first-window global timeout");
  end
endmodule
