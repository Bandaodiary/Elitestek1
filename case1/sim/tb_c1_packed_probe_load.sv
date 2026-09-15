`timescale 1ns/1ps
module tb_c1_packed_probe_load;
  reg clk=0, rst=1;
  reg [63:0] stimulus=0;
  wire [46:0] observe;
  reg [511:0] descriptor=0;
  reg [127:0] parameters=0;
  reg [575:0] window_data=0;
  reg [31:0] word_data;
  c1_ti60_cnn_top_packed_wrapper dut(.*);
  always #5 clk=~clk;
  initial begin
    repeat(3) @(negedge clk);
    rst=0;
    for(integer sel=0;sel<3;sel=sel+1) begin
      for(integer i=0;i<18;i=i+1) begin
        word_data=32'h129a5600 + sel*256 + i;
        stimulus=64'h8000000000000000 | (64'(sel)<<61) | word_data;
        case(sel)
          0: descriptor={descriptor[479:0],word_data};
          1: parameters={parameters[95:0],word_data};
          2: window_data={window_data[543:0],word_data};
        endcase
        @(negedge clk);
        if(dut.stage_config_descriptor!==descriptor || dut.param_rd_data!==parameters ||
           dut.in_window_s8!==window_data) $fatal(1,"probe banks not independently loadable");
        if(dut.start_valid || dut.stage_config_valid || dut.in_valid || dut.param_rd_valid)
          $fatal(1,"load command leaked into transaction controls");
      end
    end
    stimulus=0;
    if($bits(observe)!=47) $fatal(1,"observation truncation");
    $display("C1_PACKED_PROBE_LOAD_PASS banks=3 independent_words=54 observe_bits=47");
    $finish;
  end
  initial begin #10000; $fatal(1,"watchdog"); end
endmodule
