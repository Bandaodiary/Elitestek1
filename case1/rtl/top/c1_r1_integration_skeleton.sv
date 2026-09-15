`timescale 1ns/1ps

// Board-independent R1 integration skeleton.
//
// Real connections in this module:
//   APB mux -> main CSR -> latched job command -> descriptor scheduler/reader
//   APB mux -> ISP shadow/config bank -> R1 ISP active config and Gamma LUT
//   RAW10 input -> R1 ISP -> finite elastic RGB ready/valid boundary
//   XRGB8888 frame reader -> independent RGB ready/valid engine boundary
//   RGB ready/valid engine output -> XRGB8888 frame writer
//   descriptor reader + frame reader + frame writer -> one AXI4-128 port
//     through two cascaded, ID-less, transaction-locked arbiters
//
// Deliberate external boundaries (not fake compute):
//   * input/output_buffer_table_base are table pointers, while the existing
//     frame DMAs require resolved 32-bit frame addresses.  A future job/buffer
//     controller consumes job_command_* and supplies input_dma_base_addr and
//     output_dma_base_addr together with explicit DMA start pulses.
//   * Resize/MicroStyle execution is external.  It consumes either the ISP RGB
//     stream or the XRGB DMA RGB stream, consumes layer_command_*, and returns
//     engine_output_* plus layer_done/error.
//   * current frame DMAs have no protocol-safe abort input.  job_abort_pulse is
//     exported to the future job controller and only the descriptor scheduler
//     is directly aborted here.  A controller must drain already-started frame
//     DMAs or reset the complete AXI fabric; this skeleton never withdraws an
//     accepted AXI transaction.
//
// The ISP itself has no input/output backpressure.  A finite FIFO translates
// its output to ready/valid.  isp_stream_overflow_event reports any cycle that
// the fixed-rate ISP produces while that FIFO cannot accept; the eventual
// engine must sustain the configured pixel rate or provide a frame buffer.
// External rst_n is asynchronously asserted and synchronously released through
// c1_reset_sync before it reaches this clk domain.
module c1_r1_integration_skeleton #(
    parameter integer APB_ADDR_W       = 12,
    parameter integer ISP_FRAME_WIDTH  = 2560,
    parameter integer ISP_FRAME_HEIGHT = 1440,
    parameter integer ISP_X_BITS       = (ISP_FRAME_WIDTH <= 1) ? 1 : $clog2(ISP_FRAME_WIDTH),
    parameter integer ISP_Y_BITS       = (ISP_FRAME_HEIGHT <= 1) ? 1 : $clog2(ISP_FRAME_HEIGHT),
    parameter integer ISP_FIFO_DEPTH   = 16
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       psel,
    input  logic                       penable,
    input  logic                       pwrite,
    input  logic [APB_ADDR_W-1:0]      paddr,
    input  logic [31:0]                pwdata,
    input  logic [3:0]                 pstrb,
    output logic [31:0]                prdata,
    output logic                       pready,
    output logic                       pslverr,
    output logic                       irq,

    // Latched software job command.  valid remains asserted until ready or
    // CSR abort.  Table bases are intentionally not interpreted as frame data.
    output logic                       job_command_valid,
    input  logic                       job_command_ready,
    output logic                       job_command_accept_pulse,
    output logic                       job_abort_pulse,
    output logic [15:0]                job_frame_width,
    output logic [15:0]                job_frame_height,
    output logic                       job_continuous_mode,
    output logic                       job_drop_oldest_mode,
    output logic [31:0]                job_input_stride_bytes,
    output logic [31:0]                job_output_stride_bytes,
    output logic [3:0]                 job_input_pixel_format,
    output logic [3:0]                 job_output_pixel_format,
    output logic [63:0]                job_input_buffer_table_base,
    output logic [63:0]                job_output_buffer_table_base,
    output logic [31:0]                job_descriptor_base,
    output logic [15:0]                job_descriptor_count,
    output logic [7:0]                 job_style_id,
    output logic [63:0]                job_weight_base,
    output logic [7:0]                 job_display_mode,

    // Completion remains an explicit job-controller decision because the
    // descriptor scheduler and two optional frame DMAs finish independently.
    input  logic                       job_retire_done_event,
    input  logic                       job_retire_error_event,
    input  logic [7:0]                 job_retire_error_code,
    input  logic [31:0]                job_retire_error_address,
    input  logic                       external_engine_busy,
    output logic                       system_busy,

    // Resolved single-frame DMA command boundary.  Width/height/stride come
    // from the latched job command; the future buffer resolver supplies bases.
    // TODO: assert these starts only when the corresponding pixel format is 2
    // (XRGB8888).  Other CSR format encodings need different DMA front ends.
    input  logic                       input_dma_start,
    input  logic [31:0]                input_dma_base_addr,
    output logic                       input_dma_busy,
    output logic                       input_dma_done,
    output logic                       input_dma_error,
    input  logic                       output_dma_start,
    input  logic [31:0]                output_dma_base_addr,
    output logic                       output_dma_busy,
    output logic                       output_dma_done,
    output logic                       output_dma_error,

    // XRGB frame-reader stream to the external Resize/MicroStyle engine.
    output logic                       dma_input_valid,
    input  logic                       dma_input_ready,
    output logic [23:0]                dma_input_rgb,
    output logic                       dma_input_sof,
    output logic                       dma_input_eol,
    output logic                       dma_input_eof,
    output logic [15:0]                dma_input_x,
    output logic [15:0]                dma_input_y,

    // External Resize/MicroStyle output stream into the XRGB frame writer.
    input  logic                       engine_output_valid,
    output logic                       engine_output_ready,
    input  logic [23:0]                engine_output_rgb,
    input  logic                       engine_output_sof,
    input  logic                       engine_output_eol,
    input  logic                       engine_output_eof,

    // Descriptor/layer command boundary to the external compute engine.
    output logic                       layer_command_valid,
    input  logic                       layer_command_ready,
    output logic [15:0]                layer_command_index,
    output logic [511:0]               layer_command_descriptor,
    input  logic                       layer_done_pulse,
    input  logic                       layer_error_pulse,
    output logic                       descriptor_busy,
    output logic                       descriptor_done_pulse,
    output logic                       descriptor_error_pulse,
    output logic                       descriptor_aborted_pulse,
    output logic [15:0]                active_layer_index,

    // RAW10 camera/capture boundary.  This fixed-rate source has no ready.
    input  logic                       raw_input_valid,
    input  logic                       raw_input_sof,
    input  logic                       raw_input_eol,
    input  logic                       raw_input_eof,
    input  logic [ISP_X_BITS-1:0]      raw_input_x,
    input  logic [ISP_Y_BITS-1:0]      raw_input_y,
    input  logic [9:0]                 raw_input_raw10,

    // Elastic ISP RGB stream to the external Resize/MicroStyle engine.
    output logic                       isp_stream_valid,
    input  logic                       isp_stream_ready,
    output logic [23:0]                isp_stream_rgb,
    output logic                       isp_stream_sof,
    output logic                       isp_stream_eol,
    output logic                       isp_stream_eof,
    output logic [ISP_X_BITS-1:0]      isp_stream_x,
    output logic [ISP_Y_BITS-1:0]      isp_stream_y,
    output logic                       isp_stream_overflow_event,

    // Single ID-less AXI4-128 master after the cascaded arbiters.
    output logic [31:0]                m_axi_awaddr,
    output logic [7:0]                 m_axi_awlen,
    output logic [2:0]                 m_axi_awsize,
    output logic [1:0]                 m_axi_awburst,
    output logic                       m_axi_awvalid,
    input  logic                       m_axi_awready,
    output logic [127:0]               m_axi_wdata,
    output logic [15:0]                m_axi_wstrb,
    output logic                       m_axi_wlast,
    output logic                       m_axi_wvalid,
    input  logic                       m_axi_wready,
    input  logic [1:0]                 m_axi_bresp,
    input  logic                       m_axi_bvalid,
    output logic                       m_axi_bready,
    output logic [31:0]                m_axi_araddr,
    output logic [7:0]                 m_axi_arlen,
    output logic [2:0]                 m_axi_arsize,
    output logic [1:0]                 m_axi_arburst,
    output logic                       m_axi_arvalid,
    input  logic                       m_axi_arready,
    input  logic [127:0]               m_axi_rdata,
    input  logic [1:0]                 m_axi_rresp,
    input  logic                       m_axi_rlast,
    input  logic                       m_axi_rvalid,
    output logic                       m_axi_rready
);

    localparam integer ISP_STREAM_WIDTH = 27 + ISP_X_BITS + ISP_Y_BITS;
    localparam integer ISP_FIFO_LEVEL_WIDTH =
        (ISP_FIFO_DEPTH < 2) ? 1 : $clog2(ISP_FIFO_DEPTH + 1);

    logic local_rst_n;
    logic core_rst;

    logic csr_system_enable;
    logic csr_continuous_mode;
    logic csr_drop_oldest_mode;
    logic csr_start_pulse;
    logic csr_abort_pulse;
    logic csr_clear_stats_pulse;
    logic [15:0] csr_frame_width;
    logic [15:0] csr_frame_height;
    logic [31:0] csr_input_stride_bytes;
    logic [31:0] csr_output_stride_bytes;
    logic [3:0] csr_input_pixel_format;
    logic [3:0] csr_output_pixel_format;
    logic [63:0] csr_input_buffer_table_base;
    logic [63:0] csr_output_buffer_table_base;
    logic [63:0] csr_descriptor_base;
    logic [15:0] csr_descriptor_count;
    logic [7:0] csr_style_id;
    logic [63:0] csr_weight_base;
    logic [7:0] csr_display_mode;

    logic csr_apb_psel;
    logic csr_apb_penable;
    logic csr_apb_pwrite;
    logic [APB_ADDR_W-1:0] csr_apb_paddr;
    logic [31:0] csr_apb_pwdata;
    logic [3:0] csr_apb_pstrb;
    logic [31:0] csr_apb_prdata;
    logic csr_apb_pready;
    logic csr_apb_pslverr;

    logic isp_apb_psel;
    logic isp_apb_penable;
    logic isp_apb_pwrite;
    logic [APB_ADDR_W-1:0] isp_apb_paddr;
    logic [31:0] isp_apb_pwdata;
    logic [3:0] isp_apb_pstrb;
    logic [31:0] isp_apb_prdata;
    logic isp_apb_pready;
    logic isp_apb_pslverr;

    logic isp_cfg_commit;
    logic isp_cfg_ready;
    logic [1:0] isp_cfg_bayer_pattern;
    logic isp_cfg_roi_x_parity;
    logic isp_cfg_roi_y_parity;
    logic [9:0] isp_cfg_black_r;
    logic [9:0] isp_cfg_black_gr;
    logic [9:0] isp_cfg_black_gb;
    logic [9:0] isp_cfg_black_b;
    logic [15:0] isp_cfg_awb_gain_r;
    logic [15:0] isp_cfg_awb_gain_g;
    logic [15:0] isp_cfg_awb_gain_b;
    logic signed [15:0] isp_cfg_ccm_rr;
    logic signed [15:0] isp_cfg_ccm_rg;
    logic signed [15:0] isp_cfg_ccm_rb;
    logic signed [15:0] isp_cfg_ccm_gr;
    logic signed [15:0] isp_cfg_ccm_gg;
    logic signed [15:0] isp_cfg_ccm_gb;
    logic signed [15:0] isp_cfg_ccm_br;
    logic signed [15:0] isp_cfg_ccm_bg;
    logic signed [15:0] isp_cfg_ccm_bb;
    logic signed [31:0] isp_cfg_ccm_offset_r;
    logic signed [31:0] isp_cfg_ccm_offset_g;
    logic signed [31:0] isp_cfg_ccm_offset_b;
    logic isp_gamma_cfg_we;
    logic [9:0] isp_gamma_cfg_addr;
    logic [7:0] isp_gamma_cfg_data;
    logic isp_gamma_cfg_ready;
    logic isp_cfg_abort_pulse;

    logic scheduler_start_pulse;
    logic descriptor_launch_pending;
    logic local_start_error_pulse;
    logic [7:0] local_start_error_code;
    logic [31:0] local_start_error_address;

    logic combined_error_event;
    logic [7:0] combined_error_code;
    logic [31:0] combined_error_address;

    logic desc_arvalid;
    logic desc_arready;
    logic [31:0] desc_araddr;
    logic [7:0] desc_arlen;
    logic [2:0] desc_arsize;
    logic [1:0] desc_arburst;
    logic [127:0] desc_rdata;
    logic [1:0] desc_rresp;
    logic desc_rlast;
    logic desc_rvalid;
    logic desc_rready;

    logic frame_arvalid;
    logic frame_arready;
    logic [31:0] frame_araddr;
    logic [7:0] frame_arlen;
    logic [2:0] frame_arsize;
    logic [1:0] frame_arburst;
    logic [127:0] frame_rdata;
    logic [1:0] frame_rresp;
    logic frame_rlast;
    logic frame_rvalid;
    logic frame_rready;

    logic writer_awvalid;
    logic writer_awready;
    logic [31:0] writer_awaddr;
    logic [7:0] writer_awlen;
    logic [2:0] writer_awsize;
    logic [1:0] writer_awburst;
    logic [127:0] writer_wdata;
    logic [15:0] writer_wstrb;
    logic writer_wlast;
    logic writer_wvalid;
    logic writer_wready;
    logic [1:0] writer_bresp;
    logic writer_bvalid;
    logic writer_bready;

    // Inner arbiter output: descriptor reader + XRGB frame reader.
    logic [31:0] inner_awaddr;
    logic [7:0] inner_awlen;
    logic [2:0] inner_awsize;
    logic [1:0] inner_awburst;
    logic inner_awvalid;
    logic inner_awready;
    logic [127:0] inner_wdata;
    logic [15:0] inner_wstrb;
    logic inner_wlast;
    logic inner_wvalid;
    logic inner_wready;
    logic [1:0] inner_bresp;
    logic inner_bvalid;
    logic inner_bready;
    logic [31:0] inner_araddr;
    logic [7:0] inner_arlen;
    logic [2:0] inner_arsize;
    logic [1:0] inner_arburst;
    logic inner_arvalid;
    logic inner_arready;
    logic [127:0] inner_rdata;
    logic [1:0] inner_rresp;
    logic inner_rlast;
    logic inner_rvalid;
    logic inner_rready;

    logic isp_core_valid;
    logic isp_core_sof;
    logic isp_core_eol;
    logic isp_core_eof;
    logic [ISP_X_BITS-1:0] isp_core_x;
    logic [ISP_Y_BITS-1:0] isp_core_y;
    logic [23:0] isp_core_rgb;
    logic isp_fifo_in_ready;
    logic [ISP_STREAM_WIDTH-1:0] isp_fifo_in_data;
    logic [ISP_STREAM_WIDTH-1:0] isp_fifo_out_data;
    logic isp_fifo_full;
    logic isp_fifo_empty;
    logic [ISP_FIFO_LEVEL_WIDTH-1:0] isp_fifo_level;

    c1_reset_sync #(
        .STAGES(2)
    ) u_core_reset_sync (
        .clk(clk),
        .arst_n(rst_n),
        .srst_n(local_rst_n)
    );

    assign core_rst = ~local_rst_n;
    assign job_abort_pulse = csr_abort_pulse;
    assign system_busy = job_command_valid || descriptor_launch_pending || descriptor_busy ||
                         input_dma_busy || output_dma_busy ||
                         external_engine_busy;

    // Internal errors are reported automatically.  End-to-end successful job
    // retirement remains owned by the external job controller.
    always_comb begin
        combined_error_event = 1'b0;
        combined_error_code = 8'h00;
        combined_error_address = 32'h0000_0000;

        if (job_retire_error_event) begin
            combined_error_event = 1'b1;
            combined_error_code = job_retire_error_code;
            combined_error_address = job_retire_error_address;
        end else if (local_start_error_pulse) begin
            combined_error_event = 1'b1;
            combined_error_code = local_start_error_code;
            combined_error_address = local_start_error_address;
        end else if (descriptor_error_pulse) begin
            combined_error_event = 1'b1;
            combined_error_code = 8'h31;
            combined_error_address = job_descriptor_base;
        end else if (input_dma_done && input_dma_error) begin
            combined_error_event = 1'b1;
            combined_error_code = 8'h41;
            combined_error_address = input_dma_base_addr;
        end else if (output_dma_done && output_dma_error) begin
            combined_error_event = 1'b1;
            combined_error_code = 8'h42;
            combined_error_address = output_dma_base_addr;
        end else if (isp_stream_overflow_event) begin
            combined_error_event = 1'b1;
            combined_error_code = 8'h51;
            combined_error_address = {isp_core_y, isp_core_x};
        end
    end

    // One software-visible APB port is split into the fixed main-CSR and ISP
    // windows.  The full absolute address reaches each selected slave.
    c1_apb_r1_mux #(
        .APB_ADDR_W(APB_ADDR_W)
    ) u_apb_mux (
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .pstrb(pstrb),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .csr_psel(csr_apb_psel),
        .csr_penable(csr_apb_penable),
        .csr_pwrite(csr_apb_pwrite),
        .csr_paddr(csr_apb_paddr),
        .csr_pwdata(csr_apb_pwdata),
        .csr_pstrb(csr_apb_pstrb),
        .csr_prdata(csr_apb_prdata),
        .csr_pready(csr_apb_pready),
        .csr_pslverr(csr_apb_pslverr),
        .isp_psel(isp_apb_psel),
        .isp_penable(isp_apb_penable),
        .isp_pwrite(isp_apb_pwrite),
        .isp_paddr(isp_apb_paddr),
        .isp_pwdata(isp_apb_pwdata),
        .isp_pstrb(isp_apb_pstrb),
        .isp_prdata(isp_apb_prdata),
        .isp_pready(isp_apb_pready),
        .isp_pslverr(isp_apb_pslverr)
    );

    c1_apb_csr #(
        .APB_ADDR_W(APB_ADDR_W)
    ) u_csr (
        .clk(clk),
        .rst_n(local_rst_n),
        .psel(csr_apb_psel),
        .penable(csr_apb_penable),
        .pwrite(csr_apb_pwrite),
        .paddr(csr_apb_paddr),
        .pwdata(csr_apb_pwdata),
        .pstrb(csr_apb_pstrb),
        .prdata(csr_apb_prdata),
        .pready(csr_apb_pready),
        .pslverr(csr_apb_pslverr),
        .busy(system_busy),
        .done_event(job_retire_done_event),
        .error_event(combined_error_event),
        .error_code_in(combined_error_code),
        .error_address_in(combined_error_address),
        .capture_drop_event(1'b0),
        .display_swap_event(1'b0),
        .display_underflow_event(1'b0),
        .input_ready_count(3'd0),
        .output_ready_count(2'd0),
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
        .system_enable(csr_system_enable),
        .continuous_mode(csr_continuous_mode),
        .drop_oldest_mode(csr_drop_oldest_mode),
        .start_pulse(csr_start_pulse),
        .abort_pulse(csr_abort_pulse),
        .clear_stats_pulse(csr_clear_stats_pulse),
        .frame_width(csr_frame_width),
        .frame_height(csr_frame_height),
        .input_stride_bytes(csr_input_stride_bytes),
        .output_stride_bytes(csr_output_stride_bytes),
        .input_pixel_format(csr_input_pixel_format),
        .output_pixel_format(csr_output_pixel_format),
        .input_buffer_table_base(csr_input_buffer_table_base),
        .output_buffer_table_base(csr_output_buffer_table_base),
        .descriptor_base(csr_descriptor_base),
        .descriptor_count(csr_descriptor_count),
        .style_id(csr_style_id),
        .weight_base(csr_weight_base),
        .display_mode(csr_display_mode),
        .irq(irq)
    );

    // Software writes ISP shadow state in 0x200..0x2ff.  COMMIT and Gamma
    // commands are held as ready/valid requests until the pixel pipeline is
    // empty, so active frame configuration cannot be changed partway through.
    c1_apb_isp_config #(
        .APB_ADDR_W(APB_ADDR_W)
    ) u_isp_config (
        .clk(clk),
        .rst_n(local_rst_n),
        .psel(isp_apb_psel),
        .penable(isp_apb_penable),
        .pwrite(isp_apb_pwrite),
        .paddr(isp_apb_paddr),
        .pwdata(isp_apb_pwdata),
        .pstrb(isp_apb_pstrb),
        .prdata(isp_apb_prdata),
        .pready(isp_apb_pready),
        .pslverr(isp_apb_pslverr),
        .cfg_valid(isp_cfg_commit),
        .cfg_ready(isp_cfg_ready),
        .cfg_bayer_pattern(isp_cfg_bayer_pattern),
        .cfg_roi_x_parity(isp_cfg_roi_x_parity),
        .cfg_roi_y_parity(isp_cfg_roi_y_parity),
        .cfg_black_r(isp_cfg_black_r),
        .cfg_black_gr(isp_cfg_black_gr),
        .cfg_black_gb(isp_cfg_black_gb),
        .cfg_black_b(isp_cfg_black_b),
        .cfg_awb_gain_r(isp_cfg_awb_gain_r),
        .cfg_awb_gain_g(isp_cfg_awb_gain_g),
        .cfg_awb_gain_b(isp_cfg_awb_gain_b),
        .cfg_ccm_rr(isp_cfg_ccm_rr),
        .cfg_ccm_rg(isp_cfg_ccm_rg),
        .cfg_ccm_rb(isp_cfg_ccm_rb),
        .cfg_ccm_gr(isp_cfg_ccm_gr),
        .cfg_ccm_gg(isp_cfg_ccm_gg),
        .cfg_ccm_gb(isp_cfg_ccm_gb),
        .cfg_ccm_br(isp_cfg_ccm_br),
        .cfg_ccm_bg(isp_cfg_ccm_bg),
        .cfg_ccm_bb(isp_cfg_ccm_bb),
        .cfg_ccm_offset_r(isp_cfg_ccm_offset_r),
        .cfg_ccm_offset_g(isp_cfg_ccm_offset_g),
        .cfg_ccm_offset_b(isp_cfg_ccm_offset_b),
        .gamma_valid(isp_gamma_cfg_we),
        .gamma_cfg_ready(isp_gamma_cfg_ready),
        .gamma_cfg_addr(isp_gamma_cfg_addr),
        .gamma_cfg_data(isp_gamma_cfg_data),
        .abort_pulse(isp_cfg_abort_pulse)
    );

    // Snapshot the CSR shadow registers.  64-bit descriptor addresses are
    // rejected instead of silently truncating them to the current 32-bit AXI.
    always_ff @(posedge clk or negedge local_rst_n) begin
        if (!local_rst_n) begin
            job_command_valid <= 1'b0;
            job_command_accept_pulse <= 1'b0;
            scheduler_start_pulse <= 1'b0;
            descriptor_launch_pending <= 1'b0;
            local_start_error_pulse <= 1'b0;
            local_start_error_code <= 8'h00;
            local_start_error_address <= 32'h0000_0000;
            job_frame_width <= 16'd0;
            job_frame_height <= 16'd0;
            job_continuous_mode <= 1'b0;
            job_drop_oldest_mode <= 1'b0;
            job_input_stride_bytes <= 32'd0;
            job_output_stride_bytes <= 32'd0;
            job_input_pixel_format <= 4'd0;
            job_output_pixel_format <= 4'd0;
            job_input_buffer_table_base <= 64'd0;
            job_output_buffer_table_base <= 64'd0;
            job_descriptor_base <= 32'd0;
            job_descriptor_count <= 16'd0;
            job_style_id <= 8'd0;
            job_weight_base <= 64'd0;
            job_display_mode <= 8'd0;
        end else begin
            job_command_accept_pulse <= 1'b0;
            scheduler_start_pulse <= 1'b0;
            local_start_error_pulse <= 1'b0;

            if (csr_abort_pulse) begin
                job_command_valid <= 1'b0;
                descriptor_launch_pending <= 1'b0;
            end else begin
                if (descriptor_busy || descriptor_done_pulse ||
                    descriptor_error_pulse || descriptor_aborted_pulse) begin
                    descriptor_launch_pending <= 1'b0;
                end
                if (csr_start_pulse) begin
                    if (!csr_system_enable) begin
                        local_start_error_pulse <= 1'b1;
                        local_start_error_code <= 8'h11;
                        local_start_error_address <= 32'h0000_0010;
                    end else if (system_busy) begin
                        local_start_error_pulse <= 1'b1;
                        local_start_error_code <= 8'h12;
                        local_start_error_address <= 32'h0000_0014;
                    end else if (csr_descriptor_base[63:32] != 32'd0) begin
                        local_start_error_pulse <= 1'b1;
                        local_start_error_code <= 8'h13;
                        local_start_error_address <= csr_descriptor_base[31:0];
                    end else begin
                        job_frame_width <= csr_frame_width;
                        job_frame_height <= csr_frame_height;
                        job_continuous_mode <= csr_continuous_mode;
                        job_drop_oldest_mode <= csr_drop_oldest_mode;
                        job_input_stride_bytes <= csr_input_stride_bytes;
                        job_output_stride_bytes <= csr_output_stride_bytes;
                        job_input_pixel_format <= csr_input_pixel_format;
                        job_output_pixel_format <= csr_output_pixel_format;
                        job_input_buffer_table_base <= csr_input_buffer_table_base;
                        job_output_buffer_table_base <= csr_output_buffer_table_base;
                        job_descriptor_base <= csr_descriptor_base[31:0];
                        job_descriptor_count <= csr_descriptor_count;
                        job_style_id <= csr_style_id;
                        job_weight_base <= csr_weight_base;
                        job_display_mode <= csr_display_mode;
                        job_command_valid <= 1'b1;
                    end
                end

                if (job_command_valid && job_command_ready) begin
                    job_command_valid <= 1'b0;
                    job_command_accept_pulse <= 1'b1;
                    scheduler_start_pulse <= 1'b1;
                    descriptor_launch_pending <= 1'b1;
                end
            end
        end
    end

    c1_descriptor_scheduler_subsystem #(
        .COUNT_BITS(16)
    ) u_descriptor_control (
        .clk(clk),
        .rst(core_rst),
        .start_pulse(scheduler_start_pulse),
        .abort_pulse(csr_abort_pulse),
        .descriptor_count(job_descriptor_count),
        .descriptor_base(job_descriptor_base),
        .layer_command_valid(layer_command_valid),
        .layer_command_ready(layer_command_ready),
        .layer_command_index(layer_command_index),
        .layer_command_descriptor(layer_command_descriptor),
        .layer_done_pulse(layer_done_pulse),
        .layer_error_pulse(layer_error_pulse),
        .busy(descriptor_busy),
        .done_pulse(descriptor_done_pulse),
        .error_pulse(descriptor_error_pulse),
        .aborted_pulse(descriptor_aborted_pulse),
        .active_layer_index(active_layer_index),
        .m_axi_araddr(desc_araddr),
        .m_axi_arlen(desc_arlen),
        .m_axi_arsize(desc_arsize),
        .m_axi_arburst(desc_arburst),
        .m_axi_arvalid(desc_arvalid),
        .m_axi_arready(desc_arready),
        .m_axi_rdata(desc_rdata),
        .m_axi_rresp(desc_rresp),
        .m_axi_rlast(desc_rlast),
        .m_axi_rvalid(desc_rvalid),
        .m_axi_rready(desc_rready)
    );

    c1_axi_xrgb_frame_reader u_input_frame_dma (
        .clk(clk),
        .rst(core_rst),
        .start(input_dma_start),
        .cancel(1'b0),
        .cfg_base_addr(input_dma_base_addr),
        .cfg_width_pixels(job_frame_width),
        .cfg_height_lines(job_frame_height),
        .cfg_stride_bytes(job_input_stride_bytes),
        .busy(input_dma_busy),
        .done(input_dma_done),
        .error(input_dma_error),
        .m_valid(dma_input_valid),
        .m_ready(dma_input_ready),
        .m_rgb(dma_input_rgb),
        .m_sof(dma_input_sof),
        .m_eol(dma_input_eol),
        .m_eof(dma_input_eof),
        .m_x(dma_input_x),
        .m_y(dma_input_y),
        .m_axi_araddr(frame_araddr),
        .m_axi_arlen(frame_arlen),
        .m_axi_arsize(frame_arsize),
        .m_axi_arburst(frame_arburst),
         .m_axi_arvalid(frame_arvalid),
         .m_axi_arready(frame_arready),
         .m_axi_rdata(frame_rdata),
        .m_axi_rresp(frame_rresp),
        .m_axi_rlast(frame_rlast),
        .m_axi_rvalid(frame_rvalid),
         .m_axi_rready(frame_rready),
         .m_axi_ar_allow(1'b1)
     );

    c1_axi_xrgb_frame_writer u_output_frame_dma (
        .clk(clk),
        .rst(core_rst),
        .start(output_dma_start),
        .cancel(1'b0),
        .cfg_base_addr(output_dma_base_addr),
        .cfg_width_pixels(job_frame_width),
        .cfg_height_lines(job_frame_height),
        .cfg_stride_bytes(job_output_stride_bytes),
        .busy(output_dma_busy),
        .done(output_dma_done),
        .error(output_dma_error),
        .s_valid(engine_output_valid),
        .s_ready(engine_output_ready),
        .s_rgb(engine_output_rgb),
        .s_sof(engine_output_sof),
        .s_eol(engine_output_eol),
        .s_eof(engine_output_eof),
        .m_axi_awaddr(writer_awaddr),
        .m_axi_awlen(writer_awlen),
        .m_axi_awsize(writer_awsize),
        .m_axi_awburst(writer_awburst),
        .m_axi_awvalid(writer_awvalid),
        .m_axi_awready(writer_awready),
        .m_axi_wdata(writer_wdata),
        .m_axi_wstrb(writer_wstrb),
        .m_axi_wlast(writer_wlast),
        .m_axi_wvalid(writer_wvalid),
        .m_axi_wready(writer_wready),
        .m_axi_bresp(writer_bresp),
        .m_axi_bvalid(writer_bvalid),
        .m_axi_bready(writer_bready)
    );

    c1_r1_isp_pipeline #(
        .FRAME_WIDTH(ISP_FRAME_WIDTH),
        .FRAME_HEIGHT(ISP_FRAME_HEIGHT),
        .X_BITS(ISP_X_BITS),
        .Y_BITS(ISP_Y_BITS)
    ) u_r1_isp (
        .clk(clk),
        .rst(core_rst),
        .in_valid(raw_input_valid),
        .in_sof(raw_input_sof),
        .in_eol(raw_input_eol),
        .in_eof(raw_input_eof),
        .in_x(raw_input_x),
        .in_y(raw_input_y),
        .in_raw10(raw_input_raw10),
        .cfg_commit(isp_cfg_commit),
        .cfg_ready(isp_cfg_ready),
        .cfg_bayer_pattern(isp_cfg_bayer_pattern),
        .cfg_roi_x_parity(isp_cfg_roi_x_parity),
        .cfg_roi_y_parity(isp_cfg_roi_y_parity),
        .cfg_black_r(isp_cfg_black_r),
        .cfg_black_gr(isp_cfg_black_gr),
        .cfg_black_gb(isp_cfg_black_gb),
        .cfg_black_b(isp_cfg_black_b),
        .cfg_awb_gain_r(isp_cfg_awb_gain_r),
        .cfg_awb_gain_g(isp_cfg_awb_gain_g),
        .cfg_awb_gain_b(isp_cfg_awb_gain_b),
        .cfg_ccm_rr(isp_cfg_ccm_rr),
        .cfg_ccm_rg(isp_cfg_ccm_rg),
        .cfg_ccm_rb(isp_cfg_ccm_rb),
        .cfg_ccm_gr(isp_cfg_ccm_gr),
        .cfg_ccm_gg(isp_cfg_ccm_gg),
        .cfg_ccm_gb(isp_cfg_ccm_gb),
        .cfg_ccm_br(isp_cfg_ccm_br),
        .cfg_ccm_bg(isp_cfg_ccm_bg),
        .cfg_ccm_bb(isp_cfg_ccm_bb),
        .cfg_ccm_offset_r(isp_cfg_ccm_offset_r),
        .cfg_ccm_offset_g(isp_cfg_ccm_offset_g),
        .cfg_ccm_offset_b(isp_cfg_ccm_offset_b),
        .gamma_cfg_we(isp_gamma_cfg_we),
        .gamma_cfg_addr(isp_gamma_cfg_addr),
        .gamma_cfg_data(isp_gamma_cfg_data),
        .gamma_cfg_ready(isp_gamma_cfg_ready),
        .out_valid(isp_core_valid),
        .out_sof(isp_core_sof),
        .out_eol(isp_core_eol),
        .out_eof(isp_core_eof),
        .out_x(isp_core_x),
        .out_y(isp_core_y),
        .out_rgb888(isp_core_rgb)
    );

    assign isp_fifo_in_data = {isp_core_eof, isp_core_eol, isp_core_sof,
                               isp_core_y, isp_core_x, isp_core_rgb};
    assign isp_stream_overflow_event = isp_core_valid && !isp_fifo_in_ready;

    c1_stream_fifo #(
        .DATA_WIDTH(ISP_STREAM_WIDTH),
        .DEPTH(ISP_FIFO_DEPTH),
        .LEVEL_WIDTH(ISP_FIFO_LEVEL_WIDTH)
    ) u_isp_elastic_boundary (
        .clk(clk),
        .rst(core_rst),
        .in_valid(isp_core_valid),
        .in_ready(isp_fifo_in_ready),
        .in_data(isp_fifo_in_data),
        .out_valid(isp_stream_valid),
        .out_ready(isp_stream_ready),
        .out_data(isp_fifo_out_data),
        .full(isp_fifo_full),
        .empty(isp_fifo_empty),
        .level(isp_fifo_level)
    );

    assign isp_stream_rgb = isp_fifo_out_data[23:0];
    assign isp_stream_x = isp_fifo_out_data[24 +: ISP_X_BITS];
    assign isp_stream_y = isp_fifo_out_data[24+ISP_X_BITS +: ISP_Y_BITS];
    assign isp_stream_sof = isp_fifo_out_data[24+ISP_X_BITS+ISP_Y_BITS];
    assign isp_stream_eol = isp_fifo_out_data[25+ISP_X_BITS+ISP_Y_BITS];
    assign isp_stream_eof = isp_fifo_out_data[26+ISP_X_BITS+ISP_Y_BITS];

    // First arbitration level: the two read-only masters.  Their write inputs
    // are tied inactive; the arbiter still provides a complete AXI interface
    // for clean cascading into the outer level.
    c1_axi2_serial_arbiter_128 u_read_arbiter (
        .clk(clk), .rst(core_rst),
        .s0_awaddr(32'd0), .s0_awlen(8'd0), .s0_awsize(3'd0),
        .s0_awburst(2'd0), .s0_awvalid(1'b0), .s0_awready(),
        .s0_wdata(128'd0), .s0_wstrb(16'd0), .s0_wlast(1'b0),
        .s0_wvalid(1'b0), .s0_wready(), .s0_bresp(), .s0_bvalid(),
        .s0_bready(1'b1),
        .s0_araddr(desc_araddr), .s0_arlen(desc_arlen),
        .s0_arsize(desc_arsize), .s0_arburst(desc_arburst),
        .s0_arvalid(desc_arvalid), .s0_arready(desc_arready),
        .s0_rdata(desc_rdata), .s0_rresp(desc_rresp),
        .s0_rlast(desc_rlast), .s0_rvalid(desc_rvalid),
        .s0_rready(desc_rready),
        .s1_awaddr(32'd0), .s1_awlen(8'd0), .s1_awsize(3'd0),
        .s1_awburst(2'd0), .s1_awvalid(1'b0), .s1_awready(),
        .s1_wdata(128'd0), .s1_wstrb(16'd0), .s1_wlast(1'b0),
        .s1_wvalid(1'b0), .s1_wready(), .s1_bresp(), .s1_bvalid(),
        .s1_bready(1'b1),
        .s1_araddr(frame_araddr), .s1_arlen(frame_arlen),
        .s1_arsize(frame_arsize), .s1_arburst(frame_arburst),
        .s1_arvalid(frame_arvalid), .s1_arready(frame_arready),
        .s1_rdata(frame_rdata), .s1_rresp(frame_rresp),
        .s1_rlast(frame_rlast), .s1_rvalid(frame_rvalid),
        .s1_rready(frame_rready),
        .m_awaddr(inner_awaddr), .m_awlen(inner_awlen),
        .m_awsize(inner_awsize), .m_awburst(inner_awburst),
        .m_awvalid(inner_awvalid), .m_awready(inner_awready),
        .m_wdata(inner_wdata), .m_wstrb(inner_wstrb),
        .m_wlast(inner_wlast), .m_wvalid(inner_wvalid),
        .m_wready(inner_wready), .m_bresp(inner_bresp),
        .m_bvalid(inner_bvalid), .m_bready(inner_bready),
        .m_araddr(inner_araddr), .m_arlen(inner_arlen),
        .m_arsize(inner_arsize), .m_arburst(inner_arburst),
        .m_arvalid(inner_arvalid), .m_arready(inner_arready),
        .m_rdata(inner_rdata), .m_rresp(inner_rresp),
        .m_rlast(inner_rlast), .m_rvalid(inner_rvalid),
        .m_rready(inner_rready)
    );

    // Second level: the aggregated read side plus the write-only frame writer.
    // Read and write directions remain independent inside the arbiter.
    c1_axi2_serial_arbiter_128 u_memory_arbiter (
        .clk(clk), .rst(core_rst),
        .s0_awaddr(inner_awaddr), .s0_awlen(inner_awlen),
        .s0_awsize(inner_awsize), .s0_awburst(inner_awburst),
        .s0_awvalid(inner_awvalid), .s0_awready(inner_awready),
        .s0_wdata(inner_wdata), .s0_wstrb(inner_wstrb),
        .s0_wlast(inner_wlast), .s0_wvalid(inner_wvalid),
        .s0_wready(inner_wready), .s0_bresp(inner_bresp),
        .s0_bvalid(inner_bvalid), .s0_bready(inner_bready),
        .s0_araddr(inner_araddr), .s0_arlen(inner_arlen),
        .s0_arsize(inner_arsize), .s0_arburst(inner_arburst),
        .s0_arvalid(inner_arvalid), .s0_arready(inner_arready),
        .s0_rdata(inner_rdata), .s0_rresp(inner_rresp),
        .s0_rlast(inner_rlast), .s0_rvalid(inner_rvalid),
        .s0_rready(inner_rready),
        .s1_awaddr(writer_awaddr), .s1_awlen(writer_awlen),
        .s1_awsize(writer_awsize), .s1_awburst(writer_awburst),
        .s1_awvalid(writer_awvalid), .s1_awready(writer_awready),
        .s1_wdata(writer_wdata), .s1_wstrb(writer_wstrb),
        .s1_wlast(writer_wlast), .s1_wvalid(writer_wvalid),
        .s1_wready(writer_wready), .s1_bresp(writer_bresp),
        .s1_bvalid(writer_bvalid), .s1_bready(writer_bready),
        .s1_araddr(32'd0), .s1_arlen(8'd0), .s1_arsize(3'd0),
        .s1_arburst(2'd0), .s1_arvalid(1'b0), .s1_arready(),
        .s1_rdata(), .s1_rresp(), .s1_rlast(), .s1_rvalid(),
        .s1_rready(1'b1),
        .m_awaddr(m_axi_awaddr), .m_awlen(m_axi_awlen),
        .m_awsize(m_axi_awsize), .m_awburst(m_axi_awburst),
        .m_awvalid(m_axi_awvalid), .m_awready(m_axi_awready),
        .m_wdata(m_axi_wdata), .m_wstrb(m_axi_wstrb),
        .m_wlast(m_axi_wlast), .m_wvalid(m_axi_wvalid),
        .m_wready(m_axi_wready), .m_bresp(m_axi_bresp),
        .m_bvalid(m_axi_bvalid), .m_bready(m_axi_bready),
        .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
        .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst),
        .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready),
        .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
        .m_rlast(m_axi_rlast), .m_rvalid(m_axi_rvalid),
        .m_rready(m_axi_rready)
    );

endmodule
