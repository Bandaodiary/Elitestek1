`timescale 1ns/1ps

// Small procedural AXI client used only by the boardless fabric preflight.
// It deliberately keeps one ID-less burst in flight and holds every VALID
// payload stable while the shared arbiter or the DDR BFM applies backpressure.
module c1_native_fabric_client #(
    parameter integer CLIENT_ID = 1,
    parameter integer TXNS = 3,
    parameter integer BURST_BEATS = 4
) (
    input  logic clk,
    input  logic rst,
    output logic [31:0] awaddr,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic [1:0] awburst,
    output logic awvalid,
    input  logic awready,
    output logic [127:0] wdata,
    output logic [15:0] wstrb,
    output logic wlast,
    output logic wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready,
    output logic [31:0] araddr,
    output logic [7:0] arlen,
    output logic [2:0] arsize,
    output logic [1:0] arburst,
    output logic arvalid,
    input logic arready,
    input logic [127:0] rdata,
    input logic [1:0] rresp,
    input logic rlast,
    input logic rvalid,
    output logic rready,
    output logic done,
    output logic error,
    output logic [31:0] aw_count,
    output logic [31:0] w_count,
    output logic [31:0] b_count,
    output logic [31:0] ar_count,
    output logic [31:0] r_count,
    output logic [31:0] max_aw_wait,
    output logic [31:0] max_w_wait,
    output logic [31:0] max_b_wait,
    output logic [31:0] max_ar_wait,
    output logic [31:0] max_r_wait
);
    localparam logic [31:0] CLIENT_BASE = 32'h1000_0000 + CLIENT_ID*32'h0010_0000;
    typedef enum logic [3:0] {ST_AW, ST_W, ST_B, ST_AR, ST_R, ST_DONE, ST_FAIL} state_t;
    state_t state_q;
    integer txn_q;
    integer beat_q;
    integer aw_wait_q, w_wait_q, b_wait_q, ar_wait_q, r_wait_q;
    integer max_aw_q, max_w_q, max_b_q, max_ar_q, max_r_q;
    integer aw_n_q, w_n_q, b_n_q, ar_n_q, r_n_q;

    function automatic [31:0] txn_addr(input integer t);
        txn_addr = CLIENT_BASE + t*32'h0000_0100;
    endfunction
    function automatic [127:0] txn_data(input integer t, input integer b);
        txn_data = {32'hc100_0000 | CLIENT_ID,
                    32'hd200_0000 | t,
                    32'he300_0000 | (CLIENT_ID << 8) | b,
                    32'hf400_00a5 | (CLIENT_ID << 4) | b};
    endfunction

    always_comb begin
        awaddr = txn_addr(txn_q);
        awlen = BURST_BEATS-1;
        awsize = 3'd4;
        awburst = 2'b01;
        awvalid = (state_q == ST_AW);
        wdata = txn_data(txn_q, beat_q);
        wstrb = 16'hffff;
        wlast = (beat_q == BURST_BEATS-1);
        wvalid = (state_q == ST_W);
        bready = (state_q == ST_B);
        araddr = txn_addr(txn_q);
        arlen = BURST_BEATS-1;
        arsize = 3'd4;
        arburst = 2'b01;
        arvalid = (state_q == ST_AR);
        rready = (state_q == ST_R);
        done = (state_q == ST_DONE);
        error = (state_q == ST_FAIL);
        aw_count = aw_n_q; w_count = w_n_q; b_count = b_n_q;
        ar_count = ar_n_q; r_count = r_n_q;
        max_aw_wait = max_aw_q; max_w_wait = max_w_q;
        max_b_wait = max_b_q; max_ar_wait = max_ar_q; max_r_wait = max_r_q;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= ST_AW;
            txn_q <= 0;
            beat_q <= 0;
            aw_wait_q <= 0; w_wait_q <= 0; b_wait_q <= 0;
            ar_wait_q <= 0; r_wait_q <= 0;
            max_aw_q <= 0; max_w_q <= 0; max_b_q <= 0; max_ar_q <= 0; max_r_q <= 0;
            aw_n_q <= 0; w_n_q <= 0; b_n_q <= 0; ar_n_q <= 0; r_n_q <= 0;
        end else begin
            if (awvalid && !awready) begin aw_wait_q <= aw_wait_q+1; if (aw_wait_q+1 > max_aw_q) max_aw_q <= aw_wait_q+1; end
            else aw_wait_q <= 0;
            if (wvalid && !wready) begin w_wait_q <= w_wait_q+1; if (w_wait_q+1 > max_w_q) max_w_q <= w_wait_q+1; end
            else w_wait_q <= 0;
            if (bready && !bvalid) begin b_wait_q <= b_wait_q+1; if (b_wait_q+1 > max_b_q) max_b_q <= b_wait_q+1; end
            else b_wait_q <= 0;
            if (arvalid && !arready) begin ar_wait_q <= ar_wait_q+1; if (ar_wait_q+1 > max_ar_q) max_ar_q <= ar_wait_q+1; end
            else ar_wait_q <= 0;
            if (rready && !rvalid) begin r_wait_q <= r_wait_q+1; if (r_wait_q+1 > max_r_q) max_r_q <= r_wait_q+1; end
            else r_wait_q <= 0;

            case (state_q)
                ST_AW: if (awvalid && awready) begin aw_n_q <= aw_n_q+1; beat_q <= 0; state_q <= ST_W; end
                ST_W: if (wvalid && wready) begin
                    w_n_q <= w_n_q+1;
                    if (wlast) state_q <= ST_B;
                    else beat_q <= beat_q+1;
                end
                ST_B: if (bvalid && bready) begin
                    if (bresp != 2'b00) state_q <= ST_FAIL;
                    else begin b_n_q <= b_n_q+1; state_q <= ST_AR; beat_q <= 0; end
                end
                ST_AR: if (arvalid && arready) begin ar_n_q <= ar_n_q+1; beat_q <= 0; state_q <= ST_R; end
                ST_R: if (rvalid && rready) begin
                    if (rresp != 2'b00 || rdata !== txn_data(txn_q, beat_q) ||
                        (rlast !== (beat_q == BURST_BEATS-1))) begin
                        state_q <= ST_FAIL;
                    end else begin
                        r_n_q <= r_n_q+1;
                        if (rlast) begin
                            if (txn_q == TXNS-1) state_q <= ST_DONE;
                            else begin txn_q <= txn_q+1; beat_q <= 0; state_q <= ST_AW; end
                        end else beat_q <= beat_q+1;
                    end
                end
                ST_DONE, ST_FAIL: state_q <= state_q;
                default: state_q <= ST_FAIL;
            endcase
        end
    end
endmodule

// Boardless fabric preflight.  Client 0 is the real 640x480
// c1_r1_boardless_frame_system.  Clients 1..6 are independent procedural
// AXI traffic generators.  All seven clients share the real ID-less
// c1_axi_n_serial_arbiter_128 and one delayed/back-pressured associative DDR
// model.  The opposite-edge READY shell is confined to this simulation BFM.
module tb_c1_r1_native_boardless_fabric;
`ifdef NATIVE_FABRIC_REAL_PARAMETER
    // Optional next-stage mode: client slot 1 is the real parameter-arena
    // AXI reader/loader.  The default build remains the previously verified
    // six-procedural-client fabric preflight.
    localparam bit REAL_PARAMETER_CLIENT = 1'b1;
`else
    localparam bit REAL_PARAMETER_CLIENT = 1'b0;
`endif
    localparam integer CLIENTS = 7;
    localparam integer SYNTH_CLIENTS = 6;
    localparam integer MAX_WIDTH = 640;
    localparam integer MAX_STAGES = 22;
    localparam integer COUNT_BITS = 16;
    localparam integer GENERATION_BITS = 8;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer STRIDE = FRAME_W*4;
    localparam integer FRAME_BYTES = STRIDE*FRAME_H;
    localparam integer ROW_BEATS = FRAME_W/4;
    localparam integer FRAME_BEATS = FRAME_H*ROW_BEATS;
    localparam integer FRAME_BURSTS = FRAME_H*((ROW_BEATS+15)/16);
    localparam integer PARAM_BYTES = 16896;
    localparam integer PARAM_WORDS = PARAM_BYTES/16;
    localparam integer PARAM_BURSTS = (PARAM_WORDS+15)/16;
    localparam integer PARAM_ADDR_W = (PARAM_WORDS <= 1) ? 1 : $clog2(PARAM_WORDS);
    localparam logic [31:0] PARAM_BASE = 32'h0080_0000;
    localparam logic [31:0] INPUT_TABLE_BASE = 32'h0008_0000;
    localparam logic [31:0] OUTPUT_TABLE_BASE = 32'h0009_0000;
    localparam logic [31:0] DESCRIPTOR_BASE = 32'h000a_0000;
    localparam logic [31:0] INPUT_FRAME_BASE = 32'h0010_0000;
    localparam logic [31:0] OUTPUT_FRAME_BASE = 32'h0060_0000;
    localparam logic [23:0] PIXEL_RGB = 24'h21_83_d7;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    // Boardless-job control and CNN seam.
    logic job_start_valid = 1'b0, job_start_ready, job_abort = 1'b0;
    logic [63:0] job_input_table_base = INPUT_TABLE_BASE, job_output_table_base = OUTPUT_TABLE_BASE;
    logic [1:0] job_input_buffer_index = 0, job_output_buffer_index = 0;
    logic [15:0] job_width_pixels = FRAME_W, job_height_lines = FRAME_H;
    logic [31:0] job_descriptor_base = DESCRIPTOR_BASE;
    logic [COUNT_BITS-1:0] job_descriptor_count = MAX_STAGES;
    logic [31:0] job_cycle_budget = 32'd100_000_000;
    logic signed [31:0] job_x_step_q16 = 32'sh0001_0000, job_y_step_q16 = 32'sh0001_0000;
    logic signed [31:0] job_x_phase0_q16 = 0, job_y_phase0_q16 = 0;
    logic busy, job_done, job_error, job_aborted;
    logic [7:0] error_code; logic [31:0] error_address;
    logic [31:0] resolved_input_base, resolved_input_stride, resolved_output_base, resolved_output_stride;
    logic [15:0] resolved_input_width, resolved_input_height, resolved_output_width, resolved_output_height;
    logic active_config_bank; logic [COUNT_BITS-1:0] active_config_count;
    logic [GENERATION_BITS-1:0] active_config_generation;
    logic stage_dispatch_complete, stage_config_valid, stage_config_ready;
    logic [COUNT_BITS-1:0] stage_config_index; logic [511:0] stage_config_descriptor;
    logic [GENERATION_BITS-1:0] stage_config_generation;
    logic cnn_start_valid, cnn_start_ready = 1'b1, cnn_abort;
    logic cnn_error = 1'b0; logic [7:0] cnn_error_code = 8'h25;
    logic cnn_in_valid, cnn_in_ready, cnn_in_sof, cnn_in_eol, cnn_in_eof;
    logic [63:0] cnn_in_data_s8; logic [15:0] cnn_in_x, cnn_in_y;
    logic cnn_out_valid, cnn_out_ready, cnn_out_sof, cnn_out_eol, cnn_out_eof;
    logic [63:0] cnn_out_data_s8; logic [15:0] cnn_out_x, cnn_out_y;

    // Optional real client-1 parameter-arena path.  It is intentionally
    // self-contained in this TB: no production top-level port is changed.
    logic param_start_valid = 1'b0, param_start_ready, param_abort = 1'b0;
    logic param_busy, param_done, param_error, param_aborted;
    logic [3:0] param_error_code; logic [31:0] param_error_address;
    logic param_bank_load_start, param_bank_load_start_ready;
    logic param_bank_load_valid, param_bank_load_ready;
    logic [127:0] param_bank_load_data; logic param_bank_load_last, param_bank_load_abort;
    logic param_bank_busy, param_bank_done, param_bank_aborted, param_bank_error;
    logic param_active_valid, param_active_bank; logic [31:0] param_generation;
    logic param_rd_en = 1'b0; logic [PARAM_ADDR_W-1:0] param_rd_addr = '0;
    logic param_rd_valid, param_rd_error; logic [127:0] param_rd_data;
    logic [31:0] param_araddr; logic [7:0] param_arlen; logic [2:0] param_arsize;
    logic [1:0] param_arburst; logic param_arvalid, param_arready;
    logic [127:0] param_rdata; logic [1:0] param_rresp; logic param_rlast;
    logic param_rvalid, param_rready;
    logic param_done_seen = 1'b0, param_error_seen = 1'b0;

    // Arbiter client arrays.  Client 0 is populated from the real boardless
    // top; clients 1..6 are driven by generated c1_native_fabric_client.
    logic [CLIENTS-1:0][31:0] s_awaddr, s_araddr;
    logic [CLIENTS-1:0][7:0] s_awlen, s_arlen;
    logic [CLIENTS-1:0][2:0] s_awsize, s_arsize;
    logic [CLIENTS-1:0][1:0] s_awburst, s_arburst;
    logic [CLIENTS-1:0] s_awvalid, s_awready, s_wlast, s_wvalid, s_wready;
    logic [CLIENTS-1:0][127:0] s_wdata, s_rdata;
    logic [CLIENTS-1:0][15:0] s_wstrb;
    logic [CLIENTS-1:0][1:0] s_bresp, s_rresp;
    logic [CLIENTS-1:0] s_bvalid, s_bready, s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
    logic [31:0] job_awaddr, job_araddr; logic [7:0] job_awlen, job_arlen;
    logic [2:0] job_awsize, job_arsize; logic [1:0] job_awburst, job_arburst;
    logic job_awvalid, job_awready, job_wlast, job_wvalid, job_wready;
    logic [127:0] job_wdata, job_rdata; logic [15:0] job_wstrb;
    logic [1:0] job_bresp, job_rresp; logic job_bvalid, job_bready, job_arvalid, job_arready, job_rlast, job_rvalid, job_rready;

    logic [SYNTH_CLIENTS-1:0][31:0] c_awaddr, c_araddr, c_aw_count, c_w_count, c_b_count, c_ar_count, c_r_count;
    logic [SYNTH_CLIENTS-1:0][7:0] c_awlen, c_arlen;
    logic [SYNTH_CLIENTS-1:0][2:0] c_awsize, c_arsize;
    logic [SYNTH_CLIENTS-1:0][1:0] c_awburst, c_arburst;
    logic [SYNTH_CLIENTS-1:0] c_awvalid, c_awready, c_wlast, c_wvalid, c_wready;
    logic [SYNTH_CLIENTS-1:0][127:0] c_wdata, c_rdata;
    logic [SYNTH_CLIENTS-1:0][15:0] c_wstrb;
    logic [SYNTH_CLIENTS-1:0][1:0] c_bresp, c_rresp;
    logic [SYNTH_CLIENTS-1:0] c_bvalid, c_bready, c_arvalid, c_arready, c_rlast, c_rvalid, c_rready;
    logic [SYNTH_CLIENTS-1:0] c_done, c_error;
    logic [SYNTH_CLIENTS-1:0][31:0] c_max_aw_wait, c_max_w_wait, c_max_b_wait, c_max_ar_wait, c_max_r_wait;

    // Real boardless frame system.
    c1_r1_boardless_frame_system #(.MAX_WIDTH(MAX_WIDTH), .MAX_STAGES(MAX_STAGES),
        .COUNT_BITS(COUNT_BITS), .GENERATION_BITS(GENERATION_BITS),
        .READ_TIMEOUT_CYCLES(256), .SYNC_READ(1'b1), .FAST_WIDE(1'b0)) u_job (
        .job_input_width_pixels(16'd0),.job_input_height_lines(16'd0),
        .clk, .rst, .job_start_valid, .job_start_ready, .job_abort,
        .job_input_table_base, .job_output_table_base, .job_input_buffer_index,
        .job_output_buffer_index, .job_width_pixels, .job_height_lines,
        .job_descriptor_base, .job_descriptor_count, .job_cycle_budget,
        .job_x_step_q16, .job_y_step_q16, .job_x_phase0_q16, .job_y_phase0_q16,
        .busy, .job_done, .job_error, .job_aborted, .error_code, .error_address,
        .resolved_input_base, .resolved_input_stride, .resolved_input_width,
        .resolved_input_height, .resolved_output_base, .resolved_output_stride,
        .resolved_output_width, .resolved_output_height, .active_config_bank,
        .active_config_count, .active_config_generation, .stage_dispatch_complete,
        .stage_config_valid, .stage_config_ready, .stage_config_index,
        .stage_config_descriptor, .stage_config_generation, .cnn_start_valid,
        .cnn_start_ready, .cnn_abort, .cnn_error, .cnn_error_code,
        .cnn_in_valid, .cnn_in_ready, .cnn_in_data_s8, .cnn_in_x, .cnn_in_y,
        .cnn_in_sof, .cnn_in_eol, .cnn_in_eof, .cnn_out_valid, .cnn_out_ready,
        .cnn_out_data_s8, .cnn_out_x, .cnn_out_y, .cnn_out_sof, .cnn_out_eol,
        .cnn_out_eof, .m_axi_awaddr(job_awaddr), .m_axi_awlen(job_awlen),
        .m_axi_awsize(job_awsize), .m_axi_awburst(job_awburst),
        .m_axi_awvalid(job_awvalid), .m_axi_awready(job_awready),
        .m_axi_wdata(job_wdata), .m_axi_wstrb(job_wstrb), .m_axi_wlast(job_wlast),
        .m_axi_wvalid(job_wvalid), .m_axi_wready(job_wready), .m_axi_bresp(job_bresp),
        .m_axi_bvalid(job_bvalid), .m_axi_bready(job_bready), .m_axi_araddr(job_araddr),
        .m_axi_arlen(job_arlen), .m_axi_arsize(job_arsize), .m_axi_arburst(job_arburst),
        .m_axi_arvalid(job_arvalid), .m_axi_arready(job_arready), .m_axi_rdata(job_rdata),
        .m_axi_rresp(job_rresp), .m_axi_rlast(job_rlast), .m_axi_rvalid(job_rvalid),
        .m_axi_rready(job_rready));

    generate
        for (genvar cg=0; cg<SYNTH_CLIENTS; cg=cg+1) begin : GEN_FABRIC_CLIENTS
            if (REAL_PARAMETER_CLIENT && (cg == 0)) begin : GEN_REAL_PARAMETER
                // Client slot 1 is a production AXI leaf in this mode.  Its
                // bank is local to the TB so the test proves the loader's
                // burst/backpressure/commit path without changing a top port.
                c1_r1_parameter_bank #(
                    .ARENA_BYTES(PARAM_BYTES), .READ_PORTS(1),
                    .ADDR_W(PARAM_ADDR_W)
                ) u_param_bank (
                    .clk, .rst,
                    .load_start(param_bank_load_start),
                    .load_start_ready(param_bank_load_start_ready),
                    .load_valid(param_bank_load_valid),
                    .load_ready(param_bank_load_ready),
                    .load_data(param_bank_load_data),
                    .load_last(param_bank_load_last),
                    .load_abort(param_bank_load_abort),
                    .load_busy(param_bank_busy),
                    .load_done(param_bank_done),
                    .load_aborted(param_bank_aborted),
                    .load_error(param_bank_error),
                    .load_error_code(),
                    .active_valid(param_active_valid),
                    .active_bank(param_active_bank),
                    .generation(param_generation),
                    .rd_en(param_rd_en), .rd_addr(param_rd_addr),
                    .rd_valid(param_rd_valid), .rd_error(param_rd_error),
                    .rd_data(param_rd_data)
                );
                c1_axi_parameter_loader #(.ARENA_BYTES(PARAM_BYTES)) u_param_loader (
                    .clk, .rst,
                    .start_valid(param_start_valid),
                    .start_ready(param_start_ready),
                    .start_base_addr(PARAM_BASE), .abort(param_abort),
                    .busy(param_busy), .done(param_done), .error(param_error),
                    .aborted(param_aborted), .error_code(param_error_code),
                    .error_address(param_error_address),
                    .bank_load_start(param_bank_load_start),
                    .bank_load_start_ready(param_bank_load_start_ready),
                    .bank_load_valid(param_bank_load_valid),
                    .bank_load_ready(param_bank_load_ready),
                    .bank_load_data(param_bank_load_data),
                    .bank_load_last(param_bank_load_last),
                    .bank_load_abort(param_bank_load_abort),
                    .bank_load_busy(param_bank_busy),
                    .bank_load_done(param_bank_done),
                    .bank_load_aborted(param_bank_aborted),
                    .bank_load_error(param_bank_error),
                    .m_axi_araddr(param_araddr), .m_axi_arlen(param_arlen),
                    .m_axi_arsize(param_arsize), .m_axi_arburst(param_arburst),
                    .m_axi_arvalid(param_arvalid), .m_axi_arready(param_arready),
                    .m_axi_rdata(param_rdata), .m_axi_rresp(param_rresp),
                    .m_axi_rlast(param_rlast), .m_axi_rvalid(param_rvalid),
                    .m_axi_rready(param_rready)
                );
            end else begin : GEN_SYNTHETIC
                c1_native_fabric_client #(.CLIENT_ID(cg+1), .TXNS(3), .BURST_BEATS(4)) u_client (
                    .clk, .rst, .awaddr(c_awaddr[cg]), .awlen(c_awlen[cg]), .awsize(c_awsize[cg]),
                    .awburst(c_awburst[cg]), .awvalid(c_awvalid[cg]), .awready(c_awready[cg]),
                    .wdata(c_wdata[cg]), .wstrb(c_wstrb[cg]), .wlast(c_wlast[cg]),
                    .wvalid(c_wvalid[cg]), .wready(c_wready[cg]), .bresp(c_bresp[cg]),
                    .bvalid(c_bvalid[cg]), .bready(c_bready[cg]), .araddr(c_araddr[cg]),
                    .arlen(c_arlen[cg]), .arsize(c_arsize[cg]), .arburst(c_arburst[cg]),
                    .arvalid(c_arvalid[cg]), .arready(c_arready[cg]), .rdata(c_rdata[cg]),
                    .rresp(c_rresp[cg]), .rlast(c_rlast[cg]), .rvalid(c_rvalid[cg]),
                    .rready(c_rready[cg]), .done(c_done[cg]), .error(c_error[cg]),
                    .aw_count(c_aw_count[cg]), .w_count(c_w_count[cg]), .b_count(c_b_count[cg]),
                    .ar_count(c_ar_count[cg]), .r_count(c_r_count[cg]),
                    .max_aw_wait(c_max_aw_wait[cg]), .max_w_wait(c_max_w_wait[cg]),
                    .max_b_wait(c_max_b_wait[cg]), .max_ar_wait(c_max_ar_wait[cg]),
                    .max_r_wait(c_max_r_wait[cg]));
            end
        end
    endgenerate

    // Pack client 0 and the six procedural clients into the real arbiter.
    integer pi;
    always_comb begin
        s_awaddr='0; s_awlen='0; s_awsize='0; s_awburst='0; s_awvalid='0;
        s_wdata='0; s_wstrb='0; s_wlast='0; s_wvalid='0; s_bready='0;
        s_araddr='0; s_arlen='0; s_arsize='0; s_arburst='0; s_arvalid='0; s_rready='0;
        s_awaddr[0]=job_awaddr; s_awlen[0]=job_awlen; s_awsize[0]=job_awsize;
        s_awburst[0]=job_awburst; s_awvalid[0]=job_awvalid; s_wdata[0]=job_wdata;
        s_wstrb[0]=job_wstrb; s_wlast[0]=job_wlast; s_wvalid[0]=job_wvalid;
        s_bready[0]=job_bready; s_araddr[0]=job_araddr; s_arlen[0]=job_arlen;
        s_arsize[0]=job_arsize; s_arburst[0]=job_arburst; s_arvalid[0]=job_arvalid;
        s_rready[0]=job_rready;
        param_arready=1'b0; param_rdata='0; param_rresp='0; param_rlast=1'b0;
        param_rvalid=1'b0;
        for (pi=0; pi<SYNTH_CLIENTS; pi=pi+1) begin
            if (REAL_PARAMETER_CLIENT && (pi == 0)) begin
                // Parameter loader is read-only; hold all write channels
                // inactive and route its read channels to arbiter slot 1.
                s_araddr[pi+1]=param_araddr; s_arlen[pi+1]=param_arlen;
                s_arsize[pi+1]=param_arsize; s_arburst[pi+1]=param_arburst;
                s_arvalid[pi+1]=param_arvalid; s_rready[pi+1]=param_rready;
            end else begin
                s_awaddr[pi+1]=c_awaddr[pi]; s_awlen[pi+1]=c_awlen[pi]; s_awsize[pi+1]=c_awsize[pi];
                s_awburst[pi+1]=c_awburst[pi]; s_awvalid[pi+1]=c_awvalid[pi]; s_wdata[pi+1]=c_wdata[pi];
                s_wstrb[pi+1]=c_wstrb[pi]; s_wlast[pi+1]=c_wlast[pi]; s_wvalid[pi+1]=c_wvalid[pi];
                s_bready[pi+1]=c_bready[pi]; s_araddr[pi+1]=c_araddr[pi]; s_arlen[pi+1]=c_arlen[pi];
                s_arsize[pi+1]=c_arsize[pi]; s_arburst[pi+1]=c_arburst[pi]; s_arvalid[pi+1]=c_arvalid[pi];
                s_rready[pi+1]=c_rready[pi];
            end
        end
        job_awready=s_awready[0]; job_wready=s_wready[0]; job_bvalid=s_bvalid[0]; job_bresp=s_bresp[0];
        job_arready=s_arready[0]; job_rvalid=s_rvalid[0]; job_rdata=s_rdata[0]; job_rresp=s_rresp[0]; job_rlast=s_rlast[0];
        for (pi=0; pi<SYNTH_CLIENTS; pi=pi+1) begin
            if (REAL_PARAMETER_CLIENT && (pi == 0)) begin
                param_arready=s_arready[pi+1]; param_rvalid=s_rvalid[pi+1];
                param_rdata=s_rdata[pi+1]; param_rresp=s_rresp[pi+1];
                param_rlast=s_rlast[pi+1];
            end else begin
                c_awready[pi]=s_awready[pi+1]; c_wready[pi]=s_wready[pi+1]; c_bvalid[pi]=s_bvalid[pi+1]; c_bresp[pi]=s_bresp[pi+1];
                c_arready[pi]=s_arready[pi+1]; c_rvalid[pi]=s_rvalid[pi+1]; c_rdata[pi]=s_rdata[pi+1]; c_rresp[pi]=s_rresp[pi+1]; c_rlast[pi]=s_rlast[pi+1];
            end
        end
    end

    logic [31:0] m_awaddr, m_araddr; logic [7:0] m_awlen, m_arlen; logic [2:0] m_awsize, m_arsize; logic [1:0] m_awburst, m_arburst;
    logic m_awvalid, m_awready=0, m_wvalid, m_wready=0, m_wlast, m_bvalid=0, m_bready;
    logic [127:0] m_wdata, m_rdata=0; logic [15:0] m_wstrb; logic [1:0] m_bresp=0, m_rresp=0; logic m_arvalid, m_arready=0, m_rlast=0, m_rvalid=0, m_rready;

    c1_axi_n_serial_arbiter_128 #(.CLIENTS(CLIENTS)) u_arbiter (
        .clk, .rst, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awvalid, .s_awready,
        .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready, .s_bresp, .s_bvalid, .s_bready,
        .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arvalid, .s_arready, .s_rdata, .s_rresp,
        .s_rlast, .s_rvalid, .s_rready, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awvalid,
        .m_awready, .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready, .m_bresp, .m_bvalid,
        .m_bready, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arvalid, .m_arready,
        .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready);

    logic [31:0] prng=32'h6a31_90c7; logic rd_active=0, wr_active=0, b_pending=0;
    logic [31:0] rd_base_q=0, wr_base_q=0; logic [7:0] rd_len_q=0, rd_beat_q=0, wr_len_q=0, wr_beat_q=0;
    integer rd_gap_q=0, b_gap_q=0; logic [511:0] descriptor_memory [0:MAX_STAGES-1];
    logic [127:0] fabric_mem [longint unsigned]; logic [127:0] output_mem [longint unsigned];
    integer ar_count=0, aw_count=0, w_count=0, b_count=0, input_ar_count=0, input_r_count=0, table_ar_count=0, descriptor_ar_count=0;
    integer param_ar_count=0, param_r_count=0;
    integer ar_stall_count=0, aw_stall_count=0, w_stall_count=0, r_gap_count=0, b_delay_count=0, output_pixel_count=0;
    integer stage_count=0, cnn_in_count=0, cnn_out_count=0, stage_stall_count=0, cnn_in_stall_count=0, cnn_out_stall_count=0;
    integer client_aw_total=0, client_w_total=0, client_b_total=0, client_ar_total=0, client_r_total=0;
    integer job_aw_count=0, job_w_count=0, job_b_count=0, job_ar_count=0, job_r_count=0;
    integer client_max_wait [0:SYNTH_CLIENTS-1];

    function automatic [511:0] legal_descriptor(input integer idx);
        logic [511:0] d; begin d='0; d[7:0]=8'd2; d[9:8]=idx[0]?2'd1:2'd0; d[23:16]=8'd1; d[31:24]=8'd16; d[47:32]=16'd8+(idx%5); d[63:48]=16'd9+(idx%5); d[79:64]=d[47:32]; d[95:80]=d[63:48]; d[111:96]=16'd8; d[127:112]=16'd8; d[159:128]=32'h0010_0000+idx*32'h10; d[191:160]=32'h0020_0000+idx*32'h10; d[255:224]=32'h0040_0000+idx*32'h10; d[287:256]=32'h0050_0000+idx*32'h10; d[319:288]=32'h0058_0000+idx*32'h10; d[351:320]=32'h0060_0000+idx*32'h10; d[423:416]=8'd1; d[431:424]=8'd1; d[439:432]=8'd1; d[447:440]=8'd1; d[455:448]=8'd8; d[463:456]=8'd8; d[471:464]=8'd4; d[479:472]=8'd4; d[511:480]=32'd1000+idx; legal_descriptor=d; end
    endfunction
    function automatic [127:0] table_entry(input logic [31:0] base_addr);
        table_entry={16'(FRAME_H),16'(FRAME_W),32'(STRIDE),32'd0,base_addr};
    endfunction
    function automatic [127:0] synth_data(input logic [31:0] addr);
        integer cid, tx, bt; begin cid=(addr-32'h1000_0000)/32'h0010_0000; tx=((addr- (32'h1000_0000+cid*32'h0010_0000))>>8)&255; bt=(addr>>4)&3; synth_data={32'hc100_0000|cid,32'hd200_0000|tx,32'he300_0000|(cid<<8)|bt,32'hf400_00a5|(cid<<4)|bt}; end
    endfunction
    function automatic [127:0] parameter_data(input logic [31:0] addr);
        integer wi; begin
            wi=(addr-PARAM_BASE)>>4;
            parameter_data={32'h5041_5200|wi,32'h4d45_5400|(wi<<1),
                            32'h5245_4144^(wi*32'h0101_0101),
                            32'hcafe_0000|wi};
        end
    endfunction
    function automatic [127:0] read_lookup(input logic [31:0] a);
        integer idx, beat; begin read_lookup=0;
            if(a==INPUT_TABLE_BASE) read_lookup=table_entry(INPUT_FRAME_BASE);
            else if(a==OUTPUT_TABLE_BASE) read_lookup=table_entry(OUTPUT_FRAME_BASE);
            else if(a>=DESCRIPTOR_BASE && a<DESCRIPTOR_BASE+MAX_STAGES*64) begin idx=(a-DESCRIPTOR_BASE)>>6; beat=((a-DESCRIPTOR_BASE)>>4)&3; read_lookup=descriptor_memory[idx][beat*128 +: 128]; end
            else if(a>=INPUT_FRAME_BASE && a<INPUT_FRAME_BASE+FRAME_BYTES) read_lookup={{4{8'h00,PIXEL_RGB}}};
            else if(a>=PARAM_BASE && a<PARAM_BASE+PARAM_BYTES) read_lookup=parameter_data(a);
            else if(a>=32'h1000_0000 && a<32'h1700_0000) read_lookup=fabric_mem.exists(a>>4)?fabric_mem[a>>4]:synth_data(a);
        end
    endfunction
    task automatic fail(input string msg); begin $display("C1_R1_NATIVE_BOARDLESS_FABRIC_FAIL %s",msg); $fatal(1,"%s",msg); end endtask

    // Stable randomized READY is generated on the opposite edge.
    always @(negedge clk) begin
        if(rst) begin m_awready<=0; m_wready<=0; m_arready<=0; end
        else begin m_awready<=!wr_active&&!b_pending&&!m_bvalid&&(prng[3:0]!=0); m_wready<=wr_active&&(prng[7:4]!=0); m_arready<=!rd_active&&!m_rvalid&&(prng[11:8]!=0); end
    end
    always @(posedge clk) begin if(rst) prng<=32'h6a31_90c7; else prng<={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]}; end

    logic cnn_loop_valid_q=0; logic [63:0] cnn_loop_data_q=0; logic [15:0] cnn_loop_x_q=0, cnn_loop_y_q=0; logic cnn_loop_sof_q=0,cnn_loop_eol_q=0,cnn_loop_eof_q=0;
    always_comb begin
        stage_config_ready=(prng[14:12]!=0); cnn_in_ready=!cnn_loop_valid_q&&(prng[17:15]!=0); cnn_out_valid=cnn_loop_valid_q; cnn_out_data_s8=cnn_loop_data_q; cnn_out_x=cnn_loop_x_q; cnn_out_y=cnn_loop_y_q; cnn_out_sof=cnn_loop_sof_q; cnn_out_eol=cnn_loop_eol_q; cnn_out_eof=cnn_loop_eof_q;
    end
    always @(posedge clk) begin
        if(rst||cnn_abort) cnn_loop_valid_q<=0;
        else begin
            if(cnn_out_valid&&cnn_out_ready) begin cnn_loop_valid_q<=0; cnn_out_count=cnn_out_count+1; end
            if(cnn_in_valid&&cnn_in_ready) begin if(cnn_loop_valid_q) fail("CNN echo overflow"); if(!stage_dispatch_complete||stage_count!=MAX_STAGES) fail("CNN before descriptors"); cnn_loop_valid_q<=1; cnn_loop_data_q<=cnn_in_data_s8; cnn_loop_x_q<=cnn_in_x; cnn_loop_y_q<=cnn_in_y; cnn_loop_sof_q<=cnn_in_sof; cnn_loop_eol_q<=cnn_in_eol; cnn_loop_eof_q<=cnn_in_eof; cnn_in_count=cnn_in_count+1; end
        end
    end
    always @(posedge clk) begin
        if(rst) stage_count=0;
        else begin
            if(stage_config_valid&&!stage_config_ready) stage_stall_count=stage_stall_count+1;
            if(cnn_in_valid&&!cnn_in_ready) cnn_in_stall_count=cnn_in_stall_count+1;
            if(cnn_out_valid&&!cnn_out_ready) cnn_out_stall_count=cnn_out_stall_count+1;
            if(stage_config_valid&&stage_config_ready) begin if(stage_config_index!==stage_count[COUNT_BITS-1:0]||stage_config_descriptor!==descriptor_memory[stage_count]) fail("descriptor mismatch"); stage_count=stage_count+1; end
            if(stage_dispatch_complete&&stage_count!=MAX_STAGES) fail("dispatch early");
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            param_done_seen <= 1'b0;
            param_error_seen <= 1'b0;
        end else begin
            if (param_done) param_done_seen <= 1'b1;
            if (param_error || param_aborted || param_bank_error || param_bank_aborted)
                param_error_seen <= 1'b1;
        end
    end

    always @(posedge clk) begin : read_bfm
        if(rst) begin rd_active<=0; m_rvalid<=0; m_rdata<=0; m_rlast<=0; rd_gap_q<=0; end
        else begin
            if(m_arvalid&&!m_arready) ar_stall_count=ar_stall_count+1;
            if(m_arvalid&&m_arready) begin rd_active<=1; rd_base_q<=m_araddr; rd_len_q<=m_arlen; rd_beat_q<=0; rd_gap_q=1+(prng[13:12]); ar_count=ar_count+1; if(m_araddr==INPUT_TABLE_BASE||m_araddr==OUTPUT_TABLE_BASE)table_ar_count=table_ar_count+1; else if(m_araddr>=DESCRIPTOR_BASE&&m_araddr<DESCRIPTOR_BASE+MAX_STAGES*64)descriptor_ar_count=descriptor_ar_count+1; else if(m_araddr>=INPUT_FRAME_BASE&&m_araddr<INPUT_FRAME_BASE+FRAME_BYTES)begin input_ar_count=input_ar_count+1; job_ar_count=job_ar_count+1; end else if(m_araddr>=PARAM_BASE&&m_araddr<PARAM_BASE+PARAM_BYTES) param_ar_count=param_ar_count+1; else if(m_araddr<32'h1000_0000) job_ar_count=job_ar_count+1; end
            if(m_rvalid&&!m_rready) begin end
            if(m_rvalid&&m_rready) begin m_rvalid<=0; if(rd_beat_q==rd_len_q) rd_active<=0; else begin rd_beat_q<=rd_beat_q+1; rd_gap_q=1+(prng[15:14]); end; if(rd_base_q>=INPUT_FRAME_BASE&&rd_base_q<INPUT_FRAME_BASE+FRAME_BYTES) begin input_r_count=input_r_count+1; job_r_count=job_r_count+1; end else if(rd_base_q>=PARAM_BASE&&rd_base_q<PARAM_BASE+PARAM_BYTES) param_r_count=param_r_count+1; else if(rd_base_q<32'h1000_0000) job_r_count=job_r_count+1; end
            else if(rd_active&&!m_rvalid) begin if(rd_gap_q!=0) begin rd_gap_q=rd_gap_q-1; r_gap_count=r_gap_count+1; end else begin m_rdata<=read_lookup(rd_base_q+(rd_beat_q<<4)); m_rresp<=0; m_rlast<=(rd_beat_q==rd_len_q); m_rvalid<=1; end end
        end
    end
    always @(posedge clk) begin : write_bfm
        integer lane; longint unsigned key; logic [127:0] line; logic [31:0] pixel_addr;
        if(rst) begin wr_active<=0; b_pending<=0; m_bvalid<=0; b_gap_q<=0; end
        else begin
            if(m_awvalid&&!m_awready) aw_stall_count=aw_stall_count+1;
            if(m_wvalid&&!m_wready) w_stall_count=w_stall_count+1;
            if(m_awvalid&&m_awready) begin wr_active<=1; wr_base_q<=m_awaddr; wr_len_q<=m_awlen; wr_beat_q<=0; aw_count=aw_count+1; if(m_awaddr>=OUTPUT_FRAME_BASE&&m_awaddr<OUTPUT_FRAME_BASE+FRAME_BYTES) job_aw_count=job_aw_count+1; end
            if(m_wvalid&&m_wready) begin if(!wr_active||m_wstrb!=16'hffff) fail("invalid W"); key=(wr_base_q+wr_beat_q*16)>>4; line=fabric_mem.exists(key)?fabric_mem[key]:128'd0; for(lane=0;lane<16;lane=lane+1) if(m_wstrb[lane]) line[lane*8 +:8]=m_wdata[lane*8 +:8]; fabric_mem[key]=line; if(wr_base_q>=OUTPUT_FRAME_BASE&&wr_base_q<OUTPUT_FRAME_BASE+FRAME_BYTES) begin for(lane=0;lane<4;lane=lane+1) begin pixel_addr=wr_base_q+wr_beat_q*16+lane*4; if(m_wdata[lane*32 +:32]!=={8'h00,PIXEL_RGB}) fail("output pixel mismatch"); output_mem[pixel_addr>>4]=line; end output_pixel_count=output_pixel_count+4; job_w_count=job_w_count+1; end w_count=w_count+1; if(m_wlast) begin wr_active<=0; b_pending<=1; b_gap_q=1+(prng[17:16]); end else wr_beat_q<=wr_beat_q+1; end
            if(b_pending&&!m_bvalid) begin if(b_gap_q!=0) begin b_gap_q=b_gap_q-1; b_delay_count=b_delay_count+1; end else begin m_bvalid<=1; m_bresp<=0; b_pending<=0; end end
            if(m_bvalid&&m_bready) begin m_bvalid<=0; b_count=b_count+1; if(wr_base_q>=OUTPUT_FRAME_BASE&&wr_base_q<OUTPUT_FRAME_BASE+FRAME_BYTES) job_b_count=job_b_count+1; end
        end
    end

    task automatic start_param_load;
        begin
            @(negedge clk);
            param_start_valid <= 1'b1;
            while (!param_start_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            param_start_valid <= 1'b0;
        end
    endtask
    task automatic check_param_word(input integer index);
        begin
            @(negedge clk);
            param_rd_addr <= index[PARAM_ADDR_W-1:0];
            param_rd_en <= 1'b1;
            @(posedge clk);
            #1;
            if (!param_rd_valid || param_rd_error ||
                param_rd_data !== parameter_data(PARAM_BASE + index*16))
                fail("parameter real-leaf readback mismatch");
            @(negedge clk);
            param_rd_en <= 1'b0;
        end
    endtask
    task automatic start_job; begin @(negedge clk); job_start_valid<=1; while(!job_start_ready) @(negedge clk); @(posedge clk); @(negedge clk); job_start_valid<=0; end endtask
    task automatic verify_output; integer x,y,lane; longint unsigned key; logic [127:0] line; begin for(y=0;y<FRAME_H;y=y+1) for(x=0;x<FRAME_W;x=x+1) begin key=(OUTPUT_FRAME_BASE+y*STRIDE+x*4)>>4; if(!output_mem.exists(key)) fail("missing output line"); line=output_mem[key]; lane=x&3; if(line[lane*32 +:32]!=={8'h00,PIXEL_RGB}) fail("output readback mismatch"); end end endtask

    initial begin : main
        integer i, j; integer total_done;
        for(i=0;i<MAX_STAGES;i=i+1) descriptor_memory[i]=legal_descriptor(i);
        repeat(8) @(posedge clk); @(negedge clk); rst<=0; repeat(4) @(posedge clk); if(!job_start_ready||busy) fail("top not idle");
        if (REAL_PARAMETER_CLIENT) start_param_load();
        start_job();
        while((!job_done&&!job_error&&!job_aborted) ||
              (REAL_PARAMETER_CLIENT && !param_done_seen && !param_error_seen)) begin
            @(negedge clk); if($time>500_000_000) fail("timeout");
        end
        if(!job_done||job_error||job_aborted) fail("boardless job failed");
        if (REAL_PARAMETER_CLIENT) begin
            if (!param_done_seen || param_error_seen || param_error ||
                param_aborted || !param_active_valid || param_generation != 32'd1)
                fail("real parameter client did not commit");
            if (param_ar_count != PARAM_BURSTS || param_r_count != PARAM_WORDS)
                fail("real parameter AXI coverage mismatch");
            check_param_word(0);
            check_param_word(PARAM_WORDS/2);
            check_param_word(PARAM_WORDS-1);
        end
        repeat(20) @(posedge clk);
        total_done=0;
        if (REAL_PARAMETER_CLIENT) begin
            for(i=1;i<SYNTH_CLIENTS;i=i+1) begin
                total_done=total_done+c_done[i];
                if(c_error[i]) fail("synthetic client error");
            end
            if(total_done!=SYNTH_CLIENTS-1) fail("synthetic clients incomplete");
        end else begin
            for(i=0;i<SYNTH_CLIENTS;i=i+1) begin
                total_done=total_done+c_done[i];
                if(c_error[i]) fail("synthetic client error");
            end
            if(total_done!=SYNTH_CLIENTS) fail("synthetic clients incomplete");
        end
        if(stage_count!=MAX_STAGES||cnn_in_count!=FRAME_W*FRAME_H||cnn_out_count!=FRAME_W*FRAME_H||output_pixel_count!=FRAME_W*FRAME_H) fail("boardless coverage mismatch");
        if(input_ar_count!=FRAME_BURSTS||input_r_count!=FRAME_BEATS||aw_count<FRAME_BURSTS||w_count<FRAME_BEATS||b_count<FRAME_BURSTS||ar_stall_count==0||r_gap_count==0||aw_stall_count==0||w_stall_count==0||b_delay_count==0) fail("DDR traffic coverage missing");
        verify_output();
        for(j=(REAL_PARAMETER_CLIENT ? 1 : 0);j<SYNTH_CLIENTS;j=j+1) begin
            client_aw_total=client_aw_total+c_aw_count[j]; client_w_total=client_w_total+c_w_count[j]; client_b_total=client_b_total+c_b_count[j]; client_ar_total=client_ar_total+c_ar_count[j]; client_r_total=client_r_total+c_r_count[j];
            client_max_wait[j]=c_max_aw_wait[j];
            if(c_max_w_wait[j]>client_max_wait[j]) client_max_wait[j]=c_max_w_wait[j];
            if(c_max_b_wait[j]>client_max_wait[j]) client_max_wait[j]=c_max_b_wait[j];
            if(c_max_ar_wait[j]>client_max_wait[j]) client_max_wait[j]=c_max_ar_wait[j];
            if(c_max_r_wait[j]>client_max_wait[j]) client_max_wait[j]=c_max_r_wait[j];
        end
        if (REAL_PARAMETER_CLIENT) begin
            $display("C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_PASS frame=%0dx%0d total_clients=%0d real_param=1 synthetic_clients=%0d param_ar=%0d param_r=%0d param_generation=%0d client_aw=%0d client_w=%0d client_b=%0d client_ar=%0d client_r=%0d job_aw=%0d job_w=%0d job_b=%0d job_ar=%0d job_r=%0d input_ar=%0d input_r=%0d output_pixels=%0d arb_aw_stalls=%0d arb_ar_stalls=%0d r_gaps=%0d b_delays=%0d",FRAME_W,FRAME_H,CLIENTS,SYNTH_CLIENTS-1,param_ar_count,param_r_count,param_generation,client_aw_total,client_w_total,client_b_total,client_ar_total,client_r_total,job_aw_count,job_w_count,job_b_count,job_ar_count,job_r_count,input_ar_count,input_r_count,output_pixel_count,aw_stall_count,ar_stall_count,r_gap_count,b_delay_count);
            $display("C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_CLIENT_STATS c2=%0d/%0d/%0d/%0d/%0d/%0d c3=%0d/%0d/%0d/%0d/%0d/%0d c4=%0d/%0d/%0d/%0d/%0d/%0d c5=%0d/%0d/%0d/%0d/%0d/%0d c6=%0d/%0d/%0d/%0d/%0d/%0d",c_aw_count[1],c_w_count[1],c_b_count[1],c_ar_count[1],c_r_count[1],client_max_wait[1],c_aw_count[2],c_w_count[2],c_b_count[2],c_ar_count[2],c_r_count[2],client_max_wait[2],c_aw_count[3],c_w_count[3],c_b_count[3],c_ar_count[3],c_r_count[3],client_max_wait[3],c_aw_count[4],c_w_count[4],c_b_count[4],c_ar_count[4],c_r_count[4],client_max_wait[4],c_aw_count[5],c_w_count[5],c_b_count[5],c_ar_count[5],c_r_count[5],client_max_wait[5]);
        end else begin
            $display("C1_R1_NATIVE_BOARDLESS_FABRIC_PASS frame=%0dx%0d clients=%0d client_aw=%0d client_w=%0d client_b=%0d client_ar=%0d client_r=%0d job_aw=%0d job_w=%0d job_b=%0d job_ar=%0d job_r=%0d input_ar=%0d input_r=%0d output_pixels=%0d arb_aw_stalls=%0d arb_ar_stalls=%0d r_gaps=%0d b_delays=%0d max_aw_waits=%0d/%0d/%0d/%0d/%0d/%0d max_ar_waits=%0d/%0d/%0d/%0d/%0d/%0d",FRAME_W,FRAME_H,SYNTH_CLIENTS,client_aw_total,client_w_total,client_b_total,client_ar_total,client_r_total,job_aw_count,job_w_count,job_b_count,job_ar_count,job_r_count,input_ar_count,input_r_count,output_pixel_count,aw_stall_count,ar_stall_count,r_gap_count,b_delay_count,c_max_aw_wait[0],c_max_aw_wait[1],c_max_aw_wait[2],c_max_aw_wait[3],c_max_aw_wait[4],c_max_aw_wait[5],c_max_ar_wait[0],c_max_ar_wait[1],c_max_ar_wait[2],c_max_ar_wait[3],c_max_ar_wait[4],c_max_ar_wait[5]);
            $display("C1_R1_NATIVE_BOARDLESS_FABRIC_CLIENT_STATS c1=%0d/%0d/%0d/%0d/%0d/%0d c2=%0d/%0d/%0d/%0d/%0d/%0d c3=%0d/%0d/%0d/%0d/%0d/%0d c4=%0d/%0d/%0d/%0d/%0d/%0d c5=%0d/%0d/%0d/%0d/%0d/%0d c6=%0d/%0d/%0d/%0d/%0d/%0d",c_aw_count[0],c_w_count[0],c_b_count[0],c_ar_count[0],c_r_count[0],client_max_wait[0],c_aw_count[1],c_w_count[1],c_b_count[1],c_ar_count[1],c_r_count[1],client_max_wait[1],c_aw_count[2],c_w_count[2],c_b_count[2],c_ar_count[2],c_r_count[2],client_max_wait[2],c_aw_count[3],c_w_count[3],c_b_count[3],c_ar_count[3],c_r_count[3],client_max_wait[3],c_aw_count[4],c_w_count[4],c_b_count[4],c_ar_count[4],c_r_count[4],client_max_wait[4],c_aw_count[5],c_w_count[5],c_b_count[5],c_ar_count[5],c_r_count[5],client_max_wait[5]);
        end
        $finish;
    end
    initial begin #600_000_000; fail("global timeout"); end
endmodule
