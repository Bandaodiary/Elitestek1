`timescale 1ns/1ps
module tb_c1_column_transaction_owner;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic s_req_valid=0,s_req_ready,s_rsp_valid,s_rsp_ready=0,s_rsp_error;
    logic signed [16:0] s_req_x=-3,s_req_center_y=7,m_req_x,m_req_center_y;
    logic [2:0] s_req_group=2,m_req_group;
    logic [191:0] s_rsp_data,m_rsp_data=192'h123456789abcdef;
    logic m_req_valid,m_req_ready=0,m_rsp_valid=0,m_rsp_ready,m_rsp_error=0;
    logic abort_req=0,flush_req=0,abort_done,flush_done;
    logic m_abort_req,m_flush_req,m_abort_done=0,m_flush_done=0;
    logic backend_config_valid=1,backend_quiescent=1,config_pending=0;
    logic config_permit,busy,quiescent;
    integer requests=0,responses=0,aborts=0,flushes=0,done_a=0,done_f=0;
    c1_column_transaction_owner dut(.*);
    always @(posedge clk) if(!rst) begin
        if(m_req_valid&&m_req_ready) requests<=requests+1;
        if(s_rsp_valid&&s_rsp_ready) responses<=responses+1;
        if(m_abort_req) aborts<=aborts+1;
        if(m_flush_req) flushes<=flushes+1;
        if(abort_done) done_a<=done_a+1;
        if(flush_done) done_f<=done_f+1;
    end
    task tick; begin @(posedge clk); #1; end endtask
    task drive; begin @(negedge clk); end endtask
    task check(input bit ok,input string msg);
        if(!ok) $fatal(1,"OWNER: %s",msg);
    endtask
    initial begin
        #20000; $fatal(1,"OWNER timeout");
    end
    initial begin
        repeat(3) tick(); drive(); rst=0;
        // Normal bypass, followed by a held success response and a late fence.
        s_req_valid=1;m_req_ready=1; #1;
        check(m_req_valid&&s_req_ready,"request bypass"); tick();
        drive();s_req_valid=0;backend_quiescent=0;m_rsp_valid=1; #1;
        check(s_rsp_valid&&!s_rsp_error&&s_rsp_data==m_rsp_data,"response bypass");
        flush_req=1;#1;
        check(s_rsp_valid&&!s_rsp_error&&s_rsp_data==m_rsp_data,
            "late fence must not combinationally rewrite bypass response");
        tick();drive();m_rsp_valid=0;flush_req=1;backend_quiescent=1;
        tick();tick();drive();m_flush_done=1;
        tick();drive();m_flush_done=0;
        repeat(3) begin tick();check(!flush_done&&s_rsp_valid&&!s_rsp_error,
            "fence must preserve stalled success and wait for consumption");end
        drive();s_rsp_ready=1;tick();tick();tick();
        check(done_f==1&&flushes==1,"joined flush completion");
        // Held high fence: late requests terminate locally without retrigger.
        drive();s_req_valid=1;tick();drive();s_req_valid=0; #1;
        check(s_rsp_valid&&s_rsp_error&&s_rsp_data==0&&!m_req_valid,"late fence reject");
        tick();tick();check(flushes==1,"held fence retriggered");
        drive();flush_req=0;s_rsp_ready=0;tick();
        // Cache not configured: reject locally instead of hanging.
        drive();backend_config_valid=0;s_req_valid=1;tick();
        drive();s_req_valid=0;#1;check(s_rsp_valid&&s_rsp_error,"invalid config reject");
        s_rsp_ready=1;tick();drive();s_rsp_ready=0;backend_config_valid=1;
        // Configuration wins arbitration; both config directions use permit.
        config_pending=1;s_req_valid=1;#1;
        check(config_permit&&!s_req_ready&&!m_req_valid,"config arbitration");
        tick();drive();config_pending=0;m_req_ready=0;tick();
        // Upstream request is owned, but child has not accepted it yet.
        drive();s_req_valid=0;s_req_x=91;abort_req=1;backend_quiescent=0;
        repeat(4) begin tick();check(m_req_valid&&m_req_x==-3&&!m_abort_req&&!abort_done,
            "held downstream request must precede fence");end
        drive();flush_req=1;tick();drive();abort_req=0;flush_req=0;
        tick();drive();abort_req=1;tick(); // same-kind repeated edge coalesces
        drive();abort_req=0;m_req_ready=1;tick();
        check(m_abort_req&&m_flush_req,"joined downstream fence after acceptance");
        tick();drive();m_abort_done=1;m_rsp_valid=1;m_rsp_error=1;
        tick();drive();m_abort_done=0;m_rsp_valid=0;backend_quiescent=1;
        check(s_rsp_valid&&s_rsp_error&&s_rsp_data==0,"cancelled reply poisoned");
        repeat(3) begin tick();check(!abort_done&&!flush_done,"wait for other ACK and consumer");end
        drive();m_flush_done=1;tick();drive();m_flush_done=0;
        tick();check(!abort_done,"still waiting for response consumption");
        drive();s_rsp_ready=1;tick();tick();tick();
        check(done_a==1&&done_f==2&&aborts==1&&flushes==2,"coalesced fence counts");
        // Request and new fence together: no request reaches child.
        drive();s_req_valid=1;abort_req=1;#1;
        check(s_req_ready&&!m_req_valid,"same-edge fence admission");
        tick();drive();s_req_valid=0;abort_req=0;tick();
        drive();m_abort_done=1;tick();drive();m_abort_done=0;tick();tick();
        check(done_a==2&&requests==2&&responses==5,"request response conservation");
        // Restart without reset, with a downstream error.
        drive();s_req_valid=1;tick();drive();s_req_valid=0;m_rsp_valid=1;m_rsp_error=1;
        #1;check(s_rsp_valid&&s_rsp_error&&s_rsp_data==0,"backend error forwarding");
        tick();drive();m_rsp_valid=0;m_rsp_error=0;tick();
        check(quiescent&&requests==3&&responses==6,"restart and final drain");
        $display("C1_COLUMN_OWNER_PASS requests=%0d responses=%0d aborts=%0d flushes=%0d",requests,responses,aborts,flushes);
        $finish;
    end
endmodule
