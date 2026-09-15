`timescale 1ns/1ps

// Small trained-artifact engine probe.  The memory files are copied into the
// detached runner's disposable working directory before xsim starts.
module tb_c1_r1_microstyle_engine_artifact_8x8;
  localparam integer STAGES=22;
  localparam integer PARAM_BYTES=16896;
  localparam integer PARAM_WORDS=PARAM_BYTES/16;
  localparam integer RECORDS=896;
  localparam integer EXPECTED=836;

  logic clk=0; always #5 clk=~clk;
  logic rst=1, abort=0;
  logic start_valid=0, start_ready;
  logic [15:0] stage_count=STAGES;
  logic [7:0] config_generation=8'h51;
  logic parameter_active_valid=1;
  logic [31:0] parameter_generation=32'h20260828;
  logic busy, done, aborted, error;
  logic [7:0] error_code;
  logic stage_config_valid=0, stage_config_ready;
  logic [15:0] stage_config_index=0;
  logic [511:0] stage_config_descriptor=0;
  logic [7:0] stage_config_generation=0;
  logic param_rd_en, param_rd_valid=0, param_rd_error=0;
  logic [10:0] param_rd_addr;
  logic [127:0] param_rd_data=0;
  logic in_valid=0, in_ready;
  logic [575:0] in_window_s8=0;
  logic [63:0] in_residual_s8=0;
  logic [2:0] in_group_index=0;
  logic in_group_last=0;
  logic [15:0] in_x=0, in_y=0;
  logic in_sof=0, in_eol=0, in_eof=0;
  logic out_valid, out_ready=1;
  logic [63:0] out_data_s8;
  logic [2:0] out_group_index;
  logic out_group_last;
  logic [15:0] out_x, out_y;
  logic out_sof, out_eol, out_eof;
  logic [4:0] stage_index;
  logic [7:0] stage_opcode;
  logic stage_active, adapter_required, stage_done, overflow_seen;
  logic config_capture_complete;

  logic [511:0] descriptors [0:STAGES-1];
  logic [127:0] parameter_mem [0:PARAM_WORDS-1];
  logic [1023:0] input_records [0:RECORDS-1];
  logic [63:0] expected_records [0:EXPECTED-1];
  logic [127:0] stage_meta [0:STAGES-1];
  integer record_index, expected_index, output_count, stage_done_count;
  integer pending_addr, pending_valid, cycles;

  c1_r1_microstyle_cnn_top #(
    .REQUIRED_STAGES(STAGES), .PARAM_ADDR_W(11),
    .PARAM_ARENA_BYTES(PARAM_BYTES), .MAX_CHANNELS(48),
    .MAX_WEIGHT_BYTES(2592)
  ) dut (
    .clk,.rst,.abort,.start_valid,.start_ready,.stage_count,
    .config_generation,.parameter_active_valid,.parameter_generation,
    .busy,.done,.aborted,.error,.error_code,
    .stage_config_valid,.stage_config_ready,.stage_config_index,
    .stage_config_descriptor,.stage_config_generation,
    .param_rd_en,.param_rd_addr,.param_rd_valid,.param_rd_error,
    .param_rd_data,.in_valid,.in_ready,.in_window_s8,.in_residual_s8,
    .in_group_index,.in_group_last,.in_x,.in_y,.in_sof,.in_eol,.in_eof,
    .out_valid,.out_ready,.out_data_s8,.out_group_index,.out_group_last,
    .out_x,.out_y,.out_sof,.out_eol,.out_eof,.stage_index,.stage_opcode,
    .stage_active,.adapter_required,.stage_done,.overflow_seen,
    .config_capture_complete
  );

  task automatic pulse_start;
    begin
      @(negedge clk); start_valid=1'b1;
      while (!start_ready) @(negedge clk);
      @(negedge clk); start_valid=1'b0;
    end
  endtask

  task automatic send_config(input integer index);
    begin
      @(negedge clk); stage_config_index=index;
      stage_config_descriptor=descriptors[index];
      stage_config_generation=config_generation; stage_config_valid=1'b1;
      while (!stage_config_ready) @(negedge clk);
      @(negedge clk); stage_config_valid=1'b0;
    end
  endtask

  task automatic send_record(input integer index);
    logic [1023:0] record;
    begin
      record=input_records[index];
      @(negedge clk);
      in_window_s8=record[575:0]; in_residual_s8=record[639:576];
      in_x=record[719:704]; in_y=record[735:720];
      in_group_index=record[743:736];
      in_valid=1'b1;
      // Metadata is generated with the vectors, so the TB does not duplicate
      // stage offsets, geometry, or C8 group counts by hand.
      in_group_last=(record[743:736] == stage_meta[record[751:744]][103:96]-1);
      in_sof=(record[719:704]==0)&&(record[735:720]==0);
      in_eol=(record[719:704] == stage_meta[record[751:744]][79:64]-1);
      in_eof=in_eol && (record[735:720] == stage_meta[record[751:744]][95:80]-1);
      while (!in_ready) @(negedge clk);
      @(negedge clk); in_valid=1'b0;
    end
  endtask

  integer si, ri, oi, got_stage, exp_pos;
  initial begin
    $readmemh("descriptors.mem", descriptors);
    $readmemh("parameter_arena.mem", parameter_mem);
    $readmemh("engine_vectors.mem", input_records);
    $readmemh("expected_outputs.mem", expected_records);
    $readmemh("stage_meta.mem", stage_meta);
    expected_index=0; output_count=0; stage_done_count=0;
    pending_valid=0; pending_addr=0; cycles=0;
    repeat (8) @(negedge clk); rst=1'b0;
    pulse_start();
    for (si=0; si<STAGES; si=si+1) send_config(si);
    record_index=0;
    while (record_index < RECORDS) begin
      if (error) $fatal(1,"engine error code=%0h",error_code);
      if (stage_active) begin send_record(record_index); record_index=record_index+1; end
      else @(negedge clk);
    end
    while (!done) begin
      if (error) $fatal(1,"engine error code=%0h",error_code);
      @(negedge clk);
    end
    repeat (4) @(negedge clk);
    if (output_count != EXPECTED)
      $fatal(1,"expected %0d outputs got %0d",EXPECTED,output_count);
    if (expected_index != EXPECTED)
      $fatal(1,"expected cursor %0d got %0d",EXPECTED,expected_index);
    $display("C1_R1_MICROSTYLE_ENGINE_ARTIFACT_8X8_PASS stages=%0d records=%0d outputs=%0d cycles=%0d",STAGES,RECORDS,output_count,cycles);
    $finish;
  end

  always @(posedge clk) begin
    cycles=cycles+1;
    param_rd_valid<=1'b0; param_rd_error<=1'b0;
    if (rst || abort) begin pending_valid<=0; param_rd_data<='0; end
    else begin
      if (param_rd_en) begin
        if (pending_valid) $fatal(1,"second parameter read");
        pending_valid<=1; pending_addr<=param_rd_addr;
      end
      if (pending_valid) begin
        param_rd_data<=parameter_mem[pending_addr];
        param_rd_valid<=1'b1; pending_valid<=0;
      end
    end
    if (out_valid && out_ready) begin
      got_stage=stage_index;
      if (expected_index >= EXPECTED)
        $fatal(1,"unexpected extra output stage=%0d",got_stage);
      if (expected_records[expected_index] !== out_data_s8)
        $fatal(1,"artifact mismatch stage=%0d xy=%0d,%0d group=%0d got=%h exp=%h",got_stage,out_x,out_y,out_group_index,out_data_s8,expected_records[expected_index]);
      expected_index=expected_index+1; output_count=output_count+1;
    end
    if (stage_done) stage_done_count=stage_done_count+1;
    if (overflow_seen) $fatal(1,"unexpected accumulator overflow");
    if (cycles > 2000000) $fatal(1,"artifact probe timeout");
  end
endmodule
