`timescale 1ns/1ps

// Trained-artifact ABI evidence.
//
// This test deliberately stops at the portable descriptor/arena boundary. It
// does not claim a 640x480 arithmetic frame run: the current microstyle
// engine enters ST_COLLECT after loading the first native-size layer and needs
// the full camera stream before it can accept the next descriptor. Keeping the
// test at the decoder boundary makes that limitation explicit and gives us a
// fast, deterministic regression for the trained 22-stage image.
module tb_c1_r1_microstyle_artifact_abi;
  localparam integer STAGES=22;
  localparam integer PARAM_BYTES=16896;
  localparam integer PARAM_WORDS=PARAM_BYTES/16;
  // Sum of the trained descriptor regions (weight+bias+multiplier+shift),
  // with each region read in 16-byte words.  The arena contains additional
  // alignment/padding bytes beyond this logical payload.
  localparam integer PARAM_PAYLOAD_BYTES=16379;
  localparam integer PARAM_READ_WORDS=1030;

  logic clk=0; always #5 clk=~clk;
  logic rst=1, abort=0;
  logic desc_valid=0, desc_ready;
  logic [511:0] desc_data=0;
  logic cmd_valid, cmd_ready=1;
  logic [511:0] cmd_data;
  logic error_pulse;
  logic [4:0] error_code;
  logic [511:0] desc_mem[0:STAGES-1];
  logic [127:0] param_mem[0:PARAM_WORDS-1];
  logic sched_start_valid=0, sched_start_ready;
  logic [7:0] sched_opcode=0;
  logic [15:0] sched_cin=0, sched_cout=0;
  logic [31:0] sched_w_off=0, sched_b_off=0, sched_m_off=0, sched_s_off=0;
  logic sched_param_en, sched_param_v, sched_param_err;
  logic [10:0] sched_param_addr;
  logic [127:0] sched_param_data;
  logic sched_cache_valid, sched_busy, sched_done, sched_error;
  logic [3:0] sched_error_code;
  logic [1:0] sched_cache_region;
  logic [15:0] sched_cache_word;
  logic [4:0] sched_cache_bytes;
  logic [127:0] sched_cache_data;
  integer i, j, accepted, param_nonzero, cycles, sched_reads, sched_writes, sched_bytes;

  c1_layer_command_decoder u_decoder (
    .clk, .rst, .abort,
    .descriptor_valid(desc_valid), .descriptor_ready(desc_ready),
    .descriptor_data(desc_data),
    .command_valid(cmd_valid), .command_ready(cmd_ready),
    .command_descriptor(cmd_data),
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
    .command_kernel_height(), .command_stride_x(), .command_stride_y(),
    .command_channel_block(), .command_mac_lanes(), .command_tile_width(),
    .command_tile_height(), .command_cycle_budget(),
    .error_pulse, .error_code
  );

  c1_r1_c8_parameter_scheduler #(.PARAM_ADDR_W(11),.PARAM_ARENA_BYTES(PARAM_BYTES)) u_scheduler (
    .clk,.rst,.abort,
    .start_valid(sched_start_valid), .start_ready(sched_start_ready),
    .cfg_opcode(sched_opcode), .cfg_input_channels(sched_cin),
    .cfg_output_channels(sched_cout), .cfg_weight_offset(sched_w_off),
    .cfg_bias_offset(sched_b_off), .cfg_multiplier_offset(sched_m_off),
    .cfg_shift_offset(sched_s_off),
    .param_rd_en(sched_param_en), .param_rd_addr(sched_param_addr),
    .param_rd_valid(sched_param_v), .param_rd_error(sched_param_err),
    .param_rd_data(sched_param_data),
    .cache_write_valid(sched_cache_valid), .cache_write_region(sched_cache_region),
    .cache_write_word_index(sched_cache_word), .cache_write_byte_count(sched_cache_bytes),
    .cache_write_data(sched_cache_data), .busy(sched_busy), .done(sched_done),
    .error(sched_error), .error_code(sched_error_code),
    .input_group_count(), .output_group_count(), .input_tail_mask(),
    .output_tail_mask(), .kernel_taps(), .weight_bytes()
  );

  assign sched_param_err = 1'b0;
  // Registered arena response, matching the scheduler's one-outstanding
  // contract.  The counters are testbench observability only.
  always @(posedge clk) begin
    if (rst || abort) begin
      sched_param_v <= 1'b0;
      sched_param_data <= '0;
    end else begin
      sched_param_v <= sched_param_en;
      if (sched_param_en) begin
        sched_param_data <= param_mem[sched_param_addr];
        sched_reads = sched_reads + 1;
      end
      if (sched_cache_valid) begin
        sched_writes = sched_writes + 1;
        sched_bytes = sched_bytes + sched_cache_bytes;
      end
    end
  end

  task automatic expect_scheduler_error(
    input logic [7:0] opcode,
    input logic [15:0] cin,
    input logic [15:0] cout,
    input logic [31:0] w_off,
    input logic [31:0] b_off,
    input logic [31:0] m_off,
    input logic [31:0] s_off,
    input logic [3:0] expected_code
  );
    integer reads_before;
    integer wait_cycles;
    begin
      @(negedge clk);
      wait_cycles = 0;
      while (!sched_start_ready || sched_done) begin
        @(negedge clk);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 100) $fatal(1, "negative scheduler ready timeout");
      end
      sched_opcode = opcode;
      sched_cin = cin;
      sched_cout = cout;
      sched_w_off = w_off;
      sched_b_off = b_off;
      sched_m_off = m_off;
      sched_s_off = s_off;
      reads_before = sched_reads;
      sched_start_valid = 1'b1;
      @(posedge clk); @(negedge clk);
      sched_start_valid = 1'b0;
      wait_cycles = 0;
      while (!sched_error) begin
        @(negedge clk);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 20) $fatal(1, "scheduler error timeout expected=%0d", expected_code);
      end
      if (sched_error_code != expected_code)
        $fatal(1, "scheduler error priority mismatch got=%0d expected=%0d",
               sched_error_code, expected_code);
      if (sched_reads != reads_before)
        $fatal(1, "invalid scheduler config issued a parameter read code=%0d", expected_code);
      @(negedge clk); abort = 1'b1;
      @(posedge clk); @(negedge clk); abort = 1'b0;
      if (!sched_start_ready) $fatal(1, "scheduler did not recover after error abort");
    end
  endtask

  task automatic expect_validate_abort;
    integer reads_before;
    begin
      @(negedge clk);
      while (!sched_start_ready || sched_done) @(negedge clk);
      sched_opcode = 8'd2;
      sched_cin = 16'd8;
      sched_cout = 16'd8;
      sched_w_off = 32'd0;
      sched_b_off = 32'd0;
      sched_m_off = 32'd0;
      sched_s_off = 32'd0;
      reads_before = sched_reads;
      sched_start_valid = 1'b1;
      @(posedge clk); @(negedge clk);
      sched_start_valid = 1'b0;
      abort = 1'b1;
      @(posedge clk); @(negedge clk);
      abort = 1'b0;
      if (!sched_start_ready || sched_busy || sched_done || sched_error)
        $fatal(1, "scheduler validate-stage abort did not return cleanly to idle");
      if (sched_reads != reads_before)
        $fatal(1, "scheduler validate-stage abort leaked a parameter request");
    end
  endtask

  task automatic expect_captured_config;
    integer reads_before;
    integer writes_before;
    integer bytes_before;
    integer wait_cycles;
    begin
      @(negedge clk);
      while (!sched_start_ready || sched_done) @(negedge clk);
      sched_opcode = 8'd2;
      sched_cin = 16'd8;
      sched_cout = 16'd8;
      sched_w_off = 32'd0;
      sched_b_off = 32'd0;
      sched_m_off = 32'd0;
      sched_s_off = 32'd0;
      reads_before = sched_reads;
      writes_before = sched_writes;
      bytes_before = sched_bytes;
      sched_start_valid = 1'b1;
      @(posedge clk); @(negedge clk);
      sched_start_valid = 1'b0;
      // Deliberately corrupt every live input immediately after acceptance.
      // The registered scheduler snapshot must remain authoritative.
      sched_opcode = 8'd0;
      sched_cin = 16'd0;
      sched_cout = 16'd0;
      sched_w_off = 32'd1;
      sched_b_off = 32'd1;
      sched_m_off = 32'd1;
      sched_s_off = 32'd1;
      wait_cycles = 0;
      while (!sched_done && !sched_error) begin
        @(negedge clk);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 100) $fatal(1, "captured-config scheduler timeout");
      end
      if (sched_error) $fatal(1, "scheduler used live cfg after START code=%0d", sched_error_code);
      if ((sched_reads - reads_before) != 9 ||
          (sched_writes - writes_before) != 9 ||
          (sched_bytes - bytes_before) != 136)
        $fatal(1, "captured-config coverage mismatch reads=%0d writes=%0d bytes=%0d",
               sched_reads-reads_before, sched_writes-writes_before,
               sched_bytes-bytes_before);
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    accepted = 0;
    param_nonzero = 0;
    cycles = 0;
    sched_reads = 0;
    sched_writes = 0;
    sched_bytes = 0;
`ifdef C1_LOCAL_ARTIFACT_VECTORS
    // Detached runners copy the compact ABI vectors into their disposable
    // working directory so the simulator never depends on a relative path
    // outside the run root.
    $readmemh("descriptors.mem", desc_mem);
    $readmemh("parameter_arena.mem", param_mem);
`else
    $readmemh("../vectors/microstyle_artifact/descriptors.mem", desc_mem);
    $readmemh("../vectors/microstyle_artifact/parameter_arena.mem", param_mem);
`endif

    repeat (5) @(negedge clk);
    rst = 0;
    @(negedge clk);

    if (desc_mem[0][7:0] !== 8'd1 || desc_mem[STAGES-1][7:0] !== 8'd6)
      $fatal(1, "artifact opcode boundary mismatch");
    for (j=0; j<PARAM_WORDS; j=j+1)
      if (param_mem[j] !== 128'd0) param_nonzero = param_nonzero + 1;
    if (param_nonzero == 0) $fatal(1, "parameter arena image is empty");

    // One descriptor per ready/valid transfer. Driving and sampling at
    // falling edges leaves the DUT's rising-edge state transition race-free.
    for (i=0; i<STAGES; i=i+1) begin
      desc_data = desc_mem[i];
      desc_valid = 1'b1;
      cycles = 0;
      while (!desc_ready) begin
        @(negedge clk);
        cycles = cycles + 1;
        if (cycles > 100) $fatal(1, "decoder ready timeout stage=%0d", i);
      end
      @(posedge clk);
      @(negedge clk);
      desc_valid = 1'b0;
      if (!cmd_valid) $fatal(1, "decoder command missing stage=%0d", i);
      if (cmd_data[7:0] !== desc_mem[i][7:0])
        $fatal(1, "opcode mismatch stage=%0d", i);
      if (error_pulse) $fatal(1, "descriptor rejected stage=%0d code=%0d", i, error_code);
      accepted = accepted + 1;
      // command_ready is permanently high, so the registered command is
      // retired at the next rising edge before the next descriptor.
      @(posedge clk);
      @(negedge clk);
    end

    if (accepted != STAGES) $fatal(1, "descriptor acceptance mismatch");

    // Run the real parameter scheduler once per trained descriptor.  This
    // exercises the same registered one-outstanding arena read contract used
    // by the engine, while intentionally stopping before the 640x480 data
    // plane.
    for (i=0; i<STAGES; i=i+1) begin
      // Residual/upsample/output descriptors intentionally have no parameter
      // regions.  The scheduler's parameterized-layer contract is exercised
      // for every Conv/ DW descriptor; the decoder loop above still covers all
      // 22 opcodes, including these zero-parameter stages.
      if ((desc_mem[i][7:0] == 8'd1) ||
          (desc_mem[i][7:0] == 8'd2) ||
          (desc_mem[i][7:0] == 8'd3)) begin
        // Move configuration onto a quiet half-cycle and allow the
        // combinational scheduler outputs to settle before the start edge.
        @(negedge clk); #1;
        sched_opcode = desc_mem[i][7:0];
        sched_cin = desc_mem[i][111:96];
        sched_cout = desc_mem[i][127:112];
        sched_w_off = desc_mem[i][255:224];
        sched_b_off = desc_mem[i][287:256];
        sched_m_off = desc_mem[i][319:288];
        sched_s_off = desc_mem[i][351:320];
        #1;
        cycles = 0;
        // ST_DONE presents done and start_ready together for one cycle.  Do
        // not launch the next descriptor until that pulse has cleared.
        while (sched_done || !sched_start_ready) begin @(negedge clk); cycles=cycles+1; if(cycles>100) $fatal(1,"scheduler ready timeout stage=%0d",i); end
        sched_start_valid = 1'b1;
        @(posedge clk); @(negedge clk); sched_start_valid = 1'b0;
        cycles = 0;
        while (!sched_done && !sched_error) begin
          @(posedge clk);
          cycles = cycles + 1;
          if (cycles > 20000) $fatal(1,"scheduler timeout stage=%0d",i);
        end
        if (sched_error) $fatal(1,"scheduler rejected stage=%0d code=%0d",i,sched_error_code);
        repeat(2) @(posedge clk);
      end
    end
    if (sched_reads != PARAM_READ_WORDS || sched_writes != PARAM_READ_WORDS || sched_bytes != PARAM_PAYLOAD_BYTES)
      $fatal(1,"scheduler arena coverage mismatch reads=%0d writes=%0d bytes=%0d",sched_reads,sched_writes,sched_bytes);
    $display("C1_R1_MICROSTYLE_ARTIFACT_ABI_PASS stages=%0d param_bytes=%0d param_words=%0d param_payload_bytes=%0d nonzero_words=%0d param_reads=%0d cache_writes=%0d boundary=RTL_DECODER_SCHEDULER_ARENA_ONLY_NATIVE_640x480", accepted, PARAM_BYTES, PARAM_WORDS, PARAM_PAYLOAD_BYTES, param_nonzero, sched_reads, sched_writes);

    // Preserve the historical trained-artifact marker above, then cover every
    // scheduler validation priority and the new one-cycle validation boundary.
    expect_scheduler_error(8'd0, 16'd8, 16'd8,
                           32'd0, 32'd0, 32'd0, 32'd0, 4'd1);
    expect_scheduler_error(8'd1, 16'd0, 16'd8,
                           32'd0, 32'd0, 32'd0, 32'd0, 4'd2);
    expect_scheduler_error(8'd3, 16'd8, 16'd16,
                           32'd0, 32'd0, 32'd0, 32'd0, 4'd3);
    expect_scheduler_error(8'd2, 16'd8, 16'd8,
                           32'd1, 32'd0, 32'd0, 32'd0, 4'd4);
    expect_scheduler_error(8'd1, 16'd48, 16'd48,
                           32'd0, 32'd0, 32'd0, 32'd0, 4'd5);
    expect_scheduler_error(8'd2, 16'd8, 16'd8,
                           PARAM_BYTES-32, 32'd0, 32'd0, 32'd0, 4'd6);
    expect_validate_abort();
    expect_captured_config();
    $display("C1_R1_PARAMETER_SCHEDULER_DIRECTED_PASS negative=6 validate_aborts=1 captured_configs=1");
    $finish;
  end
endmodule
