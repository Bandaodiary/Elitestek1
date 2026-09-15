`timescale 1ns/1ps

// Board-independent integration boundary for case 1.
//
// Implemented here:
//   * APB3 configuration/status/interrupt block
//   * three-input/two-output frame ownership manager
//   * explicit camera, memory, Sapphire and video vendor seams
//
// Not implemented here yet:
//   * camera PHY/CSI-2, ISP, frame DMA, CNN scheduler/data path, display DMA,
//     video timing generation, DDR controller/PHY, or Sapphire itself
//
// The future processing pipeline connects through the pipeline_* and
// core_mem_* ports.  Keeping these ports explicit lets this skeleton compile
// without depending on in-progress CNN modules or any FPGA vendor library.
module c1_portable_top #(
    parameter integer APB_ADDR_W = 12,
    parameter integer CAM_PIXEL_W = 16,
    parameter integer MEM_ADDR_W = 32,
    parameter integer MEM_DATA_W = 128
) (
    input  wire                         core_clk,
    input  wire                         core_rst_n,

    // Sapphire/APB-side boundary.
    input  wire                         cpu_psel,
    input  wire                         cpu_penable,
    input  wire                         cpu_pwrite,
    input  wire [APB_ADDR_W-1:0]        cpu_paddr,
    input  wire [31:0]                  cpu_pwdata,
    input  wire [3:0]                   cpu_pstrb,
    output wire [31:0]                  cpu_prdata,
    output wire                         cpu_pready,
    output wire                         cpu_pslverr,
    output wire                         irq,

    // Camera vendor side.  At present this is already-decoded pixel data;
    // real CSI-2/D-PHY logic belongs outside the portable core.
    input  wire                         camera_pixel_clk,
    input  wire [CAM_PIXEL_W-1:0]       camera_pixel_data,
    input  wire                         camera_pixel_valid,
    input  wire                         camera_pixel_sof,
    input  wire                         camera_pixel_eol,
    input  wire                         camera_pixel_eof,
    output wire                         camera_pixel_ready,

    // Camera stream presented to the future ISP/capture pipeline.
    output wire                         pipeline_camera_pixel_clk,
    output wire [CAM_PIXEL_W-1:0]       pipeline_camera_pixel_data,
    output wire                         pipeline_camera_pixel_valid,
    output wire                         pipeline_camera_pixel_sof,
    output wire                         pipeline_camera_pixel_eol,
    output wire                         pipeline_camera_pixel_eof,
    input  wire                         pipeline_camera_pixel_ready,

    // Future portable display pipeline supplies parallel video here.
    input  wire                         pipeline_video_pixel_clk,
    input  wire [23:0]                  pipeline_video_rgb,
    input  wire                         pipeline_video_de,
    input  wire                         pipeline_video_hsync,
    input  wire                         pipeline_video_vsync,
    output wire                         video_pixel_clk,
    output wire [23:0]                  video_rgb,
    output wire                         video_de,
    output wire                         video_hsync,
    output wire                         video_vsync,

    // Portable DMA/interconnect AXI master side.
    input  wire [MEM_ADDR_W-1:0]        core_mem_awaddr,
    input  wire [7:0]                   core_mem_awlen,
    input  wire [2:0]                   core_mem_awsize,
    input  wire [1:0]                   core_mem_awburst,
    input  wire                         core_mem_awvalid,
    output wire                         core_mem_awready,
    input  wire [MEM_DATA_W-1:0]        core_mem_wdata,
    input  wire [(MEM_DATA_W/8)-1:0]    core_mem_wstrb,
    input  wire                         core_mem_wlast,
    input  wire                         core_mem_wvalid,
    output wire                         core_mem_wready,
    output wire [1:0]                   core_mem_bresp,
    output wire                         core_mem_bvalid,
    input  wire                         core_mem_bready,
    input  wire [MEM_ADDR_W-1:0]        core_mem_araddr,
    input  wire [7:0]                   core_mem_arlen,
    input  wire [2:0]                   core_mem_arsize,
    input  wire [1:0]                   core_mem_arburst,
    input  wire                         core_mem_arvalid,
    output wire                         core_mem_arready,
    output wire [MEM_DATA_W-1:0]        core_mem_rdata,
    output wire [1:0]                   core_mem_rresp,
    output wire                         core_mem_rlast,
    output wire                         core_mem_rvalid,
    input  wire                         core_mem_rready,

    // Vendor DDR-controller AXI side.
    output wire [MEM_ADDR_W-1:0]        ddr_awaddr,
    output wire [7:0]                   ddr_awlen,
    output wire [2:0]                   ddr_awsize,
    output wire [1:0]                   ddr_awburst,
    output wire                         ddr_awvalid,
    input  wire                         ddr_awready,
    output wire [MEM_DATA_W-1:0]        ddr_wdata,
    output wire [(MEM_DATA_W/8)-1:0]    ddr_wstrb,
    output wire                         ddr_wlast,
    output wire                         ddr_wvalid,
    input  wire                         ddr_wready,
    input  wire [1:0]                   ddr_bresp,
    input  wire                         ddr_bvalid,
    output wire                         ddr_bready,
    output wire [MEM_ADDR_W-1:0]        ddr_araddr,
    output wire [7:0]                   ddr_arlen,
    output wire [2:0]                   ddr_arsize,
    output wire [1:0]                   ddr_arburst,
    output wire                         ddr_arvalid,
    input  wire                         ddr_arready,
    input  wire [MEM_DATA_W-1:0]        ddr_rdata,
    input  wire [1:0]                   ddr_rresp,
    input  wire                         ddr_rlast,
    input  wire                         ddr_rvalid,
    output wire                         ddr_rready,

    // Capture/CNN/display ownership events from future data movers.
    input  wire                         capture_frame_start,
    input  wire                         capture_frame_done,
    output wire                         capture_accept_pulse,
    output wire                         capture_drop_pulse,
    output wire [1:0]                   capture_input_index,
    output wire [31:0]                  capture_frame_id,

    input  wire                         nn_job_request,
    input  wire                         nn_done,
    input  wire                         accelerator_busy,
    output wire                         nn_job_grant,
    output wire [1:0]                   nn_input_index,
    output wire                         nn_output_index,
    output wire [31:0]                  nn_frame_id,

    input  wire                         display_vsync_event,
    input  wire                         display_underflow_event,
    output wire                         display_swap_pulse,
    output wire [1:0]                   display_input_index,
    output wire                         display_output_index,
    output wire [31:0]                  display_frame_id,
    output wire                         display_active,

    // Future pipeline error reporting.
    input  wire                         pipeline_error_event,
    input  wire [7:0]                   pipeline_error_code,
    input  wire [31:0]                  pipeline_error_address,

    // Software-visible configuration exported to future pipeline blocks.
    output wire                         system_enable,
    output wire                         continuous_mode,
    output wire                         start_pulse,
    output wire                         abort_pulse,
    output wire                         clear_stats_pulse,
    output wire [15:0]                  frame_width,
    output wire [15:0]                  frame_height,
    output wire [31:0]                  input_stride_bytes,
    output wire [31:0]                  output_stride_bytes,
    output wire [3:0]                   input_pixel_format,
    output wire [3:0]                   output_pixel_format,
    output wire [63:0]                  input_buffer_table_base,
    output wire [63:0]                  output_buffer_table_base,
    output wire [63:0]                  descriptor_base,
    output wire [15:0]                  descriptor_count,
    output wire [7:0]                   style_id,
    output wire [63:0]                  weight_base,
    output wire [7:0]                   display_mode,
    output wire [31:0]                  dropped_frame_count
);

    wire csr_psel;
    wire csr_penable;
    wire csr_pwrite;
    wire [APB_ADDR_W-1:0] csr_paddr;
    wire [31:0] csr_pwdata;
    wire [3:0] csr_pstrb;
    wire [31:0] csr_prdata;
    wire csr_pready;
    wire csr_pslverr;

    wire drop_oldest_mode;
    wire [2:0] input_ready_count;
    wire [1:0] output_ready_count;
    wire capture_active;
    wire frame_nn_active;
    wire system_busy;
    wire valid_nn_done;

    assign system_busy = accelerator_busy | frame_nn_active;
    assign valid_nn_done = nn_done & frame_nn_active;

    c1_sapphire_vendor_adapter_stub #(
        .APB_ADDR_W(APB_ADDR_W)
    ) u_sapphire_boundary (
        .vendor_psel(cpu_psel),
        .vendor_penable(cpu_penable),
        .vendor_pwrite(cpu_pwrite),
        .vendor_paddr(cpu_paddr),
        .vendor_pwdata(cpu_pwdata),
        .vendor_pstrb(cpu_pstrb),
        .vendor_prdata(cpu_prdata),
        .vendor_pready(cpu_pready),
        .vendor_pslverr(cpu_pslverr),
        .core_psel(csr_psel),
        .core_penable(csr_penable),
        .core_pwrite(csr_pwrite),
        .core_paddr(csr_paddr),
        .core_pwdata(csr_pwdata),
        .core_pstrb(csr_pstrb),
        .core_prdata(csr_prdata),
        .core_pready(csr_pready),
        .core_pslverr(csr_pslverr)
    );

    c1_apb_csr #(
        .APB_ADDR_W(APB_ADDR_W)
    ) u_csr (
        .clk(core_clk),
        .rst_n(core_rst_n),
        .psel(csr_psel),
        .penable(csr_penable),
        .pwrite(csr_pwrite),
        .paddr(csr_paddr),
        .pwdata(csr_pwdata),
        .pstrb(csr_pstrb),
        .prdata(csr_prdata),
        .pready(csr_pready),
        .pslverr(csr_pslverr),
        .busy(system_busy),
        .done_event(valid_nn_done),
        .error_event(pipeline_error_event),
        .error_code_in(pipeline_error_code),
        .error_address_in(pipeline_error_address),
        .capture_drop_event(capture_drop_pulse),
        .display_swap_event(display_swap_pulse),
        .display_underflow_event(display_underflow_event),
        .input_ready_count(input_ready_count),
        .output_ready_count(output_ready_count),
        .qos_monitor_enabled(1'b0),
        .qos_frame_active(1'b0),
        .qos_monitor_overflow(1'b0),
        .qos_frame_count(32'd0),
        .qos_last_frame_cycles(32'd0),
        .qos_deadline_miss_count(32'd0),
        .qos_display_underflow_count(32'd0),
        .qos_read_busy_cycles(32'd0),
        .qos_write_busy_cycles(32'd0),
        .qos_read_owner_hold_max(32'd0),
        .qos_write_owner_hold_max(32'd0),
        .qos_protocol_error_count(32'd0),
        .system_enable(system_enable),
        .continuous_mode(continuous_mode),
        .drop_oldest_mode(drop_oldest_mode),
        .start_pulse(start_pulse),
        .abort_pulse(abort_pulse),
        .clear_stats_pulse(clear_stats_pulse),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .input_stride_bytes(input_stride_bytes),
        .output_stride_bytes(output_stride_bytes),
        .input_pixel_format(input_pixel_format),
        .output_pixel_format(output_pixel_format),
        .input_buffer_table_base(input_buffer_table_base),
        .output_buffer_table_base(output_buffer_table_base),
        .descriptor_base(descriptor_base),
        .descriptor_count(descriptor_count),
        .style_id(style_id),
        .weight_base(weight_base),
        .display_mode(display_mode),
        .irq(irq)
    );

    c1_frame_manager u_frame_manager (
        .clk(core_clk),
        .rst_n(core_rst_n),
        .abort(abort_pulse),
        .drop_oldest_mode(drop_oldest_mode),
        .cap_frame_start(capture_frame_start),
        .cap_frame_done(capture_frame_done),
        .cap_accept_pulse(capture_accept_pulse),
        .cap_drop_pulse(capture_drop_pulse),
        .cap_input_index(capture_input_index),
        .cap_frame_id(capture_frame_id),
        .nn_job_request(nn_job_request),
        .nn_done(valid_nn_done),
        .nn_job_grant(nn_job_grant),
        .nn_input_index(nn_input_index),
        .nn_output_index(nn_output_index),
        .nn_frame_id(nn_frame_id),
        .display_vsync(display_vsync_event),
        .display_swap_pulse(display_swap_pulse),
        .display_input_index(display_input_index),
        .display_output_index(display_output_index),
        .display_frame_id(display_frame_id),
        .display_active(display_active),
        .input_ready_count(input_ready_count),
        .output_ready_count(output_ready_count),
        .capture_active_out(capture_active),
        .nn_active_out(frame_nn_active),
        .dropped_frame_count(dropped_frame_count)
    );

    c1_camera_vendor_adapter_stub #(
        .PIXEL_W(CAM_PIXEL_W)
    ) u_camera_boundary (
        .vendor_pixel_clk(camera_pixel_clk),
        .vendor_pixel_data(camera_pixel_data),
        .vendor_pixel_valid(camera_pixel_valid),
        .vendor_pixel_sof(camera_pixel_sof),
        .vendor_pixel_eol(camera_pixel_eol),
        .vendor_pixel_eof(camera_pixel_eof),
        .vendor_pixel_ready(camera_pixel_ready),
        .core_pixel_clk(pipeline_camera_pixel_clk),
        .core_pixel_data(pipeline_camera_pixel_data),
        .core_pixel_valid(pipeline_camera_pixel_valid),
        .core_pixel_sof(pipeline_camera_pixel_sof),
        .core_pixel_eol(pipeline_camera_pixel_eol),
        .core_pixel_eof(pipeline_camera_pixel_eof),
        .core_pixel_ready(pipeline_camera_pixel_ready)
    );

    c1_memory_vendor_adapter_stub #(
        .ADDR_W(MEM_ADDR_W),
        .DATA_W(MEM_DATA_W)
    ) u_memory_boundary (
        .core_awaddr(core_mem_awaddr),
        .core_awlen(core_mem_awlen),
        .core_awsize(core_mem_awsize),
        .core_awburst(core_mem_awburst),
        .core_awvalid(core_mem_awvalid),
        .core_awready(core_mem_awready),
        .core_wdata(core_mem_wdata),
        .core_wstrb(core_mem_wstrb),
        .core_wlast(core_mem_wlast),
        .core_wvalid(core_mem_wvalid),
        .core_wready(core_mem_wready),
        .core_bresp(core_mem_bresp),
        .core_bvalid(core_mem_bvalid),
        .core_bready(core_mem_bready),
        .core_araddr(core_mem_araddr),
        .core_arlen(core_mem_arlen),
        .core_arsize(core_mem_arsize),
        .core_arburst(core_mem_arburst),
        .core_arvalid(core_mem_arvalid),
        .core_arready(core_mem_arready),
        .core_rdata(core_mem_rdata),
        .core_rresp(core_mem_rresp),
        .core_rlast(core_mem_rlast),
        .core_rvalid(core_mem_rvalid),
        .core_rready(core_mem_rready),
        .mem_awaddr(ddr_awaddr),
        .mem_awlen(ddr_awlen),
        .mem_awsize(ddr_awsize),
        .mem_awburst(ddr_awburst),
        .mem_awvalid(ddr_awvalid),
        .mem_awready(ddr_awready),
        .mem_wdata(ddr_wdata),
        .mem_wstrb(ddr_wstrb),
        .mem_wlast(ddr_wlast),
        .mem_wvalid(ddr_wvalid),
        .mem_wready(ddr_wready),
        .mem_bresp(ddr_bresp),
        .mem_bvalid(ddr_bvalid),
        .mem_bready(ddr_bready),
        .mem_araddr(ddr_araddr),
        .mem_arlen(ddr_arlen),
        .mem_arsize(ddr_arsize),
        .mem_arburst(ddr_arburst),
        .mem_arvalid(ddr_arvalid),
        .mem_arready(ddr_arready),
        .mem_rdata(ddr_rdata),
        .mem_rresp(ddr_rresp),
        .mem_rlast(ddr_rlast),
        .mem_rvalid(ddr_rvalid),
        .mem_rready(ddr_rready)
    );

    c1_video_vendor_adapter_stub u_video_boundary (
        .core_pixel_clk(pipeline_video_pixel_clk),
        .core_rgb(pipeline_video_rgb),
        .core_de(pipeline_video_de),
        .core_hsync(pipeline_video_hsync),
        .core_vsync(pipeline_video_vsync),
        .vendor_pixel_clk(video_pixel_clk),
        .vendor_rgb(video_rgb),
        .vendor_de(video_de),
        .vendor_hsync(video_hsync),
        .vendor_vsync(video_vsync)
    );

endmodule
