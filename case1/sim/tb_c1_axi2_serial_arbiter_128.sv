`timescale 1ns/1ps

module tb_c1_axi2_serial_arbiter_128;

    localparam integer WRITE_BURSTS_PER_MASTER = 12;
    localparam integer READ_BURSTS_PER_MASTER = 12;
    // Sum of the deterministic per-transaction beat functions below for
    // masters 0 and 1 over transaction indices 0..11.
    localparam integer EXPECTED_WRITE_BEATS = 104;
    // The focused malformed-RLAST cases below shorten master0/txn1 from six
    // beats to an early two-beat burst and suppress RLAST on master1/txn2's
    // fourth expected beat.  All other randomized transactions are nominal.
    localparam integer EXPECTED_READ_BEATS = 100;
    localparam integer EXPECTED_RLASTS = 23;
    localparam integer EARLY_RLAST_MASTER = 0;
    localparam integer EARLY_RLAST_TXN = 1;
    localparam integer EARLY_RLAST_BEAT = 1;
    localparam integer MISSING_RLAST_MASTER = 1;
    localparam integer MISSING_RLAST_TXN = 2;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic go = 1'b0;

    logic [31:0] s0_awaddr = '0;
    logic [7:0] s0_awlen = '0;
    logic [2:0] s0_awsize = '0;
    logic [1:0] s0_awburst = '0;
    logic s0_awvalid = 1'b0;
    logic s0_awready;
    logic [127:0] s0_wdata = '0;
    logic [15:0] s0_wstrb = '0;
    logic s0_wlast = 1'b0;
    logic s0_wvalid = 1'b0;
    logic s0_wready;
    logic [1:0] s0_bresp;
    logic s0_bvalid;
    logic s0_bready = 1'b0;
    logic [31:0] s0_araddr = '0;
    logic [7:0] s0_arlen = '0;
    logic [2:0] s0_arsize = '0;
    logic [1:0] s0_arburst = '0;
    logic s0_arvalid = 1'b0;
    logic s0_arready;
    logic [127:0] s0_rdata;
    logic [1:0] s0_rresp;
    logic s0_rlast;
    logic s0_rvalid;
    logic s0_rready = 1'b0;

    logic [31:0] s1_awaddr = '0;
    logic [7:0] s1_awlen = '0;
    logic [2:0] s1_awsize = '0;
    logic [1:0] s1_awburst = '0;
    logic s1_awvalid = 1'b0;
    logic s1_awready;
    logic [127:0] s1_wdata = '0;
    logic [15:0] s1_wstrb = '0;
    logic s1_wlast = 1'b0;
    logic s1_wvalid = 1'b0;
    logic s1_wready;
    logic [1:0] s1_bresp;
    logic s1_bvalid;
    logic s1_bready = 1'b0;
    logic [31:0] s1_araddr = '0;
    logic [7:0] s1_arlen = '0;
    logic [2:0] s1_arsize = '0;
    logic [1:0] s1_arburst = '0;
    logic s1_arvalid = 1'b0;
    logic s1_arready;
    logic [127:0] s1_rdata;
    logic [1:0] s1_rresp;
    logic s1_rlast;
    logic s1_rvalid;
    logic s1_rready = 1'b0;

    logic [31:0] m_awaddr;
    logic [7:0] m_awlen;
    logic [2:0] m_awsize;
    logic [1:0] m_awburst;
    logic m_awvalid;
    logic m_awready = 1'b0;
    logic [127:0] m_wdata;
    logic [15:0] m_wstrb;
    logic m_wlast;
    logic m_wvalid;
    logic m_wready = 1'b0;
    logic [1:0] m_bresp = 2'b00;
    logic m_bvalid = 1'b0;
    logic m_bready;
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_arvalid;
    logic m_arready = 1'b0;
    logic [127:0] m_rdata = '0;
    logic [1:0] m_rresp = 2'b00;
    logic m_rlast = 1'b0;
    logic m_rvalid = 1'b0;
    logic m_rready;

    logic write_done0 = 1'b0;
    logic write_done1 = 1'b0;
    logic read_done0 = 1'b0;
    logic read_done1 = 1'b0;
    integer write_error_seen0 = 0;
    integer write_error_seen1 = 0;
    integer read_error_seen0 = 0;
    integer read_error_seen1 = 0;

    logic [31:0] wr_bfm_prng = 32'h9137_a4d5;
    logic [31:0] rd_bfm_prng = 32'h5e2c_8b71;
    logic [31:0] response_prng0 = 32'h6d2b_79f5;
    logic [31:0] response_prng1 = 32'h1b87_3593;

    logic write_active = 1'b0;
    integer write_owner = 0;
    integer write_txn = 0;
    integer write_beats_expected = 0;
    integer write_beat_index = 0;
    logic write_resp_pending = 1'b0;
    integer write_resp_delay = 0;
    logic [1:0] write_pending_bresp = 2'b00;

    logic read_active = 1'b0;
    integer read_owner = 0;
    integer read_txn = 0;
    integer read_beats_expected = 0;
    integer read_beat_index = 0;
    integer read_gap = 0;

    integer write_rr_expected = 0;
    integer read_rr_expected = 0;
    integer write_contentions = 0;
    integer read_contentions = 0;
    integer write_grants0 = 0;
    integer write_grants1 = 0;
    integer read_grants0 = 0;
    integer read_grants1 = 0;
    integer total_aw = 0;
    integer total_w = 0;
    integer total_b = 0;
    integer total_ar = 0;
    integer total_r = 0;
    integer total_rlast = 0;
    integer early_rlast_releases = 0;
    integer missing_rlast_releases = 0;

    integer aw_stalls = 0;
    integer w_stalls = 0;
    integer b_stalls = 0;
    integer ar_stalls = 0;
    integer r_stalls = 0;
    integer b_delay_cycles = 0;
    integer r_gap_cycles = 0;
    logic saw_parallel_read_write = 1'b0;

    logic held_aw = 1'b0;
    logic [31:0] held_awaddr = '0;
    logic [7:0] held_awlen = '0;
    logic [2:0] held_awsize = '0;
    logic [1:0] held_awburst = '0;
    logic held_w = 1'b0;
    logic [127:0] held_wdata = '0;
    logic [15:0] held_wstrb = '0;
    logic held_wlast = 1'b0;
    logic held_b = 1'b0;
    logic [1:0] held_bresp = '0;
    logic held_ar = 1'b0;
    logic [31:0] held_araddr = '0;
    logic [7:0] held_arlen = '0;
    logic [2:0] held_arsize = '0;
    logic [1:0] held_arburst = '0;
    logic held_r = 1'b0;
    logic [127:0] held_rdata = '0;
    logic [1:0] held_rresp = '0;
    logic held_rlast = 1'b0;

    integer write_decoded_owner;
    integer write_decoded_txn;
    integer read_decoded_owner;
    integer read_decoded_txn;

    c1_axi2_serial_arbiter_128 dut (
        .clk, .rst,
        .s0_awaddr, .s0_awlen, .s0_awsize, .s0_awburst, .s0_awvalid, .s0_awready,
        .s0_wdata, .s0_wstrb, .s0_wlast, .s0_wvalid, .s0_wready,
        .s0_bresp, .s0_bvalid, .s0_bready,
        .s0_araddr, .s0_arlen, .s0_arsize, .s0_arburst, .s0_arvalid, .s0_arready,
        .s0_rdata, .s0_rresp, .s0_rlast, .s0_rvalid, .s0_rready,
        .s1_awaddr, .s1_awlen, .s1_awsize, .s1_awburst, .s1_awvalid, .s1_awready,
        .s1_wdata, .s1_wstrb, .s1_wlast, .s1_wvalid, .s1_wready,
        .s1_bresp, .s1_bvalid, .s1_bready,
        .s1_araddr, .s1_arlen, .s1_arsize, .s1_arburst, .s1_arvalid, .s1_arready,
        .s1_rdata, .s1_rresp, .s1_rlast, .s1_rvalid, .s1_rready,
        .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awvalid, .m_awready,
        .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready,
        .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arvalid, .m_arready,
        .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
    );

    function automatic [31:0] prng_next(input [31:0] state);
        reg feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
        end
    endfunction

    function automatic integer write_beats(input integer master, input integer txn);
        begin
            write_beats = 1 + ((txn*3 + master*5) % 8);
        end
    endfunction

    function automatic [31:0] write_addr(input integer master, input integer txn);
        begin
            write_addr = (master == 0 ? 32'h1000_0000 : 32'h2000_0000) +
                         (txn << 12) + 32'h0000_0100;
        end
    endfunction

    function automatic [2:0] write_size(input integer master, input integer txn);
        begin
            write_size = ((txn + master) % 3 == 0) ? 3'd3 : 3'd4;
        end
    endfunction

    function automatic [1:0] write_burst(input integer master, input integer txn);
        begin
            write_burst = ((txn + master) % 4 == 0) ? 2'b00 : 2'b01;
        end
    endfunction

    function automatic [127:0] write_data_value(
        input integer master,
        input integer txn,
        input integer beat
    );
        reg [31:0] tag;
        begin
            tag = (master << 24) | (txn << 8) | beat;
            write_data_value = {
                32'hd300_0000 ^ tag,
                32'hc200_0000 ^ tag,
                32'hb100_0000 ^ tag,
                32'ha000_0000 ^ tag
            };
        end
    endfunction

    function automatic [15:0] write_strb_value(
        input integer master,
        input integer txn,
        input integer beat
    );
        begin
            case ((master + txn + beat) % 4)
                0: write_strb_value = 16'hffff;
                1: write_strb_value = 16'h0f0f;
                2: write_strb_value = 16'ha5a5;
                default: write_strb_value = 16'h3333;
            endcase
        end
    endfunction

    function automatic [1:0] write_resp_value(input integer master, input integer txn);
        begin
            write_resp_value = (((master == 0) && (txn == 3)) ||
                                ((master == 1) && (txn == 8))) ?
                               2'b10 : 2'b00;
        end
    endfunction

    function automatic integer read_beats(input integer master, input integer txn);
        begin
            read_beats = 1 + ((txn*5 + master) % 8);
        end
    endfunction

    function automatic [31:0] read_addr(input integer master, input integer txn);
        begin
            read_addr = (master == 0 ? 32'h3000_0000 : 32'h4000_0000) +
                        (txn << 12) + 32'h0000_0280;
        end
    endfunction

    function automatic integer read_delivered_beats(
        input integer master,
        input integer txn
    );
        begin
            if ((master == EARLY_RLAST_MASTER) &&
                (txn == EARLY_RLAST_TXN))
                read_delivered_beats = EARLY_RLAST_BEAT + 1;
            else
                read_delivered_beats = read_beats(master, txn);
        end
    endfunction

    function automatic logic read_last_value(
        input integer master,
        input integer txn,
        input integer beat
    );
        begin
            if ((master == EARLY_RLAST_MASTER) &&
                (txn == EARLY_RLAST_TXN))
                read_last_value = (beat == EARLY_RLAST_BEAT);
            else if ((master == MISSING_RLAST_MASTER) &&
                     (txn == MISSING_RLAST_TXN))
                read_last_value = 1'b0;
            else
                read_last_value = (beat == read_beats(master, txn)-1);
        end
    endfunction

    function automatic [2:0] read_size(input integer master, input integer txn);
        begin
            read_size = ((txn + 2*master) % 3 == 1) ? 3'd3 : 3'd4;
        end
    endfunction

    function automatic [1:0] read_burst(input integer master, input integer txn);
        begin
            read_burst = ((txn + master) % 5 == 0) ? 2'b00 : 2'b01;
        end
    endfunction

    function automatic [127:0] read_data_value(
        input integer master,
        input integer txn,
        input integer beat
    );
        reg [31:0] tag;
        begin
            tag = (master << 24) | (txn << 8) | beat;
            read_data_value = {
                32'h7300_0000 ^ tag,
                32'h6200_0000 ^ tag,
                32'h5100_0000 ^ tag,
                32'h4000_0000 ^ tag
            };
        end
    endfunction

    function automatic [1:0] read_resp_value(
        input integer master,
        input integer txn,
        input integer beat
    );
        begin
            read_resp_value = (((master == 0) && (txn == 4) && (beat == 1)) ||
                               ((master == 1) && (txn == 6) &&
                                (beat == read_beats(master, txn)-1))) ?
                              2'b10 : 2'b00;
        end
    endfunction

    task automatic fail(input string message);
        begin
            $display("C1_AXI2_SERIAL_ARBITER_FAIL time=%0t aw=%0d w=%0d b=%0d ar=%0d r=%0d: %s",
                     $time, total_aw, total_w, total_b, total_ar, total_r, message);
            $fatal(1);
            $finish;
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        repeat (6) @(posedge clk);
        #1 rst = 1'b0;
    end

    // Random response back-pressure from both upstream masters.
    always @(negedge clk) begin
        if (rst) begin
            response_prng0 <= 32'h6d2b_79f5;
            response_prng1 <= 32'h1b87_3593;
            s0_bready <= 1'b0;
            s1_bready <= 1'b0;
            s0_rready <= 1'b0;
            s1_rready <= 1'b0;
        end else begin
            response_prng0 <= prng_next(response_prng0);
            response_prng1 <= prng_next(response_prng1);
            s0_bready <= response_prng0[2] ^ response_prng0[9];
            s1_bready <= response_prng1[3] ^ response_prng1[11];
            s0_rready <= response_prng0[5] | response_prng0[13];
            s1_rready <= response_prng1[6] | response_prng1[15];
        end
    end

    // Write-side downstream BFM and protocol scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            m_awready <= 1'b0;
            m_wready <= 1'b0;
            m_bvalid <= 1'b0;
            m_bresp <= 2'b00;
            wr_bfm_prng <= 32'h9137_a4d5;
            write_active = 1'b0;
            write_resp_pending = 1'b0;
            held_aw = 1'b0;
            held_w = 1'b0;
            held_b = 1'b0;
        end else begin
            wr_bfm_prng <= prng_next(wr_bfm_prng);
            m_awready <= wr_bfm_prng[0] && wr_bfm_prng[5];
            m_wready <= wr_bfm_prng[1] ^ wr_bfm_prng[8];

            if (held_aw && (!m_awvalid || (m_awaddr !== held_awaddr) ||
                            (m_awlen !== held_awlen) ||
                            (m_awsize !== held_awsize) ||
                            (m_awburst !== held_awburst)))
                fail("downstream AW payload changed while stalled");
            if (held_w && (!m_wvalid || (m_wdata !== held_wdata) ||
                           (m_wstrb !== held_wstrb) ||
                           (m_wlast !== held_wlast)))
                fail("downstream W payload changed while stalled");
            if (held_b && (!m_bvalid || (m_bresp !== held_bresp)))
                fail("downstream B payload changed while stalled");

            if (m_awvalid && !m_awready)
                aw_stalls = aw_stalls + 1;
            if (m_wvalid && !m_wready)
                w_stalls = w_stalls + 1;
            if (m_bvalid && !m_bready)
                b_stalls = b_stalls + 1;

            if (m_awvalid && m_awready) begin
                if (write_active || write_resp_pending || m_bvalid)
                    fail("write direction switched before prior B completion");
                if (m_awaddr[31:28] == 4'h1)
                    write_decoded_owner = 0;
                else if (m_awaddr[31:28] == 4'h2)
                    write_decoded_owner = 1;
                else
                    fail("AW address does not identify either test master");
                write_decoded_txn = (m_awaddr >> 12) & 8'hff;
                if ((write_decoded_txn < 0) ||
                    (write_decoded_txn >= WRITE_BURSTS_PER_MASTER))
                    fail("decoded AW transaction index is invalid");
                if (m_awaddr !== write_addr(write_decoded_owner, write_decoded_txn) ||
                    m_awlen !== write_beats(write_decoded_owner, write_decoded_txn)-1 ||
                    m_awsize !== write_size(write_decoded_owner, write_decoded_txn) ||
                    m_awburst !== write_burst(write_decoded_owner, write_decoded_txn))
                    fail("AW field passthrough mismatch");

                if (s0_awvalid && s1_awvalid) begin
                    write_contentions = write_contentions + 1;
                    if (write_decoded_owner != write_rr_expected)
                        fail("write round-robin fairness/order mismatch");
                end
                write_rr_expected = 1 - write_decoded_owner;
                if (write_decoded_owner == 0)
                    write_grants0 = write_grants0 + 1;
                else
                    write_grants1 = write_grants1 + 1;

                write_active = 1'b1;
                write_owner = write_decoded_owner;
                write_txn = write_decoded_txn;
                write_beats_expected = write_beats(write_decoded_owner, write_decoded_txn);
                write_beat_index = 0;
                total_aw = total_aw + 1;
            end

            if (m_wvalid && m_wready) begin
                if (!write_active)
                    fail("W beat appeared without its locked AW owner");
                if (m_wdata !== write_data_value(
                        write_owner, write_txn, write_beat_index) ||
                    m_wstrb !== write_strb_value(
                        write_owner, write_txn, write_beat_index) ||
                    m_wlast !== (write_beat_index == write_beats_expected-1))
                    fail("W data/strobe/last routed from the wrong owner or beat");
                total_w = total_w + 1;
                if (m_wlast) begin
                    write_active = 1'b0;
                    write_resp_pending = 1'b1;
                    write_resp_delay = 1 + wr_bfm_prng[12:10];
                    write_pending_bresp = write_resp_value(write_owner, write_txn);
                end else begin
                    write_beat_index = write_beat_index + 1;
                end
            end

            if (m_bvalid) begin
                if (write_owner == 0) begin
                    if (!s0_bvalid || s1_bvalid ||
                        (m_bready !== s0_bready) ||
                        (s0_bresp !== m_bresp))
                        fail("B response was not routed exclusively to master 0");
                end else begin
                    if (!s1_bvalid || s0_bvalid ||
                        (m_bready !== s1_bready) ||
                        (s1_bresp !== m_bresp))
                        fail("B response was not routed exclusively to master 1");
                end
            end

            if (m_bvalid && m_bready) begin
                total_b = total_b + 1;
                m_bvalid <= 1'b0;
            end else if (!m_bvalid && write_resp_pending) begin
                if (write_resp_delay == 0) begin
                    m_bvalid <= 1'b1;
                    m_bresp <= write_pending_bresp;
                    write_resp_pending = 1'b0;
                end else begin
                    write_resp_delay = write_resp_delay - 1;
                    b_delay_cycles = b_delay_cycles + 1;
                end
            end

            held_aw = m_awvalid && !m_awready;
            held_awaddr = m_awaddr;
            held_awlen = m_awlen;
            held_awsize = m_awsize;
            held_awburst = m_awburst;
            held_w = m_wvalid && !m_wready;
            held_wdata = m_wdata;
            held_wstrb = m_wstrb;
            held_wlast = m_wlast;
            held_b = m_bvalid && !m_bready;
            held_bresp = m_bresp;
        end
    end

    // Read-side downstream BFM and protocol scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            m_arready <= 1'b0;
            m_rvalid <= 1'b0;
            m_rdata <= '0;
            m_rresp <= 2'b00;
            m_rlast <= 1'b0;
            rd_bfm_prng <= 32'h5e2c_8b71;
            read_active = 1'b0;
            held_ar = 1'b0;
            held_r = 1'b0;
        end else begin
            rd_bfm_prng <= prng_next(rd_bfm_prng);
            m_arready <= rd_bfm_prng[0] && rd_bfm_prng[6];

            if (held_ar && (!m_arvalid || (m_araddr !== held_araddr) ||
                            (m_arlen !== held_arlen) ||
                            (m_arsize !== held_arsize) ||
                            (m_arburst !== held_arburst)))
                fail("downstream AR payload changed while stalled");
            if (held_r && (!m_rvalid || (m_rdata !== held_rdata) ||
                           (m_rresp !== held_rresp) ||
                           (m_rlast !== held_rlast)))
                fail("downstream R payload changed while stalled");

            if (m_arvalid && !m_arready)
                ar_stalls = ar_stalls + 1;
            if (m_rvalid && !m_rready)
                r_stalls = r_stalls + 1;

            if (m_arvalid && m_arready) begin
                if (read_active || m_rvalid)
                    fail("read direction switched before prior RLAST completion");
                if (m_araddr[31:28] == 4'h3)
                    read_decoded_owner = 0;
                else if (m_araddr[31:28] == 4'h4)
                    read_decoded_owner = 1;
                else
                    fail("AR address does not identify either test master");
                read_decoded_txn = (m_araddr >> 12) & 8'hff;
                if ((read_decoded_txn < 0) ||
                    (read_decoded_txn >= READ_BURSTS_PER_MASTER))
                    fail("decoded AR transaction index is invalid");
                if (m_araddr !== read_addr(read_decoded_owner, read_decoded_txn) ||
                    m_arlen !== read_beats(read_decoded_owner, read_decoded_txn)-1 ||
                    m_arsize !== read_size(read_decoded_owner, read_decoded_txn) ||
                    m_arburst !== read_burst(read_decoded_owner, read_decoded_txn))
                    fail("AR field passthrough mismatch");

                if (s0_arvalid && s1_arvalid) begin
                    read_contentions = read_contentions + 1;
                    if (read_decoded_owner != read_rr_expected)
                        fail("read round-robin fairness/order mismatch");
                end
                read_rr_expected = 1 - read_decoded_owner;
                if (read_decoded_owner == 0)
                    read_grants0 = read_grants0 + 1;
                else
                    read_grants1 = read_grants1 + 1;

                read_active = 1'b1;
                read_owner = read_decoded_owner;
                read_txn = read_decoded_txn;
                read_beats_expected = read_beats(read_decoded_owner, read_decoded_txn);
                read_beat_index = 0;
                read_gap = 1 + rd_bfm_prng[10:8];
                total_ar = total_ar + 1;
            end

            if (m_rvalid) begin
                if (read_owner == 0) begin
                    if (!s0_rvalid || s1_rvalid ||
                        (m_rready !== s0_rready) ||
                        (s0_rdata !== m_rdata) ||
                        (s0_rresp !== m_rresp) ||
                        (s0_rlast !== m_rlast))
                        fail("R beat was not routed exclusively to master 0");
                end else begin
                    if (!s1_rvalid || s0_rvalid ||
                        (m_rready !== s1_rready) ||
                        (s1_rdata !== m_rdata) ||
                        (s1_rresp !== m_rresp) ||
                        (s1_rlast !== m_rlast))
                        fail("R beat was not routed exclusively to master 1");
                end
            end

            if (m_rvalid && m_rready) begin
                total_r = total_r + 1;
                m_rvalid <= 1'b0;
                if ((read_owner == EARLY_RLAST_MASTER) &&
                    (read_txn == EARLY_RLAST_TXN) &&
                    (read_beat_index == EARLY_RLAST_BEAT) && m_rlast)
                    early_rlast_releases = early_rlast_releases + 1;
                if ((read_owner == MISSING_RLAST_MASTER) &&
                    (read_txn == MISSING_RLAST_TXN) &&
                    (read_beat_index == read_beats_expected-1) && !m_rlast)
                    missing_rlast_releases = missing_rlast_releases + 1;
                if (m_rlast) begin
                    total_rlast = total_rlast + 1;
                    read_active = 1'b0;
                end else if (read_beat_index == read_beats_expected-1) begin
                    // ARLEN-implied end: the arbiter must release even when a
                    // malformed slave omits RLAST on this final expected beat.
                    read_active = 1'b0;
                end else begin
                    read_beat_index = read_beat_index + 1;
                    read_gap = rd_bfm_prng[14:12];
                end
            end else if (!m_rvalid && read_active) begin
                if (read_gap == 0) begin
                    m_rvalid <= 1'b1;
                    m_rdata <= read_data_value(
                        read_owner, read_txn, read_beat_index);
                    m_rresp <= read_resp_value(
                        read_owner, read_txn, read_beat_index);
                    m_rlast <= read_last_value(
                        read_owner, read_txn, read_beat_index);
                end else begin
                    read_gap = read_gap - 1;
                    r_gap_cycles = r_gap_cycles + 1;
                end
            end

            held_ar = m_arvalid && !m_arready;
            held_araddr = m_araddr;
            held_arlen = m_arlen;
            held_arsize = m_arsize;
            held_arburst = m_arburst;
            held_r = m_rvalid && !m_rready;
            held_rdata = m_rdata;
            held_rresp = m_rresp;
            held_rlast = m_rlast;

            if ((write_active || write_resp_pending || m_bvalid ||
                 m_awvalid || m_wvalid) &&
                (read_active || m_rvalid || m_arvalid))
                saw_parallel_read_write = 1'b1;
        end
    end

    task automatic drive_write_master(input integer master);
        integer txn;
        integer beat;
        logic accepted;
        logic [1:0] observed_resp;
        begin
            wait (go);
            for (txn = 0; txn < WRITE_BURSTS_PER_MASTER; txn = txn + 1) begin
                @(negedge clk);
                if (master == 0) begin
                    s0_awaddr = write_addr(master, txn);
                    s0_awlen = write_beats(master, txn)-1;
                    s0_awsize = write_size(master, txn);
                    s0_awburst = write_burst(master, txn);
                    s0_awvalid = 1'b1;
                end else begin
                    s1_awaddr = write_addr(master, txn);
                    s1_awlen = write_beats(master, txn)-1;
                    s1_awsize = write_size(master, txn);
                    s1_awburst = write_burst(master, txn);
                    s1_awvalid = 1'b1;
                end
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if ((master == 0 && s0_awvalid && s0_awready) ||
                        (master == 1 && s1_awvalid && s1_awready))
                        accepted = 1'b1;
                end
                @(negedge clk);
                if (master == 0)
                    s0_awvalid = 1'b0;
                else
                    s1_awvalid = 1'b0;

                for (beat = 0; beat < write_beats(master, txn);
                     beat = beat + 1) begin
                    @(negedge clk);
                    if (master == 0) begin
                        s0_wdata = write_data_value(master, txn, beat);
                        s0_wstrb = write_strb_value(master, txn, beat);
                        s0_wlast = (beat == write_beats(master, txn)-1);
                        s0_wvalid = 1'b1;
                    end else begin
                        s1_wdata = write_data_value(master, txn, beat);
                        s1_wstrb = write_strb_value(master, txn, beat);
                        s1_wlast = (beat == write_beats(master, txn)-1);
                        s1_wvalid = 1'b1;
                    end
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if ((master == 0 && s0_wvalid && s0_wready) ||
                            (master == 1 && s1_wvalid && s1_wready))
                            accepted = 1'b1;
                    end
                end
                @(negedge clk);
                if (master == 0) begin
                    s0_wvalid = 1'b0;
                    s0_wlast = 1'b0;
                end else begin
                    s1_wvalid = 1'b0;
                    s1_wlast = 1'b0;
                end

                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if (master == 0 && s0_bvalid && s0_bready) begin
                        observed_resp = s0_bresp;
                        accepted = 1'b1;
                    end else if (master == 1 && s1_bvalid && s1_bready) begin
                        observed_resp = s1_bresp;
                        accepted = 1'b1;
                    end
                end
                if (observed_resp !== write_resp_value(master, txn))
                    fail("BRESP reached the wrong master or transaction");
                if (observed_resp != 2'b00) begin
                    if (master == 0)
                        write_error_seen0 = write_error_seen0 + 1;
                    else
                        write_error_seen1 = write_error_seen1 + 1;
                end
            end
            if (master == 0)
                write_done0 = 1'b1;
            else
                write_done1 = 1'b1;
        end
    endtask

    task automatic drive_read_master(input integer master);
        integer txn;
        integer beat;
        logic accepted;
        logic [127:0] observed_data;
        logic [1:0] observed_resp;
        logic observed_last;
        begin
            wait (go);
            for (txn = 0; txn < READ_BURSTS_PER_MASTER; txn = txn + 1) begin
                @(negedge clk);
                if (master == 0) begin
                    s0_araddr = read_addr(master, txn);
                    s0_arlen = read_beats(master, txn)-1;
                    s0_arsize = read_size(master, txn);
                    s0_arburst = read_burst(master, txn);
                    s0_arvalid = 1'b1;
                end else begin
                    s1_araddr = read_addr(master, txn);
                    s1_arlen = read_beats(master, txn)-1;
                    s1_arsize = read_size(master, txn);
                    s1_arburst = read_burst(master, txn);
                    s1_arvalid = 1'b1;
                end
                accepted = 1'b0;
                while (!accepted) begin
                    @(posedge clk);
                    if ((master == 0 && s0_arvalid && s0_arready) ||
                        (master == 1 && s1_arvalid && s1_arready))
                        accepted = 1'b1;
                end
                @(negedge clk);
                if (master == 0)
                    s0_arvalid = 1'b0;
                else
                    s1_arvalid = 1'b0;

                for (beat = 0; beat < read_delivered_beats(master, txn);
                     beat = beat + 1) begin
                    accepted = 1'b0;
                    while (!accepted) begin
                        @(posedge clk);
                        if (master == 0 && s0_rvalid && s0_rready) begin
                            observed_data = s0_rdata;
                            observed_resp = s0_rresp;
                            observed_last = s0_rlast;
                            accepted = 1'b1;
                        end else if (master == 1 && s1_rvalid && s1_rready) begin
                            observed_data = s1_rdata;
                            observed_resp = s1_rresp;
                            observed_last = s1_rlast;
                            accepted = 1'b1;
                        end
                    end
                    if (observed_data !== read_data_value(master, txn, beat) ||
                        observed_resp !== read_resp_value(master, txn, beat) ||
                        observed_last !== read_last_value(master, txn, beat))
                        fail("R data/response/last reached wrong master or beat");
                    if (observed_resp != 2'b00) begin
                        if (master == 0)
                            read_error_seen0 = read_error_seen0 + 1;
                        else
                            read_error_seen1 = read_error_seen1 + 1;
                    end
                end
            end
            if (master == 0)
                read_done0 = 1'b1;
            else
                read_done1 = 1'b1;
        end
    endtask

    initial drive_write_master(0);
    initial drive_write_master(1);
    initial drive_read_master(0);
    initial drive_read_master(1);

    initial begin
        wait (!rst);
        @(posedge clk);
        #0.1;
        if (m_awvalid || m_wvalid || m_bready || m_arvalid || m_rready ||
            s0_awready || s1_awready || s0_wready || s1_wready ||
            s0_bvalid || s1_bvalid || s0_arready || s1_arready ||
            s0_rvalid || s1_rvalid)
            fail("arbiter did not return to idle after reset");
        @(negedge clk);
        go = 1'b1;

        wait (write_done0 && write_done1 && read_done0 && read_done1);
        wait (!write_active && !write_resp_pending && !m_bvalid &&
              !read_active && !m_rvalid);
        repeat (5) @(posedge clk);

        $display("C1_AXI2_SERIAL_ARBITER_COUNTS aw=%0d w=%0d exp_w=%0d b=%0d ar=%0d r=%0d exp_r=%0d rlast=%0d",
                 total_aw, total_w, EXPECTED_WRITE_BEATS, total_b,
                 total_ar, total_r, EXPECTED_READ_BEATS, total_rlast);

        if (total_aw != 2*WRITE_BURSTS_PER_MASTER ||
            total_b != total_aw || total_w != EXPECTED_WRITE_BEATS)
            fail("final write transaction/beat counts indicate loss or duplication");
        if (total_ar != 2*READ_BURSTS_PER_MASTER ||
            total_rlast != EXPECTED_RLASTS ||
            total_r != EXPECTED_READ_BEATS)
            fail("final read transaction/beat counts indicate loss or duplication");
        if ((early_rlast_releases != 1) ||
            (missing_rlast_releases != 1))
            fail("early/missing RLAST release coverage was not observed once");
        if (write_grants0 != WRITE_BURSTS_PER_MASTER ||
            write_grants1 != WRITE_BURSTS_PER_MASTER ||
            read_grants0 != READ_BURSTS_PER_MASTER ||
            read_grants1 != READ_BURSTS_PER_MASTER)
            fail("one master was starved or granted an extra transaction");
        if ((write_contentions < 2*WRITE_BURSTS_PER_MASTER-2) ||
            (read_contentions < 2*READ_BURSTS_PER_MASTER-2))
            fail("round-robin contention coverage was insufficient");
        if ((write_error_seen0 != 1) || (write_error_seen1 != 1) ||
            (read_error_seen0 != 1) || (read_error_seen1 != 1))
            fail("SLVERR routing coverage was not observed exactly once per master");
        if ((aw_stalls == 0) || (w_stalls == 0) || (b_stalls == 0) ||
            (ar_stalls == 0) || (r_stalls == 0) ||
            (b_delay_cycles == 0) || (r_gap_cycles == 0))
            fail("random ready/valid stall coverage was not observed");
        if (!saw_parallel_read_write)
            fail("read and write directions never progressed concurrently");

        $display("C1_AXI2_SERIAL_ARBITER_PASS wr_bursts=%0d wr_beats=%0d rd_bursts=%0d rd_beats=%0d wr_contentions=%0d rd_contentions=%0d stalls=%0d/%0d/%0d/%0d/%0d early_rlast=%0d missing_rlast=%0d",
                  total_aw, total_w, total_ar, total_r,
                  write_contentions, read_contentions,
                  aw_stalls, w_stalls, b_stalls, ar_stalls, r_stalls,
                  early_rlast_releases, missing_rlast_releases);
        $finish;
    end

    initial begin
        #5_000_000;
        fail("global timeout/deadlock");
    end

endmodule
