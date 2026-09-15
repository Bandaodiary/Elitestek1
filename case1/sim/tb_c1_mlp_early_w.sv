`timescale 1ns/1ps
module tb_c1_mlp_early_w #(parameter bit EARLY_AW=0);
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic cmd_valid=0,payload_valid=0,payload_last=0,payload_flush=0,rsp_ready=0;
    wire cmd_ready,payload_ready,rsp_valid,rsp_error;
    logic [31:0] cmd_addr=0;
    logic [8:0] cmd_beats=3;
    logic [127:0] payload_data=0;
    logic [15:0] payload_strb=16'hffff;
    wire [31:0] rsp_addr;
    wire [8:0] rsp_beats;
    wire [15:0] rsp_tag;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    logic m_axi_awready=0,m_axi_wready=0,m_axi_bvalid=0;
    logic [1:0] m_axi_bresp=0;
    wire protocol_error,early_payload_last_error,late_payload_last_error;
    wire payload_flush_error,orphan_payload_error,early_b_error,orphan_b_error,perf_busy;
    wire [63:0] perf_cmd_accept_count,perf_payload_beat_count,perf_axi_burst_count,perf_axi_beat_count;
    wire [63:0] perf_aw_issue_count,perf_rsp_count,perf_error_count,perf_aw_stall_count,perf_w_stall_count,perf_b_stall_count;
    wire [7:0] perf_cmd_occupancy,perf_max_cmd_occupancy,perf_outstanding,perf_max_outstanding;
    integer trial=0,beats=0,aw=0,b=0,responses=0,cycle=0,after_w=0;
    logic held_aw=0,held_w=0;
    logic [39:0] saved_aw;
    logic [144:0] saved_w;
    c1_axi128_write_mlp #(.MAX_BEATS(4),.MAX_OUTSTANDING(4),
        .ISSUE_AW_BEFORE_PAYLOAD(EARLY_AW)) dut (.*);
    always @(negedge clk) begin
        m_axi_wready=!rst && cycle%3!=0;
        m_axi_awready=!rst && after_w>=12;
        // One unsolicited B after WLAST but before AW. It must be drained
        // without retiring the descriptor, even though its W has completed.
        m_axi_bvalid=!rst && ((trial==0 && after_w==5) || (aw==1 && after_w>=20 && b==0));
        m_axi_bresp=trial==2 ? 2'b10 : 2'b00;
    end
    always @(posedge clk) begin
        if (rst) begin
            cycle=0; held_aw=0; held_w=0;
        end else begin
            cycle=cycle+1;
            if (held_aw && (!m_axi_awvalid || saved_aw!=={m_axi_awaddr,m_axi_awlen})) $fatal(1,"AW hold");
            if (held_w && (!m_axi_wvalid || saved_w!=={m_axi_wdata,m_axi_wstrb,m_axi_wlast})) $fatal(1,"W hold");
            held_aw=m_axi_awvalid&&!m_axi_awready; saved_aw={m_axi_awaddr,m_axi_awlen};
            held_w=m_axi_wvalid&&!m_axi_wready; saved_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            if (m_axi_wvalid && m_axi_wready) begin
                if (aw!=0 || beats>=3 || m_axi_wdata!==128'hac0000+trial*16+beats ||
                    m_axi_wstrb!==16'hffff || m_axi_wlast!==(beats==2)) $fatal(1,"early W mismatch");
                beats=beats+1;
            end
            if (beats==3) after_w=after_w+1;
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw!=0 || beats!=3 || m_axi_awaddr!==32'h1000+trial*64 ||
                    m_axi_awlen!==2 || m_axi_awsize!==4 || m_axi_awburst!==1) $fatal(1,"AW mismatch");
                aw=1;
            end
            if (m_axi_bvalid && m_axi_bready && aw==1) b=b+1;
            if (rsp_valid && rsp_ready) begin
                if (b!=1 || responses!=trial || rsp_addr!==32'h1000+trial*64 ||
                    rsp_tag!==trial || rsp_beats!==3 || rsp_error!==(trial==2)) $fatal(1,"response/retirement mismatch");
                responses=responses+1;
            end
            if (after_w==10 && aw==0 && (perf_cmd_occupancy!=1 || rsp_valid || perf_outstanding!=0))
                $fatal(1,"orphan B or early W retired unissued descriptor");
            if (cycle>2000) $fatal(1,"MLP early W timeout");
        end
    end
    initial begin
        repeat(4) @(negedge clk); rst=0;
        for (trial=0;trial<3;trial=trial+1) begin
            beats=0;aw=0;b=0;after_w=0;rsp_ready=0;
            cmd_valid=1;cmd_addr='h1000+trial*64;
            do @(posedge clk); while(!cmd_ready);
            @(negedge clk);cmd_valid=0;
            for(integer p=0;p<3;p=p+1) begin
                payload_valid=1;payload_data=128'hac0000+trial*16+p;payload_last=(p==2);
                do @(posedge clk); while(!payload_ready);
                @(negedge clk);
            end
            payload_valid=0;payload_last=0;
            wait(b==1);repeat(10) @(negedge clk);rsp_ready=1;
            wait(responses==trial+1);repeat(5) @(negedge clk);
            if(perf_busy) $fatal(1,"did not drain");
        end
        if(!orphan_b_error || early_b_error || early_payload_last_error || late_payload_last_error ||
            payload_flush_error || orphan_payload_error || perf_rsp_count!=3 || perf_axi_burst_count!=3 ||
            perf_axi_beat_count!=9 || perf_error_count!=1 || perf_outstanding!=0)
            $fatal(1,"final error/counter mismatch");
        $display("C1_MLP_EARLY_W_PASS early_aw=%0d descriptors=3 beats_before_aw=9 orphan_b=1 slverr=1",EARLY_AW);
        $finish;
    end
    initial begin #50000;$fatal(1,"global timeout");end
endmodule
