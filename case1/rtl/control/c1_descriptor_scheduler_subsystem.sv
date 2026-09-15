`timescale 1ns/1ps

// Thin board-independent integration of c1_layer_scheduler and the AXI128
// descriptor reader.  The external reset is active-high.  It is explicitly
// inverted for the scheduler, whose reset input is asynchronous active-low;
// therefore asserting rst resets the scheduler immediately and resets the
// active-high synchronous reader on the next clk.
//
// descriptor_base must remain stable for a scheduled run.  The reader samples
// it together with every descriptor request and ignores later changes for that
// in-flight AXI transaction.
module c1_descriptor_scheduler_subsystem #(
    parameter integer COUNT_BITS = 16
) (
    input  logic                       clk,
    input  logic                       rst,

    input  logic                       start_pulse,
    input  logic                       abort_pulse,
    input  logic [COUNT_BITS-1:0]      descriptor_count,
    input  logic [31:0]                descriptor_base,

    output logic                       layer_command_valid,
    input  logic                       layer_command_ready,
    output logic [COUNT_BITS-1:0]      layer_command_index,
    output logic [511:0]               layer_command_descriptor,
    input  logic                       layer_done_pulse,
    input  logic                       layer_error_pulse,

    output logic                       busy,
    output logic                       done_pulse,
    output logic                       error_pulse,
    output logic                       aborted_pulse,
    output logic [COUNT_BITS-1:0]      active_layer_index,

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

    logic scheduler_rst_n;

    logic descriptor_request_valid;
    logic descriptor_request_ready;
    logic [COUNT_BITS-1:0] descriptor_request_index;
    logic descriptor_response_valid;
    logic descriptor_response_error;
    logic [511:0] descriptor_response_data;

    assign scheduler_rst_n = ~rst;

    c1_layer_scheduler #(
        .DESCRIPTOR_BITS(512),
        .COUNT_BITS(COUNT_BITS)
    ) u_scheduler (
        .clk(clk),
        .rst_n(scheduler_rst_n),
        .start_pulse(start_pulse),
        .abort_pulse(abort_pulse),
        .descriptor_count(descriptor_count),
        .descriptor_request_valid(descriptor_request_valid),
        .descriptor_request_ready(descriptor_request_ready),
        .descriptor_request_index(descriptor_request_index),
        .descriptor_response_valid(descriptor_response_valid),
        .descriptor_response_error(descriptor_response_error),
        .descriptor_response_data(descriptor_response_data),
        .layer_command_valid(layer_command_valid),
        .layer_command_ready(layer_command_ready),
        .layer_command_index(layer_command_index),
        .layer_command_descriptor(layer_command_descriptor),
        .layer_done_pulse(layer_done_pulse),
        .layer_error_pulse(layer_error_pulse),
        .busy(busy),
        .done_pulse(done_pulse),
        .error_pulse(error_pulse),
        .aborted_pulse(aborted_pulse),
        .active_layer_index(active_layer_index)
    );

    c1_axi_descriptor_reader #(
        .INDEX_BITS(COUNT_BITS)
    ) u_descriptor_reader (
        .clk(clk),
        .rst(rst),
        .abort(abort_pulse),
        .descriptor_base(descriptor_base),
        .descriptor_request_valid(descriptor_request_valid),
        .descriptor_request_ready(descriptor_request_ready),
        .descriptor_request_index(descriptor_request_index),
        .descriptor_response_valid(descriptor_response_valid),
        .descriptor_response_error(descriptor_response_error),
        .descriptor_response_data(descriptor_response_data),
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
        .m_axi_rready(m_axi_rready)
    );

endmodule
