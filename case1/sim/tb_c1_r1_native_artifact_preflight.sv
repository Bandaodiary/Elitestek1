`timescale 1ns/1ps

// Native-size trained-artifact preflight.
//
// This is deliberately a staged test: it proves that the real 640x480
// descriptor image is accepted by the production decoder, that all adjacent
// tensor shapes are continuous, and that the real 16,896-byte parameter arena
// can be fetched through the production AXI parameter loader and atomically
// committed into the production dual-bank parameter RAM.  It intentionally
// stops before the CNN data plane.  A full 640x480 arithmetic run is therefore
// not implied by this marker and remains a separate (long) qualification.
module tb_c1_r1_native_artifact_preflight;
  localparam integer STAGES      = 22;
  localparam integer PARAM_BYTES = 16896;
  localparam integer PARAM_WORDS = PARAM_BYTES / 16;
  localparam logic [31:0] PARAM_BASE = 32'h0080_0000;
  localparam integer FRAME_W = 640;
  localparam integer FRAME_H = 480;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic [511:0] descriptors [0:STAGES-1];
  logic [127:0] parameter_mem [0:PARAM_WORDS-1];

  // Decoder interface.
  logic desc_valid = 1'b0;
  logic desc_ready;
  logic [511:0] desc_data = '0;
  logic cmd_valid;
  logic cmd_ready = 1'b1;
  logic [511:0] cmd_data;
  logic [4:0] desc_error_override = 5'd0;
  logic [7:0] cmd_opcode;
  logic [1:0] cmd_activation;
  logic [5:0] cmd_flags;
  logic [7:0] cmd_version, cmd_words;
  logic [15:0] cmd_iw, cmd_ih, cmd_ow, cmd_oh, cmd_ic, cmd_oc;
  logic [31:0] cmd_ioff, cmd_ooff, cmd_roff, cmd_woff, cmd_boff, cmd_moff,
               cmd_soff, cmd_istride, cmd_ostride, cmd_budget;
  logic [7:0] cmd_kw, cmd_kh, cmd_sx, cmd_sy, cmd_block, cmd_lanes,
              cmd_tw, cmd_th;
  logic decoder_error_pulse;
  logic [4:0] decoder_error_code;

  c1_layer_command_decoder u_decoder (
    .clk, .rst, .abort(1'b0),
    .descriptor_valid(desc_valid), .descriptor_ready(desc_ready),
    .descriptor_data(desc_data), .command_valid(cmd_valid),
    .command_ready(cmd_ready), .command_descriptor(cmd_data),
    .descriptor_error_override(desc_error_override),
    .command_opcode(cmd_opcode), .command_activation(cmd_activation),
    .command_flags(cmd_flags), .command_version(cmd_version),
    .command_words(cmd_words), .command_input_width(cmd_iw),
    .command_input_height(cmd_ih), .command_output_width(cmd_ow),
    .command_output_height(cmd_oh), .command_input_channels(cmd_ic),
    .command_output_channels(cmd_oc), .command_input_offset(cmd_ioff),
    .command_output_offset(cmd_ooff), .command_residual_offset(cmd_roff),
    .command_weight_offset(cmd_woff), .command_bias_offset(cmd_boff),
    .command_multiplier_offset(cmd_moff), .command_shift_offset(cmd_soff),
    .command_input_row_stride(cmd_istride),
    .command_output_row_stride(cmd_ostride), .command_kernel_width(cmd_kw),
    .command_kernel_height(cmd_kh), .command_stride_x(cmd_sx),
    .command_stride_y(cmd_sy), .command_channel_block(cmd_block),
    .command_mac_lanes(cmd_lanes), .command_tile_width(cmd_tw),
    .command_tile_height(cmd_th), .command_cycle_budget(cmd_budget),
    .error_pulse(decoder_error_pulse), .error_code(decoder_error_code)
  );

  // Production parameter loader and atomic parameter bank.
  logic load_start_valid = 1'b0, load_start_ready;
  logic load_busy, load_done, load_error, load_aborted;
  logic [3:0] load_error_code;
  logic [31:0] load_error_address;
  logic bank_load_start, bank_load_start_ready;
  logic bank_load_valid, bank_load_valid_bank, bank_load_ready,
        bank_load_ready_bank;
  logic [127:0] bank_load_data;
  logic bank_load_last, bank_load_abort;
  logic bank_load_busy, bank_load_done, bank_load_aborted, bank_load_error;
  logic [2:0] bank_load_error_code;
  logic bank_active_valid, bank_active_bank;
  logic [31:0] bank_generation;
  logic [0:0] bank_rd_en = 1'b0, bank_rd_valid, bank_rd_error;
  logic [10:0] bank_rd_addr = '0;
  logic [127:0] bank_rd_data;

  logic [31:0] axi_araddr;
  logic [7:0] axi_arlen;
  logic [2:0] axi_arsize;
  logic [1:0] axi_arburst;
  logic axi_arvalid, axi_arready;
  logic [127:0] axi_rdata;
  logic [1:0] axi_rresp;
  logic axi_rlast, axi_rvalid, axi_rready;

  c1_r1_parameter_bank #(
    .ARENA_BYTES(PARAM_BYTES), .READ_PORTS(1), .ADDR_W(11)
  ) u_parameter_bank (
    .clk, .rst,
    .load_start(bank_load_start), .load_start_ready(bank_load_start_ready),
    .load_valid(bank_load_valid_bank), .load_ready(bank_load_ready_bank),
    .load_data(bank_load_data), .load_last(bank_load_last),
    .load_abort(bank_load_abort), .load_busy(bank_load_busy),
    .load_done(bank_load_done), .load_aborted(bank_load_aborted),
    .load_error(bank_load_error), .load_error_code(bank_load_error_code),
    .active_valid(bank_active_valid), .active_bank(bank_active_bank),
    .generation(bank_generation), .rd_en(bank_rd_en), .rd_addr(bank_rd_addr),
    .rd_valid(bank_rd_valid), .rd_error(bank_rd_error), .rd_data(bank_rd_data)
  );

  c1_axi_parameter_loader #(.ARENA_BYTES(PARAM_BYTES)) u_parameter_loader (
    .clk, .rst,
    .start_valid(load_start_valid), .start_ready(load_start_ready),
    .start_base_addr(PARAM_BASE), .abort(1'b0), .busy(load_busy),
    .done(load_done), .error(load_error), .aborted(load_aborted),
    .error_code(load_error_code), .error_address(load_error_address),
    .bank_load_start(bank_load_start),
    .bank_load_start_ready(bank_load_start_ready),
    .bank_load_valid(bank_load_valid), .bank_load_ready(bank_load_ready),
    .bank_load_data(bank_load_data), .bank_load_last(bank_load_last),
    .bank_load_abort(bank_load_abort), .bank_load_busy(bank_load_busy),
    .bank_load_done(bank_load_done), .bank_load_aborted(bank_load_aborted),
    .bank_load_error(bank_load_error), .m_axi_araddr(axi_araddr),
    .m_axi_arlen(axi_arlen), .m_axi_arsize(axi_arsize),
    .m_axi_arburst(axi_arburst), .m_axi_arvalid(axi_arvalid),
    .m_axi_arready(axi_arready), .m_axi_rdata(axi_rdata),
    .m_axi_rresp(axi_rresp), .m_axi_rlast(axi_rlast),
    .m_axi_rvalid(axi_rvalid), .m_axi_rready(axi_rready)
  );

  // Bounded, delayed AXI read slave.  It stores no waveform and only one
  // burst at a time, matching the ID-less loader contract.
  logic rd_active_q = 1'b0;
  logic [31:0] rd_base_addr_q = '0;
  logic [7:0] rd_len_q = '0, rd_beat_q = '0;
  logic [2:0] rd_gap_q = '0;
  logic [31:0] lfsr_q = 32'h4d21_7ab3;
  integer burst_count = 0;
  integer beat_count = 0;
  integer bank_write_count = 0;
  integer ar_stall_count = 0;
  integer r_stall_count = 0;

  // Add a small deterministic bank-side pause.  This forces the loader to
  // hold a validated beat and deassert AXI RREADY occasionally, exercising
  // the same backpressure path used by a real embedded RAM wrapper.
  assign bank_load_ready = bank_load_ready_bank &&
                           (lfsr_q[7:6] != 2'b00);
  assign bank_load_valid_bank = bank_load_valid && bank_load_ready;

  // READY changes only on the falling edge so VALID/READY sampling is
  // race-free in both Icarus and Vivado xsim.
  always @(negedge clk) begin
    if (rst)
      axi_arready <= 1'b0;
    else
      axi_arready <= !rd_active_q && !axi_rvalid && (lfsr_q[1:0] != 2'b00);
  end

  always @(posedge clk) begin
    integer word_index;
    if (rst) begin
      rd_active_q <= 1'b0;
      rd_base_addr_q <= '0;
      rd_len_q <= '0;
      rd_beat_q <= '0;
      rd_gap_q <= '0;
      lfsr_q <= 32'h4d21_7ab3;
      axi_rvalid <= 1'b0;
      axi_rdata <= '0;
      axi_rresp <= 2'b00;
      axi_rlast <= 1'b0;
    end else begin
      lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^
                 lfsr_q[1] ^ lfsr_q[0]};
      if (axi_arvalid && !axi_arready)
        ar_stall_count = ar_stall_count + 1;
      if (axi_rvalid && !axi_rready)
        r_stall_count = r_stall_count + 1;

      if (axi_arvalid && axi_arready) begin
        if (axi_arsize != 3'd4 || axi_arburst != 2'b01 ||
            axi_araddr[3:0] != 4'd0 || axi_arlen > 8'd15)
          $fatal(1, "invalid parameter AXI AR");
        if ({1'b0, axi_araddr[11:0]} +
            ({5'd0, axi_arlen} + 13'd1) * 13'd16 > 13'd4096)
          $fatal(1, "parameter AXI burst crosses 4 KiB");
        if (axi_araddr < PARAM_BASE ||
            axi_araddr + ((axi_arlen + 1) * 16) > PARAM_BASE + PARAM_BYTES)
          $fatal(1, "parameter AXI address outside arena");
        rd_active_q <= 1'b1;
        rd_base_addr_q <= axi_araddr;
        rd_len_q <= axi_arlen;
        rd_beat_q <= 0;
        rd_gap_q <= {1'b0, lfsr_q[3:2]};
        burst_count = burst_count + 1;
      end

      if (axi_rvalid && axi_rready) begin
        axi_rvalid <= 1'b0;
        if (rd_beat_q == rd_len_q)
          rd_active_q <= 1'b0;
        else begin
          rd_beat_q <= rd_beat_q + 1'b1;
          rd_gap_q <= {1'b0, lfsr_q[5:4]};
        end
        beat_count = beat_count + 1;
      end else if (rd_active_q && !axi_rvalid) begin
        if (rd_gap_q != 0)
          rd_gap_q <= rd_gap_q - 1'b1;
        else begin
          word_index = (rd_base_addr_q - PARAM_BASE) / 16 + rd_beat_q;
          if (word_index < 0 || word_index >= PARAM_WORDS)
            $fatal(1, "parameter BFM word index out of range");
          axi_rdata <= parameter_mem[word_index];
          axi_rresp <= 2'b00;
          axi_rlast <= (rd_beat_q == rd_len_q);
          axi_rvalid <= 1'b1;
        end
      end
      if (bank_load_valid && bank_load_ready)
        begin
          bank_write_count = bank_write_count + 1;
        end
    end
  end

  function automatic integer region_bytes(input integer opcode,
                                           input integer cin,
                                           input integer cout);
    begin
      case (opcode)
        1: region_bytes = cin * cout * 9;
        2: region_bytes = cin * cout;
        3: region_bytes = cin * 9;
        default: region_bytes = 0;
      endcase
    end
  endfunction

  task automatic fail(input string message);
    begin
      $display("C1_R1_NATIVE_ARTIFACT_PREFLIGHT_FAIL %s", message);
      $fatal(1, "%s", message);
    end
  endtask

  task automatic check_descriptor_semantics(input integer idx);
    integer opcode, iw, ih, ow, oh, cin, cout;
    integer kw, kh, sx, sy;
    integer woff, boff, moff, soff;
    integer wb, bb, mb, sb;
    begin
      opcode = descriptors[idx][7:0];
      iw = descriptors[idx][47:32]; ih = descriptors[idx][63:48];
      ow = descriptors[idx][79:64]; oh = descriptors[idx][95:80];
      cin = descriptors[idx][111:96]; cout = descriptors[idx][127:112];
      kw = descriptors[idx][423:416]; kh = descriptors[idx][431:424];
      sx = descriptors[idx][439:432]; sy = descriptors[idx][447:440];
      woff = descriptors[idx][255:224]; boff = descriptors[idx][287:256];
      moff = descriptors[idx][319:288]; soff = descriptors[idx][351:320];
      if (descriptors[idx][23:16] != 8'd1 ||
          descriptors[idx][31:24] != 8'd16)
        fail($sformatf("descriptor header stage=%0d", idx));
      if (iw <= 0 || ih <= 0 || ow <= 0 || oh <= 0 ||
          iw > FRAME_W || ow > FRAME_W || ih > FRAME_H || oh > FRAME_H ||
          cin <= 0 || cout <= 0 || cin > 48 || cout > 48)
        fail($sformatf("descriptor dimensions stage=%0d", idx));
      if (descriptors[idx][455:448] != 8'd8 ||
          descriptors[idx][471:464] != 8'd1 ||
          descriptors[idx][479:472] != 8'd1)
        fail($sformatf("descriptor block/tile ABI stage=%0d", idx));

      case (opcode)
        1: begin
          if (kw != 3 || kh != 3 || (sx != 1 && sx != 2) || sy != sx)
            fail($sformatf("conv3x3 geometry stage=%0d", idx));
          wb = cin * cout * 9; bb = cout * 4; mb = cout * 4; sb = cout;
        end
        2: begin
          if (kw != 1 || kh != 1 || sx != 1 || sy != 1)
            fail($sformatf("conv1x1 geometry stage=%0d", idx));
          wb = cin * cout; bb = cout * 4; mb = cout * 4; sb = cout;
        end
        3: begin
          if (kw != 3 || kh != 3 || sx != 1 || sy != 1 || cin != cout)
            fail($sformatf("depthwise geometry stage=%0d", idx));
          wb = cin * 9; bb = cout * 4; mb = cout * 4; sb = cout;
        end
        4: begin
          if (kw != 1 || kh != 1 || sx != 2 || sy != 2 ||
              ow != iw*2 || oh != ih*2 || woff != 0 || boff != 0 ||
              moff != 0 || soff != 0)
            fail($sformatf("upsample geometry stage=%0d", idx));
          wb = 0; bb = 0; mb = 0; sb = 0;
        end
        5: begin
          if (iw != ow || ih != oh || cin != cout ||
              kw != 1 || kh != 1 || sx != 1 || sy != 1 ||
              woff != 0 || boff != 0 || moff != 0 || soff != 0)
            fail($sformatf("residual geometry stage=%0d", idx));
          wb = 0; bb = 0; mb = 0; sb = 0;
        end
        6: begin
          if (iw != ow || ih != oh || cin != 3 || cout != 3 ||
              kw != 1 || kh != 1 || sx != 1 || sy != 1 ||
              woff != 0 || boff != 0 || moff != 0 || soff != 0)
            fail($sformatf("RGB output geometry stage=%0d", idx));
          wb = 0; bb = 0; mb = 0; sb = 0;
        end
        default: fail($sformatf("unsupported opcode stage=%0d", idx));
      endcase

      if (wb != 0 && ((woff & 15) != 0 || (boff & 15) != 0 ||
                      (moff & 15) != 0 || (soff & 15) != 0))
        fail($sformatf("parameter alignment stage=%0d", idx));
      if (wb != 0 && (woff + wb > PARAM_BYTES || boff + bb > PARAM_BYTES ||
                      moff + mb > PARAM_BYTES || soff + sb > PARAM_BYTES))
        fail($sformatf("parameter range stage=%0d", idx));
      if (idx > 0 &&
          (descriptors[idx][47:32] != descriptors[idx-1][79:64] ||
           descriptors[idx][63:48] != descriptors[idx-1][95:80]))
        fail($sformatf("shape continuity stage=%0d", idx));
    end
  endtask

  task automatic send_descriptor(input integer idx);
    integer guard;
    begin
      @(negedge clk);
      desc_data <= descriptors[idx];
      desc_valid <= 1'b1;
      guard = 0;
      while (!desc_ready) begin
        @(negedge clk); guard = guard + 1;
        if (guard > 100) fail($sformatf("decoder ready timeout stage=%0d", idx));
      end
      @(posedge clk);
      @(negedge clk);
      desc_valid <= 1'b0;
      if (!cmd_valid || cmd_data !== descriptors[idx] || decoder_error_pulse)
        fail($sformatf("decoder payload stage=%0d code=%0d", idx,
                       decoder_error_code));
      if (cmd_opcode !== descriptors[idx][7:0] ||
          cmd_iw !== descriptors[idx][47:32] ||
          cmd_ih !== descriptors[idx][63:48] ||
          cmd_ow !== descriptors[idx][79:64] ||
          cmd_oh !== descriptors[idx][95:80] ||
          cmd_ic !== descriptors[idx][111:96] ||
          cmd_oc !== descriptors[idx][127:112])
        fail($sformatf("decoder field projection stage=%0d", idx));
      // command_ready is high; retire the output before the next descriptor.
      @(posedge clk);
    end
  endtask

  task automatic start_parameter_load;
    integer guard;
    begin
      @(negedge clk);
      load_start_valid <= 1'b1;
      guard = 0;
      while (!load_start_ready) begin
        @(negedge clk); guard = guard + 1;
        if (guard > 100) fail("parameter loader start timeout");
      end
      @(posedge clk);
      @(negedge clk);
      load_start_valid <= 1'b0;
      guard = 0;
      while (!load_done && !load_error && !load_aborted) begin
        @(negedge clk); guard = guard + 1;
        if (guard > 20000) fail("parameter loader timeout");
      end
      if (!load_done || load_error || load_aborted || !bank_active_valid ||
          bank_generation != 32'd1)
        fail($sformatf("parameter commit failed done=%0d error=%0d code=%0d addr=%h abort=%0d bank_busy=%0d bank_done=%0d bank_error=%0d bank_error_code=%0d bank_active=%0d gen=%0d bursts=%0d beats=%0d bank_writes=%0d bank_idx=%0d loader_state=%0d rem=%0d",
                       load_done, load_error, load_error_code,
                       load_error_address, load_aborted, bank_load_busy,
                       bank_load_done, bank_load_error, bank_load_error_code,
                       bank_active_valid,
                       bank_generation, burst_count, beat_count,
                       bank_write_count, u_parameter_bank.load_word_index,
                       u_parameter_loader.state,
                       u_parameter_loader.words_remaining));
    end
  endtask

  task automatic check_bank_word(input integer idx);
    integer guard;
    begin
      @(negedge clk);
      bank_rd_addr <= idx[10:0];
      bank_rd_en <= 1'b1;
      @(posedge clk);
      @(negedge clk);
      bank_rd_en <= 1'b0;
      guard = 0;
      while (!bank_rd_valid) begin
        @(negedge clk); guard = guard + 1;
        if (guard > 10) fail($sformatf("bank read timeout word=%0d", idx));
      end
      if (bank_rd_error || bank_rd_data !== parameter_mem[idx])
        fail($sformatf("bank readback mismatch word=%0d", idx));
    end
  endtask

  initial begin : main
    integer i;
    integer nonzero_words;
    integer descriptor_count;
`ifdef C1_LOCAL_NATIVE_ARTIFACT_VECTORS
    // Detached runners copy the small vectors into the disposable xsim
    // working directory.  This keeps path resolution independent of the
    // caller's current directory and avoids writing into the source tree.
    $readmemh("descriptors.mem", descriptors);
    $readmemh("parameter_arena.mem", parameter_mem);
`else
    $readmemh("../vectors/microstyle_artifact/descriptors.mem", descriptors);
    $readmemh("../vectors/microstyle_artifact/parameter_arena.mem", parameter_mem);
`endif
    nonzero_words = 0;
    for (i = 0; i < PARAM_WORDS; i = i + 1)
      if (parameter_mem[i] !== 128'd0) nonzero_words = nonzero_words + 1;
    if (nonzero_words == 0) fail("real parameter arena is empty");

    descriptor_count = 0;
    for (i = 0; i < STAGES; i = i + 1) begin
      check_descriptor_semantics(i);
      descriptor_count = descriptor_count + 1;
    end
    if (descriptors[0][47:32] != FRAME_W || descriptors[0][63:48] != FRAME_H ||
        descriptors[STAGES-1][79:64] != FRAME_W ||
        descriptors[STAGES-1][95:80] != FRAME_H ||
        descriptors[STAGES-1][127:112] != 16'd3 ||
        descriptors[STAGES-1][7:0] != 8'd6)
      fail("native 640x480 descriptor boundary mismatch");

    repeat (8) @(posedge clk);
    @(negedge clk);
    rst <= 1'b0;
    repeat (3) @(posedge clk);
    for (i = 0; i < STAGES; i = i + 1)
      send_descriptor(i);
    start_parameter_load();
    // Spot-check both bank edges and interior words.  The full arena is
    // covered on the AXI and bank write paths; these reads prove committed
    // data visibility without producing a large trace.
    check_bank_word(0);
    check_bank_word(1);
    check_bank_word(PARAM_WORDS/2);
    check_bank_word(PARAM_WORDS-1);

    if (burst_count != 66 || beat_count != PARAM_WORDS ||
        ar_stall_count == 0 || r_stall_count == 0 || axi_rvalid ||
        rd_active_q || bank_load_busy)
      fail($sformatf("AXI coverage mismatch bursts=%0d beats=%0d ar_stall=%0d r_stall=%0d",
                     burst_count, beat_count, ar_stall_count, r_stall_count));
    $display("C1_R1_NATIVE_ARTIFACT_PREFLIGHT_PASS frame=640x480 stages=%0d descriptor_count=%0d parameter_bytes=%0d parameter_words=%0d parameter_nonzero_words=%0d bursts=%0d beats=%0d ar_stalls=%0d r_stalls=%0d generation=%0d boundary=DESCRIPTOR_CONTINUITY_PLUS_PARAMETER_COMMIT_ONLY", STAGES, descriptor_count, PARAM_BYTES, PARAM_WORDS, nonzero_words, burst_count, beat_count, ar_stall_count, r_stall_count, bank_generation);
    $finish;
  end

  initial begin
    #5_000_000;
    fail("native artifact preflight global timeout");
  end
endmodule
