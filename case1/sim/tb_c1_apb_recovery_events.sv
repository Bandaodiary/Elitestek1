`timescale 1ns/1ps
// CSR event-priority test. done is an input stimulus, not a forced SoC signal.
module tb_c1_apb_recovery_events;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic psel=0,penable=0,pwrite=0;
    logic [11:0] paddr=0;
    logic [31:0] pwdata=0;
    logic [3:0] pstrb=0;
    logic ready=1,busy=0,done=0,source_ack=0;
    wire [31:0] prdata;
    wire pready,pslverr,request;
    integer requests=0;
    always @(posedge clk) if(rst_n && request) requests<=requests+1;
    c1_apb_csr #(.ENABLE_CAPTURE_RECOVERY(1)) dut (
        .clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),
        .prdata(prdata),.pready(pready),.pslverr(pslverr),
        .busy(1'b0),.done_event(1'b0),.error_event(1'b0),
        .capture_drop_event(1'b0),.display_swap_event(1'b0),.display_underflow_event(1'b0),
        .recovery_ready(ready),.recovery_busy(busy),.recovery_done(done),
        .source_quiescent(source_ack),.recovery_request(request)
    );
    task automatic command(input logic[31:0] value,input bit event_done,
                           input bit target_ready,input bit expected_error);
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr=12'h130;pwdata=value;pstrb=15;
        #1;if(request) $fatal(1,"request during APB setup");
        @(negedge clk);penable=1;done=event_done;ready=target_ready;
        @(posedge clk);
        if(pslverr!==expected_error || !pready) $fatal(1,"wrong recovery response");
        @(negedge clk);psel=0;penable=0;pwrite=0;done=0;
    endtask
    task automatic check_done(input bit expected);
        paddr=12'h134;
        #1;if(prdata[3]!==expected) $fatal(1,"wrong sticky done expected=%0d got=%h",expected,prdata);
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        command(2,1,1,0);check_done(1); // completion wins W1C
        command(2,0,1,0);check_done(0);
        command(1,1,1,0);check_done(0); // new request supersedes old completion
        if(requests!=1) $fatal(1,"accepted command not exactly once");
        command(1,1,0,1);check_done(1); // rejection cannot erase new completion
        if(requests!=1) $fatal(1,"rejected command escaped");
        command(3,0,1,1);check_done(1); // illegal command no side effects
        command(1,0,1,0);check_done(0);
        if(requests!=2) $fatal(1,"second request missing");
        @(negedge clk);rst_n=0;
        @(negedge clk);check_done(0);
        $display("C1_APB_RECOVERY_EVENTS_PASS accepted=2 completion_wins_clear=1 new_request_clears_old_done=1 rejected_no_effect=1");
        $finish;
    end
    initial begin #10000;$fatal(1,"CSR recovery event timeout");end
endmodule
