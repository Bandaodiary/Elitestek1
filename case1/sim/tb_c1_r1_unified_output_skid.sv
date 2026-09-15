`timescale 1ns/1ps
module tb_c1_r1_unified_output_skid;
`ifdef C1_UNIFIED_SKID_REGISTERED_ERROR
 localparam integer EG=0;
`else
 localparam integer EG=1;
`endif
 logic clk=0,rst=1,abort=0,error_flush=0,in_valid=0,out_ready=0;
 logic in_ready,out_valid,in_group_last,in_sof,in_eol,in_eof;
 logic [63:0] in_data_s8=0,out_data_s8; logic [2:0] in_group_index=0,out_group_index;
 logic [15:0] in_x=0,in_y=0,out_x,out_y; logic out_group_last,out_sof,out_eol,out_eof;
 logic level,full,empty;
 c1_r1_unified_output_skid #(.COMBINATIONAL_ERROR_GATE(EG)) dut(.*);
 always #5 clk=~clk;
 task automatic drive(input integer n); begin
   in_data_s8=64'hc1a5_0000_0000_0000+n; in_group_index=n%8; in_group_last=(n%3)==0;
   in_x=n; in_y=16'h1200+n; in_sof=(n%5)==0; in_eol=(n%4)==1; in_eof=(n%7)==6;
 end endtask
 function automatic logic [63:0] exp_data(input integer n);
   exp_data=64'hc1a5_0000_0000_0000+n;
 endfunction
 function automatic logic [2:0] exp_group(input integer n);
   exp_group=n%8;
 endfunction
 function automatic logic exp_group_last(input integer n);
   exp_group_last=(n%3)==0;
 endfunction
 function automatic logic [15:0] exp_x(input integer n);
   exp_x=n;
 endfunction
 function automatic logic [15:0] exp_y(input integer n);
   exp_y=16'h1200+n;
 endfunction
 function automatic logic exp_sof(input integer n);
   exp_sof=(n%5)==0;
 endfunction
 function automatic logic exp_eol(input integer n);
   exp_eol=(n%4)==1;
 endfunction
 function automatic logic exp_eof(input integer n);
   exp_eof=(n%7)==6;
 endfunction
 task automatic check(input integer n); begin
   if (out_data_s8 !== exp_data(n) || out_group_index !== exp_group(n) ||
       out_group_last !== exp_group_last(n) || out_x !== exp_x(n) ||
       out_y !== exp_y(n) || out_sof !== exp_sof(n) ||
       out_eol !== exp_eol(n) || out_eof !== exp_eof(n))
     $fatal(1,"skid payload mismatch %0d data=%h group=%0d last=%0b xy=%0d,%0d flags=%0b%0b%0b",
            n,out_data_s8,out_group_index,out_group_last,out_x,out_y,
            out_sof,out_eol,out_eof);
 end endtask
 initial begin
   repeat(2) @(posedge clk); #1; if(in_ready||out_valid||level) $fatal(1,"reset fence");
   @(negedge clk); rst=0; in_valid=1; drive(1); out_ready=0; #1;
   if(!in_ready||out_valid) $fatal(1,"fall-through"); @(posedge clk); #1; in_valid=0;
   if(!out_valid||!full||!level) $fatal(1,"push failed"); check(1);
   repeat(3) begin @(posedge clk); #1; if(!out_valid) $fatal(1,"stall valid lost"); check(1); end
   @(negedge clk); in_valid=1; drive(2); out_ready=1; #1;
   if(in_ready) $fatal(1,"full replacement accepted"); check(1); @(posedge clk); #1;
   if(level||out_valid) $fatal(1,"pop failed"); in_valid=0;
   // First fill the entry, then assert abort while a producer/consumer are
   // presenting transfers.  Both handshakes must fence immediately and the
   // queued payload must disappear at the abort edge.
   @(negedge clk); in_valid=1; drive(3); out_ready=0; #1;
   if(!in_ready) $fatal(1,"post-pop ready");
   @(posedge clk); #1; in_valid=0;
   @(negedge clk); in_valid=1; drive(4); out_ready=1; abort=1; #1;
   if(in_ready||out_valid) $fatal(1,"abort handshake fence");
   @(posedge clk); #1; abort=0; in_valid=0; #1;
   if(level||out_valid||!in_ready) $fatal(1,"abort flush failed");

   // Error flush, including registered-error mode behavior.
   @(negedge clk); in_valid=1; drive(5); out_ready=0; #1;
   if(!in_ready) $fatal(1,"error-test input not ready");
   @(posedge clk); #1; in_valid=0;
   @(negedge clk); error_flush=1; #1;
`ifndef C1_UNIFIED_SKID_REGISTERED_ERROR
   if(in_ready||out_valid) $fatal(1,"error gate");
`else
   if(!out_valid||level!=1) $fatal(1,"registered error changed pre-edge");
`endif
   @(posedge clk); #1; error_flush=0; if(level||out_valid) $fatal(1,"flush failed");
   // New epoch and complete metadata check.
   @(negedge clk); in_valid=1; drive(6); out_ready=1; #1; if(!in_ready||out_valid) $fatal(1,"new epoch"); @(posedge clk); #1; in_valid=0;
   if(!out_valid) $fatal(1,"epoch beat absent"); check(6); @(posedge clk); #1;
   $display("C1_R1_UNIFIED_OUTPUT_SKID_PASS depth=1 payload=103"); $finish;
 end
endmodule
