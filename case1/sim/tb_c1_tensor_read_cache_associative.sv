`timescale 1ns/1ps
// Independent physical AXI byte memory; it has no knowledge of cache ways.
module tb_c1_tensor_read_cache_associative #(
    parameter integer ENTRIES=2, WRITE_OUTSTANDING=1,
    parameter bit PACKED=0, W_FIRST=0, PRECISE=1
);
    tb_c1_tensor_packing_memory #(.EXTERNAL_DRIVER(1),.READ_BEAT_CACHE(1),
        .READ_CACHE_ENTRIES(ENTRIES),.PRECISE_WRITE_INVALIDATION(PRECISE),
        .PACKED_WRITES(PACKED),.W_FIRST(W_FIRST),.USE_END(1),
        .WRITE_OUTSTANDING(WRITE_OUTSTANDING)) m();
    integer checks=0, base_ar, residual_ar;
    logic [63:0] held;
    logic [31:0] query_addr;
    wire raw_match;
    function automatic logic [63:0] expected(input integer addr);
        for(integer lane=0;lane<8;lane++) expected[lane*8+:8]=m.expected_mem[addr+lane];
    endfunction
    task automatic read_checked(input integer addr,ar_delta);
        integer n;
        n=m.ars;m.readback(addr);
        if(m.ars-n!=ar_delta) $fatal(1,"associative read mismatch addr=%h AR=%0d expected=%0d",addr,m.ars-n,ar_delta);
        checks++;
    endtask
    task automatic fence;
        @(negedge m.clk);m.read_cache_invalidate=1;
        @(negedge m.clk);m.read_cache_invalidate=0;
    endtask
    task automatic warm_pair;
        fence();read_checked('h100,1);read_checked('h500,1);
    endtask
    task automatic modify_line(input integer addr,delta);
        for(integer lane=0;lane<16;lane++) begin
            m.physical_mem[addr+lane]=m.physical_mem[addr+lane]^8'(delta);
            m.expected_mem[addr+lane]=m.physical_mem[addr+lane];
        end
    endtask
    generate if(PACKED) begin
        assign raw_match=m.dut.g_packed.u_read.read_cache_addr_match;
        initial if(m.dut.g_packed.u_read.READ_BEAT_CACHE_ENTRIES!=ENTRIES)
            $fatal(1,"two-way test did not reach packed leaf");
    end else begin
        assign raw_match=m.dut.g_legacy.u_bridge.read_cache_addr_match;
        initial if(m.dut.g_legacy.u_bridge.READ_BEAT_CACHE_ENTRIES!=ENTRIES)
            $fatal(1,"two-way test did not reach legacy leaf");
    end endgenerate
    initial begin
        repeat(6) @(negedge m.clk);
        for(integer i=0;i<8192;i++) begin
            m.physical_mem[i]=8'(i^(i>>4)^(i>>8));m.expected_mem[i]=m.physical_mem[i];
        end
        m.rst=0;m.mem_req_end=1;
        warm_pair();
        for(integer base=0;base<2;base++) begin
            for(integer bit_index=4;bit_index<32;bit_index++) begin
                query_addr=(base==0?32'h100:32'h500)^(32'b1<<bit_index);
                m.mem_req_addr=query_addr;#1;
                if(raw_match!==((query_addr==32'h500) || (ENTRIES==2 && query_addr==32'h100)))
                    $fatal(1,"associative tag query ignored address bit %0d",bit_index);
            end
            for(integer offset=0;offset<16;offset++) begin
                m.mem_req_addr=(base==0?'h100:'h500)+offset;#1;
                if(raw_match!==((ENTRIES==2)||base==1)) $fatal(1,"associative raw tag query lost half-byte offset");
            end
        end
        read_checked('h108,ENTRIES==2?0:1);read_checked('h508,ENTRIES==2?0:1);
        read_checked('h100,ENTRIES==2?0:1); // A is MRU: C must replace B, not A.
        read_checked('h900,1);read_checked('h108,ENTRIES==2?0:1);
        read_checked('h500,1);read_checked('h900,1);
        $display("C1_SCALAR_ASSOC_LRU_PASS entries=%0d alternating_tags=1 hit_updates_lru=%0d tag_bits=28 offsets=16",ENTRIES,ENTRIES==2);

        // Keep both an interleaved write-pressure pattern and the actual
        // residual schedule: collect three A/B groups, then write three C
        // groups. Coarse invalidation retains reuse within the current pixel.
        for(integer batch=1;batch<=3;batch+=2) begin
            fence();base_ar=m.ars;
            for(integer word_base=0;word_base<24;word_base+=batch) begin
                for(integer group_index=0;group_index<batch;group_index++) begin
                    m.readback('h1000+(word_base+group_index)*8);
                    m.readback('h1800+(word_base+group_index)*8);
                end
                for(integer group_index=0;group_index<batch;group_index++) begin
                    m.request(1,'h800+(word_base+group_index)*8,
                              64'h1234abcdef678900^(word_base+group_index),8'hff);
                    m.response(0,0);
                end
            end
            residual_ar=m.ars-base_ar;
            if(residual_ar!=(ENTRIES==1?48:(PRECISE?24:(batch==3?32:48))))
                $fatal(1,"residual cache physical AR budget mismatch batch=%0d AR=%0d",batch,residual_ar);
            if(batch==3)
                $display("C1_SCALAR_ASSOC_RESIDUAL_PASS entries=%0d precise=%0d words=24 reads=48 writes=24 ar=%0d",ENTRIES,PRECISE,residual_ar);
            else
                $display("C1_SCALAR_ASSOC_GROUP_WRITE_PASS entries=%0d precise=%0d words=24 reads=48 writes=24 ar=%0d",ENTRIES,PRECISE,residual_ar);
        end

        // An unrelated write may retain BOTH entries. A hit in either tag
        // must instead invalidate all entries, independent of WSTRB, AW/W order.
        for(integer target=0;target<3;target++) begin
            warm_pair();
            m.request(1,target==0?'h700:(target==1?'h108:'h508),
                      64'hcafebabedeadbeef,target==1?8'h00:8'h5a);m.response(0,0);
            read_checked('h100,(PRECISE && ENTRIES==2 && target==0)?0:1);
            read_checked('h500,(PRECISE && ENTRIES==2 && target==0)?0:1);
        end
        warm_pair();m.request(1,'h703,0,8'hff);m.response(1,0);
        read_checked('h100,1);read_checked('h500,1);

        // A possible two-way HIT cannot bypass an earlier physical B or its
        // logical retirement. Attempt the read while B is really withheld.
        warm_pair();base_ar=m.ars;m.hold_responses=1;
        m.request(1,'h700,64'hfedcba9876543210,8'hff);
        while(!m.b_valid_q) @(negedge m.clk);
        if(PACKED && WRITE_OUTSTANDING>1)
            m.request(1,'h710,64'h1020304050607080,8'hff);
        fork
            m.request(0,'h108,0,0);
            begin
                // Before the read is presented, READY may legally advertise
                // room for another packed write. Qualify the held-read check.
                wait(m.mem_req_valid && !m.mem_req_write);
                repeat(10) begin @(posedge m.clk);#1;
                    if(m.mem_req_ready || m.mem_rsp_valid || m.m_axi_arvalid)
                        $fatal(1,"cached read overtook real B or logical write retirement");
                end
                @(negedge m.clk);m.hold_responses=0;m.response(0,0);
                if(PACKED && WRITE_OUTSTANDING>1) begin
                    if(m.mem_req_ready) $fatal(1,"cached read overtook second logical write");
                    m.response(0,0);
                end
            end
        join
        m.response(0,expected('h108));
        if(m.ars-base_ar!=((ENTRIES==2 && PRECISE)?0:1))
            $fatal(1,"post-B read lost expected cache behavior");
        $display("C1_SCALAR_ASSOC_B_FENCE_PASS held_cycles=10 physical_and_logical=1 entries=%0d logical_writes=%0d",ENTRIES,(PACKED && WRITE_OUTSTANDING>1)?2:1);
        for(integer error_code=1;error_code<=3;error_code++) begin
            warm_pair();m.hold_responses=1;
            m.request(1,'h700,64'h2468013579abcdef,8'hff);
            while(!m.b_valid_q) @(negedge m.clk);
            // The byte-memory BFM chooses BRESP when committing the write.
            // Inject only after that scheduling edge, before exposing BVALID.
            m.m_axi_bresp=2'(error_code);m.hold_responses=0;m.response(1,0);m.m_axi_bresp=0;
            read_checked('h100,1);read_checked('h500,1);
        end

        // R errors and malformed single-beat LAST cannot preserve another
        // old entry as an accidental recovery cache, nor install the bad beat.
        for(integer mode=0;mode<4;mode++) begin
            warm_pair();m.m_axi_rresp=mode<3?2'(mode+1):2'b00;m.m_axi_rlast=mode!=3;
            m.request(0,'h900,0,0);m.response(1,expected('h900));
            m.m_axi_rresp=0;m.m_axi_rlast=1;
            read_checked('h100,1);read_checked('h500,1);read_checked('h908,1);
        end

        // Fence while a replacement miss is held: invalidate every way and
        // latch late-fill suppression. Old response must still be delivered.
        warm_pair();m.block_read_address=1;m.request(0,'h900,0,0);
        while(!m.m_axi_arvalid) @(negedge m.clk);
        fence();repeat(4) @(negedge m.clk);
        m.block_read_address=0;m.response(0,expected('h900));
        modify_line('h100,'h21);modify_line('h500,'h42);modify_line('h900,'h84);
        read_checked('h100,1);read_checked('h500,1);read_checked('h900,1);
        read_checked('h908,0);

        // Already presented hit response is immutable while a fence invalidates
        // both ways. Alternate target to exercise each physical way.
        for(integer target=0;target<2;target++) begin
            warm_pair();base_ar=m.ars;
            m.request(0,target==0?'h108:'h508,0,0);
            while(!m.mem_rsp_valid) @(negedge m.clk);
            held=m.mem_rsp_rdata;fence();
            repeat(7) begin @(negedge m.clk);
                if(!m.mem_rsp_valid || m.mem_rsp_error || m.mem_rsp_rdata!==held)
                    $fatal(1,"two-way fence changed held response");
            end
            m.response(0,held);
            if(m.ars-base_ar!=((ENTRIES==2 || target==1)?0:1))
                $fatal(1,"held response was not the expected hit");
            modify_line('h100,'h13);modify_line('h500,'h31);
            read_checked('h100,1);read_checked('h500,1);
        end
        if(m.aws!=m.bs || m.mem_rsp_valid || m.r_valid_q || m.committed)
            $fatal(1,"associative cache reset attempted with live ownership");
        @(negedge m.clk);m.rst=1;repeat(3) @(negedge m.clk);m.rst=0;
        read_checked('h100,1);read_checked('h500,1);
        for(integer addr=0;addr<8192;addr++)
            if(m.physical_mem[addr]!==m.expected_mem[addr]) $fatal(1,"associative physical byte memory mismatch");
        $display("C1_SCALAR_ASSOC_CACHE_PASS entries=%0d packed=%0d precise=%0d w_first=%0d writes_outstanding=%0d checks=%0d errors=1 fences=1 no_posted_ack=1",
                 ENTRIES,PACKED,PRECISE,W_FIRST,WRITE_OUTSTANDING,checks);
        $finish;
    end
    initial begin #2000000;$fatal(1,"associative cache test timeout");end
endmodule
