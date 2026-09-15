`timescale 1ns/1ps
module tb_c1_tensor_packing_memory #(
    parameter integer W_FIRST=0, parameter integer EXTERNAL_DRIVER=0,
    parameter integer USE_END=0, parameter integer PACKED_WRITES=1,
    parameter integer B_RESPONSE_DELAY=12,
    parameter bit READ_BEAT_CACHE=0, parameter bit PRECISE_WRITE_INVALIDATION=0,
    parameter integer READ_CACHE_ENTRIES=1,
    parameter integer WRITE_BUILD_TIMEOUT=8, WRITE_OUTSTANDING=1
);
    initial begin
        if(B_RESPONSE_DELAY<0) $fatal(1,"B response delay must be nonnegative");
        if(!EXTERNAL_DRIVER && !PACKED_WRITES)
            $fatal(1,"standalone queued stimulus requires packing; use the external adapter driver for legacy comparison");
    end
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic mem_req_valid=0, mem_req_ready, mem_req_write=0;
    logic [31:0] mem_req_addr=0;
    logic [63:0] mem_req_wdata=0;
    logic [7:0] mem_req_wstrb=0;
    logic mem_req_end=0;
    logic read_cache_invalidate=0, block_read_address=0;
    logic mem_rsp_valid, mem_rsp_ready=0, mem_rsp_error;
    logic [63:0] mem_rsp_rdata;
    logic [31:0] m_axi_awaddr, m_axi_araddr;
    logic [7:0] m_axi_awlen, m_axi_arlen;
    logic [2:0] m_axi_awsize, m_axi_arsize;
    logic [1:0] m_axi_awburst, m_axi_arburst;
    logic m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_wlast;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    wire m_axi_bvalid;
    logic b_valid_q=0, m_axi_bready;
    logic [1:0] m_axi_bresp=0;
    logic m_axi_arvalid, m_axi_arready, m_axi_rready;
    wire m_axi_rvalid;
    logic r_valid_q=0;
    logic hold_responses=0;
    assign m_axi_bvalid=b_valid_q && !hold_responses;
    assign m_axi_rvalid=r_valid_q && !hold_responses;
    logic [127:0] m_axi_rdata=0;
    logic [1:0] m_axi_rresp=0;
    logic m_axi_rlast=1;
    c1_tensor_mem_axi128_packing_bridge #(.ENABLE_PACKED_WRITES(PACKED_WRITES),.USE_WRITE_END(USE_END),
        .WRITE_BUILD_TIMEOUT(WRITE_BUILD_TIMEOUT),.WRITE_OUTSTANDING(WRITE_OUTSTANDING),
        .ENABLE_READ_BEAT_CACHE(READ_BEAT_CACHE),
        .READ_BEAT_CACHE_ENTRIES(READ_CACHE_ENTRIES),
        .PRECISE_WRITE_INVALIDATION(PRECISE_WRITE_INVALIDATION)) dut(.*);

    // Independent physical byte memory, never written by logical requests.
    byte unsigned physical_mem[0:8191], expected_mem[0:8191];
    logic aw_held=0, w_complete=0, committed=0;
    logic [31:0] aw_base;
    integer aw_beats, w_count=0, b_delay=0, cycle=0;
    logic [127:0] held_wdata[0:3];
    logic [15:0] held_wstrb[0:3];
    logic fault=0;
    integer aws=0, ws=0, bs=0, ars=0, commits=0, w_before_aw=0;
    integer end_start_seen=0, end_same_seen=0, end_next_seen=0;
    integer end_direct_seen=0;
    integer logical_writes_seen=0, local_errors_seen=0;
    always @(posedge clk) if(!rst && mem_req_valid && mem_req_ready && mem_req_write) begin
        logical_writes_seen++;
        if(mem_req_addr[2:0]!=0) local_errors_seen++;
    end
    // Independent latency requirement: consuming an aligned terminal FIFO
    // item commits a complete registered descriptor immediately. The existing
    // physical byte scoreboard below still checks its contents and responses.
    generate if(USE_END && PACKED_WRITES && WRITE_OUTSTANDING==1) begin : g_end_dispatch_check
        always @(posedge clk) if(!rst &&
            (dut.g_packed.g_serial.u_write.build_start || dut.g_packed.g_serial.u_write.build_append) &&
            dut.g_packed.g_serial.u_write.q_head_aligned_ok &&
            dut.g_packed.g_serial.u_write.q_head_end) begin
            if(dut.g_packed.g_serial.u_write.direct_start) begin
                end_direct_seen++;
                if(!mem_req_ready || !mem_req_valid || !mem_req_write ||
                   dut.g_packed.g_serial.u_write.req_count_q!=0 || dut.g_packed.g_serial.u_write.req_pop ||
                   dut.g_packed.g_serial.u_write.req_fifo_push)
                    $fatal(1,"direct descriptor intake violated empty FIFO ownership");
            end
            if(dut.g_packed.g_serial.u_write.build_start) end_start_seen++;
            else if(dut.g_packed.g_serial.u_write.same_beat) end_same_seen++;
            else end_next_seen++;
            #1;
            if(!m_axi_awvalid || !m_axi_wvalid || dut.g_packed.g_serial.u_write.state_q!=2)
                $fatal(1,"terminal FIFO request incurred a redundant BUILD cycle");
        end
    end endgenerate
    bit aw_stalled=0, w_stalled=0, ar_stalled=0;
    logic [44:0] saved_aw, saved_ar;
    logic [144:0] saved_w;
    always @(posedge clk) begin
        if(rst) begin aw_stalled<=0; w_stalled<=0; ar_stalled<=0; end
        else begin
            if(aw_stalled && (!m_axi_awvalid ||
                {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst} !== saved_aw))
                $fatal(1,"packed AW changed while stalled");
            if(w_stalled && (!m_axi_wvalid ||
                {m_axi_wdata,m_axi_wstrb,m_axi_wlast} !== saved_w))
                $fatal(1,"packed W changed while stalled");
            if(ar_stalled && (!m_axi_arvalid ||
                {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst} !== saved_ar))
                $fatal(1,"packed AR changed while stalled");
            aw_stalled<=m_axi_awvalid && !m_axi_awready;
            w_stalled<=m_axi_wvalid && !m_axi_wready;
            ar_stalled<=m_axi_arvalid && !m_axi_arready;
            saved_aw<={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            saved_w<={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            saved_ar<={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
        end
    end
    assign m_axi_awready=!rst && !aw_held && !m_axi_bvalid &&
                         (!W_FIRST || w_complete) && cycle%5!=1;
    assign m_axi_wready=!rst && !w_complete && !m_axi_bvalid &&
                        (W_FIRST || aw_held) && cycle%4!=2;
    assign m_axi_arready=!rst && !block_read_address && !r_valid_q && cycle%3!=1;
    always @(posedge clk) if(!rst) begin
        cycle<=cycle+1;
        if(m_axi_awvalid && m_axi_awready) begin
            if(m_axi_awsize!=4 || m_axi_awburst!=1 || m_axi_awaddr[3:0]!=0 ||
               m_axi_awlen>3 || m_axi_awaddr+16*(m_axi_awlen+1)>8192 ||
               m_axi_awaddr[31:12] != ((m_axi_awaddr+16*(m_axi_awlen+1)-1)>>12))
                $fatal(1,"bad packed AW or crossed 4 KiB");
            aw_held<=1; aw_base<=m_axi_awaddr; aw_beats<=m_axi_awlen+1; aws<=aws+1;
        end
        if(m_axi_wvalid && m_axi_wready) begin
            if(w_count>=4) $fatal(1,"too many packed W beats");
            held_wdata[w_count]<=m_axi_wdata; held_wstrb[w_count]<=m_axi_wstrb;
            w_count<=w_count+1; ws<=ws+1;
            if(!aw_held) w_before_aw<=w_before_aw+1;
            if(m_axi_wlast) w_complete<=1;
        end
        if(aw_held && w_complete && !committed) begin
            if(w_count!=aw_beats) $fatal(1,"AWLEN/WLAST mismatch");
            for(integer beat=0;beat<w_count;beat=beat+1)
                for(integer lane=0;lane<16;lane=lane+1)
                    if(held_wstrb[beat][lane])
                        physical_mem[aw_base+beat*16+lane]<=held_wdata[beat][lane*8+:8];
            committed<=1; b_delay<=B_RESPONSE_DELAY; commits<=commits+1;
            m_axi_bresp<=fault ? 2'b10 : 2'b00;
        end
        if(committed && !b_valid_q) begin
            if(b_delay==0) b_valid_q<=1;
            else b_delay<=b_delay-1;
        end
        if(m_axi_bvalid && m_axi_bready) begin
            bs<=bs+1; b_valid_q<=0; committed<=0; aw_held<=0;
            w_complete<=0; w_count<=0;
        end
        if(m_axi_arvalid && m_axi_arready) begin
            if(aw_held || w_count!=0 || m_axi_bvalid || m_axi_arlen!=0 ||
               m_axi_arsize!=4 || m_axi_arburst!=1 || m_axi_araddr[3:0]!=0)
                $fatal(1,"read crossed physical write fence or malformed AR");
            for(integer lane=0;lane<16;lane=lane+1)
                m_axi_rdata[lane*8+:8]<=physical_mem[m_axi_araddr+lane];
            r_valid_q<=1; ars<=ars+1;
        end
        if(m_axi_rvalid && m_axi_rready) r_valid_q<=0;
    end

    task automatic request(input bit wr,input integer addr,input logic [63:0] data,input logic [7:0] strb);
        begin
            @(negedge clk);
            mem_req_valid=1; mem_req_write=wr; mem_req_addr=addr;
            mem_req_wdata=data; mem_req_wstrb=strb;
            do @(posedge clk); while(!mem_req_ready);
            if(wr && (addr%8==0))
                for(integer lane=0;lane<8;lane=lane+1)
                    if(strb[lane]) expected_mem[addr+lane]=data[lane*8+:8];
            @(negedge clk); mem_req_valid=0;
        end
    endtask
    task automatic response(input bit error_expected,input logic [63:0] data_expected);
        begin
            while(!mem_rsp_valid) @(negedge clk);
            repeat(3) begin
                @(negedge clk);
                if(!mem_rsp_valid || mem_rsp_error!=error_expected || mem_rsp_rdata!==data_expected)
                    $fatal(1,"logical response/data changed or wrong addr=%h write=%b valid=%b error=%b/%b data=%h/%h",
                           mem_req_addr,mem_req_write,mem_rsp_valid,mem_rsp_error,error_expected,mem_rsp_rdata,data_expected);
            end
            mem_rsp_ready=1;
            @(posedge clk);
            @(negedge clk); mem_rsp_ready=0;
        end
    endtask
    task automatic readback(input integer addr);
        logic [63:0] expected;
        begin
            for(integer lane=0;lane<8;lane=lane+1) expected[lane*8+:8]=expected_mem[addr+lane];
            request(0,addr,0,0); response(0,expected);
        end
    endtask
    integer aw_before;
    initial begin
        for(integer i=0;i<8192;i=i+1) begin
            physical_mem[i]=EXTERNAL_DRIVER ? 0 : 8'ha6;
            expected_mem[i]=EXTERNAL_DRIVER ? 0 : 8'ha6;
        end
    end
    generate if (!EXTERNAL_DRIVER) begin : g_standalone
    initial begin
        repeat(6) @(negedge clk); rst=0;
        // Upper lane first, cross 0x1000, then continue past a 4-beat burst.
        for(integer i=0;i<12;i=i+1) begin
            mem_req_end=(i==11);
            request(1,32'hff8+i*8,64'h1020304050607080+i,8'hff);
        end
        // Present a read early, holding VALID through the entire logical
        // write-response drain. It must not be admitted merely because B
        // has arrived for one of the physical bursts.
        @(negedge clk);
        mem_req_valid=1; mem_req_write=0; mem_req_addr=32'hff8; mem_req_wstrb=0;
        repeat(5) begin
            @(negedge clk);
            if(mem_req_ready || m_axi_arvalid) $fatal(1,"early read escaped write fence");
        end
        for(integer i=0;i<12;i=i+1) begin
            response(0,0);
            if(i<11 && mem_req_ready) $fatal(1,"read admitted before final write acknowledgement");
        end
        do @(posedge clk); while(!mem_req_ready);
        @(negedge clk); mem_req_valid=0;
        response(0,64'h1020304050607080);
        if(aws>=12 || ws>=12 || aws<3) $fatal(1,"missing packing or boundary splitting");
        for(integer i=0;i<12;i=i+1) readback(32'hff8+i*8);
        // Partial strobes and repeated writes to the same lane must preserve
        // byte order, including two different values that cannot be merged.
        // Deliberately omit the marker: finite timeout still drains a partial
        // batch, as required when an adapter is canceled before its last group.
        mem_req_end=0;
        request(1,32'h1000,64'hffeeddccbbaa9988,8'h55);
        request(1,32'h1000,64'h0123456789abcdef,8'h3f);
        request(1,32'h1008,64'h9876543210abcdef,8'h0f);
        repeat(3) response(0,0);
        readback(32'h1000); readback(32'h1008);
        if(USE_END) begin
            // Two adjacent writes explicitly end different batches. The end
            // bit must stay with its FIFO entry, not flush an earlier prefix.
            aw_before=aws; mem_req_end=1;
            request(1,32'h1200,64'habcdef0123456789,8'hff);
            request(1,32'h1208,64'h5555aaaa99996666,8'hff);
            response(0,0); response(0,0);
            if(aws!=aw_before+2) $fatal(1,"queued batch end was lost or crossed");
            readback(32'h1200); readback(32'h1208);
        end
        // Local rejection must produce no physical write transaction.
        aw_before=aws; request(1,32'h1003,64'd1,8'hff); response(1,0);
        if(aws!=aw_before) $fatal(1,"misaligned request issued AXI");
        fault=1;
        mem_req_end=0;
        request(1,32'h1100,64'h1111222233334444,8'hff);
        mem_req_end=1;
        request(1,32'h1108,64'h5555666677778888,8'hff);
        response(1,0); response(1,0); fault=0;
        // BRESP error does not imply rollback. This BFM committed the writes.
        readback(32'h1100); readback(32'h1108);
        // Every byte mask on both halves, with both logical arrival orders.
        // Change data on every iteration so an incorrectly preserved/written
        // byte cannot hide behind a value left by the previous transaction.
        for(integer order=0;order<2;order++) begin
            for(integer mask=0;mask<256;mask++) begin
                mem_req_end=0;
                request(1,order ? 32'h1308 : 32'h1300,
                    64'h1032547698badcfe ^ {8{8'(mask)}},8'(mask));
                mem_req_end=1;
                request(1,order ? 32'h1300 : 32'h1308,
                    64'hefcdab8967452301 ^ {8{8'(mask)}},~8'(mask));
                response(0,0);response(0,0);
                readback(32'h1300);readback(32'h1308);
            end
        end
        $display("C1_PACKING_WSTRB_MATRIX_PASS masks=256 lane_orders=2 logical_writes=1024");
        if(USE_END) begin
            // Exercise the idle direct-intake mux with every strobe and both
            // address halves, not just the full-strobe first request above.
            for(integer half=0;half<2;half++) begin
                for(integer mask=0;mask<256;mask++) begin
                    mem_req_end=1;
                    request(1,32'h1400+8*half,
                        64'h89abcdef01234567 ^ {8{8'(mask)}} ^ half,8'(mask));
                    response(0,0); readback(32'h1400+8*half);
                end
            end
            if(end_direct_seen<513) $fatal(1,"direct write mask coverage missing");
            // Older responses may fill the FIFO while the request side is
            // empty. The ninth direct descriptor must preserve them and hold
            // B until real response capacity is released; no posted ACK.
            for(integer item=0;item<8;item++) begin
                mem_req_end=1;
                request(1,32'h1500+item*8,64'h9988776655443300+item,8'hff);
                while(dut.g_packed.g_serial.u_write.rsp_count_q!=item+1) @(negedge clk);
            end
            if(dut.g_packed.g_serial.u_write.state_q!=0 || dut.g_packed.g_serial.u_write.req_count_q!=0)
                $fatal(1,"response-full direct-intake precondition missing");
            aw_before=bs;
            request(1,32'h1540,64'hfedcba9876543210,8'hff);
            while(!m_axi_bvalid) @(negedge clk);
            repeat(6) begin
                @(negedge clk);
                if(m_axi_bready || bs!=aw_before || dut.g_packed.g_serial.u_write.rsp_count_q!=8)
                    $fatal(1,"direct descriptor overran older held responses");
            end
            repeat(9) response(0,0);
            for(integer item=0;item<9;item++) readback(32'h1500+item*8);
            $display("C1_DIRECT_END_MATRIX_PASS masks=256 halves=2 full_rsp_fifo=8 held_b=6");
            if(end_start_seen<2 || end_same_seen<512 || end_next_seen==0 || end_direct_seen==0)
                $fatal(1,"terminal dispatch branch coverage missing start=%0d same=%0d next=%0d",
                    end_start_seen,end_same_seen,end_next_seen);
            $display("C1_END_DISPATCH_PASS start=%0d same_beat=%0d next_beat=%0d direct=%0d",
                end_start_seen,end_same_seen,end_next_seen,end_direct_seen);
        end
        for(integer i=0;i<8192;i=i+1)
            if(physical_mem[i]!==expected_mem[i]) $fatal(1,"independent byte memory mismatch addr=%h",i);
        if(aws!=bs || commits!=bs || (W_FIRST && w_before_aw==0))
            $fatal(1,"AXI drain/order coverage missing");
        if(dut.g_packed.g_serial.u_write.perf_req_accept_count!=logical_writes_seen ||
           dut.g_packed.g_serial.u_write.perf_rsp_count!=logical_writes_seen ||
           dut.g_packed.g_serial.u_write.perf_axi_burst_count!=aws ||
           dut.g_packed.g_serial.u_write.perf_axi_beat_count!=ws ||
           dut.g_packed.g_serial.u_write.perf_packed_request_count!=logical_writes_seen-local_errors_seen-ws ||
           dut.g_packed.g_serial.u_write.perf_error_count!=3 || dut.g_packed.g_serial.u_write.perf_busy)
            $fatal(1,"physical/logical write conservation or packing statistics mismatch");
        $display("C1_PACKING_CONSERVATION_PASS accepted=%0d local_errors=%0d packed_saved=%0d",
            logical_writes_seen,local_errors_seen,logical_writes_seen-local_errors_seen-ws);
        $display("C1_PACKING_MEMORY_PASS w_first=%0d end_marker=%0d aw=%0d w=%0d b=%0d reads=%0d bytes=8192",W_FIRST,USE_END,aws,ws,bs,ars);
        $finish;
    end
    end endgenerate
    initial begin #10000000; $fatal(1,"packing memory timeout"); end
endmodule
