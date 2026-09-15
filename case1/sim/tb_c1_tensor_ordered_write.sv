`timescale 1ns/1ps
module tb_c1_tensor_ordered_write #(parameter integer SLOTS=2, parameter bit DEPENDENT_AW=0, USE_END=1);
    logic clk=0,rst=1;always #5 clk=~clk;
    logic req_valid=0,req_ready,req_flush=0,req_end=0;
    logic [31:0] req_addr=0;logic [63:0] req_wdata=0;logic [7:0] req_wstrb=0;
    logic rsp_valid,rsp_ready=1,rsp_error;logic [63:0] rsp_rdata;
    logic [31:0] m_axi_awaddr;logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;logic [1:0] m_axi_awburst;
    logic m_axi_awvalid,m_axi_awready,m_axi_wvalid,m_axi_wready,m_axi_wlast;
    logic [127:0] m_axi_wdata;logic [15:0] m_axi_wstrb;
    logic m_axi_bvalid=0,m_axi_bready;logic [1:0] m_axi_bresp=0;
    logic perf_busy;logic [7:0] perf_outstanding,perf_max_outstanding;
    bit hold_b=0,hold_aw=0,hold_w=0;
    integer cycle=0,accepted=0,responses=0,aws=0,ws=0,bs=0,completed=0,commit_word=0,commit_beat=0;
    integer errors=0,physical_peak=0,w_before_aw=0,bursts_multi=0;
    logic [31:0] aw_addr[0:1023];integer aw_beats[0:1023],b_due[0:1023];
    logic [127:0] w_data[0:2047];logic [15:0] w_strb[0:2047];logic w_last[0:2047];
    logic [63:0] expected_data[0:2047];logic expected_error[0:2047];
    byte unsigned physical[0:65535],expected[0:65535];
    logic aw_held=0,w_held=0;logic [44:0] aw_saved;logic [144:0] w_saved;
    c1_tensor_mem_axi128_ordered_write_client #(.MAX_OUTSTANDING(SLOTS),.BURST_BEATS(4),
        .BUILD_TIMEOUT_CYCLES(8),.USE_REQUEST_END(USE_END)) dut(.*);
    assign m_axi_awready=!rst && !hold_aw && cycle%7!=2 && (!DEPENDENT_AW || m_axi_wvalid || ws>commit_word);
    assign m_axi_wready=!rst && !hold_w && cycle%5!=1;

    // AW and W are captured independently. Memory is touched ONLY after
    // both channels identify the next ordered beat, never on a logical req.
    always @(posedge clk) begin : scoreboard
        integer address;
        cycle++;
        if(!rst) begin
            if(aw_held && (!m_axi_awvalid || {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst}!==aw_saved))
                $fatal(1,"ordered AW changed under backpressure");
            if(w_held && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==w_saved))
                $fatal(1,"ordered W changed under backpressure");
            aw_held=m_axi_awvalid && !m_axi_awready;aw_saved={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            w_held=m_axi_wvalid && !m_axi_wready;w_saved={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            if(req_valid && req_ready) begin
                expected_data[accepted]=req_addr[2:0]!=0 ? 0 : req_wdata;
                expected_error[accepted]=req_addr[2:0]!=0 || req_addr[31:12]==20'h5;
                if(req_addr[2:0]==0)for(integer i=0;i<8;i++)if(req_wstrb[i]) expected[(req_addr+i)&65535]=req_wdata[i*8+:8];
                accepted++;
            end
            if(rsp_valid && rsp_ready)begin
                if(responses>=accepted || rsp_rdata!==expected_data[responses] || rsp_error!==expected_error[responses])
                    $fatal(1,"ordered logical response mismatch index=%0d data=%h expected=%h error=%b expected_error=%b",
                        responses,rsp_rdata,expected_data[responses],rsp_error,expected_error[responses]);
                if(rsp_error)errors++;responses++;
            end
            if(m_axi_awvalid && m_axi_awready)begin
                if(m_axi_awaddr[3:0]!=0 || m_axi_awsize!=4 || m_axi_awburst!=1 || m_axi_awlen>=4 ||
                   {1'b0,m_axi_awaddr[11:0]}+((m_axi_awlen+1)*16)>4096)
                    $fatal(1,"illegal ordered AXI descriptor");
                aw_addr[aws]=m_axi_awaddr;aw_beats[aws]=m_axi_awlen+1;
                if(m_axi_awlen!=0)bursts_multi++;aws++;
            end
            if(m_axi_wvalid && m_axi_wready)begin
                if(aws==completed)w_before_aw++;
                w_data[ws]=m_axi_wdata;w_strb[ws]=m_axi_wstrb;w_last[ws]=m_axi_wlast;ws++;
            end
            if(completed<aws && commit_word<ws)begin
                if(w_last[commit_word]!==(commit_beat==aw_beats[completed]-1))$fatal(1,"ordered WLAST mismatch");
                address=(aw_addr[completed]+commit_beat*16)&65535;
                for(integer i=0;i<16;i++)if(w_strb[commit_word][i])physical[(address+i)&65535]=w_data[commit_word][i*8+:8];
                commit_word++;commit_beat++;
                if(commit_beat==aw_beats[completed])begin b_due[completed]=cycle+20;completed++;commit_beat=0;end
            end
            if(m_axi_bvalid && m_axi_bready)begin bs++;m_axi_bvalid<=0;end
            if(!m_axi_bvalid && !hold_b && bs<completed && cycle>=b_due[bs])begin
                m_axi_bvalid<=1;m_axi_bresp<=aw_addr[bs][31:12]==20'h5 ? 2'b10 : 2'b00;
            end
            if(aws-bs>physical_peak)physical_peak=aws-bs;
            if(aws-bs>SLOTS || bs>completed)$fatal(1,"unowned or excessive physical AXI debt");
        end
    end
    task automatic send(input logic[31:0] address,input logic[63:0] data,input logic[7:0] strb=8'hff,input bit terminal=0);
        integer wait_count;
        begin
            @(negedge clk);req_addr=address;req_wdata=data;req_wstrb=strb;req_end=terminal;req_valid=1;wait_count=0;
            do begin @(posedge clk);wait_count++;if(wait_count>20000)$fatal(1,"ordered request timed out");end while(!req_ready);
            @(negedge clk);req_valid=0;req_end=0;
        end
    endtask
    task automatic drain;
        integer wait_count;
        begin
            wait_count=0;
            while(perf_busy || responses!=accepted)begin @(negedge clk);wait_count++;if(wait_count>20000)$fatal(1,"ordered drain timeout");end
            if(aws!=bs || completed!=bs || commit_word!=ws)$fatal(1,"ordered early idle");
            for(integer i=0;i<65536;i++)if(physical[i]!==expected[i])$fatal(1,"ordered physical byte mismatch address=%h got=%h expected=%h",i,physical[i],expected[i]);
        end
    endtask
    initial begin : stimulus
        integer target,wait_count;
        for(integer i=0;i<65536;i++)begin physical[i]=0;expected[i]=0;end
        repeat(5)@(negedge clk);rst=0;hold_b=1;
        // Real same-client MLP, not merely requests sitting in a FIFO.
        for(integer i=0;i<SLOTS;i++)send(32'h2000+i*256,64'h100+i,8'hff,1);
        wait_count=0;
        while(aws!=SLOTS || completed!=SLOTS)begin @(negedge clk);wait_count++;if(wait_count>1000)$fatal(1,"no physical multi-outstanding progress aw=%0d w_complete=%0d words=%0d b=%0d valid=%b sealed=%b cmd=%b feed=%b backend_head=%0d backend_issue=%0d",
            aws,completed,ws,bs,dut.valid_q,dut.sealed_q,dut.command_sent_q,dut.payload_sent_q,dut.u_backend.head_q,dut.u_backend.issue_ptr_q);end
        repeat(64)begin @(negedge clk);if(bs!=0 || responses!=0 || !perf_busy)$fatal(1,"posted ACK before real B");end
        if(physical_peak!=SLOTS || perf_max_outstanding!=SLOTS)$fatal(1,"physical outstanding not exercised");
        hold_b=0;drain();$display("C1_ORDERED_WRITE_MLP_PASS slots=%0d held_b=64 real_aw=%0d",SLOTS,aws);

        rsp_ready=0;target=aws+SLOTS;
        for(integer i=0;i<SLOTS;i++)send(32'h3000+i*256,64'h200+i,8'hff,1);
        wait(bs==target);@(negedge clk);
        req_valid=1;req_addr=32'h3800;req_wdata=64'habc;req_wstrb=8'h55;req_end=1;
        repeat(9)begin @(negedge clk);if(req_ready || !perf_busy)$fatal(1,"slot reused before logical response consumption");end
        rsp_ready=1;do @(posedge clk);while(!req_ready);
        @(negedge clk);req_valid=0;req_end=0;drain();
        $display("C1_ORDERED_WRITE_RESPONSE_FENCE_PASS slots=%0d reset=0",SLOTS);

        // Repeated ring wraps, pairs, full bursts, sparse/duplicate writes,
        // 4 KiB and 32-bit limits, local rejection between real descriptors.
        for(integer pass=0;pass<6;pass++)begin
            for(integer i=0;i<8;i++)send(32'h4000+pass*64+i*8,64'hffeeddccbb000000+pass*256+i,8'hff,i==7);
        end
        for(integer i=0;i<8;i++)send(32'hff0+i*8,64'hbbaa110000+i,i%2?8'h55:8'haa,i==7);
        send(32'h6008,64'h123456789abcdef0,8'hff);
        send(32'h6000,64'hfedcba9876543210,8'hff);
        send(32'h6010,64'h11,8'hff);send(32'h6010,64'h22,8'h0f);send(32'h6010,64'h33,8'hff,1);
        send(32'h1235,64'h999,8'hff,1);
        send(32'h7000,64'h55,8'h00,1);send(32'h7208,64'h66,8'h80,1);
        send(32'hfffffff8,64'h77,8'hff);send(32'h00000000,64'h88,8'hff,1);
        send(32'h5000,64'h1234,8'hff);send(32'h5008,64'h5678,8'hff,1);
        drain();
        if(errors!=3 || bursts_multi<6)$fatal(1,"ordered fault/burst coverage incomplete errors=%0d multi=%0d",errors,bursts_multi);
        hold_aw=1;hold_w=0;target=aws;send(32'h7800,64'h112233,8'hff,1);
        repeat(32)@(negedge clk);if(aws!=target || ws==commit_word)$fatal(1,"W-before-AW was not exercised");
        hold_aw=0;drain();
        send(32'h7900,64'h999,8'hff);@(negedge clk);req_flush=1;@(negedge clk);req_flush=0;drain();
        if(w_before_aw==0)$fatal(1,"missing independent W/AW coverage");
        $display("C1_TENSOR_ORDERED_WRITE_PASS slots=%0d dependent_aw=%0d end=%0d requests=%0d responses=%0d aw=%0d w=%0d b=%0d errors=%0d peak=%0d multi=%0d w_before_aw=%0d",
            SLOTS,DEPENDENT_AW,USE_END,accepted,responses,aws,ws,bs,errors,physical_peak,bursts_multi,w_before_aw);
        $finish;
    end
    initial begin #5000000;$fatal(1,"ordered write watchdog");end
endmodule
