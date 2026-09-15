`timescale 1ns/1ps
// C25 MAP/resource probe. Full 1920x1080 RGB -> 1440x1080 ROI -> 640x480 capture.
// Two clocks are real RTL clocks. This is NOT a physically constrained board top.
module c1_ti60_r2_camera_capture (
    input wire clk,rst,cam_clk,cam_rst,enable,cancel,
    input wire cam_valid,cam_sof,cam_eol,cam_eof,cam_error,
    input wire [23:0] cam_rgb,
    input wire m_axi_awready,m_axi_wready,m_axi_bvalid,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire [3:0] observe,
    output logic [31:0] observed,
    output wire m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready
);
    wire cam_busy,job_valid,job_ready,job_done,job_failed,job_cancel,busy,config_error;
    wire result_valid,result_failed,result_admitted,s_valid,s_ready,s_sof,s_eol,s_eof;
    wire [31:0] cam_seen,cam_skipped,job_tag,result_tag;
    wire [10:0] cam_peak;
    wire [3:0] result_code;
    wire [23:0] s_rgb;
    wire [15:0] s_x,s_y;
    c1_r2_camera_ingress u_ingress(.*);
    wire cap_busy,cap_done,cap_error,cap_drop,cap_overflow,cap_protocol,source_error;
    wire [3:0] source_error_code,m_axi_awid;
    wire [31:0] done_base,done_tag,m_axi_awaddr;
    wire [7:0] outstanding,m_axi_awlen;
    wire [8:0] peak_level;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    assign job_done=cap_done;
    assign job_failed=cap_error || cap_drop;
    c1_r2_resize_capture_rgbx32 u_capture (
        .clk(clk),.rst(rst),.cmd_valid(job_valid),.cmd_ready(job_ready),.cfg_base(32'h08000000),.cfg_tag(job_tag),
        .cfg_width(11'd640),.cfg_height(10'd480),.cfg_source_width(16'd1440),.cfg_source_height(16'd1080),
        .cfg_x_step_q16(32'sd147456),.cfg_y_step_q16(32'sd147456),
        .cfg_x_phase0_q16(32'sd40960),.cfg_y_phase0_q16(32'sd40960),
        .s_x(s_x),.s_y(s_y),.s_ready(s_ready),.source_error(source_error),.source_error_code(source_error_code),
        .cancel(job_cancel),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),.s_rgb(s_rgb),
        .busy(cap_busy),.done_valid(cap_done),.done_ready(1'b1),.done_error(cap_error),.done_dropped(cap_drop),
        .done_base(done_base),.done_tag(done_tag),.overflow_pulse(cap_overflow),.peak_level(peak_level),
        .protocol_error(cap_protocol),.outstanding(outstanding),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),.m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready));
    always_comb begin
        observed=0;
        case(observe)
            0,1,2,3:observed=m_axi_wdata[observe[1:0]*32+:32];
            4:observed=m_axi_awaddr;
            5:observed={m_axi_wstrb,m_axi_awlen,m_axi_awid,m_axi_awsize,1'b0};
            6:observed=job_tag;
            7:observed=result_tag;
            8:observed=cam_seen;
            9:observed=cam_skipped;
            10:observed={16'd0,cam_peak,result_code,result_failed};
            11:observed={8'd0,source_error_code,outstanding,peak_level,cap_protocol,cap_overflow,source_error};
            12:observed={20'd0,m_axi_awburst,cam_busy,busy,config_error,result_admitted,result_valid,cap_done,cap_error,cap_drop,cap_busy,job_cancel};
            13:observed=done_base;
            14:observed=done_tag;
            default:observed=0;
        endcase
    end
endmodule
