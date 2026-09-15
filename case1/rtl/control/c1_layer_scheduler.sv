// Vendor-independent descriptor/layer scheduler for the R1 accelerator.
//
// Exactly one descriptor request and one layer are outstanding. The external
// descriptor reader may be a small on-chip RAM or an AXI DMA; the compute
// engine receives the complete descriptor only after a successful response.
// This module deliberately does not interpret descriptor fields, keeping the
// control sequencing independent from the final tensor/DMA microarchitecture.
`timescale 1ns/1ps

module c1_layer_scheduler #(
    parameter integer DESCRIPTOR_BITS = 512,
    parameter integer COUNT_BITS      = 16
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start_pulse,
    input  logic                         abort_pulse,
    input  logic [COUNT_BITS-1:0]        descriptor_count,

    output logic                         descriptor_request_valid,
    input  logic                         descriptor_request_ready,
    output logic [COUNT_BITS-1:0]        descriptor_request_index,
    input  logic                         descriptor_response_valid,
    input  logic                         descriptor_response_error,
    input  logic [DESCRIPTOR_BITS-1:0]   descriptor_response_data,

    output logic                         layer_command_valid,
    input  logic                         layer_command_ready,
    output logic [COUNT_BITS-1:0]        layer_command_index,
    output logic [DESCRIPTOR_BITS-1:0]   layer_command_descriptor,
    input  logic                         layer_done_pulse,
    input  logic                         layer_error_pulse,

    output logic                         busy,
    output logic                         done_pulse,
    output logic                         error_pulse,
    output logic                         aborted_pulse,
    output logic [COUNT_BITS-1:0]        active_layer_index
);
    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_REQUEST,
        STATE_RESPONSE,
        STATE_LAUNCH,
        STATE_RUN
    } scheduler_state_t;

    scheduler_state_t state;
    logic [COUNT_BITS-1:0] count_latched;
    logic [DESCRIPTOR_BITS-1:0] descriptor_latched;

    always_comb begin
        descriptor_request_valid = (state == STATE_REQUEST);
        descriptor_request_index = active_layer_index;
        layer_command_valid = (state == STATE_LAUNCH);
        layer_command_index = active_layer_index;
        layer_command_descriptor = descriptor_latched;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            count_latched <= '0;
            descriptor_latched <= '0;
            active_layer_index <= '0;
            busy <= 1'b0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            aborted_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            aborted_pulse <= 1'b0;

            if (abort_pulse && (state != STATE_IDLE)) begin
                state <= STATE_IDLE;
                busy <= 1'b0;
                aborted_pulse <= 1'b1;
            end else begin
                case (state)
                    STATE_IDLE: begin
                        busy <= 1'b0;
                        if (start_pulse) begin
                            if (descriptor_count == 0) begin
                                error_pulse <= 1'b1;
                            end else begin
                                count_latched <= descriptor_count;
                                active_layer_index <= '0;
                                busy <= 1'b1;
                                state <= STATE_REQUEST;
                            end
                        end
                    end

                    STATE_REQUEST: begin
                        if (descriptor_request_valid && descriptor_request_ready)
                            state <= STATE_RESPONSE;
                    end

                    STATE_RESPONSE: begin
                        if (descriptor_response_valid) begin
                            if (descriptor_response_error) begin
                                busy <= 1'b0;
                                error_pulse <= 1'b1;
                                state <= STATE_IDLE;
                            end else begin
                                descriptor_latched <= descriptor_response_data;
                                state <= STATE_LAUNCH;
                            end
                        end
                    end

                    STATE_LAUNCH: begin
                        if (layer_command_valid && layer_command_ready)
                            state <= STATE_RUN;
                    end

                    STATE_RUN: begin
                        if (layer_error_pulse) begin
                            busy <= 1'b0;
                            error_pulse <= 1'b1;
                            state <= STATE_IDLE;
                        end else if (layer_done_pulse) begin
                            if (active_layer_index == count_latched - 1'b1) begin
                                busy <= 1'b0;
                                done_pulse <= 1'b1;
                                state <= STATE_IDLE;
                            end else begin
                                active_layer_index <= active_layer_index + 1'b1;
                                state <= STATE_REQUEST;
                            end
                        end
                    end

                    default: begin
                        state <= STATE_IDLE;
                        busy <= 1'b0;
                        error_pulse <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
