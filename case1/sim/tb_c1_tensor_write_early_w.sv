`timescale 1ns/1ps
module tb_c1_tensor_write_early_w #(parameter bit USE_END=0);
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic req_valid=0, req_flush=0, rsp_ready=0;
    logic [31:0] req_addr=0;
    wire req_end = (req_addr==32'h1038);
    logic [63:0] req_wdata=0;
    logic [7:0] req_wstrb=8'hff;
    wire req_ready, rsp_valid, rsp_error;
    wire [63:0] rsp_rdata;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    logic m_axi_awready=0, m_axi_wready=0, m_axi_bvalid=0;
    logic [1:0] m_axi_bresp=0;
    wire perf_busy;
    wire [63:0] perf_req_accept_count, perf_axi_burst_count, perf_axi_beat_count;
    wire [63:0] perf_rsp_count, perf_packed_request_count, perf_error_count;
    wire [7:0] perf_req_occupancy, perf_max_req_occupancy, perf_outstanding, perf_max_outstanding;
    integer beats=0, responses=0, aw=0, b=0, cycle=0, after_w=0, trial=0;
    logic held_aw=0, held_w=0;
    logic [39:0] saved_aw;
    logic [144:0] saved_w;
    c1_tensor_mem_axi128_write_burst_client #(
        .BURST_BEATS(4), .BUILD_TIMEOUT_CYCLES(20), .USE_REQUEST_END(USE_END)
    ) dut (.*);
    always @(negedge clk) begin
        m_axi_wready=!rst && cycle%3!=0;
        // Accept all four data beats before allowing the address.
        m_axi_awready=!rst && after_w>=10;
        m_axi_bvalid=!rst && aw==1 && after_w>=20 && b==0;
    end
    always @(posedge clk) begin
        if (rst) begin
            beats=0; responses=0; aw=0; b=0; cycle=0; after_w=0;
            held_aw=0; held_w=0;
        end else begin
            cycle=cycle+1;
            if (held_aw && (!m_axi_awvalid || saved_aw!=={m_axi_awaddr,m_axi_awlen}))
                $fatal(1,"AW changed while held");
            if (held_w && (!m_axi_wvalid || saved_w!=={m_axi_wdata,m_axi_wstrb,m_axi_wlast}))
                $fatal(1,"W changed while held");
            held_aw=m_axi_awvalid&&!m_axi_awready; saved_aw={m_axi_awaddr,m_axi_awlen};
            held_w=m_axi_wvalid&&!m_axi_wready; saved_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            if (m_axi_wvalid && m_axi_wready) begin
                if (aw!=0 || beats>=4 || m_axi_wdata[63:0]!==64'hc1000000+2*beats ||
                    m_axi_wdata[127:64]!==64'hc1000001+2*beats ||
                    m_axi_wstrb!==16'hffff || m_axi_wlast!==(beats==3))
                    $fatal(1,"early W payload/order mismatch beat=%0d",beats);
                beats=beats+1;
            end
            if (beats==4) after_w=after_w+1;
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw!=0 || beats!=4 || m_axi_awaddr!==32'h1000 ||
                    m_axi_awlen!==3 || m_axi_awsize!==4 || m_axi_awburst!==1)
                    $fatal(1,"AW metadata/ordering mismatch");
                aw=aw+1;
            end
            if (m_axi_bvalid && m_axi_bready) b=b+1;
            if (rsp_valid && rsp_ready) begin
                if (b!=1 || responses>=8 || rsp_rdata!==64'hc1000000+responses ||
                    rsp_error!==(trial==1)) $fatal(1,"logical response mismatch");
                responses=responses+1;
            end
            if (cycle>1000) $fatal(1,"early W deadlock");
        end
    end
    initial begin
        for (trial=0; trial<2; trial=trial+1) begin
            @(negedge clk); rst=1; req_valid=0; req_flush=0; rsp_ready=0;
            repeat(3) @(negedge clk);
            rst=0; m_axi_bresp=trial==1 ? 2'b10 : 2'b00;
            for (integer r=0; r<8; r=r+1) begin
                req_valid=1; req_addr='h1000+r*8; req_wdata=64'hc1000000+r;
                do @(posedge clk); while(!req_ready);
                @(negedge clk);
            end
            req_valid=0;
            wait(beats==4);
            // Flush requests closure; it must not discard an exposed burst.
            @(negedge clk); req_flush=1;
            @(negedge clk); req_flush=0;
            wait(b==1);
            repeat(20) @(negedge clk);
            rsp_ready=1;
            wait(responses==8);
            repeat(5) @(negedge clk);
            if (perf_busy || perf_axi_burst_count!=1 || perf_axi_beat_count!=4 ||
                perf_rsp_count!=8 || perf_packed_request_count!=4 || perf_outstanding!=0 ||
                perf_error_count!=(trial==1?8:0)) $fatal(1,"performance/accounting mismatch");
        end
        $display("C1_TENSOR_WRITE_EARLY_W_PASS cases=2 beats_before_aw=8 responses=16 slverr_responses=8");
        $display("C1_TENSOR_WRITE_EARLY_W_MODE end_marker=%0d",USE_END);
        $finish;
    end
    initial begin #50000; $fatal(1,"timeout"); end
endmodule
