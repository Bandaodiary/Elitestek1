`timescale 1ns/1ps
// Reuse the independent physical AXI byte memory, not a cache-aware responder.
module tb_c1_tensor_read_beat_cache #(
    parameter bit CACHE=1, parameter bit PACKED=0, parameter bit W_FIRST=0,
    parameter bit PRECISE=0, parameter integer ENTRIES=1
);
    tb_c1_tensor_packing_memory #(.EXTERNAL_DRIVER(1),.PACKED_WRITES(PACKED),
        .READ_BEAT_CACHE(CACHE),.READ_CACHE_ENTRIES(ENTRIES),
        .PRECISE_WRITE_INVALIDATION(PRECISE),.W_FIRST(W_FIRST),.USE_END(1)) m();
    integer checks=0, before_ar;
    logic [63:0] saved_data;

    function automatic logic [63:0] expected(input integer addr);
        for(integer lane=0;lane<8;lane++) expected[lane*8+:8]=m.expected_mem[addr+lane];
    endfunction
    task automatic read_checked(input integer addr,input integer axi_reads);
        integer n;
        begin
            n=m.ars; m.readback(addr);
            if(m.ars!=n+axi_reads) $fatal(1,"read cache AR count addr=%h expected_delta=%0d got=%0d",addr,axi_reads,m.ars-n);
            checks++;
        end
    endtask
    task automatic invalidate;
        @(negedge m.clk); m.read_cache_invalidate=1;
        @(negedge m.clk); m.read_cache_invalidate=0;
    endtask

    initial begin
        repeat(6) @(negedge m.clk);
        for(integer i=0;i<8192;i++) begin
            m.physical_mem[i]=8'(i ^ (i>>5)); m.expected_mem[i]=m.physical_mem[i];
        end
        m.rst=0; m.mem_req_end=1;
        read_checked('h100,1);
        read_checked('h108,CACHE ? 0 : 1);
        read_checked('h100,CACHE ? 0 : 1);
        read_checked('h128,1); // Upper half first must also populate lower half.
        read_checked('h120,CACHE ? 0 : 1);
        read_checked('h100,(CACHE && ENTRIES==2) ? 0 : 1);
        m.request(1,'h100,64'h123456789abcdef0,8'h55); m.response(0,0);
        read_checked('h108,1); read_checked('h100,CACHE ? 0 : 1);
        // The optional precise policy retains only unrelated aligned writes.
        m.request(1,'h200,64'hf0e0d0c0b0a09080,8'hff); m.response(0,0);
        read_checked('h100,(CACHE && PRECISE) ? 0 : 1);
        before_ar=m.ars;
        m.request(0,'h103,0,0); m.response(1,0);
        if(m.ars!=before_ar) $fatal(1,"misaligned cached read escaped to AXI");
        m.request(1,'h103,0,8'hff); m.response(1,0);
        read_checked('h100,1);
        // Both AXI error responses and malformed LAST must never fill cache.
        for(integer mode=0;mode<3;mode++) begin
            invalidate();
            m.m_axi_rresp=(mode==0) ? 2 : ((mode==1) ? 3 : 0);
            m.m_axi_rlast=(mode!=2);
            m.request(0,'h400,0,0); m.response(1,expected('h400));
            m.m_axi_rresp=0; m.m_axi_rlast=1;
            read_checked('h408,1); read_checked('h400,CACHE ? 0 : 1);
        end
        // Invalidate before a held AR transfers. Its eventual successful R
        // must complete the old request without installing a new cache entry.
        m.block_read_address=1;
        m.request(0,'h300,0,0);
        while(!m.m_axi_arvalid) @(negedge m.clk);
        invalidate(); repeat(3) @(negedge m.clk);
        m.block_read_address=0; m.response(0,expected('h300));
        read_checked('h308,1);

        // One pulse before R, then a separate case coincident with R handshake.
        // Memory is changed externally only AFTER the accepted read retires.
        for(integer same_edge=0;same_edge<2;same_edge++) begin
            invalidate(); m.hold_responses=1;
            m.request(0,'h500,0,0);
            while(!m.r_valid_q) @(negedge m.clk);
            saved_data=expected('h500);
            if(same_edge) begin
                m.read_cache_invalidate=1; m.hold_responses=0;
                @(negedge m.clk); m.read_cache_invalidate=0;
            end else begin
                invalidate(); repeat(3) @(negedge m.clk); m.hold_responses=0;
            end
            m.response(0,saved_data);
            for(integer lane=0;lane<16;lane++) begin
                m.physical_mem['h500+lane]=m.physical_mem['h500+lane]^8'h69;
                m.expected_mem['h500+lane]=m.physical_mem['h500+lane];
            end
            read_checked('h508,1); read_checked('h500,CACHE ? 0 : 1);
        end
        // A fence on the same acceptance edge disables a would-be hit and
        // prevents its replacement read from filling while the fence is high.
        before_ar=m.ars;
        fork
            begin
                // Assert with VALID, not a clock before the request task.
                @(negedge m.clk); m.read_cache_invalidate=1;
                for(integer lane=0;lane<16;lane++) begin
                    m.physical_mem['h500+lane]=m.physical_mem['h500+lane]^8'hb7;
                    m.expected_mem['h500+lane]=m.physical_mem['h500+lane];
                end
            end
            m.request(0,'h508,0,0);
        join
        m.read_cache_invalidate=0;
        m.response(0,expected('h508));
        if(m.ars!=before_ar+1) $fatal(1,"same-edge invalidation incorrectly allowed a cache hit");
        read_checked('h500,1);
        // An already presented cache-hit response is immutable under a fence.
        m.request(0,'h508,0,0);
        while(!m.mem_rsp_valid) @(negedge m.clk);
        saved_data=m.mem_rsp_rdata;
        invalidate();
        repeat(4) begin
            @(negedge m.clk);
            if(!m.mem_rsp_valid || m.mem_rsp_error || m.mem_rsp_rdata!==saved_data)
                $fatal(1,"invalidation changed held read response");
        end
        m.response(0,expected('h508));
        read_checked('h500,1);
        // Whole-domain reset is used only after all requests have retired.
        @(negedge m.clk); m.rst=1;
        repeat(3) @(negedge m.clk); m.rst=0;
        read_checked('h508,1);
        if(m.aws!=m.bs || m.mem_rsp_valid || m.r_valid_q || m.committed)
            $fatal(1,"read cache test did not drain physical ownership");
        if(checks!=24) $fatal(1,"read cache coverage count changed: %0d",checks);
        $display("C1_READ_BEAT_CACHE_PASS cache=%0d packed=%0d w_first=%0d precise=%0d checked_reads=%0d ar=%0d writes=%0d",
                 CACHE,PACKED,W_FIRST,PRECISE,checks,m.ars,m.aws);
        $finish;
    end
endmodule
