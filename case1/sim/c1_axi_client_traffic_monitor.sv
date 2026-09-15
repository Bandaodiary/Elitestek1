`timescale 1ns/1ps

// Board-independent, testbench-only monitor for the seven-client portable
// SoC memory contract.  This module is intentionally attached with a bind
// statement (see the final lines below), so no production RTL ports or state
// are added.  It measures accepted AXI channel handshakes and the maximum
// consecutive cycles for which each client is presenting a request while the
// serial arbiter withholds READY.
//
// The monitor is a traffic-shape gate, not a throughput signoff.  It proves
// that the real portable top exercised the expected leaf/client mapping and
// that no client remained indefinitely starved under the DDR BFM used by the
// small-frame integration bench.  It deliberately does not infer FPGA LUT,
// BRAM or timing usage.
module c1_axi_client_traffic_monitor #(
    parameter integer CLIENTS = 7,
    parameter integer MAX_CONSECUTIVE_WAIT = 1_000_000
) (
    input logic clk,
    input logic rst,
    input logic [CLIENTS-1:0] awvalid,
    input logic [CLIENTS-1:0] awready,
    input logic [CLIENTS-1:0] wvalid,
    input logic [CLIENTS-1:0] wready,
    input logic [CLIENTS-1:0] bvalid,
    input logic [CLIENTS-1:0] bready,
    input logic [CLIENTS-1:0] arvalid,
    input logic [CLIENTS-1:0] arready,
    input logic [CLIENTS-1:0] rvalid,
    input logic [CLIENTS-1:0] rready,
    input logic job_done,
    input logic display_done,
    input logic system_busy
);

`ifdef C1_TWO_FRAME
    localparam integer REQUIRED_JOB_COMPLETIONS = 2;
`else
    localparam integer REQUIRED_JOB_COMPLETIONS = 1;
`endif

    // Client map is frozen by c1_r1_portable_soc:
    //   0 boardless frame job, 1 capture writer, 2 parameter loader,
    //   3 capture table reader, 4/5 display original/styled readers,
    //   6 tensor/cache bridge.
    // The tensor/cache leaf may legally be read-only for a particular
    // descriptor image, so its write directions are reported but optional.
    localparam logic [CLIENTS-1:0] REQUIRE_AW = 7'b0000011;
    localparam logic [CLIENTS-1:0] REQUIRE_W  = 7'b0000011;
    localparam logic [CLIENTS-1:0] REQUIRE_B  = 7'b0000011;
    localparam logic [CLIENTS-1:0] REQUIRE_AR = 7'b1111101;
    localparam logic [CLIENTS-1:0] REQUIRE_R  = 7'b1111101;

    integer aw_count [0:CLIENTS-1];
    integer w_count  [0:CLIENTS-1];
    integer b_count  [0:CLIENTS-1];
    integer ar_count [0:CLIENTS-1];
    integer r_count  [0:CLIENTS-1];
    integer aw_wait_total [0:CLIENTS-1];
    integer w_wait_total  [0:CLIENTS-1];
    integer ar_wait_total [0:CLIENTS-1];
    integer b_wait_total  [0:CLIENTS-1];
    integer r_wait_total  [0:CLIENTS-1];
    integer aw_wait_run [0:CLIENTS-1];
    integer w_wait_run  [0:CLIENTS-1];
    integer ar_wait_run [0:CLIENTS-1];
    integer b_wait_run  [0:CLIENTS-1];
    integer r_wait_run  [0:CLIENTS-1];
    integer aw_wait_max [0:CLIENTS-1];
    integer w_wait_max  [0:CLIENTS-1];
    integer ar_wait_max [0:CLIENTS-1];
    integer b_wait_max  [0:CLIENTS-1];
    integer r_wait_max  [0:CLIENTS-1];
    integer i;
    logic armed_q;
    logic display_seen_q;
    logic reported_q;
    integer job_done_count_q;

    always @(posedge clk) begin
        if (rst) begin
            armed_q    <= 1'b0;
            display_seen_q <= 1'b0;
            reported_q <= 1'b0;
            job_done_count_q <= 0;
            for (i = 0; i < CLIENTS; i = i + 1) begin
                aw_count[i] <= 0; w_count[i] <= 0; b_count[i] <= 0;
                ar_count[i] <= 0; r_count[i] <= 0;
                aw_wait_total[i] <= 0; w_wait_total[i] <= 0;
                ar_wait_total[i] <= 0;
                b_wait_total[i] <= 0; r_wait_total[i] <= 0;
                aw_wait_run[i] <= 0; w_wait_run[i] <= 0; ar_wait_run[i] <= 0;
                b_wait_run[i] <= 0; r_wait_run[i] <= 0;
                aw_wait_max[i] <= 0; w_wait_max[i] <= 0; ar_wait_max[i] <= 0;
                b_wait_max[i] <= 0; r_wait_max[i] <= 0;
            end
        end else begin
            if (job_done) begin
                armed_q <= 1'b1;
                job_done_count_q <= job_done_count_q + 1;
            end
            if ((armed_q || job_done) && display_done)
                display_seen_q <= 1'b1;

            for (i = 0; i < CLIENTS; i = i + 1) begin
                if (awvalid[i] && awready[i]) aw_count[i] <= aw_count[i] + 1;
                if (wvalid[i]  && wready[i])  w_count[i]  <= w_count[i] + 1;
                if (bvalid[i]  && bready[i])  b_count[i]  <= b_count[i] + 1;
                if (arvalid[i] && arready[i]) ar_count[i] <= ar_count[i] + 1;
                if (rvalid[i]  && rready[i])  r_count[i]  <= r_count[i] + 1;

                if (bvalid[i] && !bready[i]) begin
                    b_wait_total[i] <= b_wait_total[i] + 1;
                    b_wait_run[i] <= b_wait_run[i] + 1;
                    if ((b_wait_run[i] + 1) > b_wait_max[i])
                        b_wait_max[i] <= b_wait_run[i] + 1;
                end else begin
                    b_wait_run[i] <= 0;
                end

                if (rvalid[i] && !rready[i]) begin
                    r_wait_total[i] <= r_wait_total[i] + 1;
                    r_wait_run[i] <= r_wait_run[i] + 1;
                    if ((r_wait_run[i] + 1) > r_wait_max[i])
                        r_wait_max[i] <= r_wait_run[i] + 1;
                end else begin
                    r_wait_run[i] <= 0;
                end

                if (awvalid[i] && !awready[i]) begin
                    aw_wait_total[i] <= aw_wait_total[i] + 1;
                    aw_wait_run[i] <= aw_wait_run[i] + 1;
                    if ((aw_wait_run[i] + 1) > aw_wait_max[i])
                        aw_wait_max[i] <= aw_wait_run[i] + 1;
                end else begin
                    aw_wait_run[i] <= 0;
                end

                if (wvalid[i] && !wready[i]) begin
                    w_wait_total[i] <= w_wait_total[i] + 1;
                    w_wait_run[i] <= w_wait_run[i] + 1;
                    if ((w_wait_run[i] + 1) > w_wait_max[i])
                        w_wait_max[i] <= w_wait_run[i] + 1;
                end else begin
                    w_wait_run[i] <= 0;
                end

                if (arvalid[i] && !arready[i]) begin
                    ar_wait_total[i] <= ar_wait_total[i] + 1;
                    ar_wait_run[i] <= ar_wait_run[i] + 1;
                    if ((ar_wait_run[i] + 1) > ar_wait_max[i])
                        ar_wait_max[i] <= ar_wait_run[i] + 1;
                end else begin
                    ar_wait_run[i] <= 0;
                end

            end

            // display_done is the final foreground/display fence used by the
            // cache DDR BFM.  system_busy additionally guarantees that the
            // tensor bridge/cache has retired its last response before the
            // counts are checked.
            if (((job_done_count_q + (job_done ? 1 : 0)) >=
                 REQUIRED_JOB_COMPLETIONS) &&
                (display_seen_q || ((armed_q || job_done) && display_done)) &&
                !system_busy && !reported_q) begin : report_once
                logic failed;
                logic traffic_ok;
                failed = 1'b0;
                traffic_ok = 1'b1;
                for (i = 0; i < CLIENTS; i = i + 1) begin
                    if (REQUIRE_AW[i] && (aw_count[i] == 0)) begin
                        failed = 1'b1; traffic_ok = 1'b0;
                    end
                    if (REQUIRE_W[i] && (w_count[i] == 0)) begin
                        failed = 1'b1; traffic_ok = 1'b0;
                    end
                    if (REQUIRE_B[i] && (b_count[i] == 0)) begin
                        failed = 1'b1; traffic_ok = 1'b0;
                    end
                    if (REQUIRE_AR[i] && (ar_count[i] == 0)) begin
                        failed = 1'b1; traffic_ok = 1'b0;
                    end
                    if (REQUIRE_R[i] && (r_count[i] == 0)) begin
                        failed = 1'b1; traffic_ok = 1'b0;
                    end
                    if (aw_wait_max[i] > MAX_CONSECUTIVE_WAIT) failed = 1'b1;
                    if (w_wait_max[i]  > MAX_CONSECUTIVE_WAIT) failed = 1'b1;
                    if (ar_wait_max[i] > MAX_CONSECUTIVE_WAIT) failed = 1'b1;
                    if (b_wait_max[i]  > MAX_CONSECUTIVE_WAIT) failed = 1'b1;
                    if (r_wait_max[i]  > MAX_CONSECUTIVE_WAIT) failed = 1'b1;
                end
                $display("C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_STATS c0=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c1=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c2=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c3=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c4=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c5=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d c6=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                         aw_count[0],w_count[0],b_count[0],ar_count[0],r_count[0],aw_wait_max[0],w_wait_max[0],ar_wait_max[0],ar_wait_total[0],
                         aw_count[1],w_count[1],b_count[1],ar_count[1],r_count[1],aw_wait_max[1],w_wait_max[1],ar_wait_max[1],ar_wait_total[1],
                         aw_count[2],w_count[2],b_count[2],ar_count[2],r_count[2],aw_wait_max[2],w_wait_max[2],ar_wait_max[2],ar_wait_total[2],
                         aw_count[3],w_count[3],b_count[3],ar_count[3],r_count[3],aw_wait_max[3],w_wait_max[3],ar_wait_max[3],ar_wait_total[3],
                         aw_count[4],w_count[4],b_count[4],ar_count[4],r_count[4],aw_wait_max[4],w_wait_max[4],ar_wait_max[4],ar_wait_total[4],
                         aw_count[5],w_count[5],b_count[5],ar_count[5],r_count[5],aw_wait_max[5],w_wait_max[5],ar_wait_max[5],ar_wait_total[5],
                         aw_count[6],w_count[6],b_count[6],ar_count[6],r_count[6],aw_wait_max[6],w_wait_max[6],ar_wait_max[6],ar_wait_total[6]);
                $display("C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_RESPONSE_HOLD_MAX b0=%0d b1=%0d b2=%0d b3=%0d b4=%0d b5=%0d b6=%0d r0=%0d r1=%0d r2=%0d r3=%0d r4=%0d r5=%0d r6=%0d",
                         b_wait_max[0],b_wait_max[1],b_wait_max[2],b_wait_max[3],b_wait_max[4],b_wait_max[5],b_wait_max[6],
                         r_wait_max[0],r_wait_max[1],r_wait_max[2],r_wait_max[3],r_wait_max[4],r_wait_max[5],r_wait_max[6]);
                if (traffic_ok)
                    $display("C1_R1_PORTABLE_SOC_AXI_CLIENT_TRAFFIC_SHAPE_PASS clients=%0d",
                             CLIENTS);
                else
                    $display("C1_R1_PORTABLE_SOC_AXI_CLIENT_TRAFFIC_SHAPE_FAIL clients=%0d",
                             CLIENTS);
                if (failed)
                    $fatal(1, "portable SoC client traffic/arbiter wait gate failed");
                $display("C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS clients=%0d max_wait_bound=%0d job_completions=%0d",
                         CLIENTS, MAX_CONSECUTIVE_WAIT, REQUIRED_JOB_COMPLETIONS);
                reported_q <= 1'b1;
            end
        end
    end
endmodule

// Bind is deliberately kept in the monitor source, rather than in the
// portable SoC, so normal synthesis and all non-gated simulations are
// unchanged.  The bind target exposes the real seven-client vectors that feed
// c1_axi_n_serial_arbiter_128.
bind c1_r1_portable_soc c1_axi_client_traffic_monitor #(
    .CLIENTS(7), .MAX_CONSECUTIVE_WAIT(1_000_000)
) u_axi_client_traffic_monitor (
    .clk(core_clk), .rst(core_rst),
    .awvalid(axi_s_awvalid), .awready(axi_s_awready),
    .wvalid(axi_s_wvalid), .wready(axi_s_wready),
    .bvalid(axi_s_bvalid), .bready(axi_s_bready),
    .arvalid(axi_s_arvalid), .arready(axi_s_arready),
    .rvalid(axi_s_rvalid), .rready(axi_s_rready),
    .job_done(control_done_event),
    .display_done(display_prefetch_done),
    .system_busy(system_busy)
);
