`timescale 1ns/1ps
// Real 22-stage tensor adapter + production packing/read bridge + independent
// physical AXI memory. Engine remains the existing operand-checking model;
// this test is not full CNN numerical signoff and does not contain a cache.
module tb_c1_adapter_packing_memory #(
    parameter integer W_FIRST=0, parameter integer USE_END=0,
    parameter integer PACKED_WRITES=1, parameter integer B_RESPONSE_DELAY=12
);
    tb_c1_r1_microstyle_tensor_adapter #(
        .PIPELINED_WRITES(1), .RUN_WRITE_DRAIN_SCENARIOS(0),
        .RESPONSE_DEPTH(PACKED_WRITES ? 8 : 1)
    ) base();
    tb_c1_tensor_packing_memory #(
        .W_FIRST(W_FIRST),.EXTERNAL_DRIVER(1),.USE_END(USE_END),
        .PACKED_WRITES(PACKED_WRITES),.B_RESPONSE_DELAY(B_RESPONSE_DELAY)
    ) physical();
    integer job_start_cycle=0;
    always @(posedge base.clk)
        if(!base.rst && base.adapter_start_valid && base.adapter_start_ready)
            job_start_cycle<=physical.cycle;
    // Test interconnect inserts two admission cycles per logical request.
    // Once opened, VALID remains presented until the downstream handshake;
    // gating READY alone would make the physical bridge accept ghost writes.
    logic admit=0, admission_age=0;
    logic fault_pending=0;
    integer fault_requests=0, fault_responses=0;
    wire gated_valid=base.mem_req_valid && admit;
    wire gated_ready=physical.mem_req_ready && admit;
    always @(posedge base.clk) begin
        if(!base.rst && base.mem_req_valid && gated_ready && base.inject_response_error)
            fault_requests<=fault_requests+1;
        if(!base.rst && fault_pending && physical.aw_held && physical.w_complete && !physical.committed)
            if(physical.fault !== 1'b1) $fatal(1,"fault injection lost before AXI commit");
        if(!base.rst && base.mem_rsp_valid && base.mem_rsp_ready && fault_pending) begin
            if(base.mem_rsp_error !== 1'b1 || fault_requests!=1 || fault_responses!=0)
                $fatal(1,"AXI write error missing or duplicated");
            fault_responses<=fault_responses+1;
            $display("C1_ADAPTER_PACKING_ERROR_PASS requests=1 responses=1");
        end
        if(base.rst) fault_pending<=0;
        else if(base.mem_req_valid && gated_ready && base.inject_response_error)
            fault_pending<=1;
        else if(base.mem_rsp_valid && base.mem_rsp_ready) fault_pending<=0;
        if(base.rst || !base.mem_req_valid || gated_ready) begin
            admit<=0; admission_age<=0;
        end else if(!admit) begin
            if(admission_age) admit<=1;
            else admission_age<=1;
        end
    end
    initial begin
        force physical.clk=base.clk;
        force physical.rst=base.rst;
        force physical.mem_req_valid=gated_valid;
        force physical.mem_req_write=base.mem_req_write;
        force physical.mem_req_addr=base.mem_req_addr;
        force physical.mem_req_wdata=base.mem_req_wdata;
        force physical.mem_req_wstrb=base.mem_req_wstrb;
        force physical.mem_req_end=base.dut.mem_req_end;
        force physical.mem_rsp_ready=base.mem_rsp_ready;
        force physical.hold_responses=base.hold_responses;
        force physical.fault=fault_pending;
        force base.mem_req_ready=gated_ready;
        force base.mem_rsp_valid=physical.mem_rsp_valid;
        force base.mem_rsp_error=physical.mem_rsp_error;
        force base.mem_rsp_rdata=physical.mem_rsp_rdata;
    end
    integer compared=0, frames=0;
    always @(negedge base.clk) if(!base.rst && base.adapter_done) begin
        if(physical.aw_held || physical.w_count!=0 || physical.b_valid_q ||
           base.response_count!=0 || base.dut.result_writes_pending_q!=0)
            $fatal(1,"adapter done before physical writes drained");
        for(integer word=0;word<384;word=word+1)
            for(integer lane=0;lane<8;lane=lane+1) begin
                if(physical.physical_mem[4096+word*8+lane] !== base.memory[word][lane*8+:8])
                    $fatal(1,"adapter/AXI memory mismatch word=%0d lane=%0d",word,lane);
                compared=compared+1;
            end
        frames=frames+1;
        if((PACKED_WRITES && physical.aws>=base.write_count) ||
           (!PACKED_WRITES && physical.aws!=base.write_count) || physical.aws!=physical.bs)
            $fatal(1,"adapter packing/drain coverage missing");
        $display("C1_ADAPTER_PACKING_MEMORY_PASS w_first=%0d end_marker=%0d frames=%0d bytes=%0d logical_writes=%0d aw=%0d w=%0d b=%0d reads=%0d",
                 W_FIRST,USE_END,frames,compared,base.write_count,physical.aws,physical.ws,physical.bs,physical.ars);
        $display("C1_ADAPTER_WRITE_LATENCY_PASS packed=%0d end_marker=%0d b_delay=%0d w_first=%0d job_cycles=%0d",
                 PACKED_WRITES,USE_END,B_RESPONSE_DELAY,W_FIRST,physical.cycle-job_start_cycle);
    end
endmodule
