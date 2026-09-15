`timescale 1ns/1ps
// Address-aware invalidation against an independent physical byte memory.
module tb_c1_tensor_read_cache_invalidation #(
    parameter bit PRECISE=1, parameter bit PACKED=0, parameter bit W_FIRST=0,
    parameter integer ENTRIES=1
);
    tb_c1_tensor_packing_memory #(.EXTERNAL_DRIVER(1),.READ_BEAT_CACHE(1),
        .READ_CACHE_ENTRIES(ENTRIES),
        .PRECISE_WRITE_INVALIDATION(PRECISE),.PACKED_WRITES(PACKED),
        .W_FIRST(W_FIRST),.USE_END(1)) m();
    integer masks=0, probes=0, before_ar, before_aw;
    wire raw_match;
    generate if(PACKED) begin
        assign raw_match=m.dut.g_packed.u_read.read_cache_addr_match;
    end else begin
        assign raw_match=m.dut.g_legacy.u_bridge.read_cache_addr_match;
    end endgenerate
    function automatic logic [63:0] expected(input integer address);
        for(integer lane=0;lane<8;lane++) expected[lane*8+:8]=m.expected_mem[address+lane];
    endfunction
    task automatic read_checked(input integer address,input integer delta);
        integer n;
        n=m.ars; m.readback(address);
        if(m.ars!=n+delta) $fatal(1,"precise invalidate AR mismatch address=%h delta=%0d actual=%0d",address,delta,m.ars-n);
        probes++;
    endtask
    task automatic warm;
        @(negedge m.clk); m.read_cache_invalidate=1;
        @(negedge m.clk); m.read_cache_invalidate=0;
        read_checked('h100,1);
    endtask
    initial begin
        repeat(6) @(negedge m.clk);
        for(integer i=0;i<8192;i++) begin
            m.physical_mem[i]=8'(i^(i>>5)); m.expected_mem[i]=m.physical_mem[i];
        end
        m.rst=0; m.mem_req_end=1;
        // No bus transaction: prove the snoop compares all 28 tag bits and
        // ignores only the 16-byte lane offset. Also exercise the query while
        // invalidate is asserted, before its clock edge clears the valid bit.
        warm();
        for(integer offset=0;offset<16;offset++) begin
            m.mem_req_addr='h100+offset; #1;
            if(raw_match!==1'b1) $fatal(1,"raw cache query did not match same line");
        end
        for(integer tag_bit=4;tag_bit<32;tag_bit++) begin
            m.mem_req_addr=32'h100^(32'h1<<tag_bit); #1;
            if(raw_match!==1'b0) $fatal(1,"raw cache query ignored tag bit %0d",tag_bit);
        end
        @(negedge m.clk); m.mem_req_addr='h100; m.read_cache_invalidate=1; #1;
        if(raw_match!==1'b1) $fatal(1,"raw snoop incorrectly depends on invalidate input");
        @(negedge m.clk); m.read_cache_invalidate=0;
        $display("C1_PRECISE_TAG_QUERY_PASS tag_bits=28 offsets=16 raw_during_fence=1");
        // Full 128-bit tag comparison, not byte strobes or the selected half:
        // both halves, all 256 masks, same line and adjacent unrelated line.
        for(integer unrelated=0;unrelated<2;unrelated++)
            for(integer half=0;half<2;half++)
                for(integer mask=0;mask<256;mask++) begin
                    warm();
                    m.request(1,'h100+unrelated*16+half*8,64'hfe0123456789abcd ^ mask,8'(mask));
                    m.response(0,0);
                    read_checked('h100,(PRECISE && unrelated) ? 0 : 1);
                    read_checked('h108,0);
                    masks++;
                end
        // Different higher tag bits with identical low address bits.
        for(integer bit_index=5;bit_index<=12;bit_index++) begin
            warm();
            m.request(1,'h100^(1<<bit_index),64'h9876543210123456,8'hff); m.response(0,0);
            read_checked('h108,PRECISE ? 0 : 1);
        end
        // A local alignment rejection still clears the entry, even unrelated.
        for(integer address='h103;address<='h203;address+='h100) begin
            warm(); before_aw=m.aws;
            m.request(1,address,0,8'hff); m.response(1,0);
            if(m.aws!=before_aw) $fatal(1,"misaligned write escaped to AXI");
            read_checked('h100,1);
        end
        // Every non-OKAY B must clear a retained unrelated read line. This BFM
        // physically commits strobes even on error: never assume no write.
        for(integer error_code=1;error_code<=3;error_code++) begin
            warm(); m.fault=1;
            m.request(1,'h210,64'hf1e2d3c4b5a69788,8'h55);
            while(!m.committed) @(negedge m.clk);
            m.m_axi_bresp=2'(error_code);
            m.response(1,0); m.fault=0;
            read_checked('h100,1);
        end
        // An unconditional owner fence wins over an unrelated write snoop.
        warm();
        fork
            begin @(negedge m.clk); m.read_cache_invalidate=1; end
            m.request(1,'h210,64'hddccbbaa99887766,8'hff);
        join
        m.read_cache_invalidate=0; m.response(0,0);
        read_checked('h100,1);

        // A possible hit may not be admitted before the real B and logical
        // write acknowledgement retire. Keep read VALID through that fence.
        warm(); before_ar=m.ars; m.hold_responses=1;
        m.request(1,'h210,64'h1020304050607080,8'hff);
        while(!m.b_valid_q) @(negedge m.clk);
        m.mem_req_valid=1; m.mem_req_write=0; m.mem_req_addr='h100; m.mem_req_wstrb=0;
        repeat(7) begin
            @(negedge m.clk);
            if(m.mem_req_ready || m.m_axi_arvalid || m.mem_rsp_valid) $fatal(1,"cached read crossed held B fence");
        end
        m.hold_responses=0; m.response(0,0);
        do @(posedge m.clk); while(!m.mem_req_ready);
        @(negedge m.clk); m.mem_req_valid=0;
        m.response(0,expected('h100));
        if(m.ars!=before_ar+(PRECISE ? 0 : 1)) $fatal(1,"post-write cached read count mismatch");

        // Conversely, an unrelated write cannot enter while a read/fill or
        // its logical response is still owned by the read bridge.
        warm(); m.read_cache_invalidate=1;
        @(negedge m.clk); m.read_cache_invalidate=0; m.hold_responses=1;
        m.request(0,'h100,0,0);
        while(!m.r_valid_q) @(negedge m.clk);
        fork
            m.request(1,'h210,64'h1234123412341234,8'hff);
            begin
                repeat(7) begin
                    @(negedge m.clk);
                    if(m.mem_req_ready || m.m_axi_awvalid || m.m_axi_wvalid) $fatal(1,"write snoop raced pending read fill");
                end
                m.hold_responses=0; m.response(0,expected('h100));
            end
        join
        m.response(0,0);
        read_checked('h100,PRECISE ? 0 : 1);
        if(PACKED) begin
            // Clearing on a matching accepted write must survive later
            // unrelated queued writes; reversing their order is also safe.
            for(integer reverse_order=0;reverse_order<2;reverse_order++) begin
                warm(); m.mem_req_end=0;
                m.request(1,reverse_order ? 'h108 : 'h210,64'h1122334455667788,8'hf0);
                m.mem_req_end=1;
                m.request(1,reverse_order ? 'h210 : 'h108,64'h8877665544332211,8'h0f);
                repeat(2) m.response(0,0);
                read_checked('h100,1); read_checked('h108,0);
            end
        end
        if(m.aws!=m.bs || m.mem_rsp_valid || m.r_valid_q || m.committed)
            $fatal(1,"precise invalidation test left pending physical transactions");
        for(integer address=0;address<8192;address++)
            if(m.physical_mem[address]!==m.expected_mem[address])
                $fatal(1,"physical byte memory mismatch after invalidation tests addr=%h",address);
        if(masks!=1024) $fatal(1,"incomplete strobe/address coverage");
        $display("C1_PRECISE_INVALIDATION_PASS precise=%0d packed=%0d w_first=%0d masks=%0d read_probes=%0d aw=%0d b=%0d",
            PRECISE,PACKED,W_FIRST,masks,probes,m.aws,m.bs);
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1,"precise invalidation test timeout");
    end
endmodule
