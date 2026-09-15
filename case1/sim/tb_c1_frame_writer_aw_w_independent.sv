`timescale 1ns/1ps
// Independent channel scoreboard: W is accepted and checked before AW exists.
module tb_c1_frame_writer_aw_w_independent;
    logic clk=0, rst=1, start=0, cancel=0;
    always #5 clk=~clk;
    logic [31:0] cfg_base_addr=32'hff0, cfg_stride_bytes=256;
    logic [15:0] cfg_width_pixels=64, cfg_height_lines=1;
    wire busy, done, error, s_ready;
    logic s_valid=0, s_sof=0, s_eol=0, s_eof=0;
    logic [23:0] s_rgb=0;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    logic m_axi_awready=0, m_axi_wready=0, m_axi_bvalid=0;
    logic [1:0] m_axi_bresp=0;
    integer mode=0, aw_count=0, w_count=0, b_count=0, cycle=0;
    integer burst_index=0, beat_in_burst=0, aw_wait=0, b_wait=0;
    integer w_before_aw=0, cases=0, cancel_cases=0;
    logic aw_seen=0, w_seen=0, cancel_test=0;
    logic held_aw=0, held_w=0;
    logic [39:0] saved_aw;
    logic [144:0] saved_w;
    c1_axi_xrgb_frame_writer dut (.*);

    // mode 0: AW acceptance depends on WVALID (legal slave dependency).
    // mode 1: entire W burst completes before AW; AW then stalls 8 cycles.
    // mode 2: AW first, W delayed. mode 3: both channels together.
    always @(negedge clk) begin
        if (rst) begin
            m_axi_awready=0; m_axi_wready=0; m_axi_bvalid=0;
        end else begin
            case (mode)
                0: begin m_axi_awready=m_axi_wvalid; m_axi_wready=(cycle%3!=0); end
                1: begin m_axi_awready=w_seen && aw_wait>=8; m_axi_wready=(cycle%3!=0); end
                2: begin m_axi_awready=1; m_axi_wready=aw_seen && aw_wait>=8; end
                3: begin m_axi_awready=1; m_axi_wready=1; end
            endcase
            m_axi_bvalid=aw_seen && w_seen && b_wait>=7;
        end
    end

    always @(posedge clk) begin : scoreboard
        integer beats, expected_addr;
        logic [127:0] expected_data;
        if (rst) begin
            aw_count=0; w_count=0; b_count=0; cycle=0;
            burst_index=0; beat_in_burst=0; aw_wait=0; b_wait=0;
            aw_seen=0; w_seen=0; held_aw=0; held_w=0;
        end else begin
            cycle=cycle+1;
            if (held_aw && (!m_axi_awvalid || {m_axi_awaddr,m_axi_awlen}!==saved_aw))
                $fatal(1,"AW changed under backpressure");
            if (held_w && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==saved_w))
                $fatal(1,"W changed under backpressure");
            held_aw=m_axi_awvalid && !m_axi_awready;
            saved_aw={m_axi_awaddr,m_axi_awlen};
            held_w=m_axi_wvalid && !m_axi_wready;
            saved_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
            beats=(burst_index==0) ? 1 : 15;
            expected_addr=(burst_index==0) ? 'hff0 : 'h1000;
            if (m_axi_wvalid && m_axi_wready) begin
                if (w_seen) $fatal(1,"duplicate W after WLAST");
                if (!aw_seen) w_before_aw=w_before_aw+1;
                for (integer lane=0; lane<4; lane=lane+1)
                    expected_data[lane*32+:32]=32'h120000+w_count*4+lane;
                if (m_axi_wdata!==expected_data || m_axi_wstrb!==16'hffff ||
                    m_axi_wlast!==(beat_in_burst==beats-1))
                    $fatal(1,"W data/strb/last mismatch beat=%0d",w_count);
                beat_in_burst=beat_in_burst+1; w_count=w_count+1;
                if (m_axi_wlast) w_seen=1;
            end
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw_seen || m_axi_awaddr!==expected_addr || m_axi_awlen!==beats-1 ||
                    m_axi_awsize!==3'd4 || m_axi_awburst!==2'b01)
                    $fatal(1,"AW duplicate/address/length mismatch");
                aw_seen=1; aw_count=aw_count+1;
            end
            if (w_seen || aw_seen) aw_wait=aw_wait+1;
            if (aw_seen && w_seen) b_wait=b_wait+1;
            if (m_axi_bready && !(aw_seen && w_seen)) $fatal(1,"BREADY before AW and W complete");
            if (m_axi_bvalid && m_axi_bready) begin
                b_count=b_count+1; burst_index=burst_index+1;
                aw_seen=0; w_seen=0; beat_in_burst=0; aw_wait=0; b_wait=0;
            end
            if (cycle>4000) $fatal(1,"AW/W progress timeout mode=%0d",mode);
        end
    end

    task automatic run_case(input integer selected_mode, input bit do_cancel);
        integer pixels, timeout_count;
        begin
            @(negedge clk); rst=1; mode=selected_mode; cancel=0; start=0; s_valid=0;
            repeat(3) @(negedge clk);
            rst=0; start=1;
            @(negedge clk); start=0;
            pixels=do_cancel ? 4 : 64;
            for (integer p=0; p<pixels; p=p+1) begin
                s_valid=1; s_rgb=24'h120000+p; s_sof=(p==0); s_eol=(p==63); s_eof=(p==63);
                do @(posedge clk); while (!s_ready);
                @(negedge clk);
            end
            s_valid=0;
            if (do_cancel) begin
                // W is already committed while AW remains pending.
                wait(w_seen && !aw_seen);
                @(negedge clk); cancel=1;
                @(negedge clk); cancel=0;
                cancel_cases=cancel_cases+1;
            end
            timeout_count=0;
            while (!done && timeout_count<4000) begin
                @(negedge clk); timeout_count=timeout_count+1;
            end
            if (!done || busy || error || aw_count!=(do_cancel?1:2) ||
                b_count!=aw_count || w_count!=(do_cancel?1:16))
                $fatal(1,"completion/count/error mismatch mode=%0d",mode);
            repeat(5) begin
                @(negedge clk);
                if (done || m_axi_awvalid || m_axi_wvalid || busy) $fatal(1,"repeated completion/transaction");
            end
            cases=cases+1;
        end
    endtask
    initial begin
        for (integer m=0; m<4; m=m+1) run_case(m,0);
        run_case(1,1);
        run_case(0,0); // restart after cancellation
        if (w_before_aw<17) $fatal(1,"W-before-AW coverage missing");
        $display("C1_FRAME_WRITER_AW_W_INDEPENDENT_PASS cases=%0d cancel=%0d w_before_aw=%0d",cases,cancel_cases,w_before_aw);
        $finish;
    end
    initial begin #1000000; $fatal(1,"global timeout"); end
endmodule
