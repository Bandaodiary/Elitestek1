`timescale 1ns/1ps
// Real fork + writer. Independently stop AW, W, B and the CNN consumer.
module tb_c1_r1_preview_dma_cancel;
    logic clk=0,rst=1; always #5 clk=~clk;
    logic start_valid=0,start_ready,cancel=0,busy,done,error,aborted;
    logic [31:0] base_addr=32'h1000,stride_bytes=32;
    logic [15:0] width_pixels=8,height_lines=1;
    logic in_valid,in_ready,cnn_valid,cnn_ready;
    logic [63:0] in_data_s8,cnn_data_s8;
    logic [15:0] in_x,in_y=0,cnn_x,cnn_y;
    logic in_sof,in_eol,in_eof,cnn_sof,cnn_eol,cnn_eof;
    wire [31:0] m_axi_awaddr; wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize; wire [1:0] m_axi_awburst;
    wire m_axi_awvalid; logic m_axi_awready=0;
    wire [127:0] m_axi_wdata; wire [15:0] m_axi_wstrb;
    wire m_axi_wlast,m_axi_wvalid; logic m_axi_wready=0;
    logic [1:0] m_axi_bresp=0; wire m_axi_bvalid,m_axi_bready;
    integer sent=0,received=0,aws=0,beats=0,bs=0;
    integer source_limit=0,cnn_limit=8,mode=0,completed=0;
    integer aw_stalls=0,w_stalls=0,cnn_stalls=0;
    logic permit_b=0,abort_seen=0,bad_sof=0;
    logic aw_held=0,w_held=0,cnn_held=0;
    logic [44:0] saved_aw;
    logic [144:0] saved_w;
    logic [98:0] saved_cnn;
    c1_r1_preview_dma dut(.*);
    function automatic [63:0] token(input integer n);
        token={40'h1020304050,8'(n*19),8'(n*11+1),8'(n*7+2)};
    endfunction
    function automatic [31:0] pixel(input integer n);
        logic [63:0] v;
        v=token(n);pixel={8'd0,v[7:0]^8'h80,v[15:8]^8'h80,v[23:16]^8'h80};
    endfunction
    assign in_valid=sent<source_limit;
    assign in_data_s8=token(sent);
    assign in_x=16'(sent);
    assign in_sof=(sent==0)&&!bad_sof;
    assign in_eol=(sent==7);
    assign in_eof=(sent==7);
    assign cnn_ready=received<cnn_limit;
    assign m_axi_bvalid=permit_b && aws==1 && beats==2 && bs==0;

    always @(posedge clk) if(!rst) begin
        if(cancel) abort_seen<=1;
        if((cancel||abort_seen) && ((in_valid&&in_ready)||(cnn_valid&&cnn_ready)))
            $fatal(1,"post-cancel stream handshake mode=%0d",mode);
        if(in_valid&&in_ready) sent<=sent+1;
        if(cnn_valid&&cnn_ready) begin
            if(cnn_data_s8!==token(received) || cnn_x!==16'(received) || cnn_y!==0 ||
               cnn_sof!==((received==0)&&!bad_sof) || cnn_eol!==(received==7) || cnn_eof!==(received==7))
                $fatal(1,"CNN mismatch mode=%0d pixel=%0d",mode,received);
            received<=received+1;
        end
        // AXI promises survive cancel; only CNN promises may be flushed by it.
        if(aw_held && (!m_axi_awvalid ||
            {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst}!==saved_aw))
            $fatal(1,"AW retracted/changed while stalled mode=%0d",mode);
        if(w_held && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==saved_w))
            $fatal(1,"W retracted/changed while stalled mode=%0d",mode);
        if(cnn_held && !cancel && (!cnn_valid ||
            {cnn_sof,cnn_eol,cnn_eof,cnn_y,cnn_x,cnn_data_s8}!==saved_cnn))
            $fatal(1,"CNN token retracted/changed without cancel mode=%0d",mode);
        aw_held<=m_axi_awvalid&&!m_axi_awready;
        w_held<=m_axi_wvalid&&!m_axi_wready;
        cnn_held<=cnn_valid&&!cnn_ready;
        saved_aw<={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
        saved_w<={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
        saved_cnn<={cnn_sof,cnn_eol,cnn_eof,cnn_y,cnn_x,cnn_data_s8};
        if(m_axi_awvalid&&!m_axi_awready) aw_stalls<=aw_stalls+1;
        if(m_axi_wvalid&&!m_axi_wready) w_stalls<=w_stalls+1;
        if(cnn_valid&&!cnn_ready) cnn_stalls<=cnn_stalls+1;
        if(m_axi_awvalid&&m_axi_awready) begin
            if(aws!=0 || m_axi_awaddr!==32'h1000 || m_axi_awlen!==1 || m_axi_awsize!==4 || m_axi_awburst!==1)
                $fatal(1,"AW mismatch mode=%0d",mode);
            aws<=aws+1;
        end
        if(m_axi_wvalid&&m_axi_wready) begin
            if(beats>=2 || m_axi_wstrb!==16'hffff || m_axi_wlast!==(beats==1))
                $fatal(1,"W framing mismatch mode=%0d",mode);
            for(integer n=0;n<4;n++)
                if(m_axi_wdata[n*32+:32]!==pixel(beats*4+n)) $fatal(1,"W pixel mismatch");
            beats<=beats+1;
        end
        if(m_axi_bvalid&&m_axi_bready) bs<=bs+1;
    end
    task automatic pulse_cancel;
        cancel=1; @(negedge clk); cancel=0;
    endtask
    task automatic must_stay_busy;
        repeat(12) begin
            @(negedge clk);
            if(!busy || done || start_ready) $fatal(1,"early retirement mode=%0d",mode);
        end
    endtask
    task automatic check_terminal(input bit expect_error,input bit expect_abort,input integer expected_b);
        // Cancellation can retire on its own edge when AXI is already idle.
        // Do not skip that one-cycle terminal pulse when this task is entered
        // at the following falling edge.
        if(!done) begin wait(done); @(negedge clk); end
        if(busy || error!==expect_error || aborted!==expect_abort || bs!=expected_b)
            $fatal(1,"bad terminal mode=%0d busy=%b error=%b abort=%b B=%0d",mode,busy,error,aborted,bs);
        completed=completed+1;
        repeat(3) begin @(negedge clk); if(done) $fatal(1,"duplicate terminal"); end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        for(mode=0;mode<8;mode++) begin
            wait(start_ready); @(negedge clk);
            sent=0;received=0;aws=0;beats=0;bs=0;abort_seen=0;
            source_limit=0;cnn_limit=8;permit_b=0;bad_sof=0;
            m_axi_awready=0;m_axi_wready=0;m_axi_bresp=0;
            start_valid=1; @(negedge clk);start_valid=0;
            case(mode)
                0: begin // Cancel in preflight, before any source admission.
                    source_limit=8;pulse_cancel();
                    check_terminal(0,1,0);
                    if(sent!=0 || aws!=0 || beats!=0) $fatal(1,"preflight cancel leaked work");
                end
                1: begin // Partial burst + CNN token held: discard uncommitted work.
                    source_limit=3;cnn_limit=2;
                    wait(sent==3 && received==2);@(negedge clk);
                    must_stay_busy();pulse_cancel();check_terminal(0,1,0);
                    if(aws!=0 || beats!=0) $fatal(1,"partial capture committed unexpectedly");
                end
                2,3,4: begin
                    source_limit=8;cnn_limit=7;
                    if(mode==3) m_axi_awready=1;
                    if(mode==4) m_axi_wready=1;
                    wait(sent==8 && m_axi_awvalid);@(negedge clk);
                    if(mode==3) begin wait(aws==1);@(negedge clk);end
                    if(mode==4) begin wait(beats==2);@(negedge clk);end
                    pulse_cancel();must_stay_busy();
                    // Mode 2 also completes W before accepting AW, after cancel.
                    m_axi_wready=1;
                    wait(beats==2);@(negedge clk);
                    if(mode!=3) begin
                        must_stay_busy();
                        if(aws!=0) $fatal(1,"AW accepted while gated");
                    end
                    m_axi_awready=1;wait(aws==1);@(negedge clk);
                    must_stay_busy();permit_b=1;check_terminal(0,1,1);
                    if(received!=7) $fatal(1,"cancel did not flush pending CNN EOF");
                end
                5: begin // Error cannot revoke a stalled CNN EOF; parent cancels.
                    source_limit=8;cnn_limit=7;m_axi_awready=1;m_axi_wready=1;
                    m_axi_bresp=2;permit_b=1;
                    wait(error && bs==1);@(negedge clk);
                    must_stay_busy();
                    if(!cnn_valid || !cnn_eof || in_ready) $fatal(1,"error lost held EOF or admitted source");
                    pulse_cancel();check_terminal(1,1,1);
                end
                6: begin // Malformed SOF before a complete AXI beat/burst.
                    source_limit=1;cnn_limit=0;bad_sof=1;
                    wait(error);@(negedge clk);must_stay_busy();
                    if(cnn_valid || in_ready || received!=0 || sent!=1)
                        $fatal(1,"marker error crossed pre-fork guard");
                    pulse_cancel();check_terminal(1,1,0);
                    if(aws!=0 || beats!=0) $fatal(1,"malformed partial frame committed");
                end
                7: begin // Valid restart after every previous sticky error/abort.
                    source_limit=8;m_axi_awready=1;m_axi_wready=1;permit_b=1;
                    check_terminal(0,0,1);
                    if(sent!=8 || received!=8) $fatal(1,"no-reset restart lost pixels");
                end
            endcase
            source_limit=0;
        end
        if(completed!=8 || aw_stalls<24 || w_stalls<24 || cnn_stalls<24)
            $fatal(1,"insufficient lifecycle coverage");
        $display("C1_PREVIEW_DMA_CANCEL_PASS jobs=%0d cancel=7 errors=2 restart=1 aw_stalls=%0d w_stalls=%0d cnn_stalls=%0d",completed,aw_stalls,w_stalls,cnn_stalls);
        $finish;
    end
    initial begin #200000;$fatal(1,"preview cancel timeout mode=%0d",mode);end
endmodule
