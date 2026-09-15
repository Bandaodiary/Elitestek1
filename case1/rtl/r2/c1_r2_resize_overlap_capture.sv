// C30 independent Resize overlap candidate; retained R1/C23/C29 unchanged.
`timescale 1ns/1ps
// C24: one lease owns both Resize and the existing RGBX32 capture writer.
// Completion fences source/Resize flush AND actual submitted AXI writes.
// A visible completion is immutable; a later cancel cannot retract it.
// Source is core-domain ready/valid RGB, not an unstoppable CSI interface.
module c1_r2_resize_overlap_capture #(
    parameter integer FIFO_DEPTH=256,OUTSTANDING=4,MAX_SOURCE_WIDTH=2048,
    parameter integer LW=$clog2(FIFO_DEPTH+1)
) (
    input wire clk,rst,cmd_valid,
    output wire cmd_ready,
    input wire [31:0] cfg_base,cfg_tag,
    input wire [10:0] cfg_width,
    input wire [9:0] cfg_height,
    input wire [15:0] cfg_source_width,cfg_source_height,s_x,s_y,
    input wire signed [31:0] cfg_x_step_q16,cfg_y_step_q16,cfg_x_phase0_q16,cfg_y_phase0_q16,
    output wire s_ready,
    output logic source_error,
    output logic [3:0] source_error_code,
    input wire cancel,s_valid,s_sof,s_eol,s_eof,
    input wire [23:0] s_rgb,
    output wire busy,
    output logic done_valid,done_error,done_dropped,
    input wire done_ready,
    output wire [31:0] done_base,done_tag,
    output logic overflow_pulse,
    output logic [LW-1:0] peak_level,
    output wire protocol_error,
    output wire [7:0] outstanding,
    output wire [3:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast,m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready
);
    logic owned,failed_q,error_q;
    wire cap_ready,cap_busy,cap_done,cap_error,cap_drop,cap_overflow;
    wire resize_ready,resize_cfg_error,resize_busy,resize_done,resize_error;
    wire [3:0] resize_error_code;
    wire resize_in_ready,resize_valid,resize_sof,resize_eol,resize_eof;
    wire [23:0] resize_rgb;
    wire cap_done_ready;
    wire legal=cfg_source_width!=0 && cfg_source_width<=MAX_SOURCE_WIDTH &&
               cfg_source_height!=0 && !cfg_y_step_q16[31];
    wire terminal=cap_done && !resize_busy;
    wire mutable_job=owned && !terminal;
    wire local_error=resize_error || resize_cfg_error || cap_overflow || protocol_error;
    wire stop_trigger=mutable_job && (cancel || local_error || (cap_done && (cap_error || cap_drop)));
    wire stop=owned && (failed_q || stop_trigger);
    assign cmd_ready=!rst && !owned && cap_ready && resize_ready && legal;
    wire fire=cmd_valid && cmd_ready;
    // Cancel present on descriptor acceptance is remembered, then both child
    // jobs are poisoned on the following cycle. No source pixel is consumed.
    assign s_ready=!rst && owned && !stop && !cap_done && resize_in_ready;
    assign busy=owned || cap_busy || resize_busy;
    assign done_valid=!rst && owned && terminal;
    assign done_error=cap_error || error_q;
    assign done_dropped=cap_drop || failed_q;
    assign cap_done_ready=done_valid && done_ready;
    assign overflow_pulse=cap_overflow;
    always_ff @(posedge clk)begin
        if(rst)begin owned<=0;failed_q<=0;error_q<=0;source_error<=0;source_error_code<=0;end
        else begin
            if(fire)begin
                owned<=1;failed_q<=cancel;error_q<=0;source_error<=0;source_error_code<=0;
            end
            if(mutable_job)begin
                if(stop_trigger)failed_q<=1;
                if(local_error)error_q<=1;
                if((resize_error || resize_cfg_error) && !source_error)begin
                    source_error<=1;source_error_code<=resize_error ? resize_error_code : 4'd8;
                end
            end
            if(done_valid && done_ready)owned<=0;
        end
    end
    c1_r2_resize_overlap_pipeline #(.MAX_WIDTH(MAX_SOURCE_WIDTH),.REGISTER_ABORT_RESET(1)) u_resize (
        .clk(clk),.rst(rst),.cfg_valid(fire),.cfg_ready(resize_ready),.cfg_error(resize_cfg_error),
        .cfg_win(cfg_source_width),.cfg_hin(cfg_source_height),
        .cfg_wout({5'd0,cfg_width}),.cfg_hout({6'd0,cfg_height}),
        .cfg_x_step_q16(cfg_x_step_q16),.cfg_y_step_q16(cfg_y_step_q16),
        .cfg_x_phase0_q16(cfg_x_phase0_q16),.cfg_y_phase0_q16(cfg_y_phase0_q16),
        .abort(stop),.aborted(),.busy(resize_busy),.done(resize_done),.error(resize_error),.error_code(resize_error_code),
        .in_valid(s_valid && owned && !stop && !cap_done),.in_ready(resize_in_ready),
        .in_x(s_x),.in_y(s_y),.in_sof(s_sof),.in_eol(s_eol),.in_eof(s_eof),.in_rgb888(s_rgb),
        .out_valid(resize_valid),.out_ready(owned && !stop && !cap_done),
        .out_sof(resize_sof),.out_eol(resize_eol),.out_eof(resize_eof),.out_x(),.out_y(),.out_rgb888(resize_rgb)
    );
    c1_r2_video_capture_rgbx32 #(.FIFO_DEPTH(FIFO_DEPTH),.OUTSTANDING(OUTSTANDING)) u_capture (
        .clk(clk),.rst(rst),.cmd_valid(fire),.cmd_ready(cap_ready),
        .cfg_base(cfg_base),.cfg_tag(cfg_tag),.cfg_width(cfg_width),.cfg_height(cfg_height),
        .cancel(stop && !cap_done),.s_valid(resize_valid && owned && !stop && !cap_done),
        .s_sof(resize_sof),.s_eol(resize_eol),.s_eof(resize_eof),.s_rgb(resize_rgb),.busy(cap_busy),
        .done_valid(cap_done),.done_ready(cap_done_ready),.done_error(cap_error),.done_dropped(cap_drop),
        .done_base(done_base),.done_tag(done_tag),.overflow_pulse(cap_overflow),.peak_level(peak_level),
        .protocol_error(protocol_error),.outstanding(outstanding),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

`ifndef SYNTHESIS
    reg was_held=0;
    reg [65:0] held_result;
    always @(posedge clk)begin
        if(rst)was_held<=0;
        else begin
            if(was_held && (!done_valid || {done_error,done_dropped,done_base,done_tag}!==held_result))
                $fatal(1,"Resize/Capture held completion changed");
            was_held<=done_valid && !done_ready;
            held_result<={done_error,done_dropped,done_base,done_tag};
            if(done_valid && (resize_busy || outstanding!=0))$fatal(1,"Resize/Capture completed before drain");
            if(fire && (!cap_ready || !resize_ready))$fatal(1,"Resize/Capture non-atomic launch");
            if(stop && s_ready)$fatal(1,"Resize/Capture consumed source on cancel");
            if(resize_done && !owned)$fatal(1,"Resize completed without capture owner");
        end
    end
`endif
endmodule
