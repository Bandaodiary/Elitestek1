// C31 independent RGB2/VS/DE host integration; retained C29 unchanged.
// C29 capacity candidate; retained C28 baseline unchanged.
// C26 actual unstoppable camera + ROI/CDC + C24 host/CNN. Retained C24 untouched.
// C24 independent Resize/Capture integration; retained C22 sources unchanged.
// C22 independent feature-overlay branch; retained C21 sources unchanged.
// C21 independent six-lane weight branch; retained C18 sources unchanged.
// C18 independent generated-plan integration. Retained C12/C14/C15 RTL is unchanged.
`timescale 1ns/1ps
// C18 generated-plan RGBX32 video pipeline, retaining C14 leases/C10 fabric.
// Source is TWO RGB pixels/valid in cam_clk AFTER ISP; positive VS, DE==valid.
// Display requests remain core-domain BEFORE HDMI CDC. No CSI/DDR/HDMI PHY.
// CPU master is normalized 128-bit ID0; not a direct Sapphire multi-ID port.
module c1_r2_video_ring_rgb2_system #(
    parameter integer WIDTH=640,HEIGHT=480,CAPTURE_FIFO=256,DISPLAY_FIFO=512,FIFO_DEPTH=8,
    parameter integer SOURCE_WIDTH=1920,SOURCE_HEIGHT=1080,ROI_X=240,ROI_Y=0,ROI_WIDTH=1440,ROI_HEIGHT=1080,
    parameter integer CAMERA_FIFO=512,FRAME_TIMEOUT=5000000,FRAME_DIVISOR=2,
    parameter logic [31:0] ARENA_BASE=32'h08000000
) (
    input wire clk,rst,platform_ready,psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    input wire [3:0] pstrb,
    output wire [31:0] prdata,
    output wire pready,pslverr,irq,
    input wire cam_clk,cam_rst,cam_valid,cam_vs,cam_de,cam_error,
    input wire [47:0] cam_rgb,
    input wire camera_cancel,
    output wire camera_busy,camera_config_error,camera_snapshot_valid,
    output wire [31:0] camera_seen,camera_skipped,
    output wire [15:0] camera_fifo_peak,
    output wire camera_result_valid,camera_result_failed,camera_result_admitted,
    output wire [3:0] camera_result_code,
    output wire [31:0] camera_result_tag,
    input wire display_request,
    output wire display_request_ready,
    input wire p_req,p_sof,p_eol,p_eof,
    output wire m_valid,m_sof,m_eol,m_eof,
    output wire [23:0] m_rgb,
    output wire front_valid,display_frame_armed,
    output wire [31:0] display_pair_tag,
    output wire nn_complete,nn_failed,
    output wire [31:0] nn_result_tag,nn_result_cycles,
    output wire fabric_error,
    output wire [7:0] physical_read_outstanding,physical_write_outstanding,
    input wire [31:0] cpu_araddr,
    input wire [7:0] cpu_arlen,
    input wire [2:0] cpu_arsize,
    input wire [1:0] cpu_arburst,
    input wire cpu_arvalid,
    output wire cpu_arready,
    output wire [127:0] cpu_rdata,
    output wire [1:0] cpu_rresp,
    output wire cpu_rlast,
    output wire cpu_rvalid,
    input wire cpu_rready,
    input wire [31:0] cpu_awaddr,
    input wire [7:0] cpu_awlen,
    input wire [2:0] cpu_awsize,
    input wire [1:0] cpu_awburst,
    input wire cpu_awvalid,
    output wire cpu_awready,
    input wire [127:0] cpu_wdata,
    input wire [15:0] cpu_wstrb,
    input wire cpu_wlast,
    input wire cpu_wvalid,
    output wire cpu_wready,
    output wire [1:0] cpu_bresp,
    output wire cpu_bvalid,
    input wire cpu_bready,
    output wire [3:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,m_axi_arqos,
    output wire [2:0] m_axi_arprot,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,m_axi_rvalid,
    output wire m_axi_rready,
    output wire [3:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,m_axi_awqos,
    output wire [2:0] m_axi_awprot,
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
    wire [3:0][31:0] s_araddr;
    wire [3:0][7:0] s_arlen;
    wire [3:0][2:0] s_arsize;
    wire [3:0][1:0] s_arburst;
    wire [3:0] s_arvalid;
    wire [3:0] s_arready;
    wire [3:0][127:0] s_rdata;
    wire [3:0][1:0] s_rresp;
    wire [3:0] s_rlast;
    wire [3:0] s_rvalid;
    wire [3:0] s_rready;
    wire [3:0][31:0] s_awaddr;
    wire [3:0][7:0] s_awlen;
    wire [3:0][2:0] s_awsize;
    wire [3:0][1:0] s_awburst;
    wire [3:0] s_awvalid;
    wire [3:0] s_awready;
    wire [3:0][127:0] s_wdata;
    wire [3:0][15:0] s_wstrb;
    wire [3:0] s_wlast;
    wire [3:0] s_wvalid;
    wire [3:0] s_wready;
    wire [3:0][1:0] s_bresp;
    wire [3:0] s_bvalid;
    wire [3:0] s_bready;

    assign s_araddr[3]=cpu_araddr;
    assign s_arlen[3]=cpu_arlen;
    assign s_arsize[3]=cpu_arsize;
    assign s_arburst[3]=cpu_arburst;
    assign s_arvalid[3]=cpu_arvalid;
    assign cpu_arready=s_arready[3];
    assign cpu_rdata=s_rdata[3];
    assign cpu_rresp=s_rresp[3];
    assign cpu_rlast=s_rlast[3];
    assign cpu_rvalid=s_rvalid[3];
    assign s_rready[3]=cpu_rready;
    assign s_awaddr[3]=cpu_awaddr;
    assign s_awlen[3]=cpu_awlen;
    assign s_awsize[3]=cpu_awsize;
    assign s_awburst[3]=cpu_awburst;
    assign s_awvalid[3]=cpu_awvalid;
    assign cpu_awready=s_awready[3];
    assign s_wdata[3]=cpu_wdata;
    assign s_wstrb[3]=cpu_wstrb;
    assign s_wlast[3]=cpu_wlast;
    assign s_wvalid[3]=cpu_wvalid;
    assign cpu_wready=s_wready[3];
    assign cpu_bresp=s_bresp[3];
    assign cpu_bvalid=s_bvalid[3];
    assign s_bready[3]=cpu_bready;
    assign s_araddr[1]=0;assign s_arlen[1]=0;assign s_arsize[1]=4;assign s_arburst[1]=1;assign s_arvalid[1]=0;assign s_rready[1]=1;
    assign s_awaddr[2]=0;assign s_awlen[2]=0;assign s_awsize[2]=4;assign s_awburst[2]=1;assign s_awvalid[2]=0;
    assign s_wdata[2]=0;assign s_wstrb[2]=0;assign s_wlast[2]=0;assign s_wvalid[2]=0;assign s_bready[2]=1;
    wire enabled,lease_error,cap_active,nn_active,display_active;
    wire [2:0] request_enable;
    wire lease_cap_ready,lease_display_ready;
    wire capture_request,capture_request_ready;
    wire [31:0] capture_tag;
    wire cap_admission=capture_request && capture_request_ready;
    assign capture_request_ready=lease_cap_ready && request_enable[0];
    wire s_valid,s_ready,s_sof,s_eol,s_eof,source_error,source_cancel;
    wire [23:0] s_rgb;wire [15:0] s_x,s_y;wire [3:0] source_error_code;
    wire writer_done,writer_error,writer_drop,capture_overflow;
    wire [31:0] cam_seen_src,cam_skipped_src;
    wire [$clog2(CAMERA_FIFO):0] cam_peak_src;
    wire cam_busy_src;
    wire [80:0] camera_snapshot;
    wire base_pready,base_pslverr;wire [31:0] base_prdata;
    wire camera_page=paddr[7:6]==2'b10;
    wire camera_access=!rst && psel && penable && camera_page;
    logic [31:0] camera_prdata;
    logic camera_legal;
    logic [31:0] camera_results,camera_bad,camera_unadmitted,camera_last_tag;
    logic [5:0] camera_last_status;
    function automatic signed [31:0] rounded_q(input logic signed [63:0] n,input integer d);
        begin rounded_q=n<0 ? -((-n+d/2)/d) : (n+d/2)/d;end
    endfunction
    localparam signed [31:0] XS=rounded_q(64'(ROI_WIDTH)<<16,WIDTH);
    localparam signed [31:0] YS=rounded_q(64'(ROI_HEIGHT)<<16,HEIGHT);
    localparam signed [31:0] XP=rounded_q((64'(ROI_WIDTH)-64'(WIDTH))<<<15,WIDTH);
    localparam signed [31:0] YP=rounded_q((64'(ROI_HEIGHT)-64'(HEIGHT))<<<15,HEIGHT);

    assign display_request_ready=lease_display_ready && request_enable[2];
    wire graph_start_valid,graph_start_ready,graph_done_valid,graph_done_ready,graph_done_error,graph_busy,graph_protocol_error;
    wire [31:0] graph_cycles,input_base,workspace_base,output_base,parameter_base,nn_tag;
    wire [10:0] frame_width=WIDTH;wire [9:0] frame_height=HEIGHT;
    wire [7:0] read_outstanding,write_outstanding;
    wire [4:0] active_stage,stage_done_index;wire stage_done,interconnect_error,cap_protocol,scan_protocol;
    wire cap_cmd_valid,cap_cmd_ready,cap_done_valid,cap_done_ready,cap_error,cap_drop,cap_busy;
    wire [31:0] cap_base,cap_tag;
    wire disp_cmd_valid,disp_cmd_ready,disp_done_valid,disp_done_ready,disp_error,disp_cancel,disp_busy;
    wire [31:0] disp_raw,disp_style,disp_tag;
    wire overflow_event,underflow_event;
    wire [31:0] dropped_captures,retired_pairs,display_errors,capture_count,nn_count,display_count,underflow_count,last_nn_cycles,last_nn_tag;
    wire run_enable=enabled && platform_ready && !fabric_error && !lease_error;
    wire cap_event=camera_result_valid,cap_bad=camera_result_failed;
    assign cap_done_valid=camera_result_valid && camera_result_admitted;
    assign cap_error=camera_result_failed;assign cap_drop=camera_result_failed;
    assign overflow_event=capture_overflow || (camera_result_valid && camera_result_failed && camera_result_code==2);
    wire nn_event=graph_done_valid && graph_done_ready,nn_bad=graph_done_error || fabric_error;
    wire display_event=disp_done_valid && disp_done_ready,display_bad=disp_error || disp_cancel;
    assign fabric_error=interconnect_error || graph_protocol_error || cap_protocol || scan_protocol;
    assign nn_complete=nn_event;assign nn_failed=nn_bad;assign nn_result_tag=nn_tag;assign nn_result_cycles=graph_cycles;
    assign display_frame_armed=disp_cmd_valid && disp_cmd_ready;assign display_pair_tag=disp_tag;
    wire pair_valid,pair_sof,pair_eol,pair_eof,raster_error;
    wire [47:0] pair_rgb;
    c1_r2_rgb2_raster_source #(.SOURCE_WIDTH(SOURCE_WIDTH),.SOURCE_HEIGHT(SOURCE_HEIGHT)) u_raster (
        .clk(cam_clk),.rst(cam_rst),.in_vs(cam_vs),.in_de(cam_de),.in_valid(cam_valid),.in_rgb(cam_rgb),
        .pair_valid(pair_valid),.pair_sof(pair_sof),.pair_eol(pair_eol),.pair_eof(pair_eof),
        .pair_error(raster_error),.pair_rgb(pair_rgb));
    c1_r2_camera_decimated_ingress #(.SOURCE_WIDTH(SOURCE_WIDTH),.SOURCE_HEIGHT(SOURCE_HEIGHT),
        .ROI_X(ROI_X),.ROI_Y(ROI_Y),.ROI_WIDTH(ROI_WIDTH),.ROI_HEIGHT(ROI_HEIGHT),
        .FIFO_DEPTH(CAMERA_FIFO),.FRAME_TIMEOUT(FRAME_TIMEOUT),.FRAME_DIVISOR(FRAME_DIVISOR)) u_ingress (
        .cam_clk(cam_clk),.cam_rst(cam_rst),.cam_valid(pair_valid),.cam_sof(pair_sof),.cam_eol(pair_eol),.cam_eof(pair_eof),
        .cam_error(cam_error || raster_error),.cam_rgb(pair_rgb),.cam_busy(cam_busy_src),
        .cam_seen(cam_seen_src),.cam_skipped(cam_skipped_src),.cam_peak(cam_peak_src),
        .clk(clk),.rst(rst),.enable(run_enable && request_enable[0]),.cancel(camera_cancel),
        .job_valid(capture_request),.job_ready(capture_request_ready),.job_tag(capture_tag),
        .job_done(writer_done),.job_failed(writer_error || writer_drop),.job_cancel(source_cancel),
        .s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),.s_rgb(s_rgb),.s_x(s_x),.s_y(s_y),
        .busy(camera_busy),.config_error(camera_config_error),
        .result_valid(camera_result_valid),.result_failed(camera_result_failed),.result_admitted(camera_result_admitted),
        .result_code(camera_result_code),.result_tag(camera_result_tag));
    // Latest telemetry is coherent per snapshot, not a lossless event queue.
    // Frame ownership uses core-domain result events, NEVER this snapshot.
    c1_cdc_latest_snapshot_guarded #(.WIDTH(81)) u_camera_snapshot (
        .src_clk(cam_clk),.src_rst(cam_rst),.src_data({cam_seen_src,cam_skipped_src,16'(cam_peak_src),cam_busy_src}),
        .dst_clk(clk),.dst_rst(rst),.dst_data(camera_snapshot),.dst_valid(camera_snapshot_valid),.dst_update());
    assign camera_seen=camera_snapshot[80:49];
    assign camera_skipped=camera_snapshot[48:17];
    assign camera_fifo_peak=camera_snapshot[16:1];
    assign prdata=camera_page ? camera_prdata : base_prdata;
    assign pready=camera_page ? !rst : base_pready;
    assign pslverr=camera_page ? camera_access && (!camera_legal || pwrite) : base_pslverr;
    always_comb begin
        camera_prdata=0;camera_legal=1;
        case(paddr)
            8'h80:camera_prdata=32'h52324332; // R2C2: peak/depth now count pair records; base R2V2 unchanged
            8'h84:camera_prdata={29'd0,camera_snapshot[0],camera_snapshot_valid,camera_busy};
            8'h88:camera_prdata=camera_seen;
            8'h8c:camera_prdata=camera_skipped;
            8'h90:camera_prdata={16'd0,camera_fifo_peak};
            8'h94:camera_prdata=camera_results;
            8'h98:camera_prdata=camera_bad;
            8'h9c:camera_prdata=camera_unadmitted;
            8'ha0:camera_prdata=camera_last_tag;
            8'ha4:camera_prdata={26'd0,camera_last_status};
            8'ha8:camera_prdata={16'(SOURCE_HEIGHT),16'(SOURCE_WIDTH)};
            8'hac:camera_prdata={16'(ROI_HEIGHT),16'(ROI_WIDTH)};
            8'hb0:camera_prdata={16'(ROI_Y),16'(ROI_X)};
            8'hb4:camera_prdata=CAMERA_FIFO;
            8'hb8:camera_prdata=32'h01310201; // revision=1, record_bits=49, pixels=2, unit=1(pair record)
            8'hbc:camera_prdata=FRAME_DIVISOR;
            default:camera_legal=0;
        endcase
    end
    always_ff @(posedge clk)begin
        if(rst)begin camera_results<=0;camera_bad<=0;camera_unadmitted<=0;camera_last_tag<=0;camera_last_status<=0;end
        else if(camera_result_valid)begin
            camera_results<=camera_results+1;
            if(camera_result_failed)camera_bad<=camera_bad+1;
            if(!camera_result_admitted)camera_unadmitted<=camera_unadmitted+1;
            camera_last_tag<=camera_result_tag;
            camera_last_status<={camera_result_code,camera_result_failed,camera_result_admitted};
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(!rst && camera_result_valid && camera_result_admitted)begin
        if(!cap_done_ready || camera_result_tag!=cap_tag || writer_done)
            $fatal(1,"camera final completion missing lease or preceded capture drain fence");
    end
`endif
    c1_r2_video_rgbx_csr #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.ARENA_BASE(ARENA_BASE)) u_control (
        .clk(clk),.rst(rst),.psel(psel && !camera_page),.penable(penable),.pwrite(pwrite),.paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),
        .prdata(base_prdata),.pready(base_pready),.pslverr(base_pslverr),.enabled(enabled),.request_enable(request_enable),.irq(irq),
        .platform_ready(platform_ready),.fabric_error(fabric_error),.lease_error(lease_error),.cap_active(cap_active),.nn_active(nn_active),
        .display_active(display_active),.front_valid(front_valid),.cap_event(cap_event),.cap_bad(cap_bad),.nn_event(nn_event),.nn_bad(nn_bad),
        .display_event(display_event),.display_bad(display_bad),.overflow_event(overflow_event),.underflow_event(underflow_event),
        .nn_cycles(graph_cycles),.nn_tag(nn_tag),.dropped_captures(dropped_captures),.retired_pairs(retired_pairs),
        .read_outstanding(physical_read_outstanding),.write_outstanding(physical_write_outstanding),
        .capture_count(capture_count),.nn_count(nn_count),.display_count(display_count),.underflow_count(underflow_count),
        .last_nn_cycles(last_nn_cycles),.last_nn_tag(last_nn_tag)
    );
    c1_r2_video_fresh_leases #(.ARENA_BASE(ARENA_BASE)) u_leases (
        .clk(clk),.rst(rst),.enable(run_enable),.cap_request(cap_admission),.capture_tag(capture_tag),.cap_request_ready(lease_cap_ready),
        .cap_cmd_valid(cap_cmd_valid),.cap_cmd_ready(cap_cmd_ready),.cap_base(cap_base),.cap_tag(cap_tag),
        .cap_done_valid(cap_done_valid),.cap_done_bad(cap_bad),.cap_done_ready(cap_done_ready),
        .nn_request(request_enable[1]),.nn_request_ready(),.nn_cmd_valid(graph_start_valid),.nn_cmd_ready(graph_start_ready),
        .nn_input(input_base),.nn_output(output_base),.nn_workspace(workspace_base),.nn_parameters(parameter_base),.nn_tag(nn_tag),
        .nn_done_valid(graph_done_valid),.nn_done_bad(nn_bad),.nn_done_ready(graph_done_ready),
        .display_request(display_request && request_enable[2]),.display_request_ready(lease_display_ready),
        .display_cmd_valid(disp_cmd_valid),.display_cmd_ready(disp_cmd_ready),.display_raw(disp_raw),.display_style(disp_style),.display_tag(disp_tag),
        .display_done_valid(disp_done_valid),.display_done_bad(display_bad),.display_done_ready(disp_done_ready),
        .input_owned(),.output_owned(),.capture_active(cap_active),.nn_active(nn_active),.display_active(display_active),.front_valid(front_valid),
        .dropped_captures(dropped_captures),.retired_pairs(retired_pairs),.display_errors(display_errors),.protocol_error(lease_error)
    );
    c1_r2_resize_overlap_capture #(.FIFO_DEPTH(CAPTURE_FIFO)) u_capture (
        .clk(clk),.rst(rst),.cmd_valid(cap_cmd_valid),.cmd_ready(cap_cmd_ready),.cfg_base(cap_base),.cfg_tag(cap_tag),.cfg_width(frame_width),.cfg_height(frame_height),
        .cfg_source_width(16'(ROI_WIDTH)),.cfg_source_height(16'(ROI_HEIGHT)),
        .cfg_x_step_q16(XS),.cfg_y_step_q16(YS),.cfg_x_phase0_q16(XP),.cfg_y_phase0_q16(YP),
        .s_x(s_x),.s_y(s_y),.s_ready(s_ready),.source_error(source_error),.source_error_code(source_error_code),
        .cancel(source_cancel),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),.s_rgb(s_rgb),.busy(cap_busy),
        .done_valid(writer_done),.done_ready(1'b1),.done_error(writer_error),.done_dropped(writer_drop),.done_base(),.done_tag(),
        .overflow_pulse(capture_overflow),.peak_level(),.protocol_error(cap_protocol),.outstanding(),.m_axi_awid(),.m_axi_bid(m_axi_bid),
        .m_axi_awaddr(s_awaddr[1]),
        .m_axi_awlen(s_awlen[1]),
        .m_axi_awsize(s_awsize[1]),
        .m_axi_awburst(s_awburst[1]),
        .m_axi_awvalid(s_awvalid[1]),
        .m_axi_awready(s_awready[1]),
        .m_axi_wdata(s_wdata[1]),
        .m_axi_wstrb(s_wstrb[1]),
        .m_axi_wlast(s_wlast[1]),
        .m_axi_wvalid(s_wvalid[1]),
        .m_axi_wready(s_wready[1]),
        .m_axi_bresp(s_bresp[1]),
        .m_axi_bvalid(s_bvalid[1]),
        .m_axi_bready(s_bready[1])
    );
    c1_r2_video_scanout_rgbx32 #(.FIFO_DEPTH(DISPLAY_FIFO)) u_scanout (
        .clk(clk),.rst(rst),.cmd_valid(disp_cmd_valid),.cmd_ready(disp_cmd_ready),.cfg_raw_base(disp_raw),.cfg_style_base(disp_style),.cfg_tag(disp_tag),
        .cfg_width(frame_width),.cfg_height(frame_height),.cancel(1'b0),.p_req(p_req),.p_sof(p_sof),.p_eol(p_eol),.p_eof(p_eof),
        .m_valid(m_valid),.m_rgb(m_rgb),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.busy(disp_busy),.prefill_ready(),
        .done_valid(disp_done_valid),.done_ready(disp_done_ready),.done_error(disp_error),.done_cancelled(disp_cancel),
        .done_raw_base(),.done_style_base(),.done_tag(),.underflow_pulse(underflow_event),.peak_level(),.min_active_level(),
        .protocol_error(scan_protocol),.outstanding(),.m_axi_arid(),.m_axi_rid(m_axi_rid),
        .m_axi_araddr(s_araddr[2]),
        .m_axi_arlen(s_arlen[2]),
        .m_axi_arsize(s_arsize[2]),
        .m_axi_arburst(s_arburst[2]),
        .m_axi_arvalid(s_arvalid[2]),
        .m_axi_arready(s_arready[2]),
        .m_axi_rdata(s_rdata[2]),
        .m_axi_rresp(s_rresp[2]),
        .m_axi_rlast(s_rlast[2]),
        .m_axi_rvalid(s_rvalid[2]),
        .m_axi_rready(s_rready[2])
    );
    c1_r2_ring_rgbx_axi_graph u_cnn (
        .clk(clk),.rst(rst),.start_valid(graph_start_valid),.start_ready(graph_start_ready),
        .frame_width(frame_width),.frame_height(frame_height),.input_base(input_base),.workspace_base(workspace_base),.output_base(output_base),.parameter_base(parameter_base),
        .busy(graph_busy),.done_valid(graph_done_valid),.done_ready(graph_done_ready),.done_error(graph_done_error),.frame_cycles(graph_cycles),
        .stage_done(stage_done),.stage_done_index(stage_done_index),.active_stage(active_stage),
        .protocol_error(graph_protocol_error),.read_outstanding(read_outstanding),.write_outstanding(write_outstanding),
        .m_axi_arid(),.m_axi_awid(),.m_axi_arlock(),.m_axi_arcache(),.m_axi_arqos(),.m_axi_arprot(),
        .m_axi_awlock(),.m_axi_awcache(),.m_axi_awqos(),.m_axi_awprot(),.m_axi_rid(m_axi_rid),.m_axi_bid(m_axi_bid),
        .m_axi_araddr(s_araddr[0]),
        .m_axi_arlen(s_arlen[0]),
        .m_axi_arsize(s_arsize[0]),
        .m_axi_arburst(s_arburst[0]),
        .m_axi_arvalid(s_arvalid[0]),
        .m_axi_arready(s_arready[0]),
        .m_axi_rdata(s_rdata[0]),
        .m_axi_rresp(s_rresp[0]),
        .m_axi_rlast(s_rlast[0]),
        .m_axi_rvalid(s_rvalid[0]),
        .m_axi_rready(s_rready[0]),
        .m_axi_awaddr(s_awaddr[0]),
        .m_axi_awlen(s_awlen[0]),
        .m_axi_awsize(s_awsize[0]),
        .m_axi_awburst(s_awburst[0]),
        .m_axi_awvalid(s_awvalid[0]),
        .m_axi_awready(s_awready[0]),
        .m_axi_wdata(s_wdata[0]),
        .m_axi_wstrb(s_wstrb[0]),
        .m_axi_wlast(s_wlast[0]),
        .m_axi_wvalid(s_wvalid[0]),
        .m_axi_wready(s_wready[0]),
        .m_axi_bresp(s_bresp[0]),
        .m_axi_bvalid(s_bvalid[0]),
        .m_axi_bready(s_bready[0])
    );
    c1_r2_axi_fabric #(.CLIENTS(4),.FIFO_DEPTH(FIFO_DEPTH)) u_fabric (
        .clk(clk),.rst(rst),.protocol_error(interconnect_error),
        .physical_read_outstanding(physical_read_outstanding),.physical_write_outstanding(physical_write_outstanding),
        .s_araddr(s_araddr),
        .s_arlen(s_arlen),
        .s_arsize(s_arsize),
        .s_arburst(s_arburst),
        .s_arvalid(s_arvalid),
        .s_arready(s_arready),
        .s_rdata(s_rdata),
        .s_rresp(s_rresp),
        .s_rlast(s_rlast),
        .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .s_awaddr(s_awaddr),
        .s_awlen(s_awlen),
        .s_awsize(s_awsize),
        .s_awburst(s_awburst),
        .s_awvalid(s_awvalid),
        .s_awready(s_awready),
        .s_wdata(s_wdata),
        .s_wstrb(s_wstrb),
        .s_wlast(s_wlast),
        .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bresp(s_bresp),
        .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
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
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_awid(m_axi_awid),
        .m_axi_rid(m_axi_rid),
        .m_axi_bid(m_axi_bid),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awprot(m_axi_awprot)
    );
endmodule
